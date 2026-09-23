import Foundation

/// Where a person is in their command history, and what ↑ and ↓ do to it.
///
/// This is the one piece of key handling in the editor that is *stateful* — everything else either inserts
/// text or hands the key back — and stateful key handling written inside a view is exactly what this
/// project's view layer has got wrong every time it was written ahead of a running window. So the rule lives
/// here, where a harness can hold it, and the editor does nothing but put the answer in its buffer.
///
/// The rule is readline's, because that is what "normally" means in a terminal:
///
/// - The first ↑ remembers what had been typed and starts at the **newest** entry, so the draft is not lost.
/// - Further ↑s walk backwards and stop at the oldest — a shell does not wrap round, and neither does this.
/// - ↓ walks forwards, and one ↓ past the newest gives the draft back and ends the walk. That is what makes
///   ↑ ↑ ↓ ↓ return you to what you were typing.
struct HistoryNavigation: Equatable {
    /// Which entry is showing, or nil when the buffer is the user's own and not a recalled one.
    private var index: Int?
    /// What was in the buffer when the walk started, so ↓ can hand it back.
    private var draft = ""

    var isNavigating: Bool { index != nil }

    /// ↑. `entries` is oldest-first, which is the order a shell keeps them in and the opposite of the order
    /// they are offered in.
    mutating func previous(in entries: [String], from buffer: String) -> String? {
        guard !entries.isEmpty else {
            // A history that emptied under the walk ends it rather than leaving a position pointing at
            // nothing — and an empty history is not a walk at all, so the key goes back to the shell.
            reset()
            return nil
        }
        if index == nil {
            draft = buffer
            index = entries.count - 1
        } else {
            index = max(0, (index ?? 0) - 1)
        }
        // **Clamped, not trusted.** The history is the session's, so a block evicted by the scrollback cap
        // mid-walk leaves this index past the end of the list. The honest answer there is the nearest entry
        // that still exists; returning nil would make ↑ silently dead, which is a worse failure than
        // recalling the wrong line — one is visible, the other is not.
        let clamped = min(max(0, index ?? 0), entries.count - 1)
        index = clamped
        return entries[clamped]
    }

    /// ↓. One past the newest is not a failure — it is the draft coming back.
    mutating func next(in entries: [String]) -> String? {
        guard let index else { return nil }
        let forward = index + 1
        if forward >= entries.count {
            self.index = nil
            return draft
        }
        self.index = forward
        return entries[forward]
    }

    /// The buffer is somebody's own again — a command was submitted, or the editor was emptied. Without
    /// this the next ↑ would continue a walk that the user has long since finished.
    mutating func reset() {
        index = nil
        draft = ""
    }
}
