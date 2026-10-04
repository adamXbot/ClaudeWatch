import Foundation

/// The tool calls written in a Codex "code mode" script.
///
/// Codex used to record each shell command as its own `exec_command` record. Since mid-2026
/// it records one `custom_tool_call` named `exec` whose `input` is a JavaScript program, and
/// the commands are calls inside that program:
///
///     const r = await tools.exec_command({cmd: "git status", workdir: "/repo"});
///     text(await tools.apply_patch("*** Begin Patch\n…"));
///
/// This reads the program far enough to find those calls and the arguments that are written
/// out as literals. Nothing is run: an argument the script works out as it goes (a loop
/// variable, a concatenation) is reported as `.computed`, never guessed.
enum CodexExecScript {

    enum Argument: Equatable {
        /// A string, template or number literal, or a name declared once with one. A template
        /// keeps its `${…}` parts as written.
        case known(String)
        /// Worked out when the script runs.
        case computed

        var text: String? {
            if case .known(let text) = self { return text }
            return nil
        }
    }

    struct Call: Equatable {
        var tool: String
        /// The properties of a first argument written as an object: `{cmd: …, workdir: …}`.
        var properties: [String: Argument] = [:]
        /// A first argument that is anything else, such as `apply_patch`'s patch.
        var argument: Argument?
    }

    /// Every `tools.<name>(…)` call in `script`, in the order written.
    static func calls(in script: String) -> [Call] {
        var reader = Reader(Array(script.utf8))
        reader.run()
        return reader.calls
    }

    // MARK: - Reading

    private struct Reader {
        let bytes: [UInt8]
        var lexer: Lexer
        var calls: [Call] = []
        /// Names declared once with a literal: `const patch = "…"`.
        var literals: [String: String] = [:]
        /// Names whose value cannot be told from here: declared twice, a parameter, assigned to.
        var unknown: Set<String> = []

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            lexer = Lexer(bytes: bytes)
        }

        mutating func run() {
            var previous = Lexer.Token.end
            var open: [Int] = []            // where each "(" still open is
            var closed: Range<Int>?         // the "( … )" that closed last
            while true {
                let token = lexer.next()
                switch token {
                case .end:
                    return
                case .word(let range):
                    let afterDot = previous == .punct(Byte.dot)
                    switch word(range) {
                    case "tools" where !afterDot: readCall()
                    case "const", "let", "var": readDeclaration()
                    case "function": readParameters()
                    case let name where !afterDot: forgetIfAssigned(name)
                    default: break
                    }
                case .punct(Byte.openParen):
                    open.append(lexer.position - 1)
                case .punct(Byte.closeParen):
                    if let start = open.popLast() { closed = start..<lexer.position }
                case .punct(Byte.equals) where byte(at: lexer.position) == Byte.greater:
                    // An arrow function: what stands before it are its parameters, and they
                    // hide any outer name.
                    if case .word(let range) = previous {
                        forget(word(range))
                    } else if previous == .punct(Byte.closeParen), let closed {
                        forgetNames(in: closed)
                    }
                default:
                    break
                }
                previous = token
            }
        }

        /// `tools.name(` or `tools["name"](`, with the lexer just past `tools`. The lexer is
        /// left there, so calls inside the arguments are found too.
        private mutating func readCall() {
            var ahead = lexer
            var name: String?
            switch ahead.next() {
            case .punct(Byte.dot):
                if case .word(let range) = ahead.next() { name = word(range) }
            case .punct(Byte.openBracket):
                if case .string(let content) = ahead.next(), ahead.next() == .punct(Byte.closeBracket) {
                    name = text(of: content, template: false)
                }
            default:
                break
            }
            guard let name, ahead.next() == .punct(Byte.openParen) else { return }

            var call = Call(tool: name)
            var first = ahead
            switch first.next() {
            case .end, .punct(Byte.closeParen):
                break
            case .punct(Byte.openBrace):
                call.properties = readProperties(&first)
            default:
                call.argument = readValue(&ahead)
            }
            calls.append(call)
        }

        /// The properties of an object, with the lexer just past its `{`.
        private func readProperties(_ lexer: inout Lexer) -> [String: Argument] {
            var properties: [String: Argument] = [:]
            while true {
                let key: String
                switch lexer.next() {
                case .end, .punct(Byte.closeBrace):
                    return properties
                case .punct(Byte.comma):
                    continue
                case .word(let range):
                    key = word(range)
                case .string(let content):
                    key = text(of: content, template: false)
                default:
                    skipValue(&lexer)       // `...spread` or `[computed]: …`: nothing to name
                    continue
                }
                var ahead = lexer
                switch ahead.next() {
                case .punct(Byte.colon):
                    lexer = ahead
                    properties[key] = readValue(&lexer)
                case .end, .punct(Byte.comma), .punct(Byte.closeBrace):
                    properties[key] = literals[key].map(Argument.known) ?? .computed     // `{cmd}`
                default:
                    skipValue(&lexer)
                    properties[key] = .computed
                }
            }
        }

        /// The value that starts at the lexer, which is left on the `,` or bracket ending it.
        private func readValue(_ lexer: inout Lexer) -> Argument {
            var ahead = lexer
            if let value = literal(&ahead) {
                // Only when that is the whole value: `"a" + b` and `name.trim()` are computed.
                var after = ahead
                switch after.next() {
                case .end, .punct(Byte.comma), .punct(Byte.closeBrace), .punct(Byte.closeParen), .punct(Byte.closeBracket):
                    lexer = ahead
                    return .known(value)
                default:
                    break
                }
            }
            skipValue(&lexer)
            return .computed
        }

        /// A literal at the lexer, or a name standing for one. The lexer moves past it.
        private func literal(_ lexer: inout Lexer) -> String? {
            switch lexer.next() {
            case .string(let content):
                return text(of: content, template: false)
            case .template(let content):
                return text(of: content, template: true)
            case .number(let range):
                return word(range)
            case .word(let range):
                let name = word(range)
                guard name == "String" else { return literals[name] }
                // String.raw`…`: the text exactly as written.
                guard lexer.next() == .punct(Byte.dot), case .word(let raw) = lexer.next(), word(raw) == "raw",
                      case .template(let content) = lexer.next()
                else { return nil }
                return String(decoding: bytes[content], as: UTF8.self)
            default:
                return nil
            }
        }

        /// Moves the lexer to the `,` or closing bracket that ends the value it is in.
        private func skipValue(_ lexer: inout Lexer) {
            var depth = 0
            while true {
                var ahead = lexer
                switch ahead.next() {
                case .end:
                    lexer = ahead
                    return
                case .punct(Byte.openParen), .punct(Byte.openBracket), .punct(Byte.openBrace):
                    depth += 1
                case .punct(Byte.closeParen), .punct(Byte.closeBracket), .punct(Byte.closeBrace):
                    if depth == 0 { return }
                    depth -= 1
                case .punct(Byte.comma) where depth == 0:
                    return
                default:
                    break
                }
                lexer = ahead
            }
        }

        // MARK: Names

        /// `const name = "literal"`, with the lexer just past the keyword. Anything else
        /// declared here is a name whose value is not known.
        private mutating func readDeclaration() {
            while true {
                var ahead = lexer
                switch ahead.next() {
                case .punct(Byte.openBracket), .punct(Byte.openBrace):
                    // A destructuring pattern: its names take whatever the other side holds.
                    forgetNames(in: (ahead.position - 1)..<endOfGroup(ahead))
                    return
                case .word(let range):
                    let name = word(range)
                    guard ahead.next() == .punct(Byte.equals),
                          byte(at: ahead.position) != Byte.equals, byte(at: ahead.position) != Byte.greater,
                          let value = literal(&ahead)
                    else { return forget(name) }
                    var after = ahead
                    let terminator = after.next()
                    guard endsDeclarator(terminator, lineBreakBefore: after.lineBreakBefore) else { return forget(name) }
                    if unknown.contains(name) || literals[name] != nil {
                        forget(name)        // declared in two scopes: which one a use means is not known
                    } else {
                        literals[name] = value
                    }
                    lexer = ahead
                    guard terminator == .punct(Byte.comma) else { return }
                    lexer = after           // `const a = "x", b = "y"`
                default:
                    return
                }
            }
        }

        private func endsDeclarator(_ token: Lexer.Token, lineBreakBefore: Bool) -> Bool {
            switch token {
            case .end, .punct(Byte.semicolon), .punct(Byte.comma), .punct(Byte.closeBrace): return true
            case .word: return lineBreakBefore      // no semicolon, and the next line starts a statement
            default: return false
            }
        }

        /// `function name(a, b)`, with the lexer just past the keyword: its parameters hide
        /// any outer name.
        private mutating func readParameters() {
            var ahead = lexer
            var token = ahead.next()
            if token == .punct(Byte.star) { token = ahead.next() }
            if case .word = token { token = ahead.next() }
            guard token == .punct(Byte.openParen) else { return }
            forgetNames(in: ahead.position..<endOfGroup(ahead))
        }

        /// `name = …`, `name += …`, `name++`, with the lexer just past the name: the literal
        /// it was declared with no longer holds.
        private mutating func forgetIfAssigned(_ name: String) {
            guard literals[name] != nil else { return }
            var index = lexer.position
            while byte(at: index) == Byte.space || byte(at: index) == Byte.tab { index += 1 }
            var run: [UInt8] = []
            while run.count < 5, let next = byte(at: index), Byte.operators.contains(next) {
                run.append(next)
                index += 1
            }
            let op = String(decoding: run, as: UTF8.self)
            if op.hasPrefix("++") || op.hasPrefix("--") { return forget(name) }
            guard let equals = run.firstIndex(of: Byte.equals) else { return }
            let following = equals + 1 < run.count ? run[equals + 1] : nil
            guard following != Byte.equals, following != Byte.greater else { return }     // ==, =>
            let compound = ["", "+", "-", "*", "/", "%", "**", "<<", ">>", ">>>", "&", "|", "^", "&&", "||", "??"]
            if compound.contains(String(op.prefix(equals))) { forget(name) }
        }

        private mutating func forget(_ name: String) {
            literals[name] = nil
            unknown.insert(name)
        }

        private mutating func forgetNames(in range: Range<Int>) {
            var inner = Lexer(bytes: bytes, position: range.lowerBound)
            while inner.position < range.upperBound {
                switch inner.next() {
                case .end: return
                case .word(let name) where name.upperBound <= range.upperBound: forget(word(name))
                default: break
                }
            }
        }

        /// Where the bracket the lexer is just inside closes (the index after it).
        private func endOfGroup(_ lexer: Lexer) -> Int {
            var lexer = lexer
            var depth = 0
            while true {
                switch lexer.next() {
                case .end:
                    return bytes.count
                case .punct(Byte.openParen), .punct(Byte.openBracket), .punct(Byte.openBrace):
                    depth += 1
                case .punct(Byte.closeParen), .punct(Byte.closeBracket), .punct(Byte.closeBrace):
                    if depth == 0 { return lexer.position }
                    depth -= 1
                default:
                    break
                }
            }
        }

        // MARK: Text

        private func byte(at index: Int) -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private func word(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }

        /// What a string literal says, given what stands between its quotes. A template keeps
        /// its `${…}` parts as written.
        private func text(of content: Range<Int>, template: Bool) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(content.count)
            var index = content.lowerBound
            let end = content.upperBound
            while index < end {
                let byte = bytes[index]
                if template, byte == Byte.dollar, index + 1 < end, bytes[index + 1] == Byte.openBrace {
                    let close = min(lexer.endOfSubstitution(from: index + 2), end)
                    out.append(contentsOf: bytes[index..<close])
                    index = close
                } else if byte == Byte.backslash, index + 1 < end {
                    index = appendEscape(at: index + 1, upTo: end, to: &out)
                } else {
                    out.append(byte)
                    index += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// Appends what the escape whose letter is at `index` stands for, and returns the
        /// index after it.
        private func appendEscape(at index: Int, upTo end: Int, to out: inout [UInt8]) -> Int {
            switch bytes[index] {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "0"): out.append(0x00)
            case 0x0A:
                break                                               // a line continued with a backslash
            case 0x0D:
                return index + (index + 1 < end && bytes[index + 1] == 0x0A ? 2 : 1)
            case UInt8(ascii: "x"):
                guard let value = hex(at: index + 1, count: 2, upTo: end) else { out.append(bytes[index]); break }
                append(scalar: value, to: &out)
                return index + 3
            case UInt8(ascii: "u"):
                if index + 1 < end, bytes[index + 1] == Byte.openBrace {
                    guard let close = bytes[index..<end].firstIndex(of: Byte.closeBrace),
                          let value = hex(at: index + 2, count: close - index - 2, upTo: end)
                    else { out.append(bytes[index]); break }
                    append(scalar: value, to: &out)
                    return close + 1
                }
                guard var value = hex(at: index + 1, count: 4, upTo: end) else { out.append(bytes[index]); break }
                var next = index + 5
                // An astral character is written as two escapes, a surrogate pair.
                if (0xD800...0xDBFF).contains(value), next + 1 < end,
                   bytes[next] == Byte.backslash, bytes[next + 1] == UInt8(ascii: "u"),
                   let low = hex(at: next + 2, count: 4, upTo: end), (0xDC00...0xDFFF).contains(low) {
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    next += 6
                }
                append(scalar: value, to: &out)
                return next
            default:
                out.append(bytes[index])                            // \\ \" \' \` \$ and the like
            }
            return index + 1
        }

        private func hex(at index: Int, count: Int, upTo end: Int) -> UInt32? {
            guard (1...6).contains(count), index + count <= end else { return nil }
            return UInt32(String(decoding: bytes[index..<(index + count)], as: UTF8.self), radix: 16)
        }

        private func append(scalar value: UInt32, to out: inout [UInt8]) {
            UTF8.encode(Unicode.Scalar(value) ?? "\u{FFFD}") { out.append($0) }
        }
    }

    // MARK: - Lexing

    /// Splits JavaScript into the tokens the reader steps over: enough to know where strings,
    /// templates, comments and regular expressions start and end, so that a call quoted
    /// inside one of them is not taken for a call.
    private struct Lexer {
        enum Token: Equatable {
            case end
            case word(Range<Int>)
            case string(Range<Int>)         // what stands between the quotes
            case template(Range<Int>)       // what stands between the backticks
            case number(Range<Int>)
            case regex
            case punct(UInt8)
        }

        let bytes: [UInt8]
        var position = 0
        /// Whether a line break came before the token last returned.
        private(set) var lineBreakBefore = false
        /// A `/` starts a regular expression after an operator, and divides after a value.
        private var regexAllowed = true
        /// How many `${…}` deep this lexer is, so a hostile script cannot exhaust the stack.
        private var nesting = 0

        init(bytes: [UInt8], position: Int = 0) {
            self.bytes = bytes
            self.position = position
        }

        mutating func next() -> Token {
            lineBreakBefore = false
            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case 0x0A, 0x0D:
                    lineBreakBefore = true
                    position += 1
                case Byte.space, Byte.tab, 0x0B, 0x0C:
                    position += 1
                case Byte.slash where peek(1) == Byte.slash:
                    while position < bytes.count, bytes[position] != 0x0A { position += 1 }
                case Byte.slash where peek(1) == Byte.star:
                    position += 2
                    while position < bytes.count, !(bytes[position] == Byte.star && peek(1) == Byte.slash) { position += 1 }
                    position = min(position + 2, bytes.count)
                default:
                    return token(startingWith: byte)
                }
            }
            return .end
        }

        private mutating func token(startingWith byte: UInt8) -> Token {
            let start = position
            switch byte {
            case Byte.doubleQuote, Byte.singleQuote:
                position += 1
                while position < bytes.count, bytes[position] != byte, bytes[position] != 0x0A {
                    position += bytes[position] == Byte.backslash ? 2 : 1
                }
                let content = (start + 1)..<min(position, bytes.count)
                position = min(position + 1, bytes.count)
                regexAllowed = false
                return .string(content)

            case Byte.backtick:
                position += 1
                while position < bytes.count, bytes[position] != Byte.backtick {
                    if bytes[position] == Byte.backslash {
                        position += 2
                    } else if bytes[position] == Byte.dollar, peek(1) == Byte.openBrace {
                        position = endOfSubstitution(from: position + 2)
                    } else {
                        position += 1
                    }
                }
                let content = (start + 1)..<min(position, bytes.count)
                position = min(position + 1, bytes.count)
                regexAllowed = false
                return .template(content)

            case Byte.slash:
                if regexAllowed, let end = endOfRegex(from: start) {
                    position = end
                    regexAllowed = false
                    return .regex
                }

            case _ where Byte.isDigit(byte):
                while position < bytes.count, Byte.isWord(bytes[position]) || bytes[position] == Byte.dot { position += 1 }
                regexAllowed = false
                return .number(start..<position)

            case _ where Byte.isWord(byte):
                while position < bytes.count, Byte.isWord(bytes[position]) { position += 1 }
                regexAllowed = Self.beforeExpression.contains(String(decoding: bytes[start..<position], as: UTF8.self))
                return .word(start..<position)

            default:
                break
            }
            position += 1
            regexAllowed = !(byte == Byte.closeParen || byte == Byte.closeBracket || byte == Byte.closeBrace)
            return .punct(byte)
        }

        /// Keywords that are followed by a value, so a `/` after one starts a regular expression.
        private static let beforeExpression: Set<String> = [
            "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await",
        ]

        private func peek(_ offset: Int) -> UInt8? {
            position + offset < bytes.count ? bytes[position + offset] : nil
        }

        /// The index after the `}` closing a template's `${`, whose code starts at `start`.
        func endOfSubstitution(from start: Int) -> Int {
            guard nesting < 16 else { return bytes.count }
            var inner = Lexer(bytes: bytes, position: start)
            inner.nesting = nesting + 1
            var depth = 0
            while true {
                switch inner.next() {
                case .end:
                    return bytes.count
                case .punct(Byte.openBrace):
                    depth += 1
                case .punct(Byte.closeBrace):
                    if depth == 0 { return inner.position }
                    depth -= 1
                default:
                    break
                }
            }
        }

        /// The index after the regular expression whose `/` is at `start`, or nil if the line
        /// ends first: then it was a division after all.
        private func endOfRegex(from start: Int) -> Int? {
            var index = start + 1
            var inClass = false
            while index < bytes.count {
                switch bytes[index] {
                case 0x0A, 0x0D:
                    return nil
                case Byte.backslash:
                    index += 1
                case Byte.openBracket:
                    inClass = true
                case Byte.closeBracket:
                    inClass = false
                case Byte.slash where !inClass:
                    index += 1
                    while index < bytes.count, Byte.isWord(bytes[index]) { index += 1 }     // its flags
                    return index
                default:
                    break
                }
                index += 1
            }
            return nil
        }
    }

    private enum Byte {
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let dot = UInt8(ascii: ".")
        static let comma = UInt8(ascii: ",")
        static let colon = UInt8(ascii: ":")
        static let semicolon = UInt8(ascii: ";")
        static let equals = UInt8(ascii: "=")
        static let greater = UInt8(ascii: ">")
        static let star = UInt8(ascii: "*")
        static let slash = UInt8(ascii: "/")
        static let backslash = UInt8(ascii: "\\")
        static let dollar = UInt8(ascii: "$")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let backtick = UInt8(ascii: "`")
        static let openParen = UInt8(ascii: "(")
        static let closeParen = UInt8(ascii: ")")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let operators = Set("+-*/%&|^?<>=!".utf8)

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        /// A byte of a name: a letter, digit, `_`, `$`, or part of a character outside ASCII.
        static func isWord(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), dollar, 0x80...:
                return true
            default:
                return false
            }
        }
    }
}
