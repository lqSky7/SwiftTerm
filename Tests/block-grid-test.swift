import Foundation

/// Guards the thing Warp actually seals: a grid with a start and a finish.
///
/// The lifecycle is not decoration. It is what makes "a `D` with no `C` before it is not a finish"
/// true by construction instead of by a guard someone has to remember to write, and it is what lets a
/// renderer cache a finished grid's rows and never revisit them.
@main
enum BlockGridTest {
    static func main() {
        let harness = Harness("block-grid-test")

        lifecycle(harness)
        height(harness)
        text(harness)

        harness.finish()
    }

    private static func lifecycle(_ harness: Harness) {
        let grid = BlockGrid(size: TerminalSize(columns: 20, rows: 4))
        harness.equal(grid.isStarted, false, "a fresh grid has not started")
        harness.equal(grid.isFinished, false, "and has not finished")
        harness.equal(grid.startedAt, nil, "with no start time")

        let start = Date(timeIntervalSince1970: 100)
        harness.equal(grid.start(at: start), true, "starting it works once")
        harness.equal(grid.isStarted, true, "and it counts as started")
        harness.equal(grid.startedAt, start, "recording when")
        harness.equal(grid.start(at: Date()), false, "and a second start is refused")

        // A grid that never started cannot finish. This is the `D`-with-no-`C` bug from
        // `learnings.md`, expressed as a property of the type rather than as a conditional.
        let unstarted = BlockGrid(size: TerminalSize.fallback)
        harness.equal(unstarted.finish(at: Date()), false, "a grid that never started cannot finish")
        harness.equal(unstarted.isFinished, false, "so it is still not finished")

        let end = Date(timeIntervalSince1970: 103)
        harness.equal(grid.finish(at: end), true, "finishing a started grid works once")
        harness.equal(grid.isFinished, true, "and it is sealed")
        harness.equal(grid.finishedAt, end, "recording when")
        harness.equal(grid.finish(at: Date()), false, "and finishing twice is refused")
    }

    private static func height(_ harness: Harness) {
        let live = BlockGrid(size: TerminalSize(columns: 20, rows: 4))
        live.start(at: Date())
        harness.equal(live.lineCount, 1, "an empty live grid is one line tall — the cursor's")

        live.grid.write("one\r\ntwo")
        harness.equal(live.lineCount, 2, "content is counted")

        live.grid.write("\r\n")
        harness.equal(live.lineCount, 3, "and a trailing newline leaves the cursor on its own line")

        // The screen always has `rows` rows, so trailing blanks are not content: a block that claimed
        // them would reserve the bottom of the window for nothing.
        live.finish(at: Date())
        harness.equal(live.lineCount, 2, "a sealed grid stops at its content")

        let empty = BlockGrid(size: TerminalSize(columns: 20, rows: 4))
        empty.start(at: Date())
        empty.finish(at: Date())
        harness.equal(empty.lineCount, 0, "a command that printed nothing owns no lines")
    }

    private static func text(_ harness: Harness) {
        let grid = BlockGrid(size: TerminalSize(columns: 20, rows: 4))
        grid.start(at: Date())
        grid.grid.write("alpha\r\nbeta\r\n")
        harness.equal(grid.text, "alpha\nbeta", "a live grid copies its content, not its cursor line")

        grid.finish(at: Date())
        harness.equal(grid.text, "alpha\nbeta", "and sealing does not change what it says")

        // A block's own history is what the clipboard should see, not just what fits on screen.
        let long = BlockGrid(size: TerminalSize(columns: 20, rows: 2))
        long.start(at: Date())
        long.grid.write("first\r\nsecond\r\nthird\r\nfourth")
        harness.equal(long.grid.historyLineCount, 2, "lines past the screen went into its own history")
        harness.expect(long.text.hasPrefix("first\nsecond"), "which the copy still reaches")
    }
}
