import AppKit
import SwiftUI

/// What a surface is made of, chosen by name.
///
/// Every option is the system's, and none of them is a backdrop we painted. But **only the glass ones are
/// window-level effects on their own**, and the difference decides whether this needs a second layer:
///
/// - `glassRegular` and `glassClear` are SwiftUI's glass, which samples what is behind the *window*.
/// - `ultraThin` is SwiftUI's `Material`, and a SwiftUI material blurs what is behind it **in the window**.
///
/// So on the **window's own backdrop** — which sits over a transparent window, with nothing behind it inside
/// the window but the desktop — `ultraThin` renders as a flat translucent tint unless it is stacked on a
/// behind-window blur. On a surface **inside** the window, that stacking is exactly what must not happen: the
/// window's own background is already there, and a second behind-window blur is the blur of a blur that made
/// zero opacity look wrong. One flag, and it is the difference between the two.
///
/// The mapping from a name to a material lives here and nowhere else, which is what lets
/// `ChromeMaterial` stay a plain enum in a file a harness compiles.
struct MaterialBackground: View {
    let material: ChromeMaterial
    /// Whether this is the window's own backdrop, which is the only surface with nothing behind it inside
    /// the window.
    var isWindowBackdrop = false

    var body: some View {
        switch material {
        case .ultraThin, .thin:
            // The two `Material` cases, and the one place this flag matters: over a transparent window with
            // nothing behind it inside the window, a `Material` alone is a flat tint, so the window's own
            // backdrop stacks it on a behind-window blur. A surface inside the window must not — the window's
            // background is already there, and a second blur is the blur of a blur.
            if isWindowBackdrop {
                behindWindow(.underWindowBackground) { Rectangle().fill(.clear).background(swiftUIMaterial) }
            } else {
                Rectangle().fill(.clear).background(swiftUIMaterial)
            }
        case .glassRegular:
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 0))
        case .glassClear:
            Rectangle().fill(.clear).glassEffect(.clear, in: .rect(cornerRadius: 0))
        }
    }

    /// The SwiftUI `Material` this name stands for. Only the two `Material` cases reach it.
    private var swiftUIMaterial: Material {
        switch material {
        case .thin: .thin
        default: .ultraThin
        }
    }

    /// A behind-window blur with something over it, for the material that cannot blur the desktop
    /// itself. The blur is the window-level part; what sits on it is the weight the name promises.
    private func behindWindow<Content: View>(
        _ blur: NSVisualEffectView.Material, @ViewBuilder over content: () -> Content
    ) -> some View {
        ZStack {
            VisualEffectView(material: blur, blendingMode: .behindWindow)
            content()
        }
    }
}

// MARK: - The frame every settings page is drawn in

/// A settings page: a bar naming it, and a centred column of groups under the bar.
///
/// **The bar is ours, and it is not the window's toolbar.** The system's navigation bar would put the title
/// and the back button in the window's toolbar, and the window's toolbar is the window's *leading edge* —
/// over the sidebar, which is not where the settings are. So the stack navigates and both the title and the
/// way back are placed inside the page they belong to.
///
/// The column is a **ceiling rather than a width** (`maxWidth`): a window dragged narrow shrinks the page
/// instead of cutting the right-hand side off it, which is what a fixed width did.
/// Not `private`: the profile page is built from the same chrome — the top bar with the way back, the surface, the
/// margins — and a second implementation of that would be a second place that knows what a page looks like.
struct SettingsPage<Content: View>: View {
    let title: String
    /// The root page has nothing behind it, so it has no way back — a chevron that does nothing is worse
    /// than no chevron.
    let showsBackButton: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar(title: title, showsBackButton: showsBackButton)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    content()
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.xxl)
                .frame(maxWidth: Theme.Size.settingsContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

/// The bar at the top of a settings page: the name of the page, centred, and the way back on the leading side.
///
/// The title is **centred rather than led**, and that is the point of it: it says which page you are inside.
/// A title in the corner is a caption on the content below it rather than the name of the page.
private struct SettingsTopBar: View {
    let title: String
    let showsBackButton: Bool

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Colors.titlebarInk)

            HStack(spacing: 0) {
                // The room the floating sidebar button takes at the panel's top-leading corner. A back button
                // beside it would be two controls in the same place, so the bar steps past it — one token,
                // shared with the button itself, rather than two numbers that have to agree.
                Color.clear
                    .frame(width: Theme.Size.paneToggleFootprint, height: 0)
                if showsBackButton { SettingsBackButton() }
                Spacer(minLength: 0)
            }
        }
        .frame(height: Theme.Size.settingsTopBarHeight)
        .padding(.horizontal, Theme.Spacing.xxl)
    }
}

/// The way back, placed inside the page rather than left to the window's toolbar.
///
/// `@Environment(\.dismiss)` is a property wrapper rather than a macro, so unlike `@State` it costs nothing
/// to the whole-app typecheck — and it is not state this view owns, which is the rule the rest of the chrome
/// follows.
struct SettingsBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Material.ultraThin, in: .circle)
        .help("Back to settings")
    }
}

// MARK: - Groups and rows

/// A labelled group of rows on one thin-material card.
///
/// The card is what the reference does and what the earlier version did not: rows that share a subject share
/// a surface, so a page reads as a handful of decisions rather than as a list of unrelated switches. The
/// label names the group and the rows do not repeat it — "Material" under "Window", not "Window material".
///
/// A **thin material** rather than a hand-mixed alpha: a surface the system draws adapts to the appearance
/// and to what is behind it, which a literal `Color` cannot.
private struct SettingsGroup<Content: View>: View {
    var label: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Spacing.lg)
            }
            VStack(spacing: 0) { content() }
                .background(Material.ultraThin, in: .rect(cornerRadius: Theme.Radius.panel))
        }
    }
}

/// The hairline between two rows of one card.
///
/// Inset on the leading side so it starts where the labels do. A rule that ran the card's full width would
/// cut it into separate boxes, which is the opposite of what a card is for.
private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.ramp(dark: 0.08, light: 0.06))
            .frame(height: 1)
            .padding(.leading, Theme.Spacing.lg)
    }
}

/// One row: what it is on the left, the control that sets it on the right.
///
/// A subtitle only when the title is ambiguous — "Terminal" needs "Over the sidebar's.", "Material" under a
/// "Window" label needs nothing. A control that needs a sentence to explain itself is a control that is
/// wrong.
///
/// This is the card's equivalent of `LabeledContent`, and it is a hand-rolled row rather than that view
/// because `LabeledContent` wraps its trailing value in a selectable text field that eats clicks — the note
/// `docs/settings.md` §3 already carries about it.
private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(.system(size: 14))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            control()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(minHeight: Theme.Size.settingsRowMinHeight)
    }
}

// MARK: - The settings root

/// The settings, as a centred column of categories with a search field over it.
///
/// The root is a list of *categories*, each of which is a page pushed onto the stack — so the thing you are
/// changing is named in the bar at the top of the page you are on, rather than being a row you have to
/// remember you clicked.
struct SettingsView: View {
    let workspace: AppCore

    var body: some View {
        NavigationStack {
            SettingsPage(title: "Settings", showsBackButton: false) {
                searchField

                SettingsGroup {
                    ForEach(Array(matching.enumerated()), id: \.element.id) { index, category in
                        if index > 0 { SettingsRowDivider() }
                        NavigationLink {
                            destination(for: category)
                        } label: {
                            SettingsCategoryRow(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if matching.isEmpty {
                    Text("Nothing matches \(workspace.settingsSearch).")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.Colors.settingsSurface)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            TextField("Search settings", text: search)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Theme.Size.settingsSearchHeight)
        // The system's own ultra-thin material rather than a tint of ours: it is a *surface*, and a surface
        // the system draws adapts to the appearance and to what is behind it, which a hand-mixed alpha does
        // not.
        .background(Material.ultraThin, in: .rect(cornerRadius: Theme.Radius.panel))
    }

    private var search: Binding<String> {
        Binding(
            get: { workspace.settingsSearch },
            set: { workspace.setSettingsSearch($0) })
    }

    /// The categories the query matches, by name or by what they are for — a search that only looked at
    /// names would miss the one that says "opacity".
    private var matching: [SettingsCategory] {
        let query = workspace.settingsSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SettingsCategory.allCases }
        return SettingsCategory.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func destination(for category: SettingsCategory) -> some View {
        switch category {
        case .appearance: AppearanceSettingsView(workspace: workspace)
        case .sidebar: SidebarSettingsView(workspace: workspace)
        }
    }
}

/// One thing a person can go and change.
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case sidebar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .sidebar: "Sidebar"
        }
    }

    /// Every row carries one. A list of names is a menu; a list of names with a symbol and a sentence is a
    /// page somebody can read without clicking anything.
    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .sidebar: "sidebar.left"
        }
    }

    var description: String {
        switch self {
        case .appearance:
            "What the window is made of, and how opaque each of its surfaces is."
        case .sidebar:
            "Whether the sidebar shows, and how it is sized and hidden."
        }
    }
}

/// One row of the settings root: a symbol, a name and a sentence.
private struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: category.icon)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: Theme.Size.settingsIconTile, height: Theme.Size.settingsIconTile)
                .background(
                    Theme.Colors.ramp(dark: 0.08, light: 0.05),
                    in: .rect(cornerRadius: Theme.Radius.control))

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(category.title)
                    .font(.system(size: 14, weight: .medium))
                Text(category.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.lg)

            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Appearance

/// What the window is made of, what each of its two surfaces is made of, and how opaque each one is.
///
/// **A group per surface, not one group of two sliders.** The sidebar and the terminal are separate
/// decisions with separate jobs — the sidebar is chrome and can be as glassy as anyone likes, the terminal
/// has text on it and a material under text is a legibility decision — so they get a material each and an
/// opacity each, and the group label is what says which row belongs to which. That is also why the rows are
/// just "Material" and "Opacity": the group already named the surface, and a row that repeats it is a row
/// that says the same thing twice.
///
/// Three groups and no paragraphs. The reference for this is the settings UI in Tinycast
/// (`~/Desktop/tinycast`), and the rule that comes from it is in `docs/settings.md` §3: a row is a title and a
/// control, a subtitle only when the title is ambiguous, and rows that share a subject share a surface.
struct AppearanceSettingsView: View {
    let workspace: AppCore

    var body: some View {
        SettingsPage(title: "Appearance", showsBackButton: true) {
            SettingsGroup(label: "Window") {
                SettingsRow(title: "Appearance") {
                    appearancePicker
                }
            }

            // Typography first among the surfaces, because it is the one people actually change: the size and
            // the line height are how the terminal reads, and everything below is how it looks.
            SettingsGroup(label: "Text") {
                SettingsRow(title: "Size") { fontSizeStepper }
                SettingsRowDivider()
                SettingsRow(title: "Line height") { lineHeightStepper }
            }

            SettingsGroup(label: "Sidebar") {
                SettingsRow(title: "Material") { materialPicker(sidebarMaterial) }
                SettingsRowDivider()
                SettingsSliderRow(
                    title: "Opacity",
                    value: sidebarOpacity,
                    defaultValue: workspace.chrome.sidebarMaterial.defaultOpacity,
                    set: { workspace.setSidebarOpacity($0) })
            }

            SettingsGroup(label: "Terminal") {
                SettingsRow(title: "Material") { materialPicker(terminalMaterial) }
                SettingsRowDivider()
                SettingsSliderRow(
                    title: "Opacity",
                    value: terminalOpacity,
                    defaultValue: workspace.chrome.terminalMaterial.defaultOpacity,
                    set: { workspace.setTerminalOpacity($0) })
            }
        }
    }

    /// A **dropdown**, not a radio group: choices that are mutually exclusive and take one line each.
    ///
    /// A radio group stacks them, and stacked they were the tallest thing on the page — for a setting whose
    /// value is one word. A menu shows the word and offers the rest, which is what the reference does.
    private func materialPicker(_ selection: Binding<ChromeMaterial>) -> some View {
        Picker("Material", selection: selection) {
            ForEach(ChromeMaterial.allCases, id: \.self) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// System, light or dark. `System` is the default and is not the same as "light": it is the *absence* of
    /// an opinion, so the window keeps following the machine after the choice is made.
    private var appearancePicker: some View {
        Picker("Appearance", selection: appearanceMode) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// A **stepper**, not a slider, unlike the opacities. A point size is a whole number somebody wants exactly —
    /// 13, not 12.8 — and a slider makes 13 something you hunt for.
    private var fontSizeStepper: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("\(Int(fontSize.wrappedValue)) pt")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Stepper(
                "Size", value: fontSize, in: ChromeSettings.fontSizeRange,
                step: Double(Theme.Typography.pointSizeStep)
            )
            .labelsHidden()
            .controlSize(.small)
        }
    }

    /// Warp's `line_height_ratio`. Shown as a multiple because that is what it is — the same 1.4 is a different
    /// number of points at 11pt and at 18pt, and a row that said "18.2 pt" would be wrong the moment the size
    /// changed.
    private var lineHeightStepper: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(String(format: "%.2f×", lineHeight.wrappedValue))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Stepper(
                "Line height", value: lineHeight, in: ChromeSettings.lineHeightRatioRange,
                step: Double(Theme.Typography.lineHeightRatioStep)
            )
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { workspace.chrome.fontSize },
            set: { workspace.setFontSize($0) })
    }

    private var lineHeight: Binding<Double> {
        Binding(
            get: { workspace.chrome.lineHeightRatio },
            set: { workspace.setLineHeightRatio($0) })
    }

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { workspace.chrome.appearanceMode },
            set: { workspace.setAppearanceMode($0) })
    }

    private var sidebarMaterial: Binding<ChromeMaterial> {
        Binding(
            get: { workspace.chrome.sidebarMaterial },
            set: { workspace.setSidebarMaterial($0) })
    }

    private var terminalMaterial: Binding<ChromeMaterial> {
        Binding(
            get: { workspace.chrome.terminalMaterial },
            set: { workspace.setTerminalMaterial($0) })
    }

    private var sidebarOpacity: Binding<Double> {
        Binding(
            get: { workspace.chrome.sidebarOpacity },
            set: { workspace.setSidebarOpacity($0) })
    }

    private var terminalOpacity: Binding<Double> {
        Binding(
            get: { workspace.chrome.terminalOpacity },
            set: { workspace.setTerminalOpacity($0) })
    }
}

/// A percentage row: a title, a small slider between "Less" and "More", and the way back to the default.
///
/// **The slider is not the row's width**, and that is the whole of this view. A slider stretched across the
/// window is one whose value is hard to nudge and whose two ends are a long way from each other; the thing it
/// sets is a percentage, not a position on a track. "Less" and "More" say which end is which, because an
/// opacity slider has no left or right that means anything on its own.
///
/// The `Reset` is not decoration. A slider whose neutral value is somewhere in the middle is a slider nobody
/// can put back, and the opacity a material wants is not a number anybody remembers.
private struct SettingsSliderRow: View {
    let title: String
    var subtitle: String?
    let value: Binding<Double>
    let defaultValue: Double
    let set: (Double) -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Less")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: value, in: ChromeSettings.opacityRange)
                    .controlSize(.small)
                    .frame(maxWidth: Theme.Size.settingsSliderWidth)
                Text("More")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button("Reset") { set(defaultValue) }
                    .controlSize(.small)
                    .disabled(abs(value.wrappedValue - defaultValue) < 0.001)
            }
        }
    }
}

// MARK: - Sidebar

/// The sidebar's own page: whether it shows, and the two ways to work it that are not controls.
struct SidebarSettingsView: View {
    let workspace: AppCore

    var body: some View {
        SettingsPage(title: "Sidebar", showsBackButton: true) {
            SettingsGroup {
                SettingsRow(title: "Show the sidebar") {
                    Toggle("Show the sidebar", isOn: isVisible)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsGroup(label: "Shortcuts") {
                // Values nobody types, so they read as plain ink on the trailing side — and they are text
                // rather than a control on purpose, because there is nothing here to click.
                SettingsRow(title: "Hide or show") {
                    Text("⌘⇧B")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                SettingsRowDivider()
                SettingsRow(title: "Resize") {
                    Text("Drag its right edge")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isVisible: Binding<Bool> {
        Binding(
            get: { !workspace.layout.isSidebarCollapsed },
            set: { _ in workspace.toggleSidebar() })
    }
}
