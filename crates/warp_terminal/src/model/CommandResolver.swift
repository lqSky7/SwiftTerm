import Foundation

/// Whether the first word of a command is something the shell could actually run.
///
/// The answer is deliberately three-valued. A two-valued check would have to guess, and guessing
/// wrong means a red dashed underline under a command that works — which is worse than no underline
/// at all, because it teaches the user to ignore the underline.
struct CommandResolver {
    enum Resolution: Equatable {
        /// It can be run. The path is nil for a shell builtin, which has none.
        case found(path: String?)
        /// It cannot: nothing on `PATH`, no builtin, and no such file.
        case notFound
        /// It cannot be known from the text alone — `$EDITOR`, a glob, a quoted name, `~/bin/x`.
        case indeterminate
    }

    /// Shell builtins and reserved words, for zsh, bash and fish together.
    ///
    /// Curated rather than discovered, and aliases are *not* here: Warp captures them during
    /// bootstrap (`warp_features.md` #6), and this project's bootstrap does not yet. That is the one
    /// known source of false "not found" answers, and it is why the resolution is three-valued —
    /// an alias is reported as `found` only if it happens to be a real command too.
    static let builtins: Set<String> = [
        ".", ":", "[", "[[", "abbr", "alias", "and", "autoload", "bg", "bindkey", "break", "builtin",
        "case", "cd", "command", "continue", "coproc", "declare", "dirs", "disown", "do", "done",
        "echo", "elif", "else", "emulate", "enable", "end", "esac", "eval", "exec", "exit", "export",
        "false", "fc", "fg", "fi", "for", "function", "functions", "getopts", "hash", "history", "if",
        "in", "jobs", "kill", "let", "local", "logout", "noglob", "not", "or", "popd", "printf",
        "pushd", "pwd", "read", "readonly", "rehash", "return", "select", "set", "setopt", "shift",
        "source", "status", "string", "suspend", "switch", "test", "then", "time", "times", "trap",
        "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "unsetopt", "until", "wait",
        "whence", "where", "while", "zmodload",
    ]

    private let directories: [String]
    private let fileManager: FileManager

    /// Built from a `PATH` string. There is no internal cache: constructing this is splitting a
    /// string, and the caller holds one for as long as the environment it came from is current.
    init(path: String?, fileManager: FileManager = .default) {
        self.directories = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        self.fileManager = fileManager
    }

    /// Every executable name on `PATH`, plus the shell's builtins, sorted and deduplicated.
    ///
    /// This is the source Warp lists as *"System `$PATH` executable binaries"* (`warp_features.md` #4), and
    /// without it Tab after `ls` offers the dozen commands this project has *signatures* for and nothing else —
    /// which is not what a shell does and not what anybody means by pressing Tab on a command name.
    ///
    /// A directory that cannot be read is skipped rather than fatal: `PATH` routinely names directories that do
    /// not exist on this machine, and one of them must not cost the whole list.
    func executableNames() -> [String] {
        var names = Self.builtins
        for directory in directories {
            let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries where fileManager.isExecutableFile(atPath: directory + "/" + entry) {
                names.insert(entry)
            }
        }
        return names.sorted()
    }

    /// Characters that make the word's meaning depend on something this cannot see: an expansion, a
    /// glob, a quote, a backtick.
    private static let expansionCharacters = Set("$\\`\"'*?[]{}")

    func resolution(of command: String) -> Resolution {
        guard !command.isEmpty else { return .indeterminate }
        if command.contains(where: \.isWhitespace) { return .indeterminate }
        // Builtins come before the expansion check, because `[` and `[[` are both builtins *and*
        // glob characters, and a name that is exactly a builtin has an answer.
        if Self.builtins.contains(command) { return .found(path: nil) }
        if command.contains(where: { Self.expansionCharacters.contains($0) }) { return .indeterminate }
        // `~` expands, but only the plain leading `~/` form: `~someone/bin/x` is another user's home
        // and this has no business guessing where that is.
        if command.hasPrefix("~"), !command.hasPrefix("~/") { return .indeterminate }

        if command.contains("/") {
            // A path is its own answer: either it is there and executable, or it is not.
            let path = expanded(command)
            return fileManager.isExecutableFile(atPath: path) ? .found(path: path) : .notFound
        }
        for directory in directories {
            let candidate = directory + "/" + command
            if fileManager.isExecutableFile(atPath: candidate) { return .found(path: candidate) }
        }
        return .notFound
    }

    /// The spans to draw a dashed underline under. Empty when there is nothing to complain about.
    ///
    /// Every command in the line is checked, not just the first, so `ls | nope` underlines the half
    /// that is wrong. This is the whole of what the editor needs to know about resolution, which is
    /// why it lives here rather than in the view: the view draws a squiggle, it does not decide what
    /// deserves one.
    func notFoundRanges(in buffer: String, tokens: [ShellToken]) -> [Range<String.Index>] {
        tokens.filter { $0.kind == .command }
            .filter { resolution(of: String(buffer[$0.range])) == .notFound }
            .map(\.range)
    }

    /// `~` is only expanded for a path the shell would expand, and only the plain leading form.
    private func expanded(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }
}
