# crates/warpui_core/src — index

| File | Holds |
| --- | --- |
| `Theme.swift` | every design token. A view that invents its own padding is how a design system rots. |
| `ChromeSettings.swift` | the window chrome's numbers — sidebar width, panel margin, glass opacity, materials (including `.none`) — with the range each is clamped to, and their tolerant decoding |
| `Keymap.swift` | shortcut definitions, key equivalents, modifier sets, action mappings, and default bindings |
| `SettingsStore.swift` | the versioned settings document (chrome, themes, custom keymaps) and the `UserDefaults` it is kept in |
| `VisualEffectView.swift` | behind-window blur, which SwiftUI's own materials cannot express |

The terminal's own colours are deliberately *not* here. A terminal's palette is its content, not its
chrome, so it lives with the terminal in `crates/warp_terminal/src/model/TerminalPalette.swift`.

`ChromeSettings`, `Keymap`, and `SettingsStore` are the files in this folder that are **not** view-layer files, and
the split is deliberate rather than tidiness: they are `Foundation`-only, so the harnesses compile them and a
harness can hold the ranges, the clamping, shortcut resolution, and what happens to a settings file written by another build.
`Theme.swift` beside them imports AppKit and is not compiled by the harnesses. That is why
`Scripts/run-tests.sh` names these files individually instead of globbing the directory — a glob would let a UI
framework into the harnesses through the back door — and `Scripts/lint.sh` names them the same way.

A value that has a range belongs here and not in `Theme`, because a range is a decision with two ends
that have to agree, and the view that draws the slider is the last place that can be checked.
