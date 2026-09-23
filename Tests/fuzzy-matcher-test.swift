import Foundation

/// Tests the subsequence fuzzy matching engine matching Warp's fuzzy matching semantics.
@main
enum FuzzyMatcherTest {
    static func main() {
        let harness = Harness("fuzzy-matcher-test")

        emptyInputs(harness)
        exactAndPrefixMatches(harness)
        subsequenceMatching(harness)
        boundaryAndConsecutiveBonuses(harness)
        smartCaseMatching(harness)

        harness.finish()
    }

    private static func emptyInputs(_ harness: Harness) {
        harness.expect(
            FuzzyMatcher.match(text: "git status", pattern: "")?.isMatch == true,
            "an empty pattern matches any text")
        harness.equal(
            FuzzyMatcher.match(text: "git status", pattern: "")?.score, 0,
            "empty pattern has score 0")
        harness.expect(
            FuzzyMatcher.match(text: "", pattern: "git") == nil,
            "matching against empty text yields nil")
    }

    private static func exactAndPrefixMatches(_ harness: Harness) {
        let exact = FuzzyMatcher.match(text: "checkout", pattern: "checkout")
        harness.expect(exact != nil && exact!.isMatch, "exact match succeeds")

        let prefix = FuzzyMatcher.match(text: "checkout", pattern: "check")
        harness.expect(prefix != nil && prefix!.isMatch, "prefix match succeeds")

        let nonPrefix = FuzzyMatcher.match(text: "checkout", pattern: "out")
        harness.expect(nonPrefix != nil && nonPrefix!.isMatch, "subsequence match succeeds")

        harness.expect(
            exact!.score > prefix!.score,
            "exact match receives exact bonus and outscores prefix")
        harness.expect(
            prefix!.score > nonPrefix!.score,
            "prefix match receives prefix bonus and outscores non-prefix")
    }

    private static func subsequenceMatching(_ harness: Harness) {
        let match = FuzzyMatcher.match(text: "docker-compose.yml", pattern: "dcy")
        harness.expect(match != nil && match!.isMatch, "acronym subsequence dcy matches docker-compose.yml")

        let mismatch = FuzzyMatcher.match(text: "docker-compose.yml", pattern: "xyz")
        harness.expect(mismatch == nil, "mismatched subsequence yields nil")
    }

    private static func boundaryAndConsecutiveBonuses(_ harness: Harness) {
        // Boundary bonus: matching right after `-` or `/` scores higher than inside a word
        let boundaryMatch = FuzzyMatcher.match(text: "git-commit", pattern: "gc")
        let nonBoundaryMatch = FuzzyMatcher.match(text: "gitcommit", pattern: "gt")
        harness.expect(boundaryMatch != nil && nonBoundaryMatch != nil, "both are subsequences")
        harness.expect(
            boundaryMatch!.score > nonBoundaryMatch!.score,
            "boundary match receives word-boundary bonus")

        // Consecutive bonus: consecutive characters score higher than split characters
        let consecutive = FuzzyMatcher.match(text: "package-lock.json", pattern: "lock")
        let split = FuzzyMatcher.match(text: "package-lock.json", pattern: "pck")
        harness.expect(consecutive != nil && split != nil, "both are valid")
        harness.expect(
            consecutive!.score > split!.score,
            "consecutive characters receive consecutive match bonus")
    }

    private static func smartCaseMatching(_ harness: Harness) {
        // Lowercase query matches uppercase text (case-insensitive)
        let lowerQuery = FuzzyMatcher.match(text: "Calibre Library", pattern: "cal")
        harness.expect(lowerQuery != nil && lowerQuery!.isMatch, "lowercase query matches uppercase text")

        // Uppercase query requires exact case (smart-case)
        let upperMatching = FuzzyMatcher.match(text: "Calibre Library", pattern: "Cal")
        harness.expect(upperMatching != nil && upperMatching!.isMatch, "matching case succeeds")

        let upperMismatched = FuzzyMatcher.match(text: "calibre library", pattern: "Cal")
        harness.expect(upperMismatched == nil, "uppercase query rejects mismatched lowercase text")
    }
}
