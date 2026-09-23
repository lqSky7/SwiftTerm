import Foundation

/// How one cell is painted. Colours stay symbolic so a palette swap repaints history.
struct CellAttributes: Hashable, Sendable {
    /// Underline variants are separate bits because a terminal draws them differently, not
    /// because SGR treats them independently — `SGR 21` and `SGR 4:2` both mean double.
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt16

        static let bold = Flags(rawValue: 1 << 0)
        static let faint = Flags(rawValue: 1 << 1)
        static let italic = Flags(rawValue: 1 << 2)
        static let underline = Flags(rawValue: 1 << 3)
        static let blink = Flags(rawValue: 1 << 4)
        static let reverse = Flags(rawValue: 1 << 5)
        static let hidden = Flags(rawValue: 1 << 6)
        static let strikethrough = Flags(rawValue: 1 << 7)
        static let doubleUnderline = Flags(rawValue: 1 << 8)
        static let curlyUnderline = Flags(rawValue: 1 << 9)
        static let dottedUnderline = Flags(rawValue: 1 << 10)
        static let dashedUnderline = Flags(rawValue: 1 << 11)

        static let anyUnderline: Flags = [
            .underline, .doubleUnderline, .curlyUnderline, .dottedUnderline, .dashedUnderline,
        ]
    }

    var flags: Flags = []
    var foreground: TerminalColor = .defaultForeground
    var background: TerminalColor = .defaultBackground
    var underlineColor: TerminalColor?

    var hasUnderline: Bool { !flags.isDisjoint(with: .anyUnderline) }

    /// What the reverse bit actually paints. Resolving here rather than in the renderer keeps
    /// the swap in one place and means a renderer never has to know the bit exists.
    func resolvedColors(using palette: TerminalPalette) -> (foreground: TerminalRGB, background: TerminalRGB) {
        let foreground = self.foreground.resolvedRGB(using: palette)
        let background = self.background.resolvedRGB(using: palette)
        guard flags.contains(.reverse) else { return (foreground, background) }
        return (background, foreground)
    }
}
