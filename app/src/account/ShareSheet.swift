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
            if workspace.sharing[paneID] == nil {
                Button("Temporary Public Stream") { workspace.preparePublicShare(paneID, live: true) }
                    .disabled(workspace.isPreparingShare)
                Text("Anyone with the link can watch for one hour. Read-only; stops when you stop sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Public Static Snapshot…") { workspace.preparePublicShare(paneID, live: false) }
                .disabled(workspace.isPreparingShare)
            Text("Share completed commands with anyone. No live connection.")
                .font(.caption).foregroundStyle(.secondary)
            if workspace.isPreparingShare { ProgressView("Setting up sharing…") }
            if let error = workspace.sharingFailure { Text(error).font(.caption).foregroundStyle(.secondary) }
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
        if !workspace.account.isSignedIn { return "Choose a public link, or sign in below for private sharing." }
        if workspace.account.deviceID == nil { return "This machine has to be registered before a pane can be published." }
        if let sharing = workspace.sharing[paneID] {
            return sharing.viewerCount == 1 ? "Live · 1 viewer" : "Live · \(sharing.viewerCount) viewers"
        }
        return "Nobody can see this pane yet. The link appears here once it is up."
    }

    @ViewBuilder
    private var content: some View {
        if !workspace.account.isSignedIn {
            SignInSection(account: workspace.account)
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
            Button("Account…") { workspace.openAccount() }
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

/// The password grant, or — when this build has no Supabase pair — an explanation of why it cannot
/// sign anyone in, and the operator path underneath.
///
/// **It used to be a bare "Access token" field with a line of jargon.** That is accurate and
/// useless: somebody who has never seen a Supabase token has no idea what one is, where it comes
/// from, or who could give them one, and a sheet that cannot sign anybody in should say so rather
/// than invite them to paste a credential they do not have.
///
/// So the unconfigured state says three things in the order a person needs them: what is wrong, what
/// would fix it, and who can do that. The token field is behind a disclosure, labelled as the
/// operator path, with the command that produces one.
struct SignInSection: View {
    let account: AccountController

    @State private var email = ""
    @State private var password = ""
    @State private var token = ""
    @State private var showingTokenPath = false
    @State private var anonymousAvailable = false

    /// The project the backend verifies tokens against — the same value as its `OIDC_ISSUER`. Named
    /// here so the link an operator needs is one click rather than a hunt through a dashboard.
    private static let projectRef = "upmarjiewuwvaljnnboq"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if account.configuration.canSignInWithPassword {
                passwordPath
                if anonymousAvailable {
                    Button("Continue Anonymously") {
                        account.signInAnonymously()
                    }
                    .disabled(account.isAuthenticating)
                    Text("This account stays on this Mac. Without a recovery email, signing out loses access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                notConfigured
            }

            if let error = account.lastError {
                Text(error.messageForUser)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.75, light: 0.65))
            }
            if account.isAuthenticating { ProgressView().controlSize(.small) }
        }
        .task {
            guard let url = account.configuration.supabaseURL,
                let key = account.configuration.supabaseAnonKey else { return }
            anonymousAvailable = await SupabaseAuth(url: url, anonKey: key).anonymousAvailable()
        }
        .onDisappear { if !account.isSignedIn { account.cancelSignIn() } }
    }

    private var passwordPath: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { submit() }
            Button("Sign In") { submit() }
                .disabled(email.isEmpty || password.isEmpty || account.isAuthenticating)
        }
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Sign-in is not set up in this build.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.titlebarInk)
                Text(
                    "Sharing needs an account, and this build has no Supabase configuration, so "
                        + "there is nothing here to sign in with yet. It is a build setting rather "
                        + "than something you can fix from this window.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("The URL is already set. The missing half is the client key:")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                Text("app/Info.plist → SwiftTermSupabaseAnonKey")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                // A real link, because "go to the dashboard" is the instruction that made the old
                // version useless. **`settings/api-keys`, not `settings/api`** — Supabase's own docs
                // are explicit that there is no separate "Settings → API" page any more, and a link
                // that lands on a page which does not exist is worse than no link: it looks like the
                // reader did something wrong.
                Link(
                    "Open Settings → API Keys",
                    destination: URL(
                        string:
                            "https://supabase.com/dashboard/project/\(Self.projectRef)/settings/api-keys/"
                    )!)
                    .font(.caption)
                // And the one-click version, which shows the URL and the key together.
                Link(
                    "Open the Connect dialog",
                    destination: URL(
                        string:
                            "https://supabase.com/dashboard/project/\(Self.projectRef)?showConnect=true"
                    )!)
                    .font(.caption)
                Text(
                    "It is the anon public key — or its newer name, publishable. It is publishable "
                        + "and safe to embed: it authorises the client, and every row is still "
                        + "scoped by row-level security. The secret key (formerly service_role) "
                        + "must never go in this file.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only in a build that asked for it. A shipped build shows the explanation and nothing
            // else, which is the honest answer when there is no way in — and it means the escape
            // hatch cannot reach a user by default rather than by somebody remembering to remove it.
            if account.configuration.allowsTokenSignIn {
                DisclosureGroup("I already have an access token", isExpanded: $showingTokenPath) {
                    tokenPath
                }
                .font(.callout)
            }
        }
    }

    private var tokenPath: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(
                "An access token is a short-lived signed pass that Supabase Auth issues when "
                    + "somebody signs in. It is not a password and not a shared secret: the "
                    + "backend verifies its signature against the project's published keys, so a "
                    + "token it did not issue is refused. It is valid for about an hour.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                .fixedSize(horizontal: false, vertical: true)
            Text("This produces one, given the same anon key and an account that already exists:")
                .font(.caption)
                .foregroundStyle(Theme.Colors.ramp(dark: 0.6, light: 0.55))
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.curlCommand)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.ramp(dark: 0.08, light: 0.05))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            SecureField("Access token", text: $token)
                .onSubmit { submitToken() }
            Button("Sign In") { submitToken() }
                .disabled(token.isEmpty || account.isAuthenticating)
        }
        .padding(.top, Theme.Spacing.md)
    }

    private static let curlCommand = """
        curl -s -X POST \\
          'https://upmarjiewuwvaljnnboq.supabase.co/auth/v1/token?grant_type=password' \\
          -H 'apikey: <ANON_KEY>' -H 'content-type: application/json' \\
          -d '{"email":"you@example.com","password":"..."}' | jq -r .access_token
        """

    private func submit() {
        account.signIn(email: email, password: password)
    }

    private func submitToken() {
        let flow = SignInFlow(configuration: account.configuration, controller: account)
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
            .disabled(workspace.account.isAuthenticating)

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

            if sharing.publisher?.publicReadSecret != nil {
                Text("Public · read-only · expires one hour after starting")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let sessionID = sharing.publisher?.sessionID {
                InvitationSection(account: workspace.account, sessionID: sessionID)
            }
            if case .failed(let reason) = sharing.publisher?.state {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                if sharing.publisher?.publicReadSecret != nil {
                    Button("Start New Temporary Public Stream") {
                        workspace.stopSharing(paneID)
                        workspace.preparePublicShare(paneID, live: true)
                    }
                }
            }
            Button("Stop Sharing") { workspace.stopSharing(paneID) }
        }
    }
}

private struct InvitationSection: View {
    let account: AccountController
    let sessionID: String
    @State private var recipientID = ""
    @State private var permission = "viewer"
    @State private var link: String?
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Invite a Browser").font(.headline)
            Text("Ask the viewer for the account ID shown on the stream page. Anonymous accounts are separate on each device.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Viewer account ID", text: $recipientID)
            Picker("Access", selection: $permission) {
                Text("Watch").tag("viewer")
                Text("Watch and request control").tag("controller")
            }
            Button(isWorking ? "Creating…" : "Create Invitation") {
                isWorking = true
                error = nil
                link = nil
                Task {
                    defer { isWorking = false }
                    do {
                        let invite = try await account.invite(
                            sessionID: sessionID, recipientID: recipientID, permission: permission)
                        link = "\(account.configuration.origin)/live/?s=\(sessionID)#invite=\(invite.code)"
                    } catch {
                        self.error = "Could not create the invitation. Check the viewer’s account ID and try again."
                    }
                }
            }
            .disabled(UUID(uuidString: recipientID) == nil || isWorking)
            if let link { ShareLinkField(link: link) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
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
