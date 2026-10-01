import AppKit
import SwiftUI

@MainActor
final class AccountWindowController: NSWindowController, NSWindowDelegate {
    private let account: AccountController

    init(account: AccountController, signOut: @escaping () async -> Void,
         revoke: @escaping (String) async -> Void) {
        self.account = account
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Account"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AccountView(
            account: account, signOut: signOut, revoke: revoke))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if !account.isSignedIn { account.cancelSignIn() }
    }
}

private struct AccountView: View {
    let account: AccountController
    let signOut: () async -> Void
    let revoke: (String) async -> Void
    @State private var pendingRevoke: String?

    var body: some View {
        Form {
            if let summary = account.account {
                Section("Your Account") {
                    Text(summary.displayName.isEmpty ? "Your account" : summary.displayName)
                    Text(summary.id).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Sign Out") { Task { await signOut() } }
                }
                Section("Registered Devices") {
                    ForEach(account.devices, id: \.id) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.label)
                                if device.id == account.deviceID { Text("This Mac").font(.caption) }
                            }
                            Spacer()
                            if device.revokedAt != nil {
                                Text("Revoked").foregroundStyle(.secondary)
                            } else {
                                Button("Revoke") { pendingRevoke = device.id }
                            }
                        }
                    }
                    if account.devices.isEmpty { Text("No registered devices.") }
                    Button("Refresh") { Task { await account.refreshDevices() } }
                    if account.deviceID == nil {
                        Button("Register This Mac") { Task { await account.registerThisDevice() } }
                    }
                }
                if let error = account.lastError { Text(error.messageForUser).foregroundStyle(.secondary) }
            } else {
                Section("Sign In") { SignInSection(account: account) }
            }
        }
        .formStyle(.grouped)
        .task(id: account.isSignedIn) {
            if account.isSignedIn { await account.refreshDevices() }
        }
        .sheet(isPresented: Binding(
            get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Revoke this device?").font(.headline)
                Text("Its shared panes will stop. Local terminals will keep running.")
                HStack {
                    Button("Cancel") { pendingRevoke = nil }
                    Button("Revoke", role: .destructive) {
                        guard let id = pendingRevoke else { return }
                        pendingRevoke = nil
                        Task { await revoke(id) }
                    }
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }
}
