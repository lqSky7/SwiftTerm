import Foundation

/// A prompt-lifecycle hook reported by the shell over `OSC 133`, the protocol iTerm2, VS Code
/// and Warp's shell scripts all speak. Phase 1 only reports these; Phase 2 turns each pair of
/// `commandExecuted` and `commandFinished` into a block.
enum ShellIntegrationEvent: Hashable, Sendable {
    /// `OSC 133 ; A` — the shell is about to draw a prompt.
    case promptStart
    /// `OSC 133 ; B` — the prompt has been drawn and the shell is reading a command. The cursor is
    /// where the command begins, which is the point `HeaderGrid` records.
    case commandStart
    /// `OSC 133 ; C` — a command was accepted and its output is about to start.
    case commandExecuted
    /// `OSC 133 ; D ; exit` — the command finished. The exit code is what the block header shows.
    case commandFinished(exitCode: Int)
}
