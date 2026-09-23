import Foundation

/// Turns a byte stream into characters without assuming chunk boundaries fall on them.
///
/// A read from a PTY can end mid-codepoint, so the bytes that do not yet form a scalar are held
/// until the next read. Grapheme clustering is left to `String`: the scalars that arrive in one
/// piece are appended to a `String` and read back out as `Character`s, which is what makes a
/// combining mark join the letter before it. A sequence split across reads degrades to its
/// pieces rather than being held hostage — a terminal that withholds the last character until
/// more output arrives is worse than one that renders a torn emoji.
struct VTStringDecoder {
    private var pending: [UInt8] = []

    var hasPendingBytes: Bool { !pending.isEmpty }

    mutating func reset() {
        pending.removeAll()
    }

    mutating func feed(_ bytes: [UInt8], into sink: (Character) -> Void) {
        pending.append(contentsOf: bytes)
        var text = ""
        var consumed = 0
        while consumed < pending.count {
            let leading = pending[consumed]
            let length = Self.sequenceLength(of: leading)
            if length == 0 {
                consumed += 1                        // a stray continuation byte
                continue
            }
            if length == 1 {
                text.append(Character(Unicode.Scalar(leading)))
                consumed += 1
                continue
            }
            guard consumed + length <= pending.count else { break }
            guard let scalar = Self.scalar(pending[consumed..<(consumed + length)], length: length) else {
                consumed += 1
                continue
            }
            text.append(Character(scalar))
            consumed += length
        }
        pending.removeFirst(consumed)
        for character in text { sink(character) }
    }

    private static func sequenceLength(of leading: UInt8) -> Int {
        switch leading {
        case 0x00...0x7F: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 0
        }
    }

    private static func scalar(_ bytes: ArraySlice<UInt8>, length: Int) -> Unicode.Scalar? {
        var value = UInt32(bytes[bytes.startIndex] & (0xFF >> (length + 1)))
        for offset in 1..<length {
            let byte = bytes[bytes.startIndex + offset]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        return Unicode.Scalar(value)
    }
}
