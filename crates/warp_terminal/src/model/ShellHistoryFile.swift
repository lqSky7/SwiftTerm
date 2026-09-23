import Foundation

/// The commands in a shell's **own** history file.
///
/// This is what Warp reads, and the reason to read it is that the history worth having is the one the shell has been
/// keeping for years — not the one this app started writing yesterday.
///
/// **The format is detected rather than assumed**, because the three shells disagree and two of them disagree with
/// themselves:
///
/// - zsh writes `: <timestamp>:<duration>;<command>` when `EXTENDED_HISTORY` is set and a plain line when it is not,
///   so the same file can be either and the *same user* can have both over time.
/// - bash writes plain lines.
/// - fish writes YAML-ish `- cmd: <command>` records with a `when:` line after each.
///
/// A parser that assumed one of them would silently offer nothing at all for the others — a history that looks empty
/// is indistinguishable from a history that failed, and that is worse than not reading the file.
enum ShellHistoryFile {
    /// Where a shell of this kind conventionally keeps its history.
    ///
    /// Conventional rather than reported: the shell's own `$HISTFILE` is whatever it was set to, and asking for it
    /// would mean another escape sequence for a value that is `~/.zsh_history` on essentially every machine. The
    /// paths are the three defaults.
    static func defaultURL(for shellType: ShellType, home: String) -> URL {
        switch shellType {
        case .zsh: return URL(fileURLWithPath: home + "/.zsh_history")
        case .bash: return URL(fileURLWithPath: home + "/.bash_history")
        case .fish: return URL(fileURLWithPath: home + "/.local/share/fish/fish_history")
        case .other: return URL(fileURLWithPath: home + "/.zsh_history")
        }
    }

    /// The commands, **oldest first**, which is the order a history file is written in.
    ///
    /// An absent or unreadable file is an empty history, not a failure: plenty of machines have no `~/.bash_history`,
    /// and a terminal that refused to start over one would be a terminal that could not be used at all.
    static func read(at url: URL, fileManager: FileManager = .default) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return commands(in: contents)
    }

    /// The commands in a history file's text. Split out so a harness can drive it with a literal, which is the only
    /// way to test three formats without three shells.
    static func commands(in contents: String) -> [String] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // **A positive test over the whole file, not "does it contain a line that looks like X".** The first
        // version asked whether any line looked like a fish record, and one command that happened to start with
        // `- cmd: ` then re-read an entire plain history as fish. A file is a format when nothing in it *contradicts*
        // that format.
        if looksLikeFish(lines) { return fishCommands(lines) }
        if looksLikeExtendedZsh(lines) { return zshExtendedCommands(lines) }
        return plainCommands(lines)
    }

    /// `: <timestamp>:<duration>;<command>`.
    ///
    /// The separator is the first `;`: everything before it is `<timestamp>:<duration>`, neither of which can
    /// contain one.
    private static func isExtendedZshLine(_ line: String) -> Bool {
        line.hasPrefix(": ") && line.contains(";")
    }

    /// Whether the whole file is zsh's extended format.
    ///
    /// Every non-blank line has to be a record: a command's newlines are *escaped* inside the record, so an extended
    /// history has no continuation lines for anything else to be.
    private static func looksLikeExtendedZsh(_ lines: [String]) -> Bool {
        var sawRecord = false
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard isExtendedZshLine(line) else { return false }
            sawRecord = true
        }
        return sawRecord
    }

    /// Whether the whole file is fish's format: `- cmd:` records and the indented key lines that follow them.
    private static func looksLikeFish(_ lines: [String]) -> Bool {
        var sawRecord = false
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.hasPrefix("- cmd: ") {
                sawRecord = true
            } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // An indented key line — `when:`, `paths:`. Part of the record above it, not a command.
                continue
            } else {
                return false
            }
        }
        return sawRecord
    }

    private static func zshExtendedCommands(_ lines: [String]) -> [String] {
        var commands: [String] = []
        for line in lines {
            guard isExtendedZshLine(line), let separator = line.firstIndex(of: ";") else {
                // A continuation of the record above it. zsh escapes a newline inside a command as `\n` *in* the
                // record, so a bare line here is a file that has been edited by hand — skipped rather than guessed at.
                continue
            }
            let command = unescaped(String(line[line.index(after: separator)...]))
            if !command.isEmpty { commands.append(command) }
        }
        return commands
    }

    /// `- cmd: <command>` followed by a `when:` line, which is not a command.
    private static func fishCommands(_ lines: [String]) -> [String] {
        var commands: [String] = []
        for line in lines where line.hasPrefix("- cmd: ") {
            let command = unescaped(String(line.dropFirst("- cmd: ".count)))
            if !command.isEmpty { commands.append(command) }
        }
        return commands
    }

    private static func plainCommands(_ lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The escapes zsh and fish both use for a newline inside a record.
    ///
    /// `\n` is two characters in the file, not a newline — which is the whole point of the escaping. The backslash
    /// itself is escaped as `\\`, and it has to be put back *first* or `\\n` would come back as a newline.
    private static func unescaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\\\", with: "\u{0}")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "\\")
    }
}
