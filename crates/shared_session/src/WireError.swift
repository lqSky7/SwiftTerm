import Foundation

/// The allowlisted protocol error codes. Nothing else may travel: a code is the whole message, so
/// a malformed frame can never leak a diagnostic, a path or a payload back to the peer.
enum WireErrorCode: String, Sendable, CaseIterable, Codable {
    case unauthorized
    case unsupportedVersion = "unsupported_version"
    case invalidFrame = "invalid_frame"
    case staleEpoch = "stale_epoch"
    case staleLease = "stale_lease"
    case inputGap = "input_gap"
    case rateLimited = "rate_limited"
    case capacity
    case unsupportedInput = "unsupported_input"
    case sessionEnded = "session_ended"
    case resyncRequired = "resync_required"
}

/// A rejection with enough local detail to fix a bug and no more. `path` is a field path such as
/// `blocks[3].output.lines[7]`; it is for tests and logs on the owning side, never for the wire.
enum WireError: Error, Equatable {
    case unknownField(path: String, field: String)
    case missingField(path: String, field: String)
    case invalidValue(path: String, reason: String)
    case unsupportedVersion(got: Int)
    case malformedFrame(reason: String)
    case oversized(path: String, limit: Int, actual: Int)
    case duplicateID(String)
    case outOfBounds(path: String, reason: String)
    case staleEpoch(expected: String, got: String)
    case sequenceGap(expected: String, got: String)
    case unknownBlock(String)
    case unknownSession(String)
    case resyncRequired(reason: String)
    case unsupportedInput(reason: String)

    /// Which wire code carries this rejection.
    var code: WireErrorCode {
        switch self {
        case .unsupportedVersion: .unsupportedVersion
        case .staleEpoch: .staleEpoch
        case .sequenceGap, .resyncRequired: .resyncRequired
        case .unsupportedInput: .unsupportedInput
        case .unknownSession: .sessionEnded
        case .unknownField, .missingField, .invalidValue, .malformedFrame,
            .oversized, .duplicateID, .outOfBounds, .unknownBlock:
            .invalidFrame
        }
    }

    /// A stable, non-sensitive description for the harness. Never sent to a peer.
    var diagnostic: String {
        switch self {
        case let .unknownField(path, field): "\(path): unknown field \(field)"
        case let .missingField(path, field): "\(path): missing field \(field)"
        case let .invalidValue(path, reason): "\(path): \(reason)"
        case let .unsupportedVersion(got): "unsupported version \(got)"
        case let .malformedFrame(reason): "malformed frame: \(reason)"
        case let .oversized(path, limit, actual): "\(path): \(actual) bytes exceeds \(limit)"
        case let .duplicateID(id): "duplicate id \(id)"
        case let .outOfBounds(path, reason): "\(path): \(reason)"
        case let .staleEpoch(expected, got): "stale epoch: expected \(expected), got \(got)"
        case let .sequenceGap(expected, got): "sequence gap: expected \(expected), got \(got)"
        case let .unknownBlock(id): "unknown block \(id)"
        case let .unknownSession(id): "unknown session \(id)"
        case let .resyncRequired(reason): "resync required: \(reason)"
        case let .unsupportedInput(reason): "unsupported input: \(reason)"
        }
    }
}
