import Foundation

/// Puts the terminal's shell integration in front of the user's shell without touching a file the
/// user owns.
///
/// zsh reads its dotfiles out of `$ZDOTDIR`, so pointing `ZDOTDIR` at a generated directory and
/// putting a one-line shim in front of each real dotfile is the only way to add hooks without
/// editing anything of theirs. bash has `--rcfile` and fish has `--init-command`, which are the
/// same idea spelled as flags.
struct ShellBootstrap {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    /// Where the integration was written, or nil when this shell gets none.
    let rcDirectory: URL?

    var hasIntegration: Bool { rcDirectory != nil }

    /// Reported to the shell as `TERM_PROGRAM_VERSION`, which is how a program tells which
    /// terminal it is talking to.
    static let version = "0.1.0"

    static let integrationDirectoryName = "swiftterm-shell-integration"

    /// `$SHELL` when it names something executable, else `/bin/zsh` — the shell macOS ships and
    /// the one a user is running unless they changed it.
    static func resolveShellPath(
        environment: [String: String], fileManager: FileManager = .default
    ) -> String {
        if let shell = environment["SHELL"], fileManager.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// Writes the integration and returns the argv and environment that make the shell load it.
    /// Throws only on a filesystem failure; the caller is expected to fall back to a plain shell
    /// rather than refuse to start.
    static func prepare(
        shellPath: String,
        environment: [String: String],
        homeDirectory: String,
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ShellBootstrap {
        let shell = ShellType(executablePath: shellPath)
        var environment = environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "swiftTerm"
        environment["TERM_PROGRAM_VERSION"] = version
        environment["SWIFTTERM"] = "1"

        guard shell != .other else {
            return ShellBootstrap(
                executable: shellPath, arguments: ["-i"], environment: environment, rcDirectory: nil)
        }

        // A stable directory rather than a per-launch one: nothing in these files depends on the
        // session — every session-specific fact travels in the environment — so one directory is
        // correct and does not leave a trail of temp directories behind.
        let directory = (baseDirectory ?? fileManager.temporaryDirectory)
            .appending(path: integrationDirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // zsh resolves its dotfiles through ZDOTDIR — except `directory` is a *stable* path, so a pane
        // launched from inside an already-bootstrapped swiftTerm shell inherits ZDOTDIR pointed at us,
        // not the user, and would have the shim source itself until it runs out of file handles. The
        // parent session's own resolved answer, SWIFTTERM_USER_ZDOTDIR, is authoritative in that case.
        let inheritedZDOTDIR = environment["ZDOTDIR"]
        let userDirectory: String
        switch (shell, inheritedZDOTDIR) {
        case (.zsh, .some(let zdotdir)) where zdotdir != directory.path:
            userDirectory = zdotdir
        case (.zsh, _):
            userDirectory = environment["SWIFTTERM_USER_ZDOTDIR"] ?? homeDirectory
        default:
            userDirectory = homeDirectory
        }
        environment["SWIFTTERM_USER_ZDOTDIR"] = userDirectory
        environment["SWIFTTERM_BOOTSTRAP_ZDOTDIR"] = directory.path
        environment["SWIFTTERM_INTEGRATION"] = directory.appending(path: integrationFileName(for: shell)).path

        try install(shell: shell, into: directory, fileManager: fileManager)
        if shell == .zsh { environment["ZDOTDIR"] = directory.path }

        return ShellBootstrap(
            executable: shellPath,
            arguments: launchArguments(for: shell, directory: directory),
            environment: environment,
            rcDirectory: directory)
    }

    // MARK: - Installation

    private static func integrationFileName(for shell: ShellType) -> String {
        switch shell {
        case .zsh: return "integration.zsh"
        case .bash: return "integration.bash"
        case .fish: return "integration.fish"
        case .other: return ""
        }
    }

    private static func launchArguments(for shell: ShellType, directory: URL) -> [String] {
        switch shell {
        case .zsh:
            return ["-l", "-i"]
        case .bash:
            return ["--rcfile", directory.appending(path: "integration.bash").path, "-i"]
        case .fish:
            return ["-i", "-C", "source \(directory.appending(path: "integration.fish").path)"]
        case .other:
            return ["-i"]
        }
    }

    private static func install(
        shell: ShellType, into directory: URL, fileManager: FileManager
    ) throws {
        func write(_ contents: String, to name: String) throws {
            try contents.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }

        switch shell {
        case .zsh:
            for name in ShellType.zshDotFileNames {
                var shim = chainedDotFileShim(named: name)
                if name == ".zshrc" { shim += "\n" + integrationSource }
                try write(shim, to: name)
            }
            try write(zshIntegration, to: "integration.zsh")
        case .bash:
            try write(bashIntegration, to: "integration.bash")
        case .fish:
            try write(fishIntegration, to: "integration.fish")
        case .other:
            break
        }
    }

    /// Reads the user's own copy of a dotfile, with `ZDOTDIR` pointed back at them while it runs so
    /// anything inside that resolves through `ZDOTDIR` still finds their files.
    private static func chainedDotFileShim(named name: String) -> String {
        #"""
        if [[ -n "$SWIFTTERM_USER_ZDOTDIR" && -f "$SWIFTTERM_USER_ZDOTDIR/\#(name)" ]]; then
          ZDOTDIR="$SWIFTTERM_USER_ZDOTDIR"
          source "$ZDOTDIR/\#(name)"
          ZDOTDIR="$SWIFTTERM_BOOTSTRAP_ZDOTDIR"
        fi
        """#
    }

    private static let integrationSource =
        #"[[ -n "$SWIFTTERM_INTEGRATION" ]] && source "$SWIFTTERM_INTEGRATION""#

    // MARK: - The integration scripts

    /// `OSC 133` is the marker protocol iTerm2, VS Code and Warp's own shell scripts all speak, so
    /// these hooks are the same four reports everywhere. `A` and `B` are emitted together: the
    /// prompt text follows them and the command line ends at `C`, which is the region a block
    /// needs. Splitting them needs a zle widget and nothing consumes the split yet.
    private static let zshIntegration = #"""
    # swiftTerm shell integration for zsh. Written by the terminal at launch; do not edit.

    __swiftterm_report_prompt() {
      local __swiftterm_status=$?
      printf '\e]133;D;%d\a' "$__swiftterm_status"
      printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
      # The shell's own PATH, so completion and resolution are against the commands *this shell* can run.
      printf '\e]9282;%s\a' "$PATH"
      printf '\e]133;A\a\e]133;B\a'
    }

    __swiftterm_report_preexec() {
      printf '\e]9281;%s\a' "$1"
      printf '\e]133;C\a'
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __swiftterm_report_prompt
    add-zsh-hook preexec __swiftterm_report_preexec

    # The terminal draws the prompt's context itself, as chips above the input, so the shell's own
    # prompt is suppressed. That is what Warp does, and it is what puts the command at the left margin
    # instead of in the middle of the line. The directory is not lost with it: it arrives over OSC 7.
    PROMPT=''
    RPROMPT=''
    PROMPT2=''

    printf '\e]133;A\a\e]133;B\a'
    """#

    /// bash has no `precmd`, so `PROMPT_COMMAND` is the prompt hook and a `DEBUG` trap stands in
    /// for `preexec`. The trap fires before every simple command including the prompt hook itself,
    /// so the arming flag is what keeps `C` to the first command after a prompt.
    private static let bashIntegration = #"""
    # swiftTerm shell integration for bash. Written by the terminal at launch; do not edit.

    # The terminal replaces bash's own rc file, so the user's is sourced here. Without this a bash
    # user loses every alias, PATH addition and prompt setting they own, which is not a thing a
    # terminal gets to do — and zsh gets it for free, because its dotfiles are shimmed rather than
    # replaced.
    if [[ -f "$HOME/.bashrc" ]]; then
      source "$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
      source "$HOME/.bash_profile"
    fi

    __swiftterm_armed=0

    __swiftterm_report_prompt() {
      local __swiftterm_status=$?
      __swiftterm_armed=1
      printf '\e]133;D;%d\a' "$__swiftterm_status"
      printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
      # The shell's own PATH — see the zsh integration for why this is reported rather than assumed.
      printf '\e]9282;%s\a' "$PATH"
      printf '\e]133;A\a\e]133;B\a'
    }

    __swiftterm_report_preexec() {
      (( __swiftterm_armed )) || return
      __swiftterm_armed=0
      printf '\e]9281;%s\a' "$BASH_COMMAND"
      printf '\e]133;C\a'
    }

    trap '__swiftterm_report_preexec' DEBUG
    PROMPT_COMMAND="__swiftterm_report_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

    # The terminal draws the prompt's context itself, as chips above the input; see the zsh script.
    PS1=''
    PS2=''

    printf '\e]133;A\a\e]133;B\a'
    """#

    private static let fishIntegration = #"""
    # swiftTerm shell integration for fish. Written by the terminal at launch; do not edit.

    function __swiftterm_report_prompt --on-event fish_prompt
      printf '\e]7;file://%s%s\a' (hostname) "$PWD"
      # The shell's own PATH — see the zsh integration for why this is reported rather than assumed.
      printf '\e]9282;%s\a' "$PATH"
      printf '\e]133;A\a\e]133;B\a'
    end

    function __swiftterm_report_preexec --on-event fish_preexec
      printf '\e]9281;%s\a' "$argv"
      printf '\e]133;C\a'
    end

    function __swiftterm_report_postexec --on-event fish_postexec
      printf '\e]133;D;%d\a' $status
    end

    # The terminal draws the prompt's context itself, as chips above the input; see the zsh script.
    function fish_prompt
    end
    """#
}
