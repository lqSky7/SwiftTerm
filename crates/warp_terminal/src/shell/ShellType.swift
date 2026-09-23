import Foundation

/// The shells this terminal knows how to install prompt markers into. Anything else still runs
/// normally, just without blocks to build on later.
enum ShellType: String, Sendable, CaseIterable {
    case zsh
    case bash
    case fish
    case other

    /// Identified from the basename so `/bin/zsh`, `/opt/homebrew/bin/zsh` and a versioned
    /// `zsh-5.9` all land on the same case.
    init(executablePath: String) {
        let name = (executablePath as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("zsh") {
            self = .zsh
        } else if name.hasPrefix("bash") {
            self = .bash
        } else if name.hasPrefix("fish") {
            self = .fish
        } else {
            self = .other
        }
    }

    /// The dotfiles zsh reads out of `ZDOTDIR`, in the order it reads them. Pointing `ZDOTDIR` at
    /// a generated directory hides the user's copies of exactly these, so each needs a shim.
    static let zshDotFileNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
}
