import Foundation

/// Guards the block lifecycle and what each block owns.
///
/// There are no line ranges left to check, which is the point of the phase: a block's extent is its
/// own grid's length, so the off-by-one that a shared line sequence invited cannot be written down.
@main
enum BlockListTest {
    static func main() {
        let harness = Harness("block-list-test")

        promptCycle(harness)
        theFirstPromptTakesOverTheInitialBlock(harness)
        foldingABlock(harness)
        aBlockWithNoSubmissionNeverGrowsAHeader(harness)
        outcomes(harness)
        grids(harness)
        eviction(harness)
        clearingHistory(harness)
        resizing(harness)

        harness.finish()
    }

    private static func promptCycle(_ harness: Harness) {
        var list = BlockList(size: TerminalSize.fallback)
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1002.5)

        list.begin(at: start, workingDirectory: "/Users/example")
        harness.equal(list.blocks.count, 1, "a prompt starts a block")
        harness.equal(list.blocks[0].isSubmitted, false, "which is not yet submitted")
        harness.equal(list.blocks[0].isSealed, false, "and not yet sealed")
        harness.equal(list.blocks[0].workingDirectory, "/Users/example", "carrying the directory")

        // zsh reports the rc files' exit status at the first prompt, before anything has run. Sealing
        // on the strength of it would close the block about to hold the first real command.
        list.finish(exitCode: 0, at: start)
        harness.equal(list.blocks[0].isSealed, false, "a finish with nothing submitted is not a finish")
        harness.equal(list.blocks[0].exitCode, nil, "and records no exit code")

        list.markCommandSubmitted(command: "ls -la", at: start)
        harness.equal(list.blocks[0].isSubmitted, true, "a submission submits the block")
        harness.equal(list.blocks[0].command, "ls -la", "the shell's report is kept verbatim")
        harness.equal(list.blocks[0].isSealed, false, "but it is not yet finished")
        harness.equal(list.blocks[0].startedAt, start, "and it knows when it started")

        list.finish(exitCode: 0, at: end)
        harness.equal(list.blocks[0].exitCode, 0, "the exit code is kept")
        harness.equal(list.blocks[0].isSealed, true, "and the block is sealed")
        harness.equal(list.blocks[0].duration, 2.5, "and knows how long it took")

        list.begin(at: end, workingDirectory: "/Users/example")
        harness.equal(list.blocks.count, 2, "the next prompt starts the next block")
        harness.equal(list.blocks[1].isSubmitted, false, "which has its own, fresh grids")
        harness.equal(list.blocks[1].id, list.activeBlock?.id, "and is the active one")
    }

    /// A new session must not show an empty block.
    ///
    /// A session begins with one block so a shell without integration has somewhere to write, and a shell *with*
    /// integration then sends `133 ; A` for its first prompt. Beginning a second block there left the first one on
    /// screen with a header and nothing else — the empty block at the top of every new tab.
    private static func theFirstPromptTakesOverTheInitialBlock(_ harness: Harness) {
        var list = BlockList(size: TerminalSize(columns: 80, rows: 24))
        _ = list.begin(at: Date(), workingDirectory: "/home/someone")
        harness.equal(list.blocks.count, 1, "a session starts with one block")

        list.beginPrompt(at: Date(), workingDirectory: "/home/someone/project")
        harness.equal(
            list.blocks.count, 1, "the first prompt takes it over rather than beginning a second")
        harness.equal(
            list.blocks[0].workingDirectory, "/home/someone/project",
            "and the directory the shell reports replaces the guess the session started with")

        // Once that prompt has been drawn the block is in use, so the *next* prompt is a new block.
        list.markPromptEnd(line: 0, column: 12)
        harness.expect(!list.blocks[0].isUntouched, "a block with a prompt in it is no longer untouched")
        list.beginPrompt(at: Date(), workingDirectory: "/home/someone/project")
        harness.equal(list.blocks.count, 2, "so the next prompt begins a second block")

        // And a submitted block is never taken over, however the session got here.
        list.markCommandSubmitted(command: "ls", at: Date())
        list.beginPrompt(at: Date(), workingDirectory: "/home/someone/project")
        harness.equal(list.blocks.count, 3, "and a submitted block is never reused")
    }

    /// Folding a block, and the two numbers that decide when it is allowed.
    ///
    /// The layout reads `visibleLineCount` rather than `lineCount`, which is what makes folding a change to the
    /// *document* — the blocks below move up — rather than a clip at draw time. That is the load-bearing part, so it
    /// is the part asserted here.
    private static func foldingABlock(_ harness: Harness) {
        var list = BlockList(size: TerminalSize(columns: 80, rows: 24))
        _ = list.begin(at: Date(), workingDirectory: "/tmp")
        let block = list.blocks[0]

        // A block being typed has nothing to hide, and folding the line somebody is typing into would lose it.
        harness.expect(!block.isCollapsible, "a block that has not run anything cannot be folded")
        block.toggleCollapsed()
        harness.expect(!block.isCollapsed, "and folding it does nothing")

        list.markPromptEnd(line: 0, column: 4)
        list.markCommandSubmitted(command: "ls", at: Date())
        harness.expect(!block.isCollapsible, "nor can a short one — there is nothing to hide")
        harness.equal(block.visibleLineCount, block.lineCount, "so it shows everything it has")

        // A block with output past the threshold can be folded, and folded it shows only the first few lines.
        for _ in 0..<(Block.collapsibleLineCount + 5) { block.outputGrid.grid.lineFeed() }
        harness.expect(block.isCollapsible, "a block past the threshold can be folded")
        harness.expect(
            block.lineCount >= Block.collapsibleLineCount, "which is measured in the block's own lines")
        block.toggleCollapsed()
        harness.expect(block.isCollapsed, "folding it folds it")
        harness.equal(
            block.visibleLineCount, Block.collapsedLineCount,
            "and it then shows exactly the collapsed number of lines, not more")

        // The visible grids are what the renderer draws, and they add up to the visible count.
        let drawn = block.visibleGrids.reduce(0) { $0 + $1.lines }
        harness.equal(drawn, block.visibleLineCount, "the grids drawn add up to the lines shown")

        // Expanding is always allowed, and gives everything back.
        block.toggleCollapsed()
        harness.expect(!block.isCollapsed, "and folding it again unfolds it")
        harness.equal(block.visibleLineCount, block.lineCount, "with every line back")
    }

    private static func aBlockWithNoSubmissionNeverGrowsAHeader(_ harness: Harness) {
        var list = BlockList(size: TerminalSize.fallback)
        list.begin(at: Date(), workingDirectory: nil)
        // The shell printed something without ever reporting a submission — no integration, or the
        // rc files running before the first prompt.
        list.begin(at: Date(), workingDirectory: nil)
        harness.equal(list.blocks.count, 2, "the next prompt still starts a new block")
        harness.equal(list.blocks[0].isSubmitted, false, "and the block that never ran stays unsubmitted")
        harness.equal(list.blocks[0].isSealed, false, "so it never grows a header")
        harness.equal(list.blocks[0].lineCount, 1, "its body is just its own prompt line")
    }

    private static func outcomes(_ harness: Harness) {
        var list = BlockList(size: TerminalSize.fallback)
        list.begin(at: Date(), workingDirectory: nil)
        harness.equal(list.blocks[0].didSucceed, nil, "a block still being typed has no outcome")

        list.markCommandSubmitted(command: "sleep 1", at: Date())
        harness.equal(list.blocks[0].didSucceed, nil, "nor does a running one")
        harness.equal(list.blocks[0].duration, nil, "and it has no duration yet")

        list.finish(exitCode: 130, at: Date())
        harness.equal(list.blocks[0].didSucceed, false, "a signalled command did not succeed")

        var ok = BlockList(size: TerminalSize.fallback)
        ok.begin(at: Date(), workingDirectory: nil)
        ok.markCommandSubmitted(command: "true", at: Date())
        ok.finish(exitCode: 0, at: Date())
        harness.equal(ok.blocks[0].didSucceed, true, "a clean exit did")
    }

    private static func grids(_ harness: Harness) {
        var list = BlockList(size: TerminalSize(columns: 30, rows: 5))
        list.begin(at: Date(), workingDirectory: nil)
        let first = list.blocks[0]
        list.markCommandSubmitted(command: "echo hi", at: Date())
        list.finish(exitCode: 0, at: Date())
        list.begin(at: Date(), workingDirectory: nil)
        let second = list.blocks[1]

        harness.equal(first.contentGrids.count, 2, "a submitted block draws two grids")
        harness.expect(
            first.contentGrids[0] === first.headerGrid.promptAndCommandGrid,
            "the command it ran")
        harness.expect(first.contentGrids[1] === first.outputGrid, "and then its output")
        harness.equal(second.contentGrids.count, 1, "an unsubmitted one draws one")
        harness.expect(
            second.contentGrids[0] === second.headerGrid.promptAndCommandGrid, "just its prompt")
        harness.equal(
            first.lineCount,
            first.headerGrid.promptAndCommandGrid.lineCount + first.outputGrid.lineCount,
            "and a block's height is every grid it draws")
        harness.expect(first.outputGrid.grid !== second.outputGrid.grid, "no two blocks share a grid")
        harness.expect(
            first.headerGrid.promptAndCommandGrid.grid !== first.outputGrid.grid,
            "nor do a block's own two grids")
        harness.equal(first.grids.count, 2, "a block owns exactly two grids")
        harness.equal(first.isAlternateScreen, false, "and no block is on the alternate screen yet")
    }

    private static func eviction(_ harness: Harness) {
        var list = BlockList(size: TerminalSize.fallback, maximumBlockCount: 3)
        for _ in 0..<5 { list.begin(at: Date(), workingDirectory: nil) }
        harness.equal(list.blocks.count, 3, "the list is bounded by the block cap")
        harness.equal(list.activeBlock?.id, list.blocks[2].id, "and the newest block is still active")

        // The bound used to be the scrollback, which was one grid's worth of lines for every block.
        // Now each block has its own, so the list is what has to be capped.
        var single = BlockList(size: TerminalSize.fallback, maximumBlockCount: 1)
        single.begin(at: Date(), workingDirectory: nil)
        single.begin(at: Date(), workingDirectory: nil)
        harness.equal(single.blocks.count, 1, "a cap of one keeps one block")
    }

    private static func clearingHistory(_ harness: Harness) {
        var list = BlockList(size: TerminalSize.fallback)
        list.begin(at: Date(), workingDirectory: nil)
        list.markCommandSubmitted(command: "one", at: Date())
        list.finish(exitCode: 0, at: Date())
        list.begin(at: Date(), workingDirectory: nil)
        harness.equal(list.blocks.count, 2, "two blocks before the clear")

        list.clearHistory()
        harness.equal(list.blocks.count, 1, "clearing keeps the block the user is in")
        harness.equal(list.blocks[0].isSubmitted, false, "and it is the live one that survives")
    }

    private static func resizing(_ harness: Harness) {
        var list = BlockList(size: TerminalSize(columns: 30, rows: 5))
        list.begin(at: Date(), workingDirectory: nil)
        list.markCommandSubmitted(command: "one", at: Date())
        list.finish(exitCode: 0, at: Date())
        list.begin(at: Date(), workingDirectory: nil)

        list.resize(columns: 40, rows: 8)
        harness.equal(list.size.columns, 40, "the list tracks the new size")
        harness.equal(list.size.rows, 8, "in both directions")
        for block in list.blocks {
            for blockGrid in block.grids {
                harness.equal(blockGrid.grid.size.columns, 40, "every block's every grid reflowed")
            }
        }
        // Finished means the shell will not write to it again, not that its bytes are frozen: a
        // wrapped line still has to re-wrap when the window changes shape.
        harness.equal(list.blocks[0].isSealed, true, "and reflowing does not unseal anything")
    }
}
