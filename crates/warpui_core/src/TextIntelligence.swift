import AppKit

/// A terminal's text views, with the system's *text intelligence* turned off.
///
/// **None of it means anything for a shell.** macOS offers a command line everything it offers a form:
/// autocorrection, smart quotes and dashes, text replacement, data and link detection, spelling and
/// grammar, text completion, inline prediction, math completion, Writing Tools. A command is not prose —
/// a smart quote typed into one is a different byte, a completed word is a word the shell will reject,
/// and a link detected inside a path is a decoration on text nobody is reading. Warp turns the same set
/// off for the same reason.
///
/// **And behind several of them is AutoFill.** macOS 26 starts an AutoFill helper *per app* — the
/// `AutoFill (<app>)` process that appears in Activity Monitor and lives for as long as the app does —
/// because AppKit's text input offers passwords, passkeys, contacts and cards to any field that might
/// take them. Nothing here can: this app has no forms, no accounts and no network, so there is nothing
/// for the helper to have been started for. The fields say so, and it stops being started.
///
/// **Every one of these defaults to `.default`, which means "whatever the system setting says"** — which
/// is why this is a fix rather than a preference. On a Mac with smart quotes on, the terminal had them
/// on too, and the editor was quietly rewriting the characters being typed into a shell.
///
/// The trait family is AppKit's `NSTextInputTraits`. `NSTextView` implements it but does not declare it
/// to Swift, so the access is `value(forKey:)` rather than a property — the *keys* and the enum are
/// AppKit's, and only the spelling of the access is ours.
extension NSTextView {
    /// Turn off every text-intelligence trait this view answers to.
    ///
    /// Answered-to rather than assumed: a key nothing implements is an `NSUnknownKeyException` and a
    /// crash at launch, and the trait family is a protocol's — AppKit is free to add to it and this
    /// target is free to run on a macOS that predates the newest member.
    func disableTextIntelligence() {
        for key in Self.textIntelligenceTraits where responds(to: NSSelectorFromString(key)) {
            setValue(NSTextInputTraitType.no.rawValue, forKey: key)
        }
        // Not a trait but a sibling: the service that rewrites what you typed, which a shell has even
        // less use for than the rest.
        if responds(to: NSSelectorFromString("writingToolsBehavior")) {
            setValue(NSWritingToolsBehavior.none.rawValue, forKey: "writingToolsBehavior")
        }
        // Declared on the class rather than by the protocol, so this one is a property and not a key.
        isAutomaticTextCompletionEnabled = false
    }

    /// The trait family, in one list so it reads as a set and so a member that stops existing is one
    /// edit rather than a hunt.
    private static let textIntelligenceTraits = [
        "autocorrectionType",
        "spellCheckingType",
        "grammarCheckingType",
        "smartQuotesType",
        "smartDashesType",
        "smartInsertDeleteType",
        "textReplacementType",
        "dataDetectionType",
        "linkDetectionType",
        "textCompletionType",
        "inlinePredictionType",
        "mathExpressionCompletionType",
    ]
}

extension NSTextField {
    /// The same, for a field.
    ///
    /// **A field's traits are not its own** — they live on the *field editor*, the shared `NSTextView`
    /// AppKit lends a field while it is being edited — so what is set here is only what a field
    /// declares, and `becomeFirstResponder` in the field's own subclass is where the editor gets the
    /// treatment above. Both halves are needed; either alone leaves half the typing covered.
    func disableTextIntelligence() {
        isAutomaticTextCompletionEnabled = false
        // Writing Tools is the other system service that attaches itself to a text view, and a shell
        // command is not something to rewrite.
        allowsWritingTools = false
        allowsWritingToolsAffordance = false
    }

    /// What a field has to do the moment it is edited: reach the editor AppKit has just made for it.
    ///
    /// Called from `becomeFirstResponder` in a field's subclass, after `super` — the editor does not
    /// exist until the field is the first responder.
    func disableTextIntelligenceInFieldEditor() {
        (currentEditor() as? NSTextView)?.disableTextIntelligence()
    }
}
