# app/src — index

| Path | Holds |
| --- | --- |
| `AppCore.swift` | composition root; owns one window's tabs and one shell per pane |
| `AppDelegate.swift` | application lifecycle; owns one `AppCore` per open window, so `⌘N`/Dock "New Window" can start another |
| `AppMenus.swift` | the menu bar |
| `SwiftTermApp.swift` | `@main` |
| `workspace/` | the window as a whole: the sidebar, the tab strip, where the panes go |
| `terminal/` | the terminal feature: its session, its views |

`workspace/` composes `terminal/` rather than the other way round: a pane is a terminal, and a
workspace is what decides how many of them there are and where they sit. Nothing in `terminal/`
knows that a sidebar exists.
