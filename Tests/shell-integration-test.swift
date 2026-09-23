import Foundation

/// Guards the protocol Phase 2 builds blocks on. If a prompt cycle stops reporting the four
/// markers in order, or the exit code goes missing, blocks would silently pair the wrong command
/// with the wrong output — a failure that looks like a rendering bug and is not one.
@main
enum ShellIntegrationTest {
    static func main() {
        let harness = Harness("shell-integration-test")

        fullCycle(harness)
        exitCodes(harness)
        extraFields(harness)
        interleavedWithOutput(harness)
        workingDirectory(harness)

        harness.finish()
    }

    private static func makeParser() -> (VTParser, () -> [TerminalEvent]) {
        let parser = VTParser(grid: TerminalGrid(size: TerminalSize(columns: 40, rows: 8)))
        let collected = EventLog()
        parser.onEvent = { collected.append($0) }
        return (parser, { collected.events })
    }

    private static func fullCycle(_ harness: Harness) {
        let (parser, events) = makeParser()
        parser.feed("\u{1B}]133;A\u{07}")
        parser.feed("\u{1B}]133;B\u{07}")
        parser.feed("\u{1B}]133;C\u{07}")
        parser.feed("total 0\r\n")
        parser.feed("\u{1B}]133;D;0\u{07}")

        harness.equal(
            events().compactMap(\.shellIntegration), [
                .promptStart, .commandStart, .commandExecuted, .commandFinished(exitCode: 0),
            ],
            "a prompt cycle reports the four markers in order")
    }

    private static func exitCodes(_ harness: Harness) {
        let (parser, events) = makeParser()
        parser.feed("\u{1B}]133;D;130\u{07}")
        harness.equal(
            events().last?.shellIntegration, .commandFinished(exitCode: 130),
            "a signalled command reports the shell's own code")

        let (bare, bareEvents) = makeParser()
        bare.feed("\u{1B}]133;D\u{07}")
        harness.equal(
            bareEvents().last?.shellIntegration, .commandFinished(exitCode: 0),
            "a marker with no code means success")
    }

    private static func extraFields(_ harness: Harness) {
        let (parser, events) = makeParser()
        // zsh's `add-zsh-hook` reports the line the command started on; iTerm2 ignores it and so
        // do we, but it must not stop the marker from being recognised.
        parser.feed("\u{1B}]133;A;cl=line;aid=42\u{07}")
        parser.feed("\u{1B}]133;D;1;aid=42\u{07}")
        harness.equal(
            events().compactMap(\.shellIntegration), [
                .promptStart, .commandFinished(exitCode: 1),
            ],
            "extra semicolon-separated fields are ignored")
    }

    private static func interleavedWithOutput(_ harness: Harness) {
        let (parser, events) = makeParser()
        parser.feed("\u{1B}]133;A\u{07}$ ")
        parser.feed("\u{1B}]133;B\u{07}")
        parser.feed("\u{1B}]133;C\u{07}")
        parser.feed("hello\r\nworld\r\n")
        parser.feed("\u{1B}]133;D;0\u{07}")
        parser.feed("\u{1B}]133;A\u{07}$ ")

        // The command's first line continues the prompt's row, because the shell never emitted a
        // newline between them. A block view has to know that, so it is asserted rather than fixed.
        harness.equal(parser.grid.rowText(0), "$ hello", "output continues on the prompt's row")
        harness.equal(parser.grid.rowText(1), "world", "the second output row follows")
        harness.equal(parser.grid.rowText(2), "$", "the next prompt starts a fresh row")
        harness.equal(
            events().compactMap(\.shellIntegration).count, 5,
            "five markers across a cycle and a half")
    }

    private static func workingDirectory(_ harness: Harness) {
        let (parser, events) = makeParser()
        parser.feed("\u{1B}]7;file://hostname/Users/example/project\u{07}")
        parser.feed("\u{1B}]7;file:///tmp\u{07}")
        harness.equal(
            events().compactMap(\.workingDirectory), ["/Users/example/project", "/tmp"],
            "OSC 7 reports the cwd with and without a host")
    }
}

/// `VTParser.onEvent` is a plain closure, so the harness needs somewhere to put what it collects.
private final class EventLog {
    private var storage: [TerminalEvent] = []
    var events: [TerminalEvent] { storage }
    func append(_ event: TerminalEvent) { storage.append(event) }
}

private extension TerminalEvent {
    var shellIntegration: ShellIntegrationEvent? {
        guard case .shellIntegration(let event) = self else { return nil }
        return event
    }

    var workingDirectory: String? {
        guard case .workingDirectoryChanged(let path) = self else { return nil }
        return path
    }
}
