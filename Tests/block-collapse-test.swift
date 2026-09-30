import AppKit

@main @MainActor enum BlockCollapseTest {
    static func main() async throws {
        let harness = Harness("block-collapse-test")
        let home = FileManager.default.temporaryDirectory.appending(path: "swiftterm-collapse-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = try TerminalSession(size: .fallback,
            environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": home.path, "PS1": ""],
            homeDirectory: home.path)
        session.historyStore = CommandHistoryStore(url: home.appending(path: "history"))
        defer { session.stop() }
        let surface = TerminalSurfaceView(session: session, pointSize: 14)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        surface.frame = NSRect(x: 35, y: 50, width: 800, height: 500)
        parent.addSubview(surface)
        session.write("printf '\\033]133;A\\007\\033]133;B\\007\\033]133;C\\007'; "
                      + "seq 1 80; printf '\\033]133;D;0\\007\\033]133;A\\007\\033]133;B\\007\\033]133;C\\007'; "
                      + "seq 1 70; printf '\\033]133;D;0\\007\\033]133;A\\007\\033]133;B\\007'\n")
        let deadline = ContinuousClock.now + .seconds(5)
        while session.blocks.count != 3 || session.activeBlock?.headerGrid.promptEnd == nil,
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        harness.equal(session.blocks.count, 3, "scratch shell creates two completed blocks and a prompt")
        guard session.blocks.count == 3 else { harness.finish() }
        let block = session.blocks[0]
        let font = TerminalFont(pointSize: 14)
        let layout = BlockLayout(contributions: session.blockGeometry,
            chipRow: BlockLayout.ChipRow(blockIndex: 2, height: Theme.Size.contextChipHeight),
            headerHeight: Theme.Size.blockHeaderHeight, lineHeight: font.cellHeight,
            bottomPadding: font.cellHeight * Theme.Typography.blockBottomPaddingRatio)
        let top = layout.scrollableTop(scrollPosition: 0, viewportHeight: surface.bounds.height)
        let initialPoint = CGPoint(x: 100, y: surface.bounds.maxY + top - Theme.Size.blockHeaderHeight / 2)
        _ = surface.menu(for: event(.rightMouseDown, at: initialPoint, in: surface))
        harness.equal(surface.selectedBlock?.id, block.id, "header hit testing converts nested view coordinates")
        surface.scrollToSelectedBlock(nil)
        let header = CGPoint(x: 100, y: surface.bounds.maxY - Theme.Size.blockHeaderHeight / 2)
        surface.mouseDown(with: event(.leftMouseDown, at: header, in: surface, count: 1))
        harness.expect(!block.isCollapsed, "first click only selects the expanded block")
        surface.mouseDown(with: event(.leftMouseDown, at: header, in: surface, count: 2))
        harness.expect(block.isCollapsed, "double-click collapses the block")
        harness.expect(surface.menu(for: event(.rightMouseDown, at: header, in: surface)) != nil,
                       "collapse immediately keeps the header under the pointer with no shell update")
        surface.mouseDown(with: event(.leftMouseDown, at: header, in: surface, count: 1))
        harness.expect(block.isCollapsed, "first click of an expansion leaves the block folded")
        surface.mouseDown(with: event(.leftMouseDown, at: header, in: surface, count: 2))
        harness.expect(!block.isCollapsed, "double-click expands once instead of folding again")
        harness.equal(surface.selectedBlock?.id, block.id, "expansion acts on the same block")
        surface.toggleSelectedBlockCollapsed(nil)
        harness.expect(block.isCollapsed, "menu action uses the same collapse transition")
        harness.expect(surface.menu(for: event(.rightMouseDown, at: header, in: surface)) != nil,
                       "menu collapse also updates scroll geometry immediately")
        surface.toggleSelectedBlockCollapsed(nil)
        harness.expect(!block.isCollapsed, "menu action expands the block")
        let body = CGPoint(x: 100, y: surface.bounds.maxY - Theme.Size.blockHeaderHeight - font.cellHeight / 2)
        surface.mouseDown(with: event(.leftMouseDown, at: body, in: surface, count: 2))
        harness.expect(!block.isCollapsed, "double-clicking body text does not collapse the block")
        try await fullscreenGeometry(harness, surface: surface, session: session, font: font)
        harness.finish()
    }

    private static func fullscreenGeometry(
        _ harness: Harness, surface: TerminalSurfaceView, session: TerminalSession, font: TerminalFont
    ) async throws {
        let columns = Int(surface.bounds.width / font.cellWidth)
        let rows = Int(surface.bounds.height / font.cellHeight)
        let expected = "\u{1B}[<0;2;1M\u{1B}[<0;\(columns);\(rows)M"
        session.write("stty -echo -icanon min 1 time 0; "
                      + "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; "
                      + "dd bs=1 count=\(expected.utf8.count) 2>/dev/null | od -An -tu1; "
                      + "printf 'MOUSE_DONE'; sleep 1; stty sane; "
                      + "printf '\\033[?1000l\\033[?1006l\\033[?1049l'\n")
        let deadline = ContinuousClock.now + .seconds(5)
        while !session.isAlternateScreen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        harness.expect(session.isAlternateScreen, "scratch shell enters fullscreen mode")
        harness.equal(session.size.columns, columns, "fullscreen entry updates PTY columns without a window resize")
        surface.mouseDown(with: event(.leftMouseDown,
            at: CGPoint(x: font.cellWidth + 1, y: surface.bounds.maxY - font.cellHeight / 2), in: surface))
        surface.mouseDown(with: event(.leftMouseDown,
            at: CGPoint(x: surface.bounds.maxX - 1, y: surface.bounds.minY + 1), in: surface))
        while !session.activeGrid.screenContains("MOUSE_DONE"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = session.activeGrid.screenText.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let bytes = expected.utf8.map { String($0) }.joined(separator: " ")
        harness.expect(text.contains(bytes), "SGR mouse coordinates match the full-width cells and bottom corner")
        while session.isAlternateScreen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        harness.expect(!session.isAlternateScreen, "scratch shell exits fullscreen mode")
        harness.equal(session.size.columns,
            Int((surface.bounds.width - Theme.Size.terminalContentInset * 2) / font.cellWidth),
            "normal block padding and PTY columns return on fullscreen exit")
    }

    private static func event(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, count: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
}
