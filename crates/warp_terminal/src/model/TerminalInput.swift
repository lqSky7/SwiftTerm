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

    // Raw programs receive Enter bytes; LF can invoke nano's Ctrl-J justify command.
    static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        let payload = bracketed ? "\u{1B}[200~\(normalized)\u{1B}[201~" : normalized
        return Array(payload.utf8)
    }
}
