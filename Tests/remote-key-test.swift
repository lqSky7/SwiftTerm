import Foundation

/// Tests the translation from a browser's logical key to the bytes a shell receives.
///
/// This is the seam where a mistake is silent: a wrong escape sequence is not a crash, it is a key
/// the person did not press — an arrow that moves the cursor somewhere else, a Backspace that
/// deletes forwards, a Ctrl-C that is not an interrupt. So every case here asserts exact bytes.
///
/// The vocabulary is checked exhaustively rather than by example: `WireInputKey` is `CaseIterable`,
/// so a key added to the contract and not to the table fails here rather than at a shell.
@main
enum RemoteKeyTest {
    static func main() {
        let harness = Harness("remote-key-test")

        namedKeys(harness)
        modifierEncoding(harness)
        applicationCursorKeys(harness)
        letters(harness)
        coverage(harness)

        harness.finish()
    }

    /// The bytes for one key, as text, so an assertion reads as the sequence it is checking.
    private static func bytes(
        _ key: WireInputKey, _ modifiers: [WireModifier] = [], application: Bool = false
    ) -> String {
        guard
            let raw = RemoteKeyBytes.bytes(
                for: key, modifiers: modifiers, applicationCursorKeys: application)
        else { return "<none>" }
        return String(bytes: raw, encoding: .utf8) ?? "<not utf8>"
    }

    /// The named keys, as the sequences a terminal actually uses.
    private static func namedKeys(_ harness: Harness) {
        harness.equal(bytes(.enter), "\r", "Enter is CR")
        harness.equal(bytes(.tab), "\t", "Tab is HT")
        harness.equal(bytes(.escape), "\u{1B}", "Escape is ESC")

        // Backspace and forward-delete are different bytes, and swapping them is the classic way a
        // remote terminal becomes unusable in an editor.
        harness.equal(bytes(.backspace), "\u{7F}", "Backspace is DEL")
        harness.equal(bytes(.delete), "\u{1B}[3~", "forward-delete is the tilde form")

        harness.equal(bytes(.pageUp), "\u{1B}[5~", "PageUp")
        harness.equal(bytes(.pageDown), "\u{1B}[6~", "PageDown")

        // F1–F4 are SS3 finals; F5 onwards are tilde codes, and the gap at 16 is the terminal
        // standard's rather than an oversight.
        harness.equal(bytes(.f1), "\u{1B}OP", "F1")
        harness.equal(bytes(.f4), "\u{1B}OS", "F4")
        harness.equal(bytes(.f5), "\u{1B}[15~", "F5")
        harness.equal(bytes(.f6), "\u{1B}[17~", "F6 skips 16")
        harness.equal(bytes(.f12), "\u{1B}[24~", "F12")
    }

    /// The xterm modifier parameter, and that it reaches the sequence.
    private static func modifierEncoding(_ harness: Harness) {
        harness.equal(RemoteKeyBytes.modifierParameter([]), 1, "no modifiers is one")
        harness.equal(RemoteKeyBytes.modifierParameter([.shift]), 2, "shift adds one")
        harness.equal(RemoteKeyBytes.modifierParameter([.alt]), 3, "option adds two")
        harness.equal(RemoteKeyBytes.modifierParameter([.control]), 5, "control adds four")
        harness.equal(RemoteKeyBytes.modifierParameter([.shift, .control, .alt]), 8, "and they add up")
        // Meta has no bit: it is the escape prefix, not a parameter.
        harness.equal(RemoteKeyBytes.modifierParameter([.meta]), 1, "meta is not a parameter")

        harness.equal(bytes(.arrowUp, [.control]), "\u{1B}[1;5A", "Ctrl+Up")
        harness.equal(bytes(.pageUp, [.shift]), "\u{1B}[5;2~", "Shift+PageUp")
    }

    /// The shell's own mode decides the arrow form, and the caller has to supply it.
    private static func applicationCursorKeys(_ harness: Harness) {
        harness.equal(bytes(.arrowUp), "\u{1B}[A", "normal cursor keys")
        harness.equal(bytes(.arrowUp, [], application: true), "\u{1B}OA", "application cursor keys")
        harness.equal(bytes(.home, [], application: true), "\u{1B}OH", "Home follows the mode")
        // A modifier forces the CSI form either way, which is what the standard says and what a
        // program reading the sequence expects.
        harness.equal(
            bytes(.arrowUp, [.shift], application: true), "\u{1B}[1;2A", "a chord is CSI regardless")
        // F1 is the application form always, so the mode cannot change it.
        harness.equal(bytes(.f1), "\u{1B}OP", "F1 ignores the mode")
    }

    /// Letters, where the byte depends entirely on the chord.
    private static func letters(_ harness: Harness) {
        harness.equal(bytes(.a, [.control]), "\u{01}", "Ctrl-A is 0x01")
        harness.equal(bytes(.c, [.control]), "\u{03}", "Ctrl-C stays the interrupt")
        harness.equal(bytes(.z, [.control]), "\u{1A}", "Ctrl-Z is 0x1A")
        // Escape-then-key is what meta means to a terminal, so Option and Command translate alike.
        harness.equal(bytes(.a, [.alt]), "\u{1B}a", "Option-A is the escape prefix")
        harness.equal(bytes(.a, [.meta]), "\u{1B}a", "Meta-A is the escape prefix")
        harness.equal(bytes(.a, [.control, .alt]), "\u{1B}\u{01}", "both compose")
        harness.equal(bytes(.a, [.shift]), "A", "a shifted letter is upper case")
        harness.equal(bytes(.a), "a", "and a bare one is lower case")
    }

    /// Every key in the contract has a translation. This is the case that fails when the contract
    /// grows a key and the table does not.
    private static func coverage(_ harness: Harness) {
        var missing: [String] = []
        for key in WireInputKey.allCases {
            // A letter with no chord is not something the contract lets a browser send, so it is
            // exercised with one here rather than asserted to translate bare.
            let modifiers: [WireModifier] = key.isLetter ? [.control] : []
            let translated = RemoteKeyBytes.bytes(
                for: key, modifiers: modifiers, applicationCursorKeys: false)
            if translated == nil { missing.append(key.rawValue) }
        }
        harness.equal(missing, [], "every key in the contract translates")

        // And the count, so a key added to the enum shows up here as a number that moved.
        harness.equal(
            WireInputKey.allCases.count, 51,
            "five named, four arrows, four navigation, twelve function, twenty-six letters")
    }
}
