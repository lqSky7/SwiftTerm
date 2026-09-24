import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One `AppCore` per open window. Plural now: the app used to be exactly one window, but `⌘N` and
    /// the Dock's "New Window" both need a place that can start another one — and that place has to
    /// own the list, or two windows could each think they were the only one and both try to be the
    /// one that restores last launch's tabs.
    private var cores: [AppCore] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenus.install()
        openWindow(persistsSession: true)
    }

    /// The last window closing already ran that window's `terminate()` — see `windowWillClose(on:)` —
    /// so there is nothing left running to keep the app alive for.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Reached when the app quits without every window having closed on its own first — `⌘Q` with more
    /// than one window open tears the process down directly rather than closing each window in turn.
    /// Whichever cores are still here have not had their shells told to hang up yet.
    func applicationWillTerminate(_ notification: Notification) {
        for core in cores { core.terminate() }
        cores.removeAll()
    }

    /// The Dock icon's own menu. Without this, right-clicking or long-pressing it offers nothing but
    /// what AppKit adds unasked — there was no way to start a second window without switching to the
    /// app first and reaching for `⌘N`.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newWindow = NSMenuItem(
            title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)
        return menu
    }

    /// `⌘N`, the File menu, and the Dock menu all land here — see the note in `AppMenus.fileMenu()` on
    /// why the menu item targets `nil` instead of this directly.
    @objc func newWindow(_ sender: Any?) {
        openWindow(persistsSession: false)
    }

    /// One more window, holding one shell — what every caller above means by "new window".
    private func openWindow(persistsSession: Bool) {
        let core = AppCore(persistsSession: persistsSession)
        core.onWindowClosed = { [weak self, weak core] in
            guard let self, let core else { return }
            cores.removeAll { $0 === core }
        }
        cores.append(core)
        core.start(isPrimary: persistsSession)
    }
}
