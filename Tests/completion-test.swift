import Foundation

/// Guards what the popover and the ghost text offer.
///
/// The engine is pure, so everything here is a plain function call: no shell, no file system, no
/// window server. The directory listing is a dictionary.
@main
enum CompletionTest {
    static func main() {
        let harness = Harness("completion-test")

        commands(harness)
        subcommands(harness)
        flags(harness)
        paths(harness)
        aDotSlashIsAPathNotACommand(harness)
        pathNamesAreEscapedForTheShell(harness)
        theShellsOwnCommands(harness)
        ghostText(harness)
        ranking(harness)

        harness.finish()
    }

    private static let files: [String: [DirectoryEntry]] = [
        "/work": [
            DirectoryEntry(name: "main.swift", isDirectory: false),
            DirectoryEntry(name: "src", isDirectory: true),
            DirectoryEntry(name: "Calibre Library", isDirectory: true),
            DirectoryEntry(name: "Makefile", isDirectory: false),
        ],
        "/work/src": [DirectoryEntry(name: "main.swift", isDirectory: false)],
        // What `FileManager` answers for `/work/.` — the same directory under another name. A fixture without it
        // would fail a test for `./` that the real file system passes.
        "/work/.": [
            DirectoryEntry(name: "main.swift", isDirectory: false),
            DirectoryEntry(name: "src", isDirectory: true),
            DirectoryEntry(name: "Calibre Library", isDirectory: true),
            DirectoryEntry(name: "Makefile", isDirectory: false),
        ],
    ]

    private static func makeEngine(history: [String] = [], commands: [String] = [])
        -> CompletionEngine
    {
        CompletionEngine(history: history, commands: commands, workingDirectory: "/work") {
            files[$0] ?? []
        }
    }

    private static func texts(_ candidates: [CompletionCandidate]) -> [String] {
        candidates.map(\.text)
    }

    private static func commands(_ harness: Harness) {
        let candidates = makeEngine().candidates(for: "gi", cursor: 2)
        harness.equal(candidates.first?.text, "git", "a prefix match comes first")
        harness.equal(candidates.first?.kind, .command, "and is a command")
        harness.equal(
            makeEngine().candidates(for: "", cursor: 0), [],
            "an empty line offers nothing: the popover appears once there is something to filter")
        harness.equal(
            makeEngine().candidates(for: "sw", cursor: 2).contains { $0.text == "swift" }, true,
            "another table entry")
    }

    private static func subcommands(_ harness: Harness) {
        let candidates = makeEngine().candidates(for: "git ch", cursor: 6)
        harness.equal(
            texts(candidates).prefix(2).map { $0 }, ["checkout", "cherry-pick"],
            "the table's order is kept among prefix matches")
        harness.equal(candidates.first?.kind, .subcommand, "and they are subcommands")
        harness.equal(
            makeEngine().candidates(for: "swiftformatter ", cursor: 15).contains { $0.kind == .subcommand },
            false, "an unknown command offers no subcommands")
    }

    private static func flags(_ harness: Harness) {
        let candidates = makeEngine().candidates(for: "git --a", cursor: 7)
        harness.equal(
            texts(candidates).prefix(2).map { $0 }, ["--all", "--amend"],
            "prefix matches come first, the rest of the flags follow rather than being hidden")
        harness.equal(candidates.first?.description, "every ref", "with their description")
        harness.equal(candidates.first?.kind, .flag, "and are flags")

        let all = makeEngine().candidates(for: "git -", cursor: 5)
        harness.equal(all.count, 6, "a bare dash offers every flag of that command")
        harness.equal(
            makeEngine().candidates(for: "cd -", cursor: 4), [],
            "a command with no flags offers none")
    }

    private static func paths(_ harness: Harness) {
        let bare = makeEngine().candidates(for: "cat ma", cursor: 6)
        harness.equal(texts(bare), ["main.swift"], "a bare word completes against the working directory")
        harness.equal(bare.first?.kind, .path, "as a path")

        let nested = makeEngine().candidates(for: "cat src/ma", cursor: 10)
        harness.equal(texts(nested), ["src/main.swift"], "a directory part is kept in the answer")

        let directories = makeEngine().candidates(for: "cat s", cursor: 5)
        harness.equal(
            directories.contains { $0.text == "src/" && $0.description == "directory" }, true,
            "a directory is marked, and gets a slash so the next Tab descends into it")

        let everything = makeEngine().candidates(for: "cat ", cursor: 4)
        harness.equal(everything.count, 4, "an empty word offers the whole directory")

        harness.equal(
            makeEngine().candidates(for: "brew ", cursor: 5).contains { $0.kind == .path }, false,
            "a command that takes no paths offers none")
    }

    /// A file name with a space in it is **one argument**, and inserting it plainly makes it two.
    ///
    /// This is the bug the escaping exists for: the list offered `Calibre Library/`, the buffer got
    /// `Calibre Library/`, the shell read two words, and the directory the list had just offered could not be
    /// entered. Warp escapes the same thing at the same place.
    private static func pathNamesAreEscapedForTheShell(_ harness: Harness) {
        let candidates = makeEngine().candidates(for: "cd Cal", cursor: 6)
        let library = candidates.first { $0.text == "Calibre Library/" }
        harness.expect(library != nil, "a directory with a space in its name is offered")
        harness.equal(
            library?.insertion, "Calibre\\ Library/",
            "and what goes in the buffer is escaped, because that is what one argument looks like")

        // A name that needs no escaping is not escaped, so this is not a change to every path.
        let plain = makeEngine().candidates(for: "cd sr", cursor: 5).first { $0.text == "src/" }
        harness.equal(plain?.insertion, "src/", "a plain name is inserted as itself")

        // And typing the escape yourself is the same request: the list is narrowed by the *name*.
        harness.expect(
            makeEngine().candidates(for: "cd Calibre\\ L", cursor: 13)
                .contains { $0.text == "Calibre Library/" },
            "a path typed with its space already escaped still matches the name")

        harness.equal(
            CompletionEngine.shellEscaped("Calibre Library"), "Calibre\\ Library",
            "the escape itself: a space gets a backslash")
        harness.equal(
            CompletionEngine.shellEscaped("a-b_c.d+e"), "a-b_c.d+e",
            "and the characters a shell reads as literal are left alone")
    }

    /// Tab on a command name offers what the shell can actually run, not just the commands this project
    /// happens to have signatures for.
    private static func theShellsOwnCommands(_ harness: Harness) {
        let engine = makeEngine(commands: ["lsblk", "lsof", "ls", "zsh", "zshrc"])
        let offered = engine.candidates(for: "ls", cursor: 2).map(\.text)

        harness.expect(offered.contains("lsblk"), "a command on PATH that starts with the prefix is offered")
        harness.expect(offered.contains("lsof"), "and so is the next one")
        harness.expect(offered.contains("ls"), "including the name itself")
        harness.expect(
            !offered.contains("zsh"),
            "and nothing that does not start with what was typed — the list is a list of matches")

        // The table's entry wins when both sources know a name, so a command keeps its description.
        harness.equal(
            offered.filter { $0 == "ls" }.count, 1,
            "a name both the table and PATH know is offered once")
        harness.equal(
            engine.candidates(for: "ls", cursor: 2).first { $0.text == "ls" }?.kind, .command,
            "and it is the table's entry that is kept")

        // A shell that changed its own PATH does not change ours, so an empty source is legitimate and the
        // table still answers.
        harness.expect(
            !makeEngine().candidates(for: "git", cursor: 3).isEmpty,
            "with no PATH source at all the signature table still answers")
    }

    /// `./` is a path. Nothing on `PATH` starts with it, so treating the word as a command name offered nothing —
    /// no popover, no ghost text, and no way to complete the file you were looking straight at.
    private static func aDotSlashIsAPathNotACommand(_ harness: Harness) {
        let here = makeEngine().candidates(for: "./", cursor: 2)
        harness.expect(!here.isEmpty, "`./` offers the working directory's contents")
        harness.expect(here.contains { $0.text == "./src/" }, "including its directories")
        harness.expect(here.contains { $0.text == "./main.swift" }, "and its files")
        harness.equal(here.first?.kind, .path, "as paths, not commands")

        let typed = makeEngine().candidates(for: "./sr", cursor: 4)
        harness.equal(texts(typed), ["./src/"], "`./sr` narrows to the directory that matches")

        harness.expect(
            makeEngine().candidates(for: "/work/ma", cursor: 8).contains { $0.text == "/work/main.swift" },
            "an absolute path is completed from the file system as well")
    }

    private static func ghostText(_ harness: Harness) {
        let engine = makeEngine(history: ["git status", "git stash", "ls -la"])
        harness.equal(
            engine.ghostText(for: "git st", cursor: 6), "atus",
            "the newest matching history entry supplies the rest")
        harness.equal(
            engine.ghostText(for: "git stash", cursor: 9), nil,
            "a line that is already complete suggests nothing")
        harness.equal(engine.ghostText(for: "", cursor: 0), nil, "nor does an empty line")
        harness.equal(
            engine.ghostText(for: "git st", cursor: 3), nil,
            "and nothing is suggested with the cursor mid-line")

        let history = makeEngine(history: ["ls -la", "ls -lta"])
        harness.equal(
            history.ghostText(for: "ls -l", cursor: 5), "a",
            "the newest entry wins, because that is the order history is kept in")
    }

    private static func ranking(_ harness: Harness) {
        // A command that is both in the table and in history is offered once, as the table's entry.
        let engine = makeEngine(history: ["ls -la", "ls -lta"])
        let ls = engine.candidates(for: "l", cursor: 1).filter { $0.text == "ls" }
        harness.equal(ls.count, 1, "a command is offered once however many sources know it")
        harness.equal(ls.first?.kind, .command, "and the table's entry is the one kept")

        // A command that is only in history is still offered.
        let mine = makeEngine(history: ["deploy.sh --now"])
        harness.equal(
            mine.candidates(for: "dep", cursor: 3).contains { $0.text == "deploy.sh" }, true,
            "a command that has been run is offered even when the table has never heard of it")
    }
}
