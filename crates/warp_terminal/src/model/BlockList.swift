import Foundation

/// The ordered blocks and the one still being written to.
///
/// Pure. Every environmental fact — the time, the size, the exit code — arrives as a parameter, so
/// this can be exercised with no shell and no clock at all. The session is what reads those from the
/// world.
///
/// There is no `shift(by:)` any more. It existed only because a block named a range of lines in one
/// shared sequence, so trimming the scrollback renumbered every block at once; each block owns its
/// own grids now, so there is nothing to renumber and nothing that can renumber it wrongly.
struct BlockList {
    /// How many blocks are kept.
    ///
    /// The bound moved here from the scrollback. One grid used to cap the whole sequence; now every
    /// block has its own history, so the *list* is what has to be bounded, and a hundred blocks of a
    /// thousand lines each is the worst case rather than the expected one. Warp evicts old blocks for
    /// the same reason.
    static let defaultMaximumBlockCount = 100

    private(set) var blocks: [Block] = []
    private(set) var size: TerminalSize

    private var nextIdentifier: UInt64 = 1
    private let maximumBlockCount: Int

    init(size: TerminalSize, maximumBlockCount: Int = BlockList.defaultMaximumBlockCount) {
        self.size = size
        self.maximumBlockCount = max(1, maximumBlockCount)
    }

    var activeBlock: Block? { blocks.last }
    var isEmpty: Bool { blocks.isEmpty }

    /// A prompt is about to be drawn. `OSC 133 ; A`.
    ///
    /// A new block every time, which is what Warp does: the shell decides when a block begins, and
    /// the previous one is done with whether or not it ever ran a command. Nothing is reused — a
    /// block that never saw a `C` has an unstarted output grid, so its body is just its prompt line
    /// and it renders as the run of lines a terminal would have shown anyway, with no header to claim
    /// otherwise.
    @discardableResult
    mutating func begin(at time: Date, workingDirectory: String?) -> Block {
        let block = Block(
            id: BlockID(rawValue: nextIdentifier), size: size, workingDirectory: workingDirectory)
        nextIdentifier += 1
        block.headerGrid.promptAndCommandGrid.start(at: time)
        blocks.append(block)
        evictOldest()
        return block
    }

    /// `133 ; A`: the shell is about to draw a prompt.
    ///
    /// **Takes over the active block when nothing has been drawn into it yet.** A session starts with one block so
    /// that a shell without integration still has somewhere to write; a shell *with* integration then sends `133;A`
    /// for its very first prompt, and beginning a second block there left the first one orphaned — an empty block
    /// with a header and no content, at the top of every new tab.
    ///
    /// The working directory is taken from the new prompt rather than kept: the first `133;A` is the first news the
    /// session has of where the shell actually is, and the initial block was created guessing.
    mutating func beginPrompt(at time: Date, workingDirectory: String?) {
        if let active = activeBlock, active.isUntouched {
            active.workingDirectory = workingDirectory
            return
        }
        _ = begin(at: time, workingDirectory: workingDirectory)
    }

    /// `133 ; B`: the shell has finished drawing its prompt, so the cursor is where a command begins.
    mutating func markPromptEnd(line: Int, column: Int) {
        activeBlock?.headerGrid.markPromptEnd(line: line, column: column)
    }

    /// Whether a command is running: submitted and not yet finished.
    ///
    /// The one state in which the shell's cursor is unambiguously **not** the cursor the user wants to see — a
    /// command that is running is not waiting for input, and the cursor the shell left at the end of its output is
    /// noise. Read off the grids rather than tracked separately, so it cannot disagree with them.
    var isRunningCommand: Bool {
        guard let block = activeBlock else { return false }
        return block.isSubmitted && !block.isSealed
    }

    /// The command was submitted. `OSC 133 ; C`.
    mutating func markCommandSubmitted(command: String?, at time: Date) {
        guard let block = activeBlock, !block.isSubmitted else { return }
        block.headerGrid.promptAndCommandGrid.finish(at: time)
        block.outputGrid.start(at: time)
        block.command = command
    }

    /// The command finished. `OSC 133 ; D`.
    ///
    /// Only a grid that started can finish, so a `D` with no `C` before it is ignored without a guard
    /// anyone has to remember to write: the shell reporting the exit status of its own rc files has no
    /// output grid to seal. That was a conditional in Phase 2 and it is a property of the type now.
    mutating func finish(exitCode: Int, at time: Date) {
        guard let block = activeBlock, block.outputGrid.finish(at: time) else { return }
        block.exitCode = exitCode
    }

    /// The shell changed directory. `OSC 7`.
    mutating func setWorkingDirectory(_ path: String) {
        activeBlock?.workingDirectory = path
    }

    /// The window changed shape, so every block's grids reflow.
    mutating func resize(columns: Int, rows: Int) {
        size = TerminalSize(
            columns: columns, rows: rows, cellWidth: size.cellWidth, cellHeight: size.cellHeight)
        for block in blocks { block.resize(columns: columns, rows: rows) }
    }

    /// The pixel geometry the pty is told about. Kept apart from `resize` because a font change moves
    /// these without changing the cell count.
    mutating func setCellGeometry(width: Int, height: Int) {
        size.cellWidth = width
        size.cellHeight = height
        for block in blocks {
            for blockGrid in block.grids {
                blockGrid.grid.setCellGeometry(width: width, height: height)
            }
        }
    }

    /// Clearing history keeps the block the user is in and drops the rest, which is what a person
    /// asking for a cleared terminal expects to be left with.
    mutating func clearHistory() {
        guard let active = blocks.last else { return }
        for block in blocks {
            for blockGrid in block.grids { blockGrid.grid.clearScrollback() }
        }
        blocks = [active]
    }

    private mutating func evictOldest() {
        let excess = blocks.count - maximumBlockCount
        guard excess > 0 else { return }
        blocks.removeFirst(excess)
    }
}
