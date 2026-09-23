import Foundation

/// Guards ↑ and ↓: the walk through the commands already run, and the draft it has to give back.
///
/// The interesting cases are not "↑ gives the last command" — they are the two ends. At the oldest entry a
/// shell stops rather than wrapping, and one ↓ past the newest has to return what the user had typed
/// *before* they started walking. Getting the second one wrong is how a half-written command is lost, which
/// is the kind of bug nobody reports because they assume they imagined it.
@main
enum HistoryNavigationTest {
    static func main() {
        let harness = Harness("history-navigation-test")

        itStartsAtTheNewest(harness)
        itWalksBackwardsAndStops(harness)
        itWalksForwardAndGivesTheDraftBack(harness)
        anEmptyHistoryDoesNothing(harness)
        itSurvivesTheHistoryShrinking(harness)

        harness.finish()
    }

    /// Oldest first, which is how a shell keeps them and the opposite of the order they are offered in.
    private static let history = ["ls", "cd src", "swift build", "swift test"]

    private static func itStartsAtTheNewest(_ harness: Harness) {
        var navigation = HistoryNavigation()
        harness.expect(!navigation.isNavigating, "nothing is recalled to begin with")
        harness.equal(
            navigation.previous(in: history, from: ""), "swift test",
            "the first up gives the newest command")
        harness.expect(navigation.isNavigating, "and starts the walk")

        // The draft is what was there before the walk, not the entry that replaced it.
        var typed = HistoryNavigation()
        _ = typed.previous(in: history, from: "swift b")
        harness.equal(
            typed.next(in: history), "swift b",
            "and the draft is what was typed before the first up, not the recalled line")
    }

    private static func itWalksBackwardsAndStops(_ harness: Harness) {
        var navigation = HistoryNavigation()
        harness.equal(navigation.previous(in: history, from: ""), "swift test", "newest")
        harness.equal(navigation.previous(in: history, from: ""), "swift build", "then the one before")
        harness.equal(navigation.previous(in: history, from: ""), "cd src", "and the one before that")
        harness.equal(navigation.previous(in: history, from: ""), "ls", "down to the oldest")

        // A shell does not wrap round, and neither does this: up at the top stays at the top.
        harness.equal(
            navigation.previous(in: history, from: ""), "ls",
            "up at the oldest entry stays on the oldest entry")
        harness.equal(
            navigation.previous(in: history, from: ""), "ls", "however many times it is pressed")
    }

    private static func itWalksForwardAndGivesTheDraftBack(_ harness: Harness) {
        var navigation = HistoryNavigation()
        harness.equal(navigation.previous(in: history, from: "half typed"), "swift test", "newest")
        harness.equal(
            navigation.previous(in: history, from: "half typed"), "swift build",
            "and the one before it")
        harness.equal(
            navigation.next(in: history), "swift test",
            "down walks forwards through the history")
        harness.equal(
            navigation.next(in: history), "half typed",
            "and one down past the newest gives back what was being typed")
        harness.expect(!navigation.isNavigating, "which ends the walk")

        // With the walk over, down does nothing at all — the buffer is the user's own again.
        harness.equal(navigation.next(in: history), nil, "down with nothing recalled does nothing")

        // And down from the newest in a fresh walk gives the draft back immediately.
        var fresh = HistoryNavigation()
        _ = fresh.previous(in: history, from: "echo hi")
        harness.equal(fresh.next(in: history), "echo hi", "up then down returns the draft")
        harness.expect(!fresh.isNavigating, "and the walk is over")

        // Submitting resets it, so the next up starts from the newest entry again rather than continuing.
        var afterSubmit = HistoryNavigation()
        _ = afterSubmit.previous(in: history, from: "")
        afterSubmit.reset()
        harness.expect(!afterSubmit.isNavigating, "submitting ends the walk")
        harness.equal(
            afterSubmit.previous(in: history, from: ""), "swift test",
            "so the next up starts at the newest again")
    }

    private static func anEmptyHistoryDoesNothing(_ harness: Harness) {
        var navigation = HistoryNavigation()
        harness.equal(
            navigation.previous(in: [], from: "typing"), nil,
            "up with nothing in the history leaves the buffer alone")
        harness.expect(
            !navigation.isNavigating,
            "and does not start a walk — the key is the shell's, and an empty history is not a walk")
        harness.equal(navigation.next(in: []), nil, "and neither does down")
    }

    private static func itSurvivesTheHistoryShrinking(_ harness: Harness) {
        // A block can be evicted while a walk is in progress — the scrollback has a cap — and an index
        // past the end of the list is a crash in a view that trusted it.
        var navigation = HistoryNavigation()
        harness.equal(navigation.previous(in: history, from: ""), "swift test", "a walk starts at the end")
        let shrunk = ["ls"]
        harness.equal(
            navigation.previous(in: shrunk, from: ""), "ls",
            "a history that shrank under the walk answers with the nearest entry that still exists")
        harness.equal(
            navigation.previous(in: shrunk, from: ""), "ls",
            "and keeps answering, rather than leaving the up key dead")

        // A history that emptied entirely is not a walk at all: the key goes back to the shell.
        var emptied = HistoryNavigation()
        _ = emptied.previous(in: history, from: "draft")
        harness.equal(emptied.previous(in: [], from: "draft"), nil, "an emptied history answers nothing")
        harness.expect(!emptied.isNavigating, "and ends the walk rather than pointing at nothing")
    }
}
