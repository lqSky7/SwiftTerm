import Foundation

/// Guards the facts the chips are built from.
///
/// All three of these read the file system rather than a shell, which is the whole point: a temporary
/// directory is a real repository as far as this is concerned, so the assertions below are about real
/// behaviour and not about a stub. Nothing here needs a window server, a shell or a prompt.
@main
enum ContextChipsTest {
    static func main() {
        let harness = Harness("context-chips-test")

        let scratch = Scratch()
        defer { scratch.remove() }

        repository(harness, scratch)
        projectKind(harness, scratch)
        tagging(harness)
        chips(harness, scratch)

        harness.finish()
    }

    /// A temporary directory to build fake repositories in.
    private struct Scratch {
        let root: URL

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftterm-chips-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func directory(_ path: String) -> String {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        @discardableResult
        func file(_ path: String, _ contents: String = "") -> String {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    private static func repository(_ harness: Harness, _ scratch: Scratch) {
        let repo = scratch.directory("repo")
        scratch.file("repo/.git/HEAD", "ref: refs/heads/main\n")

        let metadata = RepoMetadata.inspect(directory: repo)
        harness.equal(metadata.repositoryRoot, repo, "a .git directory is a repository")
        harness.equal(metadata.branch, "main", "and its HEAD names the branch")

        // The whole point of walking up: a shell three directories deep is still on the branch.
        let deep = scratch.directory("repo/sources/nested/deeper")
        harness.equal(
            RepoMetadata.inspect(directory: deep).branch, "main",
            "a directory inside the repository finds it")

        // A branch name may contain a slash, and everything after `refs/heads/` is the name.
        let feature = scratch.directory("feature")
        scratch.file("feature/.git/HEAD", "ref: refs/heads/feature/chips\n")
        harness.equal(
            RepoMetadata.inspect(directory: feature).branch, "feature/chips",
            "a branch with a slash in it keeps the whole name")

        // Detached: HEAD is a commit, and the short form is what a person recognises.
        let detached = scratch.directory("detached")
        scratch.file(
            "detached/.git/HEAD",
            "9fceb02d0ae598e95dc970b74767f19372d61af8\n")
        harness.equal(
            RepoMetadata.inspect(directory: detached).branch, "9fceb02",
            "a detached HEAD reports the short commit")

        // A worktree or submodule has a `.git` *file* pointing at the real directory.
        let real = scratch.directory("real-git")
        scratch.file("real-git/HEAD", "ref: refs/heads/worktree-branch\n")
        let worktree = scratch.directory("worktree")
        scratch.file("worktree/.git", "gitdir: \(real)\n")
        harness.equal(
            RepoMetadata.inspect(directory: worktree).branch, "worktree-branch",
            "a worktree's .git file is followed to the real directory")

        let plain = scratch.directory("not-a-repo")
        let empty = RepoMetadata.inspect(directory: plain)
        harness.equal(empty.repositoryRoot, nil, "a directory with no .git above it is not a repository")
        harness.equal(empty.branch, nil, "and has no branch")
        harness.equal(empty, RepoMetadata.empty, "which is what empty looks like")

        // A .git with no readable HEAD is a repository with an unknown branch, not a crash.
        let broken = scratch.directory("broken")
        scratch.directory("broken/.git")
        harness.equal(
            RepoMetadata.inspect(directory: broken).branch, nil, "a repository with no HEAD has no branch")
        harness.equal(
            RepoMetadata.inspect(directory: broken).repositoryRoot, broken,
            "but it is still a repository")
    }

    private static func projectKind(_ harness: Harness, _ scratch: Scratch) {
        let swift = scratch.directory("swift-project")
        scratch.file("swift-project/Package.swift", "// swift-tools-version: 6.2\n")
        harness.equal(RepoMetadata.inspect(directory: swift).projectKind, .swift, "Package.swift is Swift")

        let rust = scratch.directory("rust-project")
        scratch.file("rust-project/Cargo.toml", "[package]\n")
        harness.equal(RepoMetadata.inspect(directory: rust).projectKind, .rust, "Cargo.toml is Rust")

        let node = scratch.directory("node-project")
        scratch.file("node-project/package.json", "{}\n")
        harness.equal(RepoMetadata.inspect(directory: node).projectKind, .node, "package.json is Node")

        // The nearest manifest wins, so a front end inside a Rust repository is a Node project where
        // you are standing.
        let nested = scratch.directory("rust-project/web")
        scratch.file("rust-project/web/package.json", "{}\n")
        harness.equal(
            RepoMetadata.inspect(directory: nested).projectKind, .node,
            "the nearest manifest is the project you are in")

        // A manifest and a repository are found independently, and are allowed to differ.
        let mixed = scratch.directory("mixed/inner")
        scratch.file("mixed/.git/HEAD", "ref: refs/heads/main\n")
        scratch.file("mixed/inner/go.mod", "module example\n")
        let metadata = RepoMetadata.inspect(directory: mixed)
        harness.equal(metadata.branch, "main", "the repository is found from a level up")
        harness.equal(metadata.projectKind, .go, "and the manifest from the level below")
    }

    private static func tagging(_ harness: Harness) {
        var table = DirectoryColorTag.Table.empty
        harness.equal(table.isEmpty, true, "an empty table tags nothing")
        harness.equal(table.tag(for: "/anything"), nil, "and says so")

        table.tag("/Users/me/work", as: DirectoryColorTag(paletteIndex: 1))
        harness.equal(
            table.tag(for: "/Users/me/work")?.paletteIndex, 1, "a tagged directory is tagged")
        harness.equal(
            table.tag(for: "/Users/me/work/api")?.paletteIndex, 1, "so is everything under it")
        harness.equal(
            table.tag(for: "/Users/me/work/api/deep/file.swift")?.paletteIndex, 1, "however deep")

        // The one that a string prefix would get wrong.
        harness.equal(
            table.tag(for: "/Users/me/workshop"), nil,
            "a sibling whose name starts the same is not inside it")

        // Longest prefix wins, so the more specific tag is the one that applies.
        table.tag("/Users/me/work/api", as: DirectoryColorTag(paletteIndex: 4))
        harness.equal(
            table.tag(for: "/Users/me/work/api")?.paletteIndex, 4, "the more specific tag wins")
        harness.equal(
            table.tag(for: "/Users/me/work/web")?.paletteIndex, 1, "and the less specific one still applies")

        // A trailing slash is not part of a path's identity.
        var slashes = DirectoryColorTag.Table.empty
        slashes.tag("/tmp/project/", as: DirectoryColorTag(paletteIndex: 2))
        harness.equal(
            slashes.tag(for: "/tmp/project")?.paletteIndex, 2, "a tag stored with a slash still matches")

        slashes.untag("/tmp/project/")
        harness.equal(slashes.tag(for: "/tmp/project"), nil, "and untagging it takes it away")

        // A slot is one of the palette's sixteen, and a caller cannot ask for a seventeenth.
        harness.equal(DirectoryColorTag(paletteIndex: 99).paletteIndex, 15, "a slot above the palette clamps")
        harness.equal(DirectoryColorTag(paletteIndex: -3).paletteIndex, 0, "and so does one below it")
    }

    private static func chips(_ harness: Harness, _ scratch: Scratch) {
        let home = "/Users/example"
        let repo = scratch.directory("chips-repo")
        scratch.file("chips-repo/.git/HEAD", "ref: refs/heads/main\n")
        let metadata = RepoMetadata.inspect(directory: repo)

        // The directory is always the first chip, and it is always there — it is the one fact that is
        // never unknown, and the chip row is what replaced the shell's prompt.
        let plain = ContextChips.forPrompt(directory: home, home: home)
        harness.equal(plain.count, 1, "outside a repository there is one chip")
        harness.equal(plain[0].kind, .directory, "which is the directory")
        harness.equal(plain[0].text, "~", "abbreviated against home")

        let inside = ContextChips.forPrompt(directory: repo, metadata: metadata, home: home)
        harness.equal(inside.count, 2, "inside a repository there is a second")
        harness.equal(inside[1].kind, .branch, "which is the branch")
        harness.equal(inside[1].text, "main", "naming it")

        let withEnvironment = ContextChips.forPrompt(
            directory: repo, metadata: metadata, environment: ".venv", home: home)
        harness.equal(withEnvironment.count, 3, "the shell's own fact is a third")
        harness.equal(withEnvironment[2].kind, .environment, "an environment")
        harness.equal(withEnvironment[2].text, ".venv", "naming it")
        harness.equal(
            withEnvironment.map(\.kind), [.directory, .branch, .environment],
            "and the order is Warp's: where you are, what you are on, what you are inside")

        // A directory under home keeps the abbreviation, and one outside it is left alone.
        harness.equal(
            ContextChips.forPrompt(directory: home + "/src/app", home: home)[0].text, "~/src/app",
            "a directory under home is abbreviated")
        harness.equal(
            ContextChips.forPrompt(directory: "/opt/build", home: home)[0].text, "/opt/build",
            "and one outside it is not")
        // The prefix trap: `/Users/example2` is not under `/Users/example`.
        harness.equal(
            ContextChips.forPrompt(directory: "/Users/example2", home: home)[0].text,
            "/Users/example2",
            "a sibling whose name starts the same is not abbreviated")

        // An empty environment is not a chip, and neither is a repository whose branch is unknown.
        harness.equal(
            ContextChips.forPrompt(directory: home, environment: "", home: home).count, 1,
            "an empty environment says nothing")
        let branchless = RepoMetadata(repositoryRoot: repo, branch: nil, projectKind: nil)
        harness.equal(
            ContextChips.forPrompt(directory: home, metadata: branchless, home: home).count, 1,
            "and a repository with no readable branch has no chip to show")
    }
}
