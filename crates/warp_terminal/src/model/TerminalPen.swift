import Foundation

/// What the parser is currently drawing with: the attributes SGR has set, the character set
/// in force, and whether the cursor is sitting one column past the last printed character.
struct TerminalPen: Hashable, Sendable {
    /// The two character sets a terminal can designate. `decSpecialGraphics` is the box-drawing
    /// set ncurses and vim switch into, and the reason a dialog draws with lines not letters.
    enum Charset: Hashable, Sendable {
        case ascii
        case decSpecialGraphics
    }

    var attributes = CellAttributes()
    var g0: Charset = .ascii
    var g1: Charset = .ascii
    var usesG1 = false                  // SO selects G1, SI selects G0
    var pendingWrap = false

    var activeCharset: Charset { usesG1 ? g1 : g0 }

    /// `ESC ( ) * +` designations, and `SI` / `SO`.
    mutating func designate(_ charset: Charset, slot: UInt8) {
        switch slot {
        case 0x28: g0 = charset      // `(`
        case 0x29: g1 = charset      // `)`
        case 0x2A, 0x2B: break       // G2 and G3 are designated but never selected here
        default: break
        }
    }

    /// DEC Special Graphics: only `0x5F`–`0x7E` are remapped; everything else is ASCII.
    func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard activeCharset == .decSpecialGraphics else { return scalar }
        let value = scalar.value
        guard (0x5F...0x7E).contains(value) else { return scalar }
        return Self.decSpecialGraphics[Int(value - 0x5F)]
    }

    private static let decSpecialGraphics: [Unicode.Scalar] = Array(
        "\u{00A0}◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars)
}
