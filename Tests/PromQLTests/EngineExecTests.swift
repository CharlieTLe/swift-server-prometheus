//===----------------------------------------------------------------------===//
// Differential tests for the ported half of query EXECUTION: `Exec` → `exec` →
// `execEvalStmt`'s instant branch → `Evaluator.eval` → `rangeEval`.
//
// The corpus is restricted to expressions that never touch the storage, which is exactly
// what this slice implements; everything else throws `EvaluatorNotPorted` by name. See
// oracle/suites_promql_engine_exec.go.
//
// The `stmt` field is the statement's rendering AFTER `Exec`, which is how
// `setOffsetForAtModifier`'s in-place AST rewrite is observed — and how the missing
// `"EVAL "` prefix on `EvalStmt.description` was found.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromChunks
import PromLabels
import PromModel
import PromQLParser
import PromStorage
import PromTestStorage
import Testing

@testable import PromQL

/// The same wire shape as `PromTestStorageTests`' loader, declared here because the two test
/// targets cannot share a type.
struct ExecSeriesIn: Decodable, Sendable {
    var labels: [String]
    var t: [String]
    var st: [String]
    /// Hex bit patterns.
    var f: [String]
}

struct ExecIn: Decodable, Sendable {
    var query: String
    var ts: String
    var lookback: String
    var maxSamples: Int
    var series: [ExecSeriesIn]
}

struct ExecOut: Decodable, Equatable, Sendable {
    var valueType: String
    var value: String
    var err: String
    var warnings: [String]
    var stmt: String
}

/// A queryable whose querier knows nothing — all the ported arms need, since none reads it.
private struct EmptyQueryable: Queryable {
    func querier(mint: Int64, maxt: Int64) throws -> any Querier {
        NoopQuerier()
    }
}

@Suite("promql execution: instant queries that need no storage")
struct EngineExecTests {

    @Test("every committed query matches Go — value, error, warnings and statement")
    func execMatchesGo() throws {
        try Fixtures.check("promql/exec.jsonl", FixtureCase<ExecIn, ExecOut>.self) { input in
            let engine = Engine(
                EngineOpts(
                    maxSamples: input.maxSamples,
                    timeout: GoDuration(nanoseconds: 60_000_000_000),
                    lookbackDelta: GoDuration(nanoseconds: Int64(input.lookback)!),
                    noStepSubqueryIntervalFn: { _ in 60_000 },
                    enableAtModifier: true,
                    enableNegativeOffset: true,
                    parserOptions: Options(enableExperimentalFunctions: true)))

            let ts = Timestamp.time(Int64(input.ts)!)
            // A loaded in-memory storage when the case has series, and a querier that knows
            // nothing when it does not.
            let queryable: any Queryable
            if input.series.isEmpty {
                queryable = EmptyQueryable()
            } else {
                let store = MemStorage()
                for s in input.series {
                    var samples = [any PromChunks.Sample]()
                    for i in s.t.indices {
                        samples.append(
                            FSample(
                                st: Int64(s.st[i])!, t: Int64(s.t[i])!,
                                f: Double(bitPattern: UInt64(s.f[i], radix: 16)!)))
                    }
                    try store.load(Labels(strings: s.labels), samples)
                }
                queryable = store
            }
            let query: Query
            do {
                query = try engine.newInstantQuery(queryable, nil, input.query, ts)
            } catch {
                // Go returns the build error before Exec is ever called.
                return ExecOut(
                    valueType: "", value: "", err: String(describing: error), warnings: [],
                    stmt: "")
            }

            let res = query.exec(GoContext.background())
            var out = ExecOut(valueType: "", value: "", err: "", warnings: [], stmt: "")
            if let err = res.error {
                out.err = String(describing: err)
            }
            if let value = res.value {
                out.valueType = value.type.rawValue
                out.value = value.description
            }
            let (warnings, infos) = res.warnings.asStrings(
                query: input.query, maxWarnings: 0, maxInfos: 0)
            out.warnings = (warnings + infos).sorted()
            // After Exec: execEvalStmt rewrote the AST in place.
            out.stmt = query.statement.description
            return out
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("execution invariants")
struct EngineExecInvariantTests {

    private func engine(maxSamples: Int = 50_000_000) -> Engine {
        Engine(
            EngineOpts(
                maxSamples: maxSamples,
                timeout: GoDuration(nanoseconds: 60_000_000_000),
                lookbackDelta: GoDuration(nanoseconds: 300_000_000_000),
                noStepSubqueryIntervalFn: { _ in 60_000 },
                enableAtModifier: true, enableNegativeOffset: true,
                parserOptions: Options(enableExperimentalFunctions: true)))
    }

    private func run(_ query: String, maxSamples: Int = 50_000_000, at ms: Int64 = 0) throws
        -> Result
    {
        let q = try engine(maxSamples: maxSamples).newInstantQuery(
            EmptyQueryable(), nil, query, Timestamp.time(ms))
        return q.exec(GoContext.background())
    }

    @Test("an unported expression names itself rather than answering wrongly")
    func unportedArmsAreLoud() throws {
        // A selector, an aggregation and a range are all out of scope for this slice. What
        // matters is that each says so — a silent zero would be far worse than an error.
        // A bare selector now WORKS — that is this slice. What still throws is everything
        // the selector unlocks but that has not landed: aggregations, ranges, vector binops.
        for query in ["sum(foo)", "rate(foo[5m])", "foo + bar", "1 + foo", "foo unless bar"] {
            let res = try run(query)
            guard let err = res.error as? EvaluatorNotPorted else {
                Issue.record("\(query) did not report EvaluatorNotPorted: \(String(describing: res.error))")
                continue
            }
            #expect(!err.nodeType.isEmpty)
        }
    }

    @Test("a scalar comparison is arithmetic, not a filter")
    func scalarComparisonsReturnOneOrZero() throws {
        // The reason `1 > 2` is 0 rather than "no data": scalarBinop's comparisons go through
        // btos. A port that filtered would return an empty result and look plausible.
        #expect(try run("1 > bool 2").scalar().v == 0)
        #expect(try run("2 > bool 1").scalar().v == 1)
        #expect(try run("NaN == bool NaN").scalar().v == 0)
    }

    @Test("the sample limit is checked after the call, and 1 sample fits in a limit of 1")
    func sampleLimitBoundary() throws {
        // `currentSamples > maxSamples`, so a one-sample result passes a limit of exactly 1
        // and fails a limit of 0. `1 + 2` needs FIVE, because gatherVector counts the two
        // operands as it copies them in — the limit is enforced on the inputs as well as on
        // the result.
        #expect(try run("1", maxSamples: 1).scalar().v == 1)
        #expect(try run("1 + 2", maxSamples: 4).error != nil)
        #expect(try run("1 + 2", maxSamples: 5).scalar().v == 3)
        let rejected = try run("1", maxSamples: 0)
        #expect(rejected.error != nil)
        #expect(
            String(describing: rejected.error!)
                == "query processing would load too many samples into memory in query execution")
    }

    @Test("a string result skips the matrix conversion entirely")
    func stringResultsBypassTheTails() throws {
        // StringLiteral is the only arm that does not return a Matrix, and execEvalStmt
        // returns it before the type switch.
        let res = try run("\"hello\"", at: 1234)
        #expect(res.error == nil)
        #expect(res.value?.type == .string)
        // `String.String()` is the value alone — no `@[ts]`, unlike Scalar's rendering.
        #expect(res.value?.description == "hello")
    }

    @Test("EvalStmt renders with Go's EVAL prefix")
    func evalStmtPrefix() throws {
        // printer.go:52. Nothing else in the corpora printed an EvalStmt, because nothing
        // else built one — so this was wrong until the exec fixture compared it.
        let q = try engine().newInstantQuery(
            EmptyQueryable(), nil, "1 + 2", Timestamp.time(0))
        #expect(q.statement.description == "EVAL 1 + 2")
        #expect(q.statement.pretty(0) == "EVAL 1 + 2")
    }
}
