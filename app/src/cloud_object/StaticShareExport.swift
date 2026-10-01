import Foundation

struct StaticShareBlockDraft: Identifiable, Sendable {
    let id: String
    var selected = true
    var command: String
    var output: String
    let exitCode: Int?
    let durationMS: Int?
}

enum StaticShareExport {
    static func capture(_ blocks: [Block]) throws -> [StaticShareBlockDraft] {
        let sealed = Array(blocks.filter(\.isSealed).suffix(WireLimits.maxShareBlocks))
        guard !sealed.isEmpty, sealed.count <= WireLimits.maxShareBlocks else {
            throw WireError.invalidValue(path: "share.blocks", reason: "Select completed commands within the export limit")
        }
        var bytes = 0
        return try sealed.map { block in
            var lines: [String] = []
            for index in 0..<block.outputGrid.lineCount {
                guard let line = block.outputGrid.line(at: index) else { continue }
                let text = line.string()
                bytes += text.utf8.count + 1
                guard bytes <= WireLimits.maxShareBytes else {
                    throw WireError.oversized(path: "share", limit: WireLimits.maxShareBytes, actual: bytes)
                }
                lines.append(text)
            }
            return StaticShareBlockDraft(
                id: UUID().uuidString.lowercased(), command: block.command ?? "",
                output: lines.joined(separator: "\n"), exitCode: block.exitCode,
                durationMS: block.duration.map { max(0, Int($0 * 1000)) })
        }
    }

    static func redacted(_ drafts: [StaticShareBlockDraft]) -> [StaticShareBlockDraft] {
        drafts.map { original in
            var draft = original
            draft.command = SecretRedaction.mask(draft.command)
            draft.output = SecretRedaction.mask(draft.output)
            return draft
        }
    }

    static func snapshot(_ drafts: [StaticShareBlockDraft], id: String) throws -> WireShareSnapshot {
        let selected = drafts.filter(\.selected)
        guard !selected.isEmpty else {
            throw WireError.invalidValue(path: "share.blocks", reason: "Select at least one completed command")
        }
        let document = WireShareSnapshot(snapshotID: id,
            styles: [WireStyle(fg: .palette(index: 7), bg: .palette(index: 0), flags: 0)],
            blocks: selected.map { draft in
                WireShareBlock(id: draft.id, command: draft.command, exitCode: draft.exitCode,
                               durationMS: draft.durationMS,
                               lines: draft.output.components(separatedBy: "\n").map { WireShareLine(text: $0) })
            })
        try document.validate()
        return document
    }
}
