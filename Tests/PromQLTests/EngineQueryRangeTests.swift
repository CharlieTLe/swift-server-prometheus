//===----------------------------------------------------------------------===//
// Differential tests for engine.go's query-planning arithmetic and `limit_ratio`'s
// sampler — the first two pieces of `promql/engine.go` in the port.
//
// Both are pinned by calling them directly: `FindMinMaxTime` takes a `parser.EvalStmt`, so
// each case is a query string plus the four statement fields, and both sides parse the
// same bytes. See oracle/suites_promql_engine_range.go.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromLabels
import PromModel
import PromQLParser
import Testing

@testable import PromQL

struct PlanIn: Decodable, Sendable {
    var expr: String
    /// Milliseconds since the epoch.
    var start: String
    var end: String
    /// Nanoseconds.
    var interval: String
    var lookback: String
}

struct PlanOut: Decodable, Equatable, Sendable {
    var min: String
    var max: String
}

struct RatioIn: Decodable, Sendable {
    var metric: [String]
    var ratioLimit: String
    var sampleOffset: String
    var kind: String
}

struct RatioOut: Decodable, Equatable, Sendable {
    var offset: String
    var added: Bool
}

@Suite("engine.go's query planner: FindMinMaxTime")
struct FindMinMaxTimeTests {

    @Test("every committed statement matches Go")
    func minMaxMatchesGo() throws {
        try Fixtures.check("promql/minmaxtime.jsonl", FixtureCase<PlanIn, PlanOut>.self) { input in
            // The same two options the oracle parses with: `anchored`/`smoothed` need the
            // extended range selectors, and the experimental functions widen which names
            // resolve.
            let parser = Parser(
                options: Options(
                    enableExperimentalFunctions: true,
                    enableExtendedRangeSelectors: true))
            let expr = try parser.parseExpr(input.expr)
            let stmt = EvalStmt(
                expr: expr,
                start: Timestamp.time(Int64(input.start)!),
                end: Timestamp.time(Int64(input.end)!),
                interval: GoDuration(nanoseconds: Int64(input.interval)!),
                lookbackDelta: GoDuration(nanoseconds: Int64(input.lookback)!))
            let (minT, maxT) = findMinMaxTime(stmt)
            return PlanOut(min: String(minT), max: String(maxT))
        }
    }
}

@Suite("engine.go's HashRatioSampler, which limit_ratio's determinism rests on")
struct RatioSamplerTests {

    @Test("every committed case matches Go")
    func ratioMatchesGo() throws {
        try Fixtures.check("promql/ratiosampler.jsonl", FixtureCase<RatioIn, RatioOut>.self) {
            input in
            let sampler = HashRatioSampler()
            switch input.kind {
            case "offset":
                let m = Labels(strings: input.metric)
                return RatioOut(offset: Self.hex(sampler.sampleOffset(m)), added: false)
            case "sample":
                let m = Labels(strings: input.metric)
                let sample = Sample(f: 1, metric: m)
                let limit = Double(bitPattern: UInt64(input.ratioLimit, radix: 16)!)
                return RatioOut(
                    offset: Self.hex(sampler.sampleOffset(m)),
                    added: sampler.addRatioSample(limit, sample))
            case "withOffset":
                let limit = Double(bitPattern: UInt64(input.ratioLimit, radix: 16)!)
                let offset = Double(bitPattern: UInt64(input.sampleOffset, radix: 16)!)
                return RatioOut(
                    offset: "", added: sampler.addRatioSampleWithOffset(limit, offset))
            default:
                fatalError("unknown kind \(input.kind)")
            }
        }
    }

    /// The corpus' float encoding: the 16-digit hex bit pattern.
    static func hex(_ v: Double) -> String {
        String(format: "%016lx", v.bitPattern)
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("query-planning invariants")
struct QueryPlanInvariantTests {

    private func stmt(_ query: String, lookback: Int64 = 5 * 60_000_000_000) throws -> EvalStmt {
        let parser = Parser(
            options: Options(
                enableExperimentalFunctions: true, enableExtendedRangeSelectors: true))
        return EvalStmt(
            expr: try parser.parseExpr(query),
            start: Timestamp.time(1_000_000),
            end: Timestamp.time(1_000_000),
            lookbackDelta: GoDuration(nanoseconds: lookback))
    }

    @Test("no selector means (0, 0), not the sentinels")
    func noSelector() throws {
        // `FindMinMaxTime` seeds min with MaxInt64 and max with MinInt64 and only resets
        // them when max is untouched. A port that returned the sentinels would ask the
        // storage for everything.
        let (minT, maxT) = findMinMaxTime(try stmt("1 + 2"))
        #expect(minT == 0)
        #expect(maxT == 0)
    }

    @Test("the lookback window is half-open, so the start is lookbackDelta - 1 back")
    func halfOpenLookback() throws {
        let (minT, maxT) = findMinMaxTime(try stmt("foo"))
        // 5m = 300_000ms, and the start moves back 299_999.
        #expect(minT == 1_000_000 - 299_999)
        #expect(maxT == 1_000_000)
    }

    @Test("only `smoothed` reaches forward in time")
    func smoothedExtendsTheEnd() throws {
        let plain = findMinMaxTime(try stmt("rate(foo[10m])"))
        let anchored = findMinMaxTime(try stmt("rate(foo[10m] anchored)"))
        let smoothed = findMinMaxTime(try stmt("rate(foo[10m] smoothed)"))

        // The end: plain and anchored stop at the evaluation time; smoothed goes a full
        // lookbackDelta past it, which is what lets extendedRate interpolate to a right
        // boundary sitting after the last in-range sample.
        #expect(plain.1 == 1_000_000)
        #expect(anchored.1 == 1_000_000)
        #expect(smoothed.1 == 1_000_000 + 300_000)

        // The start: plain gets the range, the two modifiers get the range PLUS the
        // lookback delta.
        #expect(plain.0 == 1_000_000 - (600_000 - 1))
        #expect(anchored.0 == 1_000_000 - (900_000 - 1))
        #expect(smoothed.0 == anchored.0)
    }

    @Test("an @ modifier pins the window, and an offset still moves it")
    func atModifierThenOffset() throws {
        let pinned = findMinMaxTime(try stmt("foo @ 100"))
        // 100 seconds, and the lookback still applies.
        #expect(pinned.0 == 100_000 - 299_999)
        #expect(pinned.1 == 100_000)

        // The selector's own offset is subtracted last and unconditionally, so it shifts
        // the pinned timestamp rather than being ignored.
        let shifted = findMinMaxTime(try stmt("foo @ 100 offset 5m"))
        #expect(shifted.0 == pinned.0 - 300_000)
        #expect(shifted.1 == pinned.1 - 300_000)
    }

    @Test("a subquery's @ resets the accumulated offsets rather than adding to them")
    func subqueryAtResetsAccumulation() throws {
        // The inner `offset 3m` is discarded by the outer `@ 100`, because the timestamp
        // makes everything inside absolute. Compare with the same query minus the `@`.
        let withAt = findMinMaxTime(
            try stmt("max_over_time(max_over_time(foo[5m:1m] offset 3m)[1h:10m] @ 100)"))
        let withoutAt = findMinMaxTime(
            try stmt("max_over_time(max_over_time(foo[5m:1m] offset 3m)[1h:10m])"))
        // Same width, different position: the reset drops the 3m, and the `@` moves the
        // window to t=100s.
        #expect(withAt.1 - withAt.0 == withoutAt.1 - withoutAt.0)
        #expect(withAt.1 != withoutAt.1)
    }

    @Test("a negative ratio limit selects exactly what the positive complement drops")
    func negativeRatioIsTheComplement() {
        let sampler = HashRatioSampler()
        for offset in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 0.9999] {
            // `limit_ratio(0.9, …)` keeps offset < 0.9; `limit_ratio(-0.1, …)` keeps
            // offset >= 0.9. Exactly one of them takes any given series.
            #expect(
                sampler.addRatioSampleWithOffset(0.9, offset)
                    != sampler.addRatioSampleWithOffset(-0.1, offset))
        }
    }

    @Test("a NaN ratio limit adds nothing, because both halves are false")
    func nanRatioLimit() {
        let sampler = HashRatioSampler()
        #expect(!sampler.addRatioSampleWithOffset(.nan, 0.5))
        #expect(!sampler.addRatioSampleWithOffset(0.5, .nan))
    }
}
