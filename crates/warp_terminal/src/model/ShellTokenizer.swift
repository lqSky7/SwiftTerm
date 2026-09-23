import Foundation

/// One span of a command line, classified for colouring.
///
/// A flat, non-overlapping list, because that is exactly what a text view wants: apply one attribute
/// per span and move on. Nesting — a variable inside a double-quoted string inside an argument — is
/// resolved by the scanner into consecutive spans rather than into a tree, so nothing downstream has
/// to walk one.
struct ShellToken: Equatable {
    enum Kind: Equatable {
        /// The first word of a simple command. Also the word a not-found check is run against.
        case command
        /// Any other word.
        case argument
        /// A word that begins with `-`, including `--long`.
        case flag
        /// Inside quotes, including the quotes themselves.
        case string
        /// `$name`, `${name}`, `$(…)`, `$?`, `$1`.
        case variable
        /// `>`, `>>`, `<`, `2>`, `&>`.
        case redirect
        /// `|`, `||`, `&&`, `;`, `&`, `(`, `)`.
        case control
        /// `#` to the end of the line.
        case comment
    }

    var range: Range<String.Index>
    var kind: Kind
}

/// Splits a command line into the spans a highlighter colours.
///
/// Pure and shell-agnostic: it knows the *shape* of a shell command — words, quotes, operators,
/// redirections, `$` expansions — and nothing about which commands exist. Deciding that a word is an
/// unknown command is `CommandResolver`'s job, and deciding that an argument is a subcommand is the
/// signature table's, because both need to know things this does not.
///
/// It is a scanner, not a parser. A shell grammar would need a tree, and a tree would need to be
/// walked to colour anything; the flat span list is the whole output.
enum ShellTokenizer {
    static func tokens(in buffer: String) -> [ShellToken] {
        var scanner = Scanner(buffer)
        return scanner.run()
    }
}

// MARK: - The scanner

private struct Scanner {
    private let characters: [Character]
    private let buffer: String
    private var index = 0
    private var tokens: [ShellToken] = []
    /// Whether the next word would be the first of a simple command. True at the start and after
    /// every control operator, which is what makes `git log | grep x` colour two commands.
    private var isCommandPosition = true
    /// The terminator of a `<<` whose body has not been read yet. A here-document is the one place a
    /// shell stops being line-oriented, and the one place the body is not shell at all.
    private var pendingHeredocs: [String] = []
    /// Set by a `<<` so the next word is taken as the terminator rather than as an argument.
    private var expectsHeredocTerminator = false

    init(_ buffer: String) {
        self.buffer = buffer
        self.characters = Array(buffer)
    }

    mutating func run() -> [ShellToken] {
        while index < characters.count {
            let character = characters[index]
            // A here-document is the one place a shell stops being line-oriented: everything from
            // here to the terminator is text, not shell.
            if character == "\n", !pendingHeredocs.isEmpty {
                consumeHeredocBodies()
                continue
            }
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "#" {
                emit(index, to: characters.count, as: .comment)
                break
            }
            if let end = redirectEnding(at: index) {
                emit(index, to: end, as: .redirect)
                if isHeredocOperator(from: index, to: end) { expectsHeredocTerminator = true }
                index = end
                continue
            }
            // After the redirect check, so `&>` is one redirection rather than an `&` and a `>`.
            if let end = controlRunEnding(at: index) {
                emit(index, to: end, as: .control)
                isCommandPosition = true
                index = end
                continue
            }
            scanWord()
        }
        return tokens
    }

    /// `|`, `||`, `&&`, `;`, `&`, `(`, `)` — and a run of them, so `&&` is one span and not two.
    private func controlRunEnding(at start: Int) -> Int? {
        let character = characters[start]
        guard "|&;()".contains(character) else { return nil }
        var end = start
        while end < characters.count, "|&;()".contains(characters[end]) { end += 1 }
        return end
    }

    /// `<`, `>`, `>>`, `<<`, `<<-`, and the shapes that carry a descriptor or a target: `2>`, `2>>`,
    /// `&>`, and the `&1` of `2>&1`. The target of a plain redirect is deliberately *not* swallowed —
    /// a filename is a word and colours like one.
    private func redirectEnding(at start: Int) -> Int? {
        let character = characters[start]
        if character == "<" || character == ">" {
            var end = start + 1
            if end < characters.count, characters[end] == character {
                end += 1
                // `<<-` strips leading tabs from the body, and the dash is part of the operator.
                if character == "<", end < characters.count, characters[end] == "-" { end += 1 }
            }
            if end < characters.count, characters[end] == "&" {
                end += 1
                while end < characters.count, characters[end].isNumber || characters[end] == "-" {
                    end += 1
                }
            }
            return end
        }
        // A leading descriptor, as in `2>` or `2>>`.
        if character.isNumber, start + 1 < characters.count, "<>".contains(characters[start + 1]) {
            var end = start + 2
            if end < characters.count, characters[end] == characters[start + 1] { end += 1 }
            if end < characters.count, characters[end] == "&" {
                end += 1
                while end < characters.count, characters[end].isNumber || characters[end] == "-" {
                    end += 1
                }
            }
            return end
        }
        // `&>` redirects both streams.
        if character == "&", start + 1 < characters.count, characters[start + 1] == ">" {
            var end = start + 2
            if end < characters.count, characters[end] == ">" { end += 1 }
            return end
        }
        return nil
    }

    /// One word, plus the spans inside it that are not the word's own kind.
    ///
    /// The word's kind is decided from its first character — `-` is a flag, a command position is a
    /// command, anything else is an argument — and every span inside it that is a quote or an
    /// expansion is emitted as its own token, in order.
    private mutating func scanWord() {
        let wordStart = index
        let kind: ShellToken.Kind
        if characters[index] == "-" {
            kind = .flag
        } else if isCommandPosition {
            kind = .command
        } else {
            kind = .argument
        }
        isCommandPosition = false

        var plainStart = wordStart
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { break }
            if redirectEnding(at: index) != nil { break }
            if controlRunEnding(at: index) != nil { break }

            switch character {
            case "'":
                flushPlain(plainStart, to: index, as: kind)
                let quoteStart = index
                index = endOfSingleQuoted(from: index)
                emit(quoteStart, to: index, as: .string)
                plainStart = index
            case "\"":
                flushPlain(plainStart, to: index, as: kind)
                index = endOfDoubleQuoted(from: index)
                plainStart = index
            case "\\":
                index = min(index + 2, characters.count)
                continue
            case "$":
                let end = endOfExpansion(from: index)
                if end > index + 1 {
                    flushPlain(plainStart, to: index, as: kind)
                    emit(index, to: end, as: .variable)
                    index = end
                    plainStart = index
                } else {
                    // Not an expansion, so the `$` belongs to the word: advance past it without
                    // moving `plainStart`, or it falls out of the span and vanishes.
                    index += 1
                }
            default:
                index += 1
            }
        }
        flushPlain(plainStart, to: index, as: kind)

        if expectsHeredocTerminator {
            expectsHeredocTerminator = false
            // `<<'EOF'` quotes the terminator, and quoting it is also how the body is kept from being
            // expanded. Either way the terminator is the word without its quotes.
            let raw = String(characters[wordStart..<index])
            let terminator = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            // A terminator the shell will expand cannot be known from here, and guessing at one would
            // swallow the rest of the buffer. Colouring a body as shell is the better failure.
            if !terminator.isEmpty, !raw.contains("$") { pendingHeredocs.append(terminator) }
        }
    }

    /// Everything from just after the newline that ended the command, to and including each
    /// terminator's own line, is body.
    ///
    /// A here-document body is text: `$`, `|` and `#` in it mean nothing to the shell, and colouring
    /// them as shell is exactly the confusion the colour is there to prevent. A body with no
    /// terminator runs to the end of the buffer, which is what the user has typed so far.
    private mutating func consumeHeredocBodies() {
        let terminators = pendingHeredocs
        pendingHeredocs.removeAll()
        index += 1  // past the newline that ended the command line

        for terminator in terminators {
            let bodyStart = index
            while index < characters.count {
                let lineEnd = endOfLine(from: index)
                let line = String(characters[index..<lineEnd])
                index = lineEnd < characters.count ? lineEnd + 1 : lineEnd
                if line.trimmingCharacters(in: .whitespaces) == terminator { break }
            }
            emit(bodyStart, to: index, as: .string)
        }
        isCommandPosition = true
    }

    private func endOfLine(from start: Int) -> Int {
        var end = start
        while end < characters.count, characters[end] != "\n" { end += 1 }
        return end
    }

    private func isHeredocOperator(from start: Int, to end: Int) -> Bool {
        let text = String(characters[start..<end])
        return text == "<<" || text == "<<-"
    }

    /// Everything before `from` that has not been emitted yet, as one span of the word's own kind.
    private mutating func flushPlain(_ from: Int, to: Int, as kind: ShellToken.Kind) {
        guard to > from else { return }
        emit(from, to: to, as: kind)
    }

    private mutating func emit(_ from: Int, to: Int, as kind: ShellToken.Kind) {
        guard to > from else { return }
        let lower = buffer.index(buffer.startIndex, offsetBy: from)
        let upper = buffer.index(buffer.startIndex, offsetBy: to)
        tokens.append(ShellToken(range: lower..<upper, kind: kind))
    }

    // MARK: - The ends of things

    /// Past the closing quote. An unterminated quote runs to the end of the buffer, because that is
    /// what the user has typed so far and colouring should not flicker while they finish it.
    private func endOfSingleQuoted(from start: Int) -> Int {
        var end = start + 1
        while end < characters.count {
            if characters[end] == "'" { return end + 1 }
            end += 1
        }
        return characters.count
    }

    /// A double-quoted string is one span with the expansions inside it cut out, so `"a $b c"` is
    /// three spans: string, variable, string.
    private mutating func endOfDoubleQuoted(from start: Int) -> Int {
        var end = start + 1
        var plainStart = start
        while end < characters.count {
            let character = characters[end]
            if character == "\\" {
                end = min(end + 2, characters.count)
                continue
            }
            if character == "\"" {
                flushPlain(plainStart, to: end + 1, as: .string)
                return end + 1
            }
            if character == "$" {
                let expansionEnd = endOfExpansion(from: end)
                if expansionEnd > end + 1 {
                    flushPlain(plainStart, to: end, as: .string)
                    emit(end, to: expansionEnd, as: .variable)
                    end = expansionEnd
                    plainStart = end
                    continue
                }
            }
            end += 1
        }
        flushPlain(plainStart, to: characters.count, as: .string)
        return characters.count
    }

    /// `$name`, `${name}`, `$(…)`, `$1`, `$?`, `$*`. A `$` that starts none of those is just a `$`.
    private func endOfExpansion(from start: Int) -> Int {
        guard start + 1 < characters.count else { return start }
        let next = characters[start + 1]
        if next == "{" {
            var end = start + 2
            while end < characters.count, characters[end] != "}" { end += 1 }
            return end < characters.count ? end + 1 : characters.count
        }
        if next == "(" {
            var end = start + 2
            var depth = 1
            while end < characters.count, depth > 0 {
                if characters[end] == "(" { depth += 1 }
                if characters[end] == ")" { depth -= 1 }
                end += 1
            }
            return end
        }
        if next.isLetter || next == "_" {
            var end = start + 1
            while end < characters.count, characters[end].isLetter || characters[end].isNumber
                || characters[end] == "_"
            {
                end += 1
            }
            return end
        }
        if next.isNumber || "?*@#!$-".contains(next) { return start + 2 }
        return start
    }
}
