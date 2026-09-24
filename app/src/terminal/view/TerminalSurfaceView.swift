import AppKit

/// The terminal's surface: focus, keyboard translation, scrolling, resize and drawing.
///
/// The view owns presentation only. Every decision about what a key *means* to the shell is in
/// `translatedBytes`, everything about what the screen *holds* is in the grid, and everything about
/// how the blocks are arranged is in `BlockLayout`. A `draw` that started deciding things would be
/// the first sign this file was doing too much.
@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    let session: TerminalSession

    /// Set by the coordinator once it exists. The view performs the menu actions because the
    /// responder chain is what routes them here, but the logic stays on the coordinator.
    weak var coordinator: TerminalCoordinator?

    private let renderer: TerminalRenderer
    private let editor: CommandEditorView
    private var pointSize: CGFloat
    /// How far back the viewport is, in pixels: whole rows plus the fraction of the next one that has
    /// slid in. A terminal cannot show half a row of *text*, but it can slide the rows it has, and
    /// that is the difference between scrolling and a series of jumps.
    private var scrollPosition: CGFloat = 0
    private var selectedBlockID: BlockID?
    /// The block the pointer is over, so its hover control can be drawn. Nil when the pointer is outside the
    /// window or over no block — and one block at a time, because two sets of dots would say two things.
    private var hoveredBlock: BlockID?
    /// The text selected in the grid, or nil. A *click* leaves this empty rather than nil — see `mouseDown` — so
    /// "nothing is selected" and "there is a selection" are one thing rather than two.
    private var selection: TextSelection?
    private var markedText: NSMutableAttributedString?
    /// How tall a line is, as a multiple of `pointSize`.
    private var lineHeightRatio: CGFloat = Theme.Typography.lineHeightRatio
    /// The `PATH` the cached command names and the editor's resolver were built from.
    private var lastSearchPath: String?

    /// The resolver, against the shell's `PATH`.
    private var commandResolver: CommandResolver { CommandResolver(path: resolvedSearchPath) }
    /// Precise scroll deltas, accumulated until they are worth a wheel notch. See `sendMouseWheel`.
    private var accumulatedWheel: CGFloat = 0
    /// Which appearance the terminal draws in. Pushed in by the coordinator; the palette is resolved from it
    /// and this view's own `effectiveAppearance`.
    private var appearanceMode: AppearanceMode = .system
    private var blinkTask: Task<Void, Never>?
    private var cursorBlinkOn = true
    /// The chips above the prompt, and what they were computed for.
    ///
    /// Recomputed when a new prompt begins, which is exactly when the directory and the branch may have
    /// changed — so a `cd` and a `git switch` both show up on the next prompt, and neither costs
    /// anything per frame. A new prompt is a new block, which is the signal this keys on.
    private var chips: [ContextChip] = []
    private var chipsDirectory: String?
    private var chipsBlock: BlockID?

    /// The completion list, when it is open. **Nil is the closed state**, so "is it open" and "what is it
    /// showing" cannot disagree — a `Bool` beside a menu is two things that have to be kept in step.
    private var completion: CompletionMenu?
    /// The buffer and caret as they were when the list opened — what every preview is computed against,
    /// since `editor.string` already holds the previous candidate's insertion by the next cycle.
    private var completionOriginalBuffer: String?
    private var completionOriginalCaret: Int?
    private let completionPopover = CompletionPopover()
    /// The hover control's actions, on glass. A panel of our own rather than an `NSMenu`, because the point of
    /// the three dots is that what they open belongs to the terminal.
    private let blockMenuPopover = BlockMenuPopover()
    /// Which block the open panel belongs to, so it follows that block when the document scrolls.
    private var blockMenuIndex: Int?
    /// The actions the open panel is showing, so the row it reports can be turned back into one. Kept because the
    /// list is built per block — a row index means nothing without the list it came from.
    private var blockMenuActions: [(title: String, action: Selector)] = []

    init(
        session: TerminalSession, pointSize: CGFloat = Theme.Typography.terminalPointSize,
        lineHeightRatio: CGFloat = Theme.Typography.lineHeightRatio
    ) {
        self.session = session
        self.pointSize = pointSize
        self.lineHeightRatio = lineHeightRatio
        let font = TerminalFont(pointSize: pointSize, lineHeightRatio: lineHeightRatio)
        self.renderer = TerminalRenderer(palette: .builtin, font: font)
        self.editor = CommandEditorView(
            font: font,
            palette: .builtin,
            resolver: CommandResolver(path: ProcessInfo.processInfo.environment["PATH"]))
        // Replaced by the shell's own report as soon as one arrives; see `sessionDidUpdate`.
        super.init(frame: .zero)
        // The window's blur is behind this view, so the surface must not claim to be opaque.
        wantsLayer = true
        layer?.isOpaque = false
        // The editor rides on top of the surface, hidden until the shell draws a prompt and the
        // first draw positions it. Its callbacks are the whole of how it reaches the pty: submit
        // goes through `CommandSubmission` and `send(_:)` like everything else, keys the shell
        // owns arrive as raw bytes, and navigation chords fall through to the surface's handler.
        editor.isHidden = true
        addSubview(editor)
        editor.onSubmit = { [weak self] buffer in self?.submit(buffer) }
        editor.onRawBytes = { [weak self] bytes in self?.send(bytes) }
        editor.onNavigationKey = { [weak self] event in self?.handleNavigationKey(event) ?? false }
        editor.onHistory = { [weak self] in self?.commandHistory ?? [] }
        editor.onCompletionRequest = { [weak self] in self?.openCompletion() ?? false }
        editor.onCompletionKey = { [weak self] event in self?.handleCompletionKey(event) ?? false }
        editor.onCopyWithoutSelection = { [weak self] in self?.copySelectedText() ?? false }
        // Above the editor, because the list is drawn over the line being typed. Added after the editor so
        // the order is stated rather than inherited from the order of two `addSubview` calls.
        addSubview(completionPopover, positioned: .above, relativeTo: editor)
        // Above everything: a menu the terminal's own text could be drawn over is not a menu.
        addSubview(blockMenuPopover, positioned: .above, relativeTo: nil)
        blockMenuPopover.onSelect = { [weak self] row in self?.performBlockAction(row) }
        editor.onBufferChanged = { [weak self] in
            guard let self else { return }
            // Typing belongs at the bottom; a buffer change that arrived while the reader is
            // scrolled back would be invisible until they scrolled to it.
            if scrollPosition > 0 { scrollToBottom() }
            refreshGhostText()
            needsDisplay = true
        }
        // The session is the view's model, so the view is what listens for its changes. Events and
        // exit are the coordinator's to observe; they are separate properties for exactly this.
        session.onUpdate = { [weak self] in self?.sessionDidUpdate() }
        startBlinking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceView is created in code, never from a nib")
    }

    deinit {
        blinkTask?.cancel()
    }

    // MARK: - Geometry

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridForBounds()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGridForBounds()
        claimFocusIfActive()
        syncFirstResponder()
        // A hover control needs to know where the pointer is, and AppKit does not send `mouseMoved` unless the
        // window has asked for it.
        window?.acceptsMouseMovedEvents = true
    }

    /// One tracking area over everything, rather than one per block: the block under the pointer is a lookup
    /// this view already knows how to do, and a hundred tracking areas is a hundred things to keep in step with
    /// the document.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        // Only a program that asked for drags gets them; 1000 is press and release, nothing more.
        if sendMouseEvent(event, .drag) { return }
        guard var current = selection,
            let point = selectionPoint(atViewPoint: convert(event.locationInWindow, from: nil))
        else { return }
        current.focus = point
        selection = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if sendMouseEvent(event, .release) { return }
        super.mouseUp(with: event)
    }

    /// Right-click is the program's too, when it asked for the mouse — and that has to happen here rather than in
    /// `menu(for:)`, because a right-click that opens a block menu *and* reaches the program is two menus.
    override func rightMouseDown(with event: NSEvent) {
        if sendMouseEvent(event, .press) { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if sendMouseEvent(event, .release) { return }
        super.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        // 1003 tracks motion with nothing held. Before the hover control, because the program's mouse is the
        // program's.
        if session.activeGrid.modes.mouseTracking == .anyMotion, sendMouseEvent(event, .motion) { return }
        let index = blockIndex(atViewPoint: convert(event.locationInWindow, from: nil))
        let identifier = index.flatMap { session.blocks.indices.contains($0) ? session.blocks[$0].id : nil }
        guard identifier != hoveredBlock else { return }
        hoveredBlock = identifier
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredBlock != nil else { return }
        hoveredBlock = nil
        needsDisplay = true
    }

    /// A pane takes the keyboard when it arrives in a window and it is the pane the window is showing.
    ///
    /// Driven by the structure rather than by anything the shell prints: this fires when a pane
    /// appears — a new split, a tab being switched to, the first one at launch — and never while a
    /// command is running. That is what keeps it from being the defect `journal.md` records as "focus
    /// that moved under the user's hands", where the first keystroke went to the pty, the echo came
    /// back, and the echo was what moved the focus. Nothing here reacts to output at all.
    private func claimFocusIfActive() {
        guard let window, coordinator?.isActive == true, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// The one place the cell count and the pixel geometry are derived, so a window resize and a font
    /// change cannot disagree about what size the shell was told.
    private func updateGridForBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let (columns, rows) = renderer.gridSize(fitting: bounds.size)
        let scale = window?.backingScaleFactor ?? 2
        session.resize(
            columns: columns,
            rows: rows,
            cellWidth: Int((renderer.font.cellWidth * scale).rounded()),
            cellHeight: Int((renderer.font.cellHeight * scale).rounded()))
        needsDisplay = true
    }

    /// The text size, pushed in by the coordinator from the setting.
    func setFontSize(_ size: Double) {
        let clamped = CGFloat(
            ChromeSettings.fontSizeRange.clamping(size))
        guard clamped != pointSize else { return }
        pointSize = clamped
        applyFont()
    }

    /// How tall a line is, as a multiple of the text size. Warp's `line_height_ratio`, and the number that
    /// decides whether the grid reads like a terminal or like a text editor.
    func setLineHeightRatio(_ ratio: Double) {
        let clamped = CGFloat(ChromeSettings.lineHeightRatioRange.clamping(ratio))
        guard clamped != lineHeightRatio else { return }
        lineHeightRatio = clamped
        applyFont()
    }

    /// Rebuild the font from the two settings that decide it, and re-measure everything that depends on it.
    ///
    /// The palette goes with it rather than being left alone: `TerminalRenderer.update` takes both, and passing
    /// `.builtin` here — which this used to do — silently reverted a light terminal to the dark palette the first
    /// time somebody pressed `⌘+`.
    private func applyFont() {
        let font = TerminalFont(pointSize: pointSize, lineHeightRatio: lineHeightRatio)
        renderer.update(palette: appearanceMode.palette(for: effectiveAppearance), font: font)
        editor.update(font: font)
        updateGridForBounds()
    }

    /// How opaque the terminal's own background is, over the window's.
    ///
    /// Pushed in rather than read here: the setting is `AppCore`'s, and a view that went and read the
    /// settings store would be a second place that knows how they are stored — and a second answer to
    /// what the value currently is.
    func setTerminalOpacity(_ opacity: Double) {
        renderer.backgroundOpacity = CGFloat(opacity)
        needsDisplay = true
    }

    /// Which appearance the terminal draws in — dark or light, following the setting.
    ///
    /// The *mode* rather than a palette, so this view can re-resolve it for itself when its appearance
    /// changes. That is what makes `system` work: flipping the system appearance re-resolves every view's
    /// `effectiveAppearance`, and `viewDidChangeEffectiveAppearance` is where the palette notices.
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        applyPalette()
    }

    /// A new palette invalidates every cached row, because the palette is baked into the `CTLine`s rather
    /// than applied when they are drawn. `TerminalRenderer.update` is the one place that knows that.
    private func applyPalette() {
        renderer.update(palette: appearanceMode.palette(for: effectiveAppearance), font: renderer.font)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let currentLayout = layout
        renderer.draw(
            in: context,
            bounds: bounds,
            session: session,
            layout: currentLayout,
            scrollPosition: scrollPosition,
            showsCursor: shouldDrawGridCursor,
            markedText: markedText?.string,
            cursorBlinkOn: cursorBlinkOn,
            selectedBlockID: selectedBlockID,
            hoveredBlockID: hoveredBlock,
            selection: selection,
            chips: visibleChips)
        positionEditor(from: currentLayout)
        positionBlockMenu()
        // After the editor, and from the same layout: the list is anchored to the line the editor was just
        // placed on, so doing it anywhere but here is two answers to where that line is.
        positionCompletion()
    }

    /// Where the editor sits, computed in `draw` from the same layout the renderer just painted.
    ///
    /// Never from a callback: a frame computed from an event goes stale the first time the document
    /// moves without firing that event, which is how the editor once ended up a row too high and
    /// stayed there while typing. The frame runs from the prompt's end to the right edge, and is as
    /// many lines tall as the buffer — the same number the layout reserved for it.
    private func positionEditor(from layout: BlockLayout) {
        guard editorIsVisible,
            let index = session.blocks.indices.last,
            let entry = layout.entries.first(where: { $0.blockIndex == index }),
            let promptEnd = session.activeBlock?.headerGrid.promptEnd
        else {
            editor.isHidden = true
            return
        }
        let font = renderer.font
        let top = entry.contentTop + CGFloat(promptEnd.line) * font.cellHeight
        let height = max(font.cellHeight, CGFloat(editor.lineCount) * font.cellHeight)
        // The same inset the renderer draws the grid inside, so the editor's first column lands on the
        // grid's first column rather than on the panel's edge. Two numbers here would be a prompt that
        // jumps sideways the moment a command is submitted.
        let x = Theme.Size.terminalContentInset + CGFloat(promptEnd.column) * font.cellWidth
        // Document coordinates run down from the top; this view is y-up, so the frame's origin is
        // the region's bottom edge.
        // The editor is on the *pinned* block by definition — it is the block being typed into — so it is placed
        // against that viewport rather than the scrolling one.
        let originY = bounds.maxY - (top + height - pinnedViewportTop)
        let width = max(font.cellWidth, bounds.width - x - Theme.Size.terminalContentInset)
        editor.frame = NSRect(x: x, y: originY, width: width, height: height)
        editor.isHidden = false
    }

    private func sessionDidUpdate() {
        // New output must never fight a reader who has scrolled back, so the position is kept and
        // only clamped to what still exists.
        if scrollPosition > maximumScroll { scrollPosition = maximumScroll }
        // A command ran, or a prompt arrived: the list was about a buffer that no longer exists, and the
        // candidates in it were about a working directory that may have just changed under a `cd`. The
        // *suggestion* is refreshed rather than dropped, because the history just grew by one and the newest
        // command is the one worth suggesting.
        closeCompletion()
        // **New output invalidates a selection.** It was a range of a document that no longer exists — the rows have
        // moved — so keeping it would highlight whatever text has slid into those cells, and ⌘C would copy that.
        selection = nil
        // The shell can report a new `PATH` at any prompt, and both the resolver and the completion list are built
        // from it. Checked rather than rebuilt every time: `executableNames()` is a few thousand `stat` calls.
        if session.searchPath != lastSearchPath {
            lastSearchPath = session.searchPath
            cachedCommandNames = nil
            editor.update(resolver: commandResolver)
        }
        refreshGhostText()
        refreshChips()
        needsDisplay = true
        syncFirstResponder()
    }

    /// The one place that decides who has the keyboard.
    ///
    /// The editor owns it while a prompt is showing (which is also what suppresses the grid's
    /// cursor — the renderer only draws one when the surface is the first responder), and the
    /// surface owns it for a running command or a full-screen program. This is Warp's
    /// `redetermine_global_focus` in miniature.
    ///
    /// It is a *reconciliation*, not an assertion: when the two already agree it does nothing, so
    /// calling it from the output path is safe — typing in the editor produces no output, a running
    /// command's output leaves the answer unchanged, and the only calls that ever move focus are the
    /// ones where the block's state actually flipped (a prompt appeared, a command started). The
    /// defect `journal.md` records as "focus that moved under the user's hands" was this function
    /// without the agreement check, reacting to the echo of the user's own keystroke.
    private func syncFirstResponder() {
        guard let window, coordinator?.isActive == true else { return }
        if editorIsVisible {
            guard window.firstResponder !== editor else { return }
            // A hidden view cannot take the keyboard; the draw that positions it is about to run.
            editor.isHidden = false
            window.makeFirstResponder(editor)
        } else if window.firstResponder === editor {
            window.makeFirstResponder(self)
        }
    }

    // MARK: - Context chips

    /// The chips above the prompt, or none when something other than a prompt is showing. A command
    /// that is running has no prompt, so it has no chips.
    private var visibleChips: [ContextChip] {
        guard !session.isAlternateScreen, let block = session.activeBlock, !block.isSubmitted else {
            return []
        }
        return chips
    }

    private func refreshChips() {
        let directory = session.workingDirectory ?? NSHomeDirectory()
        let block = session.activeBlock?.id
        guard directory != chipsDirectory || block != chipsBlock else { return }
        chipsDirectory = directory
        chipsBlock = block
        chips = ContextChips.forPrompt(
            directory: directory, metadata: RepoMetadata.inspect(directory: directory))
    }

    /// The cursor is the only thing that repaints on a blink, so the invalidation is the cursor's
    /// rect rather than the view.
    private func startBlinking() {
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                guard let self else { return }
                guard session.activeGrid.cursorStyle.blinks, window?.firstResponder === self else { continue }
                cursorBlinkOn.toggle()
                needsDisplay = true
            }
        }
    }

    // MARK: - The document

    /// Rebuilt on demand rather than cached. It is a few hundred comparisons over a list the block cap
    /// already bounds, and a cache here would be one more thing to invalidate — which is the bug this
    /// codebase already paid for once.
    ///
    /// This is the *one* layout: the renderer is handed it rather than building its own, so a viewport
    /// and the thing that painted it cannot disagree about where the document is.
    private var layout: BlockLayout {
        BlockLayout(
            contributions: layoutContributions,
            chipRow: chipRow,
            headerHeight: Theme.Size.blockHeaderHeight,
            lineHeight: renderer.font.cellHeight,
            bottomPadding: renderer.font.cellHeight * Theme.Typography.blockBottomPaddingRatio)
    }

    /// The blocks' contributions, with room folded in for the editor on the block being typed.
    ///
    /// The editor overlays the prompt and grows downward as the buffer does, so the document has
    /// to be told that block is taller than the shell's grid says. Every other block contributes
    /// exactly what the session reports; `BlockLayout` never hears about the editor directly.
    private var layoutContributions: [BlockLayout.Contribution] {
        var contributions = session.blockGeometry
        if let index = contributions.indices.last, editorIsVisible,
            let promptEnd = session.activeBlock?.headerGrid.promptEnd
        {
            contributions[index].lineCount = max(
                contributions[index].lineCount, promptEnd.line + editor.lineCount)
        }
        return contributions
    }

    /// Whether the **shell's** cursor is the cursor the user should see.
    ///
    /// The grid's cursor belongs to the shell, and there are exactly two states where it is the right thing to draw:
    ///
    /// - **A full-screen program is running.** `nano` and `opencode` draw their own cursor and expect the terminal
    ///   to show it — in the shape they asked for with `DECSCUSR`, which is why `nano` gets the bar it wants.
    /// - **The shell has never reported a prompt**, so there is no integration and the grid *is* the prompt. Hiding
    ///   the cursor there would leave a terminal with no cursor at all.
    ///
    /// Everywhere else it is noise, and this is the thick cursor that flashes when a command is run: between
    /// submitting a line and the prompt coming back, the editor is hidden, output is arriving, and the grid's block
    /// cursor appeared at the end of it for as long as the command took. **A command that is running is not waiting
    /// for input**, and Warp shows no cursor for one.
    ///
    /// It was gated on the surface being the first responder and nothing else — wrong in both directions: clicking a
    /// block drew a block cursor over a prompt that already had the editor's caret, and running a command flashed
    /// one over its own output.
    private var shouldDrawGridCursor: Bool {
        // The keyboard first, then the session's own answer — which is harnessed, because every time this rule was
        // reasoned about rather than asserted it was wrong.
        window?.firstResponder === self && session.showsShellCursor
    }

    /// Whether a prompt is showing that the editor can own: not a full-screen program, not a
    /// submitted block, and the shell has marked where its prompt ends (`133 ; B`). A shell
    /// without the marker gets the grid's keyboard path, exactly as before — the editor never
    /// guesses where to sit.
    private var editorIsVisible: Bool {
        guard !session.isAlternateScreen, session.activeBlock?.isSubmitted != true else { return false }
        return session.activeBlock?.headerGrid.promptEnd != nil
    }

    /// The commands already run, oldest first — the order ↑ and ↓ walk in.
    ///
    /// **The saved history first, then this session's blocks.** The file is everything from before this window;
    /// the blocks are what has run since, and they cover a shell that reports no command text. A command that ran in
    /// this session is in both — it was written to the file the moment it was submitted — so the duplicates are
    /// dropped and the file's order wins, which is the chronological one.
    private var commandHistory: [String] {
        var seen = Set<String>()
        var combined: [String] = []
        for command in session.history.entries + session.blocks.compactMap(Self.commandText(of:))
        where seen.insert(command).inserted {
            combined.append(command)
        }
        return combined
    }

    /// The command a submitted block ran, as far as the shell reported it.
    private static func commandText(of block: Block) -> String? {
        guard block.isSubmitted, let text = block.command ?? block.headerGrid.commandText else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Completion

    /// The inline suggestion: the rest of the most recent command that starts with what has been typed.
    ///
    /// Recomputed on every buffer change rather than when the prompt appears, because it is a function of the
    /// *buffer* — a suggestion that only updated on output would sit there stale for as long as somebody was
    /// typing, which is the whole time it is on screen.
    ///
    /// Only offered with the caret at the end of the line, and that rule is the engine's rather than this
    /// view's: ghost text in the middle of a line is a suggestion about a buffer that does not exist yet.
    private func refreshGhostText() {
        guard editorIsVisible else {
            editor.ghostText = nil
            return
        }
        editor.ghostText = completionEngine.ghostText(
            for: editor.string, cursor: editor.selectedRange().location)
    }

    /// Tab. Build the list from the buffer and show it, or answer `false` so the key goes on to the shell.
    ///
    /// The engine is built here and thrown away rather than kept: its inputs are the history, the working
    /// directory and a directory listing, and all three change while the window is open. A cached engine is an
    /// engine offering the directory you were in ten minutes ago.
    private func openCompletion() -> Bool {
        guard
            let menu = CompletionMenu(
                buffer: editor.string,
                caret: editor.selectedRange().location,
                engine: completionEngine)
        else {
            // Nothing to offer, so this is not a list — and Tab then belongs to the shell, which is what the
            // editor does with the `false`.
            closeCompletion()
            return false
        }
        completionOriginalBuffer = editor.string
        completionOriginalCaret = editor.selectedRange().location
        completion = menu
        positionCompletion()
        previewSelection(menu)
        return true
    }

    /// A key while the list is open.
    ///
    /// Tab and the arrows move — Tab as well as ↓, because in a shell Tab is the key you press to go through
    /// the choices, and a list that can only be walked with the arrows is a list that ignores the key which
    /// opened it. Return takes the chosen one, Escape closes, and **anything else closes the list and is then
    /// handled as itself** — which is what makes typing one more character dismiss it and narrow the next one.
    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard var menu = completion else { return false }
        let key = event.specialKey
        let characters = event.characters ?? ""
        let isTab = characters == "\t" || key == .tab

        if isTab || key == .downArrow {
            menu.moveDown()
            completion = menu
            positionCompletion()
            previewSelection(menu)
            return true
        }
        if key == .upArrow {
            menu.moveUp()
            completion = menu
            positionCompletion()
            previewSelection(menu)
            return true
        }
        if characters == "\r" || characters == "\n" || key == .carriageReturn || key == .enter
            || key == .newline
        {
            acceptCompletion(menu)
            return true
        }
        if characters == "\u{1B}" {
            if let original = completionOriginalBuffer {
                editor.setBuffer(original, caret: completionOriginalCaret ?? (original as NSString).length)
            }
            closeCompletion()
            return true
        }

        closeCompletion()
        return false
    }

    /// Put the highlighted candidate into the line live, so it doesn't lag a keystroke behind the popover.
    private func previewSelection(_ menu: CompletionMenu) {
        guard let base = completionOriginalBuffer, let accepted = menu.accepted(in: base) else { return }
        editor.setBuffer(accepted.text, caret: accepted.caret)
    }

    /// Return takes the highlighted candidate and runs it in one keystroke — a deliberate divergence from
    /// Warp's accept-then-a-second-Return, since Return already means "run this" everywhere else here.
    private func acceptCompletion(_ menu: CompletionMenu) {
        guard let base = completionOriginalBuffer, let accepted = menu.accepted(in: base) else {
            closeCompletion()
            return
        }
        closeCompletion()
        submit(accepted.text)
    }

    private func closeCompletion() {
        guard completion != nil else { return }
        completion = nil
        completionOriginalBuffer = nil
        completionOriginalCaret = nil
        completionPopover.hide()
    }

    /// Where the list sits: just above the line the editor is on, which is the line the candidate belongs to.
    ///
    /// Called from `draw` and from every key that moves the selection, never from a callback — the rule the
    /// editor's own frame follows, and for the same reason: a frame computed from an event goes stale the
    /// first time the document moves without one.
    private func positionCompletion() {
        guard let menu = completion else { return }
        completionPopover.show(menu, above: completionAnchor, within: bounds)
    }

    /// The top edge of the prompt line, in this view's coordinates — which are y-up, while the document runs
    /// y-down, so this is one of the two places the two are reconciled.
    private var completionAnchor: NSPoint {
        guard let index = session.blocks.indices.last,
            let entry = layout.entries.first(where: { $0.blockIndex == index }),
            let promptEnd = session.activeBlock?.headerGrid.promptEnd
        else { return NSPoint(x: Theme.Size.terminalContentInset, y: bounds.midY) }
        let documentY = entry.contentTop + CGFloat(promptEnd.line) * renderer.font.cellHeight
        // Anchored to the pinned block, for the same reason the editor is: the list belongs to the line being typed.
        return NSPoint(
            x: Theme.Size.terminalContentInset, y: bounds.maxY - (documentY - pinnedViewportTop))
    }

    /// The engine, built for one Tab.
    private var completionEngine: CompletionEngine {
        CompletionEngine(
            history: commandHistory.reversed(),
            commands: commandNames,
            workingDirectory: session.workingDirectory ?? NSHomeDirectory(),
            listDirectory: Self.listDirectory)
    }

    /// The `PATH` to resolve and complete against: **the shell's**, or the app's before one has been reported.
    ///
    /// Opened from the Finder the app inherits launchd's `/usr/bin:/bin:/usr/sbin:/sbin`, so a Homebrew command is
    /// neither resolved nor offered — and the shell the user is typing into can run it perfectly well. The shell
    /// reports its own `PATH` from its prompt hook, which is how Warp gets it too (`warp_features.md` #5).
    private var resolvedSearchPath: String? {
        session.searchPath ?? ProcessInfo.processInfo.environment["PATH"]
    }

    /// The executables on that `PATH`, cached **against the string they were read from**.
    ///
    /// A few thousand `stat` calls, so not on every Tab and not on every prompt — but keyed on the string rather
    /// than built once, because the shell can change its `PATH` between prompts and a cache built at startup would
    /// go on answering for the environment the app was launched with.
    private var commandNames: [String] {
        let path = resolvedSearchPath
        if let cached = cachedCommandNames, cached.path == path { return cached.entries }
        let entries = CommandResolver(path: path).executableNames()
        cachedCommandNames = (path, entries)
        return entries
    }

    private var cachedCommandNames: (path: String?, entries: [String])?
    private static var directoryCache: [String: (timestamp: Date, entries: [DirectoryEntry])] = [:]

    /// A real directory listing, read when Tab is pressed rather than kept.
    ///
    /// Hidden files are **not** skipped: `cd .` and `git add .g` both need them, and a name that does not
    /// match the word being completed is ranked last rather than offered, so a dotfile costs nothing when it is
    /// not wanted. Cached for a couple seconds to avoid redundant disk syscalls while typing.
    private static func listDirectory(_ path: String) -> [DirectoryEntry] {
        let now = Date()
        if let cached = directoryCache[path], now.timeIntervalSince(cached.timestamp) < 2.0 {
            return cached.entries
        }
        let url = URL(fileURLWithPath: path)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let result = entries.map { entry in
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return DirectoryEntry(name: entry.lastPathComponent, isDirectory: isDirectory)
        }
        directoryCache[path] = (now, result)
        return result
    }

    /// The block being typed gets the chip row. It is reserved *above* that block's content, so no
    /// other block's offsets move and the block's own rows keep their line numbers.
    private var chipRow: BlockLayout.ChipRow? {
        guard !visibleChips.isEmpty, let index = session.blocks.indices.last else { return nil }
        return BlockLayout.ChipRow(blockIndex: index, height: Theme.Size.contextChipHeight)
    }

    /// The top of the viewport, in document coordinates. Negative when the document is shorter than
    /// the window, which is what anchors a short document to the bottom.
    /// Where the **scrolling region** starts in the document.
    ///
    /// Not `totalHeight - scrollPosition - bounds.height` any more: the pinned block at the bottom does not scroll, so
    /// the region that does is the view's height *minus* the pinned block's, and it shows the document above it.
    private var viewportTop: CGFloat {
        layout.scrollableTop(scrollPosition: scrollPosition, viewportHeight: bounds.height)
    }

    /// The viewport top for the pinned block, which is where the input, the editor and the completion list all live.
    ///
    /// A constant for a given view size, which is the whole point: the block the shell is writing into does not move.
    private var pinnedViewportTop: CGFloat {
        layout.pinnedViewportTop(viewportHeight: bounds.height)
    }

    /// Whether a point in this view is over the pinned block rather than over the scrolling region above it.
    private func isOverPinnedBlock(_ point: CGPoint) -> Bool {
        point.y < bounds.minY + layout.pinnedHeight
    }

    private var maximumScroll: CGFloat {
        layout.maximumScroll(viewportHeight: bounds.height)
    }

    /// The document position a point in the view sits at. The view is y-up and the document is
    /// y-down, so this is the one place the two are reconciled.
    private func documentY(atViewPoint point: NSPoint) -> CGFloat {
        // **Which viewport depends on which region the point is in**, and this is the one place that decides. Every
        // hit test goes through here — `blockIndex(atViewPoint:)`, `selectionPoint(atViewPoint:)` — so a click and a
        // drag agree about where a row is without either of them knowing this changed.
        let top = isOverPinnedBlock(point) ? pinnedViewportTop : viewportTop
        return top + (bounds.maxY - point.y)
    }

    /// The block a point lands on: its header or its output.
    ///
    /// Phase 2 made headers the only target, on the grounds that a body click was ambiguous without
    /// text-level selection to tell it apart from a drag. There is still no text-level selection, so
    /// there is nothing for a body click to be confused with — and a block you cannot click is a
    /// block you cannot act on. When selection arrives, the rule becomes the conventional one: a
    /// click in the body places the caret, a click on the header picks the block.
    private func blockIndex(atViewPoint point: NSPoint) -> Int? {
        let y = documentY(atViewPoint: point)
        for entry in layout.entries.reversed() where y >= entry.headerTop && y < entry.bottom {
            return entry.blockIndex
        }
        return nil
    }

    // MARK: - Scrolling

    private var scrollStep: CGFloat { max(1, renderer.font.cellHeight) }

    override func scrollWheel(with event: NSEvent) {
        // **A program that asked for the mouse gets the wheel.**
        //
        // This is the whole of "I cannot scroll in opencode". A TUI turns on mouse reporting and then scrolls
        // itself; a terminal that keeps the wheel for its own scrollback is a terminal the program never hears
        // from, and the screen simply sits there. Warp forwards it (`warp_features.md` #17, full mouse reporting).
        if programOwnsMouse(event), let cell = mouseCell(for: event) {
            sendMouseWheel(event, at: cell)
            return
        }
        // A full-screen program that did *not* ask for the mouse owns the whole screen, scrollback included.
        guard !session.activeGrid.isAlternateScreen else { return }
        // A trackpad reports points, a wheel reports notches. Both end up in the same pixel space so
        // a gesture and a click advance the viewport by the same amount.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * scrollStep
        setScrollPosition(scrollPosition + delta)
    }

    /// Whether the program asked for the mouse at all.
    ///
    /// **⇧ is the escape hatch, and it is why this is not just a mode check.** Every terminal has to leave a way to
    /// select text locally while a TUI owns the mouse, and the convention is to hold ⇧: that is what iTerm,
    /// Terminal.app and Warp all do. So a shift-click is never forwarded, which also means ⇧ is never *sent* as a
    /// modifier — the two cannot both be true of one key.
    private func programOwnsMouse(_ event: NSEvent) -> Bool {
        session.activeGrid.modes.mouseTracking != .none && !event.modifierFlags.contains(.shift)
    }

    /// Where the pointer is, in cells, **1-based** — which is what every mouse protocol counts in, and the
    /// off-by-one that is easiest to get wrong and hardest to notice.
    private func mouseCell(for event: NSEvent) -> (column: Int, row: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return nil }
        let font = renderer.font
        let column = Int((point.x - bounds.minX - Theme.Size.terminalContentInset) / font.cellWidth) + 1
        // The grid is drawn downward from the top of the viewport and the view is y-up.
        let row = Int((bounds.maxY - point.y) / font.cellHeight) + 1
        return (
            min(max(column, 1), session.size.columns), min(max(row, 1), session.size.rows))
    }

    /// A gesture, as the notches the protocol counts in.
    ///
    /// A trackpad sends a stream of a few points each, and forwarding one wheel event per `NSEvent` would send the
    /// program hundreds of notches for one gesture — its scroll would fly. So precise deltas accumulate until they
    /// are worth a notch. A wheel mouse already reports in notches and passes straight through.
    private func sendMouseWheel(_ event: NSEvent, at cell: (column: Int, row: Int)) {
        let notches: Int
        if event.hasPreciseScrollingDeltas {
            accumulatedWheel += event.scrollingDeltaY
            notches = Int(accumulatedWheel / scrollStep)
            accumulatedWheel -= CGFloat(notches) * scrollStep
        } else {
            notches = Int(event.scrollingDeltaY.rounded())
        }
        guard notches != 0 else { return }
        // One event per notch, because that is what the program counts in: it sees "wheel up" and moves one line.
        // Capped, because a hard flick of a trackpad is one gesture and should not become a flood.
        for _ in 0..<min(abs(notches), 20) {
            emitWheel(up: notches > 0, at: cell)
        }
    }

    private enum MouseAction { case press, release, drag, motion }

    /// Encode one mouse event for the program, and answer whether it was sent.
    ///
    /// Two encodings, like the wheel: SGR (`?1006`) writes the numbers in decimal and separates press from release
    /// with the final byte, while the original form packs three bytes, cannot address past column 223, and has no
    /// button number for a release at all — a release is the code `3` there. Getting that wrong is how a click
    /// becomes a click that never lifts.
    @discardableResult
    private func sendMouseEvent(_ event: NSEvent, _ action: MouseAction) -> Bool {
        let modes = session.activeGrid.modes
        guard modes.mouseTracking != .none, !event.modifierFlags.contains(.shift) else { return false }
        // 1000 is press and release only; motion is not the program's business under it.
        if action == .drag || action == .motion, modes.mouseTracking == .buttonPress { return false }
        guard let cell = mouseCell(for: event) else { return false }

        let held = Self.mouseButton(for: event)
        var code: Int
        switch action {
        case .press, .release: code = max(held, 0)
        // Motion carries the button in the code, and 3 — "no button" — when nothing is held.
        case .drag, .motion: code = 32 + (held >= 0 ? held : 3)
        }
        // Modifiers are part of the code, which is the only way a program can tell a ⌥-click from a click.
        let flags = event.modifierFlags
        if flags.contains(.option) { code += 8 }
        if flags.contains(.control) { code += 16 }

        if modes.mouseSGR {
            let final = action == .release ? "m" : "M"
            send(Array("\u{1B}[<\(code);\(cell.column);\(cell.row)\(final)".utf8))
            return true
        }
        let legacy = action == .release ? 3 : code
        let values = [legacy, cell.column, cell.row].map { UInt8(clamping: $0 + 32) }
        send([0x1B, 0x5B, 0x4D] + values)
        return true
    }

    /// Which button, in the **protocol's** numbering — which is not AppKit's.
    ///
    /// AppKit counts left 0, right 1, other 2. The X10 protocol counts left 0, **middle 1, right 2**. Swapping
    /// those two is invisible until somebody right-clicks in a program that draws a menu, and then the menu opens
    /// on the wrong click.
    private static func mouseButton(for event: NSEvent) -> Int {
        switch event.buttonNumber {
        case 0: return 0
        case 1: return 2
        case 2: return 1
        default: return -1
        }
    }

    private func emitWheel(up: Bool, at cell: (column: Int, row: Int)) {
        let button = up ? 64 : 65
        if session.activeGrid.modes.mouseSGR {
            send(Array("\u{1B}[<\(button);\(cell.column);\(cell.row)M".utf8))
            return
        }
        // The original X10 form packs the values into three bytes and cannot address past 223, so they are
        // *clamped* rather than wrapped — a wrapped coordinate is a click somewhere else entirely.
        let values = [button, cell.column, cell.row].map { UInt8(clamping: $0 + 32) }
        send([0x1B, 0x5B, 0x4D] + values)
    }

    /// Positive means further back into history, which is the direction a scroll up goes.
    private func setScrollPosition(_ position: CGFloat) {
        let clamped = min(max(position, 0), maximumScroll)
        guard clamped != scrollPosition else { return }
        scrollPosition = clamped
        needsDisplay = true
    }

    /// A discrete action — a page key, a menu item — lands on a whole row rather than leaving the
    /// viewport part-way between two, because there is no gesture to finish it.
    private func scroll(byLines lines: Int) {
        let snapped = (scrollPosition / scrollStep).rounded() * scrollStep
        setScrollPosition(snapped + CGFloat(lines) * scrollStep)
    }

    private func scrollToBottom() {
        setScrollPosition(0)
    }

    /// Scrolls so that a block's header sits at the top of the viewport.
    private func scrollToBlock(at index: Int) {
        guard let top = layout.headerTop(ofBlock: index) else { return }
        // Through the layout's own inverse rather than `totalHeight - top - bounds.height`: the pinned block does not
        // scroll, so the document's full height is the wrong number to measure against.
        setScrollPosition(layout.scrollPosition(puttingTopAt: top, viewportHeight: bounds.height))
    }

    /// The next header below the top of the viewport, or the previous one above it. Header positions
    /// are the only landmarks the document has, which is exactly what makes block jumping possible.
    private func scrollToAdjacentBlock(forward: Bool) {
        let tops = layout.entries.filter { $0.headerHeight > 0 }.map(\.headerTop)
        guard !tops.isEmpty else { return }
        let target = forward
            ? tops.first { $0 > viewportTop + 1 }
            : tops.last { $0 < viewportTop - 1 }
        guard let target else {
            setScrollPosition(forward ? 0 : maximumScroll)
            return
        }
        setScrollPosition(layout.scrollPosition(puttingTopAt: target, viewportHeight: bounds.height))
    }

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        // **The program's mouse comes first** — before selection, before the block menu, before anything. A TUI
        // that turned on mouse reporting is drawing its own interface and handling its own clicks; a terminal that
        // also selected a block underneath it would be doing two things with one click, which is what made
        // `opencode` and `nano` feel broken.
        if sendMouseEvent(event, .press) { return }

        let point = convert(event.locationInWindow, from: nil)
        let index = blockIndex(atViewPoint: point)

        // An open panel takes the click as a dismissal and nothing else: a menu that could only be closed by
        // choosing something from it is a menu that makes you do something.
        if blockMenuPopover.isOpen {
            hideBlockMenu()
            return
        }

        // The hover control next, and before the block selection below it: it is a control *inside* a block, so
        // a click on it must not also be read as a click on the block underneath it.
        if let index, hoverControlRect(atBlockIndex: index)?.contains(point) == true {
            selectBlock(at: index)
            presentBlockMenu(atBlockIndex: index)
            return
        }

        // Folding. **After the two checks above**, deliberately: a program that owns the mouse must never lose a
        // click to this, and the hover control is a control rather than a click on the block.
        if let index, collapseIfAsked(atBlockIndex: index, event: event) { return }

        // **⇧ extends the selection rather than starting a new one**, which is how every list and text view on the
        // platform behaves and the only way to reach a range with two clicks.
        if event.modifierFlags.contains(.shift), let existing = selection,
            let end = selectionPoint(atViewPoint: point)
        {
            selection = TextSelection(anchor: existing.anchor, focus: end)
            needsDisplay = true
            return
        }

        // A double-click takes the **word** under the pointer; a single one starts a selection collapsed to the cell,
        // which a click leaves empty and drawn as nothing — so this does not interfere with selecting a block below
        // it, and the selection only becomes visible once a drag moves it.
        selection =
            event.clickCount == 2
            ? selectionPoint(atViewPoint: point).flatMap(wordSelection(at:))
            : selectionPoint(atViewPoint: point).map { TextSelection(anchor: $0, focus: $0) }

        // A click on the block being typed belongs to the editor.
        //
        // The editor is that block's input, so a click landing on it must not cost the editor the
        // keyboard — and taking it is what produced both halves of the defect: the grid drew its own
        // cursor over a prompt that already had the editor's caret, and the next keystroke went to the
        // shell instead of the buffer. Any *other* block is a block to act on, so that click still takes
        // the keyboard, which is what keeps `Copy Output` and friends live.
        if editorIsVisible, let index, index == session.blocks.indices.last {
            selectBlock(at: index)
            syncFirstResponder()
            return
        }

        selectBlock(at: index)
        // **A click on an older block does not take the keyboard away from the editor.**
        //
        // It is a click about *that* block, not a decision to stop typing — and taking the keyboard left the prompt
        // with no caret, so the terminal looked dead and the next keystroke went to the shell instead of the line.
        // `syncFirstResponder` decides, which is the same function that decides it everywhere else.
        //
        // The block's actions are still reachable, and by three routes: the right-click menu, the hover control's
        // panel, and `⌘⇧C` / `⌥⌘C`, whose selectors only this view implements — so the responder chain passes
        // through the editor to get to them. Plain `⌘C` is the *editor's* when the editor has the keyboard, which is
        // what it means in a text field and what Warp does.
        syncFirstResponder()
    }

    /// The word under a point, as a selection of that word alone.
    private func wordSelection(at point: TextSelection.Point) -> TextSelection? {
        guard session.blocks.indices.contains(point.blockIndex),
            let text = session.blocks[point.blockIndex].bodyLineText(point.bodyLine)
        else { return nil }
        let range = TextSelection.wordRange(in: text, atColumn: point.column)
        return TextSelection(
            anchor: TextSelection.Point(
                blockIndex: point.blockIndex, bodyLine: point.bodyLine, column: range.lowerBound),
            focus: TextSelection.Point(
                blockIndex: point.blockIndex, bodyLine: point.bodyLine, column: range.upperBound))
    }

    /// Fold on a double-click, unfold on a click. Answers whether the click was this.
    ///
    /// **Only a single click expands.** Collapsing needs the double-click, because a single click is also how a block
    /// is selected, and a block that folded every time somebody selected it would be unusable. The cost is that a
    /// double-click on an already-folded block ends up folded again — the first click of the pair unfolds it and the
    /// second folds it — which is the direction the user was going in anyway.
    private func collapseIfAsked(atBlockIndex index: Int, event: NSEvent) -> Bool {
        let block = session.blocks[index]
        // **Only on the header.** A double-click in the body is the platform's "select this word", and a terminal
        // that folded a block instead would be a terminal whose text could not be selected the way every other text
        // on the system is. The header is the block's own chrome and has no text worth selecting.
        if let entry = layout.entries.first(where: { $0.blockIndex == index }) {
            // `locationInWindow` is not a coordinate in this view — the surface sits inside a panel inside a window —
            // and `documentY(atViewPoint:)` is the one conversion that knows which viewport a point belongs to. Using
            // the raw window y here meant the header test failed for every double-click, so collapsing stopped
            // working from the body as well as from the header.
            let documentY = documentY(atViewPoint: convert(event.locationInWindow, from: nil))
            guard documentY < entry.contentTop else { return false }
        }
        if block.isCollapsed, event.clickCount == 1 {
            block.toggleCollapsed()
            needsDisplay = true
            return true
        }
        if event.clickCount == 2, block.isCollapsible, !block.isCollapsed {
            block.toggleCollapsed()
            needsDisplay = true
            return true
        }
        return false
    }

    /// Where a block's hover control is, in this view's coordinates — the one place the two coordinate systems
    /// are reconciled for it, so the thing that is drawn and the thing that is clicked are the same rect.
    private func hoverControlRect(atBlockIndex index: Int) -> CGRect? {
        guard let entry = layout.entries.first(where: { $0.blockIndex == index }) else { return nil }
        // **The entry's own viewport.** The pinned block's control is placed by a constant rather than by the scroll
        // position, so testing it against the scrolling viewport drew the dots in one place and looked for the click
        // in another — the control appeared and did nothing, which is exactly what was reported.
        let top = entry.blockIndex == session.blocks.indices.last ? pinnedViewportTop : viewportTop
        return renderer.hoverControlRect(
            top: renderer.screenY(entry.headerTop, viewportTop: top, bounds: bounds),
            bounds: bounds)
    }

    /// Open the block's actions, hanging from the hover control that was clicked.
    private func presentBlockMenu(atBlockIndex index: Int) {
        guard let rect = hoverControlRect(atBlockIndex: index) else { return }
        blockMenuIndex = index
        blockMenuActions = blockActions(forBlockAt: index)
        blockMenuPopover.show(blockMenuActions.map(\.title), at: rect, within: bounds)
    }

    /// Run the chosen action — and close the panel first, so anything the action opens is not drawn behind it.
    private func performBlockAction(_ row: Int) {
        let actions = blockMenuActions
        hideBlockMenu()
        guard actions.indices.contains(row) else { return }
        _ = perform(actions[row].action, with: nil)
    }

    private func hideBlockMenu() {
        blockMenuIndex = nil
        blockMenuPopover.hide()
    }

    /// Follow the block it belongs to. Called from `draw` like every other frame in this view, so a scroll moves
    /// the panel with the header it hangs from.
    private func positionBlockMenu() {
        guard let index = blockMenuIndex, let rect = hoverControlRect(atBlockIndex: index) else { return }
        blockMenuPopover.reposition(at: rect, within: bounds)
    }

    /// Select the block at an index, or clear the selection when there is none there.
    private func selectBlock(at index: Int?) {
        let identifier = index.flatMap { session.blocks.indices.contains($0) ? session.blocks[$0].id : nil }
        guard identifier != selectedBlockID else { return }
        selectedBlockID = identifier
        needsDisplay = true
    }

    /// A right-click selects the block it landed on and offers that block's actions.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = blockIndex(atViewPoint: point), session.blocks.indices.contains(index) else {
            return nil
        }
        selectBlock(at: index)
        return blockMenu(forBlockAt: index)
    }

    /// A block's actions, in the order they are offered.
    ///
    /// **One function, read by both menus** — the right-click one and the hover control's glass panel — so the two
    /// cannot drift. Built rather than constant because the first entry says *Collapse* or *Expand* according to the
    /// block, and a menu whose first item lies about what it will do is worse than one without it.
    private func blockActions(forBlockAt index: Int?) -> [(title: String, action: Selector)] {
        let block = index.flatMap { session.blocks.indices.contains($0) ? session.blocks[$0] : nil }
        return [
            (
                block?.isCollapsed == true ? "Expand" : "Collapse",
                #selector(toggleSelectedBlockCollapsed(_:))
            ),
            ("Copy Command", #selector(copySelectedCommand(_:))),
            ("Copy Output", #selector(copySelectedOutput(_:))),
            ("Copy Working Directory", #selector(copySelectedWorkingDirectory(_:))),
            ("Scroll to Block", #selector(scrollToSelectedBlock(_:))),
        ]
    }

    /// The right-click menu: the same actions, in the platform's own menu, which is what a right-click is
    /// expected to produce.
    private func blockMenu(forBlockAt index: Int?) -> NSMenu {
        let actions = blockActions(forBlockAt: index)
        let menu = NSMenu()
        for (position, entry) in actions.enumerated() {
            if position == actions.count - 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// Collapse the selected block, or expand it.
    ///
    /// Acts on the *selection* rather than on a row index, so the menu item and the double-click reach the same
    /// place. `Block.toggleCollapsed` refuses when there is nothing to hide, so a block too short to collapse is
    /// unaffected even if this is called on it.
    @objc func toggleSelectedBlockCollapsed(_ sender: Any?) {
        guard let selectedBlockID,
            let index = session.blocks.firstIndex(where: { $0.id == selectedBlockID })
        else { return }
        session.blocks[index].toggleCollapsed()
        needsDisplay = true
    }

    var selectedBlock: Block? {
        guard let selectedBlockID else { return nil }
        return session.blocks.first { $0.id == selectedBlockID }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !handleNavigationKey(event) else { return }
        // A keystroke that reaches the surface while a prompt is showing belongs in the editor —
        // it only lands here when focus drifted (a block was clicked, say), and writing it to the
        // pty instead is how the editor's buffer and the shell's line editor diverge. Warp's
        // `typed_characters_on_terminal` is the same rule: the editor is the input while a prompt
        // is up, no matter which view the window happened to give the key to.
        if editorIsVisible, !event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(editor)
            editor.keyDown(with: event)
            return
        }
        guard let bytes = translatedBytes(for: event) else {
            // Nothing in the table matched, so the input system composes it: dead keys, accented
            // input and IME candidates all arrive through `insertText`.
            interpretKeyEvents([event])
            return
        }
        send(bytes)
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        session.write(bytes)
        scrollToBottom()
    }

    /// Send the buffer to the shell and put the editor back to empty, ready for the next prompt.
    private func submit(_ buffer: String) {
        send(CommandSubmission.bytes(for: buffer))
        editor.reset()
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard let key = event.specialKey else { return false }
        let command = event.modifierFlags.contains(.command)
        let page = session.activeGrid.size.rows - 1

        // Block jumping owns Command plus a vertical arrow, so Phase 1's "jump to the ends of the
        // scrollback" binding has moved to Home and End.
        if command, key == .upArrow { scrollToAdjacentBlock(forward: false); return true }
        if command, key == .downArrow { scrollToAdjacentBlock(forward: true); return true }
        if command, key == .home { setScrollPosition(maximumScroll); return true }
        if command, key == .end { scrollToBottom(); return true }

        // A full-screen program owns the page keys too: it wants them as input, not as scrolling.
        guard !session.activeGrid.isAlternateScreen else { return false }
        if key == .pageUp { scroll(byLines: page); return true }
        if key == .pageDown { scroll(byLines: -page); return true }
        return false
    }

    /// Nil means "not a key this table knows", which is the signal to hand the event to the input
    /// system rather than to swallow it.
    private func translatedBytes(for event: NSEvent) -> [UInt8]? {
        // Command chords belong to the app's menus, not to the shell.
        guard !event.modifierFlags.contains(.command) else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isControl = flags.contains(.control)
        let isOption = flags.contains(.option)

        if let key = event.specialKey {
            // Option plus a horizontal arrow is word movement, which the input system knows how to
            // express and `doCommand(by:)` turns into the shell's own binding.
            if isOption, key == .leftArrow || key == .rightArrow { return nil }
            return bytes(forSpecialKey: key)
        }
        // Tab, Return, Escape, Backspace and every Ctrl chord arrive as control characters rather
        // than as special keys, so they are read out of the characters the event carries.
        if let sequence = controlSequence(for: event, isOption: isOption) { return sequence }
        guard isControl, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }
        switch scalar.value {
        case 0x40...0x5F: return [UInt8(scalar.value - 0x40)]    // @ A–Z [ \ ] ^ _
        case 0x61...0x7A: return [UInt8(scalar.value - 0x60)]    // a–z
        case 0x3F: return [0x7F]                                 // Ctrl+? is backspace
        default: return nil
        }
    }

    /// The bytes a key stands for when AppKit hands it over as a control character.
    ///
    /// Shift-Tab is the exception: it arrives as the back-tab control character, and every shell
    /// expects `CSI Z` instead, so the one character that means two bytes is spelled out here.
    private func controlSequence(for event: NSEvent, isOption: Bool) -> [UInt8]? {
        guard !isOption, let characters = event.characters,
            characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first
        else { return nil }
        let value = scalar.value
        if value == 0x19 { return Array("\u{1B}[Z".utf8) }
        guard value < 0x20 || value == 0x7F else { return nil }
        return [UInt8(value)]
    }

    private func bytes(forSpecialKey key: NSEvent.SpecialKey) -> [UInt8]? {
        let application = session.activeGrid.modes.applicationCursorKeys
        switch key {
        case .upArrow: return cursorSequence("A", application: application)
        case .downArrow: return cursorSequence("B", application: application)
        case .rightArrow: return cursorSequence("C", application: application)
        case .leftArrow: return cursorSequence("D", application: application)
        case .home, .begin: return cursorSequence("H", application: application)
        case .end: return cursorSequence("F", application: application)
        case .pageUp: return Array("\u{1B}[5~".utf8)
        case .pageDown: return Array("\u{1B}[6~".utf8)
        case .deleteForward: return Array("\u{1B}[3~".utf8)
        case .insert: return Array("\u{1B}[2~".utf8)
        case .delete, .backspace: return [0x7F]
        case .enter, .carriageReturn, .newline: return [0x0D]
        case .tab: return [0x09]
        case .backTab: return Array("\u{1B}[Z".utf8)
        default: return functionKeyBytes(for: key)
        }
    }

    /// `DECCKM`: a full-screen program that asked for application cursor keys gets `SS3` rather than
    /// `CSI`, and a program that checks for the wrong one never sees the arrow at all.
    private func cursorSequence(_ final: String, application: Bool) -> [UInt8] {
        Array((application ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8)
    }

    private func functionKeyBytes(for key: NSEvent.SpecialKey) -> [UInt8]? {
        let order: [NSEvent.SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
        guard let index = order.firstIndex(of: key) else { return nil }
        let number = index + 1
        if number <= 4 {
            let finals = Array("PQRS".utf8)
            return Array("\u{1B}O".utf8) + [finals[index]]
        }
        let codes = [15, 17, 18, 19, 20, 21, 23, 24]
        guard number - 5 < codes.count else { return nil }
        return Array("\u{1B}[\(codes[number - 5])~".utf8)
    }

    /// The selectors the input system produces for keys this view does not translate itself. Only the
    /// ones a shell has a binding for are mapped; everything else is dropped rather than beeped,
    /// because a terminal that beeps at a key it does not use is a terminal that feels broken.
    override func doCommand(by selector: Selector) {
        switch NSStringFromSelector(selector) {
        case "moveWordLeft:", "moveBackward:":
            send(Array("\u{1B}b".utf8))
        case "moveWordRight:", "moveForward:":
            send(Array("\u{1B}f".utf8))
        case "deleteWordBackward:":
            send(Array("\u{1B}\u{7F}".utf8))
        default:
            break
        }
    }

    // MARK: - Menu actions

    @objc func paste(_ sender: Any?) {
        // With a prompt showing, the buffer being pasted into is the editor's — even when the
        // surface happened to keep the keyboard (a block was clicked first, say). When the editor
        // is the first responder this never runs: its own `paste:` answers the menu first.
        if editorIsVisible, let text = NSPasteboard.general.string(forType: .string) {
            editor.insertText(text, replacementRange: editor.selectedRange())
            return
        }
        coordinator?.paste()
    }

    /// **The text selection wins over the block.** `⌘C` means "copy what is selected", and a selected *block* is the
    /// fallback for when no text is — which is what it has always been here.
    @objc func copy(_ sender: Any?) {
        guard !copySelectedText() else { return }
        coordinator?.copyBlock(.output, id: selectedBlockID)
    }

    /// Put the selected text on the pasteboard. Answers whether there was any.
    @discardableResult
    private func copySelectedText() -> Bool {
        guard let selection, !selection.isEmpty else { return false }
        let text = selection.text(
            height: { [session] index in
                session.blocks.indices.contains(index) ? session.blocks[index].visibleLineCount : 0
            },
            line: { [session] index, line in
                session.blocks.indices.contains(index) ? session.blocks[index].bodyLineText(line) : nil
            })
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// The cell a point in this view is over.
    ///
    /// The inverse of everything the renderer does to place a row: the entry whose span contains the document y, then
    /// the line and column inside it. **Clamped rather than refused**, so a drag that leaves the view keeps extending
    /// the selection to the edge — which is what dragging past the end of a line means.
    private func selectionPoint(atViewPoint point: CGPoint) -> TextSelection.Point? {
        guard !session.blocks.isEmpty else { return nil }
        let documentY = viewportTop + (bounds.maxY - point.y)
        guard let entry = layout.entries.last(where: { $0.headerTop <= documentY }) else { return nil }
        let line = Int((documentY - entry.contentTop) / renderer.font.cellHeight)
        let column = Int(
            (point.x - bounds.minX - Theme.Size.terminalContentInset) / renderer.font.cellWidth)
        return TextSelection.Point(
            blockIndex: entry.blockIndex,
            bodyLine: min(max(0, line), max(0, entry.contentLineCount - 1)),
            column: max(0, column))
    }

    /// Select all — of **the current block**, never of the scrollback.
    ///
    /// Warp has no select-all on the terminal view; its `EditorAction::SelectAll` belongs to the input
    /// editor. So the two cases here are the two things "all" can mean:
    ///
    /// - A prompt is showing, so the text that is anybody's to select is the command line — and
    ///   `NSTextView` already selects all of it. This is the case the item exists for.
    /// - There is no command line: a command is running, or a full-screen program owns the screen. Then
    ///   "all" is the block the user is working in — the last one — because selecting every block in the
    ///   scrollback is a selection nobody asked for and one that no block action can act on.
    ///
    /// When the editor is the first responder this never runs: the responder chain finds `NSTextView`'s
    /// own `selectAll:` first, which is the same answer by a shorter route.
    @objc override func selectAll(_ sender: Any?) {
        if editorIsVisible {
            editor.selectAll(sender)
            return
        }
        selectBlock(at: session.blocks.indices.last)
    }

    /// Cut is the editor's, and only the editor's.
    ///
    /// A terminal's grid is the shell's output — there is nothing in it that a cut could delete, and Warp
    /// has no terminal cut either. So this forwards to the editor when a prompt is showing, and is
    /// disabled otherwise rather than doing nothing quietly.
    @objc func cut(_ sender: Any?) {
        guard editorIsVisible else { return }
        editor.cut(sender)
    }

    @objc func clearScrollback(_ sender: Any?) { coordinator?.clearScrollback() }

    @objc func increaseFontSize(_ sender: Any?) { coordinator?.increaseFontSize() }

    @objc func decreaseFontSize(_ sender: Any?) { coordinator?.decreaseFontSize() }

    @objc func resetFontSize(_ sender: Any?) { coordinator?.resetFontSize() }

    @objc func copySelectedCommand(_ sender: Any?) {
        coordinator?.copyBlock(.command, id: selectedBlockID)
    }

    @objc func copySelectedOutput(_ sender: Any?) {
        coordinator?.copyBlock(.output, id: selectedBlockID)
    }

    @objc func copySelectedWorkingDirectory(_ sender: Any?) {
        coordinator?.copyBlock(.workingDirectory, id: selectedBlockID)
    }

    @objc func scrollToSelectedBlock(_ sender: Any?) {
        guard let selectedBlockID,
            let index = session.blocks.firstIndex(where: { $0.id == selectedBlockID })
        else { return }
        scrollToBlock(at: index)
    }

    /// Every block action is enabled only with a block selected, so an item explains itself by being
    /// greyed rather than by doing nothing when it is clicked.
    ///
    /// `Cut` follows the same rule for the same reason: with no prompt showing there is no buffer to cut
    /// from, and a live-looking Cut that does nothing is the defect this menu was built to avoid.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            // **A text selection counts too.** This asked only about the selected *block*, so with text selected and
            // no block selected the item was greyed out — and `⌘C` did nothing, which is the one case where it is
            // worth pressing.
            return selectedBlockID != nil || selection?.isEmpty == false
        case #selector(copySelectedCommand(_:)),
            #selector(copySelectedOutput(_:)), #selector(copySelectedWorkingDirectory(_:)),
            #selector(scrollToSelectedBlock(_:)):
            return selectedBlockID != nil
        case #selector(toggleSelectedBlockCollapsed(_:)):
            guard let selectedBlock else { return false }
            return selectedBlock.isCollapsed || selectedBlock.isCollapsible
        case #selector(cut(_:)):
            guard editorIsVisible else { return false }
            return editor.selectedRange().length > 0
        case #selector(selectAll(_:)):
            return editorIsVisible || !session.blocks.isEmpty
        default:
            return true
        }
    }

    // MARK: - Pasteboard

    /// Pastes as literal text, with newlines normalised to carriage returns so a paste into a
    /// readline never leaves a stray line feed. A shell that asked for bracketed paste gets the
    /// wrapper, which is the only thing standing between a pasted script and running every line of it
    /// the moment it arrives.
    func insertPastedText(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        if session.activeGrid.modes.bracketedPaste {
            session.write("\u{1B}[200~\(normalized)\u{1B}[201~")
        } else {
            session.write(normalized)
        }
        scrollToBottom()
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        default: return
        }
        markedText = nil
        send(Array(text.utf8))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as String: markedText = NSMutableAttributedString(string: value)
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        default: markedText = nil
        }
        needsDisplay = true
    }

    func unmarkText() {
        markedText = nil
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { markedText != nil }

    func markedRange() -> NSRange {
        guard let markedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: session.activeGrid.cursorColumn, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { session.activeGrid.cursorColumn }

    /// Where the IME's candidate window should appear. Without this the candidate list lands in the
    /// corner of the screen and typing in a non-Latin language becomes unusable.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cell = cursorRect
        guard let window else { return cell }
        return window.convertToScreen(convert(cell, to: nil))
    }

    private var cursorRect: NSRect {
        let font = renderer.font
        return NSRect(
            x: Theme.Size.terminalContentInset + CGFloat(session.activeGrid.cursorColumn) * font.cellWidth,
            y: bounds.maxY - CGFloat(session.activeGrid.cursorRow + 1) * font.cellHeight,
            width: font.cellWidth,
            height: font.cellHeight)
    }
}
