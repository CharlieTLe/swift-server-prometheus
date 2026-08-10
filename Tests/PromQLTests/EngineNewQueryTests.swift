//===----------------------------------------------------------------------===//
// Differential tests for engine.go's front door: `newInstantQuery`/`newRangeQuery` up to
// but not including execution.
//
// The observable is either Go's error text or the `EvalStmt` the engine built — including
// the **preprocessed** expression's rendering, which makes this a check on the whole
// parse → validate → type-check → preprocess pipeline. See
// oracle/suites_promql_engine_newquery.go.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromModel
import PromQLParser
import PromStorage
import Testing

@testable import PromQL

struct EngineIn: Decodable, Sendable {
    var query: String
    var kind: String
    var start: String
    var end: String
    var interval: String
    var engineLookback: String
    var enableAt: Bool
    var enableNegOffset: Bool
    var enableExperimental: Bool
    var enableExtendedRange: Bool
    var enableDurationExpr: Bool
    var queryLookback: String
    var nilOpts: Bool
}

struct EngineOut: Decodable, Equatable, Sendable {
    var err: String
    var expr: String
    var start: String
    var end: String
    var interval: String
    var lookback: String
}

/// A `Queryable` that is never queried: this slice stops before execution.
private struct NopQueryable: Queryable {
    func querier(mint: Int64, maxt: Int64) throws -> any Querier {
        preconditionFailure("this slice never queries the storage")
    }
}

@Suite("engine.go's front door: NewInstantQuery and NewRangeQuery")
struct EngineNewQueryTests {

    @Test("every committed query matches Go, error text included")
    func newQueryMatchesGo() throws {
        try Fixtures.check("promql/newquery.jsonl", FixtureCase<EngineIn, EngineOut>.self) {
            input in
            let engine = Engine(
                EngineOpts(
                    maxSamples: 50_000_000,
                    timeout: GoDuration(nanoseconds: 60_000_000_000),
                    lookbackDelta: GoDuration(nanoseconds: Int64(input.engineLookback)!),
                    noStepSubqueryIntervalFn: { _ in 60_000 },
                    enableAtModifier: input.enableAt,
                    enableNegativeOffset: input.enableNegOffset,
                    parserOptions: Options(
                        enableExperimentalFunctions: input.enableExperimental,
                        experimentalDurationExpr: input.enableDurationExpr,
                        enableExtendedRangeSelectors: input.enableExtendedRange)))

            let opts: (any QueryOpts)? =
                input.nilOpts
                ? nil
                : PrometheusQueryOpts(
                    enablePerStepStats: false,
                    lookbackDelta: GoDuration(nanoseconds: Int64(input.queryLookback)!))

            let start = Timestamp.time(Int64(input.start)!)
            let end = Timestamp.time(Int64(input.end)!)

            do {
                let query: Query
                switch input.kind {
                case "instant":
                    query = try engine.newInstantQuery(NopQueryable(), opts, input.query, start)
                case "range":
                    query = try engine.newRangeQuery(
                        NopQueryable(), opts, input.query, start, end,
                        GoDuration(nanoseconds: Int64(input.interval)!))
                default:
                    fatalError("unknown kind \(input.kind)")
                }
                guard let es = query.statement as? EvalStmt else {
                    fatalError("the statement is an EvalStmt")
                }
                return EngineOut(
                    err: "",
                    expr: es.expr.description,
                    start: String(Timestamp.fromTime(es.start)),
                    end: String(Timestamp.fromTime(es.end)),
                    interval: String(es.interval.nanoseconds),
                    lookback: String(es.lookbackDelta.nanoseconds))
            } catch {
                // Go returns the error and nothing else, so the statement fields stay at
                // their zero values.
                return EngineOut(
                    err: String(describing: error), expr: "", start: "", end: "",
                    interval: "", lookback: "")
            }
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("engine front-door invariants")
struct EngineNewQueryInvariantTests {

    private func engine(at: Bool = true, negOffset: Bool = true, lookback: Int64 = 300_000_000_000)
        -> Engine
    {
        Engine(
            EngineOpts(
                lookbackDelta: GoDuration(nanoseconds: lookback),
                noStepSubqueryIntervalFn: { _ in 60_000 },
                enableAtModifier: at,
                enableNegativeOffset: negOffset,
                parserOptions: Options(
                    enableExperimentalFunctions: true, experimentalDurationExpr: true,
                    enableExtendedRangeSelectors: true)))
    }

    @Test("a negative per-query lookback asks for the default, not for a negative window")
    func lookbackDefaultingIsLessThanOrEqual() throws {
        // `newQuery`'s test is `<= 0`, so -1ns and 0 both fall back to the engine's.
        for ns in [Int64(0), -1, -60_000_000_000] {
            let q = try engine().newInstantQuery(
                NopQueryable(),
                PrometheusQueryOpts(
                    enablePerStepStats: false, lookbackDelta: GoDuration(nanoseconds: ns)),
                "foo", Timestamp.time(0))
            let es = q.statement as! EvalStmt
            #expect(es.lookbackDelta.nanoseconds == 300_000_000_000)
        }
        // A positive one wins.
        let q = try engine().newInstantQuery(
            NopQueryable(),
            PrometheusQueryOpts(
                enablePerStepStats: false, lookbackDelta: GoDuration(nanoseconds: 1)),
            "foo", Timestamp.time(0))
        #expect((q.statement as! EvalStmt).lookbackDelta.nanoseconds == 1)
    }

    @Test("only the range form type-checks, so one query can be legal and illegal at once")
    func rangeQueryTypeCheck() throws {
        let eng = engine()
        // A range vector is a fine instant query and never a range query.
        _ = try eng.newInstantQuery(NopQueryable(), nil, "foo[5m]", Timestamp.time(0))
        #expect(throws: QueryValidationError.self) {
            _ = try eng.newRangeQuery(
                NopQueryable(), nil, "foo[5m]", Timestamp.time(0), Timestamp.time(1000),
                GoDuration(nanoseconds: 1_000_000_000))
        }
        // And the message names the DOCUMENTED type, quoted.
        #expect(
            QueryValidationError.invalidRangeQueryType(.matrix).description
                == "invalid expression type \"range vector\" for range query, must be Scalar or instant Vector"
        )
        #expect(
            QueryValidationError.invalidRangeQueryType(.string).description
                == "invalid expression type \"string\" for range query, must be Scalar or instant Vector"
        )
    }

    @Test("a parse error beats a validation error, because parsing happens first")
    func parseBeatsValidation() throws {
        let eng = engine(at: false, negOffset: false)
        // `foo @ 100 +` is both malformed and uses a disabled feature. Go parses first, so
        // the parse error is what comes back — swapping the two would change the message.
        do {
            _ = try eng.newInstantQuery(NopQueryable(), nil, "foo @ 100 +", Timestamp.time(0))
            Issue.record("expected an error")
        } catch let e as QueryValidationError {
            Issue.record("got the validation error \(e), not the parse error")
        } catch {
            // A parse error, which is what upstream returns.
        }
    }

    @Test("with both features off, traversal order decides which error is reported")
    func traversalOrderDecidesTheError() throws {
        let eng = engine(at: false, negOffset: false)
        // The same two violations, in the two possible orders. Whichever node the walk
        // meets first names the error — so this is a property of the expression, not of the
        // engine's flags.
        var first: QueryValidationError?
        var second: QueryValidationError?
        do {
            _ = try eng.newInstantQuery(
                NopQueryable(), nil, "foo @ 100 + bar offset -5m", Timestamp.time(0))
        } catch let e as QueryValidationError {
            first = e
        }
        do {
            _ = try eng.newInstantQuery(
                NopQueryable(), nil, "foo offset -5m + bar @ 100", Timestamp.time(0))
        } catch let e as QueryValidationError {
            second = e
        }
        #expect(first == .atModifierDisabled)
        #expect(second == .negativeOffsetDisabled)
    }

    @Test("validateOpts returns early only when BOTH features are enabled")
    func earlyReturnNeedsBoth() throws {
        // With `@` enabled and negative offsets disabled, an `@` query still walks the AST
        // — and passes. A port whose early return tested `||` would accept the negative
        // offset below.
        let eng = engine(at: true, negOffset: false)
        _ = try eng.newInstantQuery(NopQueryable(), nil, "foo @ 100", Timestamp.time(0))
        #expect(throws: QueryValidationError.self) {
            _ = try eng.newInstantQuery(NopQueryable(), nil, "foo offset -5m", Timestamp.time(0))
        }
    }
}
