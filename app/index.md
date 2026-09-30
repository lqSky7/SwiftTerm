# app — index

The application. `src/` holds the composition root and one folder per feature; `assets/` is where a
bundled resource would go.

| Path | Holds |
| --- | --- |
| `src/AppCore.swift` | the composition root — the window's tabs, and one shell per pane |
| `src/AppDelegate.swift` | launch and terminate |
| `src/AppMenus.swift` | the menu bar; every item targets `nil` so it walks the responder chain |
| `src/SwiftTermApp.swift` | `@main`; drives `NSApplication` directly |
| `src/workspace/` | the window: the sidebar, the tab strip, and where the panes go |
| `src/terminal/` | the terminal feature |
| `Info.plist`, `SwiftTerm.entitlements` | read by `Scripts/build-app.sh` when it assembles the bundle |

There is no `assets/` yet: the shell integration scripts are embedded in the binary rather than
shipped beside it, so the protocol and the parser that reads it can never disagree about a version.

The TUI repair uses the existing native terminal surface; build/install leaves the app unopened.

Paste/startup follow-up uses the existing terminal surface and shell bootstrap.

Resource optimization build 103 keeps the native presentation and existing features unchanged.

Block collapse and fullscreen edge repair: build 105 installed without launching.

Active-editor undo/redo is repaired using native per-pane histories; no appearance change.
Web terminal relay, browser input and static sharing remain planning artifacts under `../docs/backend/`.

Apple text assistance is disabled for terminal, Settings, Profile, rename and find inputs.

Startup crash repair: window field-editor lookup never mutates NSTextField, because its content-type
setter re-enters the lookup. Regression fields are attached to a window; user authorized app launch
for crash diagnosis and installed-build verification.
