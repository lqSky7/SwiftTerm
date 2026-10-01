import Foundation

// Export-only masking; the local terminal and live stream are never changed.
enum SecretRedaction {
    private static let patterns = [
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)\b[A-Za-z0-9_]*(?:password|passwd|secret|token|api[_-]?key|authorization)\b\s*[:=]\s*"#
            + #"(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})\b"#,
        #"(?i)(https?://)[^\s/:@]+:[^\s/@]+@"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
    ].map { pattern in
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid export redaction pattern")
        }
        return expression
    }

    static func mask(_ text: String) -> String {
        patterns.reduce(text) { value, regex in
            regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                           withTemplate: "[REDACTED]")
        }
    }
}
