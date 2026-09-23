import Foundation

/// One command and its output, each in its own grid.
///
/// This is Warp's `Block` (`app/src/terminal/model/block.rs`): a `header_grid` and an `output_grid`,
/// plus the metadata the shell reported. A reference type now, because it owns grids — a value type
/// that copied them would be a lie about what sealing one means.
///
/// There is deliberately no `state` field. Whether a block is being typed, running or finished is
/// exactly whether its output grid has started and finished, so storing it as well would be a second
/// source of truth for the same fact, free to disagree with the first.
final class Block {
    let id: BlockID

    /// The prompt and the command line. The shell writes here until the command is submitted.
    let headerGrid: HeaderGrid

    /// Everything the command printed. Started at `133 ; C`, sealed at `133 ; D`.
    let outputGrid: BlockGrid

    /// The command text, as the shell reported it. Nil when the shell reported none.
    var command: String?

    var exitCode: Int?
    var workingDirectory: String?

    init(id: BlockID, size: TerminalSize, workingDirectory: String?) {
        self.id = id
        self.headerGrid = HeaderGrid(size: size)
        self.outputGrid = BlockGrid(size: size)
        self.workingDirectory = workingDirectory
    }

    var isSubmitted: Bool { outputGrid.isStarted }

    /// Whether the shell has not yet drawn anything into this block.
    ///
    /// The test is the **prompt marker** rather than a scan of the cells: a block a shell has drawn a prompt into
    /// has had `133 ; B` report where that prompt ended, and a block that has not is the one a session begins with.
    /// That block exists so a shell *without* integration still has somewhere to write — and a shell *with*
    /// integration then sends `133 ; A` for its first prompt, which used to begin a second block and leave the
    /// first on screen with nothing in it. That was the empty block at the top of every new tab.
    var isUntouched: Bool { !isSubmitted && headerGrid.promptEnd == nil }
    var isSealed: Bool { outputGrid.isFinished }

    /// Whether the block is folded down to its first few lines.
    ///
    /// A property of the block rather than a set of collapsed ids somewhere else: it has to survive the layout being
    /// rebuilt on every frame, and a separate set would be a second answer to "is this collapsed".
    var isCollapsed = false

    /// How many lines a collapsed block shows, and the shortest block that can be collapsed at all.
    ///
    /// Twenty because below that there is nothing to hide: a ten-line block collapsed to ten lines is a control
    /// that does nothing, and a menu item that does nothing is worse than one that is not there.
    static let collapsedLineCount = 10
    static let collapsibleLineCount = 20

    /// Whether this block has anything to hide.
    ///
    /// **Only a submitted block.** A block being typed has no output, and folding the line somebody is typing into
    /// is a way to lose their own text.
    var isCollapsible: Bool { isSubmitted && lineCount >= Self.collapsibleLineCount }

    /// How many of the block's lines the document shows.
    ///
    /// The layout and the renderer both read this rather than `lineCount`, which is what makes collapsing a change
    /// to the **document** rather than a clip at draw time — the blocks below it move up, which is the whole point.
    var visibleLineCount: Int {
        isCollapsed ? min(lineCount, Self.collapsedLineCount) : lineCount
    }

    /// Fold or unfold, if either would do anything. Expanding is always allowed.
    func toggleCollapsed() {
        guard isCollapsed || isCollapsible else { return }
        isCollapsed.toggle()
    }

    /// The grids the body is drawn from, each with the number of lines to draw from it.
    ///
    /// The grids themselves are never truncated — they belong to the shell and are still whole. Only the number of
    /// lines the document *shows* is, which is exactly what a collapsed block is.
    var visibleGrids: [(contentGrid: BlockGrid, lines: Int)] {
        var budget = visibleLineCount
        var visible: [(contentGrid: BlockGrid, lines: Int)] = []
        for contentGrid in contentGrids {
            guard budget > 0 else { break }
            let lines = min(budget, contentGrid.lineCount)
            budget -= lines
            visible.append((contentGrid, lines))
        }
        return visible
    }

    var startedAt: Date? { outputGrid.startedAt }
    var finishedAt: Date? { outputGrid.finishedAt }

    /// How long the command ran, once it has finished.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// Whether the command reported success. Nil while it is still running, or when no shell
    /// integration is present to report an exit code.
    var didSucceed: Bool? {
        guard isSealed, let exitCode else { return nil }
        return exitCode == 0
    }

    /// The grids the block's body is drawn from, in the order they are drawn in.
    ///
    /// An unsubmitted block is just its prompt — the command being typed. A submitted one is **the
    /// command that ran and then its output**, which is what Warp shows and what makes a block read as a
    /// command and its output rather than as a transcript. The prompt contributes the command now that
    /// the shell's own prompt is suppressed: what the echo leaves on that line *is* the command.
    var contentGrids: [BlockGrid] {
        isSubmitted
            ? [headerGrid.promptAndCommandGrid, outputGrid]
            : [headerGrid.promptAndCommandGrid]
    }

    /// How many lines the body contributes to the document: every grid it draws, in order.
    var lineCount: Int { contentGrids.reduce(0) { $0 + $1.lineCount } }

    /// Every grid this block owns. Resize and the alternate-screen check both walk this, so a block
    /// cannot end up with one grid at the new size and one at the old.
    var grids: [BlockGrid] { [headerGrid.promptAndCommandGrid, outputGrid] }

    /// Re-wraps every grid. Sealed grids are re-wrapped too: finished means the shell will never write
    /// to them again, not that their bytes are frozen.
    func resize(columns: Int, rows: Int) {
        for blockGrid in grids { blockGrid.grid.resize(columns: columns, rows: rows) }
    }

    /// A full-screen program runs in the block that started it, so the alternate screen is a
    /// property of that block's output grid rather than of the session.
    var isAlternateScreen: Bool {
        isSubmitted && outputGrid.grid.isAlternateScreen
    }
}
