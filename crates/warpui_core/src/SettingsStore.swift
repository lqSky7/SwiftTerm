import Foundation

/// Everything the app remembers between launches.
///
/// One document with a version and one field per *area* of settings, rather than a key per setting scattered
/// through the app. Adding an area is a field here; adding a setting is a property on that area's type. That
/// is the shape that reads the same at twenty settings as at four — and it is the shape a migration can be
/// written against, because a version is a thing a document can have and a bag of loose keys cannot.
///
/// Pure and `Foundation`-only, so a harness can round-trip it and prove what happens to a file written by a
/// different build.
///
/// **It is split in two, and that is what makes it syncable.** `synced` is what follows the user to another
/// machine; `device` is what must not. The split is in the *shape* rather than a filter at the edge, because a
/// backend that had to be told which fields to skip is a backend that has to be changed every time a setting
/// is added.
struct SettingsDocument: Codable, Equatable {
    /// Bumped when a change cannot be read by the version before it. Stored *with* the values: a file that does
    /// not say what it is, is a file nothing can be migrated.
    ///
    /// **2** — the document split into `synced` and `device`, which is what made it syncable. A version 1 file
    /// is still readable; see `init(from:)`.
    static let currentVersion = 2

    var version = SettingsDocument.currentVersion

    /// Incremented on every save. One integer, and it is the whole of optimistic concurrency: a future sync
    /// backend can tell a stale write from a fresh one without comparing contents, and a device that has not
    /// seen revision 40 knows it is behind rather than guessing.
    ///
    /// Nothing reads it yet. It is written now because it is the one field a syncing client cannot add
    /// afterwards — a revision has to be incremented by every writer from the first, or the first few writes
    /// after the backend arrives are indistinguishable from each other.
    var revision = 0

    /// Roams between devices: anything a person would be annoyed to set again on a second machine.
    var synced = SyncedSettings()

    /// Stays on this one: geometry tied to a display, and state tied to a window. A backend that synced these
    /// would fight the other machine's screen size, so they are separate in the *shape* rather than filtered
    /// out at the edge.
    var device = DeviceSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version
        case revision
        case synced
        case device
    }

    /// The one key the current shape does *not* have, kept so a version 1 file can still be read. It is a key of
    /// its own type rather than a case on `CodingKeys`, because `CodingKeys` is the honest list of what this
    /// document holds and `chrome` is not one of them any more.
    private enum LegacyKeys: String, CodingKey {
        case chrome
    }

    /// Tolerant on the way in, deliberately.
    ///
    /// A document written by a newer build carries fields this one has never heard of; one written by an older
    /// build is missing fields this one expects. Neither is an error. The first is ignored and the second falls
    /// back to its default, because a settings file that refuses to load is a settings file that resets
    /// everything — a worse outcome than one field nobody understood.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsDocument()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? fallback.version
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        // `try?` around each area rather than plain `decodeIfPresent`: an area whose own decoder throws would
        // otherwise take the document with it, and the whole point of the area's tolerance is that it cannot.
        synced = (try? container.decode(SyncedSettings.self, forKey: .synced)) ?? fallback.synced
        device = (try? container.decode(DeviceSettings.self, forKey: .device)) ?? fallback.device

        // The first migration, and the reason the version is stored: version 1 kept one `chrome` object holding
        // *both* areas, because the two had not yet been told apart. Reading one costs a field rather than every
        // setting the user had set — and it is `try?` for the same reason the areas are: a `chrome` that is not
        // an object at all should cost the migration, not the document.
        let legacy =
            (try? decoder.container(keyedBy: LegacyKeys.self)
                .decodeIfPresent(VersionOneChrome.self, forKey: .chrome)) ?? nil
        if version < 2, let legacy {
            legacy.apply(to: &synced.chrome, and: &device.chrome)
            version = 2
        }
    }
}

/// The document as version 1 wrote it: appearance and geometry in one object, because nothing had told them
/// apart yet.
///
/// Every field is optional, and the material is a `String`: this type exists to read a file that may be
/// hand-edited or written by a build whose names differ, so it is the one place where a field being wrong must
/// cost that field and nothing else. It is `private` to the file because it is not a shape anything writes.
private struct VersionOneChrome: Decodable {
    var sidebarWidth: CGFloat?
    var isSidebarCollapsed: Bool?
    var sidebarMaterial: String?
    var sidebarOpacity: Double?
    var terminalOpacity: Double?

    /// Split into the two areas it became, through the same setters a control goes through — so a width outside
    /// the range a layout can use arrives clamped rather than at whatever the file said.
    func apply(to appearance: inout ChromeSettings, and geometry: inout ChromeLayoutSettings) {
        if let sidebarWidth { geometry.setSidebarWidth(sidebarWidth) }
        if let isSidebarCollapsed { geometry.isSidebarCollapsed = isSidebarCollapsed }
        if let sidebarMaterial, let material = ChromeMaterial(rawValue: sidebarMaterial) {
            appearance.sidebarMaterial = material
        }
        if let sidebarOpacity { appearance.setSidebarOpacity(sidebarOpacity) }
        if let terminalOpacity { appearance.setTerminalOpacity(terminalOpacity) }
    }
}

/// What roams.
struct SyncedSettings: Codable, Equatable {
    var chrome = ChromeSettings()
    var themeName: String = "SwiftTerm Mono"
    var activeCustomPalette: TerminalPalette? = nil
    var customPalettes: [String: TerminalPalette] = [:]
    var customKeymap: [String: KeyEquivalent] = [:]
    var savedCommands: [String] = []

    private enum CodingKeys: String, CodingKey {
        case chrome
        case themeName
        case activeCustomPalette
        case customPalettes
        case customKeymap
        case savedCommands
    }

    init() {}

    /// Per-area tolerance, one line per area. A version that adds an area and a version that has never heard of
    /// one both land here, and the answer is the same in both cases: keep what is understood, default the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SyncedSettings()
        chrome = (try? container.decode(ChromeSettings.self, forKey: .chrome)) ?? fallback.chrome
        themeName = (try? container.decode(String.self, forKey: .themeName)) ?? fallback.themeName
        activeCustomPalette = (try? container.decodeIfPresent(TerminalPalette.self, forKey: .activeCustomPalette)) ?? nil
        customPalettes = (try? container.decode([String: TerminalPalette].self, forKey: .customPalettes)) ?? fallback.customPalettes
        customKeymap = (try? container.decode([String: KeyEquivalent].self, forKey: .customKeymap)) ?? fallback.customKeymap
        savedCommands = (try? container.decode([String].self, forKey: .savedCommands)) ?? fallback.savedCommands
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chrome, forKey: .chrome)
        try container.encode(themeName, forKey: .themeName)
        try container.encodeIfPresent(activeCustomPalette, forKey: .activeCustomPalette)
        try container.encode(customPalettes, forKey: .customPalettes)
        try container.encode(customKeymap, forKey: .customKeymap)
        try container.encode(savedCommands, forKey: .savedCommands)
    }
}

/// What stays.
struct DeviceSettings: Codable, Equatable {
    var chrome = ChromeLayoutSettings()

    private enum CodingKeys: String, CodingKey {
        case chrome
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DeviceSettings()
        chrome = (try? container.decode(ChromeLayoutSettings.self, forKey: .chrome)) ?? fallback.chrome
    }
}

/// The chrome's *geometry*, which is not the same thing as its appearance.
///
/// Split out of `ChromeSettings` because the two have opposite answers to "should this roam?": the opacity you
/// like is a preference, the width your sidebar is on a 27-inch display is a fact about a screen. This is the
/// half that stays.
struct ChromeLayoutSettings: Codable, Equatable {
    /// How wide the column the tabs sit in is.
    ///
    /// There is no control for this one, and that is deliberate: the sidebar's edge is draggable, so a
    /// slider for it would be a second way to set the same number and a second place for it to be wrong.
    /// The value still lives here because the drag has to write *somewhere*, and it still has a range
    /// because a drag can go anywhere.
    var sidebarWidth: CGFloat = 220

    /// Whether that column is showing. `⌘⇧B`.
    var isSidebarCollapsed = false

    /// The range a drag can reach. Lives here rather than in the gesture that sets it, so the number the layout
    /// uses and the number the drag can reach are the same number.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 160...420

    /// How much of the window's leading edge the sidebar's column takes.
    ///
    /// Zero when it is hidden, and the width is *not* lost when it is: hiding is not narrowing, so showing it
    /// again puts it back where it was. The panel's geometry is derived from this one number rather than from an
    /// `if` written out at each call site — which is how a collapsed sidebar ends up leaving a strip of itself
    /// behind.
    var occupiedWidth: CGFloat { isSidebarCollapsed ? 0 : sidebarWidth }

    mutating func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = Self.sidebarWidthRange.clamping(width)
    }

    /// Where the content panel sits: everything to the right of the sidebar's column.
    ///
    /// **No margin, deliberately.** An earlier version floated the panel clear of the window's edges,
    /// which reads as a card lying on a desktop rather than as a terminal filling its window — and worse,
    /// it kept a strip of sidebar visible on the leading side even when the sidebar was hidden, which is
    /// the same thing as not being able to hide it. The panel's *leading* corners are still rounded; that
    /// is the view's business, and it is not a margin.
    ///
    /// Here rather than on `ChromeSettings` because it is geometry: the view lays out with it and `AppCore`
    /// sizes the shell with it, and one function read by both is what stops the panel's size and the size the
    /// shell is told from being two numbers.
    func contentPanelFrame(in contentSize: CGSize) -> CGRect {
        let occupied = occupiedWidth
        return CGRect(
            x: occupied,
            y: 0,
            width: max(0, contentSize.width - occupied),
            height: contentSize.height)
    }

    private enum CodingKeys: String, CodingKey {
        case sidebarWidth
        case isSidebarCollapsed
    }

    init() {}

    /// Tolerant and clamped, exactly as `ChromeSettings` is and for the same reason: this half of the chrome is
    /// the one a *display* decides, so it is the one most likely to be wrong on the machine that reads it — a
    /// width saved on a 27-inch screen arriving on a laptop, or a file edited by hand into a width the layout
    /// cannot use. A stored width of 40 is not an error worth reporting, it is a width that is not allowed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ChromeLayoutSettings()

        self.init()
        setSidebarWidth(
            try container.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? fallback.sidebarWidth)
        isSidebarCollapsed =
            try container.decodeIfPresent(Bool.self, forKey: .isSidebarCollapsed)
            ?? fallback.isSidebarCollapsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(isSidebarCollapsed, forKey: .isSidebarCollapsed)
    }
}

/// Where the document is kept, and how it gets there.
///
/// One JSON blob in `UserDefaults`, rather than a defaults key per setting. Defaults are a dictionary of loose
/// values with no shape of their own: they cannot be versioned, they cannot be migrated, and reading one back
/// means every call site has to remember the key *and* what it was supposed to be. A document is the thing
/// that can be tested as a whole.
///
/// The `UserDefaults` is a parameter, so a harness hands it a scratch suite and nothing here ever touches the
/// real one unless the app hands it over.
struct SettingsStore {
    static let defaultKey = "swiftTerm.settings"

    private let defaults: UserDefaults
    private let key: String
    /// Canonical output: stable key order, so the same settings always produce the same bytes. A backend that
    /// wants to diff, hash or ETag the document cannot do that with a dictionary whose order moves.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = SettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// What was saved, or a fresh document. **Never a failure.**
    ///
    /// A corrupt blob is worth no more than no blob at all, and the alternative is an app that will not start
    /// because of a preferences file — which is the worst bug in this category, because the thing the user has
    /// to delete is the thing that is broken.
    func load() -> SettingsDocument {
        guard let data = defaults.data(forKey: key) else { return SettingsDocument() }
        return (try? decoder.decode(SettingsDocument.self, from: data)) ?? SettingsDocument()
    }

    func save(_ document: SettingsDocument) {
        guard let data = try? encoder.encode(document) else { return }
        defaults.set(data, forKey: key)
    }
}
