import Foundation

/// The byte state machine that turns PTY output into grid mutations and events.
///
/// It is deliberately not a delegate: the parser owns *a* grid and calls it directly. That keeps
/// the escape-sequence vocabulary in one switch instead of spread across a protocol, and it means
/// a harness can assert on a grid after feeding bytes with no wiring in between.
///
/// The grid is settable because a block owns its own. The shell's output moves from a block's
/// prompt-and-command grid to its output grid when the command is submitted, and to the next block's
/// grid when the prompt comes round again — the parser's shape does not change, only where it writes.
final class VTParser {
    var grid: TerminalGrid

    /// Reported upward for everything that is not a grid mutation.
    var onEvent: ((TerminalEvent) -> Void)?
    /// Bytes the terminal must send back, for the handful of queries a program waits on.
    var onReply: ((String) -> Void)?

    /// Where a sequence is being collected. Strings (OSC, DCS, SOS/PM/APC) share a mode because
    /// they all run until a terminator and only differ in what happens when it arrives.
    private enum Mode {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case csiIntermediate
        case osc
        case dcs
        case sos
    }

    private var mode: Mode = .ground
    /// Set when ESC interrupts a string, so `ESC \` can be recognised as its terminator rather
    /// than as the start of an escape sequence.
    private var resumeAfterEscape: Mode?
    private var intermediates: [UInt8] = []
    private var parameterBytes: [UInt8] = []
    private var privateMarker: UInt8 = 0
    private var stringPayload: [UInt8] = []
    private var decoder = VTStringDecoder()
    private var lastPrinted: Character?

    /// A single OSC or DCS longer than this is a runaway or an attack; it is dropped, not stored.
    private static let maximumStringLength = 64 * 1024

    init(grid: TerminalGrid) {
        self.grid = grid
    }

    func feed(_ bytes: [UInt8]) {
        for byte in bytes { step(byte) }
    }

    func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    // MARK: - Dispatch

    private func step(_ byte: UInt8) {
        switch mode {
        case .ground: stepGround(byte)
        case .escape: stepEscape(byte)
        case .escapeIntermediate: stepIntermediate(byte)
        case .csi: stepCSI(byte)
        case .csiIntermediate: stepIntermediate(byte)
        case .osc: stepString(byte, terminatesOnBell: true)
        case .dcs, .sos: stepString(byte, terminatesOnBell: false)
        }
    }

    private func stepGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            enterEscape(from: .ground)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            executeControl(byte)
        case 0x7F:
            break                                   // DEL is ignored
        default:
            print(byte)
        }
    }

    private func stepEscape(_ byte: UInt8) {
        if byte == 0x5C {                           // ESC \ — string terminator, or a no-op
            guard let resume = resumeAfterEscape else {
                mode = .ground
                return
            }
            resumeAfterEscape = nil
            finishString(resume)
            return
        }
        resumeAfterEscape = nil
        switch byte {
        case 0x1B:
            enterEscape(from: .ground)
        case 0x5B:
            mode = .csi
        case 0x5D:
            enterString(.osc)
        case 0x50:
            enterString(.dcs)
        case 0x58, 0x5E, 0x5F:
            enterString(.sos)                       // SOS, PM and APC all run to ST and are dropped
        case 0x20...0x2F:
            intermediates.append(byte)
            mode = .escapeIntermediate
        case 0x30...0x7E:
            dispatchEscape(byte)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            executeControl(byte)
        default:
            break
        }
    }

    private func stepIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            enterEscape(from: .ground)
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x30...0x7E:
            if mode == .csiIntermediate {
                dispatchCSI(byte)
            } else {
                dispatchEscape(byte)
            }
        default:
            break
        }
    }

    private func stepCSI(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            enterEscape(from: .csi)
        case 0x20...0x2F:
            intermediates.append(byte)
            mode = .csiIntermediate
        case 0x30...0x3B:
            parameterBytes.append(byte)
        case 0x3C...0x3F:
            privateMarker = byte
        case 0x40...0x7E:
            dispatchCSI(byte)
        default:
            break                                   // C0 inside a CSI is ignored
        }
    }

    private func stepString(_ byte: UInt8, terminatesOnBell: Bool) {
        if terminatesOnBell, byte == 0x07 {
            finishString(mode)
            return
        }
        if byte == 0x1B {
            enterEscape(from: mode)
            return
        }
        if byte == 0x9C {                           // 8-bit ST
            finishString(mode)
            return
        }
        guard stringPayload.count < Self.maximumStringLength else { return }
        stringPayload.append(byte)
    }

    private func enterEscape(from previous: Mode) {
        switch previous {
        case .osc, .dcs, .sos: resumeAfterEscape = previous
        default: resumeAfterEscape = nil
        }
        mode = .escape
        intermediates.removeAll()
        parameterBytes.removeAll()
        privateMarker = 0
        // A partial codepoint cannot be completed by an escape sequence, so it is abandoned.
        decoder.reset()
    }

    /// Starts a string state. The payload is cleared rather than carried over, because an
    /// abandoned string's bytes belong to a sequence that never completed.
    private func enterString(_ target: Mode) {
        stringPayload.removeAll()
        mode = target
    }

    private func finishString(_ resume: Mode) {
        switch resume {
        case .osc: dispatchOSC()
        case .dcs: break                            // Phase 2 reads Warp's hook channel here
        default: break
        }
        stringPayload.removeAll()
        mode = .ground
    }

    // MARK: - C0 and printing

    private func executeControl(_ byte: UInt8) {
        if byte == 0x07 { onEvent?(.bell) }
        grid.applyControl(byte)
    }

    private func print(_ byte: UInt8) {
        decoder.feed([byte]) { character in
            lastPrinted = character
            grid.put(character)
        }
    }

    // MARK: - ESC

    private func dispatchEscape(_ final: UInt8) {
        let slot = intermediates.first ?? 0
        defer {
            mode = .ground
            intermediates.removeAll()
            parameterBytes.removeAll()
            privateMarker = 0
        }
        switch slot {
        case 0x28, 0x29, 0x2A, 0x2B:                // G0–G3 designation
            grid.pen.designate(final == 0x30 ? .decSpecialGraphics : .ascii, slot: slot)
        case 0x23 where final == 0x38:              // ESC # 8, the alignment test
            grid.screenAlignmentTest()
        case 0x20 where final == 0x47:              // ESC SP G, 8-bit controls; nothing to do
            break
        default:
            dispatchEscapeFinal(final)
        }
    }

    private func dispatchEscapeFinal(_ final: UInt8) {
        switch final {
        case 0x37: grid.saveCursor()                // DECSC
        case 0x38: grid.restoreCursor()             // DECRC
        case 0x44: grid.lineFeed()                  // IND
        case 0x45: grid.nextLine()                  // NEL
        case 0x48: grid.setTabStop()                // HTS
        case 0x4D: grid.reverseIndex()              // RI
        case 0x63: grid.reset()                     // RIS
        case 0x3D: grid.modes.applicationKeypad = true
        case 0x3E: grid.modes.applicationKeypad = false
        default: break
        }
    }

    // MARK: - CSI

    private func dispatchCSI(_ final: UInt8) {
        let parameters = parsedParameters()
        let raw = String(decoding: parameterBytes, as: UTF8.self)
        let isPrivate = privateMarker == 0x3F
        let isSecondary = privateMarker == 0x3E
        let intermediate = intermediates.first ?? 0

        defer {
            mode = .ground
            intermediates.removeAll()
            parameterBytes.removeAll()
            privateMarker = 0
        }

        func value(_ index: Int, _ fallback: Int) -> Int {
            guard parameters.indices.contains(index), let parameter = parameters[index] else { return fallback }
            return parameter
        }

        switch final {
        case 0x40: grid.insertCharacters(value(0, 1))                       // ICH
        case 0x41: grid.moveCursor(rowDelta: -value(0, 1))                  // CUU
        case 0x42: grid.moveCursor(rowDelta: value(0, 1))                   // CUD
        case 0x43: grid.moveCursor(columnDelta: value(0, 1))                // CUF
        case 0x44: grid.moveCursor(columnDelta: -value(0, 1))               // CUB
        case 0x45: grid.moveCursor(rowDelta: value(0, 1)); grid.carriageReturn()
        case 0x46: grid.moveCursor(rowDelta: -value(0, 1)); grid.carriageReturn()
        case 0x47: grid.setCursorColumn(value(0, 1) - 1)                    // CHA
        case 0x48, 0x66:                                                    // CUP, HVP
            grid.setCursorPosition(row: value(0, 1), column: value(1, 1))
        case 0x49: repeatCount(value(0, 1)) { grid.horizontalTab() }        // CHT
        case 0x4A:                                                          // ED
            let eraseMode = value(0, 0)
            grid.eraseInDisplay(mode: eraseMode)
            // **`clear`.** `CSI 2 J` empties the screen and `CSI 3 J` also drops the scrollback; in a terminal made of
            // blocks the blocks that were on that screen are gone rather than scrolled away, which is what Warp does —
            // running `clear` in Warp leaves one prompt and nothing above it.
            //
            // **Only on the primary screen.** A full-screen program erases the display constantly — `nano` on every
            // repaint, `htop` on every refresh — and dropping the scrollback each time would be a terminal that forgot
            // its history whenever a TUI blinked. The alternate screen is a program's own canvas, not the session's
            // scrollback.
            if (eraseMode == 2 || eraseMode == 3), !grid.isAlternateScreen {
                onEvent?(.displayCleared)
            }
        case 0x4B: grid.eraseInLine(mode: value(0, 0))                      // EL
        case 0x4C: grid.insertLines(value(0, 1))                            // IL
        case 0x4D: grid.deleteLines(value(0, 1))                            // DL
        case 0x50: grid.deleteCharacters(value(0, 1))                       // DCH
        case 0x53: grid.scrollUp(value(0, 1))                               // SU
        case 0x54: grid.scrollDown(value(0, 1))                             // SD
        case 0x58: grid.eraseCharacters(value(0, 1))                        // ECH
        case 0x5A: repeatCount(value(0, 1)) { grid.horizontalTabBack() }    // CBT
        case 0x60: grid.setCursorColumn(value(0, 1) - 1)                    // HPA
        case 0x61: grid.setCursorRow(value(0, 1) - 1)                       // VPA
        case 0x62: repeatLastCharacter(value(0, 1))                         // REP
        case 0x63: reportDeviceAttributes(isSecondary: isSecondary)         // DA
        case 0x64: grid.moveCursor(rowDelta: value(0, 1))                   // VPR
        case 0x65: grid.moveCursor(rowDelta: -value(0, 1))                  // VPB
        case 0x67: grid.clearTabStops(mode: value(0, 0))                    // TBC
        case 0x68: applyModes(parameters, enabled: true, isPrivate: isPrivate)
        case 0x6C: applyModes(parameters, enabled: false, isPrivate: isPrivate)
        case 0x6D: applySGR(raw)                                            // SGR
        case 0x6E: reportDeviceStatus(value(0, 0))                          // DSR
        case 0x70 where intermediate == 0x21: softReset()                   // DECSTR
        case 0x71 where intermediate == 0x20:                              // DECSCUSR
            grid.setCursorStyle(TerminalCursorStyle(decscusr: value(0, 0)))
        case 0x72:                                                          // DECSTBM
            grid.setScrollRegion(top: value(0, 1) - 1, bottom: value(1, grid.size.rows) - 1)
        case 0x73: grid.saveCursor()                                        // SCOSC
        case 0x75: grid.restoreCursor()                                     // SCORC
        default: break
        }
    }

    private func parsedParameters() -> [Int?] {
        guard !parameterBytes.isEmpty else { return [] }
        return String(decoding: parameterBytes, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? nil : Int($0) }
    }

    private func repeatCount(_ count: Int, _ body: () -> Void) {
        for _ in 0..<max(0, min(count, grid.size.columns)) { body() }
    }

    private func repeatLastCharacter(_ count: Int) {
        guard let character = lastPrinted else { return }
        for _ in 0..<max(0, min(count, grid.size.columns)) { grid.put(character) }
    }

    private func applyModes(_ parameters: [Int?], enabled: Bool, isPrivate: Bool) {
        for mode in parameters.compactMap({ $0 }) {
            guard isPrivate else {
                grid.modes.apply(mode: mode, enabled: enabled, isPrivate: false)
                continue
            }
            switch mode {
            case 47, 1047, 1049: grid.setAlternateScreen(enabled)
            case 1048: enabled ? grid.saveCursor() : grid.restoreCursor()
            default: grid.modes.apply(mode: mode, enabled: enabled, isPrivate: true)
            }
        }
    }

    private func softReset() {
        grid.pen.attributes = CellAttributes()
        grid.pen.pendingWrap = false
        grid.modes.insert = false
        grid.modes.originMode = false
        grid.modes.automaticWrap = true
        grid.modes.applicationCursorKeys = false
        grid.modes.cursorVisible = true
        grid.modes.mouseTracking = .none
        grid.modes.mouseSGR = false
        grid.modes.bracketedPaste = false
        grid.modes.applicationKeypad = false
        grid.setScrollRegion(top: 0, bottom: grid.size.rows - 1)
        grid.resetTabStops()
    }

    private func reportDeviceAttributes(isSecondary: Bool) {
        onReply?(isSecondary ? "\u{1B}[>0;0;0c" : "\u{1B}[?1;2c")
    }

    private func reportDeviceStatus(_ request: Int) {
        switch request {
        case 5:
            onReply?("\u{1B}[0n")
        case 6:
            let row = grid.modes.originMode ? grid.cursorRow - grid.scrollTop + 1 : grid.cursorRow + 1
            onReply?("\u{1B}[\(row);\(grid.cursorColumn + 1)R")
        default:
            break
        }
    }

    // MARK: - SGR

    private func applySGR(_ raw: String) {
        var attributes = grid.pen.attributes
        let source = raw.isEmpty ? "0" : raw
        let groups = source.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < groups.count {
            let parts = groups[index].split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            let code = parts.first.flatMap { $0 } ?? 0
            switch code {
            case 0: attributes = CellAttributes()
            case 1: attributes.flags.insert(.bold)
            case 2: attributes.flags.insert(.faint)
            case 3: attributes.flags.insert(.italic)
            case 4:
                attributes.flags.subtract(.anyUnderline)
                attributes.flags.insert(Self.underlineFlag(style: parts.count > 1 ? parts[1] ?? 1 : 1))
            case 5, 6: attributes.flags.insert(.blink)
            case 7: attributes.flags.insert(.reverse)
            case 8: attributes.flags.insert(.hidden)
            case 9: attributes.flags.insert(.strikethrough)
            case 21:
                attributes.flags.subtract(.anyUnderline)
                attributes.flags.insert(.doubleUnderline)
            case 22: attributes.flags.subtract([.bold, .faint])
            case 23: attributes.flags.remove(.italic)
            case 24: attributes.flags.subtract(.anyUnderline)
            case 25: attributes.flags.remove(.blink)
            case 27: attributes.flags.remove(.reverse)
            case 28: attributes.flags.remove(.hidden)
            case 29: attributes.flags.remove(.strikethrough)
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 39: attributes.foreground = .defaultForeground
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 49: attributes.background = .defaultBackground
            case 59: attributes.underlineColor = nil
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            default:
                index += applyExtendedColor(code: code, parts: parts, groups: groups, index: index, into: &attributes)
            }
            index += 1
        }
        grid.pen.attributes = attributes
    }

    /// `38`, `48` and `58` take an argument list rather than a single code, so they consume the
    /// groups after them and hand back how many were used.
    private func applyExtendedColor(
        code: Int, parts: [Int?], groups: [String], index: Int, into attributes: inout CellAttributes
    ) -> Int {
        guard code == 38 || code == 48 || code == 58 else { return 0 }
        let result = extendedColor(parts: parts, groups: groups, index: index)
        guard let color = result.color else { return result.consumed }
        switch code {
        case 38: attributes.foreground = color
        case 48: attributes.background = color
        default: attributes.underlineColor = color
        }
        return result.consumed
    }

    /// Both spellings reach here: `38;5;n` spreads across groups, `38:5:n` stays in one.
    private func extendedColor(parts: [Int?], groups: [String], index: Int) -> (color: TerminalColor?, consumed: Int) {
        if parts.count > 1 { return (Self.color(from: Array(parts.dropFirst())), 0) }
        var arguments: [Int?] = []
        var consumed = 0
        var cursor = index + 1
        while cursor < groups.count, arguments.count < 4 {
            guard let value = Int(groups[cursor]) else { break }
            arguments.append(value)
            consumed += 1
            cursor += 1
            if arguments.first.flatMap({ $0 }) == 5, arguments.count == 2 { break }
            if arguments.first.flatMap({ $0 }) == 2, arguments.count == 4 { break }
        }
        return (Self.color(from: arguments), consumed)
    }

    private static func color(from arguments: [Int?]) -> TerminalColor? {
        guard let mode = arguments.first.flatMap({ $0 }) else { return nil }
        if mode == 5, arguments.count >= 2, let index = arguments[1] {
            return .indexed(UInt8(clamping: index))
        }
        guard mode == 2 else { return nil }
        // The colour-space slot between the mode and the components is optional and usually empty.
        let components = arguments.compactMap { $0 }
        guard components.count >= 4 else { return nil }
        return .rgb(
            red: UInt8(clamping: components[1]),
            green: UInt8(clamping: components[2]),
            blue: UInt8(clamping: components[3]))
    }

    private static func underlineFlag(style: Int) -> CellAttributes.Flags {
        switch style {
        case 2: return .doubleUnderline
        case 3: return .curlyUnderline
        case 4: return .dottedUnderline
        case 5: return .dashedUnderline
        default: return .underline
        }
    }

    // MARK: - OSC

    private func dispatchOSC() {
        let text = String(decoding: stringPayload, as: UTF8.self)
        guard let separator = text.firstIndex(of: ";") else {
            handleOSC(command: text, body: "")
            return
        }
        handleOSC(
            command: String(text[text.startIndex..<separator]),
            body: String(text[text.index(after: separator)...]))
    }

    private func handleOSC(command: String, body: String) {
        switch command {
        case "0", "2":
            onEvent?(.titleChanged(body))
        case "7":
            guard let url = URL(string: body), url.isFileURL else { return }
            onEvent?(.workingDirectoryChanged(url.path))
        case "9", "777":
            handleNotification(command: command, body: body)
        case "133":
            handleShellIntegration(body)
        case Self.searchPathMarker:
            onEvent?(.searchPathChanged(body))
        case Self.commandMarker:
            // `OSC 133` stays exactly what iTerm2 and VS Code expect, so swiftTerm's own extension
            // rides on a code in the private range Warp uses for its extensions.
            onEvent?(.commandSubmitted(body))
        default:
            break
        }
    }

    /// swiftTerm's private marker for the command line the shell is about to run.
    static let commandMarker = "9281"

    /// swiftTerm's private marker for the shell's `PATH`.
    ///
    /// A sibling of `commandMarker`, on the same private range, and reported from the prompt hook for the same
    /// reason the working directory is: it is the *shell's* answer. The app's environment is launchd's when the app
    /// was opened from the Finder, and a Homebrew command would be neither resolved nor offered.
    static let searchPathMarker = "9282"

    /// `OSC 9 ; text` from the terminal's own scripts, and the `OSC 777 ; notify ; title ; body`
    /// form iTerm2 introduced and everything else copied.
    private func handleNotification(command: String, body: String) {
        guard command != "9" else {
            onEvent?(.notification(title: "Terminal", body: body))
            return
        }
        let fields = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, fields[0] == "notify" else { return }
        onEvent?(.notification(title: fields[1], body: fields.dropFirst(2).joined(separator: ";")))
    }

    private func handleShellIntegration(_ body: String) {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let letter = fields.first?.first else { return }
        switch letter {
        case "A": onEvent?(.shellIntegration(.promptStart))
        case "B": onEvent?(.shellIntegration(.commandStart))
        case "C": onEvent?(.shellIntegration(.commandExecuted))
        case "D":
            let exitCode = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            onEvent?(.shellIntegration(.commandFinished(exitCode: exitCode)))
        default: break
        }
    }
}
