import Foundation

/// Guards the chrome's numbers: that every one has a range, that the range is what the value is clamped
/// to, that the default is inside its own range, and where the content panel lands.
///
/// The chrome is **two types**, and this harness guards both halves — `ChromeSettings` (appearance, which
/// roams) and `ChromeLayoutSettings` (geometry, which does not). Which half a value belongs to is not a
/// matter of taste: it is the question "would a person be annoyed to set this again on a second machine?".
/// A value filed on the wrong side of that line is a value that either follows a laptop's screen size around
/// or has to be set twice.
///
/// The default-inside-its-range one is not busywork. A default edited to sit outside its range means the
/// first drag of the sidebar's edge jumps — and a jump that happens once, on the way in, is the kind of
/// defect that gets blamed on the gesture.
@main
enum ChromeSettingsTest {
    static func main() {
        let harness = Harness("chrome-settings-test")

        defaultsAreInsideTheirOwnRanges(harness)
        theSidebarWidthIsClamped(harness)
        theOpacityIsClamped(harness)
        theTerminalHasItsOwnOpacity(harness)
        theMaterialList(harness)
        everyMaterialArrivesVisible(harness)
        theTwoSurfacesAreIndependent(harness)
        theTextSizeIsClamped(harness)
        theUserName(harness)
        theAppearanceModes(harness)
        thePanelFillsWhatIsLeft(harness)

        harness.finish()
    }

    private static func defaultsAreInsideTheirOwnRanges(_ harness: Harness) {
        let layout = ChromeLayoutSettings()
        harness.expect(
            ChromeLayoutSettings.sidebarWidthRange.contains(layout.sidebarWidth),
            "the default width is inside its range")
        harness.expect(!layout.isSidebarCollapsed, "and a new window shows its sidebar")

        let settings = ChromeSettings()
        harness.expect(
            ChromeSettings.opacityRange.contains(settings.sidebarOpacity),
            "the default opacity is inside its range")
    }

    /// Geometry: the one number with a range, and the one derived from it.
    private static func theSidebarWidthIsClamped(_ harness: Harness) {
        var settings = ChromeLayoutSettings()

        settings.setSidebarWidth(300)
        harness.equal(settings.sidebarWidth, 300, "a width in range is kept")

        // Below the minimum clamps to the minimum rather than to zero: a sidebar dragged shut is one
        // nobody can drag open again, because the edge went with it.
        settings.setSidebarWidth(10)
        harness.equal(
            settings.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.lowerBound,
            "too narrow clamps up")
        settings.setSidebarWidth(-100)
        harness.equal(
            settings.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.lowerBound,
            "and a negative one too")

        settings.setSidebarWidth(10_000)
        harness.equal(
            settings.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.upperBound,
            "too wide clamps down")

        // The bounds themselves are inside the range, which is what makes them reachable.
        settings.setSidebarWidth(ChromeLayoutSettings.sidebarWidthRange.lowerBound)
        harness.equal(
            settings.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.lowerBound,
            "the minimum is reachable")
        settings.setSidebarWidth(ChromeLayoutSettings.sidebarWidthRange.upperBound)
        harness.equal(
            settings.sidebarWidth, ChromeLayoutSettings.sidebarWidthRange.upperBound,
            "and so is the maximum")

        // The width is not lost when the sidebar is hidden — hiding is not narrowing.
        settings.setSidebarWidth(260)
        harness.equal(settings.occupiedWidth, 260, "an open sidebar occupies its width")
        settings.isSidebarCollapsed = true
        harness.equal(settings.occupiedWidth, 0, "a collapsed one occupies nothing")
        harness.equal(settings.sidebarWidth, 260, "and remembers how wide it was")
        settings.isSidebarCollapsed = false
        harness.equal(settings.occupiedWidth, 260, "so showing it again is where it was")
    }

    /// Appearance: the sidebar's opacity.
    private static func theOpacityIsClamped(_ harness: Harness) {
        var settings = ChromeSettings()

        settings.setSidebarOpacity(0.5)
        harness.equal(settings.sidebarOpacity, 0.5, "an opacity in range is kept")
        settings.setSidebarOpacity(-0.2)
        harness.equal(settings.sidebarOpacity, 0, "below zero is nothing")
        settings.setSidebarOpacity(1.4)
        harness.equal(settings.sidebarOpacity, 1, "and above one is full")

        // Both ends are legitimate values, not clamp artefacts.
        settings.setSidebarOpacity(0)
        harness.equal(settings.sidebarOpacity, 0, "zero is allowed")
        settings.setSidebarOpacity(1)
        harness.equal(settings.sidebarOpacity, 1, "and so is one")
    }

    /// The second opacity, and the one thing about it that would be easy to get wrong: that picking a material
    /// must not move it. A material's default opacity is a fact about the *window*; the terminal's is a
    /// preference about the terminal, and one setting silently rewriting another is the worst kind of coupling.
    private static func theTerminalHasItsOwnOpacity(_ harness: Harness) {
        var settings = ChromeSettings()
        harness.expect(
            ChromeSettings.opacityRange.contains(settings.terminalOpacity),
            "the default is inside the range")
        // **The terminal starts fully translucent and the sidebar does not.** The two materials are chosen for what
        // is behind them: the sidebar carries chrome of its own, while the terminal has text on it, so there its
        // material *is* the surface and its own fill is nothing.
        harness.equal(settings.terminalOpacity, 0, "the terminal starts with no fill of its own")
        harness.equal(settings.terminalMaterial, .ultraThin, "over the lightest material")
        harness.expect(
            settings.sidebarOpacity > settings.terminalOpacity,
            "and the sidebar starts more solid than the terminal beside it")

        settings.setTerminalOpacity(0.4)
        harness.equal(settings.terminalOpacity, 0.4, "an opacity in range is kept")
        settings.setTerminalOpacity(-1)
        harness.equal(settings.terminalOpacity, 0, "below zero is nothing")
        settings.setTerminalOpacity(2)
        harness.equal(settings.terminalOpacity, 1, "and above one is full")

        settings.setTerminalOpacity(0.4)
        settings.setSidebarMaterial(.glassRegular)
        harness.equal(
            settings.terminalOpacity, 0.4,
            "choosing a material moves the sidebar's opacity and leaves the terminal's alone")
        harness.equal(
            settings.sidebarOpacity, ChromeMaterial.glassRegular.defaultOpacity,
            "which is the one it does move")
        harness.expect(
            ChromeSettings.opacityRange.contains(ChromeSettings.defaultTerminalOpacity),
            "and the value Reset goes back to is one the slider can reach")
    }

    /// The list a picker draws, and the two things about it that can be wrong without anybody noticing:
    /// two entries for the same material, and an entry with no label.
    private static func theMaterialList(_ harness: Harness) {
        harness.equal(ChromeMaterial.allCases.count, 5, "five materials to choose from")
        harness.equal(
            Set(ChromeMaterial.allCases.map(\.rawValue)).count, 5, "each with its own name")
        let labels = ChromeMaterial.allCases.map(\.displayName)
        harness.equal(Set(labels).count, 5, "and its own label")
        harness.expect(!labels.contains(where: \.isEmpty), "none of them unlabelled")
        // The two `Material` cases are ordered by weight, so moving down the picker moves one way.
        harness.expect(
            ChromeMaterial.ultraThin.defaultOpacity < ChromeMaterial.thin.defaultOpacity,
            "ultra thin is lighter than thin")

        var settings = ChromeSettings()
        harness.equal(settings.sidebarMaterial, .glassRegular, "glass to start with")
        settings.setSidebarMaterial(.glassRegular)
        harness.equal(settings.sidebarMaterial, .glassRegular, "and a choice is kept")
        settings.setSidebarMaterial(.none)
        harness.equal(settings.sidebarMaterial, .none, "none can be selected")
        settings.setSidebarMaterial(.ultraThin)
        harness.equal(settings.sidebarMaterial, .ultraThin, "whichever it is")
    }

    /// Each material knows the window opacity that shows it off, and picking one moves to it.
    ///
    /// Without this a material chosen while the window is opaque looks like a picker that does nothing —
    /// the material is behind the background, so an opacity of 1 hides whichever one is selected.
    private static func everyMaterialArrivesVisible(_ harness: Harness) {
        for material in ChromeMaterial.allCases {
            harness.expect(
                material.defaultOpacity < 1,
                "\(material.displayName) arrives visible rather than behind an opaque window")
            harness.expect(
                ChromeSettings.opacityRange.contains(material.defaultOpacity),
                "\(material.displayName)'s default opacity is inside the range the control can reach")
            harness.expect(
                !material.displayName.isEmpty, "\(material.rawValue) has a name to show")

            var settings = ChromeSettings()
            settings.setSidebarOpacity(1)
            settings.setSidebarMaterial(material)
            harness.equal(
                settings.sidebarOpacity, material.defaultOpacity,
                "choosing \(material.displayName) moves the opacity to what it wants")
            harness.equal(
                settings.sidebarMaterial, material,
                "and keeps the material that was chosen")
        }
    }

    /// The two surfaces have a material each and an opacity each, and **neither moves the other's**.
    ///
    /// This is the whole reason there are two controls. A sidebar material that moved the terminal's opacity
    /// would be a setting quietly rewriting another setting, which is the coupling that makes a settings page
    /// impossible to reason about — you change one thing and something else is different.
    private static func theTwoSurfacesAreIndependent(_ harness: Harness) {
        var settings = ChromeSettings()
        settings.setSidebarMaterial(.glassRegular)
        settings.setTerminalMaterial(.ultraThin)

        harness.equal(settings.sidebarMaterial, .glassRegular, "the sidebar keeps its material")
        harness.equal(settings.terminalMaterial, .ultraThin, "and the terminal keeps its own")
        harness.equal(
            settings.terminalOpacity, ChromeMaterial.ultraThin.defaultOpacity,
            "picking the terminal's material moves the terminal's opacity")
        harness.equal(
            settings.sidebarOpacity, ChromeMaterial.glassRegular.defaultOpacity,
            "and leaves the sidebar's exactly where its own material put it")

        // And the other way round: a sidebar material must not touch the terminal's opacity.
        settings.setTerminalOpacity(0.31)
        settings.setSidebarMaterial(.glassClear)
        harness.equal(
            settings.terminalOpacity, 0.31,
            "choosing a sidebar material leaves the terminal's opacity alone")

        // Each has its own default, so a Reset on one surface goes back to the material that surface is
        // wearing rather than to the other one's.
        var fresh = ChromeSettings()
        fresh.setTerminalMaterial(.thin)
        harness.equal(
            fresh.terminalMaterial.defaultOpacity, ChromeMaterial.thin.defaultOpacity,
            "the terminal's Reset goes back to the material the terminal is wearing")
    }

    /// The two settings that decide how the terminal reads.
    ///
    /// Both are reachable from `⌘+`/`⌘−` as well as from the settings page, so a value out of range has to be
    /// impossible rather than merely unlikely — a font size of 400 is not a mistake the clamp can leave to the
    /// view, because the view is the thing that would have to draw it.
    private static func theTextSizeIsClamped(_ harness: Harness) {
        var settings = ChromeSettings()
        harness.equal(settings.fontSize, 13, "13 points, which is what Warp ships")
        harness.equal(settings.lineHeightRatio, 1.4, "and Warp's line height ratio")

        settings.setFontSize(400)
        harness.equal(settings.fontSize, ChromeSettings.fontSizeRange.upperBound, "an absurd size is clamped")
        settings.setFontSize(1)
        harness.equal(settings.fontSize, ChromeSettings.fontSizeRange.lowerBound, "and so is a tiny one")
        settings.setFontSize(15)
        harness.equal(settings.fontSize, 15, "a real one is kept exactly")

        settings.setLineHeightRatio(9)
        harness.equal(
            settings.lineHeightRatio, ChromeSettings.lineHeightRatioRange.upperBound,
            "the line height is clamped too")
        settings.setLineHeightRatio(0.1)
        harness.equal(
            settings.lineHeightRatio, ChromeSettings.lineHeightRatioRange.lowerBound,
            "at both ends")
        settings.setLineHeightRatio(1.25)
        harness.equal(settings.lineHeightRatio, 1.25, "and kept when it is real")

        // The line height has to be able to be *tighter* than the font's own leading as well as looser, which is
        // why the range starts below 1.19 rather than at it.
        harness.expect(
            ChromeSettings.lineHeightRatioRange.lowerBound < 1.19,
            "the range reaches below a font's natural leading")
    }

    /// The name on the profile page, which is also the name in the sidebar.
    private static func theUserName(_ harness: Harness) {
        var settings = ChromeSettings()
        harness.equal(settings.userName, "CoolUser", "a fresh install is a CoolUser")
        harness.equal(settings.avatarPath, nil, "with no picture until one is chosen")

        // **An empty name is refused rather than stored.** It would leave the sidebar with a blank row and the page with
        // nothing on it, which is worse than not being able to clear it.
        settings.setUserName("")
        harness.equal(settings.userName, "CoolUser", "clearing the name falls back to the default")
        settings.setUserName("   ")
        harness.equal(settings.userName, "CoolUser", "and so does a name that is only spaces")

        settings.setUserName("  Ada Lovelace  ")
        harness.equal(settings.userName, "Ada Lovelace", "a real name is trimmed and kept")

        settings.setAvatarPath("/tmp/me.png")
        harness.equal(settings.avatarPath, "/tmp/me.png", "and the picture is a path")
        settings.setAvatarPath(nil)
        harness.equal(settings.avatarPath, nil, "which can be cleared again")
    }

    /// The appearance selector: three names, a default that has no opinion, and no two of them the same.
    private static func theAppearanceModes(_ harness: Harness) {
        harness.equal(AppearanceMode.allCases.count, 3, "system, light and dark")
        let labels = AppearanceMode.allCases.map(\.displayName)
        harness.equal(Set(labels).count, 3, "each with its own label")
        harness.expect(!labels.contains(where: \.isEmpty), "none of them unlabelled")

        harness.equal(
            ChromeSettings().appearanceMode, .system,
            "and the default follows the system rather than picking a side")

        // `system` has no opinion — that is what makes it different from light, and answering it with a
        // default is how a light terminal ends up drawn in a dark window.
        harness.expect(AppearanceMode.system.isLight == nil, "system does not say which it is")
        harness.equal(AppearanceMode.light.isLight, true, "light is light")
        harness.equal(AppearanceMode.dark.isLight, false, "and dark is not")
    }

    /// The panel takes everything to the right of the sidebar's column and *nothing else* — there is no
    /// margin. The margin that used to be here kept a strip of sidebar visible even when the sidebar was
    /// hidden, which is the same thing as not being able to hide it.
    private static func thePanelFillsWhatIsLeft(_ harness: Harness) {
        let window = CGSize(width: 1000, height: 600)
        var settings = ChromeLayoutSettings()
        settings.setSidebarWidth(220)

        let open = settings.contentPanelFrame(in: window)
        harness.equal(open.minX, 220, "the panel starts where the sidebar's column ends")
        harness.equal(open.minY, 0, "and at the very top of the window")
        harness.equal(open.width, 780, "taking all the width that is left")
        harness.equal(open.height, 600, "and the whole height")

        settings.isSidebarCollapsed = true
        let collapsed = settings.contentPanelFrame(in: window)
        harness.equal(collapsed.minX, 0, "a hidden sidebar gives the panel the whole window")
        harness.equal(collapsed.width, 1000, "in both directions")
        harness.equal(collapsed.height, 600, "with nothing held back for the window's own controls")

        // A window narrower than the sidebar gives the panel no width rather than a negative one.
        settings.isSidebarCollapsed = false
        settings.setSidebarWidth(ChromeLayoutSettings.sidebarWidthRange.upperBound)
        let tiny = settings.contentPanelFrame(in: CGSize(width: 100, height: 40))
        harness.equal(tiny.width, 0, "a window narrower than its sidebar gives no width")
        harness.equal(tiny.height, 40, "and still the height it has")
    }
}
