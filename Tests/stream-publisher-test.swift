import Foundation
import Observation
@main struct StreamPublisherTest {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("frames.json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", "-e", Self.relay, output.path]
        let pipe = Pipe()
        server.standardOutput = pipe
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let publisher = StreamPublisher(api: CloudAPI(baseURL: url, origin: "http://localhost"),
            identity: PaneExportIdentity(), deviceID: UUID().uuidString.lowercased(),
            socketBaseURL: url, origin: "http://localhost")
        let data = try Data(contentsOf: URL(fileURLWithPath: "contracts/fixtures/golden/snapshot-blocks.json"))
        let snapshot = try JSONDecoder().decode(WireSnapshot.self, from: data)
        publisher.start(title: "queue regression")
        publisher.publish(snapshot)
        try await Task.sleep(for: .seconds(2))
        guard publisher.isLive else { fatalError("Publisher did not connect: \(publisher.state)") }
        let captured = try Data(contentsOf: output)
        let frames = try JSONSerialization.jsonObject(with: captured) as! [[String: Any]]
        precondition(frames.map { $0["type"] as! String } == ["auth", "hello", "snapshot.begin", "snapshot.chunk", "snapshot.end"])
        precondition(frames.dropFirst().allSatisfy { $0["epoch"] as? String == "7" })
        let chunk = frames.first { $0["type"] as? String == "snapshot.chunk" }!
        let payload = Data(base64Encoded: chunk["data"] as! String)!
        let delivered = try JSONDecoder().decode(WireSnapshot.self, from: payload)
        var expected = snapshot
        expected.epoch = "7"
        precondition(delivered == expected, "The initial snapshot must arrive intact")
        publisher.stop()
        print("PASS: native publisher retains pre-connect snapshot; auth → hello → complete snapshot, ticket epoch 7")
    }

    static let relay = #"""
    const http = require('http');
    const { WebSocketServer } = require(process.cwd() + '/backend/node_modules/ws');
    const fs = require('fs');
    const frames = [];
    const server = http.createServer((req,res) => {
      res.setHeader('content-type','application/json');
      if (req.url === '/live' && req.method === 'POST') {
        setTimeout(() => res.end(JSON.stringify({session_id:'00000000-0000-4000-8000-000000000001'})), 300);
      } else if (req.url.endsWith('/tickets')) res.end(JSON.stringify({ticket:'test-ticket',epoch:'7',role:'publisher',lease_token:'test-lease'}));
      else res.end('{}');
    });
    const wss = new WebSocketServer({server});
    wss.on('connection', socket => socket.on('message', raw => {
      const frame = JSON.parse(raw.toString());
      frames.push(frame);
      if (frames.length === 1 && frame.type !== 'auth') socket.close(4400);
      if (frame.type === 'auth') socket.send(JSON.stringify({type:'viewer.count',epoch:'7',count:0}));
      if (frame.type === 'snapshot.end') fs.writeFileSync(process.argv[1], JSON.stringify(frames));
    }));
    server.listen(0,'127.0.0.1', () => process.stdout.write(String(server.address().port)+'\n'));
    """#
}
