import AppKit
import SwiftUI

/// The window's content.
///
/// **The sidebar is the window.** It is a full-bleed glass background with the tab list in its leading
/// column, and the terminal is a rounded panel floating *on* it — which is what the margin around the
/// panel and its rounded corners are for. That is the opposite of the first version of this, which had
/// a column beside the terminal; the column and the panel were two halves of a split, and a split is
/// not what this is.
///
/// There is no top bar. The window has no titlebar band of its own — `.fullSizeContentView` with the
/// title hidden — so the traffic lights float over the sidebar, and the control that shows and hides it
/// floats on the terminal instead.
///
/// It holds no state. Everything it draws comes from `AppCore` and from `PaneLayout`, and every gesture
/// calls a command — which is deliberate, because the four view-layer defects this project has had were
/// all a view keeping its own copy of something the model already knew.
struct WorkspaceScreen: View {
    let workspace: AppCore

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The window's material, and then the window's own background colour drawn over it.
            //
            // **One background layer, not two.** There used to be a `VisualEffectView(.underWindowBackground)`
            // here as well, with the material drawn on top of it — which meant that at zero opacity the
            // window showed a blur of a blur: flat, milky, and nothing like vicinae, whose window material
            // is a single compositor blur behind a transparent window
            // (`src/server/src/services/window-material/ext-background-effect-v1-manager.cpp`). The
            // material *is* the window's background; there is nothing for it to sit on.
            //
            // The order below is the whole point, and it is vicinae's arrangement too: the material is
            // always drawn, and the opacity is how much of the window's background colour covers it. At 1
            // the material is invisible, at 0 only the material is left. So "lower the window opacity to
            // see the material" — and so the picker does something at every opacity rather than only above
            // zero, which is what it did when the opacity was multiplied into the material itself.
            MaterialBackground(material: workspace.chrome.sidebarMaterial, isWindowBackdrop: true)
                .allowsHitTesting(false)
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .opacity(workspace.chrome.sidebarOpacity)
                .allowsHitTesting(false)

            sidebarColumn
            contentPanel
        }
        .ignoresSafeArea()
        // One animation for both, scoped to the one value that decides them. Animating them separately
        // would let the sidebar and the panel disagree about where the edge between them is for the
        // length of the animation.
        //
        // The cost, stated because it is real: the panel's width animates, and the panel *is* the
        // terminal, so the pty is told a new size on each frame of the slide and the shell redraws its
        // prompt each time. If that reads as a flicker, the fix is to move this modifier onto
        // `sidebarColumn` alone — the sidebar slides, the panel snaps, and the jump is hidden by the
        // sidebar arriving over exactly the region the panel gives up.
        .animation(
            .easeInOut(duration: Theme.Motion.chromeFade), value: workspace.layout.isSidebarCollapsed)
    }

    /// The leading column: the tab list, and the strip you drag to resize it.
    ///
    /// Always present, even when hidden — at a width of zero rather than absent — because a view that
    /// is removed cannot slide. The inner frame gives the content its own width and the outer one is the
    /// window onto it, so collapsing reveals and hides the column rather than squeezing it.
    private var sidebarColumn: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(workspace: workspace)
                .frame(width: workspace.layout.sidebarWidth, alignment: .leading)
                .frame(width: workspace.layout.occupiedWidth, alignment: .leading)
                .clipped()
                // An overlay, not a sibling: a handle with a width of its own would come out of the
                // panel's area, and then the width the shell is told and the width it is drawn at would
                // differ by six points.
                .overlay(alignment: .trailing) { SidebarResizeHandle(workspace: workspace) }
                .allowsHitTesting(!workspace.layout.isSidebarCollapsed)
            Spacer(minLength: 0)
        }
    }

    /// The terminal, as a panel floating on the sidebar.
    ///
    /// Its frame is `ChromeSettings`' arithmetic — the same function `AppCore` uses to decide what size
    /// to tell the shell — so the panel's geometry exists once rather than twice.
    private var contentPanel: some View {
        GeometryReader { proxy in
            let frame = workspace.layout.contentPanelFrame(in: proxy.size)
            let bounds = CGRect(origin: .zero, size: frame.size)

            panelContent(in: bounds)
                // The terminal's *own* material, and a setting of its own — separate from the sidebar's
                // because a material under text is a legibility decision rather than a taste one. It sits
                // under the terminal's background fill, which the renderer paints at `terminalOpacity` from
                // the palette: material first, then the surface's own colour over it, which is the same
                // arrangement the sidebar uses and the reason the two controls compose instead of fighting.
                //
                // Not a window backdrop, so `MaterialBackground` deliberately does **not** stack a
                // behind-window blur on it — the window's own background is already behind this.
                .background(
                    MaterialBackground(material: workspace.chrome.terminalMaterial)
                        .allowsHitTesting(false))
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                // Rounded on the leading side only. Those are the corners that meet the sidebar, and the
                // curve into it is the whole of the effect; the other two sit at the window's own edges,
                // which are already square.
                //
                // **No fill here, and that is deliberate.** There used to be a
                // `windowBackgroundColor` at `terminalOpacity` inside this clip — which is the second
                // opacity control, and the reason it appeared to do nothing: the terminal paints its own
                // background from the palette in `TerminalRenderer`, over this, so the panel's fill was
                // covered completely. The terminal's opacity is the renderer's fill and nothing else, and
                // `AppCore` pushes the setting into it. The two fills still stack in the order the
                // documentation describes — the window's colour at `sidebarOpacity` under the terminal's
                // own — they are just not both drawn here.
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: Theme.Radius.panel,
                        bottomLeadingRadius: Theme.Radius.panel,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0))
                .overlay(alignment: .topLeading) { dividerHandles(in: bounds) }
                .overlay(alignment: .topLeading) { sidebarToggle }
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// The one control for the sidebar, floating on the terminal.
    ///
    /// It sits at the panel's top-leading corner, over the terminal's first row — which is the one cost
    /// of a control that reserves no space, and the alternative is a bar above the terminal, which is
    /// the thing this design exists to not have. Glass, so it reads as floating rather than as a
    /// control that was placed there.
    private var sidebarToggle: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        // In line with the window's traffic lights rather than below them. They sit in the titlebar, whose
        // controls are centred about 14 points down, so a 28-point button wants its top about 10 down.
        .padding(.top, Theme.Spacing.lg)
        // With the sidebar showing, the panel already starts to the right of the traffic lights, so this is
        // only a margin. With the sidebar hidden the panel starts at the window's edge *and the lights are
        // hidden with it*, so the button takes the corner they were in and this is still only a margin. One
        // inset, because there is nothing left to step over.
        .padding(.leading, Theme.Spacing.md)
        .padding([.bottom, .trailing], Theme.Spacing.md)
        .help(workspace.layout.isSidebarCollapsed ? "Show the sidebar" : "Hide the sidebar")
    }

    /// What the panel holds: the settings page, or the panes of the tab that is showing.
    ///
    /// A tab that is not showing has no panes here at all: its shells keep running, but its surfaces are
    /// out of the view hierarchy. That is what makes switching tabs cheap, and it is what lets a pane take
    /// the keyboard for itself when it comes back — a surface that is already in a window has nothing to
    /// claim it again.
    @ViewBuilder
    private func panelContent(in bounds: CGRect) -> some View {
        // The profile is the panel's state rather than a tab — see `AppCore.isShowingProfile` — so it is asked for
        // first, before whatever tab happens to be selected behind it.
        if workspace.isShowingProfile {
            ProfileView(workspace: workspace)
        } else if let tab = workspace.tabs.activeTab {
            switch tab.content {
            case .settings:
                SettingsView(workspace: workspace)
            case .terminals(let tree):
                panes(of: tree, in: bounds)
            }
        } else {
            // Every tab is gone and the window is closing. This is the frame in between.
            Color.clear
        }
    }

    /// The strips you grab to drag a divider.
    ///
    /// Drawn from the layout's own `dividers`, so the thing you grab and the thing that moves are the same
    /// boundary by construction — and each strip is wider than the one-point gap it sits on, because the gap
    /// is what is drawn and this is what is hit.
    @ViewBuilder
    private func dividerHandles(in bounds: CGRect) -> some View {
        if let tab = workspace.tabs.activeTab, let tree = tab.panes {
            let layout = PaneLayout(tree: tree, in: bounds, gap: Theme.Size.paneGap)
            ZStack(alignment: .topLeading) {
                ForEach(layout.dividers.indices, id: \.self) { index in
                    let divider = layout.dividers[index]
                    let horizontal = divider.axis == .horizontal
                    let hit = Theme.Size.paneDividerHit
                    DividerHandle(workspace: workspace, divider: divider)
                        .frame(
                            width: horizontal ? hit : divider.frame.width,
                            height: horizontal ? divider.frame.height : hit)
                        .position(
                            x: divider.frame.midX,
                            y: divider.frame.midY)
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        }
    }

    private func panes(of tree: PaneTree, in bounds: CGRect) -> some View {
        let layout = PaneLayout(tree: tree, in: bounds, gap: Theme.Size.paneGap)
        return ZStack(alignment: .topLeading) {
            ForEach(layout.entries, id: \.pane) { entry in
                if let coordinator = workspace.coordinator(for: entry.pane) {
                    TerminalPane(coordinator: coordinator)
                        .frame(width: entry.frame.width, height: entry.frame.height)
                        .position(x: entry.frame.midX, y: entry.frame.midY)
                        // Identity is the pane, so a split adds a surface rather than repainting the one
                        // that was already there.
                        .id(entry.pane)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }
}

/// The strip you drag to move a divider.
///
/// It holds no state. Where the drag started is `AppCore`'s, because a gesture reports where the pointer is
/// rather than how far it moved, and turning one into the other is arithmetic the model can do once.
private struct DividerHandle: View {
    let workspace: AppCore
    let divider: PaneLayout.Divider

    var body: some View {
        ZStack {
            // Invisible wider hit target so dragging is reliable
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())

            // Visible crisp hairline separator between panes
            if divider.axis == .horizontal {
                Rectangle()
                    .fill(Theme.Colors.ramp(dark: 0.35, light: 0.22))
                    .frame(width: 1)
            } else {
                Rectangle()
                    .fill(Theme.Colors.ramp(dark: 0.35, light: 0.22))
                    .frame(height: 1)
            }
        }
        .onHover { inside in
            if inside {
                if divider.axis == .horizontal {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.resizeUpDown.push()
                }
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if value.translation == .zero { workspace.beginDividerDrag() }
                    let moved =
                        divider.axis == .horizontal
                        ? value.translation.width : value.translation.height
                    workspace.dragDivider(divider, by: moved)
                }
                .onEnded { _ in workspace.endDividerDrag() }
        )
    }
}

/// The strip you drag to widen or narrow the sidebar.
///
/// It holds no state. Where the drag started is `AppCore`'s, alongside the width itself — a width the
/// view remembered would be a second answer to how wide the sidebar is, and the panel's geometry is
/// derived from that number.
private struct SidebarResizeHandle: View {
    let workspace: AppCore

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Theme.Size.sidebarResizeHandle)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if value.translation == .zero { workspace.beginSidebarDrag() }
                        workspace.dragSidebar(by: value.translation.width)
                    }
                    .onEnded { _ in workspace.endSidebarDrag() }
            )
    }
}
