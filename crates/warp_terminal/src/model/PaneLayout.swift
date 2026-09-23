import CoreGraphics
import Foundation

/// Where every pane in a tab lands inside the content area.
///
/// Pure arithmetic over the tree: it knows nothing about a session, a window, a font or a theme — the
/// two measurements it needs arrive as parameters, the way `BlockLayout`'s do. That is what makes the
/// part most likely to be off by one the part that is easiest to test, and a pane one point too wide
/// is not something a screenshot tells you about.
///
/// The `CoreGraphics` import is the only one in this folder that is not `Foundation`, and it is
/// geometry rather than UI: the purity rule is about AppKit, SwiftUI and Cocoa, and a rectangle is not
/// a view. Without it `CGRect` is not even `Equatable`, which is what a harness needs it to be.
struct PaneLayout {
    struct Entry: Equatable {
        let pane: PaneID
        let frame: CGRect
    }

    /// A boundary between two panes: the gap a drag moves.
    ///
    /// The pair of panes names it — they are adjacent children of exactly one branch — so a drag can refer
    /// to a divider without knowing anything about the shape of the tree, and without a path that a split
    /// or a close would invalidate.
    struct Divider {
        let leading: PaneID
        let trailing: PaneID
        /// The gap itself, which is what is *drawn*: nothing, since the gap is the window showing through.
        /// A view wants a hit area wider than this, the way the sidebar's edge does.
        let frame: CGRect
        /// The axis of the branch it belongs to, and how long that branch is along it. A drag needs both:
        /// the first to know which way the pointer moved, and the second to turn points into a fraction.
        let axis: SplitAxis
        let extent: CGFloat
    }

    private(set) var entries: [Entry] = []

    /// Every boundary between two panes, in no particular order. Empty for a tab with one pane.
    private(set) var dividers: [Divider] = []

    /// The panes, in the order the tree lays them out — left to right, then top to bottom. The same
    /// order `PaneTree.panes` gives, which is what keeps a sidebar's list and the screen agreeing.
    var panes: [PaneID] { entries.map(\.pane) }

    /// Where a pane is, or `nil` when it is not in this layout.
    func frame(of pane: PaneID) -> CGRect? {
        entries.first { $0.pane == pane }?.frame
    }

    /// Lay `tree` out in `bounds`, leaving `gap` between siblings.
    ///
    /// **The gap is the divider.** Two panes do not touch, and what shows between them is whatever
    /// the window is showing there — so there is no rule to draw, no second piece of geometry to keep
    /// in step with this one, and no colour token for a line that is really an absence. It is also
    /// what makes fractional widths safe: two panes that met exactly would seam on a half-pixel.
    ///
    /// The gaps come out of the space *before* it is divided, so the panes plus the gaps are exactly
    /// `bounds` and the last pane ends where the content area does rather than a gap short of it.
    init(tree: PaneTree, in bounds: CGRect, gap: CGFloat) {
        let laidOut = Self.layOut(tree.root, in: bounds, gap: max(0, gap))
        entries = laidOut.entries
        dividers = laidOut.dividers
    }

    private static func layOut(
        _ node: PaneTree.Node, in bounds: CGRect, gap: CGFloat
    ) -> (entries: [Entry], dividers: [Divider]) {
        switch node {
        case .leaf(let pane):
            return ([Entry(pane: pane, frame: bounds)], [])

        case .branch(let branch):
            let count = branch.children.count
            guard count > 0 else { return ([], []) }

            let horizontal = branch.axis == .horizontal
            let extent = horizontal ? bounds.width : bounds.height
            // The gaps come out of the space *before* it is divided, so the panes plus the gaps are exactly
            // the bounds and the last pane ends where the content area does rather than a gap short of it.
            let available = extent - gap * CGFloat(count - 1)
            // A branch of one is not a layout, so `PaneTree` never makes one — but a layout must not crash
            // on a tree it was handed rather than built, and dividing by a total of zero would.
            let total = branch.children.reduce(0) { $0 + $1.weight }

            var entries: [Entry] = []
            var dividers: [Divider] = []
            var offset = horizontal ? bounds.minX : bounds.minY

            for (index, child) in branch.children.enumerated() {
                // A window too small for its panes gives them zero size rather than a negative one. The
                // panes are still there, still in the tree and still focusable, which is the honest
                // degradation — clamping the *size* rather than dropping a pane keeps the count right.
                let share = total > 0 ? max(0, available) * (child.weight / total) : 0
                let slot =
                    horizontal
                    ? CGRect(x: offset, y: bounds.minY, width: share, height: bounds.height)
                    : CGRect(x: bounds.minX, y: offset, width: bounds.width, height: share)

                let childLayout = layOut(child.node, in: slot, gap: gap)
                entries.append(contentsOf: childLayout.entries)
                dividers.append(contentsOf: childLayout.dividers)

                // The boundary after this child — the one a drag moves. A child that is itself a branch
                // contributes its own boundaries above; this is only the one between it and its next
                // sibling, which is why the last child has none.
                if index < count - 1, let leading = child.node.lastLeaf,
                    let trailing = branch.children[index + 1].node.firstLeaf {
                    let frame =
                        horizontal
                        ? CGRect(x: offset + share, y: bounds.minY, width: gap, height: bounds.height)
                        : CGRect(x: bounds.minX, y: offset + share, width: bounds.width, height: gap)
                    dividers.append(
                        Divider(
                            leading: leading, trailing: trailing, frame: frame, axis: branch.axis,
                            extent: extent))
                }

                offset += share + gap
            }
            return (entries, dividers)
        }
    }
}
