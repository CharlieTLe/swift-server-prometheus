//===----------------------------------------------------------------------===//
// Differential tests for RANGE query evaluation: `Exec` → `exec` → `execEvalStmt`'s range
// branch → `Evaluator.eval` → `rangeEval`'s multi-step assembly, `addToSeries`, and
// `StepInvariantExpr`'s step duplication.
//
// See oracle/suites_promql_engine_rangequery.go for what the corpus reaches and why it is a
// separate file from `promql/exec` — a range query's input is start/end/step where an instant
// query's is a single `ts`, and one fixture file holds one in/out shape.
//
// The single most useful case in the file is `http_requests @ 60` over three steps: the
// answer is step 0's sample repeated with three different timestamps. Without the
// step-invariant wrapper, `setOffsetForAtModifier`'s rewritten offset makes each step read a
// *different* sample and the values ascend — so the case separates the duplication path from
// the ordinary step loop, which nothing in the instant corpus can do.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromChunks
import PromHistogram
import PromLabels
import PromModel
import PromQLParser
import PromStorage
import PromTestStorage
import Testing

@testable import PromQL

struct ExecRangeIn: Decodable, Sendable {
    var query: String
    var start: String
    var end: String
    /// Nanoseconds.
    var step: String
    /// Nanoseconds.
    var lookback: String
    var maxSamples: Int
    var series: [ExecSeriesIn]
}

struct ExecRangeOut: Decodable, Equatable, Sendable {
    var valueType: String
    var value: String
    var err: String
    var warnings: [String]
    var stmt: String
}

/// A queryable whose querier knows nothing, for the storage-free half of the corpus.
private struct RangeEmptyQueryable: Queryable {
    func querier(mint: Int64, maxt: Int64) throws -> any Querier {
        NoopQuerier()
    }
}

@Suite("promql execution: range queries")
struct EngineExecRangeTests {

    @Test("every committed range query matches Go — value, error, warnings and statement")
    func execRangeMatchesGo() throws {
        try Fixtures.check("promql/exec-range.jsonl", FixtureCase<ExecRangeIn, ExecRangeOut>.self) {
            input in
            let engine = Engine(
                EngineOpts(
                    maxSamples: input.maxSamples,
                    timeout: GoDuration(nanoseconds: 60_000_000_000),
                    lookbackDelta: GoDuration(nanoseconds: Int64(input.lookback)!),
                    noStepSubqueryIntervalFn: { _ in 60_000 },
                    enableAtModifier: true,
                    enableNegativeOffset: true,
                    parserOptions: Options(enableExperimentalFunctions: true)))

            let start = Timestamp.time(Int64(input.start)!)
            let end = Timestamp.time(Int64(input.end)!)
            let step = GoDuration(nanoseconds: Int64(input.step)!)

            let queryable: any Queryable
            if input.series.isEmpty {
                queryable = RangeEmptyQueryable()
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
                query = try engine.newRangeQuery(
                    queryable, nil, input.query, start, end, step)
            } catch {
                // Go returns the build error — a parse failure or the range-query type
                // rejection — before Exec is ever called.
                return ExecRangeOut(
                    valueType: "", value: "", err: String(describing: error), warnings: [],
                    stmt: "")
            }

            let res = query.exec(GoContext.background())
            var out = ExecRangeOut(valueType: "", value: "", err: "", warnings: [], stmt: "")
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
            out.stmt = query.statement.description
            return out
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("range-query invariants")
struct EngineExecRangeInvariantTests {

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

    private func run(
        _ query: String, from: Int64, to: Int64, stepMS: Int64 = 60_000,
        maxSamples: Int = 50_000_000
    ) throws -> Result {
        let q = try engine(maxSamples: maxSamples).newRangeQuery(
            RangeEmptyQueryable(), nil, query, Timestamp.time(from), Timestamp.time(to),
            GoDuration(nanoseconds: stepMS * 1_000_000))
        return q.exec(GoContext.background())
    }

    @Test("a range query always returns a Matrix, even for a scalar expression")
    func rangeResultIsAlwaysAMatrix() throws {
        // The instant path has three type tails and the range path has none: `1` comes back
        // as a one-series matrix with a point per step. A port that reused the instant tails
        // would answer `Scalar` here and every consumer downstream would be wrong.
        let res = try run("1", from: 0, to: 120_000)
        #expect(res.error == nil)
        #expect(res.value?.type == .matrix)
        let mat = res.value as? Matrix
        #expect(mat?.series.count == 1)
        #expect(mat?.series[0].floats.map(\.t) == [0, 60_000, 120_000])
    }

    @Test("an inverted range is an empty matrix, not an error and not one step")
    func invertedRangeIsEmpty() throws {
        // engine.go:2057, checked before the expression switch — so nothing is evaluated at
        // all. Unreachable from an instant query, where start == end by construction.
        let res = try run("time()", from: 120_000, to: 0)
        #expect(res.error == nil)
        #expect((res.value as? Matrix)?.series.isEmpty == true)
    }

    @Test("start == end with a non-zero step still takes the range branch")
    func oneStepRangeIsNotTheInstantPath() throws {
        // `execEvalStmt`'s guard is `start == end && interval == 0` — BOTH. So a range query
        // whose start equals its end is a range evaluation with one step, and its result is a
        // Matrix rather than a Scalar.
        let res = try run("1", from: 0, to: 0)
        #expect(res.value?.type == .matrix)
        #expect((res.value as? Matrix)?.series[0].floats.count == 1)
    }

    @Test("a step that does not divide the range stops before the end")
    func partialFinalStepIsDropped() throws {
        // `for ts := start; ts <= end; ts += interval` — the last step is the largest
        // multiple of the interval that is still `<= end`, so a 150s range at a 60s step has
        // three points and not four.
        let res = try run("time()", from: 0, to: 150_000)
        #expect((res.value as? Matrix)?.series[0].floats.map(\.t) == [0, 60_000, 120_000])
    }

    @Test("a histogram series lands in the histogram slice at every step")
    func histogramsAreCarriedPerStep() throws {
        // `addToSeries` chooses which slice to grow from `h == nil`, and putting a histogram
        // in the float slice survives the whole differential corpus — because the corpus is
        // float-only. It is float-only on purpose: a histogram appended to a real `tsdb.DB`
        // comes back through the chunk encoding, which re-derives `CounterResetHint`, so
        // pinning it would pin Phases 6-7's subject (HANDOFF §5). Histogram carriage is
        // therefore a Swift-side assertion, and this is it — the control that closes it.
        let store = MemStorage()
        let h = FloatHistogram(
            schema: 0, count: 10, sum: 25,
            positiveSpans: [Span(offset: 0, length: 2)], positiveBuckets: [4, 6])
        for t in [Int64(0), 60_000, 120_000] {
            try store.load(
                Labels(strings: ["__name__", "native"]), [FHSample(st: 0, t: t, fh: h)])
        }

        let q = try engine().newRangeQuery(
            store, nil, "native", Timestamp.time(0), Timestamp.time(120_000),
            GoDuration(nanoseconds: 60_000_000_000))
        let res = q.exec(GoContext.background())
        #expect(res.error == nil)
        let mat = try #require(res.value as? Matrix)
        #expect(mat.series.count == 1)
        #expect(mat.series[0].floats.isEmpty)
        #expect(mat.series[0].histograms.map(\.t) == [0, 60_000, 120_000])
        #expect(mat.series[0].histograms.allSatisfy { $0.h.count == 10 })

        // And through a Call, which is the path that goes via `rangeEval`'s assembly rather
        // than straight out of `evalSeries`. `histogram_count` reduces to a float; only
        // `sort_by_label` passes a histogram sample *through* — `sort`/`sort_desc` drop them
        // in `filterFloats` — so it is the one ported function that can put a histogram into
        // `addToSeries` at all. That is what makes it the case here rather than an odd choice.
        let counted = try engine().newRangeQuery(
            store, nil, "histogram_count(native)", Timestamp.time(0), Timestamp.time(120_000),
            GoDuration(nanoseconds: 60_000_000_000))
        let countedMat = try #require(counted.exec(GoContext.background()).value as? Matrix)
        #expect(countedMat.series[0].floats.map(\.f) == [10, 10, 10])
        #expect(countedMat.series[0].histograms.isEmpty)

        let passed = try engine().newRangeQuery(
            store, nil, "sort_by_label(native, \"job\")", Timestamp.time(0),
            Timestamp.time(120_000), GoDuration(nanoseconds: 60_000_000_000))
        let passedMat = try #require(passed.exec(GoContext.background()).value as? Matrix)
        #expect(passedMat.series[0].floats.isEmpty)
        #expect(passedMat.series[0].histograms.map(\.t) == [0, 60_000, 120_000])
    }

    @Test("the sort warning fires only when the evaluator's own timestamps differ")
    func sortWarningNeedsMoreThanOneStep() throws {
        // The condition is `startTimestamp != endTimestamp`, not "was NewRangeQuery called",
        // and `preprocessExpr` decides which evaluator sees the Call. `sort(vector(1))` is
        // step-invariant, so it is wrapped and evaluated by a CHILD evaluator whose start
        // equals its end — no warning, in a range query. `sort(vector(time()))` is not
        // step-invariant, because `time` is at-modifier-unsafe, so it keeps the outer
        // timestamps and warns.
        //
        // This expectation was written the other way round and Go said no; the corpus carries
        // both spellings for that reason.
        let quietBecauseInvariant = try run("sort(vector(1))", from: 0, to: 120_000)
        #expect(quietBecauseInvariant.warnings.count == 0)
        let warned = try run("sort(vector(time()))", from: 0, to: 120_000)
        #expect(warned.warnings.count == 1)
        let quietBecauseOneStep = try run("sort(vector(time()))", from: 0, to: 0)
        #expect(quietBecauseOneStep.warnings.count == 0)
    }
}
