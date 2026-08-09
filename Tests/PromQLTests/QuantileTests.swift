//===----------------------------------------------------------------------===//
// Differential tests for promql/quantile.go and math.Exp2.
//
// The highest silent-divergence risk in Phase 5: a wrong interpolation looks like
// a plausible number. `math.Exp2` in particular is assembly on arm64 and fused, so
// libm's version is one ULP out on roughly a fifth of realistic inputs — see
// GoMath.exp2's note and docs/PORTING.md quirk 0.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromAnnotations
import PromHistogram
import PromLabels
import PromPosRange
import Testing

@testable import PromQL

@Suite("GoMath.exp2 matches Go's arm64 assembly")
struct Exp2Tests {

    @Test("every committed case")
    func fixtures() throws {
        try Fixtures.check("gocompat/exp2.jsonl", FixtureCase<String, String>.self) { hex in
            hexBitsQ(GoMath.exp2(doubleFromHexQ(hex)))
        }
    }

    @Test("libm's exp2 is NOT what Go computes")
    func libmDiffers() {
        // The reason GoMath.exp2 exists at all. If Swift's exp2 ever starts
        // agreeing with Go's fused arm64 routine this test fails, which is the
        // signal to reconsider carrying our own — not a reason to delete it
        // silently.
        //
        // 2**0.5: libm gives the correctly rounded 1.4142135623730951, Go's
        // assembly is one ULP below. Matching Go is the requirement.
        #expect(GoMath.exp2(0.5) != Foundation_exp2(0.5))
        #expect(GoMath.exp2(0.5).bitPattern == 0x3ff6_a09e_667f_3bcc)
        #expect(Foundation_exp2(0.5).bitPattern == 0x3ff6_a09e_667f_3bcd)
    }

    @Test("the special cases and the denormal path")
    func specials() {
        #expect(GoMath.exp2(0) == 1)
        #expect(GoMath.exp2(1) == 2)
        #expect(GoMath.exp2(-1) == 0.5)
        #expect(GoMath.exp2(Double.nan).isNaN)
        #expect(GoMath.exp2(Double.infinity) == Double.infinity)
        #expect(GoMath.exp2(-Double.infinity) == 0)
        // The exp2-specific thresholds, not Exp's.
        #expect(GoMath.exp2(1024) == Double.infinity)
        #expect(GoMath.exp2(-1075) == 0)
        // Denormal: the inlined Ldexp needs its 2**-52 scaling below exponent 1.
        #expect(GoMath.exp2(-1050) > 0, "still a subnormal, not flushed to zero")
        #expect(GoMath.exp2(-1050) < Double.leastNormalMagnitude)
    }
}

@Suite("classic-histogram quantiles match Go")
struct BucketQuantileTests {

    @Test("BucketQuantile, with the monotonicity outputs")
    func bucketQuantileFixtures() throws {
        try Fixtures.check(
            "promql/bucketquantile.jsonl", FixtureCase<BucketQuantileIn, BucketQuantileOut>.self
        ) { input in
            var buckets = input.swiftBuckets
            let (q, fix) = bucketQuantile(doubleFromHexQ(input.q), &buckets)
            return BucketQuantileOut(
                quantile: hexBitsQ(q),
                forcedMonotonic: fix.forcedMonotonic,
                fixedPrecision: fix.fixedPrecision,
                minBucket: hexBitsQ(fix.minBucket),
                maxBucket: hexBitsQ(fix.maxBucket),
                maxDiff: hexBitsQ(fix.maxDiff))
        }
    }

    @Test("BucketFraction")
    func bucketFractionFixtures() throws {
        try Fixtures.check(
            "promql/bucketfraction.jsonl", FixtureCase<BucketFractionIn, String>.self
        ) { input in
            var buckets = input.swiftBuckets
            return hexBitsQ(
                bucketFraction(
                    lower: doubleFromHexQ(input.lower), upper: doubleFromHexQ(input.upper),
                    &buckets))
        }
    }
}

@Suite("native-histogram quantiles match Go")
struct HistogramQuantileTests {

    @Test("HistogramQuantile, value and annotations")
    func histogramQuantileFixtures() throws {
        try Fixtures.check(
            "promql/histogramquantile.jsonl", FixtureCase<HistQuantileIn, HistQuantileOut>.self
        ) { input in
            let (v, annos) = histogramQuantile(
                doubleFromHexQ(input.q), input.h.swiftHistogram,
                metricName: input.metricName,
                pos: PositionRange(start: Pos(input.start), end: Pos(input.end)))
            let (warnings, infos) = annos.asStrings(query: "q", maxWarnings: 0, maxInfos: 0)
            return HistQuantileOut(
                value: hexBitsQ(v), warnings: warnings.sorted(), infos: infos.sorted())
        }
    }

    @Test("HistogramFraction, value and annotations")
    func histogramFractionFixtures() throws {
        try Fixtures.check(
            "promql/histogramfraction.jsonl", FixtureCase<HistFractionIn, HistQuantileOut>.self
        ) { input in
            let (v, annos) = histogramFraction(
                lower: doubleFromHexQ(input.lower), upper: doubleFromHexQ(input.upper),
                input.h.swiftHistogram, metricName: input.metricName,
                pos: PositionRange(start: Pos(input.start), end: Pos(input.end)))
            let (warnings, infos) = annos.asStrings(query: "q", maxWarnings: 0, maxInfos: 0)
            return HistQuantileOut(
                value: hexBitsQ(v), warnings: warnings.sorted(), infos: infos.sorted())
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("quantile invariants")
struct QuantileInvariantTests {

    private func inf(_ sign: Double = 1) -> Double { sign < 0 ? -.infinity : .infinity }

    @Test("BucketQuantile's special exits, in Go's order")
    func specialExits() {
        var normal: Buckets = [
            Bucket(upperBound: 1, count: 10), Bucket(upperBound: 2, count: 30),
            Bucket(upperBound: .infinity, count: 30),
        ]
        #expect(bucketQuantile(Double.nan, &normal).quantile.isNaN)
        #expect(bucketQuantile(-0.1, &normal).quantile == -.infinity)
        #expect(bucketQuantile(1.1, &normal).quantile == .infinity)

        // No +Inf bucket at all.
        var noInf: Buckets = [Bucket(upperBound: 1, count: 10)]
        #expect(bucketQuantile(0.5, &noInf).quantile.isNaN)
    }

    @Test("the early exits report zeros, not the inverted range")
    func earlyExitsReportZeros() {
        // Go declares minBucket/maxBucket/maxDiff as NAMED RETURNS, so they start
        // at 0; only ensureMonotonicAndIgnoreSmallDeltas sets the inverted
        // +Inf/-Inf range, at its own start (quantile.go:678). The three q exits and
        // the no-+Inf-bucket exit all return before that pass, so they report
        // zeros — initialising the struct to the inverted range instead would be
        // wrong on exactly those paths.
        var buckets: Buckets = [
            Bucket(upperBound: 1, count: 20), Bucket(upperBound: 2, count: 10),
            Bucket(upperBound: .infinity, count: 30),
        ]
        for q in [Double.nan, -0.1, 1.1] {
            let (_, fix) = bucketQuantile(q, &buckets)
            #expect(fix.minBucket == 0, "q=\(q)")
            #expect(fix.maxBucket == 0, "q=\(q)")
            #expect(fix.maxDiff == 0, "q=\(q)")
            #expect(!fix.forcedMonotonic)
        }

        var noInf: Buckets = [Bucket(upperBound: 1, count: 20)]
        let (q, fix) = bucketQuantile(0.5, &noInf)
        #expect(q.isNaN)
        #expect(fix.minBucket == 0, "the no-+Inf exit is also before the pass")
    }

    @Test("forcing monotonicity raises the last bucket, so zero observations cannot co-occur")
    func forcingReachesTheLastBucket() {
        // A non-obvious consequence worth pinning, because it is why the
        // zero-observations exit and a reported fix are mutually exclusive: the
        // pass carries the highest accepted count forward through EVERY later
        // bucket, including the +Inf one that `observations` is read from. So a
        // trailing zero count is rewritten and the NaN exit is not taken.
        //
        // Checked against the whole corpus: no case has a NaN quantile together
        // with forcedMonotonic or fixedPrecision set.
        var buckets: Buckets = [
            Bucket(upperBound: 1, count: 20), Bucket(upperBound: 2, count: 10),
            Bucket(upperBound: .infinity, count: 0),
        ]
        let (value, fix) = bucketQuantile(0.5, &buckets)
        #expect(fix.forcedMonotonic)
        #expect(!value.isNaN, "observations is 20 after the fix, not 0")
        // Both later buckets were forced, so the range spans up to +Inf and the
        // largest decrease is the 20 the last bucket lost.
        #expect(fix.minBucket == 2)
        #expect(fix.maxBucket == .infinity)
        #expect(fix.maxDiff == 20)
    }

    @Test("an unset monotonicity range is +Inf/-Inf, not zero")
    func unsetRangeIsInverted() {
        // minBucket starts at +Inf and maxBucket at -Inf, so an untouched range is
        // inverted rather than empty. The annotation formats these, so the values
        // are observable.
        var monotone: Buckets = [
            Bucket(upperBound: 1, count: 10), Bucket(upperBound: 2, count: 20),
            Bucket(upperBound: .infinity, count: 20),
        ]
        let (_, fix) = bucketQuantile(0.5, &monotone)
        #expect(!fix.forcedMonotonic)
        #expect(fix.minBucket == .infinity)
        #expect(fix.maxBucket == -.infinity)
        #expect(fix.maxDiff == 0)
    }

    @Test("a tiny decrease is absorbed as precision, not forced")
    func tinyDecreaseIsPrecision() {
        // The two flags mean different things and drive different annotations:
        // fixedPrecision is silent, forcedMonotonic is reported to the user.
        var buckets: Buckets = [
            Bucket(upperBound: 1, count: 100),
            Bucket(upperBound: 2, count: 100 * (1 - 1e-14)),
            Bucket(upperBound: .infinity, count: 200),
        ]
        let fix = ensureMonotonicAndIgnoreSmallDeltas(&buckets, smallDeltaTolerance)
        #expect(fix.fixedPrecision)
        #expect(!fix.forcedMonotonic)
        #expect(buckets[1].count == 100, "carried forward, exactly")
    }

    @Test("prev is not updated by a correction")
    func prevTracksTheAcceptedCount() {
        // quantile.go:690, :697 — both correction branches `continue` WITHOUT
        // updating prev, so the envelope is measured against the last count that
        // was accepted, not the last one seen. Two consecutive decreases therefore
        // both flatten to the original value.
        var buckets: Buckets = [
            Bucket(upperBound: 1, count: 100),
            Bucket(upperBound: 2, count: 50),
            Bucket(upperBound: 3, count: 60),
            Bucket(upperBound: .infinity, count: 200),
        ]
        let fix = ensureMonotonicAndIgnoreSmallDeltas(&buckets, smallDeltaTolerance)
        #expect(fix.forcedMonotonic)
        #expect(buckets[1].count == 100)
        #expect(buckets[2].count == 100, "not 60: prev is still the accepted 100")
        #expect(fix.maxDiff == 50, "the larger of the two decreases")
    }

    @Test("coalesceBuckets merges equal bounds")
    func coalesce() {
        let merged = coalesceBuckets([
            Bucket(upperBound: 1, count: 10), Bucket(upperBound: 1, count: 5),
            Bucket(upperBound: 5, count: 30), Bucket(upperBound: .infinity, count: 30),
        ])
        #expect(merged.count == 3)
        #expect(merged[0].upperBound == 1)
        #expect(merged[0].count == 15)
    }

    @Test("empty buckets are rejected rather than read past")
    func emptyBucketsRejected() {
        // quantile.go:131 indexes buckets[len-1] before any emptiness check and
        // panics; coalesceBuckets would too. No upstream caller can produce an
        // empty set, so this reports the same failure with a clearer message. The
        // corpus excludes it because Go would take the generator down.
        //
        // Asserted by construction: a single-element set is the smallest legal
        // input and still works.
        var single: Buckets = [Bucket(upperBound: .infinity, count: 10)]
        #expect(bucketQuantile(0.5, &single).quantile.isNaN, "len < 2 after coalescing")
    }

    @Test("HistogramQuantile picks its iterator direction by q and Sum")
    func iteratorDirection() {
        // Forward for a NaN Sum or q < 0.5, reverse otherwise (quantile.go:245).
        // The choice is not observable directly, but it changes which rank
        // arithmetic runs, so a symmetric histogram should still agree with itself
        // across the boundary.
        let h = FloatHistogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 0, count: 12, sum: 30,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [4, 4, 4])
        let pos = PositionRange(start: 0, end: 1)
        let below = histogramQuantile(
            0.5.nextDown, h, metricName: "m", pos: pos).0
        let at = histogramQuantile(0.5, h, metricName: "m", pos: pos).0
        // Crossing the boundary must not jump: the two directions have to agree
        // about the same distribution.
        #expect(abs(below - at) < 0.01, "below=\(below) at=\(at)")
    }

    @Test("a NaN Sum with a short bucket total reports the skew")
    func nanSkewAnnotation() {
        // Count exceeds the bucket total, which means real NaN observations; they
        // count as +Inf and so skew the result upward.
        let h = FloatHistogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 0, count: 20, sum: Double.nan,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [4, 5, 3])
        let (_, annos) = histogramQuantile(
            0.5, h, metricName: "m", pos: PositionRange(start: 0, end: 1))
        let (_, infos) = annos.asStrings(query: "m", maxWarnings: 0, maxInfos: 0)
        #expect(infos.contains { $0.contains("skewed higher") })
    }

    @Test("a NaN Sum whose buckets account for everything reports nothing")
    func nanExactNoAnnotation() {
        // Sum is NaN only because the histogram saw -Inf and +Inf, so there is no
        // skew to report.
        let h = FloatHistogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 0, count: 12, sum: Double.nan,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [4, 5, 3])
        let (_, annos) = histogramQuantile(
            0.5, h, metricName: "m", pos: PositionRange(start: 0, end: 1))
        #expect(annos.isEmpty)
    }

    @Test("HistogramFraction divides by Count, not the narrowed count")
    func fractionDenominator() {
        // quantile.go:522 returns (upperRank - lowerRank) / h.Count even when the
        // NaN branch narrowed `count`, which is why histogram_fraction(-Inf, +Inf)
        // can be below 1 for a histogram with NaN observations. Using `count` here
        // would make it exactly 1 and hide the NaNs.
        let h = FloatHistogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 0, count: 20, sum: Double.nan,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [4, 5, 3])
        let (v, annos) = histogramFraction(
            lower: -.infinity, upper: .infinity, h, metricName: "m",
            pos: PositionRange(start: 0, end: 1))
        #expect(v < 1, "12 of 20 observations landed in buckets")
        #expect(!annos.isEmpty, "and the NaNs are reported")
    }

    @Test("quantile over a value list")
    func quantileOverValues() {
        // Unexported in Go, so no fixture; the interpolation is a weighted average
        // of the two straddling samples.
        #expect(quantile(0.5, []).isNaN)
        #expect(quantile(Double.nan, [1, 2]).isNaN)
        #expect(quantile(-0.1, [1, 2]) == -.infinity)
        #expect(quantile(1.1, [1, 2]) == .infinity)

        #expect(quantile(0, [1, 2, 3, 4]) == 1)
        #expect(quantile(1, [1, 2, 3, 4]) == 4)
        #expect(quantile(0.5, [1, 2, 3, 4]) == 2.5, "between the middle pair")
        #expect(quantile(0.5, [1, 2, 3]) == 2, "exactly on a sample")
        // Unsorted input is sorted first.
        #expect(quantile(0.5, [4, 1, 3, 2]) == 2.5)
        #expect(quantile(0.25, [1, 2, 3, 4]) == 1.75)
    }

    @Test("quantile sorts NaNs to the front, with a total order")
    func quantileNaNOrdering() {
        // Go's comparator is `if IsNaN(vi) { return true }; return vi < vj`, which
        // makes NaN compare less than itself — not a strict weak ordering, so Go's
        // sort.Sort is unspecified with two or more NaNs and Swift's sort(by:) may
        // trap on it. This uses a total order with the same intent, so it agrees
        // wherever Go's own answer is defined.
        #expect(quantile(1, [Double.nan, 1, 2]) == 2, "the NaN sorts below")
        #expect(quantile(0, [Double.nan, 1, 2]).isNaN, "and is therefore first")
        // Two NaNs must at least not trap.
        #expect(throws: Never.self) {
            _ = quantile(0.5, [Double.nan, Double.nan, 1, 2])
        }
    }

    @Test("excludedLabels is the bucket label")
    func excluded() {
        #expect(excludedLabels == ["le"])
    }
}
