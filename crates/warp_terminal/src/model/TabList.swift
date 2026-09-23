import Foundation

/// The tabs in one window, and which one is showing.
///
/// Pure. Nothing here knows about a session, a window or a pty: a tab is a shape, and the sessions
/// that fill it are the view layer's, keyed by `PaneID`. This is the whole of Phase 4b's structural
/// change — `AppCore` holds one of these where it used to hold one `TerminalCoordinator`, and the
/// sidebar and the tab bar are two views over `tabs`.
struct TabList {
    /// The tabs, in the order the tab bar shows them.
    private(set) var tabs: [Tab] = []

    /// The tab being shown. Always a tab that is present, and `nil` only when there are none — which
    /// is a window with nothing in it, the state `AppCore` closes a window from rather than one it
    /// sits in.
    private(set) var activeTabID: TabID?

    private var nextTabIdentifier: UInt64 = 1
    private var nextPaneIdentifier: UInt64 = 1

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var isEmpty: Bool { tabs.isEmpty }
    var count: Int { tabs.count }

    /// How many panes every tab together holds — what a sidebar's session count reads. The settings page
    /// is not a session and is not counted.
    var paneCount: Int { tabs.reduce(0) { $0 + ($1.panes?.count ?? 0) } }

    /// Open a tab holding one shell, and show it, which is what opening a tab does.
    ///
    /// Returns the pane the caller has to start a session for. The tab itself is not returned: it is
    /// `activeTabID` by definition, since opening a tab shows it, and a copy of a `Tab` handed back here
    /// would go stale the moment the tab was split — the same reason `Tab` holds a tree rather than the
    /// tree being reachable from somewhere else.
    @discardableResult
    mutating func add() -> PaneID {
        let id = TabID(rawValue: nextTabIdentifier)
        nextTabIdentifier += 1
        let firstPane = mintPane()
        tabs.append(Tab(id: id, content: .terminals(PaneTree(first: firstPane))))
        activeTabID = id
        return firstPane
    }

    /// Show the settings page, in a tab of its own.
    ///
    /// One per window: asking again brings the tab that is already there to the front rather than opening
    /// a second copy of the same controls. That is what a person means by asking twice, and it is what
    /// stops "which tab has the settings" from becoming a question with two answers.
    ///
    /// Returns the tab's identity, so a caller can say where it went.
    @discardableResult
    mutating func openSettings() -> TabID {
        if let existing = tabs.first(where: { $0.content.isSettings }) {
            activeTabID = existing.id
            return existing.id
        }
        let id = TabID(rawValue: nextTabIdentifier)
        nextTabIdentifier += 1
        tabs.append(Tab(id: id, content: .settings))
        activeTabID = id
        return id
    }

    /// Close a tab. The last one closing leaves an empty list, and the caller reads that as "close
    /// the window" — a `TabList` cannot close a window and does not pretend to.
    ///
    /// When the tab being closed is the one showing, the tab to its right takes over, or the one to
    /// its left when it was the last. That is the browser rule, and it is deliberately not the pane
    /// rule below: a hand expects the strip to move one step left, and Warp's panes move the other
    /// way because a pane's neighbour is usually where the last command ran. Two rules, each
    /// recorded where it lives so neither gets "fixed" into the other.
    mutating func close(_ tab: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        let wasShowing = activeTabID == tab
        tabs.remove(at: index)
        guard wasShowing else { return }
        activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
    }

    /// Show a tab that is present. Returns whether it was.
    @discardableResult
    mutating func select(_ tab: TabID) -> Bool {
        guard tabs.contains(where: { $0.id == tab }) else { return false }
        activeTabID = tab
        return true
    }

    /// The next tab along the strip, wrapping round.
    mutating func selectNext() { moveSelection(by: 1) }

    /// The previous tab along the strip, wrapping round.
    mutating func selectPrevious() { moveSelection(by: -1) }

    /// Split a pane and focus the new one. Returns the pane that was added, which is what the view
    /// layer needs in order to start a session for it, or `nil` when that pane is not in that tab.
    ///
    /// A refused split mints no identity, so the counter cannot be spent by a caller that asked for
    /// something the model could not give it — the same "either it happens or nothing does" the pane
    /// close has. The settings page is not a terminal and cannot be split, which this refuses by the same
    /// test every pane operation starts with.
    @discardableResult
    mutating func split(_ pane: PaneID, in tab: TabID, _ placement: SplitPlacement) -> PaneID? {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            case .terminals(var tree) = tabs[index].content,
            tree.contains(pane)
        else { return nil }
        let newPane = mintPane()
        tree.split(pane, adding: newPane, placement)
        tabs[index].content = .terminals(tree)
        return newPane
    }

    /// Close a pane. When it was its tab's last, the tab closes with it: a tab holding no panes is not a
    /// state this model can be in, so that decision is made here rather than left to a caller who might
    /// forget it.
    ///
    /// The pane is checked to be *in* that tab before anything happens. Without that check a pane
    /// belonging to another tab would close this one, which is the sort of mistake a caller makes once
    /// and then stops trusting the model over.
    mutating func closePane(_ pane: PaneID, in tab: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            case .terminals(var tree) = tabs[index].content,
            tree.contains(pane)
        else { return }
        guard tree.count > 1 else {
            close(tab)
            return
        }
        tree.close(pane)
        tabs[index].content = .terminals(tree)
    }

    /// Drag a divider in a tab's layout. Returns whether that boundary was there to move.
    ///
    /// `fraction` is a fraction of the branch's extent along its axis, which is what a drag produces: the
    /// view knows how far the pointer moved and how long the branch is.
    @discardableResult
    mutating func resizePanes(
        between leading: PaneID, and trailing: PaneID, by fraction: CGFloat, in tab: TabID
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            case .terminals(var tree) = tabs[index].content,
            tree.resize(between: leading, and: trailing, by: fraction)
        else { return false }
        tabs[index].content = .terminals(tree)
        return true
    }

    /// Focus a pane inside a tab — what clicking its row in a sidebar does. Returns whether it was there,
    /// so a caller can tell a click on a stale row from a click that worked.
    @discardableResult
    mutating func focus(_ pane: PaneID, in tab: TabID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            case .terminals(var tree) = tabs[index].content,
            tree.focus(pane)
        else { return false }
        tabs[index].content = .terminals(tree)
        return true
    }

    /// Move the focus to the next pane of a tab, wrapping round.
    mutating func focusNextPane(in tab: TabID) { moveFocus(in: tab, by: 1) }

    /// Move the focus to the previous pane of a tab, wrapping round.
    mutating func focusPreviousPane(in tab: TabID) { moveFocus(in: tab, by: -1) }

    private mutating func moveFocus(in tab: TabID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            case .terminals(var tree) = tabs[index].content
        else { return }
        if offset > 0 { tree.focusNext() } else { tree.focusPrevious() }
        tabs[index].content = .terminals(tree)
    }

    // MARK: - Naming and order

    /// Rename a tab, or clear the name with `nil` or blank text so it goes back to showing the
    /// session's own title.
    ///
    /// Whitespace is trimmed rather than rejected: a name that is only spaces is a name nobody meant,
    /// and storing it would make the tab look unnamed while behaving as though it were named.
    mutating func rename(_ tab: TabID, to title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Pin a tab, or unpin it.
    ///
    /// Both directions land in the same slot, which is the nice thing about the invariant: the pinned
    /// tabs are a block at the front, so the end of that block is the end of the pinned group when
    /// pinning and the start of everything else when unpinning.
    mutating func setPinned(_ pinned: Bool, for tab: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }),
            tabs[index].isPinned != pinned
        else { return }

        let boundary = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
        var moved = tabs.remove(at: index)
        moved.isPinned = pinned
        // Unpinning removes a tab from *inside* the block, so the boundary it was measured against
        // has moved down by one.
        tabs.insert(moved, at: index < boundary ? boundary - 1 : boundary)
    }

    /// Move a tab to a position in the list — what dragging one does.
    ///
    /// The pinned block is an invariant rather than a suggestion, so a move is clamped to keep it: an
    /// unpinned tab cannot be dropped among the pinned ones and a pinned tab cannot leave the block.
    /// Dropping an unpinned tab *onto* the block is a request to sit next to it, not to be pinned, and
    /// pinning it silently would be the model doing something nobody asked for.
    mutating func move(_ tab: TabID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab }) else { return }
        let moved = tabs.remove(at: from)
        // Measured after the removal, because the tab being moved is no longer in the list.
        let boundary = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
        var to = min(max(destination, 0), tabs.count)
        to = moved.isPinned ? min(to, boundary) : max(to, boundary)
        tabs.insert(moved, at: to)
    }

    private mutating func moveSelection(by offset: Int) {
        guard let showing = activeTabID,
            let index = tabs.firstIndex(where: { $0.id == showing })
        else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// A pane identity from a counter the whole window shares, so no two panes in it can collide
    /// however many tabs are opened. Minted here rather than by the caller, because this is the only
    /// thing that knows every tab.
    private mutating func mintPane() -> PaneID {
        defer { nextPaneIdentifier += 1 }
        return PaneID(rawValue: nextPaneIdentifier)
    }
}
