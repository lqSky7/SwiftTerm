import Foundation

/// Guards the escape-sequence layer: the dispatch tables, the string states, SGR's two spellings
/// of an extended colour, and the byte-level buffering that lets a read end anywhere.
@main
enum VTParserTest {
    static func main() {
        let harness = Harness("vt-parser-test")

        cursorAndErase(harness)
        sgr(harness)
        modes(harness)
        escapeSequences(harness)
        charsets(harness)
        stringStates(harness)
        queries(harness)
        encoding(harness)

        harness.finish()
    }

    private static func makeParser(columns: Int = 10, rows: Int = 4) -> VTParser {
        VTParser(grid: TerminalGrid(size: TerminalSize(columns: columns, rows: rows)))
    }

    private static func cursorAndErase(_ harness: Harness) {
        let parser = makeParser()
        parser.feed("\u{1B}[2;3H")
        harness.equal(parser.grid.cursorRow, 1, "CUP row is one-based")
        harness.equal(parser.grid.cursorColumn, 2, "CUP column is one-based")

        parser.feed("\u{1B}[H")
        harness.equal(parser.grid.cursorRow, 0, "a bare CUP means home")

        parser.feed("hello")
        parser.feed("\u{1B}[3D")
        harness.equal(parser.grid.cursorColumn, 2, "CUB moves back")
        parser.feed("\u{1B}[2C")
        harness.equal(parser.grid.cursorColumn, 4, "CUF moves forward")

        parser.feed("\u{1B}[2K")
        harness.equal(parser.grid.rowText(0), "", "EL 2 clears the whole line")
        harness.equal(parser.grid.cursorColumn, 4, "erasing does not move the cursor")

        parser.feed("\u{1B}[5;7f")
        harness.equal(parser.grid.cursorRow, 3, "HVP is CUP's synonym, clamped to the last row")
        harness.equal(parser.grid.cursorColumn, 6, "HVP takes a column too")

        let region = makeParser()
        region.feed("\u{1B}[2;3r")
        harness.equal(region.grid.scrollTop, 1, "DECSTBM top is one-based")
        harness.equal(region.grid.scrollBottom, 2, "DECSTBM bottom is one-based")
        harness.equal(region.grid.cursorRow, 0, "DECSTBM homes the cursor")
    }

    private static func sgr(_ harness: Harness) {
        let parser = makeParser()
        parser.feed("\u{1B}[1;31m")
        var attributes = parser.grid.pen.attributes
        harness.expect(attributes.flags.contains(.bold), "SGR 1 sets bold")
        harness.equal(attributes.foreground, .indexed(1), "SGR 31 is the first ANSI slot")

        parser.feed("\u{1B}[4:3m")
        attributes = parser.grid.pen.attributes
        harness.expect(attributes.flags.contains(.curlyUnderline), "SGR 4:3 is a curly underline")
        harness.expect(!attributes.flags.contains(.underline), "the plain underline bit is cleared")

        parser.feed("\u{1B}[0m")
        harness.equal(parser.grid.pen.attributes, CellAttributes(), "SGR 0 resets everything")

        parser.feed("\u{1B}[38;5;208m")
        harness.equal(parser.grid.pen.attributes.foreground, .indexed(208), "38;5;n is a palette index")

        parser.feed("\u{1B}[48;2;10;20;30m")
        harness.equal(
            parser.grid.pen.attributes.background, .rgb(red: 10, green: 20, blue: 30),
            "48;2;r;g;b is a direct colour")

        parser.feed("\u{1B}[38:2::40:50:60m")
        harness.equal(
            parser.grid.pen.attributes.foreground, .rgb(red: 40, green: 50, blue: 60),
            "the colon spelling skips the empty colour-space slot")

        parser.feed("\u{1B}[58;5;9m")
        harness.equal(parser.grid.pen.attributes.underlineColor, .indexed(9), "58 sets the underline colour")

        parser.feed("\u{1B}[59m")
        harness.equal(parser.grid.pen.attributes.underlineColor, nil, "59 clears the underline colour")

        // The argument list must not leak back in as codes of its own: 208 would read as bright red
        // and 5 as blink if the parser forgot to skip what it consumed.
        let leakage = makeParser()
        leakage.feed("\u{1B}[38;5;208mX")
        harness.expect(!leakage.grid.pen.attributes.flags.contains(.blink), "38;5;n consumed its arguments")
        harness.equal(leakage.grid.rowText(0), "X", "the character after an extended colour printed")

        let bright = makeParser()
        bright.feed("\u{1B}[91;104m")
        harness.equal(bright.grid.pen.attributes.foreground, .indexed(9), "SGR 91 is bright red")
        harness.equal(bright.grid.pen.attributes.background, .indexed(12), "SGR 104 is bright blue")
    }

    private static func modes(_ harness: Harness) {
        let parser = makeParser()
        parser.feed("\u{1B}[?25l")
        harness.equal(parser.grid.modes.cursorVisible, false, "DECTCEM hides the cursor")
        parser.feed("\u{1B}[?25h")
        harness.equal(parser.grid.modes.cursorVisible, true, "and shows it again")

        parser.feed("\u{1B}[?7l")
        harness.equal(parser.grid.modes.automaticWrap, false, "DECAWM off")
        parser.feed("abcdefghijklm")
        harness.equal(parser.grid.cursorColumn, 9, "with autowrap off the cursor parks at the margin")
        harness.equal(parser.grid.rowText(1), "", "and nothing wraps to the next row")

        parser.feed("\u{1B}[?7h")
        parser.feed("\u{1B}[4h")
        harness.equal(parser.grid.modes.insert, true, "IRM is a plain, non-private mode")
        parser.feed("\u{1B}[4l")

        parser.feed("\u{1B}[?1002h\u{1B}[?1006h")
        harness.equal(parser.grid.modes.mouseTracking, .buttonAndDrag, "1002 asks for drag reporting")
        harness.equal(parser.grid.modes.mouseSGR, true, "1006 switches to the SGR encoding")

        let alternate = makeParser()
        alternate.feed("primary")
        alternate.feed("\u{1B}[?1049h")
        harness.equal(alternate.grid.isAlternateScreen, true, "1049 enters the alternate screen")
        harness.equal(alternate.grid.rowText(0), "", "and clears it")
        alternate.feed("\u{1B}[?1049l")
        harness.equal(alternate.grid.isAlternateScreen, false, "1049 leaves it")
        harness.equal(alternate.grid.rowText(0), "primary", "restoring the primary screen")

        let saved = makeParser()
        saved.feed("\u{1B}[3;4H\u{1B}[?1048h\u{1B}[1;1H\u{1B}[?1048l")
        harness.equal(saved.grid.cursorRow, 2, "1048 saves the cursor")
        harness.equal(saved.grid.cursorColumn, 3, "and restores it")
    }

    private static func escapeSequences(_ harness: Harness) {
        let parser = makeParser()
        parser.feed("\u{1B}[2;2H")
        parser.feed("\u{1B}7")
        parser.feed("\u{1B}[1;1H")
        parser.feed("\u{1B}8")
        harness.equal(parser.grid.cursorRow, 1, "ESC 7 / ESC 8 save and restore the cursor")

        parser.feed("\u{1B}[1;1Habc")
        parser.feed("\u{1B}D")
        harness.equal(parser.grid.cursorRow, 1, "ESC D is an index")

        parser.feed("\u{1B}[1;1H")
        parser.feed("\u{1B}M")
        harness.equal(parser.grid.cursorRow, 0, "ESC M is a reverse index")

        parser.feed("\u{1B}[2;1H\u{1B}E")
        harness.equal(parser.grid.cursorColumn, 0, "ESC E is a next-line")

        let alignment = makeParser(columns: 4, rows: 2)
        alignment.feed("\u{1B}#8")
        harness.equal(alignment.grid.screenText, ["EEEE", "EEEE"], "ESC # 8 is the alignment test")

        let reset = makeParser()
        reset.feed("text\u{1B}c")
        harness.equal(reset.grid.screenText, ["", "", "", ""], "ESC c is a full reset")
        harness.equal(reset.grid.pen.attributes, CellAttributes(), "which clears the pen too")
    }

    private static func charsets(_ harness: Harness) {
        let parser = makeParser()
        parser.feed("\u{1B}(0")
        parser.feed("q")
        harness.equal(parser.grid.rowText(0), "─", "DEC special graphics remaps q to a horizontal rule")

        parser.feed("\u{1B}(B")
        parser.feed("q")
        harness.equal(parser.grid.rowText(0), "─q", "designating ASCII restores the letter")

        let shifted = makeParser()
        shifted.feed("\u{1B})0\u{0E}")
        shifted.feed("x")
        harness.equal(shifted.grid.rowText(0), "│", "SO selects G1, which holds the graphics set")
        shifted.feed("\u{0F}")
        shifted.feed("x")
        harness.equal(shifted.grid.rowText(0), "│x", "SI selects G0 again")
    }

    private static func stringStates(_ harness: Harness) {
        let parser = makeParser()
        var events: [TerminalEvent] = []
        parser.onEvent = { events.append($0) }

        parser.feed("\u{1B}]0;window title\u{07}")
        parser.feed("\u{1B}]2;second title\u{1B}\\")
        harness.equal(
            events, [.titleChanged("window title"), .titleChanged("second title")],
            "OSC is terminated by BEL and by ST alike")

        parser.feed("\u{1B}]7;file://localhost/Users/example\u{07}")
        harness.equal(events.last, .workingDirectoryChanged("/Users/example"), "OSC 7 carries the cwd")

        parser.feed("\u{1B}]9;build finished\u{07}")
        harness.equal(
            events.last, .notification(title: "Terminal", body: "build finished"),
            "OSC 9 is a notification")

        parser.feed("\u{1B}]777;notify;Deploy;done in 4s\u{07}")
        harness.equal(
            events.last, .notification(title: "Deploy", body: "done in 4s"),
            "OSC 777 carries a title and a body")

        // An escape inside a string abandons it, and what follows is an ordinary sequence.
        parser.feed("\u{1B}]0;abandoned\u{1B}[1mX")
        harness.equal(events.last, .notification(title: "Deploy", body: "done in 4s"), "no title was reported")
        harness.expect(parser.grid.pen.attributes.flags.contains(.bold), "the escape that broke it still ran")
        harness.equal(parser.grid.rowText(0), "X", "and the string's contents never printed")

        // **`clear` empties the screen and the blocks go with it** — but only on the primary screen.
        parser.feed("\u{1B}[2J")
        harness.equal(
            events.last, .displayCleared,
            "erasing the display reports that the session should drop the blocks above")
        parser.feed("\u{1B}[3J")
        harness.equal(events.last, .displayCleared, "and so does erasing the saved lines")

        // A full-screen program erases the display on every repaint. Reporting that would be a terminal that forgot
        // its scrollback whenever a TUI blinked, so the alternate screen is left alone.
        parser.feed("\u{1B}[?1049h")
        let before = events.count
        parser.feed("\u{1B}[2J")
        harness.equal(events.count, before, "an erase on the alternate screen reports nothing")
        parser.feed("\u{1B}[?1049l")

        parser.feed("\u{1B}]9282;/opt/homebrew/bin:/usr/bin\u{07}")
        harness.equal(
            events.last, .searchPathChanged("/opt/homebrew/bin:/usr/bin"),
            "OSC 9282 carries the shell's own PATH, which is what completion and resolution are against")

        parser.feed("\u{1B}]9281;git status --short\u{07}")
        harness.equal(
            events.last, .commandSubmitted("git status --short"),
            "swiftTerm's own marker carries the command line")

        // An OSC string may contain newlines, so a heredoc arrives intact rather than truncated at
        // the first line break.
        parser.feed("\u{1B}]9281;for i in 1 2 3; do\n  echo $i\ndone\u{07}")
        harness.equal(
            events.last, .commandSubmitted("for i in 1 2 3; do\n  echo $i\ndone"),
            "a multi-line command survives whole")

        parser.feed("\u{1B}]9281;\u{07}")
        harness.equal(
            events.last, .commandSubmitted(""),
            "an empty command is reported as empty, not dropped")

        let dcs = makeParser()
        var dcsEvents: [TerminalEvent] = []
        dcs.onEvent = { dcsEvents.append($0) }
        dcs.feed("\u{1B}P1;2;3+payload\u{1B}\\after")
        harness.equal(dcs.grid.rowText(0), "after", "a DCS is consumed, not printed")
        harness.equal(dcsEvents.count, 0, "and reports nothing yet")
    }

    private static func queries(_ harness: Harness) {
        let parser = makeParser()
        var replies: [String] = []
        parser.onReply = { replies.append($0) }

        parser.feed("\u{1B}[c")
        harness.equal(replies, ["\u{1B}[?1;2c"], "a primary DA gets a VT100 answer")

        parser.feed("\u{1B}[>c")
        harness.equal(replies.last, "\u{1B}[>0;0;0c", "a secondary DA gets a secondary answer")

        parser.feed("\u{1B}[3;4H\u{1B}[6n")
        harness.equal(replies.last, "\u{1B}[3;4R", "a cursor position report is one-based")

        parser.feed("\u{1B}[2;5H\u{1B}[6n")
        harness.equal(replies.last, "\u{1B}[2;5R", "and follows the cursor")
    }

    private static func encoding(_ harness: Harness) {
        let parser = makeParser()
        parser.feed([0xE6])
        harness.equal(parser.grid.rowText(0), "", "a lone lead byte prints nothing yet")
        parser.feed([0x97, 0xA5])
        harness.equal(parser.grid.rowText(0), "日", "the split codepoint completes on the next read")

        let twoByte = makeParser()
        twoByte.feed([0xC3])
        twoByte.feed([0xA9])
        harness.equal(twoByte.grid.rowText(0), "é", "a two-byte codepoint splits too")

        let abandoned = makeParser()
        abandoned.feed([0xE6])
        abandoned.feed("\u{1B}[1m")
        harness.equal(abandoned.grid.rowText(0), "", "an escape abandons a partial codepoint")
        harness.expect(abandoned.grid.pen.attributes.flags.contains(.bold), "and the escape still runs")

        let mixed = makeParser(columns: 6, rows: 2)
        mixed.feed("ab\r\n")
        mixed.feed("\u{1B}[31m")
        mixed.feed("red")
        harness.equal(mixed.grid.rowText(1), "red", "text after a line feed lands on the next row")
        harness.equal(mixed.grid.pen.attributes.foreground, .indexed(1), "with the colour in force")

        let controls = makeParser()
        var events: [TerminalEvent] = []
        controls.onEvent = { events.append($0) }
        controls.feed("a\u{07}b\u{08}c")
        harness.equal(events, [.bell], "BEL is reported, not printed")
        harness.equal(controls.grid.rowText(0), "ac", "and backspace overwrote the b")
    }
}
