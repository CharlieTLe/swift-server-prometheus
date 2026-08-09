//===----------------------------------------------------------------------===//
// Differential tests for promql/durations.go and PreprocessExpr.
//
// This is the query-preparation pass: four rewrites over the parsed AST, in a
// fixed order, all of them in-place field assignments on nodes (ADR-11). The
// fixture drives `promql.PreprocessExpr` on the Go side over the committed
// 6,000-expression parse corpus at seven (start, end, step) triples, plus a
// hand-written corpus for the error branches and the step-invariance shapes.
//
// The serialiser below mirrors `oracle/suites_promql_preprocess.go` field for
// field. It is deliberately not the `translate_ast.go` port used by the parse
// suite: that one panics on `StepInvariantExpr` and omits `SkipHistogramBuckets`,
// because upstream's HTTP API serialises the tree as *parsed*.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromModel
import PromPosRange
import Testing

@testable import PromQL
@testable import PromQLParser

// MARK: - Wire shapes

struct PreprocessIn: Decodable, Sendable {
    /// Hex-encoded: a query can hold invalid UTF-8 and JSON cannot (ADR-9).
    let query: String
    let opts: String
    let range: String
}

struct PreprocessOut: Decodable, Equatable, Sendable {
    let err: String
    let ok: Bool
    let ast: JSONValue?
    let str: String
    let panic: String
}

// MARK: - The (start, end, step) triples

/// Must match `preprocessTimeRanges` in the oracle exactly, by name.
struct PreprocessRange {
    let start: GoTime
    let end: GoTime
    let step: GoDuration

    static func named(_ name: String) -> PreprocessRange {
        switch name {
        case "instant":
            return PreprocessRange(
                start: .unix(1_600_000_000, 0), end: .unix(1_600_000_000, 0),
                step: GoDuration(nanoseconds: 0))
        case "instant-nonzero-step":
            return PreprocessRange(
                start: .unix(1_600_000_000, 0), end: .unix(1_600_000_000, 0), step: .minute)
        case "range":
            return PreprocessRange(
                start: .unix(1_600_000_000, 0), end: .unix(1_600_003_600, 0), step: .minute)
        case "range-subsecond":
            return PreprocessRange(
                start: .unix(1_600_000_000, 123_456_789),
                end: .unix(1_600_007_200, 987_654_321),
                step: GoDuration(nanoseconds: 1_500_000_000))
        case "epoch":
            return PreprocessRange(
                start: .unix(0, 0), end: .unix(0, 0), step: GoDuration(nanoseconds: 0))
        case "pre-epoch":
            return PreprocessRange(
                start: .unix(-2_000_000_000, 0), end: .unix(-1_000_000_000, 0), step: .hour)
        case "huge-range":
            return PreprocessRange(
                start: .unix(0, 0), end: .unix(200_000_000_000, 0),
                step: GoDuration(nanoseconds: 24 * 60 * 60 * 1_000_000_000))
        default:
            preconditionFailure("unknown preprocess range \(name)")
        }
    }
}

// MARK: - The serialiser

/// Mirrors `translatePreprocessed` in `oracle/suites_promql_preprocess.go`.
func translatePreprocessed(_ node: (any Expr)?) -> JSONValue {
    guard let node else { return .null }

    switch node {
    case let n as StepInvariantExpr:
        return .object([
            "type": .string("stepInvariant"),
            "expr": translatePreprocessed(n.expr),
        ])

    case let n as VectorSelector:
        return .object([
            "type": .string("vectorSelector"),
            "name": .string(n.name),
            "offsetMS": .int(milliseconds(n.originalOffset)),
            "timestamp": n.timestamp.map { JSONValue.int($0) } ?? .null,
            "startOrEnd": startOrEndJSON(n.startOrEnd),
            "skipHistogramBuckets": .bool(n.skipHistogramBuckets),
            "hasOffsetExpr": .bool(n.originalOffsetExpr != nil),
        ])

    case let n as MatrixSelector:
        guard let vs = n.vectorSelector as? VectorSelector else {
            preconditionFailure("MatrixSelector without a VectorSelector")
        }
        return .object([
            "type": .string("matrixSelector"),
            "rangeMS": .int(milliseconds(n.range)),
            "hasRangeExpr": .bool(n.rangeExpr != nil),
            "name": .string(vs.name),
            "offsetMS": .int(milliseconds(vs.originalOffset)),
            "timestamp": vs.timestamp.map { JSONValue.int($0) } ?? .null,
            "startOrEnd": startOrEndJSON(vs.startOrEnd),
            "skipHistogramBuckets": .bool(vs.skipHistogramBuckets),
            "hasOffsetExpr": .bool(vs.originalOffsetExpr != nil),
        ])

    case let n as SubqueryExpr:
        return .object([
            "type": .string("subquery"),
            "expr": translatePreprocessed(n.expr),
            "rangeMS": .int(milliseconds(n.range)),
            "hasRangeExpr": .bool(n.rangeExpr != nil),
            "stepMS": .int(milliseconds(n.step)),
            "hasStepExpr": .bool(n.stepExpr != nil),
            "offsetMS": .int(milliseconds(n.originalOffset)),
            "hasOffsetExpr": .bool(n.originalOffsetExpr != nil),
            "timestamp": n.timestamp.map { JSONValue.int($0) } ?? .null,
            "startOrEnd": startOrEndJSON(n.startOrEnd),
        ])

    case let n as NumberLiteral:
        return .object([
            "type": .string("numberLiteral"),
            "bits": .string(hexBitsQ(n.val)),
            "duration": .bool(n.duration),
        ])

    case let n as Call:
        return .object([
            "type": .string("call"),
            "func": .string(n.function?.name ?? ""),
            "args": .array(n.args.map { translatePreprocessed($0) }),
        ])

    case let n as AggregateExpr:
        return .object([
            "type": .string("aggregation"),
            "op": .string(n.op.description),
            "expr": translatePreprocessed(n.expr),
            "param": translatePreprocessed(n.param),
            "grouping": .array(n.grouping.map { JSONValue.string($0) }),
            "without": .bool(n.without),
        ])

    case let n as BinaryExpr:
        return .object([
            "type": .string("binaryExpr"),
            "op": .string(n.op.description),
            "lhs": translatePreprocessed(n.lhs),
            "rhs": translatePreprocessed(n.rhs),
        ])

    case let n as ParenExpr:
        return .object([
            "type": .string("parenExpr"),
            "expr": translatePreprocessed(n.expr),
        ])

    case let n as UnaryExpr:
        return .object([
            "type": .string("unaryExpr"),
            "op": .string(n.op.description),
            "expr": translatePreprocessed(n.expr),
        ])

    case let n as StringLiteral:
        return .object([
            "type": .string("stringLiteral"),
            "val": .string(Hex.encode(n.val)),
        ])

    case let n as DurationExpr:
        return .object([
            "type": .string("durationExpr"),
            "op": .string(n.op.description),
            "lhs": translatePreprocessed(n.lhs),
            "rhs": translatePreprocessed(n.rhs),
        ])

    default:
        return .object([
            "type": .string("UNHANDLED"),
            "goType": .string("*parser.\(node.nodeTypeName)"),
        ])
    }
}

/// Go: `time.Duration.Milliseconds()` — truncating integer division, so a
/// sub-millisecond duration reports 0 and a negative one truncates toward zero.
private func milliseconds(_ d: GoDuration) -> Int64 {
    d.nanoseconds / 1_000_000
}

private func startOrEndJSON(_ t: ItemType) -> JSONValue {
    t == ItemType(0) ? .null : .string(t.description)
}

/// The option sets the oracle generates under, by the name it puts on the wire.
///
/// Note "durexpr" enables experimental *functions* as well: the error corpus uses
/// `step()`/`range()`/`max_of()`, which are gated behind that flag rather than
/// behind `ExperimentalDurationExpr`. Getting this wrong makes every error case
/// fail to parse rather than fail to preprocess.
func preprocessOptions(_ name: String) -> Options {
    switch name {
    case "all":
        return Options(
            enableExperimentalFunctions: true, experimentalDurationExpr: true,
            enableExtendedRangeSelectors: true, enableBinopFillModifiers: true)
    case "off":
        return Options()
    case "durexpr":
        return Options(enableExperimentalFunctions: true, experimentalDurationExpr: true)
    default:
        preconditionFailure("unknown preprocess option set \(name)")
    }
}

// MARK: - Tests

@Suite("PreprocessExpr and the duration visitor")
struct PreprocessTests {

    static func run(_ input: PreprocessIn) -> PreprocessOut {
        let query = Hex.decode(input.query)
        let parser = Parser(options: preprocessOptions(input.opts))
        let range = PreprocessRange.named(input.range)

        // A fresh parse per case, exactly as the oracle does. PreprocessExpr
        // mutates the tree in place, so reusing one across ranges would compound
        // the rewrites and make the whole corpus meaningless.
        guard let expr = try? parser.parseExpr(query) else {
            preconditionFailure(
                "preprocess fixture case did not parse in Swift: \(String(decoding: query, as: UTF8.self))"
            )
        }

        do {
            let result = try preprocessExpr(
                expr, start: range.start, end: range.end, step: range.step)
            return PreprocessOut(
                err: "", ok: true, ast: translatePreprocessed(result),
                str: result.description, panic: "")
        } catch {
            return PreprocessOut(
                err: String(describing: error), ok: false, ast: nil, str: "", panic: "")
        }
    }

    @Test("every committed case")
    func fixtures() throws {
        try Fixtures.check("promql/preprocess.jsonl", FixtureCase<PreprocessIn, PreprocessOut>.self)
        { input in
            Self.run(input)
        }
    }

    // MARK: - Invariants the corpus cannot state

    @Test("the error messages carry byte offsets, not line:col")
    func errorPrefixIsByteOffsets() throws {
        // This is the trap: `ParseErr` renders `line:col`, and these are NOT
        // ParseErrs. `foo[1h / (1h - 1h)]` puts the DurationExpr at bytes 4..17.
        let parser = Parser(options: preprocessOptions("durexpr"))
        do {
            _ = try preprocessExpr(
                try parser.parseExpr("foo[1h / (1h - 1h)]"),
                start: .unix(0, 0), end: .unix(3600, 0), step: .minute)
            Issue.record("expected a division-by-zero error")
        } catch {
            #expect(String(describing: error) == "4:17: division by zero")
        }
    }

    @Test("the parser folds literal duration expressions first, so both error forms exist")
    func parserFoldsLiteralsFirst() throws {
        // docs/PORTING.md quirk 31. `foo[1h % 0]` never reaches the visitor: the
        // parser constant-folds it and reports its own ParseErr with a line:col
        // prefix. Only a non-foldable operand reaches durationVisitor.
        let parser = Parser(options: preprocessOptions("durexpr"))
        #expect(throws: (any Error).self) {
            _ = try parser.parseExpr("foo[1h % 0]")
        }
        // ... whereas this one parses and fails in the visitor, with byte offsets.
        let expr = try parser.parseExpr("foo[1h % (1h - 1h)]")
        do {
            _ = try preprocessExpr(
                expr, start: .unix(0, 0), end: .unix(3600, 0), step: .minute)
            Issue.record("expected a modulo-by-zero error")
        } catch {
            #expect(String(describing: error) == "4:17: modulo by zero")
        }
    }

    @Test("a negative duration is legal in an offset and nowhere else")
    func negativeAllowedOnlyForOffset() throws {
        let parser = Parser(options: preprocessOptions("durexpr"))
        let start = GoTime.unix(0, 0)
        let end = GoTime.unix(3600, 0)

        // `allowedNegative: true` — only the offset positions pass it.
        let offset = try preprocessExpr(
            try parser.parseExpr("foo offset (1h - 2h)"),
            start: start, end: end, step: .minute)
        let vs = (offset as? VectorSelector) ?? {
            preconditionFailure("expected a VectorSelector")
        }()
        #expect(vs.originalOffset.nanoseconds == -3600 * 1_000_000_000)

        // A range must be strictly positive.
        do {
            _ = try preprocessExpr(
                try parser.parseExpr("foo[1h - 2h]"),
                start: start, end: end, step: .minute)
            Issue.record("expected a must-be-greater-than-0 error")
        } catch {
            #expect(String(describing: error) == "4:11: duration must be greater than 0")
        }
    }

    @Test("step() folds to 0 on an instant query even when step is non-zero")
    func stepOnInstantQuery() throws {
        // `foldQueryContextFunctions` gates on `!start.Equal(end)`, not on step
        // being zero. A port that read `step` unconditionally would pass every
        // range case and fail only here.
        let parser = Parser(options: preprocessOptions("durexpr"))
        let at = GoTime.unix(1_600_000_000, 0)
        let folded = try preprocessExpr(
            try parser.parseExpr("step()"), start: at, end: at, step: .minute)
        // A bare step() is step-invariant, so it comes back wrapped.
        let inner = (folded as? StepInvariantExpr)?.expr ?? folded
        #expect((inner as? NumberLiteral)?.val == 0)

        // The same query over a real range folds to the step in seconds.
        let ranged = try preprocessExpr(
            try parser.parseExpr("step()"),
            start: at, end: GoTime.unix(1_600_003_600, 0), step: .minute)
        let rangedInner = (ranged as? StepInvariantExpr)?.expr ?? ranged
        #expect((rangedInner as? NumberLiteral)?.val == 60)
    }

    @Test("timestamp() is @-unsafe except over bare vector selectors")
    func timestampSpecialCase() throws {
        let parser = Parser(options: preprocessOptions("all"))
        let start = GoTime.unix(0, 0)
        let end = GoTime.unix(3600, 0)

        // Step-invariant: every argument is a vector selector with an @.
        let overSelector = try preprocessExpr(
            try parser.parseExpr("timestamp(foo @ 1)"), start: start, end: end, step: .minute)
        #expect(overSelector is StepInvariantExpr)

        // Not step-invariant: the argument is a Call, not a VectorSelector, even
        // though it is itself invariant.
        let overCall = try preprocessExpr(
            try parser.parseExpr("timestamp(abs(foo @ 1))"),
            start: start, end: end, step: .minute)
        #expect(!(overCall is StepInvariantExpr))
    }

    @Test("detectHistogramStatsDecoding's veto walks the whole path")
    func histogramStatsVeto() throws {
        let parser = Parser(options: preprocessOptions("all"))
        let start = GoTime.unix(0, 0)
        let end = GoTime.unix(3600, 0)

        func skipFlag(_ q: String) throws -> Bool {
            let out = try preprocessExpr(
                try parser.parseExpr(q), start: start, end: end, step: .minute)
            var found: Bool?
            inspect(out) { node, _ in
                if let vs = node as? VectorSelector { found = vs.skipHistogramBuckets }
            }
            guard let found else {
                preconditionFailure("no VectorSelector in \(q)")
            }
            return found
        }

        #expect(try skipFlag("histogram_count(foo)"))
        #expect(try skipFlag("histogram_sum(foo)"))
        #expect(try skipFlag("histogram_avg(foo)"))
        #expect(try !skipFlag("histogram_quantile(0.5, foo)"))
        // Set by the inner histogram_count, then vetoed by the subquery above it —
        // the reason the loop continues instead of stopping at the first match.
        #expect(try !skipFlag("histogram_count(sum_over_time(foo[5m:1m]))"))
        // The trim operators depend on buckets too.
        #expect(try !skipFlag("histogram_count(foo </ 0.5)"))
        #expect(try !skipFlag("histogram_count(foo >/ 0.5)"))
    }

    @Test("folding leaves the duration expression in place")
    func foldingDoesNotClearTheExpr() throws {
        // durationVisitor writes `Range`/`OriginalOffset` and leaves `RangeExpr`/
        // `OriginalOffsetExpr` alone. Clearing them would still produce the right
        // numbers, so only this distinguishes the two.
        let parser = Parser(options: preprocessOptions("durexpr"))
        let out = try preprocessExpr(
            try parser.parseExpr("foo[1h + 30m] offset (2h / 2)"),
            start: .unix(0, 0), end: .unix(3600, 0), step: .minute)
        guard let ms = out as? MatrixSelector,
            let vs = ms.vectorSelector as? VectorSelector
        else {
            preconditionFailure("expected a MatrixSelector")
        }
        #expect(ms.range.nanoseconds == 90 * 60 * 1_000_000_000)
        #expect(ms.rangeExpr != nil)
        #expect(vs.originalOffset.nanoseconds == 3600 * 1_000_000_000)
        #expect(vs.originalOffsetExpr != nil)
    }
}
