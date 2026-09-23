import AppKit

/// Names to AppKit, for the one setting whose meaning AppKit owns.
///
/// `ChromeSettings` says *which* appearance; this says what that means. It is the same split
/// `SidebarBackground` makes for `ChromeMaterial`, and for the same reason: the model file has to stay
/// compilable by a harness, and `NSAppearance` is not something a harness can be handed.
extension AppearanceMode {
    /// What to set on the window. `nil` hands the decision back to the system, which is exactly what
    /// `system` means — setting `.aqua` or `.darkAqua` there would be picking a side on the user's behalf.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The palette the terminal draws with, resolved against the window it is drawn in.
    ///
    /// Resolved against the *window* rather than against `NSApp`: `system` has to mean "what this window is
    /// actually drawn in", and a window whose appearance was set explicitly is exactly the case where those
    /// two answers differ.
    func palette(for appearance: NSAppearance) -> TerminalPalette {
        let light = isLight ?? (appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        return light ? .light : .builtin
    }
}
