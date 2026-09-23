import AppKit
import CoreText

/// The monospace metrics the whole terminal is laid out on.
///
/// Measured once and snapped to whole pixels: a cell box that lands between pixels makes every
/// glyph in the window soft, and a cell width that is not an integer multiple of the advance makes
/// the columns drift apart by the right-hand edge of the screen.
struct TerminalFont {
    let base: NSFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Where the baseline sits below the top of the cell. Text is centred in the cell's leading.
    let baselineFromTop: CGFloat

    private let bold: NSFont
    private let italic: NSFont
    private let boldItalic: NSFont

    init(
        pointSize: CGFloat, lineHeightRatio: CGFloat = Theme.Typography.lineHeightRatio,
        scale: CGFloat = 2
    ) {
        let base = Self.resolve(pointSize: pointSize)
        let manager = NSFontManager.shared
        self.base = base
        self.bold = manager.convert(base, toHaveTrait: .boldFontMask)
        self.italic = manager.convert(base, toHaveTrait: .italicFontMask)
        self.boldItalic = manager.convert(self.italic, toHaveTrait: .boldFontMask)

        let metrics = Self.measure(base)
        self.cellWidth = Self.snap(metrics.advance, scale: scale)
        // The line height is a *ratio of the point size*, not the font's own metrics. That one change is most of
        // the difference between reading like a terminal and reading like a text editor — see the token.
        self.cellHeight = Self.snap(pointSize * lineHeightRatio, scale: scale)
        // The text stays centred in the taller cell, which is what `line-height` does on the web: growing the line
        // adds room around the glyphs rather than pushing them down inside it.
        let natural = metrics.ascent + metrics.descent + metrics.leading
        self.baselineFromTop = Self.snap(
            metrics.ascent + metrics.leading / 2 + max(0, self.cellHeight - natural) / 2, scale: scale)
    }

    func font(for flags: CellAttributes.Flags) -> NSFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return base
        }
    }

    /// Whole pixels only. Rounding to whole *points* instead would halve the usable density on a
    /// Retina display, which is where the crispness comes from in the first place.
    private static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    private static func resolve(pointSize: CGFloat) -> NSFont {
        for name in ["SFMono-Regular", "Menlo-Regular"] {
            if let font = NSFont(name: name, size: pointSize) { return font }
        }
        return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    private static func measure(
        _ font: NSFont
    ) -> (advance: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        let ctFont = font as CTFont
        // Measured from a real glyph rather than a typographic constant: the two disagree for
        // several monospace faces, and the glyph is the one that decides where the next column is.
        var glyph = CGGlyph()
        var character: UniChar = 0x4D                             // M
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        }
        return (
            advance.width > 0 ? advance.width : CTFontGetSize(ctFont) * 0.6,
            CTFontGetAscent(ctFont),
            CTFontGetDescent(ctFont),
            CTFontGetLeading(ctFont)
        )
    }
}
