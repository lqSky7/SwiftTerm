import AppKit
import SwiftUI

/// Owns the terminal's window. A plain titled window rather than a full-size content view: a
/// terminal's first row is a line of output, and putting it under the titlebar would hide it.
///
/// It owns the window and nothing else. What is on screen is `AppCore`'s, and this class is also
/// where the menu bar's tab and pane commands land — every menu item targets `nil`, which walks the
/// responder chain, and a window controller is in that chain after its window.
@MainActor
final class TerminalWindowController: NSWindowController {
    /// Weak, deliberately: `AppCore` owns this controller, and the root view it hosts already holds
    /// `AppCore` strongly. A second strong edge back would be a cycle that only `terminate()` could
    /// break, and a cycle is a thing you find out about by reading a leak report years later.
    private weak var workspace: AppCore?

    /// The content size the shell should be started at. Read before a coordinator exists, so the
    /// shell's first prompt is drawn once, at the right size, rather than being redrawn on the
    /// first layout pass.
    var terminalContentSize: CGSize {
        window?.contentLayoutRect.size ?? Theme.Size.defaultWindow
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.Size.defaultWindow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // No titlebar band of its own. The content runs to the top of the window and the traffic
        // lights float over the sidebar, which is what the sidebar's header row is reserved for — and
        // it is why there is no strip above the terminal saying where you are: the sidebar already
        // does, and the path was the least useful thing a title could hold.
        //
        // The title is still *set*, because the Window menu and Mission Control read it; it is only
        // not drawn.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // **The window has to be transparent for any of this to work.** This is the line that was missing,
        // and it is why only some materials let the desktop through: an `NSVisualEffectView` with
        // behind-window blending makes AppKit render *its own region* translucent, so the materials that
        // contained one worked and the ones that did not were sampling an opaque window — which is what
        // "both glass ones feel opaque" was. SwiftUI's glass does not punch that hole for itself; it
        // refracts whatever is behind the window, and there was nothing behind the window but the window.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = "swiftTerm"
        window.minSize = Theme.Size.minimumWindow
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SwiftTermMainWindow")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code, never from a nib")
    }

    /// Which appearance the window is drawn in. `nil` hands the decision back to the system, which is what
    /// `system` means — picking `.aqua` or `.darkAqua` there would be choosing a side on the user's behalf.
    ///
    /// Setting this re-resolves every view's `effectiveAppearance`, and that is how the terminal's palette
    /// follows: the surface overrides `viewDidChangeEffectiveAppearance`, so nothing has to be told that the
    /// chrome and the sixteen colours have to agree.
    func setAppearance(_ mode: AppearanceMode) {
        window?.appearance = mode.nsAppearance
    }

    func attach(workspace: AppCore) {
        guard let window else { return }
        self.workspace = workspace
        window.contentView = NSHostingView(rootView: WorkspaceScreen(workspace: workspace))
    }

    /// Show or hide the window's own controls.
    ///
    /// With the sidebar hidden they have nothing to sit on and would be three buttons floating over the
    /// terminal's first line of output — so they go with the sidebar, and the sidebar's own button takes the
    /// corner they were in.
    func setTrafficLights(visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    /// The window is named after the tab that is showing, so a shell in a tab nobody is looking at
    /// cannot rename the window.
    func updateTitle(_ title: String) {
        window?.title = title
    }

    /// Focus goes to the pane the keyboard should be in, not to the window: a terminal that opens
    /// without the cursor in it is a terminal the user has to click before it works.
    ///
    /// Safe to call before the pane has been laid out — `makeFirstResponder` refuses a view that is
    /// not in the hierarchy, and the surface claims the keyboard for itself when it arrives.
    func focusActivePane() {
        guard let surface = workspace?.activeCoordinator?.surface else { return }
        window?.makeFirstResponder(surface)
    }

    // MARK: - Menu actions

    // Each of these is a one-line forward. The commands belong to `AppCore`, which owns the tabs;
    // these exist so the menu bar has something in the responder chain to reach.
    @objc func newTab(_ sender: Any?) { workspace?.newTab() }
    @objc func openSettings(_ sender: Any?) { workspace?.openSettings() }
    @objc func closePane(_ sender: Any?) { workspace?.closeActivePane() }
    @objc func toggleSidebar(_ sender: Any?) { workspace?.toggleSidebar() }
    @objc func selectNextTab(_ sender: Any?) { workspace?.selectNextTab() }
    @objc func selectPreviousTab(_ sender: Any?) { workspace?.selectPreviousTab() }
    @objc func splitRight(_ sender: Any?) { workspace?.splitActivePane(.right) }
    @objc func splitDown(_ sender: Any?) { workspace?.splitActivePane(.down) }
    @objc func focusNextPane(_ sender: Any?) { workspace?.focusNextPane() }
    @objc func focusPreviousPane(_ sender: Any?) { workspace?.focusPreviousPane() }

    /// One menu item says two things: a command named for what it will do is the difference between a
    /// menu that reads as a list of actions and one that reads as a list of nouns.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar(_:)) {
            let hidden = workspace?.layout.isSidebarCollapsed ?? false
            menuItem.title = hidden ? "Show Sidebar" : "Hide Sidebar"
        }
        return true
    }
}
