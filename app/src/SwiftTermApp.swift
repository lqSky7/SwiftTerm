import AppKit

/// The entry point.
///
/// `NSApplication` is driven directly rather than through SwiftUI's `App`, because the app owns a
/// window it wants to size before the shell starts and a menu whose items walk the responder chain
/// to the terminal view. Both are AppKit's to do and neither survives being wrapped.
@main
enum SwiftTermApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // `.regular` is what gives the app a Dock icon and a menu bar. A terminal is a normal app.
        application.setActivationPolicy(.regular)
        // The delegate is held weakly by AppKit, so it has to outlive `run()` from here.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
