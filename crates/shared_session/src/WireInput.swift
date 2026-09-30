import Foundation

/// The keys a browser may name. A key is a named intent, not a byte: the host maps it through the
/// same paths its own keyboard uses, so a browser cannot inject an escape sequence.
enum WireInputKey: String, Sendable, CaseIterable, Codable {
    case enter, tab, backspace, delete, escape
    case arrowUp = "arrow_up", arrowDown = "arrow_down"
    case arrowLeft = "arrow_left", arrowRight = "arrow_right"
    case home, end, pageUp = "page_up", pageDown = "page_down"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    /// Listed rather than ranged: a `String`-backed enum is not `Comparable`, and the case order
    /// is not the alphabet anyway.
    private static let letterKeys: Set<WireInputKey> = [
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
        .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
    ]

    var isLetter: Bool { Self.letterKeys.contains(self) }
}

enum WireModifier: String, Sendable, CaseIterable, Codable {
    case shift, control, alt, meta
}

/// The exact input union. There is no raw-bytes case, no mouse case and no resize case: the host
/// owns geometry, and a paste is text the editor places rather than bytes the PTY receives.
enum WireInputOperation: Equatable, Sendable {
    case text(String)
    case paste(String)
    case key(WireInputKey, [WireModifier])
    case undo
    case redo

    var name: String {
        switch self {
        case .text: "text"
        case .paste: "paste"
        case .key: "key"
        case .undo: "undo"
        case .redo: "redo"
        }
    }
}

extension WireInputOperation: Codable {
    private enum Field {
        static let kind = "kind", text = "text", key = "key", modifiers = "modifiers"
        static let textSet: Set<String> = [kind, text]
        static let keySet: Set<String> = [kind, key, modifiers]
        static let bareSet: Set<String> = [kind]
    }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: WireKey.self)
        guard let kind = try probe.decodeIfPresent(String.self, forKey: WireKey(Field.kind)) else {
            throw WireError.missingField(path: "operation", field: Field.kind)
        }
        let path = "operation.\(kind)"
        let container = try decoder.container(keyedBy: WireKey.self)

        switch kind {
        case "text", "paste":
            try container.rejectUnknown(known: Field.textSet, path: path)
            let raw = try container.require(String.self, Field.text, path: path)
            let text = try Self.validateText(raw, path: "\(path).text")
            self = kind == "text" ? .text(text) : .paste(text)
        case "key":
            try container.rejectUnknown(known: Field.keySet, path: path)
            let key = try container.require(WireInputKey.self, Field.key, path: path)
            let modifiers = try container.require([WireModifier].self, Field.modifiers, path: path)
            self = .key(key, try Self.validateModifiers(modifiers, key: key, path: path))
        case "undo":
            try container.rejectUnknown(known: Field.bareSet, path: path)
            self = .undo
        case "redo":
            try container.rejectUnknown(known: Field.bareSet, path: path)
            self = .redo
        default:
            throw WireError.invalidValue(path: "operation", reason: "unknown kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(name, forKey: WireKey(Field.kind))
        switch self {
        case let .text(text), let .paste(text):
            try container.encode(text, forKey: WireKey(Field.text))
        case let .key(key, modifiers):
            try container.encode(key, forKey: WireKey(Field.key))
            try container.encode(modifiers, forKey: WireKey(Field.modifiers))
        case .undo, .redo:
            break
        }
    }

    /// Text is an IME committed insertion. CR and LF are preserved exactly as sent and no Enter is
    /// appended; NUL is refused because it is not a text scalar and would truncate a C string.
    static func validateText(_ text: String, path: String) throws -> String {
        _ = try WireValue.utf8(text, path: path, limit: WireLimits.maxInputBytes)
        guard !text.utf8.contains(0) else {
            throw WireError.invalidValue(path: path, reason: "NUL in text")
        }
        return text
    }

    /// Modifiers are unique and a bare letter is refused: an unmodified letter is text, and a
    /// layout guess is exactly what the contract forbids.
    static func validateModifiers(
        _ modifiers: [WireModifier], key: WireInputKey, path: String
    ) throws -> [WireModifier] {
        var seen = Set<WireModifier>()
        for modifier in modifiers {
            guard seen.insert(modifier).inserted else {
                throw WireError.invalidValue(
                    path: "\(path).modifiers", reason: "duplicate \(modifier.rawValue)")
            }
        }
        if key.isLetter {
            let chords = seen.intersection([.control, .alt, .meta])
            guard !chords.isEmpty else {
                throw WireError.unsupportedInput(
                    reason: "letter key needs a control, alt or meta chord")
            }
        }
        return modifiers
    }
}

/// One input frame on the control lease. `input_seq` is per lease, not the terminal output seq.
struct WireInputFrame: Equatable, Sendable, Codable {
    var epoch: String
    var controlLease: String
    var inputSeq: String
    var operation: WireInputOperation

    private enum Field {
        static let type = "type"
        static let epoch = "epoch", lease = "control_lease"
        static let inputSeq = "input_seq", operation = "operation"
        static let all: Set<String> = [type, epoch, lease, inputSeq, operation]
    }

    static let typeName = "input"

    init(epoch: String, controlLease: String, inputSeq: String, operation: WireInputOperation) {
        self.epoch = epoch
        self.controlLease = controlLease
        self.inputSeq = inputSeq
        self.operation = operation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "input")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "input"), path: "input.epoch"))
        self.controlLease = try WireValue.uuid(
            try container.require(String.self, Field.lease, path: "input"),
            path: "input.control_lease")
        self.inputSeq = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.inputSeq, path: "input"),
            path: "input.input_seq"))
        self.operation = try container.require(
            WireInputOperation.self, Field.operation, path: "input")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(controlLease, forKey: WireKey(Field.lease))
        try container.encode(inputSeq, forKey: WireKey(Field.inputSeq))
        try container.encode(operation, forKey: WireKey(Field.operation))
    }
}

enum WireInputStatus: String, Sendable, CaseIterable, Codable {
    case applied, rejected
}

/// An acknowledgement means the host accepted the input into its editor or PTY write queue. It
/// never means a command ran, and no peer retries an unacknowledged input.
struct WireInputAck: Equatable, Sendable, Codable {
    var epoch: String
    var controlLease: String
    var inputSeq: String
    var status: WireInputStatus
    var code: WireErrorCode?

    private enum Field {
        static let type = "type"
        static let epoch = "epoch", lease = "control_lease"
        static let inputSeq = "input_seq", status = "status", code = "code"
        static let all: Set<String> = [type, epoch, lease, inputSeq, status, code]
    }

    static let typeName = "input.ack"

    init(
        epoch: String, controlLease: String, inputSeq: String, status: WireInputStatus,
        code: WireErrorCode? = nil
    ) {
        self.epoch = epoch
        self.controlLease = controlLease
        self.inputSeq = inputSeq
        self.status = status
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "input.ack")
        self.epoch = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.epoch, path: "input.ack"),
            path: "input.ack.epoch"))
        self.controlLease = try WireValue.uuid(
            try container.require(String.self, Field.lease, path: "input.ack"),
            path: "input.ack.control_lease")
        self.inputSeq = String(try WireValue.positiveCounter(
            try container.require(String.self, Field.inputSeq, path: "input.ack"),
            path: "input.ack.input_seq"))
        self.status = try container.require(WireInputStatus.self, Field.status, path: "input.ack")
        self.code = try container.optional(WireErrorCode.self, Field.code)
        guard status == .applied || code != nil else {
            throw WireError.invalidValue(
                path: "input.ack", reason: "a rejected input must carry a code")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(Self.typeName, forKey: WireKey(Field.type))
        try container.encode(epoch, forKey: WireKey(Field.epoch))
        try container.encode(controlLease, forKey: WireKey(Field.lease))
        try container.encode(inputSeq, forKey: WireKey(Field.inputSeq))
        try container.encode(status, forKey: WireKey(Field.status))
        try container.encodeIfPresent(code, forKey: WireKey(Field.code))
    }
}
