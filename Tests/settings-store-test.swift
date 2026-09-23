import Foundation

/// Guards the settings document and the store that keeps it.
///
/// The interesting cases are not the round trip — that either works or nothing works — but the *other* builds:
/// a file written by a version that knew about a field this one does not, one written before the document was
/// split in two, one a person edited by hand into a value the layout cannot use, and one that is not a document
/// at all. Every one of those has to end with settings that are usable, because the alternative is an app that
/// resets everything or will not start.
///
/// The second subject is the **split**: `synced` roams between machines and `device` does not, and that is in
/// the file's shape rather than in a filter at the edge. So the tests below say which area each value lands in,
/// and one of them reads a version 1 file to prove the migration puts each half where it belongs.
@main
enum SettingsStoreTest {
    static func main() {
        let harness = Harness("settings-store-test")

        anEmptyStoreGivesTheDefaults(harness)
        whatIsSavedIsWhatComesBack(harness)
        aDocumentFromAnotherBuildStillLoads(harness)
        oneUnreadableFieldCostsOneField(harness)
        oneUnreadableAreaCostsOneArea(harness)
        aValueOutOfRangeIsClamped(harness)
        aCorruptBlobIsWorthNoMoreThanNoBlob(harness)
        storesWithDifferentKeysDoNotCollide(harness)
        theVersionIsStoredWithTheValues(harness)
        theRevisionIsStoredWithTheValues(harness)

        harness.finish()
    }

    // MARK: - Scratch suites

    /// A suite of its own per case, wiped first, so a harness never touches the settings the app is using.
    private static func fresh(_ name: String) -> UserDefaults {
        let suite = "swiftterm-harness-\(name)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func store(_ name: String) -> SettingsStore {
        SettingsStore(defaults: fresh(name), key: "test")
    }

    /// A document written by hand, the way a file on disk would be.
    private static func stored(_ json: String, as name: String) -> SettingsStore {
        let defaults = fresh(name)
        defaults.set(Data(json.utf8), forKey: "test")
        return SettingsStore(defaults: defaults, key: "test")
    }

    // MARK: - The cases

    private static func anEmptyStoreGivesTheDefaults(_ harness: Harness) {
        let document = store("empty").load()
        harness.equal(document.version, SettingsDocument.currentVersion, "a fresh document is the current version")
        harness.equal(document.synced.chrome, ChromeSettings(), "and holds every default of the roaming half")
        harness.equal(document.device.chrome, ChromeLayoutSettings(), "and of the half that stays")
        harness.equal(document.revision, 0, "with nothing written yet")
    }

    private static func whatIsSavedIsWhatComesBack(_ harness: Harness) {
        let store = store("round-trip")
        var document = SettingsDocument()
        // Both halves, in the one place each belongs.
        document.synced.chrome.setSidebarMaterial(.ultraThin)
        document.synced.chrome.setTerminalMaterial(.thin)
        document.synced.chrome.appearanceMode = .light
        document.synced.chrome.setFontSize(15)
        document.synced.chrome.setLineHeightRatio(1.55)
        document.synced.chrome.setSidebarOpacity(0.42)
        document.synced.chrome.setTerminalOpacity(0.31)
        document.device.chrome.setSidebarWidth(301)
        document.device.chrome.isSidebarCollapsed = true
        store.save(document)

        let back = store.load()
        harness.equal(back.device.chrome.sidebarWidth, 301, "the width comes back")
        harness.equal(back.synced.chrome.sidebarOpacity, 0.42, "the sidebar's opacity comes back")
        harness.equal(back.synced.chrome.terminalOpacity, 0.31, "and the terminal's, separately")
        harness.equal(back.synced.chrome.sidebarMaterial, .ultraThin, "the material comes back")
        harness.equal(
            back.synced.chrome.terminalMaterial, .thin, "and the terminal's, which is its own")
        harness.equal(back.synced.chrome.appearanceMode, .light, "and the appearance")
        harness.equal(back.synced.chrome.fontSize, 15, "and the text size, so ⌘+ survives a restart")
        harness.equal(back.synced.chrome.lineHeightRatio, 1.55, "and the line height")
        harness.equal(back.device.chrome.isSidebarCollapsed, true, "and whether the sidebar was hidden")
        harness.equal(back, document, "the whole document is unchanged by the trip")

        // Saving twice is the same as saving once: every command that changes a setting writes.
        store.save(document)
        harness.equal(store.load(), document, "and writing it again changes nothing")
    }

    /// The migration, and the reason a version is stored at all: version 1 had **one** `chrome` object holding
    /// both halves, because nothing had told appearance and geometry apart yet.
    private static func aDocumentFromAnotherBuildStillLoads(_ harness: Harness) {
        // Written by a build that knew about a field this one has never heard of, that did not know about one
        // this one expects, and that kept both halves in the same object.
        let store = stored(
            #"{"version":1,"chrome":{"sidebarWidth":260,"sidebarOpacity":0.3,"sidebarMaterial":"thin"},"somethingNew":{"a":1}}"#,
            as: "partial")
        let document = store.load()

        harness.equal(
            document.device.chrome.sidebarWidth, 260,
            "the geometry a version 1 file kept lands in the area that does not roam")
        harness.equal(
            document.synced.chrome.sidebarOpacity, 0.3,
            "and the appearance it kept lands in the area that does")
        harness.equal(document.synced.chrome.sidebarMaterial, .thin, "material and all")
        harness.equal(
            document.synced.chrome.terminalOpacity, ChromeSettings().terminalOpacity,
            "a field that is missing falls back to its default")
        harness.equal(
            document.device.chrome.isSidebarCollapsed, false,
            "in both areas, not just the one that was written")
        harness.equal(
            document.version, SettingsDocument.currentVersion,
            "and reading it is what migrates it, so the version moves with it")
    }

    private static func oneUnreadableFieldCostsOneField(_ harness: Harness) {
        // A material name this build does not know. Decoding the enum directly would throw, and the throw would
        // take the whole document with it — which is how one unknown setting becomes no settings at all.
        let store = stored(
            #"{"version":1,"chrome":{"sidebarMaterial":"liquid_glass_from_the_future","sidebarWidth":300}}"#,
            as: "bad-material")
        let document = store.load()

        harness.equal(
            document.synced.chrome.sidebarMaterial, ChromeSettings().sidebarMaterial,
            "an unrecognised material falls back")
        harness.equal(
            document.device.chrome.sidebarWidth, 300,
            "and the field beside it survives — across the split, in the other area")

        // The same thing in the shape this build writes, where the bad field and its neighbour are in one area.
        let current = stored(
            #"{"version":2,"synced":{"chrome":{"sidebarMaterial":"glass_from_the_future","terminalOpacity":0.4}}}"#,
            as: "bad-material-current")
        let migrated = current.load()
        harness.equal(
            migrated.synced.chrome.sidebarMaterial, ChromeSettings().sidebarMaterial,
            "in the current shape an unrecognised material also falls back")
        harness.equal(
            migrated.synced.chrome.terminalOpacity, 0.4,
            "and costs only itself, not the field next to it")
    }

    /// An area whose whole object is the wrong shape costs that area and not the document. The two areas are
    /// separate in the *shape* so a backend can take one of them; this is the other half of that: a file where
    /// one of them is junk still loads the other.
    private static func oneUnreadableAreaCostsOneArea(_ harness: Harness) {
        let store = stored(
            #"{"version":2,"synced":{"chrome":"not an object at all"},"device":{"chrome":{"sidebarWidth":300}}}"#,
            as: "bad-area")
        let document = store.load()

        harness.equal(
            document.synced.chrome, ChromeSettings(),
            "an area that cannot be read is every default")
        harness.equal(
            document.device.chrome.sidebarWidth, 300,
            "and the area beside it is read anyway")
    }

    private static func aValueOutOfRangeIsClamped(_ harness: Harness) {
        // A file can be hand-edited, or written by a build whose ranges were different. Neither is an error to
        // report: it is a value that is not allowed, so it loads as the nearest one that is.
        let store = stored(
            #"{"synced":{"chrome":{"sidebarOpacity":9}},"device":{"chrome":{"sidebarWidth":40}}}"#,
            as: "clamped")
        let document = store.load()

        harness.equal(
            document.device.chrome.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.lowerBound,
            "a width below the range loads at the minimum")
        harness.equal(document.synced.chrome.sidebarOpacity, 1, "an opacity above it loads at the maximum")
        harness.expect(
            ChromeLayoutSettings.sidebarWidthRange.contains(document.device.chrome.sidebarWidth),
            "so a document that loaded is always one the layout can use")
        harness.equal(
            document.version, SettingsDocument.currentVersion,
            "and a document with no version is taken as the current one")

        // The migration goes through the same setter a drag does, so a version 1 file is clamped too — the
        // alternative is an old file being the one way to get a width the layout cannot use.
        let legacy = stored(#"{"version":1,"chrome":{"sidebarWidth":40}}"#, as: "clamped-legacy").load()
        harness.equal(
            legacy.device.chrome.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.lowerBound,
            "and so is a width read out of a version 1 file")
    }

    private static func aCorruptBlobIsWorthNoMoreThanNoBlob(_ harness: Harness) {
        harness.equal(
            stored("not json at all", as: "corrupt").load(), SettingsDocument(),
            "a blob that is not JSON loads as a fresh document")
        harness.equal(
            stored("[1,2,3]", as: "wrong-shape").load(), SettingsDocument(),
            "and so does the right format with the wrong shape")
        let empty = stored("{}", as: "empty-object").load()
        harness.equal(empty.synced.chrome, ChromeSettings(), "and an empty object is every default")
        harness.equal(empty.device.chrome, ChromeLayoutSettings(), "in both areas")
    }

    private static func storesWithDifferentKeysDoNotCollide(_ harness: Harness) {
        let defaults = fresh("keys")
        var document = SettingsDocument()
        document.device.chrome.setSidebarWidth(300)
        SettingsStore(defaults: defaults, key: "one").save(document)

        harness.equal(
            SettingsStore(defaults: defaults, key: "two").load().device.chrome.sidebarWidth,
            ChromeLayoutSettings().sidebarWidth, "a second key starts fresh")
        harness.equal(
            SettingsStore(defaults: defaults, key: "one").load().device.chrome.sidebarWidth, 300,
            "and leaves the first key alone")
    }

    private static func theVersionIsStoredWithTheValues(_ harness: Harness) {
        let defaults = fresh("version")
        let store = SettingsStore(defaults: defaults, key: "test")
        var document = SettingsDocument()
        document.version = 7
        store.save(document)

        harness.equal(store.load().version, 7, "the version survives the trip")

        // And it is a field in the file, where a migration can read it without this build's decoder.
        let blob = defaults.data(forKey: "test") ?? Data()
        let text = String(bytes: blob, encoding: .utf8) ?? ""
        harness.expect(text.contains("\"version\""), "the version is a field in the stored document")
        // The split is in the *file*, which is the whole reason it is in the type: a backend that had to be told
        // which fields to skip would have to be changed every time a setting is added.
        harness.expect(text.contains("\"synced\""), "and the roaming half is named in it")
        harness.expect(text.contains("\"device\""), "and so is the half that stays")
        harness.expect(text.contains("\"chrome\""), "with the chrome area named inside them")
    }

    /// The revision is the one field a syncing client cannot add later — a revision has to be incremented by
    /// every writer from the first, or the writes made before the backend arrived cannot be ordered against the
    /// ones after. So it is written now, and this checks it survives.
    ///
    /// What *increments* it is `AppCore.persist()`, one line beside the two areas it saves, and that is not
    /// reachable from a harness: `AppCore` is the composition root and imports AppKit. The field being here, and
    /// round-tripping, is what this can honestly check.
    private static func theRevisionIsStoredWithTheValues(_ harness: Harness) {
        let defaults = fresh("revision")
        let store = SettingsStore(defaults: defaults, key: "test")
        var document = SettingsDocument()
        document.revision = 41
        store.save(document)

        harness.equal(store.load().revision, 41, "the revision survives the trip")

        let blob = defaults.data(forKey: "test") ?? Data()
        let text = String(bytes: blob, encoding: .utf8) ?? ""
        harness.expect(text.contains("\"revision\""), "and is a field in the stored document")
    }
}
