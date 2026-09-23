import AppKit
import SwiftUI

/// One pane's content: the terminal surface, or why the shell could not start.
///
/// The window's backdrop is deliberately not here. It belongs to the window, in `WorkspaceScreen`,
/// because with more than one pane a blur behind each pane would be a stack of blurs behind each
/// other — and because the sidebar and the tab strip are glass *over* that backdrop, so it has to be
/// under all of them rather than under one of them.
struct TerminalPane: View {
    let coordinator: TerminalCoordinator

    var body: some View {
        if let surface = coordinator.surface {
            TerminalSurfaceRepresentable(surface: surface)
        } else {
            failureMessage
        }
    }

    private var failureMessage: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("swiftTerm could not start a shell")
                .font(.headline)
                .foregroundStyle(Theme.Colors.titlebarInk)
            Text(coordinator.failure ?? "The reason was not reported.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: 420)
    }
}

/// Hosts the surface the coordinator already built. The view is created once, by the feature, so
/// SwiftUI is only being asked to place it — not to own its lifetime.
///
/// Not private: a window with more than one pane places several of these, one per pane, and a second
/// representable for the same job would be a second place for the surface's lifecycle to be decided.
struct TerminalSurfaceRepresentable: NSViewRepresentable {
    let surface: TerminalSurfaceView

    func makeNSView(context: Context) -> TerminalSurfaceView { surface }

    func updateNSView(_ view: TerminalSurfaceView, context: Context) {}
}
