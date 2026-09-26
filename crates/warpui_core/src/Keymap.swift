import Foundation

/// Modifier flags for keyboard shortcuts. Pure Swift and independent of AppKit.
struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    let rawValue: UInt

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)

    var symbolString: String {
        var str = ""
        if contains(.control) { str += "⌃" }
        if contains(.option) { str += "⌥" }
        if contains(.shift) { str += "⇧" }
        if contains(.command) { str += "⌘" }
        return str
    }
}

/// A key equivalent chord representing a key and its active modifier flags.
struct KeyEquivalent: Hashable, Sendable, Codable {
    var key: String
    var modifiers: KeyModifiers

    init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// User-facing string representation (e.g. `⌘D`, `⇧⌘W`, `⌃Tab`, `⌘↑`).
    var displayString: String {
        let modifierSymbols = modifiers.symbolString
        let keySymbol: String
        switch key {
        case "\t": keySymbol = "Tab"
        case "\r", "\n": keySymbol = "↩"
        case " ": keySymbol = "Space"
        case "UpArrow", "\u{F700}": keySymbol = "↑"
        case "DownArrow", "\u{F701}": keySymbol = "↓"
        case "LeftArrow", "\u{F702}": keySymbol = "←"
        case "RightArrow", "\u{F703}": keySymbol = "→"
        default: keySymbol = key.uppercased()
        }
        return modifierSymbols + keySymbol
    }
}

/// Configurable keyboard actions matching Warp's command palette and shortcut system.
enum KeymapAction: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    // Window & Panes
    case splitPaneHorizontal = "split_pane_horizontal"
    case splitPaneVertical = "split_pane_vertical"
    case closePane = "close_pane"

    // Tabs
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case nextTab = "next_tab"
    case previousTab = "previous_tab"

    // Navigation & Blocks
    case jumpPreviousBlock = "jump_previous_block"
    case jumpNextBlock = "jump_next_block"
    case toggleSidebar = "toggle_sidebar"

    // Terminal Operations
    case clearBuffer = "clear_buffer"
    case find = "find"
    case openSettings = "open_settings"

    // Editing
    case copy = "copy"
    case paste = "paste"
    case openCompletion = "open_completion"

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case windowAndTabs = "Window & Tabs"
        case navigation = "Navigation"
        case terminal = "Terminal"
        case editing = "Editing"
    }

    var category: Category {
        switch self {
        case .splitPaneHorizontal, .splitPaneVertical, .closePane, .newTab, .closeTab, .nextTab, .previousTab:
            return .windowAndTabs
        case .jumpPreviousBlock, .jumpNextBlock, .toggleSidebar:
            return .navigation
        case .clearBuffer, .find, .openSettings:
            return .terminal
        case .copy, .paste, .openCompletion:
            return .editing
        }
    }

    var title: String {
        switch self {
        case .splitPaneHorizontal: return "Split Pane Right"
        case .splitPaneVertical: return "Split Pane Down"
        case .closePane: return "Close Active Pane"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .jumpPreviousBlock: return "Jump to Previous Block"
        case .jumpNextBlock: return "Jump to Next Block"
        case .toggleSidebar: return "Toggle Sidebar"
        case .clearBuffer: return "Clear Terminal Buffer"
        case .find: return "Find in Terminal"
        case .openSettings: return "Open Settings"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .openCompletion: return "Open Autocomplete Menu"
        }
    }

    var defaultKeyEquivalent: KeyEquivalent {
        switch self {
        case .splitPaneHorizontal:
            return KeyEquivalent(key: "d", modifiers: [.command])
        case .splitPaneVertical:
            return KeyEquivalent(key: "d", modifiers: [.shift, .command])
        case .closePane:
            return KeyEquivalent(key: "w", modifiers: [.command])
        case .newTab:
            return KeyEquivalent(key: "t", modifiers: [.command])
        case .closeTab:
            return KeyEquivalent(key: "w", modifiers: [.shift, .command])
        // `⌥⌘↓`/`⌥⌘↑` rather than the bracket pair every tabbed app uses, and the arrow pair is the one
        // a terminal can spare: `⌘↑`/`⌘↓` are already the block jumps, and this is the same gesture one
        // modifier further out, which is what moving through a list is. The brackets are not lost — the
        // menu carries them as hidden alternates, because a menu item has room for exactly one.
        case .nextTab:
            return KeyEquivalent(key: "DownArrow", modifiers: [.command, .option])
        case .previousTab:
            return KeyEquivalent(key: "UpArrow", modifiers: [.command, .option])
        case .jumpPreviousBlock:
            return KeyEquivalent(key: "UpArrow", modifiers: [.command])
        case .jumpNextBlock:
            return KeyEquivalent(key: "DownArrow", modifiers: [.command])
        case .toggleSidebar:
            return KeyEquivalent(key: "b", modifiers: [.shift, .command])
        case .clearBuffer:
            return KeyEquivalent(key: "k", modifiers: [.command])
        case .find:
            return KeyEquivalent(key: "f", modifiers: [.command])
        case .openSettings:
            return KeyEquivalent(key: ",", modifiers: [.command])
        case .copy:
            return KeyEquivalent(key: "c", modifiers: [.command])
        case .paste:
            return KeyEquivalent(key: "v", modifiers: [.command])
        case .openCompletion:
            return KeyEquivalent(key: "\t", modifiers: [])
        }
    }
}

/// The active keymap table resolving actions from keys or custom overrides.
struct Keymap: Hashable, Sendable, Codable {
    var overrides: [KeymapAction: KeyEquivalent] = [:]

    init(overrides: [KeymapAction: KeyEquivalent] = [:]) {
        self.overrides = overrides
    }

    /// Resolves the effective key equivalent for an action.
    func shortcut(for action: KeymapAction) -> KeyEquivalent {
        overrides[action] ?? action.defaultKeyEquivalent
    }

    /// Resolves which action matches a given key chord, if any.
    func action(for key: String, modifiers: KeyModifiers) -> KeymapAction? {
        let normalizedKey = key.lowercased()
        for action in KeymapAction.allCases {
            let chord = shortcut(for: action)
            if chord.key.lowercased() == normalizedKey && chord.modifiers == modifiers {
                return action
            }
        }
        return nil
    }

    /// Default keymap with all system factory settings.
    static let defaultKeymap = Keymap()
}
