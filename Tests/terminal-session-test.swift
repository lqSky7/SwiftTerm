import Foundation

/// Guards the two things that can only be wrong at runtime: that a shell really comes up on a
/// pseudo-terminal and reports what it prints, and that the integration scripts we write are
/// valid in the shells they claim to be written for.
///
/// The shells are started in a scratch directory with a minimal environment so the harness never
/// touches the user's own dotfiles, history or working tree.
@main
@MainActor
enum TerminalSessionTest {
    static func main() async {
        let harness = Harness("terminal-session-test")

        await interactiveShell(harness)
        await terminalReporting(harness)
        await resizing(harness)
        await blockLifecycle(harness)
        shellDetection(harness)
        await bootstrapLayout(harness)
        await integrationScriptsParse(harness)

        harness.finish()
    }

    // MARK: - A real shell

    private static func scratchEnvironment(
        shell: String = "/bin/sh"
    ) -> (environment: [String: String], directory: String) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swiftterm-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            ["SHELL": shell, "PATH": "/bin:/usr/bin:/usr/local/bin", "HOME": directory.path],
            directory.path
        )
    }

    /// `/bin/sh` is not zsh, bash or fish, so the session starts it with no integration at all —
    /// which is exactly the plainest thing to assert a round trip against.
    private static func interactiveShell(_ harness: Harness) async {
        let (environment, directory) = scratchEnvironment()
        guard let session = try? TerminalSession(
            size: TerminalSize(columns: 80, rows: 24), environment: environment,
            homeDirectory: directory)
        else {
            harness.expect(false, "a shell started on a pseudo-terminal")
            return
        }
        harness.equal(session.shellType, .other, "an unrecognised shell is still a shell")

        session.write("echo swiftterm-probe\n")
        let echoed = await waitForText("swiftterm-probe", in: session)
        harness.expect(echoed, "the shell's output reached the grid")

        session.write("printf 'RESULT-%s\\n' 42\n")
        let computed = await waitForText("RESULT-42", in: session)
        harness.expect(computed, "a second command ran on the same session")

        session.stop()
    }

    /// A program that drives the screen with escape sequences must end up with a screen, not a
    /// transcript, and the terminal's answers have to travel back down the pty. Both are checked
    /// here by asking the shell to report the length of the cursor report it received: the report
    /// for row 3 column 5 is exactly six bytes, so a wrong cursor or a missing reply both show up
    /// as a different number.
    private static func terminalReporting(_ harness: Harness) async {
        let (environment, directory) = scratchEnvironment()
        guard let session = try? TerminalSession(
            size: TerminalSize(columns: 20, rows: 4), environment: environment,
            homeDirectory: directory)
        else {
            harness.expect(false, "a shell started")
            return
        }

        // Canonical mode will not hand the reply over until a newline arrives, so the harness sends
        // one. Echo is switched off around the read so the reply is not also printed twice.
        session.write(
            "printf '\\033[3;5H'; printf '\\033[6n'; stty -echo; read -r reply; "
                + "stty echo; echo \"LEN${#reply}\"\n")

        // The echo of the line is the signal that the shell has read it and is running it.
        _ = await waitForText("LEN${#reply}", in: session)
        try? await Task.sleep(for: .milliseconds(400))
        session.write("\n")

        let reported = await waitForText("LEN6", in: session)
        harness.expect(reported, "the terminal's cursor report reached the shell intact")

        session.stop()
    }

    private static func resizing(_ harness: Harness) async {
        let (environment, directory) = scratchEnvironment()
        guard let session = try? TerminalSession(
            size: TerminalSize(columns: 80, rows: 24), environment: environment,
            homeDirectory: directory)
        else {
            harness.expect(false, "a shell started")
            return
        }

        session.write("stty size\n")
        let before = await waitForText("24 80", in: session)
        harness.expect(before, "the shell sees the size it was started with")

        session.resize(columns: 100, rows: 30)
        harness.equal(session.size.columns, 100, "the session took the new width at once")
        harness.equal(session.size.rows, 30, "and the new height")

        // **The program is told a moment later, on purpose.** A live drag is dozens of sizes and every `TIOCSWINSZ`
        // raises `SIGWINCH`, so the signal waits for the size to settle — which is what stops `opencode` repainting
        // its whole screen once per mouse event. The grid above is already right; only the kernel waits.
        try? await Task.sleep(for: .milliseconds(250))

        session.write("stty size\n")
        let after = await waitForText("30 100", in: session)
        harness.expect(after, "and the shell was told, once the size stopped moving")

        session.stop()
    }

    /// Wait for the shell to report its own `PATH`, which its prompt hook does once per prompt.
    private static func waitForSearchPath(
        in session: TerminalSession, timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let path = session.searchPath, !path.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// The whole of Phase 2 in one test: a real zsh, our real integration scripts, and the prompt
    /// markers arriving over a real pty. Everything below this line is stubbed in the other
    /// harnesses, so if the boundaries are wrong anywhere this is where it shows.
    private static func blockLifecycle(_ harness: Harness) async {
        let (environment, directory) = scratchEnvironment(shell: "/bin/zsh")
        guard let session = try? TerminalSession(
            size: TerminalSize(columns: 80, rows: 24), environment: environment,
            homeDirectory: directory)
        else {
            harness.expect(false, "zsh started on a pseudo-terminal")
            return
        }
        harness.equal(session.shellType, .zsh, "the shell was recognised")

        // **The shell's own `PATH`, end to end against a real zsh** — the integration script emits `OSC 9282`, the
        // parser recognises it, the session keeps it. This is the one assertion that covers the whole chain, and it
        // is the one that matters: the app's environment is launchd's when it is opened from the Finder, so
        // completion and resolution cannot use it.
        harness.expect(
            await waitForSearchPath(in: session, timeout: 8),
            "the shell reported its own PATH over OSC 9282")
        harness.expect(
            session.searchPath?.contains("/") == true,
            "and what arrived is a PATH rather than an empty report")

        session.write("echo BLOCKPROBE-$((6*7))\n")
        harness.expect(
            await waitForText("BLOCKPROBE-42", in: session),
            "the command ran and its output reached the grid")

        // The markers ride along with the output, so the block list catches up a beat later.
        harness.expect(
            await waitForSealedBlock(in: session, timeout: 8),
            "the prompt cycle sealed a block")

        let sealed = session.blocks.filter(\.isSealed)
        harness.expect(sealed.count >= 1, "at least one block was sealed")
        guard let block = sealed.first(where: { ($0.command ?? "").contains("BLOCKPROBE") }) else {
            harness.expect(false, "a sealed block names the command the shell reported")
            session.stop()
            return
        }
        harness.equal(block.exitCode, 0, "and carries its exit code")
        harness.equal(block.didSucceed, true, "which reads as success")
        harness.expect(
            session.commandText(for: block)?.contains("BLOCKPROBE") == true,
            "the header has a command to show")
        harness.expect(
            session.outputText(for: block).contains("BLOCKPROBE-42"),
            "and the block owns the output it produced")
        harness.expect(
            block.outputGrid.grid.screenContains("BLOCKPROBE-42"),
            "in its own grid, not in a sequence shared with every other block")
        harness.expect(block.lineCount > 0, "so it claims at least one line")

        session.stop()
    }

    private static func shellDetection(_ harness: Harness) {
        harness.equal(ShellType(executablePath: "/bin/zsh"), .zsh, "a plain zsh path")
        harness.equal(ShellType(executablePath: "/opt/homebrew/bin/zsh-5.9"), .zsh, "a versioned zsh")
        harness.equal(ShellType(executablePath: "/usr/local/bin/bash"), .bash, "bash is recognised")
        harness.equal(ShellType(executablePath: "/opt/homebrew/bin/fish"), .fish, "fish is recognised")
        harness.equal(ShellType(executablePath: "/bin/dash"), .other, "an unknown shell is other")

        let resolved = ShellBootstrap.resolveShellPath(environment: ["SHELL": "/bin/sh"])
        harness.equal(resolved, "/bin/sh", "$SHELL wins when it names something real")
        harness.equal(
            ShellBootstrap.resolveShellPath(environment: ["SHELL": "/nowhere/nope"]), "/bin/zsh",
            "and falls back to the shell macOS ships")
        harness.equal(
            ShellBootstrap.resolveShellPath(environment: [:]), "/bin/zsh",
            "an unset SHELL falls back too")
    }

    private static func bootstrapLayout(_ harness: Harness) async {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "swiftterm-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let environment = ["HOME": "/Users/example", "PATH": "/usr/bin", "ZDOTDIR": "/Users/example/config"]
        let zsh = try? ShellBootstrap.prepare(
            shellPath: "/bin/zsh", environment: environment, homeDirectory: "/Users/example",
            baseDirectory: base)
        guard let zsh, let directory = zsh.rcDirectory else {
            harness.expect(false, "the zsh bootstrap was written")
            return
        }
        harness.equal(zsh.arguments, ["-l", "-i"], "zsh starts as a login shell")
        harness.equal(zsh.environment["ZDOTDIR"], directory.path, "ZDOTDIR points at the generated files")
        harness.equal(
            zsh.environment["SWIFTTERM_USER_ZDOTDIR"], "/Users/example/config",
            "the user's original ZDOTDIR is remembered, not overwritten")
        harness.equal(zsh.environment["TERM"], "xterm-256color", "TERM is set for a modern terminal")
        harness.equal(zsh.environment["COLORTERM"], "truecolor", "and so is COLORTERM")

        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        for expected in ["integration.zsh", ".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            harness.expect(names.contains(expected), "\(expected) was written")
        }

        let zshrc = (try? String(contentsOf: directory.appending(path: ".zshrc"), encoding: .utf8)) ?? ""
        harness.expect(zshrc.contains("SWIFTTERM_USER_ZDOTDIR"), "the shim sources the user's own zshrc")
        harness.expect(zshrc.contains("SWIFTTERM_INTEGRATION"), "and then the integration")

        let bash = try? ShellBootstrap.prepare(
            shellPath: "/bin/bash", environment: environment, homeDirectory: "/Users/example",
            baseDirectory: base)
        harness.equal(
            bash?.arguments.first, "--rcfile", "bash is pointed at the generated rcfile")
        harness.equal(
            bash?.environment["ZDOTDIR"], "/Users/example/config",
            "bash keeps the ZDOTDIR it was handed, because bash never reads it")

        // `--rcfile` *replaces* the user's rc, so the generated one has to source it back. zsh gets
        // this for free because its dotfiles are shimmed rather than replaced; bash loses aliases,
        // PATH additions and the whole prompt without this line.
        let bashrc = (try? String(contentsOf: directory.appending(path: "integration.bash"), encoding: .utf8)) ?? ""
        harness.expect(bashrc.contains("\"$HOME/.bashrc\""), "the generated rc sources the user's bashrc")
        harness.expect(bashrc.contains("\"$HOME/.bash_profile\""), "and falls back to bash_profile")
        harness.expect(
            (bashrc.range(of: "$HOME/.bashrc")?.lowerBound ?? bashrc.endIndex)
                < (bashrc.range(of: "PS1=''")?.lowerBound ?? bashrc.startIndex),
            "before suppressing the prompt, so the user's own is loaded and then replaced")

        let fish = try? ShellBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/fish", environment: environment,
            homeDirectory: "/Users/example", baseDirectory: base)
        harness.equal(fish?.arguments.first, "-i", "fish starts interactive")
        harness.expect(
            fish?.arguments.last?.hasPrefix("source ") == true,
            "and is told to source the integration")

        let other = try? ShellBootstrap.prepare(
            shellPath: "/bin/dash", environment: environment, homeDirectory: "/Users/example",
            baseDirectory: base)
        harness.equal(other?.rcDirectory, nil, "an unknown shell gets no integration")
        harness.equal(other?.hasIntegration, false, "and says so")
        harness.equal(other?.arguments, ["-i"], "but still starts interactive")
    }

    /// The scripts are strings until a shell reads them. Running each one through its own shell is
    /// the only thing that proves the quoting, the `printf` escapes and the hook names are real.
    private static func integrationScriptsParse(_ harness: Harness) async {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "swiftterm-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let environment = ["HOME": base.path, "PATH": "/bin:/usr/bin"]

        for (shellPath, shellName, extra) in [
            ("/bin/zsh", "zsh", ["-f"]),
            ("/bin/bash", "bash", ["--noprofile", "--norc"]),
        ] {
            guard let bootstrap = try? ShellBootstrap.prepare(
                shellPath: shellPath, environment: environment, homeDirectory: base.path,
                baseDirectory: base),
                let directory = bootstrap.rcDirectory
            else {
                harness.expect(false, "the \(shellName) bootstrap was written")
                continue
            }
            let script = directory.appending(path: shellName == "zsh" ? "integration.zsh" : "integration.bash")
            let result = runShell(shellPath, arguments: extra + ["-c", "source \(script.path); echo LOADED"])

            harness.equal(result.status, 0, "\(shellName) sourced the integration without erroring")
            harness.expect(result.output.contains("LOADED"), "\(shellName) ran the whole script")
            harness.expect(
                result.output.contains("\u{1B}]133;A\u{07}"),
                "\(shellName) emitted the prompt-start marker")
        }
    }

    // MARK: - Helpers

    /// Waits for the session to catch up. The read loop runs on the main actor too, so yielding is
    /// all it takes for the output to arrive.
    ///
    /// Searches every block's grids rather than one shared grid, because that is now where output
    /// lives: by the time a poll runs, the command that printed this may have finished and its block
    /// been sealed, with the parser already writing the next prompt into a different grid.
    @MainActor
    private static func waitForText(
        _ needle: String, in session: TerminalSession, timeout: Double = 8
    ) async -> Bool {
        await poll(timeout: timeout) {
            session.blocks.contains { block in
                block.grids.contains { $0.grid.screenContains(needle) }
            }
        }
    }

    @MainActor
    private static func waitForSealedBlock(
        in session: TerminalSession, timeout: Double = 8
    ) async -> Bool {
        await poll(timeout: timeout) { session.blocks.contains { $0.isSealed } }
    }

    /// Polls rather than awaiting a notification, because what is being waited for is the *absence*
    /// of a thing: there is no event that says the shell has stopped printing.
    @MainActor
    private static func poll(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func runShell(
        _ executable: String, arguments: [String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not launch \(executable)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }
}
