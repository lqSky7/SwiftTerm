import Foundation

/// What was open when the window closed, so the next launch can put it back.
///
/// A **description of the shape** rather than the tabs themselves: `TabID` and `PaneID` are monotonic and never
/// reused, so restoring the recorded ones would collide with anything opened since. This records how many tabs there
/// were, how each was split, which pane had the keyboard and what directory each pane was in; the replay mints fresh
/// ids.
///
/// The directories are the whole reason it is worth writing down. A restored layout with every shell back in the home
/// directory is a window that looks right and is useless.
struct SessionSnapshot: Equatable, Codable {
    /// One pane, as far as the snapshot cares: where it was.
    struct Pane: Equatable, Codable {
        var workingDirectory: String?
    }

    /// How a tab's panes are arranged.
    indirect enum Layout: Equatable, Codable {
        case pane(Pane)
        /// A split along an axis, with its children in layout order.
        case split(axis: Axis, children: [Layout])
    }

    enum Axis: String, Equatable, Codable {
        case horizontal
        case vertical
    }

    struct Tab: Equatable, Codable {
        var layout: Layout
        /// Which pane had the keyboard, **counted in layout order** — an index rather than an id, because the ids do
        /// not survive the round trip.
        var focusedPane: Int
    }

    var tabs: [Tab]
    var activeTab: Int

    /// An empty window, which is what a first launch restores.
    static let empty = SessionSnapshot(tabs: [], activeTab: 0)

    // MARK: - Capturing

    /// Read the shape out of a live tab list.
    ///
    /// The working directory is asked for per pane rather than looked up here: the directories belong to the
    /// *sessions*, which are the view layer's, and this model has never known about one. The settings tab is skipped —
    /// it is chrome, not a session, and reopening it on launch would be a window that opens onto its own settings.
    init(tabs list: TabList, workingDirectory: (PaneID) -> String?) {
        var captured: [Tab] = []
        for tab in list.tabs {
            guard case .terminals(let tree) = tab.content else { continue }
            captured.append(
                Tab(
                    layout: Self.layout(of: tree.root, workingDirectory: workingDirectory),
                    focusedPane: tree.panes.firstIndex(of: tree.focused) ?? 0))
        }
        self.tabs = captured
        self.activeTab = list.tabs.firstIndex { $0.id == list.activeTabID } ?? 0
    }

    private init(tabs: [Tab], activeTab: Int) {
        self.tabs = tabs
        self.activeTab = activeTab
    }

    private static func layout(
        of node: PaneTree.Node, workingDirectory: (PaneID) -> String?
    ) -> Layout {
        switch node {
        case .leaf(let pane):
            return .pane(Pane(workingDirectory: workingDirectory(pane)))
        case .branch(let branch):
            return .split(
                axis: branch.axis == .horizontal ? .horizontal : .vertical,
                children: branch.children.map {
                    layout(of: $0.node, workingDirectory: workingDirectory)
                })
        }
    }

    // MARK: - Replaying

    /// Rebuild the tabs, handing back every pane that needs a session started for it.
    ///
    /// The caller starts one shell per returned pane, in the directory beside it — which is the only part of this that
    /// needs a pty, and so the only part that is not here.
    func restore(into list: inout TabList) -> [(pane: PaneID, workingDirectory: String?)] {
        var started: [(pane: PaneID, workingDirectory: String?)] = []
        for (index, recorded) in tabs.enumerated() {
            let first = list.add()
            guard let tabID = list.activeTabID else { continue }
            apply(recorded.layout, to: first, in: tabID, into: &list, started: &started)

            if let tree = list.tabs.first(where: { $0.id == tabID })?.panes,
                tree.panes.indices.contains(recorded.focusedPane)
            {
                _ = list.focus(tree.panes[recorded.focusedPane], in: tabID)
            }
            if index == activeTab { _ = list.select(tabID) }
        }
        return started
    }

    private func apply(
        _ layout: Layout, to pane: PaneID, in tab: TabID, into list: inout TabList,
        started: inout [(pane: PaneID, workingDirectory: String?)]
    ) {
        switch layout {
        case .pane(let recorded):
            started.append((pane, recorded.workingDirectory))

        case .split(let axis, let children):
            guard !children.isEmpty else {
                started.append((pane, nil))
                return
            }
            // The placement is the *axis*'s own: a horizontal split puts each new pane to the right of the last one,
            // a vertical split below it. Splitting the pane that was just created — rather than the original — is what
            // keeps the children in the order they were recorded instead of reversing them.
            let placement: SplitPlacement = axis == .horizontal ? .right : .down
            var current = pane
            for (index, child) in children.enumerated() {
                // The first child *is* the pane that was handed in; each later one is a new split after it.
                if index > 0 {
                    guard let new = list.split(current, in: tab, placement) else { continue }
                    current = new
                }
                apply(child, to: current, in: tab, into: &list, started: &started)
                // The next child goes after everything this one added, which is the tab's last pane — read from the
                // tree rather than tracked, so a child that is itself a split cannot put the next one inside it.
                if let tree = list.tabs.first(where: { $0.id == tab })?.panes, let last = tree.panes.last {
                    current = last
                }
            }
        }
    }
}

/// Where the snapshot lives between launches.
///
/// JSON in `Application Support`, beside the settings. Written whole and read whole: it is a description of a window,
/// and a partial one is not a smaller window, it is a wrong one.
struct SessionSnapshotStore {
    let url: URL
    private let fileManager: FileManager

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("swiftTerm/session.json", isDirectory: false)
    }

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? Self.defaultURL(fileManager: fileManager)
    }

    /// What was open last time. A missing or unreadable file is an empty window rather than a failure — the first
    /// launch has no file, and a terminal that refused to start over one would be a terminal that could not be used.
    func load() -> SessionSnapshot {
        guard let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    func save(_ snapshot: SessionSnapshot) {
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
