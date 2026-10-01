import Foundation

/// A cell colour: a palette index or a true-colour triple, never both and never a CSS string.
/// `Hashable` rather than only `Equatable` so a host can deduplicate styles as it walks a grid. That
/// is not a wire change — the conformance is Swift-side and the encoding is written out below — but
/// it is what lets the exporter send one style per distinct appearance instead of one per cell.
enum WireColor: Hashable, Sendable {
    case palette(index: Int)
    case rgb(r: Int, g: Int, b: Int)

    var kind: String {
        switch self {
        case .palette: "palette"
        case .rgb: "rgb"
        }
    }
}

extension WireColor: Codable {
    private enum Field {
        static let kind = "kind"
        static let index = "index"
        static let r = "r", g = "g", b = "b"
        static let all: Set<String> = [kind, index, r, g, b]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "color")
        let kind: String = try container.require(String.self, Field.kind, path: "color")
        switch kind {
        case "palette":
            let index = try container.require(Int.self, Field.index, path: "color")
            guard try container.optional(Int.self, Field.r) == nil,
                try container.optional(Int.self, Field.g) == nil,
                try container.optional(Int.self, Field.b) == nil
            else {
                throw WireError.invalidValue(
                    path: "color", reason: "palette carries rgb components")
            }
            self = .palette(
                index: try WireValue.safeInteger(
                    index, path: "color.index", range: 0...WireLimits.maxColorIndex))
        case "rgb":
            guard try container.optional(Int.self, Field.index) == nil else {
                throw WireError.invalidValue(path: "color", reason: "rgb carries an index")
            }
            let r = try WireValue.safeInteger(
                try container.require(Int.self, Field.r, path: "color"),
                path: "color.r", range: 0...WireLimits.maxChannel)
            let g = try WireValue.safeInteger(
                try container.require(Int.self, Field.g, path: "color"),
                path: "color.g", range: 0...WireLimits.maxChannel)
            let b = try WireValue.safeInteger(
                try container.require(Int.self, Field.b, path: "color"),
                path: "color.b", range: 0...WireLimits.maxChannel)
            self = .rgb(r: r, g: g, b: b)
        default:
            throw WireError.invalidValue(path: "color.kind", reason: "unknown kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(kind, forKey: WireKey(Field.kind))
        switch self {
        case let .palette(index):
            _ = try WireValue.safeInteger(index, path: "color.index", range: 0...WireLimits.maxColorIndex)
            try container.encode(index, forKey: WireKey(Field.index))
        case let .rgb(r, g, b):
            for channel in [r, g, b] {
                _ = try WireValue.safeInteger(channel, path: "color.rgb", range: 0...WireLimits.maxChannel)
            }
            try container.encode(r, forKey: WireKey(Field.r))
            try container.encode(g, forKey: WireKey(Field.g))
            try container.encode(b, forKey: WireKey(Field.b))
        }
    }
}

/// `{fg,bg,flags}`. Flags are eight named bits in a fixed order; a renderer reads the bit, never a
/// font name or a CSS class.
/// `Hashable` for the same reason as `WireColor`: a style table is a dictionary keyed on the style,
/// and one style object per cell is an order of magnitude more bytes for no information.
struct WireStyle: Hashable, Sendable, Codable {
    var fg: WireColor
    var bg: WireColor
    var flags: Int

    private enum Field {
        static let fg = "fg", bg = "bg", flags = "flags"
        static let all: Set<String> = [fg, bg, flags]
    }

    init(fg: WireColor, bg: WireColor, flags: Int) {
        self.fg = fg
        self.bg = bg
        self.flags = flags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "style")
        self.fg = try container.require(WireColor.self, Field.fg, path: "style")
        self.bg = try container.require(WireColor.self, Field.bg, path: "style")
        self.flags = try WireValue.safeInteger(
            try container.require(Int.self, Field.flags, path: "style"),
            path: "style.flags", range: 0...WireLimits.maxStyleFlags)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(fg, forKey: WireKey(Field.fg))
        try container.encode(bg, forKey: WireKey(Field.bg))
        _ = try WireValue.safeInteger(flags, path: "style.flags", range: 0...WireLimits.maxStyleFlags)
        try container.encode(flags, forKey: WireKey(Field.flags))
    }
}

/// One cell. `width` is 1 for a normal grapheme, 2 for a wide one and 0 for the continuation that
/// follows it.
struct WireCell: Equatable, Sendable, Codable {
    var text: String
    var width: Int
    var style: Int

    private enum Field {
        static let text = "text", width = "width", style = "style"
        static let all: Set<String> = [text, width, style]
    }

    init(text: String, width: Int, style: Int) {
        self.text = text
        self.width = width
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "cell")
        self.text = try container.require(String.self, Field.text, path: "cell")
        self.width = try WireValue.safeInteger(
            try container.require(Int.self, Field.width, path: "cell"),
            path: "cell.width", range: 0...2)
        self.style = try WireValue.safeInteger(
            try container.require(Int.self, Field.style, path: "cell"),
            path: "cell.style", range: 0...WireLimits.maxStyleIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(text, forKey: WireKey(Field.text))
        try container.encode(width, forKey: WireKey(Field.width))
        try container.encode(style, forKey: WireKey(Field.style))
    }
}

/// A row is a bare JSON array of cells, exactly `columns` long. It is a type rather than an array
/// alias so the row rules live next to the cell rules.
struct WireRow: Equatable, Sendable {
    var cells: [WireCell]

    init(cells: [WireCell]) { self.cells = cells }
}

extension WireRow: Codable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var cells: [WireCell] = []
        while !container.isAtEnd {
            cells.append(try container.decode(WireCell.self))
        }
        self.cells = cells
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for cell in cells { try container.encode(cell) }
    }
}

enum WireCursorShape: String, Sendable, CaseIterable, Codable {
    case block, underline, bar
}

struct WireCursor: Equatable, Sendable, Codable {
    var row: Int
    var column: Int
    var visible: Bool
    var shape: WireCursorShape
    var blink: Bool

    private enum Field {
        static let row = "row", column = "column", visible = "visible"
        static let shape = "shape", blink = "blink"
        static let all: Set<String> = [row, column, visible, shape, blink]
    }

    init(row: Int, column: Int, visible: Bool, shape: WireCursorShape, blink: Bool) {
        self.row = row
        self.column = column
        self.visible = visible
        self.shape = shape
        self.blink = blink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "cursor")
        // A grid may hold up to the whole snapshot line budget, so the row bound is that budget,
        // not the column dimension. `WireGrid.validate` narrows it to the actual line count.
        self.row = try WireValue.safeInteger(
            try container.require(Int.self, Field.row, path: "cursor"),
            path: "cursor.row", range: 0...WireLimits.maxTotalGridLines)
        self.column = try WireValue.safeInteger(
            try container.require(Int.self, Field.column, path: "cursor"),
            path: "cursor.column", range: 0...WireLimits.maxGridDimension)
        self.visible = try container.require(Bool.self, Field.visible, path: "cursor")
        self.shape = try container.require(WireCursorShape.self, Field.shape, path: "cursor")
        self.blink = try container.require(Bool.self, Field.blink, path: "cursor")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(row, forKey: WireKey(Field.row))
        try container.encode(column, forKey: WireKey(Field.column))
        try container.encode(visible, forKey: WireKey(Field.visible))
        try container.encode(shape, forKey: WireKey(Field.shape))
        try container.encode(blink, forKey: WireKey(Field.blink))
    }
}

/// `{lines,cursor}`. A grid carries bounded visible/recent state, never the whole scrollback.
struct WireGrid: Equatable, Sendable, Codable {
    var lines: [WireRow]
    var cursor: WireCursor

    private enum Field {
        static let lines = "lines", cursor = "cursor"
        static let all: Set<String> = [lines, cursor]
    }

    init(lines: [WireRow], cursor: WireCursor) {
        self.lines = lines
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "grid")
        self.lines = try container.require([WireRow].self, Field.lines, path: "grid")
        self.cursor = try container.require(WireCursor.self, Field.cursor, path: "grid")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(lines, forKey: WireKey(Field.lines))
        try container.encode(cursor, forKey: WireKey(Field.cursor))
    }

    /// Geometry, cursor placement and every cell in one pass. `columns` comes from the snapshot,
    /// because a row cannot know how wide it is supposed to be.
    func validate(path: String, columns: Int) throws {
        guard (WireLimits.minGridDimension...WireLimits.maxGridDimension).contains(columns) else {
            throw WireError.outOfBounds(path: path, reason: "columns \(columns)")
        }
        for (index, row) in lines.enumerated() {
            try row.validate(path: "\(path)[\(index)]", columns: columns)
        }
        if lines.isEmpty {
            guard cursor.row == 0, cursor.column == 0, !cursor.visible else {
                throw WireError.outOfBounds(
                    path: "\(path).cursor", reason: "empty grid must park an invisible cursor at 0,0")
            }
            return
        }
        guard cursor.row >= 0, cursor.row < lines.count else {
            throw WireError.outOfBounds(
                path: "\(path).cursor.row", reason: "\(cursor.row) of \(lines.count) lines")
        }
        guard cursor.column >= 0, cursor.column < columns else {
            throw WireError.outOfBounds(
                path: "\(path).cursor.column", reason: "\(cursor.column) of \(columns) columns")
        }
    }
}

extension WireRow {
    /// A row is exactly `columns` cells. Continuations are checked against their neighbour on both
    /// sides, so no frame can leave a half-width pair or a wide cell hanging off the last column.
    func validate(path: String, columns: Int) throws {
        guard cells.count == columns else {
            throw WireError.outOfBounds(
                path: path, reason: "\(cells.count) cells, expected \(columns)")
        }
        for (index, cell) in cells.enumerated() {
            let cellPath = "\(path)[\(index)]"
            _ = try WireValue.safeInteger(cell.style, path: "\(cellPath).style", range: 0...WireLimits.maxStyleIndex)
            switch cell.width {
            case 0:
                guard cell.text.isEmpty else {
                    throw WireError.invalidValue(
                        path: cellPath, reason: "continuation cell carries text")
                }
                guard index > 0, cells[index - 1].width == 2 else {
                    throw WireError.invalidValue(
                        path: cellPath, reason: "isolated continuation cell")
                }
            case 1:
                _ = try WireValue.visibleGrapheme(cell.text, path: cellPath)
            case 2:
                guard index < columns - 1 else {
                    throw WireError.outOfBounds(
                        path: cellPath, reason: "wide cell in the last column")
                }
                guard cells[index + 1].width == 0 else {
                    throw WireError.invalidValue(
                        path: cellPath, reason: "wide cell without a continuation")
                }
                _ = try WireValue.visibleGrapheme(cell.text, path: cellPath)
            default:
                throw WireError.invalidValue(path: cellPath, reason: "width \(cell.width)")
            }
        }
    }
}

/// The active draft and its selection, in UTF-16 offsets because that is what a text editor
/// reports. This is draft selection only, never native scrollback selection.
struct WireEditor: Equatable, Sendable, Codable {
    var visible: Bool
    var text: String
    var selectionStart: Int
    var selectionLength: Int

    private enum Field {
        static let visible = "visible", text = "text"
        static let start = "selection_start", length = "selection_length"
        static let all: Set<String> = [visible, text, start, length]
    }

    init(visible: Bool, text: String, selectionStart: Int, selectionLength: Int) {
        self.visible = visible
        self.text = text
        self.selectionStart = selectionStart
        self.selectionLength = selectionLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "editor")
        self.visible = try container.require(Bool.self, Field.visible, path: "editor")
        self.text = try container.require(String.self, Field.text, path: "editor")
        self.selectionStart = try WireValue.safeInteger(
            try container.require(Int.self, Field.start, path: "editor"),
            path: "editor.selection_start")
        self.selectionLength = try WireValue.safeInteger(
            try container.require(Int.self, Field.length, path: "editor"),
            path: "editor.selection_length")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(visible, forKey: WireKey(Field.visible))
        try container.encode(text, forKey: WireKey(Field.text))
        try container.encode(selectionStart, forKey: WireKey(Field.start))
        try container.encode(selectionLength, forKey: WireKey(Field.length))
    }

    func validate(path: String) throws {
        try WireValue.utf8(text, path: "\(path).text", limit: WireLimits.maxEditorBytes)
        guard visible else {
            guard text.isEmpty, selectionStart == 0, selectionLength == 0 else {
                throw WireError.invalidValue(
                    path: path, reason: "hidden editor must carry no text or selection")
            }
            return
        }
        _ = try WireValue.safeInteger(selectionStart, path: "\(path).selection_start")
        _ = try WireValue.safeInteger(selectionLength, path: "\(path).selection_length")
        let units = Array(text.utf16)
        let end = selectionStart + selectionLength
        guard end <= units.count else {
            throw WireError.outOfBounds(
                path: "\(path).selection_length",
                reason: "selection ends at \(end) of \(units.count) UTF-16 units")
        }
        // A selection may not begin or end inside a surrogate pair: the browser would split a
        // scalar and render half a character.
        for offset in [selectionStart, end] where offset < units.count {
            let unit = units[offset]
            if unit >= 0xDC00 && unit <= 0xDFFF {
                throw WireError.outOfBounds(
                    path: path, reason: "selection offset \(offset) splits a surrogate pair")
            }
        }
    }
}

/// Where the viewer is looking. Every referenced block must exist in the same snapshot.
struct WireViewport: Equatable, Sendable, Codable {
    var firstBlockID: String
    var firstLine: Int
    var pinnedBlockID: String

    private enum Field {
        static let first = "first_block_id", line = "first_line", pinned = "pinned_block_id"
        static let all: Set<String> = [first, line, pinned]
    }

    init(firstBlockID: String, firstLine: Int, pinnedBlockID: String) {
        self.firstBlockID = firstBlockID
        self.firstLine = firstLine
        self.pinnedBlockID = pinnedBlockID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "viewport")
        self.firstBlockID = try WireValue.uuid(
            try container.require(String.self, Field.first, path: "viewport"),
            path: "viewport.first_block_id")
        self.firstLine = try WireValue.safeInteger(
            try container.require(Int.self, Field.line, path: "viewport"),
            path: "viewport.first_line", range: 0...WireLimits.maxTotalGridLines)
        self.pinnedBlockID = try WireValue.uuid(
            try container.require(String.self, Field.pinned, path: "viewport"),
            path: "viewport.pinned_block_id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(firstBlockID, forKey: WireKey(Field.first))
        try container.encode(firstLine, forKey: WireKey(Field.line))
        try container.encode(pinnedBlockID, forKey: WireKey(Field.pinned))
    }
}

enum WireBlockState: String, Sendable, CaseIterable, Codable {
    case draft, running, sealed
}

enum WireMode: String, Sendable, CaseIterable, Codable {
    case blocks, fullscreen
}

/// One block: its identity, its prompt line and its two grids. No cwd, hostname, environment, Git
/// state or hyperlink travels — those leak information and none is needed to render a cell.
struct WireBlock: Equatable, Sendable, Codable {
    var id: String
    var command: String
    var state: WireBlockState
    var collapsed: Bool
    var header: WireGrid
    var output: WireGrid
    var exitCode: Int?
    var durationMS: Int?

    private enum Field {
        static let id = "id", command = "command", state = "state"
        static let collapsed = "collapsed", header = "header", output = "output"
        static let exitCode = "exit_code", duration = "duration_ms"
        static let all: Set<String> = [
            id, command, state, collapsed, header, output, exitCode, duration,
        ]
    }

    init(
        id: String, command: String, state: WireBlockState, collapsed: Bool,
        header: WireGrid, output: WireGrid, exitCode: Int? = nil, durationMS: Int? = nil
    ) {
        self.id = id
        self.command = command
        self.state = state
        self.collapsed = collapsed
        self.header = header
        self.output = output
        self.exitCode = exitCode
        self.durationMS = durationMS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "block")
        self.id = try WireValue.uuid(
            try container.require(String.self, Field.id, path: "block"), path: "block.id")
        self.command = try container.require(String.self, Field.command, path: "block")
        self.state = try container.require(WireBlockState.self, Field.state, path: "block")
        self.collapsed = try container.require(Bool.self, Field.collapsed, path: "block")
        self.header = try container.require(WireGrid.self, Field.header, path: "block")
        self.output = try container.require(WireGrid.self, Field.output, path: "block")
        if let exitCode = try container.optional(Int.self, Field.exitCode) {
            self.exitCode = try WireValue.signedInt32(exitCode, path: "block.exit_code")
        } else {
            self.exitCode = nil
        }
        if let duration = try container.optional(Int.self, Field.duration) {
            self.durationMS = try WireValue.safeInteger(duration, path: "block.duration_ms")
        } else {
            self.durationMS = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(id, forKey: WireKey(Field.id))
        try container.encode(command, forKey: WireKey(Field.command))
        try container.encode(state, forKey: WireKey(Field.state))
        try container.encode(collapsed, forKey: WireKey(Field.collapsed))
        try container.encode(header, forKey: WireKey(Field.header))
        try container.encode(output, forKey: WireKey(Field.output))
        try container.encodeIfPresent(exitCode, forKey: WireKey(Field.exitCode))
        try container.encodeIfPresent(durationMS, forKey: WireKey(Field.duration))
    }

    func validate(path: String, columns: Int) throws {
        try WireValue.utf8(command, path: "\(path).command", limit: WireLimits.maxCommandBytes)
        _ = try WireValue.uuid(id, path: "\(path).id")
        if let exitCode { _ = try WireValue.signedInt32(exitCode, path: "\(path).exit_code") }
        if let durationMS { _ = try WireValue.safeInteger(durationMS, path: "\(path).duration_ms") }
        try header.validate(path: "\(path).header", columns: columns)
        try output.validate(path: "\(path).output", columns: columns)
    }

    /// Both grids' line counts, which is what the snapshot-level cap is spent on.
    var lineCount: Int { header.lines.count + output.lines.count }
}

/// The assembled snapshot: the whole visible/recent model, small enough to travel as one unit.
struct WireSnapshot: Equatable, Sendable, Codable {
    var version: Int
    var epoch: String
    var seq: String
    var mode: WireMode
    var columns: Int
    var rows: Int
    var styles: [WireStyle]
    var blocks: [WireBlock]
    var viewport: WireViewport
    var editor: WireEditor

    private enum Field {
        static let version = "version", epoch = "epoch", seq = "seq", mode = "mode"
        static let columns = "columns", rows = "rows", styles = "styles"
        static let blocks = "blocks", viewport = "viewport", editor = "editor"
        static let all: Set<String> = [
            version, epoch, seq, mode, columns, rows, styles, blocks, viewport, editor,
        ]
    }

    init(
        version: Int = WireLimits.schemaVersion, epoch: String, seq: String, mode: WireMode,
        columns: Int, rows: Int, styles: [WireStyle], blocks: [WireBlock],
        viewport: WireViewport, editor: WireEditor
    ) {
        self.version = version
        self.epoch = epoch
        self.seq = seq
        self.mode = mode
        self.columns = columns
        self.rows = rows
        self.styles = styles
        self.blocks = blocks
        self.viewport = viewport
        self.editor = editor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "snapshot")
        let version = try container.require(Int.self, Field.version, path: "snapshot")
        guard version == WireLimits.schemaVersion else {
            throw WireError.unsupportedVersion(got: version)
        }
        self.version = version
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "snapshot"),
            path: "snapshot.epoch"))
        // The snapshot's own seq may be 0: it is the state before the first damage frame.
        self.seq = String(try WireValue.counter(
            try container.require(String.self, Field.seq, path: "snapshot"), path: "snapshot.seq"))
        self.mode = try container.require(WireMode.self, Field.mode, path: "snapshot")
        self.columns = try WireValue.safeInteger(
            try container.require(Int.self, Field.columns, path: "snapshot"),
            path: "snapshot.columns",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
        self.rows = try WireValue.safeInteger(
            try container.require(Int.self, Field.rows, path: "snapshot"),
            path: "snapshot.rows",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
        self.styles = try container.require([WireStyle].self, Field.styles, path: "snapshot")
        self.blocks = try container.require([WireBlock].self, Field.blocks, path: "snapshot")
        self.viewport = try container.require(WireViewport.self, Field.viewport, path: "snapshot")
        self.editor = try container.require(WireEditor.self, Field.editor, path: "snapshot")
        // A decoded snapshot is validated before it can be returned, so no caller ever holds a
        // value that the contract rejects.
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(version, forKey: WireKey(Field.version))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(seq, forKey: WireKey(Field.seq))
        try container.encode(mode, forKey: WireKey(Field.mode))
        try container.encode(columns, forKey: WireKey(Field.columns))
        try container.encode(rows, forKey: WireKey(Field.rows))
        try container.encode(styles, forKey: WireKey(Field.styles))
        try container.encode(blocks, forKey: WireKey(Field.blocks))
        try container.encode(viewport, forKey: WireKey(Field.viewport))
        try container.encode(editor, forKey: WireKey(Field.editor))
    }

    /// Everything the snapshot is responsible for, in the order a reader would ask about it.
    func validate() throws {
        guard version == WireLimits.schemaVersion else {
            throw WireError.unsupportedVersion(got: version)
        }
        _ = try WireValue.positiveCounter(epoch, path: "snapshot.epoch")
        _ = try WireValue.counter(seq, path: "snapshot.seq")
        _ = try WireValue.safeInteger(
            columns, path: "snapshot.columns",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
        _ = try WireValue.safeInteger(
            rows, path: "snapshot.rows",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
        guard styles.count <= WireLimits.maxStyles else {
            throw WireError.oversized(
                path: "snapshot.styles", limit: WireLimits.maxStyles, actual: styles.count)
        }
        guard !styles.isEmpty else {
            throw WireError.invalidValue(
                path: "snapshot.styles", reason: "index 0 is the default style")
        }
        guard blocks.count <= WireLimits.maxBlocks else {
            throw WireError.oversized(
                path: "snapshot.blocks", limit: WireLimits.maxBlocks, actual: blocks.count)
        }

        var identifiers = Set<String>()
        var lines = 0
        for (index, block) in blocks.enumerated() {
            let path = "snapshot.blocks[\(index)]"
            _ = try WireValue.uuid(block.id, path: "\(path).id")
            guard identifiers.insert(block.id).inserted else {
                throw WireError.duplicateID(block.id)
            }
            try block.validate(path: path, columns: columns)
            lines += block.lineCount
        }
        guard lines <= WireLimits.maxTotalGridLines else {
            throw WireError.oversized(
                path: "snapshot.blocks", limit: WireLimits.maxTotalGridLines, actual: lines)
        }

        // Every style a cell names must exist, or a renderer would fall back silently.
        for (blockIndex, block) in blocks.enumerated() {
            for (gridName, grid) in [("header", block.header), ("output", block.output)] {
                for (lineIndex, row) in grid.lines.enumerated() {
                    for (cellIndex, cell) in row.cells.enumerated() {
                        guard cell.style < styles.count else {
                            throw WireError.outOfBounds(
                                path: "snapshot.blocks[\(blockIndex)].\(gridName)"
                                    + "[\(lineIndex)][\(cellIndex)].style",
                                reason: "style \(cell.style) of \(styles.count)")
                        }
                    }
                }
            }
        }

        _ = try WireValue.safeInteger(viewport.firstLine, path: "snapshot.viewport.first_line",
                                      range: 0...WireLimits.maxTotalGridLines)
        guard identifiers.contains(viewport.firstBlockID) else {
            throw WireError.unknownBlock(viewport.firstBlockID)
        }
        guard identifiers.contains(viewport.pinnedBlockID) else {
            throw WireError.unknownBlock(viewport.pinnedBlockID)
        }
        try editor.validate(path: "snapshot.editor")

        if mode == .fullscreen {
            guard blocks.count == 1 else {
                throw WireError.invalidValue(
                    path: "snapshot.blocks",
                    reason: "fullscreen has exactly one active block, got \(blocks.count)")
            }
            guard !editor.visible else {
                throw WireError.invalidValue(
                    path: "snapshot.editor", reason: "fullscreen hides the editor")
            }
        }

        // The assembled size is the last rule, because it is the one the relay enforces on bytes.
        let bytes = try WireCanonicalJSON.encode(self).count
        guard bytes <= WireLimits.maxSnapshotBytes else {
            throw WireError.oversized(
                path: "snapshot", limit: WireLimits.maxSnapshotBytes, actual: bytes)
        }
    }

    /// The digest a `snapshot.begin` frame advertises.
    func sha256Hex() throws -> String { try WireCanonicalJSON.sha256Hex(self) }
}
