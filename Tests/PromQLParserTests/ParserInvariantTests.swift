//===----------------------------------------------------------------------===//
// Properties the fixtures cannot state, and one round trip they enable.
//
// Everything here is a fact about the parser that a case-by-case comparison does
// not make visible: precedence and associativity, where the boundary between an
// expression and a duration expression falls, and which tokens are context
// sensitive. Each was verified against Go before being written down — several of
// them corrected a first guess.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromHistogram
import Testing

@testable import PromQLParser

@Suite("PromQL parser invariants")
struct ParserInvariantTests {

    static let all = Parser(options: Options.named("all"))

    static func str(_ q: String, _ parser: Parser = all) throws -> String {
        try parser.parseExpr(q).description
    }

    static func errorText(_ q: String, _ parser: Parser = all) -> String? {
        do {
            _ = try parser.parseExpr(q)
            return nil
        } catch let e as ParseErrors {
            return e.errors.first?.message
        } catch {
            return String(describing: error)
        }
    }

    @Test("unary minus takes MUL's precedence, so only POW binds tighter")
    func unaryPrecedence() throws {
        // `unary_op expr %prec MUL`. With POW above MUL, the exponentiation is
        // absorbed into the operand and the result is a UnaryExpr over a
        // BinaryExpr — not a negative literal raised to a power.
        let node = try Self.all.parseExpr("-1^2")
        #expect(node is UnaryExpr)
        #expect((node as? UnaryExpr)?.expr is BinaryExpr)
        // At equal precedence the sign folds into the literal instead.
        let mul = try Self.all.parseExpr("-1*2")
        #expect(mul is BinaryExpr)
        #expect((mul as? BinaryExpr)?.lhs is NumberLiteral)
        #expect(try Self.str("-1^2") == "-1 ^ 2")
    }

    @Test("POW is the only right-associative operator")
    func powerAssociativity() throws {
        #expect(try Self.str("2^3^2") == "2 ^ 3 ^ 2")
        let node = try Self.all.parseExpr("2^3^2")
        // Right-associative: the right operand is the nested one.
        #expect((node as? BinaryExpr)?.rhs is BinaryExpr)
        // Left-associative for the rest.
        let sub = try Self.all.parseExpr("1-2-3")
        #expect((sub as? BinaryExpr)?.lhs is BinaryExpr)
    }

    @Test("range, offset and @ bind tighter than every binary operator")
    func postfixBinding() throws {
        // All three are `expr <token> ...` productions above POW in the precedence
        // list, so they attach to the nearest operand rather than to the whole
        // binary expression.
        #expect(try Self.str("1 + foo offset 5m") == "1 + foo offset 5m")
        let sum = try Self.all.parseExpr("1 + foo offset 5m") as? BinaryExpr
        #expect((sum?.rhs as? VectorSelector)?.originalOffset.nanoseconds == 300_000_000_000)
        #expect(try Self.str("foo + rate(bar[5m])") == "foo + rate(bar[5m])")
        // And they compose: a second offset parses and is rejected semantically,
        // rather than being a syntax error.
        #expect(Self.errorText("foo offset 5m offset 5m") == "offset may not be set multiple times")
    }

    @Test("an aggregator name is still a metric name unless a body follows")
    func aggregatorIsAlsoAMetricIdentifier() throws {
        // `sum` is in both `aggregate_op` and `metric_identifier`, and goyacc only
        // reduces to the former when the lookahead can follow it. So `foo * sum`
        // multiplies two selectors.
        #expect(try Self.str("foo * sum") == "foo * sum")
        #expect(try Self.all.parseExpr("min") is VectorSelector)
        #expect(try Self.all.parseExpr("sum(foo)") is AggregateExpr)
        #expect(try Self.all.parseExpr("sum by (a) (foo)") is AggregateExpr)
        // The same rule keeps `start`, `end`, `step` and `offset` usable as names.
        #expect(try Self.all.parseExpr("offset") is VectorSelector)
        #expect(try Self.all.parseExpr("step") is VectorSelector)
    }

    @Test("a bare step() is a function call, not a duration expression")
    func stepIsAFunctionAtTopLevel() throws {
        // `function_call: STEP function_call_body` claims it first, and `step` is in
        // the function table gated behind EnableExperimentalFunctions — which is why
        // enabling only ExperimentalDurationExpr still rejects it.
        #expect(try Self.all.parseExpr("step()") is Call)
        #expect(
            Self.errorText("step()", Parser(options: Options.named("durexpr")))
                == "function \"step\" is not enabled")
        // In duration position it is a DurationExpr instead.
        let matrix = try Self.all.parseExpr("foo[step()]") as? MatrixSelector
        #expect(matrix?.rangeExpr?.op == .step)
    }

    @Test("offset stops at the literal, so arithmetic after it is a binary expression")
    func offsetStopsAtTheLiteral() throws {
        // `offset_duration_expr` and `duration_expr` both derive
        // `number_duration_literal`; goyacc takes the rule declared earlier, which
        // is the offset one. This is what the grammar's own comment about
        // `foo offset -2^2` describes.
        #expect(try Self.str("foo offset -2^2") == "foo offset -2s ^ 2")
        #expect(try Self.str("foo offset 1m+1m") == "foo offset 1m + 1m")
        #expect(try Self.str("foo offset step()*2") == "foo offset step() * 2")
        // Inside brackets there is no competition, so the arithmetic applies.
        #expect(try Self.str("foo[1m+1m*2]") == "foo[1m + 1m * 2]")
        #expect(try Self.str("foo[2^3^2s]") == "foo[2 ^ 3 ^ 2s]")
    }

    @Test("a parenthesised duration literal loses its parentheses when reprinted")
    func parenthesesOnlySurviveOnDurationExpressions() throws {
        // `Wrapped` is a field on DurationExpr only, so `(1m)` in duration position
        // reprints bare while `(1m+1m)` keeps its parentheses.
        #expect(try Self.str("foo[(1m)]") == "foo[1m]")
        #expect(try Self.str("foo[(1m+1m)*2]") == "foo[(1m + 1m) * 2]")
    }

    @Test("a string literal keeps bytes a Swift String cannot hold")
    func stringLiteralIsByteBacked() throws {
        // `"\xff"` is a legal PromQL string whose value is not valid UTF-8. Go's
        // strconv.Quote re-escapes the raw byte; decoding through U+FFFD would
        // change the printed query. This is why StringLiteral.val is [UInt8]
        // (ADR-9).
        let node = try Self.all.parseExpr(#""\xff""#) as? StringLiteral
        #expect(node?.val == [0xFF])
        #expect(node?.description == #""\xff""#)
    }

    @Test("printing sorts matchers by byte, not by Unicode collation")
    func matcherOrderIsByteWise() throws {
        // ADR-10: sort.Strings is byte-wise, and the printed selector has to match.
        #expect(try Self.str(#"foo{b="1",a="2"}"#) == #"foo{a="2",b="1"}"#)
    }

    @Test("a duration prints through model.Duration, never time.Duration")
    func durationsPrintThePromQLWay() throws {
        // `5m`, not `5m0s`; and a sub-millisecond value collapses to `0s`.
        #expect(try Self.str("foo[5m]") == "foo[5m]")
        #expect(try Self.str("foo offset 1h30m") == "foo offset 1h30m")
        #expect(try Self.str("foo[90s]") == "foo[1m30s]")
    }

    @Test("the empty-matcher rule is bypassed only for info()'s second argument")
    func emptyMatcherCheck() {
        #expect(
            Self.errorText(#"{a=""}"#) == "vector selector must contain at least one non-empty matcher")
        #expect(Self.errorText(#"info(foo, {a=""})"#) == nil)
    }
}

// MARK: - The histogram round trip

@Suite("Histogram descriptions round-trip through the parser")
struct HistogramDescriptionRoundTripTests {

    struct FloatHistIn: Decodable, Sendable {
        let crh: UInt8
        let schema: Int32
    }

    struct FloatHistOut: Decodable, Equatable, Sendable {
        let testExpr: String
    }

    /// `FloatHistogram.testExpression()` emits exactly the series-description DSL
    /// the parser reads, so parsing its output and emitting it again must reproduce
    /// the same text. Over the whole committed histogram corpus that exercises
    /// every descriptor key, the bucket and span reconstruction, and the custom
    /// values path — states the promql/lex suite could not reach at all.
    ///
    /// Idempotence rather than equality with the original histogram: the DSL
    /// describes one contiguous span per side, so a histogram with gaps is not
    /// recoverable from it, and requiring equality would only test the subset that
    /// happens to have none.
    @Test("testExpression() is a fixed point of the series-description parser")
    func testExpressionRoundTrips() throws {
        let parser = Parser(options: Options.named("all"))
        let cases = try Fixtures.load(
            "histogram/float.jsonl", FixtureCase<FloatHistIn, FloatHistOut>.self)
        #expect(cases.count > 100, "the histogram corpus should be substantial")

        var failures = 0
        var skipped = 0
        var detail = ""
        for c in cases {
            let line = "metric \(c.out.testExpr)"
            do {
                let (_, values) = try parser.parseSeriesDesc(line)
                guard let h = values.first?.histogram else {
                    failures += 1
                    if failures <= 10 { detail += "  [\(c.id)] no histogram parsed from \(line)\n" }
                    continue
                }
                let again = h.testExpression()
                if again != c.out.testExpr {
                    failures += 1
                    if failures <= 10 {
                        detail += "  [\(c.id)]\n    got  \(again)\n    want \(c.out.testExpr)\n"
                    }
                }
            } catch {
                // Upstream emits some descriptions its own lexer cannot read back.
                // Verified against Go: `metric {{sum:+Inf}}` fails there with the
                // same message and position this port produces, and so does a
                // bucket set holding a non-finite value. Those are skipped rather
                // than tolerated — anything else failing is a real regression.
                if Self.unlexableByUpstream(c.out.testExpr) {
                    skipped += 1
                    continue
                }
                failures += 1
                if failures <= 10 { detail += "  [\(c.id)] \(line) threw \(error)\n" }
            }
        }
        #expect(failures == 0, "\(failures) of \(cases.count) did not round-trip\n\(detail)")
        // The skip list should stay a minority; if it grows, the emitter changed.
        #expect(skipped < cases.count / 4, "\(skipped) of \(cases.count) were skipped")
    }

    /// Whether `testExpression()` produced a description Go's own histogram lexer
    /// rejects: a leading `+` on an infinity, or any non-finite value inside a
    /// bracketed set.
    static func unlexableByUpstream(_ testExpr: String) -> Bool {
        if testExpr.contains("+Inf") { return true }
        var inBracket = false
        var bracketed = ""
        for ch in testExpr {
            if ch == "[" { inBracket = true; bracketed = ""; continue }
            if ch == "]" {
                inBracket = false
                if bracketed.contains("Inf") || bracketed.contains("NaN") { return true }
                continue
            }
            if inBracket { bracketed.append(ch) }
        }
        return false
    }
}
