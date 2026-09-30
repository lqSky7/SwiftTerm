import Foundation

// The C0 gate. This harness is deliberately self-contained and Foundation-only: it compiles
// `crates/shared_session/src` and `crates/cloud_objects/src` and nothing else, so a transport DTO
// that reached for TerminalGrid, Block, NSTextView or AppKit would stop it compiling. That is the
// same trick the rest of Tests/ uses for the pure model layers, applied to the wire format.
//
// Run with `--write-fixtures` to regenerate contracts/fixtures/golden from the Swift DTOs. The
// checked-in bytes are then verified by both this harness and the TypeScript validators, which is
// what makes "the same logical snapshot produces the same bytes on both sides" a test rather than
// a hope.

final class Checks {
    private var checks = 0
    private var failures: [String] = []

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("line \(line): \(message())")
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: UInt = #line) {
        expect(actual == expected, "\(label): expected \(expected), got \(actual)", line: line)
    }

    /// Assert that a block is rejected with a specific allowlisted code. Comparing the code rather
    /// than the message is the point: the code is what travels, the message is local.
    func rejects(
        _ label: String, _ expected: WireErrorCode, line: UInt = #line, _ body: () throws -> Void
    ) {
        checks += 1
        do {
            try body()
            failures.append("line \(line): \(label): expected \(expected), nothing thrown")
        } catch let error as WireError {
            guard error.code == expected else {
                failures.append(
                    "line \(line): \(label): expected \(expected), got \(error.code) — "
                        + error.diagnostic)
                return
            }
        } catch {
            failures.append("line \(line): \(label): unexpected error \(error)")
        }
    }

    func accepts(_ label: String, line: UInt = #line, _ body: () throws -> Void) {
        checks += 1
        do {
            try body()
        } catch {
            failures.append("line \(line): \(label): rejected (\(error))")
        }
    }

    func finish() -> Never {
        guard failures.isEmpty else {
            print("✗ wire-contract-test: \(failures.count) of \(checks) checks failed")
            for failure in failures { print("    \(failure)") }
            exit(1)
        }
        print("✓ wire-contract-test: \(checks) checks passed")
        exit(0)
    }
}

// MARK: - Fixture builders

/// Repository root, from this file's own path, so the harness runs from anywhere.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let goldenDirectory = repositoryRoot.appendingPathComponent("contracts/fixtures/golden")

let defaultStyle = WireStyle(fg: .palette(index: 7), bg: .palette(index: 0), flags: 0)
let accentStyle = WireStyle(
    fg: .rgb(r: 255, g: 128, b: 0), bg: .palette(index: 0), flags: 0b0000_0001)
let fixtureStyles = [defaultStyle, accentStyle]

/// The ranges the fixture needs: CJK and emoji render two cells wide. A real capture asks the
/// emulator; a fixture only needs to be unambiguous about which cells are wide.
func isWide(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
        0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
        true
    default:
        false
    }
}

/// A row of exactly `columns` cells. Wide scalars get their continuation cell, which is the only
/// way to build a row the validator accepts.
func row(_ text: String, columns: Int, style: Int = 1) -> WireRow {
    var cells: [WireCell] = []
    for character in text {
        let wide = character.unicodeScalars.first.map(isWide) ?? false
        if wide {
            cells.append(WireCell(text: String(character), width: 2, style: style))
            cells.append(WireCell(text: "", width: 0, style: style))
        } else {
            cells.append(WireCell(text: String(character), width: 1, style: style))
        }
    }
    while cells.count < columns { cells.append(WireCell(text: " ", width: 1, style: 0)) }
    return WireRow(cells: Array(cells.prefix(columns)))
}

func emptyGrid() -> WireGrid {
    WireGrid(
        lines: [],
        cursor: WireCursor(row: 0, column: 0, visible: false, shape: .bar, blink: false))
}

func grid(
    _ lines: [String], columns: Int, cursorRow: Int = 0, cursorColumn: Int = 0,
    cursorVisible: Bool = true
) -> WireGrid {
    guard !lines.isEmpty else { return emptyGrid() }
    return WireGrid(
        lines: lines.map { row($0, columns: columns) },
        cursor: WireCursor(
            row: min(cursorRow, lines.count - 1), column: cursorColumn, visible: cursorVisible,
            shape: .block, blink: false))
}

let firstBlockID = "11111111-1111-4111-8111-111111111111"
let secondBlockID = "22222222-2222-4222-8222-222222222222"
let thirdBlockID = "33333333-3333-4333-8333-333333333333"
let snapshotID = "44444444-4444-4444-8444-444444444444"
let leaseID = "55555555-5555-4555-8555-555555555555"
let sessionID = "66666666-6666-4666-8666-666666666666"
let clientID = "77777777-7777-4777-8777-777777777777"
/// Carries hex letters, so an uppercasing bug is actually observable.
let letteredUUID = "abcdefab-cdef-4abc-8def-abcdefabcdef"

/// A snapshot with the awkward cases in it: a wide glyph, a combining sequence, an emoji ZWJ
/// sequence, an empty grid, a collapsed block and a non-default style.
func sampleSnapshot(mode: WireMode = .blocks, columns: Int = 40, rows: Int = 12) -> WireSnapshot {
    let output = grid(
        ["total 8", "drwxr-xr-x  \u{4E16}\u{754C}", "caf\u{00E9} \u{1F469}\u{200D}\u{1F4BB} ok"],
        columns: columns, cursorRow: 2, cursorColumn: 8)
    let blocks = [
        WireBlock(
            id: firstBlockID, command: "ls -la", state: .sealed, collapsed: false,
            header: grid(["ls -la"], columns: columns, cursorRow: 0, cursorColumn: 6),
            output: output, exitCode: 0, durationMS: 12),
        WireBlock(
            id: secondBlockID, command: "echo ready", state: .draft, collapsed: true,
            header: grid(["echo ready"], columns: columns, cursorRow: 0, cursorColumn: 10),
            output: emptyGrid()),
    ]
    return WireSnapshot(
        epoch: "1", seq: "0", mode: mode, columns: columns, rows: rows, styles: fixtureStyles,
        blocks: mode == .fullscreen ? [blocks[0]] : blocks,
        viewport: WireViewport(
            firstBlockID: firstBlockID, firstLine: 0,
            pinnedBlockID: mode == .fullscreen ? firstBlockID : secondBlockID),
        editor: mode == .fullscreen
            ? WireEditor(visible: false, text: "", selectionStart: 0, selectionLength: 0)
            : WireEditor(visible: true, text: "echo ", selectionStart: 5, selectionLength: 0))
}

func sampleShare() -> WireShareSnapshot {
    WireShareSnapshot(
        snapshotID: snapshotID, styles: fixtureStyles,
        blocks: [
            WireShareBlock(
                id: firstBlockID, command: "ls -la", state: .sealed, exitCode: 0, durationMS: 12,
                lines: [
                    WireShareLine(text: "total 8"),
                    WireShareLine(
                        text: "drwxr-xr-x  \u{4E16}\u{754C}",
                        spans: [WireShareSpan(start: 0, length: 10, style: 1)]),
                    WireShareLine(text: "caf\u{00E9} \u{1F469}\u{200D}\u{1F4BB} ok"),
                ]),
            WireShareBlock(id: secondBlockID, command: "echo ready", lines: []),
        ],
        directory: "swiftTerm")
}

// The harness is single-threaded: `main` runs the sections in order and `finish` exits.
nonisolated(unsafe) let checks = Checks()
let writingFixtures = CommandLine.arguments.contains("--write-fixtures")

/// Golden bytes are generated once and verified from then on. Regeneration is explicit, so a
/// contract change that alters the bytes is a visible diff rather than a silently updated hash.
///
/// `SHA256SUMS` is written from the same bytes, and the TypeScript checker verifies it against its
/// own SHA-256. That is the "hashed identically by Swift and Node" requirement made mechanical:
/// two independent implementations, one recorded digest.
func checkGolden() {
    let files: [(name: String, data: Data)] = [
        ("snapshot-blocks.json", snapshotBytes(sampleSnapshot())),
        ("snapshot-fullscreen.json", snapshotBytes(sampleSnapshot(mode: .fullscreen))),
        ("share.json", (try? WireCanonicalJSON.encode(sampleShare())) ?? Data()),
    ]
    var sums: [String] = []
    for file in files {
        checks.expect(!file.data.isEmpty, "\(file.name) encodes to bytes")
        sums.append("\(WireSHA256.hexDigest(file.data))  \(file.name)")
        let path = goldenDirectory.appendingPathComponent(file.name)
        if writingFixtures {
            try? FileManager.default.createDirectory(
                at: goldenDirectory, withIntermediateDirectories: true)
            try? file.data.write(to: path)
            print(
                "wrote \(file.name) — \(file.data.count) bytes — \(WireSHA256.hexDigest(file.data))")
            continue
        }
        guard let expected = try? Data(contentsOf: path), !expected.isEmpty else {
            checks.expect(false, "\(file.name) missing; run the harness with --write-fixtures")
            continue
        }
        checks.expect(
            file.data == expected, "\(file.name) differs from the checked-in golden bytes")
    }

    let sumsText = sums.joined(separator: "\n") + "\n"
    let sumsPath = goldenDirectory.appendingPathComponent("SHA256SUMS")
    if writingFixtures {
        try? sumsText.write(to: sumsPath, atomically: true, encoding: .utf8)
        print("wrote SHA256SUMS")
        return
    }
    let recorded = (try? String(contentsOf: sumsPath, encoding: .utf8)) ?? ""
    checks.expect(
        recorded == sumsText,
        "SHA256SUMS differs from the golden bytes — regenerate the fixtures deliberately")
}

/// The bytes a producer would advertise in `snapshot.begin`.
func snapshotBytes(_ snapshot: WireSnapshot) -> Data {
    (try? WireCanonicalJSON.encode(snapshot)) ?? Data()
}

func encode<T: Encodable>(_ value: T) -> String {
    (try? WireCanonicalJSON.string(value)) ?? ""
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try WireCanonicalJSON.decode(type, from: text)
}

// MARK: - 1. Canonical encoding

func checkCanonicalEncoding() {
    let snapshot = sampleSnapshot()
    let first = snapshotBytes(snapshot)
    let second = snapshotBytes(snapshot)
    checks.expect(!first.isEmpty, "snapshot encodes to bytes")
    checks.expect(first == second, "encoding is deterministic")

    let text = String(decoding: first, as: UTF8.self)
    checks.expect(text.hasPrefix("{\"blocks\":["), "keys are sorted: \(text.prefix(24))")
    checks.expect(!text.contains("\\/"), "slashes are not escaped")

    // Sorted keys means a peer re-serialising the same tree with sorted keys reproduces the bytes.
    let reparsed = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any]
    checks.expect(reparsed != nil, "golden bytes are valid JSON")

    let digest = WireSHA256.hexDigest(first)
    checks.equal(digest.count, 64, "digest length")
    checks.equal(
        WireSHA256.hexDigest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "SHA-256 of empty input")
    checks.equal(
        WireSHA256.hexDigest(Data("abc".utf8)),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256 of abc")
}

// MARK: - 2. Round trips

func checkRoundTrips() {
    let snapshot = sampleSnapshot()
    checks.accepts("snapshot validates") { try snapshot.validate() }
    guard let decoded = try? decode(WireSnapshot.self, encode(snapshot)) else {
        checks.expect(false, "snapshot round trip")
        return
    }
    checks.equal(decoded, snapshot, "snapshot round trip")
    checks.equal(
        WireSHA256.hexDigest(snapshotBytes(decoded)),
        WireSHA256.hexDigest(snapshotBytes(snapshot)), "snapshot digest")

    let fullscreen = sampleSnapshot(mode: .fullscreen)
    checks.accepts("fullscreen snapshot validates") { try fullscreen.validate() }
    checks.equal(
        try? decode(WireSnapshot.self, encode(fullscreen)), fullscreen,
        "fullscreen snapshot round trip")

    let share = sampleShare()
    checks.accepts("share validates") { try share.validate() }
    checks.equal(try? decode(WireShareSnapshot.self, encode(share)), share, "share round trip")

    let editor = WireEditor(visible: true, text: "a\u{1F600}b", selectionStart: 1, selectionLength: 2)
    checks.accepts("editor selection spans a surrogate pair") { try editor.validate(path: "editor") }

    // Frames that carry no optionals must not grow a null when a field is absent.
    let denied = WireControlDenied(epoch: "3")
    let deniedText = encode(WireFrame.controlDenied(denied))
    checks.expect(!deniedText.contains("null"), "absent fields are omitted: \(deniedText)")

    let ack = WireInputAck(
        epoch: "2", controlLease: leaseID, inputSeq: "4", status: .rejected, code: .rateLimited)
    checks.equal(
        try? decode(WireFrame.self, encode(WireFrame.inputAck(ack))), .inputAck(ack),
        "input ack round trip")
}

// MARK: - 3. Golden bytes
// `checkGolden` lives with the fixture builders above, because it is the writer as well as the
// verifier.

// MARK: - 4. Version and framing

func checkVersionAndFraming() {
    checks.rejects("snapshot version 2", .unsupportedVersion) {
        _ = try decode(WireSnapshot.self, encode(sampleSnapshot()).replacingOccurrences(
            of: "\"version\":1", with: "\"version\":2"))
    }
    checks.rejects("hello version 0", .unsupportedVersion) {
        _ = try decode(
            WireHello.self,
            #"{"type":"hello","version":0,"session_id":"\#(sessionID)","epoch":"1","#
                + #""mode":"blocks","columns":80,"rows":24}"#)
    }
    checks.rejects("unknown frame type", .invalidFrame) {
        _ = try decode(WireFrame.self, #"{"type":"teleport"}"#)
    }
    checks.rejects("missing type", .invalidFrame) {
        _ = try decode(WireFrame.self, #"{"epoch":"1"}"#)
    }
    checks.rejects("frame over 64 KiB", .invalidFrame) {
        let padding = String(repeating: "a", count: WireLimits.maxFrameBytes)
        _ = try WireFrame.decode(
            from: #"{"type":"resync","epoch":"1","pad":"\#(padding)"}"#,
            direction: .viewerToRelay)
    }

    // Direction is enforced, so a viewer cannot write on the host's behalf.
    let chunk = WireFrame.snapshotChunk(
        WireSnapshotChunk(epoch: "1", snapshotID: snapshotID, index: 0, data: Data([1, 2, 3])))
    checks.rejects("viewer sending snapshot.chunk", .invalidFrame) {
        _ = try WireFrame.decode(from: encode(chunk), direction: .viewerToRelay)
    }
    checks.accepts("host sending snapshot.chunk") {
        _ = try WireFrame.decode(from: encode(chunk), direction: .hostToRelay)
    }
    checks.rejects("viewer.count from a viewer", .invalidFrame) {
        _ = try WireFrame.decode(
            from: encode(WireFrame.viewerCount(WireViewerCount(epoch: "1", count: 0))),
            direction: .viewerToRelay)
    }
    checks.accepts("resume from a viewer") {
        _ = try WireFrame.decode(
            from: encode(WireFrame.resume(WireResume(epoch: "1", seq: "0"))),
            direction: .viewerToRelay)
    }
    checks.rejects("damage from a viewer", .invalidFrame) {
        _ = try WireFrame.decode(
            from: encode(WireFrame.damage(WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: []))),
            direction: .viewerToRelay)
    }
}

// MARK: - 5. Strict decoding

func checkStrictDecoding() {
    checks.rejects("unknown field in a snapshot", .invalidFrame) {
        _ = try decode(
            WireSnapshot.self,
            encode(sampleSnapshot()).replacingOccurrences(
                of: "\"blocks\":", with: "\"sidebar\":null,\"blocks\":"))
    }
    checks.rejects("unknown field in a cell", .invalidFrame) {
        _ = try decode(
            WireCell.self, #"{"text":"a","width":1,"style":0,"font":"Menlo"}"#)
    }
    checks.rejects("unknown field in a damage op", .invalidFrame) {
        _ = try decode(
            WireDamageOp.self,
            #"{"op":"remove_block","block_id":"\#(firstBlockID)","row":0}"#)
    }
    checks.rejects("unknown colour kind", .invalidFrame) {
        _ = try decode(WireColor.self, #"{"kind":"hsl","index":1}"#)
    }
    checks.rejects("palette carrying rgb", .invalidFrame) {
        _ = try decode(WireColor.self, #"{"kind":"palette","index":1,"r":0,"g":0,"b":0}"#)
    }
    checks.rejects("rgb carrying an index", .invalidFrame) {
        _ = try decode(WireColor.self, #"{"kind":"rgb","index":1,"r":0,"g":0,"b":0}"#)
    }
    checks.rejects("unknown cursor shape", .invalidFrame) {
        _ = try decode(
            WireCursor.self,
            #"{"row":0,"column":0,"visible":true,"shape":"beam","blink":false}"#)
    }
    checks.rejects("unknown block state", .invalidFrame) {
        _ = try decode(WireBlockState.self, #""finished""#)
    }
    checks.rejects("explicit null for an optional field", .invalidFrame) {
        _ = try decode(
            WireBlock.self,
            encode(sampleSnapshot().blocks[0]).replacingOccurrences(
                of: "\"exit_code\":0", with: "\"exit_code\":null"))
    }

    // UUID spelling is canonical or refused: one identity must not have two wire forms.
    checks.rejects("uppercase UUID", .invalidFrame) {
        _ = try WireValue.uuid(letteredUUID.uppercased(), path: "id")
    }
    checks.accepts("lowercase lettered UUID") {
        _ = try WireValue.uuid(letteredUUID, path: "id")
    }
    checks.rejects("braced UUID", .invalidFrame) {
        _ = try WireValue.uuid("{\(firstBlockID)}", path: "id")
    }
    checks.rejects("misplaced hyphen", .invalidFrame) {
        _ = try WireValue.uuid("111111111-111-4111-8111-111111111111", path: "id")
    }
    checks.accepts("canonical UUID") { _ = try WireValue.uuid(firstBlockID, path: "id") }

    // Counters are decimal strings inside the signed 64-bit range.
    checks.equal(try? WireValue.counter("0", path: "c"), 0, "counter 0")
    checks.equal(try? WireValue.counter("9007199254740993", path: "c"), 9_007_199_254_740_993, "counter past 2^53")
    checks.equal(
        try? WireValue.counter(String(WireLimits.maxCounterValue), path: "c"),
        WireLimits.maxCounterValue, "counter at Int64 max")
    checks.rejects("counter with a leading zero", .invalidFrame) {
        _ = try WireValue.counter("01", path: "c")
    }
    checks.rejects("counter of 20 digits", .invalidFrame) {
        _ = try WireValue.counter("10000000000000000000", path: "c")
    }
    checks.rejects("negative counter", .invalidFrame) {
        _ = try WireValue.counter("-1", path: "c")
    }
    checks.rejects("empty counter", .invalidFrame) { _ = try WireValue.counter("", path: "c") }
    checks.rejects("positive counter at zero", .invalidFrame) {
        _ = try WireValue.positiveCounter("0", path: "c")
    }

    // Non-counter integers must stay inside the JSON safe range.
    checks.rejects("unsafe integer", .invalidFrame) {
        _ = try WireValue.safeInteger(WireLimits.maxSafeInteger + 1, path: "n")
    }
    checks.rejects("negative integer", .invalidFrame) {
        _ = try WireValue.safeInteger(-1, path: "n")
    }
    checks.rejects("exit code past Int32", .invalidFrame) {
        _ = try decode(
            WireBlock.self,
            encode(sampleSnapshot().blocks[0]).replacingOccurrences(
                of: "\"exit_code\":0", with: "\"exit_code\":2147483648"))
    }
}

// MARK: - 6. Cells, rows and grids

func checkCellsAndRows() {
    checks.rejects("two graphemes in one cell", .invalidFrame) {
        _ = try WireValue.visibleGrapheme("ab", path: "cell")
    }
    checks.rejects("empty text in a visible cell", .invalidFrame) {
        _ = try WireValue.visibleGrapheme("", path: "cell")
    }
    checks.rejects("control scalar in a cell", .invalidFrame) {
        _ = try WireValue.visibleGrapheme("\u{1B}", path: "cell")
    }
    checks.rejects("bidi override in a cell", .invalidFrame) {
        _ = try WireValue.visibleGrapheme("\u{202E}", path: "cell")
    }
    checks.rejects("DEL in a cell", .invalidFrame) {
        _ = try WireValue.visibleGrapheme("\u{7F}", path: "cell")
    }
    checks.accepts("ZWJ sequence is one grapheme") {
        _ = try WireValue.visibleGrapheme("\u{1F469}\u{200D}\u{1F4BB}", path: "cell")
    }
    checks.accepts("combining sequence is one grapheme") {
        _ = try WireValue.visibleGrapheme("e\u{0301}", path: "cell")
    }

    // Grapheme byte budget: 63 bytes accepted, 65 refused. The cluster stays a single Character.
    let short = "a" + String(repeating: "\u{0301}", count: 31)
    let long = "a" + String(repeating: "\u{0301}", count: 32)
    checks.equal(short.count, 1, "63-byte cluster is one grapheme")
    checks.equal(long.count, 1, "65-byte cluster is one grapheme")
    checks.accepts("63-byte grapheme") { _ = try WireValue.grapheme(short, path: "cell") }
    checks.rejects("65-byte grapheme", .invalidFrame) {
        _ = try WireValue.grapheme(long, path: "cell")
    }

    // Row geometry.
    checks.rejects("row of the wrong width", .invalidFrame) {
        try row("hi", columns: 4).validate(path: "row", columns: 6)
    }
    checks.accepts("row of the exact width") {
        try row("hi", columns: 4).validate(path: "row", columns: 4)
    }
    checks.rejects("isolated continuation", .invalidFrame) {
        try WireRow(cells: [
            WireCell(text: "", width: 0, style: 0),
            WireCell(text: " ", width: 1, style: 0),
        ]).validate(path: "row", columns: 2)
    }
    checks.rejects("continuation carrying text", .invalidFrame) {
        try WireRow(cells: [
            WireCell(text: "\u{4E16}", width: 2, style: 0),
            WireCell(text: "x", width: 0, style: 0),
        ]).validate(path: "row", columns: 2)
    }
    checks.rejects("wide cell without a continuation", .invalidFrame) {
        try WireRow(cells: [
            WireCell(text: "\u{4E16}", width: 2, style: 0),
            WireCell(text: " ", width: 1, style: 0),
        ]).validate(path: "row", columns: 2)
    }
    checks.rejects("wide cell in the last column", .invalidFrame) {
        try WireRow(cells: [
            WireCell(text: " ", width: 1, style: 0),
            WireCell(text: "\u{4E16}", width: 2, style: 0),
        ]).validate(path: "row", columns: 2)
    }
    checks.rejects("width 3", .invalidFrame) {
        _ = try decode(WireCell.self, #"{"text":"a","width":3,"style":0}"#)
    }

    // Cursors.
    checks.rejects("visible cursor in an empty grid", .invalidFrame) {
        try WireGrid(
            lines: [],
            cursor: WireCursor(row: 0, column: 0, visible: true, shape: .block, blink: false)
        ).validate(path: "grid", columns: 4)
    }
    checks.accepts("invisible cursor in an empty grid") {
        try emptyGrid().validate(path: "grid", columns: 4)
    }
    checks.rejects("cursor past the last line", .invalidFrame) {
        // Built directly: the `grid` helper clamps, which is exactly what this must not do.
        try WireGrid(
            lines: [row("one", columns: 4)],
            cursor: WireCursor(row: 5, column: 0, visible: true, shape: .block, blink: false)
        ).validate(path: "grid", columns: 4)
    }
    checks.rejects("cursor past the last column", .invalidFrame) {
        try grid(["one"], columns: 4, cursorColumn: 9).validate(path: "grid", columns: 4)
    }
}

// MARK: - 7. Snapshot invariants and boundary sizes

func checkSnapshotInvariants() {
    checks.rejects("empty style table", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.styles = []
        try snapshot.validate()
    }
    checks.rejects("style index out of range", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.styles = [defaultStyle]
        try snapshot.validate()
    }
    checks.rejects("duplicate block id", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.blocks[1].id = snapshot.blocks[0].id
        snapshot.viewport = WireViewport(
            firstBlockID: snapshot.blocks[0].id, firstLine: 0,
            pinnedBlockID: snapshot.blocks[0].id)
        try snapshot.validate()
    }
    checks.rejects("viewport naming a missing block", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.viewport = WireViewport(
            firstBlockID: thirdBlockID, firstLine: 0, pinnedBlockID: thirdBlockID)
        try snapshot.validate()
    }
    checks.rejects("fullscreen with two blocks", .invalidFrame) {
        var snapshot = sampleSnapshot(mode: .fullscreen)
        snapshot.blocks.append(sampleSnapshot().blocks[1])
        try snapshot.validate()
    }
    checks.rejects("fullscreen with a visible editor", .invalidFrame) {
        var snapshot = sampleSnapshot(mode: .fullscreen)
        snapshot.editor = WireEditor(
            visible: true, text: "x", selectionStart: 0, selectionLength: 0)
        try snapshot.validate()
    }
    checks.rejects("editor selection splitting a surrogate pair", .invalidFrame) {
        let editor = WireEditor(
            visible: true, text: "a\u{1F600}b", selectionStart: 2, selectionLength: 0)
        try editor.validate(path: "editor")
    }
    checks.rejects("hidden editor with text", .invalidFrame) {
        let editor = WireEditor(
            visible: false, text: "x", selectionStart: 0, selectionLength: 0)
        try editor.validate(path: "editor")
    }

    // Boundary sizes: exactly at the cap is accepted, one past it is not.
    var manyStyles = sampleSnapshot()
    manyStyles.styles = Array(repeating: defaultStyle, count: WireLimits.maxStyles)
    manyStyles.blocks = [WireBlock(
        id: firstBlockID, command: "x", state: .sealed, collapsed: false,
        header: WireGrid(lines: [row("x", columns: 40)], cursor: WireCursor(
            row: 0, column: 0, visible: true, shape: .block, blink: false)),
        output: emptyGrid())]
    manyStyles.viewport = WireViewport(
        firstBlockID: firstBlockID, firstLine: 0, pinnedBlockID: firstBlockID)
    manyStyles.editor = WireEditor(visible: false, text: "", selectionStart: 0, selectionLength: 0)
    checks.accepts("4096 styles") { try manyStyles.validate() }
    manyStyles.styles.append(defaultStyle)
    checks.rejects("4097 styles", .invalidFrame) { try manyStyles.validate() }

    var fiftyBlocks = sampleSnapshot()
    fiftyBlocks.blocks = (0..<WireLimits.maxBlocks).map { index in
        WireBlock(
            id: String(format: "%08d-1111-4111-8111-111111111111", index), command: "c",
            state: .sealed, collapsed: false,
            header: WireGrid(
                lines: [row("c", columns: 40)],
                cursor: WireCursor(row: 0, column: 0, visible: true, shape: .block, blink: false)),
            output: emptyGrid())
    }
    fiftyBlocks.viewport = WireViewport(
        firstBlockID: fiftyBlocks.blocks[0].id, firstLine: 0,
        pinnedBlockID: fiftyBlocks.blocks[0].id)
    fiftyBlocks.editor = WireEditor(visible: false, text: "", selectionStart: 0, selectionLength: 0)
    checks.accepts("50 blocks") { try fiftyBlocks.validate() }
    fiftyBlocks.blocks.append(fiftyBlocks.blocks[0])
    checks.rejects("51 blocks", .invalidFrame) { try fiftyBlocks.validate() }

    // Content budgets are counted in UTF-8 bytes, not characters.
    let atCommandCap = String(repeating: "a", count: WireLimits.maxCommandBytes)
    checks.accepts("command at 64 KiB") {
        try WireValue.utf8(atCommandCap, path: "command", limit: WireLimits.maxCommandBytes)
    }
    checks.rejects("command past 64 KiB", .invalidFrame) {
        try WireValue.utf8(
            atCommandCap + "a", path: "command", limit: WireLimits.maxCommandBytes)
    }
    checks.rejects("four-byte scalars counted as bytes", .invalidFrame) {
        try WireValue.utf8(
            String(repeating: "\u{1F600}", count: 20_000), path: "text",
            limit: WireLimits.maxEditorBytes)
    }
}

// MARK: - 8. Damage

func damageState() -> WireStreamState {
    var state = WireStreamState()
    try? state.apply(snapshot: sampleSnapshot())
    return state
}

func checkDamage() {
    var state = damageState()
    checks.equal(state.blockCount, 2, "snapshot primed two blocks")
    checks.equal(state.lastSeq, 0, "snapshot seq")
    checks.equal(state.columns, 40, "snapshot columns")

    // Appending a row at the current length is the only legal way to grow a grid.
    let append = WireDamage(
        epoch: "1", seq: "1", baseSeq: "0",
        changes: [
            .replaceRow(
                blockID: firstBlockID, grid: .output, row: 3, cells: row("new line", columns: 40))
        ])
    checks.equal(try? state.apply(damage: append), true, "append applied")
    checks.equal(state.block(id: firstBlockID)?.output.lines.count, 4, "grid grew by one")
    checks.equal(state.lastSeq, 1, "seq advanced")

    // A row index past the end would leave a gap the viewer cannot draw.
    checks.rejects("row past the end", .invalidFrame) {
        try state.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [
                    .replaceRow(
                        blockID: firstBlockID, grid: .output, row: 9,
                        cells: row("gap", columns: 40))
                ]))
    }
    checks.equal(state.lastSeq, 1, "a failed frame does not advance seq")
    checks.equal(state.block(id: firstBlockID)?.output.lines.count, 4, "a failed frame changes nothing")

    // Truncation may only shrink.
    checks.rejects("truncate past the end", .invalidFrame) {
        try state.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [.truncateGrid(blockID: firstBlockID, grid: .output, lineCount: 9)]))
    }
    checks.accepts("truncate within the grid with the cursor moved") {
        try state.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [
                    .truncateGrid(blockID: firstBlockID, grid: .output, lineCount: 2),
                    .setCursor(
                        blockID: firstBlockID, grid: .output,
                        cursor: WireCursor(
                            row: 1, column: 0, visible: true, shape: .block, blink: false)),
                ]))
    }
    checks.equal(state.block(id: firstBlockID)?.output.lines.count, 2, "grid shrank")

    // Truncating without moving the cursor would leave it past the end, so the frame fails whole.
    checks.rejects("truncate that strands the cursor", .invalidFrame) {
        try state.apply(
            damage: WireDamage(
                epoch: "1", seq: "3", baseSeq: "2",
                changes: [.truncateGrid(blockID: firstBlockID, grid: .output, lineCount: 0)]))
    }
    checks.equal(state.block(id: firstBlockID)?.output.lines.count, 2, "stranded truncate changed nothing")

    // Ordering: duplicates are ignored, gaps ask for a snapshot.
    var ordered = damageState()
    let first = WireDamage(
        epoch: "1", seq: "1", baseSeq: "0",
        changes: [.setCollapsed(blockID: firstBlockID, collapsed: true)])
    checks.equal(try? ordered.apply(damage: first), true, "first damage applied")
    checks.equal(try? ordered.apply(damage: first), false, "duplicate ignored")
    checks.equal(ordered.lastSeq, 1, "duplicate did not advance seq")
    checks.rejects("gap in the sequence", .resyncRequired) {
        try ordered.apply(
            damage: WireDamage(
                epoch: "1", seq: "5", baseSeq: "1",
                changes: [.setCollapsed(blockID: firstBlockID, collapsed: false)]))
    }
    checks.rejects("stale epoch", .staleEpoch) {
        try ordered.apply(
            damage: WireDamage(
                epoch: "2", seq: "2", baseSeq: "1",
                changes: [.setCollapsed(blockID: firstBlockID, collapsed: false)]))
    }
    checks.rejects("seq not base plus one", .resyncRequired) {
        try ordered.apply(
            damage: WireDamage(
                epoch: "1", seq: "3", baseSeq: "1",
                changes: [.setCollapsed(blockID: firstBlockID, collapsed: false)]))
    }
    checks.rejects("damage before a snapshot", .resyncRequired) {
        var fresh = WireStreamState()
        try fresh.apply(damage: first)
    }

    // Deleting an unknown block is an error, not a silent no-op.
    checks.rejects("removing an unknown block", .invalidFrame) {
        try ordered.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [.removeBlock(blockID: thirdBlockID)]))
    }
    checks.rejects("editing an unknown block", .invalidFrame) {
        try ordered.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [.setCollapsed(blockID: thirdBlockID, collapsed: true)]))
    }

    // A frame that fails on its second operation must leave the first one unapplied.
    var atomic = damageState()
    let before = atomic.block(id: firstBlockID)
    checks.rejects("second operation fails", .invalidFrame) {
        try atomic.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [
                    .setCollapsed(blockID: firstBlockID, collapsed: true),
                    .removeBlock(blockID: thirdBlockID),
                ]))
    }
    checks.equal(atomic.block(id: firstBlockID), before, "first operation rolled back")

    // Insert, remove and re-point the viewport in one frame.
    var editing = damageState()
    let inserted = WireBlock(
        id: thirdBlockID, command: "pwd", state: .running, collapsed: false,
        header: grid(["pwd"], columns: 40), output: emptyGrid())
    checks.accepts("insert, remove and viewport move") {
        try editing.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [
                    .insertBlock(afterID: firstBlockID, block: inserted),
                    .removeBlock(blockID: secondBlockID),
                    .replaceViewport(
                        viewport: WireViewport(
                            firstBlockID: thirdBlockID, firstLine: 0,
                            pinnedBlockID: firstBlockID)),
                ]))
    }
    checks.equal(editing.blockCount, 2, "insert and remove net to two blocks")
    checks.equal(editing.index(ofBlock: thirdBlockID), 1, "inserted after the named block")

    // The editor and its selection travel as one replacement, not as incremental edits.
    checks.accepts("replace editor") {
        try editing.apply(
            damage: WireDamage(
                epoch: "1", seq: "2", baseSeq: "1",
                changes: [
                    .replaceEditor(
                        editor: WireEditor(
                            visible: true, text: "pwd", selectionStart: 3, selectionLength: 0))
                ]))
    }
    checks.equal(editing.editor?.text, "pwd", "editor replaced")
    checks.rejects("editor selection past the text", .invalidFrame) {
        try editing.apply(
            damage: WireDamage(
                epoch: "1", seq: "3", baseSeq: "2",
                changes: [
                    .replaceEditor(
                        editor: WireEditor(
                            visible: true, text: "pwd", selectionStart: 9, selectionLength: 1))
                ]))
    }

    // Op count and serialized size are bounded.
    var manyOps = damageState()
    let atCap = (0..<WireLimits.maxDamageOps).map { _ in
        WireDamageOp.setCollapsed(blockID: firstBlockID, collapsed: true)
    }
    checks.accepts("128 damage operations") {
        try manyOps.apply(damage: WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: atCap))
    }
    checks.rejects("129 damage operations", .invalidFrame) {
        try WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: atCap + atCap).validate()
    }
}

// MARK: - 9. Barriers and eviction

func checkBarriers() {
    var state = damageState()
    checks.equal(state.mode, .blocks, "blocks mode")
    checks.equal(state.totalLines, 5, "snapshot line count")

    // Geometry and mode change only through a snapshot, and the snapshot drops everything the
    // previous mode held: no stale block, no stale row, no stale style.
    let resized = sampleSnapshot(mode: .fullscreen, columns: 120, rows: 40)
    checks.accepts("snapshot barrier") { try state.apply(snapshot: resized) }
    checks.equal(state.columns, 120, "columns replaced")
    checks.equal(state.rows, 40, "rows replaced")
    checks.equal(state.mode, .fullscreen, "mode replaced")
    checks.equal(state.blockCount, 1, "the second block did not survive the barrier")
    checks.expect(state.block(id: secondBlockID) == nil, "stale block evicted")
    checks.equal(state.lastSeq, 0, "seq reset to the snapshot's")

    // A block from the pre-barrier snapshot is now unknown, not silently writable.
    checks.rejects("damage naming an evicted block", .invalidFrame) {
        try state.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [.setCollapsed(blockID: secondBlockID, collapsed: true)]))
    }

    // Evicting the last block leaves a viewport pointing at nothing, which must not ship.
    var lastBlock = damageState()
    checks.rejects("removing the last referenced block", .invalidFrame) {
        try lastBlock.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [
                    .removeBlock(blockID: secondBlockID),
                    .removeBlock(blockID: firstBlockID),
                ]))
    }
    checks.equal(lastBlock.blockCount, 2, "failed eviction changed nothing")

    // Removing one of two blocks is fine once the viewport no longer names it.
    checks.accepts("remove the pinned block with a new viewport") {
        try lastBlock.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [
                    .removeBlock(blockID: secondBlockID),
                    .replaceViewport(
                        viewport: WireViewport(
                            firstBlockID: firstBlockID, firstLine: 0,
                            pinnedBlockID: firstBlockID)),
                ]))
    }
    checks.equal(lastBlock.blockCount, 1, "one block left")

    // An epoch change is a new stream, not a patch on the old one.
    var newEpoch = damageState()
    var epochTwo = sampleSnapshot()
    epochTwo.epoch = "2"
    checks.accepts("second epoch snapshot") { try newEpoch.apply(snapshot: epochTwo) }
    checks.rejects("damage from the old epoch", .staleEpoch) {
        try newEpoch.apply(
            damage: WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [.setCollapsed(blockID: firstBlockID, collapsed: true)]))
    }
}

// MARK: - 10. Input

func checkInput() {
    func input(_ body: String) -> String { #"{"type":"input","epoch":"1","control_lease":"\#(leaseID)","input_seq":"1","operation":\#(body)}"# }

    checks.accepts("text operation") {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"text","text":"ls -la"}"#), direction: .viewerToRelay)
    }
    checks.accepts("paste preserves CR and LF and adds no Enter") {
        guard case let .input(frame) = try WireFrame.decode(
            from: input(#"{"kind":"paste","text":"a\nb\r\n"}"#), direction: .viewerToRelay)
        else { return }
        guard case let .paste(text) = frame.operation else {
            throw WireError.invalidValue(path: "operation", reason: "not a paste")
        }
        checks.equal(text, "a\nb\r\n", "paste text verbatim")
    }
    checks.accepts("ctrl-c stays a key chord") {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"c","modifiers":["control"]}"#),
            direction: .viewerToRelay)
    }
    checks.accepts("bare enter") {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"enter","modifiers":[]}"#),
            direction: .viewerToRelay)
    }
    checks.accepts("undo") {
        _ = try WireFrame.decode(from: input(#"{"kind":"undo"}"#), direction: .viewerToRelay)
    }

    checks.rejects("unmodified letter", .unsupportedInput) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"a","modifiers":[]}"#), direction: .viewerToRelay)
    }
    checks.rejects("shift-only letter", .unsupportedInput) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"a","modifiers":["shift"]}"#),
            direction: .viewerToRelay)
    }
    checks.rejects("duplicate modifier", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"enter","modifiers":["shift","shift"]}"#),
            direction: .viewerToRelay)
    }
    checks.rejects("unknown key", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"key","key":"f13","modifiers":[]}"#), direction: .viewerToRelay)
    }
    checks.rejects("raw bytes operation", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"bytes","data":"001b"}"#), direction: .viewerToRelay)
    }
    checks.rejects("mouse operation", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"mouse","x":1,"y":2}"#), direction: .viewerToRelay)
    }
    checks.rejects("resize operation", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"resize","columns":120,"rows":40}"#),
            direction: .viewerToRelay)
    }
    checks.rejects("NUL in text", .invalidFrame) {
        _ = try WireInputOperation.validateText("a\u{0}b", path: "text")
    }
    checks.accepts("text at 64 KiB") {
        _ = try WireInputOperation.validateText(
            String(repeating: "a", count: WireLimits.maxInputBytes), path: "text")
    }
    checks.rejects("text past 64 KiB", .invalidFrame) {
        _ = try WireInputOperation.validateText(
            String(repeating: "a", count: WireLimits.maxInputBytes + 1), path: "text")
    }
    checks.rejects("negative input seq", .invalidFrame) {
        _ = try WireFrame.decode(
            from: input(#"{"kind":"undo"}"#).replacingOccurrences(
                of: #""input_seq":"1""#, with: #""input_seq":"0""#),
            direction: .viewerToRelay)
    }

    // A rejection must say why; a silent rejected ack is the failure mode this prevents.
    checks.rejects("rejected ack without a code", .invalidFrame) {
        _ = try decode(
            WireInputAck.self,
            #"{"type":"input.ack","epoch":"1","control_lease":"\#(leaseID)","input_seq":"1","status":"rejected"}"#)
    }
    checks.accepts("applied ack without a code") {
        _ = try decode(
            WireInputAck.self,
            #"{"type":"input.ack","epoch":"1","control_lease":"\#(leaseID)","input_seq":"1","status":"applied"}"#)
    }

    // Control frames.
    checks.accepts("control grant with an expiry") {
        _ = try decode(
            WireControlGranted.self,
            #"{"type":"control.granted","epoch":"1","lease":"\#(leaseID)","expires_at":"2026-09-30T18:59:28.123Z"}"#)
    }
    checks.rejects("control grant with a loose timestamp", .invalidFrame) {
        _ = try decode(
            WireControlGranted.self,
            #"{"type":"control.granted","epoch":"1","lease":"\#(leaseID)","expires_at":"2026-09-30T18:59:28Z"}"#)
    }
    checks.accepts("revoke reasons are the allowlisted set") {
        for reason in WireRevokeReason.allCases {
            _ = try decode(
                WireControlRevoked.self,
                #"{"type":"control.revoked","epoch":"1","lease":"\#(leaseID)","reason":"\#(reason.rawValue)"}"#)
        }
    }
    checks.rejects("unknown revoke reason", .invalidFrame) {
        _ = try decode(
            WireControlRevoked.self,
            #"{"type":"control.revoked","epoch":"1","lease":"\#(leaseID)","reason":"timeout"}"#)
    }
    checks.rejects("viewer requesting control with a lease", .invalidFrame) {
        _ = try decode(
            WireControlRequest.self,
            #"{"type":"control.request","epoch":"1","lease":"\#(leaseID)"}"#)
    }
}

// MARK: - 11. Snapshot assembly

func checkAssembler() {
    let bytes = snapshotBytes(sampleSnapshot())
    guard let frames = try? WireSnapshotAssembler.chunk(
        bytes: bytes, epoch: "1", seq: "0", snapshotID: snapshotID)
    else {
        checks.expect(false, "chunking produced no frames")
        return
    }
    checks.equal(frames.count, 3, "a small snapshot is begin, one chunk, end")
    guard case let .snapshotBegin(begin) = frames[0] else {
        checks.expect(false, "first frame is snapshot.begin")
        return
    }
    checks.equal(begin.bytes, bytes.count, "declared length matches")
    checks.equal(begin.sha256, WireSHA256.hexDigest(bytes), "declared digest matches")
    checks.equal(begin.chunks, 1, "declared chunk count")

    checks.equal(
        try? WireSnapshotAssembler.assemble(frames: frames), sampleSnapshot(),
        "assembled snapshot round trip")

    // A chunk from another snapshot aborts the transfer rather than mixing two transfers.
    checks.rejects("chunk from another snapshot", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(begin)
        try assembler.append(
            WireSnapshotChunk(
                epoch: "1", snapshotID: thirdBlockID, index: 0, data: Data([1])))
    }
    checks.rejects("chunk out of order", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(begin)
        try assembler.append(
            WireSnapshotChunk(epoch: "1", snapshotID: snapshotID, index: 3, data: Data([1])))
    }
    checks.rejects("chunk before begin", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.append(
            WireSnapshotChunk(epoch: "1", snapshotID: snapshotID, index: 0, data: Data([1])))
    }
    checks.rejects("second begin while assembling", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(begin)
        try assembler.begin(begin)
    }
    checks.rejects("end without all chunks", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(begin)
        _ = try assembler.finish(WireSnapshotEnd(epoch: "1", snapshotID: snapshotID))
    }
    checks.rejects("digest mismatch", .resyncRequired) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(
            WireSnapshotBegin(
                epoch: "1", seq: "0", snapshotID: snapshotID, bytes: bytes.count, chunks: 1,
                sha256: String(repeating: "0", count: 64)))
        try assembler.append(
            WireSnapshotChunk(epoch: "1", snapshotID: snapshotID, index: 0, data: bytes))
        _ = try assembler.finish(WireSnapshotEnd(epoch: "1", snapshotID: snapshotID))
    }
    checks.rejects("declared length past the chunk budget", .invalidFrame) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(
            WireSnapshotBegin(
                epoch: "1", seq: "0", snapshotID: snapshotID, bytes: WireLimits.maxSnapshotBytes,
                chunks: 1, sha256: String(repeating: "a", count: 64)))
    }
    checks.rejects("chunk count past the cap", .invalidFrame) {
        _ = try decode(
            WireSnapshotBegin.self,
            #"{"type":"snapshot.begin","epoch":"1","seq":"0","snapshot_id":"\#(snapshotID)","bytes":1024,"chunks":129,"sha256":"\#(String(repeating: "a", count: 64))"}"#)
    }
    checks.rejects("chunk data past 45 KiB", .invalidFrame) {
        let oversized = Data(repeating: 7, count: WireLimits.maxRawChunkBytes + 1)
        _ = try WireFrame.snapshotChunk(
            WireSnapshotChunk(
                epoch: "1", snapshotID: snapshotID, index: 0, data: oversized))
            .validateDirection(.hostToRelay)
        _ = try decode(
            WireSnapshotChunk.self,
            encode(WireSnapshotChunk(
                epoch: "1", snapshotID: snapshotID, index: 0, data: oversized)))
    }
    checks.accepts("chunk data at 45 KiB") {
        _ = try decode(
            WireSnapshotChunk.self,
            encode(WireSnapshotChunk(
                epoch: "1", snapshotID: snapshotID, index: 0,
                data: Data(repeating: 7, count: WireLimits.maxRawChunkBytes))))
    }

    // Non-canonical base64 would give one byte string two spellings.
    checks.rejects("non-canonical base64", .invalidFrame) {
        _ = try WireValue.base64("AAECAw", path: "data", maxBytes: 64)
    }
    checks.rejects("base64 with padding in the wrong place", .invalidFrame) {
        _ = try WireValue.base64("AA=A", path: "data", maxBytes: 64)
    }
    checks.accepts("canonical base64") {
        _ = try WireValue.base64(Data([0, 1, 2, 3]).base64EncodedString(), path: "data", maxBytes: 64)
    }

    // A multi-chunk snapshot reassembles in order. Kept well inside the 4 MiB snapshot cap: the
    // point is the chunking arithmetic, not the cap, which is asserted separately.
    var large = sampleSnapshot(columns: 200)
    large.blocks = (0..<40).map { index in
        WireBlock(
            id: String(format: "%08d-2222-4222-8222-222222222222", index), command: "c",
            state: .sealed, collapsed: false,
            header: grid(["c"], columns: 200),
            output: WireGrid(
                lines: (0..<3).map { line in
                    row("line \(line) \(String(repeating: "x", count: 60))", columns: 200)
                },
                cursor: WireCursor(row: 0, column: 0, visible: true, shape: .block, blink: false)))
    }
    large.viewport = WireViewport(
        firstBlockID: large.blocks[0].id, firstLine: 0, pinnedBlockID: large.blocks[0].id)
    large.editor = WireEditor(visible: false, text: "", selectionStart: 0, selectionLength: 0)
    let largeBytes = snapshotBytes(large)
    checks.expect(largeBytes.count > WireLimits.maxRawChunkBytes, "large snapshot spans chunks")
    guard let largeFrames = try? WireSnapshotAssembler.chunk(
        bytes: largeBytes, epoch: "1", seq: "0", snapshotID: snapshotID)
    else {
        checks.expect(false, "large snapshot did not chunk")
        return
    }
    checks.expect(largeFrames.count > 3, "large snapshot used several chunks")
    checks.equal(
        try? WireSnapshotAssembler.assemble(frames: largeFrames), large,
        "multi-chunk round trip")
}

// MARK: - 12. Static shares

func checkShares() {
    checks.rejects("overlapping spans", .invalidFrame) {
        var share = sampleShare()
        share.blocks[0].lines[0] = WireShareLine(
            text: "total 8",
            spans: [
                WireShareSpan(start: 0, length: 4, style: 1),
                WireShareSpan(start: 2, length: 2, style: 1),
            ])
        try share.validate()
    }
    checks.rejects("span past the end of the line", .invalidFrame) {
        var share = sampleShare()
        share.blocks[0].lines[0] = WireShareLine(
            text: "total 8", spans: [WireShareSpan(start: 4, length: 9, style: 1)])
        try share.validate()
    }
    checks.rejects("zero-length span", .invalidFrame) {
        _ = try decode(WireShareSpan.self, #"{"start":0,"length":0,"style":1}"#)
    }
    checks.rejects("span style out of range", .invalidFrame) {
        var share = sampleShare()
        share.styles = [defaultStyle]
        try share.validate()
    }
    checks.rejects("control scalar in exported text", .invalidFrame) {
        var share = sampleShare()
        share.blocks[0].lines[0] = WireShareLine(text: "a\u{1B}[31mb")
        try share.validate()
    }
    checks.rejects("newline inside an exported line", .invalidFrame) {
        var share = sampleShare()
        share.blocks[0].lines[0] = WireShareLine(text: "a\nb")
        try share.validate()
    }
    checks.rejects("duplicate exported block id", .invalidFrame) {
        var share = sampleShare()
        share.blocks[1].id = share.blocks[0].id
        try share.validate()
    }
    checks.rejects("more than 20 exported blocks", .invalidFrame) {
        var share = sampleShare()
        share.blocks = (0..<(WireLimits.maxShareBlocks + 1)).map { index in
            WireShareBlock(
                id: String(format: "%08d-3333-4333-8333-333333333333", index), command: "c",
                lines: [])
        }
        try share.validate()
    }
    checks.accepts("20 exported blocks") {
        var share = sampleShare()
        share.blocks = (0..<WireLimits.maxShareBlocks).map { index in
            WireShareBlock(
                id: String(format: "%08d-3333-4333-8333-333333333333", index), command: "c",
                lines: [])
        }
        try share.validate()
    }

    // The directory label is a display string, never an implicit full-path export.
    checks.accepts("abbreviated directory label") {
        try WireShareSnapshot.validateDirectory("swiftTerm/docs")
    }
    checks.rejects("absolute directory", .invalidFrame) {
        try WireShareSnapshot.validateDirectory("/Users/someone/private")
    }
    checks.rejects("home directory", .invalidFrame) {
        try WireShareSnapshot.validateDirectory("~/private")
    }
    checks.rejects("traversal in the label", .invalidFrame) {
        try WireShareSnapshot.validateDirectory("a/../../etc")
    }
    checks.rejects("share schema version 2", .unsupportedVersion) {
        var share = sampleShare()
        share.schemaVersion = 2
        try share.validate()
    }

    // The capability is 32 random bytes in one canonical spelling.
    checks.equal(WireShareCapability.encodedLength, 43, "capability length")
    checks.accepts("canonical capability") {
        let secret = Data((0..<32).map { UInt8($0) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        checks.expect(WireShareCapability.isValid(secret), "\(secret) should be valid")
    }
    checks.expect(!WireShareCapability.isValid("short"), "short secret refused")
    checks.expect(
        !WireShareCapability.isValid(String(repeating: "A", count: 42) + "="),
        "padded secret refused")
    checks.expect(
        !WireShareCapability.isValid(String(repeating: "A", count: 42) + "B"),
        "non-canonical tail refused")
    checks.expect(
        WireShareCapability.isValid(String(repeating: "A", count: 42) + "A"),
        "canonical tail accepted")
    checks.equal(WireShareCapability.digestHex("a").count, 64, "capability digest is 32 bytes hex")
}

// MARK: - 13. Shared invalid fixtures

/// One rejection both implementations must agree on. `payload` is JSON text rather than a nested
/// object so the bytes under test are exactly the bytes authored here.
struct InvalidCase: Codable, Equatable {
    var name: String
    var kind: String
    var expected: WireErrorCode
    var payload: String
    var direction: WireDirection?
}

struct InvalidFixtureFile: Codable, Equatable {
    var version: Int
    var cases: [InvalidCase]
}

/// The smallest valid snapshot the invalid cases mutate: one block, four columns, no editor.
func baseSnapshot() -> WireSnapshot {
    var snapshot = sampleSnapshot(columns: 4)
    snapshot.blocks = [
        WireBlock(
            id: firstBlockID, command: "x", state: .sealed, collapsed: false,
            header: grid(["x"], columns: 4, cursorRow: 0, cursorColumn: 1), output: emptyGrid())
    ]
    snapshot.viewport = WireViewport(
        firstBlockID: firstBlockID, firstLine: 0, pinnedBlockID: firstBlockID)
    snapshot.editor = WireEditor(visible: false, text: "", selectionStart: 0, selectionLength: 0)
    return snapshot
}

func invalidCases() -> [InvalidCase] {
    var cases: [InvalidCase] = []
    func add(
        _ name: String, _ kind: String, _ expected: WireErrorCode, _ payload: String,
        _ direction: WireDirection? = nil
    ) {
        cases.append(
            InvalidCase(
                name: name, kind: kind, expected: expected, payload: payload,
                direction: direction))
    }
    /// Apply the mutation to a fresh copy of the base snapshot and encode it.
    func snapshot(_ mutate: (inout WireSnapshot) -> Void) -> String {
        var value = baseSnapshot()
        mutate(&value)
        return encode(value)
    }
    let base = encode(baseSnapshot())

    // Snapshot: version, style table and identity.
    add("snapshot-version-2", "snapshot", .unsupportedVersion,
        snapshot { $0.version = 2 })
    add("snapshot-empty-styles", "snapshot", .invalidFrame,
        snapshot { $0.styles = [] })
    add("snapshot-style-index-out-of-range", "snapshot", .invalidFrame,
        snapshot { $0.styles = [defaultStyle] })
    add("snapshot-duplicate-block-id", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks.append($0.blocks[0])
            $0.viewport = WireViewport(
                firstBlockID: firstBlockID, firstLine: 0, pinnedBlockID: firstBlockID)
        })
    add("snapshot-viewport-unknown-block", "snapshot", .invalidFrame,
        snapshot {
            $0.viewport = WireViewport(
                firstBlockID: thirdBlockID, firstLine: 0, pinnedBlockID: thirdBlockID)
        })
    add("snapshot-unknown-field", "snapshot", .invalidFrame,
        base.replacingOccurrences(of: "\"blocks\":", with: "\"sidebar\":null,\"blocks\":"))
    add("snapshot-explicit-null-optional", "snapshot", .invalidFrame,
        encode(sampleSnapshot()).replacingOccurrences(
            of: "\"exit_code\":0", with: "\"exit_code\":null"))
    add("snapshot-uppercase-uuid", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].id = letteredUUID
            $0.viewport = WireViewport(
                firstBlockID: letteredUUID, firstLine: 0, pinnedBlockID: letteredUUID)
        }.replacingOccurrences(of: letteredUUID, with: letteredUUID.uppercased()))

    // Snapshot: geometry and cells.
    add("snapshot-row-wrong-width", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.lines = [WireRow(cells: [WireCell(text: "x", width: 1, style: 0)])]
            $0.blocks[0].header.cursor = WireCursor(
                row: 0, column: 0, visible: true, shape: .block, blink: false)
        })
    add("snapshot-isolated-continuation", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.lines = [
                WireRow(cells: [
                    WireCell(text: "", width: 0, style: 0),
                    WireCell(text: " ", width: 1, style: 0),
                    WireCell(text: " ", width: 1, style: 0),
                    WireCell(text: " ", width: 1, style: 0),
                ])
            ]
        })
    add("snapshot-wide-cell-in-last-column", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.lines = [
                WireRow(cells: [
                    WireCell(text: " ", width: 1, style: 0),
                    WireCell(text: " ", width: 1, style: 0),
                    WireCell(text: " ", width: 1, style: 0),
                    WireCell(text: "\u{4E16}", width: 2, style: 0),
                ])
            ]
        })
    add("snapshot-control-scalar-in-cell", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.lines = [row("\u{1B}", columns: 4)]
        })
    add("snapshot-bidi-override-in-cell", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.lines = [row("\u{202E}", columns: 4)]
        })
    add("snapshot-cursor-past-last-line", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].header.cursor = WireCursor(
                row: 3, column: 0, visible: true, shape: .block, blink: false)
        })
    add("snapshot-visible-cursor-in-empty-grid", "snapshot", .invalidFrame,
        snapshot {
            $0.blocks[0].output.cursor = WireCursor(
                row: 0, column: 0, visible: true, shape: .bar, blink: false)
        })
    add("snapshot-fullscreen-two-blocks", "snapshot", .invalidFrame,
        snapshot {
            $0.mode = .fullscreen
            $0.blocks.append(sampleSnapshot().blocks[1])
            $0.viewport = WireViewport(
                firstBlockID: firstBlockID, firstLine: 0, pinnedBlockID: firstBlockID)
            $0.editor = WireEditor(
                visible: false, text: "", selectionStart: 0, selectionLength: 0)
        })
    add("snapshot-fullscreen-visible-editor", "snapshot", .invalidFrame,
        snapshot {
            $0.mode = .fullscreen
            $0.viewport = WireViewport(
                firstBlockID: firstBlockID, firstLine: 0, pinnedBlockID: firstBlockID)
            $0.editor = WireEditor(
                visible: true, text: "x", selectionStart: 0, selectionLength: 0)
        })
    add("snapshot-editor-selection-splits-surrogate", "snapshot", .invalidFrame,
        snapshot {
            $0.editor = WireEditor(
                visible: true, text: "a\u{1F600}b", selectionStart: 2, selectionLength: 0)
        })

    // Damage: ordering, the op union and the operation budget.
    add("damage-seq-not-base-plus-one", "damage", .resyncRequired,
        encode(WireDamage(
            epoch: "1", seq: "3", baseSeq: "1",
            changes: [.setCollapsed(blockID: firstBlockID, collapsed: true)])))
    add("damage-unknown-op", "damage", .invalidFrame,
        #"{"type":"damage","epoch":"1","seq":"1","base_seq":"0","changes":[{"op":"teleport"}]}"#)
    add("damage-op-with-extra-field", "damage", .invalidFrame,
        #"{"type":"damage","epoch":"1","seq":"1","base_seq":"0","changes":[{"op":"remove_block","block_id":"\#(firstBlockID)","row":0}]}"#)
    add("damage-unknown-grid-kind", "damage", .invalidFrame,
        #"{"type":"damage","epoch":"1","seq":"1","base_seq":"0","changes":[{"op":"truncate_grid","block_id":"\#(firstBlockID)","grid":"scrollback","line_count":0}]}"#)
    add("damage-unknown-block-state", "damage", .invalidFrame,
        #"{"type":"damage","epoch":"1","seq":"1","base_seq":"0","changes":[{"op":"replace_header","block_id":"\#(firstBlockID)","command":"x","state":"finished"}]}"#)
    add("damage-too-many-ops", "damage", .invalidFrame,
        encode(WireDamage(
            epoch: "1", seq: "1", baseSeq: "0",
            changes: (0...(WireLimits.maxDamageOps)).map { _ in
                WireDamageOp.setCollapsed(blockID: firstBlockID, collapsed: true)
            })))
    add("damage-zero-seq", "damage", .invalidFrame,
        encode(WireDamage(
            epoch: "1", seq: "0", baseSeq: "0",
            changes: [.setCollapsed(blockID: firstBlockID, collapsed: true)])))

    // Input: the union, the keys and the size budget.
    func inputFrame(_ operation: String, seq: String = "1") -> String {
        #"{"type":"input","epoch":"1","control_lease":"\#(leaseID)","input_seq":"\#(seq)","operation":\#(operation)}"#
    }
    add("input-unknown-key", "input", .invalidFrame,
        inputFrame(#"{"kind":"key","key":"f13","modifiers":[]}"#))
    add("input-bare-letter", "input", .unsupportedInput,
        inputFrame(#"{"kind":"key","key":"a","modifiers":[]}"#))
    add("input-shift-only-letter", "input", .unsupportedInput,
        inputFrame(#"{"kind":"key","key":"a","modifiers":["shift"]}"#))
    add("input-duplicate-modifier", "input", .invalidFrame,
        inputFrame(#"{"kind":"key","key":"enter","modifiers":["shift","shift"]}"#))
    add("input-raw-bytes-op", "input", .invalidFrame,
        inputFrame(#"{"kind":"bytes","data":"001b"}"#))
    add("input-mouse-op", "input", .invalidFrame,
        inputFrame(#"{"kind":"mouse","x":1,"y":2}"#))
    add("input-resize-op", "input", .invalidFrame,
        inputFrame(#"{"kind":"resize","columns":120,"rows":40}"#))
    add("input-nul-text", "input", .invalidFrame,
        inputFrame(#"{"kind":"paste","text":"a\u0000b"}"#))
    add("input-zero-seq", "input", .invalidFrame,
        inputFrame(#"{"kind":"undo"}"#, seq: "0"))
    add("input-oversized-text", "input", .invalidFrame,
        inputFrame(#"{"kind":"paste","text":"\#(String(repeating: "a", count: WireLimits.maxInputBytes + 1))"}"#))

    // Shares: spans, labels and the block budget.
    add("share-version-2", "share", .unsupportedVersion,
        encode({ var value = sampleShare(); value.schemaVersion = 2; return value }()))
    add("share-zero-length-span", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[0].lines[0] = WireShareLine(
                text: "total 8", spans: [WireShareSpan(start: 0, length: 0, style: 1)])
            return value
        }()))
    add("share-span-past-line", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[0].lines[0] = WireShareLine(
                text: "total 8", spans: [WireShareSpan(start: 4, length: 9, style: 1)])
            return value
        }()))
    add("share-overlapping-spans", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[0].lines[0] = WireShareLine(
                text: "total 8",
                spans: [
                    WireShareSpan(start: 0, length: 4, style: 1),
                    WireShareSpan(start: 2, length: 2, style: 1),
                ])
            return value
        }()))
    add("share-absolute-directory", "share", .invalidFrame,
        encode({ var value = sampleShare(); value.directory = "/Users/someone/private"; return value }()))
    add("share-traversal-directory", "share", .invalidFrame,
        encode({ var value = sampleShare(); value.directory = "a/../../etc"; return value }()))
    add("share-newline-in-line", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[0].lines[0] = WireShareLine(text: "a\nb")
            return value
        }()))
    add("share-control-scalar", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[0].lines[0] = WireShareLine(text: "a\u{1B}[31mb")
            return value
        }()))
    add("share-duplicate-block-id", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks[1].id = value.blocks[0].id
            return value
        }()))
    add("share-too-many-blocks", "share", .invalidFrame,
        encode({
            var value = sampleShare()
            value.blocks = (0...WireLimits.maxShareBlocks).map { index in
                WireShareBlock(
                    id: String(format: "%08d-3333-4333-8333-333333333333", index), command: "c",
                    lines: [])
            }
            return value
        }()))

    // Frames: the envelope and the direction rule.
    add("frame-unknown-type", "frame", .invalidFrame, #"{"type":"teleport"}"#)
    add("frame-missing-type", "frame", .invalidFrame, #"{"epoch":"1"}"#)
    // `hello` travels relay-to-peer, so the version is checked in a direction where it is legal —
    // otherwise the direction rule would mask the rule this case is about.
    add("frame-hello-version-0", "frame", .unsupportedVersion,
        #"{"type":"hello","version":0,"session_id":"\#(sessionID)","epoch":"1","mode":"blocks","columns":80,"rows":24}"#,
        .relayToHost)
    add("frame-rejected-ack-without-code", "frame", .invalidFrame,
        #"{"type":"input.ack","epoch":"1","control_lease":"\#(leaseID)","input_seq":"1","status":"rejected"}"#)
    add("frame-loose-timestamp", "frame", .invalidFrame,
        #"{"type":"control.granted","epoch":"1","lease":"\#(leaseID)","expires_at":"2026-09-30T18:59:28Z"}"#)
    add("frame-viewer-sends-snapshot-chunk", "frame", .invalidFrame,
        encode(WireFrame.snapshotChunk(
            WireSnapshotChunk(
                epoch: "1", snapshotID: snapshotID, index: 0, data: Data([1, 2, 3])))),
        .viewerToRelay)
    add("frame-viewer-sends-damage", "frame", .invalidFrame,
        encode(WireFrame.damage(
            WireDamage(
                epoch: "1", seq: "1", baseSeq: "0",
                changes: [.setCollapsed(blockID: firstBlockID, collapsed: true)]))),
        .viewerToRelay)
    add("frame-viewer-sends-viewer-count", "frame", .invalidFrame,
        encode(WireFrame.viewerCount(WireViewerCount(epoch: "1", count: 0))), .viewerToRelay)
    add("frame-chunk-past-45-kib", "frame", .invalidFrame,
        encode(WireFrame.snapshotChunk(
            WireSnapshotChunk(
                epoch: "1", snapshotID: snapshotID, index: 0,
                data: Data(repeating: 7, count: WireLimits.maxRawChunkBytes + 1)))))
    return cases
}

/// Decode a payload the way its kind says, so a case cannot pass by being validated as the wrong
/// thing.
func decodeInvalid(_ kind: String, _ payload: String, _ direction: WireDirection?) throws {
    switch kind {
    case "snapshot": _ = try WireCanonicalJSON.decode(WireSnapshot.self, from: payload)
    case "damage": _ = try WireCanonicalJSON.decode(WireDamage.self, from: payload)
    case "input": _ = try WireCanonicalJSON.decode(WireInputFrame.self, from: payload)
    case "share": _ = try WireCanonicalJSON.decode(WireShareSnapshot.self, from: payload)
    case "frame":
        _ = try WireFrame.decode(from: payload, direction: direction ?? .hostToRelay)
    default:
        throw WireError.malformedFrame(reason: "unknown fixture kind \(kind)")
    }
}

func checkInvalidFixtures() {
    let file = InvalidFixtureFile(version: 1, cases: invalidCases())
    checks.expect(!file.cases.isEmpty, "invalid fixtures were generated")
    checks.equal(
        Set(file.cases.map(\.name)).count, file.cases.count, "invalid fixture names are unique")
    for value in file.cases {
        checks.rejects(value.name, value.expected) {
            try decodeInvalid(value.kind, value.payload, value.direction)
        }
    }

    // The index is checked in too, so a rule that silently stops being enforced shows up as a
    // diff on both sides rather than as a quietly shrinking test.
    let path = repositoryRoot.appendingPathComponent("contracts/fixtures/invalid.json")
    guard let data = try? WireCanonicalJSON.encode(file) else {
        checks.expect(false, "invalid.json: cannot encode")
        return
    }
    if writingFixtures {
        try? data.write(to: path)
        print("wrote invalid.json — \(file.cases.count) cases — \(WireSHA256.hexDigest(data))")
        return
    }
    guard let expected = try? Data(contentsOf: path) else {
        checks.expect(false, "invalid.json missing; run with --write-fixtures")
        return
    }
    checks.expect(
        data == expected,
        "invalid.json differs from the checked-in index — regenerate it deliberately")
}

// MARK: - Run

func checkAuditRegressions() {
    checks.rejects("UTF-16 frame cannot bypass UTF-8 transport", .invalidFrame) {
        let text = #"{"type":"resync","epoch":"1"}"#
        _ = try WireFrame.decode(from: Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }),
                                 direction: .viewerToRelay)
    }
    checks.rejects("raw JSON bounded before decoding", .invalidFrame) {
        _ = try WireCanonicalJSON.decode(WireSnapshot.self,
            from: Data(repeating: 32, count: WireLimits.maxSnapshotBytes + 1))
    }
    checks.rejects("negative native cursor", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.blocks[0].output.cursor.row = -1
        try snapshot.validate()
    }
    checks.rejects("invalid native color", .invalidFrame) {
        var snapshot = sampleSnapshot()
        snapshot.styles[0].fg = .palette(index: -1)
        try snapshot.validate()
    }
    checks.rejects("exhausted counter fails without overflow", .resyncRequired) {
        _ = try decode(WireDamage.self,
            #"{"type":"damage","epoch":"1","seq":"1","base_seq":"9223372036854775807","changes":[]}"#)
    }
    checks.rejects("negative native editor offset", .invalidFrame) {
        try WireEditor(visible: true, text: "abc", selectionStart: -1, selectionLength: 0).validate(path: "editor")
    }
    checks.rejects("overflowing native editor offset", .invalidFrame) {
        try WireEditor(visible: true, text: "abc", selectionStart: Int.max, selectionLength: 1).validate(path: "editor")
    }
    checks.expect(!WireTime.isValid("2026-02-31T12:00:00.000Z"), "impossible calendar date rejected")
    checks.expect(WireTime.isValid("2028-02-29T12:00:00.000Z"), "valid leap day accepted")
    for (epoch, seq) in [("2", "0"), ("1", "1")] {
        checks.rejects("transfer watermark mismatch \(epoch)/\(seq)", .resyncRequired) {
            let frames = try WireSnapshotAssembler.chunk(bytes: snapshotBytes(sampleSnapshot()),
                epoch: epoch, seq: seq, snapshotID: snapshotID)
            _ = try WireSnapshotAssembler.assemble(frames: frames)
        }
    }
    checks.rejects("native begin cannot overflow multiplication", .invalidFrame) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(WireSnapshotBegin(epoch: "1", seq: "0", snapshotID: snapshotID,
            bytes: 1, chunks: Int.max, sha256: String(repeating: "a", count: 64)))
    }
    checks.rejects("native chunk enforces byte cap", .invalidFrame) {
        var assembler = WireSnapshotAssembler()
        try assembler.begin(WireSnapshotBegin(epoch: "1", seq: "0", snapshotID: snapshotID,
            bytes: WireLimits.maxRawChunkBytes * 2, chunks: 2, sha256: String(repeating: "a", count: 64)))
        try assembler.append(WireSnapshotChunk(epoch: "1", snapshotID: snapshotID, index: 0,
            data: Data(repeating: 0, count: WireLimits.maxRawChunkBytes + 1)))
    }
    checks.accepts("snapshot rollback and fullscreen damage leave state intact") {
        var state = WireStreamState()
        var current = sampleSnapshot()
        current.epoch = "2"
        current.seq = "4"
        try state.apply(snapshot: current)
        var old = current
        old.epoch = "1"
        checks.rejects("older snapshot epoch", .staleEpoch) { try state.apply(snapshot: old) }
        old.epoch = "2"
        old.seq = "3"
        checks.rejects("older snapshot watermark", .resyncRequired) { try state.apply(snapshot: old) }
        checks.equal(state.lastSeq, 4, "rollback rejection retains sequence")
        state = WireStreamState()
        try state.apply(snapshot: sampleSnapshot(mode: .fullscreen))
        checks.rejects("fullscreen damage cannot expose editor", .invalidFrame) {
            try state.apply(damage: WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: [
                .replaceEditor(editor: WireEditor(visible: true, text: "", selectionStart: 0, selectionLength: 0))]))
        }
        checks.rejects("fullscreen damage cannot insert second block", .invalidFrame) {
            try state.apply(damage: WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: [
                .insertBlock(afterID: nil, block: sampleSnapshot().blocks[1])]))
        }
        checks.equal(state.blockCount, 1, "fullscreen rejects partial changes")
        checks.equal(state.lastSeq, 0, "fullscreen rejection retains sequence")
        checks.rejects("negative native damage row", .invalidFrame) {
            try state.apply(damage: WireDamage(epoch: "1", seq: "1", baseSeq: "0", changes: [
                .replaceRow(blockID: firstBlockID, grid: .output, row: -1, cells: row("", columns: 12))]))
        }
    }
    checks.accepts("damage enforces aggregate retained byte budget atomically") {
        var snapshot = sampleSnapshot()
        snapshot.columns = 64
        snapshot.blocks = [snapshot.blocks[0]]
        snapshot.viewport.pinnedBlockID = firstBlockID
        let cell = WireCell(text: "a" + String(repeating: "\u{0301}", count: 31), width: 1, style: 0)
        let line = WireRow(cells: Array(repeating: cell, count: 64))
        snapshot.blocks[0].header = WireGrid(lines: [],
            cursor: WireCursor(row: 0, column: 0, visible: false, shape: .block, blink: false))
        snapshot.blocks[0].output = WireGrid(lines: Array(repeating: line, count: 550),
            cursor: WireCursor(row: 0, column: 0, visible: true, shape: .block, blink: false))
        var state = WireStreamState()
        try state.apply(snapshot: snapshot)
        var rejected = false
        for _ in 0..<30 {
            let previousSeq = state.lastSeq
            let previousLines = state.totalLines
            let changes = (0..<8).map { offset in
                WireDamageOp.replaceRow(blockID: firstBlockID, grid: .output,
                    row: previousLines + offset, cells: line)
            }
            do {
                try state.apply(damage: WireDamage(epoch: "1", seq: String(previousSeq + 1),
                    baseSeq: String(previousSeq), changes: changes))
            } catch let error as WireError {
                checks.equal(error.code, .invalidFrame, "byte budget rejection")
                checks.equal(state.lastSeq, previousSeq, "oversized damage preserves seq")
                checks.equal(state.totalLines, previousLines, "oversized damage preserves rows")
                rejected = true
                break
            }
        }
        checks.expect(rejected, "retained bytes capped before reaching line limit")
    }
    for blockState in [WireBlockState.draft, .running] {
        checks.rejects("export requires sealed blocks \(blockState)", .invalidFrame) {
            var share = sampleShare()
            share.blocks[0].state = blockState
            try share.validate()
        }
    }
    checks.rejects("export span cannot split emoji", .invalidFrame) {
        try WireShareLine(text: "😀", spans: [WireShareSpan(start: 0, length: 1, style: 0)])
            .validate(path: "line", styleCount: 1)
    }
    checks.rejects("native span length cannot overflow", .invalidFrame) {
        try WireShareLine(text: "abc", spans: [WireShareSpan(start: 1, length: Int.max, style: 0)])
            .validate(path: "line", styleCount: 1)
    }
}

@main
enum WireContractTest {
    static func main() {
        checkCanonicalEncoding()
        checkRoundTrips()
        checkGolden()
        checkVersionAndFraming()
        checkStrictDecoding()
        checkCellsAndRows()
        checkSnapshotInvariants()
        checkDamage()
        checkBarriers()
        checkInput()
        checkAssembler()
        checkShares()
        checkInvalidFixtures()
        checkAuditRegressions()
        checks.finish()
    }
}
