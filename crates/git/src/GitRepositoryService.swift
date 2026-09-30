import Foundation
import Darwin

struct GitRepositoryService {
    enum Failure: Error, LocalizedError {
        case command(String)
        var errorDescription: String? { if case .command(let text) = self { text } else { nil } }
    }
    struct Output: Sendable { let data: Data; let limited: Bool }

    // Cancellation may terminate Process; the operation owns all other state.
    private final class Command: @unchecked Sendable {
        let process = Process()
        func stop() { if process.isRunning { process.terminate() } }
    }

    static func run(_ arguments: [String], root: String, limit: Int = 1_048_576,
                    allowed: [Int32] = [0]) async throws -> Output {
        let task = Task.detached(priority: .utility) {
            let command = Command()
            let directory = FileManager.default.temporaryDirectory.appending(path: "swiftterm-git-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appending(path: "stdout")
            let errorURL = directory.appending(path: "stderr")
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? errors.close() }
            let process = command.process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--literal-pathspecs", "-c", "core.quotepath=false", "-c", "core.pager=cat"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try process.run()
                let deadline = ContinuousClock.now + .seconds(15)
                var limited = false
                do {
                    while process.isRunning {
                        try Task.checkCancellation()
                        let size = try output.offset()
                        if size > UInt64(limit) { limited = true; command.stop(); break }
                        guard ContinuousClock.now < deadline else { throw Failure.command("Git operation timed out") }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                } catch {
                    command.stop()
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw error
                }
                if limited {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                while process.isRunning { await Task.yield() }
                let reader = try FileHandle(forReadingFrom: outputURL)
                defer { try? reader.close() }
                let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
                limited = limited || size > limit
                let data = try reader.read(upToCount: limit) ?? Data()
                if !limited, !allowed.contains(process.terminationStatus) {
                    let reader = try FileHandle(forReadingFrom: errorURL)
                    defer { try? reader.close() }
                    let diagnostic = try reader.read(upToCount: 4096) ?? Data()
                    let message = String(data: diagnostic, encoding: .utf8) ?? "Git returned non-UTF-8 diagnostics"
                    throw Failure.command(message.isEmpty ? "Git exited \(process.terminationStatus)" : message)
                }
                return Output(data: data, limited: limited)
            } onCancel: { command.stop() }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func summary(root: String) async throws -> GitSummary {
        var summary = GitSummary()
        for scope in [GitFileChange.Scope.unstaged, .staged] {
            var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat", "-z"]
            if scope == .staged { args.append("--cached") }
            let output = try await run(args, root: root)
            summary.files += GitSummary.parse(output.data, scope: scope)
            summary.isLimited = summary.isLimited || output.limited || String(data: output.data, encoding: .utf8) == nil
        }
        let untracked = try await run(["ls-files", "--others", "--exclude-standard", "-z"], root: root)
        summary.isLimited = summary.isLimited || untracked.limited
        let complete = untracked.data.prefix((untracked.data.lastIndex(of: 0).map { $0 + 1 }) ?? 0)
        let paths = complete.split(separator: 0)
        var readBudget = 16 * 1_048_576
        for bytes in paths.prefix(10_000) {
            try Task.checkCancellation()
            guard let path = String(bytes: bytes, encoding: .utf8) else {
                summary.isLimited = true
                continue
            }
            let url = URL(fileURLWithPath: root).appending(path: path)
            var lines = 0
            var binary = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                lines = 1
            } else if readBudget > 0, let file = try? FileHandle(forReadingFrom: url) {
                defer { try? file.close() }
                var last: UInt8?
                var bytesRead = 0
                while bytesRead < min(readBudget, 4_375_000) {
                    try Task.checkCancellation()
                    let remaining = min(readBudget, GitDiffDocument.byteLimit) - bytesRead
                    let chunk = try file.read(upToCount: min(65_536, remaining)) ?? Data()
                    if chunk.isEmpty { break }
                    bytesRead += chunk.count
                    if chunk.contains(0) { binary = true; break }
                    lines += chunk.lazy.filter { $0 == 10 }.count
                    last = chunk.last
                }
                if !binary, let last, last != 10 { lines += 1 }
                readBudget -= bytesRead
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                if !binary, bytesRead < size { summary.isLimited = true }
            } else { summary.isLimited = true }
            summary.files.append(GitFileChange(path: path, scope: .untracked,
                added: binary ? 0 : lines, removed: 0, binary: binary))
        }
        if paths.count > 10_000 || summary.files.count > 10_000 { summary.isLimited = true }
        summary.files = Array(summary.files.prefix(10_000))
        return summary
    }

    static func diff(root: String, file: GitFileChange) async throws -> GitDiffDocument {
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=4"]
        if file.scope == .staged { args.append("--cached") }
        if file.scope == .untracked {
            args += ["--no-index", "--", "/dev/null", file.path]
        } else { args += ["--", file.path] }
        let output = try await run(args, root: root, limit: GitDiffDocument.byteLimit,
                                   allowed: file.scope == .untracked ? [0, 1] : [0])
        return GitDiffDocument(data: output.data, limited: output.limited)
    }

    static func stage(root: String, file: GitFileChange) async throws {
        if file.scope != .staged { _ = try await run(["add", "--", file.path], root: root); return }
        let head = try await run(["rev-parse", "--verify", "HEAD"], root: root, allowed: [0, 128])
        try Task.checkCancellation()
        if !head.data.isEmpty {
            _ = try await run(["reset", "--quiet", "HEAD", "--", file.path], root: root)
        } else { _ = try await run(["rm", "--cached", "--force", "--", file.path], root: root) }
    }
}
