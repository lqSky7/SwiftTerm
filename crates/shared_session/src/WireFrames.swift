import Foundation

/// Which way a frame may travel. A viewer that sends `snapshot.chunk` is not merely ignored: the
/// direction check is what stops one role writing on another's behalf.
///
/// The raw values are wire-visible because the shared fixtures name a direction, and both the
/// Swift and TypeScript sides have to agree on which one a case means.
enum WireDirection: String, Sendable, CaseIterable, Codable {
    case hostToRelay = "host_to_relay"
    case viewerToRelay = "viewer_to_relay"
    case relayToHost = "relay_to_host"
    case relayToViewer = "relay_to_viewer"
}

/// The first frame on a socket. It is the only frame allowed before authentication, and only
/// within five seconds.
struct WireAuth: Equatable, Sendable, Codable {
    var ticket: String
    var clientID: String

    private enum Field {
        static let type = "type", ticket = "ticket", clientID = "client_id"
        static let all: Set<String> = [type, ticket, clientID]
    }

    static let typeName = "auth"

    init(ticket: String, clientID: String) {
        self.ticket = ticket
        self.clientID = clientID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "auth")
        self.ticket = try WireValue.utf8(
            try container.require(String.self, Field.ticket, path: "auth"),
            path: "auth.ticket", limit: WireLimits.maxAuthFrameBytes, allowEmpty: false)
        self.clientID = try WireValue.uuid(
            try container.require(String.self, Field.clientID, path: "auth"),
            path: "auth.client_id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(ticket, forKey: WireKey(Field.ticket))
        try container.encode(clientID, forKey: WireKey(Field.clientID))
    }
}

/// Relay to peer, once authenticated: the session's geometry and mode as the relay understands it.
struct WireHello: Equatable, Sendable, Codable {
    var version: Int
    var sessionID: String
    var epoch: String
    var mode: WireMode
    var columns: Int
    var rows: Int

    private enum Field {
        static let type = "type", version = "version", sessionID = "session_id"
        static let epoch = "epoch", mode = "mode", columns = "columns", rows = "rows"
        static let all: Set<String> = [type, version, sessionID, epoch, mode, columns, rows]
    }

    static let typeName = "hello"

    init(version: Int = WireLimits.schemaVersion, sessionID: String, epoch: String, mode: WireMode,
        columns: Int, rows: Int
    ) {
        self.version = version
        self.sessionID = sessionID
        self.epoch = epoch
        self.mode = mode
        self.columns = columns
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "hello")
        let version = try container.require(Int.self, Field.version, path: "hello")
        guard version == WireLimits.schemaVersion else {
            throw WireError.unsupportedVersion(got: version)
        }
        self.version = version
        self.sessionID = try WireValue.uuid(
            try container.require(String.self, Field.sessionID, path: "hello"),
            path: "hello.session_id")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "hello"), path: "hello.epoch"))
        self.mode = try container.require(WireMode.self, Field.mode, path: "hello")
        self.columns = try WireValue.safeInteger(
            try container.require(Int.self, Field.columns, path: "hello"), path: "hello.columns",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
        self.rows = try WireValue.safeInteger(
            try container.require(Int.self, Field.rows, path: "hello"), path: "hello.rows",
            range: WireLimits.minGridDimension...WireLimits.maxGridDimension)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(version, forKey: WireKey(Field.version))
        try container.encode(sessionID, forKey: WireKey(Field.sessionID))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(mode, forKey: WireKey(Field.mode))
        try container.encode(columns, forKey: WireKey(Field.columns))
        try container.encode(rows, forKey: WireKey(Field.rows))
    }
}

/// A viewer asking to continue from a seq. Only the current epoch may replay retained frames.
struct WireResume: Equatable, Sendable, Codable {
    var epoch: String
    var seq: String

    private enum Field {
        static let type = "type", epoch = "epoch", seq = "seq"
        static let all: Set<String> = [type, epoch, seq]
    }

    static let typeName = "resume"

    init(epoch: String, seq: String) {
        self.epoch = epoch
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "resume")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "resume"), path: "resume.epoch"))
        self.seq = String(try WireValue.counter(
            try container.require(String.self, Field.seq, path: "resume"), path: "resume.seq"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(seq, forKey: WireKey(Field.seq))
    }
}

struct WireResync: Equatable, Sendable, Codable {
    var epoch: String

    private enum Field {
        static let type = "type", epoch = "epoch"
        static let all: Set<String> = [type, epoch]
    }

    static let typeName = "resync"

    init(epoch: String) { self.epoch = epoch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "resync")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "resync"), path: "resync.epoch"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
    }
}

/// Reports the seq the viewer applied, not that the socket finished writing it.
struct WireOutputAck: Equatable, Sendable, Codable {
    var epoch: String
    var seq: String

    private enum Field {
        static let type = "type", epoch = "epoch", seq = "seq"
        static let all: Set<String> = [type, epoch, seq]
    }

    static let typeName = "output.ack"

    init(epoch: String, seq: String) {
        self.epoch = epoch
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "output.ack")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "output.ack"),
            path: "output.ack.epoch"))
        self.seq = String(try WireValue.counter(
            try container.require(String.self, Field.seq, path: "output.ack"),
            path: "output.ack.seq"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(seq, forKey: WireKey(Field.seq))
    }
}

/// An allowlisted code and nothing else. A frame that carried a message would be a channel for
/// whatever the sender felt like saying.
struct WireErrorFrame: Equatable, Sendable, Codable {
    var code: WireErrorCode

    private enum Field {
        static let type = "type", code = "code"
        static let all: Set<String> = [type, code]
    }

    static let typeName = "error"

    init(code: WireErrorCode) { self.code = code }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "error")
        self.code = try container.require(WireErrorCode.self, Field.code, path: "error")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(code, forKey: WireKey(Field.code))
    }
}

/// Opens a snapshot transfer. `sha256` is over the raw UTF-8 snapshot bytes, which is why the
/// producer must hash the bytes it actually sends rather than a re-encoding of the object.
struct WireSnapshotBegin: Equatable, Sendable, Codable {
    var epoch: String
    var seq: String
    var snapshotID: String
    var bytes: Int
    var chunks: Int
    var sha256: String

    private enum Field {
        static let type = "type", epoch = "epoch", seq = "seq", snapshotID = "snapshot_id"
        static let bytes = "bytes", chunks = "chunks", sha256 = "sha256"
        static let all: Set<String> = [type, epoch, seq, snapshotID, bytes, chunks, sha256]
    }

    static let typeName = "snapshot.begin"

    init(epoch: String, seq: String, snapshotID: String, bytes: Int, chunks: Int, sha256: String) {
        self.epoch = epoch
        self.seq = seq
        self.snapshotID = snapshotID
        self.bytes = bytes
        self.chunks = chunks
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "snapshot.begin")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "snapshot.begin"),
            path: "snapshot.begin.epoch"))
        self.seq = String(try WireValue.counter(
            try container.require(String.self, Field.seq, path: "snapshot.begin"),
            path: "snapshot.begin.seq"))
        self.snapshotID = try WireValue.uuid(
            try container.require(String.self, Field.snapshotID, path: "snapshot.begin"),
            path: "snapshot.begin.snapshot_id")
        self.bytes = try WireValue.safeInteger(
            try container.require(Int.self, Field.bytes, path: "snapshot.begin"),
            path: "snapshot.begin.bytes", range: 0...WireLimits.maxSnapshotBytes)
        self.chunks = try WireValue.safeInteger(
            try container.require(Int.self, Field.chunks, path: "snapshot.begin"),
            path: "snapshot.begin.chunks", range: 1...WireLimits.maxChunks)
        self.sha256 = try WireValue.hexDigest(
            try container.require(String.self, Field.sha256, path: "snapshot.begin"),
            path: "snapshot.begin.sha256")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(seq, forKey: WireKey(Field.seq))
        try container.encode(snapshotID, forKey: WireKey(Field.snapshotID))
        try container.encode(bytes, forKey: WireKey(Field.bytes))
        try container.encode(chunks, forKey: WireKey(Field.chunks))
        try container.encode(sha256, forKey: WireKey(Field.sha256))
    }
}

struct WireSnapshotChunk: Equatable, Sendable, Codable {
    var epoch: String
    var snapshotID: String
    var index: Int
    var data: Data

    private enum Field {
        static let type = "type", epoch = "epoch", snapshotID = "snapshot_id"
        static let index = "index", data = "data"
        static let all: Set<String> = [type, epoch, snapshotID, index, data]
    }

    static let typeName = "snapshot.chunk"

    init(epoch: String, snapshotID: String, index: Int, data: Data) {
        self.epoch = epoch
        self.snapshotID = snapshotID
        self.index = index
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "snapshot.chunk")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "snapshot.chunk"),
            path: "snapshot.chunk.epoch"))
        self.snapshotID = try WireValue.uuid(
            try container.require(String.self, Field.snapshotID, path: "snapshot.chunk"),
            path: "snapshot.chunk.snapshot_id")
        self.index = try WireValue.safeInteger(
            try container.require(Int.self, Field.index, path: "snapshot.chunk"),
            path: "snapshot.chunk.index", range: 0...(WireLimits.maxChunks - 1))
        self.data = try WireValue.base64(
            try container.require(String.self, Field.data, path: "snapshot.chunk"),
            path: "snapshot.chunk.data", maxBytes: WireLimits.maxRawChunkBytes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(snapshotID, forKey: WireKey(Field.snapshotID))
        try container.encode(index, forKey: WireKey(Field.index))
        try container.encode(data.base64EncodedString(), forKey: WireKey(Field.data))
    }
}

struct WireSnapshotEnd: Equatable, Sendable, Codable {
    var epoch: String
    var snapshotID: String

    private enum Field {
        static let type = "type", epoch = "epoch", snapshotID = "snapshot_id"
        static let all: Set<String> = [type, epoch, snapshotID]
    }

    static let typeName = "snapshot.end"

    init(epoch: String, snapshotID: String) {
        self.epoch = epoch
        self.snapshotID = snapshotID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "snapshot.end")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "snapshot.end"),
            path: "snapshot.end.epoch"))
        self.snapshotID = try WireValue.uuid(
            try container.require(String.self, Field.snapshotID, path: "snapshot.end"),
            path: "snapshot.end.snapshot_id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(snapshotID, forKey: WireKey(Field.snapshotID))
    }
}

/// Every frame the protocol has, as one type, so the direction check and the size check happen in
/// one place instead of once per handler.
enum WireFrame: Equatable, Sendable {
    case auth(WireAuth)
    case hello(WireHello)
    case resume(WireResume)
    case resync(WireResync)
    case outputAck(WireOutputAck)
    case error(WireErrorFrame)
    case inputAck(WireInputAck)
    case snapshotBegin(WireSnapshotBegin)
    case snapshotChunk(WireSnapshotChunk)
    case snapshotEnd(WireSnapshotEnd)
    case damage(WireDamage)
    case input(WireInputFrame)
    case controlRequest(WireControlRequest)
    case controlGranted(WireControlGranted)
    case controlDenied(WireControlDenied)
    case controlRevoked(WireControlRevoked)
    case viewerCount(WireViewerCount)

    var typeName: String {
        switch self {
        case .auth: WireAuth.typeName
        case .hello: WireHello.typeName
        case .resume: WireResume.typeName
        case .resync: WireResync.typeName
        case .outputAck: WireOutputAck.typeName
        case .error: WireErrorFrame.typeName
        case .inputAck: WireInputAck.typeName
        case .snapshotBegin: WireSnapshotBegin.typeName
        case .snapshotChunk: WireSnapshotChunk.typeName
        case .snapshotEnd: WireSnapshotEnd.typeName
        case .damage: WireDamage.typeName
        case .input: WireInputFrame.typeName
        case .controlRequest: WireControlRequest.typeName
        case .controlGranted: WireControlGranted.typeName
        case .controlDenied: WireControlDenied.typeName
        case .controlRevoked: WireControlRevoked.typeName
        case .viewerCount: WireViewerCount.typeName
        }
    }

    var directions: [WireDirection] {
        switch self {
        case .auth: [.hostToRelay, .viewerToRelay]
        case .hello: [.relayToHost, .relayToViewer]
        case .resume: [.viewerToRelay]
        case .resync: [.viewerToRelay, .relayToHost]
        case .outputAck: [.viewerToRelay, .relayToHost]
        case .error: WireDirection.allCases
        case .inputAck: [.hostToRelay, .relayToViewer]
        case .snapshotBegin, .snapshotChunk, .snapshotEnd, .damage:
            [.hostToRelay, .relayToViewer]
        case .input, .controlRequest: [.viewerToRelay, .relayToHost]
        case .controlGranted, .controlDenied, .controlRevoked:
            [.hostToRelay, .relayToViewer]
        case .viewerCount: [.relayToHost]
        }
    }
}

extension WireFrame: Codable {
    private enum Field {
        static let type = "type"
    }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: WireKey.self)
        guard let type = try probe.decodeIfPresent(String.self, forKey: WireKey(Field.type)) else {
            throw WireError.missingField(path: "$", field: Field.type)
        }
        switch type {
        case WireAuth.typeName: self = .auth(try WireAuth(from: decoder))
        case WireHello.typeName: self = .hello(try WireHello(from: decoder))
        case WireResume.typeName: self = .resume(try WireResume(from: decoder))
        case WireResync.typeName: self = .resync(try WireResync(from: decoder))
        case WireOutputAck.typeName: self = .outputAck(try WireOutputAck(from: decoder))
        case WireErrorFrame.typeName: self = .error(try WireErrorFrame(from: decoder))
        case WireInputAck.typeName: self = .inputAck(try WireInputAck(from: decoder))
        case WireSnapshotBegin.typeName: self = .snapshotBegin(try WireSnapshotBegin(from: decoder))
        case WireSnapshotChunk.typeName: self = .snapshotChunk(try WireSnapshotChunk(from: decoder))
        case WireSnapshotEnd.typeName: self = .snapshotEnd(try WireSnapshotEnd(from: decoder))
        case WireDamage.typeName: self = .damage(try WireDamage(from: decoder))
        case WireInputFrame.typeName: self = .input(try WireInputFrame(from: decoder))
        case WireControlRequest.typeName:
            self = .controlRequest(try WireControlRequest(from: decoder))
        case WireControlGranted.typeName:
            self = .controlGranted(try WireControlGranted(from: decoder))
        case WireControlDenied.typeName: self = .controlDenied(try WireControlDenied(from: decoder))
        case WireControlRevoked.typeName:
            self = .controlRevoked(try WireControlRevoked(from: decoder))
        case WireViewerCount.typeName: self = .viewerCount(try WireViewerCount(from: decoder))
        default:
            throw WireError.invalidValue(path: "type", reason: "unknown frame \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .auth(frame): try frame.encode(to: encoder)
        case let .hello(frame): try frame.encode(to: encoder)
        case let .resume(frame): try frame.encode(to: encoder)
        case let .resync(frame): try frame.encode(to: encoder)
        case let .outputAck(frame): try frame.encode(to: encoder)
        case let .error(frame): try frame.encode(to: encoder)
        case let .inputAck(frame): try frame.encode(to: encoder)
        case let .snapshotBegin(frame): try frame.encode(to: encoder)
        case let .snapshotChunk(frame): try frame.encode(to: encoder)
        case let .snapshotEnd(frame): try frame.encode(to: encoder)
        case let .damage(frame): try frame.encode(to: encoder)
        case let .input(frame): try frame.encode(to: encoder)
        case let .controlRequest(frame): try frame.encode(to: encoder)
        case let .controlGranted(frame): try frame.encode(to: encoder)
        case let .controlDenied(frame): try frame.encode(to: encoder)
        case let .controlRevoked(frame): try frame.encode(to: encoder)
        case let .viewerCount(frame): try frame.encode(to: encoder)
        }
    }
}

extension WireFrame {
    /// Decode one frame from one direction. Size is checked first: an oversized frame is refused
    /// before a parser is allowed to walk it.
    static func decode(from data: Data, direction: WireDirection) throws -> WireFrame {
        guard data.count <= WireLimits.maxFrameBytes else {
            throw WireError.oversized(
                path: "frame", limit: WireLimits.maxFrameBytes, actual: data.count)
        }
        let frame = try WireCanonicalJSON.decode(WireFrame.self, from: data)
        try frame.validateDirection(direction)
        return frame
    }

    static func decode(from text: String, direction: WireDirection) throws -> WireFrame {
        guard let data = text.data(using: .utf8) else {
            throw WireError.malformedFrame(reason: "not UTF-8")
        }
        return try decode(from: data, direction: direction)
    }

    func validateDirection(_ direction: WireDirection) throws {
        guard directions.contains(direction) else {
            throw WireError.malformedFrame(
                reason: "\(typeName) may not travel \(direction)")
        }
    }
}
