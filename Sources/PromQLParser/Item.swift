//===----------------------------------------------------------------------===//
// Ported from promql/parser/lex.go @ v3.13.2 — Item, ItemType and the keyword
// tables. The scanner itself is in Lexer.swift.
//
// The numeric ItemType values are goyacc's, reproduced exactly even though this
// port replaces goyacc with a hand-written parser. They are observable:
// `ItemType.String()` falls back to `<Item %d>` for any type absent from
// `ItemTypeStr` (the histogram descriptors and counter-reset hints), and
// `desc()` falls back to `%q` on the raw number, which renders as a rune
// literal like `''`. Both reach user-facing parse errors, so the numbers
// are part of the contract.
//===----------------------------------------------------------------------===//

public import PromPosRange

private import GoCompat

/// Go: `ItemType` — a token type.
///
/// Ordering matters as much as the values: `isOperator()`, `isAggregator()` and
/// `isKeyword()` are range checks against the `*Start`/`*End` sentinels.
public struct ItemType: RawRepresentable, Sendable, Hashable, Comparable {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public init(_ rawValue: Int32) { self.rawValue = rawValue }

    public static func < (a: ItemType, b: ItemType) -> Bool { a.rawValue < b.rawValue }
}

extension ItemType {
    // goyacc numbers its tokens from 57346 (0xE002).
    public static let eql = ItemType(57346)
    public static let blank = ItemType(57347)
    public static let colon = ItemType(57348)
    public static let comma = ItemType(57349)
    public static let comment = ItemType(57350)
    public static let duration = ItemType(57351)
    public static let eof = ItemType(57352)
    public static let error = ItemType(57353)
    public static let identifier = ItemType(57354)
    public static let leftBrace = ItemType(57355)
    public static let leftBracket = ItemType(57356)
    public static let leftParen = ItemType(57357)
    public static let openHist = ItemType(57358)
    public static let closeHist = ItemType(57359)
    public static let metricIdentifier = ItemType(57360)
    public static let number = ItemType(57361)
    public static let rightBrace = ItemType(57362)
    public static let rightBracket = ItemType(57363)
    public static let rightParen = ItemType(57364)
    public static let semicolon = ItemType(57365)
    public static let space = ItemType(57366)
    public static let string = ItemType(57367)
    public static let times = ItemType(57368)

    static let histogramDescStart = ItemType(57369)
    public static let sumDesc = ItemType(57370)
    public static let countDesc = ItemType(57371)
    public static let schemaDesc = ItemType(57372)
    public static let offsetDesc = ItemType(57373)
    public static let negativeOffsetDesc = ItemType(57374)
    public static let bucketsDesc = ItemType(57375)
    public static let negativeBucketsDesc = ItemType(57376)
    public static let zeroBucketDesc = ItemType(57377)
    public static let zeroBucketWidthDesc = ItemType(57378)
    public static let customValuesDesc = ItemType(57379)
    public static let counterResetHintDesc = ItemType(57380)
    static let histogramDescEnd = ItemType(57381)

    static let operatorsStart = ItemType(57382)
    public static let add = ItemType(57383)
    public static let div = ItemType(57384)
    public static let eqlc = ItemType(57385)
    public static let eqlRegex = ItemType(57386)
    public static let gte = ItemType(57387)
    public static let gtr = ItemType(57388)
    public static let trimUpper = ItemType(57389)
    public static let trimLower = ItemType(57390)
    public static let land = ItemType(57391)
    public static let lor = ItemType(57392)
    public static let lss = ItemType(57393)
    public static let lte = ItemType(57394)
    public static let lunless = ItemType(57395)
    public static let mod = ItemType(57396)
    public static let mul = ItemType(57397)
    public static let neq = ItemType(57398)
    public static let neqRegex = ItemType(57399)
    public static let pow = ItemType(57400)
    public static let sub = ItemType(57401)
    public static let at = ItemType(57402)
    public static let atan2 = ItemType(57403)
    static let operatorsEnd = ItemType(57404)

    static let aggregatorsStart = ItemType(57405)
    public static let avg = ItemType(57406)
    public static let bottomk = ItemType(57407)
    public static let count = ItemType(57408)
    public static let countValues = ItemType(57409)
    public static let group = ItemType(57410)
    public static let max = ItemType(57411)
    public static let min = ItemType(57412)
    public static let quantile = ItemType(57413)
    public static let stddev = ItemType(57414)
    public static let stdvar = ItemType(57415)
    public static let sum = ItemType(57416)
    public static let topk = ItemType(57417)
    public static let limitk = ItemType(57418)
    public static let limitRatio = ItemType(57419)
    static let aggregatorsEnd = ItemType(57420)

    static let keywordsStart = ItemType(57421)
    public static let bool = ItemType(57422)
    public static let by = ItemType(57423)
    public static let groupLeft = ItemType(57424)
    public static let groupRight = ItemType(57425)
    public static let fill = ItemType(57426)
    public static let fillLeft = ItemType(57427)
    public static let fillRight = ItemType(57428)
    public static let ignoring = ItemType(57429)
    public static let offset = ItemType(57430)
    public static let smoothed = ItemType(57431)
    public static let anchored = ItemType(57432)
    public static let on = ItemType(57433)
    public static let without = ItemType(57434)
    static let keywordsEnd = ItemType(57435)

    static let preprocessorStart = ItemType(57436)
    public static let start = ItemType(57437)
    public static let end = ItemType(57438)
    public static let step = ItemType(57439)
    public static let range = ItemType(57440)
    public static let maxOf = ItemType(57441)
    public static let minOf = ItemType(57442)
    static let preprocessorEnd = ItemType(57443)

    static let counterResetHintsStart = ItemType(57444)
    public static let unknownCounterReset = ItemType(57445)
    public static let counterReset = ItemType(57446)
    public static let notCounterReset = ItemType(57447)
    public static let gaugeType = ItemType(57448)
}

// MARK: - Predicates

extension ItemType {
    /// Go: `IsOperator` — an arithmetic or set operator.
    public var isOperator: Bool { self > .operatorsStart && self < .operatorsEnd }

    /// Go: `IsAggregator`.
    public var isAggregator: Bool { self > .aggregatorsStart && self < .aggregatorsEnd }

    /// Go: `IsAggregatorWithParam`.
    public var isAggregatorWithParam: Bool {
        self == .topk || self == .bottomk || self == .countValues || self == .quantile
            || self == .limitk || self == .limitRatio
    }

    /// Go: `IsExperimentalAggregator` — gated behind `EnableExperimentalFunctions`.
    public var isExperimentalAggregator: Bool { self == .limitk || self == .limitRatio }

    /// Go: `IsKeyword`.
    public var isKeyword: Bool { self > .keywordsStart && self < .keywordsEnd }

    /// Go: `IsComparisonOperator`.
    public var isComparisonOperator: Bool {
        switch self {
        case .eqlc, .neq, .lte, .lss, .gte, .gtr: return true
        default: return false
        }
    }

    /// Go: `IsSetOperator`.
    public var isSetOperator: Bool {
        switch self {
        case .land, .lor, .lunless: return true
        default: return false
        }
    }
}

// MARK: - Keyword tables

/// Go: `key` — every PromQL keyword.
///
/// Note the two entries `init()` adds after `ItemTypeStr` is built: `inf` and
/// `nan` map to `number`, and deliberately do *not* appear in `ItemTypeStr`.
let promQLKeywords: [String: ItemType] = [
    // Operators.
    "and": .land,
    "or": .lor,
    "unless": .lunless,
    "atan2": .atan2,

    // Aggregators.
    "sum": .sum,
    "avg": .avg,
    "count": .count,
    "min": .min,
    "max": .max,
    "group": .group,
    "stddev": .stddev,
    "stdvar": .stdvar,
    "topk": .topk,
    "bottomk": .bottomk,
    "count_values": .countValues,
    "quantile": .quantile,
    "limitk": .limitk,
    "limit_ratio": .limitRatio,

    // Keywords.
    "offset": .offset,
    "smoothed": .smoothed,
    "anchored": .anchored,
    "by": .by,
    "without": .without,
    "on": .on,
    "ignoring": .ignoring,
    "group_left": .groupLeft,
    "group_right": .groupRight,
    "fill": .fill,
    "fill_left": .fillLeft,
    "fill_right": .fillRight,
    "bool": .bool,

    // Preprocessors.
    "start": .start,
    "end": .end,
    "step": .step,
    "range": .range,
    "max_of": .maxOf,
    "min_of": .minOf,

    // Added by Go's init(), after ItemTypeStr is populated: special numbers.
    "inf": .number,
    "nan": .number,
]

/// Go: `histogramDesc`.
let histogramDesc: [String: ItemType] = [
    "sum": .sumDesc,
    "count": .countDesc,
    "schema": .schemaDesc,
    "offset": .offsetDesc,
    "n_offset": .negativeOffsetDesc,
    "buckets": .bucketsDesc,
    "n_buckets": .negativeBucketsDesc,
    "z_bucket": .zeroBucketDesc,
    "z_bucket_w": .zeroBucketWidthDesc,
    "custom_values": .customValuesDesc,
    "counter_reset_hint": .counterResetHintDesc,
]

/// Go: `counterResetHints`.
let counterResetHints: [String: ItemType] = [
    "unknown": .unknownCounterReset,
    "reset": .counterReset,
    "not_reset": .notCounterReset,
    "gauge": .gaugeType,
]

/// Go: `durationKeywordTokens`.
let durationKeywordTokens: [String: ItemType] = [
    "step": .step,
    "range": .range,
    "max_of": .maxOf,
    "min_of": .minOf,
]

/// Go: `durationKeywordStartChars`, derived from the table above.
let durationKeywordStartChars: Set<UInt32> = Set(
    durationKeywordTokens.keys.map { UInt32($0.utf8.first!) })

/// Go: `isDurationKeywordStartChar`.
func isDurationKeywordStartChar(_ r: Int32) -> Bool {
    guard r >= 0 else { return false }
    return durationKeywordStartChars.contains(goToLower(UInt32(r)))
}

/// Go: `ItemTypeStr` — the default rendering for the common items. It does not
/// imply those are the only character sequences that lex to them.
///
/// Go builds this as a literal and then has `init()` add every entry of `key`.
/// Because `key` gains `inf`/`nan` → `number` only *after* that loop, `number`
/// stays absent here — which is why a number renders through `desc()`'s named
/// fallback rather than as a literal.
public let itemTypeStr: [ItemType: String] = {
    var m: [ItemType: String] = [
        .openHist: "{{",
        .closeHist: "}}",
        .leftParen: "(",
        .rightParen: ")",
        .leftBrace: "{",
        .rightBrace: "}",
        .leftBracket: "[",
        .rightBracket: "]",
        .comma: ",",
        .eql: "=",
        .colon: ":",
        .semicolon: ";",
        .blank: "_",
        .times: "x",
        .space: "<space>",

        .sub: "-",
        .add: "+",
        .mul: "*",
        .mod: "%",
        .div: "/",
        .eqlc: "==",
        .neq: "!=",
        .lte: "<=",
        .lss: "<",
        .gte: ">=",
        .gtr: ">",
        .trimUpper: "</",
        .trimLower: ">/",
        .eqlRegex: "=~",
        .neqRegex: "!~",
        .pow: "^",
        .at: "@",
    ]
    // Go's init() adds the keywords. It iterates a map, so when two keywords share
    // an ItemType the winner is random — but `key` has no duplicate values at this
    // point, so the result is deterministic.
    for (s, ty) in promQLKeywords where ty != .number {
        m[ty] = s
    }
    return m
}()

extension ItemType: CustomStringConvertible {
    /// Go: `ItemType.String()`.
    public var description: String {
        if let s = itemTypeStr[self] { return s }
        return "<Item \(rawValue)>"
    }

    /// Go: `ItemType.desc()` — a human-readable name for error messages.
    ///
    /// The fallback applies `%q` to the raw token number, which renders as a rune
    /// literal. Reachable for histogram descriptors and counter-reset hints, which
    /// `itemTypeStr` does not cover.
    var desc: String {
        switch self {
        case .error: return "error"
        case .eof: return "end of input"
        case .comment: return "comment"
        case .identifier: return "identifier"
        case .metricIdentifier: return "metric identifier"
        case .string: return "string"
        case .number: return "number"
        case .duration: return "duration"
        default:
            return GoFmt.quoteVerb(Int64(rawValue))
        }
    }
}

// MARK: - Item

/// Go: `Item` — a token, or the text of an error.
///
/// `val` is bytes, not a `String`, because a Go `string` here is a slice of the
/// raw query and a comment absorbs everything up to the newline — including
/// invalid UTF-8. ADR-9: the primitive takes `[UInt8]` and the `String` form wraps
/// it. `pos` is a byte offset for the same reason.
public struct Item: Sendable, Hashable {
    /// The type of this item.
    public var typ: ItemType
    /// The starting position, **in bytes**, of this item in the input.
    public var pos: Pos
    /// The value of this item. For `error` items this is the message.
    public var val: [UInt8]

    public init(typ: ItemType, pos: Pos, val: [UInt8]) {
        self.typ = typ
        self.pos = pos
        self.val = val
    }

    public init(typ: ItemType, pos: Pos, val: String) {
        self.init(typ: typ, pos: pos, val: Array(val.utf8))
    }

    /// `val` decoded as UTF-8, with U+FFFD substituted for invalid bytes. Only for
    /// display and for surfaces already known to be valid UTF-8.
    public var valString: String { String(decoding: val, as: UTF8.self) }
}

extension Item: CustomStringConvertible {
    /// Go: `Item.String()`.
    public var description: String {
        if typ == .eof { return "EOF" }
        if typ == .error { return valString }
        if typ == .identifier || typ == .metricIdentifier { return GoStrconv.quote(bytes: val) }
        if typ.isKeyword { return "<\(valString)>" }
        if typ.isOperator { return "<op:\(valString)>" }
        if typ.isAggregator { return "<aggr:\(valString)>" }
        if val.count > 10 {
            // Go: %.10q, whose precision truncates the operand to 10 RUNES before
            // quoting — not 10 bytes and not 10 grapheme clusters.
            return GoStrconv.quote(bytes: Self.truncateRunes(val, 10)) + "..."
        }
        return GoStrconv.quote(bytes: val)
    }

    /// Go: `fmt.truncateString` — keep the first `n` runes.
    static func truncateRunes(_ bytes: [UInt8], _ n: Int) -> [UInt8] {
        var i = 0
        var runes = 0
        while i < bytes.count {
            if runes == n { return Array(bytes[0..<i]) }
            let (_, width) = GoStrconv.decodeRune(bytes, i)
            i += width
            runes += 1
        }
        return bytes
    }

    /// Go: `Item.desc()`.
    var desc: String {
        if itemTypeStr[typ] != nil { return description }
        if typ == .eof { return typ.desc }
        return "\(typ.desc) \(description)"
    }

    /// Go: `Item.Pretty` — the same as `String()`.
    public func pretty(_: Int) -> String { description }
}
