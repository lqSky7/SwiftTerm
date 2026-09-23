import Foundation

/// One thing the popover or the ghost text can offer.
struct CompletionCandidate: Equatable {
    enum Kind: Equatable {
        case history
        case path
        case command
        case flag
        case subcommand

        /// What the popover calls it.
        ///
        /// A candidate's *kind* is worth showing beside it: "history" and "a subcommand of git" are
        /// different reasons to trust a suggestion, and the text on its own does not say which one this is.
        /// Warp shows the same thing as a label on each row.
        var displayName: String {
            switch self {
            case .history: "history"
            case .path: "path"
            case .command: "command"
            case .flag: "flag"
            case .subcommand: "subcommand"
            }
        }
    }

    /// What replaces the word under the cursor — and what the row *reads*.
    var text: String
    var kind: Kind
    /// Shown beside it. Nil when there is nothing more to say than the text itself.
    var description: String?
    /// What to put in the buffer when it is accepted, when that is not the same as `text`.
    ///
    /// **A path with a space in it is the whole reason this exists.** The row should read `Calibre Library/`,
    /// because that is the name; the buffer needs `Calibre\ Library/`, because that is what the shell needs to
    /// receive *one* argument. Inserting the readable form is the difference between a completion that works
    /// and one that silently puts half a path in the buffer and cannot be `cd`'d into.
    ///
    /// Nil means the two are the same, which is true of everything that is not a path.
    var insertion: String?
}

/// A directory entry, as completion needs to see one.
struct DirectoryEntry: Equatable {
    var name: String
    var isDirectory: Bool
}

/// What a command's arguments look like.
///
/// A table rather than a parser, because a table is content: adding `terraform` here is a line, not a
/// feature. Warp ships 500+ of these in `command-signatures-v2`; this starts with a dozen and grows as
/// commands turn out to matter.
struct CommandSignature: Equatable {
    struct Flag: Equatable {
        var name: String
        var description: String
    }

    var subcommands: [String] = []
    var flags: [Flag] = []
    /// Whether this command's arguments are usually file paths.
    var takesPaths = true

    static let table: [String: CommandSignature] = [
        "git": CommandSignature(
            subcommands: [
                "add", "bisect", "blame", "branch", "checkout", "cherry-pick", "clone", "commit",
                "diff", "fetch", "log", "merge", "pull", "push", "rebase", "reset", "restore",
                "revert", "show", "stash", "status", "switch", "tag", "worktree",
            ],
            flags: [
                Flag(name: "--all", description: "every ref"),
                Flag(name: "--amend", description: "replace the last commit"),
                Flag(name: "--oneline", description: "one line per commit"),
                Flag(name: "--stat", description: "diffstat"),
                Flag(name: "--hard", description: "discard working tree changes"),
                Flag(name: "-b", description: "create a branch"),
            ],
            takesPaths: true),
        "docker": CommandSignature(
            subcommands: [
                "build", "compose", "container", "cp", "exec", "image", "images", "inspect", "logs",
                "network", "ps", "pull", "push", "restart", "rm", "run", "start", "stop", "volume",
            ],
            flags: [
                Flag(name: "--detach", description: "run in the background"),
                Flag(name: "--env", description: "set an environment variable"),
                Flag(name: "--name", description: "name the container"),
                Flag(name: "--rm", description: "remove when it exits"),
                Flag(name: "--volume", description: "mount a volume"),
            ],
            takesPaths: true),
        "cargo": CommandSignature(
            subcommands: [
                "add", "bench", "build", "check", "clean", "clippy", "doc", "fmt", "install", "new",
                "publish", "remove", "run", "test", "tree", "update",
            ],
            flags: [
                Flag(name: "--all-features", description: "every feature"),
                Flag(name: "--jobs", description: "parallel jobs"),
                Flag(name: "--release", description: "optimised build"),
                Flag(name: "--target", description: "target triple"),
                Flag(name: "--workspace", description: "the whole workspace"),
            ],
            takesPaths: true),
        "npm": CommandSignature(
            subcommands: [
                "ci", "dedupe", "exec", "init", "install", "link", "outdated", "publish", "run",
                "test", "uninstall", "update", "view", "why",
            ],
            flags: [
                Flag(name: "--global", description: "install globally"),
                Flag(name: "--save-dev", description: "as a dev dependency"),
                Flag(name: "--workspace", description: "a workspace"),
            ],
            takesPaths: true),
        "kubectl": CommandSignature(
            subcommands: [
                "apply", "config", "delete", "describe", "edit", "exec", "get", "logs", "port-forward",
                "rollout", "scale", "top", "version",
            ],
            flags: [
                Flag(name: "--all-namespaces", description: "every namespace"),
                Flag(name: "--context", description: "which cluster"),
                Flag(name: "--namespace", description: "which namespace"),
                Flag(name: "--output", description: "output format"),
                Flag(name: "--watch", description: "stream changes"),
            ],
            takesPaths: true),
        "ls": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--all", description: "include dotfiles"),
                Flag(name: "--color", description: "colourise"),
                Flag(name: "--human-readable", description: "sizes people can read"),
                Flag(name: "-a", description: "include dotfiles"),
                Flag(name: "-h", description: "sizes people can read"),
                Flag(name: "-l", description: "long format"),
            ],
            takesPaths: true),
        "cd": CommandSignature(subcommands: [], flags: [], takesPaths: true),
        "grep": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--extended-regexp", description: "ERE"),
                Flag(name: "--ignore-case", description: "case insensitive"),
                Flag(name: "--line-number", description: "show line numbers"),
                Flag(name: "--recursive", description: "descend directories"),
                Flag(name: "-i", description: "case insensitive"),
                Flag(name: "-n", description: "show line numbers"),
                Flag(name: "-r", description: "descend directories"),
            ],
            takesPaths: true),
        "make": CommandSignature(subcommands: [], flags: [], takesPaths: true),
        "swift": CommandSignature(
            subcommands: ["build", "format", "package", "run", "test"],
            flags: [
                Flag(name: "--configuration", description: "debug or release"),
                Flag(name: "--disable-sandbox", description: "do not sandbox the build"),
                Flag(name: "--target", description: "which target"),
            ],
            takesPaths: true),
        "brew": CommandSignature(
            subcommands: [
                "cleanup", "doctor", "info", "install", "leaves", "list", "outdated", "search",
                "services", "uninstall", "update", "upgrade",
            ],
            flags: [
                Flag(name: "--cask", description: "an application"),
                Flag(name: "--formula", description: "a formula"),
            ],
            takesPaths: false),
    ]
}

/// Turns a command line and a cursor into things to offer.
///
/// Pure: the history, the signature table, the working directory and the directory listing all arrive
/// as parameters, so the whole engine runs in a harness with no shell, no file system and no window
/// server. That matters more here than anywhere else in the project, because completion's behaviour
/// is nothing *but* a function of its inputs.
struct CompletionEngine {
    /// Newest first, because that is the order a shell writes them and the order worth offering.
    var history: [String] = []
    var signatures: [String: CommandSignature] = CommandSignature.table
    /// The executable names on the shell's `PATH`, plus its builtins.
    ///
    /// Injected exactly like `listDirectory`, so the engine stays pure and a harness drives it with a list.
    /// Empty is a legitimate value — a caller with nothing to offer — and the signature table alone still
    /// answers in that case.
    var commands: [String] = []
    var workingDirectory: String
    var listDirectory: (String) -> [DirectoryEntry]

    // MARK: - Candidates

    func candidates(for buffer: String, cursor: Int) -> [CompletionCandidate] {
        let characters = Array(buffer)
        let cursor = min(max(0, cursor), characters.count)
        let wordStart = startOfWord(in: characters, before: cursor)
        let word = String(characters[wordStart..<cursor])
        let before = String(characters[0..<wordStart])

        // The first word of a line is a command; everything after it is that command's business.
        //
        // **Unless the first word is a path.** `./build.sh` and `~/bin/x` are files, not names to look up on `PATH`,
        // and nothing on `PATH` begins with `./` — so treating one as a command name offered an empty list, which is
        // why typing `./` produced no popover and no suggestion at all. The file system is the only thing with an
        // answer there.
        if !before.contains(where: { !$0.isWhitespace }) {
            if word.contains("/") || word.hasPrefix("~") {
                return rank(pathCandidates(prefix: word), prefix: word)
            }
            return rank(commandCandidates(prefix: word), prefix: word)
        }
        guard let command = firstWord(characters) else { return [] }
        if word.hasPrefix("-") { return rank(flagCandidates(command: command, prefix: word), prefix: word) }

        var candidates = subcommandCandidates(command: command, prefix: word)
        if signatures[command]?.takesPaths ?? true { candidates += pathCandidates(prefix: word) }
        return rank(candidates, prefix: word)
    }

    /// The rest of the most recent history entry that starts with what has been typed.
    ///
    /// Only offered with the cursor at the end of the line: ghost text in the middle of a line is a
    /// suggestion about a buffer that does not exist yet.
    func ghostText(for buffer: String, cursor: Int) -> String? {
        guard cursor == buffer.count, !buffer.isEmpty else { return nil }
        guard let match = history.first(where: { $0.hasPrefix(buffer) && $0.count > buffer.count })
        else { return nil }
        return String(match.dropFirst(buffer.count))
    }

    // MARK: - The sources

    private func commandCandidates(prefix: String) -> [CompletionCandidate] {
        guard !prefix.isEmpty else { return [] }
        var candidates = signatures.keys.sorted().map {
            CompletionCandidate(text: $0, kind: .command, description: nil)
        }
        // The shell's own answer to "what can I run". The table's entries come first because they are the ones
        // with descriptions, and a name both sources know is deduplicated by `rank`.
        candidates += commands.map {
            CompletionCandidate(text: $0, kind: .command, description: nil)
        }
        // A command that has actually been run is worth offering even if it is not on `PATH` any more — a
        // script in a directory since deleted is still something you ran.
        for line in history {
            guard let word = line.split(separator: " ").first, !word.isEmpty else { continue }
            candidates.append(
                CompletionCandidate(text: String(word), kind: .history, description: "from history"))
        }
        return candidates
    }

    private func flagCandidates(command: String, prefix: String) -> [CompletionCandidate] {
        guard let signature = signatures[command] else { return [] }
        return signature.flags.map {
            CompletionCandidate(text: $0.name, kind: .flag, description: $0.description)
        }
    }

    private func subcommandCandidates(command: String, prefix: String) -> [CompletionCandidate] {
        guard let signature = signatures[command] else { return [] }
        return signature.subcommands.map {
            CompletionCandidate(text: $0, kind: .subcommand, description: nil)
        }
    }

    private func pathCandidates(prefix: String) -> [CompletionCandidate] {
        let split = prefix.lastIndex(of: "/")
        let directoryPart = split.map { String(prefix[prefix.startIndex...$0]) } ?? ""
        let namePart = split.map { String(prefix[prefix.index(after: $0)...]) } ?? prefix

        let absolute = absoluteDirectory(for: directoryPart)
        // Matched on the *name*, with the backslashes the user may already have typed taken off. `Calibre\ L`
        // and `Calibre L` are the same request, and a filter that compared the typed text against the name
        // literally would drop the first one — which is the one somebody types once they have learned they
        // have to escape.
        let wanted = namePart.replacingOccurrences(of: "\\", with: "")
        return listDirectory(absolute).map { entry in
            let suffix = entry.isDirectory ? "/" : ""
            return CompletionCandidate(
                text: directoryPart + entry.name + suffix,
                kind: .path,
                description: entry.isDirectory ? "directory" : nil,
                insertion: directoryPart + Self.shellEscaped(entry.name) + suffix)
        }
        .filter { wanted.isEmpty || $0.text.dropFirst(directoryPart.count).hasPrefix(wanted) }
    }

    /// A file name as the shell needs to receive it.
    ///
    /// `Calibre Library` is one argument, and written out plainly it is two — which is exactly the bug this
    /// exists for: the completion inserted the readable name, the shell read two words, and there was no way
    /// to `cd` into the directory the list had just offered. Warp escapes the same thing at the same place
    /// (`shell_escape()` on the relative path name in `crates/warp_completer/src/completer/engine/path.rs`).
    ///
    /// An **allow-list** rather than a list of dangerous characters: the set of characters a shell reads as
    /// literal is small and closed, and the set it reads as special is neither. A character that is not on the
    /// list gets a backslash, which every POSIX shell reads as "this one, literally".
    static func shellEscaped(_ name: String) -> String {
        let literal = "._-+,:@%^/="
        var escaped = ""
        for character in name {
            if character.isLetter || character.isNumber || literal.contains(character) {
                escaped.append(character)
            } else {
                escaped.append("\\")
                escaped.append(character)
            }
        }
        return escaped
    }

    /// A directory the file system can be asked about. An empty part means the working directory, and
    /// a bare `~` means home — the two expansions worth doing here rather than leaving to the shell.
    ///
    /// The trailing slash is dropped: it is part of the *text* being completed, not of the directory
    /// being listed, and a path that depends on which of the two a caller passed is a path that will
    /// be wrong half the time.
    private func absoluteDirectory(for directoryPart: String) -> String {
        if directoryPart.isEmpty { return workingDirectory }
        var part = directoryPart
        while part.hasSuffix("/"), part.count > 1 { part.removeLast() }
        if part == "~" { return NSHomeDirectory() }
        if part.hasPrefix("~/") { return NSHomeDirectory() + part.dropFirst() }
        if part.hasPrefix("/") { return part }
        return workingDirectory + "/" + part
    }

    // MARK: - Ranking

    /// Prefix matches first, then the rest in source order — which puts history newest-first and the
    /// table's own order after it. Deduplicated on the text, keeping the first.
    ///
    /// **Non-matching candidates are dropped, not ranked last.** They used to be kept, which was harmless
    /// while the only source was a table of thirteen commands — and became a two-thousand-entry list the moment
    /// `PATH` arrived. A completion list is a list of things that match; "here is everything, best guess first"
    /// is only a defensible answer when there is nothing to match against, which is the empty-prefix case the
    /// guard below returns early for.
    private func rank(_ candidates: [CompletionCandidate], prefix: String) -> [CompletionCandidate] {
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.text).inserted }
        guard !lowered.isEmpty else { return unique }
        return unique.filter { Self.matchesPrefix($0, lowered) }
    }

    /// Whether a candidate is a prefix match.
    ///
    /// Checked against both the text the row *reads* and the text it *inserts*: a path typed with its space
    /// already escaped (`Calibre\ L`) matches neither the readable name nor anything else literally, and the
    /// person who typed it meant the same request as the one who typed `Calibre L`. Ranking it last would be
    /// punishing them for knowing how the shell works.
    private static func matchesPrefix(_ candidate: CompletionCandidate, _ lowered: String) -> Bool {
        if candidate.text.lowercased().hasPrefix(lowered) { return true }
        guard let insertion = candidate.insertion else { return false }
        return insertion.lowercased().hasPrefix(lowered)
    }

    // MARK: - The word under the cursor

    /// Where the word under the cursor begins.
    ///
    /// Not private: an accepted candidate has to replace exactly the range the candidates were matched
    /// against, so `CompletionMenu` needs the same answer. Two copies of "where does a word start" would be
    /// two answers, and the one that drifts is the one that eats a character of somebody's command.
    ///
    /// **A backslash-escaped space does not end a word.** `Calibre\ Library` is one word, and a scanner that
    /// stopped at the space would answer `Library` — so a person who had escaped the space *correctly*, which
    /// is exactly what this app tells them to do, would press Tab and get a list of nothing. The escape has to
    /// be understood here or the escaping is a trap.
    func startOfWord(in characters: [Character], before cursor: Int) -> Int {
        var start = min(max(0, cursor), characters.count)
        while start > 0 {
            let previous = characters[start - 1]
            if !previous.isWhitespace {
                start -= 1
                continue
            }
            guard Self.isEscaped(characters, at: start - 1) else { break }
            start -= 1
        }
        return start
    }

    /// Whether the character at `index` is preceded by an **odd** number of backslashes — which is what makes
    /// it escaped rather than a separator. Odd, not "any": `\\ ` is an escaped backslash followed by a space
    /// that really does end the word.
    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        var backslashes = 0
        var cursor = index
        while cursor > 0, characters[cursor - 1] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    private func firstWord(_ characters: [Character]) -> String? {
        var index = 0
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        let start = index
        while index < characters.count, !characters[index].isWhitespace { index += 1 }
        return index > start ? String(characters[start..<index]) : nil
    }
}
