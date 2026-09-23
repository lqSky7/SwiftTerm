import Foundation

/// Guards the not-found check that puts a red dashed underline under a mistyped command.
///
/// The case worth protecting is the *indeterminate* one. A two-valued check would have to guess about
/// `$EDITOR` and `foo*`, and guessing wrong underlines a command that works — which teaches the user
/// to ignore the underline, and makes the feature worse than not having it.
@main
enum CommandResolverTest {
    static func main() {
        let harness = Harness("command-resolver-test")

        builtins(harness)
        unknownNames(harness)
        indeterminate(harness)
        lookup(harness)
        underline(harness)

        harness.finish()
    }

    private static func builtins(_ harness: Harness) {
        let resolver = CommandResolver(path: "/usr/bin:/bin")
        harness.equal(resolver.resolution(of: "cd"), .found(path: nil), "cd is a builtin")
        harness.equal(resolver.resolution(of: "export"), .found(path: nil), "so is export")
        harness.equal(resolver.resolution(of: "["), .found(path: nil), "and the test bracket")
        harness.equal(
            resolver.resolution(of: "ls"), .found(path: "/bin/ls"),
            "a real tool resolves to its path")
        harness.equal(resolver.resolution(of: ""), .indeterminate, "nothing is not a command")
    }

    private static func unknownNames(_ harness: Harness) {
        let resolver = CommandResolver(path: "/usr/bin:/bin")
        harness.equal(
            resolver.resolution(of: "swiftterm-no-such-command"),
            .notFound, "a name on no path is not found")
        // An empty PATH finds nothing but still knows the builtins.
        let bare = CommandResolver(path: "")
        harness.equal(bare.resolution(of: "ls"), .notFound, "an empty PATH finds no tool")
        harness.equal(bare.resolution(of: "cd"), .found(path: nil), "but a builtin is still a builtin")
    }

    private static func indeterminate(_ harness: Harness) {
        let resolver = CommandResolver(path: "/usr/bin:/bin")
        for name in ["$EDITOR", "foo*", "\"quoted\"", "`backtick`", "a\\ b", "~someone/bin/x"] {
            harness.equal(
                resolver.resolution(of: name), .indeterminate,
                "\(name) depends on something the text does not say")
        }
        // A leading `~/` is expandable, so it gets a real answer rather than a shrug.
        harness.equal(
            resolver.resolution(of: "~/swiftterm-no-such-thing"), .notFound,
            "a home-relative path is checked, not shrugged at")
    }

    private static func lookup(_ harness: Harness) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-resolver-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tool = directory.appendingPathComponent("probe-tool")
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        // A file that is there but not executable is not a command, which is the difference between
        // "you typed the wrong name" and "you cannot run this".
        let data = directory.appendingPathComponent("probe-data")
        FileManager.default.createFile(atPath: data.path, contents: Data("x".utf8))

        let resolver = CommandResolver(path: directory.path)
        harness.equal(
            resolver.resolution(of: "probe-tool"), .found(path: tool.path),
            "a tool on PATH is found")
        harness.equal(
            resolver.resolution(of: "probe-data"), .notFound,
            "a non-executable file is not a command")
        harness.equal(
            resolver.resolution(of: "swiftterm-no-such-tool"), .notFound, "nor is nothing at all")
        harness.equal(
            resolver.resolution(of: tool.path), .found(path: tool.path),
            "an absolute path answers for itself")
        harness.equal(
            resolver.resolution(of: directory.path + "/missing"), .notFound,
            "and a missing one does not")
    }

    private static func underline(_ harness: Harness) {
        let resolver = CommandResolver(path: "/usr/bin:/bin")
        func underlined(_ buffer: String) -> [String] {
            let tokens = ShellTokenizer.tokens(in: buffer)
            return resolver.notFoundRanges(in: buffer, tokens: tokens).map { String(buffer[$0]) }
        }

        harness.equal(underlined("ls -la"), [], "a real command is not underlined")
        harness.equal(
            underlined("swiftterm-no-such-command --help"), ["swiftterm-no-such-command"],
            "an unknown one is, without its arguments")
        harness.equal(
            underlined("ls | swiftterm-no-such-command"), ["swiftterm-no-such-command"],
            "every command in the line is checked, not just the first")
        harness.equal(underlined("echo $EDITOR"), [], "an expansion is never underlined")
        harness.equal(underlined(""), [], "and neither is nothing")
    }
}
