import Foundation

/// Guards the spans a command line is coloured in.
///
/// The invariant that matters most is at the bottom: the spans must be ordered, non-overlapping, and
/// cover everything that is not whitespace. A highlighter that drops a span leaves a word in the
/// default colour, which looks like a bug in the command rather than in the scanner.
@main
enum ShellTokenizerTest {
    static func main() {
        let harness = Harness("shell-tokenizer-test")

        words(harness)
        operators(harness)
        quoting(harness)
        expansions(harness)
        redirection(harness)
        heredocs(harness)
        comments(harness)
        coverage(harness)

        harness.finish()
    }

    /// The spans of a buffer as `(text, kind)` pairs, which is how every assertion below reads.
    private static func spans(_ buffer: String) -> [(String, ShellToken.Kind)] {
        ShellTokenizer.tokens(in: buffer).map { (String(buffer[$0.range]), $0.kind) }
    }

    private static func expect(
        _ harness: Harness, _ buffer: String, _ expected: [(String, ShellToken.Kind)], _ label: String
    ) {
        let actual = spans(buffer)
        let matches = actual.count == expected.count
            && zip(actual, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        harness.expect(
            matches,
            "\(label): \(buffer) → \(actual.map { "\($0.0):\($0.1)" }) "
                + "expected \(expected.map { "\($0.0):\($0.1)" })")
    }

    private static func words(_ harness: Harness) {
        expect(harness, "", [], "an empty buffer has no spans")
        expect(harness, "   ", [], "nor does whitespace")
        expect(harness, "ls", [("ls", .command)], "a lone command")
        expect(harness, "ls -la", [("ls", .command), ("-la", .flag)], "a command and a flag")
        expect(
            harness, "git log --oneline",
            [("git", .command), ("log", .argument), ("--oneline", .flag)],
            "a long flag")
        expect(
            harness, "  ls   /tmp  ",
            [("ls", .command), ("/tmp", .argument)],
            "leading, repeated and trailing whitespace is skipped")
        // A subcommand is the signature table's business, not the scanner's: it needs to know that
        // `git` has subcommands at all.
        expect(
            harness, "echo a\\ b",
            [("echo", .command), ("a\\ b", .argument)],
            "an escaped space keeps a word whole")
    }

    private static func operators(_ harness: Harness) {
        expect(
            harness, "ls | grep x",
            [("ls", .command), ("|", .control), ("grep", .command), ("x", .argument)],
            "a pipe starts a new command")
        expect(
            harness, "cd /tmp && ls",
            [("cd", .command), ("/tmp", .argument), ("&&", .control), ("ls", .command)],
            "so does &&, as one span")
        expect(
            harness, "make || make -j4",
            [("make", .command), ("||", .control), ("make", .command), ("-j4", .flag)],
            "and ||")
        expect(
            harness, "sleep 1 & ls",
            [("sleep", .command), ("1", .argument), ("&", .control), ("ls", .command)],
            "and a background ampersand")
        expect(
            harness, "(cd /tmp; ls)",
            [("(", .control), ("cd", .command), ("/tmp", .argument), (";", .control),
             ("ls", .command), (")", .control)],
            "a subshell is two commands and three operators")
    }

    private static func quoting(_ harness: Harness) {
        expect(
            harness, "echo 'a $b'",
            [("echo", .command), ("'a $b'", .string)],
            "nothing expands inside single quotes")
        expect(
            harness, "echo \"a $USER b\"",
            [("echo", .command), ("\"a ", .string), ("$USER", .variable), (" b\"", .string)],
            "a double-quoted string is cut around the expansion inside it")
        expect(
            harness, "echo \"unterminated",
            [("echo", .command), ("\"unterminated", .string)],
            "an unterminated quote runs to the end rather than flickering while it is typed")
        expect(
            harness, "echo 'it'\"s\"",
            [("echo", .command), ("'it'", .string), ("\"s\"", .string)],
            "adjacent quotes are two spans")
        expect(
            harness, "echo \"a \\\" b\"",
            [("echo", .command), ("\"a \\\" b\"", .string)],
            "an escaped quote does not close the string")
    }

    private static func expansions(_ harness: Harness) {
        expect(
            harness, "echo $HOME",
            [("echo", .command), ("$HOME", .variable)],
            "a bare variable")
        expect(
            harness, "echo ${HOME}/bin",
            [("echo", .command), ("${HOME}", .variable), ("/bin", .argument)],
            "a braced variable stops at the brace")
        expect(
            harness, "echo $(date +%s)",
            [("echo", .command), ("$(date +%s)", .variable)],
            "a command substitution is one span, spaces and all")
        expect(
            harness, "echo $? $1",
            [("echo", .command), ("$?", .variable), ("$1", .variable)],
            "the status and a positional")
        // A `$` that starts none of those is just a character.
        expect(
            harness, "echo 100$",
            [("echo", .command), ("100$", .argument)],
            "a trailing dollar is not an expansion")
        // The word's kind is the plain run's kind, so a variable at command position is a variable:
        // what it expands to is not knowable here.
        expect(
            harness, "$EDITOR file",
            [("$EDITOR", .variable), ("file", .argument)],
            "a variable in command position is still a variable")
    }

    private static func redirection(_ harness: Harness) {
        expect(
            harness, "ls > out.txt",
            [("ls", .command), (">", .redirect), ("out.txt", .argument)],
            "the operator is a redirect and its target is a word")
        expect(
            harness, "ls >> out.txt",
            [("ls", .command), (">>", .redirect), ("out.txt", .argument)],
            "appending is one span")
        expect(
            harness, "cmd 2>&1",
            [("cmd", .command), ("2>&1", .redirect)],
            "a descriptor and its target are one span")
        expect(
            harness, "cmd &> log",
            [("cmd", .command), ("&>", .redirect), ("log", .argument)],
            "so is &>")
        expect(
            harness, "cmd < in",
            [("cmd", .command), ("<", .redirect), ("in", .argument)],
            "and input redirection")
    }

    private static func heredocs(_ harness: Harness) {
        // A here-document is the one place a shell stops being line-oriented, and the one place the
        // body is not shell at all: `$`, `|` and `#` in it mean nothing.
        expect(
            harness, "cat <<EOF\n$HOME | # not a comment\nEOF\n",
            [("cat", .command), ("<<", .redirect), ("EOF", .argument),
             ("$HOME | # not a comment\nEOF\n", .string)],
            "the body is one string, terminator included")

        expect(
            harness, "cat <<'EOF'\nraw $HOME\nEOF\n",
            [("cat", .command), ("<<", .redirect), ("'EOF'", .string),
             ("raw $HOME\nEOF\n", .string)],
            "a quoted terminator is the same word, and its body is still body")

        expect(
            harness, "cat <<-EOF\n\tindented\n\tEOF\n",
            [("cat", .command), ("<<-", .redirect), ("EOF", .argument),
             ("\tindented\n\tEOF\n", .string)],
            "`<<-` is one operator, and an indented terminator still terminates")

        // A body with no terminator runs to the end of the buffer, which is what has been typed.
        expect(
            harness, "cat <<EOF\nstill typing",
            [("cat", .command), ("<<", .redirect), ("EOF", .argument), ("still typing", .string)],
            "an unterminated body runs to the end")

        // The line after the terminator is shell again.
        expect(
            harness, "cat <<EOF\nbody\nEOF\nls -la",
            [("cat", .command), ("<<", .redirect), ("EOF", .argument),
             ("body\nEOF\n", .string), ("ls", .command), ("-la", .flag)],
            "and the shell resumes after it")

        // A terminator the shell will expand cannot be known here, so the body is left as shell
        // rather than swallowing everything that follows.
        expect(
            harness, "cat <<$X\nbody",
            [("cat", .command), ("<<", .redirect), ("$X", .variable), ("body", .argument)],
            "an expandable terminator is not guessed at")
    }

    private static func comments(_ harness: Harness) {
        expect(harness, "# just a note", [("# just a note", .comment)], "a whole-line comment")
        expect(
            harness, "ls # why",
            [("ls", .command), ("# why", .comment)],
            "a trailing comment takes the rest of the line")
        // `#` inside a word is not a comment, which is what makes `foo#bar` a filename.
        expect(
            harness, "echo a#b",
            [("echo", .command), ("a#b", .argument)],
            "a hash inside a word is not a comment")
    }

    /// The invariant: ordered, never overlapping, and covering every character that is not
    /// whitespace. A dropped span leaves a word in the default colour, which reads as a bug in the
    /// command rather than in the scanner.
    private static func coverage(_ harness: Harness) {
        let samples = [
            "git log --oneline | head -20",
            "echo \"a $USER b\" 'c' ${HOME} $(date)",
            "cat < in.txt >> out.txt 2>&1 && echo done # ok",
            "for f in *.swift; do echo $f; done",
            "kubectl get pods -n kube-system --watch",
            "   ",
            "",
        ]
        for sample in samples {
            let label = sample.isEmpty ? "<empty>" : sample
            let tokens = ShellTokenizer.tokens(in: sample)
            let characters = Array(sample)
            var marks = Array(repeating: 0, count: characters.count)
            var ordered = true
            var cursor = sample.startIndex

            for token in tokens {
                if token.range.lowerBound < cursor { ordered = false }
                cursor = token.range.upperBound
                let lower = sample.distance(from: sample.startIndex, to: token.range.lowerBound)
                let upper = sample.distance(from: sample.startIndex, to: token.range.upperBound)
                for index in lower..<upper where marks.indices.contains(index) { marks[index] += 1 }
            }

            harness.expect(ordered, "spans of \(label) are in order")
            harness.expect(!marks.contains { $0 > 1 }, "spans of \(label) never overlap")
            let missed = zip(characters, marks).filter { !$0.0.isWhitespace && $0.1 == 0 }
            harness.expect(
                missed.isEmpty,
                "spans of \(label) leave nothing uncovered: \(String(missed.map(\.0)))")
        }
    }
}
