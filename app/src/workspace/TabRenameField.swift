import AppKit
import SwiftUI

/// The field a tab is renamed in.
///
/// An `NSTextField` behind a representable rather than SwiftUI's `TextField`, for two reasons.
///
/// The first is focus. Putting the caret in a SwiftUI `TextField` needs `@FocusState`, which is a
/// macro the whole-app typecheck cannot expand — and that typecheck is the only automated check the
/// view layer has, so a view that uses one drops out of the gate. This takes the keyboard the same way
/// the terminal surface does: when it *arrives* in a window. One story about focus in this app rather
/// than two, and no view state anywhere.
///
/// The second is that `NSTextField` is what a rename in a sidebar is on this platform, and the escape
/// and return behaviour comes with it.
struct TabRenameField: NSViewRepresentable {
    let text: String
    let onEdit: (String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusOnArrivalField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onEdit = onEdit
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        // Only while nobody is editing it: writing `stringValue` mid-edit moves the caret to the end.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onEdit: (String) -> Void
        var onCommit: () -> Void
        var onCancel: () -> Void

        init(
            onEdit: @escaping (String) -> Void, onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onEdit = onEdit
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onEdit(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
            if movement == NSTextMovement.cancel.rawValue {
                onCancel()
            } else {
                onCommit()
            }
        }

        @objc func commit() {
            onCommit()
        }
    }
}

/// A field that takes the keyboard when it lands in a window, with its text selected so a rename is
/// one gesture: double-click, type, Return.
private final class FocusOnArrivalField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, currentEditor() == nil else { return }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
