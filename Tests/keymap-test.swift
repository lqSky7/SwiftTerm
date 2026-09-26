import Foundation

@main
enum KeymapTest {
    static func main() {
        let harness = Harness("keymap-test")

        testDefaultShortcuts(harness)
        testKeyMatchingAndOverrides(harness)
        testSettingsDocumentRoundTrip(harness)

        harness.finish()
    }

    private static func testDefaultShortcuts(_ harness: Harness) {
        let keymap = Keymap.defaultKeymap

        let splitH = keymap.shortcut(for: .splitPaneHorizontal)
        harness.equal(splitH.key, "d", "Split horizontal key")
        harness.equal(splitH.modifiers, [.command], "Split horizontal modifiers")
        harness.equal(splitH.displayString, "⌘D", "Display string matches")

        let splitV = keymap.shortcut(for: .splitPaneVertical)
        harness.equal(splitV.displayString, "⇧⌘D", "Split vertical display string")

        let prevBlock = keymap.shortcut(for: .jumpPreviousBlock)
        harness.equal(prevBlock.displayString, "⌘↑", "Jump previous block display string")

        let nextBlock = keymap.shortcut(for: .jumpNextBlock)
        harness.equal(nextBlock.displayString, "⌘↓", "Jump next block display string")

        // **The two arrow pairs, and that they are two.** `⌘↑`/`⌘↓` are the block jumps and `⌥⌘↑`/`⌥⌘↓`
        // are the tabs, which is the whole reason the tab pair is spelled the way it is — one modifier
        // further out is the same gesture. They are one modifier apart, so a mistake here is not a
        // shortcut that fails but a shortcut that does the *other* thing.
        harness.equal(
            keymap.shortcut(for: .nextTab).displayString, "⌥⌘↓", "Next tab display string")
        harness.equal(
            keymap.shortcut(for: .previousTab).displayString, "⌥⌘↑", "Previous tab display string")

        harness.equal(
            keymap.action(for: "DownArrow", modifiers: [.command, .option]), .nextTab,
            "⌥⌘↓ moves to the next tab")
        harness.equal(
            keymap.action(for: "UpArrow", modifiers: [.command, .option]), .previousTab,
            "⌥⌘↑ moves to the previous tab")
        harness.equal(
            keymap.action(for: "DownArrow", modifiers: [.command]), .jumpNextBlock,
            "⌘↓ is still the next block")
        harness.equal(
            keymap.action(for: "UpArrow", modifiers: [.command]), .jumpPreviousBlock,
            "⌘↑ is still the previous block")
    }

    private static func testKeyMatchingAndOverrides(_ harness: Harness) {
        var keymap = Keymap()
        // Test default lookup
        let action1 = keymap.action(for: "d", modifiers: [.command])
        harness.equal(action1, .splitPaneHorizontal, "Matches default split action")

        // Override split horizontal with ⌘H
        keymap.overrides[.splitPaneHorizontal] = KeyEquivalent(key: "h", modifiers: [.command])

        let action2 = keymap.action(for: "d", modifiers: [.command])
        harness.equal(action2, nil, "⌘D no longer triggers split horizontal")

        let action3 = keymap.action(for: "h", modifiers: [.command])
        harness.equal(action3, .splitPaneHorizontal, "⌘H now triggers split horizontal")
        harness.equal(keymap.shortcut(for: .splitPaneHorizontal).displayString, "⌘H", "New shortcut display string")
    }

    private static func testSettingsDocumentRoundTrip(_ harness: Harness) {
        var doc = SettingsDocument()
        doc.synced.themeName = "Dracula"
        doc.synced.customKeymap["split_pane_horizontal"] = KeyEquivalent(key: "h", modifiers: [.command])

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(doc) else {
            harness.expect(false, "Failed to encode SettingsDocument")
            return
        }

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(SettingsDocument.self, from: data) else {
            harness.expect(false, "Failed to decode SettingsDocument")
            return
        }

        harness.equal(decoded.synced.themeName, "Dracula", "Theme name preserved")
        harness.equal(
            decoded.synced.customKeymap["split_pane_horizontal"]?.displayString,
            "⌘H",
            "Custom keymap preserved"
        )
    }
}
