import AppKit
import SwiftUI

extension NSTextView {
    // Traits are optional AppKit selectors, not declared Swift properties on NSTextView.
    func disableTextIntelligence() {
        for key in Self.textIntelligenceTraits where responds(to: NSSelectorFromString(key)) {
            setValue(NSTextInputTraitType.no.rawValue, forKey: key)
        }
        contentType = nil
        writingToolsBehavior = .none
        isAutomaticTextCompletionEnabled = false
    }

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
    func disableTextIntelligence() {
        contentType = nil
        isAutomaticTextCompletionEnabled = false
        allowsWritingTools = false
        allowsWritingToolsAffordance = false
    }

    func disableTextIntelligenceInFieldEditor() {
        (currentEditor() as? NSTextView)?.disableTextIntelligence()
    }
}

extension View {
    func disableTextIntelligence() -> some View {
        autocorrectionDisabled()
            .textContentType(nil)
            .writingToolsBehavior(.disabled)
    }
}

// All native and SwiftUI fields use the window's editor, including newly added Settings fields.
final class TextInputWindow: NSWindow {
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        (editor as? NSTextView)?.disableTextIntelligence()
        return editor
    }
}
