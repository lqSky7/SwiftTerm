import Foundation

/// Stable export identities for a stream.
///
/// The terminal's own identities are **local and numeric** — a pane is a `PaneID`, a block is a
/// `BlockID` wrapping a `UInt64`. Those are meaningful inside one process and meaningless anywhere
/// else: two machines both have a block `#1`, and a block number is reused after a tab is closed. A
/// viewer cannot be told "block 1 changed" without it meaning something, so every block that goes on
/// the wire gets a UUID allocated here, once, and keeps it for as long as the stream lives.
///
/// Two properties make this correct rather than merely convenient:
///
///   * **The mapping is one-way and stable.** A local id maps to one UUID and never to a second, so a
///     delta that names a block names the block the snapshot named. Re-deriving the UUID from the
///     local id would be tempting and wrong — a `BlockID` is reused after a close, and the second
///     block to hold `#7` is not the first.
///   * **It is bounded.** A long session closes blocks forever, and a registry that grew with them
///     would be the leak the relay's own ring exists to avoid. Eviction drops the *oldest*, which is
///     safe because a viewer is only ever shown the recent window and a block that has been evicted
///     is one no retained frame can still reference.
///
/// This type deliberately knows nothing about the terminal. It takes integers, so it can live beside
/// the wire contract and be tested without a grid.
struct ExportIdentityRegistry {
    /// How many live identities are kept. A snapshot carries at most 50 blocks and the relay's ring
    /// is bounded by time, so a few hundred covers the window with room for the frames still in
    /// flight.
    static let defaultCapacity = 256

    private let capacity: Int
    /// Insertion-ordered so eviction can drop the oldest without a second structure.
    private var order: [UInt64] = []
    private var byLocalID: [UInt64: String] = [:]

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { byLocalID.count }

    /// The UUID for a local block, allocating one the first time it is seen.
    mutating func identity(for localBlockID: UInt64) -> String {
        if let existing = byLocalID[localBlockID] { return existing }
        // Lowercase, because the wire validator refuses any other spelling rather than normalising
        // it, and a UUID that arrives uppercase is a frame the browser rejects outright.
        let allocated = UUID().uuidString.lowercased()
        byLocalID[localBlockID] = allocated
        order.append(localBlockID)
        evictIfNeeded()
        return allocated
    }

    /// The UUID already allocated, or nil. Used where allocating would be wrong — a delta that names
    /// a block the viewer has never been told about is a bug on this side, not a new block.
    func existingIdentity(for localBlockID: UInt64) -> String? {
        byLocalID[localBlockID]
    }

    /// Drop an identity. Called when a block is closed *and* the eviction window has moved past it;
    /// dropping one a viewer can still see would make a later delta unresolvable.
    mutating func forget(_ localBlockID: UInt64) {
        guard byLocalID.removeValue(forKey: localBlockID) != nil else { return }
        order.removeAll { $0 == localBlockID }
    }

    private mutating func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            byLocalID.removeValue(forKey: oldest)
        }
    }
}

/// Allocates the stream identity for one pane.
///
/// Separate from the block registry because the lifetime is different: a block identity lives as long
/// as the stream, and the *stream* identity is the pane's export UUID — assigned when sharing starts
/// and kept until it stops. Reconnecting must reuse it, or a relay that restarted would see a new
/// stream where the owner sees the same one.
struct PaneExportIdentity {
    /// The pane's stable export UUID. Allocated once, on the first share, and reused after that.
    let uuid: String
    /// A client request id for the create call, so a retry after a dropped response returns the
    /// stream that already exists rather than making a second one.
    let clientRequestID: String

    init(uuid: String = UUID().uuidString.lowercased()) {
        self.uuid = uuid
        self.clientRequestID = UUID().uuidString.lowercased()
    }
}
