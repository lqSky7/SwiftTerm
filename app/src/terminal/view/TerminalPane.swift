import AppKit
import SwiftUI

/// One pane's content: the terminal surface, or why the shell could not start.
///
/// The window's backdrop is deliberately not here. It belongs to the window, in `WorkspaceScreen`,
/// because with more than one pane a blur behind each pane would be a stack of blurs behind each
/// other — and because the sidebar and the tab strip are glass *over* that backdrop, so it has to be
/// under all of them rather than under one of them.
struct TerminalPane: View {
    let workspace: AppCore
    let paneID: PaneID
    let coordinator: TerminalCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Only while this pane is sharing. A pane that is not shows nothing rather than a bar
            // that says "not sharing", because a strip on every pane would be a permanent reminder
            // of a feature nobody asked to use.
            if let sharing = workspace.sharing[paneID] {
                SharingBar(sharing: sharing, onStop: { workspace.stopSharing(paneID) })
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
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

/// What the pane says about sharing, and what it asks when a browser wants to type.
///
/// Three states, in the order they can be true:
///
///   * **A browser is asking.** The prompt comes first because it is the only one that needs an
///     answer, and answering it is what makes the other two reachable. Nothing is granted by asking.
///   * **A browser has control.** Shown for the whole time it is held, with the way out: any
///     keystroke at this machine takes it back, and the bar says so rather than leaving a person to
///     discover it.
///   * **Sharing, with nobody driving.** The viewer count, and the way to stop.
private struct SharingBar: View {
    let sharing: PaneSharing
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            content
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.ramp(dark: 0.08, light: 0.05))
    }

    @ViewBuilder
    private var content: some View {
        if sharing.hasPendingRequest {
            Text("A browser is asking to type.")
                .foregroundStyle(Theme.Colors.titlebarInk)
            Button("Allow") { sharing.approveControl() }
                .buttonStyle(.borderless)
            Button("Deny") { sharing.denyControl() }
                .buttonStyle(.borderless)
        } else if sharing.canControl {
            // The escape hatch is named rather than implied. A person who does not know that typing
            // takes control back will look for a button, and there is not going to be one: a browser
            // that could hold a prompt against the person at the machine would be the whole problem.
            Text("A browser has control. Type here to take it back.")
                .foregroundStyle(Theme.Colors.titlebarInk)
            Button("Revoke") { sharing.revokeControl(reason: .revoked) }
                .buttonStyle(.borderless)
        } else {
            Text(sharing.viewerCount == 1 ? "Shared · 1 viewer" : "Shared · \(sharing.viewerCount) viewers")
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
            Button("Stop Sharing", action: onStop)
                .buttonStyle(.borderless)
        }
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
