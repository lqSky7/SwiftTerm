import Foundation

/// One badge above the prompt.
struct ContextChip: Equatable {
    enum Kind: Equatable {
        case directory
        case branch
        /// A virtualenv, a conda environment — anything only the shell knows it is inside.
        case environment
    }

    var kind: Kind
    /// What it says. The directory is abbreviated against home, which is the only formatting this does;
    /// truncating it to a width is the renderer's job, and the renderer already has the measuring to do
    /// it.
    var text: String
}

/// What the chips above a prompt should say.
///
/// A pure function of what is known, which is the only reason it is a model rather than a view. The
/// chips are the first thing in this app whose *content* is worth asserting on, and a harness can
/// assert on it here with no window server and no shell — which, given how the view layer has gone, is
/// the difference between a feature that can be checked and one that cannot.
///
/// The set and the order are Warp's: where you are, then what you are on, then what you are running
/// inside. Warp also shows a runtime version and the git diff stats; those need facts this does not
/// have yet — a version is not in a file, and a diff count needs git — so they are absent rather than
/// approximated. See `docs/phase-4-todo.md`.
enum ContextChips {
    static func forPrompt(
        directory: String,
        metadata: RepoMetadata = .empty,
        environment: String? = nil,
        home: String = NSHomeDirectory()
    ) -> [ContextChip] {
        var chips: [ContextChip] = [
            ContextChip(kind: .directory, text: abbreviated(directory, home: home))
        ]

        if let branch = metadata.branch, !branch.isEmpty {
            chips.append(ContextChip(kind: .branch, text: branch))
        }
        if let environment, !environment.isEmpty {
            chips.append(ContextChip(kind: .environment, text: environment))
        }
        return chips
    }

    /// `~` for the home directory and everything under it, and the path as it is otherwise.
    ///
    /// The same abbreviation the block header uses for a working directory, because two abbreviations
    /// that disagree about the same path is a thing a user notices. A path that merely *starts* with the
    /// home directory's text is not under it — `/Users/me` does not contain `/Users/mex` — which is why
    /// this compares a component boundary and not a string prefix.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
