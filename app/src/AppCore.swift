import AppKit
import Observation

/// The composition root. Every long-lived object the app owns is created here and nowhere else —
/// a second place that builds a session or a window is how an app ends up with two of them.
///
/// It owns the window's tabs. Their *shape* — which are open, which is showing, how one's panes are
/// arranged — is `TabList`, which is pure and harnessed. What lives here is the part that cannot be
/// pure: one `TerminalCoordinator` per pane, because a coordinator owns a shell.
@MainActor
@Observable
final class AppCore {
    /// The tabs of the window, and which one is showing.
    private(set) var tabs = TabList()

    /// The shell behind every pane. The tree names panes; this is what turns a name into a session,
    /// and it is the whole reason the model holds identities rather than sessions.
    private(set) var coordinators: [PaneID: TerminalCoordinator] = [:]

    @ObservationIgnored private var windowController: TerminalWindowController?

    /// What the window is made of, and how opaque its two surfaces are. This is the half of the chrome that
    /// roams: it is a preference, and a person setting it again on a second machine would be annoyed.
    ///
    /// Stored here rather than in the views that draw them, because the pane area is *derived* from
    /// them: the layout and the size the shell is told have to come from one set of numbers, and a
    /// width a view kept to itself is exactly how those two drift apart.
    private(set) var chrome: ChromeSettings

    /// How wide the sidebar's column is and whether it is showing. The half of the chrome that does *not* roam:
    /// geometry is a fact about a screen, and a backend that synced it would fight the other machine's.
    ///
    /// Two properties rather than one because the document keeps them apart, and a view that had to know which
    /// area a value came from would be a view that knows how settings are stored.
    private(set) var layout: ChromeLayoutSettings

    /// Where the settings came from and where they go back to. Every command that changes one writes it: there
    /// are few enough that a debounce would be more machinery than the writes are worth, and `UserDefaults`
    /// coalesces its own. The two drags are the exception and say so where they are.
    @ObservationIgnored private let store = SettingsStore()

    init() {
        let document = store.load()
        chrome = document.synced.chrome
        layout = document.device.chrome
    }

    /// Write the settings back, keeping whatever else the document holds.
    ///
    /// Read-modify-write rather than replacing the document, so a second area of settings added later is not
    /// erased by whichever one happened to save last. Both halves are written from the one place, so neither can
    /// be the one that gets forgotten.
    ///
    /// The revision goes up by one on every write. It is what a sync backend compares to tell a stale write from
    /// a fresh one, and it has to be incremented from the first write rather than from the first *sync* — a
    /// revision that starts at zero when the backend arrives cannot order the writes that came before it.
    private func persist() {
        var document = store.load()
        document.synced.chrome = chrome
        document.device.chrome = layout
        document.revision += 1
        store.save(document)
    }

    /// The pane the window is showing, and the one the keyboard belongs to. `nil` when the settings page
    /// is showing, because a page is not a terminal and has no keyboard of its own to give.
    var activeCoordinator: TerminalCoordinator? {
        guard let pane = tabs.activeTab?.focusedPane ?? nil else { return nil }
        return coordinators[pane]
    }

    func coordinator(for pane: PaneID) -> TerminalCoordinator? { coordinators[pane] }

    /// What a tab is called in the sidebar.
    ///
    /// Three answers in order, and each earns its place. The user's name, if they gave one — that is the
    /// only thing `Tab` stores. Then the shell's, which is the working directory and is a good name once
    /// there is one. Then a numbered name, because a new tab whose shell has not drawn a prompt yet is
    /// otherwise nameless, and a list of nameless rows is not a list. The settings page has no shell to
    /// ask, so it is called what it is.
    func title(for tab: Tab) -> String {
        if let custom = tab.customTitle { return custom }
        guard let pane = tab.focusedPane else { return "Settings" }
        let derived = title(for: pane)
        return derived.isEmpty ? "Tab \(tab.id.rawValue)" : derived
    }

    func title(for pane: PaneID) -> String { coordinators[pane]?.title ?? "" }

    // MARK: - Lifecycle

    /// Built in `start()` rather than in an initialiser so the window can exist first and the shell
    /// can be started at the size the pane it will be drawn in already is.
    func start() {
        guard windowController == nil else { return }

        let windowController = TerminalWindowController()
        self.windowController = windowController
        openTab()
        // Before the window is shown, so the first pane is the active one when its surface arrives
        // in the window — that is the moment the surface claims the keyboard for itself.
        syncActivePane()
        windowController.attach(workspace: self)
        applyAppearance()

        windowController.showWindow(nil)
        windowController.focusActivePane()
        NSApp.activate()
    }

    /// Called on the way out. Every shell gets a hangup, so a job control shell's children do not
    /// outlive the window they were started from — and with more than one pane there is more than
    /// one shell to tell.
    func terminate() {
        for coordinator in coordinators.values { coordinator.shutdown() }
        coordinators.removeAll()
        tabs = TabList()
        windowController = nil
    }

    // MARK: - Tabs

    /// A new tab holding one shell, shown — which is what a new tab does.
    func newTab() {
        openTab()
        afterStructuralChange()
    }

    func selectTab(_ tab: TabID) {
        guard tabs.select(tab) else { return }
        afterStructuralChange()
    }

    func selectNextTab() {
        tabs.selectNext()
        afterStructuralChange()
    }

    func selectPreviousTab() {
        tabs.selectPrevious()
        afterStructuralChange()
    }

    /// Show the settings page, as a tab.
    ///
    /// `⌘,`, and the gear in the sidebar's header. A tab rather than a window: the settings are one more
    /// thing that is open, and a window of its own would be a second place that knows what is open.
    func openSettings() {
        tabs.openSettings()
        afterStructuralChange()
    }

    /// Close what is in front of the user. Closing a tab's last pane closes the tab, and closing the last
    /// tab closes the window — which `AppDelegate` makes a finished app.
    ///
    /// **`⌘W` closes *the thing on top*, and on the settings page that is the page.** This used to guard on
    /// `focusedPane` and do nothing when there was none, which meant the one shortcut everybody tries first did
    /// nothing on one of the two things you can have open — and a shortcut that silently does nothing is a
    /// shortcut people conclude is broken. The settings page is a tab with no shell in it, so closing it is
    /// closing the tab.
    func closeActivePane() {
        guard let tab = tabs.activeTab else { return }
        guard let pane = tab.focusedPane else {
            closeTab(tab.id)
            return
        }
        tabs.closePane(pane, in: tab.id)
        afterStructuralChange()
    }

    /// Close a tab and every shell in it — what the sidebar's menu does.
    func closeTab(_ tab: TabID) {
        tabs.close(tab)
        afterStructuralChange()
    }

    // MARK: - Panes

    func focusNextPane() {
        guard let tab = tabs.activeTab, tab.isTerminal else { return }
        tabs.focusNextPane(in: tab.id)
        afterStructuralChange()
    }

    func focusPreviousPane() {
        guard let tab = tabs.activeTab, tab.isTerminal else { return }
        tabs.focusPreviousPane(in: tab.id)
        afterStructuralChange()
    }

    /// Split the pane the keyboard is in, and start a shell in the new one.
    func splitActivePane(_ placement: SplitPlacement) {
        guard let tab = tabs.activeTab, let pane = tab.focusedPane, let windowController else {
            return
        }
        guard let newPane = tabs.split(pane, in: tab.id, placement) else { return }
        coordinators[newPane] = makeCoordinator(in: windowController)
        afterStructuralChange()
    }

    // MARK: - The sidebar

    /// The sidebar was dragged. Clamped by `ChromeLayoutSettings`, so the number the layout uses and the
    /// number the drag can reach are the same number.
    func setSidebarWidth(_ width: CGFloat) {
        layout.setSidebarWidth(width)
        persist()
    }

    func setSidebarMaterial(_ material: ChromeMaterial) {
        chrome.setSidebarMaterial(material)
        persist()
    }

    func setSidebarOpacity(_ opacity: Double) {
        chrome.setSidebarOpacity(opacity)
        persist()
    }

    func setTerminalMaterial(_ material: ChromeMaterial) {
        chrome.setTerminalMaterial(material)
        applyAppearance()
        persist()
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        chrome.appearanceMode = mode
        applyAppearance()
        persist()
    }

    func setFontSize(_ size: Double) {
        chrome.setFontSize(size)
        applyTypography()
        persist()
    }

    /// `⌘+` and `⌘−`. Stepped and clamped by the setting, and **saved** — a text size that resets when the window
    /// closes is a text size you have to set again every morning.
    func adjustFontSize(by delta: Double) { setFontSize(chrome.fontSize + delta) }

    /// How tall a line is, as a multiple of the text size. The other half of how the terminal reads.
    func setLineHeightRatio(_ ratio: Double) {
        chrome.setLineHeightRatio(ratio)
        applyTypography()
        persist()
    }

    /// Push the text size and the line height into every surface, like the appearance and the opacity.
    private func applyTypography() {
        for coordinator in coordinators.values {
            coordinator.setFontSize(chrome.fontSize)
            coordinator.setLineHeightRatio(chrome.lineHeightRatio)
        }
    }

    func setTerminalOpacity(_ opacity: Double) {
        chrome.setTerminalOpacity(opacity)
        applyAppearance()
        persist()
    }

    /// Put the window into the appearance that was asked for, and push what the terminals draw with into
    /// every surface.
    ///
    /// One function for both because they are one decision: the palette is chosen *by* the appearance, and
    /// doing them apart is how a light terminal ends up drawn in a dark window. The opacity rides along
    /// because it is the same push to the same objects.
    ///
    /// The renderer is the only thing that knows the palette, so it is the only thing that can paint the
    /// terminal's own background — and that fill is what the opacity control moves. It used to be a fill in
    /// `WorkspaceScreen` behind the surface, which is why the slider did nothing: the renderer's own fill
    /// covered it.
    private func applyAppearance() {
        guard let windowController else { return }
        windowController.setAppearance(chrome.appearanceMode)
        for coordinator in coordinators.values {
            coordinator.setAppearanceMode(chrome.appearanceMode)
            coordinator.setTerminalOpacity(chrome.terminalOpacity)
        }
    }

    /// A divider was dragged. `translation` is where the pointer is *now*, in points, measured from where
    /// the gesture began — which is cumulative, so what gets applied is the step since the last update.
    ///
    /// The alternative is for the view to keep the previous value, and a view that holds a number the model
    /// needs is the one thing this codebase does not do.
    func dragDivider(_ divider: PaneLayout.Divider, by translation: CGFloat) {
        guard let tab = tabs.activeTab, tab.isTerminal, divider.extent > 0 else { return }
        let step = translation - lastDividerTranslation
        lastDividerTranslation = translation
        tabs.resizePanes(
            between: divider.leading, and: divider.trailing, by: step / divider.extent, in: tab.id)
    }

    func beginDividerDrag() {
        lastDividerTranslation = 0
    }

    func endDividerDrag() {
        lastDividerTranslation = 0
    }

    /// Where the last divider update was, so each one applies the step rather than the whole distance
    /// again. Same reason as the sidebar's drag origin: a gesture reports where the pointer is, not how far
    /// it moved since you last asked.
    @ObservationIgnored private var lastDividerTranslation: CGFloat = 0

    /// The gear in the sidebar's header, and the only thing it does.
    func toggleChromeSettings() {
        openSettings()
    }

    /// Where a drag started, so it is measured from the width the sidebar had when the gesture began.
    /// Accumulating deltas instead drifts, and a drag that drifts is a drag that never lands where it
    /// was dropped.
    ///
    /// Gesture state, but kept here rather than in the view: the width is the model's, and a view with
    /// no state at all is also what keeps the whole-app typecheck working — `@State` is a macro the
    /// typecheck cannot expand, so a view that uses one drops out of the only automated gate the view
    /// layer has.
    @ObservationIgnored private var sidebarWidthAtDragStart: CGFloat?

    func beginSidebarDrag() {
        sidebarWidthAtDragStart = layout.sidebarWidth
    }

    /// During a drag the width is set *without* saving — a write per frame is a write per frame — and the save
    /// happens once, when the gesture ends.
    func dragSidebar(by translation: CGFloat) {
        layout.setSidebarWidth((sidebarWidthAtDragStart ?? layout.sidebarWidth) + translation)
    }

    func endSidebarDrag() {
        sidebarWidthAtDragStart = nil
        persist()
    }

    func toggleSidebar() {
        layout.isSidebarCollapsed.toggle()
        persist()
        // The window's own controls go with the sidebar. Nothing else would put them back, so this is the
        // one place that decides — rather than each of the three ways to collapse it remembering to.
        windowController?.setTrafficLights(visible: !layout.isSidebarCollapsed)
    }

    // MARK: - Renaming a tab

    /// The tab being renamed, and what has been typed so far.
    ///
    /// Editing state, but here for the same two reasons the drag origin is: the views hold nothing, and
    /// a draft kept in a view is thrown away by the next re-render — which, in a terminal, is a shell
    /// printing its title in the middle of your typing.
    private(set) var renaming: TabID?
    private(set) var renameDraft = ""

    func beginRename(_ tab: TabID) {
        guard let current = tabs.tabs.first(where: { $0.id == tab }) else { return }
        renameDraft = current.customTitle ?? title(for: current)
        renaming = tab
    }

    func updateRenameDraft(_ text: String) {
        renameDraft = text
    }

    /// Keep the name. A blank one clears the override, so the tab goes back to showing the title the
    /// session derives — which is why this stores the draft rather than special-casing "empty".
    func commitRename() {
        guard let tab = renaming else { return }
        tabs.rename(tab, to: renameDraft)
        endRename()
    }

    func cancelRename() {
        endRename()
    }

    private func endRename() {
        renaming = nil
        renameDraft = ""
        focusActivePaneSoon()
    }

    /// A drag in the sidebar's list.
    ///
    /// `List` reports the dragged rows as an `IndexSet` and the destination measured against the list
    /// *before* the move; `TabList.move` takes a destination measured *after* it. One of the two has to
    /// be converted, and getting it wrong is the off-by-one that makes a tab dragged downwards land one
    /// slot short every time — which reads as a rendering glitch rather than as arithmetic.
    func moveTabs(from source: IndexSet, to destination: Int) {
        guard let from = source.first, tabs.tabs.indices.contains(from) else { return }
        tabs.move(tabs.tabs[from].id, to: destination > from ? destination - 1 : destination)
    }

    /// What has been typed into the settings search field.
    ///
    /// Here for the usual reason, and it is the same reason the rename draft is here: a field's text kept in
    /// the view is thrown away by the next re-render, and in this app the next re-render is a shell printing
    /// its title.
    private(set) var settingsSearch = ""

    func setSettingsSearch(_ text: String) {
        settingsSearch = text
    }

    /// The tab the pointer is over, so its row can offer a cross to close it.
    ///
    /// Here rather than in the view for the usual reason — a view holding it would be a second copy of
    /// something the model can answer — and because the enter and the leave of two adjacent rows can arrive
    /// in either order. Clearing only the row that was hovered makes both orders correct.
    private(set) var hoveredTab: TabID?

    func setTabHovered(_ tab: TabID, _ isHovered: Bool) {
        if isHovered {
            hoveredTab = tab
        } else if hoveredTab == tab {
            hoveredTab = nil
        }
    }

    func rename(_ tab: TabID, to title: String?) {
        tabs.rename(tab, to: title)
    }

    func setPinned(_ pinned: Bool, for tab: TabID) {
        tabs.setPinned(pinned, for: tab)
    }

    /// Put the keyboard back in the terminal. Called when a field in the chrome gives it up — a rename
    /// that has just finished, for instance — because the surface only claims the keyboard for itself
    /// when it *arrives* in a window, and it never left.
    func focusTerminal() {
        focusActivePaneSoon()
    }

    // MARK: - The one place a shell is built

    private func openTab() {
        guard let windowController else { return }
        let pane = tabs.add()
        coordinators[pane] = makeCoordinator(in: windowController)
    }

    private func makeCoordinator(in windowController: TerminalWindowController)
        -> TerminalCoordinator
    {
        let coordinator = TerminalCoordinator(
            contentSize: paneContentSize(for: windowController.terminalContentSize))
        // Before it is shown, so a new pane never draws a frame at a different opacity or in a different
        // palette than the one beside it.
        coordinator.setAppearanceMode(chrome.appearanceMode)
        coordinator.setTerminalOpacity(chrome.terminalOpacity)
        coordinator.setFontSize(chrome.fontSize)
        coordinator.setLineHeightRatio(chrome.lineHeightRatio)
        // `⌘+` and `⌘−` go up to the app, not into the surface: the size is a setting, and a coordinator that
        // resized only its own surface would be a second answer the settings page disagrees with.
        coordinator.onAdjustFontSize = { [weak self] delta in self?.adjustFontSize(by: delta) }
        coordinator.onResetFontSize = { [weak self] in
            self?.setFontSize(Double(Theme.Typography.terminalPointSize))
        }
        // The window is named after the tab that is showing, not after whichever shell spoke last.
        coordinator.onTitleChange = { [weak self] _ in self?.syncActivePane() }
        return coordinator
    }

    /// One pane's area, before the window has laid anything out.
    ///
    /// It is the content panel's frame, which is `ChromeLayoutSettings`' arithmetic rather than a second copy
    /// of it — the same function the view lays out with, so the panel's size and the size the shell is
    /// told cannot disagree. The first layout pass is what makes it exact; this only has to be close
    /// enough that the shell draws its prompt once instead of redrawing it.
    private func paneContentSize(for contentSize: CGSize) -> CGSize {
        layout.contentPanelFrame(in: contentSize).size
    }

    // MARK: - Keeping the window in step

    /// Everything that has to happen after the tabs or the panes change, in one place: shells for
    /// panes that no longer exist are stopped, the active pane and the window's title are brought up
    /// to date, the window closes when there is nothing left to show, and the keyboard follows.
    private func afterStructuralChange() {
        reapOrphanedCoordinators()
        syncActivePane()
        closeIfEmpty()
        focusActivePaneSoon()
    }

    /// Shells whose pane is no longer in any tab.
    ///
    /// Closing a pane or a tab has to take its shell with it, or a window that has had a few tabs
    /// opened and closed is a window with a handful of shells still running and nothing on screen to
    /// say so.
    private func reapOrphanedCoordinators() {
        let live = Set(tabs.tabs.compactMap(\.panes).flatMap { $0.panes })
        let orphans = coordinators.filter { !live.contains($0.key) }
        for (pane, coordinator) in orphans {
            coordinator.shutdown()
            coordinators.removeValue(forKey: pane)
        }
    }

    /// Exactly one pane is active across the whole window. Written here rather than read by the
    /// views, so a pane cannot decide for itself that it should have the keyboard.
    private func syncActivePane() {
        let active = tabs.activeTab?.focusedPane ?? nil
        for (pane, coordinator) in coordinators {
            coordinator.isActive = (pane == active)
        }
        windowController?.updateTitle(windowTitle)
    }

    /// The window's own title, for the Window menu and Mission Control.
    ///
    /// Never drawn — the window has no titlebar band — so this is only ever read by the system, and the
    /// app's name is the right answer until the shell says where it is.
    private var windowTitle: String {
        guard let title = activeCoordinator?.title, !title.isEmpty else { return "swiftTerm" }
        return title
    }

    /// A window with no tabs has nothing to show, so it closes.
    private func closeIfEmpty() {
        guard tabs.isEmpty else { return }
        windowController?.close()
    }

    /// Focus the pane the structure just moved to.
    ///
    /// A turn later, because the surface a new pane is about to show does not exist until SwiftUI
    /// has laid it out. It is called from structural changes only — never from anything that fires
    /// while a command runs, which is the difference between this and the defect `journal.md` records
    /// as "focus that moved under the user's hands".
    private func focusActivePaneSoon() {
        Task { @MainActor [weak self] in self?.windowController?.focusActivePane() }
    }
}
