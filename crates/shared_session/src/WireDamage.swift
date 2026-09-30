import Foundation

enum WireGridKind: String, Sendable, CaseIterable, Codable {
    case header, output
}

/// The exact damage union. Each case names its own field set, so an `insert_block` carrying a
/// `row` is a rejection rather than a field some peer ignores.
enum WireDamageOp: Equatable, Sendable {
    case insertBlock(afterID: String?, block: WireBlock)
    case removeBlock(blockID: String)
    case replaceHeader(
        blockID: String, command: String, state: WireBlockState, exitCode: Int?, durationMS: Int?)
    case setCollapsed(blockID: String, collapsed: Bool)
    case replaceRow(blockID: String, grid: WireGridKind, row: Int, cells: WireRow)
    case truncateGrid(blockID: String, grid: WireGridKind, lineCount: Int)
    case setCursor(blockID: String, grid: WireGridKind, cursor: WireCursor)
    case replaceEditor(editor: WireEditor)
    case replaceViewport(viewport: WireViewport)

    var name: String {
        switch self {
        case .insertBlock: "insert_block"
        case .removeBlock: "remove_block"
        case .replaceHeader: "replace_header"
        case .setCollapsed: "set_collapsed"
        case .replaceRow: "replace_row"
        case .truncateGrid: "truncate_grid"
        case .setCursor: "set_cursor"
        case .replaceEditor: "replace_editor"
        case .replaceViewport: "replace_viewport"
        }
    }
}

extension WireDamageOp: Codable {
    private enum Field {
        static let op = "op"
        static let afterID = "after_id", block = "block"
        static let blockID = "block_id", command = "command", state = "state"
        static let exitCode = "exit_code", duration = "duration_ms"
        static let collapsed = "collapsed", grid = "grid", row = "row", cells = "cells"
        static let lineCount = "line_count", cursor = "cursor"
        static let editor = "editor", viewport = "viewport"

        static let insert: Set<String> = [op, afterID, block]
        static let remove: Set<String> = [op, blockID]
        static let header: Set<String> = [op, blockID, command, state, exitCode, duration]
        static let collapse: Set<String> = [op, blockID, collapsed]
        static let replaceRow: Set<String> = [op, blockID, grid, row, cells]
        static let truncate: Set<String> = [op, blockID, grid, lineCount]
        static let setCursor: Set<String> = [op, blockID, grid, cursor]
        static let replaceEditorSet: Set<String> = [op, editor]
        static let replaceViewportSet: Set<String> = [op, viewport]
    }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: WireKey.self)
        guard let name = try probe.decodeIfPresent(String.self, forKey: WireKey(Field.op)) else {
            throw WireError.missingField(path: "op", field: Field.op)
        }
        let path = "op.\(name)"
        let known: Set<String>
        switch name {
        case "insert_block": known = Field.insert
        case "remove_block": known = Field.remove
        case "replace_header": known = Field.header
        case "set_collapsed": known = Field.collapse
        case "replace_row": known = Field.replaceRow
        case "truncate_grid": known = Field.truncate
        case "set_cursor": known = Field.setCursor
        case "replace_editor": known = Field.replaceEditorSet
        case "replace_viewport": known = Field.replaceViewportSet
        default:
            throw WireError.invalidValue(path: "op", reason: "unknown operation \(name)")
        }
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: known, path: path)

        switch name {
        case "insert_block":
            var after: String?
            if let raw = try container.optional(String.self, Field.afterID) {
                after = try WireValue.uuid(raw, path: "\(path).after_id")
            }
            self = .insertBlock(
                afterID: after,
                block: try container.require(WireBlock.self, Field.block, path: path))
        case "remove_block":
            self = .removeBlock(blockID: try Self.blockID(container, path))
        case "replace_header":
            let exitCode = try container.optional(Int.self, Field.exitCode).map {
                try WireValue.signedInt32($0, path: "\(path).exit_code")
            }
            let duration = try container.optional(Int.self, Field.duration).map {
                try WireValue.safeInteger($0, path: "\(path).duration_ms")
            }
            self = .replaceHeader(
                blockID: try Self.blockID(container, path),
                command: try WireValue.utf8(
                    try container.require(String.self, Field.command, path: path),
                    path: "\(path).command", limit: WireLimits.maxCommandBytes),
                state: try container.require(WireBlockState.self, Field.state, path: path),
                exitCode: exitCode, durationMS: duration)
        case "set_collapsed":
            self = .setCollapsed(
                blockID: try Self.blockID(container, path),
                collapsed: try container.require(Bool.self, Field.collapsed, path: path))
        case "replace_row":
            self = .replaceRow(
                blockID: try Self.blockID(container, path),
                grid: try container.require(WireGridKind.self, Field.grid, path: path),
                row: try WireValue.safeInteger(
                    try container.require(Int.self, Field.row, path: path),
                    path: "\(path).row", range: 0...WireLimits.maxTotalGridLines),
                cells: try container.require(WireRow.self, Field.cells, path: path))
        case "truncate_grid":
            self = .truncateGrid(
                blockID: try Self.blockID(container, path),
                grid: try container.require(WireGridKind.self, Field.grid, path: path),
                lineCount: try WireValue.safeInteger(
                    try container.require(Int.self, Field.lineCount, path: path),
                    path: "\(path).line_count", range: 0...WireLimits.maxTotalGridLines))
        case "set_cursor":
            self = .setCursor(
                blockID: try Self.blockID(container, path),
                grid: try container.require(WireGridKind.self, Field.grid, path: path),
                cursor: try container.require(WireCursor.self, Field.cursor, path: path))
        case "replace_editor":
            self = .replaceEditor(
                editor: try container.require(WireEditor.self, Field.editor, path: path))
        case "replace_viewport":
            self = .replaceViewport(
                viewport: try container.require(WireViewport.self, Field.viewport, path: path))
        default:
            throw WireError.invalidValue(path: "op", reason: "unknown operation \(name)")
        }
    }

    private static func blockID(
        _ container: KeyedDecodingContainer<WireKey>, _ path: String
    ) throws -> String {
        try WireValue.uuid(
            try container.require(String.self, Field.blockID, path: path),
            path: "\(path).block_id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(name, forKey: WireKey(Field.op))
        switch self {
        case let .insertBlock(afterID, block):
            try container.encodeIfPresent(afterID, forKey: WireKey(Field.afterID))
            try container.encode(block, forKey: WireKey(Field.block))
        case let .removeBlock(blockID):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
        case let .replaceHeader(blockID, command, state, exitCode, durationMS):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
            try container.encode(command, forKey: WireKey(Field.command))
            try container.encode(state, forKey: WireKey(Field.state))
            try container.encodeIfPresent(exitCode, forKey: WireKey(Field.exitCode))
            try container.encodeIfPresent(durationMS, forKey: WireKey(Field.duration))
        case let .setCollapsed(blockID, collapsed):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
            try container.encode(collapsed, forKey: WireKey(Field.collapsed))
        case let .replaceRow(blockID, grid, row, cells):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
            try container.encode(grid, forKey: WireKey(Field.grid))
            try container.encode(row, forKey: WireKey(Field.row))
            try container.encode(cells, forKey: WireKey(Field.cells))
        case let .truncateGrid(blockID, grid, lineCount):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
            try container.encode(grid, forKey: WireKey(Field.grid))
            try container.encode(lineCount, forKey: WireKey(Field.lineCount))
        case let .setCursor(blockID, grid, cursor):
            try container.encode(blockID, forKey: WireKey(Field.blockID))
            try container.encode(grid, forKey: WireKey(Field.grid))
            try container.encode(cursor, forKey: WireKey(Field.cursor))
        case let .replaceEditor(editor):
            try container.encode(editor, forKey: WireKey(Field.editor))
        case let .replaceViewport(viewport):
            try container.encode(viewport, forKey: WireKey(Field.viewport))
        }
    }
}

/// One validated damage frame. `base_seq` must equal the last applied seq and `seq` is
/// `base_seq + 1`; a gap asks for a snapshot instead of guessing.
struct WireDamage: Equatable, Sendable, Codable {
    var epoch: String
    var seq: String
    var baseSeq: String
    var changes: [WireDamageOp]

    private enum Field {
        static let type = "type"
        static let epoch = "epoch", seq = "seq", baseSeq = "base_seq", changes = "changes"
        static let all: Set<String> = [type, epoch, seq, baseSeq, changes]
    }

    static let typeName = "damage"

    init(epoch: String, seq: String, baseSeq: String, changes: [WireDamageOp]) {
        self.epoch = epoch
        self.seq = seq
        self.baseSeq = baseSeq
        self.changes = changes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "damage")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "damage"), path: "damage.epoch"))
        self.seq = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.seq, path: "damage"), path: "damage.seq"))
        self.baseSeq = String(try WireValue.counter(
            try container.require(String.self, Field.baseSeq, path: "damage"),
            path: "damage.base_seq"))
        self.changes = try container.require([WireDamageOp].self, Field.changes, path: "damage")
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(seq, forKey: WireKey(Field.seq))
        try container.encode(baseSeq, forKey: WireKey(Field.baseSeq))
        try container.encode(changes, forKey: WireKey(Field.changes))
    }

    /// The op count, the serialized size and the seq arithmetic, checked together so a frame that
    /// is too big to relay is never the frame that also breaks ordering.
    func validate() throws {
        let seq = try WireValue.positiveCounter(self.seq, path: "damage.seq")
        let base = try WireValue.counter(baseSeq, path: "damage.base_seq")
        guard base < WireLimits.maxCounterValue else {
            throw WireError.resyncRequired(reason: "sequence counter exhausted")
        }
        guard seq == base + 1 else {
            throw WireError.sequenceGap(expected: String(base + 1), got: String(seq))
        }
        guard changes.count <= WireLimits.maxDamageOps else {
            throw WireError.oversized(
                path: "damage.changes", limit: WireLimits.maxDamageOps, actual: changes.count)
        }
        let bytes = try WireCanonicalJSON.encode(self).count
        guard bytes <= WireLimits.maxDamageBytes else {
            throw WireError.oversized(
                path: "damage", limit: WireLimits.maxDamageBytes, actual: bytes)
        }
    }
}
