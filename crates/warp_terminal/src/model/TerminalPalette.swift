import Foundation

/// A colour scheme: the sixteen ANSI slots plus the surfaces a terminal paints around them.
/// Supports preset switching, in-memory customization, and JSON import/export.
struct TerminalPalette: Hashable, Sendable, Codable {
    /// Slots 0–7 normal, 8–15 bright. Ordered so `indexed(n)` can index straight in.
    var ansi: [TerminalRGB]
    var foreground: TerminalRGB
    var background: TerminalRGB
    var cursor: TerminalRGB

    init(
        ansi: [TerminalRGB],
        foreground: TerminalRGB,
        background: TerminalRGB,
        cursor: TerminalRGB
    ) {
        if ansi.count == 16 {
            self.ansi = ansi
        } else {
            var padded = ansi
            while padded.count < 16 {
                padded.append(padded.last ?? TerminalRGB(hex: 0x000000))
            }
            self.ansi = Array(padded.prefix(16))
        }
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    // MARK: - Built-in Presets

    static let swiftTermMono = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x161616),
            TerminalRGB(hex: 0xEE5555),
            TerminalRGB(hex: 0x9E9E9E),
            TerminalRGB(hex: 0xB0B0B0),
            TerminalRGB(hex: 0xC4C4C4),
            TerminalRGB(hex: 0xD0D0D0),
            TerminalRGB(hex: 0xDBDBDB),
            TerminalRGB(hex: 0xEAEAEA),
            TerminalRGB(hex: 0x505050),
            TerminalRGB(hex: 0xFF6E6E),
            TerminalRGB(hex: 0xAAAAAA),
            TerminalRGB(hex: 0xBEBEBE),
            TerminalRGB(hex: 0xD2D2D2),
            TerminalRGB(hex: 0xDEDEDE),
            TerminalRGB(hex: 0xE6E6E6),
            TerminalRGB(hex: 0xFFFFFF),
        ],
        foreground: TerminalRGB(hex: 0xE0E0E0),
        background: TerminalRGB(hex: 0x121212),
        cursor: TerminalRGB(hex: 0xFFFFFF))

    static let builtin = swiftTermMono
    static let light = swiftTermMono

    static let dracula = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x21222C), TerminalRGB(hex: 0xFF5555),
            TerminalRGB(hex: 0x50FA7B), TerminalRGB(hex: 0xF1FA8C),
            TerminalRGB(hex: 0xBD93F9), TerminalRGB(hex: 0xFF79C6),
            TerminalRGB(hex: 0x8BE9FD), TerminalRGB(hex: 0xF8F8F2),
            TerminalRGB(hex: 0x6272A4), TerminalRGB(hex: 0xFF6E6E),
            TerminalRGB(hex: 0x69FF94), TerminalRGB(hex: 0xFFFFA5),
            TerminalRGB(hex: 0xD6ACFF), TerminalRGB(hex: 0xFF92DF),
            TerminalRGB(hex: 0xA4FFFF), TerminalRGB(hex: 0xFFFFFF),
        ],
        foreground: TerminalRGB(hex: 0xF8F8F2),
        background: TerminalRGB(hex: 0x282A36),
        cursor: TerminalRGB(hex: 0xF8F8F2))

    static let solarizedDark = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x073642), TerminalRGB(hex: 0xDC322F),
            TerminalRGB(hex: 0x859900), TerminalRGB(hex: 0xB58900),
            TerminalRGB(hex: 0x268BD2), TerminalRGB(hex: 0xD33682),
            TerminalRGB(hex: 0x2AA198), TerminalRGB(hex: 0xEEE8D5),
            TerminalRGB(hex: 0x002B36), TerminalRGB(hex: 0xCB4B16),
            TerminalRGB(hex: 0x586E75), TerminalRGB(hex: 0x657B83),
            TerminalRGB(hex: 0x839496), TerminalRGB(hex: 0x6C71C4),
            TerminalRGB(hex: 0x93A1A1), TerminalRGB(hex: 0xFDF6E3),
        ],
        foreground: TerminalRGB(hex: 0x839496),
        background: TerminalRGB(hex: 0x002B36),
        cursor: TerminalRGB(hex: 0x839496))

    static let solarizedLight = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0xEEE8D5), TerminalRGB(hex: 0xDC322F),
            TerminalRGB(hex: 0x859900), TerminalRGB(hex: 0xB58900),
            TerminalRGB(hex: 0x268BD2), TerminalRGB(hex: 0xD33682),
            TerminalRGB(hex: 0x2AA198), TerminalRGB(hex: 0x073642),
            TerminalRGB(hex: 0xFDF6E3), TerminalRGB(hex: 0xCB4B16),
            TerminalRGB(hex: 0x93A1A1), TerminalRGB(hex: 0x839496),
            TerminalRGB(hex: 0x657B83), TerminalRGB(hex: 0x6C71C4),
            TerminalRGB(hex: 0x586E75), TerminalRGB(hex: 0x002B36),
        ],
        foreground: TerminalRGB(hex: 0x657B83),
        background: TerminalRGB(hex: 0xFDF6E3),
        cursor: TerminalRGB(hex: 0x657B83))

    static let oneDark = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x1E2127), TerminalRGB(hex: 0xE06C75),
            TerminalRGB(hex: 0x98C379), TerminalRGB(hex: 0xD19A66),
            TerminalRGB(hex: 0x61AFEF), TerminalRGB(hex: 0xC678DD),
            TerminalRGB(hex: 0x56B6C2), TerminalRGB(hex: 0xABB2BF),
            TerminalRGB(hex: 0x5C6370), TerminalRGB(hex: 0xE06C75),
            TerminalRGB(hex: 0x98C379), TerminalRGB(hex: 0xE5C07B),
            TerminalRGB(hex: 0x61AFEF), TerminalRGB(hex: 0xC678DD),
            TerminalRGB(hex: 0x56B6C2), TerminalRGB(hex: 0xFFFFFF),
        ],
        foreground: TerminalRGB(hex: 0xABB2BF),
        background: TerminalRGB(hex: 0x282C34),
        cursor: TerminalRGB(hex: 0x528BFF))

    static let monokai = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x272822), TerminalRGB(hex: 0xF92672),
            TerminalRGB(hex: 0xA6E22E), TerminalRGB(hex: 0xF4BF75),
            TerminalRGB(hex: 0x66D9EF), TerminalRGB(hex: 0xAE81FF),
            TerminalRGB(hex: 0xA1EFE4), TerminalRGB(hex: 0xF8F8F2),
            TerminalRGB(hex: 0x75715E), TerminalRGB(hex: 0xF92672),
            TerminalRGB(hex: 0xA6E22E), TerminalRGB(hex: 0xF4BF75),
            TerminalRGB(hex: 0x66D9EF), TerminalRGB(hex: 0xAE81FF),
            TerminalRGB(hex: 0xA1EFE4), TerminalRGB(hex: 0xF9F8F5),
        ],
        foreground: TerminalRGB(hex: 0xF8F8F2),
        background: TerminalRGB(hex: 0x272822),
        cursor: TerminalRGB(hex: 0xF8F8F0))

    static let gruvboxDark = TerminalPalette(
        ansi: [
            TerminalRGB(hex: 0x282828), TerminalRGB(hex: 0xCC241D),
            TerminalRGB(hex: 0x98971A), TerminalRGB(hex: 0xD79921),
            TerminalRGB(hex: 0x458588), TerminalRGB(hex: 0xB16286),
            TerminalRGB(hex: 0x689D6A), TerminalRGB(hex: 0xA89984),
            TerminalRGB(hex: 0x928374), TerminalRGB(hex: 0xFB4934),
            TerminalRGB(hex: 0xB8BB26), TerminalRGB(hex: 0xFABD2F),
            TerminalRGB(hex: 0x83A598), TerminalRGB(hex: 0xD3869B),
            TerminalRGB(hex: 0x8EC07C), TerminalRGB(hex: 0xEBDBB2),
        ],
        foreground: TerminalRGB(hex: 0xEBDBB2),
        background: TerminalRGB(hex: 0x282828),
        cursor: TerminalRGB(hex: 0xEBDBB2))

    /// The list of standard presets presented in the theme selector.
    static let presets: [(name: String, palette: TerminalPalette)] = [
        ("SwiftTerm Mono", swiftTermMono),
        ("Dracula", dracula),
        ("Solarized Dark", solarizedDark),
        ("Solarized Light", solarizedLight),
        ("One Dark", oneDark),
        ("Monokai", monokai),
        ("Gruvbox Dark", gruvboxDark),
    ]

    static func preset(named name: String) -> TerminalPalette? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.palette
            ?? (name.caseInsensitiveCompare("Warp Dark") == .orderedSame ? swiftTermMono : nil)
            ?? (name.caseInsensitiveCompare("Warp Light") == .orderedSame ? swiftTermMono : nil)
    }
}

/// Encoder/decoder for portable 16-color ANSI palettes.
enum TerminalPaletteCoder {
    /// Formats a palette as a clean JSON document.
    static func encode(_ palette: TerminalPalette, name: String = "Custom") throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let doc = PaletteExportDocument(
            name: name,
            foreground: palette.foreground.hexString,
            background: palette.background.hexString,
            cursor: palette.cursor.hexString,
            ansi: palette.ansi.map(\.hexString))
        return try encoder.encode(doc)
    }

    /// Decodes a palette from standard JSON formats (flat array or keyed normal/bright).
    static func decode(from data: Data) -> TerminalPalette? {
        let decoder = JSONDecoder()
        // Try flat export doc
        if let doc = try? decoder.decode(PaletteExportDocument.self, from: data) {
            let ansi = doc.ansi.compactMap(TerminalRGB.init(hexString:))
            guard let fg = TerminalRGB(hexString: doc.foreground),
                let bg = TerminalRGB(hexString: doc.background),
                let cur = TerminalRGB(hexString: doc.cursor)
            else { return nil }
            return TerminalPalette(ansi: ansi, foreground: fg, background: bg, cursor: cur)
        }
        // Try direct Codable TerminalPalette
        if let palette = try? decoder.decode(TerminalPalette.self, from: data) {
            return palette
        }
        // Try nested normal/bright schema (Warp/iTerm style)
        if let nested = try? decoder.decode(NestedPaletteDocument.self, from: data) {
            let ansi = nested.orderedAnsi.compactMap(TerminalRGB.init(hexString:))
            guard let fg = TerminalRGB(hexString: nested.foreground),
                let bg = TerminalRGB(hexString: nested.background),
                let cur = TerminalRGB(hexString: nested.cursor ?? nested.foreground)
            else { return nil }
            return TerminalPalette(ansi: ansi, foreground: fg, background: bg, cursor: cur)
        }
        return nil
    }

    private struct PaletteExportDocument: Codable {
        var name: String
        var foreground: String
        var background: String
        var cursor: String
        var ansi: [String]
    }

    private struct NestedPaletteDocument: Codable {
        var foreground: String
        var background: String
        var cursor: String?
        var normal: AnsiGroup
        var bright: AnsiGroup

        var orderedAnsi: [String] {
            [
                normal.black, normal.red, normal.green, normal.yellow,
                normal.blue, normal.magenta, normal.cyan, normal.white,
                bright.black, bright.red, bright.green, bright.yellow,
                bright.blue, bright.magenta, bright.cyan, bright.white,
            ]
        }
    }

    private struct AnsiGroup: Codable {
        var black: String
        var red: String
        var green: String
        var yellow: String
        var blue: String
        var magenta: String
        var cyan: String
        var white: String
    }
}
