import Foundation

/// One grid inside a block, and the lifecycle Warp gives it.
///
/// This is `crates/warp_terminal/src/model/blockgrid.rs` reduced to what it actually is: a grid, a
/// start, a finish, and the memoisation that becomes legal once it is finished. Warp's `GridHandler`
/// underneath it is not ported — `TerminalGrid` already is that, and re-translating an emulator this
/// project has into a worse one would be work for nothing.
///
/// The lifecycle is the point. A block's prompt-and-command grid finishes when the command is
/// submitted; its output grid finishes when the command reports an exit code. After that the grid is
/// immutable, which is what lets a renderer cache its rows and never think about them again.
final class BlockGrid {
    /// A single command's own history. Smaller than a session-wide scrollback on purpose: the
    /// block cap is what bounds the list, and this bounds one runaway command inside it.
    static let defaultScrollbackLimit = 1_000

    let grid: TerminalGrid

    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    var isStarted: Bool { startedAt != nil }
    var isFinished: Bool { finishedAt != nil }

    init(size: TerminalSize, scrollbackLimit: Int = BlockGrid.defaultScrollbackLimit) {
        self.grid = TerminalGrid(size: size, scrollbackLimit: scrollbackLimit)
    }

    /// Only the first start counts. Warp treats a finished grid as immutable, so a later cycle
    /// cannot reopen one — the block's *next* grid is the one that starts.
    @discardableResult
    func start(at time: Date) -> Bool {
        guard !isStarted else { return false }
        startedAt = time
        return true
    }

    /// A grid that never started cannot finish. That is the whole guard: a shell reporting an exit
    /// status for something that was never a command — the rc files, at the first prompt — has no
    /// output grid to seal, so the `D`-with-no-`C` bug is now unrepresentable rather than rejected.
    @discardableResult
    func finish(at time: Date) -> Bool {
        guard isStarted, !isFinished else { return false }
        finishedAt = time
        return true
    }

    /// How many lines this grid contributes to the document.
    ///
    /// A finished grid is exactly as tall as its content. A live one is one line taller than its
    /// content when the cursor sits past the last thing written, because that is where the cursor is
    /// and a terminal shows the cursor's line. The screen always has `rows` rows, so trailing blanks
    /// are never content — a block that claimed them would reserve the bottom of the window for
    /// nothing.
    var lineCount: Int {
        let content = grid.contentLineCount
        return isFinished ? content : max(grid.cursorLine + 1, content)
    }

    func line(at index: Int) -> TerminalLine? { grid.line(at: index) }

    /// The grid's lines as one string, for the clipboard.
    ///
    /// Bounded by content rather than by `lineCount`: a live grid is a line taller than its content
    /// because that is where the cursor is, and nobody wants that blank line on the pasteboard.
    var text: String {
        (0..<grid.contentLineCount)
            .compactMap { grid.line(at: $0)?.string() }
            .joined(separator: "\n")
    }
}
