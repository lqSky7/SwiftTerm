# crates/warpui_core/src — index

| File | Holds |
| --- | --- |
| `Theme.swift` | every design token. A view that invents its own padding is how a design system rots. |
| `ChromeSettings.swift` | the window chrome's numbers — sidebar width, panel margin, glass opacity, materials (including `.none`), chip background material (`.thinMaterial`, `.glass`) — with the range each is clamped to, and their tolerant decoding |
| `Keymap.swift` | shortcut definitions, key equivalents, modifier sets, action mappings, and default bindings |
| `SettingsStore.swift` | the versioned settings document (chrome, themes, custom keymaps, saved custom commands) and the `UserDefaults` it is kept in |
| `VisualEffectView.swift` | behind-window blur, which SwiftUI's own materials cannot express |
| `TextIntelligence.swift` | turning macOS's text intelligence — autocorrection, substitutions, completion, prediction, Writing Tools, and the AutoFill service behind them — off on the app's text views |

The terminal's own colours are deliberately *not* here. A terminal's palette is its content, not its
chrome, so it lives with the terminal in `crates/warp_terminal/src/model/TerminalPalette.swift`.

`ChromeSettings`, `Keymap`, and `SettingsStore` are the files in this folder that are **not** view-layer files, and
the split is deliberate rather than tidiness: they are `Foundation`-only, so the harnesses compile them and a
harness can hold the ranges, the clamping, shortcut resolution, and what happens to a settings file written by another build.
`Theme.swift` beside them imports AppKit and is not compiled by the harnesses — and neither is
`TextIntelligence.swift`, which is AppKit extensions and nothing else. That is why
`Scripts/run-tests.sh` names these files individually instead of globbing the directory — a glob would let a UI
framework into the harnesses through the back door — and `Scripts/lint.sh` names them the same way.

A value that has a range belongs here and not in `Theme`, because a range is a decision with two ends
that have to agree, and the view that draws the slider is the last place that can be checked.

**`TextIntelligence.swift` is the one file here that is not a token and not a model**, and it is here
rather than in a feature because two features need it: the terminal's editor and find bar, and the
sidebar's rename field. A feature may not import another feature, so a shared answer to "what should
macOS be allowed to do to this text view" has to live below both of them.
