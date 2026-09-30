import Foundation

/// A key of any name, so a decoding container can enumerate what actually arrived and reject
/// anything the contract does not name. `JSONDecoder` ignores unknown keys by default; the wire
/// format must not, because an unread field is a field two peers disagree about.
struct WireKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    init(_ name: String) { self.stringValue = name }
}

extension KeyedDecodingContainer where Key == WireKey {
    /// Reject every field the contract does not name. Called first in each `init(from:)`, before
    /// any value is read, so a frame carrying an extra field is refused rather than partially read.
    func rejectUnknown(known: Set<String>, path: String) throws {
        for key in allKeys where !known.contains(key.stringValue) {
            throw WireError.unknownField(path: path, field: key.stringValue)
        }
    }

    /// A required field. An explicit JSON `null` is refused rather than treated as absent: the
    /// contract says optional fields are omitted, so a null is a peer that means something else.
    func require<T: Decodable>(_ type: T.Type, _ name: String, path: String) throws -> T {
        let key = WireKey(name)
        guard contains(key) else {
            throw WireError.missingField(path: path, field: name)
        }
        return try decode(type, forKey: key)
    }

    /// An optional field. Present-and-null is an error; only omission means "no value".
    func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let key = WireKey(name)
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}

/// Value-level rules shared by every DTO. Each one is a rule from wire-contract.md; keeping them
/// here means the snapshot, the damage frame and the share DTO cannot drift apart on what an
/// integer or a grapheme is.
enum WireValue {
    static let hexDigits = Set("0123456789abcdef")

    /// Counters travel as decimal strings so no JSON parser can round them.
    static func counter(_ text: String, path: String) throws -> Int64 {
        guard !text.isEmpty, text.count <= WireLimits.maxCounterDigits else {
            throw WireError.invalidValue(path: path, reason: "counter \(text.count) digits")
        }
        let scalars = Array(text.unicodeScalars)
        if scalars.count > 1 && scalars[0] == "0" {
            throw WireError.invalidValue(path: path, reason: "counter has a leading zero")
        }
        var value: Int64 = 0
        for scalar in scalars {
            guard scalar.value >= 48, scalar.value <= 57 else {
                throw WireError.invalidValue(path: path, reason: "counter is not decimal")
            }
            let digit = Int64(scalar.value - 48)
            let (multiplied, overflowA) = value.multipliedReportingOverflow(by: 10)
            guard !overflowA else {
                throw WireError.invalidValue(path: path, reason: "counter overflows Int64")
            }
            let (added, overflowB) = multiplied.addingReportingOverflow(digit)
            guard !overflowB, added <= WireLimits.maxCounterValue else {
                throw WireError.invalidValue(path: path, reason: "counter overflows Int64")
            }
            value = added
        }
        return value
    }

    /// Epoch and seq start at 1; snapshot `S` may be 0.
    static func positiveCounter(_ text: String, path: String) throws -> Int64 {
        let value = try counter(text, path: path)
        guard value >= 1 else {
            throw WireError.outOfBounds(path: path, reason: "counter must be >= 1")
        }
        return value
    }

    /// Every non-counter integer is a JSON safe integer and nonnegative unless the caller says
    /// otherwise.
    static func safeInteger(
        _ value: Int, path: String, range: ClosedRange<Int> = 0...WireLimits.maxSafeInteger
    ) throws -> Int {
        guard range.contains(value) else {
            throw WireError.outOfBounds(
                path: path, reason: "\(value) outside \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    static func signedInt32(_ value: Int, path: String) throws -> Int {
        try safeInteger(
            value, path: path, range: WireLimits.minSignedInt32...WireLimits.maxSignedInt32)
    }

    /// Canonical lowercase UUID text: 36 characters, hyphens in the four fixed places, lowercase
    /// hex elsewhere. A peer that sends an uppercase or braced UUID is refused rather than
    /// normalised, because normalising would give one identity two wire spellings.
    @discardableResult
    static func uuid(_ text: String, path: String) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 36 else {
            throw WireError.invalidValue(path: path, reason: "UUID is \(scalars.count) characters")
        }
        for (offset, scalar) in scalars.enumerated() {
            if offset == 8 || offset == 13 || offset == 18 || offset == 23 {
                guard scalar == "-" else {
                    throw WireError.invalidValue(path: path, reason: "UUID hyphen misplaced")
                }
            } else {
                guard scalar.value < 128, hexDigits.contains(Character(scalar)) else {
                    throw WireError.invalidValue(
                        path: path, reason: "UUID is not lowercase hex")
                }
            }
        }
        return text
    }

    /// Lowercase 64-character hex, the spelling `snapshot.begin.sha256` uses.
    @discardableResult
    static func hexDigest(_ text: String, path: String) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 64 else {
            throw WireError.invalidValue(path: path, reason: "digest is \(scalars.count) characters")
        }
        for scalar in scalars {
            guard scalar.value < 128, hexDigits.contains(Character(scalar)) else {
                throw WireError.invalidValue(path: path, reason: "digest is not lowercase hex")
            }
        }
        return text
    }

    /// Strict, canonical base64. Re-encoding and comparing rejects both unknown characters and a
    /// non-canonical tail, so two peers cannot disagree about the bytes behind one frame.
    static func base64(_ text: String, path: String, maxBytes: Int) throws -> Data {
        guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else {
            throw WireError.invalidValue(path: path, reason: "not canonical base64")
        }
        guard data.count <= maxBytes else {
            throw WireError.oversized(path: path, limit: maxBytes, actual: data.count)
        }
        return data
    }

    /// UTF-8 byte budget. Counted in octets, not characters: the limit exists to bound a buffer.
    @discardableResult
    static func utf8(_ text: String, path: String, limit: Int, allowEmpty: Bool = true) throws
        -> String
    {
        let bytes = text.utf8.count
        guard bytes <= limit else {
            throw WireError.oversized(path: path, limit: limit, actual: bytes)
        }
        if !allowEmpty && text.isEmpty {
            throw WireError.invalidValue(path: path, reason: "must not be empty")
        }
        return text
    }

    /// Format and bidi controls, plus the C0/C1 controls. These have no place in a cell: they
    /// cannot be drawn, and the bidi set can make one row render as another.
    static let forbiddenScalars: [ClosedRange<UInt32>] = [
        0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069,
    ]

    /// Exactly one extended grapheme cluster, at most 64 UTF-8 bytes, with no control scalar.
    /// Swift's `Character` is the grapheme cluster, so the count *is* the rule.
    @discardableResult
    static func grapheme(_ text: String, path: String) throws -> String {
        guard text.count <= 1 else {
            throw WireError.invalidValue(
                path: path, reason: "\(text.count) graphemes, expected at most one")
        }
        try utf8(text, path: path, limit: WireLimits.maxGraphemeBytes)
        for scalar in text.unicodeScalars {
            for range in forbiddenScalars where range.contains(scalar.value) {
                throw WireError.invalidValue(
                    path: path, reason: "control scalar U+\(String(scalar.value, radix: 16))")
            }
        }
        return text
    }

    /// `text` for a width-1 or width-2 cell: exactly one grapheme, and a lone space is the
    /// canonical empty cell.
    @discardableResult
    static func visibleGrapheme(_ text: String, path: String) throws -> String {
        let value = try grapheme(text, path: path)
        guard !value.isEmpty else {
            throw WireError.invalidValue(path: path, reason: "empty text in a visible cell")
        }
        return value
    }
}
