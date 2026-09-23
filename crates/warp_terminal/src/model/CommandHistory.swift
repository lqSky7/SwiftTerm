import Foundation

/// The commands that have been run, across sessions.
///
/// **A file rather than memory, because the thing history is *for* is the session after this one.** Until now the
/// history was the session's own blocks, so every new tab started with an empty ↑ — which is not what a shell does
/// and not what anybody means by "my history".
///
/// It does not read the *shell's* history file, which is what Warp does. That would mean parsing somebody's
/// `HISTFILE`, and the formats disagree: zsh writes `: <timestamp>:<duration>;<command>` when extended history is on
/// and a plain line when it is off, bash writes plain lines, and fish writes YAML. A parser that guessed wrong
/// would silently offer nothing at all — worse than a history that is only this app's. Reading it is worth doing
/// later, with the format detected rather than assumed.
struct CommandHistory: Equatable {
    /// How many commands are kept. The oldest are dropped.
    ///
    /// Capped because this is read at every start and walked on every ↑. Two thousand is more than anybody scrolls
    /// through and small enough to load without thinking about it.
    static let maximumEntries = 2000

    /// Oldest first, which is the order a shell keeps them in and the opposite of the order they are offered in.
    private(set) var entries: [String] = []

    init(entries: [String] = []) {
        self.entries = Array(Self.cleaned(entries).suffix(Self.maximumEntries))
    }

    /// Record a command that was run.
    ///
    /// **Consecutive duplicates are folded**, which is what a shell's own `ignoredups` does and what stops ↑ from
    /// being a key that does nothing. Not *all* duplicates: running `ls`, then `cd`, then `ls` again is a history
    /// worth keeping, and collapsing it would lose the order somebody actually worked in.
    mutating func record(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.last != trimmed else { return }
        entries.append(trimmed)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    /// The commands to offer, **newest first** — the order `CompletionEngine` wants and the order ↑ walks in.
    var newestFirst: [String] { entries.reversed() }

    /// Blank lines and surrounding whitespace are not commands, and a file that has been hand-edited is where they
    /// come from.
    private static func cleaned(_ entries: [String]) -> [String] {
        entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Where the history lives between sessions.
///
/// One command per line, which is the format a shell uses and the format a person can read and edit. A command
/// containing a newline is therefore stored with its newlines turned into spaces: a multi-line command is rare, and
/// a file that cannot be parsed is a history that is silently lost.
struct CommandHistoryStore {
    let url: URL
    private let fileManager: FileManager

    /// The default location: `Application Support`, which is where a Mac app keeps this. Not a dotfile in the home
    /// directory — that is a shell's habit, and this is not a shell.
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("swiftTerm/history", isDirectory: false)
    }

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? Self.defaultURL(fileManager: fileManager)
    }

    /// What was saved last time. An absent or unreadable file is an empty history, not a failure: the first run has
    /// no file, and a history that refused to start would be a terminal that refused to start.
    func load() -> CommandHistory {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return CommandHistory()
        }
        return CommandHistory(entries: contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init))
    }

    /// Write it back.
    ///
    /// Written whole rather than appended to, because the cap means the *beginning* of the file has to be dropped
    /// as the end grows — an append-only file would grow without bound and stop being a history and start being a
    /// log. Created with intermediate directories, so the first run works.
    func save(_ history: CommandHistory) {
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = history.entries.map(Self.singleLine).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One command on one line. See the note on the format.
    private static func singleLine(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
