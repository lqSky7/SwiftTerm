import AppKit
import CoreText

/// Paints the terminal into a Core Graphics context.
///
/// Two documents, one renderer. Normally it draws a vertically-scrolling stack of blocks, each from
/// the grids that block owns; when a full-screen program is running it draws the active block's grid
/// instead, because the alternate screen has its own cursor and its own idea of where things are, and
/// a block view underneath it would be nonsense.
///
/// Rows are cached as a `CTLine` keyed by *the grid that holds them and the row in that grid*, so a
/// sealed block's rows are built once and never revisited. The key carries whether the row is a
/// screen row or a history row because the two are stamped from different sources and must not share
/// a slot — the bug in `learnings.md` was a cache whose key was not actually unique to its contents.
/// An active hovered link span for interactive underline and ⌘-click dispatch.
struct HoveredLink: Equatable, Sendable {
    var blockIndex: Int?
    var bodyLine: Int
    var colRange: Range<Int>
    var link: DetectedLink
    var isAlternateScreen: Bool = false
}

@MainActor
final class TerminalRenderer {
    /// A stretch of one row that shares attributes and can be drawn as a single `CTLine`.
    private struct Run {
        var column: Int
        var columns: Int
        var attributes: CellAttributes
        var string: String
    }

    private struct CachedRow {
        var generation: UInt64
        var line: CTLine
        var runs: [Run]
    }

    /// Identity, not equality: a grid is a reference, and two blocks' grids are never the same rows.
    private struct RowKey: Hashable {
        let grid: ObjectIdentifier
        let row: Int
        let isScreenRow: Bool
        /// The weight is baked into the `CTLine`, so it is part of the row's identity — without it a bold row
        /// and a plain one would share a cache slot, which is the bug `learnings.md` records as "a cache whose
        /// key was not actually unique to its contents".
        let isCommand: Bool
    }

    private var rowCache: [RowKey: CachedRow] = [:]
    /// How many rows may be remembered before the cache is emptied rather than grown.
    private static let maximumCachedRows = 4_000
    /// The grids the cache was built for. When the block list changes — a new block, an evicted one —
    /// every entry is dropped, which is the one moment the cache can be wrong wholesale.
    private var cachedGrids: [ObjectIdentifier] = []

    private var palette: TerminalPalette
    private(set) var font: TerminalFont

    /// How much of the palette's background is painted. Below one the window's behind-window blur
    /// shows through, which is the only reason a terminal can sit on a wallpaper at all.
    ///
    /// **This is the terminal's opacity control, and it is the only thing that paints the terminal's own
    /// background.** It used to be a constant 0.92 with a second, translucent fill drawn by the panel in
    /// `WorkspaceScreen` behind it — which meant the setting did nothing at all, because this fill covered
    /// it completely. The renderer is the only thing that knows the palette, so this is where the terminal's
    /// background belongs; the panel's fill is gone.
    var backgroundOpacity = CGFloat(ChromeSettings.defaultTerminalOpacity)
    var chipMaterial: ChipMaterial = .thinMaterial

    init(palette: TerminalPalette, font: TerminalFont) {
        self.palette = palette
        self.font = font
    }

    /// A new font or a new palette invalidates every cached line, because both are baked into the
    /// `CTLine`'s attributes rather than applied at draw time.
    func update(palette: TerminalPalette, font: TerminalFont) {
        let changed = palette != self.palette || font.cellWidth != self.font.cellWidth
            || font.cellHeight != self.font.cellHeight || font.base != self.font.base
        self.palette = palette
        self.font = font
        if changed { rowCache.removeAll() }
    }

    /// How much of the view's width the content stays clear of, on both sides.
    ///
    /// **One number for the grid *and* the block chrome** — the status dot, the chips, the rules — because
    /// they used to be two numbers that disagreed. The chrome was inset by `Spacing.md` and the grid was
    /// not, so the text hung *outside* the block's own chrome and the first column of every line sat on the
    /// panel's rounded leading corner, where the clip cut into it.
    ///
    /// It applies to **content**: text, the cursor, the status dot, the chips. Not to the two things that are
    /// *surfaces* — the selection tint and the rule between blocks — which run edge to edge on purpose. A
    /// tint or a rule that stopped short of the panel's edges reads as a box drawn around the text, which is
    /// exactly what neither of them is.
    private var contentInset: CGFloat { Theme.Size.terminalContentInset }

    /// How many cells fit in a view of this size. Never zero: a zero divides by zero in every layout
    /// calculation downstream and the pty rejects it.
    ///
    /// **The content inset comes off the width.** The count has to be the number of columns that are
    /// actually drawn inside the inset; counting them across the full width is how the last column ends up
    /// past the edge the rest of the content respects.
    func gridSize(fitting bounds: CGSize) -> (columns: Int, rows: Int) {
        (
            max(1, Int((bounds.width - contentInset * 2) / font.cellWidth)),
            max(1, Int(bounds.height / font.cellHeight))
        )
    }

    // MARK: - Drawing

    func draw(
        in context: CGContext,
        bounds: CGRect,
        session: TerminalSession,
        layout: BlockLayout,
        scrollPosition: CGFloat,
        showsCursor: Bool,
        markedText: String?,
        cursorBlinkOn: Bool,
        selectedBlockID: BlockID?,
        hoveredBlockID: BlockID?,
        hoveredLink: HoveredLink? = nil,
        selection: TextSelection?,
        chips: [ContextChip]
    ) {
        context.setFillColor(palette.background.nsColor.withAlphaComponent(backgroundOpacity).cgColor)
        context.fill(bounds)

        guard !session.isAlternateScreen else {
            drawAlternateScreen(in: context, bounds: bounds, grid: session.activeGrid, hoveredLink: hoveredLink)
            return
        }
        drawBlocks(
            in: context, bounds: bounds, session: session, layout: layout,
            scrollPosition: scrollPosition, showsCursor: showsCursor, markedText: markedText,
            cursorBlinkOn: cursorBlinkOn, selectedBlockID: selectedBlockID,
            hoveredBlockID: hoveredBlockID, hoveredLink: hoveredLink, selection: selection, chips: chips)
    }

    /// A subtle tint over the whole selected block — header and output together, and no border.
    ///
    /// **The header is included**, because the command that ran is part of what was selected: a tint
    /// that stopped at the content would say half the block is selected, and with the header painting no
    /// background of its own there is nothing left to stop it reaching the top.
    ///
    /// Warp's default indicator is a 2pt border (`SelectionBorderWidth` in `block_list_element.rs`),
    /// but its own `MinimalistUI` flag zeroes those widths to `0.0`, so a selection with no border is
    /// a mode Warp ships. This is that mode, deliberately: a border draws a box around the block, and a
    /// tint says the same thing without adding a line to the page or touching a glyph.
    ///
    /// It runs **edge to edge**, and so does the rule between blocks, while the text does not. The
    /// distinction is the one thing worth holding on to here: a tint and a rule are *surfaces*, and a surface
    /// that stopped short of the panel's edges would read as a box drawn around the text — which is the border
    /// this deliberately is not. The content inset is for content.
    private func drawSelectionHighlight(
        entry: BlockLayout.Entry, viewportTop: CGFloat, bounds: CGRect, in context: CGContext
    ) {
        let top = screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds)
        let bottom = screenY(entry.bottom, viewportTop: viewportTop, bounds: bounds)
        let rect = CGRect(x: bounds.minX, y: bottom, width: bounds.width, height: max(0, top - bottom))
        guard rect.height > 0 else { return }
        context.setFillColor(selectionTint.cgColor)
        context.fill(rect)
    }

    /// The wash over a selected block. Subtle enough to read through, which is the point: it says
    /// which block the menu will act on without competing with the text inside it.
    private var selectionTint: NSColor {
        palette.foreground.nsColor.withAlphaComponent(0.06)
    }

    /// The rule between one block and the next.
    ///
    /// Warp's `draw_border_between_blocks` (`app/src/terminal/block_list_element.rs`): one hairline at
    /// each block boundary, in the theme's outline colour, gated on a spacing setting. A block's header
    /// already tells blocks apart once something has run; this is what makes the *boundary* visible,
    /// which is the difference between a stack of blocks and one long scrollback.
    ///
    /// Full width, like the selection tint and unlike the text: a rule is a surface, and one that stopped
    /// short of the panel's edges would read as an underline on the text rather than as a division between
    /// two blocks.
    private func drawBlockSeparator(
        above entry: BlockLayout.Entry, viewportTop: CGFloat, bounds: CGRect, in context: CGContext
    ) {
        let boundary = screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds)
        let rule = CGRect(x: bounds.minX, y: boundary - 1, width: bounds.width, height: 1)
        guard rule.maxY > bounds.minY, rule.minY < bounds.maxY else { return }
        context.setFillColor(outline.cgColor)
        context.fill(rule)
    }

    /// The palette's stand-in for Warp's `theme.outline()`: the terminal's own ink, far enough down
    /// that it reads as a rule rather than as text, so no colour enters the palette that was not in it.
    private var outline: NSColor {
        palette.foreground.nsColor.withAlphaComponent(0.18)
    }

    /// The row of context chips above a prompt.
    ///
    /// Drawn rather than laid out: a chip is a rounded capsule with a label in it, which is one path and
    /// one `CTLine`. The height the document reserved for the row is `BlockLayout`'s business, so this
    /// only has to fill it — and the chips are handed in rather than computed here, because what a chip
    /// says is a model question and this is not the model.
    private func drawChips(
        _ chips: [ContextChip], entry: BlockLayout.Entry, viewportTop: CGFloat, bounds: CGRect,
        in context: CGContext
    ) {
        guard !chips.isEmpty, entry.chipHeight > 0 else { return }
        let top = screenY(entry.chipTop, viewportTop: viewportTop, bounds: bounds)
        let bottom = screenY(entry.chipTop + entry.chipHeight, viewportTop: viewportTop, bounds: bounds)
        guard bottom < bounds.maxY, top > bounds.minY else { return }

        // Original chip pill size, with no borders and increased distance from top block
        let padding = Theme.Spacing.lg
        let chipHeight: CGFloat = 22
        let originY = bottom + Theme.Spacing.xs
        var x = bounds.minX + contentInset

        for chip in chips {
            let label = truncated(chip.text, fitting: maximumChipLabelWidth)
            let width = measure(label, font: font.base) + padding * 2
            // Off the end of the window: better to show three chips than to show three and a sliver.
            guard x + width <= bounds.maxX - contentInset else { return }

            let chipRect = CGRect(x: x, y: originY, width: width, height: chipHeight)
            let (bg, _, text) = chipColors(for: chip)

            context.setFillColor(bg.cgColor)
            let path = CGPath(
                roundedRect: chipRect, cornerWidth: Theme.Radius.control,
                cornerHeight: Theme.Radius.control, transform: nil)
            context.addPath(path)
            context.fillPath()

            draw(
                label,
                at: CGPoint(
                    x: chipRect.minX + padding,
                    y: originY + (chipHeight - font.cellHeight) / 2 + font.cellHeight
                        - font.baselineFromTop),
                font: font.base, color: text, in: context)
            x = chipRect.maxX + Theme.Spacing.sm
        }
    }

    /// Colors for contextual prompt chips derived from the active theme palette and chip material.
    private func chipColors(for chip: ContextChip) -> (background: NSColor, stroke: NSColor, text: NSColor) {
        let isGlass = chipMaterial == .glass
        switch chip.kind {
        case .directory:
            let accent = palette.ansi[4].nsColor
            let bgAlpha = isGlass ? 0.22 : 0.12
            return (accent.withAlphaComponent(bgAlpha), .clear, palette.foreground.nsColor)
        case .branch:
            let accent = palette.ansi[5].nsColor
            let bgAlpha = isGlass ? 0.24 : 0.14
            return (accent.withAlphaComponent(bgAlpha), .clear, accent)
        case .environment:
            let accent = palette.ansi[2].nsColor
            let bgAlpha = isGlass ? 0.24 : 0.14
            return (accent.withAlphaComponent(bgAlpha), .clear, accent)
        }
    }

    /// A chip is a label, not a path display: a very deep directory truncates rather than pushing the
    /// chips after it off the window.
    private var maximumChipLabelWidth: CGFloat { 240 }

    /// The whole document, scrolled to `scrollPosition` pixels up from the bottom.
    ///
    /// Each block is drawn from its own grids, so a row is addressed inside the block that owns it
    /// rather than by an index into one shared sequence — which is the arithmetic Phase 2 got wrong
    /// twice.
    private func drawBlocks(
        in context: CGContext,
        bounds: CGRect,
        session: TerminalSession,
        layout: BlockLayout,
        scrollPosition: CGFloat,
        showsCursor: Bool,
        markedText: String?,
        cursorBlinkOn: Bool,
        selectedBlockID: BlockID?,
        hoveredBlockID: BlockID?,
        hoveredLink: HoveredLink?,
        selection: TextSelection?,
        chips: [ContextChip]
    ) {
        // Where the top of the viewport sits in the document. Negative when the document is shorter
        // than the window, which is what anchors a short document to the bottom the way a terminal
        // should rather than to the top.
        // **Two viewports.** The scrolling region shows the blocks above the pinned one; the pinned block — the one
        // the shell is writing into — is drawn against a constant viewport top that puts its bottom on the view's
        // bottom. One `viewportTop` for both is what made the prompt scroll off the screen.
        let scrollableTop = layout.scrollableTop(
            scrollPosition: scrollPosition, viewportHeight: bounds.height)
        let pinnedTop = layout.pinnedViewportTop(viewportHeight: bounds.height)
        let pinnedIndex = session.blocks.indices.last
        let blocks = session.blocks

        invalidateCacheIfBlocksChanged(blocks)

        var visible = layout.entries(
            intersecting: scrollableTop,
            scrollableTop + layout.scrollableViewportHeight(bounds.height))
        // The pinned block is visible whatever the scroll position — that is what pinning means — and it is not in
        // the scrolling region's entries once anything is scrolled.
        if let pinned = layout.pinnedEntry, !visible.contains(where: { $0.blockIndex == pinned.blockIndex }) {
            visible.append(pinned)
        }
        // **The scrolling region is clipped to itself.** Nothing above the pinned block may be drawn *below* it: the
        // pinned block paints no background of its own — the terminal paints one fill for the whole view — so scrolled
        // content showed straight through it. Clipping is the honest fix rather than giving the pinned block a
        // background: a background would hide the symptom while the block above was still drawn where it does not
        // belong.
        let scrollingRect = CGRect(
            x: bounds.minX, y: bounds.minY + layout.pinnedHeight, width: bounds.width,
            height: layout.scrollableViewportHeight(bounds.height))

        context.saveGState()
        context.clip(to: scrollingRect)
        for entry in visible where entry.blockIndex != pinnedIndex {
            guard blocks.indices.contains(entry.blockIndex) else { continue }
            let block = blocks[entry.blockIndex]
            drawEntry(
                entry, block: block, viewportTop: scrollableTop,
                isSelected: block.id == selectedBlockID, selection: selection,
                hoveredBlockID: hoveredBlockID, hoveredLink: hoveredLink, chips: chips, bounds: bounds, in: context)
        }
        context.restoreGState()

        // Then the pinned block, **outside that clip**: it is not in the scrolling region and must not be cut by it.
        if let pinned = layout.pinnedEntry, blocks.indices.contains(pinned.blockIndex) {
            let block = blocks[pinned.blockIndex]
            drawEntry(
                pinned, block: block, viewportTop: pinnedTop, isSelected: block.id == selectedBlockID,
                selection: selection, hoveredBlockID: hoveredBlockID, hoveredLink: hoveredLink, chips: chips, bounds: bounds,
                in: context)
        }

        // After the blocks, so a header's own background cannot cover the rule. Every boundary gets one
        // except a boundary that separates nothing: `headerTop` is the sum of everything above, so a
        // zero means every block above this one is empty — which is what a fresh terminal is, and a
        // rule at the top of an empty screen is a line that separates nothing from nothing.
        context.saveGState()
        context.clip(to: scrollingRect)
        for entry in visible where entry.headerTop > 0 && entry.blockIndex != pinnedIndex {
            drawBlockSeparator(
                above: entry, viewportTop: scrollableTop, bounds: bounds, in: context)
        }
        context.restoreGState()
        if let pinned = layout.pinnedEntry, pinned.headerTop > 0 {
            drawBlockSeparator(above: pinned, viewportTop: pinnedTop, bounds: bounds, in: context)
        }

        // `showsCursor` is not "is the view focused" — see `TerminalSurfaceView.shouldDrawGridCursor`. It is
        // "is the shell's cursor the cursor the user should see", which is a narrower question with a narrower
        // answer.
        guard showsCursor, scrollPosition == 0, let activeIndex = blocks.indices.last else { return }
        let entry = layout.entries.first { $0.blockIndex == activeIndex }
        let grid = session.activeGrid
        guard let entry, grid.cursorLine < entry.contentLineCount else { return }
        let documentY = entry.contentTop + CGFloat(grid.cursorLine) * font.cellHeight
        drawCursor(
            in: context, grid: grid,
            originX: bounds.minX + contentInset + CGFloat(grid.cursorColumn) * font.cellWidth,
            // The cursor is on the active block, which is the pinned one, so it is measured against the pinned
            // viewport like the rest of that block.
            originY: screenY(documentY + font.cellHeight, viewportTop: pinnedTop, bounds: bounds),
            markedText: markedText, blinkOn: cursorBlinkOn)
    }

    /// The block list is what decides which grids exist, so a change to it is the one thing that can
    /// invalidate the cache wholesale. Rebuilt as a list rather than a set so it is a few comparisons
    /// in document order, which is the order it is built in.
    private func invalidateCacheIfBlocksChanged(_ blocks: [Block]) {
        var identities: [ObjectIdentifier] = []
        identities.reserveCapacity(blocks.count * 2)
        for block in blocks {
            for blockGrid in block.grids { identities.append(ObjectIdentifier(blockGrid.grid)) }
        }
        guard identities != cachedGrids else { return }
        cachedGrids = identities
        rowCache.removeAll()
    }


    /// One block's entry: its tints, its marks, its header, its hover control, its chips and its rows.
    ///
    /// Split out of the loop so the scrolling entries and the pinned one can be drawn in **two passes** — the first
    /// clipped to the scrolling region and the second outside it. See `drawBlocks` for why that matters.
    private func drawEntry(
        _ entry: BlockLayout.Entry, block: Block, viewportTop: CGFloat, isSelected: Bool,
        selection: TextSelection?, hoveredBlockID: BlockID?, hoveredLink: HoveredLink?,
        chips: [ContextChip], bounds: CGRect, in context: CGContext
    ) {

            let viewportBottom = viewportTop + bounds.height

            // **Under the text and over the tints**, which is the order the layers have to be in: a selection is
            // something the user made and it has to read as being *behind* the characters, or the glyphs it covers
            // look struck through. Drawn before the rows for that reason, not after.
            if let selection {
                drawSelection(
                    selection, entry: entry, block: block, viewportTop: viewportTop, bounds: bounds,
                    in: context)
            }

            // Folded blocks get the same two marks a failed one does — a tint and a leading stripe — in a
            // different colour. See `drawCollapsedMark`.
            if block.isCollapsed {
                drawCollapsedMark(
                    entry: entry, isSelected: isSelected, viewportTop: viewportTop, bounds: bounds,
                    in: context)
            }

            // Under the selection tint: both are translucent washes over the same pixels, and the user's own
            // selection is the one that should read as the stronger statement.
            if block.didSucceed == false {
                drawFailureMark(
                    entry: entry, isSelected: isSelected, viewportTop: viewportTop, bounds: bounds,
                    in: context)
            }

            // Under everything: the header has its own background, and a cell with a background of its
            // own still wins, which is correct — a coloured cell is the program's, not ours.
            if isSelected {
                drawSelectionHighlight(
                    entry: entry, viewportTop: viewportTop, bounds: bounds, in: context)
            }

            if entry.headerHeight > 0, entry.headerTop + entry.headerHeight > viewportTop,
                entry.headerTop < viewportBottom
            {
                drawHeader(
                    block: block,
                    top: screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds),
                    bounds: bounds, in: context)
            }

            // After the header, and only for the block the pointer is over. One control at a time: the dots
            // say which block a menu would act on, and two sets of them would say two things.
            if block.id == hoveredBlockID {
                drawHoverControl(
                    top: screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds),
                    bounds: bounds, in: context)
            }

            // After the header, so its background cannot cover a capsule. A block with no chip row has
            // no height for one, so this is the same call either way.
            drawChips(
                chips, entry: entry, viewportTop: viewportTop, bounds: bounds, in: context)

            // Each grid the block draws, one after another: a submitted block is its command and then its
            // output, which is what Warp's is.
            // A collapsed block draws only its first few lines — and the *layout* was built from the same count,
            // so the blocks below it have already moved up.
            var rowOrigin = entry.contentTop
            var bodyLineCounter = 0
            for (gridIndex, visibleGrid) in block.visibleGrids.enumerated() {
                let contentGrid = visibleGrid.contentGrid
                for row in 0..<visibleGrid.lines {
                    let currentBodyLine = bodyLineCounter
                    bodyLineCounter += 1
                    let documentY = rowOrigin + CGFloat(row) * font.cellHeight
                    guard documentY + font.cellHeight > viewportTop, documentY < viewportBottom
                    else { continue }
                    guard let line = contentGrid.line(at: row) else { continue }
                    let originX = bounds.minX + contentInset
                    let originY = screenY(
                        documentY + font.cellHeight, viewportTop: viewportTop, bounds: bounds)
                    drawRow(
                        row: row, line: line, grid: contentGrid.grid,
                        isFinished: contentGrid.isFinished,
                        // The first grid is what was typed; the rest is what came back.
                        isCommand: gridIndex == 0,
                        originX: originX,
                        originY: originY,
                        in: context)
                    if let hoveredLink, !hoveredLink.isAlternateScreen,
                        hoveredLink.blockIndex == entry.blockIndex,
                        hoveredLink.bodyLine == currentBodyLine {
                        draw(linkUnderline: hoveredLink.colRange, originX: originX, originY: originY, in: context)
                    }
                }
                rowOrigin += CGFloat(visibleGrid.lines) * font.cellHeight
            }
    }
    /// A full-screen program owns the screen: no blocks, no headers, no scrollback.
    private func drawAlternateScreen(
        in context: CGContext, bounds: CGRect, grid: TerminalGrid, hoveredLink: HoveredLink? = nil
    ) {
        for screenRow in 0..<grid.size.rows {
            let row = grid.historyLineCount + screenRow
            guard let line = grid.line(at: row) else { continue }
            let originX = bounds.minX + contentInset
            let originY = bounds.maxY - CGFloat(screenRow + 1) * font.cellHeight
            drawRow(
                row: row, line: line, grid: grid, isFinished: false,
                originX: originX,
                originY: originY,
                in: context)
            if let hoveredLink, hoveredLink.isAlternateScreen, hoveredLink.bodyLine == screenRow {
                draw(linkUnderline: hoveredLink.colRange, originX: originX, originY: originY, in: context)
            }
        }
        drawCursor(
            in: context, grid: grid,
            originX: bounds.minX + contentInset + CGFloat(grid.cursorColumn) * font.cellWidth,
            originY: bounds.maxY - CGFloat(grid.cursorRow + 1) * font.cellHeight,
            markedText: nil, blinkOn: true)
    }

    private func draw(linkUnderline range: Range<Int>, originX: CGFloat, originY: CGFloat, in context: CGContext) {
        let x = originX + CGFloat(range.lowerBound) * font.cellWidth
        let width = CGFloat(range.count) * font.cellWidth
        let baseline = originY + font.cellHeight - font.baselineFromTop
        let (color, _) = CellAttributes().resolvedColors(using: palette)
        context.setStrokeColor(color.nsColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: x, y: baseline - 1))
        context.addLine(to: CGPoint(x: x + width, y: baseline - 1))
        context.strokePath()
    }

    /// Document coordinates are measured down from the top; the view is y-up, so this is the one
    /// place the two are reconciled.
    ///
    /// Not private: the view hit-tests the hover control the renderer drew, so it has to place a point in the
    /// same space. Two reconciliations of the same two coordinate systems is how a control ends up clickable
    /// somewhere other than where it is.
    func screenY(_ documentY: CGFloat, viewportTop: CGFloat, bounds: CGRect) -> CGFloat {
        bounds.maxY - (documentY - viewportTop)
    }

    // MARK: - The hover control

    static let hoverControlWidth: CGFloat = 26
    static let hoverControlHeight: CGFloat = 18
    /// Kept for backwards compatibility if callers inspect size
    static var hoverControlSize: CGFloat { max(hoverControlWidth, hoverControlHeight) }
    private static let hoverControlDotDiameter: CGFloat = 2.5
    private static let hoverControlDotSpacing: CGFloat = 3.0

    /// Where a block's hover control sits: the trailing corner of its header, vertically centered in the header strip.
    func hoverControlRect(top: CGFloat, bounds: CGRect) -> CGRect {
        let height = Theme.Size.blockHeaderHeight
        let y = top - height + (height - Self.hoverControlHeight) / 2
        return CGRect(
            x: bounds.maxX - contentInset - Self.hoverControlWidth,
            y: y,
            width: Self.hoverControlWidth,
            height: Self.hoverControlHeight)
    }

    /// The sleek ellipsis action pill, drawn for the one block the pointer is over.
    func drawHoverControl(top: CGFloat, bounds: CGRect, in context: CGContext) {
        let rect = hoverControlRect(top: top, bounds: bounds)
        guard rect.maxY > bounds.minY, rect.minY < bounds.maxY else { return }

        // Sleek rounded rectangle pill background
        let pillPath = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.setFillColor(palette.foreground.nsColor.withAlphaComponent(0.12).cgColor)
        context.addPath(pillPath)
        context.fillPath()

        // Subtle hairline stroke for crisp definition
        context.setStrokeColor(palette.foreground.nsColor.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(1)
        context.addPath(pillPath)
        context.strokePath()

        // Three horizontal dots (macOS HIG ellipsis)
        let diameter = Self.hoverControlDotDiameter
        let spacing = Self.hoverControlDotSpacing
        context.setFillColor(palette.foreground.nsColor.withAlphaComponent(0.85).cgColor)
        let midX = rect.midX
        let dotY = (rect.midY - diameter / 2).rounded()
        for offset in [-1, 0, 1] {
            let dotX = (midX + CGFloat(offset) * (diameter + spacing) - diameter / 2).rounded()
            context.fillEllipse(in: CGRect(x: dotX, y: dotY, width: diameter, height: diameter))
        }
    }

    // MARK: - Rows

    private func drawRow(
        row: Int, line: TerminalLine, grid: TerminalGrid, isFinished: Bool, isCommand: Bool = false,
        originX: CGFloat, originY: CGFloat, in context: CGContext
    ) {
        let cached = cachedRow(
            row: row, line: line, grid: grid, isFinished: isFinished, isCommand: isCommand)
        for run in cached.runs { draw(background: run, originX: originX, originY: originY, in: context) }
        for run in cached.runs { draw(underline: run, originX: originX, originY: originY, in: context) }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: originX, y: originY + font.cellHeight - font.baselineFromTop)
        CTLineDraw(cached.line, context)
    }

    /// A row's `CTLine`, from the cache whenever the cache can prove it is still current.
    private func cachedRow(
        row: Int, line: TerminalLine, grid: TerminalGrid, isFinished: Bool, isCommand: Bool
    ) -> CachedRow {
        let identity = ObjectIdentifier(grid)
        // A screen row carries its own generation stamp, so it is cached against the row it occupies.
        if let screenRow = grid.screenRow(forLine: row) {
            return cached(
                key: RowKey(grid: identity, row: row, isScreenRow: true, isCommand: isCommand),
                stamp: grid.rowGenerations[screenRow], line: line)
        }
        // A history row has no stamp of its own. In a *finished* grid the history cannot change except
        // by a resize, and a resize bumps the grid's generation — so there the grid's generation is a
        // sound key and the row is built once, which is the memoisation Warp gets from sealing a grid.
        // In a live grid it is not sound, so the row is rebuilt every frame: that is what Phase 1
        // settled on after the cache bug in `learnings.md`.
        guard isFinished else { return build(line: line, isCommand: isCommand) }
        return cached(
            key: RowKey(grid: identity, row: row, isScreenRow: false, isCommand: isCommand),
            stamp: grid.generation, line: line)
    }

    private func cached(key: RowKey, stamp: UInt64, line: TerminalLine) -> CachedRow {
        let isCommand = key.isCommand
        if let hit = rowCache[key], hit.generation == stamp { return hit }
        // Scrolling through a long sealed block would otherwise cache every row it ever showed, so
        // the cache is emptied wholesale rather than grown without a bound. It is one frame of
        // rebuilding, and it is the same thing a font change already does.
        if rowCache.count >= Self.maximumCachedRows { rowCache.removeAll() }
        var built = build(line: line, isCommand: isCommand)
        built.generation = stamp
        rowCache[key] = built
        return built
    }

    /// Builds a row's line and its runs. Instance-level rather than static because both the font and
    /// the palette are baked into the attributed string.
    private func build(line: TerminalLine, isCommand: Bool = false) -> CachedRow {
        let runs = Self.runs(for: line)
        let attributed = NSMutableAttributedString()
        for run in runs { attributed.append(attributedString(for: run, isCommand: isCommand)) }
        return CachedRow(
            generation: 0, line: CTLineCreateWithAttributedString(attributed), runs: runs)
    }

    /// Splits a row into stretches that can each be one `CTLine`. A glyph wider than one column is
    /// always its own run: a monospace face does not promise a double-width advance, so placing it at
    /// its own column is the only way to keep the columns after it lined up.
    private static func runs(for line: TerminalLine) -> [Run] {
        var runs: [Run] = []
        let cells = line.cells
        var index = 0
        while index < cells.count {
            let start = index
            let attributes = cells[index].attributes
            var text = ""
            while index < cells.count, cells[index].attributes == attributes {
                let cell = cells[index]
                if !cell.isContinuation { text += cell.text.isEmpty ? " " : cell.text }
                index += 1
                if cell.width != 1 { break }
            }
            runs.append(
                Run(column: start, columns: index - start, attributes: attributes, string: text))
        }
        return runs
    }

    /// One run as an attributed string.
    ///
    /// `isCommand` is the block's **first** grid — what was typed — and it is drawn bold. Warp does not do this:
    /// it applies one `appearance.monospace_font_weight()` to the whole grid
    /// (`crates/warp_core/src/ui/appearance.rs`, used by `blockgrid_element.rs`), so on Warp's own code the
    /// command and the output weigh the same. This is a deliberate divergence, asked for directly and twice, and
    /// the honest statement of it is that it separates what you asked for from what came back. Flip this one
    /// flag to match Warp exactly.
    private func attributedString(for run: Run, isCommand: Bool = false) -> NSAttributedString {
        let (foreground, _) = run.attributes.resolvedColors(using: palette)
        var color = foreground.nsColor
        if run.attributes.flags.contains(.hidden) {
            color = .clear
        } else if run.attributes.flags.contains(.faint) {
            // Faint has no lighter weight in a monospace face, so it is drawn as ink instead.
            color = color.withAlphaComponent(0.6)
        }
        let runFont = font.font(for: run.attributes.flags)
        return NSAttributedString(
            string: run.string,
            attributes: [
                .font: isCommand
                    ? NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) : runFont,
                .foregroundColor: color,
            ])
    }

    private func draw(background run: Run, originX: CGFloat, originY: CGFloat, in context: CGContext) {
        let (_, background) = run.attributes.resolvedColors(using: palette)
        guard background != palette.background else { return }
        context.setFillColor(background.nsColor.cgColor)
        context.fill(
            CGRect(
                x: originX + CGFloat(run.column) * font.cellWidth,
                y: originY,
                width: CGFloat(run.columns) * font.cellWidth,
                height: font.cellHeight))
    }

    private func draw(underline run: Run, originX: CGFloat, originY: CGFloat, in context: CGContext) {
        guard run.attributes.hasUnderline else { return }
        let (foreground, _) = run.attributes.resolvedColors(using: palette)
        context.setStrokeColor(foreground.nsColor.cgColor)
        let x = originX + CGFloat(run.column) * font.cellWidth
        let width = CGFloat(run.columns) * font.cellWidth
        // One point below the baseline, so the rule never touches the descenders above it.
        let baseline = originY + font.cellHeight - font.baselineFromTop

        if run.attributes.flags.contains(.doubleUnderline) {
            context.setFillColor(foreground.nsColor.cgColor)
            context.fill(CGRect(x: x, y: baseline - 2, width: width, height: 1))
            context.fill(CGRect(x: x, y: baseline - 4, width: width, height: 1))
            return
        }
        context.setLineWidth(1)
        if run.attributes.flags.contains(.dottedUnderline) || run.attributes.flags.contains(.dashedUnderline)
            || run.attributes.flags.contains(.curlyUnderline)
        {
            context.setLineDash(phase: 0, lengths: [2, 2])
        }
        context.move(to: CGPoint(x: x, y: baseline - 1))
        context.addLine(to: CGPoint(x: x + width, y: baseline - 1))
        context.strokePath()
    }

    // MARK: - Headers

    /// The block's header: where the command ran and how long it took, and nothing else.
    ///
    /// Warp's header line is `~/path · 16ms` — no command. The command is the block's first *body* line
    /// now, which is where Warp puts it, so drawing it here as well would say it twice. (`commandText`
    /// is still what the Copy Command menu item uses.)
    ///
    /// **There is no status dot, and that is Warp's design rather than an omission.** Warp has none: a failed
    /// block is marked by a wash over it and a stripe down its leading edge (`draw_flag_pole`), and a block
    /// that succeeded is marked by *nothing at all*. A green dot on every successful block is a mark on the
    /// overwhelming majority of them, which is a mark that carries no information — and the red one beside it
    /// is then read as decoration rather than as a warning. The mark belongs on the failure.
    private func drawHeader(
        block: Block, top: CGFloat, bounds: CGRect, in context: CGContext
    ) {
        let height = Theme.Size.blockHeaderHeight
        let strip = CGRect(x: bounds.minX, y: top - height, width: bounds.width, height: height)

        // No background of its own. A header is dim text on the terminal's own background and a thin
        // rule between blocks, which is what Warp's is — and a strip that painted itself was two
        // problems: it was a second signal saying what the rule already says, and at 26pt it reached
        // past its own row into the chips below it. A selected block's tint still covers the header,
        // because the tint is painted before this.
        //
        // **Left-aligned, in the terminal's own font, like Warp's.**
        //
        // It reads `~/path (16ms)` starting at the content inset — the same column the command below it starts
        // in — and not as a proportional label pushed to the trailing edge. Warp builds it as a `Flex::row` of
        // the prompt followed by the duration, both in `appearance.monospace_font_family()` at the prompt's own
        // weight (`app/src/terminal/view.rs`), which is why it reads as part of the block rather than as chrome
        // floating over it. A right-aligned label in a second typeface is the thing that made this look like a
        // status bar.
        //
        // The directory is a record of where a command *ran* — it stays right for a block from an hour ago,
        // which a chip above the prompt can only ever say for now.
        let label = [
            block.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath },
            block.duration.map { "(\(Self.durationText($0)))" },
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let baseline = strip.minY + (height - font.cellHeight) / 2 + font.cellHeight - font.baselineFromTop

        if !label.isEmpty {
            draw(
                label, at: CGPoint(x: strip.minX + contentInset, y: baseline),
                font: font.base, color: dimInk, in: context)
        }
    }

    /// How wide the stripe down a failed block's leading edge is.
    ///
    /// Warp's `LEFT_STRIPE_WIDTH` (`app/src/terminal/warpify/render.rs`), which is also the width it uses for
    /// the AI context stripe and the subshell stripe. It sits in the content inset's margin, so it never
    /// touches a glyph.
    private static let failureStripeWidth: CGFloat = 5

    /// A failed block: a wash over the whole of it, and a solid stripe down its leading edge.
    ///
    /// **Both, because they answer different questions.** The wash says *which* block failed when you are
    /// reading it; the stripe says that one did when you are scrolling past it, which a 10%-opacity wash
    /// cannot do at speed. Warp draws both, and drops the stripe while the block is selected — the selection
    /// tint is already saying something about this block, and two marks on one edge fight.
    ///
    /// Painted before the block's own content, so a cell with a background of its own still wins: a coloured
    /// cell is the program's, not ours.
    private func drawFailureMark(
        entry: BlockLayout.Entry, isSelected: Bool, viewportTop: CGFloat, bounds: CGRect,
        in context: CGContext
    ) {
        let top = screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds)
        let bottom = screenY(entry.bottom, viewportTop: viewportTop, bounds: bounds)
        let height = max(0, top - bottom)
        guard height > 0 else { return }

        context.setFillColor(failureWash.cgColor)
        context.fill(CGRect(x: bounds.minX, y: bottom, width: bounds.width, height: height))

        guard !isSelected else { return }
        context.setFillColor(failureStripe.cgColor)
        context.fill(CGRect(x: bounds.minX, y: bottom, width: Self.failureStripeWidth, height: height))
    }

    /// The selected text, as one rectangle per line.
    ///
    /// A rectangle per line rather than one rectangle for the range: a selection that crosses a short line is not a
    /// rectangle, and filling one would paint over text that is not selected — which is the difference between a
    /// highlight that says what will be copied and one that lies about it.
    private func drawSelection(
        _ selection: TextSelection, entry: BlockLayout.Entry, block: Block,
        viewportTop: CGFloat, bounds: CGRect, in context: CGContext
    ) {
        guard !selection.isEmpty else { return }
        context.setFillColor(selectionInk.cgColor)

        for bodyLine in 0..<entry.contentLineCount {
            guard let text = block.bodyLineText(bodyLine) else { continue }
            let trimmed = Self.trimmedLength(text)
            guard
                let columns = selection.columnRange(
                    forBodyLine: bodyLine, inBlock: entry.blockIndex, lineLength: trimmed)
            else { continue }

            let documentY = entry.contentTop + CGFloat(bodyLine) * font.cellHeight
            let originY = screenY(
                documentY + font.cellHeight, viewportTop: viewportTop, bounds: bounds)
            guard originY + font.cellHeight > bounds.minY, originY < bounds.maxY else { continue }

            context.fill(
                CGRect(
                    x: bounds.minX + contentInset + CGFloat(columns.lowerBound) * font.cellWidth,
                    y: originY,
                    width: CGFloat(columns.count) * font.cellWidth,
                    height: font.cellHeight))
        }
    }

    /// How much of a row is text. A terminal row is a rectangle and the text in it is not, so a selection dragged to
    /// the right edge stops at the last character rather than copying a screenful of blanks.
    static func trimmedLength(_ text: String) -> Int {
        var count = text.count
        for character in text.reversed() {
            guard character == " " || character == "\t" else { break }
            count -= 1
        }
        return count
    }

    /// The palette's own selection colour, which is what a terminal has used since long before this app: the cursor
    /// colour at low alpha reads as "this text is chosen" in every palette, and a new colour would have to be right
    /// in all of them.
    private var selectionInk: NSColor { palette.cursor.nsColor.withAlphaComponent(0.28) }

    /// A folded block: a wash over it, and a stripe down its leading edge.
    ///
    /// **Not an icon and not a glyph.** A folded block is a block *hiding* something, and the honest way to say so
    /// on a grid of text is with the two marks a failed block already uses — a tint and a stripe — rather than by
    /// putting a character where a character would otherwise be. It reuses that geometry deliberately: a leading
    /// stripe is already this terminal's "this block has a state" mark.
    ///
    /// The palette's **blue**, not the red of a failure: a folded block is not a problem, and reusing the failure
    /// colour would say that it was.
    private func drawCollapsedMark(
        entry: BlockLayout.Entry, isSelected: Bool, viewportTop: CGFloat, bounds: CGRect,
        in context: CGContext
    ) {
        let top = screenY(entry.headerTop, viewportTop: viewportTop, bounds: bounds)
        let bottom = screenY(entry.bottom, viewportTop: viewportTop, bounds: bounds)
        let height = max(0, top - bottom)
        guard height > 0 else { return }

        context.setFillColor(collapsedWash.cgColor)
        context.fill(CGRect(x: bounds.minX, y: bottom, width: bounds.width, height: height))

        guard !isSelected else { return }
        context.setFillColor(collapsedStripe.cgColor)
        context.fill(CGRect(x: bounds.minX, y: bottom, width: Self.failureStripeWidth, height: height))
    }

    private var collapsedStripe: NSColor { palette.ansi[4].nsColor }

    /// Fainter than the failure wash, because folding a block is something the *user* did: it needs to be findable,
    /// not alarming.
    private var collapsedWash: NSColor { palette.ansi[4].nsColor.withAlphaComponent(0.08) }

    /// The palette's red, which is where a terminal's "this went wrong" already lives — no colour enters the
    /// palette that was not in it, the same rule the outline and the chip background follow.
    private var failureStripe: NSColor { palette.ansi[1].nsColor }

    /// Warp's wash is `failed_block_color().with_opacity(10)` — ten percent, which is a tint you read as
    /// "something is off about this block" without it competing with the output inside it.
    private var failureWash: NSColor { palette.ansi[1].nsColor.withAlphaComponent(0.1) }

    private var dimInk: NSColor { palette.foreground.nsColor.withAlphaComponent(0.55) }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private func truncated(_ text: String, fitting width: CGFloat) -> String {
        guard measure(text, font: font.base) > width else { return text }
        var result = text
        while !result.isEmpty, measure(result + "…", font: font.base) > width {
            result.removeLast()
        }
        return result + "…"
    }

    private func draw(
        _ text: String, at point: CGPoint, font: NSFont, color: NSColor, in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        guard seconds >= 60 else { return String(format: "%.2fs", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    // MARK: - Cursor

    private func drawCursor(
        in context: CGContext, grid: TerminalGrid,
        originX: CGFloat, originY: CGFloat, markedText: String?, blinkOn: Bool
    ) {
        guard grid.modes.cursorVisible, blinkOn else { return }
        let cell = CGRect(x: originX, y: originY, width: font.cellWidth, height: font.cellHeight)
        let thickness = max(1, font.cellWidth / 8)

        context.setFillColor(palette.cursor.nsColor.cgColor)
        switch grid.cursorStyle.shape {
        case .block: context.fill(cell)
        case .bar: context.fill(CGRect(x: originX, y: originY, width: thickness, height: font.cellHeight))
        case .underline: context.fill(CGRect(x: originX, y: originY, width: font.cellWidth, height: thickness))
        }

        if let markedText, !markedText.isEmpty {
            drawMarkedText(markedText, at: cell, in: context)
            return
        }
        // The character under a block cursor is repainted in the background colour, which is what
        // makes the cursor read as behind the text rather than over it.
        guard grid.cursorStyle.shape == .block,
            let line = grid.line(at: grid.cursorLine),
            line.cells.indices.contains(grid.cursorColumn)
        else { return }
        let cellContent = line.cells[grid.cursorColumn]
        guard !cellContent.isContinuation, !cellContent.text.isEmpty, cellContent.text != " " else { return }
        let attributed = NSAttributedString(
            string: cellContent.text,
            attributes: [
                .font: font.font(for: cellContent.attributes.flags),
                .foregroundColor: palette.background.nsColor,
            ])
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: originX, y: originY + font.cellHeight - font.baselineFromTop)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// Composed-but-uncommitted input — an IME candidate, a dead key's accent — is drawn at the
    /// cursor with an underline, which is what every text field on the platform does.
    private func drawMarkedText(_ text: String, at cell: CGRect, in context: CGContext) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font.base,
                .foregroundColor: palette.foreground.nsColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        let width = CGFloat(text.count) * font.cellWidth
        context.setFillColor(palette.background.nsColor.cgColor)
        context.fill(CGRect(x: cell.minX, y: cell.minY, width: width, height: cell.height))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: cell.minX, y: cell.minY + font.cellHeight - font.baselineFromTop)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}

extension TerminalRGB {
    /// The only place a terminal colour becomes an AppKit colour. Everything above this line is
    /// palette-free, which is what lets the emulator be tested without a window server.
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1)
    }
}
