import Foundation

/// The whole assertion vocabulary. There is no XCTest target: a harness is a plain executable
/// that compiles the shipped sources it guards, so a harness that stops compiling means a
/// decision leaked out of a pure layer.
///
/// State lives on an instance rather than in globals because Swift 6 rejects a mutable global
/// outright, and because `exit` is the only way out — there is no runner to return a verdict to.
final class Harness {
    private let name: String
    private var checks = 0
    private var failures: [String] = []

    init(_ name: String) {
        self.name = name
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("line \(line): \(message())")
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: UInt = #line) {
        expect(actual == expected, "\(label): expected \(expected), got \(actual)", line: line)
    }

    /// For geometry, which is divided and so is mostly not exactly representable. Comparing with a
    /// tolerance is the difference between a harness that checks the arithmetic and one that checks
    /// whether `CGFloat` rounded a particular way today.
    func close(_ actual: CGFloat, _ expected: CGFloat, _ label: String, line: UInt = #line) {
        expect(
            abs(actual - expected) < 0.0001, "\(label): expected \(expected), got \(actual)",
            line: line)
    }

    func finish() -> Never {
        guard failures.isEmpty else {
            print("✗ \(name): \(failures.count) of \(checks) checks failed")
            for failure in failures { print("    \(failure)") }
            exit(1)
        }
        print("✓ \(name): \(checks) checks passed")
        exit(0)
    }
}

extension TerminalGrid {
    /// The whole screen as text with trailing blanks dropped, which is what a test wants to
    /// compare against. Reading rows through here keeps assertions about content, not cells.
    var screenText: [String] {
        (0..<size.rows).map { rowText($0) }
    }

    func rowText(_ row: Int) -> String {
        line(at: historyLineCount + row)?.string() ?? ""
    }

    func screenContains(_ needle: String) -> Bool {
        screenText.contains { $0.contains(needle) }
    }

    /// Writes a literal string the way a program's output would reach the screen, minus the
    /// escape sequences. Control scalars go through the grid's own control handling so a test
    /// never re-implements what `\r` means.
    func write(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                applyControl(UInt8(scalar.value))
            } else {
                put(Character(scalar))
            }
        }
    }
}
