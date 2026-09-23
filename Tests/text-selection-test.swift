import Foundation

/// Guards the arithmetic of a text selection.
///
/// This is the part of selection that can be wrong without looking wrong: a range that is one column short copies
/// almost the right text, and a reversed drag that is not normalised copies the line backwards. A harness is the only
/// place to see that, so the arithmetic lives in the model rather than in the drag handler.
@main
enum TextSelectionTest {
    static func main() {
        let harness = Harness("text-selection-test")

        itNormalisesADrag(harness)
        itFindsTheWordUnderAColumn(harness)
        itCoversTheRightColumns(harness)
        itCopiesTheRightText(harness)
        itWalksAcrossBlocks(harness)
        itMapsBodyLinesToGridRows(harness)

        harness.finish()
    }

    /// The three lines of one block, as a grid would answer them.
    private static let lines = [
        "swift build --configuration release",
        "Compiling SwiftTerm",
        "Build complete!",
    ]

    private static func selection(
        from anchor: TextSelection.Point, to focus: TextSelection.Point
    ) -> TextSelection {
        TextSelection(anchor: anchor, focus: focus)
    }

    private static func point(_ block: Int, _ line: Int, _ column: Int) -> TextSelection.Point {
        TextSelection.Point(blockIndex: block, bodyLine: line, column: column)
    }

    private static func itNormalisesADrag(_ harness: Harness) {
        // Dragging up and to the left is the same selection as dragging down and to the right, and the *only*
        // difference is that the caller may want to know it went backwards.
        let forward = selection(from: point(0, 0, 2), to: point(0, 2, 7))
        let backward = selection(from: point(0, 2, 7), to: point(0, 0, 2))

        harness.equal(forward.start, point(0, 0, 2), "the start is the earlier end")
        harness.equal(forward.end, point(0, 2, 7), "and the end is the later one")
        harness.equal(backward.start, forward.start, "a reversed drag normalises to the same range")
        harness.equal(backward.end, forward.end, "at both ends")
        harness.expect(!forward.isReversed, "a forward drag is not reversed")
        harness.expect(backward.isReversed, "and a backward one is, which is what keyboard extension needs")

        harness.expect(
            selection(from: point(1, 3, 4), to: point(1, 3, 4)).isEmpty,
            "a click is a selection with nothing in it")

        // Reading order runs down the document and then across the line, so a lower line is always later — whatever
        // its column.
        harness.expect(
            point(0, 1, 0) < point(0, 1, 40), "a later column is later on the same line")
        harness.expect(
            point(0, 1, 40) < point(0, 2, 0), "but the next line is later than any column on this one")
        harness.expect(point(0, 9, 40) < point(1, 0, 0), "and the next block is later than this one")
    }

    /// A double-click takes the word, punctuation and all.
    private static func itFindsTheWordUnderAColumn(_ harness: Harness) {
        let line = "swift build --configuration release"
        harness.equal(
            TextSelection.wordRange(in: line, atColumn: 7), 6..<11, "a word in the middle")
        harness.equal(
            TextSelection.wordRange(in: line, atColumn: 12), 12..<27,
            "a flag is one word, hyphen and all — a text editor's boundary rule would split it")
        harness.equal(
            TextSelection.wordRange(in: "cd ~/Desktop/x.png", atColumn: 6), 3..<18,
            "and so is a path, slashes and all")

        // Clicking on whitespace takes that cell rather than a neighbouring word.
        harness.equal(
            TextSelection.wordRange(in: line, atColumn: 5), 5..<6, "a space is its own single cell")
        // And a click past the end takes the last word rather than nothing.
        harness.equal(
            TextSelection.wordRange(in: line, atColumn: 99), 28..<35, "past the end is the last word")
        harness.equal(
            TextSelection.wordRange(in: "", atColumn: 0), 0..<0, "an empty line has no word")
    }

    private static func itCoversTheRightColumns(_ harness: Harness) {
        // From column 6 of line 0 to column 9 of line 2.
        let dragged = selection(from: point(0, 0, 6), to: point(0, 2, 9))

        harness.equal(
            dragged.columnRange(forBodyLine: 0, inBlock: 0, lineLength: 33), 6..<33,
            "the first line runs from the start column to the end of the text")
        harness.equal(
            dragged.columnRange(forBodyLine: 1, inBlock: 0, lineLength: 21), 0..<21,
            "a line inside the selection is covered end to end")
        harness.equal(
            dragged.columnRange(forBodyLine: 2, inBlock: 0, lineLength: 15), 0..<9,
            "and the last line runs to the end column, which is exclusive")

        harness.equal(
            dragged.columnRange(forBodyLine: 0, inBlock: 1, lineLength: 10), nil,
            "a line before the selection is not in it")
        harness.equal(
            dragged.columnRange(forBodyLine: 3, inBlock: 0, lineLength: 10), nil,
            "nor is one after it")

        // **The row's own length is the limit, not the grid's width.** A terminal row is a rectangle and the text in
        // it is not, so a selection dragged to the right edge must not copy a screenful of blanks.
        harness.equal(
            dragged.columnRange(forBodyLine: 0, inBlock: 0, lineLength: 8), 6..<8,
            "a row shorter than the selection ends where its text does")
        harness.equal(
            dragged.columnRange(forBodyLine: 0, inBlock: 0, lineLength: 3), nil,
            "and a row that ends before the selection starts contributes nothing")
    }

    private static func itCopiesTheRightText(_ harness: Harness) {
        let dragged = selection(from: point(0, 0, 6), to: point(0, 2, 9))
        let text = dragged.text(
            height: { _ in 3 },
            line: { block, line in block == 0 && lines.indices.contains(line) ? lines[line] : nil })

        harness.equal(
            text, "build --configuration release\nCompiling SwiftTerm\nBuild com",
            "the selected text, line by line, with the ends cut where they were dragged")

        // Trailing blanks are not text.
        let padded = selection(
            from: point(0, 0, 0), to: point(0, 0, 40))
        harness.equal(
            padded.text(height: { _ in 1 }, line: { _, _ in "echo hi" + String(repeating: " ", count: 33) }),
            "echo hi",
            "a row's trailing blanks are not copied")

        // A selection that ends where it starts copies nothing rather than a line.
        let click = selection(from: point(0, 0, 4), to: point(0, 0, 4))
        harness.equal(
            click.text(height: { _ in 1 }, line: { _, _ in "echo hi" }), "",
            "a click copies nothing")
    }

    private static func itWalksAcrossBlocks(_ harness: Harness) {
        // Two blocks, two lines each, selected from the middle of the first to the middle of the second.
        let heights = [0: 2, 1: 2]
        let rows = [0: ["first one", "first two"], 1: ["second one", "second two"]]
        let across = selection(from: point(0, 1, 6), to: point(1, 1, 6))

        harness.equal(
            across.text(
                height: { heights[$0] ?? 0 },
                line: { block, line in rows[block]?[line] }),
            "two\nsecond one\nsecond",
            "a selection across two blocks takes the tail of the first, all of the second's first line, and the head "
                + "of its second")
    }

    private static func itMapsBodyLinesToGridRows(_ harness: Harness) {
        // A submitted block's body is the command grid and then the output grid, so body line 1 is *row 0 of the
        // output* — not row 1 of anything. Getting this wrong copies the wrong line.
        var list = BlockList(size: TerminalSize(columns: 80, rows: 24))
        _ = list.begin(at: Date(), workingDirectory: "/tmp")
        guard let block = list.activeBlock else {
            harness.expect(false, "a block was created")
            return
        }
        list.markPromptEnd(line: 0, column: 4)
        list.markCommandSubmitted(command: "ls", at: Date())

        let commandGrid = block.contentGrids[0]
        let outputGrid = block.contentGrids[1]
        // Nothing has been drawn into the command grid, so it has no lines and the body is the output alone — which is
        // the honest answer rather than a failure. What this test is for is the *mapping*: whichever grid a body line
        // lands in, the row it reports is relative to **that grid**, which is the off-by-one worth guarding.
        harness.equal(commandGrid.lineCount, 0, "the fixture drew no prompt")
        harness.equal(
            block.gridLine(forBodyLine: 0)?.contentGrid === outputGrid, true,
            "so the first body line is the output grid")
        harness.equal(
            block.gridLine(forBodyLine: 0)?.row, 0,
            "at its row 0 rather than at the block's line number")
        harness.expect(
            block.gridLine(forBodyLine: block.lineCount) == nil,
            "and one past the end is nothing rather than the next grid")

        // A folded block maps only the lines it shows, so a selection cannot read text that is not on screen.
        for _ in 0..<(Block.collapsibleLineCount + 5) { outputGrid.grid.lineFeed() }
        block.toggleCollapsed()
        harness.expect(
            block.gridLine(forBodyLine: Block.collapsedLineCount) == nil,
            "a folded block has no line at its collapsed limit")
    }
}
