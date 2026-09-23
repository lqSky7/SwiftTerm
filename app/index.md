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
