import AppKit

/// The completion list, on glass.
///
/// `NSGlassEffectView` rather than `NSVisualEffectView`, and that is the whole reason it is this class: the
/// list floats *over* the terminal's own text, and a plain blur would smear the command line behind it into
/// an unreadable wash. The glass gives it a surface with an edge of its own, which is what makes a list
/// legible on top of text.
///
/// The rows go in `contentView` and nowhere else. `NSGlassEffectView` guarantees only that its `contentView`
/// is placed inside the effect — arbitrary subviews have no promised z-order against the glass — so a row
/// drawn straight onto the view could end up behind its own background.
///
/// It holds no state of its own: the surface owns the `CompletionMenu` and hands it over to be drawn, the
/// same split the rest of this project uses. What is here is presentation and geometry.
@MainActor
final class CompletionPopover: NSGlassEffectView {
    /// One row, which is one cell of the terminal's own line height and then some: a list of eight is a
    /// glance, and eight rows of a terminal-sized font is not a glance.
    static let rowHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    /// How far the list sits from the line it belongs to.
    static let gap: CGFloat = 4
    /// How far it keeps from the surface's edges when it has to be moved to fit.
    static let margin: CGFloat = 4
    /// Wide enough for a path and its description, narrow enough to leave the terminal visible behind it.
    static let maximumWidth: CGFloat = 440

    private let list = CompletionRowsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = Theme.Radius.panel
        contentView = list
        // The list is a surface, not a control: nothing in it is clickable yet, and the interactive glass
        // would put a hover response on a row that cannot be clicked. (`effectIsInteractive` is macOS 27 and
        // this app targets 26, but its default is already the answer we want — no interaction.)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CompletionPopover is created in code, never from a nib")
    }

    /// Draw `menu` anchored above a point, staying inside `bounds`.
    ///
    /// The anchor is the top edge of the line the command is being typed on, so the list grows *upwards*
    /// from the prompt — which is the only direction it can go in a terminal, where the prompt is at the
    /// bottom. It flips below the anchor when there is no room above, which is what a short window does.
    func show(_ menu: CompletionMenu, above anchor: NSPoint, within bounds: CGRect) {
        list.rows = menu.rows
        list.selectedRow = menu.selectedRow
        list.needsDisplay = true

        let size = list.preferredSize
        var origin = NSPoint(x: anchor.x, y: anchor.y + Self.gap)
        if origin.y + size.height > bounds.maxY - Self.margin {
            origin.y = max(bounds.minY + Self.margin, anchor.y - Self.gap - size.height)
        }
        origin.x = min(
            max(bounds.minX + Self.margin, origin.x), bounds.maxX - Self.margin - size.width)
        frame = NSRect(origin: origin, size: size)
        list.frame = CGRect(origin: .zero, size: size)
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    /// Pushes an updated theme palette into the popover.
    func update(palette: TerminalPalette) {
        list.palette = palette
        list.needsDisplay = true
    }
}

/// The rows themselves.
///
/// Hand-drawn rather than a stack of labels, for the reason the terminal's own renderer is hand-drawn: the
/// row is three pieces of text on a baseline and a highlight behind one of them, and a view hierarchy for
/// that is three views per row that all have to agree about the same baseline.
private final class CompletionRowsView: NSView {
    var rows: [CompletionCandidate] = []
    var selectedRow = 0
    var palette: TerminalPalette = .builtin

    private let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let detailFont = NSFont.systemFont(ofSize: 11)

    /// What the popover should be sized to. Measured from the rows rather than fixed, so a list of short
    /// subcommands is a small panel and a list of deep paths is a wide one — up to the cap.
    /// Not called `fittingSize`: `NSView` already has one, and it means something else — the size that
    /// satisfies the view's constraints. Overriding it would be a lie about what this answers.
    var preferredSize: NSSize {
        let height =
            CGFloat(rows.count) * CompletionPopover.rowHeight + CompletionPopover.verticalPadding * 2
        guard !rows.isEmpty else { return NSSize(width: 120, height: height) }
        let widest = rows.map { row in
            width(row.text, font: textFont) + 12 + width(row.kind.displayName, font: detailFont)
                + descriptionWidth(row)
        }
        .max() ?? 0
        let padding = CompletionPopover.horizontalPadding * 2
        return NSSize(
            width: min(CompletionPopover.maximumWidth, (widest + padding).rounded(.up)), height: height)
    }

    private func descriptionWidth(_ row: CompletionCandidate) -> CGFloat {
        guard let description = row.description else { return 0 }
        return 12 + width(description, font: detailFont)
    }

    private func width(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight = CompletionPopover.rowHeight
        for (index, row) in rows.enumerated() {
            // Row 0 is at the top, and this view is y-up like every other AppKit view.
            let top = bounds.maxY - CompletionPopover.verticalPadding - CGFloat(index) * rowHeight
            let rowRect = CGRect(
                x: 0, y: top - rowHeight, width: bounds.width, height: rowHeight)

            if index == selectedRow {
                palette.ansi[4].nsColor.withAlphaComponent(0.25).setFill()
                let path = NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5)
                path.fill()
                palette.ansi[4].nsColor.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            let baseline = rowRect.midY - textFont.capHeight / 2 + 0.5
            var x = CompletionPopover.horizontalPadding
            draw(row.text, at: x, baseline: baseline, font: textFont, color: palette.foreground.nsColor)
            x += width(row.text, font: textFont) + 12

            // The kind, right after the text: it is the reason to trust the suggestion, and the text alone
            // does not say whether this is a subcommand or something that was run last week.
            draw(row.kind.displayName, at: x, baseline: baseline, font: detailFont, color: palette.ansi[6].nsColor)

            guard let description = row.description else { continue }
            x += width(row.kind.displayName, font: detailFont) + 12
            draw(description, at: x, baseline: baseline, font: detailFont, color: palette.foreground.nsColor.withAlphaComponent(0.6))
        }
    }

    private func draw(_ string: String, at x: CGFloat, baseline: CGFloat, font: NSFont, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            .draw(at: NSPoint(x: x, y: baseline))
    }
}
