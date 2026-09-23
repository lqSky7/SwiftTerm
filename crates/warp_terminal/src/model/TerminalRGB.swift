import Foundation

/// A colour the terminal can actually paint. Kept free of `NSColor` so the emulator stays
/// testable without a window server; the UI layer converts at the last moment.
struct TerminalRGB: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`, the form every theme file and ANSI table is written in.
    init(hex: UInt32) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF))
    }
}
