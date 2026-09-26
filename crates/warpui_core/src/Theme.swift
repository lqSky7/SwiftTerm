import AppKit
import SwiftUI

/// Central design tokens. Every value here is the one place a number lives; a view that invents
/// its own padding is the way a design system rots.
///
/// The window chrome resolves per appearance, but the terminal's own colours do not come from
/// here — a terminal's palette is its content, not its chrome, and lives with the terminal.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 20
    }

    enum Radius {
        static let panel: CGFloat = 12
        static let control: CGFloat = 6
        /// A sidebar row's highlight. Larger than `control` because a tab row is taller than a control
        /// is: the reference's corners are a *ratio* of the highlight's height rather than a fixed
        /// radius, and at `sidebarRowHeight` that ratio is this.
        static let sidebarRow: CGFloat = 8
        /// Where two rounded corners sit adjacent, `inner = outer - gap`.
        static let inset: CGFloat = 4
    }

    enum Size {
        static let defaultWindow = CGSize(width: 960, height: 600)
        /// Below this the titlebar's own controls start colliding with the title text.
        static let minimumWindow = CGSize(width: 420, height: 240)
        /// Room for the shell to draw a prompt without a program thinking it is on a phone.
        static let minimumTerminal = CGSize(width: 200, height: 100)
        /// How far the terminal's content stays clear of the surface's edges, on both sides.
        ///
        /// **Not zero, and this token exists because it was.** The grid used to start at the panel's very
        /// edge while every other part of a block — the status dot, the context chips, the rule between
        /// blocks — was inset by `Spacing.md`. So the text hung *outside* the block's own chrome, and the
        /// first column of every line sat on the panel's rounded leading corner, where the clip cut into it.
        ///
        /// At least `Radius.panel`, because that is the curve it has to clear. One number for the grid and
        /// the chrome both: they were two numbers that disagreed, and the text was the one that lost.
        static let terminalContentInset: CGFloat = 12
        /// The strip a block's header occupies. A fixed height, so the document's geometry is
        /// arithmetic rather than a measurement — which is what makes it testable.
        static let blockHeaderHeight: CGFloat = 26
        /// The row of context chips above a prompt. A fixed height like the header's, and for the same
        /// reason: it makes the document's geometry arithmetic rather than a measurement.
        /// Tall enough for the label to sit in a shape rather than in a line of text: the chips are the block's own
        /// metadata and they were the smallest thing on screen.
        static let contextChipHeight: CGFloat = 36
        /// The strip at the top of the window that still belongs to the *window*.
        ///
        /// The window is drawn with a full-size content view, which is what puts the traffic lights over
        /// the sidebar — but the titlebar is still above the content in the view hierarchy, and it still
        /// takes the mouse events in its band. **A control placed up here is a control that does
        /// nothing**, silently, which is the worst way for a button to fail. Everything interactive in
        /// the chrome has to start below this.
        static let titlebarBand: CGFloat = 28
        /// The row the window's traffic lights sit in, at the top of the sidebar. Tall enough that the
        /// tab list starts *below* them, and its own controls are bottom-aligned so they clear
        /// `titlebarBand` as well.
        ///
        /// The sidebar's width and the material's opacity are not here: they are preferences, and they
        /// live in `ChromeSettings`, which is a model a harness can hold.
        static let sidebarHeaderHeight: CGFloat = 54
        /// The placeholder avatar in the sidebar's first row, and how tall that row is. Taller than a tab
        /// row on purpose: it is not a tab, and the one row that says whose window this is should not look
        /// like the things you can click to switch.
        static let profileAvatarSize: CGFloat = 36
        static let profileRowHeight: CGFloat = 56
        /// A tab row, and the pill the selection draws inside it. A token because three places have to
        /// agree about it — the row, the rename field that replaces it, and the pill's own geometry.
        static let sidebarRowHeight: CGFloat = 34
        /// The identity mark's width in a row, and how heavy its stroke is as a fraction of that width.
        ///
        /// The icon's own SVG draws the stroke at 3 units in a 100-unit box, and that is right on a
        /// 1024-point canvas and wrong on a row: at this size it comes out under three quarters of a
        /// point, which reads as a printing defect rather than as a mark. **A glyph needs its stroke
        /// heavier relative to its size, not lighter** — this is the icon's shape at a row's weight.
        static let identityMarkWidth: CGFloat = 22
        static let identityMarkStrokeRatio: CGFloat = 0.08
        /// The mark's aspect, from the icon's 100×80 viewBox. Here rather than in the shape because a
        /// caller laying the mark out has to know it, and two copies of `80/100` would drift.
        static let identityMarkAspect: CGFloat = 0.8
        /// How far the selection highlight sits from the sidebar's edges.
        ///
        /// **Small on purpose.** The highlight runs almost edge to edge: the reference the sidebar is
        /// drawn from insets it by about two per cent of the sidebar's width, and this used to be
        /// fourteen points, which turned the highlight into a chip floating inside the row rather than
        /// the row itself being lit.
        static let sidebarRowInset: CGFloat = 4
        /// How much of the `List`'s own content inset a row has to take *back* to reach the sidebar's
        /// edges.
        ///
        /// A `List` keeps its rows clear of its own edges, and `.listRowInsets` can only add to that —
        /// so the number is negative and it is the only way past it. **Measured, not guessed**: with
        /// `leading: 0` a row's highlight lands twelve points in from the sidebar's edge, so eight of
        /// those are the list's and `sidebarRowInset` is the other four. Get this wrong and the
        /// highlight stops short of the edge by exactly the error, which is what it did.
        static let sidebarRowBleed: CGFloat = 8
        /// The hairline along the highlight's top and bottom edges.
        static let sidebarRowHairline: CGFloat = 1
        /// How far along each of those edges its bright end reaches before settling to the faint line
        /// that runs the rest of the way.
        ///
        /// The highlight is a **diagonal**: the top edge is lit at its leading end and the bottom edge at
        /// its trailing one, which is what a surface catching light from one side looks like. Lit evenly
        /// along both edges it reads as a border, and lit down the vertical sides it reads as a box.
        static let sidebarRowGlowSpan: CGFloat = 0.22
        /// What the hairline drops to once past its bright end. Not zero — the edge is still there, it is
        /// just not catching anything — and about a third of the peak, which is the reference's ratio.
        static let sidebarRowGlowFloor: CGFloat = 0.35
        /// The settings root is a centred column rather than a full-width list: a page of two choices reads
        /// as a page when it is in the middle of the window and as a menu when it is pinned to a corner.
        ///
        /// A **ceiling, not a width** — the column is `maxWidth`, so a window narrower than this shrinks it
        /// rather than letting the page run off the panel. It was a fixed width, and a window dragged narrow
        /// enough cut the right-hand side of every slider off.
        static let settingsContentWidth: CGFloat = 520
        static let settingsSearchHeight: CGFloat = 38
        /// The tile a settings icon sits in.
        static let settingsIconTile: CGFloat = 30
        /// The bar at the top of a settings page: the way back, and the name of the page you are on.
        ///
        /// Tall enough for the traffic lights' row and the floating sidebar button to be clear of it, which
        /// is why it is not a label with padding around it.
        static let settingsTopBarHeight: CGFloat = 56
        /// The floor a settings row is laid out to, so a card of one-line rows reads as a list rather than
        /// as a stack of different heights.
        static let settingsRowMinHeight: CGFloat = 40
        /// How wide an opacity slider is. **Not the row's width**, which is what it used to be: a slider
        /// stretched across the window is a slider whose value is hard to nudge, and the thing it controls
        /// is a percentage rather than a position.
        static let settingsSliderWidth: CGFloat = 130
        /// How much of the content panel's top-leading corner the floating sidebar button occupies — its own
        /// width plus the padding around it. Anything else that wants that corner has to clear this much, or
        /// the two sit on top of each other.
        static let paneToggleFootprint: CGFloat = 44
        /// The leading space in the sidebar's header row that the window's traffic lights occupy. The
        /// lights are AppKit's and their position is the window's business, so this is the one number
        /// that has to know how wide three circles and their margins are.
        static let trafficLightInset: CGFloat = 76
        /// How close to the sidebar's trailing edge a drag resizes it.
        static let sidebarResizeHandle: CGFloat = 6
        /// The gap between two panes — which is the divider. The panes do not touch, and what shows
        /// between them is the window's own backdrop, so there is no rule to draw and no second piece
        /// of geometry to keep in step with the layout's.
        static let paneGap: CGFloat = 1
        /// How wide the strip you grab to drag a divider is. Wider than the gap itself, which is one point
        /// and would be a poor target: the gap is what is *drawn*, this is what is *hit*.
        static let paneDividerHit: CGFloat = 9
    }

    enum Typography {
        /// Derived from the settings, which own them — see `ChromeSettings.defaultFontSize`. A second copy here
        /// would be a second answer to "how big is the text", free to drift from the one the settings page shows.
        static let terminalPointSize = CGFloat(ChromeSettings.defaultFontSize)
        static let minimumTerminalPointSize = CGFloat(ChromeSettings.fontSizeRange.lowerBound)
        static let maximumTerminalPointSize = CGFloat(ChromeSettings.fontSizeRange.upperBound)
        static let pointSizeStep: CGFloat = 1

        /// The line height, as a multiple of the font size.
        ///
        /// **This is most of the difference between a grid that reads like a wall of text and one that reads like
        /// a text editor**, and it is the number this terminal got wrong: it used the font's own leading, which
        /// for SF Mono is about 1.19. Warp lays its grid out at `line_height_ratio` 1.4
        /// (`crates/warp_core/src/ui/appearance.rs:117`), and 1.4 is what this is now.
        static let lineHeightRatio = CGFloat(ChromeSettings.defaultLineHeightRatio)
        static let minimumLineHeightRatio = CGFloat(ChromeSettings.lineHeightRatioRange.lowerBound)
        static let maximumLineHeightRatio = CGFloat(ChromeSettings.lineHeightRatioRange.upperBound)
        static let lineHeightRatioStep: CGFloat = 0.05

        /// The gap below each block, as a fraction of a line.
        ///
        /// **Warp's `padding_bottom()`** (`app/src/terminal/model/block.rs:1560`): it is added to *every* block's
        /// height, not reserved once at the end of the document — which is why the last block's cursor sits clear of
        /// the window's edge instead of touching it, and why consecutive blocks are not jammed together either.
        ///
        /// A fraction of a line rather than a point value, because the gap has to grow with the text: half a line at
        /// 13pt is 9pt, and half a line at 24pt is 17pt.
        static let blockBottomPaddingRatio: CGFloat = 0.5
        /// The name beside the avatar in the sidebar. Bigger than a tab's label on purpose: it is not a tab,
        /// and the two sitting at the same weight is what made the row feel off.
        static let profileNameSize: CGFloat = 20
    }

    enum Colors {
        /// The surface a settings page is drawn on.
        ///
        /// A scrim that *darkens* in both appearances — black, at a higher alpha in dark mode. Deliberately
        /// not `ramp`, which is white on dark: that is right for ink and wrong for a scrim, and building this
        /// out of `ramp` is what made the settings page a light grey wash in dark mode while the sidebar
        /// beside it was perfectly dark.
        static let settingsSurface = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.12)
        })

        /// UI ink is one alpha ramp, white on dark and black on light — never a grey, which is how
        /// a surface ends up fighting its own backdrop.
        static func ramp(dark: CGFloat, light: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor.white.withAlphaComponent(dark)
                    : NSColor.black.withAlphaComponent(light)
            })
        }

        /// The band the window draws behind its title, so the title stays readable over any shell.
        static let titlebarInk = ramp(dark: 0.75, light: 0.7)

        /// The fill behind the selected row.
        ///
        /// A scrim that **darkens** in both appearances — black, at a much higher alpha in dark mode.
        /// The reference the sidebar is drawn from lights the selected row by *recessing* it: the row is
        /// the darkest thing on the sidebar, and that is what makes it read as the one you are in.
        ///
        /// Not the accent colour: `NSColor.selectedContentBackgroundColor` resolves to `#0064E1` in light
        /// mode on this machine, a blue bar through a list that is meant to read as a stack of paper.
        /// And not `ramp`, which cannot express this at all — `ramp` is white on dark, and a white lift
        /// is invisible the moment the window's background is opaque white, which is a state the opacity
        /// control can reach. A scrim survives both: it is black on light and black on dark, so it reads
        /// on the window's background at any opacity and on the material behind it.
        ///
        /// The hairline that goes with it is `selectionEdge`, and it is drawn on two edges rather than
        /// four — see `SidebarRowHighlight` for why.
        static let selectionFill = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.06)
        })

        /// The hairline along the selected row's top and bottom edges.
        ///
        /// Dim, and deliberately: in the reference it measures about a fifth of the way from the row's
        /// fill to its surroundings. Brighter and it stops being the edge of a surface catching light
        /// and becomes a border, which is the thing this design is avoiding.
        static let selectionEdge = ramp(dark: 0.18, light: 0.12)

        /// The identity mark's ink in a sidebar row.
        ///
        /// **The same in a selected row and an unselected one**, which is what the reference does. The mark
        /// is the app's rather than the row's, so it does not brighten when the row becomes the one you are
        /// in — the label does that, and a mark that also lit up would be two things saying it at once.
        static let identityMark = ramp(dark: 0.38, light: 0.32)
    }

    enum Motion {
        /// Long enough to read as a fade, short enough that a keystroke never waits on it.
        static let chromeFade: TimeInterval = 0.18
    }
}
