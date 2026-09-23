import Foundation

/// What the filesystem says about the directory a shell is sitting in.
///
/// Warp gets all of this from its shell hooks (`warp_features.md` #5): `precmd` gathers `$PWD`, the git
/// branch, the virtualenv and the node version, hex-encodes them and ships them over a DCS channel. It
/// has to, because its hooks run in a process it does not control.
///
/// Most of it is a file read from here. A repository's branch is the contents of `.git/HEAD` and a
/// project's kind is which manifest is present, so this costs no process spawn per prompt — and it can
/// be tested in a harness with a temporary directory instead of a real repository.
///
/// What it deliberately does *not* answer: how far ahead or behind the branch is, and how many files
/// are dirty. Those are not in a file, and a count that is wrong is worse than a count that is absent.
struct RepoMetadata: Equatable {
    enum ProjectKind: String, Equatable, CaseIterable {
        case swift = "Swift"
        case rust = "Rust"
        case node = "Node"
        case python = "Python"
        case go = "Go"
        case ruby = "Ruby"
    }

    /// The repository root, when the directory is inside one.
    var repositoryRoot: String?
    /// The branch name, or the short commit when the repository is on a detached HEAD.
    var branch: String?
    /// What kind of project the root holds, from the manifest it carries.
    var projectKind: ProjectKind?

    static let empty = RepoMetadata()

    /// Walks up from `directory`, taking the nearest of each thing it finds.
    ///
    /// The nearest manifest is the project the user is in; the nearest `.git` is the repository it
    /// belongs to. They are usually the same directory and are allowed not to be — a manifest inside a
    /// repository, or a repository with no manifest at all.
    static func inspect(directory: String, fileManager: FileManager = .default) -> RepoMetadata {
        var metadata = RepoMetadata()
        var current = URL(fileURLWithPath: directory).standardizedFileURL

        while true {
            if metadata.projectKind == nil,
                let kind = projectKind(in: current.path, fileManager: fileManager)
            {
                metadata.projectKind = kind
            }
            if metadata.repositoryRoot == nil,
                let gitDirectory = gitDirectory(in: current.path, fileManager: fileManager)
            {
                metadata.repositoryRoot = current.path
                metadata.branch = branch(inGitDirectory: gitDirectory, fileManager: fileManager)
            }
            if metadata.projectKind != nil, metadata.repositoryRoot != nil { break }

            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return metadata
    }

    /// A branch out of a `.git` directory's `HEAD`.
    ///
    /// `ref: refs/heads/main` while on a branch; a bare commit hash when detached, in which case the
    /// short commit is what a person recognises.
    static func branch(
        inGitDirectory gitDirectory: String, fileManager: FileManager = .default
    ) -> String? {
        let path = gitDirectory + "/HEAD"
        guard let head = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("ref:") else { return String(trimmed.prefix(7)) }

        let ref = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        let prefix = "refs/heads/"
        // Anything else — a tag, a remote ref — is reported as it is rather than guessed at.
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    /// `.git` is a directory in an ordinary clone and a *file* in a worktree or a submodule, holding
    /// `gitdir: <path>`. Both are a repository, and the pointer may be relative.
    private static func gitDirectory(in directory: String, fileManager: FileManager) -> String? {
        let path = directory + "/.git"
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return path }

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return target.hasPrefix("/") ? target : directory + "/" + target
    }

    /// The first manifest that is there. Ordered so that a repository with more than one is reported as
    /// the thing it most obviously is — a Swift package that also has a `package.json` is a Swift
    /// package with a web front end, not a Node project.
    private static let manifests: [(file: String, kind: ProjectKind)] = [
        ("Package.swift", .swift),
        ("Cargo.toml", .rust),
        ("go.mod", .go),
        ("pyproject.toml", .python),
        ("requirements.txt", .python),
        ("Gemfile", .ruby),
        ("package.json", .node),
    ]

    private static func projectKind(
        in directory: String, fileManager: FileManager
    ) -> ProjectKind? {
        for manifest in manifests
        where fileManager.fileExists(atPath: directory + "/" + manifest.file) {
            return manifest.kind
        }
        return nil
    }
}
