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
/// feature. Warp ships 500+ of these in `command-signatures-v2`; this provides the top 50+ common developer
/// tools with flags, subcommands, descriptions and path behaviors.
struct CommandSignature: Equatable {
    struct Flag: Equatable {
        var name: String
        var description: String
    }

    var subcommands: [String] = []
    var flags: [Flag] = []
    /// Whether this command's arguments are usually file paths.
    var takesPaths = true
    /// Whether this command only accepts directories (like cd).
    var directoriesOnly = false

    static let table: [String: CommandSignature] = [
        "git": CommandSignature(
            subcommands: [
                "add", "bisect", "blame", "branch", "checkout", "cherry-pick", "clone", "commit",
                "diff", "fetch", "init", "log", "merge", "pull", "push", "rebase", "remote", "reset", "restore",
                "revert", "show", "stash", "status", "switch", "tag", "worktree",
            ],
            flags: [
                Flag(name: "--all", description: "every ref"),
                Flag(name: "--amend", description: "replace the last commit"),
                Flag(name: "--oneline", description: "one line per commit"),
                Flag(name: "--stat", description: "diffstat"),
                Flag(name: "--hard", description: "discard working tree changes"),
                Flag(name: "-b", description: "create a branch"),
                Flag(name: "-m", description: "commit message"),
                Flag(name: "-a", description: "stage all tracked modified files"),
                Flag(name: "-p", description: "patch interactive mode"),
            ],
            takesPaths: true),
        "docker": CommandSignature(
            subcommands: [
                "build", "compose", "container", "cp", "exec", "image", "images", "inspect", "logs",
                "network", "ps", "pull", "push", "restart", "rm", "rmi", "run", "start", "stop", "system", "volume",
            ],
            flags: [
                Flag(name: "--detach", description: "run in the background"),
                Flag(name: "--env", description: "set an environment variable"),
                Flag(name: "--name", description: "name the container"),
                Flag(name: "--rm", description: "remove when it exits"),
                Flag(name: "--volume", description: "mount a volume"),
                Flag(name: "-it", description: "interactive tty"),
                Flag(name: "-p", description: "publish a port"),
                Flag(name: "-d", description: "detached mode"),
            ],
            takesPaths: true),
        "cargo": CommandSignature(
            subcommands: [
                "add", "bench", "build", "check", "clean", "clippy", "doc", "fmt", "info", "init", "install", "new",
                "publish", "remove", "run", "test", "tree", "update", "vendor",
            ],
            flags: [
                Flag(name: "--all-features", description: "every feature"),
                Flag(name: "--jobs", description: "parallel jobs"),
                Flag(name: "--release", description: "optimised build"),
                Flag(name: "--target", description: "target triple"),
                Flag(name: "--workspace", description: "the whole workspace"),
                Flag(name: "-p", description: "package to run/build"),
            ],
            takesPaths: true),
        "rustc": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--edition", description: "Rust edition"),
                Flag(name: "--emit", description: "output types to produce"),
                Flag(name: "--explain", description: "explain compiler error"),
                Flag(name: "--opt-level", description: "optimization level"),
                Flag(name: "--target", description: "target architecture"),
                Flag(name: "-g", description: "debug info"),
                Flag(name: "-O", description: "optimize output"),
                Flag(name: "-v", description: "verbose"),
            ],
            takesPaths: true),
        "npm": CommandSignature(
            subcommands: [
                "ci", "dedupe", "exec", "fund", "init", "install", "link", "ls", "outdated", "publish", "run",
                "start", "test", "uninstall", "update", "version", "view", "why",
            ],
            flags: [
                Flag(name: "--global", description: "install globally"),
                Flag(name: "--save-dev", description: "as a dev dependency"),
                Flag(name: "--workspace", description: "a workspace"),
                Flag(name: "-D", description: "save dev dependency"),
                Flag(name: "-g", description: "global"),
            ],
            takesPaths: true),
        "pnpm": CommandSignature(
            subcommands: [
                "add", "audit", "build", "create", "dlx", "exec", "import", "init", "install", "link",
                "list", "outdated", "patch", "publish", "remove", "run", "test", "update", "why",
            ],
            flags: [
                Flag(name: "-D", description: "save as dev dependency"),
                Flag(name: "-g", description: "global"),
                Flag(name: "-r", description: "recursive across workspace"),
                Flag(name: "--filter", description: "filter by package"),
            ],
            takesPaths: true),
        "yarn": CommandSignature(
            subcommands: [
                "add", "audit", "build", "cache", "config", "create", "dedupe", "info", "init", "install",
                "link", "list", "outdated", "publish", "remove", "run", "test", "unlink", "upgrade", "why", "workspace",
            ],
            flags: [
                Flag(name: "--dev", description: "save dev dependency"),
                Flag(name: "-D", description: "save dev dependency"),
                Flag(name: "--cwd", description: "working directory"),
            ],
            takesPaths: true),
        "bun": CommandSignature(
            subcommands: [
                "add", "build", "create", "dev", "init", "install", "link", "pm", "remove", "run", "test", "unlink", "update", "upgrade", "x",
            ],
            flags: [
                Flag(name: "-d", description: "save dev dependency"),
                Flag(name: "-g", description: "global"),
                Flag(name: "--watch", description: "watch mode"),
                Flag(name: "--hot", description: "hot reload"),
            ],
            takesPaths: true),
        "go": CommandSignature(
            subcommands: [
                "build", "clean", "doc", "env", "fix", "fmt", "generate", "get", "install", "list", "mod", "run", "test", "tool", "version", "vet", "work",
            ],
            flags: [
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-race", description: "enable data race detection"),
                Flag(name: "-o", description: "output file"),
            ],
            takesPaths: true),
        "python": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-m", description: "run library module"),
                Flag(name: "-c", description: "execute program passed as string"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-V", description: "print python version"),
                Flag(name: "-i", description: "inspect interactively after running script"),
                Flag(name: "-u", description: "unbuffered binary stdout and stderr"),
            ],
            takesPaths: true),
        "python3": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-m", description: "run library module"),
                Flag(name: "-c", description: "execute program passed as string"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-V", description: "print python version"),
                Flag(name: "-i", description: "inspect interactively after running script"),
                Flag(name: "-u", description: "unbuffered binary stdout and stderr"),
            ],
            takesPaths: true),
        "node": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-e", description: "evaluate inline script"),
                Flag(name: "-p", description: "evaluate and print"),
                Flag(name: "--inspect", description: "activate inspector on host:port"),
                Flag(name: "--watch", description: "watch mode"),
                Flag(name: "--test", description: "built-in test runner"),
                Flag(name: "-v", description: "print node version"),
            ],
            takesPaths: true),
        "swift": CommandSignature(
            subcommands: ["build", "format", "package", "run", "test", "repl"],
            flags: [
                Flag(name: "--configuration", description: "debug or release"),
                Flag(name: "-c", description: "debug or release"),
                Flag(name: "--disable-sandbox", description: "do not sandbox the build"),
                Flag(name: "--target", description: "which target"),
                Flag(name: "-v", description: "verbose"),
            ],
            takesPaths: true),
        "make": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-f", description: "file to use as Makefile"),
                Flag(name: "-j", description: "number of parallel jobs"),
                Flag(name: "-B", description: "unconditionally make all targets"),
                Flag(name: "-C", description: "change directory"),
                Flag(name: "-n", description: "dry run"),
                Flag(name: "-s", description: "silent"),
            ],
            takesPaths: true),
        "cmake": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--build", description: "build binary directory"),
                Flag(name: "--install", description: "install project"),
                Flag(name: "-B", description: "build directory"),
                Flag(name: "-S", description: "source directory"),
                Flag(name: "-G", description: "generator name"),
                Flag(name: "-D", description: "create or update cmake cache entry"),
            ],
            takesPaths: true),
        "brew": CommandSignature(
            subcommands: [
                "autoremove", "cleanup", "config", "doctor", "info", "install", "leaves", "list",
                "livecheck", "log", "outdated", "pin", "search", "services", "tap", "unpin",
                "uninstall", "untap", "update", "upgrade", "uses",
            ],
            flags: [
                Flag(name: "--cask", description: "an application"),
                Flag(name: "--formula", description: "a formula"),
                Flag(name: "--verbose", description: "verbose output"),
                Flag(name: "-v", description: "verbose output"),
            ],
            takesPaths: false),
        "curl": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-X", description: "HTTP method"),
                Flag(name: "-H", description: "custom header"),
                Flag(name: "-d", description: "HTTP POST data"),
                Flag(name: "-o", description: "write output to file"),
                Flag(name: "-O", description: "write output to remote file name"),
                Flag(name: "-s", description: "silent mode"),
                Flag(name: "-S", description: "show error when -s is used"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-u", description: "user:password authentication"),
                Flag(name: "-L", description: "follow redirects"),
                Flag(name: "-k", description: "allow insecure SSL connections"),
                Flag(name: "-I", description: "show response headers only"),
            ],
            takesPaths: true),
        "wget": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-O", description: "output file"),
                Flag(name: "-c", description: "continue getting partially-downloaded file"),
                Flag(name: "-q", description: "quiet (no output)"),
                Flag(name: "-r", description: "recursive download"),
            ],
            takesPaths: true),
        "tar": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-c", description: "create archive"),
                Flag(name: "-x", description: "extract archive"),
                Flag(name: "-t", description: "list contents of archive"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-f", description: "archive file name"),
                Flag(name: "-z", description: "filter through gzip"),
                Flag(name: "-j", description: "filter through bzip2"),
                Flag(name: "-C", description: "change directory"),
            ],
            takesPaths: true),
        "ssh": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-i", description: "identity file / private key"),
                Flag(name: "-p", description: "port number"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-N", description: "do not execute a remote command"),
                Flag(name: "-L", description: "local port forward"),
                Flag(name: "-R", description: "remote port forward"),
                Flag(name: "-D", description: "dynamic SOCKS port forward"),
            ],
            takesPaths: true),
        "scp": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-r", description: "recursively copy entire directories"),
                Flag(name: "-P", description: "port number"),
                Flag(name: "-i", description: "identity file"),
                Flag(name: "-C", description: "enable compression"),
                Flag(name: "-v", description: "verbose"),
            ],
            takesPaths: true),
        "rsync": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-a", description: "archive mode"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-z", description: "compress file data during transfer"),
                Flag(name: "-P", description: "show progress during transfer"),
                Flag(name: "--delete", description: "delete extraneous files from dest dirs"),
                Flag(name: "--exclude", description: "exclude files matching pattern"),
                Flag(name: "-n", description: "dry run"),
            ],
            takesPaths: true),
        "find": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-name", description: "match file name pattern"),
                Flag(name: "-iname", description: "case-insensitive pattern match"),
                Flag(name: "-type", description: "file type (f, d, l)"),
                Flag(name: "-maxdepth", description: "descend at most N levels"),
                Flag(name: "-exec", description: "execute command on matched files"),
                Flag(name: "-delete", description: "delete matching files"),
            ],
            takesPaths: true),
        "grep": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--extended-regexp", description: "ERE"),
                Flag(name: "--ignore-case", description: "case insensitive"),
                Flag(name: "--line-number", description: "show line numbers"),
                Flag(name: "--recursive", description: "descend directories"),
                Flag(name: "-i", description: "case insensitive"),
                Flag(name: "-v", description: "invert match"),
                Flag(name: "-n", description: "show line numbers"),
                Flag(name: "-r", description: "descend directories"),
                Flag(name: "-l", description: "files with matches"),
                Flag(name: "-E", description: "extended regex"),
            ],
            takesPaths: true),
        "kill": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-9", description: "SIGKILL"),
                Flag(name: "-15", description: "SIGTERM"),
                Flag(name: "-l", description: "list signal names"),
            ],
            takesPaths: false),
        "ps": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-a", description: "processes of other users too"),
                Flag(name: "-u", description: "user-oriented format"),
                Flag(name: "-x", description: "processes without controlling ttys"),
                Flag(name: "-ef", description: "standard full listing format"),
                Flag(name: "aux", description: "all running processes"),
            ],
            takesPaths: false),
        "top": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-o", description: "order by key (cpu, mem, pid)"),
                Flag(name: "-s", description: "delay interval"),
                Flag(name: "-u", description: "monitor by user"),
            ],
            takesPaths: false),
        "htop": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-d", description: "delay interval in tenths of second"),
                Flag(name: "-u", description: "filter by user name"),
                Flag(name: "-p", description: "show specified PIDs"),
            ],
            takesPaths: false),
        "chmod": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-R", description: "change files and directories recursively"),
                Flag(name: "-v", description: "verbose output"),
                Flag(name: "+x", description: "make executable"),
                Flag(name: "-x", description: "remove execute permission"),
                Flag(name: "755", description: "rwxr-xr-x"),
                Flag(name: "644", description: "rw-r--r--"),
                Flag(name: "600", description: "rw-------"),
            ],
            takesPaths: true),
        "chown": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-R", description: "recursively change ownership"),
                Flag(name: "-v", description: "verbose"),
            ],
            takesPaths: true),
        "cat": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-n", description: "number all output lines"),
                Flag(name: "-b", description: "number non-blank output lines"),
                Flag(name: "-s", description: "squeeze consecutive blank lines"),
            ],
            takesPaths: true),
        "head": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-n", description: "number of lines"),
                Flag(name: "-c", description: "number of bytes"),
            ],
            takesPaths: true),
        "tail": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-f", description: "follow file changes"),
                Flag(name: "-n", description: "number of lines"),
                Flag(name: "-c", description: "number of bytes"),
            ],
            takesPaths: true),
        "env": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-i", description: "start with empty environment"),
                Flag(name: "-u", description: "unset environment variable"),
            ],
            takesPaths: false),
        "export": CommandSignature(subcommands: [], flags: [Flag(name: "-p", description: "print exported variables")], takesPaths: false),
        "source": CommandSignature(subcommands: [], flags: [], takesPaths: true),
        "echo": CommandSignature(subcommands: [], flags: [Flag(name: "-n", description: "do not output trailing newline")], takesPaths: false),
        "which": CommandSignature(subcommands: [], flags: [Flag(name: "-a", description: "list all instances of executables")], takesPaths: false),
        "kubectl": CommandSignature(
            subcommands: [
                "apply", "config", "create", "delete", "describe", "diff", "edit", "exec", "expose",
                "get", "logs", "port-forward", "rollout", "run", "scale", "top", "version",
            ],
            flags: [
                Flag(name: "--all-namespaces", description: "every namespace"),
                Flag(name: "-A", description: "all namespaces"),
                Flag(name: "--context", description: "which cluster"),
                Flag(name: "--namespace", description: "which namespace"),
                Flag(name: "-n", description: "namespace"),
                Flag(name: "--output", description: "output format (yaml, json, wide)"),
                Flag(name: "-o", description: "output format"),
                Flag(name: "--watch", description: "stream changes"),
                Flag(name: "-w", description: "watch"),
            ],
            takesPaths: true),
        "gh": CommandSignature(
            subcommands: [
                "auth", "browse", "cache", "codespace", "gist", "issue", "org", "pr", "project",
                "release", "repo", "run", "search", "secret", "ssh-key", "variable", "workflow",
            ],
            flags: [
                Flag(name: "--help", description: "show help"),
                Flag(name: "--version", description: "show version"),
                Flag(name: "-R", description: "select repository using [HOST/]OWNER/REPO format"),
            ],
            takesPaths: true),
        "aws": CommandSignature(
            subcommands: [
                "s3", "ec2", "lambda", "iam", "sts", "configure", "ecr", "eks", "dynamodb", "sqs", "sns", "rds", "cloudfront",
            ],
            flags: [
                Flag(name: "--profile", description: "AWS CLI profile to use"),
                Flag(name: "--region", description: "AWS region"),
                Flag(name: "--output", description: "output format (json, text, table)"),
            ],
            takesPaths: true),
        "terraform": CommandSignature(
            subcommands: [
                "apply", "destroy", "fmt", "get", "graph", "import", "init", "output", "plan",
                "providers", "refresh", "show", "state", "validate", "version", "workspace",
            ],
            flags: [
                Flag(name: "-auto-approve", description: "skip interactive approval"),
                Flag(name: "-var", description: "set a variable"),
                Flag(name: "-var-file", description: "set variables from an HCL file"),
            ],
            takesPaths: true),
        "gcloud": CommandSignature(
            subcommands: [
                "auth", "compute", "container", "config", "projects", "iam", "logging", "run", "artifacts", "sql", "storage",
            ],
            flags: [
                Flag(name: "--project", description: "Google Cloud project ID"),
                Flag(name: "--account", description: "Google Cloud account"),
                Flag(name: "--format", description: "output format"),
            ],
            takesPaths: true),
        "cd": CommandSignature(subcommands: [], flags: [], takesPaths: true, directoriesOnly: true),
        "ls": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "--all", description: "include dotfiles"),
                Flag(name: "--color", description: "colourise"),
                Flag(name: "--human-readable", description: "sizes people can read"),
                Flag(name: "-a", description: "include dotfiles"),
                Flag(name: "-h", description: "sizes people can read"),
                Flag(name: "-l", description: "long format"),
                Flag(name: "-t", description: "sort by modification time"),
                Flag(name: "-r", description: "reverse sort"),
                Flag(name: "-R", description: "recursive list"),
                Flag(name: "-1", description: "one file per line"),
            ],
            takesPaths: true),
        "mkdir": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-p", description: "create intermediate parent directories"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-m", description: "set file mode permissions"),
            ],
            takesPaths: true,
            directoriesOnly: true),
        "rmdir": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-p", description: "remove directory and its ancestors"),
            ],
            takesPaths: true,
            directoriesOnly: true),
        "rm": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-r", description: "remove directories and their contents recursively"),
                Flag(name: "-R", description: "recursive remove"),
                Flag(name: "-f", description: "ignore nonexistent files, force"),
                Flag(name: "-rf", description: "force recursive remove"),
                Flag(name: "-i", description: "prompt before every removal"),
                Flag(name: "-v", description: "verbose"),
            ],
            takesPaths: true),
        "cp": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-r", description: "copy directories recursively"),
                Flag(name: "-R", description: "copy directories recursively"),
                Flag(name: "-f", description: "force copy"),
                Flag(name: "-i", description: "prompt before overwrite"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-p", description: "preserve attributes"),
            ],
            takesPaths: true),
        "mv": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-f", description: "force overwrite without prompt"),
                Flag(name: "-i", description: "prompt before overwrite"),
                Flag(name: "-v", description: "verbose"),
                Flag(name: "-n", description: "do not overwrite existing file"),
            ],
            takesPaths: true),
        "touch": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-a", description: "change access time"),
                Flag(name: "-m", description: "change modification time"),
                Flag(name: "-c", description: "do not create any files"),
            ],
            takesPaths: true),
        "man": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-k", description: "apropos keyword search"),
                Flag(name: "-f", description: "whatis equivalent"),
                Flag(name: "-a", description: "display all matches"),
            ],
            takesPaths: false),
        "open": CommandSignature(
            subcommands: [],
            flags: [
                Flag(name: "-a", description: "specify application to open with"),
                Flag(name: "-e", description: "open with TextEdit"),
                Flag(name: "-R", description: "reveal in Finder"),
                Flag(name: "-g", description: "do not bring app to foreground"),
                Flag(name: "-n", description: "open new instance of the application"),
            ],
            takesPaths: true),
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
        if !before.contains(where: { !$0.isWhitespace }) {
            if word.contains("/") || word.hasPrefix("~") {
                return rank(pathCandidates(prefix: word), query: word)
            }
            var candidates = commandCandidates(prefix: word)
            if !word.isEmpty {
                for hist in history {
                    if let _ = FuzzyMatcher.match(text: hist, pattern: word), hist != word {
                        candidates.append(CompletionCandidate(text: hist, kind: .history, description: "history"))
                    }
                }
            }
            return rank(candidates, query: word)
        }

        guard let command = firstWord(characters) else { return [] }
        if word.hasPrefix("-") {
            return rank(flagCandidates(command: command, prefix: word), query: word)
        }

        var candidates = subcommandCandidates(command: command, prefix: word)
        if signatures[command]?.takesPaths ?? true {
            candidates += pathCandidates(prefix: word, command: command)
        }

        // Include matching historical lines
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            for hist in history {
                if let _ = FuzzyMatcher.match(text: hist, pattern: trimmed), hist != trimmed {
                    candidates.append(CompletionCandidate(text: hist, kind: .history, description: "history"))
                }
            }
        }

        return rank(candidates, query: word)
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
        candidates += commands.map {
            CompletionCandidate(text: $0, kind: .command, description: nil)
        }
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

    private func pathCandidates(prefix: String, command: String? = nil) -> [CompletionCandidate] {
        let isDirectoriesOnly = command.flatMap { signatures[$0]?.directoriesOnly } ?? false
        let split = prefix.lastIndex(of: "/")
        let directoryPart = split.map { String(prefix[prefix.startIndex...$0]) } ?? ""
        let namePart = split.map { String(prefix[prefix.index(after: $0)...]) } ?? prefix

        let absolute = absoluteDirectory(for: directoryPart)
        let wanted = namePart.replacingOccurrences(of: "\\", with: "")

        let entries = listDirectory(absolute)
        return entries.compactMap { entry in
            if isDirectoriesOnly && !entry.isDirectory { return nil }

            // Dotfile rule: only show hidden files if user explicitly typed a leading dot
            if !wanted.hasPrefix(".") && entry.name.hasPrefix(".") {
                return nil
            }

            if !wanted.isEmpty {
                let matches = entry.name.hasPrefix(wanted)
                guard matches else { return nil }
            }

            let suffix = entry.isDirectory ? "/" : ""
            let displayText = directoryPart + entry.name + suffix
            let insertionText = directoryPart + Self.shellEscaped(entry.name) + suffix

            return CompletionCandidate(
                text: displayText,
                kind: .path,
                description: entry.isDirectory ? "directory" : nil,
                insertion: insertionText)
        }
    }

    /// A file name as the shell needs to receive it.
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

    /// Ranks candidates using FuzzyMatcher scores, deduplicating on text.
    private func rank(_ candidates: [CompletionCandidate], query: String) -> [CompletionCandidate] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.text).inserted }
        guard !query.isEmpty else { return unique }

        let scored = unique.compactMap { candidate -> (candidate: CompletionCandidate, score: Int)? in
            let text = candidate.text
            let insertion = candidate.insertion ?? ""

            // Prefix match gets highest score
            if text.lowercased().hasPrefix(query.lowercased()) {
                return (candidate, 1000 - text.count)
            }
            if !insertion.isEmpty && insertion.lowercased().hasPrefix(query.lowercased()) {
                return (candidate, 900 - insertion.count)
            }

            // Subsequence fuzzy match score
            if let res = FuzzyMatcher.match(text: text, pattern: query) {
                return (candidate, res.score)
            }
            if !insertion.isEmpty, let res = FuzzyMatcher.match(text: insertion, pattern: query) {
                return (candidate, res.score)
            }

            return nil
        }

        return scored
            .sorted { a, b in
                if a.score != b.score {
                    return a.score > b.score
                }
                return a.candidate.text.count < b.candidate.text.count
            }
            .map { $0.candidate }
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
