//===----------------------------------------------------------------------===//
// Differential tests for promql/parser/lex.go and posrange.
//
// The whole token stream is compared: type, byte position, raw value and
// Item.String(). Values travel as hex because a lexed item can hold arbitrary
// bytes — a comment absorbs everything up to the newline, invalid UTF-8 included
// (ADR-9).
//
// NOT covered here: the series-description and histogram-description states. Go's
// `Lex()` cannot set the unexported seriesDesc flag, so lexValueSequence,
// lexHistogram, lexHistogramDescriptor and lexBuckets are unreachable from
// outside the package. They get pinned in the parser slice, through
// ParseSeriesDesc.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromQLParser

struct ItemJSON: Codable, Equatable, Sendable {
    let typ: Int32
    let pos: Int32
    let val: String
    let str: String
}

struct LexOut: Codable, Equatable, Sendable {
    let items: [ItemJSON]
}

@Suite("PromQL lexer matches Go")
struct LexerTests {

    /// Drains a lexer with the same stopping rule the oracle uses: up to and
    /// including the first EOF or ERROR.
    static func drain(_ input: [UInt8]) -> [ItemJSON] {
        var lexer = Lexer(input)
        var items = [ItemJSON]()
        for _ in 0..<1000 {
            let item = lexer.nextItem()
            items.append(
                ItemJSON(
                    typ: item.typ.rawValue,
                    pos: item.pos,
                    val: Hex.encode(item.val),
                    str: item.description))
            if item.typ == .eof || item.typ == .error { break }
        }
        return items
    }

    @Test("every committed token stream")
    func tokenStreams() throws {
        try Fixtures.check("promql/lex.jsonl", FixtureCase<String, LexOut>.self) { input in
            LexOut(items: Self.drain(Hex.decode(input)))
        }
    }

    @Test("StartPosInput renders line:col the way Go does")
    func posRange() throws {
        struct In: Decodable, Sendable {
            let query: String
            let start: Int32
            let end: Int32
            let lineOffset: Int
        }
        try Fixtures.check("promql/posrange.jsonl", FixtureCase<In, String>.self) { input in
            PositionRange(start: input.start, end: input.end)
                .startPosInput(query: Hex.decode(input.query), lineOffset: input.lineOffset)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("PromQL lexer invariants")
struct LexerInvariantTests {

    static func types(_ input: String) -> [ItemType] {
        var lexer = Lexer(input)
        var out = [ItemType]()
        for _ in 0..<200 {
            let item = lexer.nextItem()
            out.append(item.typ)
            if item.typ == .eof || item.typ == .error { break }
        }
        return out
    }

    static func firstError(_ input: String) -> String? {
        var lexer = Lexer(input)
        for _ in 0..<200 {
            let item = lexer.nextItem()
            if item.typ == .error { return item.valString }
            if item.typ == .eof { return nil }
        }
        return nil
    }

    @Test("the goyacc token numbers are reproduced, because they are observable")
    func tokenNumbers() {
        // ItemType.String() falls back to "<Item %d>" for types absent from
        // itemTypeStr, which puts the raw number in user-facing output. The
        // histogram descriptors and counter-reset hints are exactly those types.
        #expect(ItemType.eql.rawValue == 57346)
        #expect(ItemType.sumDesc.description == "<Item 57370>")
        #expect(ItemType.gaugeType.description == "<Item 57448>")
        // And desc() renders the number through %q as a rune literal. 57370 is
        // 0xE01A, a private-use scalar, so QuoteRune escapes it rather than
        // emitting the character: the result is the eight-character text below.
        #expect(ItemType.sumDesc.desc == #"'\ue01a'"#)
    }

    @Test("the range predicates depend on the constants staying in order")
    func predicateRanges() {
        #expect(ItemType.add.isOperator)
        #expect(ItemType.atan2.isOperator)
        #expect(!ItemType.sum.isOperator)
        #expect(ItemType.sum.isAggregator)
        #expect(ItemType.limitRatio.isAggregator)
        #expect(!ItemType.by.isAggregator)
        #expect(ItemType.by.isKeyword)
        #expect(ItemType.without.isKeyword)
        #expect(!ItemType.start.isKeyword)
        #expect(ItemType.limitk.isExperimentalAggregator)
        #expect(ItemType.topk.isAggregatorWithParam)
        #expect(!ItemType.sum.isAggregatorWithParam)
        #expect(ItemType.eqlc.isComparisonOperator)
        #expect(ItemType.land.isSetOperator)
    }

    @Test("number and inf/nan are absent from itemTypeStr, deliberately")
    func numberNotInItemTypeStr() {
        // Go's init() copies `key` into ItemTypeStr and only afterwards adds
        // inf/nan → NUMBER, so NUMBER never gets a literal rendering. That is what
        // makes a number render through desc()'s named branch instead.
        #expect(itemTypeStr[.number] == nil)
        #expect(ItemType.number.desc == "number")
        #expect(itemTypeStr[.sum] == "sum")
        #expect(itemTypeStr[.leftBrace] == "{")
    }

    @Test("fill is a keyword only when followed by a left paren")
    func contextSensitiveFill() {
        // So that `fill` keeps working as a metric name, which it was before the
        // fill modifiers existed.
        #expect(Self.types("fill(1)").first == .fill)
        #expect(Self.types("fill (1)").first == .fill)
        #expect(Self.types("fill + fill").first == .identifier)
        #expect(Self.types("fill").first == .identifier)
        // Other keywords are unconditional.
        #expect(Self.types("sum + sum").first == .sum)
    }

    @Test("an item value can hold bytes a String cannot")
    func byteValues() {
        // A comment absorbs everything up to the newline, so invalid UTF-8 survives
        // into the token value. This is why Item.val is [UInt8]: a String would
        // silently substitute U+FFFD here (ADR-9).
        var lexer = Lexer(Array("# \u{FF}".utf8) + [0xFF])
        let item = lexer.nextItem()
        #expect(item.typ == .comment)
        #expect(item.val.last == 0xFF)
    }

    @Test("a validly encoded U+FFFD is reported as an invalid rune")
    func replacementCharacterIsIndistinguishable() {
        // Go tests `case utf8.RuneError`, which matches both a decoding failure and
        // a correctly encoded U+FFFD. It cannot tell them apart, so neither does
        // this — replicated, not fixed.
        #expect(Self.firstError("\"\u{FFFD}\"") == "invalid UTF-8 rune")
        #expect(Self.firstError("\"\u{FF}\"") == nil)  // valid, just non-ASCII
    }

    @Test("quoting the eof sentinel yields U+FFFD, not an error marker")
    func eofSentinelQuoting() {
        // `foo{a!` hits `unexpected character after '!' inside braces: %q` with the
        // eof rune, -1. fmt.fmtQc substitutes utf8.RuneError for anything that is
        // not a valid rune rather than falling back to its badVerb form, which is
        // what %q does for most other operand kinds. Verified against Go: my first
        // reading of fmt was wrong and the fixture caught it.
        #expect(
            Self.firstError("foo{a!")
                == "unexpected character after '!' inside braces: '\u{FFFD}'")
    }

    @Test("unclosed brackets and parens are reported at the end of input")
    func unclosedDelimiters() {
        #expect(Self.firstError("sum(rate(foo[5m])") == "unclosed left parenthesis")
        // Not "unexpected end of input in duration expression": lexNumberOrDuration
        // returns to lexStatements rather than lexDurationExpr, so the end of input
        // is reached in the top-level state with bracketOpen still set.
        #expect(Self.firstError("foo[5m") == "unclosed left bracket")
        #expect(Self.firstError("foo[") == "unexpected end of input in duration expression")
        #expect(Self.firstError("{foo=\"bar\"") == "unexpected end of input inside braces")
    }

    @Test("positions are byte offsets, not character offsets")
    func bytePositions() {
        // A multi-byte string literal advances the position by its byte length,
        // which is what every PositionRange in a parse error is measured in. Note
        // `é` cannot start an identifier — isAlpha is deliberately ASCII-only — so
        // the multi-byte content has to sit inside a string.
        var lexer = Lexer("\"é\" + 1")
        let first = lexer.nextItem()
        #expect(first.typ == .string)
        #expect(first.pos == 0)
        let plus = lexer.nextItem()
        #expect(plus.typ == .add)
        #expect(plus.pos == 5)  // 4 bytes for "é", 1 for the space.
    }
}
