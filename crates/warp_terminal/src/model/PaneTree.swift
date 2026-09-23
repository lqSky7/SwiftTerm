import Foundation

/// A pane's identity. Monotonic and never reused, like `BlockID`, so a view can key on it and an
/// action can name a pane that has since been closed without landing on a new one by accident.
struct PaneID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: PaneID, rhs: PaneID) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { "pane\(rawValue)" }
}

/// The axis a split divides along — Warp's `SplitDirection`.
///
/// It is the *axis*, not the side the new pane lands on. Warp keeps a second type for that, and this
/// file keeps the pair apart for the same reason it does: "the horizontal direction" and "the
/// horizontal axis" being one word is how a split ends up on the wrong side of the pane.
enum SplitAxis {
    /// Side by side, divided by a vertical rule.
    case horizontal
    /// Stacked, divided by a horizontal rule.
    case vertical
}

/// Which side of the pane being split the new pane lands on — Warp's `Direction`.
enum SplitPlacement {
    case left
    case right
    case up
    case down

    var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// Whether the new pane goes *before* the pane it was split from. This is the whole reason there
    /// are four placements rather than two axes: `left` and `up` put the new pane at the start.
    var goesBefore: Bool {
        switch self {
        case .left, .up: true
        case .right, .down: false
        }
    }
}

/// The panes in one tab, and which of them is showing.
///
/// Pure, and it holds identities rather than sessions: a pane here is a `PaneID`, and the session it
/// stands for is the view layer's to keep. Warp's tree is the same shape — `Leaf(PaneId)`, with the
/// `PaneGroup` holding the panes — and that is what lets a harness exercise every layout a user can
/// build with no shell, no window and no pty.
///
/// A tab with no splits is a tree of one leaf, so there is no separate "unsplit" case to keep in
/// step with the tree, and no window is ever in a state the tree cannot describe.
struct PaneTree {
    /// Warp's `PaneNode`.
    enum Node {
        /// A pane.
        case leaf(PaneID)
        /// A split: an axis and the children laid out along it.
        case branch(Branch)

        /// The pane this node is, when it is a pane rather than a split.
        var paneID: PaneID? {
            guard case .leaf(let pane) = self else { return nil }
            return pane
        }

        /// The first and last panes under this node, in layout order.
        ///
        /// A divider is named by the pair of panes either side of it, and those are exactly these two:
        /// the last pane of the child before it and the first pane of the child after it. Naming a
        /// divider that way is what lets a drag refer to one without knowing the shape of the tree.
        var firstLeaf: PaneID? {
            switch self {
            case .leaf(let pane): pane
            case .branch(let branch): branch.children.first?.node.firstLeaf
            }
        }

        var lastLeaf: PaneID? {
            switch self {
            case .leaf(let pane): pane
            case .branch(let branch): branch.children.last?.node.lastLeaf
            }
        }
    }

    /// One child of a branch, and the share of the branch's extent it takes along the axis.
    ///
    /// The weight lives *with* the child rather than in a parallel array of weights, because two arrays
    /// that have to stay the same length is a bug waiting for the first person who removes a child and
    /// updates one of them.
    struct Child {
        /// How much of the branch this child gets, relative to its siblings. Never zero or negative: a
        /// pane with no share has been closed, and one with a negative share would be drawn inside
        /// another.
        var weight: CGFloat
        var node: Node
    }

    /// Warp's `PaneBranch`, without its dividers.
    ///
    /// The weights were deliberately absent until there was something to write them — they are a drag's
    /// business, and a weight nothing wrote to would have drifted, which is the argument that keeps
    /// `HeaderGrid` one grid. The drag exists now, so they do. The *dividers* are still absent: a divider
    /// is the gap between two panes, and `PaneLayout` derives it from the frames rather than the tree
    /// keeping a second copy of the same geometry.
    struct Branch {
        var axis: SplitAxis
        var children: [Child]
    }

    /// What a new child weighs.
    ///
    /// Every split adds a child of this weight, so a branch's children start equal and only a drag makes
    /// them differ. It is Warp's `DEFAULT_FLEX_SIZE`, and it is why splitting one of two panes gives three
    /// equal columns rather than halving the pane that was split.
    static let defaultWeight: CGFloat = 1

    private(set) var root: Node

    /// The pane the keyboard goes to. Kept here rather than on the tab so a tab cannot disagree with
    /// its own tree about it, and it is always a leaf that is present — every operation that removes
    /// a pane moves it first.
    private(set) var focused: PaneID

    init(first: PaneID) {
        root = .leaf(first)
        focused = first
    }

    /// Every pane, in the order they are laid out: left to right, then top to bottom. This is the
    /// order a tab bar and a sidebar read, and the order `focusNext` walks.
    var panes: [PaneID] { Self.leaves(of: root) }

    var count: Int { panes.count }

    func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }

    /// Split `pane`, putting `newPane` on the `placement` side of it, and focus the new pane — which
    /// is what makes the split shortcut and then typing land where the eye already is.
    ///
    /// The subtlety Warp gets right and a naive tree gets wrong: when the pane's own branch already
    /// runs along the same axis, the new leaf joins that branch as a *sibling* instead of nesting a
    /// second branch inside the first. Three panes side by side are one branch of three, not a
    /// staircase of nested pairs — and the difference is visible the moment a divider is dragged.
    ///
    /// Returns whether the pane was there to split.
    @discardableResult
    mutating func split(_ pane: PaneID, adding newPane: PaneID, _ placement: SplitPlacement) -> Bool {
        let (newRoot, didSplit) = Self.split(root, at: pane, adding: newPane, placement)
        guard didSplit else { return false }
        root = newRoot
        focused = newPane
        return true
    }

    /// Close a pane.
    ///
    /// Does nothing when `pane` is the only one left — a tree with no panes is not a layout, so the
    /// caller closes the tab instead — and nothing when it was never here.
    ///
    /// Removing a leaf can leave its branch holding a single child, and a branch of one is not a
    /// layout: it is the survivor's space with a level of nesting around it. Warp collapses it, so
    /// closing one of two panes side by side gives the other the whole width rather than half of it.
    mutating func close(_ pane: PaneID) {
        let order = panes
        guard order.count > 1, let index = order.firstIndex(of: pane) else { return }

        // Warp's rule, from `focus_next_terminal_pane_and_activate_session`'s fallback when there is
        // no focus history to consult: the pane before it, or the one after when it was the first.
        // The history itself is not modelled — it exists for undo-close, which is Phase 6.
        if focused == pane {
            focused = index > 0 ? order[index - 1] : order[1]
        }
        root = Self.removing(root, pane)
    }

    /// Focus a pane that is present. Returns whether it was.
    @discardableResult
    mutating func focus(_ pane: PaneID) -> Bool {
        guard contains(pane) else { return false }
        focused = pane
        return true
    }

    /// The next pane in layout order, wrapping round — Warp's `next_pane_id_navigation`.
    mutating func focusNext() { moveFocus(by: 1) }

    /// The previous pane in layout order, wrapping round.
    mutating func focusPrevious() { moveFocus(by: -1) }

    private mutating func moveFocus(by offset: Int) {
        let order = panes
        guard let index = order.firstIndex(of: focused) else { return }
        focused = order[(index + offset + order.count) % order.count]
    }

    private static func leaves(of node: Node) -> [PaneID] {
        switch node {
        case .leaf(let pane): [pane]
        case .branch(let branch): branch.children.flatMap { leaves(of: $0.node) }
        }
    }

    private static func split(
        _ node: Node, at pane: PaneID, adding newPane: PaneID, _ placement: SplitPlacement
    ) -> (Node, Bool) {
        switch node {
        case .leaf(let leaf):
            guard leaf == pane else { return (node, false) }
            let existing = Child(weight: defaultWeight, node: .leaf(leaf))
            let added = Child(weight: defaultWeight, node: .leaf(newPane))
            let children = placement.goesBefore ? [added, existing] : [existing, added]
            return (.branch(Branch(axis: placement.axis, children: children)), true)

        case .branch(var branch):
            // Same axis: the new pane joins this branch as a sibling, which is the case above.
            if branch.axis == placement.axis,
                let index = branch.children.firstIndex(where: { $0.node.paneID == pane }) {
                let child = Child(weight: defaultWeight, node: .leaf(newPane))
                branch.children.insert(child, at: placement.goesBefore ? index : index + 1)
                return (.branch(branch), true)
            }
            for (index, child) in branch.children.enumerated() {
                let (replacement, didSplit) = split(
                    child.node, at: pane, adding: newPane, placement)
                guard didSplit else { continue }
                branch.children[index].node = replacement
                return (.branch(branch), true)
            }
            return (node, false)
        }
    }

    /// Remove a leaf, and collapse any branch left holding one child.
    ///
    /// A branch always holds at least two children — `split` makes two and this collapses at one —
    /// so the `count == 1` case below cannot fire on a branch that was already degenerate.
    private static func removing(_ node: Node, _ pane: PaneID) -> Node {
        guard case .branch(var branch) = node else { return node }

        if let index = branch.children.firstIndex(where: { $0.node.paneID == pane }) {
            branch.children.remove(at: index)
        } else {
            for (index, child) in branch.children.enumerated() {
                guard case .branch = child.node else { continue }
                branch.children[index].node = removing(child.node, pane)
            }
        }

        guard branch.children.count == 1 else { return .branch(branch) }
        return branch.children[0].node
    }

    // MARK: - Dragging a divider

    /// Move the divider between two adjacent panes.
    ///
    /// `fraction` is a fraction of the branch's extent along its axis, which is what a drag naturally
    /// produces: the view knows how far the pointer moved and how long the branch is, and the model has no
    /// business knowing about points.
    ///
    /// The *pair's* combined share is unchanged, so the panes outside the pair do not move. That is what
    /// makes dragging a divider feel like moving one edge rather than re-flowing the whole window.
    ///
    /// Neither pane can be squeezed past `minimum` — a fraction of the branch, not a weight — because a
    /// divider that can be dragged until a pane disappears is a pane nobody can get back: its edge went
    /// with it.
    ///
    /// Returns whether that boundary was there to move. The pair names it, so a pair that is not two
    /// adjacent children of one branch — a stale one from before a split, say — moves nothing.
    @discardableResult
    mutating func resize(
        between leading: PaneID, and trailing: PaneID, by fraction: CGFloat,
        minimum: CGFloat = defaultMinimumShare
    ) -> Bool {
        let (newRoot, didResize) = Self.resizing(
            root, between: leading, and: trailing, by: fraction, minimum: minimum)
        guard didResize else { return false }
        root = newRoot
        return true
    }

    /// The smallest share of a branch a pane may be dragged down to.
    static let defaultMinimumShare: CGFloat = 0.05

    private static func resizing(
        _ node: Node, between leading: PaneID, and trailing: PaneID, by fraction: CGFloat,
        minimum: CGFloat
    ) -> (Node, Bool) {
        guard case .branch(var branch) = node else { return (node, false) }

        let pair = branch.children.indices.first { index in
            branch.children.indices.contains(index + 1)
                && branch.children[index].node.lastLeaf == leading
                && branch.children[index + 1].node.firstLeaf == trailing
        }

        if let index = pair {
            let total = branch.children.reduce(0) { $0 + $1.weight }
            guard total > 0 else { return (node, false) }
            let floor = minimum * total
            let before = branch.children[index].weight
            let after = branch.children[index + 1].weight
            // Clamped so neither pane can be squeezed past the floor. When the pair is too small to give
            // both of them their floor there is nothing to give, so the divider does not move at all
            // rather than moving one of them below it.
            let lower = floor - before
            let upper = after - floor
            let allowed = lower <= upper ? min(max(fraction * total, lower), upper) : 0
            branch.children[index].weight = before + allowed
            branch.children[index + 1].weight = after - allowed
            return (.branch(branch), true)
        }

        for (position, child) in branch.children.enumerated() {
            guard case .branch = child.node else { continue }
            let (replacement, didResize) = resizing(
                child.node, between: leading, and: trailing, by: fraction, minimum: minimum)
            guard didResize else { continue }
            branch.children[position].node = replacement
            return (.branch(branch), true)
        }
        return (node, false)
    }
}
