import Foundation

/// Which appearance the window is drawn in.
///
/// A *name*, not an `NSAppearance`: this file is `Foundation`-only so a harness can hold it, and the view
/// layer is the only place that knows what a name means — the same split `ChromeMaterial` uses.
enum AppearanceMode: String, CaseIterable, Equatable, Codable {
    /// Whatever the system is set to. The default, because it is what most people want and the only one that
    /// keeps following the system after they change it.
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Whether the terminal should use its light palette, or `nil` when that depends on the machine.
    ///
    /// Spelled as a question rather than answered with a default: guessing here is how a light terminal ends
    /// up drawn in dark mode, and the view is the only thing that can ask `NSApp` what the system is doing.
    var isLight: Bool? {
        switch self {
        case .system: nil
        case .light: true
        case .dark: false
        }
    }
}

/// What the sidebar's background is made of.
///
/// Pure, so it is an enum of *names* rather than of materials: the model says which one, and the view
/// is the only place that knows what a name means. That is what lets a harness check the list and the
/// default without a UI framework in the room.
///
/// Every case is something the system draws. There is no case here that means "paint it ourselves",
/// which is the point of the whole list.
enum ChromeMaterial: String, CaseIterable, Equatable, Codable {
    /// SwiftUI's lightest `Material`, on the behind-window blur it needs to be a material at all.
    case ultraThin
    /// One weight up from `ultraThin`, and the reason both are offered: at a glance on a dark desktop the
    /// two read as "barely there" and "a surface", which is a choice worth being able to make.
    case thin
    /// `NSGlassEffectView`'s regular style, in SwiftUI: `glassEffect(.regular)`.
    case glassRegular
    /// `NSGlassEffectView`'s clear style, in SwiftUI: `glassEffect(.clear)`.
    case glassClear

    /// What a picker calls it.
    ///
    /// Four, and the pair at the top is deliberate. `thin` was removed once, on the grounds that it and
    /// `ultraThin` are the same kind of surface differing by a weight nobody was choosing between — which is
    /// true of a *window* material, where both sit over the same desktop. It stopped being true once the
    /// terminal got a material of its own: over text, the weight is the whole question, and the difference
    /// between the two is legibility rather than taste. `titlebar` is still gone, and stays gone — it was kept
    /// only for having been on screen before the titlebar was removed, which is not a reason to offer it.
    var displayName: String {
        switch self {
        case .ultraThin: "Ultra thin"
        case .thin: "Thin"
        case .glassRegular: "Glass"
        case .glassClear: "Clear glass"
        }
    }

    /// The window opacity this material wants.
    ///
    /// The glass numbers are vicinae's: its `TRANSLUCENT_OPACITY` is 0.6 for the glass material and its
    /// `BLUR_OPACITY` is 0.55 for the blur one. A material that arrives at an opacity which hides it is a
    /// material nobody can see they picked, which is why picking one sets this.
    ///
    /// The two materials are ordered by weight — `ultraThin` at 0.55, `thin` at 0.62 — so moving down the
    /// picker moves in one direction rather than jumping about.
    var defaultOpacity: Double {
        switch self {
        case .ultraThin: 0.55
        case .thin: 0.62
        case .glassRegular, .glassClear: 0.6
        }
    }
}

/// The window chrome's **appearance**: what the window is made of, and how opaque each of its two surfaces is.
///
/// Its *geometry* — how wide the sidebar's column is, and whether it is showing — is `ChromeLayoutSettings`,
/// and the two are separate types because they have opposite answers to one question: *should this follow the
/// user to another machine?* The opacity you like is a preference and roams; the width your sidebar is on a
/// 27-inch display is a fact about a screen and does not. Splitting them is also what the document is shaped
/// around — `SettingsDocument.synced.chrome` is this type and `.device.chrome` is the other — so the split is
/// not a naming choice, it is the thing that makes the document syncable.
///
/// Pure, and `Foundation`-only, which is why it is a separate file from `Theme.swift` beside it:
/// `Theme` is AppKit colours and belongs to the view layer, this is numbers and belongs to the model.
/// The harnesses compile *this* file and not that one, so the split is what makes the values testable.
///
/// **The full settings window is a later phase.** `tinycast_architecture_and_rules.md` §7 specifies a
/// settings hierarchy that no phase has built, and `docs/phase-4.md` records the directory-colour picker
/// waiting on it. This is the part of that hierarchy the chrome needs now — and it is shown as a tab in
/// the terminal rather than in a window of its own, which is the same idea one level up: one window, one
/// list of what is open.
struct ChromeSettings: Equatable {
    /// Every value that can be set has a range, and the range lives here rather than in the control that
    /// sets it. A control that can reach a value the view cannot use is how a slider ends up at an opacity
    /// that means nothing.
    /// Shared by both opacity controls: they are the same quantity on two surfaces, and two ranges that had to
    /// agree would be one more thing to keep in step.
    static let opacityRange: ClosedRange<Double> = 0...1

    /// What the user calls themselves, and where their picture is.
    ///
    /// The name roams; the picture is a **path**, which does not — a file at `~/Pictures/me.png` exists on this
    /// machine and not on the next one. Both live here anyway because there is no sync to get it wrong yet, and the
    /// honest note is that the avatar wants moving to the device half the moment there is.
    var userName: String = ChromeSettings.defaultUserName
    var avatarPath: String?

    /// The name a fresh install shows, before anybody has said otherwise.
    static let defaultUserName = "CoolUser"

    /// Which appearance the window is drawn in, and therefore which palette the terminal draws with.
    var appearanceMode: AppearanceMode = .system

    /// The terminal's text size, in points, and the height of a line as a multiple of it.
    ///
    /// Roaming rather than per-device: they are the two things that decide how the terminal *reads*, and reading
    /// comfort does not depend on which machine you are at. They live here rather than as constants in the view
    /// because `⌘+` and `⌘−` are a setting a person is changing, and a setting that does not survive a restart is
    /// not a setting.
    var fontSize: Double = ChromeSettings.defaultFontSize
    var lineHeightRatio: Double = ChromeSettings.defaultLineHeightRatio

    /// What the window is made of.
    var sidebarMaterial: ChromeMaterial = .glassRegular

    /// What the *terminal* is made of, chosen separately.
    ///
    /// Separate from the sidebar's because they are two surfaces with different jobs: the sidebar is chrome
    /// and can be as glassy as anyone likes, while the terminal has text on it and a material under text is
    /// a legibility decision rather than a taste one. One control for both is a control that has to be wrong
    /// for one of them, which is what it was.
    var terminalMaterial: ChromeMaterial = .ultraThin

    /// How opaque the window's background is, drawn *over* the material.
    ///
    /// The material is always there; this is the window's background colour on top of it. So a value of 1
    /// hides the material completely, and the material is what you see at anything less. That is the
    /// opposite of "the opacity of the material", and it is the arrangement vicinae uses — its config
    /// says *"Needs window opacity < 1 to be visible"* about the material for exactly this reason.
    ///
    /// Getting this backwards is not a subtle bug: multiplying the material by the opacity means that at
    /// zero every material looks the same, which is to say invisible, which is to say the picker appears
    /// to do nothing.
    /// 60%, which is what `glassRegular` wants — the default material and the default opacity are a pair, so the
    /// number here is the material's own rather than a second opinion about it.
    var sidebarOpacity: Double = ChromeMaterial.glassRegular.defaultOpacity

    /// How opaque the terminal's *own* background is, drawn over the window's.
    ///
    /// Separate from the sidebar's because they are separate surfaces with opposite instincts: the sidebar is
    /// chrome and wants to be translucent, the terminal is content and usually wants to be solid. They stack —
    /// this fill is drawn over the window's — so 0% means "as translucent as the sidebar", not "invisible".
    /// That is the honest reading of two fills, and it is why one slider for both could not have said it.
    var terminalOpacity: Double = ChromeSettings.defaultTerminalOpacity

    /// What the terminal's opacity resets to. Named rather than written into the view's `Reset`, because a
    /// default is a decision and a literal in a button is a decision nobody can find.
    /// **Zero, on purpose.** The terminal's own background fill is what the slider moves, and at zero none of it is
    /// drawn — so the terminal is exactly as translucent as its material allows, with the text sitting on the glass.
    /// It is the setting the default material is chosen for: `ultraThin` under a full-strength fill would be a
    /// material nobody could see.
    static let defaultTerminalOpacity: Double = 0

    mutating func setSidebarOpacity(_ opacity: Double) {
        sidebarOpacity = Self.opacityRange.clamping(opacity)
    }

    mutating func setTerminalOpacity(_ opacity: Double) {
        terminalOpacity = Self.opacityRange.clamping(opacity)
    }

    /// Choose a material, and move the opacity to the value that material wants.
    ///
    /// Picking one is then immediately visible rather than needing a second control to be found first.
    /// The user can move the opacity afterwards, and that is the point of it being separate.
    ///
    /// It moves the *sidebar's* opacity and leaves the terminal's alone, which is pinned by a harness check:
    /// a material's default opacity is a fact about the window, the terminal's is a preference about the
    /// terminal, and one setting silently rewriting another is the worst kind of coupling.
    /// **The numbers live here, not in `Theme`.** A harness compiles a *subset* of the sources, and `Theme` is
    /// not in it — so a model file that reached into the tokens would not compile there, which is how this was
    /// found. `Theme.Typography` reads these rather than the other way round, and the relationship is asserted by
    /// `chrome-settings-test`.
    ///
    /// 13 and 1.4 are Warp's defaults (`crates/warp_core/src/ui/appearance.rs:117` and `:123`).
    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32
    static let defaultLineHeightRatio: Double = 1.4
    static let lineHeightRatioRange: ClosedRange<Double> = 1.0...2.0

    /// An empty name is not a name — it would leave the sidebar with a blank row and the page with nothing on it, so
    /// it falls back rather than being stored.
    mutating func setUserName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        userName = trimmed.isEmpty ? Self.defaultUserName : trimmed
    }

    mutating func setAvatarPath(_ path: String?) { avatarPath = path }

    mutating func setFontSize(_ size: Double) { fontSize = Self.fontSizeRange.clamping(size) }

    mutating func setLineHeightRatio(_ ratio: Double) {
        lineHeightRatio = Self.lineHeightRatioRange.clamping(ratio)
    }

    mutating func setSidebarMaterial(_ material: ChromeMaterial) {
        sidebarMaterial = material
        sidebarOpacity = material.defaultOpacity
    }

    /// The terminal's material, and the same move to the opacity that material wants — by symmetry with the
    /// sidebar, and for the same reason: a material picked while its surface is opaque is a material nobody
    /// can see they picked.
    ///
    /// It moves the *terminal's* opacity and leaves the sidebar's alone. That is the whole point of the two
    /// controls existing.
    mutating func setTerminalMaterial(_ material: ChromeMaterial) {
        terminalMaterial = material
        terminalOpacity = material.defaultOpacity
    }
}

extension ChromeSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case appearanceMode
        case fontSize
        case lineHeightRatio
        case userName
        case avatarPath
        case sidebarMaterial
        case terminalMaterial
        case sidebarOpacity
        case terminalOpacity
    }

    /// Tolerant, and **clamped**, on the way in.
    ///
    /// Clamped because the document is a file: it can be hand-edited, and it can have been written by a build
    /// whose ranges were different. An opacity of 9 is not an error worth reporting, it is a value that is not
    /// allowed — so it loads as the nearest one that is, through the same setter a slider goes through.
    ///
    /// And every field falls back to its default on its own, including the material: one unrecognised string in
    /// a file should cost that one setting, not the whole document.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ChromeSettings()

        self.init()
        // Both names are decoded as *strings* rather than as the enums, so a material or an appearance this
        // build has never heard of costs that one setting and nothing else. Decoding the enum directly would
        // throw, and the throw would take the whole document with it.
        appearanceMode =
            (try container.decodeIfPresent(String.self, forKey: .appearanceMode))
            .flatMap(AppearanceMode.init(rawValue:)) ?? fallback.appearanceMode
        // Through the setters, so a file hand-edited to 400 points comes back clamped rather than drawn at 400.
        // Through the setter, so a file hand-edited to an empty name comes back as the default rather than as a blank
        // row in the sidebar.
        setUserName(
            try container.decodeIfPresent(String.self, forKey: .userName) ?? fallback.userName)
        avatarPath = try container.decodeIfPresent(String.self, forKey: .avatarPath) ?? fallback.avatarPath
        setFontSize(try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fallback.fontSize)
        setLineHeightRatio(
            try container.decodeIfPresent(Double.self, forKey: .lineHeightRatio)
                ?? fallback.lineHeightRatio)
        let materialName = try container.decodeIfPresent(String.self, forKey: .sidebarMaterial)
        sidebarMaterial = materialName.flatMap(ChromeMaterial.init(rawValue:)) ?? fallback.sidebarMaterial
        let terminalName = try container.decodeIfPresent(String.self, forKey: .terminalMaterial)
        terminalMaterial = terminalName.flatMap(ChromeMaterial.init(rawValue:)) ?? fallback.terminalMaterial
        // Directly rather than through `setSidebarMaterial`: that one moves the opacity to the material's
        // default, which is right when a person picks one and wrong when a file is being read.
        setSidebarOpacity(
            try container.decodeIfPresent(Double.self, forKey: .sidebarOpacity) ?? fallback.sidebarOpacity)
        setTerminalOpacity(
            try container.decodeIfPresent(Double.self, forKey: .terminalOpacity) ?? fallback.terminalOpacity)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearanceMode.rawValue, forKey: .appearanceMode)
        try container.encode(userName, forKey: .userName)
        try container.encodeIfPresent(avatarPath, forKey: .avatarPath)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(lineHeightRatio, forKey: .lineHeightRatio)
        try container.encode(sidebarMaterial.rawValue, forKey: .sidebarMaterial)
        try container.encode(terminalMaterial.rawValue, forKey: .terminalMaterial)
        try container.encode(sidebarOpacity, forKey: .sidebarOpacity)
        try container.encode(terminalOpacity, forKey: .terminalOpacity)
    }
}

extension ClosedRange where Bound: Comparable {
    /// Clamped into the range. Spelled once because a value that has a range is a value that is going to
    /// be clamped in more than one place, and the second place is where the two disagree.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
