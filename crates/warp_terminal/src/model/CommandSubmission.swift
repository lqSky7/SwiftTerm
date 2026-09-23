import Foundation

/// What the pty receives when the editor submits a command.
///
/// Warp's `clear_line_editor_and_write_to_pty` (`app/src/terminal/view.rs:9964`) is three bytes of
/// protocol, and every one of them is load-bearing:
///
/// - **A leading space.** Ctrl-U deletes everything *before* the cursor; on an empty line editor
///   there is nothing to delete and the shell rings the bell. The space guarantees there is.
/// - **Ctrl-K clears forward, Ctrl-U clears backward.** Together they empty the shell's line editor of
///   whatever it last held, so the buffer that follows is the whole line rather than a suffix of one.
/// - **Not Ctrl-C.** It would clear the line too, and cancel whatever is running.
///
/// The shell's line editor is never disabled — it is wiped, every time, immediately before the buffer
/// arrives. That is the whole trick, and it is why nothing has to be kept in sync with it.
enum CommandSubmission {
    /// Space, Ctrl-K, Ctrl-U.
    static let clearLineEditor: [UInt8] = [0x20, 0x0B, 0x15]

    /// What a bare `↩` sends, for a test to pin down and for a caller that has nothing to submit.
    static let empty: [UInt8] = clearLineEditor + [0x0D]

    static func bytes(for buffer: String) -> [UInt8] {
        clearLineEditor + Array(escaped(buffer).utf8) + [0x0D]
    }

    /// The buffer, with every newline turned into a line continuation.
    ///
    /// A multi-line buffer sent raw would be executed one line at a time: the shell's line editor
    /// reads until an unescaped newline, so the first `\n` would run everything before it. Escaping
    /// each one as `\` + newline makes the editor treat the whole buffer as one continued line, and
    /// the shell's lexer joins it back into one command — which is what `⇧↩` promised.
    ///
    /// Trailing newlines are dropped first, or the last thing the shell would see is a dangling
    /// continuation with nothing after it.
    ///
    /// Known limitation: this is textual, so a newline inside a quoted string or a here-document body
    /// is escaped too. Both are rare enough in a one-line prompt to be worth the simplicity, and both
    /// are visibly wrong rather than silently wrong when they happen.
    ///
    /// Line endings are normalised first, because a text view is not the only thing that can hand a
    /// buffer over. Note the order: `\r\n` is a *single* `Character` in Swift — one extended grapheme
    /// cluster — so stripping trailing newlines before normalising would not match the CRLF case at
    /// all, and the buffer would end with a continuation and nothing after it.
    static func escaped(_ buffer: String) -> String {
        var text = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return text.replacingOccurrences(of: "\n", with: "\\\n")
    }
}
