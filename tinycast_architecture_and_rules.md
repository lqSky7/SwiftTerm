# Tinycast Architecture, Swift Development Rules & Design System

A comprehensive deep-dive into the engineering standards, macOS 26+ posture, Liquid Glass UI conventions, grouped Settings hierarchy, and standalone test harness architecture extracted from the **Tinycast** codebase.

---

## 1. Swift Development Posture: Latest-Only, Always

### Single OS Target & Zero Deprecation Debt
* **Target:** macOS 26+ exclusively. Xcode 26 toolchain, Swift 6 language mode.
* **No Compatibility Floors:** There are zero shims, zero version flags (`#available(macOS ...)` is avoided; macOS 26 is the baseline), and zero backwards-compatibility fallbacks.
* **Core Principle:** *"Write code as if the platform released yesterday."* The codebase carries no migration scaffolding. A compatibility floor is an enduring maintenance tax: every shim outlives its platform and turns a one-line call into un-deletable bloat.

### Mandatory Modern Apple APIs
| Legacy / Deprecated Pattern (Banned) | Modern Replacement (Mandatory) | Rationale |
| --- | --- | --- |
| `ObservableObject` / `@Published` | `@Observable` macro | Cleaner observation, granular per-property dependency tracking. |
| `DispatchQueue` / `OperationQueue` | Swift Structured Concurrency (`async`/`await`) | Compile-time data-race safety, cooperative task cancellation. |
| Completion handlers / callbacks | `async throws` | Eliminates pyramid of doom and unhandled error states. |
| `LSSharedFileList` / AppleScript login | `SMAppService` | Native, sandboxed macOS service registration. |
| `NSAlert` / System Popovers | Custom SwiftUI Dialogs / HUDs | Uniform glass styling, prevents modal run-loop blocking. |

---

## 2. Architecture & Layer Boundaries

### Directory Structure & Responsibilities
Every feature in Tinycast is isolated in its own folder under `Tinycast/Features/<FeatureName>/`:
```
Features/<FeatureName>/
  ├── Model/       # 100% Pure Swift (Zero UI imports)
  ├── Service/     # Effects, IO, file operations, system runners
  ├── UI/          # SwiftUI views & feature Coordinator
  └── Settings/    # Feature-owned Settings panes
```

### The Pure Model Invariant (Enforced at Compile Time)
* **Rule:** A file under `Features/*/Model/` **may not import AppKit, SwiftUI, or Cocoa**.
* **Dependency Injection:** Every environmental fact (system clock, filesystem paths, home directory, locale, rate tables) must be passed as an explicit injected parameter.
* **Why it matters:** Pure models can be compiled standalone by test harnesses in milliseconds without spinning up AppKit or window servers.
* **Mechanical check:**
  ```bash
  grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/
  ```
  *(Must return 0 files).*

### Ownership Hierarchy & Single Composition Root
* **`AppCore` is the Sole Root:** All long-lived state belongs to `AppCore` and is wired in `start()`. Creating competing singletons is forbidden.
* **Coordinators:** Views communicate with a feature through that feature's **Coordinator** injected via `@Environment`, never by querying `AppCore` directly.
* **Confirmation Gates:** Security checks ("Are you sure you want to run this shell script?") live in the Coordinator, keeping the underlying `Runner` pure and headless-testable.

---

## 3. Naming Conventions (Semantic Suffix Matrix)

A type's suffix dictates its architectural responsibility. Semantic correctness always trumps suffix consistency:

| Suffix | Responsibility | Example in Tinycast |
| --- | --- | --- |
| `Store` | Owns persisted state on disk and publishes it. | `ClipboardStore`, `AISettingsStore` |
| `Repository` | File semantics with conflict detection and revisions. | `NotesRepository` |
| `Coordinator` | A feature's action surface, called by views & AppCore. | `LauncherCoordinator`, `SettingsCoordinator` |
| `Controller` | Owns an AppKit window, panel, or screen surface. | `PalettePanelController`, `DialogController` |
| `Presenter` | Owns presentation policies (fade, auto-dismiss, stacks). | `HUDPresenter`, `SettingsEditorPresenter` |
| `Manager` | Owns a subsystem's entire lifecycle *and* policy (rare). | `ClipboardManager`, `HotKeyManager` |
| `Service` | A stateless capability or system client. | `RaycastDecoder`, `AppleShortcutService` |
| `Provider` | Supplies values on demand without policy. | `RecentAppsProvider` |
| `Monitor` | Watches an external system stream and reports updates. | `IconStyleMonitor`, `ActiveAppMonitor` |
| `Scanner` | Walks directories/filesystem to yield candidates. | `ApplicationScanner`, `SettingsPaneScanner` |
| `Runner` | Executes a single effectful operation. | `ShellCommandRunner`, `SystemActionRunner` |
| `Session` | Ephemeral state for an in-progress interaction. | `FileSearchSession` |
| `State` | Shared observable state that persists nothing. | `PaletteState`, `SettingsNavigationState` |
| `Catalog` | Pure static namespace over a built-in collection. | `EmojiCatalog`, `SettingsSearchCatalog` |
| `Index` | Searchable in-memory collection rebuilt on changes. | `EmojiIndex` |
| `Engine` | Pure evaluator: transforms input into output. | `WindowPlacementEngine`, `CalcEngine` |
| `Policy` | Pure decision-making rule with no state or effects. | `NoteRevealPolicy` |

*Note: `ViewModel` and `Registry` are explicitly retired.*

---

## 4. Swift Coding Style & Comment Standard

### Swift 6 Idioms
* **Early returns over nesting:** A top-level `guard` statement always beats an `if` block wrapping the function body.
* **Immutability:** Use `let` unless local mutation is strictly required. No abbreviated identifiers (`index`, never `idx`).
* **Thin Views:** Views are purely declarative render trees. Business logic, filtering, and state transitions belong in Models, Stores, or Coordinators.
* **Error Handling:** Errors surface through `DialogController` (actionable user questions) or `MessageHUDController` (transient readouts). Never use raw `print()`, and never use silent `try?` on paths the user cares about.

### The 1-Line Comment Rule
Comments have a high maintenance cost. Tinycast enforces strict brevity:
1. **Exactly one line.** Never two consecutive comment lines. If a thought requires two lines, extract a named helper function, constant, or type.
2. **Hard cap of 100 characters** (including indentation).
3. **Comment the *why* only:** Gotchas, hardware quirks, or invariants. Never narrate *what* the code does.
4. **Delete rather than update:** Stale comments are worse than no comments.
5. **No change narration:** Never write comments explaining what a recent diff changed.

---

## 5. Concurrency & Lifetimes (Swift 6 Data-Race Safety)

* **`@MainActor` as Default:** Nearly every UI-connected class or coordinator runs on `@MainActor`.
* **Off-Main Heavy Work:** Disk scanning, image decoding, JSON parsing, and shell executions are executed as `nonisolated static` pure functions spawned via `Task.detached`.
* **No Custom Actors:** Avoid introducing secondary actors; keep the boundary clean between `@MainActor` and `nonisolated` workers.
* **Sendable Types:** All types crossing concurrency boundaries must conform to `Sendable`. `@unchecked Sendable` or `nonisolated(unsafe)` require a written rationale.
* **Task Lifetimes:** Any long-running `Task` must be stored and explicitly cancelled in `deinit` or `stop()`. An unowned task is a leak.
* **Observation Traps:**
  * `@ObservationIgnored` must be applied to memoization caches and lazily built collaborators; otherwise, reading the memo registers an observation dependency, causing infinite view refresh loops.
  * `withObservationTracking`'s `onChange` closure is a `willSet` hook (fires *before* the write completes). Re-reading must be deferred into a `Task`.

---

## 6. Liquid Glass UI & Design System (macOS 26+)

### The Five Load-Bearing Design Rules
1. **Surface = Scrim over Behind-Window Blur:** No solid opaque backgrounds. Depth comes from desktop transparency (`panelScrim` over `NSVisualEffectView`).
2. **One Alpha Ramp, Never Grays:** UI ink is white with fixed opacity stops on Dark appearance, and black with matched stops on Light appearance (`Theme.Colors.ramp(dark:light:)`).
3. **Floating Bars, Not Chrome:** Header and footer are transparent overlays (`safeAreaInset`); content fills the entire window frame.
4. **Edges Dissolve, They Don't Clip:** Lists use scroll-driven gradient masks (`edgeDissolve()` / `overflowFade()`) so items ghost out under floating bars without hard separator lines.
5. **Glass Only on Floating Controls:** The main window background is NOT glass. Liquid Glass (`.glassEffect()`) is reserved for floating elements: action pills, circular buttons, popovers, and modal dialog roots.

### Liquid Glass Implementation
On macOS 26+, Apple renders vibrancy materials with Liquid Glass:
```swift
// Floating glass control (action capsule / button)
.glassEffect(.regular, in: shape)

// Frosted interactive glass surface
.glassEffect(.regular.interactive().tint(Theme.Colors.glassFrost), in: shape)
```

### Concentric Rounded Corners
* **Mathematical Rule:** Where two rounded corners sit adjacent and are seen together:
  $$\text{Inner Radius} = \text{Outer Radius} - \text{Gap}$$
  *Example:* Inside a menu, `menuPanel` radius is `16pt`, gap is `Spacing.sm (6pt)`, so `menuRow` radius is exactly `10pt` ($16 - 6 = 10$).
* **Continuous Corners:** Always use `RoundedRectangle(cornerRadius: r, style: .continuous)`. Never use `.circular`.

---

## 7. Settings Page Hierarchy & Design System

### Window & Titlebar Architecture
* **Dedicated `NSWindow`:** Avoids the standard SwiftUI `Settings` scene (which behaves unreliably for menu-bar accessory apps).
* **Retains System Titlebar:** Unlike borderless palette panels, the Settings window sets `titlebarAppearsTransparent = false`. This allows AppKit to draw the native glass header band and scroll edge effect automatically as the pane content scrolls underneath.
* **Full-Size Content View:** Window uses `.fullSizeContentView` with `titlebarSeparatorStyle = .none` so pane content scrolls smoothly under the titlebar without harsh dividing lines.

### Visual Style: Grouped Forms
* Every settings pane is a native SwiftUI `Form` with:
  ```swift
  .formStyle(.grouped)
  ```
* This renders native macOS System Settings cards, rounded grouped sections, system-drawn hairlines, and automatic dark/light background adaptation.

### Settings Navigation Hierarchy
Settings are organized into 4 logical sections containing 22 feature tabs:

```
SettingsSection
├── General
│   ├── .general         # Launch on login, hotkey, appearance, interface scale
│   └── .permissions     # Accessibility, screen recording, input monitoring
├── Launcher
│   ├── .applications    # App search scopes, aliases, hide rules
│   ├── .systemSettings  # macOS preference pane search
│   ├── .systemActions   # Sleep, lock, restart, volume triggers
│   ├── .commands        # Built-in terminal command list
│   ├── .quicklinks      # Custom URL schemes & web queries
│   ├── .appleShortcuts  # Siri Shortcuts integration
│   └── .fallbacks       # Default search fallbacks (Google, DuckDuckGo)
├── Features
│   ├── .clipboard       # History retention, secret masking, OCR
│   ├── .snippets        # Auto-expansion keywords, delimiters
│   ├── .fileSearch      # Spotlight indices, excluded folders
│   ├── .windowManagement# Snapping zones, hotkeys, grid margins
│   ├── .navigation      # Window switcher, active app toggles
│   ├── .notes           # Floating scratchpad, markdown options
│   ├── .calendar        # Event preview, meeting join shortcuts
│   ├── .emoji           # Skin tone, frequent emoji memory
│   ├── .ai              # Local/cloud LLM providers, temperature
│   ├── .quickActions    # Context-menu actions over selected text
│   └── .extensions      # Community extension runner & JS runtime
└── Advanced
    ├── .backup          # Export/import encrypted settings backup
    └── .about           # Version, release notes, license, links
```

### Specialized Settings Components (`DesignSystem/SettingsComponents.swift`)

1. **`SettingsRow` (Why `LabeledContent` is Banned for Custom Controls):**
   * Standard SwiftUI `LabeledContent` wraps trailing values in an internal selectable text field. This absorbs mouse clicks and prevents custom controls (like `ShortcutRecorder`) from receiving tap events.
   * `SettingsRow` lays out icon, title, subtitle, and trailing control without swallowing clicks.
2. **`.settingsEnabled(_:)` Modifier:**
   * Dims opacity to `0.45` as well as applying `.disabled()`. Standard `.disabled()` leaves text labels at full opacity, making disabled rows look broken rather than inactive.
3. **`TextEditor` Read-Only Workaround:**
   * On macOS, `TextEditor` (backed by `NSTextView`) completely ignores `.disabled()`. Users can still focus, type, and select text. Tinycast swaps `TextEditor` for a plain `Text` view when read-only.
4. **`FeatureSwitchSection`:**
   * Standardized component for a feature's master enable toggle paired with its "Show in launcher" checkbox.

### Deep Search & Anchor Scroll Reveal System
* **Two Sidebar Lists:** The sidebar hosts a `SettingsSearchField`. Typing swaps the navigation list for a ranked search result list (`SettingsSearchEntry`).
* **Type-Safe `SettingsAnchor`:**
  * Every row or section registers a `SettingsAnchor(tab: .clipboard, id: "historyLimit")`.
  * `SettingsSearchCatalog` maps search queries to anchors. Because anchors embed their parent `SettingsTab`, mismatched row-tab mappings fail at compile time.
* **Scroll & Pulse Reveal:**
  * When a user selects a search result, `SettingsNavigationState` selects the tab, scrolls the row into view via `.settingsScrollTarget()`, and pulses a non-disruptive highlight pill (`SettingsRowTitle` with `Colors.searchFlash`) over the row's label.

---

## 8. Standalone Test Harness Architecture (No XCTest)

### Why Tinycast Eliminates XCTest
1. **Speed:** XCTest carries heavy bundle-loading, test-runner, and runtime overhead. Standalone harnesses execute in parallel in under 15 seconds.
2. **Enforces Layer Purity:** Harnesses compile the **shipped production source files directly** using `swiftc`. If someone accidentally imports `AppKit` or `SwiftUI` into a `Model/` file, the standalone harness fails to compile immediately.
3. **Zero Test Target Bloat:** Tests are plain `.swift` scripts inside `Tests/` with simple assertions.

### How Harnesses Run (`./Scripts/run-tests.sh`)
* The runner script compiles and executes each harness in parallel across available CPU cores (`hw.ncpu`).
* Example harness compilation:
  ```bash
  swiftc -O -I build/intermediates Tests/calc-test.swift \
    Tinycast/Features/Calculator/Model/*.swift \
    -o /tmp/calc-test && /tmp/calc-test
  ```

### Live Machine Isolation Rules
Harnesses run directly in the user's active macOS login session without sandbox isolation. They must never pollute the developer's system state:
* **Pasteboard:** Never write to `NSPasteboard.general` (which would trigger the running app to log fake clipboard items). Use `NSPasteboard.withUniqueName()`.
* **Filesystem:** Always root test scratch files under `FileManager.default.temporaryDirectory` with UUID subdirectories.
* **Preferences:** Use isolated `UserDefaults(suiteName: UUID().uuidString)`.

### Definition of Done Checklist
Before any feature or bugfix is marked complete, all five gates must pass locally:
1. `./Scripts/run-tests.sh` passes 100%.
2. Clean Debug build with **zero new compiler warnings**.
3. `./Scripts/lint.sh` passes with zero violations.
4. Pure Model grep returns zero UI imports:
   ```bash
   grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/
   ```
5. All accompanying documentation updated in the same commit.
