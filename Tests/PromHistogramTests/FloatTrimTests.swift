//===----------------------------------------------------------------------===//
// Differential tests for model/histogram/float_histogram.go, slice 6:
// TrimBuckets.
//
// The log2 suite here is not incidental. Go's `math.Log2` is a pure-Go
// implementation (frexp, then `Log(frac)*(1/Ln2)+exp`, with an exact shortcut for
// `frac == 0.5`) rather than a call into libm, and `computeSplit`'s exponential
// interpolation depends on it. If the platform's libm disagrees by an ULP, trim
// counts and the re-estimated sum drift — so log2 is pinned separately, and any
// trim failure can immediately be attributed to it or to the surrounding logic.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHistogram

@Suite("TrimBuckets matches Go")
struct FloatTrimTests {

    @Test("every committed trim, at every trim point and both directions")
    func trimBuckets() throws {
        struct In: Decodable, Sendable {
            let h: FloatHistJSON
            let rhs: String
            let isUpperTrim: Bool
        }
        // Bit-exact, including the interpolated bucket and the re-estimated sum.
        // That only holds because GoMath.log2 reproduces Go's fused final step —
        // see Tests/GoCompatTests/GoMathTests.swift. Calling libm's log2 here
        // instead mismatches 895 of these 9,048 cases.
        try Fixtures.check("histogram/float-trim.jsonl", FixtureCase<In, FloatHistJSON>.self) {
            input in
            FloatHistJSON(
                input.h.histogram.trimBuckets(
                    rhs: doubleFromHex(input.rhs), isUpperTrim: input.isUpperTrim))
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("TrimBuckets invariants")
struct FloatTrimInvariantTests {

    static func nhcb() -> FloatHistogram {
        FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 10,
            sum: 30,
            positiveSpans: [Span(offset: 0, length: 5)],
            positiveBuckets: [1, 2, 3, 3, 1],
            customValues: [1, 2, 5, 10])
    }

    static func exponential() -> FloatHistogram {
        FloatHistogram(
            schema: 0,
            zeroThreshold: 0.001,
            zeroCount: 2,
            count: 8,
            sum: 20,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 3])
    }

    @Test("trimming does not mutate the receiver")
    func nonDestructive() {
        let original = Self.exponential()
        let h = Self.exponential()
        _ = h.trimBuckets(rhs: 2.5, isUpperTrim: true)
        #expect(h.equals(original))
    }

    @Test("a trim point beyond every bucket keeps or drops everything")
    func trimOutsideRange() {
        let h = Self.exponential()
        // Upper trim above everything: nothing is removed, so the totals are left
        // exactly as they were rather than being re-estimated from midpoints.
        let keepAll = h.trimBuckets(rhs: .infinity, isUpperTrim: true)
        #expect(keepAll.positiveBuckets == h.positiveBuckets)
        #expect(keepAll.count == h.count)
        #expect(keepAll.sum == h.sum)

        // Upper trim below everything: every bucket goes, and Compact removes them.
        let dropAll = h.trimBuckets(rhs: -.infinity, isUpperTrim: true)
        #expect(dropAll.positiveBuckets.isEmpty)
        #expect(dropAll.count == 0)
        #expect(dropAll.zeroCount == 0)
    }

    @Test("the totals are only re-estimated when something was actually trimmed")
    func totalsPreservedWhenNothingTrimmed() {
        // Go guards the Count/Sum update behind trimmedBuckets, so an untouched
        // histogram keeps its original sum rather than a midpoint estimate — which
        // would otherwise silently rewrite Sum on a no-op trim.
        let h = Self.exponential()
        let untouched = h.trimBuckets(rhs: .infinity, isUpperTrim: true)
        #expect(untouched.sum == 20)
        // Whereas an actual trim replaces Sum with the midpoint estimate.
        let trimmed = h.trimBuckets(rhs: 2, isUpperTrim: true)
        #expect(trimmed.sum != 20)
    }

    @Test("custom buckets interpolate linearly, exponential ones geometrically")
    func interpolationMode() {
        // NHCB bucket (2,5] holding 3 observations, trimmed at 3.5 — exactly half
        // way — keeps half of them under linear interpolation.
        let linear = Self.nhcb().trimBuckets(rhs: 3.5, isUpperTrim: true)
        #expect(linear.positiveBuckets == [1, 2, 1.5])

        // The exponential bucket (2,4] holding 3, trimmed at its geometric middle
        // 2*sqrt(2), keeps half. Linear interpolation would keep 0.414... of them.
        let h = FloatHistogram(
            schema: 0,
            count: 3,
            sum: 9,
            positiveSpans: [Span(offset: 2, length: 1)],
            positiveBuckets: [3])
        let geometric = h.trimBuckets(rhs: 2 * 2.0.squareRoot(), isUpperTrim: true)
        #expect(abs(geometric.positiveBuckets[0] - 1.5) < 1e-12)
    }

    @Test("upper and lower trims of the same point partition the observations")
    func trimsPartition() {
        // Every bucket-contained fraction kept by one side is dropped by the other,
        // so the two counts sum back to the original for a histogram with no
        // infinite bucket.
        let h = Self.exponential()
        for rhs in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.9] {
            let upper = h.trimBuckets(rhs: rhs, isUpperTrim: true)
            let lower = h.trimBuckets(rhs: rhs, isUpperTrim: false)
            #expect(
                abs(upper.count + lower.count - h.count) < 1e-9,
                "rhs \(rhs): \(upper.count) + \(lower.count) != \(h.count)")
        }
    }

    @Test("an infinite bucket is dropped whole rather than interpolated")
    func infiniteBucketsAreConservative() {
        // The implicit +Inf bucket of an NHCB has no known distribution, so an
        // upper trim inside it removes all of it instead of guessing.
        let h = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 6,
            sum: 6,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 3],
            customValues: [0.5, 1])
        let trimmed = h.trimBuckets(rhs: 100, isUpperTrim: true)
        // The two bounded buckets survive; the +Inf one does not.
        #expect(trimmed.positiveBuckets == [1, 2])

        // A lower trim below its lower bound keeps it, since everything in it is
        // above the trim point.
        let kept = h.trimBuckets(rhs: 1, isUpperTrim: false)
        #expect(kept.positiveBuckets.last == 3)
    }

    @Test("the zero bucket's half is clamped by which side has observations")
    func zeroBucketClamping() {
        // With only positive buckets the zero bucket's lower half is meaningless,
        // so it is treated as [0, threshold] rather than [-threshold, threshold].
        let positiveOnly = FloatHistogram(
            schema: 0,
            zeroThreshold: 1,
            zeroCount: 4,
            count: 6,
            positiveSpans: [Span(offset: 1, length: 1)],
            positiveBuckets: [2])
        // Trimming at 0.5 keeps half of the zero bucket: (0.5-0)/(1-0).
        let trimmed = positiveOnly.trimBuckets(rhs: 0.5, isUpperTrim: true)
        #expect(trimmed.zeroCount == 2)

        // With observations on both sides the full width is used, so 0.5 keeps
        // three quarters: (0.5 - -1)/(1 - -1).
        let bothSides = FloatHistogram(
            schema: 0,
            zeroThreshold: 1,
            zeroCount: 4,
            count: 8,
            positiveSpans: [Span(offset: 1, length: 1)],
            negativeSpans: [Span(offset: 1, length: 1)],
            positiveBuckets: [2],
            negativeBuckets: [2])
        #expect(bothSides.trimBuckets(rhs: 0.5, isUpperTrim: true).zeroCount == 3)
    }
}
