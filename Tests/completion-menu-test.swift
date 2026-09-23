import Foundation

/// Guards the completion popover's state: when it opens, which row is chosen, how the visible window
/// follows the selection, and what accepting a candidate does to the buffer.
///
/// All of it is arithmetic over a pure engine, so all of it is testable here rather than in a window. That
/// matters more for this than for most of the model: the popover is the part of Phase 3 that failed to be
/// written three times, and every one of those failures was a *view* problem that hid a *state* problem.
@main
enum CompletionMenuTest {
    static func main() {
        let harness = Harness("completion-menu-test")

        itOpensOnlyWithSomethingToOffer(harness)
        theWindowFollowsTheSelection(harness)
        theSelectionStopsAtBothEnds(harness)
        acceptingReplacesTheWord(harness)
        acceptingWorksInTheMiddleOfALine(harness)
        acceptingAPathPutsAnEscapedOneInTheBuffer(harness)

        harness.finish()
    }

    private static let files: [String: [DirectoryEntry]] = [
        "/work": [
            DirectoryEntry(name: "main.swift", isDirectory: false),
            DirectoryEntry(name: "src", isDirectory: true),
            DirectoryEntry(name: "Calibre Library", isDirectory: true),
            DirectoryEntry(name: "Makefile", isDirectory: false),
        ]
    ]

    private static func makeEngine(history: [String] = []) -> CompletionEngine {
        CompletionEngine(history: history, workingDirectory: "/work") { files[$0] ?? [] }
    }

    /// A menu over `git`'s subcommands, which is more than one windowful — 24 subcommands plus the three
    /// entries in the working directory, so the windowing below is exercised rather than assumed.
    private static func longMenu(_ harness: Harness) -> CompletionMenu {
        guard let menu = CompletionMenu(buffer: "git ", caret: 4, engine: makeEngine()) else {
            harness.expect(false, "a menu opens for a bare `git `")
            return CompletionMenu(buffer: "git ", caret: 4, engine: makeEngine())!
        }
        harness.expect(
            menu.total > CompletionMenu.maximumRows,
            "the fixture has more candidates than one window shows")
        return menu
    }

    private static func itOpensOnlyWithSomethingToOffer(_ harness: Harness) {
        harness.expect(
            CompletionMenu(buffer: "", caret: 0, engine: makeEngine()) == nil,
            "an empty line opens nothing — Tab there is the shell's")
        harness.expect(
            CompletionMenu(buffer: "   ", caret: 3, engine: makeEngine()) == nil,
            "and neither does a line of spaces")
        harness.expect(
            CompletionMenu(buffer: "git ", caret: 4, engine: makeEngine()) != nil,
            "but a command and a space has subcommands and paths to offer")
    }

    private static func theWindowFollowsTheSelection(_ harness: Harness) {
        var menu = longMenu(harness)
        harness.equal(menu.rows.count, CompletionMenu.maximumRows, "the window is one windowful")
        harness.equal(menu.firstVisibleRow, 0, "and starts at the top")
        harness.equal(menu.selectedRow, 0, "with the first row chosen")

        // Down to the last visible row: the window must not have moved yet.
        for _ in 0..<(CompletionMenu.maximumRows - 1) { menu.moveDown() }
        harness.equal(menu.firstVisibleRow, 0, "the window holds still while the selection is inside it")
        harness.equal(
            menu.selectedRow, CompletionMenu.maximumRows - 1, "with the highlight on the last row")

        // One more, and the window has to move rather than the highlight leaving the list.
        menu.moveDown()
        harness.equal(menu.firstVisibleRow, 1, "one row further and the window follows")
        harness.equal(
            menu.selectedRow, CompletionMenu.maximumRows - 1,
            "so the highlight is still the last row of it")
        harness.equal(menu.rows.count, CompletionMenu.maximumRows, "and the window is still full")

        // At the end of a long list the window stops at the end rather than running off it.
        for _ in 0..<menu.total { menu.moveDown() }
        harness.equal(menu.selected, menu.total - 1, "the selection stops at the last candidate")
        harness.equal(menu.rows.count, CompletionMenu.maximumRows, "the last window is full")
        harness.equal(
            menu.selectedRow, CompletionMenu.maximumRows - 1, "and the highlight is on the last row")
        harness.equal(
            menu.firstVisibleRow, menu.total - CompletionMenu.maximumRows,
            "with the window flush against the end of the list")
    }

    private static func theSelectionStopsAtBothEnds(_ harness: Harness) {
        var menu = longMenu(harness)
        menu.moveUp()
        harness.equal(menu.selected, 0, "up from the first row stays on the first row")
        harness.equal(menu.firstVisibleRow, 0, "and does not scroll the window")

        for _ in 0..<(menu.total * 2) { menu.moveDown() }
        let last = menu.selected
        menu.moveDown()
        harness.equal(menu.selected, last, "down from the last row stays on the last row")

        // And back up to the top, where the window has to return to the beginning.
        for _ in 0..<menu.total { menu.moveUp() }
        harness.equal(menu.selected, 0, "and all the way back up lands on the first row")
        harness.equal(menu.firstVisibleRow, 0, "with the window back at the top")
    }

    private static func acceptingReplacesTheWord(_ harness: Harness) {
        guard var menu = CompletionMenu(buffer: "git ch", caret: 6, engine: makeEngine()) else {
            harness.expect(false, "a menu opens for `git ch`")
            return
        }
        harness.equal(menu.wordStart, 4, "the word being completed starts after the space")
        harness.equal(
            menu.selectedCandidate?.text, "checkout",
            "and the best candidate is the one the prefix names")
        harness.equal(
            menu.selectedCandidate?.kind, .subcommand, "a subcommand, not a path")

        guard let accepted = menu.accepted(in: "git ch") else {
            harness.expect(false, "accepting a chosen candidate produces a buffer")
            return
        }
        harness.equal(accepted.text, "git checkout", "accepting replaces the word and nothing else")
        harness.equal(accepted.caret, 12, "and leaves the caret after what it inserted")

        // Moving first, then accepting, takes the row that was moved to.
        menu.moveDown()
        let second = menu.selectedCandidate?.text
        harness.expect(second != nil && second != "checkout", "the second candidate is a different one")
        harness.equal(
            menu.accepted(in: "git ch")?.text, "git " + (second ?? ""),
            "and accepting takes the one that is chosen, not the best one")
    }

    /// A path with a space in it is one argument, and the buffer has to be given the escaped form.
    ///
    /// The row reads `Calibre Library/` because that is the name; the buffer gets `Calibre\ Library/` because
    /// that is what the shell needs. Inserting the readable form is how a completion offers a directory and
    /// then cannot be `cd`'d into.
    private static func acceptingAPathPutsAnEscapedOneInTheBuffer(_ harness: Harness) {
        guard let menu = CompletionMenu(buffer: "cd Cal", caret: 6, engine: makeEngine()),
            let accepted = menu.accepted(in: "cd Cal")
        else {
            harness.expect(false, "a menu opens for `cd Cal`")
            return
        }
        harness.equal(
            menu.selectedCandidate?.text, "Calibre Library/",
            "the row reads the name as it is")
        harness.equal(
            menu.selectedCandidate?.insertion, "Calibre\\ Library/",
            "and what it inserts is escaped")
        harness.equal(accepted.text, "cd Calibre\\ Library/", "so the buffer gets one argument")
        harness.equal(accepted.caret, 20, "with the caret after all of it")
    }

    private static func acceptingWorksInTheMiddleOfALine(_ harness: Harness) {
        // The caret is inside the line, so the word ends at the caret and the rest must survive.
        guard let menu = CompletionMenu(buffer: "git ch --amend", caret: 6, engine: makeEngine()),
            let accepted = menu.accepted(in: "git ch --amend")
        else {
            harness.expect(false, "a menu opens with the caret mid-line")
            return
        }
        harness.equal(
            accepted.text, "git checkout --amend",
            "the word under the caret is replaced and the arguments after it are left alone")
        harness.equal(accepted.caret, 12, "with the caret after the inserted word")
    }
}
