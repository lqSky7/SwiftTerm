# crates/warpui_core — index

The shared UI framework. Anything more than one feature needs to draw with goes here; anything only
one feature needs stays with that feature.

| Path | Holds |
| --- | --- |
| `src/Theme.swift` | the design tokens: spacing, radius, sizes, type, the chrome alpha ramp |
| `src/VisualEffectView.swift` | `NSVisualEffectView` in SwiftUI — the one thing SwiftUI's materials cannot do |
