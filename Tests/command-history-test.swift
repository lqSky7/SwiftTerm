import Foundation

/// Guards the history that outlives the window: what gets recorded, what gets folded, what gets dropped, and what
/// survives a trip through a file.
///
/// The file half runs against a temporary directory rather than the real `Application Support`, so running the
/// harnesses never touches the history of whoever is running them.
@main
enum CommandHistoryTest {
    static func main() {
        let harness = Harness("command-history-test")

        itRecordsAndFolds(harness)
        itDropsTheOldest(harness)
        itOffersNewestFirst(harness)
        itSurvivesTheFile(harness)
        anAbsentFileIsAnEmptyHistory(harness)
        aHandEditedFileIsTolerated(harness)
        itWritesOneCommandPerLine(harness)

        harness.finish()
    }

    private static func scratchStore() -> CommandHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-history-\(UUID().uuidString)", isDirectory: true)
        return CommandHistoryStore(url: directory.appendingPathComponent("history"))
    }

    private static func itRecordsAndFolds(_ harness: Harness) {
        var history = CommandHistory()
        harness.equal(history.entries, [], "nothing is remembered to begin with")

        history.record("ls")
        history.record("cd src")
        history.record("swift build")
        harness.equal(history.entries, ["ls", "cd src", "swift build"], "commands are kept in order")

        // A shell's own `ignoredups`: the same command twice in a row is one entry, or ↑ is a key that does nothing.
        history.record("swift build")
        harness.equal(
            history.entries, ["ls", "cd src", "swift build"],
            "the same command twice in a row is folded")

        // But *not* the same command later: ls, cd, ls is a history worth keeping, and folding it would lose the
        // order somebody actually worked in.
        history.record("ls")
        harness.equal(
            history.entries, ["ls", "cd src", "swift build", "ls"],
            "the same command later is kept, because the order is the history")

        history.record("")
        history.record("   ")
        harness.equal(history.entries.count, 4, "an empty command is not a command")

        history.record("  echo hi  ")
        harness.equal(history.entries.last, "echo hi", "and a command is trimmed")
    }

    private static func itDropsTheOldest(_ harness: Harness) {
        var history = CommandHistory()
        for index in 0..<(CommandHistory.maximumEntries + 20) {
            history.record("command-\(index)")
        }
        harness.equal(
            history.entries.count, CommandHistory.maximumEntries,
            "the history is capped, or the file grows without bound and stops being a history")
        harness.equal(
            history.entries.first, "command-20", "the oldest are the ones dropped")
        harness.equal(
            history.entries.last, "command-\(CommandHistory.maximumEntries + 19)",
            "and the newest are the ones kept")

        // A file that was already too long is trimmed on the way in, not just as commands arrive.
        let long = CommandHistory(entries: (0..<(CommandHistory.maximumEntries + 5)).map { "x\($0)" })
        harness.equal(long.entries.count, CommandHistory.maximumEntries, "loading trims it too")
    }

    private static func itOffersNewestFirst(_ harness: Harness) {
        let history = CommandHistory(entries: ["ls", "cd src", "swift build"])
        harness.equal(
            history.newestFirst, ["swift build", "cd src", "ls"],
            "the completion engine wants newest first, which is the opposite of how it is stored")
    }

    private static func itSurvivesTheFile(_ harness: Harness) {
        let store = scratchStore()
        var history = CommandHistory()
        history.record("ls -la")
        history.record("cd ~/Desktop")
        history.record("echo \"hello world\"")
        store.save(history)

        let loaded = store.load()
        harness.equal(loaded, history, "what was saved is what comes back")
        harness.equal(
            loaded.entries.first, "ls -la", "oldest first, so the file reads top to bottom like a log")
    }

    private static func anAbsentFileIsAnEmptyHistory(_ harness: Harness) {
        // The first run has no file. A history that refused to start would be a terminal that refused to start.
        let store = scratchStore()
        harness.equal(store.load().entries, [], "no file is an empty history, not a failure")

        // And saving creates the directory it needs, so the first run works.
        var history = CommandHistory()
        history.record("first ever command")
        store.save(history)
        harness.equal(store.load().entries, ["first ever command"], "and the first save creates the path")
    }

    private static func aHandEditedFileIsTolerated(_ harness: Harness) {
        let store = scratchStore()
        try? FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "ls\n\n   \ncd src\n".write(to: store.url, atomically: true, encoding: .utf8)

        harness.equal(
            store.load().entries, ["ls", "cd src"],
            "blank lines and stray whitespace in a hand-edited file are not commands")
    }

    private static func itWritesOneCommandPerLine(_ harness: Harness) {
        // A multi-line command is stored on one line. It is rare, and the alternative is a file that cannot be
        // parsed — which is a history silently lost rather than a command shown slightly wrong.
        let store = scratchStore()
        var history = CommandHistory()
        history.record("if true; then\n  echo hi\nfi")
        store.save(history)

        let loaded = store.load()
        harness.equal(loaded.entries.count, 1, "a multi-line command is one entry, not three")
        harness.equal(
            loaded.entries.first, "if true; then   echo hi fi",
            "with its newlines turned into spaces")
    }
}
