import Foundation

/// The viewer's copy of the host's model, and the only place the ordering rules are enforced.
///
/// Two invariants do the real work. First, a snapshot is the *only* carrier of an epoch, a
/// geometry or a mode change, so applying one replaces every field at once and no cell from the
/// previous mode can survive into the new one. Second, a damage frame is applied to a copy and
/// swapped in only if every operation succeeded, so a frame that fails halfway leaves the view
/// exactly as it was rather than half-updated.
struct WireStreamState: Sendable {
    private(set) var epoch: String?
    private(set) var seq: Int64 = -1
    private(set) var mode: WireMode?
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var styles: [WireStyle] = []
    private(set) var blocks: [WireBlock] = []
    private(set) var viewport: WireViewport?
    private(set) var editor: WireEditor?

    var isPrimed: Bool { epoch != nil }
    var blockCount: Int { blocks.count }
    var totalLines: Int { blocks.reduce(0) { $0 + $1.lineCount } }
    var lastSeq: Int64 { seq }

    func block(id: String) -> WireBlock? { blocks.first { $0.id == id } }

    func index(ofBlock id: String) -> Int? { blocks.firstIndex { $0.id == id } }

    /// The barrier. Everything the previous epoch knew is dropped: blocks, styles, viewport,
    /// editor and geometry all come from this one snapshot.
    mutating func apply(snapshot: WireSnapshot) throws {
        try snapshot.validate()
        if let epoch {
            let currentEpoch = try WireValue.positiveCounter(epoch, path: "state.epoch")
            let incomingEpoch = try WireValue.positiveCounter(snapshot.epoch, path: "snapshot.epoch")
            guard incomingEpoch >= currentEpoch else {
                throw WireError.staleEpoch(expected: epoch, got: snapshot.epoch)
            }
            if incomingEpoch == currentEpoch, try WireValue.counter(snapshot.seq, path: "snapshot.seq") < seq {
                throw WireError.resyncRequired(reason: "snapshot watermark precedes current state")
            }
        }
        epoch = snapshot.epoch
        seq = try WireValue.counter(snapshot.seq, path: "snapshot.seq")
        mode = snapshot.mode
        columns = snapshot.columns
        rows = snapshot.rows
        styles = snapshot.styles
        blocks = snapshot.blocks
        viewport = snapshot.viewport
        editor = snapshot.editor
    }

    /// Returns `true` when the frame was applied and `false` when it was a same-epoch duplicate
    /// at or below the last applied seq, which is ignored rather than replayed.
    @discardableResult
    mutating func apply(damage: WireDamage) throws -> Bool {
        guard let epoch else {
            throw WireError.resyncRequired(reason: "damage before any snapshot")
        }
        guard damage.epoch == epoch else {
            throw WireError.staleEpoch(expected: epoch, got: damage.epoch)
        }
        let incoming = try WireValue.counter(damage.seq, path: "damage.seq")
        if incoming <= seq { return false }
        let base = try WireValue.counter(damage.baseSeq, path: "damage.base_seq")
        guard base == seq else {
            throw WireError.sequenceGap(expected: String(seq + 1), got: damage.seq)
        }
        try damage.validate()

        var nextBlocks = blocks
        var nextViewport = viewport
        var nextEditor = editor
        for op in damage.changes {
            try Self.apply(
                op, blocks: &nextBlocks, viewport: &nextViewport, editor: &nextEditor,
                columns: columns, styles: styles)
        }
        guard let mode, let nextViewport, let nextEditor else {
            throw WireError.resyncRequired(reason: "unprimed viewer state")
        }
        try WireSnapshot(epoch: epoch, seq: damage.seq, mode: mode, columns: columns, rows: rows,
                         styles: styles, blocks: nextBlocks, viewport: nextViewport,
                         editor: nextEditor).validate()

        blocks = nextBlocks
        viewport = nextViewport
        editor = nextEditor
        seq = incoming
        return true
    }

    /// Applies one operation to a copy of the state. Operations check only their *local*
    /// preconditions — bounds, existence, geometry. Cross-cutting state such as cursor placement
    /// is checked once per frame by the snapshot validator, because a frame may truncate a
    /// grid and move the cursor in the same message, and an eager per-operation check would reject
    /// an intermediate state that never ships.
    private static func apply(
        _ op: WireDamageOp, blocks: inout [WireBlock], viewport: inout WireViewport?,
        editor: inout WireEditor?, columns: Int, styles: [WireStyle]
    ) throws {
        switch op {
        case let .insertBlock(afterID, block):
            guard blocks.count < WireLimits.maxBlocks else {
                throw WireError.oversized(
                    path: "insert_block", limit: WireLimits.maxBlocks, actual: blocks.count + 1)
            }
            try block.validate(path: "insert_block.block", columns: columns)
            guard !blocks.contains(where: { $0.id == block.id }) else {
                throw WireError.duplicateID(block.id)
            }
            guard let afterID else {
                blocks.insert(block, at: 0)
                return
            }
            guard let index = blocks.firstIndex(where: { $0.id == afterID }) else {
                throw WireError.unknownBlock(afterID)
            }
            blocks.insert(block, at: index + 1)

        case let .removeBlock(blockID):
            // Deleting an unknown id is an error, not a no-op: a silent no-op would let a
            // desynchronised viewer keep showing a block the host already dropped.
            guard let index = blocks.firstIndex(where: { $0.id == blockID }) else {
                throw WireError.unknownBlock(blockID)
            }
            blocks.remove(at: index)

        case let .replaceHeader(blockID, command, state, exitCode, durationMS):
            let index = try requireIndex(blockID, in: blocks)
            try WireValue.utf8(
                command, path: "replace_header.command", limit: WireLimits.maxCommandBytes)
            blocks[index].command = command
            blocks[index].state = state
            blocks[index].exitCode = exitCode
            blocks[index].durationMS = durationMS

        case let .setCollapsed(blockID, collapsed):
            let index = try requireIndex(blockID, in: blocks)
            blocks[index].collapsed = collapsed

        case let .replaceRow(blockID, grid, row, cells):
            let index = try requireIndex(blockID, in: blocks)
            _ = try WireValue.safeInteger(row, path: "replace_row.row")
            try cells.validate(path: "replace_row.cells", columns: columns)
            var lines = gridLines(blocks[index], grid)
            // Append at the current length only. A row index past the end would leave a gap the
            // viewer has nothing to draw in.
            guard row <= lines.count else {
                throw WireError.outOfBounds(
                    path: "replace_row.row", reason: "\(row) past \(lines.count) lines")
            }
            if row == lines.count {
                lines.append(cells)
            } else {
                lines[row] = cells
            }
            setGridLines(&blocks[index], grid, lines)

        case let .truncateGrid(blockID, grid, lineCount):
            _ = try WireValue.safeInteger(lineCount, path: "truncate_grid.line_count")
            let index = try requireIndex(blockID, in: blocks)
            var lines = gridLines(blocks[index], grid)
            guard lineCount <= lines.count else {
                throw WireError.outOfBounds(
                    path: "truncate_grid.line_count",
                    reason: "\(lineCount) beyond \(lines.count) lines")
            }
            lines.removeLast(lines.count - lineCount)
            setGridLines(&blocks[index], grid, lines)

        case let .setCursor(blockID, grid, cursor):
            let index = try requireIndex(blockID, in: blocks)
            setGridCursor(&blocks[index], grid, cursor)

        case let .replaceEditor(newEditor):
            try newEditor.validate(path: "replace_editor.editor")
            editor = newEditor

        case let .replaceViewport(newViewport):
            viewport = newViewport
        }
    }

    private static func requireIndex(_ blockID: String, in blocks: [WireBlock]) throws -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else {
            throw WireError.unknownBlock(blockID)
        }
        return index
    }

    private static func gridLines(_ block: WireBlock, _ kind: WireGridKind) -> [WireRow] {
        kind == .header ? block.header.lines : block.output.lines
    }

    private static func setGridLines(
        _ block: inout WireBlock, _ kind: WireGridKind, _ lines: [WireRow]
    ) {
        switch kind {
        case .header: block.header.lines = lines
        case .output: block.output.lines = lines
        }
    }

    private static func setGridCursor(
        _ block: inout WireBlock, _ kind: WireGridKind, _ cursor: WireCursor
    ) {
        switch kind {
        case .header: block.header.cursor = cursor
        case .output: block.output.cursor = cursor
        }
    }
}
