import Foundation

/// Guards the point the prompt ends at and the command line as drawn.
///
/// `133 ; B` was kept through Phase 2 with nothing to do, on the grounds that the split between the
/// prompt and the command line is what a later phase needs. This is that phase's groundwork, so the
/// marker now records something rather than being swallowed.
@main
enum HeaderGridTest {
    static func main() {
        let harness = Harness("header-grid-test")

        promptEnd(harness)
        drawnCommand(harness)

        harness.finish()
    }

    private static func promptEnd(_ harness: Harness) {
        let header = HeaderGrid(size: TerminalSize(columns: 30, rows: 6))
        harness.equal(header.promptEnd, nil, "a prompt has no end until the shell says so")

        header.promptAndCommandGrid.start(at: Date())
        header.promptAndCommandGrid.grid.write("~/src % ")
        // `133 ; B` arrives once the shell has drawn its prompt, so the cursor is where a command
        // would begin — the only thing that knows how wide the shell's own prompt was.
        header.markPromptEnd(line: 0, column: 8)
        harness.equal(
            header.promptEnd, HeaderGrid.PromptEnd(line: 0, column: 8), "the cursor is recorded")
    }

    private static func drawnCommand(_ harness: Harness) {
        let header = HeaderGrid(size: TerminalSize(columns: 30, rows: 6))
        harness.equal(header.commandText, nil, "an empty prompt grid has no command")

        header.promptAndCommandGrid.start(at: Date())
        header.promptAndCommandGrid.grid.write("~/src % ls -la")
        harness.equal(
            header.commandText, "~/src % ls -la",
            "the drawn command is the whole line: a column is not an index into a string, and a "
                + "double-width prompt would make it one")

        // A shell that echoed a newline before the command: the command is on the last line.
        header.promptAndCommandGrid.grid.write("\r\nsecond line")
        harness.equal(header.commandText, "second line", "the last non-blank line wins")

        // A trailing newline leaves the cursor on a blank line, which is not the command.
        header.promptAndCommandGrid.grid.write("\r\n")
        harness.equal(header.commandText, "second line", "and blank lines are skipped")
    }
}
