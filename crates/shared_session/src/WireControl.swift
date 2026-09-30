import Foundation

/// A UTC instant as `ISO8601` with milliseconds and a literal `Z`. Fixed width, so two peers
/// cannot disagree about the same moment's spelling.
///
/// The formatter is built per call rather than cached in a `static let`: `ISO8601DateFormatter` is
/// a non-`Sendable` class, and a shared instance would be a data race waiting for a concurrent
/// frame. These frames are rare — a grant expiry, not a damage delta — so the allocation is not on
/// any hot path.
enum WireTime {
    static func isValid(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        // 2026-09-30T18:59:28.123Z
        guard scalars.count == 24 else { return false }
        let digits: Set<Int> = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22]
        for (offset, scalar) in scalars.enumerated() where digits.contains(offset) {
            guard scalar.value >= 48, scalar.value <= 57 else { return false }
        }
        let separators: [Int: Unicode.Scalar] = [
            4: "-", 7: "-", 10: "T", 13: ":", 16: ":", 19: ".", 23: "Z",
        ]
        for (offset, expected) in separators where scalars[offset] != expected { return false }
        let formatter = formatter()
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    static func string(from date: Date) -> String { formatter().string(from: date) }

    static func parse(_ text: String) -> Date? { formatter().date(from: text) }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

/// Why a lease ended. `local_input` is the host taking over; the rest are lifecycle.
enum WireRevokeReason: String, Sendable, CaseIterable, Codable {
    case localInput = "local_input"
    case expired, disconnect, revoked, ended
}

/// A browser asking for control. It names no lease and no client: the requester cannot choose who
/// is granted, and receiving this frame grants nothing.
struct WireControlRequest: Equatable, Sendable, Codable {
    var epoch: String

    private enum Field {
        static let type = "type", epoch = "epoch"
        static let all: Set<String> = [type, epoch]
    }

    static let typeName = "control.request"

    init(epoch: String) { self.epoch = epoch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "control.request")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "control.request"),
            path: "control.request.epoch"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
    }
}

/// The host approving one connection. The lease is issued by the host, is bound to the connection
/// that asked, and expires.
struct WireControlGranted: Equatable, Sendable, Codable {
    var epoch: String
    var lease: String
    var expiresAt: String

    private enum Field {
        static let type = "type", epoch = "epoch", lease = "lease", expires = "expires_at"
        static let all: Set<String> = [type, epoch, lease, expires]
    }

    static let typeName = "control.granted"

    init(epoch: String, lease: String, expiresAt: String) {
        self.epoch = epoch
        self.lease = lease
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "control.granted")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "control.granted"),
            path: "control.granted.epoch"))
        self.lease = try WireValue.uuid(
            try container.require(String.self, Field.lease, path: "control.granted"),
            path: "control.granted.lease")
        self.expiresAt = try container.require(String.self, Field.expires, path: "control.granted")
        guard WireTime.isValid(expiresAt) else {
            throw WireError.invalidValue(
                path: "control.granted.expires_at", reason: "not UTC ISO8601 milliseconds")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(lease, forKey: WireKey(Field.lease))
        try container.encode(expiresAt, forKey: WireKey(Field.expires))
    }
}

struct WireControlDenied: Equatable, Sendable, Codable {
    var epoch: String

    private enum Field {
        static let type = "type", epoch = "epoch"
        static let all: Set<String> = [type, epoch]
    }

    static let typeName = "control.denied"

    init(epoch: String) { self.epoch = epoch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "control.denied")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "control.denied"),
            path: "control.denied.epoch"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
    }
}

/// Cancels pending browser input immediately. It carries no timestamp: a lease ends because the
/// host or relay decided so, never because a browser wrote an expiry into a frame.
struct WireControlRevoked: Equatable, Sendable, Codable {
    var epoch: String
    var lease: String
    var reason: WireRevokeReason

    private enum Field {
        static let type = "type", epoch = "epoch", lease = "lease", reason = "reason"
        static let all: Set<String> = [type, epoch, lease, reason]
    }

    static let typeName = "control.revoked"

    init(epoch: String, lease: String, reason: WireRevokeReason) {
        self.epoch = epoch
        self.lease = lease
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "control.revoked")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "control.revoked"),
            path: "control.revoked.epoch"))
        self.lease = try WireValue.uuid(
            try container.require(String.self, Field.lease, path: "control.revoked"),
            path: "control.revoked.lease")
        self.reason = try container.require(WireRevokeReason.self, Field.reason, path: "control.revoked")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(lease, forKey: WireKey(Field.lease))
        try container.encode(reason, forKey: WireKey(Field.reason))
    }
}

/// Relay to host only. At zero viewers the host stops encoding, so this frame is what makes
/// "sharing is on but nobody is watching" cheap.
struct WireViewerCount: Equatable, Sendable, Codable {
    var epoch: String
    var count: Int

    private enum Field {
        static let type = "type", epoch = "epoch", count = "count"
        static let all: Set<String> = [type, epoch, count]
    }

    static let typeName = "viewer.count"

    init(epoch: String, count: Int) {
        self.epoch = epoch
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "viewer.count")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "viewer.count"),
            path: "viewer.count.epoch"))
        self.count = try WireValue.safeInteger(
            try container.require(Int.self, Field.count, path: "viewer.count"),
            path: "viewer.count.count", range: 0...WireLimits.maxSafeInteger)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(count, forKey: WireKey(Field.count))
    }
}
