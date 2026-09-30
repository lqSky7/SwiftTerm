import Foundation

// xterm encodes Shift, Alt and Control as bits added to the default modifier value of one.
enum TerminalInput {
    static func cursor(_ final: String, application: Bool, modifier: Int = 1) -> [UInt8] {
        if modifier > 1 { return Array("\u{1B}[1;\(modifier)\(final)".utf8) }
        return Array("\u{1B}\(application ? "O" : "[")\(final)".utf8)
    }

    static func tilde(_ code: Int, modifier: Int = 1) -> [UInt8] {
        Array("\u{1B}[\(code)\(modifier > 1 ? ";\(modifier)" : "")~".utf8)
    }
}
