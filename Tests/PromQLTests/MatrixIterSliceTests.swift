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

    @Test("the storage DERIVES a histogram's counter reset hint, and the buffer carries it")
    func counterResetHintCarriage() throws {
        // **This test's original assertion was `[.notCounterReset, .counterReset]` — that the hints
        // written by the load SURVIVE the storage — and it was right about the layer while being
        // wrong about the behaviour.** It was written to test the first hypothesis for the exit
        // gate's two warning failures (the hints are lost between `MemStorage.load` and
        // `matrixIterSlice`), it refuted that hypothesis, and the cause turned out to be one layer
        // further out: the storage is supposed to DERIVE hints, not carry them (quirk 102).
        //
        // So the assertion is now the derivation. Two samples counting up, loaded with whatever hints
        // the caller likes, come back `unknown` then `not_reset` — because that is what a chunk
        // read-back produces for the first and second sample of a counter chunk, and the written hint
        // is discarded. Keeping the test rather than deleting it is the point: it is the only thing
        // pinning the storage-to-buffer link for histograms, since `storage/mem-select` is float-only.
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
        // BOTH `unknown`, and the second one is the interesting half: the load hinted it
        // `counterReset`, `appendable` "always honours" an explicit reset hint, so it CUTS A CHUNK —
        // and the first sample of a chunk reads back `unknown` whatever the header says. Predicting
        // `[unknown, not_reset]` here was wrong twice over and the assertion caught it.
        #expect(
            hists?.map(\.h.counterResetHint) == [.unknownCounterReset, .unknownCounterReset],
            "an explicit reset hint cuts a chunk, and a chunk's first sample reads back unknown")

        // The counting-up pair, which is the shape every `.test` load has and the one the collision
        // warning depends on: no explicit hints, so one chunk, so `unknown` then `not_reset`.
        let store2 = MemStorage()
        try store2.load(
            Labels(strings: ["__name__", "rising"]),
            [
                FHSample(st: 0, t: 0, fh: h(.unknownCounterReset, 1)),
                FHSample(st: 0, t: 60_000, fh: h(.unknownCounterReset, 2)),
                FHSample(st: 0, t: 120_000, fh: h(.unknownCounterReset, 3)),
            ])
        let q2 = try store2.querier(mint: 0, maxt: 120_000)
        let set2 = q2.select(
            GoContext.background(), sortSeries: true, hints: SelectHints(start: 0, end: 120_000),
            matchers: [try Matcher(.equal, "__name__", "rising")])
        var series2: [any PromStorage.Series] = []
        while set2.next() { series2.append(try #require(set2.at())) }
        let it2 = newBuffer(delta: 180_000)
        it2.reset(series2[0].iterator(nil))
        var f2: [FPoint]? = nil
        var h2: [HPoint]? = nil
        var st2: StartTimestamps? = nil
        try ev.matrixIterSlice(it2, -1, 120_000, &f2, &h2, &st2)
        #expect(
            h2?.map(\.h.counterResetHint)
                == [.unknownCounterReset, .notCounterReset, .notCounterReset])

        // A FLOAT sample between two histograms starts a fresh chunk, so the histogram after it is
        // back to `unknown` instead of continuing the `not_reset` run. Upstream gets this from the
        // encoding — a float goes in an XOR chunk, so the next histogram cannot share the previous
        // histogram chunk — and no `.test` file has a series shaped like this, so the control for it
        // survived until this assertion existed.
        let store3 = MemStorage()
        try store3.load(
            Labels(strings: ["__name__", "interrupted"]),
            [
                FHSample(st: 0, t: 0, fh: h(.unknownCounterReset, 1)),
                FHSample(st: 0, t: 60_000, fh: h(.unknownCounterReset, 2)),
                FSample(st: 0, t: 120_000, f: 3),
                FHSample(st: 0, t: 180_000, fh: h(.unknownCounterReset, 4)),
                FHSample(st: 0, t: 240_000, fh: h(.unknownCounterReset, 5)),
            ])
        let q3 = try store3.querier(mint: 0, maxt: 240_000)
        let set3 = q3.select(
            GoContext.background(), sortSeries: true, hints: SelectHints(start: 0, end: 240_000),
            matchers: [try Matcher(.equal, "__name__", "interrupted")])
        var series3: [any PromStorage.Series] = []
        while set3.next() { series3.append(try #require(set3.at())) }
        let it3 = newBuffer(delta: 300_000)
        it3.reset(series3[0].iterator(nil))
        var f3: [FPoint]? = nil
        var h3: [HPoint]? = nil
        var st3: StartTimestamps? = nil
        try ev.matrixIterSlice(it3, -1, 240_000, &f3, &h3, &st3)
        #expect(f3?.count == 1)
        #expect(
            h3?.map(\.h.counterResetHint)
                == [.unknownCounterReset, .notCounterReset, .unknownCounterReset, .notCounterReset],
            "the float restarts the chunk, so the histogram after it is unknown again")

        // And the link the original hypothesis suspected is still pinned, separately:
        // `parseSeriesDesc` DOES carry `counter_reset_hint:`. Phase 4's 1,685-case
        // series-description corpus cannot see it — that fixture compares `String()`, and
        // `FloatHistogram.String()` does not print the hint. Exactly the trap HANDOFF §3 records for
        // `promql/histogram-stats`, in a corpus that predates the lesson.
        let parsed = try Parser(options: Options()).parseSeriesDesc(
            "mixed {{schema:0 count:1 sum:1 counter_reset_hint:reset buckets:[1]}}")
        #expect(
            parsed.values.first?.histogram?.counterResetHint == .counterReset,
            "parseSeriesDesc must carry counter_reset_hint — String() cannot see it, so no fixture does")

        // The step HANDOFF §5e localises the collision finding to: the hints on `+`/`x`-EXPANDED
        // histogram samples. This is the FINDING, and it is asserted as the current behaviour with
        // the bug named, because a test that fails cannot land:
        //
        // every expanded sample comes back `unknownCounterReset` — and **so do Go's.** The
        // expansion DOES go through `FloatHistogram.Add` (`Parser+Semantics.swift:276`), and
        // `adjustCounterReset` returns early when both hints are equal, which they are for two
        // freshly parsed literals.
        //
        // So the `not_reset`/`reset` hints `native_histograms.test` relies on come from neither the
        // parser nor the arithmetic: they come from the **storage**, because `teststorage` wraps a
        // real `tsdb.DB` whose Head re-derives `CounterResetHint` on append. `MemStorage` does not.
        // That makes the gate's last collision failure a Phases 6-7 dependency rather than an
        // evaluator bug — see HANDOFF §5e, which had written the mechanism down before any of this
        // was investigated.
        let expanded = try Parser(options: Options()).parseSeriesDesc(
            "mixed {{schema:0 count:5 sum:6 buckets:[2 2 1]}}"
                + "+{{schema:0 count:3 sum:2 buckets:[1 1 1]}}x2"
                + " {{schema:0 count:4 sum:4 buckets:[1 2 1]}}")
        let hints = expanded.values.map { $0.histogram?.counterResetHint }
        #expect(
            hints == [
                .unknownCounterReset, .unknownCounterReset, .unknownCounterReset,
                .unknownCounterReset,
            ],
            "expansion hints: \(hints.map { $0.map(String.init(describing:)) ?? "nil" })")
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
