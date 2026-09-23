import Foundation

/// Where every block's header and content sit in one vertically-scrolling document.
///
/// Pure arithmetic over line counts: it knows nothing about a grid, a font, or a view. That is what
/// makes the part most likely to be off by one the part that is easiest to test — and the document
/// offset it produces is the same pixel scroll position Phase 1 already had, so a trackpad gesture
/// still slides rather than jumps.
struct BlockLayout {
    struct Entry: Equatable {
        var blockIndex: Int
        /// Top of the header, measured down from the top of the document.
        var headerTop: CGFloat
        var headerHeight: CGFloat
        /// Top of the row of context chips, when the block has one. Equal to `contentTop` when it does
        /// not, so a caller that ignores chips is still right.
        var chipTop: CGFloat
        var chipHeight: CGFloat
        /// Top of the block's first content line.
        var contentTop: CGFloat
        var contentLineCount: Int
        var contentHeight: CGFloat
        /// The gap below this block. Part of the block, not a space between blocks.
        var bottomPadding: CGFloat

        /// Where the block ends: its content **plus its own bottom padding**.
        ///
        /// The padding is part of the block rather than a gap between blocks — which is what Warp does by adding
        /// `padding_bottom()` to the block's height — and this has to say so, or everything drawn to the block's
        /// extent stops short of it: the selection tint left an unpainted strip at the bottom, and the failure and
        /// folded marks did the same. The next block's `headerTop` is this value, so the blocks tile exactly.
        var bottom: CGFloat { contentTop + contentHeight + bottomPadding }
    }

    /// One block's contribution. A block still being typed has no header — there is nothing to say
    /// about a command that has not been run.
    typealias Contribution = (lineCount: Int, hasHeader: Bool)

    /// The row of context chips one block shows above its content.
    ///
    /// Chips belong to the prompt, so they are reserved *above* the content of the block being typed
    /// and shift nothing else: every other block's offsets are unchanged, and the block's own rows keep
    /// their line numbers because `contentTop` moves rather than `contentLineCount`.
    struct ChipRow: Equatable {
        var blockIndex: Int
        var height: CGFloat
    }

    private(set) var entries: [Entry] = []
    private(set) var totalHeight: CGFloat = 0
    /// The gap below each block. Kept so the view and the layout agree about how much of the document is padding.
    private(set) var bottomPadding: CGFloat = 0

    init(
        contributions: [Contribution],
        chipRow: ChipRow? = nil,
        headerHeight: CGFloat,
        lineHeight: CGFloat,
        bottomPadding: CGFloat = 0
    ) {
        var top: CGFloat = 0
        for (index, contribution) in contributions.enumerated() {
            let height = contribution.hasHeader ? headerHeight : 0
            let chips = chipRow?.blockIndex == index ? (chipRow?.height ?? 0) : 0
            let contentHeight = CGFloat(contribution.lineCount) * lineHeight
            entries.append(
                Entry(
                    blockIndex: index,
                    headerTop: top,
                    headerHeight: height,
                    chipTop: top + height,
                    chipHeight: chips,
                    contentTop: top + height + chips,
                    contentLineCount: contribution.lineCount,
                    contentHeight: contentHeight,
                    bottomPadding: bottomPadding))
            // **Every block carries the gap, including the last one.** That is what leaves the final line clear of
            // the window's edge — the cursor touching the bottom of the terminal — while also separating consecutive
            // blocks. One inset at the end of the document would do the first and not the second. Warp's
            // `padding_bottom()` is added to the block's height for the same reason (`block.rs:1560`).
            top += height + chips + contentHeight + bottomPadding
        }
        self.bottomPadding = bottomPadding
        totalHeight = top
    }

    /// The entries a viewport touches, in document order.
    ///
    /// A linear scan rather than a binary search: the list is bounded by the scrollback cap, the
    /// scan is a few hundred comparisons, and the version that was harder to read is the version
    /// that would have the off-by-one.
    func entries(intersecting top: CGFloat, _ bottom: CGFloat) -> [Entry] {
        entries.filter { $0.bottom > top && $0.headerTop < bottom }
    }

    /// Where a block's header sits, for scrolling it into view. Nil for a block that has no header.
    func headerTop(ofBlock index: Int) -> CGFloat? {
        guard entries.indices.contains(index), entries[index].headerHeight > 0 else { return nil }
        return entries[index].headerTop
    }
}
