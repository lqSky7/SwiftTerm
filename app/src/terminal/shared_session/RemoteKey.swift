import Foundation

/// The bytes a logical key from a browser produces.
///
/// This is the seam between two vocabularies — the contract's logical keys and the terminal's escape
/// sequences — and it lives here rather than in the view for one reason: getting it wrong produces a
/// keystroke nobody typed, and a translation behind a view that needs a running shell is a
/// translation nothing can check. `Tests/remote-key-test.swift` asserts every sequence exactly.
///
/// It is deliberately *not* a second key path. `TerminalSurfaceView` keys its own table on
/// `NSEvent.SpecialKey`; a browser sends a logical key, and translating one into the other would mean
/// fabricating an `NSEvent` for a keystroke that never happened. Both tables call `TerminalInput`, so
/// the escape grammar itself stays in one place.
enum RemoteKeyBytes {
    /// The bytes for one logical key, or nil when the key has no translation.
    ///
    /// `applicationCursorKeys` is the shell's own mode and is the caller's to supply: arrows and the
    /// home/end pair are sent in the application form only while a program has asked for it, and
    /// guessing would break either `vim` or the shell depending on which way the guess went.
    static func bytes(
        for key: WireInputKey, modifiers: [WireModifier], applicationCursorKeys: Bool
    ) -> [UInt8]? {
        if key.isLetter { return letterBytes(for: key, modifiers: modifiers) }
        let modifier = modifierParameter(modifiers)
        switch key {
        case .enter: return [0x0D]
        case .tab: return [0x09]
        // Backspace is 0x7F and forward-delete is the tilde form. Swapping them is the classic way a
        // remote terminal becomes unusable in an editor, which is why the two are named separately.
        case .backspace: return [0x7F]
        case .delete: return TerminalInput.tilde(3, modifier: modifier)
        case .escape: return [0x1B]
        case .arrowUp: return TerminalInput.cursor("A", application: applicationCursorKeys, modifier: modifier)
        case .arrowDown: return TerminalInput.cursor("B", application: applicationCursorKeys, modifier: modifier)
        case .arrowRight: return TerminalInput.cursor("C", application: applicationCursorKeys, modifier: modifier)
        case .arrowLeft: return TerminalInput.cursor("D", application: applicationCursorKeys, modifier: modifier)
        case .home: return TerminalInput.cursor("H", application: applicationCursorKeys, modifier: modifier)
        case .end: return TerminalInput.cursor("F", application: applicationCursorKeys, modifier: modifier)
        case .pageUp: return TerminalInput.tilde(5, modifier: modifier)
        case .pageDown: return TerminalInput.tilde(6, modifier: modifier)
        // F1–F4 are the SS3 finals and are always sent in the application form, whatever the shell
        // asked for — which is why `TerminalSurfaceView`'s own table hard-codes `true` here too.
        case .f1: return TerminalInput.cursor("P", application: true, modifier: modifier)
        case .f2: return TerminalInput.cursor("Q", application: true, modifier: modifier)
        case .f3: return TerminalInput.cursor("R", application: true, modifier: modifier)
        case .f4: return TerminalInput.cursor("S", application: true, modifier: modifier)
        case .f5: return TerminalInput.tilde(15, modifier: modifier)
        case .f6: return TerminalInput.tilde(17, modifier: modifier)
        case .f7: return TerminalInput.tilde(18, modifier: modifier)
        case .f8: return TerminalInput.tilde(19, modifier: modifier)
        case .f9: return TerminalInput.tilde(20, modifier: modifier)
        case .f10: return TerminalInput.tilde(21, modifier: modifier)
        case .f11: return TerminalInput.tilde(23, modifier: modifier)
        case .f12: return TerminalInput.tilde(24, modifier: modifier)
        // Unreachable: the vocabulary is the named keys above plus A–Z, and `isLetter` took those. A
        // case added to `WireInputKey` and not to this table produces nothing rather than a byte
        // nobody agreed on, which is the failure worth having.
        default: return nil
        }
    }

    /// The xterm modifier parameter: one, plus one for shift, two for option and four for control.
    static func modifierParameter(_ modifiers: [WireModifier]) -> Int {
        var value = 1
        for modifier in modifiers {
            switch modifier {
            case .shift: value += 1
            case .alt: value += 2
            case .control: value += 4
            // Meta has no bit here. On a terminal, meta is the escape prefix rather than a parameter,
            // and it is applied where the bytes are built rather than folded into this number.
            case .meta: break
            }
        }
        return value
    }

    private static func letterBytes(for key: WireInputKey, modifiers: [WireModifier]) -> [UInt8] {
        guard let scalar = key.rawValue.unicodeScalars.first else { return [] }
        var bytes: [UInt8] = []
        // Escape-then-key is what meta means to a terminal, and it is the only honest translation of
        // a browser's Command key into bytes a shell understands.
        if modifiers.contains(.alt) || modifiers.contains(.meta) { bytes.append(0x1B) }
        if modifiers.contains(.control) {
            // The control characters are the letters folded onto 0x40: Ctrl-A is 0x01.
            bytes.append(UInt8(scalar.value - 0x60))
        } else if modifiers.contains(.shift) {
            // A bare shifted letter is sent as text by the browser, so this only happens on a chord
            // carrying shift and no control — and there the upper-case letter is what was meant.
            bytes.append(UInt8(scalar.value - 0x20))
        } else {
            bytes.append(UInt8(scalar.value))
        }
        return bytes
    }
}
