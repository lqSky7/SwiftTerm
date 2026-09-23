import AppKit
import Observation

/// The terminal feature's action surface. `AppCore` owns one; views and menus call it, and nothing
/// else reaches into the session directly.
@MainActor
@Observable
final class TerminalCoordinator {
    /// Why the shell is not running, when it is not. Shown in place of the terminal rather than as
    /// a modal, because a terminal that cannot start has nothing else to say.
    private(set) var failure: String?

    /// What the shell says about where it is: its own title over `OSC 0/2`, or the working directory
    /// it reported over `OSC 7`.
    ///
    /// Empty until it says anything, deliberately. The window and the sidebar each have their own
    /// answer for an empty one — the app's name and a numbered tab — and neither of those belongs here,
    /// where a placeholder would be indistinguishable from a shell that really is called "swiftTerm".
    private(set) var title: String = ""

    private(set) var lastExitStatus: Int32?

    /// Whether this pane is the one the keyboard belongs to.
    ///
    /// Written by `AppCore` whenever the active tab or the focused pane changes, and read by the
    /// surface when it arrives in a window. The answer comes from the model rather than from anything
    /// a view remembers, so a pane cannot take the keyboard from one the user is typing into: exactly
    /// one pane is ever active, and it is this one or it is not.
    @ObservationIgnored var isActive: Bool = false

    @ObservationIgnored private(set) var session: TerminalSession?
    @ObservationIgnored private(set) var surface: TerminalSurfaceView?

    /// Set by the window controller, which is the only thing that owns a window.
    @ObservationIgnored var onTitleChange: ((String) -> Void)?

    /// `startingDirectory` is where the shell is started, which is a restored pane's recorded directory. Nil is the
    /// home directory, which is where a new pane has always started.
    init(
        contentSize: CGSize, pointSize: CGFloat = Theme.Typography.terminalPointSize,
        lineHeightRatio: CGFloat = Theme.Typography.lineHeightRatio,
        startingDirectory: String? = nil
    ) {
        // Measured here rather than read back from the view so the shell is started at the size the
        // window already is. Starting at 80×24 and resizing on the first layout would make the
        // shell draw a prompt and then immediately redraw it.
        let font = TerminalFont(pointSize: pointSize, lineHeightRatio: lineHeightRatio)
        let size = TerminalSize(
            columns: max(1, Int(contentSize.width / font.cellWidth)),
            rows: max(1, Int(contentSize.height / font.cellHeight)),
            cellWidth: Int(font.cellWidth * 2),
            cellHeight: Int(font.cellHeight * 2))

        do {
            let session = try TerminalSession(
                size: size, homeDirectory: startingDirectory ?? NSHomeDirectory())
            let surface = TerminalSurfaceView(
                session: session, pointSize: pointSize, lineHeightRatio: lineHeightRatio)
            self.session = session
            self.surface = surface
            surface.coordinator = self
            session.onEvent = { [weak self] event in self?.handle(event) }
            session.onExit = { [weak self] status in self?.handleExit(status) }
        } catch {
            failure = "Could not start a shell. \(error)"
        }
    }

    var isRunning: Bool { session != nil }

    func shutdown() {
        session?.stop()
        session = nil
        surface = nil
    }

    // MARK: - Actions

    /// Which part of a block an action works on. A block is several things at once — the command
    /// that was run, what it printed, and where it ran — and copying needs to say which.
    enum BlockField {
        case command
        case output
        case workingDirectory
    }

    func paste() {
        guard let surface, let text = NSPasteboard.general.string(forType: .string) else { return }
        surface.insertPastedText(text)
    }

    func copyBlock(_ field: BlockField, id: BlockID?) {
        guard let session, let id, let block = session.blocks.first(where: { $0.id == id }) else { return }
        let text: String?
        switch field {
        case .command: text = session.commandText(for: block)
        case .output: text = session.outputText(for: block)
        case .workingDirectory: text = block.workingDirectory
        }
        guard let text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func clearScrollback() {
        guard let session, !session.isAlternateScreen else { return }
        session.clearHistory()
        // Ctrl-L is the shell's own clear-screen, so the prompt lands at the top of an empty screen
        // instead of wherever the cursor happened to be.
        session.write("\u{0C}")
    }

    /// The `View` menu's three items, and the font size itself.
    ///
    /// They do **not** resize the surface directly. The size is a *setting*: it belongs to `AppCore`, it is saved,
    /// and every pane draws at it. A coordinator that changed its own surface locally would be a second answer to
    /// what the size is, and the settings page would then disagree with the window.
    @ObservationIgnored var onAdjustFontSize: ((Double) -> Void)?
    /// `⌘0`. Separate from the delta one because reset is **not** a delta: this knows the default but not the
    /// current size, and sending `+13` for "back to 13" would jump to 26 from a 13-point terminal.
    @ObservationIgnored var onResetFontSize: (() -> Void)?

    func increaseFontSize() { onAdjustFontSize?(Double(Theme.Typography.pointSizeStep)) }

    func decreaseFontSize() { onAdjustFontSize?(-Double(Theme.Typography.pointSizeStep)) }

    func resetFontSize() { onResetFontSize?() }

    /// Pushed in like the opacity and the palette, and for the same reason: the setting is the app's.
    func setFontSize(_ size: Double) { surface?.setFontSize(size) }

    func setLineHeightRatio(_ ratio: Double) { surface?.setLineHeightRatio(ratio) }

    /// The terminal's background opacity, pushed in by `AppCore` when it is set and when a pane is
    /// created. The surface has no way to ask for it and should not: the setting belongs to the app.
    func setTerminalOpacity(_ opacity: Double) { surface?.setTerminalOpacity(opacity) }

    /// Which appearance the terminal draws in, pushed in for the same reason and at the same moments as the
    /// opacity: which palette is right is the app's decision, and the surface resolves it against its own
    /// `effectiveAppearance` so that `system` keeps following the machine.
    func setAppearanceMode(_ mode: AppearanceMode) { surface?.setAppearanceMode(mode) }

    // MARK: - Session events

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let title) where !title.isEmpty:
            self.title = title
        case .workingDirectoryChanged:
            if session?.title?.isEmpty ?? true { updateTitleFromWorkingDirectory() }
        default:
            break
        }
        onTitleChange?(title)
    }

    private func handleExit(_ status: Int32) {
        lastExitStatus = status
        title = "swiftTerm — shell exited (\(status))"
        onTitleChange?(title)
    }

    /// A shell that sets no title still deserves a useful one, and the directory it is in is the
    /// most useful thing it knows.
    private func updateTitleFromWorkingDirectory() {
        guard let directory = session?.workingDirectory else { return }
        title = (directory as NSString).abbreviatingWithTildeInPath
    }
}
