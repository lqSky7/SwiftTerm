import Foundation

/// The grid's dimensions, and the pixel geometry that goes with them.
///
/// Pixels are carried here rather than derived in the UI because `TIOCSWINSZ` is what tells a
/// full-screen program how big the window really is, and only the app knows that.
struct TerminalSize: Hashable, Sendable {
    var columns: Int
    var rows: Int
    var cellWidth: Int = 0
    var cellHeight: Int = 0

    static let fallback = TerminalSize(columns: 80, rows: 24)

    var pixelWidth: Int { columns * cellWidth }
    var pixelHeight: Int { rows * cellHeight }

    /// A grid never has a zero dimension: a zero would divide by zero in every layout
    /// calculation downstream, and the PTY rejects it.
    var normalized: TerminalSize {
        TerminalSize(
            columns: max(1, columns), rows: max(1, rows),
            cellWidth: cellWidth, cellHeight: cellHeight)
    }
}
