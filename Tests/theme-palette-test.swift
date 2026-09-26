import Foundation

@main
enum ThemePaletteTest {
    static func main() {
        let harness = Harness("theme-palette-test")

        testPresets(harness)
        testPaletteCoderRoundTrip(harness)
        testNestedSchemaDecoding(harness)

        harness.finish()
    }

    private static func testPresets(_ harness: Harness) {
        harness.equal(TerminalPalette.presets.count, 8, "Expected 8 built-in presets")

        for (name, palette) in TerminalPalette.presets {
            harness.equal(palette.ansi.count, 16, "Preset \(name) must have 16 ANSI colors")
            harness.expect(palette.foreground != palette.background, "Preset \(name) must have contrasting fg and bg")
        }

        let dracula = TerminalPalette.preset(named: "Dracula")
        harness.expect(dracula != nil, "Should find Dracula preset")
        harness.equal(dracula?.background, TerminalRGB(hex: 0x282A36), "Dracula background matches")

        let caseInsensitive = TerminalPalette.preset(named: "solarized dark")
        harness.expect(caseInsensitive != nil, "Preset lookup should be case-insensitive")
    }

    private static func testPaletteCoderRoundTrip(_ harness: Harness) {
        let original = TerminalPalette.dracula
        guard let encodedData = try? TerminalPaletteCoder.encode(original, name: "Dracula Test") else {
            harness.expect(false, "Failed to encode Dracula Test palette")
            return
        }
        let decoded = TerminalPaletteCoder.decode(from: encodedData)

        harness.expect(decoded != nil, "Decoded palette should not be nil")
        harness.equal(decoded?.foreground, original.foreground, "Foreground matches")
        harness.equal(decoded?.background, original.background, "Background matches")
        harness.equal(decoded?.cursor, original.cursor, "Cursor matches")
        harness.equal(decoded?.ansi, original.ansi, "16 ANSI slots match")
    }

    private static func testNestedSchemaDecoding(_ harness: Harness) {
        let json = """
        {
            "foreground": "#ABB2BF",
            "background": "#282C34",
            "cursor": "#528BFF",
            "normal": {
                "black": "#1E2127", "red": "#E06C75", "green": "#98C379", "yellow": "#D19A66",
                "blue": "#61AFEF", "magenta": "#C678DD", "cyan": "#56B6C2", "white": "#ABB2BF"
            },
            "bright": {
                "black": "#5C6370", "red": "#E06C75", "green": "#98C379", "yellow": "#E5C07B",
                "blue": "#61AFEF", "magenta": "#C678DD", "cyan": "#56B6C2", "white": "#FFFFFF"
            }
        }
        """
        guard let data = json.data(using: .utf8) else {
            harness.expect(false, "Failed to create UTF-8 data")
            return
        }
        let decoded = TerminalPaletteCoder.decode(from: data)
        harness.expect(decoded != nil, "Should decode nested normal/bright JSON")
        harness.equal(decoded?.foreground, TerminalRGB(hex: 0xABB2BF), "Foreground matches")
        harness.equal(decoded?.background, TerminalRGB(hex: 0x282C34), "Background matches")
        harness.equal(decoded?.ansi.count, 16, "ANSI count is 16")
        harness.equal(decoded?.ansi[0], TerminalRGB(hex: 0x1E2127), "Black slot matches")
        harness.equal(decoded?.ansi[15], TerminalRGB(hex: 0xFFFFFF), "Bright white slot matches")
    }
}
