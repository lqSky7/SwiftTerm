import Foundation

/// Subsequence fuzzy matcher following Warp's `fuzzy_match` algorithm.
///
/// Smart-case: case-insensitive if query contains no uppercase characters; case-sensitive otherwise.
/// Calculates bonus scores for consecutive character matches, word boundaries (after `/`, `-`, `_`, `.`, or space),
/// and prefix alignment.
struct FuzzyMatchResult: Equatable {
    var score: Int
    var isMatch: Bool

    static let noMatch = FuzzyMatchResult(score: 0, isMatch: false)
}

enum FuzzyMatcher {
    /// Matches `pattern` against `text` using subsequence alignment.
    /// Returns `nil` if `pattern` is not a subsequence of `text`.
    static func match(text: String, pattern: String) -> FuzzyMatchResult? {
        guard !pattern.isEmpty else {
            return FuzzyMatchResult(score: 0, isMatch: true)
        }
        guard !text.isEmpty else {
            return nil
        }

        // Smart-case decision
        let hasUpper = pattern.contains { $0.isUppercase }
        let target = hasUpper ? text : text.lowercased()
        let query = hasUpper ? pattern : pattern.lowercased()

        let textChars = Array(target)
        let queryChars = Array(query)

        var tIdx = 0
        var qIdx = 0

        var score = 0
        var consecutiveCount = 0
        var firstMatchIdx: Int?

        while tIdx < textChars.count && qIdx < queryChars.count {
            let tc = textChars[tIdx]
            let qc = queryChars[qIdx]

            if tc == qc {
                if firstMatchIdx == nil {
                    firstMatchIdx = tIdx
                    if tIdx == 0 {
                        score += 35 // Prefix match bonus
                    }
                }

                var charScore = 10

                // Word boundary bonus
                if tIdx == 0 {
                    charScore += 20
                } else {
                    let prev = textChars[tIdx - 1]
                    if prev == "/" || prev == "-" || prev == "_" || prev == "." || prev.isWhitespace {
                        charScore += 25
                    }
                }

                // Consecutive match bonus
                if consecutiveCount > 0 {
                    charScore += (consecutiveCount * 15)
                }
                consecutiveCount += 1

                score += charScore
                qIdx += 1
            } else {
                consecutiveCount = 0
            }

            tIdx += 1
        }

        guard qIdx == queryChars.count else {
            return nil // Pattern was not fully matched as a subsequence
        }

        // Exact match bonus
        if text.count == pattern.count {
            score += 50
        } else {
            // Distance penalty to favor shorter, tighter matches
            let spread = tIdx - (firstMatchIdx ?? 0)
            score -= (spread - queryChars.count) * 2
            score -= (textChars.count - queryChars.count)
        }

        return FuzzyMatchResult(score: max(1, score), isMatch: true)
    }

    /// Convenience for sorting strings by fuzzy match score against a query.
    static func score(text: String, pattern: String) -> Int? {
        match(text: text, pattern: pattern)?.score
    }
}
