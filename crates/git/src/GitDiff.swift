import Foundation

struct GitFileChange: Identifiable, Equatable, Sendable {
    enum Scope: String, Sendable { case unstaged, staged, untracked }
    let path: String
    let scope: Scope
    let added: Int
    let removed: Int
    let binary: Bool
    var id: String { scope.rawValue + "\0" + path }
}

struct GitSummary: Equatable, Sendable {
    var files: [GitFileChange] = []
    var isLimited = false
    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
    var label: String { "(+\(added) -\(removed))" + (isLimited ? "…" : "") }

    static func parse(_ data: Data, scope: GitFileChange.Scope) -> [GitFileChange] {
        let complete = data.prefix((data.lastIndex(of: 0).map { $0 + 1 }) ?? 0)
        return complete.split(separator: 0).compactMap { record in
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                let added = String(bytes: fields[0], encoding: .utf8),
                let removed = String(bytes: fields[1], encoding: .utf8),
                let path = String(bytes: fields[2], encoding: .utf8) else { return nil }
            return GitFileChange(path: path, scope: scope,
                added: Int(added) ?? 0, removed: Int(removed) ?? 0, binary: added == "-" || removed == "-")
        }
    }
}

struct GitDiffDocument: Sendable {
    enum Kind: Sendable { case context, added, removed, header }
    struct Row: Sendable {
        let bytes: Range<Int>
        let kind: Kind
        let oldLine: Int?
        let newLine: Int?
    }
    static let byteLimit = 4_375_000
    static let rowLimit = 50_000
    static let largeByteLimit = 2_187_500
    let id = UUID()
    let data: Data
    let rows: [Row]
    let isLimited: Bool
    var maximumRowBytes: Int { rows.lazy.map { $0.bytes.count }.max() ?? 0 }
    var isLarge: Bool { data.count >= Self.largeByteLimit || rows.count > 10_000 }

    init(data: Data, limited: Bool = false) {
        self.data = Data(data.prefix(Self.byteLimit))
        var rows: [Row] = []
        var start = 0
        var old = 0
        var new = 0
        var hunk = false
        var rowsLimited = false
        for end in 0...self.data.count where end == self.data.count || self.data[end] == 10 {
            guard end > start else { start = end + 1; continue }
            if rows.count == Self.rowLimit { rowsLimited = true; break }
            let range = start..<end
            let first = self.data[start]
            var kind = Kind.header
            var oldLine: Int?
            var newLine: Int?
            if first == 64 {
                let header = String(bytes: self.data[range], encoding: .utf8) ?? ""
                let fields = header.split(separator: " ")
                if fields.count >= 3, fields[0] == "@@" {
                    old = Int(String(fields[1].dropFirst().split(separator: ",").first ?? "")) ?? 0
                    new = Int(String(fields[2].dropFirst().split(separator: ",").first ?? "")) ?? 0
                    hunk = true
                }
            } else if hunk {
                switch first {
                case 43: kind = .added; newLine = new; new += 1
                case 45: kind = .removed; oldLine = old; old += 1
                case 32: kind = .context; oldLine = old; newLine = new; old += 1; new += 1
                default: break
                }
            }
            rows.append(Row(bytes: range, kind: kind, oldLine: oldLine, newLine: newLine))
            start = end + 1
        }
        self.rows = rows
        isLimited = limited || rowsLimited || data.count > Self.byteLimit
    }

    func text(at index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let bytes = rows[index].bytes
        let end = min(bytes.upperBound, bytes.lowerBound + 20_000)
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data[bytes.lowerBound..<end], as: UTF8.self)
            + (end < bytes.upperBound ? " … [long line clipped]" : "")
    }
}
