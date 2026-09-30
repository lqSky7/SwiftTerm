import Foundation

/// Static-export DTOs. An export is immutable content, not a live session: it carries explicit
/// line text and allowlisted style spans, and it deliberately has no editor, no grid controls, no
/// images, no links and no live identifiers.
///
/// These types reuse the value rules in `crates/shared_session/src` rather than restating them,
/// because a style index means the same thing in a snapshot and in an export. Both crates are
/// compiled into the same contract target and the same Foundation-only harness.

/// `{start,length,style}` in UTF-16 offsets — the offsets a browser string actually uses.
struct WireShareSpan: Equatable, Sendable, Codable {
    var start: Int
    var length: Int
    var style: Int

    private enum Field {
        static let start = "start", length = "length", style = "style"
        static let all: Set<String> = [start, length, style]
    }

    init(start: Int, length: Int, style: Int) {
        self.start = start
        self.length = length
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "span")
        self.start = try WireValue.safeInteger(
            try container.require(Int.self, Field.start, path: "span"), path: "span.start")
        self.length = try WireValue.safeInteger(
            try container.require(Int.self, Field.length, path: "span"), path: "span.length",
            range: 1...WireLimits.maxSafeInteger)
        self.style = try WireValue.safeInteger(
            try container.require(Int.self, Field.style, path: "span"), path: "span.style",
            range: 0...WireLimits.maxStyleIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(start, forKey: WireKey(Field.start))
        try container.encode(length, forKey: WireKey(Field.length))
        try container.encode(style, forKey: WireKey(Field.style))
    }
}

/// One exported line: the text, plus the spans that style it. `text` is data and is escaped when
/// rendered; it is never markup.
struct WireShareLine: Equatable, Sendable, Codable {
    var text: String
    var spans: [WireShareSpan]

    private enum Field {
        static let text = "text", spans = "spans"
        static let all: Set<String> = [text, spans]
    }

    init(text: String, spans: [WireShareSpan] = []) {
        self.text = text
        self.spans = spans
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "line")
        self.text = try container.require(String.self, Field.text, path: "line")
        self.spans = try container.require([WireShareSpan].self, Field.spans, path: "line")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(text, forKey: WireKey(Field.text))
        try container.encode(spans, forKey: WireKey(Field.spans))
    }

    /// A line is one line. A newline inside `text` would mean the export has no line model at all,
    /// and the C0/C1/bidi controls are either invisible or a spoof. Tab survives: it is drawn.
    func validate(path: String, styleCount: Int) throws {
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A || scalar.value == 0x0D {
                throw WireError.invalidValue(
                    path: "\(path).text", reason: "newline inside an exported line")
            }
            if scalar.value == 0x09 { continue }
            for range in WireValue.forbiddenScalars where range.contains(scalar.value) {
                throw WireError.invalidValue(
                    path: "\(path).text", reason: "control scalar U+\(String(scalar.value, radix: 16))")
            }
        }
        let units = text.utf16.count
        var previousEnd = 0
        for (index, span) in spans.enumerated() {
            let spanPath = "\(path).spans[\(index)]"
            guard span.start >= previousEnd else {
                throw WireError.outOfBounds(
                    path: spanPath, reason: "overlaps or is out of order at \(span.start)")
            }
            let end = span.start + span.length
            guard end <= units else {
                throw WireError.outOfBounds(
                    path: spanPath, reason: "ends at \(end) of \(units) UTF-16 units")
            }
            guard span.style < styleCount else {
                throw WireError.outOfBounds(
                    path: "\(spanPath).style", reason: "style \(span.style) of \(styleCount)")
            }
            previousEnd = end
        }
    }
}

/// One sealed block. `id` is the export identity, minted for the export rather than reused from a
/// live session.
struct WireShareBlock: Equatable, Sendable, Codable {
    var id: String
    var command: String
    var state: WireBlockState
    var exitCode: Int?
    var durationMS: Int?
    var lines: [WireShareLine]

    private enum Field {
        static let id = "id", command = "command", state = "state"
        static let exitCode = "exit_code", duration = "duration_ms", lines = "lines"
        static let all: Set<String> = [id, command, state, exitCode, duration, lines]
    }

    init(
        id: String, command: String, state: WireBlockState = .sealed, exitCode: Int? = nil,
        durationMS: Int? = nil, lines: [WireShareLine]
    ) {
        self.id = id
        self.command = command
        self.state = state
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "share.block")
        self.id = try WireValue.uuid(
            try container.require(String.self, Field.id, path: "share.block"),
            path: "share.block.id")
        self.command = try container.require(String.self, Field.command, path: "share.block")
        self.state = try container.require(WireBlockState.self, Field.state, path: "share.block")
        self.exitCode = try container.optional(Int.self, Field.exitCode).map {
            try WireValue.signedInt32($0, path: "share.block.exit_code")
        }
        self.durationMS = try container.optional(Int.self, Field.duration).map {
            try WireValue.safeInteger($0, path: "share.block.duration_ms")
        }
        self.lines = try container.require([WireShareLine].self, Field.lines, path: "share.block")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(id, forKey: WireKey(Field.id))
        try container.encode(command, forKey: WireKey(Field.command))
        try container.encode(state, forKey: WireKey(Field.state))
        try container.encodeIfPresent(exitCode, forKey: WireKey(Field.exitCode))
        try container.encodeIfPresent(durationMS, forKey: WireKey(Field.duration))
        try container.encode(lines, forKey: WireKey(Field.lines))
    }

    func validate(path: String, styleCount: Int) throws {
        try WireValue.utf8(command, path: "\(path).command", limit: WireLimits.maxCommandBytes)
        for scalar in command.unicodeScalars where scalar.value == 0x0A || scalar.value == 0x0D {
            throw WireError.invalidValue(path: "\(path).command", reason: "command is not one line")
        }
        for (index, line) in lines.enumerated() {
            try line.validate(path: "\(path).lines[\(index)]", styleCount: styleCount)
        }
    }
}

/// The exported document. `directory` is an abbreviated display label the owner approved in the
/// native preview; an absolute path is refused rather than silently exported.
struct WireShareSnapshot: Equatable, Sendable, Codable {
    var schemaVersion: Int
    var snapshotID: String
    var styles: [WireStyle]
    var blocks: [WireShareBlock]
    var directory: String?

    private enum Field {
        static let schemaVersion = "schema_version", snapshotID = "snapshot_id"
        static let styles = "styles", blocks = "blocks", directory = "directory"
        static let all: Set<String> = [schemaVersion, snapshotID, styles, blocks, directory]
    }

    static let currentSchemaVersion = 1

    init(
        schemaVersion: Int = WireShareSnapshot.currentSchemaVersion, snapshotID: String,
        styles: [WireStyle], blocks: [WireShareBlock], directory: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotID = snapshotID
        self.styles = styles
        self.blocks = blocks
        self.directory = directory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try container.rejectUnknown(known: Field.all, path: "share")
        let version = try container.require(Int.self, Field.schemaVersion, path: "share")
        guard version == Self.currentSchemaVersion else {
            throw WireError.unsupportedVersion(got: version)
        }
        self.schemaVersion = version
        self.snapshotID = try WireValue.uuid(
            try container.require(String.self, Field.snapshotID, path: "share"),
            path: "share.snapshot_id")
        self.styles = try container.require([WireStyle].self, Field.styles, path: "share")
        self.blocks = try container.require([WireShareBlock].self, Field.blocks, path: "share")
        self.directory = try container.optional(String.self, Field.directory)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(schemaVersion, forKey: WireKey(Field.schemaVersion))
        try container.encode(snapshotID, forKey: WireKey(Field.snapshotID))
        try container.encode(styles, forKey: WireKey(Field.styles))
        try container.encode(blocks, forKey: WireKey(Field.blocks))
        try container.encodeIfPresent(directory, forKey: WireKey(Field.directory))
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WireError.unsupportedVersion(got: schemaVersion)
        }
        _ = try WireValue.uuid(snapshotID, path: "share.snapshot_id")
        guard !styles.isEmpty, styles.count <= WireLimits.maxStyles else {
            throw WireError.outOfBounds(
                path: "share.styles", reason: "\(styles.count) styles")
        }
        guard blocks.count <= WireLimits.maxShareBlocks else {
            throw WireError.oversized(
                path: "share.blocks", limit: WireLimits.maxShareBlocks, actual: blocks.count)
        }
        var identifiers = Set<String>()
        for (index, block) in blocks.enumerated() {
            guard identifiers.insert(block.id).inserted else {
                throw WireError.duplicateID(block.id)
            }
            try block.validate(path: "share.blocks[\(index)]", styleCount: styles.count)
        }
        if let directory {
            try Self.validateDirectory(directory)
        }
        let bytes = try WireCanonicalJSON.encode(self).count
        guard bytes <= WireLimits.maxShareBytes else {
            throw WireError.oversized(
                path: "share", limit: WireLimits.maxShareBytes, actual: bytes)
        }
    }

    /// The directory label is a display string the owner saw in the preview. An absolute path is
    /// the implicit full-path export the contract forbids, so it is rejected here rather than
    /// abbreviated silently.
    static func validateDirectory(_ directory: String) throws {
        try WireValue.utf8(directory, path: "share.directory", limit: 256)
        guard !directory.hasPrefix("/") else {
            throw WireError.invalidValue(
                path: "share.directory", reason: "absolute path in an export label")
        }
        guard !directory.hasPrefix("~") else {
            throw WireError.invalidValue(
                path: "share.directory", reason: "home path in an export label")
        }
        for component in directory.split(separator: "/") where component == ".." {
            throw WireError.invalidValue(
                path: "share.directory", reason: "traversal in an export label")
        }
    }
}

/// The share capability: 32 random bytes the client generates and retains, base64url without
/// padding. The server stores only the SHA-256, and the secret lives in the browser fragment.
struct WireShareCapability: Equatable, Sendable {
    static let byteCount = 32
    static let encodedLength = 43

    /// A canonical base64url secret. Padding, `+`, `/` and a wrong length are all refused: the
    /// digest the server compares is over one spelling, not over whatever a client sent.
    static func isValid(_ secret: String) -> Bool {
        let scalars = Array(secret.unicodeScalars)
        guard scalars.count == encodedLength else { return false }
        var last = -1
        for scalar in scalars {
            guard let value = value(of: scalar) else { return false }
            last = value
        }
        // 32 bytes is 256 bits, and 43 base64url characters hold 258. The final character
        // therefore encodes only the top four bits of the last byte, so its low two bits must be
        // zero. A larger value is a second spelling of the same 32 bytes, and the server compares
        // a digest of one spelling.
        return last % 4 == 0
    }

    private static func value(of scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 65...90: Int(scalar.value - 65)
        case 97...122: Int(scalar.value - 97) + 26
        case 48...57: Int(scalar.value - 48) + 52
        case 45: 62  // -
        case 95: 63  // _
        default: nil
        }
    }

    static func digestHex(_ secret: String) -> String {
        WireSHA256.hexDigest(Data(secret.utf8))
    }
}
