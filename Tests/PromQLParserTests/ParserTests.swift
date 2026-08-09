//===----------------------------------------------------------------------===//
// Differential tests for promql/parser: ast.go, parse.go, printer.go and
// prettier.go, against the committed promql/parse, promql/seriesdesc,
// promql/metric and promql/metricselector fixtures.
//
// The AST is compared through the same serialisation the oracle uses — a copy of
// web/api/v1/translate_ast.go — so the field set is upstream's choice rather than
// this port's. Comparison is over a decoded JSON tree, not over encoded text, so
// key order cannot make a passing case fail.
//
// Queries travel as hex: a PromQL query can hold invalid UTF-8, and JSON cannot
// (ADR-9).
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromLabels
import Testing

@testable import PromQLParser

// MARK: - The wire shapes

/// A decoded JSON value, so an `ast` can be compared structurally.
///
/// Numbers are all integers in this serialisation — millisecond durations,
/// timestamps and `variadic`. A fractional number would fail to decode, which is
/// the right outcome: it would mean the shape changed.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
}

struct ParseErrJSON: Codable, Equatable, Sendable {
    let start: Int32
    let end: Int32
    let msg: String
    let rendered: String
}

struct ParseIn: Decodable, Sendable {
    let query: String
    let opts: String
}

struct ParseOut: Decodable, Equatable, Sendable {
    let errors: [ParseErrJSON]?
    let unexpected: Bool
    let other: String
    let ok: Bool
    let ast: JSONValue?
    let str: String
    let pretty: String
    let tree: String
    let type: String
    let reparse: String
}

// MARK: - Options

extension Options {
    /// The named option sets the oracle generates under.
    static func named(_ name: String) -> Options {
        switch name {
        case "off":
            return Options()
        case "all":
            return Options(
                enableExperimentalFunctions: true,
                experimentalDurationExpr: true,
                enableExtendedRangeSelectors: true,
                enableBinopFillModifiers: true)
        case "expfn":
            return Options(enableExperimentalFunctions: true)
        case "durexpr":
            return Options(experimentalDurationExpr: true)
        case "extrange":
            return Options(enableExtendedRangeSelectors: true)
        case "fill":
            return Options(enableBinopFillModifiers: true)
        default:
            preconditionFailure("unknown option set \(name)")
        }
    }
}

// MARK: - The test

@Suite("PromQL parser matches Go")
struct ParserTests {

    /// Runs one query the way the oracle's `runParse` does.
    static func run(_ input: ParseIn) -> ParseOut {
        let parser = PromQLParser(options: Options.named(input.opts))
        let query = Hex.decode(input.query)

        let expr: (any Expr)?
        var errors: [ParseErrJSON] = []
        do {
            expr = try parser.parseExpr(query)
        } catch let e as ParseErrors {
            expr = nil
            errors = e.errors.map {
                ParseErrJSON(
                    start: $0.positionRange.start,
                    end: $0.positionRange.end,
                    msg: $0.message,
                    rendered: $0.description)
            }
        } catch {
            return ParseOut(
                errors: nil, unexpected: false, other: String(describing: error),
                ok: false, ast: nil, str: "", pretty: "", tree: "", type: "", reparse: "")
        }

        guard let expr else {
            return ParseOut(
                errors: errors.isEmpty ? nil : errors, unexpected: false, other: "",
                ok: false, ast: nil, str: "", pretty: "", tree: "", type: "", reparse: "")
        }

        let str = expr.description
        var reparse = "<reparse failed>"
        if let reparsed = try? parser.parseExpr(str) {
            reparse = reparsed.description
        }

        return ParseOut(
            errors: nil,
            unexpected: false,
            other: "",
            ok: true,
            ast: translateAST(expr),
            str: str,
            pretty: prettify(expr),
            tree: tree(expr),
            type: expr.type.rawValue,
            reparse: reparse)
    }

    @Test("every committed parse case: AST, errors, printing and the reparse")
    func parses() throws {
        try Fixtures.check("promql/parse.jsonl", FixtureCase<ParseIn, ParseOut>.self) { input in
            Self.run(input)
        }
    }
}

// MARK: - The AST serialisation

/// A port of `web/api/v1/translate_ast.go` @ v3.13.2, matching the copy in
/// `oracle/suites_promql_parse.go` field for field.
///
/// One deliberate difference from upstream, shared with the oracle: fill values
/// are hex bit patterns rather than JSON numbers, because `fill (NaN)` is a legal
/// query and JSON cannot carry NaN.
func translateAST(_ node: (any Expr)?) -> JSONValue {
    guard let node else { return .null }

    switch node {
    case let n as AggregateExpr:
        return .object([
            "type": .string("aggregation"),
            "op": .string(n.op.description),
            "expr": translateAST(n.expr),
            "param": translateAST(n.param),
            "grouping": .array(n.grouping.map { .string($0) }),
            "without": .bool(n.without),
        ])

    case let n as BinaryExpr:
        var matching = JSONValue.null
        if let m = n.vectorMatching {
            matching = .object([
                "card": .string(m.card.description),
                "labels": .array(m.matchingLabels.map { .string($0) }),
                "on": .bool(m.on),
                "include": .array(m.include.map { .string($0) }),
                "fillValues": .object([
                    "lhs": m.fillValues.lhs.map { .string(hexBits($0)) } ?? .null,
                    "rhs": m.fillValues.rhs.map { .string(hexBits($0)) } ?? .null,
                ]),
            ])
        }
        return .object([
            "type": .string("binaryExpr"),
            "op": .string(n.op.description),
            "lhs": translateAST(n.lhs),
            "rhs": translateAST(n.rhs),
            "matching": matching,
            "bool": .bool(n.returnBool),
        ])

    case let n as Call:
        return .object([
            "type": .string("call"),
            "func": .object([
                "name": .string(n.function?.name ?? ""),
                "argTypes": .array((n.function?.argTypes ?? []).map { .string($0.rawValue) }),
                "variadic": .int(Int64(n.function?.variadic ?? 0)),
                "returnType": .string(n.function?.returnType.rawValue ?? ""),
            ]),
            "args": .array(n.args.map { translateAST($0) }),
        ])

    case let n as MatrixSelector:
        let vs = n.vectorSelector as? VectorSelector
        return .object([
            "type": .string("matrixSelector"),
            "name": .string(vs?.name ?? ""),
            "range": .int(n.range.nanoseconds / 1_000_000),
            "rangeExpr": translateDurationExpr(n.rangeExpr),
            "offset": .int((vs?.originalOffset.nanoseconds ?? 0) / 1_000_000),
            "offsetExpr": translateDurationExpr(vs?.originalOffsetExpr),
            "matchers": translateMatchers(vs?.labelMatchers ?? []),
            "timestamp": vs?.timestamp.map { .int($0) } ?? .null,
            "startOrEnd": startOrEnd(vs?.startOrEnd ?? ItemType(0)),
            "anchored": .bool(vs?.anchored ?? false),
            "smoothed": .bool(vs?.smoothed ?? false),
        ])

    case let n as SubqueryExpr:
        return .object([
            "type": .string("subquery"),
            "expr": translateAST(n.expr),
            "range": .int(n.range.nanoseconds / 1_000_000),
            "rangeExpr": translateDurationExpr(n.rangeExpr),
            "offset": .int(n.originalOffset.nanoseconds / 1_000_000),
            "offsetExpr": translateDurationExpr(n.originalOffsetExpr),
            "step": .int(n.step.nanoseconds / 1_000_000),
            "stepExpr": translateDurationExpr(n.stepExpr),
            "timestamp": n.timestamp.map { .int($0) } ?? .null,
            "startOrEnd": startOrEnd(n.startOrEnd),
        ])

    case let n as DurationExpr:
        return translateDurationExpr(n)

    case let n as NumberLiteral:
        // Note: the top-level form omits `duration`, unlike the duration-position
        // form below. That asymmetry is upstream's.
        return .object([
            "type": .string("numberLiteral"),
            "val": .string(formatFloatF(n.val)),
        ])

    case let n as ParenExpr:
        return .object([
            "type": .string("parenExpr"),
            "expr": translateAST(n.expr),
        ])

    case let n as StringLiteral:
        return .object([
            "type": .string("stringLiteral"),
            // Go's json.Marshal substitutes U+FFFD for invalid UTF-8 in a string,
            // so the serialised form is the decoded one even though printing is
            // byte-exact.
            "val": .string(n.valString),
        ])

    case let n as UnaryExpr:
        return .object([
            "type": .string("unaryExpr"),
            "op": .string(n.op.description),
            "expr": translateAST(n.expr),
        ])

    case let n as VectorSelector:
        return .object([
            "type": .string("vectorSelector"),
            "name": .string(n.name),
            "offset": .int(n.originalOffset.nanoseconds / 1_000_000),
            "offsetExpr": translateDurationExpr(n.originalOffsetExpr),
            "matchers": translateMatchers(n.labelMatchers),
            "timestamp": n.timestamp.map { .int($0) } ?? .null,
            "startOrEnd": startOrEnd(n.startOrEnd),
            "anchored": .bool(n.anchored),
            "smoothed": .bool(n.smoothed),
        ])

    default:
        preconditionFailure("unsupported node type \(node.nodeTypeName)")
    }
}

func translateDurationExpr(_ node: (any Expr)?) -> JSONValue {
    guard let node else { return .null }
    switch node {
    case let n as DurationExpr:
        return .object([
            "type": .string("durationExpr"),
            "op": .string(n.op.description),
            "lhs": translateDurationExpr(n.lhs),
            "rhs": translateDurationExpr(n.rhs),
            "wrapped": .bool(n.wrapped),
        ])
    case let n as NumberLiteral:
        return .object([
            "type": .string("numberLiteral"),
            "val": .string(formatFloatF(n.val)),
            "duration": .bool(n.duration),
        ])
    default:
        return translateAST(node)
    }
}

func translateMatchers(_ matchers: [Matcher?]) -> JSONValue {
    .array(
        matchers.compactMap { m in
            guard let m else { return nil }
            return JSONValue.object([
                "name": .string(m.name),
                "value": .string(m.value),
                "type": .string(m.type.description),
            ])
        })
}

func startOrEnd(_ t: ItemType) -> JSONValue {
    t == ItemType(0) ? .null : .string(t.description)
}
