import Foundation

/// The terminal's mode set. Everything here is a switch a program can flip and that changes
/// how the grid interprets the next bytes, so it lives with the grid rather than the parser.
struct TerminalModes: Hashable, Sendable {
    /// DEC private `?1000` / `?1002` / `?1003` tracking level.
    enum MouseTracking: Hashable, Sendable {
        case none
        case buttonPress
        case buttonAndDrag
        case anyMotion
    }

    var insert = false                  // IRM, `CSI 4`
    var automaticWrap = true            // DECAWM, `CSI ?7`
    var originMode = false              // DECOM, `CSI ?6`
    var applicationCursorKeys = false    // DECCKM, `CSI ?1`
    var applicationKeypad = false        // DECKPAM / DECKPNM
    var cursorVisible = true            // DECTCEM, `CSI ?25`
    var bracketedPaste = false          // `CSI ?2004`
    var focusReporting = false          // `CSI ?1004`
    var reverseVideo = false            // DECSCNM, `CSI ?5`
    var lineFeedMode = false            // LNM, `CSI ?20`
    var smoothScroll = false            // `CSI ?4`
    var mouseTracking: MouseTracking = .none
    var mouseSGR = false                // `CSI ?1006`
    var alternateScreen = false         // `CSI ?1049` and friends

    /// Applies an ANSI or DEC private mode set/reset. Returns false for a mode this terminal
    /// does not implement, which is not an error — the protocol has hundreds of them.
    @discardableResult
    mutating func apply(mode: Int, enabled: Bool, isPrivate: Bool) -> Bool {
        guard isPrivate else {
            switch mode {
            case 4: insert = enabled
            case 20: lineFeedMode = enabled
            default: return false
            }
            return true
        }
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 4: smoothScroll = enabled
        case 5: reverseVideo = enabled
        case 6: originMode = enabled
        case 7: automaticWrap = enabled
        case 12: break                       // cursor blink; the renderer blinks regardless
        case 25: cursorVisible = enabled
        case 1000: mouseTracking = enabled ? .buttonPress : .none
        case 1002: mouseTracking = enabled ? .buttonAndDrag : .none
        case 1003: mouseTracking = enabled ? .anyMotion : .none
        case 1004: focusReporting = enabled
        case 1006: mouseSGR = enabled
        case 2004: bracketedPaste = enabled
        case 47, 1047, 1049: alternateScreen = enabled
        default: return false
        }
        return true
    }
}
