import Foundation

/// Guards the emulator's own behaviour: wrapping, scrolling, the scrollback, wide glyphs,
/// editing, resize and the alternate screen. Every one of these is something a full-screen
/// program depends on and that a wrong off-by-one silently breaks.
@main
enum TerminalGridTest {
    static func main() {
        let harness = Harness("terminal-grid-test")

        wrapping(harness)
        scrollingAndHistory(harness)
        scrollReach(harness)
        lineIdentity(harness)
        eraseAndEdit(harness)
        wideGlyphs(harness)
        combiningMarks(harness)
        scrollRegion(harness)
        resize(harness)
        reflow(harness)
        alternateScreen(harness)
        cursorAndTabs(harness)

        harness.finish()
    }

    /// Everything the grid holds as *logical* text: rows joined, with a newline only where a row is not
    /// a continuation of the one before it.
    ///
    /// Logical rather than row-by-row, because a reflow is allowed to change where the rows break and is
    /// not allowed to change the characters. Comparing row text would fail every time the wrapping
    /// changed, which is precisely when the invariant matters most.
    private static func content(_ grid: TerminalGrid) -> String {
        var result = ""
        for index in 0..<grid.totalLineCount {
            guard let line = grid.line(at: index) else { continue }
            if index > 0, grid.line(at: index - 1)?.isWrapped != true { result += "\n" }
            // A wrapped row's trailing blanks are load-bearing: the wrap happened at the last column, so
            // a space there is a space the user typed. Trimming it loses a character at every wrap.
            result += line.string(trimmingTrailingBlanks: !line.isWrapped)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A row of exactly `columns` cells, built by hand so a logical line can be assembled without a grid.
    private static func row(_ text: String, columns: Int, wrapped: Bool = false) -> TerminalLine {
        var cells = text.map { TerminalCell(text: String($0)) }
        while cells.count < columns { cells.append(.blank) }
        return TerminalLine(cells: cells, isWrapped: wrapped)
    }

    /// The reflow, which is the part of a terminal that is easiest to get wrong and hardest to notice:
    /// before this existed, narrowing a window truncated every long line for good and widening filled
    /// the space with blanks. `TerminalLine.isWrapped` was built for it in Phase 1 and never used.
    private static func reflow(_ harness: Harness) {
        // The flag a reflow joins on has to actually be written.
        let wrapping = TerminalGrid(size: TerminalSize(columns: 5, rows: 4))
        wrapping.write("abcdefghij")
        harness.equal(wrapping.rowText(0), "abcde", "a full row is full")
        harness.equal(wrapping.rowText(1), "fghij", "and the overflow continues it")
        harness.equal(wrapping.line(at: 0)?.isWrapped, true, "the row that wrapped says so")
        harness.equal(wrapping.line(at: 1)?.isWrapped, false, "and the row it wrapped into does not")

        // Narrowing re-wraps, and widening gives the line back.
        let grid = TerminalGrid(size: TerminalSize(columns: 20, rows: 6))
        grid.write("hello wonderful world")
        harness.equal(grid.rowText(0), "hello wonderful worl", "20 columns holds 20 characters")
        harness.equal(grid.rowText(1), "d", "and the rest continues on the next row")

        grid.resize(columns: 10, rows: 6)
        harness.equal(grid.rowText(0), "hello wond", "narrowing re-wraps")
        harness.equal(grid.rowText(1), "erful worl", "across as many rows as it takes")
        harness.equal(grid.rowText(2), "d", "and no further")

        grid.resize(columns: 20, rows: 6)
        harness.equal(grid.rowText(0), "hello wonderful worl", "widening gives the line back")
        harness.equal(grid.rowText(1), "d", "exactly where it was")

        // The invariant: the same characters at every width. This is the one that would have caught the
        // truncation, because a truncated line fails it and nothing else here would.
        let survivor = TerminalGrid(size: TerminalSize(columns: 30, rows: 5))
        survivor.write("one two three four five six seven eight nine ten eleven")
        let before = content(survivor)
        for columns in [12, 40, 7, 30, 3] {
            survivor.resize(columns: columns, rows: 5)
            harness.equal(
                content(survivor), before,
                "every character survives a resize to \(columns) columns")
        }

        // A blank row is one blank row, not a screenful — which is what trimming trailing blanks per
        // logical line is for.
        let blank = TerminalGrid(size: TerminalSize(columns: 20, rows: 4))
        blank.write("a\r\n\r\nb")
        harness.equal(blank.contentLineCount, 3, "three rows of content to start with")
        blank.resize(columns: 8, rows: 4)
        harness.equal(blank.contentLineCount, 3, "and still three after narrowing")
        harness.equal(blank.line(at: 0)?.string(), "a", "the first is where it was")
        harness.equal(blank.line(at: 1)?.string(), "", "the blank row stayed blank")
        harness.equal(blank.line(at: 2)?.string(), "b", "and the last one too")

        // The cursor lands on the same character, not merely on some row.
        let cursor = TerminalGrid(size: TerminalSize(columns: 10, rows: 4))
        cursor.write("abcdefghijklmno")
        harness.equal(cursor.cursorLine, 1, "the cursor is on the second row of its logical line")
        harness.equal(cursor.cursorColumn, 5, "one past the last character")
        cursor.resize(columns: 5, rows: 4)
        harness.equal(cursor.cursorLine, 3, "after re-wrapping it is three rows down")
        harness.equal(cursor.cursorColumn, 0, "and at the start of the row, which is the same character")
        harness.equal(cursor.line(at: 2)?.string(), "klmno", "with the content above it intact")

        // A logical line that straddles the boundary between history and the screen is re-wrapped as
        // one line, not torn in half — which is why the reflow takes the whole sequence at once.
        let straddling = TerminalGrid.reflow(
            scrollback: [row("abcdef", columns: 6, wrapped: true)],
            screen: [row("ghijkl", columns: 6), row("", columns: 6), row("", columns: 6)],
            columns: 12, rows: 3, cursor: (0, 0))
        harness.equal(
            straddling.screen[0].string(), "abcdefghijkl",
            "a logical line split across the boundary is rejoined")
        harness.equal(straddling.screen.count, 3, "and the screen is still its own height")

        let torn = TerminalGrid.reflow(
            scrollback: [row("abcdef", columns: 6, wrapped: true)],
            screen: [row("ghijkl", columns: 6), row("", columns: 6), row("", columns: 6)],
            columns: 6, rows: 3, cursor: (0, 0))
        harness.equal(torn.screen[0].string(), "abcdef", "at six columns it takes two rows again")
        harness.equal(torn.screen[1].string(), "ghijkl", "with the second half on the second")
        // The screen's trailing blank rows are padding, not content. Counting them as content would
        // inflate the result by a row per blank and push the beginning of the line into history — which
        // is a reflow that looks like it worked while quietly losing output.
        harness.equal(
            torn.scrollback.count, 0,
            "and the padding above them does not push content into history")

        // The alternate screen has no history by definition, so a resize there drops what falls off
        // rather than filing it.
        let alternate = TerminalGrid(size: TerminalSize(columns: 10, rows: 3))
        alternate.setAlternateScreen(true)
        alternate.write("abcdefghijklmno")
        alternate.resize(columns: 4, rows: 3)
        harness.equal(alternate.historyLineCount, 0, "the alternate screen still has no history")
        harness.equal(alternate.screen.count, 3, "and is still its own height")

        // Nothing to re-wrap is not a crash.
        let empty = TerminalGrid.reflow(
            scrollback: [], screen: [], columns: 10, rows: 2, cursor: (0, 0))
        harness.equal(empty.screen.count, 2, "an empty sequence re-wraps to a blank screen")
        harness.equal(empty.scrollback.count, 0, "with no history")
    }

    private static func wrapping(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 10, rows: 3))
        grid.write("abcdefghijklm")
        harness.equal(grid.rowText(0), "abcdefghij", "a full row stays on its row")
        harness.equal(grid.rowText(1), "klm", "the overflow wraps")
        harness.equal(grid.cursorRow, 1, "the cursor followed the wrap")
        harness.equal(grid.cursorColumn, 3, "the cursor sits after the last character")

        // The pending wrap is what stops a newline from producing an empty line: the cursor is
        // parked on the last column, not past it.
        grid.carriageReturn()
        grid.lineFeed()
        grid.write("x")
        harness.equal(grid.rowText(2), "x", "a newline after an exact fit does not skip a row")
    }

    private static func scrollingAndHistory(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 5, rows: 2))
        grid.write("a\r\nb\r\nc")
        harness.equal(grid.historyLineCount, 1, "the line pushed off the top went to history")
        harness.equal(grid.rowText(0), "b", "the screen scrolled up")
        harness.equal(grid.rowText(1), "c", "the newest line is on the last row")
        harness.equal(grid.line(at: 0)?.string(), "a", "history keeps the displaced line")

        grid.scrollUp(1)
        harness.equal(grid.historyLineCount, 2, "a full-height scroll always files to history")

        let region = TerminalGrid(size: TerminalSize(columns: 5, rows: 3))
        region.write("1\r\n2\r\n3")
        region.setScrollRegion(top: 0, bottom: 1)
        region.setCursorPosition(row: 2, column: 1)
        region.lineFeed()
        harness.equal(region.rowText(0), "2", "a scroll inside the region moved the region up")
        harness.equal(region.rowText(2), "3", "the line below the region did not move")
        harness.equal(region.historyLineCount, 0, "a partial scroll never touches history")
    }

    /// What a scrolled viewport asks for. The renderer draws one row above the top so a part-scrolled
    /// viewport can show the row sliding in, which at the very top of history is index -1.
    private static func scrollReach(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 20, rows: 6))
        for index in 1...40 { grid.write("line \(index)\r\n") }

        let history = grid.historyLineCount
        harness.equal(history, 35, "every line past the screen went to history")

        let maximumOffset = history
        let bottomLine = grid.totalLineCount - 1 - maximumOffset
        let topLine = bottomLine - (grid.size.rows - 1)
        harness.equal(topLine, 0, "scrolling all the way back reaches the first line")
        harness.equal(
            grid.line(at: topLine)?.string(), "line 1",
            "and that line is the oldest one written")

        harness.equal(grid.line(at: -1), nil, "there is no row above the oldest line")
        harness.equal(
            grid.line(at: grid.totalLineCount), nil, "and none past the newest")
    }

    /// Blocks name lines by index, so the sequence has to behave: it only ever grows, a resize moves
    /// lines between the screen and the scrollback without renumbering them, and anything that does
    /// drop a line off the front says so.
    /// The grid's own line identity. Phase 2 leaned on this to renumber blocks when the scrollback
    /// dropped lines; nothing does now, because each block owns its grids — but a resize that
    /// silently dropped a line would still lose output, so the invariants stay.
    private static func lineIdentity(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 10, rows: 6))
        grid.write("a\r\nb\r\nc")
        harness.equal(grid.cursorLine, 2, "the cursor names the line it is on")
        harness.equal(grid.contentLineCount, 3, "and trailing blank screen rows are not content")

        let before = grid.contentLineCount
        grid.resize(columns: 10, rows: 3)
        // Every *content* line survives. The screen's trailing blank rows are padding and are dropped,
        // which is why this counts content rather than rows — the old assertion compared row counts and
        // would have passed while the content was being truncated.
        harness.equal(grid.contentLineCount, before, "shrinking keeps every line of content")
        harness.equal(grid.line(at: 0)?.string(), "a", "the first line is still the first line")
        grid.resize(columns: 10, rows: 6)
        harness.equal(grid.contentLineCount, before, "nor does growing back")
        harness.equal(grid.line(at: 0)?.string(), "a", "and it is still the first line")

        let capped = TerminalGrid(size: TerminalSize(columns: 5, rows: 2), scrollbackLimit: 3)
        for index in 1...20 { capped.write("\(index)\r\n") }
        harness.equal(capped.historyLineCount, 3, "the scrollback is capped")
        harness.equal(
            capped.line(at: 0)?.string(), "17",
            "so the oldest line still held is the one the cap says it is")
    }

    private static func eraseAndEdit(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 6, rows: 3))
        grid.write("abcdef")
        grid.setCursorColumn(3)
        grid.eraseInLine(mode: 0)
        harness.equal(grid.rowText(0), "abc", "erase to end of line")

        grid.setCursorPosition(row: 2, column: 1)
        grid.write("ghijkl")
        grid.setCursorColumn(2)
        grid.eraseInLine(mode: 1)
        harness.equal(grid.rowText(1), "   jkl", "erase to start of line takes the cursor cell too")

        grid.eraseInDisplay(mode: 2)
        harness.equal(grid.screenText, ["", "", ""], "erase in display clears the screen")
        harness.equal(grid.cursorRow, 1, "erasing does not move the cursor")

        let edit = TerminalGrid(size: TerminalSize(columns: 6, rows: 2))
        edit.write("abcdef")
        edit.setCursorColumn(2)
        edit.deleteCharacters(2)
        harness.equal(edit.rowText(0), "abef", "delete characters pulls the row left")
        edit.setCursorColumn(2)
        edit.insertCharacters(2)
        harness.equal(edit.rowText(0), "ab  ef", "insert characters pushes the row right")

        let lines = TerminalGrid(size: TerminalSize(columns: 6, rows: 3))
        lines.write("one\r\ntwo\r\nthree")
        lines.setCursorPosition(row: 2, column: 1)
        lines.deleteLines(1)
        harness.equal(lines.screenText, ["one", "three", ""], "delete lines pulls the region up")
    }

    private static func wideGlyphs(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 5, rows: 1))
        grid.write("日本")
        harness.equal(grid.rowText(0), "日本", "two ideographs fit on one row")
        harness.equal(grid.cursorColumn, 4, "each ideograph advanced two columns")

        let cells = grid.line(at: grid.historyLineCount)?.cells ?? []
        harness.equal(cells[0].width, 2, "the left half owns the glyph")
        harness.equal(cells[1].isContinuation, true, "the right half is a continuation")
        harness.equal(cells[2].text, "本", "the second glyph starts at column two")

        // Overwriting either half has to blank the other, or the row keeps a stray half-glyph.
        grid.setCursorColumn(1)
        grid.write("x")
        harness.equal(grid.rowText(0), " x本", "overwriting the right half blanked the left")

        let edge = TerminalGrid(size: TerminalSize(columns: 5, rows: 2))
        edge.setCursorColumn(4)
        edge.write("日")
        harness.equal(edge.rowText(0), "", "a wide glyph cannot straddle the margin")
        harness.equal(edge.rowText(1), "日", "so it wraps whole to the next row")
    }

    private static func combiningMarks(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 4, rows: 1))
        grid.write("e\u{0301}")
        harness.equal(grid.rowText(0), "é", "a combining mark folds into the letter before it")
        harness.equal(grid.cursorColumn, 1, "the mark consumed no column of its own")

        grid.setCursorColumn(0)
        grid.write("\u{0301}")
        harness.equal(grid.rowText(0), "é", "a mark at column zero has nothing to fold into and is dropped")
    }

    private static func scrollRegion(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 4, rows: 4))
        grid.write("top")
        grid.setCursorPosition(row: 2, column: 1)
        grid.write("mid")
        grid.setCursorPosition(row: 3, column: 1)
        grid.write("low")
        grid.setCursorPosition(row: 4, column: 1)
        grid.write("bot")

        grid.setScrollRegion(top: 1, bottom: 2)
        grid.setCursorPosition(row: 3, column: 1)
        grid.lineFeed()
        harness.equal(grid.screenText, ["top", "low", "", "bot"], "only the region scrolled")
    }

    private static func resize(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 4, rows: 3))
        grid.write("aaa\r\nbbb\r\nccc")
        grid.resize(columns: 4, rows: 5)
        harness.equal(grid.size.rows, 5, "the grid grew")
        // The content sits at the top and the new rows go *below* it, which is where a terminal puts
        // them. Padding above the content is counted as content by every height calculation downstream,
        // so it draws a gap over the prompt — and it is what the old resize did.
        harness.equal(grid.rowText(2), "ccc", "the content stayed where it was")
        harness.equal(grid.rowText(4), "", "and the new rows are below it")
        harness.equal(grid.contentLineCount, 3, "which are not content")
        harness.equal(grid.historyLineCount, 0, "growing pulls nothing out of history it does not need")

        grid.resize(columns: 4, rows: 2)
        harness.equal(grid.size.rows, 2, "the grid shrank")
        // One line fell off the top, and it is the only one that went to history: the blank rows were
        // padding, not lines, so nothing else was displaced.
        harness.equal(grid.historyLineCount, 1, "only the line that fell off the top went to history")
        harness.equal(grid.totalLineCount, 3, "so the sequence is content and nothing else")
        harness.equal(grid.rowText(1), "ccc", "the cursor line is still on screen")

        grid.resize(columns: 8, rows: 2)
        harness.equal(grid.line(at: grid.historyLineCount)?.columnCount, 8, "rows widened to the new width")
        harness.equal(grid.cursorColumn, 3, "the cursor column survived the widen")
    }

    private static func alternateScreen(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 8, rows: 2))
        grid.write("primary\r\ntext")
        harness.equal(grid.screenText, ["primary", "text"], "the primary screen holds the text")
        grid.setAlternateScreen(true)
        harness.equal(grid.screenText, ["", ""], "the alternate screen starts blank")
        harness.equal(grid.historyLineCount, 0, "the alternate screen has no history")
        harness.equal(grid.isAlternateScreen, true, "the flag follows the switch")

        grid.write("full")
        harness.equal(grid.rowText(0), "full", "the alternate screen takes output")
        grid.setAlternateScreen(false)
        harness.equal(grid.rowText(0), "primary", "leaving the alternate screen restored the primary")
        harness.equal(grid.rowText(1), "text", "the second row came back too")
        harness.equal(grid.isAlternateScreen, false, "the flag came back too")
    }

    private static func cursorAndTabs(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 20, rows: 2))
        grid.horizontalTab()
        harness.equal(grid.cursorColumn, 8, "the first tab stop is column eight")
        grid.horizontalTab()
        harness.equal(grid.cursorColumn, 16, "the second is column sixteen")
        grid.horizontalTabBack()
        harness.equal(grid.cursorColumn, 8, "tab back returns to the previous stop")

        grid.setCursorPosition(row: 2, column: 3)
        grid.saveCursor()
        grid.setCursorPosition(row: 1, column: 1)
        grid.restoreCursor()
        harness.equal(grid.cursorRow, 1, "restore brought the row back")
        harness.equal(grid.cursorColumn, 2, "restore brought the column back")

        grid.setCursorPosition(row: 1, column: 1)
        grid.moveCursor(rowDelta: -5, columnDelta: -5)
        harness.equal(grid.cursorRow, 0, "the cursor clamps at the top")
        harness.equal(grid.cursorColumn, 0, "the cursor clamps at the left")
    }
}
