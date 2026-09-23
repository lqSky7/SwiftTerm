import Foundation

/// A block's identity. Monotonic and never reused, so a view can key on it, an action can name it,
/// and a block that has been evicted is never confused with a new one.
struct BlockID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: BlockID, rhs: BlockID) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { "#\(rawValue)" }
}
