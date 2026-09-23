import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = AppCore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenus.install()
        core.start()
    }

    /// One window is the whole app, so a closed window is a finished app. Leaving it running with
    /// nothing on screen would only make the Dock icon look broken.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.terminate()
    }
}
