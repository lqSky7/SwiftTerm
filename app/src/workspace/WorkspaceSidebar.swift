import AppKit
import SwiftUI

/// The sidebar's leading column: the traffic lights' row, whose window this is, and the tabs.
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
        HStack(spacing: Theme.Spacing.md) {
            Spacer(minLength: Theme.Size.trafficLightInset)
            Spacer(minLength: 0)
            NewTabButton(workspace: workspace)
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
            Text(workspace.chrome.userName)
                .font(.system(size: Theme.Typography.profileNameSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Theme.Size.profileRowHeight, alignment: .leading)
        // **The row is the page's only affordance, so it says so when the page is up.** There is no tab for the
        // profile to highlight, which is exactly why the row has to do it.
        //
        // The same highlight a selected tab gets, because it means the same thing — this is the row you are
        // in. A different treatment here would be a second answer to that question. Its corner is the larger
        // one because the row is twice a tab's height, and the highlight's corners are a *ratio* of its
        // height in the reference rather than a fixed radius; `Radius.panel` is that ratio at this size.
        .background {
            if workspace.isShowingProfile {
                SidebarRowHighlight(cornerRadius: Theme.Radius.panel)
            }
        }
        // Inset last, so the inset is outside the highlight rather than inside it: this is the number that
        // decides how close to the sidebar's edges the highlight runs, and a selected tab gets the same one.
        .padding(.horizontal, Theme.Size.sidebarRowInset)
        // The whole row, not just the name: a row that is only tappable where its text happens to be is a row people
        // click and nothing happens.
        .contentShape(Rectangle())
        .onTapGesture { workspace.openProfile() }
    }

    /// The placeholder avatar: the name's first letter on a filled circle.
    ///
    /// Not `person.crop.circle`, which reads as a *missing* picture rather than as a picture — the thing it
    /// is standing in for. And not an asset, because there is nothing to put in one until there are
    /// accounts; a letter on a disc is what every app does in that situation and it is honest about being
    /// a placeholder.
    /// The same avatar the profile page draws, at the row's size — one view, so the sidebar cannot show a letter
    /// while the page shows the picture the user chose.
    private var avatar: some View {
        ProfileAvatar(workspace: workspace, diameter: Theme.Size.profileAvatarSize)
    }

    /// A plain `List` with no selection binding, deliberately.
    ///
    /// `.sidebar` styling would draw the system's own selection bar across the row's full width, and what is
    /// wanted is the highlight `SidebarRowHighlight` draws — a fill with two lit edges and open sides. So the
    /// highlight is drawn by the row itself and the list is left to do the two things it does better than we
    /// would: the row metrics, and the drag-to-reorder.
    ///
    /// **The rows are inset almost to the list's edges** — see `rowInsets` — because that is what makes the
    /// highlight read as the row rather than as a chip inside it.
    private var tabList: some View {
        List {
            ForEach(workspace.tabs.tabs, id: \.id) { tab in
                row(tab)
            }
            .onMove { source, destination in
                workspace.moveTabs(from: source, to: destination)
            }
        }
        .listStyle(.plain)
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
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.sidebarRowHeight)
                .padding(.horizontal, Theme.Size.sidebarRowInset)
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            let selected = tab.id == workspace.tabs.activeTabID
            HStack(spacing: Theme.Spacing.md) {
                // The identity mark, at the leading edge of every row and before the pin — it is what the
                // row *is*, and the pin is a badge on it. The reference puts a mark in this place on every
                // row, and this is the app's own.
                IdentityMarkView(
                    width: Theme.Size.identityMarkWidth,
                    color: Theme.Colors.identityMark)
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
            .frame(height: Theme.Size.sidebarRowHeight)
            .background { if selected { SidebarRowHighlight() } }
            // Outside the background, so it moves the highlight rather than the row's contents: this is the
            // half of the inset that is the design's, and `rowInsets` takes back the half that is the list's.
            .padding(.horizontal, Theme.Size.sidebarRowInset)
            .contentShape(Rectangle())
            // A plain tap rather than a `Button`, so the cross can be a `Button` of its own — a button inside
            // another button's label is the kind of thing that works until it does not. The double-click is a
            // simultaneous gesture for the same reason: a tap gesture added alongside would compete with the
            // single one and a click could be lost.
            .onTapGesture { workspace.selectTab(tab.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.beginRename(tab.id) })
            .onHover { inside in workspace.setTabHovered(tab.id, inside) }
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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

    /// What every row is inset by.
    ///
    /// **The leading and trailing numbers are negative, and that is the whole of how the highlight
    /// reaches the sidebar's edges.** A `List` keeps its rows clear of its own edges and `.listRowInsets`
    /// can only add to that, so reaching past it takes a negative inset —
    /// `Theme.Size.sidebarRowBleed`, which is that inset, measured. The row then pads itself back in by
    /// `Theme.Size.sidebarRowInset`, so the highlight's width is decided by one number here and one
    /// there, and the profile row above uses the same pair. A selected tab and a selected profile have
    /// to land on the same edges or the sidebar looks like it was assembled from two designs.
    ///
    /// The vertical pair is the gap between two highlights. Smaller than the horizontal one on purpose:
    /// rows are read as a stack, and a stack with wide gutters between its rows is a list of chips.
    private static let rowInsets = EdgeInsets(
        top: 2,
        leading: -Theme.Size.sidebarRowBleed,
        bottom: 2,
        trailing: -Theme.Size.sidebarRowBleed)
}

/// The lit row: the fill, and the two hairlines that are the whole of the highlight.
///
/// **The hairline is on the top and bottom edges and nowhere else**, and along each of those it is lit at
/// one end and gone at the other — the top edge at its leading end, the bottom edge at its trailing one.
/// That is the reference the sidebar is drawn from, and it is a *diagonal*: light arriving from one side
/// and catching the two corners that face it. Lit evenly along both edges the same hairline reads as a
/// border, which makes a selected row look like a button you could press; run down the vertical sides as
/// well and the row reads as a box. Two lit corners and open sides is the whole of the effect.
///
/// Two `Rectangle`s rather than a masked `strokeBorder`, and that is the correction: a mask on a stroke
/// cannot tell the top edge from the left one, so the only way to keep the light off the vertical sides
/// is to not draw a stroke there in the first place. The rectangles run the full width and are cut to the
/// shape at the end, so their ends land on the corner arcs rather than short of them.
private struct SidebarRowHighlight: View {
    /// The tab row's radius. The profile row passes its own, because the reference's corners are a ratio
    /// of the highlight's height rather than a fixed radius, and that row is taller.
    var cornerRadius: CGFloat = Theme.Radius.sidebarRow

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.Colors.selectionFill)
            hairline(Self.leadingGlow)
                .frame(maxHeight: .infinity, alignment: .top)
            hairline(Self.trailingGlow)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func hairline(_ fade: LinearGradient) -> some View {
        Rectangle()
            .fill(Theme.Colors.selectionEdge)
            .frame(height: Theme.Size.sidebarRowHairline)
            .mask(fade)
    }

    /// The top edge: bright at the leading end, settling to the faint line, gone by the trailing end.
    private static var leadingGlow: LinearGradient {
        glow(brightAtLeading: true)
    }

    /// The bottom edge: the same, mirrored.
    private static var trailingGlow: LinearGradient {
        glow(brightAtLeading: false)
    }

    /// One expression of the two, so the bright end and the faint one cannot disagree about where the
    /// floor starts or how dark it is.
    private static func glow(brightAtLeading: Bool) -> LinearGradient {
        let span = Theme.Size.sidebarRowGlowSpan
        let floor = Color.black.opacity(Theme.Size.sidebarRowGlowFloor)
        let bright: Color = .black
        let dim: Color = .clear
        return LinearGradient(
            stops: [
                .init(color: brightAtLeading ? bright : dim, location: 0),
                .init(color: floor, location: span),
                .init(color: floor, location: 1 - span),
                .init(color: brightAtLeading ? dim : bright, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Settings (⌘,)")
    }
}

/// Creates a new terminal tab from the sidebar.
struct NewTabButton: View {
    let workspace: AppCore

    var body: some View {
        Button {
            workspace.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("New Tab (⌘T)")
    }
}

