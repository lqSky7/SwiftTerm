import Foundation

/// Turns a pane's live model into the wire DTO.
///
/// This is the one place the terminal's own types meet the contract's, and it is deliberately a
/// **pure function over a snapshot of the model** rather than something that reads the live model as
/// it goes. The handoff's rule is that capture happens on the main actor against immutable state and
/// that encoding happens off it; a converter that reached back into a grid while it ran would be
/// doing the opposite, and would race the shell.
///
/// Three mappings are worth stating because they are losses or conventions rather than copies:
///
///   * **Default colours become palette indices 0 and 7.** The model keeps `.defaultForeground` and
///     `.defaultBackground` symbolic so a theme change repaints history; the wire has no "default"
///     case, only an index or an RGB triple. Index 0 for the background and 7 for the foreground is
///     the convention the golden fixture already uses, and the browser viewer resolves the same two
///     slots — the three agree or the same stream renders differently in two places.
///   * **Underline variants collapse to one bit.** The model distinguishes single, double, curly,
///     dotted and dashed because it draws them differently. The wire has one underline bit, so the
///     distinction is lost here. That is a real loss and it is why the model keeps them: a future
///     schema version can carry them without the parser changing.
///   * **The window is bounded, and the oldest blocks go first.** A viewer follows the tail of a
///     session, so a budget that has to give gives up the beginning. The relay's ring is bounded by
///     time for the same reason.
struct PaneExporter {
    /// How many lines of one block's output travel. The contract caps the whole snapshot at 2000
    /// lines, so a per-block window keeps one long block from crowding out every other.
    static let outputWindowLines = 200

    private let identity: ExportIdentityRegistry

    init(identity: ExportIdentityRegistry = ExportIdentityRegistry()) {
        self.identity = identity
    }

    /// Build a snapshot from a captured pane.
    ///
    /// `blocks` is expected oldest first, which is the order the model keeps them in and the order
    /// the wire carries them.
    func snapshot(
        paneID: String,
        blocks: [Block],
        size: TerminalSize,
        alternateScreen: Bool,
        editor: EditorCapture,
        epoch: String,
        seq: Int,
        pinnedBlockID: UInt64?
    ) -> WireSnapshot {
        var registry = identity
        var styles = StyleTable()
        var wireBlocks: [WireBlock] = []
        var lineBudget = WireLimits.maxTotalGridLines

        // Newest first while budgeting, then reversed: the blocks a viewer needs are the recent
        // ones, so the budget is spent from the tail of the session and the beginning is what goes.
        let candidates = blocks.suffix(WireLimits.maxBlocks)
        for block in candidates.reversed() {
            let header = grid(
                lines: lines(of: block.headerGrid.promptAndCommandGrid, window: nil),
                cursorRow: block.headerGrid.promptAndCommandGrid.grid.cursorRow,
                cursorColumn: block.headerGrid.promptAndCommandGrid.grid.cursorColumn,
                cursorVisible: block.headerGrid.promptAndCommandGrid.grid.modes.cursorVisible,
                cursorStyle: block.headerGrid.promptAndCommandGrid.grid.cursorStyle,
                styles: &styles)
            let output = grid(
                lines: lines(of: block.outputGrid, window: Self.outputWindowLines),
                cursorRow: block.outputGrid.grid.cursorRow,
                cursorColumn: block.outputGrid.grid.cursorColumn,
                cursorVisible: block.outputGrid.grid.modes.cursorVisible,
                cursorStyle: block.outputGrid.grid.cursorStyle,
                styles: &styles)

            let cost = header.lines.count + output.lines.count
            if lineBudget - cost < 0, !wireBlocks.isEmpty { break }
            lineBudget -= cost

            wireBlocks.append(
                WireBlock(
                    id: registry.identity(for: block.id.rawValue),
                    command: block.command ?? "",
                    state: state(of: block),
                    collapsed: block.isCollapsed,
                    header: header,
                    output: output,
                    exitCode: block.exitCode,
                    durationMS: duration(of: block)))
        }
        wireBlocks.reverse()

        let firstBlock = wireBlocks.first?.id ?? ""
        let pinned = pinnedBlockID.flatMap { registry.existingIdentity(for: $0) } ?? firstBlock

        return WireSnapshot(
            epoch: epoch,
            seq: String(seq),
            mode: alternateScreen ? .fullscreen : .blocks,
            columns: size.columns,
            rows: size.rows,
            styles: styles.ordered,
            blocks: wireBlocks,
            viewport: WireViewport(
                firstBlockID: firstBlock, firstLine: 0, pinnedBlockID: pinned),
            editor: editor.wire(using: &styles))
    }

    /// The state a block is in.
    ///
    /// Derived rather than stored, because the model does not keep one — "running" is exactly "the
    /// output grid has started and not finished", and a second field would be a second answer to the
    /// same question.
    private func state(of block: Block) -> WireBlockState {
        if block.isSealed { return .sealed }
        if block.isSubmitted { return .running }
        return .draft
    }

    private func duration(of block: Block) -> Int? {
        guard let started = block.outputGrid.startedAt else { return nil }
        let finished = block.outputGrid.finishedAt ?? Date()
        return max(0, Int(finished.timeIntervalSince(started) * 1000))
    }

    /// The lines of a grid, bounded to a window at the tail.
    private func lines(of grid: BlockGrid, window: Int?) -> [TerminalLine] {
        let total = grid.lineCount
        guard total > 0 else { return [] }
        let count = min(window ?? total, total)
        let start = total - count
        return (start..<total).compactMap { grid.line(at: $0) }
    }

    private func grid(
        lines: [TerminalLine],
        cursorRow: Int,
        cursorColumn: Int,
        cursorVisible: Bool,
        cursorStyle: TerminalCursorStyle,
        styles: inout StyleTable
    ) -> WireGrid {
        // A row is a type rather than an array alias, so the row rules live beside the cell rules.
        // The mapping is where a bare `[[WireCell]]` becomes the contract's `[WireRow]`.
        let rows = lines.map { line in
            WireRow(
                cells: line.cells.map { cell in
                    // A continuation cell owns no text and no column of its own: its left neighbour is
                    // double-width and already covers this position. Sending it as anything else would
                    // shift every glyph after it.
                    if cell.isContinuation {
                        return WireCell(text: "", width: 0, style: styles.index(for: cell.attributes))
                    }
                    return WireCell(
                        text: cell.text.isEmpty ? " " : cell.text,
                        width: max(1, min(2, cell.width)),
                        style: styles.index(for: cell.attributes))
                })
        }
        // A cursor past the last line would be refused by the browser's own validator, so it is
        // clamped rather than sent: an out-of-bounds cursor is a state the host cannot mean.
        let clampedRow = rows.isEmpty ? 0 : min(max(0, cursorRow), rows.count - 1)
        return WireGrid(
            lines: rows,
            cursor: WireCursor(
                row: clampedRow,
                column: max(0, cursorColumn),
                visible: cursorVisible,
                shape: shape(of: cursorStyle),
                blink: cursorStyle.blinks))
    }

    private func shape(of style: TerminalCursorStyle) -> WireCursorShape {
        switch style.shape {
        case .block: return .block
        case .bar: return .bar
        case .underline: return .underline
        }
    }
}

/// What the prompt editor is showing, captured on the main actor like everything else.
struct EditorCapture: Sendable {
    var visible: Bool
    var text: String
    /// UTF-16 offsets, which is what the contract counts in — the offsets a browser string uses.
    var selectionStart: Int
    var selectionLength: Int

    static let hidden = EditorCapture(visible: false, text: "", selectionStart: 0, selectionLength: 0)

    /// `fileprivate` because `StyleTable` is: the style table is an implementation detail of the
    /// exporter, and widening it to internal to satisfy a method signature would expose the dedup
    /// machinery to the rest of the app for no reason. This is called from `PaneExporter`, one type
    /// up in the same file.
    fileprivate func wire(using styles: inout StyleTable) -> WireEditor {
        WireEditor(
            visible: visible,
            text: text,
            selectionStart: max(0, selectionStart),
            selectionLength: max(0, selectionLength))
    }
}

/// The snapshot's style table, built as the cells are walked.
///
/// Deduplicated because the alternative is one style object per cell: a 40×12 grid is 480 cells and
/// most of them share a handful of styles, so sending them individually would multiply the snapshot
/// by an order of magnitude for no information. Index 0 is reserved for the default, which is what
/// the contract requires and what the browser falls back to.
private struct StyleTable {
    private var seen: [WireStyle: Int] = [:]
    private(set) var ordered: [WireStyle] = []

    init() {
        let fallback = WireStyle(
            fg: .palette(index: Self.defaultForegroundIndex),
            bg: .palette(index: Self.defaultBackgroundIndex),
            flags: 0)
        seen[fallback] = 0
        ordered = [fallback]
    }

    /// Index 0 is the default background and 7 the default foreground, matching the golden fixture
    /// and the browser viewer's own palette.
    static let defaultBackgroundIndex = 0
    static let defaultForegroundIndex = 7

    mutating func index(for attributes: CellAttributes) -> Int {
        let style = wireStyle(for: attributes)
        if let existing = seen[style] { return existing }
        // Past the table cap every further style is the default rather than a new entry. The
        // contract bounds the index at 4095, and a table that ran past it would be a frame the
        // browser refuses outright — losing the distinction is better than losing the frame.
        guard ordered.count < WireLimits.maxStyles else { return 0 }
        let index = ordered.count
        seen[style] = index
        ordered.append(style)
        return index
    }

    private func wireStyle(for attributes: CellAttributes) -> WireStyle {
        WireStyle(
            fg: color(attributes.foreground, fallback: Self.defaultForegroundIndex),
            bg: color(attributes.background, fallback: Self.defaultBackgroundIndex),
            flags: Self.flags(for: attributes.flags))
    }

    private func color(_ color: TerminalColor, fallback: Int) -> WireColor {
        switch color {
        case .defaultForeground, .defaultBackground:
            // Both defaults collapse to the slot they mean, not to one shared slot: a default
            // foreground painted as a background index would invert the whole grid.
            return .palette(index: color == .defaultForeground ? Self.defaultForegroundIndex : Self.defaultBackgroundIndex)
        case .indexed(let index):
            return .palette(index: Int(index))
        case .rgb(let red, let green, let blue):
            return .rgb(r: Int(red), g: Int(green), b: Int(blue))
        }
    }

    /// The model's flags as the contract's eight bits.
    ///
    /// The order is the contract's, not the model's: bold, dim, italic, underline, blink, inverse,
    /// hidden, strike. The four extra underline variants the model carries collapse into the single
    /// underline bit, which is the loss this mapping is allowed to make.
    private static func flags(for flags: CellAttributes.Flags) -> Int {
        var wire = 0
        if flags.contains(.bold) { wire |= 1 << 0 }
        if flags.contains(.faint) { wire |= 1 << 1 }
        if flags.contains(.italic) { wire |= 1 << 2 }
        if !flags.isDisjoint(with: .anyUnderline) { wire |= 1 << 3 }
        if flags.contains(.blink) { wire |= 1 << 4 }
        if flags.contains(.reverse) { wire |= 1 << 5 }
        if flags.contains(.hidden) { wire |= 1 << 6 }
        if flags.contains(.strikethrough) { wire |= 1 << 7 }
        return wire
    }
}
