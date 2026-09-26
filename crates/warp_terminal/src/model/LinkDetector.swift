import Foundation

/// The kind of link detected on a terminal line.
enum DetectedLinkKind: Hashable, Sendable {
    case url(URL)
    case filePath(path: String, line: Int?, column: Int?)
    case gitCommit(hash: String)
}

/// A detected interactive link span on a line of terminal text.
struct DetectedLink: Hashable, Sendable {
    let kind: DetectedLinkKind
    /// The column range (in character indices) within the scanned line.
    let range: Range<Int>
    let text: String

    var tooltipText: String {
        switch kind {
        case .url:
            return "Open link"
        case .filePath:
            return "Open file"
        case .gitCommit:
            return "Open commit"
        }
    }
}

/// Scans terminal grid lines for URLs, file paths with line/column numbers, and git commit hashes.
///
/// Matches Warp's link detection rules (`app/src/terminal/view/link_detection.rs`):
/// - Strips Git diff prefixes (`a/`, `b/`)
/// - Strips trailing sentence punctuation (`.`, `,`, `:`, `;`, `!`, `?`)
/// - Parses `:line:col` and `:line` suffixes
/// - Rejects spurious substrings and validates URL / path structures
struct LinkDetector: Sendable {
    private static let prefixesToRemove = ["a/", "b/"]
    private static let suffixesToRemove = ["@"]

    private static let trailingPunctuationChars: Set<Character> = [
        ".", ",", ":", ";", "!", "?", "'", "\"", ")", "]", ">", "}",
    ]

    // Precompiled regular expressions for high throughput.
    private static let urlRegex: NSRegularExpression = {
        let pattern = #"(https?://[^\s<>"'{}|\\^`]+)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let filePathRegex: NSRegularExpression = {
        // Matches paths like /foo/bar, ~/foo/bar, ./foo/bar, ../foo/bar, foo/bar.swift:42:10, file.swift:10
        let pattern = #"(?:(?:/|~/|\./|\.\./|[a-zA-Z0-9_\-\.]+/)?[a-zA-Z0-9_\-\.]+(?:/[a-zA-Z0-9_\-\.]+)+|(?:[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+))(?::\d+(?::\d+)?)?"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let gitHashRegex: NSRegularExpression = {
        // Hex commit hashes between 7 and 40 characters bounded by word boundaries or punctuation
        let pattern = #"\b([0-9a-fA-F]{7,40})\b"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Scans a full line of text and returns all detected links in column order.
    static func scanLine(_ line: String) -> [DetectedLink] {
        guard !line.isEmpty else { return [] }
        var detected: [DetectedLink] = []
        var occupiedRanges: [Range<Int>] = []

        func overlapsWithExisting(_ range: Range<Int>) -> Bool {
            for existing in occupiedRanges {
                if range.overlaps(existing) { return true }
            }
            return false
        }

        // 1. Scan for URLs (highest priority)
        let nsString = line as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        urlRegex.enumerateMatches(in: line, options: [], range: fullRange) { match, _, _ in
            guard let matchRange = match?.range, let swiftRange = Range(matchRange, in: line) else { return }
            var candidate = String(line[swiftRange])
            var candidateLength = candidate.count

            // Trim trailing sentence punctuation unless part of the URL (e.g. balanced parens)
            while let lastChar = candidate.last, trailingPunctuationChars.contains(lastChar) {
                // If closing parenthesis and URL contains opening parenthesis, keep it
                if lastChar == ")" && candidate.contains("(") {
                    break
                }
                candidate.removeLast()
                candidateLength -= 1
            }

            guard candidateLength > 0, let url = URL(string: candidate), url.scheme != nil else { return }
            let startIndex = line.distance(from: line.startIndex, to: swiftRange.lowerBound)
            let colRange = startIndex..<(startIndex + candidateLength)
            if !overlapsWithExisting(colRange) {
                detected.append(DetectedLink(kind: .url(url), range: colRange, text: candidate))
                occupiedRanges.append(colRange)
            }
        }

        // 2. Scan for file paths with optional line:col
        filePathRegex.enumerateMatches(in: line, options: [], range: fullRange) { match, _, _ in
            guard let matchRange = match?.range, let swiftRange = Range(matchRange, in: line) else { return }
            var candidate = String(line[swiftRange])
            var candidateLength = candidate.count

            // Strip trailing sentence punctuation
            while let lastChar = candidate.last, trailingPunctuationChars.contains(lastChar) {
                candidate.removeLast()
                candidateLength -= 1
            }

            for suffix in suffixesToRemove {
                if candidate.hasSuffix(suffix) {
                    candidate.removeLast(suffix.count)
                    candidateLength -= suffix.count
                }
            }

            guard candidateLength > 0 else { return }
            var pathString = candidate
            var prefixOffset = 0

            // Strip git diff prefixes ("a/", "b/")
            for prefix in prefixesToRemove {
                if pathString.hasPrefix(prefix) {
                    pathString = String(pathString.dropFirst(prefix.count))
                    prefixOffset += prefix.count
                    break
                }
            }

            let parsed = parsePathAndPosition(pathString)
            // Ensure path looks like a plausible file or directory
            guard isPlausibleFilePath(parsed.path) else { return }

            let startIndex = line.distance(from: line.startIndex, to: swiftRange.lowerBound) + prefixOffset
            let colRange = startIndex..<(startIndex + (candidateLength - prefixOffset))
            guard colRange.count > 0, !overlapsWithExisting(colRange) else { return }

            detected.append(
                DetectedLink(
                    kind: .filePath(path: parsed.path, line: parsed.line, column: parsed.column),
                    range: colRange,
                    text: candidate
                )
            )
            occupiedRanges.append(colRange)
        }

        // 3. Scan for Git commit hashes
        gitHashRegex.enumerateMatches(in: line, options: [], range: fullRange) { match, _, _ in
            guard let matchRange = match?.range, let swiftRange = Range(matchRange, in: line) else { return }
            let hashString = String(line[swiftRange])
            let startIndex = line.distance(from: line.startIndex, to: swiftRange.lowerBound)
            let colRange = startIndex..<(startIndex + hashString.count)

            guard !overlapsWithExisting(colRange) else { return }
            // Filter out pure numbers or common false positives if not hexadecimal
            if hashString.allSatisfy({ $0.isHexDigit }) {
                detected.append(DetectedLink(kind: .gitCommit(hash: hashString), range: colRange, text: hashString))
                occupiedRanges.append(colRange)
            }
        }

        return detected.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Finds the detected link covering a specific character column on the line.
    static func link(at column: Int, in line: String) -> DetectedLink? {
        let links = scanLine(line)
        return links.first { $0.range.contains(column) }
    }

    // MARK: - Path Helpers

    private static func parsePathAndPosition(_ text: String) -> (path: String, line: Int?, column: Int?) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let line = Int(parts[parts.count - 2]), let col = Int(parts[parts.count - 1]) {
            let path = parts.dropLast(2).joined(separator: ":")
            return (path, line, col)
        } else if parts.count >= 2, let line = Int(parts[parts.count - 1]) {
            let path = parts.dropLast(1).joined(separator: ":")
            return (path, line, nil)
        }
        return (text, nil, nil)
    }

    private static func isPlausibleFilePath(_ path: String) -> Bool {
        // Exclude standalone dots or empty paths
        guard !path.isEmpty, path != ".", path != ".." else { return false }
        // Must contain either a slash, a tilde, or a file extension
        if path.contains("/") || path.hasPrefix("~") { return true }
        if let dotIndex = path.lastIndex(of: "."), dotIndex != path.startIndex, dotIndex != path.index(before: path.endIndex) {
            let ext = path[path.index(after: dotIndex)...]
            // Valid alphanumeric file extension between 1 and 8 characters
            return ext.count >= 1 && ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return false
    }
}
