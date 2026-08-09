//===----------------------------------------------------------------------===//
// Differential tests for promql/histogram_stats_iterator.go, plus the properties
// the fixtures cannot state.
//
// The fixtures replay op scripts and record, at every step, the whole observable
// result: the ValueType, the timestamp, the histogram's rendering, and — the field
// that matters most and that `String()` omits — the CounterResetHint.
//
// Six of the 35 cases are upstream's own TestHistogramStatsDecoding tables,
// reproduced in shape. Their hints come out of the fixture rather than being
// asserted here, so a divergence names the case; the hints upstream *expects* are
// re-asserted directly in `UpstreamTablesTests` below, which is the only place in
// this suite where a hand-written expectation is the right tool: the numbers are
// upstream's, copied from its test file, not ours.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromHistogram
import PromLabels
import PromModel
import PromStorage
import Testing

@testable import PromQL

@Suite("HistogramStatsIterator matches Go")
struct HistogramStatsIteratorTests {

    @Test("every op script over the stats iterator")
    func fixtures() throws {
        try Fixtures.check(
            "promql/histogram-stats.jsonl", FixtureCase<StatsIn, StatsOut>.self
        ) { input in
            runHistogramStatsOps(input)
        }
    }
}

// MARK: - Upstream's own expectations, restated

@Suite("upstream's TestHistogramStatsDecoding tables")
struct UpstreamTablesTests {

    /// The hints upstream's own test asserts, keyed by the fixture case that
    /// reproduces its table (histogram_stats_iterator_test.go:29-113).
    ///
    /// This is a hand-written expectation, which the rest of this repo avoids — but
    /// the numbers are *upstream's*, not a guess of ours, and asserting them here
    /// is what proves the fixture reproduces the table rather than merely being
    /// self-consistent with the port.
    private static let tables: [(id: String, hints: [CounterResetHint])] = [
        (
            "unknown counter reset for later sample triggers detection",
            [.notCounterReset, .notCounterReset, .counterReset, .notCounterReset]
        ),
        (
            "unknown counter reset for first sample does not trigger detection",
            [.unknownCounterReset, .notCounterReset, .counterReset, .notCounterReset]
        ),
        (
            "stale sample before unknown reset hint",
            [.notCounterReset, .notCounterReset, .unknownCounterReset, .notCounterReset]
        ),
        ("unknown counter reset at the beginning", [.unknownCounterReset]),
        ("detect real counter reset", [.unknownCounterReset, .counterReset]),
        (
            "detect real counter reset after stale NaN",
            [.unknownCounterReset, .unknownCounterReset, .counterReset]
        ),
    ]

    /// The six sample lists, in the same order as `tables`. A function rather than
    /// a stored property because `any Sample` is not `Sendable`.
    private static func samples(_ i: Int) -> [any PromChunks.Sample] {
        switch i {
        case 0:
            return [
                hSample(0, 0, .notCounterReset), hSample(10, 1, .unknownCounterReset),
                hSample(20, 2, .counterReset), hSample(30, 2, .unknownCounterReset),
            ]
        case 1:
            return [
                hSample(0, 0, .unknownCounterReset), hSample(10, 1, .unknownCounterReset),
                hSample(20, 2, .counterReset), hSample(30, 2, .unknownCounterReset),
            ]
        case 2:
            return [
                hSample(0, 0, .notCounterReset), hSample(10, 1, .unknownCounterReset),
                staleSample(20), hSample(30, 1, .unknownCounterReset),
            ]
        case 3:
            return [hSample(0, 1, .unknownCounterReset)]
        case 4:
            return [hSample(0, 2, .unknownCounterReset), hSample(10, 1, .unknownCounterReset)]
        default:
            return [
                hSample(0, 2, .unknownCounterReset), staleSample(10),
                hSample(20, 1, .unknownCounterReset),
            ]
        }
    }

    private static func hSample(_ t: Int64, _ n: Int64, _ hint: CounterResetHint)
        -> any PromChunks.Sample
    {
        var h = genTestHistogram(n)
        h.counterResetHint = hint
        return StatsCorpusSample(st: 0, t: t, fValue: 0, hValue: h, fhValue: nil)
    }

    private static func staleSample(_ t: Int64) -> any PromChunks.Sample {
        StatsCorpusSample(st: 0, t: t, fValue: 0, hValue: genStaleHistogram(), fhValue: nil)
    }

    /// Upstream's `check` closure: walk, reading twice at each step to assert
    /// idempotency, and collect the stripped histograms.
    private func decode(_ samples: [any PromChunks.Sample]) -> [FloatHistogram] {
        let it = HistogramStatsIterator(newListSeriesIterator(SampleSlice(samples)))
        var out = [FloatHistogram]()
        while true {
            let vt = it.next()
            if vt == .none { break }
            #expect(vt == ValueType.floatHistogram, "never reports an integer histogram")
            let (t1, h1) = it.atFloatHistogram(nil)
            let (t2, h2) = it.atFloatHistogram(nil)
            #expect(t1 == t2)
            #expect(h1?.equals(h2 ?? FloatHistogram()) == true, "a repeated read is idempotent")
            out.append(h1 ?? FloatHistogram())
        }
        #expect(it.err() == nil)
        return out
    }

    @Test("each table's hints, on a fresh iterator and again after reset")
    func tables() {
        for (i, table) in Self.tables.enumerated() {
            let samples = Self.samples(i)

            // Fresh.
            var decoded = decode(samples)
            #expect(decoded.map(\.counterResetHint) == table.hints, "\(table.id): fresh")

            // And again after Reset, which upstream runs for exactly this reason:
            // the second walk must reproduce the first hint for hint, including the
            // first sample's `unknown`.
            let it = HistogramStatsIterator(newListSeriesIterator(SampleSlice(samples)))
            _ = decode(samples)
            it.reset(newListSeriesIterator(SampleSlice(samples)))
            decoded = []
            while it.next() != .none {
                decoded.append(it.atFloatHistogram(nil).1 ?? FloatHistogram())
            }
            #expect(decoded.map(\.counterResetHint) == table.hints, "\(table.id): after reset")

            // Upstream's other two assertions: count and sum survive, and a stale
            // sample's count is zero while its sum stays the stale marker.
            for (j, sample) in samples.enumerated() {
                let source = sample.h!.toFloat()
                if PromValue.isStaleNaN(source.sum) {
                    #expect(PromValue.isStaleNaN(decoded[j].sum))
                    #expect(decoded[j].count == 0)
                } else {
                    #expect(decoded[j].count == source.count)
                    #expect(decoded[j].sum == source.sum)
                }
            }
        }
    }

    @Test("TestHistogramStatsMixedUse — reads interleaved with advances")
    func mixedUse() {
        // histogram_stats_iterator_test.go:153. n goes 2 -> 4 -> 0, so the hints are
        // unknown (no `last` yet), notCounterReset, counterReset.
        let samples: [any PromChunks.Sample] = [
            Self.hSample(0, 2, .unknownCounterReset),
            Self.hSample(10, 4, .unknownCounterReset),
            Self.hSample(20, 0, .unknownCounterReset),
        ]
        let it = HistogramStatsIterator(newListSeriesIterator(SampleSlice(samples)))

        #expect(it.next() == ValueType.floatHistogram)
        let first = it.atFloatHistogram(nil).1
        #expect(first?.counterResetHint == CounterResetHint.unknownCounterReset)

        #expect(it.next() == ValueType.floatHistogram)
        let second = it.atFloatHistogram(nil).1
        let secondAgain = it.atFloatHistogram(nil).1
        #expect(second?.equals(secondAgain ?? FloatHistogram()) == true)
        #expect(second?.counterResetHint == CounterResetHint.notCounterReset)

        #expect(it.next() == ValueType.floatHistogram)
        #expect(it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.counterReset)

        #expect(it.next() == ValueType.none)
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("HistogramStatsIterator invariants")
struct HistogramStatsInvariantTests {

    private func iterator(_ samples: [(t: Int64, n: Int64, hint: CounterResetHint)])
        -> HistogramStatsIterator
    {
        let list = samples.map { s -> any PromChunks.Sample in
            var h = genTestHistogram(s.n)
            h.counterResetHint = s.hint
            return StatsCorpusSample(st: 0, t: s.t, fValue: 0, hValue: h, fhValue: nil)
        }
        return HistogramStatsIterator(newListSeriesIterator(SampleSlice(list)))
    }

    @Test("the buckets are stripped, and only four fields survive")
    func stripsEverythingButFourFields() {
        // The whole reason the type exists: `detectHistogramStatsDecoding` wraps a
        // selector when the query reads only count and sum, so the buckets need not
        // be decoded. If any of these came through, that optimisation would be
        // silently pointless rather than wrong, which is the hard kind of bug.
        let it = iterator([(0, 3, .notCounterReset)])
        #expect(it.next() == ValueType.floatHistogram)
        let fh = it.atFloatHistogram(nil).1!

        #expect(fh.count == 39, "count survives")
        #expect(fh.sum == 18.4 * 4, "sum survives")
        #expect(fh.schema == 1, "schema survives")
        #expect(fh.counterResetHint == CounterResetHint.notCounterReset, "the hint survives")

        #expect(fh.positiveSpans.isEmpty)
        #expect(fh.negativeSpans.isEmpty)
        #expect(fh.positiveBuckets.isEmpty)
        #expect(fh.negativeBuckets.isEmpty)
        #expect(fh.zeroCount == 0)
        #expect(fh.zeroThreshold == 0)
        #expect(fh.customValues == nil)
    }

    @Test("detection compares the FULL histograms, not the stripped ones")
    func detectionSeesTheBuckets() {
        // `last` holds a copy of `current`, buckets included, precisely so
        // DetectReset has something to work with. Two histograms with the SAME count
        // and sum but different bucket layouts must still be distinguishable — which
        // they would not be if `last` held the stripped form.
        //
        // Built by hand rather than through the generator, whose counts move with n.
        let shared = (count: UInt64(10), sum: 20.0)
        let a = Histogram(
            schema: 0, count: shared.count, sum: shared.sum,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [5, 0])
        let b = Histogram(
            schema: 0, count: shared.count, sum: shared.sum,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 3])
        let samples: [any PromChunks.Sample] = [
            StatsCorpusSample(st: 0, t: 0, fValue: 0, hValue: a, fhValue: nil),
            StatsCorpusSample(st: 0, t: 10, fValue: 0, hValue: b, fhValue: nil),
        ]
        let it = HistogramStatsIterator(newListSeriesIterator(SampleSlice(samples)))
        _ = it.next()
        _ = it.atFloatHistogram(nil)
        _ = it.next()
        let second = it.atFloatHistogram(nil).1!
        #expect(second.count == 10, "count and sum are identical either way")
        #expect(
            second.counterResetHint == CounterResetHint.counterReset,
            "bucket 0 fell from 5 to 1, which only the full histogram shows")
    }

    @Test("a repeated read cannot report 'no counter reset' for a reset")
    func repeatedReadDoesNotReRunDetection() {
        // The point of `lastIsCurrent`. Re-running detection would compare the
        // sample against the copy of ITSELF that the first read stored, which finds
        // no reset — so a second read would silently contradict the first.
        let it = iterator([(0, 9, .unknownCounterReset), (10, 1, .unknownCounterReset)])
        _ = it.next()
        _ = it.atFloatHistogram(nil)
        _ = it.next()
        let hints = (0..<5).map { _ in it.atFloatHistogram(nil).1!.counterResetHint }
        #expect(
            hints.allSatisfy { $0 == .counterReset },
            "every read agrees; got \(hints)")
    }

    @Test("a stale sample does not become the comparison baseline")
    func staleDoesNotBecomeLast() {
        // The stale branch returns before `setLastFromCurrent`, so `last` is
        // untouched and the sample AFTER a stale one is compared against the sample
        // BEFORE it. Two stales in a row therefore do not lose the baseline either.
        let stale: any PromChunks.Sample = StatsCorpusSample(
            st: 0, t: 10, fValue: 0, hValue: genStaleHistogram(), fhValue: nil)
        var big = genTestHistogram(9)
        big.counterResetHint = .unknownCounterReset
        var small = genTestHistogram(1)
        small.counterResetHint = .unknownCounterReset
        let samples: [any PromChunks.Sample] = [
            StatsCorpusSample(st: 0, t: 0, fValue: 0, hValue: big, fhValue: nil),
            stale,
            StatsCorpusSample(st: 0, t: 20, fValue: 0, hValue: small, fhValue: nil),
        ]
        let it = HistogramStatsIterator(newListSeriesIterator(SampleSlice(samples)))
        _ = it.next()
        _ = it.atFloatHistogram(nil)
        _ = it.next()
        let staleOut = it.atFloatHistogram(nil).1!
        #expect(PromValue.isStaleNaN(staleOut.sum), "the marker travels through verbatim")
        #expect(staleOut.counterResetHint == CounterResetHint.unknownCounterReset)
        _ = it.next()
        #expect(
            it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.counterReset,
            "compared against t=0, not against the stale sample")
    }

    @Test("a seek that does not move keeps the memo")
    func noOpSeekKeepsTheMemo() {
        // `if t > hsi.AtT()` — a seek to the current timestamp or earlier leaves both
        // `last` and `lastIsCurrent` alone, so the read still answers from the memo
        // rather than re-detecting against a baseline it has just dropped.
        let it = iterator([(0, 9, .unknownCounterReset), (10, 1, .unknownCounterReset)])
        _ = it.next()
        _ = it.atFloatHistogram(nil)
        _ = it.next()
        #expect(it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.counterReset)

        #expect(it.seek(10) == ValueType.floatHistogram, "already at or past 10")
        #expect(
            it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.counterReset,
            "the memo survived the no-op seek")

        // Whereas a seek that moves drops the baseline, so the hint goes back to
        // unknown even over a series that plainly reset.
        let moving = iterator([
            (0, 9, .unknownCounterReset), (10, 5, .unknownCounterReset),
            (20, 1, .unknownCounterReset),
        ])
        _ = moving.next()
        _ = moving.atFloatHistogram(nil)
        #expect(moving.seek(20) == ValueType.floatHistogram)
        #expect(
            moving.atFloatHistogram(nil).1?.counterResetHint
                == CounterResetHint.unknownCounterReset,
            "the seek dropped `last`, so there is nothing to compare against")
    }

    @Test("reset keeps the reuse buffer but drops the baseline")
    func resetDropsLastNotCurrent() {
        // Go's Reset assigns only `Iterator`, `last` and `lastIsCurrent`; `current`
        // stays as the scratch handed to the wrapped iterator. Not observable through
        // the result — it is an allocation choice — but a reset that also cleared
        // `last` is the whole point, so assert that half.
        let samples: [(t: Int64, n: Int64, hint: CounterResetHint)] = [
            (0, 9, .unknownCounterReset), (10, 1, .unknownCounterReset),
        ]
        let it = iterator(samples)
        _ = it.next()
        _ = it.atFloatHistogram(nil)
        _ = it.next()
        #expect(it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.counterReset)

        let fresh = iterator(samples)
        it.reset(fresh.iterator)
        _ = it.next()
        #expect(
            it.atFloatHistogram(nil).1?.counterResetHint == CounterResetHint.unknownCounterReset,
            "the baseline is gone, so the first sample is unknown again")
    }

    @Test("a reuse buffer's contents cannot leak into the result")
    func reuseBufferIsWiped() {
        // Worth stating plainly: under Swift's value semantics the reuse buffer is
        // NOT observable — ignoring it entirely leaves the whole differential suite
        // green, which was checked by perturbation. So this asserts the property
        // that matters (the result carries nothing but the four surviving fields,
        // whichever path built it) rather than pretending to distinguish the paths.
        let it = iterator([(0, 1, .notCounterReset)])
        _ = it.next()
        var dirty = genTestCustomBucketsHistogram(7).toFloat()
        #expect(dirty.customValues != nil, "the buffer starts dirty")
        #expect(!dirty.positiveBuckets.isEmpty)

        let out = it.atFloatHistogram(dirty).1!
        #expect(out.customValues == nil, "customValues is nilled, not resized")
        #expect(out.positiveBuckets.isEmpty)
        #expect(out.schema == 1, "the source's schema, not the buffer's -53")
        #expect(out.count == 21)

        // And the caller's own value is untouched, because `FloatHistogram` is a
        // struct here where Go's is a pointer.
        #expect(dirty.customValues != nil, "the caller's copy is unchanged")
        dirty.count = 0  // silences the unused-mutation warning
    }

    @Test("HistogramStatsSeries recycles the stats iterator it is handed")
    func seriesRecyclesTheIterator() {
        // engine.go:4795. Note WHICH iterator is passed inward: the stats iterator's
        // wrapped one, so the series underneath gets its own kind back for reuse
        // rather than a stats iterator it cannot recognise.
        var h = genTestHistogram(1)
        h.counterResetHint = .notCounterReset
        let inner = newListSeries(
            Labels(strings: "__name__", "x"),
            [StatsCorpusSample(st: 0, t: 0, fValue: 0, hValue: h, fhValue: nil)])
        let series = newHistogramStatsSeries(inner)
        #expect(series.labels()[LabelName.metricName] == "x")

        let first = series.iterator(nil)
        #expect(first is HistogramStatsIterator, "wrapped on the way out")
        #expect(first.next() == ValueType.floatHistogram)

        let second = series.iterator(first)
        #expect(second as AnyObject === first as AnyObject, "recycled, not reallocated")
        #expect(second.next() == ValueType.floatHistogram, "and reset back to the start")

        let fresh = series.iterator(newNopIterator())
        #expect(fresh as AnyObject !== first as AnyObject, "a foreign iterator is replaced")
        #expect(fresh is HistogramStatsIterator)
    }

    @Test("next and seek never report an integer histogram")
    func integerHistogramAlwaysFolded() {
        // The type's contract, and what makes `atHistogram` unreachable through a
        // caller that dispatches on the returned ValueType.
        let it = iterator([
            (0, 1, .notCounterReset), (10, 2, .notCounterReset), (20, 3, .notCounterReset),
        ])
        #expect(it.next() == ValueType.floatHistogram)
        #expect(it.seek(15) == ValueType.floatHistogram)
        #expect(it.atT() == 20)
        #expect(it.next() == ValueType.none)
    }
}
