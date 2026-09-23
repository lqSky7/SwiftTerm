import Foundation

/// Pins the bytes a submitted command becomes.
///
/// Three of them are protocol rather than text — a space, Ctrl-K, Ctrl-U — and they are exactly the
/// kind of thing that gets "tidied up" by someone who does not know why the space is there. The space
/// exists so Ctrl-U has something to delete; without it the shell rings the bell on every command.
@main
enum EditorSubmitTest {
    static func main() {
        let harness = Harness("editor-submit-test")

        prefix(harness)
        singleLine(harness)
        multiLine(harness)

        harness.finish()
    }

    private static func prefix(_ harness: Harness) {
        harness.equal(CommandSubmission.clearLineEditor, [0x20, 0x0B, 0x15], "space, Ctrl-K, Ctrl-U")
        harness.equal(
            Array(CommandSubmission.bytes(for: "ls").prefix(3)), [0x20, 0x0B, 0x15],
            "every submission starts by clearing the shell's line editor")
        harness.equal(
            CommandSubmission.bytes(for: "ls").last, UInt8(0x0D), "and ends with a return")
        harness.equal(
            CommandSubmission.empty, [0x20, 0x0B, 0x15, 0x0D], "a bare return clears and returns")
    }

    private static func singleLine(_ harness: Harness) {
        harness.equal(CommandSubmission.escaped("ls -la"), "ls -la", "a single line is passed through")
        let payload = Array(CommandSubmission.bytes(for: "git status").dropFirst(3).dropLast())
        harness.equal(
            String(bytes: payload, encoding: .utf8) ?? "", "git status",
            "and arrives verbatim between the prefix and the return")
    }

    private static func multiLine(_ harness: Harness) {
        // A raw newline would be *executed*: the shell's line editor reads until an unescaped one, so
        // the first line would run and everything after it would be a second command.
        harness.equal(
            CommandSubmission.escaped("echo a\necho b"), "echo a\\\necho b",
            "a newline becomes a line continuation")
        harness.equal(
            CommandSubmission.escaped("ls\n"), "ls", "a trailing newline is dropped, not continued")
        harness.equal(CommandSubmission.escaped("ls\n\n\n"), "ls", "however many there are")
        harness.equal(CommandSubmission.escaped("ls\r\n"), "ls", "including a carriage return")
        harness.equal(CommandSubmission.escaped("\n"), "", "a buffer of nothing but newlines is nothing")
        harness.equal(
            CommandSubmission.escaped("for f in *; do\n  echo $f\ndone"),
            "for f in *; do\\\n  echo $f\\\ndone",
            "and every newline in a multi-line buffer is escaped, not just the first")
    }
}
