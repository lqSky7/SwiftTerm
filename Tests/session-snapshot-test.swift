import Foundation

/// Guards the window's shape across a quit and a relaunch.
///
/// The two things that can be wrong here are both silent: a layout that comes back with the panes in a different
/// order still *looks* like a window, and a snapshot that loses the working directories still opens — it just opens
/// every shell in the home directory, which is the difference between restoring a session and pretending to.
@main
enum SessionSnapshotTest {
    static func main() {
        let harness = Harness("session-snapshot-test")

        itCapturesAndRestoresOneTab(harness)
        itKeepsTheSplitsAndTheirOrder(harness)
        itKeepsTheWorkingDirectories(harness)
        itKeepsWhichPaneHadTheKeyboard(harness)
        itSkipsTheSettingsTab(harness)
        itSurvivesJSON(harness)
        theStoreRoundTrips(harness)
        anAbsentFileIsAnEmptyWindow(harness)

        harness.finish()
    }

    /// A tab list with `panes` panes in one tab, split horizontally, and the last one focused.
    private static func listWithThreePanes() -> (TabList, TabID, [PaneID]) {
        var list = TabList()
        let first = list.add()
        guard let tab = list.activeTabID else { return (list, TabID(rawValue: 0), [first]) }
        let second = list.split(first, in: tab, .right) ?? first
        let third = list.split(second, in: tab, .right) ?? second
        _ = list.focus(third, in: tab)
        return (list, tab, [first, second, third])
    }

    private static func itCapturesAndRestoresOneTab(_ harness: Harness) {
        var list = TabList()
        _ = list.add()
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { _ in "/tmp" })

        harness.equal(snapshot.tabs.count, 1, "one tab was recorded")
        harness.equal(snapshot.activeTab, 0, "and it was the active one")

        var restored = TabList()
        let started = snapshot.restore(into: &restored)
        harness.equal(restored.tabs.count, 1, "and one tab comes back")
        harness.equal(started.count, 1, "with one pane needing a session")
        harness.equal(restored.paneCount, 1, "and one pane in it")
    }

    private static func itKeepsTheSplitsAndTheirOrder(_ harness: Harness) {
        let (list, _, panes) = listWithThreePanes()
        let directories = [panes[0]: "/one", panes[1]: "/two", panes[2]: "/three"]
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { directories[$0] })

        harness.equal(
            snapshot.tabs.first?.layout.childCount, 3, "all three panes were recorded")

        var restored = TabList()
        let started = snapshot.restore(into: &restored)
        harness.equal(restored.paneCount, 3, "and all three come back")
        harness.equal(started.count, 3, "each needing a session")

        // **The order is the part that fails quietly.** Splitting the pane that was just created — rather than the
        // original — is what keeps the children in the order they were recorded; the other way round restores a
        // mirror image that looks like a working window.
        harness.equal(
            started.map(\.workingDirectory), ["/one", "/two", "/three"],
            "and they come back in the order they were laid out, not reversed")
    }

    private static func itKeepsTheWorkingDirectories(_ harness: Harness) {
        let (list, _, panes) = listWithThreePanes()
        // Typed as `[PaneID: String]` rather than with an explicit nil: the middle pane is *absent* from the map,
        // which is the same thing as a pane that had no directory and does not need a double optional to say so.
        let directories = [panes[0]: "/Users/example/project", panes[2]: "/tmp"]
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { directories[$0] })

        var restored = TabList()
        let started = snapshot.restore(into: &restored)
        harness.equal(
            started.map(\.workingDirectory), ["/Users/example/project", nil, "/tmp"],
            "each pane's directory is recorded, and a pane that had none restores with none")
    }

    private static func itKeepsWhichPaneHadTheKeyboard(_ harness: Harness) {
        let (list, _, panes) = listWithThreePanes()
        // `listWithThreePanes` focused the third, so the index is 2.
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { _ in nil })
        harness.equal(snapshot.tabs.first?.focusedPane, 2, "the focused pane is recorded by its place")

        var restored = TabList()
        _ = snapshot.restore(into: &restored)
        guard let tree = restored.activeTab?.panes else {
            harness.expect(false, "a tab came back")
            return
        }
        harness.equal(
            tree.panes.firstIndex(of: tree.focused), 2,
            "and the third pane has the keyboard again — not the first, which is what ignoring this would give")
        harness.expect(!panes.isEmpty, "the fixture has panes")
    }

    private static func itSkipsTheSettingsTab(_ harness: Harness) {
        var list = TabList()
        _ = list.add()
        _ = list.openSettings()
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { _ in nil })

        harness.equal(
            snapshot.tabs.count, 1,
            "the settings tab is chrome rather than a session — reopening onto its own settings is not a restore")
    }

    private static func itSurvivesJSON(_ harness: Harness) {
        let (list, _, panes) = listWithThreePanes()
        let directories = [panes[0]: "/one", panes[1]: "/two", panes[2]: "/three"]
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { directories[$0] })

        guard let data = try? JSONEncoder().encode(snapshot),
            let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else {
            harness.expect(false, "the snapshot encodes and decodes")
            return
        }
        harness.equal(decoded, snapshot, "and what was written is what is read")

        var restored = TabList()
        _ = decoded.restore(into: &restored)
        harness.equal(restored.paneCount, 3, "and the decoded one still restores the window")
    }

    private static func theStoreRoundTrips(_ harness: Harness) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString).json")
        let store = SessionSnapshotStore(url: url)

        let (list, _, panes) = listWithThreePanes()
        let directories = [panes[0]: "/one", panes[1]: "/two", panes[2]: "/three"]
        let snapshot = SessionSnapshot(tabs: list, workingDirectory: { directories[$0] })
        store.save(snapshot)

        harness.equal(store.load(), snapshot, "a snapshot written to disk is a snapshot read back")
        try? FileManager.default.removeItem(at: url)
    }

    private static func anAbsentFileIsAnEmptyWindow(_ harness: Harness) {
        // The first launch has no file. A terminal that refused to start over one would be a terminal that could not be
        // used at all, so an absent file is an empty window rather than a failure.
        let store = SessionSnapshotStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("no-such-session-\(UUID().uuidString).json"))
        harness.equal(store.load(), .empty, "a missing snapshot is an empty window")

        // And an empty snapshot restores nothing rather than failing.
        var list = TabList()
        harness.equal(SessionSnapshot.empty.restore(into: &list).count, 0, "and it restores no panes")
        harness.equal(list.tabs.count, 0, "leaving the window empty for `AppCore` to fill")
    }
}

extension SessionSnapshot.Layout {
    /// How many panes this layout holds. A test convenience, and written as a walk rather than a stored count so it
    /// cannot disagree with the tree.
    fileprivate var childCount: Int {
        switch self {
        case .pane: return 1
        case .split(_, let children): return children.reduce(0) { $0 + $1.childCount }
        }
    }
}
