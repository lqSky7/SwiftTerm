import Foundation

struct RemoteCompletion {
    var files: [DirectoryEntry] = []
    var commands: [String] = []

    init(encoded: String) {
        guard encoded.utf8.count <= 54_000, let data = Data(base64Encoded: encoded), data.count <= 40_000 else { return }
        var start = data.startIndex
        for end in data.indices where data[end] == 0 {
            let record = data[start..<end]
            start = end + 1
            guard let kind = record.first, record.count > 1 else { continue }
            guard let name = String(bytes: record.dropFirst(), encoding: .utf8) else { continue }
            guard !name.contains("/"), name != ".", name != ".." else { continue }
            if kind == 99 { commands.append(name) } else if kind == 100 || kind == 102 {
                files.append(DirectoryEntry(name: name, isDirectory: kind == 100))
            }
        }
    }
}
