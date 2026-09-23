import Foundation

/// Guards the tab list: opening, closing, which tab is showing, and the two rules that keep it
/// consistent — a tab never holds no panes, and no two panes in a window ever share an identity.
///
/// Those two are the reason this is a model rather than arithmetic in `AppCore`. A window whose
/// sessions are keyed by pane identity and whose pane identities can collide is a window that shows
/// one shell's output in another shell's pane, and nothing about that is visible in a screenshot of
/// a single tab.
@main
enum TabListTest {
    static func main() {
        let harness = Harness("tab-list-test")

        aFreshListIsEmpty(harness)
        openingATab(harness)
        identitiesAreNeverReused(harness)
        everyPaneInTheWindowIsItsOwn(harness)
        showingATab(harness)
        closingATab(harness)
        splittingAPane(harness)
        closingAPane(harness)
        focusingAPane(harness)
        namingATab(harness)
        pinningATab(harness)
        movingATab(harness)
        theSettingsTab(harness)

        harness.finish()
    }

    private static func aFreshListIsEmpty(_ harness: Harness) {
        let list = TabList()
        harness.expect(list.isEmpty, "a new list has no tabs")
        harness.equal(list.count, 0, "and a count of none")
        harness.expect(list.activeTabID == nil, "and nothing is showing")
        harness.expect(list.activeTab == nil, "so there is no active tab")
        harness.equal(list.paneCount, 0, "and no panes")
    }

    private static func openingATab(_ harness: Harness) {
        var list = TabList()

        let first = list.add()
        harness.equal(list.count, 1, "one tab")
        harness.expect(list.activeTabID != nil, "and something is showing")
        harness.equal(panes(list, 0), [first], "holding the pane that was returned")
        harness.equal(focused(list, 0), first, "which is focused")
        harness.equal(list.paneCount, 1, "one pane in the window")

        let second = list.add()
        harness.equal(list.count, 2, "a second tab")
        harness.expect(first != second, "with a pane of its own")
        harness.expect(list.activeTabID == list.tabs[1].id, "and the new tab is the one showing")
        harness.expect(list.tabs[0].id != list.tabs[1].id, "the tabs have their own identities")
        harness.equal(list.paneCount, 2, "two panes in the window")
    }

    /// A closed tab's identity must not come back. A view keying on `TabID` would otherwise key a
    /// brand new tab to the one the user just closed.
    private static func identitiesAreNeverReused(_ harness: Harness) {
        var list = TabList()
        list.add()
        let second = list.tabs[0].id
        list.close(second)
        list.add()

        harness.equal(list.count, 1, "one tab again")
        harness.expect(list.tabs[0].id != second, "the identity is not reused")
        harness.expect(list.tabs[0].id.rawValue > second.rawValue, "the counter only goes up")

        // The same for panes: the new tab's pane is minted from the window's counter, not the tab's.
        var panes = TabList()
        let first = panes.add()
        let firstTab = panes.tabs[0].id
        panes.close(firstTab)
        let second2 = panes.add()
        harness.expect(second2 != first, "a pane identity is not reused either")
        harness.expect(second2.rawValue > first.rawValue, "and its counter only goes up")
    }

    private static func everyPaneInTheWindowIsItsOwn(_ harness: Harness) {
        var list = TabList()
        let a = list.add()
        let firstTab = list.tabs[0].id
        let secondPane = list.add()
        let secondTab = list.tabs[1].id

        guard let b = list.split(a, in: firstTab, .right) else {
            harness.expect(false, "the split added a pane")
            return
        }

        harness.equal(list.paneCount, 3, "three panes across two tabs")
        let all = allPanes(list)
        harness.equal(all.count, 3, "all of them in the list")
        harness.equal(Set(all).count, 3, "and no two of them share an identity")
        harness.expect(a != b && b != secondPane, "the identities differ from each other")

        // Splitting in a tab that is not showing must not bring it forward.
        harness.expect(list.activeTabID == secondTab, "the other tab is still the one showing")
    }

    private static func showingATab(_ harness: Harness) {
        var list = TabList()
        list.add()
        let first = list.tabs[0].id
        list.add()
        let second = list.tabs[1].id
        list.add()
        let third = list.tabs[2].id

        harness.expect(list.activeTabID == third, "the newest tab shows")

        harness.expect(list.select(first), "select a tab that is there")
        harness.expect(list.activeTabID == first, "and it shows")

        harness.expect(!list.select(TabID(rawValue: 99)), "selecting a stranger is refused")
        harness.expect(list.activeTabID == first, "and leaves the showing tab alone")

        list.selectNext()
        harness.expect(list.activeTabID == second, "next moves one along")
        list.selectNext()
        harness.expect(list.activeTabID == third, "and again")
        list.selectNext()
        harness.expect(list.activeTabID == first, "wrapping round to the start")

        list.selectPrevious()
        harness.expect(list.activeTabID == third, "previous wraps the other way")
        list.selectPrevious()
        harness.expect(list.activeTabID == second, "and walks back")
    }

    private static func closingATab(_ harness: Harness) {
        // Closing a tab that is not showing leaves the showing one where it was.
        var list = TabList()
        list.add()
        let first = list.tabs[0].id
        list.add()
        let second = list.tabs[1].id
        list.add()
        let third = list.tabs[2].id
        harness.expect(list.activeTabID == third, "the third tab shows")

        list.close(first)
        harness.equal(list.count, 2, "the first tab is gone")
        harness.expect(list.activeTabID == third, "and the showing tab is untouched")

        // Closing the showing tab with one to its right hands over to that one.
        list.select(second)
        list.close(second)
        harness.equal(list.count, 1, "the middle tab is gone")
        harness.expect(list.activeTabID == third, "and the tab to its right takes over")

        // Closing the last tab leaves an empty list — a window closing, which is the caller's to do.
        list.close(third)
        harness.expect(list.isEmpty, "no tabs left")
        harness.expect(list.activeTabID == nil, "and nothing showing")
        harness.equal(list.paneCount, 0, "and no panes")

        // With nothing to the right, the tab to the left takes over instead.
        var leftward = TabList()
        leftward.add()
        let only = leftward.tabs[0].id
        leftward.add()
        let last = leftward.tabs[1].id
        harness.expect(leftward.activeTabID == last, "the last tab shows")
        leftward.close(last)
        harness.expect(leftward.activeTabID == only, "and the one before it takes over")

        // A tab that is not there, closed twice, must not take a second tab with it.
        leftward.close(last)
        harness.equal(leftward.count, 1, "closing a stranger closes nothing")
    }

    private static func splittingAPane(_ harness: Harness) {
        var list = TabList()
        let a = list.add()
        let tab = list.tabs[0].id

        guard let b = list.split(a, in: tab, .right) else {
            harness.expect(false, "the first split added a pane")
            return
        }
        harness.equal(panes(list, 0), [a, b], "the new pane is beside the one it split")
        harness.equal(focused(list, 0), b, "and it is focused")
        harness.equal(list.paneCount, 2, "two panes in the window")

        guard let c = list.split(b, in: tab, .down) else {
            harness.expect(false, "the second split added a pane")
            return
        }
        harness.equal(panes(list, 0), [a, b, c], "a perpendicular split nests beside it")
        harness.equal(panes(list, 0).count, 3, "three panes in the tab")
        harness.equal(list.paneCount, 3, "and three in the window")

        // A pane that is not in that tab, and a tab that is not there, are both refused — and
        // neither mints an identity, which the next real split proves.
        harness.expect(
            list.split(PaneID(rawValue: 99), in: tab, .right) == nil, "a stranger pane is refused")
        harness.expect(
            list.split(a, in: TabID(rawValue: 99), .right) == nil, "a stranger tab is refused")
        harness.equal(panes(list, 0).count, 3, "and neither adds a pane")
        harness.equal(list.paneCount, 3, "so the window still holds three")

        guard let d = list.split(c, in: tab, .right) else {
            harness.expect(false, "the split after the refusals added a pane")
            return
        }
        harness.equal(d.rawValue, c.rawValue + 1, "a refused split spent no identity")
    }

    private static func closingAPane(_ harness: Harness) {
        var list = TabList()
        let a = list.add()
        let tab = list.tabs[0].id

        guard let b = list.split(a, in: tab, .right) else {
            harness.expect(false, "the split added a pane")
            return
        }

        list.closePane(b, in: tab)
        harness.equal(panes(list, 0), [a], "the split is gone")
        harness.equal(list.count, 1, "and the tab stays — it had another pane")
        harness.equal(focused(list, 0), a, "with the surviving pane focused")

        // A second tab, so closing the first one's last pane has somewhere to hand over to.
        let otherPane = list.add()
        let otherTab = list.tabs[1].id
        harness.equal(list.count, 2, "two tabs")

        // A pane belonging to the other tab must not close this one.
        list.closePane(otherPane, in: tab)
        harness.equal(list.count, 2, "a pane from another tab closes nothing")
        harness.equal(panes(list, 0), [a], "and leaves this tab's panes alone")

        list.closePane(a, in: tab)
        harness.equal(list.count, 1, "closing the last pane of a tab closes the tab")
        harness.expect(list.activeTabID == otherTab, "and the tab that is left is showing")
        harness.equal(list.paneCount, 1, "one pane left in the window")

        // Closing the only pane of the only tab leaves nothing at all.
        list.closePane(otherPane, in: otherTab)
        harness.expect(list.isEmpty, "no tabs left")
        harness.expect(list.activeTabID == nil, "and nothing showing")
        harness.equal(list.paneCount, 0, "and no panes")
    }

    /// What clicking a row in a sidebar does, and what the pane-focus keys do.
    private static func focusingAPane(_ harness: Harness) {
        var list = TabList()
        let a = list.add()
        let tab = list.tabs[0].id

        guard let b = list.split(a, in: tab, .right), let c = list.split(b, in: tab, .down) else {
            harness.expect(false, "the splits added panes")
            return
        }
        harness.equal(panes(list, 0), [a, b, c], "three panes")
        harness.equal(focused(list, 0), c, "the newest one has the focus")

        harness.expect(list.focus(a, in: tab), "focusing a pane that is there")
        harness.equal(focused(list, 0), a, "moves the focus to it")

        harness.expect(!list.focus(PaneID(rawValue: 99), in: tab), "focusing a stranger is refused")
        harness.equal(focused(list, 0), a, "and leaves the focus where it was")
        harness.expect(!list.focus(a, in: TabID(rawValue: 99)), "focusing in a stranger tab is refused")

        list.focusNextPane(in: tab)
        harness.equal(focused(list, 0), b, "next moves one along")
        list.focusNextPane(in: tab)
        harness.equal(focused(list, 0), c, "and again")
        list.focusNextPane(in: tab)
        harness.equal(focused(list, 0), a, "wrapping round to the start")
        list.focusPreviousPane(in: tab)
        harness.equal(focused(list, 0), c, "previous wraps the other way")

        // A tab that is not there focuses nothing, rather than focusing in whichever tab is showing.
        let before = focused(list, 0)
        list.focusNextPane(in: TabID(rawValue: 99))
        harness.equal(focused(list, 0), before, "a stranger tab focuses nothing")

        // And focusing in one tab leaves the other alone, which is what lets a sidebar show the
        // panes of the tab that is showing without the others being disturbed.
        let other = list.add()
        let otherTab = list.tabs[1].id
        harness.expect(list.focus(other, in: otherTab), "focusing the new tab's pane")
        harness.equal(focused(list, 0), before, "the first tab is untouched")
    }

    /// A tab's own name, which overrides the one the session derives.
    private static func namingATab(_ harness: Harness) {
        var list = TabList()
        list.add()
        let first = list.tabs[0].id
        list.add()

        harness.expect(list.tabs[0].customTitle == nil, "a new tab has no name of its own")
        list.rename(first, to: "build")
        harness.equal(list.tabs[0].customTitle, "build", "renaming stores the name")
        list.rename(first, to: "  spaced  ")
        harness.equal(list.tabs[0].customTitle, "spaced", "and trims it")

        // Clearing is the interesting case: it has to *remove* the override so the session's own title
        // shows through again, rather than freezing whatever the directory was at rename time.
        list.rename(first, to: "   ")
        harness.expect(list.tabs[0].customTitle == nil, "a blank name clears it")
        list.rename(first, to: "build")
        list.rename(first, to: nil)
        harness.expect(list.tabs[0].customTitle == nil, "and so does nil")

        list.rename(TabID(rawValue: 99), to: "nobody")
        harness.equal(list.count, 2, "renaming a stranger renames nothing")
        harness.expect(list.tabs[1].customTitle == nil, "and leaves the other tabs alone")
    }

    private static func pinningATab(_ harness: Harness) {
        var list = TabList()
        list.add()
        let a = list.tabs[0].id
        list.add()
        let b = list.tabs[1].id
        list.add()
        let c = list.tabs[2].id
        list.add()
        let d = list.tabs[3].id

        list.setPinned(true, for: c)
        harness.equal(list.tabs.map(\.id), [c, a, b, d], "a pinned tab goes to the front")
        harness.expect(list.tabs[0].isPinned, "and is marked pinned")

        list.setPinned(true, for: d)
        harness.equal(list.tabs.map(\.id), [c, d, a, b], "a second pinned tab goes after the first")

        list.setPinned(false, for: c)
        harness.equal(list.tabs.map(\.id), [d, c, a, b], "unpinning puts it at the front of the rest")
        harness.expect(
            list.tabs.first { $0.id == c }?.isPinned == false, "and it is no longer pinned")
        harness.expect(list.tabs.first { $0.id == d }?.isPinned == true, "while the other stays pinned")

        let before = list.tabs.map(\.id)
        list.setPinned(true, for: d)
        harness.equal(list.tabs.map(\.id), before, "pinning an already-pinned tab changes nothing")
        list.setPinned(true, for: TabID(rawValue: 99))
        harness.equal(list.tabs.map(\.id), before, "and pinning a stranger changes nothing")

        // A new tab goes after the pinned block rather than inside it.
        list.add()
        harness.equal(list.tabs.map(\.id)[0], d, "a new tab does not disturb the pinned block")
        harness.expect(list.tabs.last?.isPinned == false, "and is not pinned itself")
    }

    private static func movingATab(_ harness: Harness) {
        var list = TabList()
        list.add()
        let one = list.tabs[0].id
        list.add()
        let two = list.tabs[1].id
        list.add()
        let three = list.tabs[2].id
        list.add()
        let four = list.tabs[3].id

        list.move(one, to: 2)
        harness.equal(list.tabs.map(\.id), [two, three, one, four], "a tab lands at the index it was dropped at")
        list.move(four, to: 0)
        harness.equal(list.tabs.map(\.id), [four, two, three, one], "and at the front")
        list.move(two, to: 99)
        harness.equal(list.tabs.map(\.id), [four, three, one, two], "a drop past the end lands at the end")
        list.move(three, to: -5)
        harness.equal(list.tabs.map(\.id), [three, four, one, two], "and a drop before the start lands at the front")

        let before = list.tabs.map(\.id)
        list.move(TabID(rawValue: 99), to: 0)
        harness.equal(list.tabs.map(\.id), before, "moving a stranger moves nothing")

        // The pinned block survives a drag, in both directions.
        var mixed = TabList()
        mixed.add()
        let m1 = mixed.tabs[0].id
        mixed.add()
        let m2 = mixed.tabs[1].id
        mixed.add()
        let m3 = mixed.tabs[2].id
        mixed.setPinned(true, for: m2)
        harness.equal(mixed.tabs.map(\.id), [m2, m1, m3], "one pinned tab, at the front")

        mixed.move(m3, to: 0)
        harness.equal(mixed.tabs.map(\.id), [m2, m3, m1], "an unpinned tab cannot be dropped among the pinned ones")
        mixed.move(m2, to: 2)
        harness.equal(mixed.tabs.map(\.id), [m2, m3, m1], "and a pinned tab cannot leave the block")
    }

    /// The settings page is a tab like any other, with one difference: it holds no panes, so every pane
    /// operation has to refuse it rather than corrupt it — and "one per window" has to mean that asking
    /// twice gives you the tab you already have.
    private static func theSettingsTab(_ harness: Harness) {
        var list = TabList()
        let shell = list.add()
        let shellTab = list.tabs[0].id

        let settings = list.openSettings()
        harness.equal(list.count, 2, "settings opens a tab")
        harness.expect(list.activeTabID == settings, "and shows it")
        harness.expect(list.tabs[1].panes == nil, "which holds no panes")
        harness.expect(!list.tabs[1].isTerminal, "and is not a terminal")
        harness.equal(list.paneCount, 1, "so it is not counted as a session")

        // Asking again brings the one that is already there to the front.
        list.select(shellTab)
        harness.equal(list.openSettings(), settings, "asking twice gives the same tab")
        harness.equal(list.count, 2, "and opens nothing new")

        // Every pane operation refuses it, and refusing changes nothing.
        harness.expect(list.split(shell, in: settings, .right) == nil, "it cannot be split")
        harness.expect(!list.focus(shell, in: settings), "and holds no pane to focus")
        list.focusNextPane(in: settings)
        list.focusPreviousPane(in: settings)
        list.closePane(PaneID(rawValue: 99), in: settings)
        harness.equal(list.count, 2, "and closing a pane in it closes nothing")
        harness.expect(list.tabs[1].panes == nil, "it still has no panes")
        harness.equal(list.paneCount, 1, "and still counts as no session")

        // It renames, pins and closes like anything else, because none of those are pane operations.
        list.rename(settings, to: "Prefs")
        harness.equal(list.tabs[1].customTitle, "Prefs", "it can be renamed")
        list.setPinned(true, for: settings)
        harness.equal(list.tabs[0].id, settings, "and pinned to the front")
        list.close(settings)
        harness.equal(list.count, 1, "and closed")
        harness.expect(list.activeTabID == shellTab, "leaving the shell's tab showing")
        harness.equal(list.paneCount, 1, "with its session still counted")
    }

    // MARK: - Reading a tab

    /// The panes of a tab, as a plain list. `Tab.panes` is optional because the settings page has none,
    /// and every assertion below is about a *terminal* tab, so unwrapping once here keeps twenty lines
    /// from each re-testing the model's optionality instead of the behaviour they are there for.
    private static func panes(_ list: TabList, _ index: Int) -> [PaneID] {
        list.tabs[index].panes?.panes ?? []
    }

    /// Every pane in the window, across every tab.
    private static func allPanes(_ list: TabList) -> [PaneID] {
        list.tabs.compactMap(\.panes).flatMap(\.panes)
    }

    /// The focused pane of a tab. `PaneID(rawValue: 0)` when there is none, which no tab ever has — so a
    /// failure here reads as "expected pane2, got pane0" rather than as a type error.
    private static func focused(_ list: TabList, _ index: Int) -> PaneID {
        list.tabs[index].focusedPane ?? PaneID(rawValue: 0)
    }
}
