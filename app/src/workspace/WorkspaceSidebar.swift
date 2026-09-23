import AppKit
import SwiftUI

/// The sidebar's leading column: the traffic lights' row, a row to open a tab, and the tabs.
///
/// This is the only place tabs are listed. There is no strip above the panes — a second list of the
/// same tabs is a second answer to "which one is showing", and the first version of this drew every tab
/// twice because it had both.
///
/// It draws no background of its own. The sidebar *is* the window's background, and that is
/// `WorkspaceScreen`'s job; this is the column of content that sits in its leading edge.
///
/// It holds no state at all. The selection, the width, which tab is being renamed and what has been
/// typed are all `AppCore`'s, read and written through it. That is not purity for its own sake: a draft
/// kept here would be thrown away by the next re-render, which in a terminal is a shell printing its
/// title in the middle of your typing — and a view with no `@State` also stays inside the whole-app
/// typecheck, which is the only automated gate the view layer has.
struct WorkspaceSidebar: View {
    let workspace: AppCore

    var body: some View {
        VStack(spacing: 0) {
            header
            profileRow
            tabList
        }
    }

    /// The row the window's traffic lights sit in.
    ///
    /// The lights are AppKit's and their position is the window's business, so nothing is drawn on the
    /// leading side. The row exists so the tab list starts *below* them — the window has no titlebar
    /// band of its own, which is what puts them over the sidebar in the first place.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Theme.Size.trafficLightInset)
            Spacer(minLength: 0)
            SettingsButton(workspace: workspace)
        }
        .padding(.horizontal, Theme.Spacing.md)
        // Top-aligned with a small inset, so the gear sits level with the traffic lights rather than below
        // them. The row is tall enough that the tab list still starts clear of the titlebar.
        .padding(.top, Theme.Spacing.lg)
        .frame(height: Theme.Size.sidebarHeaderHeight, alignment: .top)
    }

    /// Whose window this is.
    ///
    /// A placeholder, and honestly so: there is no account and there will not be one until there is a
    /// network. It replaces the "New Tab" button that used to be here — ⌘T makes a tab, and the first row
    /// of a sidebar is where a person looks for whose window they are in.
    ///
    /// Outside the list rather than a row in it: a row that is not a tab would shift every index the
    /// drag-to-reorder arithmetic depends on, which is the kind of off-by-one that reads as a rendering
    /// glitch rather than as arithmetic.
    private var profileRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            avatar
            Text(Self.userName)
                .font(.system(size: Theme.Typography.profileNameSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Theme.Size.profileRowHeight, alignment: .leading)
    }

    /// The placeholder avatar: the name's first letter on a filled circle.
    ///
    /// Not `person.crop.circle`, which reads as a *missing* picture rather than as a picture — the thing it
    /// is standing in for. And not an asset, because there is nothing to put in one until there are
    /// accounts; a letter on a disc is what every app does in that situation and it is honest about being
    /// a placeholder.
    private var avatar: some View {
        Circle()
            .fill(Theme.Colors.ramp(dark: 0.3, light: 0.25))
            .frame(width: Theme.Size.profileAvatarSize, height: Theme.Size.profileAvatarSize)
            .overlay {
                Text(Self.userName.prefix(1).uppercased())
                    .font(
                        .system(
                            size: Theme.Size.profileAvatarSize * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
    }

    /// The name on the placeholder avatar. One place, so the day it comes from somewhere real there is one
    /// place to change.
    private static let userName = "ca5"

    /// A plain `List` with no selection binding, deliberately.
    ///
    /// `.sidebar` styling would draw the system's own selection bar across the row's full width, and
    /// what is wanted is a fill *inside* the row that says nothing about its edges. So the highlight is
    /// drawn by the row itself and the list is left to do the two things it does better than we would:
    /// the row metrics, and the drag-to-reorder.
    private var tabList: some View {
        List {
            ForEach(workspace.tabs.tabs, id: \.id) { tab in
                row(tab)
            }
            .onMove { source, destination in
                workspace.moveTabs(from: source, to: destination)
            }
        }
        .listStyle(.sidebar)
        // The sidebar's glass is behind this, over the whole window; the list's own material would be a
        // second one on top of it, and two materials in the same place is how a sidebar ends up looking
        // like a mistake.
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ tab: Tab) -> some View {
        if workspace.renaming == tab.id {
            TabRenameField(
                text: workspace.renameDraft,
                onEdit: { workspace.updateRenameDraft($0) },
                onCommit: { workspace.commitRename() },
                onCancel: { workspace.cancelRename() })
        } else {
            let selected = tab.id == workspace.tabs.activeTabID
            HStack(spacing: Theme.Spacing.md) {
                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Text(workspace.title(for: tab))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // The cross appears on hover rather than always, so a list of tabs reads as a list of names
                // until the pointer says which one it is about.
                if workspace.hoveredTab == tab.id {
                    Button {
                        workspace.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            // The fill goes on the content, not on the row: a highlight that reached the row's edges would be
            // drawing a boundary, and a tab's boundary is not a thing the selection has an opinion about.
            .background(
                selected ? Theme.Colors.selectionFill : Color.clear,
                in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
            // A plain tap rather than a `Button`, so the cross can be a `Button` of its own — a button inside
            // another button's label is the kind of thing that works until it does not. The double-click is a
            // simultaneous gesture for the same reason: a tap gesture added alongside would compete with the
            // single one and a click could be lost.
            .onTapGesture { workspace.selectTab(tab.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.beginRename(tab.id) })
            .onHover { inside in workspace.setTabHovered(tab.id, inside) }
            // The highlight *is* the row, so how wide it is is decided by the row's inset — and the list's
            // own inset has to be pulled back with a negative one to reach past it. The label then carries
            // the padding that keeps the text off the edge of the fill.
            .listRowInsets(
                EdgeInsets(
                    top: 0, leading: -Theme.Size.sidebarRowBleed, bottom: 0,
                    trailing: -Theme.Size.sidebarRowBleed))
            .contextMenu {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                    workspace.setPinned(!tab.isPinned, for: tab.id)
                }
                Button("Rename Tab") { workspace.beginRename(tab.id) }
                Divider()
                Button("Close Tab") { workspace.closeTab(tab.id) }
            }
        }
    }
}

/// The way into the settings, from the sidebar.
///
/// It opens the settings *tab* rather than a panel of its own — the same thing `⌘,` does. A popover here
/// would be a second place the settings live, and the point of putting them in a tab is that there is only
/// one.
struct SettingsButton: View {
    let workspace: AppCore

    var body: some View {
        Button {
            workspace.openSettings()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
    }
}
