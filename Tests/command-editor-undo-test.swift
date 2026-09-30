import AppKit

@main @MainActor enum CommandEditorUndoTest {
    static func main() async throws {
        let harness = Harness("command-editor-undo-test")
        let editor = makeEditor()
        textInputPolicy(harness, editor: editor)
        let undo = NSMenuItem(title: "Undo", action: #selector(CommandEditorView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(CommandEditorView.redo(_:)), keyEquivalent: "z")
        let manager = editor.undoManager!
        manager.groupsByEvent = false
        harness.expect(!editor.validateMenuItem(undo), "empty draft disables Undo")
        var changes = 0
        var dismissals = 0
        editor.onBufferChanged = { changes += 1 }
        editor.onUndoRedo = { dismissals += 1 }
        edit(editor) { editor.insertText("echo 👩🏽‍💻\nsecond line", replacementRange: NSRange(location: 0, length: 0)) }
        let original = editor.string
        harness.expect(editor.validateMenuItem(undo), "native insertion registers undo")
        editor.undo(nil)
        harness.equal(editor.string, "", "undo removes Unicode multiline insertion")
        harness.expect(editor.validateMenuItem(redo), "undo enables Redo")
        editor.redo(nil)
        harness.equal(editor.string, original, "redo restores Unicode multiline insertion")
        harness.expect(changes >= 3, "undo and redo notify layout and suggestions")
        harness.equal(dismissals, 2, "undo and redo dismiss stale completion previews")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        edit(editor) { editor.insertText("printf", replacementRange: editor.selectedRange()) }
        harness.expect(editor.string.hasPrefix("printf"), "selection replacement changes just the selection")
        editor.undo(nil)
        harness.equal(editor.string, original, "undo restores selected text")
        harness.equal(editor.selectedRange(), NSRange(location: 0, length: 4), "undo restores selection")
        editor.redo(nil)
        harness.expect(editor.string.hasPrefix("printf"), "redo reapplies replacement")
        edit(editor) { editor.setBuffer("ls ./folder", caret: 3) }
        harness.equal(editor.selectedRange().location, 3, "completion replacement sets its caret")
        editor.undo(nil)
        harness.expect(editor.string.hasPrefix("printf"), "history/completion buffer replacements are undoable")
        editor.redo(nil)
        harness.equal(editor.string, "ls ./folder", "buffer replacement can be redone")
        editor.undo(nil)
        edit(editor) { editor.insertText("!", replacementRange: editor.selectedRange()) }
        harness.expect(!manager.canRedo, "new edit clears the redo branch")
        editor.reset()
        harness.equal(editor.string, "", "submit/cancel boundary clears the draft")
        harness.expect(!manager.canUndo && !manager.canRedo, "old commands cannot be resurrected with undo")
        let second = makeEditor()
        second.undoManager!.groupsByEvent = false
        edit(editor) { editor.insertText("first pane", replacementRange: editor.selectedRange()) }
        edit(second) { second.insertText("second pane", replacementRange: second.selectedRange()) }
        editor.undo(nil)
        harness.equal(second.string, "second pane", "undo histories are isolated per pane")
        try await surfaceRouting(harness)
        harness.finish()
    }

    private static func makeEditor() -> CommandEditorView {
        CommandEditorView(font: TerminalFont(pointSize: 14), palette: .builtin,
                          resolver: CommandResolver(path: "/usr/bin:/bin"))
    }

    private static func textInputPolicy(_ harness: Harness, editor: CommandEditorView) {
        let traits = ["autocorrectionType", "spellCheckingType", "grammarCheckingType", "smartQuotesType",
                      "smartDashesType", "smartInsertDeleteType", "textReplacementType", "dataDetectionType",
                      "linkDetectionType", "textCompletionType", "inlinePredictionType", "mathExpressionCompletionType"]
        for key in traits where editor.responds(to: NSSelectorFromString(key)) {
            harness.equal((editor.value(forKey: key) as? NSNumber)?.intValue, NSTextInputTraitType.no.rawValue,
                          "command editor disables \(key)")
        }
        harness.expect(editor.contentType == nil, "command editor has no AutoFill content hint")
        harness.expect(!editor.isAutomaticTextCompletionEnabled, "Apple completion does not compete with recommendations")
        harness.equal(editor.writingToolsBehavior, .none, "command editor disables Writing Tools")
        _ = NSApplication.shared
        let window = TextInputWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "")
        window.contentView = field
        field.contentType = .emailAddress
        field.isAutomaticTextCompletionEnabled = true
        field.disableTextIntelligence()
        guard let input = window.fieldEditor(true, for: field) as? NSTextView else {
            harness.expect(false, "window supplies a native field editor")
            harness.finish()
        }
        harness.expect(field.contentType == nil, "field clears AutoFill hints without recursive editor lookup")
        harness.expect(!field.isAutomaticTextCompletionEnabled, "field disables completion before editing")
        harness.expect(!field.allowsWritingTools && !field.allowsWritingToolsAffordance,
                       "window removes field Writing Tools affordances")
        input.contentType = .password
        input.isAutomaticTextCompletionEnabled = true
        for key in traits where input.responds(to: NSSelectorFromString(key)) {
            input.setValue(NSTextInputTraitType.yes.rawValue, forKey: key)
        }
        let nextField = NSTextField(string: "")
        window.contentView = nextField
        guard let reused = window.fieldEditor(true, for: nextField) as? NSTextView else {
            harness.expect(false, "window reuses a native field editor")
            harness.finish()
        }
        harness.expect(input === reused, "policy reuses the system field editor instead of allocating another")
        harness.expect(reused.contentType == nil, "reused field editor drops previous password hint")
        harness.expect(!reused.isAutomaticTextCompletionEnabled, "reused field editor disables Apple completion")
        for key in traits where reused.responds(to: NSSelectorFromString(key)) {
            harness.equal((reused.value(forKey: key) as? NSNumber)?.intValue, NSTextInputTraitType.no.rawValue,
                          "reused field editor disables \(key)")
        }
        var requests = 0
        editor.onCompletionRequest = { requests += 1; return true }
        editor.complete(nil)
        harness.equal(requests, 1, "manual completion uses the app's engine instead of Apple's dictionary")
        editor.onCompletionRequest = nil
    }

    private static func edit(_ editor: CommandEditorView, _ operation: () -> Void) {
        editor.undoManager!.beginUndoGrouping()
        operation()
        editor.undoManager!.endUndoGrouping()
    }

    private static func surfaceRouting(_ harness: Harness) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "swiftterm-undo-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = try TerminalSession(size: .fallback,
            environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": home.path, "PS1": ""],
            homeDirectory: home.path)
        session.historyStore = CommandHistoryStore(url: home.appending(path: "history"))
        defer { session.stop() }
        let surface = TerminalSurfaceView(session: session, pointSize: 14)
        let editor = surface.subviews.compactMap { $0 as? CommandEditorView }.first!
        editor.undoManager!.groupsByEvent = false
        session.write("printf '\\033]133;A\\007\\033]133;B\\007'\n")
        let deadline = ContinuousClock.now + .seconds(5)
        while session.activeBlock?.headerGrid.promptEnd == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        harness.expect(session.activeBlock?.headerGrid.promptEnd != nil, "scratch shell reaches an editable prompt")
        edit(editor) { editor.insertText("draft", replacementRange: editor.selectedRange()) }
        let item = NSMenuItem(title: "Undo", action: #selector(CommandEditorView.undo(_:)), keyEquivalent: "z")
        harness.expect(surface.validateMenuItem(item), "surface routes Undo to the active draft")
        surface.undo(nil)
        harness.equal(editor.string, "", "surface action undoes editor text after focus drift")
        surface.redo(nil)
        harness.equal(editor.string, "draft", "surface action redoes editor text")
        session.write("printf '\\033[?1049h'\n")
        while !session.isAlternateScreen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        harness.expect(session.isAlternateScreen, "scratch shell enters fullscreen mode")
        harness.expect(!surface.validateMenuItem(item), "fullscreen programs do not expose editor Undo")
        surface.undo(nil)
        harness.equal(editor.string, "draft", "fullscreen Undo does not mutate the hidden draft")
    }
}
