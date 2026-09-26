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
    /// Filtered entry indices when navigating with a prefix.
    private var filteredIndices: [Int]? = nil

    var isNavigating: Bool { index != nil }

    /// ↑. `entries` is oldest-first, which is the order a shell keeps them in and the opposite of the order
    /// they are offered in. If the buffer is non-empty, filters to entries sharing the prefix.
    mutating func previous(in entries: [String], from buffer: String) -> String? {
        guard !entries.isEmpty else {
            reset()
            return nil
        }
        if index == nil {
            draft = buffer
            if !draft.isEmpty {
                let matching = entries.indices.filter { entries[$0].hasPrefix(draft) }
                filteredIndices = matching.isEmpty ? nil : matching
            } else {
                filteredIndices = nil
            }

            if let filtered = filteredIndices {
                index = filtered.count - 1
                let entryIndex = filtered[index ?? 0]
                return entries[entryIndex]
            } else {
                index = entries.count - 1
                return entries[index ?? 0]
            }
        } else {
            if let filtered = filteredIndices {
                index = max(0, (index ?? 0) - 1)
                let entryIndex = filtered[index ?? 0]
                return entries[entryIndex]
            } else {
                index = max(0, (index ?? 0) - 1)
                let clamped = min(max(0, index ?? 0), entries.count - 1)
                index = clamped
                return entries[clamped]
            }
        }
    }

    /// ↓. One past the newest is not a failure — it is the draft coming back.
    mutating func next(in entries: [String]) -> String? {
        guard let currentIndex = index else { return nil }
        let forward = currentIndex + 1
        let maxCount = filteredIndices?.count ?? entries.count
        if forward >= maxCount {
            let saved = draft
            reset()
            return saved
        }
        self.index = forward
        if let filtered = filteredIndices {
            return entries[filtered[forward]]
        } else {
            return entries[forward]
        }
    }

    /// The buffer is somebody's own again — a command was submitted, or the editor was emptied. Without
    /// this the next ↑ would continue a walk that the user has long since finished.
    mutating func reset() {
        index = nil
        draft = ""
        filteredIndices = nil
    }
}
