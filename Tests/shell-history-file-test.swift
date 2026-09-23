import Foundation

/// Guards the reader for the shells' own history files.
///
/// **Three formats, and the detection is the part that matters.** A reader that assumed zsh's extended format would
/// return nothing for a plain zsh history and nothing for bash — and an empty history is indistinguishable from a
/// history that failed, which is the failure mode worth a harness.
@main
enum ShellHistoryFileTest {
    static func main() {
        let harness = Harness("shell-history-file-test")

        itReadsPlainHistory(harness)
        itReadsZshExtendedHistory(harness)
        itReadsFishHistory(harness)
        itDetectsRatherThanAssumes(harness)
        itUnescapesNewlines(harness)
        itKnowsWhereEachShellKeepsIt(harness)
        anAbsentFileIsEmpty(harness)

        harness.finish()
    }

    private static func itReadsPlainHistory(_ harness: Harness) {
        // bash, and zsh with `EXTENDED_HISTORY` off.
        let plain = """
            ls -la
            cd ~/Desktop

            swift build
            """
        harness.equal(
            ShellHistoryFile.commands(in: plain), ["ls -la", "cd ~/Desktop", "swift build"],
            "a plain history is one command per line, and blank lines are not commands")
    }

    private static func itReadsZshExtendedHistory(_ harness: Harness) {
        // `: <timestamp>:<duration>;<command>`, which is what `setopt extended_history` produces.
        let extended = """
            : 1700000000:0;ls -la
            : 1700000012:3;cd ~/Desktop
            : 1700000040:1;swift build
            """
        harness.equal(
            ShellHistoryFile.commands(in: extended), ["ls -la", "cd ~/Desktop", "swift build"],
            "the timestamp and duration are metadata, not part of the command")

        // A `;` inside the command belongs to the command: the separator is the *first* one, and everything before it
        // is `<timestamp>:<duration>`, which cannot contain a `;`.
        harness.equal(
            ShellHistoryFile.commands(in: ": 1:2;echo a; echo b"), ["echo a; echo b"],
            "a semicolon in the command is kept")
    }

    private static func itReadsFishHistory(_ harness: Harness) {
        let fish = """
            - cmd: ls -la
              when: 1700000000
            - cmd: cd ~/Desktop
              when: 1700000012
            """
        harness.equal(
            ShellHistoryFile.commands(in: fish), ["ls -la", "cd ~/Desktop"],
            "fish's `when:` lines are not commands")
    }

    private static func itDetectsRatherThanAssumes(_ harness: Harness) {
        // The whole point: one reader, three files, no configuration. A file is decided by *looking* at it.
        let zsh = ": 1700000000:0;git status"
        let bash = "git status"
        let fish = "- cmd: git status\n  when: 1700000000"
        harness.equal(ShellHistoryFile.commands(in: zsh), ["git status"], "zsh extended")
        harness.equal(ShellHistoryFile.commands(in: bash), ["git status"], "plain")
        harness.equal(ShellHistoryFile.commands(in: fish), ["git status"], "fish")

        // A plain history whose *command* happens to look like a fish record must not be read as fish — detection
        // looks at the whole file, not at one line.
        let plainWithAnOddCommand = """
            echo hi
            - cmd: not a fish record
            echo bye
            """
        harness.equal(
            ShellHistoryFile.commands(in: plainWithAnOddCommand),
            ["echo hi", "- cmd: not a fish record", "echo bye"],
            "a plain file stays plain even when a line looks like fish")

        // And an empty file is empty, not a crash.
        harness.equal(ShellHistoryFile.commands(in: ""), [], "an empty file has no commands")
    }

    private static func itUnescapesNewlines(_ harness: Harness) {
        // zsh writes a newline inside a command as `\n` — two characters — so a multi-line command survives as one
        // record. Getting this wrong shows a command with a literal backslash-n in it.
        harness.equal(
            ShellHistoryFile.commands(in: ": 1:0;for i in 1 2 3; do\\n  echo $i\\ndone"),
            ["for i in 1 2 3; do\n  echo $i\ndone"],
            "an escaped newline comes back as a newline")

        // An escaped backslash has to be put back *before* the newline, or `\\n` would become a newline instead of
        // a backslash followed by an `n`.
        harness.equal(
            ShellHistoryFile.commands(in: ": 1:0;printf 'a\\\\nb'"),
            ["printf 'a\\nb'"],
            "an escaped backslash is a backslash, not the start of an escape")
    }

    private static func itKnowsWhereEachShellKeepsIt(_ harness: Harness) {
        harness.equal(
            ShellHistoryFile.defaultURL(for: .zsh, home: "/Users/example").path,
            "/Users/example/.zsh_history", "zsh")
        harness.equal(
            ShellHistoryFile.defaultURL(for: .bash, home: "/Users/example").path,
            "/Users/example/.bash_history", "bash")
        harness.equal(
            ShellHistoryFile.defaultURL(for: .fish, home: "/Users/example").path,
            "/Users/example/.local/share/fish/fish_history", "fish keeps its history in a data directory")
    }

    private static func anAbsentFileIsEmpty(_ harness: Harness) {
        // Plenty of machines have no `~/.bash_history`, and a terminal that refused to start over one would be a
        // terminal that could not be used at all.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-history-\(UUID().uuidString)")
        harness.equal(ShellHistoryFile.read(at: missing), [], "a missing file is an empty history")

        // And a real file round-trips through the same call.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)")
        try? ": 1:0;echo one\n: 2:0;echo two\n".write(to: url, atomically: true, encoding: .utf8)
        harness.equal(
            ShellHistoryFile.read(at: url), ["echo one", "echo two"],
            "and a file on disk is read")
        try? FileManager.default.removeItem(at: url)
    }
}
