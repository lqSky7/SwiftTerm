import Foundation

@main @MainActor enum GitReviewTest {
    static func main() async throws {
        let h = Harness("git-review-test")
        let parsed = GitSummary.parse(Data("2\t1\todd\tname\n.swift\0-\t-\timage\0".utf8), scope: .staged)
        h.equal(parsed.count, 2, "NUL records preserve unusual names")
        h.equal(parsed[0].path, "odd\tname\n.swift", "tabs/newlines retained")
        h.expect(parsed[1].binary, "binary numstat")
        let patch = GitDiffDocument(data: Data("@@ -2,2 +3,2 @@\n same\n-old\n+new\n@@ - + @@\n".utf8))
        h.equal(patch.rows[2].oldLine, 3, "deleted line number")
        h.equal(patch.rows[3].newLine, 4, "added line number")
        let large = GitDiffDocument(data: Data(repeating: 65, count: GitDiffDocument.byteLimit + 10))
        h.expect(large.isLarge && large.isLimited, "hard and soft limits")
        h.equal(large.data.count, GitDiffDocument.byteLimit, "bounded patch storage")
        h.expect(large.text(at: 0).count < 21_000, "bounded visible row decoding")
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftterm-git-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws { _ = try await GitRepositoryService.run(args, root: root.path) }
        try await git(["init", "--quiet"])
        try await git(["config", "user.name", "Harness"])
        try await git(["config", "user.email", "harness@example.invalid"])
        let path = ":literal name\n.txt"
        try "first\n".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        let initial = try await GitRepositoryService.summary(root: root.path)
        h.equal(initial.added, 1, "untracked line count")
        let untracked = initial.files[0]
        let untrackedDiff = try await GitRepositoryService.diff(root: root.path, file: untracked)
        h.expect(untrackedDiff.rows.contains { $0.kind == .added }, "untracked preview")
        try await GitRepositoryService.stage(root: root.path, file: untracked)
        var summary = try await GitRepositoryService.summary(root: root.path)
        h.equal(summary.files[0].scope, .staged, "stage literal path")
        try await GitRepositoryService.stage(root: root.path, file: summary.files[0])
        summary = try await GitRepositoryService.summary(root: root.path)
        h.equal(summary.files[0].scope, .untracked, "unstage unborn repository without deletion")
        try await git(["add", "--", path])
        try await git(["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
        try "second\nthird\n".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        try Data([1, 0, 2]).write(to: root.appending(path: "binary"))
        summary = try await GitRepositoryService.summary(root: root.path)
        h.equal(summary.added, 2, "working-tree addition total")
        h.equal(summary.removed, 1, "working-tree removal total")
        h.expect(summary.files.contains { $0.binary }, "untracked binary detection")
        let tracked = summary.files.first { $0.scope == .unstaged }!
        try await GitRepositoryService.stage(root: root.path, file: tracked)
        summary = try await GitRepositoryService.summary(root: root.path)
        let staged = summary.files.first { $0.scope == .staged }!
        try await GitRepositoryService.stage(root: root.path, file: staged)
        h.expect(FileManager.default.fileExists(atPath: root.appending(path: path).path), "unstage keeps worktree")
        let bounded = try await GitRepositoryService.run(["diff", "--", path], root: root.path, limit: 8)
        h.expect(bounded.limited && bounded.data.count == 8, "fast-exiting Git output still bounded")
        let cancelled = Task { try await GitRepositoryService.summary(root: root.path) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            h.expect(false, "cancelled reads fail")
        } catch is CancellationError { h.expect(true, "cancel propagated") }
        let review = CodeReviewCoordinator()
        defer { review.stop() }
        review.dragWidth(by: 10, available: 1_200)
        review.dragWidth(by: 20, available: 1_200)
        h.equal(review.sidebarWidth, 480, "width drag uses fixed origin for cumulative translations")
        review.endWidthDrag()
        review.dragWidth(by: -1_000, available: 1_200)
        h.equal(review.sidebarWidth, 240, "review minimum width")
        review.endWidthDrag()
        review.dragWidth(by: 2_000, available: 700)
        h.equal(review.width(available: 700), 700, "review preserves terminal space")
        h.equal(review.width(available: 100), 100, "narrow window bounds review")
        review.endWidthDrag()
        review.dragFilesHeight(by: 10, available: 600)
        review.dragFilesHeight(by: 20, available: 600)
        h.equal(review.fileListHeight, 210, "file split drag uses fixed origin")
        review.endFilesDrag()
        review.dragFilesHeight(by: 1_000, available: 600)
        h.equal(review.filesHeight(available: 600), 426, "file split reserves diff and handle space")
        h.equal(review.filesHeight(available: 100), 0, "small window never gives negative file height")
        review.endFilesDrag()
        review.refresh(directory: root.path)
        h.expect(await wait { review.summary.files.count == 2 }, "coordinator receives initial summary")
        review.select(tracked)
        h.expect(await wait { review.document != nil }, "selected patch loads")
        try await git(["add", "--", path])
        review.refresh(directory: root.path)
        h.expect(await wait { review.summary.files.contains { $0.scope == .staged } }, "git add refreshes index scope")
        h.expect(review.selected == nil && review.document == nil, "stage drops stale worktree preview")
        try await git(["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "second fixture"])
        review.refresh(directory: root.path)
        h.expect(await wait { review.summary.files.count == 1 && review.summary.files[0].binary },
                 "commit removes tracked changes from coordinator")
        h.equal(review.summary.label, "(+0 -0)", "commit updates pinned totals")
        h.finish()
    }
    static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }

}
