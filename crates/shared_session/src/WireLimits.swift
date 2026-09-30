import Foundation

/// The frozen v1 numbers, in one place so the encoder, the validator and the relay all read the
/// same value instead of each carrying its own copy of "64 KiB".
///
/// These are initial enforced limits, not measured throughput claims. A limit that is exceeded is
/// an error with a visible cause; nothing here truncates or resizes host content silently.
enum WireLimits {
    static let schemaVersion = 1

    // Snapshot and framing.
    static let maxSnapshotBytes = 4 * 1024 * 1024
    static let maxFrameBytes = 64 * 1024
    static let maxRawChunkBytes = 45 * 1024
    static let maxChunks = 128
    static let maxAuthFrameBytes = 4 * 1024

    // Geometry and content.
    static let maxBlocks = 50
    static let maxTotalGridLines = 2000
    static let minGridDimension = 1
    static let maxGridDimension = 512
    static let maxGraphemeBytes = 64
    static let maxCommandBytes = 64 * 1024
    static let maxEditorBytes = 64 * 1024

    // Styles.
    static let maxStyles = 4096
    static let maxStyleIndex = 4095
    static let maxColorIndex = 255
    static let maxChannel = 255
    static let maxStyleFlags = 255

    // Damage.
    static let maxDamageOps = 128
    static let maxDamageBytes = 64 * 1024

    // Input.
    static let maxInputBytes = 64 * 1024

    // Static shares.
    static let maxShareBlocks = 20
    static let maxShareBytes = 2 * 1024 * 1024

    /// The largest integer a JSON consumer can hold without losing precision. Every integer in the
    /// wire format except the explicitly decimal-string counters must stay inside this.
    static let maxSafeInteger = 9_007_199_254_740_991
    static let maxSignedInt32 = 2_147_483_647
    static let minSignedInt32 = -2_147_483_648

    /// Counters (`epoch`, `seq`, `input_seq`) travel as decimal strings so no JSON parser can round
    /// them. `0|[1-9][0-9]{0,18}` and no wider than a signed 64-bit integer.
    static let maxCounterDigits = 19
    static let maxCounterValue: Int64 = 9_223_372_036_854_775_807
}
