import Foundation

/// The completion popover's state: what is being offered, which one is chosen, and what accepting it does.
///
/// Pure, and separate from the view that draws it, because everything about it that can be wrong is
/// arithmetic: where the word under the caret starts, what an accepted candidate replaces, what happens when
/// the selection walks off either end of the list, and how the visible window follows the selection. The
/// view's whole job is to draw `rows` and put a highlight on `selectedRow`.
///
/// That split is the one this project has learned to insist on: the model layer has been reliable because a
/// harness holds it, and the view layer has been wrong every time it was written ahead of a running window.
/// See `docs/phase-3-todo.md`.
struct CompletionMenu: Equatable {
    /// How many candidates are shown at once.
    ///
    /// A list that grows to fill the window is a list you have to read to find the one you wanted; eight is
    /// a glance. It is also what makes the visible window necessary, which is why the windowing lives here
    /// rather than in the view.
    static let maximumRows = 8

    /// Every candidate, best first — `CompletionEngine`'s ranking, untouched.
    private(set) var candidates: [CompletionCandidate] = []
    /// Which one is chosen. Always a valid index while `candidates` is not empty.
    private(set) var selected = 0
    /// The first row of the visible window.
    private(set) var firstVisibleRow = 0
    /// Where the word being completed starts, and where the caret was. A candidate replaces
    /// `wordStart..<caret`.
    private(set) var wordStart = 0
    private(set) var caret = 0

    /// Nil when there is nothing to offer, which is the whole of "should the popover open".
    ///
    /// A menu with no candidates is not an empty popover — it is no popover. Tab with nothing to suggest is
    /// the shell's business (`onUnhandledTab`), and an empty panel would swallow it.
    init?(buffer: String, caret: Int, engine: CompletionEngine) {
        let characters = Array(buffer)
        let caret = min(max(0, caret), characters.count)
        let candidates = engine.candidates(for: buffer, cursor: caret)
        guard !candidates.isEmpty else { return nil }

        self.candidates = candidates
        self.caret = caret
        self.wordStart = engine.startOfWord(in: characters, before: caret)
    }

    /// The rows the view draws, which is a *window* on `candidates` rather than all of them.
    var rows: [CompletionCandidate] {
        let start = min(firstVisibleRow, max(0, candidates.count - 1))
        let end = min(start + Self.maximumRows, candidates.count)
        guard start < end else { return [] }
        return Array(candidates[start..<end])
    }

    /// Where the highlight goes, within `rows`.
    var selectedRow: Int { selected - min(firstVisibleRow, max(0, candidates.count - 1)) }

    var selectedCandidate: CompletionCandidate? {
        candidates.indices.contains(selected) ? candidates[selected] : nil
    }

    /// How many rows there are in total, which the view needs to know whether to draw a scroll hint.
    var total: Int { candidates.count }

    /// Whether the list is showing everything it has.
    var isShowingEverything: Bool { candidates.count <= Self.maximumRows }

    // MARK: - Moving

    /// Down a row, and no further.
    ///
    /// It stops at the end rather than wrapping: a list that jumps from the last row back to the first is a
    /// list whose end you cannot find, and the one thing a person does with a completion list is look for
    /// the end of it.
    mutating func moveDown() {
        guard selected + 1 < candidates.count else { return }
        selected += 1
        scrollToSelection()
    }

    mutating func moveUp() {
        guard selected > 0 else { return }
        selected -= 1
        scrollToSelection()
    }

    /// Keep the chosen row inside the visible window, and the window inside the list.
    ///
    /// Both halves matter: the first alone lets the window drift past the end of a short list, which shows
    /// blank rows under the last candidate.
    private mutating func scrollToSelection() {
        if selected < firstVisibleRow { firstVisibleRow = selected }
        let lastVisible = firstVisibleRow + Self.maximumRows - 1
        if selected > lastVisible { firstVisibleRow = selected - Self.maximumRows + 1 }
        firstVisibleRow = max(0, min(firstVisibleRow, max(0, candidates.count - Self.maximumRows)))
    }

    // MARK: - Accepting

    /// The buffer with the chosen candidate in place of the word under the caret, and where the caret lands.
    ///
    /// What goes in is the candidate's **insertion**, not its text, when the two differ — a path with a space
    /// in it reads as `Calibre Library/` and has to be inserted as `Calibre\ Library/`, or the shell gets two
    /// arguments instead of one and the directory the list just offered cannot be entered.
    ///
    /// The caret goes to the end of what was inserted rather than staying where it was: a completion you
    /// cannot keep typing after is a completion you have to move the caret away from.
    func accepted(in buffer: String) -> (text: String, caret: Int)? {
        guard let candidate = selectedCandidate else { return nil }
        let insertion = candidate.insertion ?? candidate.text
        var characters = Array(buffer)
        let start = min(max(0, wordStart), characters.count)
        let end = min(max(start, caret), characters.count)
        characters.replaceSubrange(start..<end, with: Array(insertion))
        return (String(characters), start + insertion.count)
    }
}
