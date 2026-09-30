import Foundation

@main
enum TUICompatibilityTest {
    static func main() {
        let harness = Harness("tui-compatibility-test")
        glyphs(harness)
        resize(harness)
        cursor(harness)
        editing(harness)
        queries(harness)
        input(harness)
        paste(harness)
        harness.finish()
    }

    private static func parser(columns: Int = 12, rows: Int = 4) -> VTParser {
        VTParser(grid: TerminalGrid(size: TerminalSize(columns: columns, rows: rows)))
    }

    private static func glyphs(_ harness: Harness) {
        for glyph in ["e\u{301}", "界\u{301}", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇮🇳", "♥️", "1️⃣"] {
            let width = glyph == "e\u{301}" ? 1 : 2
            let bytes = Array((glyph + "X").utf8)
            for split in 0...bytes.count {
                let vt = parser()
                vt.feed(Array(bytes.prefix(split)))
                vt.feed(Array(bytes.dropFirst(split)))
                harness.equal(vt.grid.screen[0].cells[0].text, glyph, "one grapheme at split \(split)")
                harness.equal(vt.grid.screen[0].cells[width].text, "X", "next column at split \(split)")
                harness.equal(vt.grid.cursorColumn, width + 1, "cursor at split \(split)")
                if width == 2 {
                    harness.expect(vt.grid.screen[0].cells[1].isContinuation, "a wide glyph retains its tail")
                }
            }
        }
        let margin = parser(columns: 4)
        margin.feed("abc♥️X")
        harness.equal(margin.grid.rowText(0), "abc", "emoji promotion wraps the whole glyph")
        harness.equal(margin.grid.rowText(1), "♥️X", "emoji and following text survive promotion at the margin")
    }

    private static func resize(_ harness: Harness) {
        let vt = parser(columns: 12)
        vt.feed("primary\u{1B}[?1049h\u{1B}[1;1Habcdefghijk\u{1B}[2;1Hrow-two\u{1B}[3;1Hrow-three")
        vt.grid.resize(columns: 6, rows: 3)
        harness.equal(vt.grid.screenText, ["abcdef", "row-tw", "row-th"], "fullscreen rows stay at their coordinates")
        harness.equal(vt.grid.historyLineCount, 0, "fullscreen resize never creates scrollback")
        harness.equal(vt.grid.cursorRow, 2, "fullscreen cursor stays on its row")
        vt.grid.resize(columns: 14, rows: 5)
        harness.equal(vt.grid.rowText(1), "row-tw", "growing keeps rows in place")
        vt.feed("\u{1B}[?1049l")
        harness.equal(vt.grid.rowText(0), "primary", "primary output is restored after resize")
        harness.equal(vt.grid.screen.count, 5, "restored screen has the new height")
        harness.expect(vt.grid.screen.allSatisfy { $0.cells.count == 14 }, "restored rows have the new width")
    }

    private static func cursor(_ harness: Harness) {
        let vt = parser(columns: 6, rows: 6)
        vt.feed("\u{1B}[2;5r\u{1B}[?6h")
        harness.equal(vt.grid.cursorRow, 1, "origin mode homes inside the scroll region")
        vt.feed("\u{1B}[99A")
        harness.equal(vt.grid.cursorRow, 1, "relative movement respects the top margin")
        vt.feed("\u{1B}[99B")
        harness.equal(vt.grid.cursorRow, 4, "relative movement respects the bottom margin")
        vt.feed("\u{1B}[2d")
        harness.equal(vt.grid.cursorRow, 2, "VPA is relative to the origin")
        vt.feed("\u{1B}[?6l")
        harness.equal(vt.grid.cursorRow, 0, "leaving origin mode homes the cursor")
        vt.feed("\u{1B}[?7labcdefXY")
        harness.equal(vt.grid.rowText(0), "abcdeY", "wrap-off continues replacing the margin cell")
        vt.feed("\u{1B}[?7h\u{1B}[H123456\u{1B}7\u{1B}[H\u{1B}[?1000h\u{1B}[?2004h\u{1B}8Z")
        harness.equal(vt.grid.rowText(1), "Z", "cursor restore preserves delayed wrap")
        harness.equal(vt.grid.modes.mouseTracking, .buttonPress, "cursor restore leaves mouse reporting intact")
        harness.expect(vt.grid.modes.bracketedPaste, "cursor restore leaves bracketed paste intact")
        let screens = parser()
        screens.feed("\u{1B}[2;3H\u{1B}7\u{1B}[?1049h\u{1B}[4;6H\u{1B}7\u{1B}[?1049l\u{1B}8")
        harness.equal(screens.grid.cursorRow, 1, "alternate cursor saves do not replace the primary save")
        harness.equal(screens.grid.cursorColumn, 2, "primary saved column survives the alternate screen")
        let movement = parser()
        movement.feed("\u{1B}[2;3H\u{1B}[2a\u{1B}[2e")
        harness.equal(movement.grid.cursorRow, 3, "VPR moves down by the requested count")
        harness.equal(movement.grid.cursorColumn, 4, "HPR moves horizontally without changing rows")
        movement.feed("\u{1B}[0A\u{1B}[0D")
        harness.equal(movement.grid.cursorRow, 2, "zero cursor count defaults to one")
        harness.equal(movement.grid.cursorColumn, 3, "zero horizontal count defaults to one")
        let unknown = parser()
        unknown.feed("\u{1B}[2;3H\u{1B}7\u{1B}[4;6H\u{1B}[?u\u{1B}[>4;2m")
        harness.equal(unknown.grid.cursorRow, 3, "unsupported Kitty queries do not restore the cursor")
        harness.equal(unknown.grid.cursorColumn, 5, "unsupported private commands leave the cursor alone")
        harness.equal(unknown.grid.pen.attributes, CellAttributes(), "modifyOtherKeys is not interpreted as SGR")
    }

    private static func editing(_ harness: Harness) {
        for operation in ["\u{1B}[K", "\u{1B}[1K", "\u{1B}[X", "\u{1B}[P", "\u{1B}[@"] {
            let vt = parser(columns: 6)
            vt.feed("A界B\u{1B}[1;3H" + operation)
            for (column, cell) in vt.grid.screen[0].cells.enumerated() {
                if cell.isContinuation {
                    harness.expect(column > 0 && vt.grid.screen[0].cells[column - 1].width == 2,
                                   "\(operation) leaves no orphan tail")
                } else if cell.width == 2 {
                    harness.expect(column < 5 && vt.grid.screen[0].cells[column + 1].isContinuation,
                                   "\(operation) leaves no orphan wide glyph")
                }
            }
        }
        let vt = parser(columns: 4)
        vt.feed("abcd\u{1B}[KZ")
        harness.equal(vt.grid.rowText(0), "abcZ", "erase cancels delayed wrap")
        harness.equal(vt.grid.cursorRow, 0, "printing after erase stays on the cursor row")
    }

    private static func queries(_ harness: Harness) {
        let vt = parser()
        vt.grid.setCellGeometry(width: 9, height: 18)
        var replies: [String] = []
        vt.onReply = { replies.append($0) }
        vt.feed("\u{1B}[18t\u{1B}[16t\u{1B}[14t\u{1B}[3;5H\u{1B}[?6n")
        harness.equal(replies, ["\u{1B}[8;4;12t", "\u{1B}[6;18;9t", "\u{1B}[4;72;108t", "\u{1B}[?3;5R"],
                      "geometry and private cursor reports use the live grid")
    }

    private static func input(_ harness: Harness) {
        harness.equal(TerminalInput.cursor("A", application: true), Array("\u{1B}OA".utf8), "application arrow")
        harness.equal(TerminalInput.cursor("A", application: false), Array("\u{1B}[A".utf8), "normal arrow")
        harness.equal(TerminalInput.cursor("D", application: true, modifier: 5), Array("\u{1B}[1;5D".utf8), "Ctrl arrow")
        harness.equal(TerminalInput.cursor("C", application: false, modifier: 3), Array("\u{1B}[1;3C".utf8), "Alt arrow")
        harness.equal(TerminalInput.tilde(5, modifier: 2), Array("\u{1B}[5;2~".utf8), "Shift Page Up")
        harness.equal(TerminalInput.tilde(3), Array("\u{1B}[3~".utf8), "Delete")
    }

    private static func paste(_ harness: Harness) {
        for newline in ["\n", "\r\n", "\r"] {
            let text = "first" + newline + "  second" + newline
            harness.equal(TerminalInput.paste(text, bracketed: false), Array("first\r  second\r".utf8),
                          "raw paste preserves lines, indentation and the trailing newline")
            harness.equal(TerminalInput.paste(text, bracketed: true),
                          Array("\u{1B}[200~first\r  second\r\u{1B}[201~".utf8),
                          "bracketed paste uses the same payload with one wrapper")
        }
        let source = "if ready {\n\tprint(\"👩🏽‍💻\")\n}\n\n"
        let pasted = TerminalInput.paste(source, bracketed: false)
        harness.expect(!pasted.contains(0x0A), "nano never receives Ctrl-J from a pasted newline")
        harness.equal(String(bytes: pasted, encoding: .utf8), source.replacingOccurrences(of: "\n", with: "\r"),
                      "pasting code adds no continuation backslashes and removes no blank lines")
    }
}
