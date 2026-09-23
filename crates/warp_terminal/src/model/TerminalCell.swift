import Foundation

/// One grid cell. `text` is a whole grapheme, not a scalar, so a combining sequence or an
/// emoji ZWJ family lands in a single cell instead of spilling across several.
struct TerminalCell: Hashable, Sendable {
    var text: String = ""
    var attributes = CellAttributes()
    var width: Int = 1
    /// The right-hand half of a double-width glyph. It owns no text; its left neighbour does.
    var isContinuation: Bool = false

    static let blank = TerminalCell()

    var isBlank: Bool {
        (text.isEmpty || text == " ") && !isContinuation && attributes == CellAttributes()
    }
}

extension TerminalCell {
    /// A grapheme's column span. The maximum over its scalars, because a base character plus
    /// a combining mark is still one column while a base plus a wide ideograph is two.
    static func displayWidth(of character: Character) -> Int {
        var span = 0
        for scalar in character.unicodeScalars {
            span = max(span, width(of: scalar))
        }
        return span
    }

    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value == 0 || value < 0x20 || (0x7F...0x9F).contains(value) { return 0 }
        if isZeroWidth(scalar) { return 0 }
        return isWide(scalar) ? 2 : 1
    }

    /// True for the scalars a terminal must fold into the cell before them rather than place.
    /// Only the cases Unicode does not already mark as grapheme-extend need listing.
    static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isGraphemeExtend || scalar.properties.isVariationSelector { return true }
        switch scalar.value {
        case 0x1160...0x11FF,   // Hangul Jamo medial vowels and final consonants
             0x200B...0x200F,   // zero-width space and the bidi marks around it
             0x2060...0x2064,   // word joiner and the invisible operators
             0xFEFF...0xFEFF:   // zero-width no-break space
            return true
        default:
            return false
        }
    }

    /// East Asian Wide and Fullwidth, plus anything Unicode gives an emoji presentation.
    /// Hand-rolled rather than `wcwidth` because that reads the process locale, and a test
    /// harness must not have to mutate global state to ask how wide a character is.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        let value = scalar.value
        return wideRanges.contains { $0.contains(value) }
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,    // Hangul Jamo initial consonants
        0x2E80...0x303E,    // CJK radicals, Kangxi, CJK symbols and punctuation
        0x3041...0x33FF,    // Kana, Bopomofo, Hangul compatibility, enclosed CJK
        0x3400...0x4DBF,    // CJK unified ideographs extension A
        0x4E00...0x9FFF,    // CJK unified ideographs
        0xA000...0xA4CF,    // Yi
        0xA960...0xA97F,    // Hangul Jamo extended-A
        0xAC00...0xD7A3,    // Hangul syllables
        0xF900...0xFAFF,    // CJK compatibility ideographs
        0xFE10...0xFE19,    // Vertical forms
        0xFE30...0xFE6F,    // CJK compatibility forms, small form variants
        0xFF00...0xFF60,    // Fullwidth forms
        0xFFE0...0xFFE6,    // Fullwidth signs
        0x1F300...0x1F64F,  // Emoji pictographs and emoticons
        0x1F900...0x1F9FF,  // Supplemental symbols and pictographs
        0x20000...0x2FFFD,  // CJK extensions B through F
        0x30000...0x3FFFD,  // CJK extension G
    ]
}
