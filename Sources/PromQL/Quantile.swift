//===----------------------------------------------------------------------===//
// Ported from promql/quantile.go @ v3.13.2
//
// The quantile machinery behind `histogram_quantile`, `histogram_fraction`,
// `quantile` and `quantile_over_time`, for both classic and native histograms.
//
// This is the highest silent-divergence risk in Phase 5. `docs/ROADMAP.md` argues
// for PromQL before TSDB precisely because failures here do not announce
// themselves — a wrong interpolation is a plausible-looking number. Two specific
// traps:
//
//   - The exponential interpolation goes through `math.Log2` and `math.Exp2`.
//     Both are architecture-dependent in Go and both are fused on arm64;
//     `GoMath.log2` and `GoMath.exp2` reproduce them. Swift's libm `exp2`
//     disagrees with Go's on roughly a fifth of probe values, always by one ULP,
//     so using it would have been a silent one-ULP error in every
//     `histogram_quantile` over exponential buckets. See docs/PORTING.md quirk 0.
//   - `BucketQuantile` runs `ensureMonotonicAndIgnoreSmallDeltas` *before* it
//     checks for fewer than two buckets or zero observations, so the monotonicity
//     outputs are populated even on inputs that return NaN.
//
// `quantile(q, values)` is unexported in Go, so the oracle cannot reach it; see
// its own note.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromPosRange
internal import GoCompat
internal import PromMath
internal import PromModel

/// Go's `math.NaN()`, which is **not** `Double.nan`.
///
/// Go builds its NaN from `uvnan = 0x7FF8000000000001` (`math/bits.go`), where
/// Swift's `Double.nan` has a zero payload. Every `math.NaN()` this file returns is
/// observable bit-for-bit through the fixtures, so they all go through this.
/// `PromModel.PromValue.normalNaN` is the same constant, named for its role as the
/// non-stale NaN.
private let goNaN = PromValue.normalNaN

/// Go: `smallDeltaTolerance` — the relative-delta threshold below which a
/// difference between classic buckets is treated as floating-point noise rather
/// than real non-monotonicity.
public let smallDeltaTolerance = 1e-12

/// Go: `excludedLabels` — dropped from the signature when grouping buckets.
public let excludedLabels = [LabelName.bucket]

/// Go: `promql.Bucket` — one bucket of a classic histogram.
public struct Bucket: Sendable, Hashable {
    public var upperBound: Double
    public var count: Double

    public init(upperBound: Double, count: Double) {
        self.upperBound = upperBound
        self.count = count
    }
}

/// Go: `Buckets` — `[]Bucket` with a sort. A plain array here; nothing needs it
/// to carry a protocol conformance, unlike `Vector`/`Matrix`.
public typealias Buckets = [Bucket]

/// Go: the sort in `BucketQuantile`/`BucketFraction` — `slices.SortFunc` on
/// `UpperBound`.
///
/// **Order among equal upper bounds is unspecified**, because `slices.SortFunc` is
/// pdqsort and not stable. That is only observable through `coalesceBuckets`, which
/// sums the counts of equal-bound buckets: two duplicates are safe, since IEEE
/// addition is commutative, but three or more can sum differently under different
/// orders. Nothing upstream produces that, and the corpus deliberately does not
/// either.
func sortBucketsByUpperBound(_ buckets: inout Buckets) {
    buckets.sort { a, b in a.upperBound < b.upperBound }
}

/// The five monotonicity outputs `BucketQuantile` and
/// `ensureMonotonicAndIgnoreSmallDeltas` share.
public struct MonotonicityFix: Sendable, Hashable {
    /// Go: `forcedMonotonic` — a decrease had to be removed.
    public var forcedMonotonic: Bool
    /// Go: `fixedPrecision` — a numerically insignificant difference was ignored.
    public var fixedPrecision: Bool
    /// The lowest upper bound at which monotonicity was forced.
    ///
    /// **Zero, not `+Inf`, before the monotonicity pass has run.** Go declares
    /// these as named return values, so they start at 0, and only
    /// `ensureMonotonicAndIgnoreSmallDeltas` sets the inverted `+Inf`/`-Inf` range
    /// at its own start (quantile.go:678). `BucketQuantile`'s three early exits —
    /// NaN q, q < 0, q > 1 — and its no-`+Inf`-bucket exit therefore all report
    /// 0/0/0, where an exit *after* the pass reports the inverted range.
    public var minBucket: Double
    /// The highest such upper bound. Zero or `-Inf`; see ``minBucket``.
    public var maxBucket: Double
    /// The largest count decrease that was removed.
    public var maxDiff: Double

    init(
        forcedMonotonic: Bool = false, fixedPrecision: Bool = false,
        minBucket: Double = 0, maxBucket: Double = 0, maxDiff: Double = 0
    ) {
        self.forcedMonotonic = forcedMonotonic
        self.fixedPrecision = fixedPrecision
        self.minBucket = minBucket
        self.maxBucket = maxBucket
        self.maxDiff = maxDiff
    }
}

/// Go: `BucketQuantile` — `histogram_quantile` over a classic histogram.
///
/// The buckets are sorted in place, so this takes them `inout` as Go takes a slice
/// it mutates. Cumulative counts are assumed; the highest bucket must be `+Inf`.
///
/// Special cases, in Go's order: NaN `q` gives NaN, `q < 0` gives -Inf, `q > 1`
/// gives +Inf, a highest bucket that is not `+Inf` gives NaN, fewer than two
/// buckets gives NaN, and zero observations gives NaN.
///
/// **Empty buckets trap.** Go indexes `buckets[len(buckets)-1]` before any
/// emptiness check (quantile.go:131) and panics; `coalesceBuckets` would too. No
/// upstream caller can produce an empty set — `histogram_quantile` only builds one
/// from series it found — so this reports the same failure with a clearer message.
public func bucketQuantile(_ q: Double, _ buckets: inout Buckets) -> (
    quantile: Double, fix: MonotonicityFix
) {
    var fix = MonotonicityFix()

    if q.isNaN {
        return (goNaN, fix)
    }
    if q < 0 {
        return (-Double.infinity, fix)
    }
    if q > 1 {
        return (Double.infinity, fix)
    }

    precondition(!buckets.isEmpty, "bucketQuantile: empty buckets; Go indexes past the end")
    sortBucketsByUpperBound(&buckets)

    if buckets[buckets.count - 1].upperBound != Double.infinity {
        return (goNaN, fix)
    }

    buckets = coalesceBuckets(buckets)
    fix = ensureMonotonicAndIgnoreSmallDeltas(&buckets, smallDeltaTolerance)

    // Note the ordering: the two NaN exits below come *after* the monotonicity
    // pass, so `fix` is populated even when the quantile is NaN.
    if buckets.count < 2 {
        return (goNaN, fix)
    }
    let observations = buckets[buckets.count - 1].count
    if observations == 0 {
        return (goNaN, fix)
    }

    var rank = q * observations
    // Go: sort.Search over len-1, so the +Inf bucket is excluded from the search.
    let b = searchFirst(buckets.count - 1) { buckets[$0].count >= rank }

    if b == buckets.count - 1 {
        // The quantile is in the highest bucket, so report the second highest
        // bound rather than +Inf.
        return (buckets[buckets.count - 2].upperBound, fix)
    }
    if b == 0 && buckets[0].upperBound <= 0 {
        return (buckets[0].upperBound, fix)
    }

    var bucketStart = 0.0
    let bucketEnd = buckets[b].upperBound
    var count = buckets[b].count
    if b > 0 {
        bucketStart = buckets[b - 1].upperBound
        count -= buckets[b - 1].count
        // FUSED. quantile.go:165 compiles to a single FNMSUBD: Go does not subtract
        // from the `rank` the binary search used, it recomputes
        // `q*observations - previousCount` as one operation with one rounding. The
        // search above still sees the unfused product. Verified with
        // `go tool objdump -s 'promql\.BucketQuantile'`.
        rank = (-buckets[b - 1].count).addingProduct(q, observations)
    }
    // FUSED. quantile.go:167 compiles to FMADDD.
    return (bucketStart.addingProduct(bucketEnd - bucketStart, rank / count), fix)
}

/// Go: `sort.Search` — the smallest index in `0..<n` satisfying `predicate`, or
/// `n`.
func searchFirst(_ n: Int, _ predicate: (Int) -> Bool) -> Int {
    var low = 0
    var high = n
    while low < high {
        let mid = low + (high - low) / 2
        if predicate(mid) {
            high = mid
        } else {
            low = mid + 1
        }
    }
    return low
}

/// Go: `HistogramQuantile` — `histogram_quantile` over a native histogram.
public func histogramQuantile(
    _ q: Double, _ h: FloatHistogram, metricName: String, pos: PositionRange
) -> (Double, Annotations) {
    if q < 0 {
        return (-Double.infinity, Annotations())
    }
    if q > 1 {
        return (Double.infinity, Annotations())
    }
    if h.count == 0 || q.isNaN {
        return (goNaN, Annotations())
    }

    var annos = Annotations()
    var bucket = PromHistogram.Bucket<Double>(
        lower: 0, upper: 0, lowerInclusive: false, upperInclusive: false, count: 0, index: 0)
    var count = 0.0
    var rank: Double

    // A histogram with NaN observations has a NaN Sum, and NaN observations
    // increase Count without appearing in a bucket — so the forward iterator is
    // required there. Otherwise the direction is chosen to walk the shorter way.
    var forward = h.sum.isNaN || q < 0.5
    var it: AllFloatBucketIterator
    if forward {
        it = h.allBucketIterator()
        rank = q * h.count
    } else {
        it = h.allReverseBucketIterator()
        rank = (1 - q) * h.count
    }

    var sawBucket = false
    while it.next() {
        bucket = it.at()
        sawBucket = true
        if bucket.count == 0 {
            continue
        }
        count += bucket.count
        if count >= rank {
            break
        }
    }
    _ = sawBucket

    if !h.usesCustomBuckets && bucket.lower < 0 && bucket.upper > 0 {
        if h.negativeBuckets.isEmpty && !h.positiveBuckets.isEmpty {
            // In the zero bucket with only positive buckets present, so 0 is the
            // natural lower bound.
            bucket.lower = 0
        } else if h.positiveBuckets.isEmpty && !h.negativeBuckets.isEmpty {
            bucket.upper = 0
        }
    } else if h.usesCustomBuckets {
        if bucket.lower == -Double.infinity {
            // The first bucket, whose lower bound is -Inf.
            if bucket.upper <= 0 {
                return (bucket.upper, annos)
            }
            bucket.lower = 0
        } else if bucket.upper == Double.infinity {
            // The last bucket, whose upper bound is +Inf.
            return (bucket.lower, annos)
        }
    }

    // Numerical inaccuracy can push the running count above the histogram's own,
    // so clamp it.
    if count > h.count {
        count = h.count
    }

    // Reaching the highest bucket without reaching the rank should only happen
    // when the histogram observed NaN, in which case Sum is NaN too.
    // Upstream issue 16578.
    if count < rank {
        if h.sum.isNaN {
            annos.add(newNativeHistogramQuantileNaNResultInfo(metricName, pos))
            return (goNaN, annos)
        }
        // Should not happen: either the NaNs are in the +Inf bucket of an NHCB,
        // in which case count >= rank, or Sum is NaN. A precision problem or a
        // malformed histogram; fall back to the highest explicit upper bound.
        return (bucket.upper, annos)
    }

    if forward {
        rank -= count - bucket.count
    } else {
        rank = count - rank
    }

    // A NaN Sum plus a bucket total below Count means real NaN observations, which
    // skew the result upward because they count as +Inf. If the totals match, the
    // histogram merely saw -Inf and +Inf, which also makes Sum NaN but does not
    // skew anything.
    if h.sum.isNaN {
        while it.next() {
            bucket = it.at()
            count += bucket.count
        }
        if count < h.count {
            annos.add(newNativeHistogramQuantileNaNSkewInfo(metricName, pos))
        }
    }

    // How far into the current bucket the rank falls.
    let fraction = rank / bucket.count

    // Custom buckets, and any quantile landing in the zero bucket, interpolate
    // linearly — the same assumption classic histograms make.
    if h.usesCustomBuckets || (bucket.lower <= 0 && bucket.upper >= 0) {
        // FUSED. quantile.go:337 compiles to FMADDD.
        return (bucket.lower.addingProduct(bucket.upper - bucket.lower, fraction), annos)
    }

    // Exponential buckets interpolate on a logarithmic scale, where the bucket
    // boundaries become evenly spaced, then return to the normal scale.
    //
    // GoMath, not libm: both of these are architecture-dependent and fused in Go.
    let logLower = GoMath.log2(abs(bucket.lower))
    let logUpper = GoMath.log2(abs(bucket.upper))
    if bucket.lower > 0 {
        // FUSED. quantile.go:350 compiles to FMADDD.
        return (GoMath.exp2(logLower.addingProduct(logUpper - logLower, fraction)), annos)
    }
    // A negative bucket, so everything mirrors. FUSED; quantile.go:353.
    return (-GoMath.exp2(logUpper.addingProduct(logLower - logUpper, 1 - fraction)), annos)
}

/// Go: `HistogramFraction` — the fraction of observations in `lower...upper`.
///
/// In a sense the inverse of ``histogramQuantile(_:_:metricName:pos:)``: if that
/// returns 123.4 for q = 0.9, this returns 0.9 for (-Inf, 123.4).
///
/// Inclusivity only matters when a bound coincides with a bucket boundary, and as
/// implemented `lower` is exclusive for positive values and inclusive for negative
/// ones, with `upper` the other way round.
public func histogramFraction(
    lower: Double, upper: Double, _ h: FloatHistogram, metricName: String, pos: PositionRange
) -> (Double, Annotations) {
    if h.count == 0 || lower.isNaN || upper.isNaN {
        return (goNaN, Annotations())
    }
    if lower >= upper {
        return (0, Annotations())
    }

    var count = 0.0
    var rank = 0.0
    var lowerRank = 0.0
    var upperRank = 0.0
    var lowerSet = false
    var upperSet = false
    var it = h.allBucketIterator()
    var annos = Annotations()

    while it.next() {
        var b = it.at()
        count += b.count
        var zeroBucket = false

        // Linear interpolation, used for custom buckets — to stay consistent with
        // classic histograms — and for the zero bucket.
        //
        // An infinite bound cannot be interpolated meaningfully. For a +Inf upper
        // bound the second term is finite/Inf = 0, so no observations from the last
        // bucket count. For a -Inf lower bound it would be Inf/Inf = NaN, so that
        // case returns the cumulative count at the first bucket instead, giving the
        // same "no contribution" effect.
        func interpolateLinearly(_ v: Double) -> Double {
            if b.lower == -Double.infinity {
                return b.count
            }
            return rank + b.count * (v - b.lower) / (b.upper - b.lower)
        }

        // The same exponential method as histogramQuantile, which fits exponential
        // bucketing better.
        func interpolateExponentially(_ v: Double) -> Double {
            let logLower = GoMath.log2(abs(b.lower))
            let logUpper = GoMath.log2(abs(b.upper))
            let logV = GoMath.log2(abs(v))
            var fraction: Double
            if v > 0 {
                fraction = (logV - logLower) / (logUpper - logLower)
            } else {
                fraction = 1 - ((logV - logUpper) / (logLower - logUpper))
            }
            // FUSED. quantile.go:447 compiles to FMADDD. Its sibling
            // interpolateLinearly above is NOT fused, because the divide sits
            // between the multiply and the add; nor is anything in
            // bucketFraction. Verified per function with `go tool objdump`.
            return rank.addingProduct(b.count, fraction)
        }

        if b.lower <= 0 && b.upper >= 0 {
            zeroBucket = true
            if h.negativeBuckets.isEmpty && !h.positiveBuckets.isEmpty {
                b.lower = 0
            } else if h.positiveBuckets.isEmpty && !h.negativeBuckets.isEmpty {
                b.upper = 0
            }
        }
        if !lowerSet && b.lower >= lower {
            lowerRank = rank
            lowerSet = true
        }
        if !upperSet && b.lower >= upper {
            upperRank = rank
            upperSet = true
        }
        if lowerSet && upperSet {
            break
        }
        if !lowerSet && b.lower < lower && b.upper > lower {
            if h.usesCustomBuckets || zeroBucket {
                lowerRank = interpolateLinearly(lower)
            } else {
                lowerRank = interpolateExponentially(lower)
            }
            lowerSet = true
        }
        if !upperSet && b.lower < upper && b.upper > upper {
            if h.usesCustomBuckets || zeroBucket {
                upperRank = interpolateLinearly(upper)
            } else {
                upperRank = interpolateExponentially(upper)
            }
            upperSet = true
        }
        if lowerSet && upperSet {
            break
        }
        rank += b.count
    }

    if h.sum.isNaN {
        // There may be NaN observations, so the count has to be narrowed to the
        // ones that actually landed in buckets.
        while it.next() {
            let b = it.at()
            count += b.count
        }
        if count < h.count {
            annos.add(newNativeHistogramFractionNaNsInfo(metricName, pos))
        }
    } else {
        count = h.count
    }

    if !lowerSet || lowerRank > count {
        lowerRank = count
    }
    if !upperSet || upperRank > count {
        upperRank = count
    }

    // Note the denominator is h.count, not the possibly narrowed `count`.
    return ((upperRank - lowerRank) / h.count, annos)
}

/// Go: `BucketFraction` — `HistogramFraction` for classic histograms.
///
/// Traps on empty buckets, as ``bucketQuantile(_:_:)`` does and for the same
/// reason.
public func bucketFraction(lower: Double, upper: Double, _ buckets: inout Buckets) -> Double {
    precondition(!buckets.isEmpty, "bucketFraction: empty buckets; Go indexes past the end")
    sortBucketsByUpperBound(&buckets)
    if buckets[buckets.count - 1].upperBound != Double.infinity {
        return goNaN
    }
    buckets = coalesceBuckets(buckets)

    let count = buckets[buckets.count - 1].count
    if count == 0 || lower.isNaN || upper.isNaN {
        return goNaN
    }
    if lower >= upper {
        return 0
    }

    var rank = 0.0
    var lowerRank = 0.0
    var upperRank = 0.0
    var lowerSet = false
    var upperSet = false

    // If the first bucket's upper bound is above 0 the buckets are taken to be
    // positive-only, so the first lower bound is 0; otherwise it is -Inf.
    var lowerBound = 0.0
    if buckets[0].upperBound <= 0 {
        lowerBound = -Double.infinity
    }

    for (i, b) in buckets.enumerated() {
        if i > 0 {
            lowerBound = buckets[i - 1].upperBound
        }
        let upperBound = b.upperBound

        // As the histogram version, except the counts here are cumulative, so the
        // per-bucket weight is `b.count - rank` rather than `b.count`.
        func interpolateLinearly(_ v: Double) -> Double {
            if lowerBound == -Double.infinity {
                return b.count
            }
            return rank + (b.count - rank) * (v - lowerBound) / (upperBound - lowerBound)
        }

        if !lowerSet && lowerBound >= lower {
            lowerRank = rank
            lowerSet = true
        }
        if !upperSet && lowerBound >= upper {
            upperRank = rank
            upperSet = true
        }
        if lowerSet && upperSet {
            break
        }
        if !lowerSet && lowerBound < lower && upperBound > lower {
            lowerRank = interpolateLinearly(lower)
            lowerSet = true
        }
        if !upperSet && lowerBound < upper && upperBound > upper {
            upperRank = interpolateLinearly(upper)
            upperSet = true
        }
        if lowerSet && upperSet {
            break
        }
        // Assignment, not accumulation: classic bucket counts are cumulative.
        rank = b.count
    }
    if !lowerSet || lowerRank > count {
        lowerRank = count
    }
    if !upperSet || upperRank > count {
        upperRank = count
    }

    return (upperRank - lowerRank) / count
}

/// Go: `coalesceBuckets` — merges buckets sharing an upper bound. Input must be
/// sorted.
func coalesceBuckets(_ buckets: Buckets) -> Buckets {
    var buckets = buckets
    var last = buckets[0]
    var i = 0
    for b in buckets[1...] {
        if b.upperBound == last.upperBound {
            last.count += b.count
        } else {
            buckets[i] = last
            last = b
            i += 1
        }
    }
    buckets[i] = last
    return Array(buckets[0...i])
}

/// Go: `ensureMonotonicAndIgnoreSmallDeltas`.
///
/// Classic bucket counts are meant to increase with the upper bound, and
/// `bucketQuantile`'s binary search depends on it. Real data breaks that — an
/// inconsistent target, remote write, precision loss, or a downstream system
/// trading precision for speed — so this first silently absorbs differences small
/// enough to be floating-point noise (in *either* direction), then removes any
/// remaining decrease by carrying the previous count forward.
///
/// Note `prev` is deliberately **not** updated in either correction branch: the
/// envelope is measured against the last count that was accepted, not the last one
/// seen.
func ensureMonotonicAndIgnoreSmallDeltas(
    _ buckets: inout Buckets, _ tolerance: Double
) -> MonotonicityFix {
    // quantile.go:678 — the range starts inverted so the first forced bucket sets
    // both ends. Done here, not in the initialiser, because BucketQuantile's early
    // exits must report zeros.
    var fix = MonotonicityFix(minBucket: .infinity, maxBucket: -.infinity)
    var prev = buckets[0].count
    for i in 1..<buckets.count {
        let curr = buckets[i].count  // Assumed always positive.
        if curr == prev {
            continue
        }
        if Almost.equal(prev, curr, tolerance) {
            // Numerically insignificant, so absorb it regardless of direction.
            buckets[i].count = prev
            fix.fixedPrecision = true
            continue
        }
        if curr < prev {
            buckets[i].count = prev
            fix.forcedMonotonic = true
            if buckets[i].upperBound < fix.minBucket {
                fix.minBucket = buckets[i].upperBound
            }
            if buckets[i].upperBound > fix.maxBucket {
                fix.maxBucket = buckets[i].upperBound
            }
            let diff = prev - curr
            if diff > fix.maxDiff {
                fix.maxDiff = diff
            }
            continue
        }
        prev = curr
    }
    return fix
}

/// Go: `quantile` — the φ-quantile of a set of sample values, used by the
/// `quantile` aggregator and `quantile_over_time`.
///
/// Unexported in Go, so the oracle cannot call it directly — but it is reachable
/// *through* `quantile_over_time` and `mad_over_time`, and
/// `Fixtures/promql/functions-overtime.jsonl` is what pins it. Before those existed
/// this function's two fused sites were both wrong and nothing said so.
///
/// **Go's comparator is not a strict weak ordering.** `vectorByValueHeap.Less` is
/// `if IsNaN(vi) { return true }; return vi < vj` (functions.go:2690), so NaN
/// compares less than *everything including itself*. With two or more NaNs Go's
/// `sort.Sort` result is unspecified, and Swift's `sort(by:)` may trap on such a
/// predicate. This uses a total order with the same intent — NaNs first — which
/// agrees with Go wherever Go's own answer is defined.
public func quantile(_ q: Double, _ values: [Double]) -> Double {
    if values.isEmpty || q.isNaN {
        return goNaN
    }
    if q < 0 {
        return -Double.infinity
    }
    if q > 1 {
        return Double.infinity
    }
    var values = values
    values.sort { a, b in
        if a.isNaN { return !b.isNaN }
        if b.isNaN { return false }
        return a < b
    }

    let n = Double(values.count)
    // Between two samples the result is a weighted average of the pair.
    let rank = q * (n - 1)

    // `math.Max`/`math.Min`, which are arm64 assembly — see PORTING.md quirk 28.
    // Both operands are finite here (a NaN `q` returned above), so the NaN
    // semantics do not arise; spelled as Go spells it regardless.
    let lowerIndex = GoMath.max(0, rank.rounded(.down))
    let upperIndex = GoMath.min(n - 1, lowerIndex + 1)

    // Go writes `weight := rank - math.Floor(rank)` and the compiler emits a single
    // `FNMSUBD` (quantile.go:743) that recomputes `q*(n-1)` **unrounded** — the same
    // pattern as `xatan`'s `z + Q0` and `sinh`'s `sq + Q2`, PORTING.md quirk 40. The
    // rounded `rank` above is still what `Floor` reads.
    let weight = (-rank.rounded(.down)).addingProduct(q, n - 1)
    let lower = values[Int(lowerIndex)]
    let upper = values[Int(upperIndex)]
    // And the second product is fused into the add (`FMADDD` at quantile.go:744)
    // while the first is a plain multiply. This was untested until
    // `quantile_over_time` reached it, and the port had both roundings wrong — 12 of
    // 1,480 cases.
    return (lower * (1 - weight)).addingProduct(upper, weight)
}
