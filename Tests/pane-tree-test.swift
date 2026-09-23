import Foundation

/// Guards the split-pane tree: where a new pane lands, what closing one does to the shape, and where
/// the focus goes when the focused pane is the one that closed.
///
/// The two rules worth having a harness for are both invisible in a two-pane window and obvious in a
/// three-pane one: a split along an axis the branch already runs along joins that branch as a
/// sibling rather than nesting a second branch inside the first, and a branch left holding one child
/// collapses into its parent. Get either wrong and the layout still *looks* plausible until the
/// third pane.
@main
enum PaneTreeTest {
    static func main() {
        let harness = Harness("pane-tree-test")

        aFreshTreeIsOnePane(harness)
        whereANewPaneLands(harness)
        aSplitAlongTheSameAxisJoinsTheBranch(harness)
        aSplitAcrossTheAxisNests(harness)
        closingCollapses(harness)
        focusAfterAClose(harness)
        closingWhatIsNotThere(harness)
        walkingThePanes(harness)
        branchesNeverHoldOneChild(harness)
        draggingADivider(harness)

        harness.finish()
    }

    // MARK: - Shapes

    private static func aFreshTreeIsOnePane(_ harness: Harness) {
        let tree = PaneTree(first: pane(1))
        harness.equal(tree.panes, [pane(1)], "one pane")
        harness.equal(tree.count, 1, "and a count of one")
        harness.equal(tree.focused, pane(1), "which is the focused one")
        harness.expect(isLeaf(tree.root), "an unsplit tab is a leaf, not a branch of one")
        harness.expect(tree.contains(pane(1)), "and it is in the tree")
        harness.expect(!tree.contains(pane(2)), "and nothing else is")
    }

    private static func whereANewPaneLands(_ harness: Harness) {
        // Each placement is checked for both facts it decides: which side of the old pane the new
        // one goes, and which axis the branch holding them runs along.
        let cases: [(SplitPlacement, SplitAxis, [PaneID])] = [
            (.right, .horizontal, [pane(1), pane(2)]),
            (.left, .horizontal, [pane(2), pane(1)]),
            (.down, .vertical, [pane(1), pane(2)]),
            (.up, .vertical, [pane(2), pane(1)]),
        ]

        for (placement, axis, order) in cases {
            var tree = PaneTree(first: pane(1))
            let didSplit = tree.split(pane(1), adding: pane(2), placement)
            harness.expect(didSplit, "\(placement) split the pane")
            harness.equal(tree.panes, order, "\(placement) puts the new pane here")
            harness.equal(branch(tree)?.axis, axis, "\(placement) makes a branch along that axis")
            harness.equal(tree.focused, pane(2), "\(placement) focuses the new pane")
        }
    }

    /// The rule a naive tree gets wrong: two panes side by side, split again along the same axis,
    /// must be one branch of three. Nested, it would be a branch of two holding a branch of two —
    /// the same pixels in a two-pane window and a staircase the moment there are three.
    private static func aSplitAlongTheSameAxisJoinsTheBranch(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(1), adding: pane(3), .right)

        harness.equal(tree.panes, [pane(1), pane(3), pane(2)], "a third pane joins the same branch")
        harness.equal(branch(tree)?.children.count, 3, "which is three children, not two and a half")
        harness.equal(leafChildren(tree), 3, "all three of them leaves")
        harness.equal(branch(tree)?.axis, .horizontal, "and the axis is unchanged")
        harness.equal(tree.focused, pane(3), "the newest pane has the focus")

        // Splitting from a pane in the middle inserts beside it rather than at the end.
        tree.split(pane(2), adding: pane(4), .right)
        harness.equal(tree.panes, [pane(1), pane(3), pane(2), pane(4)], "inserted beside what it split")

        // And the same the other way, which goes before.
        var leftward = PaneTree(first: pane(1))
        leftward.split(pane(1), adding: pane(2), .right)
        leftward.split(pane(1), adding: pane(3), .left)
        harness.equal(leftward.panes, [pane(3), pane(1), pane(2)], "left inserts before")
        harness.equal(branch(leftward)?.children.count, 3, "still one branch, not two")
    }

    /// A split across the axis cannot join the branch, so it nests: the pane becomes a branch of two
    /// running the other way.
    private static func aSplitAcrossTheAxisNests(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(1), adding: pane(3), .down)

        harness.equal(tree.panes, [pane(1), pane(3), pane(2)], "the nested pane comes second")
        harness.equal(branch(tree)?.axis, .horizontal, "the root still runs horizontally")
        harness.equal(branch(tree)?.children.count, 2, "with two children")
        harness.equal(nestedBranch(tree, at: 0)?.axis, .vertical, "the first of which is vertical")
        harness.equal(nestedBranch(tree, at: 0)?.children.count, 2, "and holds the two stacked panes")

        // A third level, alternating back: it must nest in the inner branch, not the outer one.
        tree.split(pane(3), adding: pane(4), .right)
        harness.equal(tree.panes, [pane(1), pane(3), pane(4), pane(2)], "a fourth pane joins the inner branch")
        harness.equal(nestedBranch(tree, at: 0)?.axis, .vertical, "whose axis it did not change")
        harness.equal(leafChildren(tree), 1, "the root holds one branch and one leaf")
    }

    // MARK: - Closing

    private static func closingCollapses(_ harness: Harness) {
        // One of two: the survivor takes the whole space, so the branch is gone entirely.
        var pair = PaneTree(first: pane(1))
        pair.split(pane(1), adding: pane(2), .right)
        pair.close(pane(2))
        harness.equal(pair.panes, [pane(1)], "one pane left")
        harness.expect(isLeaf(pair.root), "and the branch collapsed into the survivor")
        harness.equal(pair.focused, pane(1), "which has the focus")

        // One of three: the branch stays, minus a child.
        var three = threePanes()
        three.close(pane(2))
        harness.equal(three.panes, [pane(1), pane(3)], "the middle one is gone")
        harness.equal(branch(three)?.children.count, 2, "and the branch is still a branch")

        // A nested branch collapsing must lift its survivor into the outer branch's slot rather
        // than vanish with it.
        var nested = PaneTree(first: pane(1))
        nested.split(pane(1), adding: pane(2), .right)
        nested.split(pane(1), adding: pane(3), .down)
        harness.equal(nested.panes, [pane(1), pane(3), pane(2)], "two levels to start with")

        nested.close(pane(3))
        harness.equal(nested.panes, [pane(1), pane(2)], "the inner branch collapsed")
        harness.equal(branch(nested)?.axis, .horizontal, "leaving the outer axis")
        harness.equal(leafChildren(nested), 2, "and two leaves where a branch used to be")
        harness.equal(nested.focused, pane(1), "with the focus on the pane that had it")
    }

    private static func focusAfterAClose(_ harness: Harness) {
        // The focused pane goes: focus the one before it.
        var last = threePanes()
        harness.equal(last.focused, pane(3), "the newest pane starts focused")
        last.close(pane(3))
        harness.equal(last.focused, pane(2), "closing it focuses the pane before it")

        // The first pane goes: there is nothing before it, so focus the one after — Warp's fallback.
        var first = threePanes()
        first.focus(pane(1))
        first.close(pane(1))
        harness.equal(first.focused, pane(2), "closing the first focuses the one after it")

        // A pane that is not focused takes nothing with it.
        var untouched = threePanes()
        harness.equal(untouched.focused, pane(3), "the third pane has the focus")
        untouched.close(pane(1))
        harness.equal(untouched.focused, pane(3), "closing another pane leaves the focus alone")

        // The last pane cannot be closed: a tree with no panes is not a layout, and the caller is
        // the one that knows whether a tab or a window goes with it.
        var single = PaneTree(first: pane(9))
        single.close(pane(9))
        harness.equal(single.count, 1, "the only pane stays")
        harness.equal(single.focused, pane(9), "and keeps the focus")
    }

    private static func closingWhatIsNotThere(_ harness: Harness) {
        var tree = threePanes()
        tree.close(pane(99))
        harness.equal(tree.panes, [pane(1), pane(2), pane(3)], "closing a stranger is a no-op")
        harness.equal(tree.focused, pane(3), "and does not move the focus")

        // A pane that has already gone, closed twice, must not take a second pane with it. This is
        // the shape the collapse makes dangerous: a branch that briefly held a single child.
        tree.close(pane(2))
        harness.equal(tree.panes, [pane(1), pane(3)], "the second close removed the pane")
        tree.close(pane(2))
        harness.equal(tree.panes, [pane(1), pane(3)], "and the third close closed nothing")
        harness.equal(tree.count, 2, "two panes remain")
    }

    // MARK: - Focus

    private static func walkingThePanes(_ harness: Harness) {
        var tree = threePanes()
        harness.expect(tree.focus(pane(1)), "focus a pane that is present")
        harness.equal(tree.focused, pane(1), "which is now the focused one")

        tree.focusNext()
        harness.equal(tree.focused, pane(2), "next walks the layout order")
        tree.focusNext()
        harness.equal(tree.focused, pane(3), "and keeps going")
        tree.focusNext()
        harness.equal(tree.focused, pane(1), "wrapping round to the start")

        tree.focusPrevious()
        harness.equal(tree.focused, pane(3), "previous wraps the other way")
        tree.focusPrevious()
        harness.equal(tree.focused, pane(2), "and walks back")
        tree.focusPrevious()
        harness.equal(tree.focused, pane(1), "to the start again")

        harness.expect(!tree.focus(pane(99)), "focusing a stranger is refused")
        harness.equal(tree.focused, pane(1), "and leaves the focus where it was")

        // A split moves the focus, so the next keystroke goes to the pane the eye is on.
        tree.split(pane(1), adding: pane(5), .right)
        harness.equal(tree.focused, pane(5), "a split focuses what it added")

        // And splitting something that is not there changes nothing at all.
        harness.expect(
            !tree.split(pane(99), adding: pane(6), .right), "splitting a stranger is refused")
        harness.equal(tree.panes, [pane(1), pane(5), pane(2), pane(3)], "and adds no pane")
        harness.equal(tree.focused, pane(5), "nor moves the focus")
    }

    // MARK: - The invariant

    /// Every operation above assumes a branch holds at least two children — that is what makes the
    /// collapse safe to write as `count == 1`. This walks a long sequence of splits and closes and
    /// checks the invariant after every one, because a violation here is a layout that silently
    /// loses a pane rather than one that merely looks wrong.
    private static func branchesNeverHoldOneChild(_ harness: Harness) {
        var tree = PaneTree(first: pane(1))
        var next: UInt64 = 2
        let placements: [SplitPlacement] = [.right, .down, .right, .up, .right, .down]

        for placement in placements {
            let target = tree.panes[tree.panes.count / 2]
            tree.split(target, adding: pane(next), placement)
            next += 1
            harness.expect(everyBranchHasTwoChildren(tree.root), "no branch of one after a split")
            harness.expect(tree.contains(tree.focused), "the focused pane is present after a split")
        }
        harness.equal(tree.count, 7, "seven panes after six splits")

        // Close them from the middle out, which is the order that makes a collapse cascade.
        while tree.count > 1 {
            tree.close(tree.panes[tree.panes.count / 2])
            harness.expect(everyBranchHasTwoChildren(tree.root), "no branch of one after a close")
            harness.expect(tree.contains(tree.focused), "the focused pane is present after a close")
        }

        harness.equal(tree.count, 1, "one pane is where closing everything ends")
        harness.expect(isLeaf(tree.root), "and the tree is a leaf again")
    }

    /// Dragging a divider: the pair's combined share is unchanged, so the panes outside it do not move,
    /// and neither pane can be squeezed away entirely.
    private static func draggingADivider(_ harness: Harness) {
        var tree = threePanes()
        harness.expect(tree.resize(between: pane(1), and: pane(2), by: 0.1), "the boundary moved")

        let weights = branch(tree)?.children.map(\.weight) ?? []
        // A tenth of the branch is a tenth of the *total* weight, and the total is 3.
        harness.close(weights[0], 1.3, "the leading pane took the fraction")
        harness.close(weights[1], 0.7, "and the trailing one gave it up")
        harness.close(weights[2], 1, "the pane outside the pair did not move")
        harness.close(weights.reduce(0, +), 3, "and the branch's total is unchanged")

        // A pair that is not two adjacent children of one branch moves nothing: it is stale.
        harness.expect(
            !tree.resize(between: pane(1), and: pane(3), by: 0.1), "a stale pair moves nothing")
        harness.expect(
            !tree.resize(between: pane(99), and: pane(2), by: 0.1), "and a stranger moves nothing")

        // Neither pane can be squeezed past the floor. A pane that can be dragged to nothing is a pane
        // nobody can get back, because its edge went with it.
        var squeezed = threePanes()
        squeezed.resize(between: pane(1), and: pane(2), by: 100)
        let far = branch(squeezed)?.children.map(\.weight) ?? []
        harness.close(far[1], PaneTree.defaultMinimumShare * 3, "the trailing pane stops at the floor")
        harness.close(far[0], 3 - far[1] - 1, "and the leading one takes what it gave up")

        squeezed.resize(between: pane(1), and: pane(2), by: -100)
        let back = branch(squeezed)?.children.map(\.weight) ?? []
        harness.close(back[0], PaneTree.defaultMinimumShare * 3, "and the other way too")
    }

    // MARK: - Reading the shape

    /// Three panes side by side in one branch: `[1, 2, 3]` in layout order, the third focused. The
    /// layout most of the checks above are written against.
    private static func threePanes() -> PaneTree {
        var tree = PaneTree(first: pane(1))
        tree.split(pane(1), adding: pane(2), .right)
        tree.split(pane(2), adding: pane(3), .right)
        return tree
    }

    private static func pane(_ value: UInt64) -> PaneID { PaneID(rawValue: value) }

    private static func isLeaf(_ node: PaneTree.Node) -> Bool { node.paneID != nil }

    private static func branch(_ tree: PaneTree) -> PaneTree.Branch? {
        guard case .branch(let branch) = tree.root else { return nil }
        return branch
    }

    private static func nestedBranch(_ tree: PaneTree, at index: Int) -> PaneTree.Branch? {
        guard let branch = branch(tree), branch.children.indices.contains(index),
            case .branch(let nested) = branch.children[index].node
        else { return nil }
        return nested
    }

    private static func leafChildren(_ tree: PaneTree) -> Int {
        branch(tree)?.children.compactMap { $0.node.paneID }.count ?? 0
    }

    private static func everyBranchHasTwoChildren(_ node: PaneTree.Node) -> Bool {
        guard case .branch(let branch) = node else { return true }
        guard branch.children.count >= 2 else { return false }
        return branch.children.allSatisfy { everyBranchHasTwoChildren($0.node) }
    }
}
