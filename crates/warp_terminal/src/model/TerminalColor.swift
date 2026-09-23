import Foundation

/// A colour as the wire protocol names it. `indexed` stays indexed until paint time because
/// the palette can change under it — resolving early would freeze the theme.
enum TerminalColor: Hashable, Sendable {
    case defaultForeground
    case defaultBackground
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    /// Indices 0–15 are the palette's own ANSI slots, 16–231 the 6×6×6 cube, 232–255 the
    /// 24-step grey ramp. The cube's levels are the xterm ones, not an even division of 255.
    func resolvedRGB(using palette: TerminalPalette = .builtin) -> TerminalRGB {
        switch self {
        case .defaultForeground: return palette.foreground
        case .defaultBackground: return palette.background
        case .rgb(let red, let green, let blue): return TerminalRGB(red: red, green: green, blue: blue)
        case .indexed(let index):
            if index < 16 { return palette.ansi[Int(index)] }
            if index < 232 {
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                let offset = Int(index) - 16
                return TerminalRGB(
                    red: levels[offset / 36],
                    green: levels[(offset / 6) % 6],
                    blue: levels[offset % 6])
            }
            let level = UInt8(8 + (Int(index) - 232) * 10)
            return TerminalRGB(red: level, green: level, blue: level)
        }
    }
}
