import Foundation

/// The cursor's shape, as `DECSCUSR` (`CSI n q`) selects it.
struct TerminalCursorStyle: Hashable, Sendable {
    enum Shape: Hashable, Sendable {
        case block
        case bar
        case underline
    }

    var shape: Shape = .block
    var blinks = true

    /// `CSI Ps SP q`. Even numbers are steady, odd numbers blink; 0 restores the default, and the
    /// default blinks — which `parameter % 2 == 1` alone gets wrong, because `0 % 2` is not 1.
    init(decscusr parameter: Int) {
        guard (0...6).contains(parameter) else { return }
        blinks = parameter == 0 || parameter % 2 == 1
        switch parameter {
        case 0, 1, 2: shape = .block
        case 3, 4: shape = .underline
        default: shape = .bar
        }
    }

    init(shape: Shape = .block, blinks: Bool = true) {
        self.shape = shape
        self.blinks = blinks
    }
}
