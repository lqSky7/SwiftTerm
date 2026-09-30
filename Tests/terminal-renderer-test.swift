import AppKit
import CoreText

@main
@MainActor
enum TerminalRendererTest {
    static func main() {
        let harness = Harness("terminal-renderer-test")
        let font = TerminalFont(pointSize: 14)
        let renderer = TerminalRenderer(palette: .builtin, font: font)
        for prefix in [String(repeating: "M", count: 65), "界", "👩🏽‍💻", "♥️", "🇮🇳"] {
            let grid = TerminalGrid(size: TerminalSize(columns: 80, rows: 2))
            let vt = VTParser(grid: grid)
            vt.feed("\u{1B}[?1049h" + prefix + "\u{1B}[38;2;255;0;0mX\u{1B}[?25l")
            let column = grid.screen[0].cells.firstIndex(where: { $0.text == "X" }) ?? -1
            harness.expect(column >= 0, "the marker is on the row")
            let bitmap = render(renderer, grid: grid, font: font)
            let baseline = TerminalGrid(size: TerminalSize(columns: 80, rows: 2))
            VTParser(grid: baseline).feed("\u{1B}[?1049h" + prefix + "\u{1B}[?25l")
            let baselineBitmap = render(renderer, grid: baseline, font: font)
            var redColumns: [Int] = []
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color != baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.redComponent > 0.4 && color.greenComponent < 0.1 && color.blueComponent < 0.1 {
                        redColumns.append(x)
                        break
                    }
                }
            }
            let start = Int(CGFloat(column) * font.cellWidth)
            harness.expect(!redColumns.isEmpty, "the marker renders after \(prefix)")
            harness.expect(redColumns.allSatisfy { $0 >= start && $0 <= start + Int(font.cellWidth) },
                           "marker pixels stay in column \(column) after \(prefix)")
        }
        let cursor = TerminalGrid(size: TerminalSize(columns: 80, rows: 2))
        cursor.setAlternateScreen(true)
        cursor.setCursorPosition(row: 1, column: 8)
        let visible = render(renderer, grid: cursor, font: font)
        let hidden = render(renderer, grid: cursor, font: font, showsCursor: false)
        let off = render(renderer, grid: cursor, font: font, blinkOn: false)
        harness.expect(visible.tiffRepresentation != hidden.tiffRepresentation, "fullscreen cursor respects focus")
        harness.equal(off.tiffRepresentation, hidden.tiffRepresentation, "fullscreen blinking cursor has an off phase")
        cursor.setCursorStyle(TerminalCursorStyle(shape: .block, blinks: false))
        let steady = render(renderer, grid: cursor, font: font, blinkOn: false)
        harness.equal(steady.tiffRepresentation, visible.tiffRepresentation, "steady cursor ignores the blink phase")
        cacheInvalidation(harness)
        fullscreenEdges(harness)
        harness.finish()
    }

    private static func fullscreenEdges(_ harness: Harness) {
        let font = TerminalFont(pointSize: 14)
        let renderer = TerminalRenderer(palette: .builtin, font: font)
        let size = CGSize(width: 80 * font.cellWidth + 3, height: 2 * font.cellHeight + 5)
        let normal = renderer.gridSize(fitting: size)
        let full = renderer.gridSize(fitting: size, isAlternateScreen: true)
        harness.equal(full.columns, 80, "fullscreen dimensions use the entire panel width")
        harness.expect(normal.columns < full.columns, "command blocks retain their content padding")
        harness.equal(full.rows, 2, "fractional viewport height does not hide part of a TUI row")
        let grid = TerminalGrid(size: TerminalSize(columns: full.columns, rows: full.rows))
        let vt = VTParser(grid: grid)
        vt.feed("\u{1B}[?1049h\u{1B}[48;2;255;0;0m\u{1B}[2J")
        vt.feed("\u{1B}[2;1H\u{1B}[48;2;0;0;255m" + String(repeating: " ", count: 80))
        let bitmap = render(renderer, grid: grid, font: font, showsCursor: false, size: size)
        func isColor(_ x: Int, _ y: Int, blue: Bool) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return blue ? color.blueComponent > 0.9 && color.redComponent < 0.1
                : color.redComponent > 0.9 && color.blueComponent < 0.1
        }
        let right = bitmap.pixelsWide - 1
        let bottom = bitmap.pixelsHigh - 1
        // Bitmap y runs down, unlike the CGContext used to paint the terminal.
        harness.expect(isColor(0, 1, blue: false), "first column starts at the left edge")
        harness.expect(isColor(right, 1, blue: false), "right fractional strip uses its top-row background")
        harness.expect(isColor(0, bottom, blue: true), "bottom strip uses its bottom-row background")
        harness.expect(isColor(right, bottom, blue: true), "bottom-right corner has no unpainted gap")
    }

    private static func cacheInvalidation(_ harness: Harness) {
        let font = TerminalFont(pointSize: 14)
        let renderer = TerminalRenderer(palette: .builtin, font: font)
        let grid = TerminalGrid(size: TerminalSize(columns: 80, rows: 2))
        let vt = VTParser(grid: grid)
        vt.feed("\u{1B}[?1049h")
        // More distinct glyph/color pairs than the cache holds exercises wholesale eviction.
        for batch in 0..<54 {
            vt.feed("\u{1B}[H")
            for column in 0..<80 {
                let color = batch * 80 + column
                vt.feed("\u{1B}[38;2;\(color / 256);\(color % 256);100mM")
            }
            let cached = render(renderer, grid: grid, font: font, showsCursor: false)
            let fresh = render(TerminalRenderer(palette: .builtin, font: font),
                               grid: grid, font: font, showsCursor: false)
            harness.equal(cached.tiffRepresentation, fresh.tiffRepresentation,
                          "cached/evicted RGB glyphs match fresh rendering in batch \(batch)")
        }
        vt.feed("\u{1B}[0m\u{1B}[2J\u{1B}[H" + "M界👩🏽‍💻é "
                + "\u{1B}[1mM\u{1B}[3mM\u{1B}[0;2mM\u{1B}[7mM\u{1B}[8mM\u{1B}[0;4mM")
        for palette in [TerminalPalette.builtin, .dracula, .solarizedDark, .builtin] {
            for size in [CGFloat(14), 18, 14] {
                let updatedFont = TerminalFont(pointSize: size)
                renderer.update(palette: palette, font: updatedFont)
                let cached = render(renderer, grid: grid, font: updatedFont, showsCursor: false)
                let fresh = render(TerminalRenderer(palette: palette, font: updatedFont),
                                   grid: grid, font: updatedFont, showsCursor: false)
                harness.equal(cached.tiffRepresentation, fresh.tiffRepresentation,
                              "font/palette swaps preserve styled and Unicode glyph pixels")
            }
        }
    }

    private static func render(
        _ renderer: TerminalRenderer, grid: TerminalGrid, font: TerminalFont,
        showsCursor: Bool = true, blinkOn: Bool = true, size: CGSize? = nil
    ) -> NSBitmapImageRep {
        let width = Int(size?.width ?? 80 * font.cellWidth)
        let height = Int(size?.height ?? 2 * font.cellHeight)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        renderer.drawAlternateScreen(
            in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height), grid: grid,
            showsCursor: showsCursor, blinkOn: blinkOn)
        return bitmap
    }
}
