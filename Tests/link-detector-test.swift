import Foundation

@main
enum LinkDetectorTest {
    static func main() {
        let harness = Harness("link-detector-test")

        testUrlDetection(harness)
        testFilePathDetection(harness)
        testGitCommitHashDetection(harness)

        harness.finish()
    }

    private static func testUrlDetection(_ harness: Harness) {
        let line1 = "Check out https://warp.dev for more details."
        let links1 = LinkDetector.scanLine(line1)
        harness.equal(links1.count, 1, "Should find 1 URL")
        harness.equal(links1[0].text, "https://warp.dev", "URL should have trimmed trailing period")
        if case .url(let url) = links1[0].kind {
            harness.equal(url.absoluteString, "https://warp.dev", "URL string should match")
        } else {
            harness.expect(false, "Expected .url kind")
        }

        // URL with query and balanced parentheses
        let line2 = "Read https://en.wikipedia.org/wiki/Terminal_(software) please!"
        let links2 = LinkDetector.scanLine(line2)
        harness.equal(links2.count, 1, "Should find 1 URL with parens")
        harness.equal(links2[0].text, "https://en.wikipedia.org/wiki/Terminal_(software)", "Balanced parens preserved")

        // Link at specific column
        let target = LinkDetector.link(at: 15, in: line1)
        harness.equal(target?.text, "https://warp.dev", "Should find URL at column 15")
    }

    private static func testFilePathDetection(_ harness: Harness) {
        // Relative path with line and column
        let line1 = "Error at crates/warp_terminal/src/VTParser.swift:42:15: unexpected token"
        let links1 = LinkDetector.scanLine(line1)
        harness.equal(links1.count, 1, "Should find file path")
        if case .filePath(let path, let line, let col) = links1[0].kind {
            harness.equal(path, "crates/warp_terminal/src/VTParser.swift", "Path matches")
            harness.equal(line, 42, "Line matches")
            harness.equal(col, 15, "Col matches")
        } else {
            harness.expect(false, "Expected .filePath kind")
        }

        // Git diff prefix stripping (a/ or b/)
        let line2 = "--- a/app/src/AppDelegate.swift"
        let links2 = LinkDetector.scanLine(line2)
        harness.equal(links2.count, 1, "Should find file path in diff")
        if case .filePath(let path, _, _) = links2[0].kind {
            harness.equal(path, "app/src/AppDelegate.swift", "Prefix a/ stripped")
        } else {
            harness.expect(false, "Expected .filePath kind")
        }

        // Path ending with sentence punctuation
        let line3 = "Inspect ./Scripts/run-tests.sh, then run it."
        let links3 = LinkDetector.scanLine(line3)
        harness.equal(links3.count, 1, "Should find path without trailing comma")
        if case .filePath(let path, _, _) = links3[0].kind {
            harness.equal(path, "./Scripts/run-tests.sh", "Trailing comma stripped")
        } else {
            harness.expect(false, "Expected .filePath kind")
        }
    }

    private static func testGitCommitHashDetection(_ harness: Harness) {
        let line = "Merge commit 313cde6a91 into main branch"
        let links = LinkDetector.scanLine(line)
        harness.equal(links.count, 1, "Should find git commit hash")
        harness.equal(links[0].text, "313cde6a91", "Hash text matches")
        if case .gitCommit(let hash) = links[0].kind {
            harness.equal(hash, "313cde6a91", "Hash value matches")
        } else {
            harness.expect(false, "Expected .gitCommit kind")
        }
    }
}
