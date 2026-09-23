---
name: tinycast-swift-rules
description: >
  Enforces Tinycast's modern Swift engineering standards: macOS 26+ posture, Swift 6 language mode, Liquid Glass & vibrancy UI conventions, pure Model-layer boundaries, grouped Settings hierarchies, and standalone test harness patterns. Use whenever writing, refactoring, reviewing, or designing native Swift macOS apps.
---

# Tinycast Swift Rules & Architecture Skill

Guidance and non-negotiables distilled from the `Tinycast` codebase for building high-performance, native macOS 26+ applications using modern Swift, SwiftUI, AppKit, and Liquid Glass.

---

## 1. Posture: Latest-Only, Always

- **Target macOS 26+ only.** Xcode 26 toolchain, Swift 6 language mode.
- **Zero backwards compatibility.** No compatibility shims, no deprecation debt, no legacy workarounds, no version checks (`#available(macOS 15, *)` is banned — assume macOS 26).
- **Prefer modern Apple APIs:**
  - `@Observable` macro — never `ObservableObject`, `@ObservedObject`, or `@Published`.
  - Swift Concurrency (`async`/`await`, structured concurrency) — never `DispatchQueue`, `OperationQueue`, or completion handlers.
  - `SMAppService` — never legacy login item lists.
- **Migrate, never wrap.** When an API gains a modern successor, migrate immediately and delete the old call site.
- **A deprecated API is a defect**, not a warning to live with.

---

## 2. Architectural Boundaries & Feature Organization

- **Feature Directory Structure:**
  ```
  Features/<FeatureName>/
    ├── Model/       # 100% PURE SWIFT (zero UI imports)
    ├── Service/     # Effects, IO, system interactions
    ├── UI/          # SwiftUI views & Coordinator
    └── Settings/    # Feature-owned Settings panes
  ```
- **The Pure Model Invariant (CRITICAL):**
  - Files under `Features/*/Model/` **MUST NEVER** import `AppKit`, `SwiftUI`, or `Cocoa`.
  - Every environment dependency (clock, filesystem, home directory, rates) must be injected as parameters.
  - Verified by: `grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Features/*/Model/` (must return nothing).
- **Ownership & State:**
  - Single composition root: `AppCore` owns long-lived state. No competing singletons.
  - Views reach a feature's **Coordinator** through `@Environment`, never by reaching into `AppCore`.

---

## 3. Naming Conventions (Semantic Suffixes)

A type's suffix strictly denotes its responsibility:

| Suffix | Responsibility |
| --- | --- |
| `Store` | Owns persisted state and publishes it. |
| `Repository` | File semantics a Store does not imply (conflict checks, revisions). |
| `Coordinator` | A feature's action surface called by AppCore and views. |
| `Controller` | Owns one AppKit window, panel, or surface. |
| `Presenter` | Presentation policy across surfaces (auto-dismiss, fade). |
| `Manager` | Lifecycle *and* policy of a subsystem (use sparingly). |
| `Service` | Stateless capability other types call. |
| `Provider` | Supplies values on demand, owning no policy. |
| `Monitor` | Watches an external stream and reports changes. |
| `Scanner` | Reads filesystem to produce candidates. |
| `Runner` | Performs one effectful operation on request. |
| `Session` | Transient state for one in-progress interaction. |
| `State` | Shared observable state that persists nothing itself. |
| `Catalog` | Pure static namespace over a built-in list. |
| `Index` | A searchable collection rebuilt as inputs change. |
| `Engine` | Pure evaluator: input → output. |
| `Policy` | Pure decision — no state, no effects. |

*Note: `ViewModel` and `Registry` are banned.*

---

## 4. Swift Style & Comment Standards

- **Early returns over nesting:** `guard` at the top beats an `if` wrapping the body.
- **Single Responsibility:** If a function needs a section comment, split it into two functions.
- **Views stay declarative and thin:** Business logic lives in models, stores, or coordinators. A `body` that decides things is a defect.
- **Single-Line Comments Only:**
  1. **Exactly one line.** Never two consecutive comment lines.
  2. **Hard cap 100 characters** including indentation.
  3. Comment the *why*, the gotcha, or the invariant. Never narrate the code or explain what you just changed.
  4. Prefer deleting a comment over updating it.

---

## 5. Concurrency & Lifetime (Swift 6)

- **`@MainActor` is the default.** Assume main actor unless there is an explicit reason.
- **Heavy / IO work goes off-main:** Pure `nonisolated static` functions driven by `Task.detached`.
- **No custom actors** unless strictly justified.
- **Cross-actor models must be `Sendable`.**
- **No `MainActor.assumeIsolated`** (traps at runtime if wrong).
- **Long-lived tasks must be owned:** Store in a variable and cancel in `deinit` or `stop()`.
- **Observation rules:**
  - `@ObservationIgnored` on memo caches and lazily built collaborators.
  - Never write a type annotation on `@Environment` for an `@Observable` type.

---

## 6. UI & Liquid Glass Design System (macOS 26+)

- **Liquid Glass Materials:**
  - On macOS 26+, vibrancy materials render with Liquid Glass.
  - Apply `.glassEffect(.regular, in: shape)` or `.glassEffect(.regular.interactive().tint(...), in: shape)`.
  - **Glass is for floating controls** (action pills, menu circles, popovers, modal dialog roots). The main window surface is NOT glass; it uses behind-window blur under a scrim (`panelScrim` over `VisualEffectView`).
- **One Alpha Ramp, Never Grays:**
  - Depth comes from desktop transparency.
  - Use fixed white-alpha ramps on dark mode, black-alpha ramps on light mode (`Theme.Colors.ramp(dark:light:)`).
- **Concentric Corners Rule:**
  - Where two rounded corners sit adjacent: `innerRadius = outerRadius - gap`.
- **Always Continuous Corners:**
  - `RoundedRectangle(cornerRadius: r, style: .continuous)` — never `.circular`.
- **No Native `NSAlert`:** Build native SwiftUI dialogs and HUDs.

---

## 7. Settings Page Hierarchy & Design

- **Dedicated `NSWindow`:** Avoid SwiftUI's accessory `Settings` scene; host a custom `NSWindow`.
- **Keep System Titlebar:** Set `titlebarAppearsTransparent = false` so AppKit draws the native glass band and scroll edge effect as content scrolls underneath.
- **Grouped Form Structure:**
  - Root container: `Form` with `.formStyle(.grouped)`.
  - Sections: `Section(header: Text(...), footer: Text(...))` for native card styling.
- **Controls & Components:**
  - Use `SettingsRow` instead of `LabeledContent` when trailing controls have custom interactions (e.g. shortcut recorders), because `LabeledContent` wraps values in a selectable text field that swallows click events.
  - Use `.settingsEnabled(bool)` which dims as well as disables (standard `.disabled` leaves titles at full opacity).
  - Swap `TextEditor` for `Text` when read-only (macOS `NSTextView` ignores `.disabled`).
- **Deep Search & Anchor Revealing:**
  - `SettingsSearchField` in the sidebar with fuzzy multi-term matching.
  - Hand-written `SettingsSearchCatalog` linking keywords to `SettingsAnchor`.
  - Selecting a search result scrolls to the anchor (`.settingsScrollTarget()`) and triggers a non-disruptive pulse pill (`SettingsRowTitle` with `Colors.searchFlash`).

---

## 8. Test Harness Philosophy (No XCTest)

- **No XCTest Target:** Testing uses standalone `.swift` harness files in `Tests/`.
- **Direct Source Compilation:** Each harness compiles the shipped production code directly with `swiftc` via `./Scripts/run-tests.sh`.
- **Compile-Time Architectural Gate:** If UI code leaks into `Model/`, the standalone harness fails to compile.
- **Isolation:** Tests run in your live user session; they must never mutate shared system state (e.g. use `NSPasteboard.withUniqueName()`, not `NSPasteboard.general`).
- **Definition of Done:**
  1. `./Scripts/run-tests.sh` passes.
  2. Zero new compiler warnings.
  3. `./Scripts/lint.sh` clean.
  4. `grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Features/*/Model/` returns empty.
  5. Documentation updated in the same commit.
