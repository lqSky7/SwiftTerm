import AppKit

/// The command line as an editor rather than a grid. Warp wrote its own (`crates/editor`,
/// `crates/vim`) only because it has to draw on three platforms through its own GPU renderer, and
/// neither reason applies to a macOS-only AppKit app. Undo, redo, selections, mouse positioning,
/// word movement, IME and multi-line editing all come from `NSTextView`.
///
/// **Increment 1 of the unparking (`docs/phase-3-todo.md`): live, wired into `TerminalSurfaceView`,
/// and deliberately plain.** No syntax highlighting (Increment 2 — that is why `didChangeText` does
/// not restyle the buffer), no not-found squiggle (Increment 3 — `resolver` is stored and waiting),
/// no completion popover (Increment 4). This is the increment that isolates the three things that
/// failed every time the view layer was written ahead of a running window: the frame, the focus, the
/// reserved height. See `EDITOR.md` §6 and §9.
///
/// What it *does* own, because a shell's line editor is not usable without them: `⌘A` and `⌘X` through
/// `NSTextView`'s own `selectAll:` and `cut:` (the menu carries both — see `AppMenus`), and ↑/↓ walking the
/// commands already run, with the rule itself in `HistoryNavigation` rather than here.
///
/// The model half is already built, tested and waiting: `ShellTokenizer`, `CommandResolver`,
/// `Completion` and `CommandSubmission`. See `docs/phase-3-todo.md` and `docs/learnings.md`.
@MainActor
final class CommandEditorView: NSTextView {
    /// The buffer, submitted. The caller turns it into bytes.
    var onSubmit: ((String) -> Void)?
    /// Keys the shell owns rather than the editor: signals, and history search.
    var onRawBytes: (([UInt8]) -> Void)?
    /// Tab with nothing to accept is still the shell's business.
    var onUnhandledTab: (() -> Void)?
    /// Command chords the surface owns: block jumping, and the ends of the scrollback. The editor has
    /// no use for them — there is one command line to move around in — so they go straight back
    /// rather than becoming "move to start of document" in a text view.
    var onNavigationKey: ((NSEvent) -> Bool)?
    /// The buffer changed, so anything derived from it — the suggestion, mostly — is now stale.
    var onBufferChanged: (() -> Void)?
    /// The commands already run, oldest first, for ↑ and ↓. Asked for when a walk begins rather than kept
    /// here: the history is the session's, and a copy of it in a view would be a second answer that drifts
    /// the first time a block is evicted.
    var onHistory: (() -> [String])?
    /// Tab, with nothing to accept as ghost text. The owner answers whether it opened the completion list; a
    /// `false` means there was nothing to offer and the key goes on to the shell.
    var onCompletionRequest: (() -> Bool)?
    /// ⌘C with nothing selected in the editor. The owner answers whether the grid behind had a text selection;
    /// `false` leaves the key to the editor, which is where a text field's copy belongs.
    var onCopyWithoutSelection: (() -> Bool)?

    /// A key while the completion list is open. `true` means the list took it, and it is asked **before**
    /// anything else in `keyDown`: `↩` there means "take this candidate" rather than "run the line", and `esc`
    /// means "not this" rather than "clear the ghost text".
    var onCompletionKey: ((NSEvent) -> Bool)?

    /// Where ↑ and ↓ have got to. State, and the only state this view keeps that is not its text — which is
    /// why the rule lives in `HistoryNavigation` and this only holds the cursor.
    private var history = HistoryNavigation()

    /// The rest of a history suggestion, drawn after the caret. Nil when there is nothing to suggest.
    var ghostText: String? {
        didSet { if ghostText != oldValue { needsDisplay = true } }
    }

    private var terminalFont: TerminalFont
    private let palette: TerminalPalette
    private var paragraph: NSParagraphStyle
    private let ink: NSColor
    /// Stored for Increment 3, the not-found squiggle. Nothing reads it yet, on purpose: this
    /// increment ships the frame, the focus and the reserved height, and nothing else.
    private var resolver: CommandResolver

    init(font: TerminalFont, palette: TerminalPalette, resolver: CommandResolver) {
        self.terminalFont = font
        self.palette = palette
        self.ink = palette.foreground.nsColor
        self.resolver = resolver

        // One line of text is exactly one cell tall, so a column in the buffer is a column on screen
        // and the editor's caret lines up with the prompt the grid drew.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = font.cellHeight
        paragraph.maximumLineHeight = font.cellHeight
        paragraph.lineBreakMode = .byCharWrapping
        self.paragraph = paragraph

        // The TextKit 1 stack, built by hand. `lineCount` and the caret arithmetic below read
        // `layoutManager`, which is nil when a text view runs under TextKit 2 — and a view that
        // builds its own stack from a nil container runs under whichever flavour this macOS
        // defaults to. Building the stack is six lines; a `lineCount` that answers 1 for a
        // wrapped buffer is a block that clips its second line.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        // The designated initializer, called on `super` rather than as `super.init(frame:)`.
        //
        // `NSTextView.init(frame:)` is a convenience path that re-dispatches to `self.init(frame:textContainer:)`.
        // Because this subclass declares a designated initializer of its own, Swift emits an
        // *unimplemented* stub for the inherited `init(frame:textContainer:)` — so the convenience
        // init's dispatch lands on that stub and traps at launch. Calling the designated initializer
        // directly skips the dispatch.
        super.init(frame: .zero, textContainer: container)

        self.font = font.base
        textColor = ink
        insertionPointColor = palette.cursor.nsColor

        // A terminal has no margins, no background of its own and no scrollers. The container's
        // padding and width tracking were set when the stack was built, above.
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false

        // Everything AppKit would like to do to a person's typing. A shell command is not prose.
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = false

        typingAttributes = baseAttributes
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommandEditorView is created in code, never from a nib")
    }

    /// How many lines the buffer occupies, wrapped lines included, which is how much room the
    /// document has to leave for it.
    ///
    /// Counting hard newlines is not enough: a buffer longer than the width wraps inside the text
    /// container, and a block that reserved one line for a two-line buffer would clip the second.
    /// The layout manager has already laid the glyphs out by the time the surface asks, so this is
    /// a measurement rather than a computation — every line fragment is exactly one cell tall,
    /// because the paragraph style pinned the line height to the cell height.
    var lineCount: Int {
        let length = (string as NSString).length
        guard let container = textContainer, let layoutManager, length > 0 else { return 1 }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
        let glyphs = layoutManager.glyphRange(for: container)
        let used = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        var lines = max(1, Int((used.height / terminalFont.cellHeight).rounded(.up)))
        // A trailing newline leaves the caret on a fragment of its own, which the bounding rect
        // does not include.
        if layoutManager.extraLineFragmentTextContainer != nil { lines += 1 }
        return lines
    }

    /// Puts the buffer back to empty. Called on submit, because the shell will draw the next prompt
    /// itself and the editor starts again beside it.
    func reset() {
        string = ""
        ghostText = nil
        // A submitted command is the end of the walk. Without this the next ↑ would carry on from wherever
        // the last one left off, which is not what a shell does and not what anybody expects.
        history.reset()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// A new `PATH` to resolve commands against.
    ///
    /// The shell can change its own at any prompt, and the not-found squiggle would otherwise underline a command
    /// the shell can run perfectly well.
    func update(resolver: CommandResolver) {
        self.resolver = resolver
    }

    /// A new text size. The paragraph style carries the cell height, so the font and the line height
    /// have to move together — otherwise the caret stops lining up with the grid behind it.
    func update(font: TerminalFont) {
        terminalFont = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = font.cellHeight
        paragraph.maximumLineHeight = font.cellHeight
        paragraph.lineBreakMode = .byCharWrapping
        self.paragraph = paragraph
        self.font = font.base
        typingAttributes = baseAttributes
        needsDisplay = true
    }

    /// **No context menu of its own**, and that is a deliberate override rather than an omission.
    ///
    /// `NSTextView`'s default menu is a *text editor's*: Substitutions, Spelling and Grammar, **Autofill**,
    /// and the whole Services submenu. None of them mean anything for a shell command, most of them do nothing
    /// at all here, and the two that do something — smart quotes and dash substitution — are already turned off
    /// above. A right-click in a terminal belongs to the block underneath it, so returning nil hands the click
    /// up the view hierarchy to `TerminalSurfaceView`, which is where the block actions live.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// **The editor's own selection first, then the grid's.**
    ///
    /// This is a text field, so `⌘C` copies what is selected in it. When nothing is, the terminal behind may still
    /// have a text selection — and since the editor holds the keyboard whenever a prompt is showing, forwarding is the
    /// only way to copy output without clicking away from the line first.
    override func copy(_ sender: Any?) {
        if selectedRange().length > 0 || onCopyWithoutSelection?() != true {
            super.copy(sender)
        }
    }

    // MARK: - Keys

    /// A terminal's key handling, not a text field's.
    ///
    /// Return arrives as a control character rather than as a special key — the same thing the
    /// surface view already documents for the grid — so the checks below read `characters` first and
    /// fall back to `specialKey` for Tab and the arrows.
    override func keyDown(with event: NSEvent) {
        // Command chords belong to the app's menus, and the ones that move around the document belong
        // to the surface.
        if event.modifierFlags.contains(.command) {
            if onNavigationKey?(event) == true { return }
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.characters ?? ""
        let scalar = characters.unicodeScalars.count == 1 ? characters.unicodeScalars.first : nil

        // The completion list gets first refusal on every key, so that Return can mean "take this candidate"
        // and Escape "not this" while it is open. It answers `false` for anything it does not want — and it
        // closes itself on the way out, so typing one more character is what dismisses it.
        if onCompletionKey?(event) == true { return }

        // Signals are the shell's, and Ctrl-C especially must never be swallowed by an editor.
        if flags.contains(.control), let value = scalar?.value {
            if value == 0x03 || value == 0x04 || value == 0x1A {
                onRawBytes?([UInt8(value)])
                // The pty's own line discipline has nothing buffered — this editor is the buffer — so
                // without this Ctrl-C would abort whatever is running but leave a typed command sitting
                // in the box, which is not what Ctrl-C does anywhere else.
                if value == 0x03 && !string.isEmpty {
                    reset()
                }
                return
            }
            // Ctrl-R is the shell's history search. The editor's own history is ghost text and Tab.
            if value == 0x12 {
                onRawBytes?([0x12])
                return
            }
        }

        // ↑ and ↓ walk the commands already run, which is what they do in every terminal and what makes a
        // history usable without leaving the keyboard. They only do that while the buffer is **one line**:
        // a multi-line buffer's earlier lines are reachable no other way, so there the arrows stay arrows.
        //
        // This is after the Command branch above, so `⌘↑`/`⌘↓` are still the surface's block jumping.
        if isSingleLine, let key = event.specialKey, key == .upArrow || key == .downArrow {
            let recalled =
                key == .upArrow
                ? history.previous(in: onHistory?() ?? [], from: string)
                : history.next(in: onHistory?() ?? [])
            if let recalled {
                recall(recalled)
                return
            }
        }

        if characters == "\r" || characters == "\n" || event.specialKey == .carriageReturn
            || event.specialKey == .enter || event.specialKey == .newline
        {
            // `⇧↩` is a newline in the buffer; a bare Return submits, which is the whole difference
            // between this and a text field.
            if flags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?(string)
            }
            return
        }

        if characters == "\t" || event.specialKey == .tab {
            // Tab opens the completion menu first, matching Warp's behavior.
            if onCompletionRequest?() == true {
                ghostText = nil
                return
            }
            if acceptGhostText() { return }
            onUnhandledTab?()
            return
        }

        // `→` accepts the suggestion too, but only where it means "accept": at the end of the line,
        // with something to accept. Anywhere else the arrow is how you move the caret.
        if event.specialKey == .rightArrow, caretIsAtEnd, acceptGhostText() { return }

        if event.specialKey == .backTab {
            onRawBytes?(Array("\u{1B}[Z".utf8))
            return
        }

        // Escape dismisses a suggestion rather than reaching the shell, which is what it means in
        // every completion UI on the platform.
        if characters == "\u{1B}" {
            ghostText = nil
            return
        }

        super.keyDown(with: event)
    }

    private var caretIsAtEnd: Bool {
        let selection = selectedRange()
        return selection.location == (string as NSString).length && selection.length == 0
    }

    /// Whether the buffer is a single line, which is what decides whether ↑ and ↓ are history or caret
    /// movement. A trailing newline from `⇧↩` counts: the buffer has a second line to move into.
    private var isSingleLine: Bool { !string.contains("\n") }

    /// Put a recalled command in the buffer, with the caret at the end of it — where the shell would leave
    /// it, and where the next keystroke belongs.
    private func recall(_ text: String) {
        setBuffer(text, caret: (text as NSString).length)
    }

    /// Replace the whole buffer and put the caret somewhere in it.
    ///
    /// `didChangeText` is called by hand because the buffer was set directly rather than typed into. Without
    /// it nothing is told the text changed: the surface would not redraw, and the document would go on
    /// reserving room for the line the buffer used to be. Completion needs the caret placed inside the text
    /// rather than at the end of it, which is the only reason this takes a position.
    func setBuffer(_ text: String, caret: Int) {
        string = text
        setSelectedRange(NSRange(location: min(max(0, caret), (text as NSString).length), length: 0))
        didChangeText()
    }

    private func acceptGhostText() -> Bool {
        guard let ghostText, !ghostText.isEmpty else { return false }
        insertText(ghostText, replacementRange: selectedRange())
        self.ghostText = nil
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        // Increment 2 adds the tokenizer-driven restyling here, debounced; a plain buffer is
        // Increment 1's scope, so the only thing a change owes anyone now is the notification.
        onBufferChanged?()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: terminalFont.base, .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    // MARK: - Drawing

    /// The ghost text goes after the caret, which is where a fish-style suggestion belongs.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghostText, !ghostText.isEmpty else { return }
        // **The paragraph style is not optional here, and leaving it off is why the suggestion sat high.**
        // The real text is centred inside a cell that is `lineHeightRatio` times the font size; a string drawn
        // without that style gets the font's *natural* line box, which is shorter, so its baseline lands above the
        // baseline of the text beside it. The ghost has to be laid out the same way to sit on the same line.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: terminalFont.base,
            .foregroundColor: ink.withAlphaComponent(0.4),
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: ghostText, attributes: attributes).draw(at: caretOrigin)
    }

    /// Where the caret sits, in this view's own coordinates.
    ///
    /// Read from the layout manager rather than from `firstRect(forCharacterRange:)`, which answers in
    /// screen coordinates — the surface view already has to convert for the IME, and a second place
    /// that has to remember which space it is in is a second place to get it wrong.
    private var caretOrigin: NSPoint {
        guard let layoutManager, let textContainer else { return .zero }
        let end = (string as NSString).length
        let range = NSRange(location: end, length: 0)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return NSPoint(
            x: rect.minX + textContainerInset.width,
            y: rect.minY + textContainerInset.height)
    }
}
