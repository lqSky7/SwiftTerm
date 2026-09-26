import Foundation

/// The terminal's screen: lines, cursor, scroll region, history and the damage the renderer
/// needs to know about. Every escape sequence the parser understands ends up as a call here,
/// which is what keeps the parser a pure byte state machine and this the only mutable thing.
final class TerminalGrid {
    /// How many lines of history a session keeps. Bounded because the alternative is a terminal
    /// that grows until the machine swaps.
    static let defaultScrollbackLimit = 10_000

    let scrollbackLimit: Int

    private(set) var size: TerminalSize
    private(set) var screen: [TerminalLine]
    private(set) var scrollback: [TerminalLine] = []
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var scrollTop = 0
    private(set) var scrollBottom: Int
    private(set) var cursorStyle = TerminalCursorStyle()
    private(set) var isAlternateScreen = false

    var modes = TerminalModes()
    var pen = TerminalPen()

    /// Bumped on every mutation. A renderer compares it to decide whether it has anything to do.
    private(set) var generation: UInt64 = 0
    /// Per-row stamps, so a repaint can rebuild the two rows a keystroke touched and no others.
    private(set) var rowGenerations: [UInt64]

    private var tabStops: Set<Int> = []
    private var savedCursor: SavedCursor?
    private var savedPrimary: SavedScreen?

    init(size: TerminalSize = .fallback, scrollbackLimit: Int = defaultScrollbackLimit) {
        let size = size.normalized
        self.size = size
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.screen = (0..<size.rows).map { _ in TerminalLine(columns: size.columns) }
        self.scrollBottom = size.rows - 1
        self.rowGenerations = Array(repeating: 0, count: size.rows)
        resetTabStops()
    }

    // MARK: - Damage

    private func markRow(_ row: Int) {
        guard rowGenerations.indices.contains(row) else { return }
        generation += 1
        rowGenerations[row] = generation
    }

    private func markAll() {
        generation += 1
        for index in rowGenerations.indices { rowGenerations[index] = generation }
    }

    /// History changed, which only matters to a renderer scrolled back into it.
    private func markScrollback() {
        generation += 1
    }

    // MARK: - Controls

    /// What a C0 byte does to the screen. It lives on the grid rather than in the parser because
    /// this is terminal behaviour, not byte handling: the parser's job is to know *when* a control
    /// is one, and this is the answer to *what* it means. BEL is a no-op here — the session turns
    /// it into a notification, and a screen has nothing to do about it.
    func applyControl(_ byte: UInt8) {
        switch byte {
        case 0x08: moveCursor(columnDelta: -1)              // BS
        case 0x09: horizontalTab()                          // HT
        case 0x0A, 0x0B, 0x0C: lineFeed()                   // LF, VT, FF
        case 0x0D: carriageReturn()                         // CR
        case 0x0E: pen.usesG1 = true                        // SO
        case 0x0F: pen.usesG1 = false                       // SI
        default: break
        }
    }

    // MARK: - Reading

    /// History and screen as one sequence: `0` is the oldest retained line, and anything at or
    /// past `historyLineCount` is live screen.
    var historyLineCount: Int { scrollback.count }

    var totalLineCount: Int { scrollback.count + screen.count }

    func line(at index: Int) -> TerminalLine? {
        // A part-scrolled viewport asks for the row above the top, which does not exist at the very
        // top of history. A negative index into an empty array is a crash, not a miss.
        guard index >= 0 else { return nil }
        if index < scrollback.count { return scrollback[index] }
        let screenIndex = index - scrollback.count
        return screen.indices.contains(screenIndex) ? screen[screenIndex] : nil
    }

    /// The live screen row a line index falls on, or nil when it is history.
    func screenRow(forLine index: Int) -> Int? {
        let row = index - scrollback.count
        return screen.indices.contains(row) ? row : nil
    }

    /// The line the cursor is on, in the same sequence `line(at:)` indexes.
    ///
    /// This is what a block boundary is measured in: the prompt starts where the cursor is, and the
    /// output starts where the cursor is after the shell has echoed the newline.
    var cursorLine: Int { historyLineCount + cursorRow }

    /// One past the last line that has anything on it. The screen always has `rows` rows, so its
    /// trailing blanks are not content — a block that claimed them would reserve the bottom of the
    /// window for nothing.
    var contentLineCount: Int {
        var index = totalLineCount - 1
        while index >= 0, line(at: index)?.isBlank ?? true { index -= 1 }
        return index + 1
    }

    // MARK: - Cursor

    /// `CUP` / `HVP`: one-based, and relative to the scroll region when origin mode is on.
    func setCursorPosition(row: Int, column: Int) {
        let base = modes.originMode ? scrollTop : 0
        let limit = modes.originMode ? scrollBottom : size.rows - 1
        cursorRow = min(max(base + max(0, row - 1), base), limit)
        cursorColumn = min(max(column - 1, 0), size.columns - 1)
        pen.pendingWrap = false
    }

    func moveCursor(rowDelta: Int = 0, columnDelta: Int = 0) {
        cursorRow = min(max(cursorRow + rowDelta, 0), size.rows - 1)
        cursorColumn = min(max(cursorColumn + columnDelta, 0), size.columns - 1)
        pen.pendingWrap = false
    }

    func setCursorColumn(_ column: Int) {
        cursorColumn = min(max(column, 0), size.columns - 1)
        pen.pendingWrap = false
    }

    func setCursorRow(_ row: Int) {
        cursorRow = min(max(row, 0), size.rows - 1)
        pen.pendingWrap = false
    }

    func carriageReturn() {
        cursorColumn = 0
        pen.pendingWrap = false
    }

    func saveCursor() {
        savedCursor = SavedCursor(
            row: cursorRow, column: cursorColumn, pen: pen, modes: modes, style: cursorStyle)
    }

    func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = min(saved.row, size.rows - 1)
        cursorColumn = min(saved.column, size.columns - 1)
        pen = saved.pen
        modes = saved.modes
        cursorStyle = saved.style
        pen.pendingWrap = false
    }

    func setCursorStyle(_ style: TerminalCursorStyle) {
        cursorStyle = style
        markRow(cursorRow)
    }

    // MARK: - Scrolling

    func setScrollRegion(top: Int, bottom: Int) {
        let top = min(max(top, 0), size.rows - 1)
        let bottom = min(max(bottom, top), size.rows - 1)
        scrollTop = top
        scrollBottom = bottom
        // DECSTBM homes the cursor, and home is the region's origin once origin mode is on.
        setCursorPosition(row: 1, column: 1)
    }

    /// Content moves up and blanks appear at the bottom. A full-height region hands the line it
    /// pushes off the top to history, which is the only path into the scrollback.
    func scrollUp(_ count: Int = 1) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        if scrollTop == 0, scrollBottom == size.rows - 1, !isAlternateScreen {
            for _ in 0..<count {
                scrollback.append(screen.removeFirst())
                screen.append(TerminalLine(columns: size.columns))
            }
            trimScrollback()
            markScrollback()
        } else {
            screen.removeSubrange(scrollTop..<(scrollTop + count))
            let blanks = (0..<count).map { _ in TerminalLine(columns: size.columns) }
            screen.insert(contentsOf: blanks, at: scrollBottom + 1 - count)
        }
        markAll()
    }

    /// Content moves down and blanks appear at the top. Never touches history: a program that
    /// scrolls down is redrawing, not rewinding.
    func scrollDown(_ count: Int = 1) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        screen.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        let blanks = (0..<count).map { _ in TerminalLine(columns: size.columns) }
        screen.insert(contentsOf: blanks, at: scrollTop)
        markAll()
    }

    func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < size.rows - 1 {
            cursorRow += 1
        }
        pen.pendingWrap = false
        if modes.lineFeedMode { cursorColumn = 0 }
    }

    func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
        pen.pendingWrap = false
    }

    func nextLine() {
        carriageReturn()
        lineFeed()
    }

    private func trimScrollback() {
        let excess = scrollback.count - scrollbackLimit
        guard excess > 0 else { return }
        scrollback.removeFirst(excess)
    }

    func clearScrollback() {
        guard !scrollback.isEmpty else { return }
        scrollback.removeAll()
        markScrollback()
        markAll()
    }

    // MARK: - Printing

    func put(_ character: Character) {
        let width = TerminalCell.displayWidth(of: character)
        if width == 0 {
            appendCombining(character)
            return
        }
        if pen.pendingWrap {
            pen.pendingWrap = false
            guard modes.automaticWrap else { return }
            markWrapped(cursorRow)
            carriageReturn()
            lineFeed()
        }
        // A double-width glyph cannot straddle the right margin, so it wraps whole.
        if width == 2, cursorColumn + 1 >= size.columns {
            guard modes.automaticWrap else { return }
            markWrapped(cursorRow)
            carriageReturn()
            lineFeed()
        }
        if modes.insert { insertCharacters(width) }

        let attributes = pen.attributes
        let hyperlink = pen.hyperlink
        setCell(row: cursorRow, column: cursorColumn, cell: TerminalCell(
            text: translated(character), attributes: attributes, width: width, hyperlink: hyperlink))
        if width == 2 {
            setCell(row: cursorRow, column: cursorColumn + 1, cell: TerminalCell(
                text: "", attributes: attributes, width: 0, isContinuation: true, hyperlink: hyperlink))
        }
        advanceCursor(by: width)
    }

    /// Records that the row is continued by the next one, which is the one thing a reflow needs and the
    /// one thing nothing used to write.
    ///
    /// Called *before* the `lineFeed` that follows a wrap, because that feed may scroll — and the flag
    /// has to ride into history with the line it belongs to.
    private func markWrapped(_ row: Int) {
        guard screen.indices.contains(row) else { return }
        screen[row].isWrapped = true
    }

    /// Folds a combining mark into the cell it belongs to. At column zero there is nothing to
    /// fold into, so it is dropped — the same thing xterm does.
    private func appendCombining(_ character: Character) {
        let column = pen.pendingWrap ? size.columns - 1 : cursorColumn - 1
        guard column >= 0, screen[cursorRow].cells.indices.contains(column) else { return }
        var cell = screen[cursorRow].cells[column]
        cell.text += String(character)
        screen[cursorRow].cells[column] = cell
        markRow(cursorRow)
    }

    private func translated(_ character: Character) -> String {
        guard pen.activeCharset == .decSpecialGraphics, character.unicodeScalars.count == 1 else {
            return String(character)
        }
        return String(String.UnicodeScalarView(character.unicodeScalars.map(pen.translate)))
    }

    private func advanceCursor(by width: Int) {
        cursorColumn += width
        guard cursorColumn >= size.columns else { return }
        cursorColumn = size.columns - 1
        pen.pendingWrap = true
    }

    private func setCell(row: Int, column: Int, cell: TerminalCell) {        guard screen.indices.contains(row), screen[row].cells.indices.contains(column) else { return }
        // A wide glyph occupies two cells, so overwriting either half has to blank the other.
        // Without this a row keeps a stray half-glyph that no later output ever repairs.
        let existing = screen[row].cells[column]
        if existing.width == 2, screen[row].cells.indices.contains(column + 1) {
            screen[row].cells[column + 1] = .blank
        } else if existing.isContinuation, column > 0 {
            screen[row].cells[column - 1] = .blank
        }
        screen[row].cells[column] = cell
        markRow(row)
    }

    /// Erased cells take the pen's background, because a program that painted the screen red and
    /// then cleared it expects red. Everything else about them is default.
    private var eraseCell: TerminalCell {
        TerminalCell(text: "", attributes: CellAttributes(background: pen.attributes.background))
    }

    // MARK: - Erasing and editing

    /// `ED`: 0 to end of screen, 1 to start, 2 everything, 3 everything plus history.
    func eraseInDisplay(mode: Int) {
        switch mode {
        case 1:
            eraseInLine(mode: 1)
            for row in 0..<cursorRow { eraseRow(row) }
        case 2:
            for row in screen.indices { eraseRow(row) }
        case 3:
            clearScrollback()
            for row in screen.indices { eraseRow(row) }
        default:
            eraseInLine(mode: 0)
            for row in (cursorRow + 1)..<size.rows where screen.indices.contains(row) { eraseRow(row) }
        }
        markAll()
    }

    /// `EL`: 0 to end of line, 1 to start, 2 the whole line.
    func eraseInLine(mode: Int) {
        let cells = screen[cursorRow].cells
        switch mode {
        case 1:
            for column in 0...min(cursorColumn, cells.count - 1) where cells.indices.contains(column) {
                screen[cursorRow].cells[column] = eraseCell
            }
        case 2:
            for column in cells.indices { screen[cursorRow].cells[column] = eraseCell }
        default:
            for column in cursorColumn..<cells.count where cells.indices.contains(column) {
                screen[cursorRow].cells[column] = eraseCell
            }
        }
        screen[cursorRow].isWrapped = false
        markRow(cursorRow)
    }

    private func eraseRow(_ row: Int) {
        guard screen.indices.contains(row) else { return }
        let cell = eraseCell
        for column in screen[row].cells.indices { screen[row].cells[column] = cell }
        screen[row].isWrapped = false
    }

    /// `ECH`: blanks cells in place, shifting nothing.
    func eraseCharacters(_ count: Int) {
        guard count > 0 else { return }
        let limit = min(cursorColumn + count, size.columns)
        guard cursorColumn < limit else { return }
        for column in cursorColumn..<limit { screen[cursorRow].cells[column] = eraseCell }
        markRow(cursorRow)
    }

    /// `ICH`: pushes the row right, off the end.
    func insertCharacters(_ count: Int) {
        guard count > 0, cursorColumn < size.columns else { return }
        let count = min(count, size.columns - cursorColumn)
        let blanks = Array(repeating: eraseCell, count: count)
        screen[cursorRow].cells.insert(contentsOf: blanks, at: cursorColumn)
        screen[cursorRow].cells.removeLast(count)
        markRow(cursorRow)
    }

    /// `DCH`: pulls the row left and pads with blanks at the margin.
    func deleteCharacters(_ count: Int) {
        guard count > 0, cursorColumn < size.columns else { return }
        let count = min(count, size.columns - cursorColumn)
        screen[cursorRow].cells.removeSubrange(cursorColumn..<(cursorColumn + count))
        screen[cursorRow].cells.append(contentsOf: Array(repeating: eraseCell, count: count))
        markRow(cursorRow)
    }

    /// `IL`: opens blank lines at the cursor, inside the scroll region only.
    func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom, count > 0 else { return }
        let count = min(count, scrollBottom - cursorRow + 1)
        screen.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        let blanks = (0..<count).map { _ in TerminalLine(columns: size.columns) }
        screen.insert(contentsOf: blanks, at: cursorRow)
        cursorColumn = 0
        markAll()
    }

    /// `DL`: removes lines at the cursor, inside the scroll region only.
    func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom, count > 0 else { return }
        let count = min(count, scrollBottom - cursorRow + 1)
        screen.removeSubrange(cursorRow..<(cursorRow + count))
        let blanks = (0..<count).map { _ in TerminalLine(columns: size.columns) }
        screen.insert(contentsOf: blanks, at: scrollBottom + 1 - count)
        cursorColumn = 0
        markAll()
    }

    /// `DECALN`: fills the screen with `E`, the alignment test a terminal is asked for when
    /// something upstream suspects the font metrics are wrong.
    func screenAlignmentTest() {
        for row in screen.indices {
            for column in screen[row].cells.indices {
                screen[row].cells[column] = TerminalCell(text: "E")
            }
            screen[row].isWrapped = false
        }
        cursorRow = 0
        cursorColumn = 0
        pen.pendingWrap = false
        markAll()
    }

    // MARK: - Tabs

    func resetTabStops() {
        tabStops = Set(stride(from: 8, to: max(8, size.columns), by: 8))
    }

    func setTabStop() {
        tabStops.insert(cursorColumn)
    }

    /// `TBC`: 0 clears at the cursor, 3 clears them all.
    func clearTabStops(mode: Int) {
        if mode == 3 { tabStops.removeAll() } else { tabStops.remove(cursorColumn) }
    }

    func horizontalTab() {
        guard let next = tabStops.filter({ $0 > cursorColumn }).min() else {
            setCursorColumn(size.columns - 1)
            return
        }
        setCursorColumn(next)
    }

    func horizontalTabBack() {
        guard let previous = tabStops.filter({ $0 < cursorColumn }).max() else {
            setCursorColumn(0)
            return
        }
        setCursorColumn(previous)
    }

    // MARK: - Alternate screen

    /// `?1049` and friends. The primary screen keeps its history; the alternate one is a clean
    /// grid with no scrollback, which is why a full-screen program cannot pollute `less` output.
    func setAlternateScreen(_ enabled: Bool) {
        guard enabled != isAlternateScreen else { return }
        if enabled {
            savedPrimary = SavedScreen(
                screen: screen, scrollback: scrollback, cursorRow: cursorRow,
                cursorColumn: cursorColumn, pen: pen, scrollTop: scrollTop,
                scrollBottom: scrollBottom, tabStops: tabStops)
            isAlternateScreen = true
            screen = (0..<size.rows).map { _ in TerminalLine(columns: size.columns) }
            scrollback = []
            cursorRow = 0
            cursorColumn = 0
            scrollTop = 0
            scrollBottom = size.rows - 1
            pen.pendingWrap = false
            resetTabStops()
        } else {
            isAlternateScreen = false
            if let saved = savedPrimary {
                screen = saved.screen
                scrollback = saved.scrollback
                cursorRow = min(saved.cursorRow, size.rows - 1)
                cursorColumn = min(saved.cursorColumn, size.columns - 1)
                pen = saved.pen
                scrollTop = saved.scrollTop
                scrollBottom = min(saved.scrollBottom, size.rows - 1)
                tabStops = saved.tabStops
            } else {
                screen = (0..<size.rows).map { _ in TerminalLine(columns: size.columns) }
                cursorRow = 0
                cursorColumn = 0
            }
            savedPrimary = nil
        }
        modes.alternateScreen = enabled
        markAll()
    }

    // MARK: - Resize

    /// A sequence re-wrapped to a new width, and where the cursor ended up in it.
    struct Reflow: Equatable {
        var scrollback: [TerminalLine]
        var screen: [TerminalLine]
        var cursorRow: Int
        var cursorColumn: Int
    }

    /// Re-wraps the grid to a new shape.
    ///
    /// A *logical* line — a run of rows joined by `isWrapped` — is rejoined, re-split at the new column
    /// count, and its flags rebuilt. That is what makes a resize survivable: without it a narrower
    /// window truncated the right-hand side of every long line for good, and a wider one filled the
    /// space with blanks rather than giving the content back.
    func resize(columns: Int, rows: Int) {
        let columns = max(1, columns)
        let rows = max(1, rows)
        guard columns != size.columns || rows != size.rows else { return }

        let reflowed = Self.reflow(
            scrollback: scrollback, screen: screen, columns: columns, rows: rows,
            keepsHistory: !isAlternateScreen,
            cursor: (scrollback.count + cursorRow, cursorColumn))
        scrollback = reflowed.scrollback
        screen = reflowed.screen
        cursorRow = reflowed.cursorRow
        cursorColumn = reflowed.cursorColumn
        trimScrollback()

        // The saved primary screen moves to the new shape too, or leaving a full-screen program after a
        // resize puts a screen of the old shape back, with every line the wrong width.
        if var saved = savedPrimary {
            let savedReflow = Self.reflow(
                scrollback: saved.scrollback, screen: saved.screen, columns: columns, rows: rows,
                keepsHistory: true,
                cursor: (saved.scrollback.count + saved.cursorRow, saved.cursorColumn))
            saved.scrollback = savedReflow.scrollback
            saved.screen = savedReflow.screen
            saved.cursorRow = savedReflow.cursorRow
            saved.cursorColumn = savedReflow.cursorColumn
            saved.scrollTop = 0
            saved.scrollBottom = rows - 1
            savedPrimary = saved
        }

        size = TerminalSize(
            columns: columns, rows: rows, cellWidth: size.cellWidth, cellHeight: size.cellHeight)
        scrollTop = 0
        scrollBottom = rows - 1
        pen.pendingWrap = false
        rowGenerations = Array(repeating: 0, count: rows)
        resetTabStops()
        markAll()
    }

    /// Re-wraps history and screen **together**, then splits the result back into a screen of `rows`
    /// lines with the rest as history.
    ///
    /// Together, because a logical line can straddle the boundary between history and the screen, and
    /// re-wrapping the two apart would tear it in half.
    ///
    /// Pure and static — no state, no clock, no view. That is what makes the hardest arithmetic in the
    /// terminal testable on its own, and it is the arithmetic that, got wrong, silently eats output
    /// rather than failing loudly.
    ///
    /// `keepsHistory` is false on the alternate screen, which has no history by definition: a full-screen
    /// program redraws itself on resize, so what falls off the top is dropped rather than filed.
    static func reflow(
        scrollback: [TerminalLine],
        screen: [TerminalLine],
        columns: Int,
        rows: Int,
        keepsHistory: Bool = true,
        cursor: (line: Int, column: Int)
    ) -> Reflow {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let blank = { (0..<rows).map { _ in TerminalLine(columns: columns) } }
        let full = scrollback + screen
        guard let oldColumns = full.first?.cells.count else {
            return Reflow(scrollback: [], screen: blank(), cursorRow: 0, cursorColumn: 0)
        }

        // The screen's trailing blank rows are padding, not content. Re-wrapping them would inflate the
        // result by a row per blank, and the extra rows would push real content off the top into
        // history — which is how a reflow loses the beginning of a line while looking like it worked.
        // They are dropped here and re-added as padding at the end.
        //
        // Never past the cursor's own line, though: a cursor sitting on a blank row after the content
        // is still a position, and it has to stay in the sequence to be mapped through the reflow.
        var end = full.count
        while end > 0, end - 1 > cursor.line, full[end - 1].isBlank { end -= 1 }
        let sequence = Array(full[0..<end])

        // Join each logical line, and note where the cursor sits inside its own.
        var logical: [[TerminalCell]] = []
        var cursorLogical = 0
        var cursorOffset = 0
        var foundCursor = false
        var index = 0

        while index < sequence.count {
            let start = index
            var cells: [TerminalCell] = []
            while true {
                cells.append(contentsOf: sequence[index].cells)
                let continues = sequence[index].isWrapped
                if !continues || index + 1 >= sequence.count { break }
                index += 1
            }
            if cursor.line >= start, cursor.line <= index {
                cursorLogical = logical.count
                cursorOffset = (cursor.line - start) * oldColumns + cursor.column
                foundCursor = true
            }
            // Trailing blanks are trimmed per logical line, so a blank row stays one blank row rather
            // than becoming a screenful of them.
            while let last = cells.last, last.isBlank { cells.removeLast() }
            logical.append(cells)
            index += 1
        }

        // The cursor can sit past the trimmed content — a prompt at the end of a blank tail — so the
        // line it is on has to be long enough to hold it.
        if foundCursor, logical.indices.contains(cursorLogical) {
            while logical[cursorLogical].count <= cursorOffset {
                logical[cursorLogical].append(.blank)
            }
        }

        // Re-split, and note where the cursor lands.
        var lines: [TerminalLine] = []
        var cursorLine = 0
        var cursorColumn = 0

        for (lineIndex, cells) in logical.enumerated() {
            if lineIndex == cursorLogical {
                cursorLine = lines.count + cursorOffset / columns
                cursorColumn = cursorOffset % columns
            }
            guard !cells.isEmpty else {
                lines.append(TerminalLine(columns: columns))
                continue
            }
            var offset = 0
            while offset < cells.count {
                let end = min(offset + columns, cells.count)
                var segment = Array(cells[offset..<end])
                while segment.count < columns { segment.append(.blank) }
                lines.append(TerminalLine(cells: segment, isWrapped: end < cells.count))
                offset = end
            }
        }

        // The screen is the *bottom* of the result when the content is taller than it, because that is
        // what a terminal shows. `dropped` is how much went off the top, which is what the cursor's row
        // is measured against whether or not that history is being kept.
        let screenCount = min(rows, lines.count)
        let dropped = lines.count - screenCount
        var newScreen = Array(lines.suffix(screenCount))
        // Shorter than the screen: the content sits at the *top* and the padding goes below it, which is
        // where a terminal puts it — the shell writes from row zero and the blank rows are under the
        // prompt. Padding above would put a gap over the prompt, and would count as content in every
        // height calculation downstream.
        while newScreen.count < rows { newScreen.append(TerminalLine(columns: columns)) }

        return Reflow(
            scrollback: keepsHistory ? Array(lines.prefix(dropped)) : [],
            screen: newScreen,
            cursorRow: min(max(cursorLine - dropped, 0), rows - 1),
            cursorColumn: min(cursorColumn, columns - 1))
    }

    /// The pixel geometry the PTY reports. Kept separate from `resize` because a font change
    /// moves these without changing the cell count.
    func setCellGeometry(width: Int, height: Int) {
        size.cellWidth = width
        size.cellHeight = height
    }

    // MARK: - Reset

    /// `RIS`, and what a fresh session starts from.
    func reset() {
        modes = TerminalModes()
        pen = TerminalPen()
        cursorStyle = TerminalCursorStyle()
        isAlternateScreen = false
        savedPrimary = nil
        savedCursor = nil
        scrollback.removeAll()
        screen = (0..<size.rows).map { _ in TerminalLine(columns: size.columns) }
        cursorRow = 0
        cursorColumn = 0
        scrollTop = 0
        scrollBottom = size.rows - 1
        resetTabStops()
        markAll()
    }

    private struct SavedCursor {
        var row: Int
        var column: Int
        var pen: TerminalPen
        var modes: TerminalModes
        var style: TerminalCursorStyle
    }

    private struct SavedScreen {
        var screen: [TerminalLine]
        var scrollback: [TerminalLine]
        var cursorRow: Int
        var cursorColumn: Int
        var pen: TerminalPen
        var scrollTop: Int
        var scrollBottom: Int
        var tabStops: Set<Int>
    }
}
