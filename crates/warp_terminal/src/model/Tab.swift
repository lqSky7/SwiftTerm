import Foundation

/// A tab's identity. Monotonic and never reused, like `PaneID` — a sidebar can key on it, and a tab
/// that has been closed is never confused with a new one.
struct TabID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: TabID, rhs: TabID) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { "tab\(rawValue)" }
}

/// One tab: the panes it holds, and which of them the keyboard is in.
///
/// A tab is not a session. A tab with no splits is one pane and so one session, but the moment it is
/// split it is several, which is why the tab owns a tree and the sessions live beside it in the view
/// layer, keyed by `PaneID`. A tab is a shape; the sessions are what fills it.
/// What a tab holds.
///
/// A tab is not always a terminal. The settings page lives in a tab like everything else — which is the
/// point: one window, one list of what is open, and no second kind of chrome to keep in step with the
/// first. A settings *window* would be a second place that knows what is open.
enum TabContent {
    /// A tree of terminal panes, one of which has the keyboard.
    case terminals(PaneTree)
    /// The settings page. There is one per window, and asking for it again shows that one.
    case settings


    /// Whether this is the settings page.
    ///
    /// Written as a match rather than as `content == .settings`, deliberately: the terminals case carries
    /// a whole pane tree, and making that `Equatable` so two tabs could be compared would be a
    /// conformance earned by a test rather than by a use. Comparing a pane tree is not a question this
    /// model has ever needed to ask.
    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }

}

struct Tab {
    let id: TabID

    /// What the tab holds: terminal panes, or the settings page.
    var content: TabContent

    /// What the user called this tab, when they renamed it.
    ///
    /// The title a tab *shows* is derived — the focused pane's session title, which the shell keeps up
    /// to date as the directory changes. This is only the override, which is why it is optional and
    /// why clearing it restores the derived name rather than freezing whatever the directory happened
    /// to be at the moment of the rename. There is deliberately still no plain `title` here: a copy of
    /// a string the session already owns is the first place it goes stale.
    var customTitle: String? = nil

    /// A pinned tab is kept at the front of the list and out of the way of a drag.
    ///
    /// Pinning is a position, not a mark: the model holds the invariant that pinned tabs come first,
    /// so a view never has to sort them and two views cannot sort them differently.
    var isPinned: Bool = false

    /// The panes, when this tab has any. Owned rather than referenced, so a tab cannot be left pointing
    /// at a pane arrangement that no longer exists.
    ///
    /// `nil` for the settings page, and deliberately not an empty tree: an empty tree would mean "a
    /// terminal tab with no terminals", which is a state every pane operation would have to special-case.
    var panes: PaneTree? {
        guard case .terminals(let tree) = content else { return nil }
        return tree
    }

    /// The pane the keyboard is in, when there is one to be in.
    var focusedPane: PaneID? { panes?.focused }

    /// Whether this tab is a terminal. The one question every pane operation asks first.
    var isTerminal: Bool { panes != nil }
}
