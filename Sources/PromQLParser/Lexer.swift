//===----------------------------------------------------------------------===//
// Ported from promql/parser/lex.go @ v3.13.2 — the scanner.
//
// Go models this as a state machine of `stateFn`s, each returning the next state.
// That translates directly: `State` is an enum and `run(_:)` dispatches, which
// keeps every transition where Go put it. A rewrite into one big loop would make
// the histogram and series-description states unreadable, and those are where the
// subtle transitions live.
//
// The scanner works on BYTES. Positions are byte offsets, and `next()` decodes a
// UTF-8 rune the way `utf8.DecodeRuneInString` does — returning U+FFFD with a
// width of 1 for an invalid sequence. `lexString` tests for exactly that value,
// which is also why a *validly* encoded U+FFFD is reported as an invalid rune:
// Go cannot tell the two apart either, and neither does this.
//===----------------------------------------------------------------------===//

public import PromPosRange

private import GoCompat

/// Go: `eof` — the sentinel `next()` returns past the end of the input.
private let eofRune: Int32 = -1

/// Go: `histogramState`.
enum HistogramState {
    case none
    case open
    case mul
    case add
    case sub
}

/// Go: the `stateFn` values, as an enum so transitions stay explicit.
enum LexState {
    case statements
    case insideBraces
    case valueSequence
    case histogram
    case histogramDescriptor
    case buckets
    case string
    case rawString
    case escape
    case space
    case lineComment
    case number
    case numberOrDuration
    case keywordOrIdentifier
    case identifier
    case durationExpr
    /// Go's nil state: the scan is finished, and every further call emits EOF.
    case done
}

/// Go: `Lexer` — holds the state of the scanner.
public struct Lexer: Sendable {
    /// The string being scanned, as bytes.
    let input: [UInt8]
    /// The next lexing function to enter.
    var state: LexState = .statements
    /// Current position in the input.
    var pos: Pos = 0
    /// Start position of this item.
    var start: Pos = 0
    /// Width of the last rune read from the input.
    var width: Pos = 0
    /// Position of the most recent item returned by `nextItem`.
    var lastPos: Pos = 0
    /// The item being scanned into, and whether it has been written.
    var item = Item(typ: .eof, pos: 0, val: [])
    var scannedItem = false

    /// Nesting depth of `(` `)` expressions.
    var parenDepth = 0
    /// Whether a `{` is open.
    var braceOpen = false
    /// Whether a `[` is open.
    var bracketOpen = false
    /// Whether a `:` was seen after `[` was opened.
    var gotColon = false
    /// Whether a duration was seen after `[` was opened.
    var gotDuration = false
    /// Quote rune of the string currently being read.
    var stringOpen: Int32 = 0

    /// Whether a series description is being lexed. Used by the internal PromQL
    /// testing framework and by promtool rules unit tests.
    var seriesDesc = false
    /// Whether the scan is inside a histogram description.
    var histogramState: HistogramState = .none

    /// Go: `Lex` — creates a new scanner for the input.
    public init(_ input: [UInt8]) {
        self.input = input
    }

    public init(_ input: String) {
        self.init(Array(input.utf8))
    }

    /// Go: `Lex` with the unexported `seriesDesc` set, which upstream only does
    /// from within the package. Exposed here because the series-description states
    /// are otherwise unreachable, and the parser needs them.
    public init(_ input: [UInt8], seriesDesc: Bool) {
        self.input = input
        self.seriesDesc = seriesDesc
    }

    // MARK: - Primitives

    /// Go: `next` — the next rune in the input.
    mutating func next() -> Int32 {
        if Int(pos) >= input.count {
            width = 0
            return eofRune
        }
        let (r, w) = GoStrconv.decodeRune(input, Int(pos))
        width = Pos(w)
        pos += width
        return Int32(bitPattern: r)
    }

    /// Go: `peek`.
    mutating func peek() -> Int32 {
        let r = next()
        backup()
        return r
    }

    /// Go: `backup` — step back one rune. Valid only once per `next()`.
    mutating func backup() {
        pos -= width
    }

    /// Go: `emit` — hand an item back to the client.
    mutating func emit(_ t: ItemType) {
        item = Item(typ: t, pos: start, val: Array(input[Int(start)..<Int(pos)]))
        start = pos
        scannedItem = true
    }

    /// Go: `ignore` — skip the pending input.
    mutating func ignore() {
        start = pos
    }

    /// Go: `accept` — consume the next rune if it is in the set.
    mutating func accept(_ valid: String) -> Bool {
        if containsRune(valid, next()) { return true }
        backup()
        return false
    }

    /// Go: `is` — peek and report whether the next rune is in the set.
    mutating func `is`(_ valid: String) -> Bool {
        containsRune(valid, peek())
    }

    /// Go: `acceptRun`.
    mutating func acceptRun(_ valid: String) {
        while containsRune(valid, next()) {}
        backup()
    }

    private func containsRune(_ valid: String, _ r: Int32) -> Bool {
        guard r >= 0, let scalar = Unicode.Scalar(UInt32(r)) else { return false }
        return valid.unicodeScalars.contains(scalar)
    }

    /// Go: `errorf` — emit an error item and stop the scan.
    mutating func errorf(_ message: String) -> LexState {
        item = Item(typ: .error, pos: start, val: Array(message.utf8))
        scannedItem = true
        return .done
    }

    // MARK: - Driving the machine

    /// Go: `NextItem` — writes the next item and returns it.
    ///
    /// Go's version takes a pointer to write into, which exists so the parser can
    /// reuse one allocation. Returning the value is equivalent here.
    public mutating func nextItem() -> Item {
        scannedItem = false

        if state != .done {
            while !scannedItem {
                state = run(state)
            }
        } else {
            emit(.eof)
        }

        lastPos = item.pos
        return item
    }

    /// Dispatches one state. Each case is Go's function of the same name.
    mutating func run(_ state: LexState) -> LexState {
        switch state {
        case .statements: return lexStatements()
        case .insideBraces: return lexInsideBraces()
        case .valueSequence: return lexValueSequence()
        case .histogram: return lexHistogram()
        case .histogramDescriptor: return lexHistogramDescriptor()
        case .buckets: return lexBuckets()
        case .string: return lexString()
        case .rawString: return lexRawString()
        case .escape: return lexEscape()
        case .space: return lexSpace()
        case .lineComment: return lexLineComment()
        case .number: return lexNumber()
        case .numberOrDuration: return lexNumberOrDuration()
        case .keywordOrIdentifier: return lexKeywordOrIdentifier()
        case .identifier: return lexIdentifier()
        case .durationExpr: return lexDurationExpr()
        case .done:
            emit(.eof)
            return .done
        }
    }

    private var restHasLineComment: Bool {
        Int(pos) < input.count && input[Int(pos)] == UInt8(ascii: "#")
    }

    // MARK: - States

    /// Go: `lexStatements` — the top-level state.
    mutating func lexStatements() -> LexState {
        if histogramState != .none { return .histogram }
        if braceOpen { return .insideBraces }
        if restHasLineComment { return .lineComment }

        let r = next()
        switch r {
        case eofRune:
            if parenDepth != 0 { return errorf("unclosed left parenthesis") }
            if bracketOpen { return errorf("unclosed left bracket") }
            emit(.eof)
            return .done
        case Int32(UInt8(ascii: ",")):
            emit(.comma)
        case Int32(UInt8(ascii: "*")):
            emit(.mul)
        case Int32(UInt8(ascii: "/")):
            emit(.div)
        case Int32(UInt8(ascii: "%")):
            emit(.mod)
        case Int32(UInt8(ascii: "+")):
            emit(.add)
        case Int32(UInt8(ascii: "-")):
            emit(.sub)
        case Int32(UInt8(ascii: "^")):
            emit(.pow)
        case Int32(UInt8(ascii: "=")):
            let t = peek()
            if t == Int32(UInt8(ascii: "=")) {
                _ = next()
                emit(.eqlc)
            } else if t == Int32(UInt8(ascii: "~")) {
                return errorf("unexpected character after '=': \(quoteRune(t))")
            } else {
                emit(.eql)
            }
        case Int32(UInt8(ascii: "!")):
            let t = next()
            if t != Int32(UInt8(ascii: "=")) {
                return errorf("unexpected character after '!': \(quoteRune(t))")
            }
            emit(.neq)
        case Int32(UInt8(ascii: "<")):
            if peek() == Int32(UInt8(ascii: "=")) {
                _ = next()
                emit(.lte)
            } else if peek() == Int32(UInt8(ascii: "/")) {
                _ = next()
                emit(.trimUpper)
            } else {
                emit(.lss)
            }
        case Int32(UInt8(ascii: ">")):
            if peek() == Int32(UInt8(ascii: "=")) {
                _ = next()
                emit(.gte)
            } else if peek() == Int32(UInt8(ascii: "/")) {
                _ = next()
                emit(.trimLower)
            } else {
                emit(.gtr)
            }
        case Int32(UInt8(ascii: "\"")), Int32(UInt8(ascii: "'")):
            stringOpen = r
            return .string
        case Int32(UInt8(ascii: "`")):
            stringOpen = r
            return .rawString
        case Int32(UInt8(ascii: "(")):
            emit(.leftParen)
            parenDepth += 1
            return .statements
        case Int32(UInt8(ascii: ")")):
            emit(.rightParen)
            parenDepth -= 1
            if parenDepth < 0 {
                return errorf("unexpected right parenthesis \(quoteRune(r))")
            }
            return .statements
        case Int32(UInt8(ascii: "{")):
            emit(.leftBrace)
            braceOpen = true
            return .insideBraces
        case Int32(UInt8(ascii: "[")):
            if bracketOpen {
                return errorf("unexpected left bracket \(quoteRune(r))")
            }
            gotColon = false
            emit(.leftBracket)
            if isSpace(peek()) { skipSpaces() }
            bracketOpen = true
            return .durationExpr
        case Int32(UInt8(ascii: "]")):
            if !bracketOpen {
                return errorf("unexpected right bracket \(quoteRune(r))")
            }
            emit(.rightBracket)
            bracketOpen = false
        case Int32(UInt8(ascii: "@")):
            emit(.at)
        default:
            if isSpace(r) { return .space }
            if isDigit(r) || (r == Int32(UInt8(ascii: ".")) && isDigit(peek())) {
                backup()
                return .numberOrDuration
            }
            if isAlpha(r) || r == Int32(UInt8(ascii: ":")) {
                if !bracketOpen {
                    backup()
                    return .keywordOrIdentifier
                }
                if r == Int32(UInt8(ascii: ":")) {
                    if gotColon {
                        return errorf("unexpected colon \(quoteRune(r))")
                    }
                    emit(.colon)
                    gotColon = true
                    return .statements
                }
                if isDurationKeywordStartChar(r), scanDurationKeyword() {
                    return .statements
                }
                return errorf(
                    "unexpected character: \(quoteRune(r)), expected \(quoteRune(Int32(UInt8(ascii: ":"))))"
                )
            }
            return errorf("unexpected character: \(quoteRune(r))")
        }
        return .statements
    }

    /// Go: `lexHistogram`.
    mutating func lexHistogram() -> LexState {
        switch histogramState {
        case .mul:
            histogramState = .none
            _ = next()
            emit(.times)
            return .valueSequence
        case .add:
            histogramState = .none
            _ = next()
            emit(.add)
            return .valueSequence
        case .sub:
            histogramState = .none
            _ = next()
            emit(.sub)
            return .valueSequence
        case .none, .open:
            break
        }

        if bracketOpen { return .buckets }

        let r = next()
        if isSpace(r) {
            emit(.space)
            return .space
        }
        if isAlpha(r) {
            backup()
            return .histogramDescriptor
        }
        switch r {
        case Int32(UInt8(ascii: ":")):
            emit(.colon)
            return .histogram
        case Int32(UInt8(ascii: "-")):
            emit(.sub)
            return .histogram
        case Int32(UInt8(ascii: "x")):
            emit(.times)
            return .number
        case Int32(UInt8(ascii: "[")):
            bracketOpen = true
            gotColon = false
            gotDuration = false
            emit(.leftBracket)
            return .buckets
        default:
            if isDigit(r) {
                backup()
                return .number
            }
            if r == Int32(UInt8(ascii: "}")) && peek() == Int32(UInt8(ascii: "}")) {
                _ = next()
                emit(.closeHist)
                switch peek() {
                case Int32(UInt8(ascii: "x")):
                    histogramState = .mul
                    return .histogram
                case Int32(UInt8(ascii: "+")):
                    histogramState = .add
                    return .histogram
                case Int32(UInt8(ascii: "-")):
                    histogramState = .sub
                    return .histogram
                default:
                    histogramState = .none
                    return .valueSequence
                }
            }
            return errorf("histogram description incomplete unexpected: \(quoteRune(r))")
        }
    }

    /// Go: `lexHistogramDescriptor`.
    mutating func lexHistogramDescriptor() -> LexState {
        while true {
            let r = next()
            if isAlpha(r) { continue }
            backup()

            let word = Array(input[Int(start)..<Int(pos)])
            let lowered = goToLowerASCII(word)
            if let desc = histogramDesc[lowered] {
                if peek() == Int32(UInt8(ascii: ":")) {
                    emit(desc)
                    return .histogram
                }
                _ = errorf("missing `:` for histogram descriptor")
                break
            }
            // The current word is Inf or NaN.
            if let desc = promQLKeywords[lowered], desc == .number {
                emit(desc)
                return .histogram
            }
            if let desc = counterResetHints[lowered] {
                emit(desc)
                return .histogram
            }

            _ = errorf("bad histogram descriptor found: \(GoStrconv.quote(bytes: word))")
            break
        }
        // Go breaks out of the labelled loop and returns lexStatements even though
        // errorf already produced the item.
        return .statements
    }

    /// Go: `lexBuckets`.
    mutating func lexBuckets() -> LexState {
        let r = next()
        if isSpace(r) {
            emit(.space)
            return .space
        }
        if r == Int32(UInt8(ascii: "-")) {
            emit(.sub)
            return .number
        }
        if isDigit(r) {
            backup()
            return .number
        }
        if r == Int32(UInt8(ascii: "]")) {
            bracketOpen = false
            emit(.rightBracket)
            return .histogram
        }
        if isAlpha(r) {
            // The current word is Inf or NaN.
            let word = goToLowerASCII(Array(input[Int(start)..<Int(pos)]))
            if let desc = promQLKeywords[word], desc == .number {
                emit(desc)
                return .statements
            }
            return .buckets
        }
        return errorf("invalid character in buckets description: \(quoteRune(r))")
    }

    /// Go: `lexInsideBraces` — the inside of a vector selector. Keywords are
    /// scanned as identifiers here.
    mutating func lexInsideBraces() -> LexState {
        if restHasLineComment { return .lineComment }

        let r = next()
        switch r {
        case eofRune:
            return errorf("unexpected end of input inside braces")
        case Int32(UInt8(ascii: ",")):
            emit(.comma)
        case Int32(UInt8(ascii: "\"")), Int32(UInt8(ascii: "'")):
            stringOpen = r
            return .string
        case Int32(UInt8(ascii: "`")):
            stringOpen = r
            return .rawString
        case Int32(UInt8(ascii: "=")):
            if next() == Int32(UInt8(ascii: "~")) {
                emit(.eqlRegex)
                break
            }
            backup()
            emit(.eql)
        case Int32(UInt8(ascii: "!")):
            let nr = next()
            switch nr {
            case Int32(UInt8(ascii: "~")):
                emit(.neqRegex)
            case Int32(UInt8(ascii: "=")):
                emit(.neq)
            default:
                return errorf("unexpected character after '!' inside braces: \(quoteRune(nr))")
            }
        case Int32(UInt8(ascii: "{")):
            return errorf("unexpected left brace \(quoteRune(r))")
        case Int32(UInt8(ascii: "}")):
            emit(.rightBrace)
            braceOpen = false
            if seriesDesc { return .valueSequence }
            return .statements
        default:
            if isSpace(r) { return .space }
            if isAlpha(r) {
                backup()
                return .identifier
            }
            return errorf("unexpected character inside braces: \(quoteRune(r))")
        }
        return .insideBraces
    }

    /// Go: `lexValueSequence` — the value sequence of a series description.
    mutating func lexValueSequence() -> LexState {
        if histogramState != .none { return .histogram }

        let r = next()
        switch r {
        case eofRune:
            return .statements
        case Int32(UInt8(ascii: "+")):
            emit(.add)
        case Int32(UInt8(ascii: "-")):
            emit(.sub)
        case Int32(UInt8(ascii: "x")):
            emit(.times)
        case Int32(UInt8(ascii: "_")):
            emit(.blank)
        default:
            if r == Int32(UInt8(ascii: "{")) && peek() == Int32(UInt8(ascii: "{")) {
                // Go re-tests histogramState here, which cannot be non-none: the
                // guard at the top of the function already returned in that case.
                histogramState = .open
                _ = next()
                emit(.openHist)
                return .histogram
            }
            if isSpace(r) {
                emit(.space)
                _ = lexSpace()
                return .valueSequence
            }
            if isDigit(r) || (r == Int32(UInt8(ascii: ".")) && isDigit(peek())) {
                backup()
                _ = lexNumber()
                return .valueSequence
            }
            if isAlpha(r) {
                backup()
                // Invalid items may be lexed here; the parser catches them.
                return .keywordOrIdentifier
            }
            return errorf("unexpected character in series sequence: \(quoteRune(r))")
        }
        return .valueSequence
    }

    /// Go: `lexEscape` — a string escape sequence, with the `\` already consumed.
    ///
    /// Adapted in Go from `go/scanner`; the escaping logic is unchanged from there.
    mutating func lexEscape() -> LexState {
        var n = 0
        var base: UInt32 = 0
        var maxVal: UInt32 = 0

        var ch = next()
        switch ch {
        case Int32(UInt8(ascii: "a")), Int32(UInt8(ascii: "b")), Int32(UInt8(ascii: "f")),
            Int32(UInt8(ascii: "n")), Int32(UInt8(ascii: "r")), Int32(UInt8(ascii: "t")),
            Int32(UInt8(ascii: "v")), Int32(UInt8(ascii: "\\")):
            return .string
        case Int32(UInt8(ascii: "0")), Int32(UInt8(ascii: "1")), Int32(UInt8(ascii: "2")),
            Int32(UInt8(ascii: "3")), Int32(UInt8(ascii: "4")), Int32(UInt8(ascii: "5")),
            Int32(UInt8(ascii: "6")), Int32(UInt8(ascii: "7")):
            (n, base, maxVal) = (3, 8, 255)
        case Int32(UInt8(ascii: "x")):
            ch = next()
            (n, base, maxVal) = (2, 16, 255)
        case Int32(UInt8(ascii: "u")):
            ch = next()
            (n, base, maxVal) = (4, 16, GoFmt.maxRune)
        case Int32(UInt8(ascii: "U")):
            ch = next()
            (n, base, maxVal) = (8, 16, GoFmt.maxRune)
        case eofRune:
            _ = errorf("escape sequence not terminated")
            return .string
        default:
            // The opening quote is also a valid escape, checked after the fixed set
            // because Go lists `l.stringOpen` as a case alongside them.
            if ch == stringOpen { return .string }
            _ = errorf("unknown escape sequence \(GoFmt.sharpUnicode(Int64(ch)))")
            return .string
        }

        var x: UInt32 = 0
        while n > 0 {
            let d = UInt32(digitVal(ch))
            if d >= base {
                if ch == eofRune {
                    _ = errorf("escape sequence not terminated")
                    return .string
                }
                _ = errorf(
                    "illegal character \(GoFmt.sharpUnicode(Int64(ch))) in escape sequence")
                return .string
            }
            x = x &* base &+ d
            n -= 1

            // Do not seek past the last rune.
            if n > 0 { ch = next() }
        }

        if x > maxVal || (0xD800 <= x && x < 0xE000) {
            _ = errorf("escape sequence is an invalid Unicode code point")
        }
        return .string
    }

    /// Go: `skipSpaces`.
    mutating func skipSpaces() {
        while isSpace(peek()) { _ = next() }
        ignore()
    }

    /// Go: `lexString` — a quoted string, with the opening quote consumed.
    mutating func lexString() -> LexState {
        while true {
            let r = next()
            switch r {
            case Int32(UInt8(ascii: "\\")):
                return .escape
            case 0xFFFD:
                // Go compares against utf8.RuneError, which a validly encoded
                // U+FFFD also produces. Both are reported as invalid.
                _ = errorf("invalid UTF-8 rune")
                return .string
            case eofRune, Int32(UInt8(ascii: "\n")):
                return errorf("unterminated quoted string")
            default:
                if r == stringOpen {
                    emit(.string)
                    return .statements
                }
            }
        }
    }

    /// Go: `lexRawString` — a raw quoted string, with the opening quote consumed.
    mutating func lexRawString() -> LexState {
        while true {
            let r = next()
            switch r {
            case 0xFFFD:
                _ = errorf("invalid UTF-8 rune")
                return .rawString
            case eofRune:
                _ = errorf("unterminated raw string")
                return .rawString
            default:
                if r == stringOpen {
                    emit(.string)
                    return .statements
                }
            }
        }
    }

    /// Go: `lexSpace` — a run of spaces, with one already consumed.
    mutating func lexSpace() -> LexState {
        while isSpace(peek()) { _ = next() }
        ignore()
        return .statements
    }

    /// Go: `lexLineComment` — the comment marker is known to be present.
    mutating func lexLineComment() -> LexState {
        pos += 1  // len(lineComment)
        var r = next()
        while !isEndOfLine(r) && r != eofRune {
            r = next()
        }
        backup()
        emit(.comment)
        return .statements
    }

    /// Go: `lexNumber`.
    mutating func lexNumber() -> LexState {
        if !scanNumber() {
            return errorf(
                "bad number syntax: \(GoStrconv.quote(bytes: Array(input[Int(start)..<Int(pos)])))")
        }
        emit(.number)
        return .statements
    }

    /// Go: `scanDurationKeyword`.
    mutating func scanDurationKeyword() -> Bool {
        while true {
            let r = next()
            if isAlpha(r) { continue }
            backup()
            let word = goToLowerASCII(Array(input[Int(start)..<Int(pos)]))
            if let tok = durationKeywordTokens[word] {
                emit(tok)
                return true
            }
            return false
        }
    }

    /// Go: `lexNumberOrDuration`.
    mutating func lexNumberOrDuration() -> LexState {
        if scanNumber() {
            emit(.number)
            return .statements
        }
        // The next two characters must be a valid unit and a non-alphanumeric.
        if acceptRemainingDuration() {
            backup()
            emit(.duration)
            return .statements
        }
        return errorf(
            "bad number or duration syntax: \(GoStrconv.quote(bytes: Array(input[Int(start)..<Int(pos)])))"
        )
    }

    /// Go: `acceptRemainingDuration`.
    mutating func acceptRemainingDuration() -> Bool {
        if !accept("smhdwy") { return false }
        // Support for `ms`. Bad units like `hs`, `ys` are caught when the duration
        // is actually parsed.
        _ = accept("s")
        // The next character can be another number, then a unit.
        while accept("0123456789") {
            while accept("0123456789") {}
            // `y` is not in this list: it must always come first in a duration.
            if !accept("smhdw") { return false }
            _ = accept("s")
        }
        return !isAlphaNumeric(next())
    }

    /// Go: `scanNumber` — scans numbers in every format. The result is not
    /// necessarily a valid number; the parser catches that.
    mutating func scanNumber() -> Bool {
        let initialPos = pos
        // Hexadecimal changes the digit pattern.
        var digitPattern = "0123456789"
        // Hexadecimal is disallowed in series descriptions: the syntax is ambiguous.
        if !seriesDesc && accept("0") && accept("xX") {
            _ = accept("_")  // e.g. 0X_1FFFP-16 == 0.1249847412109375
            digitPattern = "0123456789abcdefABCDEF"
        }
        let dotPattern = "."
        let exponentPattern = "eE"
        let underscorePattern = "_"
        // Anti-patterns are the rune sets that cannot follow their rune.
        let dotAntiPattern = "_."
        let exponentAntiPattern = "._eE"  // and EOL.
        let underscoreAntiPattern = "._eE"  // and EOL.

        // Every number follows the prefix [.][d][d._eE]*
        _ = accept(dotPattern)
        _ = accept(digitPattern)
        var dotConsumed = false
        var exponentConsumed = false
        while `is`(digitPattern + dotPattern + underscorePattern + exponentPattern) {
            // "." cannot repeat.
            if `is`(dotPattern) && dotConsumed {
                _ = accept(dotPattern)
                return false
            }
            // "eE" cannot repeat.
            if `is`(exponentPattern) && exponentConsumed {
                _ = accept(exponentPattern)
                return false
            }
            if accept(dotPattern) {
                dotConsumed = true
                if accept(dotAntiPattern) { return false }
                // Fractional hexadecimal literals are not allowed.
                if digitPattern.count > 10 { return false }
                continue
            }
            if accept(exponentPattern) {
                exponentConsumed = true
                _ = accept("+-")
                if accept(exponentAntiPattern) || peek() == eofRune { return false }
                continue
            }
            if accept(underscorePattern) {
                if accept(underscoreAntiPattern) || peek() == eofRune { return false }
                continue
            }
            // Digits come last: they were already consumed before the loop.
            acceptRun(digitPattern)
        }
        // The empty string is not a valid number.
        if pos == initialPos { return false }
        // What follows must not be alphanumeric, unless it is the times token for
        // series repetitions.
        let r = peek()
        if (seriesDesc && r == Int32(UInt8(ascii: "x"))) || !isAlphaNumeric(r) {
            return true
        }
        return false
    }

    /// Go: `lexIdentifier` — the next character is known to be a letter.
    mutating func lexIdentifier() -> LexState {
        while isAlphaNumeric(next()) {}
        backup()
        emit(.identifier)
        return .statements
    }

    /// Go: `lexKeywordOrIdentifier` — an identifier that may contain a colon. If
    /// it is a keyword, the keyword item is emitted instead.
    mutating func lexKeywordOrIdentifier() -> LexState {
        while true {
            let r = next()
            if isAlphaNumeric(r) || r == Int32(UInt8(ascii: ":")) { continue }
            backup()
            let word = Array(input[Int(start)..<Int(pos)])
            if let kw = promQLKeywords[goToLowerASCII(word)] {
                // fill/fill_left/fill_right are only keywords when followed by '(',
                // so they can still be used as metric names — which matters because
                // they were valid names before the modifiers existed.
                if kw == .fill || kw == .fillLeft || kw == .fillRight {
                    if !peekFollowedByLeftParen() {
                        emit(.identifier)
                        break
                    }
                }
                emit(kw)
            } else if !word.contains(UInt8(ascii: ":")) {
                emit(.identifier)
            } else {
                emit(.metricIdentifier)
            }
            break
        }
        if seriesDesc && peek() != Int32(UInt8(ascii: "{")) {
            return .valueSequence
        }
        return .statements
    }

    /// Go: `peekFollowedByLeftParen`.
    func peekFollowedByLeftParen() -> Bool {
        var p = Int(pos)
        while true {
            if p >= input.count { return false }
            let (r, w) = GoStrconv.decodeRune(input, p)
            let signed = Int32(bitPattern: r)
            if !isSpace(signed) { return signed == Int32(UInt8(ascii: "(")) }
            p += w
        }
    }

    /// Go: `lexDurationExpr` — arithmetic inside brackets, for duration expressions.
    mutating func lexDurationExpr() -> LexState {
        let r = next()
        switch r {
        case eofRune:
            return errorf("unexpected end of input in duration expression")
        case Int32(UInt8(ascii: "]")):
            emit(.rightBracket)
            bracketOpen = false
            gotColon = false
            return .statements
        case Int32(UInt8(ascii: ":")):
            emit(.colon)
            if !gotDuration {
                return errorf("unexpected colon before duration in duration expression")
            }
            if gotColon {
                return errorf("unexpected repeated colon in duration expression")
            }
            gotColon = true
            return .durationExpr
        case Int32(UInt8(ascii: "(")):
            emit(.leftParen)
            parenDepth += 1
            return .durationExpr
        case Int32(UInt8(ascii: ")")):
            emit(.rightParen)
            parenDepth -= 1
            if parenDepth < 0 {
                return errorf("unexpected right parenthesis \(quoteRune(r))")
            }
            return .durationExpr
        case Int32(UInt8(ascii: "+")):
            emit(.add)
            return .durationExpr
        case Int32(UInt8(ascii: "-")):
            emit(.sub)
            return .durationExpr
        case Int32(UInt8(ascii: "*")):
            emit(.mul)
            return .durationExpr
        case Int32(UInt8(ascii: "/")):
            emit(.div)
            return .durationExpr
        case Int32(UInt8(ascii: "%")):
            emit(.mod)
            return .durationExpr
        case Int32(UInt8(ascii: "^")):
            emit(.pow)
            return .durationExpr
        case Int32(UInt8(ascii: ",")):
            emit(.comma)
            return .durationExpr
        default:
            if isSpace(r) {
                skipSpaces()
                return .durationExpr
            }
            if isDurationKeywordStartChar(r) {
                if scanDurationKeyword() { return .durationExpr }
                return errorf("unexpected character in duration expression: \(quoteRune(r))")
            }
            if isDigit(r) || (r == Int32(UInt8(ascii: ".")) && isDigit(peek())) {
                backup()
                gotDuration = true
                return .numberOrDuration
            }
            return errorf("unexpected character in duration expression: \(quoteRune(r))")
        }
    }

    /// Go: `findPrevRightParen` — the previous right parenthesis.
    ///
    /// Used where the parser had to read ahead to find the next right parenthesis
    /// and lost track of the previous one. Only valid outside string literals,
    /// since a multi-byte rune would break the position arithmetic. Falls back to
    /// the given position on any problem.
    /// https://github.com/prometheus/prometheus/issues/16053
    func findPrevRightParen(fallbackPos: Pos) -> Pos {
        if fallbackPos <= 0 || fallbackPos > Pos(input.count) || lastPos <= 0
            || lastPos >= Pos(input.count) || input[Int(lastPos)] != UInt8(ascii: ")")
        {
            return fallbackPos
        }
        var i = lastPos - 1
        while i > 0 {
            if input[Int(i)] == UInt8(ascii: ")") { return i + 1 }
            if !isSpace(Int32(input[Int(i)])) { return fallbackPos }
            i -= 1
        }
        return fallbackPos
    }
}

// MARK: - Character classes

/// Go: `%q` on a rune. Note that an invalid rune — the eof sentinel, in
/// particular — quotes as U+FFFD rather than producing an error marker.
func quoteRune(_ r: Int32) -> String {
    GoFmt.quoteVerb(Int64(r))
}

/// Go: `isSpace`.
func isSpace(_ r: Int32) -> Bool {
    r == Int32(UInt8(ascii: " ")) || r == Int32(UInt8(ascii: "\t"))
        || r == Int32(UInt8(ascii: "\n")) || r == Int32(UInt8(ascii: "\r"))
}

/// Go: `isEndOfLine`.
func isEndOfLine(_ r: Int32) -> Bool {
    r == Int32(UInt8(ascii: "\r")) || r == Int32(UInt8(ascii: "\n"))
}

/// Go: `isAlphaNumeric`.
func isAlphaNumeric(_ r: Int32) -> Bool { isAlpha(r) || isDigit(r) }

/// Go: `isDigit`. Deliberately not `unicode.IsDigit`, which would also accept
/// non-Latin digits — https://github.com/prometheus/prometheus/issues/939.
func isDigit(_ r: Int32) -> Bool {
    Int32(UInt8(ascii: "0")) <= r && r <= Int32(UInt8(ascii: "9"))
}

/// Go: `isAlpha`.
func isAlpha(_ r: Int32) -> Bool {
    r == Int32(UInt8(ascii: "_")) || (Int32(UInt8(ascii: "a")) <= r && r <= Int32(UInt8(ascii: "z")))
        || (Int32(UInt8(ascii: "A")) <= r && r <= Int32(UInt8(ascii: "Z")))
}

/// Go: `digitVal` — the digit value of a rune, or 16 when it is not a digit.
func digitVal(_ ch: Int32) -> Int {
    if Int32(UInt8(ascii: "0")) <= ch && ch <= Int32(UInt8(ascii: "9")) {
        return Int(ch - Int32(UInt8(ascii: "0")))
    }
    if Int32(UInt8(ascii: "a")) <= ch && ch <= Int32(UInt8(ascii: "f")) {
        return Int(ch - Int32(UInt8(ascii: "a")) + 10)
    }
    if Int32(UInt8(ascii: "A")) <= ch && ch <= Int32(UInt8(ascii: "F")) {
        return Int(ch - Int32(UInt8(ascii: "A")) + 10)
    }
    return 16  // Larger than any legal digit value.
}

/// Go: `unicode.ToLower` for the ASCII range, which is all the keyword tables use.
func goToLower(_ r: UInt32) -> UInt32 {
    if r >= UInt32(UInt8(ascii: "A")) && r <= UInt32(UInt8(ascii: "Z")) { return r + 32 }
    return r
}

/// Go: `strings.ToLower` restricted to what the keyword lookups need.
///
/// Go lowercases the whole word including non-ASCII, but every key in the tables
/// is ASCII, so a non-ASCII word can only fail the lookup either way. Lowercasing
/// ASCII only avoids pulling in a Unicode case table for no observable gain.
func goToLowerASCII(_ bytes: [UInt8]) -> String {
    var out = bytes
    for i in out.indices where out[i] >= UInt8(ascii: "A") && out[i] <= UInt8(ascii: "Z") {
        out[i] += 32
    }
    return String(decoding: out, as: UTF8.self)
}
