//===----------------------------------------------------------------------===//
// Tests for `matrixIterSlice`'s window boundaries, which the differential corpus provably
// cannot reach.
//
// `getTimeRangesForSelector` gives a matrix selector `start = ts - range + 1` and `end = ts`
// (quirk 68), and both `MemQuerier` and a real `tsdb.DB` **trim** to the hints — so by the time
// `matrixIterSlice` runs, no sample at exactly `mint` and none past `maxt` has survived. The
// negative controls for `t > mintFloats` and for the sought sample's `t == maxt` therefore
// survive every query-level case, and they survive for a *reason* rather than a gap: the
// querier already did the work.
//
// Both tests are defensive in upstream too — Go's own comment on the buffer loop is "Values in
// the buffer are guaranteed to be smaller than maxt". Guaranteed by the caller, that is. So the
// right level to pin them at is the function, not the query, and that is what these do:
// `matrixIterSlice` is driven directly over a `StorageSeries` whose points straddle both ends.
//
// `matrixIterSlice` is unexported in Go, so there is no oracle subcommand to compare against;
// these are transcription assertions, and the file says so rather than implying otherwise.
//===----------------------------------------------------------------------===//

import GoCompat
import PromChunkEnc
import PromHistogram
import PromLabels
import PromModel
import PromQLParser
import PromStorage
import PromTestStorage
import Testing

@testable import PromQL

@Suite("matrixIterSlice: the window boundaries the querier hides")
struct MatrixIterSliceTests {

    private func evaluator(maxSamples: Int = 1_000_000) -> Evaluator {
        Evaluator(
            startTimestamp: 0, endTimestamp: 0, interval: 1, maxSamples: maxSamples,
            lookbackDelta: GoDuration(nanoseconds: 300_000_000_000),
            noStepSubqueryIntervalFn: nil, enableDelayedNameRemoval: false,
            enableTypeAndUnitLabels: false, useStartTimestamps: false)
    }

    /// A buffered iterator over the given float points, as `matrixSelector` builds one.
    private func buffer(_ points: [(Int64, Double)], delta: Int64) -> BufferedSeriesIterator {
        var series = PromQL.Series(metric: Labels.empty)
        series.floats = points.map { FPoint(t: $0.0, f: $0.1) }
        let it = newBuffer(delta: delta)
        it.reset(StorageSeries(series).iterator(nil))
        return it
    }

    private func slice(
        _ points: [(Int64, Double)], mint: Int64, maxt: Int64, delta: Int64? = nil,
        maxSamples: Int = 1_000_000
    ) throws -> (floats: [FPoint], samples: Int) {
        let ev = evaluator(maxSamples: maxSamples)
        let it = buffer(points, delta: delta ?? (maxt - mint))
        var floats: [FPoint]? = nil
        var histograms: [HPoint]? = nil
        var sts: StartTimestamps? = nil
        try ev.matrixIterSlice(it, mint, maxt, &floats, &histograms, &sts)
        return (floats ?? [], ev.currentSamples)
    }

    @Test("the window is half-open at mint and closed at maxt")
    func windowBounds() throws {
        // Points on both boundaries and in the middle. `mint` is excluded, `maxt` is included:
        // the buffer loop appends only `t > mintFloats`, and the sought sample is taken only
        // when `t == maxt`.
        let got = try slice(
            [(0, 1), (30_000, 2), (60_000, 3)], mint: 0, maxt: 60_000)
        #expect(got.floats.map(\.t) == [30_000, 60_000])
        #expect(got.samples == 2)
    }

    @Test("a sample past maxt is not taken, even though the seek lands on it")
    func soughtSampleMustBeExactlyOnMaxt() throws {
        // `it.seek(maxt)` positions on the first sample at or after maxt. When that sample is
        // *after* maxt the tail must reject it — the `t == maxt` test rather than `t >= maxt`.
        // No query can reach this: the querier's `end` is maxt, so it has already been trimmed.
        let got = try slice(
            [(30_000, 2), (90_000, 9)], mint: 0, maxt: 60_000)
        #expect(got.floats.map(\.t) == [30_000])
    }

    @Test("an empty range returns whatever retention left, without reading the iterator")
    func emptyRangeReturnsEarly() throws {
        // `mint == maxt` returns before the seek. With no retained points that is empty, and
        // the sample at exactly that timestamp is NOT taken — which is what separates the early
        // return from falling through to the sought-sample tail.
        let got = try slice([(60_000, 3)], mint: 60_000, maxt: 60_000, delta: 60_000)
        #expect(got.floats.isEmpty)
    }

    @Test("retention keeps the overlap, drops what is at or before the new mint, and re-counts")
    func retentionAcrossSteps() throws {
        // The parameter that gives the function its name, and which `matrixSelector` never uses
        // — it always passes nil. The `Call` arm is what drives this across steps; pinning it
        // here means the next slice inherits a tested retention path rather than a fresh one.
        let ev = evaluator()
        let points: [(Int64, Double)] = [
            (10_000, 1), (20_000, 2), (30_000, 3), (40_000, 4), (50_000, 5), (60_000, 6),
        ]
        var floats: [FPoint]? = nil
        var histograms: [HPoint]? = nil
        var sts: StartTimestamps? = nil

        // Step 0: the window (0, 30000].
        let it0 = buffer(points, delta: 30_000)
        try ev.matrixIterSlice(it0, 0, 30_000, &floats, &histograms, &sts)
        #expect(floats?.map(\.t) == [10_000, 20_000, 30_000])
        #expect(ev.currentSamples == 3)

        // Step 1: the window (20000, 50000] OVERLAPS, so 10000 and 20000 are dropped, 30000 is
        // retained, and only points after 30000 are appended. `currentSamples` goes 3 - 2 + 2.
        let it1 = buffer(points, delta: 30_000)
        try ev.matrixIterSlice(it1, 20_000, 50_000, &floats, &histograms, &sts)
        #expect(floats?.map(\.t) == [30_000, 40_000, 50_000])
        #expect(ev.currentSamples == 3)

        // Step 2: the window (55000, 60000] does NOT overlap — the last retained point is
        // 50000, which is not > 55000 — so the slice is truncated to empty first and the whole
        // length is subtracted.
        let it2 = buffer(points, delta: 5_000)
        try ev.matrixIterSlice(it2, 55_000, 60_000, &floats, &histograms, &sts)
        #expect(floats?.map(\.t) == [60_000])
        #expect(ev.currentSamples == 1)

        // Step 3: the new mint is EXACTLY the last retained timestamp. The overlap test is
        // strict (`> mint`), so this is the no-overlap branch. Spelling it `>= mint` takes the
        // overlap branch instead, which then drops every point and reads
        // `floats[floats.count - 1]` on an empty slice — a trap, and in Go a panic. So the
        // strictness is not cosmetic, and this is the case that says so.
        let it3 = buffer(points, delta: 10_000)
        try ev.matrixIterSlice(it3, 60_000, 70_000, &floats, &histograms, &sts)
        #expect(floats?.isEmpty == true)
        #expect(ev.currentSamples == 0)
    }

    @Test("startTimestamps are truncated at the same drop point as the floats")
    func startTimestampsStayAligned() throws {
        // Upstream's contract in as many words: "the caller must always pass in startTimestamps
        // with fields whose lengths exactly match those of the floats and histograms slices".
        // The retention has to hold that up, which means dropping the same prefix.
        let ev = evaluator()
        var series = PromQL.Series(metric: Labels.empty)
        series.floats = [(10_000, 1.0), (20_000, 2.0), (30_000, 3.0), (40_000, 4.0)].map {
            FPoint(t: $0.0, f: $0.1)
        }

        var floats: [FPoint]? = nil
        var histograms: [HPoint]? = nil
        var sts: StartTimestamps? = StartTimestamps()

        let it0 = newBuffer(delta: 30_000)
        it0.reset(StorageSeries(series).iterator(nil))
        try ev.matrixIterSlice(it0, 0, 30_000, &floats, &histograms, &sts)
        #expect(sts?.floats.count == floats?.count)

        let it1 = newBuffer(delta: 30_000)
        it1.reset(StorageSeries(series).iterator(nil))
        try ev.matrixIterSlice(it1, 20_000, 40_000, &floats, &histograms, &sts)
        #expect(floats?.map(\.t) == [30_000, 40_000])
        #expect(sts?.floats.count == floats?.count)
    }

    @Test("a stale histogram leaves the slice non-nil and empty, which anchored rejects")
    func staleHistogramLeavesTheSliceAllocated() throws {
        // `matrixSelector`'s guard is `ss.Histograms != nil`, not a length test, and
        // `matrixIterSlice` allocates the histogram slice BEFORE it knows the sample is a stale
        // marker. So a series whose only in-range histogram is stale comes back non-nil and
        // EMPTY, and `anchored` rejects it for containing histograms it does not contain.
        //
        // No differential case can reach this: the `promql/exec` corpus is float-only because a
        // histogram through a real `tsdb.DB` re-derives `CounterResetHint`, which is Phases 6-7's
        // subject (HANDOFF §5). Pinned here instead, and pinned at the function so the nil is
        // directly observable rather than inferred from the error.
        let ev = evaluator()
        var stale = FloatHistogram(schema: 0, count: 3, sum: PromValue.staleNaN)
        stale.positiveSpans = [Span(offset: 0, length: 1)]
        stale.positiveBuckets = [3]

        var series = PromQL.Series(metric: Labels.empty)
        series.histograms = [HPoint(t: 30_000, h: stale)]
        let it = newBuffer(delta: 60_000)
        it.reset(StorageSeries(series).iterator(nil))

        var floats: [FPoint]? = nil
        var histograms: [HPoint]? = nil
        var sts: StartTimestamps? = nil
        try ev.matrixIterSlice(it, 0, 60_000, &floats, &histograms, &sts)

        #expect(floats == nil, "no float ever appeared, so that slice stays nil")
        #expect(histograms != nil, "allocated before the staleness test — the load-bearing part")
        #expect(histograms?.isEmpty == true)
        // And the stale point never counted.
        #expect(ev.currentSamples == 0)

        // Through a query, which is where the non-nil-empty slice becomes an ERROR: the guard in
        // `matrixSelector` is `ss.Histograms != nil`, so `anchored` rejects a series whose only
        // histogram was a stale marker.
        let store = MemStorage()
        try store.load(
            Labels(strings: ["__name__", "sh"]), [FHSample(st: 0, t: 30_000, fh: stale)])
        let engine = Engine(
            EngineOpts(
                maxSamples: 1_000_000, timeout: GoDuration(nanoseconds: 60_000_000_000),
                lookbackDelta: GoDuration(nanoseconds: 300_000_000_000),
                noStepSubqueryIntervalFn: { _ in 60_000 },
                enableAtModifier: true, enableNegativeOffset: true,
                parserOptions: Options(
                    enableExperimentalFunctions: true, enableExtendedRangeSelectors: true)))
        let q = try engine.newInstantQuery(store, nil, "sh[5m] anchored", Timestamp.time(60_000))
        let res = q.exec(GoContext.background())
        #expect(
            res.error.map { String(describing: $0) }
                == "anchored modifier is not supported with histograms")
    }

    @Test("a histogram's counter reset hint survives the storage and the buffer")
    func counterResetHintCarriage() throws {
        // The hypothesis HANDOFF §5e records for the exit gate's two remaining warning failures:
        // the collision warning needs one sample hinted `notCounterReset` and the next
        // `counterReset`, and the hints may be lost between `MemStorage.load` and
        // `matrixIterSlice`. The `storage/mem-select` corpus is float-only on purpose, so histogram
        // HINT carriage has never been pinned anywhere — this is the drop-a-level test for it.
        func h(_ hint: CounterResetHint, _ count: Double) -> FloatHistogram {
            FloatHistogram(
                counterResetHint: hint, schema: 0, count: count, sum: count,
                positiveSpans: [Span(offset: 0, length: 1)], positiveBuckets: [count])
        }
        let store = MemStorage()
        try store.load(
            Labels(strings: ["__name__", "mixed"]),
            [
                FHSample(st: 0, t: 0, fh: h(.notCounterReset, 1)),
                FHSample(st: 0, t: 60_000, fh: h(.counterReset, 2)),
            ])

        let ev = evaluator()
        let querier = try store.querier(mint: 0, maxt: 60_000)
        let set = querier.select(
            GoContext.background(), sortSeries: true, hints: SelectHints(start: 0, end: 60_000),
            matchers: [try Matcher(.equal, "__name__", "mixed")])
        var series: [any PromStorage.Series] = []
        while set.next() { series.append(try #require(set.at())) }
        #expect(series.count == 1)

        let it = newBuffer(delta: 60_000)
        it.reset(series[0].iterator(nil))
        var floats: [FPoint]? = nil
        var hists: [HPoint]? = nil
        var sts: StartTimestamps? = nil
        try ev.matrixIterSlice(it, -1, 60_000, &floats, &hists, &sts)

        #expect(hists?.count == 2)
        #expect(
            hists?.map(\.h.counterResetHint) == [.notCounterReset, .counterReset],
            "the hints must survive: the collision warning is the only thing that reads them")

        // They DO survive, which **refutes** the hypothesis HANDOFF §5e recorded — so the loss is
        // in the one remaining link, `parseSeriesDesc`'s handling of `counter_reset_hint:`. And
        // Phase 4's 1,685-case series-description corpus cannot see it: that fixture compares
        // `String()`, and `FloatHistogram.String()` does not print the hint. Exactly the trap
        // HANDOFF §3 records for `promql/histogram-stats`, in a corpus that predates the lesson.
        let parsed = try Parser(options: Options()).parseSeriesDesc(
            "mixed {{schema:0 count:1 sum:1 counter_reset_hint:reset buckets:[1]}}")
        #expect(
            parsed.values.first?.histogram?.counterResetHint == .counterReset,
            "parseSeriesDesc must carry counter_reset_hint — String() cannot see it, so no fixture does")
    }

    @Test("the sample limit is enforced per point, as the points are appended")
    func sampleLimitPerPoint() throws {
        // `currentSamples += 1` then `> maxSamples`, before the append — so a limit of exactly
        // the point count fits and one less does not.
        let points: [(Int64, Double)] = [(10_000, 1), (20_000, 2), (30_000, 3)]
        #expect(throws: QueryError.self) {
            _ = try slice(points, mint: 0, maxt: 30_000, maxSamples: 2)
        }
        let ok = try slice(points, mint: 0, maxt: 30_000, maxSamples: 3)
        #expect(ok.floats.count == 3)
    }
}
