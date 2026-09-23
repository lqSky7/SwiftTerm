import Foundation

/// A range of text selected in the grid.
///
/// The grid is a rectangle of cells with no notion of lines, words or paragraphs, so a selection is two cells — and
/// everything derived from them is arithmetic. That arithmetic is what this holds, so a harness can drive it: which
/// end comes first in reading order, which columns a row covers, and what text the whole thing is.
///
/// A *point* is a body line of a block rather than a grid row, because a block's body is several grids — the command
/// and then the output — and a selection that knew about grids would break the moment a block was folded or a
/// command had more than one line. `Block.gridLine(forBodyLine:)` is the one place that mapping lives.
struct TextSelection: Equatable {
    /// A cell: which block, which line of that block's body, which column.
    struct Point: Equatable, Comparable {
        var blockIndex: Int
        var bodyLine: Int
        var column: Int

        /// Reading order: down the document, then across the line.
        static func < (lhs: Point, rhs: Point) -> Bool {
            if lhs.blockIndex != rhs.blockIndex { return lhs.blockIndex < rhs.blockIndex }
            if lhs.bodyLine != rhs.bodyLine { return lhs.bodyLine < rhs.bodyLine }
            return lhs.column < rhs.column
        }
    }

    /// Where the drag started. Fixed for the whole gesture.
    var anchor: Point
    /// Where it is now. This is the end that moves.
    var focus: Point

    /// Whether the drag went backwards, which the caller needs to know when it extends the selection by keyboard.
    var isReversed: Bool { focus < anchor }

    /// The two ends in reading order.
    var start: Point { min(anchor, focus) }
    var end: Point { max(anchor, focus) }

    /// The selection collapsed to nothing, which is a click rather than a drag.
    var isEmpty: Bool { anchor == focus }

    /// The columns a body line covers, or nil when the line is not in the selection.
    ///
    /// Three cases, and the third is the one that is easy to get wrong: a line strictly inside the selection is
    /// covered end to end, the line the selection *starts* on runs from the start column to the line's end, and the
    /// line it *ends* on runs from column zero to the end column.
    ///
    /// `lineLength` is the row's own width — trailing blanks are not text, so a selection that ran to the grid's full
    /// width would copy a screenful of spaces after every command.
    func columnRange(
        forBodyLine bodyLine: Int, inBlock blockIndex: Int, lineLength: Int
    ) -> Range<Int>? {
        guard lineLength > 0 else { return nil }
        let line = Point(blockIndex: blockIndex, bodyLine: bodyLine, column: 0)
        guard line >= Point(blockIndex: start.blockIndex, bodyLine: start.bodyLine, column: 0),
            line <= Point(blockIndex: end.blockIndex, bodyLine: end.bodyLine, column: 0)
        else { return nil }

        let isFirst = blockIndex == start.blockIndex && bodyLine == start.bodyLine
        let isLast = blockIndex == end.blockIndex && bodyLine == end.bodyLine
        let from = isFirst ? min(start.column, lineLength) : 0
        // The end column is exclusive: a selection that ends *on* column 5 has taken columns 0..<5, which is what
        // dragging across five characters means.
        let to = isLast ? min(max(end.column, from), lineLength) : lineLength
        guard from < to else { return nil }
        return from..<to
    }

    /// The word a column is inside, as a half-open range of the line's characters.
    ///
    /// **A word is a run of non-blank characters, punctuation included.** That is what a terminal needs rather than a
    /// text editor's rule: `--amend`, `~/Desktop/x.png` and `a|b` are each one thing to select, and a boundary rule
    /// borrowed from prose would split every flag and every path at its punctuation.
    ///
    /// A column past the end of the text selects the last word rather than nothing, and a column on whitespace
    /// selects that one cell — both of which are what clicking there looks like it should do.
    static func wordRange(in text: String, atColumn column: Int) -> Range<Int> {
        let characters = Array(text)
        guard !characters.isEmpty else { return 0..<0 }
        let index = min(max(0, column), characters.count - 1)
        guard !characters[index].isWhitespace else { return index..<(index + 1) }

        var start = index
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = index
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return start..<end
    }

    /// The text of the selection.
    ///
    /// `line` answers a line's text for a (block, body line) and `height` says how many body lines a block has —
    /// **both supplied**, because this has no grids, and that is what keeps the arithmetic above testable without
    /// one. Each line is trimmed of its trailing blanks: a terminal row is a rectangle and the text in it is not.
    func text(height: (Int) -> Int, line: (Int, Int) -> String?) -> String {
        var rows: [String] = []
        var blockIndex = start.blockIndex
        var bodyLine = start.bodyLine
        while blockIndex <= end.blockIndex {
            if let row = line(blockIndex, bodyLine) {
                let characters = Array(row)
                if let range = columnRange(
                    forBodyLine: bodyLine, inBlock: blockIndex, lineLength: characters.count)
                {
                    rows.append(String(characters[range]).trimmingTrailingBlanks)
                }
            }
            // Walked forward by the caller's own heights rather than by asking a grid: a block with no output yet has
            // a body of one line, and a selection that assumed otherwise would stop early or run past the end.
            bodyLine += 1
            if bodyLine >= max(1, height(blockIndex)) {
                blockIndex += 1
                bodyLine = 0
            }
        }
        return rows.joined(separator: "\n")
    }
}

extension String {
    /// Spaces and tabs at the end, gone. A terminal row is a rectangle; the text in it is not.
    fileprivate var trimmingTrailingBlanks: String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous] == " " || self[previous] == "\t" else { break }
            end = previous
        }
        return String(self[startIndex..<end])
    }
}

extension Block {
    /// Which grid a body line belongs to, and which row of it.
    ///
    /// **One mapping, read by the renderer that draws the rows and by the selection that reads them.** Two mappings
    /// would be two answers about which row a document line is, and the one that drifts is the one that copies the
    /// wrong text.
    func gridLine(forBodyLine line: Int) -> (contentGrid: BlockGrid, row: Int)? {
        guard line >= 0 else { return nil }
        var remaining = line
        for visibleGrid in visibleGrids {
            if remaining < visibleGrid.lines {
                return (visibleGrid.contentGrid, remaining)
            }
            remaining -= visibleGrid.lines
        }
        return nil
    }

    /// The text of one body line, trimmed of its trailing blanks.
    func bodyLineText(_ line: Int) -> String? {
        guard let (contentGrid, row) = gridLine(forBodyLine: line),
            let gridLine = contentGrid.line(at: row)
        else { return nil }
        return gridLine.string()
    }
}
