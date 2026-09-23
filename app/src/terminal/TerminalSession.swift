import Foundation

/// One shell on one pseudo-terminal, the blocks its output is divided into, and the grid the shell
/// is writing into right now.
///
/// Reading is blocking, so it happens off the main actor and hands chunks back through a stream.
/// Everything else — parsing, grid mutation, block boundaries, events — stays on the main actor.
/// That is the whole concurrency design: one actor owns the mutable grids, so there is no lock and
/// no second actor to reason about.
@MainActor
final class TerminalSession {
    enum Failure: Error {
        case couldNotStartShell(String)
    }

    let shellType: ShellType

    /// Reported upward: everything the parser learned that is not a screen change.
    var onEvent: ((TerminalEvent) -> Void)?
    /// Something on the screen changed. The renderer decides what that means.
    var onUpdate: (() -> Void)?
    /// The shell exited, with the status a shell would report.
    var onExit: ((Int32) -> Void)?

    private(set) var workingDirectory: String?
    private(set) var title: String?
    private(set) var blockList: BlockList

    /// The grid the shell is writing into: the active block's output grid once its command has been
    /// submitted, and its prompt-and-command grid before that.
    ///
    /// Stored rather than computed so it can never be nil — a session always has one block, so this
    /// is always a real grid — and always moved by `routeToActiveGrid()` so it cannot drift away from
    /// the block list.
    private(set) var activeGrid: TerminalGrid

    private let terminal: PseudoTerminal
    private let parser: VTParser
    private var readTask: Task<Void, Never>?
    private var hasStopped = false
    /// The command the shell reported, held until the marker that says it is running arrives.
    private var reportedCommand: String?

    var size: TerminalSize { blockList.size }
    var blocks: [Block] { blockList.blocks }
    var activeBlock: Block? { blockList.activeBlock }

    /// Whether a full-screen program is running. It runs in the block that started it, so this is
    /// that block's output grid's own mode rather than a session-wide flag.
    var isAlternateScreen: Bool { blockList.activeBlock?.isAlternateScreen ?? false }

    /// Whether a command is running. See `BlockList.isRunningCommand`.
    var isRunningCommand: Bool { blockList.isRunningCommand }

    /// Whether the **shell's** cursor is the one to show, leaving aside who has the keyboard.
    ///
    /// The model half of `TerminalSurfaceView.shouldDrawGridCursor`, and it lives here so a harness can hold it: the
    /// view adds "does this view have the keyboard", and everything else is a fact about the session.
    ///
    /// Two states where the shell's cursor is right, and one where it never is:
    ///
    /// - A full-screen program is running. `nano` and `opencode` draw their own cursor and expect the terminal to show
    ///   it, in the shape they asked for with `DECSCUSR`.
    /// - The shell has never reported a prompt, so there is no integration and the grid *is* the prompt. Hiding the
    ///   cursor there would leave a terminal with no cursor at all.
    /// - **A command that is running.** It is not waiting for input, and the cursor the shell left at the end of its
    ///   output is noise. This is the block cursor that used to flash over `Building for production.` for as long as a
    ///   build took.
    var showsShellCursor: Bool {
        if isAlternateScreen { return true }
        if isRunningCommand { return false }
        return !blocks.contains { $0.headerGrid.promptEnd != nil }
    }

    /// The `PATH` the shell last reported, or nil before it has reported one.
    ///
    /// The **shell's**, not the app's. Opened from the Finder the app inherits launchd's
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so a command installed by Homebrew is neither resolved nor offered by
    /// completion — and the shell the user is actually typing into can run it perfectly well.
    private(set) var searchPath: String?

    /// Where the history is kept between sessions.
    ///
    /// A settable property rather than an `init` parameter: the session is created in exactly one place, and a
    /// harness that wants a scratch file can assign this immediately after construction — before any command has
    /// run, so before `history` has been loaded.
    var historyStore = CommandHistoryStore()

    /// The home directory the shell was started in. Kept because the shell's own history file is found relative to
    /// it, and a harness starts its shells in a scratch home rather than the real one.
    private let homeDirectory: String

    /// The commands run across every session, oldest first. Loaded on first use.
    ///
    /// **The shell's own history file first, then this app's.** The shell has been keeping a history for years and
    /// this app started yesterday: reading the shell's is what makes ↑ useful on the very first prompt of a fresh
    /// install, and it is what Warp does. Our file is merged in after it, so a command run in a shell that reports
    /// nothing is still remembered — and a command in both is deduplicated.
    private(set) lazy var history: CommandHistory = {
        var merged = CommandHistory(entries: ShellHistoryFile.read(at: shellHistoryURL))
        for command in historyStore.load().entries { merged.record(command) }
        return merged
    }()

    /// Where the shell keeps its own history, by convention for the shell that was started.
    private var shellHistoryURL: URL {
        ShellHistoryFile.defaultURL(for: shellType, home: homeDirectory)
    }

    init(
        size: TerminalSize,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws {
        let shellPath = ShellBootstrap.resolveShellPath(environment: environment, fileManager: fileManager)
        let bootstrap = Self.makeBootstrap(
            shellPath: shellPath, environment: environment, homeDirectory: homeDirectory,
            fileManager: fileManager)

        let size = size.normalized
        guard let terminal = PseudoTerminal.spawn(
            executable: bootstrap.executable,
            arguments: bootstrap.arguments,
            environment: bootstrap.environment,
            workingDirectory: homeDirectory,
            size: size)
        else {
            throw Failure.couldNotStartShell(shellPath)
        }

        self.terminal = terminal
        self.shellType = ShellType(executablePath: bootstrap.executable)
        self.workingDirectory = homeDirectory
        self.homeDirectory = homeDirectory
        // A shell with no integration reports no boundaries, so it gets one block that never closes
        // and renders exactly as it did before blocks existed.
        var blockList = BlockList(size: size)
        blockList.begin(at: Date(), workingDirectory: homeDirectory)
        self.blockList = blockList
        // The grid the shell is writing into is the *last* one the block draws: the prompt while it is
        // being typed, the output once the command has run.
        self.activeGrid = blockList.activeBlock?.contentGrids.last?.grid ?? TerminalGrid(size: size)
        self.parser = VTParser(grid: activeGrid)
        start()
    }

    deinit {
        readTask?.cancel()
    }

    /// A shell with no prompt markers is still a usable shell, so a filesystem failure while writing
    /// the integration degrades rather than refuses to start.
    private static func makeBootstrap(
        shellPath: String, environment: [String: String], homeDirectory: String,
        fileManager: FileManager
    ) -> ShellBootstrap {
        do {
            return try ShellBootstrap.prepare(
                shellPath: shellPath, environment: environment, homeDirectory: homeDirectory,
                fileManager: fileManager)
        } catch {
            return ShellBootstrap(
                executable: shellPath, arguments: ["-i"], environment: environment, rcDirectory: nil)
        }
    }

    // MARK: - Driving the shell

    func write(_ bytes: [UInt8]) {
        terminal.write(bytes)
    }

    func write(_ text: String) {
        terminal.write(text)
    }

    /// Reflows every block's grids and tells the kernel, in that order: a full-screen program redraws
    /// as soon as it hears about the new size, and it must not redraw into a grid still holding the
    /// old one.
    ///
    /// One entry point for both a window resize and a font change, because a program that draws
    /// pixels cares about the second as much as the first.
    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let cellCountChanged = columns != size.columns || rows != size.rows
        guard cellCountChanged || cellWidth != size.cellWidth || cellHeight != size.cellHeight else {
            return
        }
        blockList.setCellGeometry(width: cellWidth, height: cellHeight)
        if cellCountChanged { blockList.resize(columns: columns, rows: rows) }
        // **The grid is resized now; the program is told once the size stops moving.** See `scheduleTerminalResize`.
        scheduleTerminalResize()
        onUpdate?()
    }

    /// How long the size has to hold still before the program is told about it.
    ///
    /// **A live drag is dozens of sizes, and a full-screen program redraws its whole screen on every one.** Every
    /// `TIOCSWINSZ` raises `SIGWINCH`, so dragging the sidebar past `opencode` made it repaint once per mouse event
    /// — which is what "behaves very weird when changing sidebar size" is. Warp throttles its resize the same way.
    ///
    /// The *grid* is resized immediately, because the view has to be right on the frame it is drawn; only the
    /// signal to the program waits. Eighty milliseconds is below the threshold where a one-off resize feels late
    /// and above the gap between two mouse events in a drag.
    private static let resizeSettleInterval: TimeInterval = 0.08
    private var pendingResize: DispatchWorkItem?

    /// Tell the kernel the new size, once it has settled.
    private func scheduleTerminalResize() {
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingResize = nil
            terminal.resize(to: blockList.size)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeSettleInterval, execute: work)
    }

    /// Remember the command, and write it down.
    ///
    /// Written on **every** submission rather than on quit: a terminal that crashes is a terminal whose history
    /// would otherwise be the history from before the crash. The fallback is the degraded command text — the last
    /// non-blank line of the prompt region — because a shell that reports nothing over `OSC 9281` still has a
    /// history worth keeping, and bash and fish report nothing in the same shape.
    private func recordInHistory(_ command: String?) {
        guard let command else { return }
        history.record(command)
        historyStore.save(history)
    }

    /// The cell count on its own, for callers that do not own the pixel geometry.
    func resize(columns: Int, rows: Int) {
        resize(columns: columns, rows: rows, cellWidth: size.cellWidth, cellHeight: size.cellHeight)
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        pendingResize?.cancel()
        pendingResize = nil
        // Signal first, then close. A `read` parked on a pty cannot be interrupted, so the only way
        // the read loop ends is the shell dying and the master reaching end of file — and cancelling
        // the loop first would leave the exit status unreapable and hang the caller.
        terminal.signal(SIGHUP)
        terminal.close()
        readTask?.cancel()
        readTask = nil
    }

    // MARK: - Blocks

    /// Each block's body height and whether its header is drawn. One value rather than two, so the
    /// renderer cannot compute a height and a header from different states of the same block — and it
    /// is already the shape `BlockLayout` takes.
    var blockGeometry: [(lineCount: Int, hasHeader: Bool)] {
        // `visibleLineCount`, not `lineCount`: a collapsed block contributes only the lines it shows, which is what
        // moves the blocks below it up. Collapsing is a change to the document, not a clip at draw time.
        blocks.map { ($0.visibleLineCount, $0.isSubmitted) }
    }

    /// What a block's header shows as the command.
    ///
    /// The shell's report is preferred. Failing that — a shell without the marker, or no integration
    /// at all — the last non-blank line of the block's own prompt grid, which is the command line as
    /// drawn. Degraded, never absent.
    func commandText(for block: Block) -> String? {
        if let command = block.command, !command.isEmpty { return command }
        return block.headerGrid.commandText
    }

    /// A block's output as text, for the clipboard.
    func outputText(for block: Block) -> String {
        // The output, not the command: what the command printed. Copying the output of a block is what
        // the menu item says it does.
        return block.isSubmitted ? block.outputGrid.text : ""
    }

    /// Clearing history drops everything but the block the user is in.
    func clearHistory() {
        blockList.clearHistory()
        routeToActiveGrid()
    }

    /// The parser writes into whichever grid the active block is currently filling. Called after the
    /// two markers that change which grid that is, so the parser and the block list cannot disagree
    /// about where the shell's output is going.
    private func routeToActiveGrid() {
        guard let block = blockList.activeBlock else { return }
        activeGrid = block.contentGrids.last?.grid ?? activeGrid
        parser.grid = activeGrid
    }

    // MARK: - The read loop

    private func start() {
        parser.onEvent = { [weak self] event in self?.handle(event) }
        parser.onReply = { [weak self] reply in self?.terminal.write(reply) }
        let terminal = self.terminal
        readTask = Task { [weak self] in
            for await chunk in Self.outputStream(of: terminal) {
                guard let self, !hasStopped else { return }
                parser.feed(chunk)
                onUpdate?()
            }
            await self?.finish()
        }
    }

    /// Closing the master is what ends the read: a `read` parked on a pty has no other way to be
    /// interrupted, which is why the stream's termination handler closes it.
    private nonisolated static func outputStream(of terminal: PseudoTerminal) -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                while !Task.isCancelled {
                    guard let chunk = terminal.read() else { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
                terminal.close()
            }
        }
    }

    /// End of file means the child has closed its side and is on its way out, so this polls rather
    /// than blocks: a `waitpid` on the main actor is a beach ball if the shell is stuck in a trap.
    private func finish() async {
        readTask = nil
        var status: Int32 = 0
        for _ in 0..<100 {
            if let code = terminal.reapIfExited() {
                status = code
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        onExit?(status)
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let title):
            self.title = title
        case .workingDirectoryChanged(let path):
            workingDirectory = path
            // **The block's directory, not the session's.** Both, and this line is why: it was left behind in the
            // `searchPathChanged` case below when that case was added, so every block's header showed the shell's
            // `PATH` where its directory should be.
            blockList.setWorkingDirectory(path)
        case .searchPathChanged(let path):
            // Reported on every prompt, so a `PATH=` in an rc file or an exported one is picked up without anything
            // having to watch for it.
            searchPath = path
        case .commandSubmitted(let command):
            reportedCommand = command
        case .shellIntegration(let marker):
            apply(marker)
        default:
            break
        }
        onEvent?(event)
    }

    /// The prompt cycle, turned into block boundaries.
    ///
    /// Every boundary is now a *grid* rather than a line index in a shared sequence: `A` starts a
    /// block with a fresh pair of grids and points the parser at the first of them, `C` moves it to
    /// the second, and `D` seals that one. Nothing is measured and nothing is renumbered later.
    private func apply(_ marker: ShellIntegrationEvent) {
        switch marker {
        case .promptStart:
            blockList.beginPrompt(at: Date(), workingDirectory: workingDirectory)
            routeToActiveGrid()
        case .commandStart:
            blockList.markPromptEnd(line: activeGrid.cursorLine, column: activeGrid.cursorColumn)
        case .commandExecuted:
            blockList.markCommandSubmitted(command: reportedCommand, at: Date())
            recordInHistory(reportedCommand ?? activeBlock?.headerGrid.commandText)
            reportedCommand = nil
            routeToActiveGrid()
        case .commandFinished(let exitCode):
            blockList.finish(exitCode: exitCode, at: Date())
        }
    }
}
