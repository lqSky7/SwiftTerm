import AppKit

/// The floating in-terminal find bar on glass.
///
/// Anchored to the top-trailing corner of the terminal surface so it floats above output and scrollback.
/// Handles query typing, match counting, next/prev navigation chords, and keyboard dismissal.
@MainActor
final class TerminalFindBar: NSGlassEffectView, NSTextFieldDelegate {
    static let width: CGFloat = 320
    static let height: CGFloat = 34

    var onSearch: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = SearchTextField()
    private let counterLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        style = .regular
        cornerRadius = Theme.Radius.control
        isHidden = true

        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalFindBar is created in code, never from a nib")
    }

    private func setupViews() {
        searchField.placeholderString = "Find in terminal…"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.onEnter = { [weak self] shift in
            if shift {
                self?.onPrevious?()
            } else {
                self?.onNext?()
            }
        }
        searchField.onEscape = { [weak self] in
            self?.onClose?()
        }

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.alignment = .right
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.frame = NSRect(x: 0, y: 0, width: 64, height: 18)

        configureButton(prevButton, symbolName: "chevron.up", tooltip: "Previous (⇧⌘G)", action: #selector(prevClicked(_:)))
        configureButton(nextButton, symbolName: "chevron.down", tooltip: "Next (⌘G)", action: #selector(nextClicked(_:)))
        configureButton(closeButton, symbolName: "xmark", tooltip: "Close (Esc)", action: #selector(closeClicked(_:)))

        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        searchIcon.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [searchIcon, searchField, counterLabel, prevButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),
            prevButton.widthAnchor.constraint(equalToConstant: 18),
            prevButton.heightAnchor.constraint(equalToConstant: 18),
            nextButton.widthAnchor.constraint(equalToConstant: 18),
            nextButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func configureButton(_ button: NSButton, symbolName: String, tooltip: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    @objc private func prevClicked(_ sender: NSButton) {
        onPrevious?()
    }

    @objc private func nextClicked(_ sender: NSButton) {
        onNext?()
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }

    func show(within bounds: CGRect, query: String? = nil) {
        let x = bounds.maxX - Self.width - 16
        let y = bounds.maxY - Self.height - 12
        frame = NSRect(x: x, y: y, width: Self.width, height: Self.height)
        if let query, !query.isEmpty {
            searchField.stringValue = query
        }
        isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        onSearch?(searchField.stringValue)
    }

    func hide() {
        isHidden = true
    }

    var isOpen: Bool { !isHidden }

    var currentQuery: String { searchField.stringValue }

    func updateMatchCount(current: Int, total: Int) {
        if searchField.stringValue.isEmpty {
            counterLabel.stringValue = ""
        } else if total == 0 {
            counterLabel.stringValue = "No match"
        } else {
            counterLabel.stringValue = "\(current + 1)/\(total)"
        }
    }

    func update(palette: TerminalPalette) {
        searchField.textColor = palette.foreground.nsColor
        counterLabel.textColor = palette.foreground.nsColor.withAlphaComponent(0.6)
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearch?(searchField.stringValue)
    }
}

private final class SearchTextField: NSTextField {
    var onEnter: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    /// The field's own half of turning text intelligence off, and then the editor's half.
    ///
    /// **Both are needed.** A field's traits live on the field editor AppKit lends it, and that editor
    /// does not exist until the field is the first responder — so this is the only moment it can be
    /// reached. See `TextIntelligence.swift`.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            disableTextIntelligence()
            disableTextIntelligenceInFieldEditor()
        }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return true
        }
        if event.keyCode == 36 { // Return
            let shift = event.modifierFlags.contains(.shift)
            onEnter?(shift)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
