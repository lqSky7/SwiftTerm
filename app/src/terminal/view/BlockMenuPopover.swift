import AppKit

/// A block's actions, on glass — what the three dots in a block's header open.
///
/// A panel of our own rather than an `NSMenu`, which is the whole point of it: an `NSMenu` is drawn by the
/// window server, in its own window, in the system's appearance, and the thing it is opening from belongs to
/// the terminal. Same glass, same corner radius, same ink as the completion list it sits beside.
///
/// The actions come from `TerminalSurfaceView.blockActions` — the same list the right-click menu reads. Two
/// lists would be two menus that drift, and the point of this one is that it offers the same things.
@MainActor
final class BlockMenuPopover: NSGlassEffectView {
    /// A menu row is taller than a completion row: this is a list of things to *read and choose*, not a list to
    /// scan while typing.
    static let rowHeight: CGFloat = 26
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 4
    static let minimumWidth: CGFloat = 200
    /// How far below the control the menu hangs.
    static let gap: CGFloat = 3
    static let margin: CGFloat = 4

    private let rows = BlockMenuRowsView()

    /// Which row was chosen. The surface performs the action, because the surface is what has the selectors.
    var onSelect: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        style = .regular
        cornerRadius = Theme.Radius.panel
        contentView = rows
        rows.onSelect = { [weak self] index in self?.onSelect?(index) }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlockMenuPopover is created in code, never from a nib")
    }

    var isOpen: Bool { !isHidden }

    /// Show the actions, hanging from the control that opened them.
    ///
    /// It hangs *down* rather than growing up, which is the opposite of the completion list and right for the
    /// same reason: the completion list is anchored to a prompt at the bottom of the window and has nowhere to
    /// go but up, while this is anchored to the top-right corner of a block and has the whole block below it.
    func show(_ titles: [String], at anchor: CGRect, within bounds: CGRect) {
        rows.titles = titles
        rows.hoveredRow = nil
        rows.needsDisplay = true
        layout(at: anchor, within: bounds)
        isHidden = false
    }

    /// Keep it where it is while the document moves under it.
    func reposition(at anchor: CGRect, within bounds: CGRect) {
        guard !isHidden else { return }
        layout(at: anchor, within: bounds)
    }

    func hide() {
        isHidden = true
    }

    private func layout(at anchor: CGRect, within bounds: CGRect) {
        let width = max(
            Self.minimumWidth,
            (rows.widestTitle + Self.horizontalPadding * 2).rounded(.up))
        let size = CGSize(
            width: min(width, bounds.width - Self.margin * 2),
            height: CGFloat(rows.titles.count) * Self.rowHeight + Self.verticalPadding * 2)

        // Right edges flush: the control is at the trailing edge of a block, so a menu aligned to it reads as
        // belonging to it. Then clamped, because a block can be scrolled to the very edge.
        var origin = CGPoint(x: anchor.maxX - size.width, y: anchor.minY - Self.gap - size.height)
        origin.x = min(
            max(bounds.minX + Self.margin, origin.x), bounds.maxX - Self.margin - size.width)
        origin.y = max(bounds.minY + Self.margin, origin.y)

        frame = CGRect(origin: origin, size: size)
        rows.frame = CGRect(origin: .zero, size: size)
    }
}

/// The rows, and the mouse that goes over them.
///
/// Hand-drawn, like the completion list and the terminal itself: a row is one string on a baseline and a
/// highlight behind it, and a stack of labels for that is four views per row that all have to agree about the
/// same baseline.
private final class BlockMenuRowsView: NSView {
    var titles: [String] = [] {
        didSet { needsDisplay = true }
    }
    var hoveredRow: Int? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    var onSelect: ((Int) -> Void)?

    private let font = NSFont.systemFont(ofSize: 13)

    var widestTitle: CGFloat {
        titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    /// A menu has to be able to follow the pointer, and it is a view in a window that does not send
    /// `mouseMoved` unless it is asked to — so the tracking area is what makes the highlight work at all.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hoveredRow = row(at: event) }

    override func mouseExited(with event: NSEvent) { hoveredRow = nil }

    /// On mouse *up*, which is what a menu does: a press that slides off the row before it is released is a
    /// change of mind, and acting on the press takes that away.
    override func mouseUp(with event: NSEvent) {
        guard let row = row(at: event) else { return }
        onSelect?(row)
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((bounds.maxY - point.y - BlockMenuPopover.verticalPadding) / BlockMenuPopover.rowHeight)
        return titles.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, title) in titles.enumerated() {
            let top = bounds.maxY - BlockMenuPopover.verticalPadding - CGFloat(index) * BlockMenuPopover.rowHeight
            let rowRect = CGRect(
                x: 0, y: top - BlockMenuPopover.rowHeight, width: bounds.width,
                height: BlockMenuPopover.rowHeight)

            if index == hoveredRow {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
            }

            NSAttributedString(
                string: title,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            .draw(at: NSPoint(x: BlockMenuPopover.horizontalPadding, y: rowRect.midY - font.capHeight / 2))
        }
    }
}
