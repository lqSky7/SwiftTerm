import Foundation

/// One row of the grid. `isWrapped` records that the next row is a continuation of this one
/// rather than a new logical line, which is what lets a copy or a reflow rejoin them.
struct TerminalLine: Hashable, Sendable {
    var cells: [TerminalCell]
    var isWrapped: Bool = false

    init(columns: Int) {
        cells = Array(repeating: .blank, count: max(0, columns))
    }

    init(cells: [TerminalCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }

    var columnCount: Int { cells.count }

    var isBlank: Bool { cells.allSatisfy(\.isBlank) }

    mutating func resize(columns: Int) {
        guard columns != cells.count else { return }
        if columns < cells.count {
            cells.removeLast(cells.count - columns)
        } else {
            cells.append(contentsOf: Array(repeating: .blank, count: columns - cells.count))
        }
    }

    mutating func erase() {
        for index in cells.indices { cells[index] = .blank }
        isWrapped = false
    }

    /// The row as text. Trailing blanks are dropped unless a caller is reconstructing a
    /// wrapped logical line, where the padding is load-bearing.
    func string(trimmingTrailingBlanks: Bool = true) -> String {
        var text = ""
        // A cell with no text is a blank, not a gap: erasing clears the text but the column
        // still occupies a space, and a copy that dropped it would collapse the layout.
        for cell in cells where !cell.isContinuation { text += cell.text.isEmpty ? " " : cell.text }
        guard trimmingTrailingBlanks else { return text }
        while let last = text.last, last == " " { text.removeLast() }
        return text
    }
}
