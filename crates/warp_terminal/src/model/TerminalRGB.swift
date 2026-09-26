import Foundation

/// A colour the terminal can actually paint. Kept free of `NSColor` so the emulator stays
/// testable without a window server; the UI layer converts at the last moment.
struct TerminalRGB: Hashable, Sendable, Codable {
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

    var hexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    init?(hexString: String) {
        var str = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt32(str, radix: 16) else { return nil }
        self.init(hex: value)
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let str = try? container.decode(String.self), let parsed = TerminalRGB(hexString: str) {
                self = parsed
                return
            }
            if let hexNum = try? container.decode(UInt32.self) {
                self.init(hex: hexNum)
                return
            }
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let red = try keyed.decode(UInt8.self, forKey: .red)
        let green = try keyed.decode(UInt8.self, forKey: .green)
        let blue = try keyed.decode(UInt8.self, forKey: .blue)
        self.init(red: red, green: green, blue: blue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue
    }
}
