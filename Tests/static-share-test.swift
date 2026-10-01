import Foundation

@main struct StaticShareTest {
    static func main() async throws {
        let block = Block(id: BlockID(rawValue: 1), size: TerminalSize(columns: 80, rows: 24), workingDirectory: "/private/home")
        block.command = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz echo hello"
        _ = block.outputGrid.start(at: Date(timeIntervalSince1970: 0))
        _ = block.outputGrid.finish(at: Date(timeIntervalSince1970: 1))
        let draft = Block(id: BlockID(rawValue: 2), size: TerminalSize(columns: 80, rows: 24), workingDirectory: nil)
        let captured = try StaticShareExport.capture([block, draft])
        precondition(captured.count == 1)
        let masked = StaticShareExport.redacted(captured)
        precondition(!masked[0].command.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        let snapshot = try StaticShareExport.snapshot(masked, id: UUID().uuidString.lowercased())
        precondition(snapshot.directory == nil && snapshot.blocks[0].state == .sealed)
        let secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let first = try CloudRoutes.publishShare(snapshot: snapshot, requestID: snapshot.snapshotID, secret: secret)
        let retry = try CloudRoutes.publishShare(snapshot: snapshot, requestID: snapshot.snapshotID, secret: secret)
        precondition(first == retry)
        let body = try JSONSerialization.jsonObject(with: first.body!) as! [String: Any]
        precondition(body["access_mode"] as? String == "link" && body["blocks"] is [[String: Any]])
        for fixture in ["PASSWORD=abc123", "Bearer abc.def.ghi", "github_pat_abcdefghijklmnopqrstuvwxyz",
                        "https://alice:secret@example.com", "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"] {
            precondition(SecretRedaction.mask(fixture).contains("[REDACTED]"))
        }
        var edited = masked
        edited[0].output = "safe\n<script>alert(1)</script>\n😀"
        let safe = try StaticShareExport.snapshot(edited, id: snapshot.snapshotID)
        precondition(safe.blocks[0].lines[1].text == "<script>alert(1)</script>")
        edited[0].output = "\u{1B}]52;secret"
        do { _ = try StaticShareExport.snapshot(edited, id: snapshot.snapshotID); fatalError("OSC accepted") }
        catch is WireError { }
        edited[0].selected = false
        do { _ = try StaticShareExport.snapshot(edited, id: snapshot.snapshotID); fatalError("Empty selection accepted") }
        catch is WireError { }
        var settings = ChromeSettings()
        settings.sharingEnabled = false
        let restored = try JSONDecoder().decode(ChromeSettings.self, from: JSONEncoder().encode(settings))
        precondition(!restored.sharingEnabled)
        let defaults = try JSONDecoder().decode(ChromeSettings.self, from: Data("{}".utf8))
        precondition(defaults.sharingEnabled)
        print("PASS: sealed-only redacted export, editable hostile text, control rejection, public retry body, offline setting")
    }
}
