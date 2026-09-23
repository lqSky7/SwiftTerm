import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The user's own page: their picture, their name, and the two things that change them.
///
/// **Centred, and nothing else.** The reference is the profile page in Tinycast, and the rule that comes from it is that
/// a page with one subject has one column — the picture on the centre line, the name under it, the account under that.
/// A page with a form on it would be the settings page, and there already is one.
///
/// The two things that *are* editable are editable the way the reference does it: **double-click them.** No pencil
/// button, no gear, no "Edit" in a corner — the picture and the name are the two things on the page, so they are the
/// two things you can double-click, and the gesture is the affordance.
struct ProfileView: View {
    let workspace: AppCore

    /// How big the picture is. Large enough to be the subject of the page rather than a decoration on it.
    private static let avatarDiameter: CGFloat = 200

    var body: some View {
        // **`SettingsPage`, the same chrome as every other page** — the top bar with the way back, the surface behind
        // it, and the same margins. A page with its own chrome would be a second place that knows what a page looks
        // like, and the two would drift the first time one of them changed.
        SettingsPage(title: "Profile", showsBackButton: true) {
            VStack(spacing: Theme.Spacing.xl) {
                avatar
                name
                account
            }
            // Centred in the column rather than in the window: the page's content is one column and this is the one
            // page whose subject is on its centre line.
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Theme.Spacing.xxl)
        }
        .background(Theme.Colors.settingsSurface)
    }

    // MARK: - The picture

    /// The picture, or the name's first letter on a disc.
    ///
    /// **Double-click it to change it.** A file picker rather than a drop target: everybody already knows how a picker
    /// works, and a drop zone on a page with one circle on it is a puzzle rather than an invitation.
    private var avatar: some View {
        ProfileAvatar(workspace: workspace, diameter: Self.avatarDiameter)
            .contentShape(Circle())
            .onTapGesture(count: 2) { choosePicture() }
            .help("Double-click to choose a picture")
            .accessibilityLabel("Profile picture")
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.setAvatarPath(url.path)
    }

    // MARK: - The name

    @ViewBuilder
    private var name: some View {
        if workspace.isRenamingProfile {
            TextField(
                "Name",
                text: Binding(
                    get: { workspace.profileNameDraft },
                    set: { workspace.setProfileNameDraft($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .onSubmit { workspace.commitProfileName() }
                // Escape abandons the edit rather than committing it, which is what Escape means in a field.
                .onExitCommand { workspace.cancelRenamingProfile() }
        } else {
            Text(workspace.chrome.userName)
                .font(.system(size: 30, weight: .bold))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { workspace.beginRenamingProfile() }
                .help("Double-click to rename")
        }
    }

    // MARK: - The account

    /// Who the terminal is actually running as.
    ///
    /// **Not editable, and deliberately.** The name above is what the user calls themselves; this is the machine's
    /// answer, and a page that let you type a different one would be a page that lied about which account your
    /// commands run under.
    private var account: some View {
        Text(accountName)
            .font(.system(size: 22))
            .foregroundStyle(.secondary)
    }

    private var accountName: String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }
}
