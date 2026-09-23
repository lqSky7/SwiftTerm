import Foundation

/// Something the parser learned that is not a grid mutation. The session turns these into
/// window titles, block boundaries and notifications; the grid never sees them.
enum TerminalEvent: Hashable, Sendable {
    case titleChanged(String)
    case workingDirectoryChanged(String)
    /// The shell's own `PATH`, reported from its prompt hook.
    ///
    /// A separate event from the working directory rather than a bundle: the two are reported by the same hook but
    /// mean different things, and a session that could not tell them apart could not be tested for either.
    case searchPathChanged(String)
    case bell
    case notification(title: String, body: String)
    case clipboardWrite(String)
    case shellIntegration(ShellIntegrationEvent)
    /// The command line the shell is about to run, reported on swiftTerm's own marker.
    ///
    /// The grid cannot give this up: the prompt and the command are one drawn line, and splitting
    /// them would mean guessing where the user's prompt ends. Only the shell knows.
    case commandSubmitted(String)
    /// The screen was erased on the **primary** screen, which is what `clear` sends.
    ///
    /// A grid can only empty its own cells; what `clear` means in a terminal made of blocks is that the blocks that
    /// were on that screen are *gone* rather than scrolled away, and only the session can do that.
    case displayCleared
}
