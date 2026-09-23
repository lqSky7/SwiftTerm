import Foundation

/// The prompt and the command line, and the point the prompt ends at.
///
/// Warp keeps two grids here (`app/src/terminal/model/header_grid.rs`): a `prompt_grid` and a
/// `prompt_and_command_grid`, so the shell's prompt can be drawn independently of the user's command.
/// That split is exactly what `OSC 133 ; B` exists to describe, and Phase 2 kept the marker while
/// having nothing to do with it.
///
/// What the split is *for* is knowing where the prompt ends — one point — so this holds the one grid
/// the shell writes into plus that point, rather than a second grid nothing writes to yet. Phase 3
/// is where it earns its keep: the command stops being echoed by the shell and starts being drawn by
/// an editor, and the prompt has to be laid out around it.
final class HeaderGrid {
    /// Where the prompt ended: a line in the grid's own sequence and a column on it. That is where
    /// the user's command begins.
    struct PromptEnd: Equatable {
        var line: Int
        var column: Int
    }

    /// The line the shell drew, prompt and command together. The shell writes into this until the
    /// command is submitted; after that the block's output grid takes over.
    let promptAndCommandGrid: BlockGrid

    private(set) var promptEnd: PromptEnd?

    init(size: TerminalSize) {
        self.promptAndCommandGrid = BlockGrid(size: size)
    }

    /// `133 ; B`: the shell has finished drawing its prompt, so the cursor is where a command would
    /// begin. Read from the cursor rather than measured, because the shell is the only thing that
    /// knows how wide its own prompt was.
    func markPromptEnd(line: Int, column: Int) {
        promptEnd = PromptEnd(line: line, column: column)
    }

    /// The command as the shell drew it, for a shell that reports none over `OSC 9281` — bash and
    /// fish do not have `preexec`'s argument in the same shape, and a session with no integration
    /// reports nothing at all.
    ///
    /// Degraded, never absent: the last non-blank line of the prompt region. It is the whole line,
    /// prompt included, because cutting at `promptEnd.column` would be wrong the moment a prompt
    /// contains a double-width character — a column is not an index into a string.
    var commandText: String? {
        for index in stride(from: promptAndCommandGrid.lineCount - 1, through: 0, by: -1) {
            let text = promptAndCommandGrid.line(at: index)?.string() ?? ""
            if !text.isEmpty { return text }
        }
        return nil
    }
}
