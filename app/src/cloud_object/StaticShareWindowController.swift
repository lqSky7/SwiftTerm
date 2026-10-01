import AppKit
import SwiftUI

@MainActor final class StaticShareWindowController: NSWindowController, NSWindowDelegate {
    private let share: StaticShareCoordinator

    init(share: StaticShareCoordinator) {
        self.share = share
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Public Static Snapshot"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StaticShareView(share: share))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { share.stop() }
}

private struct StaticShareView: View {
    @Bindable var share: StaticShareCoordinator

    var body: some View {
        Form {
            Section {
                Text("Anyone with the link can read this snapshot without signing in. "
                     + "It stays available when your Mac is offline.")
                Text("Choose from the 20 most recent completed commands. Only selected commands are uploaded. "
                     + "Review the automatic masking and edit any remaining secrets below.")
                    .foregroundStyle(.secondary)
            } header: { Text("Public static snapshot") }
            if share.isPreparing { ProgressView("Preparing local preview…") }
            ForEach($share.blocks) { $block in
                Section {
                    Toggle("Include command", isOn: $block.selected)
                    TextField("Command", text: $block.command).font(.system(.body, design: .monospaced))
                    TextEditor(text: $block.output)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 240)
                    if let code = block.exitCode { Text("Exit code: \(code)").font(.caption) }
                }.disabled(share.isFrozen)
            }
            Section {
                if let error = share.error { Text(error).foregroundStyle(.secondary) }
                if let link = share.link {
                    Text(link).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    if let url = URL(string: link) { ShareLink(item: url) { Text("Share…") } }
                    Button("Revoke Public Link", role: .destructive) { share.revoke() }
                        .disabled(share.isWorking)
                } else if share.isRevoked {
                    Text("Public link revoked.")
                } else {
                    Button(share.isWorking ? "Publishing…" : (share.isFrozen ? "Retry Publish" : "Publish Public Snapshot")) {
                        share.publish()
                    }.disabled(share.isPreparing || share.isWorking || !share.blocks.contains(where: \.selected))
                }
                Text("The snapshot is immutable after publishing. "
                     + "No draft input, directory label, images, or live connection is included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
