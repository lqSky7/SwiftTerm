import AppKit
import SwiftUI

/// The window onto sharing: sign in, share a pane, and watch what is happening to it.
///
/// **It exists because the alternative was a menu item that silently did nothing.** Sharing needs an
/// account, an account needs a sign-in, and there was no sign-in anywhere in the app — so
/// `startSharing` refused on a nil `deviceID` and pressing Share produced no visible effect at all.
/// A command that appears available and does nothing is the one people conclude is broken, and they
/// are right to.
///
/// The states are shown in the order they must be resolved, and each says what it is waiting for:
///
///   * **Signed out** — the password grant, or a pasted token when the build has no Supabase pair.
///   * **Signed in, no device** — a publisher ticket is minted *for a device*, so this has to exist
///     before a stream can.
///   * **Ready** — one button, and the link once it is up.
///   * **Sharing** — the link, who is watching, who is asking to type, and the way to stop.
struct ShareSheet: View {
    let workspace: AppCore
    let paneID: PaneID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: 420, alignment: .leading)
        // The device list is what tells a person whether this machine is registered, and it is the
        // backend's answer rather than anything remembered here. Fetched when the sheet opens, and
        // again after a sign-in, because both are moments the answer can have changed.
        .task(id: workspace.account.isSignedIn) {
            guard workspace.account.isSignedIn else { return }
            await workspace.account.refreshDevices()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Share this pane")
                .font(.headline)
                .foregroundStyle(Theme.Colors.titlebarInk)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
        }
    }

    private var subtitle: String {
        if !workspace.account.isSignedIn { return "Sharing needs an account, so anyone with the link can be revoked." }
        if workspace.account.deviceID == nil { return "This machine has to be registered before a pane can be published." }
        if let sharing = workspace.sharing[paneID] {
            return sharing.viewerCount == 1 ? "Live · 1 viewer" : "Live · \(sharing.viewerCount) viewers"
        }
        return "Nobody can see this pane yet. The link appears here once it is up."
    }

    @ViewBuilder
    private var content: some View {
        if !workspace.account.isSignedIn {
            SignInSection(workspace: workspace)
        } else if workspace.account.deviceID == nil {
            DeviceSection(workspace: workspace)
        } else if let sharing = workspace.sharing[paneID] {
            LiveSection(workspace: workspace, paneID: paneID, sharing: sharing)
        } else {
            ReadySection(workspace: workspace, paneID: paneID)
        }
    }

    private var footer: some View {
        HStack {
            if workspace.account.isSignedIn {
                Button("Sign Out") { Task { await workspace.signOut() } }
                    .buttonStyle(.link)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The password grant, or a token when the build has no Supabase pair configured.
///
/// Both paths exist because both are real: the deployed build signs in with a password against
/// Supabase, and a development build without those keys still needs a way in — which is the same
/// escape hatch the website offers.
private struct SignInSection: View {
    let workspace: AppCore

    @State private var email = ""
    @State private var password = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if workspace.account.configuration.canSignInWithPassword {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit { submit() }
                Button("Sign In") { submit() }
                    .disabled(email.isEmpty || password.isEmpty || workspace.account.isWorking)
            } else {
                // Said rather than hidden. A build with no Supabase pair cannot do a password grant,
                // and a field that silently fails is worse than one that explains itself.
                Text("This build has no Supabase configuration, so sign in with an access token.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                SecureField("Access token", text: $token)
                    .onSubmit { submitToken() }
                Button("Sign In") { submitToken() }
                    .disabled(token.isEmpty || workspace.account.isWorking)
            }

            if let error = workspace.account.lastError {
                Text(error.messageForUser)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.75, light: 0.65))
            }
            if workspace.account.isWorking { ProgressView().controlSize(.small) }
        }
    }

    private func submit() {
        let flow = SignInFlow(configuration: workspace.account.configuration, controller: workspace.account)
        Task { await flow.signIn(email: email, password: password) }
    }

    private func submitToken() {
        let flow = SignInFlow(configuration: workspace.account.configuration, controller: workspace.account)
        flow.signIn(accessToken: token)
    }
}

private struct DeviceSection: View {
    let workspace: AppCore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(
                "A publisher ticket is minted for a device, so this machine has to be registered "
                    + "before a pane can be published.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
            Button("Register This Machine") {
                Task { await workspace.account.registerThisDevice() }
            }
            .disabled(workspace.account.isWorking)

            if let error = workspace.account.lastError {
                Text(error.messageForUser)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.75, light: 0.65))
            }
            if workspace.account.isWorking { ProgressView().controlSize(.small) }
        }
    }
}

private struct ReadySection: View {
    let workspace: AppCore
    let paneID: PaneID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Button("Share This Pane") { workspace.startSharing(paneID) }
            // The refusal is shown rather than swallowed. `startSharing` can still fail — a pane with
            // no shell, a device that was revoked on another machine — and a button that does nothing
            // is what this whole sheet exists to replace.
            if let failure = workspace.sharingFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.75, light: 0.65))
            }
        }
    }
}

private struct LiveSection: View {
    let workspace: AppCore
    let paneID: PaneID
    let sharing: PaneSharing

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if let link = workspace.shareLink(for: paneID) {
                ShareLinkField(link: link)
            } else {
                // Between "sharing started" and "the relay answered" there is a real gap, and saying
                // so is better than showing a link that does not work yet.
                Text("Waiting for the relay…")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
            }

            if sharing.hasPendingRequest {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("A browser is asking to type.")
                        .font(.callout)
                    HStack {
                        Button("Allow") { sharing.approveControl() }
                        Button("Deny") { sharing.denyControl() }
                    }
                }
            } else if sharing.canControl {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("A browser has control. Type in the terminal to take it back.")
                        .font(.callout)
                    Button("Revoke") { sharing.revokeControl(reason: .revoked) }
                }
            }

            Button("Stop Sharing") { workspace.stopSharing(paneID) }
        }
    }
}

/// The link, with the one action anyone wants from it.
private struct ShareLinkField: View {
    let link: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Send this to whoever should watch:")
                .font(.caption)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
            HStack(spacing: Theme.Spacing.md) {
                // Selectable as well as copyable: a link someone cannot select is a link they cannot
                // paste into a chat they are already in.
                Text(link)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") { copy() }
            }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        copied = true
        // Reverted on a timer rather than left saying "Copied", which would be a claim about the
        // clipboard that stops being about the last action the moment anything else is copied.
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The sidebar's way in.
///
/// A sheet nobody can find is a sheet nobody uses, and the menu bar is not where a person looks for
/// "share this terminal" — so this sits with the window's other controls.
struct ShareButton: View {
    let workspace: AppCore

    var body: some View {
        Button {
            workspace.openShareSheet()
        } label: {
            // Matched to `SettingsButton` rather than invented: these two sit beside each other, and a
            // pair of controls that disagree about their own size look like a mistake.
            Image(systemName: "person.2")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Share this pane (⇧⌘S)")
    }
}
