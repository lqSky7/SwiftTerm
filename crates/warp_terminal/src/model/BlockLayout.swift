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

    // MARK: - The pinned block

    /// The block at the bottom, which does not scroll.
    ///
    /// **Warp keeps the block the input is in fixed at the bottom of the window and scrolls everything above it past
    /// it.** Ours scrolled the whole document together, so scrolling back took the prompt off the bottom of the
    /// screen — the one thing you always want to see.
    ///
    /// The last entry is that block: it is where the shell is writing, and the moment it is submitted a new one takes
    /// its place. Nothing has to be tracked to know which block it is.
    var pinnedEntry: Entry? { entries.last }

    /// The height of everything **above** the pinned block. This is what scrolls.
    var scrollableHeight: CGFloat { pinnedEntry?.headerTop ?? totalHeight }

    /// The height the pinned block occupies, which the viewport has to leave room for.
    ///
    /// Its own height including its bottom padding, so the pinned block's bottom lands exactly on the view's bottom —
    /// the same place it sits when nothing is scrolled.
    var pinnedHeight: CGFloat { pinnedEntry.map { $0.bottom - $0.headerTop } ?? 0 }

    /// How tall the scrolling region is, once the pinned block has its room.
    func scrollableViewportHeight(_ viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - pinnedHeight)
    }

    /// Where the top of the scrolling region sits in the document.
    ///
    /// At `scrollPosition == 0` this is the pinned block's top: the scrolling region shows the *bottom* of what is
    /// above the pinned block, which is the state the window opens in.
    func scrollableTop(scrollPosition: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        scrollableHeight - scrollPosition - scrollableViewportHeight(viewportHeight)
    }

    /// The scroll position that puts a document position at the top of the scrolling region.
    ///
    /// **The inverse of `scrollableTop`**, and it lives here rather than in the view for the reason the rest of this
    /// does: a block jump that computed its own offset would use the whole document's height and land in the wrong
    /// place — while ordinary scrolling, which goes through `scrollableTop`, stayed correct. Two copies of one piece
    /// of arithmetic is how that happens.
    func scrollPosition(puttingTopAt documentY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        scrollableHeight - documentY - scrollableViewportHeight(viewportHeight)
    }

    /// How far back the scrolling region can go before the oldest block is at its top.
    func maximumScroll(viewportHeight: CGFloat) -> CGFloat {
        max(0, scrollableHeight - scrollableViewportHeight(viewportHeight))
    }

    /// The viewport top that puts the pinned block's bottom on the view's bottom.
    ///
    /// A constant for a given viewport size, which is the whole point: the pinned block does not move.
    func pinnedViewportTop(viewportHeight: CGFloat) -> CGFloat {
        (pinnedEntry?.bottom ?? 0) - viewportHeight
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
