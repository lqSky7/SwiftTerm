import SwiftUI

/// Pointer-hover state for a single control, held in an object rather than `@State` because `@State` is
/// a macro and the Command Line Tools toolchain ships no `SwiftUIMacros` plugin to expand it.
final class HoverState: ObservableObject {
    @Published var isHovered = false
}
