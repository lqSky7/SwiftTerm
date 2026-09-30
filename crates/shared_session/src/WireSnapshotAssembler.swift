import Foundation

/// Reassembles a chunked snapshot in a bounded scratch buffer and swaps it in only after the
/// count, the length and the digest all agree.
///
/// A partial snapshot is never rendered: until `end` validates, the previous view stays up. Any
/// chunk from another id or epoch, any missing index or any digest mismatch throws
/// `resyncRequired`, which is the caller's cue to ask for a fresh snapshot rather than to guess at
/// the missing cells.
struct WireSnapshotAssembler: Sendable {
    private struct Pending: Sendable {
        var epoch: String
        var snapshotID: String
        var expectedBytes: Int
        var expectedChunks: Int
        var sha256: String
        var buffer: Data
        var received: Int
    }

    private var pending: Pending?

    var isAssembling: Bool { pending != nil }

    /// Abandon whatever is in flight. This is the eviction barrier: after `reset` no cell from the
    /// abandoned transfer can reach a renderer.
    mutating func reset() { pending = nil }

    mutating func begin(_ frame: WireSnapshotBegin) throws {
        guard pending == nil else {
            throw WireError.resyncRequired(reason: "a snapshot is already in flight")
        }
        // The declared size has to be consistent with the declared chunk count at the frame
        // limit, or the buffer bound is a promise the sender never intended to keep.
        let maximum = frame.chunks * WireLimits.maxRawChunkBytes
        guard frame.bytes <= maximum else {
            throw WireError.oversized(
                path: "snapshot.begin.bytes", limit: maximum, actual: frame.bytes)
        }
        pending = Pending(
            epoch: frame.epoch, snapshotID: frame.snapshotID, expectedBytes: frame.bytes,
            expectedChunks: frame.chunks, sha256: frame.sha256,
            buffer: Data(capacity: min(frame.bytes, WireLimits.maxSnapshotBytes)), received: 0)
    }

    mutating func append(_ frame: WireSnapshotChunk) throws {
        guard var current = pending else {
            throw WireError.resyncRequired(reason: "chunk without a begin")
        }
        guard current.snapshotID == frame.snapshotID, current.epoch == frame.epoch else {
            pending = nil
            throw WireError.resyncRequired(reason: "chunk belongs to another snapshot")
        }
        guard frame.index == current.received else {
            pending = nil
            throw WireError.resyncRequired(
                reason: "chunk index \(frame.index), expected \(current.received)")
        }
        guard current.received < current.expectedChunks else {
            pending = nil
            throw WireError.resyncRequired(reason: "more chunks than declared")
        }
        let total = current.buffer.count + frame.data.count
        guard total <= current.expectedBytes else {
            pending = nil
            throw WireError.oversized(
                path: "snapshot", limit: current.expectedBytes, actual: total)
        }
        current.buffer.append(frame.data)
        current.received += 1
        pending = current
    }

    /// Verify and hand back the bytes. The buffer is dropped either way, so a failed transfer
    /// cannot be resumed from a half-checked state.
    mutating func finish(_ frame: WireSnapshotEnd) throws -> Data {
        guard let current = pending else {
            throw WireError.resyncRequired(reason: "end without a begin")
        }
        pending = nil
        guard current.snapshotID == frame.snapshotID, current.epoch == frame.epoch else {
            throw WireError.resyncRequired(reason: "end belongs to another snapshot")
        }
        guard current.received == current.expectedChunks else {
            throw WireError.resyncRequired(
                reason: "\(current.received) of \(current.expectedChunks) chunks")
        }
        guard current.buffer.count == current.expectedBytes else {
            throw WireError.resyncRequired(
                reason: "\(current.buffer.count) bytes, expected \(current.expectedBytes)")
        }
        guard WireSHA256.hexDigest(current.buffer) == current.sha256 else {
            throw WireError.resyncRequired(reason: "digest mismatch")
        }
        return current.buffer
    }

    /// The whole receiving half of a snapshot transfer, for a caller that already has the frames.
    static func assemble(frames: [WireFrame]) throws -> WireSnapshot {
        var assembler = WireSnapshotAssembler()
        for frame in frames {
            switch frame {
            case let .snapshotBegin(begin): try assembler.begin(begin)
            case let .snapshotChunk(chunk): try assembler.append(chunk)
            case let .snapshotEnd(end):
                let bytes = try assembler.finish(end)
                return try WireCanonicalJSON.decode(WireSnapshot.self, from: bytes)
            default:
                throw WireError.malformedFrame(reason: "unexpected frame in a snapshot transfer")
            }
        }
        throw WireError.resyncRequired(reason: "transfer ended without snapshot.end")
    }

    /// Split canonical snapshot bytes into frames. The producer hashes the bytes it sends, which
    /// is why this takes bytes rather than an object.
    static func chunk(
        bytes: Data, epoch: String, seq: String, snapshotID: String
    ) throws -> [WireFrame] {
        guard bytes.count <= WireLimits.maxSnapshotBytes else {
            throw WireError.oversized(
                path: "snapshot", limit: WireLimits.maxSnapshotBytes, actual: bytes.count)
        }
        let size = WireLimits.maxRawChunkBytes
        let count = max(1, (bytes.count + size - 1) / size)
        guard count <= WireLimits.maxChunks else {
            throw WireError.oversized(
                path: "snapshot.chunks", limit: WireLimits.maxChunks, actual: count)
        }
        var frames: [WireFrame] = [
            .snapshotBegin(
                WireSnapshotBegin(
                    epoch: epoch, seq: seq, snapshotID: snapshotID, bytes: bytes.count,
                    chunks: count, sha256: WireSHA256.hexDigest(bytes)))
        ]
        for index in 0..<count {
            let start = index * size
            let end = min(start + size, bytes.count)
            frames.append(
                .snapshotChunk(
                    WireSnapshotChunk(
                        epoch: epoch, snapshotID: snapshotID, index: index,
                        data: bytes.subdata(in: start..<end))))
        }
        frames.append(.snapshotEnd(WireSnapshotEnd(epoch: epoch, snapshotID: snapshotID)))
        return frames
    }
}
