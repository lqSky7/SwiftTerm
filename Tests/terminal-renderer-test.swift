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
            let start = Int(Theme.Size.terminalContentInset + CGFloat(column) * font.cellWidth)
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
        harness.finish()
    }

    private static func render(
        _ renderer: TerminalRenderer, grid: TerminalGrid, font: TerminalFont,
        showsCursor: Bool = true, blinkOn: Bool = true
    ) -> NSBitmapImageRep {
        let width = Int(80 * font.cellWidth + Theme.Size.terminalContentInset * 2)
        let height = Int(2 * font.cellHeight)
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
