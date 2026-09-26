import AppKit

/// The menu bar.
///
/// Every item targets `nil`, which is what routes it down the responder chain to the terminal. A
/// menu item wired straight to an object would work until there is a second window; one that walks
/// the chain keeps working.
@MainActor
enum AppMenus {
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(windowMenu())
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = mainMenu.item(at: 4)?.submenu
    }

    private static var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "swiftTerm"
    }

    /// Tabs and panes, which is what a file is in an app whose documents are shells.
    ///
    /// `Close Pane` is `⌘W` rather than closing the window, and the window's own close moved to `⇧⌘W`:
    /// with more than one pane on screen, the thing a person means by "close this" is the thing they
    /// are looking at, and closing the window is the rarer intent.
    ///
    /// `New Window` targets `nil` like every other item here, but it is not one of `TerminalWindowController`'s
    /// selectors: no object in the responder chain below `AppDelegate` can open a *second* window, so this is
    /// the one item that relies on the chain reaching all the way past the window controller to the app itself.
    private static func fileMenu() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), key: "n"))
        menu.addItem(item("New Tab", #selector(TerminalWindowController.newTab(_:)), key: "t"))
        menu.addItem(item("Close Pane", #selector(TerminalWindowController.closePane(_:)), key: "w"))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", #selector(TerminalWindowController.splitRight(_:)), key: "d"))
        menu.addItem(
            item(
                "Split Down", #selector(TerminalWindowController.splitDown(_:)), key: "d",
                modifiers: [.command, .shift]))
        return submenuItem("File", menu)
    }

    private static func appMenu() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(
            item("About \(applicationName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // `⌘,`, which is where macOS puts it — and it opens a *tab*, not a window. A settings window
        // would be a second place that knows what is open.
        menu.addItem(
            item("Settings…", #selector(TerminalWindowController.openSettings(_:)), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(applicationName)", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item(
            "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
            modifiers: [.command, .option])
        menu.addItem(hideOthers)
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(applicationName)", #selector(NSApplication.terminate(_:)), key: "q"))
        return submenuItem(applicationName, menu)
    }

    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        // **Cut and Select All are the editor's, and only the editor's.** They were absent here, on the
        // grounds that a block is the unit of selection — and the cost of that was that `⌘X` and `⌘A` did
        // *nothing at all*, because a key equivalent with no menu item behind it is never matched: it
        // reaches the view as a plain `keyDown`, and no view implements `⌘A`.
        //
        // Warp's answer is the same one, which is why both items carry the standard selectors: its
        // `EditorAction::SelectAll` and `EditorAction::Cut` are actions of the *input editor*
        // (`app/src/editor/view/mod.rs`), and there is no cut on the terminal at all — a terminal's grid is
        // the shell's output, not a buffer anything can delete from.
        //
        // So these are `NSText`'s selectors, targeting `nil`, which routes them down the responder chain:
        // with the editor focused, `NSTextView`'s own implementations run and the menu validates itself.
        // With the surface focused, `TerminalSurfaceView`'s overrides run, and they say what "select all"
        // means for a terminal — the block you are working in, never the whole scrollback.
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy Output", #selector(TerminalSurfaceView.copy(_:)), key: "c"))
        menu.addItem(
            item(
                "Copy Command", #selector(TerminalSurfaceView.copySelectedCommand(_:)), key: "c",
                modifiers: [.command, .shift]))
        menu.addItem(
            item(
                "Copy Working Directory",
                #selector(TerminalSurfaceView.copySelectedWorkingDirectory(_:)), key: "c",
                modifiers: [.command, .option]))
        menu.addItem(item("Paste", #selector(TerminalSurfaceView.paste(_:)), key: "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", #selector(TerminalSurfaceView.performFind(_:)), key: "f"))
        menu.addItem(item("Find Next", #selector(TerminalSurfaceView.findNext(_:)), key: "g"))
        menu.addItem(
            item(
                "Find Previous", #selector(TerminalSurfaceView.findPrevious(_:)), key: "g",
                modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(
            item("Clear Scrollback", #selector(TerminalSurfaceView.clearScrollback(_:)), key: "k"))
        return submenuItem("Edit", menu)
    }

    private static func viewMenu() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(
            item(
                "Bigger", #selector(TerminalSurfaceView.increaseFontSize(_:)), key: "+",
                modifiers: [.command]))
        menu.addItem(
            item(
                "Smaller", #selector(TerminalSurfaceView.decreaseFontSize(_:)), key: "-",
                modifiers: [.command]))
        menu.addItem(item("Actual Size", #selector(TerminalSurfaceView.resetFontSize(_:)), key: "0"))
        menu.addItem(.separator())
        // The title is set by the window controller's `validateMenuItem` — the item says what it will
        // do, so it reads "Show Sidebar" once the sidebar is hidden.
        menu.addItem(
            item(
                "Hide Sidebar", #selector(TerminalWindowController.toggleSidebar(_:)), key: "b",
                modifiers: [.command, .shift]))
        menu.addItem(.separator())
        // **The chords come from `Keymap`, not from a literal here.** The settings page lists what
        // `Keymap` says and this is the only thing that can make a chord fire, so a literal here would be
        // a second answer to "what is the shortcut for the next tab" — and the two would drift the first
        // time one of them changed. `⌥⌘↓`/`⌥⌘↑`.
        menu.addItem(
            item(
                "Next Tab", #selector(TerminalWindowController.selectNextTab(_:)),
                chord: Keymap.defaultKeymap.shortcut(for: .nextTab)))
        menu.addItem(
            item(
                "Previous Tab", #selector(TerminalWindowController.selectPreviousTab(_:)),
                chord: Keymap.defaultKeymap.shortcut(for: .previousTab)))
        // **The bracket pair as well, and a hidden item is the only way to have a second chord.** A menu
        // item carries exactly one key equivalent, so the alternative is a second row with the same
        // title in the same menu. Hidden, AppKit still matches it — `isHidden` takes the item out of the
        // menu's *drawing*, not out of its key handling — so the extra pair costs no rows.
        //
        // `⇧⌘]`/`⇧⌘[` because they are every tabbed app's and there is no reason to lose them.
        menu.addItem(
            item(
                "Next Tab", #selector(TerminalWindowController.selectNextTab(_:)), key: "]",
                modifiers: [.command, .shift], hidden: true))
        menu.addItem(
            item(
                "Previous Tab", #selector(TerminalWindowController.selectPreviousTab(_:)), key: "[",
                modifiers: [.command, .shift], hidden: true))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Next Pane", #selector(TerminalWindowController.focusNextPane(_:)), key: "]",
                modifiers: [.command, .option]))
        menu.addItem(
            item(
                "Previous Pane", #selector(TerminalWindowController.focusPreviousPane(_:)), key: "[",
                modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                modifiers: [.command, .control]))
        return submenuItem("View", menu)
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Close Window", #selector(NSWindow.performClose(_:)), key: "w",
                modifiers: [.command, .shift]))
        return submenuItem("Window", menu)
    }

    /// The arrow keys as AppKit spells them on a menu item.
    ///
    /// `KeyEquivalent` spells them as words — `"DownArrow"` — and a menu item given the word matches
    /// nothing at all, silently, which is the worst way for a shortcut to fail. This is the one place
    /// that translation happens.
    private static func menuKey(
        for equivalent: KeyEquivalent
    ) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        let key: String
        switch equivalent.key {
        case "UpArrow": key = "\u{F700}"
        case "DownArrow": key = "\u{F701}"
        case "LeftArrow": key = "\u{F702}"
        case "RightArrow": key = "\u{F703}"
        default: key = equivalent.key
        }

        var modifiers: NSEvent.ModifierFlags = []
        if equivalent.modifiers.contains(.command) { modifiers.insert(.command) }
        if equivalent.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if equivalent.modifiers.contains(.option) { modifiers.insert(.option) }
        if equivalent.modifiers.contains(.control) { modifiers.insert(.control) }
        return (key, modifiers)
    }

    private static func item(
        _ title: String, _ action: Selector, chord equivalent: KeyEquivalent, hidden: Bool = false
    ) -> NSMenuItem {
        let translated = menuKey(for: equivalent)
        return item(title, action, key: translated.key, modifiers: translated.modifiers, hidden: hidden)
    }

    private static func item(
        _ title: String, _ action: Selector, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, hidden: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        // Out of the menu's drawing, still in its key handling — see the tab items in `viewMenu`.
        item.isHidden = hidden
        return item
    }

    private static func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
