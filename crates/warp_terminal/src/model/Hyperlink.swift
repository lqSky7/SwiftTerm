import Foundation

/// An explicit hyperlink created via the OSC 8 terminal escape sequence (`\e]8;params;URI\e\`).
///
/// Matches Warp's `Hyperlink` model: holds an optional identifier (`id=...`) and the target URI string.
/// Pure Swift with zero UI framework dependencies.
struct Hyperlink: Hashable, Sendable, Codable {
    /// Maximum allowed byte length for a URI to prevent memory attacks.
    static let maxURILength = 2048

    var id: String?
    var uri: String

    init(id: String? = nil, uri: String) {
        self.id = (id?.isEmpty ?? true) ? nil : id
        self.uri = uri
    }

    /// Parses the raw OSC 8 body (`params;URI`).
    /// Returns `nil` when the URI is empty (which signifies the closing sequence `\e]8;;\e\`).
    static func parse(body: String) -> Hyperlink? {
        guard let separatorIndex = body.firstIndex(of: ";") else {
            return nil
        }
        let paramsString = String(body[..<separatorIndex])
        let uriString = String(body[body.index(after: separatorIndex)...])

        guard !uriString.isEmpty, uriString.utf8.count <= maxURILength else {
            return nil
        }

        let linkID = extractID(from: paramsString)
        return Hyperlink(id: linkID, uri: uriString)
    }

    /// Extracts the `id` value from semicolon or colon separated key-value pairs (e.g. `id=foo:bar=baz`).
    static func extractID(from params: String) -> String? {
        guard !params.isEmpty else { return nil }
        for token in params.split(whereSeparator: { $0 == ":" || $0 == ";" }) {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "id" {
                let idValue = String(pair[1]).trimmingCharacters(in: .whitespaces)
                return idValue.isEmpty ? nil : idValue
            }
        }
        return nil
    }
}
