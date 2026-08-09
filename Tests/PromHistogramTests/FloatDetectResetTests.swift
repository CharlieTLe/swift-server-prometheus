//===----------------------------------------------------------------------===//
// Differential tests for model/histogram/float_histogram.go, slice 3:
// DetectReset.
//
// This also closes the gap left by slice 1. `floatBucketIterator`'s merge path
// (targetSchema < schema) and its `absoluteStartValue` skipping are unexported in
// Go, and DetectReset is the only caller that reaches them from outside the
// package: it iterates BOTH histograms at the receiver's schema and from the
// receiver's zero threshold. The corpus sweeps every schema pairing against every
// zero threshold for exactly that reason.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHistogram

@Suite("DetectReset matches Go")
struct FloatDetectResetTests {

    @Test("every committed pair, and neither input is mutated")
    func detectReset() throws {
        struct In: Decodable, Sendable {
            let previous: FloatHistJSON
            let current: FloatHistJSON
        }
        struct Out: Decodable, Equatable, Sendable {
            let reset: Bool
            let previousUnmoved: Bool
            let currentUnmoved: Bool
        }
        try Fixtures.check("histogram/float-detectreset.jsonl", FixtureCase<In, Out>.self) {
            input in
            let previous = input.previous.histogram
            let current = input.current.histogram
            let reset = current.detectReset(previous)
            // Detection folds previous's buckets into its zero count and merges its
            // schema along the way, all of which must be non-destructive.
            return Out(
                reset: reset,
                previousUnmoved: FloatHistJSON(previous) == input.previous,
                currentUnmoved: FloatHistJSON(current) == input.current)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("DetectReset invariants")
struct FloatDetectResetInvariantTests {

    static func base() -> FloatHistogram {
        FloatHistogram(
            schema: 0,
            zeroThreshold: 0.01,
            zeroCount: 5.5,
            count: 3493.3,
            sum: 2349209.324,
            positiveSpans: [Span(offset: -2, length: 1), Span(offset: 2, length: 3)],
            negativeSpans: [Span(offset: 3, length: 2), Span(offset: 3, length: 2)],
            positiveBuckets: [1, 3.3, 4.2, 0.1],
            negativeBuckets: [3.1, 3, 1.234e5, 1000])
    }

    @Test("the counter reset hint short-circuits detection")
    func hintShortCircuits() {
        // counterReset says yes without looking, even against an identical
        // histogram...
        var current = Self.base()
        current.counterResetHint = .counterReset
        #expect(current.detectReset(Self.base()))

        // ...and notCounterReset says no without looking, even against one that
        // obviously reset.
        var previous = Self.base()
        previous.count *= 10
        current.counterResetHint = .notCounterReset
        #expect(!current.detectReset(previous))

        // gaugeType does the full work: PromQL lets users apply counter-only
        // functions to gauges, and then a gauge is treated as a counter.
        current.counterResetHint = .gaugeType
        #expect(current.detectReset(previous))
    }

    @Test("a decreasing sum is not a reset, but any decreasing count is")
    func sumIsExempt() {
        var lowerSum = Self.base()
        lowerSum.sum -= 1_000_000
        #expect(!lowerSum.detectReset(Self.base()))

        for mutate in [
            { (h: inout FloatHistogram) in h.count -= 1 },
            { h in h.zeroCount -= 1 },
            { h in h.positiveBuckets[0] -= 0.5 },
            { h in h.negativeBuckets[3] -= 1 },
        ] {
            var current = Self.base()
            mutate(&current)
            #expect(current.detectReset(Self.base()))
        }
    }

    @Test("a higher resolution or a smaller zero threshold implies a reset")
    func resolutionChanges() {
        // Both can only happen together with a reset, so they return true without
        // comparing buckets.
        var higherSchema = Self.base()
        higherSchema.schema = 1
        #expect(higherSchema.detectReset(Self.base()))

        var smallerThreshold = Self.base()
        smallerThreshold.zeroThreshold = 0.001
        #expect(smallerThreshold.detectReset(Self.base()))
    }

    @Test("a lower resolution does not short-circuit; it merges and compares")
    func lowerResolutionMerges() {
        // Both values verified against Go. Previous sits at schema 0 with buckets
        // at indices 1 and 2, which both merge into target index 1 at schema -1.
        let previous = FloatHistogram(
            schema: 0,
            count: 7.5,
            sum: 7.5,
            positiveSpans: [Span(offset: 1, length: 2)],
            positiveBuckets: [3.3, 4.2])
        // A coarser current histogram that still holds everything: no reset.
        var current = FloatHistogram(
            schema: -1,
            count: 10,
            sum: 10,
            positiveSpans: [Span(offset: 1, length: 1)],
            positiveBuckets: [10])
        #expect(!current.detectReset(previous))
        // Holding less than the merged total is a reset.
        current.positiveBuckets = [7]
        #expect(current.detectReset(previous))

        // Note that merely relabelling a histogram's schema downwards DOES report a
        // reset, because the same bucket indices then mean different bounds and the
        // merged previous ends up with buckets the current one lacks.
        var relabelled = Self.base()
        relabelled.schema = -1
        #expect(relabelled.detectReset(Self.base()))
    }

    @Test("Go only inspects the first previous bucket when the current one runs out")
    func drainLoopQuirk() {
        // float_histogram.go:817's comment says it checks whether *any* remaining
        // previous bucket is populated, but the loop never advances prevBucket — so
        // a populated bucket sitting behind an empty one is missed and no reset is
        // reported. Confirmed against Go directly; see docs/PORTING.md
        // "Replicated Go quirks".
        let hidden = FloatHistogram(
            schema: 0,
            count: 5,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [0, 5])
        let empty = FloatHistogram(schema: 0, count: 5)
        #expect(!empty.detectReset(hidden))

        // Put the populated bucket first and the same loop reports the reset.
        let visible = FloatHistogram(
            schema: 0,
            count: 5,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [5, 0])
        #expect(empty.detectReset(visible))
    }

    @Test("an NHCB against an exponential histogram is always a reset")
    func schemaFamilyChange() {
        let nhcb = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 6,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 3],
            customValues: [1, 2, 3])
        // The receiver is the NHCB, so it takes the usesCustomBuckets branch and
        // reports a change of representation.
        var exponential = Self.base()
        exponential.count = 6
        #expect(nhcb.detectReset(exponential))
    }

    @Test("mismatched NHCB bounds compare on the reconciled rollups")
    func mismatchedCustomBounds() {
        // Bounds 1,2,3,4 against 1,3: only bounds 1 and 3 are shared, so the
        // comparison is over the rolled-up sums at those two bounds.
        let previous = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 5,
            positiveSpans: [Span(offset: 0, length: 5)],
            positiveBuckets: [1, 1, 1, 1, 1],
            customValues: [1, 2, 3, 4])
        // Rolled up: (≤1)=1, (≤3)=1+1+1=3.
        var shrunk = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 5,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 1, 3],
            customValues: [1, 3])
        // (≤1)=1, (≤3)=1+1=2 < 3, so a bucket shrank.
        #expect(shrunk.detectReset(previous))

        // Raise it above the previous rollup and there is no reset.
        shrunk.positiveBuckets = [1, 5, 3]
        shrunk.count = 9
        #expect(!shrunk.detectReset(previous))
    }

    @Test("detection does not mutate either histogram")
    func nonDestructive() {
        // Widening the zero threshold and merging the schema both happen on the
        // previous histogram, and must leave it untouched.
        var current = Self.base()
        current.schema = -2
        current.zeroThreshold = 1
        let previous = Self.base()
        let snapshot = Self.base()
        _ = current.detectReset(previous)
        #expect(previous.equals(snapshot))
        #expect(current.schema == -2)
        #expect(current.zeroThreshold == 1)
    }
}
