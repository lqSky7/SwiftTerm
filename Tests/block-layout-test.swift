import Foundation

/// Guards the document geometry. This is the arithmetic that decides where every block's header and
/// every one of its lines lands, and an off-by-one here is a block whose header sits on top of the
/// previous block's last line.
@main
enum BlockLayoutTest {
    static func main() {
        let harness = Harness("block-layout-test")

        emptyDocument(harness)
        stacking(harness)
        headerlessBlocks(harness)
        visibleEntries(harness)
        headerPositions(harness)
        shortDocument(harness)
        theGapBelowEachBlock(harness)
        thePinnedBlock(harness)
        chipRow(harness)

        harness.finish()
    }

    private static let header: CGFloat = 26
    private static let line: CGFloat = 17
    private static let chips: CGFloat = 24

    private static func layout(_ contributions: [BlockLayout.Contribution]) -> BlockLayout {
        BlockLayout(contributions: contributions, headerHeight: header, lineHeight: line)
    }

    /// The chip row is reserved *above* one block's content, and this is the arithmetic that says so.
    /// It shifts nothing else: the blocks after it move down by exactly the row's height, and the block
    /// it belongs to keeps its line numbers because `contentTop` moved rather than the line count.
    private static func chipRow(_ harness: Harness) {
        let contributions: [BlockLayout.Contribution] = [
            (lineCount: 3, hasHeader: true),
            (lineCount: 2, hasHeader: false),
        ]
        let without = layout(contributions)
        let with = BlockLayout(
            contributions: contributions,
            chipRow: BlockLayout.ChipRow(blockIndex: 1, height: chips),
            headerHeight: header,
            lineHeight: line)

        harness.equal(
            with.totalHeight, without.totalHeight + chips,
            "the chip row is added to the document, not taken from a block")

        // The block that has no chip row is untouched — that is the whole point of reserving it above
        // rather than inside.
        harness.equal(with.entries[0].headerTop, without.entries[0].headerTop, "the first block does not move")
        harness.equal(with.entries[0].contentTop, without.entries[0].contentTop, "not even its content")
        harness.equal(
            with.entries[0].chipHeight, 0, "and it has no chip row of its own")

        // The block that has one: the chips sit between its content and whatever is above it.
        harness.equal(with.entries[1].chipTop, without.entries[1].contentTop, "the chips start where the content did")
        harness.equal(with.entries[1].chipHeight, chips, "and are the row's height")
        harness.equal(
            with.entries[1].contentTop, without.entries[1].contentTop + chips,
            "so the content starts a row lower")
        harness.equal(
            with.entries[1].contentLineCount, 2, "with the same number of lines as before")
        harness.equal(
            with.entries[1].contentHeight, 2 * line, "and the same height")
        harness.equal(
            with.entries[1].bottom, without.entries[1].bottom + chips,
            "and the block ends a row lower, so nothing is drawn through it")

        // A chip row for a block that does not exist is ignored rather than crashing or adding height.
        let orphan = BlockLayout(
            contributions: contributions,
            chipRow: BlockLayout.ChipRow(blockIndex: 9, height: chips),
            headerHeight: header,
            lineHeight: line)
        harness.equal(orphan.totalHeight, without.totalHeight, "a chip row for no block adds nothing")

        // The chip row is inside the block's extent, so clicking it selects the block.
        harness.expect(
            with.entries[1].chipTop >= with.entries[1].headerTop,
            "the chip row is inside the block, not above it")
        harness.expect(
            with.entries[1].chipTop + with.entries[1].chipHeight <= with.entries[1].bottom,
            "and within its extent")
    }

    private static func emptyDocument(_ harness: Harness) {
        let empty = layout([])
        harness.equal(empty.entries.count, 0, "no blocks, no entries")
        harness.equal(empty.totalHeight, 0, "and no height")
        harness.equal(
            empty.entries(intersecting: 0, 100).count, 0, "and nothing to draw")
    }

    private static func stacking(_ harness: Harness) {
        let document = layout([(lineCount: 3, hasHeader: true), (lineCount: 2, hasHeader: true)])
        harness.equal(
            document.totalHeight, (header + 3 * line) + (header + 2 * line),
            "the document is the sum of its blocks")

        harness.equal(document.entries[0].headerTop, 0, "the first header starts the document")
        harness.equal(document.entries[0].headerHeight, header, "and is one header tall")
        harness.equal(document.entries[0].contentTop, header, "so its content starts below it")
        harness.equal(document.entries[0].contentHeight, 3 * line, "and is as tall as its lines")
        harness.equal(document.entries[0].bottom, header + 3 * line, "ending where the next begins")

        harness.equal(
            document.entries[1].headerTop, header + 3 * line, "the second header follows the first")
        harness.equal(
            document.entries[1].bottom, document.totalHeight, "and the last one ends the document")
    }

    private static func headerlessBlocks(_ harness: Harness) {
        // A block still being typed has no header: there is nothing to say about a command that has
        // not been run, and reserving a strip for it would leave a gap above the prompt.
        let document = layout([(lineCount: 1, hasHeader: false), (lineCount: 2, hasHeader: true)])
        harness.equal(document.entries[0].headerHeight, 0, "no header, no height")
        harness.equal(document.entries[0].contentTop, 0, "so its content starts at the very top")
        harness.equal(
            document.entries[1].headerTop, line, "and the next block follows it immediately")
        harness.equal(
            document.totalHeight, line + header + 2 * line, "and contributes only its lines")
    }

    private static func visibleEntries(_ harness: Harness) {
        let document = layout([
            (lineCount: 3, hasHeader: true), (lineCount: 3, hasHeader: true),
            (lineCount: 3, hasHeader: true),
        ])
        let blockHeight = header + 3 * line

        harness.equal(
            document.entries(intersecting: 0, blockHeight).count, 1,
            "a viewport inside one block sees one block")
        harness.equal(
            document.entries(intersecting: blockHeight - 1, blockHeight + 1).count, 2,
            "a viewport straddling a boundary sees both blocks")
        harness.equal(
            document.entries(intersecting: 0, 10 * blockHeight).count, 3,
            "a viewport over everything sees everything")
        harness.equal(
            document.entries(intersecting: -100, -1).count, 0,
            "a viewport above the document sees nothing")
        harness.equal(
            document.entries(intersecting: 10 * blockHeight, 11 * blockHeight).count, 0,
            "and one below it sees nothing either")
    }

    private static func headerPositions(_ harness: Harness) {
        let document = layout([(lineCount: 1, hasHeader: false), (lineCount: 1, hasHeader: true)])
        harness.equal(
            document.headerTop(ofBlock: 0), nil, "a block with no header has no position to scroll to")
        harness.equal(
            document.headerTop(ofBlock: 1), line, "a block with one reports where it is")
        harness.equal(document.headerTop(ofBlock: 9), nil, "and an unknown block reports nothing")
    }

    /// The gap below every block, including the last.
    ///
    /// This is the "cursor touches the bottom of the terminal" fix. The assertion that matters is the *last* block:
    /// one inset at the end of the document would satisfy that, but it would not separate consecutive blocks, which
    /// is what a per-block padding does.
    private static func theGapBelowEachBlock(_ harness: Harness) {
        let padding: CGFloat = 5
        let tight = BlockLayout(
            contributions: [(lineCount: 2, hasHeader: true)], headerHeight: 10, lineHeight: 10)
        let spaced = BlockLayout(
            contributions: [(lineCount: 2, hasHeader: true)], headerHeight: 10, lineHeight: 10,
            bottomPadding: padding)

        harness.equal(tight.totalHeight, 30, "without a gap: a header and two lines")
        harness.equal(spaced.totalHeight, 35, "with one, the block is exactly that much taller")
        harness.equal(
            spaced.entries[0].contentTop, tight.entries[0].contentTop,
            "and the gap goes below the content rather than above it")
        harness.equal(
            spaced.entries[0].contentTop + spaced.entries[0].contentHeight,
            tight.entries[0].bottom,
            "so the content ends exactly where it ended before")
        harness.equal(
            spaced.entries[0].bottom, tight.entries[0].bottom + padding,
            "and the block's bottom includes the gap, or a selection tint would stop short of it")

        let two = BlockLayout(
            contributions: [(lineCount: 1, hasHeader: true), (lineCount: 1, hasHeader: true)],
            headerHeight: 10, lineHeight: 10, bottomPadding: padding)
        harness.equal(two.totalHeight, 50, "and the last block carries a gap too, which is the bottom one")
        harness.equal(
            two.entries[0].bottom, two.entries[1].headerTop,
            "the blocks tile exactly: the gap belongs to the block above it, not to the space between them")
    }

    /// The block at the bottom does not scroll; everything above it does.
    ///
    /// Three *properties*, not three formulas — a formula restated is a test that passes because it was copied:
    ///
    /// - at rest, the bottom of the scrolling region is the top of the pinned block, so nothing is hidden under it;
    /// - scrolled all the way back, the oldest block's top is the top of the scrolling region;
    /// - the pinned block's bottom is on the view's bottom, at any scroll position and at any document length.
    private static func thePinnedBlock(_ harness: Harness) {
        // Three blocks, two lines each: header 10, content 20, no padding. Block 2 is the pinned one.
        let layout = BlockLayout(
            contributions: Array(repeating: (lineCount: 2, hasHeader: true), count: 3),
            headerHeight: 10, lineHeight: 10)
        harness.equal(layout.totalHeight, 90, "three blocks of thirty")
        harness.equal(layout.pinnedEntry?.blockIndex, 2, "the pinned block is the last one")
        harness.equal(layout.scrollableHeight, 60, "and everything above it is what scrolls")
        harness.equal(layout.pinnedHeight, 30, "while the pinned block keeps its own height")

        let height: CGFloat = 50
        harness.equal(
            layout.scrollableTop(scrollPosition: 0, viewportHeight: height)
                + layout.scrollableViewportHeight(height),
            layout.scrollableHeight,
            "at rest the scrolling region ends exactly where the pinned block begins")
        harness.equal(
            layout.maximumScroll(viewportHeight: height), 40,
            "and it can scroll by all of the content above the pinned block")
        harness.equal(
            layout.scrollableTop(scrollPosition: layout.maximumScroll(viewportHeight: height), viewportHeight: height),
            0,
            "scrolled all the way back, the oldest block is at the top of the scrolling region")

        // **The pinned block does not move.** Its viewport top is a function of the view size and nothing else, so it
        // is the same however far back the scrollback has gone — which is the whole point of pinning it.
        harness.equal(
            layout.pinnedViewportTop(viewportHeight: height) + height, layout.pinnedEntry?.bottom,
            "the pinned block's bottom lands on the view's bottom")

        // A document shorter than the view: nothing to scroll, and the pinned block still at the bottom. This is the
        // state a fresh window opens in, so getting it wrong is a prompt that starts halfway up the screen.
        let one = BlockLayout(
            contributions: [(lineCount: 2, hasHeader: true)], headerHeight: 10, lineHeight: 10)
        harness.equal(one.scrollableHeight, 0, "one block has nothing above it")
        harness.equal(one.maximumScroll(viewportHeight: 100), 0, "so there is nowhere to scroll")
        harness.equal(
            one.pinnedViewportTop(viewportHeight: 100) + 100, one.pinnedEntry?.bottom,
            "and it still sits on the view's bottom")

        // **`scrollPosition(puttingTopAt:)` is the inverse of `scrollableTop`**, and asserting the round trip is
        // stronger than asserting either formula: it is the property a block jump needs, and it fails the moment the
        // two drift apart.
        for target: CGFloat in [0, 20, 40, 60] {
            let position = layout.scrollPosition(puttingTopAt: target, viewportHeight: height)
            harness.equal(
                layout.scrollableTop(scrollPosition: position, viewportHeight: height), target,
                "putting the top at \(Int(target)) and asking where the top is agree")
        }

        // A view too short for the pinned block: the scrolling region collapses to nothing rather than going negative.
        harness.equal(
            layout.scrollableViewportHeight(10), 0,
            "a view shorter than the pinned block leaves no scrolling region rather than a negative one")
    }

    private static func shortDocument(_ harness: Harness) {
        // A document shorter than the window must still report a positive height: the view is what
        // turns that into a negative viewport top, which is what anchors it to the bottom.
        let document = layout([(lineCount: 1, hasHeader: true)])
        harness.equal(document.totalHeight, header + line, "a one-block document is one block tall")
        harness.expect(
            document.totalHeight < 600, "and is shorter than a window, so the view can anchor it")
    }
}
