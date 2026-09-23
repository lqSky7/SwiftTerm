import Foundation

/// A colour scheme: the sixteen ANSI slots plus the surfaces a terminal paints around them.
/// A value rather than a namespace because Phase 5 lets the user edit one and swap it live.
struct TerminalPalette: Hashable, Sendable {
    /// Slots 0–7 normal, 8–15 bright. Ordered so `indexed(n)` can index straight in.
    var ansi: [TerminalRGB]
    var foreground: TerminalRGB
    var background: TerminalRGB
    var cursor: TerminalRGB

    /// Tomorrow Night, which is dark, low-glare, and has a distinct bright ramp — the three
    /// things that make a terminal usable before the theme engine exists.
    static let builtin = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x1D1F21), TerminalRGB(hex: 0xCC6666),
            TerminalRGB(hex: 0xB5BD68), TerminalRGB(hex: 0xF0C674),
            TerminalRGB(hex: 0x81A2BE), TerminalRGB(hex: 0xB294BB),
            TerminalRGB(hex: 0x8ABEB7), TerminalRGB(hex: 0xC5C8C6),
            TerminalRGB(hex: 0x666666), TerminalRGB(hex: 0xD54E53),
            TerminalRGB(hex: 0xB9CA4A), TerminalRGB(hex: 0xE6C547),
            TerminalRGB(hex: 0x7AA6DA), TerminalRGB(hex: 0xC397D8),
            TerminalRGB(hex: 0x70C0BA), TerminalRGB(hex: 0xEAEAEA),
        ],
        foreground: TerminalRGB(hex: 0xC5C8C6),
        background: TerminalRGB(hex: 0x1D1F21),
        cursor: TerminalRGB(hex: 0xC5C8C6))

    /// Tomorrow, the light counterpart of `builtin` — same author, same sixteen hues, inverted surfaces.
    ///
    /// A *pair* rather than one palette and a filter over it: the light ANSI slots are not the dark ones
    /// lightened, they are chosen to hold their contrast against white, and a program that prints in slot 1
    /// has to be readable in both. Which one is drawn is `AppearanceMode`'s answer, and this file does not
    /// know that setting exists.
    static let light = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x000000), TerminalRGB(hex: 0xC82829),
            TerminalRGB(hex: 0x718C00), TerminalRGB(hex: 0xEAB700),
            TerminalRGB(hex: 0x4271AE), TerminalRGB(hex: 0x8959A8),
            TerminalRGB(hex: 0x3E999F), TerminalRGB(hex: 0xD6D6D6),
            TerminalRGB(hex: 0x969896), TerminalRGB(hex: 0xC82829),
            TerminalRGB(hex: 0x718C00), TerminalRGB(hex: 0xEAB700),
            TerminalRGB(hex: 0x4271AE), TerminalRGB(hex: 0x8959A8),
            TerminalRGB(hex: 0x3E999F), TerminalRGB(hex: 0xFFFFFF),
        ],
        foreground: TerminalRGB(hex: 0x4D4D4C),
        background: TerminalRGB(hex: 0xFFFFFF),
        cursor: TerminalRGB(hex: 0x4D4D4C))
}
