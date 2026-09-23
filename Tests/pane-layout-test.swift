import CoreGraphics
import Foundation

/// Guards the pane geometry: how a tree of panes becomes a rectangle each.
///
/// This is the arithmetic a split's *appearance* rests on, and it is exactly the kind that looks right
/// in a two-pane window and is wrong in a three-pane one. The two things worth pinning down are that
/// the gaps come out of the space before it is divided — so the last pane ends where the content area
/// does, not a gap short of it — and that a nested split uses its parent's slot rather than the whole
/// area, which is what makes a pane inside a pane land in the right column.
@main
enum PaneLayoutTest {
    static func main() {
        let harness = Harness("pane-layout-test")

        onePaneFillsTheBounds(harness)
        twoPanesShareTheWidth(harness)
        theGapsComeOutOfTheSpace(harness)
        aVerticalSplitDividesTheHeight(harness)
        aNestedSplitUsesItsParentsSlot(harness)
        theOrderIsTheTreesOrder(harness)
        aZeroGapTilesExactly(harness)
        tooSmallForItsPanes(harness)
        closingRelayoutsTheSurvivor(harness)
        aStrangerHasNoFrame(harness)
        theDividers(harness)

        harness.finish()
    }

    private static let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

    private static func onePaneFillsTheBounds(_ harness: Harness) {
        let layout = PaneLayout(tree: PaneTree(first: pane(1)), in: bounds, gap: 1)
        harness.equal(layout.entries.count, 1, "one pane")
        harness.equal(layout.panes, [pane(1)], "laid out on its own")
        harness.equal(frame(harness, layout, pane(1)), bounds, "filling the content area exactly")
    }

    private static func twoPanesShareTheWidth(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 2)

        let first = frame(harness, layout, pane(1))
        let second = frame(harness, layout, pane(2))
        harness.equal(layout.entries.count, 2, "two panes")
        harness.close(first.width, second.width, "are the same width")
        harness.close(first.minX, bounds.minX, "the first starts at the left edge")
        harness.close(second.maxX, bounds.maxX, "the second ends at the right edge")
        harness.close(second.minX - first.maxX, 2, "with the gap between them")
        harness.close(first.height, bounds.height, "and both are the full height")
    }

    private static func theGapsComeOutOfTheSpace(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(2), adding: pane(3), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 4)

        harness.equal(layout.entries.count, 3, "three panes")
        let widths = layout.entries.map(\.frame.width)
        harness.expect(widths.allSatisfy { abs($0 - widths[0]) < 0.0001 }, "all the same width")
        let total = widths.reduce(0, +) + 4 * 2
        harness.close(total, bounds.width, "the panes and the two gaps are the width")
        harness.close(layout.entries[2].frame.maxX, bounds.maxX, "and the last one reaches the edge")
        harness.close(layout.entries[1].frame.minX - layout.entries[0].frame.maxX, 4, "gap one")
        harness.close(layout.entries[2].frame.minX - layout.entries[1].frame.maxX, 4, "gap two")
    }

    private static func aVerticalSplitDividesTheHeight(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .down)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 2)

        let first = frame(harness, layout, pane(1))
        let second = frame(harness, layout, pane(2))
        harness.close(first.height, second.height, "are the same height")
        harness.close(first.minY, bounds.minY, "the first starts at the top")
        harness.close(second.maxY, bounds.maxY, "the second ends at the bottom")
        harness.close(second.minY - first.maxY, 2, "with the gap between them")
        harness.close(first.width, bounds.width, "and both are the full width")
    }

    /// A pane split across the axis nests. The nested pair must divide *its parent's slot*, not the
    /// whole content area — the mistake that puts a pane in the wrong column and looks almost right.
    private static func aNestedSplitUsesItsParentsSlot(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(1), adding: pane(3), .down)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 2)

        let one = frame(harness, layout, pane(1))
        let three = frame(harness, layout, pane(3))
        let two = frame(harness, layout, pane(2))

        harness.close(one.minX, bounds.minX, "the nested pane is in the left column")
        harness.close(three.minX, bounds.minX, "and its sibling shares that column")
        harness.close(one.width, three.width, "so they are the same width")
        harness.close(three.minY - one.maxY, 2, "stacked with a gap between them")
        harness.close(one.height + 2 + three.height, bounds.height, "the column is the full height")
        harness.close(two.minX, one.maxX + 2, "the other pane is to the right of the column")
        harness.close(two.height, bounds.height, "and is the full height")
        harness.close(one.maxX + 2 + two.width, bounds.maxX, "together they fill the width")
    }

    /// The layout order is what a sidebar lists and what `focusNext` walks, so it has to be the tree's
    /// order and not, say, the order the rectangles happened to be computed in.
    private static func theOrderIsTheTreesOrder(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(1), adding: pane(3), .down)
        tree.split(pane(3), adding: pane(4), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 1)

        harness.equal(layout.panes, tree.panes, "the layout order is the tree's order")
        harness.equal(layout.panes, [pane(1), pane(3), pane(4), pane(2)], "which is left to right, top to bottom")
    }

    private static func aZeroGapTilesExactly(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 0)

        harness.close(layout.entries[0].frame.maxX, layout.entries[1].frame.minX, "no gap means the panes meet")
        harness.close(layout.entries[0].frame.width, bounds.width / 2, "and each is exactly half")
        harness.close(layout.entries[1].frame.maxX, bounds.maxX, "still ending at the edge")
    }

    private static func tooSmallForItsPanes(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(2), adding: pane(3), .right)
        // Narrower than the gaps alone, which is the case that divides by a negative number if the
        // subtraction is not clamped.
        let layout = PaneLayout(tree: tree, in: CGRect(x: 0, y: 0, width: 3, height: 2), gap: 4)

        harness.equal(layout.entries.count, 3, "every pane is still laid out")
        harness.expect(layout.entries.allSatisfy { $0.frame.width >= 0 }, "with no negative width")
        harness.expect(layout.entries.allSatisfy { $0.frame.width == 0 }, "and nothing to divide, so all zero")
    }

    /// Closing a pane collapses its branch, and the survivor must take the space rather than keep
    /// half of it — which is the collapse seen as geometry rather than as a tree shape.
    private static func closingRelayoutsTheSurvivor(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)

        let before = PaneLayout(tree: tree, in: bounds, gap: 2)
        harness.close(frame(harness, before, pane(1)).width, (bounds.width - 2) / 2, "half the width to start")

        tree.close(pane(2))
        let after = PaneLayout(tree: tree, in: bounds, gap: 2)
        harness.equal(after.entries.count, 1, "one pane left")
        harness.close(frame(harness, after, pane(1)).width, bounds.width, "and it takes the whole width")
    }

    private static func aStrangerHasNoFrame(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 1)

        harness.expect(layout.frame(of: pane(99)) == nil, "a pane that is not here has no frame")
        harness.expect(layout.frame(of: pane(1)) != nil, "and one that is has one")
    }

    /// The boundaries a drag moves, and the pair of panes that names each one.
    private static func theDividers(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(2), adding: pane(3), .right)
        let layout = PaneLayout(tree: tree, in: bounds, gap: 4)

        harness.equal(layout.dividers.count, 2, "three panes have two boundaries between them")
        harness.equal(
            layout.dividers.map(\.leading), [pane(1), pane(2)],
            "each named by the pane on its leading side")
        harness.equal(
            layout.dividers.map(\.trailing), [pane(2), pane(3)],
            "and the one on its trailing side")
        harness.equal(layout.dividers[0].axis, .horizontal, "on the branch's axis")
        harness.close(layout.dividers[0].extent, bounds.width, "with the branch's extent")
        harness.close(layout.dividers[0].frame.width, 4, "and the gap's own width")

        harness.equal(
            PaneLayout(tree: PaneTree(first: pane(1)), in: bounds, gap: 1).dividers.count, 0,
            "one pane has no boundary")

        var nested = PaneTree(first: pane(1))
        nested.split(pane(1), adding: pane(2), .right)
        nested.split(pane(1), adding: pane(3), .down)
        let nestedLayout = PaneLayout(tree: nested, in: bounds, gap: 2)
        harness.equal(nestedLayout.dividers.count, 2, "a nested pair has its own boundary plus the outer one")
        harness.equal(nestedLayout.dividers[0].axis, .vertical, "the inner one runs down the inner branch")
        harness.equal(nestedLayout.dividers[1].axis, .horizontal, "and the outer one along the outer branch")

        // Weights move the boundary, and the frames follow it.
        var weighted = tree
        weighted.resize(between: pane(1), and: pane(2), by: 0.2)
        let weightedLayout = PaneLayout(tree: weighted, in: bounds, gap: 4)
        harness.expect(
            frame(harness, weightedLayout, pane(1)).width > frame(harness, layout, pane(1)).width,
            "the pane grew, so its frame did")
        harness.close(
            frame(harness, weightedLayout, pane(3)).width, frame(harness, layout, pane(3)).width,
            "and the pane outside the pair did not move")
    }

    // MARK: - Reading the layout

    private static func pane(_ value: UInt64) -> PaneID { PaneID(rawValue: value) }

    private static func frame(
        _ harness: Harness, _ layout: PaneLayout, _ pane: PaneID
    ) -> CGRect {
        guard let frame = layout.frame(of: pane) else {
            harness.expect(false, "no frame for \(pane)")
            return .zero
        }
        return frame
    }
}
