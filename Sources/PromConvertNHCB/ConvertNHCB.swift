//===----------------------------------------------------------------------===//
// Ported from util/convertnhcb/convertnhcb.go @ v3.13.2
//
// Classic histogram samples in, one native histogram with custom buckets (an **NHCB**) out. This is
// the direction `PromHistogram.convertNHCBToClassic` does not go, and it is what
// `promqltest`'s `load_with_nhcb` needs — ~195 of the exit gate's assertions, measured rather than
// guessed (HANDOFF §5e).
//
// ## Cumulative in, delta out, and integer-or-float decided at the end
//
// The input is a set of `le` boundaries with **cumulative** counts, added incrementally by
// `setBucketCount`. `convert()` then decides between an integer and a float histogram by asking
// whether *every* count, and the overall count, is exactly an integer — so a single fractional
// bucket makes the whole thing a `FloatHistogram`. That decision is made **after** the `+Inf`
// bucket is synthesised, so a fractional overall count can force the float path on its own.
//
// The integer path emits **double deltas** (`delta - prevDelta`), which is `Histogram`'s bucket
// encoding, and the float path emits plain deltas. Both then `Compact` — but with **different
// arguments**: `Compact(2)` for the integer histogram and `Compact(0)` for the float one. That
// asymmetry is upstream's and it is observable: a classic histogram with two adjacent empty buckets
// compacts in the integer path and not in the float one.
//
// ## `CustomValues` drops the last boundary, and the array is sized for that
//
// `len(buckets) - 1` values for `len(buckets)` buckets: the final `+Inf` is implied by the schema
// rather than stored. Note the loop writes `CustomValues[i]` for every non-`+Inf` bucket, so if a
// `+Inf` bucket is *not* last — which `setBucketCount`'s ordering prevents — it would write out of
// bounds. Upstream relies on the ordering; so does this.
//
// ## The count mismatch is checked AFTER the histogram is built
//
// Both paths construct the whole result, then compare the overall count against the last bucket's
// and return the error instead. Reordering it would be tidier and would change nothing observable —
// but it also means the error is reachable only when a `count` was set explicitly *and* disagrees
// with the `+Inf` bucket, since otherwise `convert()` derives one from the other.
//
// ## `setBucketCount` is written for in-order input but handles out-of-order
//
// Three fast paths — first bucket, strictly increasing, exact duplicate — then a binary search and
// an insert. The out-of-order path checks cumulativity against **both** neighbours, where the
// in-order path checks only the predecessor. A duplicate `le` is *ignored* rather than an error, in
// both paths, because a classic histogram scrape can legitimately repeat one.
//===----------------------------------------------------------------------===//

public import PromHistogram
public import PromLabels

internal import GoCompat
internal import PromModel

/// Go: the five package-level error values, whose text reaches the user through `promqltest` and
/// (in Phase 8) the scrape loop.
public enum ConvertNHCBError: Error, CustomStringConvertible, Equatable, Sendable {
    case negativeBucketCount(le: Double, count: Double)
    case naNBucket
    case negativeCount(Double)
    case countMismatch(count: String, le: Double, bucketCount: Double)
    /// Go: `errCountNotCumulative` with `"%g < %g"` — the count is below a PREDECESSOR's.
    case countNotCumulative(Double, Double)
    /// Go: the SAME sentinel with `"%g > %g"` — the count is above a SUCCESSOR's, which only the
    /// out-of-order insert can detect. One error value, **two format strings**, and the corpus
    /// caught the port using one for both.
    case countNotCumulativeAbove(Double, Double)

    public var description: String {
        switch self {
        case .negativeBucketCount(let le, let count):
            return
                "bucket count must be non-negative: le=\(GoFmt.g(le)), count=\(GoFmt.g(count))"
        case .naNBucket:
            return "bucket boundary must not be NaN"
        case .negativeCount(let c):
            return "count must be non-negative: count=\(GoFmt.g(c))"
        case .countMismatch(let count, let le, let bucketCount):
            return
                "count mismatch: count=\(count) != le=\(GoFmt.g(le)) count=\(GoFmt.g(bucketCount))"
        case .countNotCumulative(let a, let b):
            return "count is not cumulative: \(GoFmt.g(a)) < \(GoFmt.g(b))"
        case .countNotCumulativeAbove(let a, let b):
            return "count is not cumulative: \(GoFmt.g(a)) > \(GoFmt.g(b))"
        }
    }
}

/// `%g` on a `float64`, which is Go's shortest form and **not** `Double.description` (ADR-4).
enum GoFmt {
    static func g(_ v: Double) -> String { GoFloat.formatG(v) }
}

/// Go: `tempHistogramBucket`.
struct TempHistogramBucket: Equatable, Sendable {
    var le: Double
    var count: Double
}

/// Go: `TempHistogram` — classic bucket samples collected before a histogram exists.
public struct TempHistogram: Sendable {
    var buckets: [TempHistogramBucket] = []
    var count: Double = 0
    var sum: Double = 0
    /// Go: `err` — **sticky**. Once set, every setter returns it without doing anything, so the
    /// first failure is the one reported however many samples follow.
    var error: (any Error)? = nil
    var hasCount = false

    /// Go: `NewTempHistogram`.
    public init() {
        buckets.reserveCapacity(10)
    }

    /// Go: `Err`.
    public var err: (any Error)? { error }

    /// Go: `Reset` — keeps the bucket array's capacity, which is the point of reusing the value.
    public mutating func reset() {
        buckets.removeAll(keepingCapacity: true)
        count = 0
        sum = 0
        error = nil
        hasCount = false
    }

    /// Go: `SetBucketCount`.
    ///
    /// Written for in-order input, with a binary-search insert for the rest. A duplicate `le` is
    /// **ignored**, not an error — a scrape can legitimately repeat one.
    @discardableResult
    public mutating func setBucketCount(_ boundary: Double, _ count: Double) -> (any Error)? {
        if let error { return error }
        if boundary.isNaN {
            error = ConvertNHCBError.naNBucket
            return error
        }
        if count < 0 {
            error = ConvertNHCBError.negativeBucketCount(le: boundary, count: count)
            return error
        }

        if buckets.isEmpty {
            buckets.append(TempHistogramBucket(le: boundary, count: count))
            return nil
        }
        let last = buckets[buckets.count - 1]
        if last.le < boundary {
            // The happy case.
            if count < last.count {
                error = ConvertNHCBError.countNotCumulative(count, last.count)
                return error
            }
            buckets.append(TempHistogramBucket(le: boundary, count: count))
            return nil
        }
        if last.le == boundary {
            // A duplicate sample; ignored.
            return nil
        }

        // Out of order: find where it belongs and check cumulativity against BOTH neighbours,
        // where the in-order path only has a predecessor to check.
        let i = goSortSearchNHCB(buckets.count) { buckets[$0].le >= boundary }
        if buckets[i].le == boundary {
            return nil
        }
        if i > 0 && count < buckets[i - 1].count {
            error = ConvertNHCBError.countNotCumulative(count, buckets[i - 1].count)
            return error
        }
        if count > buckets[i].count {
            error = ConvertNHCBError.countNotCumulativeAbove(count, buckets[i].count)
            return error
        }
        buckets.insert(TempHistogramBucket(le: boundary, count: count), at: i)
        return nil
    }

    /// Go: `SetCount`.
    @discardableResult
    public mutating func setCount(_ count: Double) -> (any Error)? {
        if let error { return error }
        if count < 0 {
            error = ConvertNHCBError.negativeCount(count)
            return error
        }
        self.count = count
        hasCount = true
        return nil
    }

    /// Go: `SetSum` — no validation at all; a negative or NaN sum is legal.
    @discardableResult
    public mutating func setSum(_ sum: Double) -> (any Error)? {
        if let error { return error }
        self.sum = sum
        return nil
    }

    /// Go: `Convert` — exactly one of the two results is non-nil.
    ///
    /// The integer/float decision is made **after** the `+Inf` bucket is synthesised, so a
    /// fractional overall count forces the float path even when every bucket is integral.
    public func convert() -> (
        integer: Histogram?, float: FloatHistogram?, error: (any Error)?
    ) {
        if let error { return (nil, nil, error) }
        var h = self

        if !h.hasCount && !h.buckets.isEmpty {
            // No explicit count: take the highest bucket's, which is the cumulative total.
            h.count = h.buckets[h.buckets.count - 1].count
            h.hasCount = true
        }

        if h.buckets.isEmpty || h.buckets[h.buckets.count - 1].le != Double.infinity {
            // Synthesise the `+Inf` bucket with the overall count.
            h.buckets.append(TempHistogramBucket(le: Double.infinity, count: h.count))
        }

        for b in h.buckets {
            let intCount = Int64(exactly: b.count.rounded()) ?? Int64.max
            if b.count != Double(intCount) {
                return h.convertToFloatHistogram()
            }
        }
        let intCount = UInt64(exactly: h.count.rounded()) ?? UInt64.max
        if h.count != Double(intCount) {
            return h.convertToFloatHistogram()
        }
        return h.convertToIntegerHistogram(intCount)
    }

    /// Go: `convertToIntegerHistogram` — **double** deltas, and `Compact(2)`.
    private func convertToIntegerHistogram(_ count: UInt64) -> (
        Histogram?, FloatHistogram?, (any Error)?
    ) {
        var rh = Histogram(
            schema: HistogramSchema.customBuckets, count: count, sum: sum,
            positiveSpans: [Span(offset: 0, length: UInt32(buckets.count))],
            positiveBuckets: [Int64](repeating: 0, count: buckets.count))
        // One fewer than the buckets: the final `+Inf` is implied by the schema.
        if buckets.count > 1 {
            rh.customValues = [Double](repeating: 0, count: buckets.count - 1)
        }

        var prevCount: Int64 = 0
        var prevDelta: Int64 = 0
        for (i, b) in buckets.enumerated() {
            // The input is cumulative, so the bucket's own count is the difference — and then the
            // encoding stores the difference of *those*.
            let delta = Int64(b.count) - prevCount
            rh.positiveBuckets[i] = delta - prevDelta
            prevCount = Int64(b.count)
            prevDelta = delta
            if b.le != Double.infinity {
                rh.customValues![i] = b.le
            }
        }

        // Checked after the histogram is built, which is upstream's order.
        if count != UInt64(buckets[buckets.count - 1].count) {
            return (
                nil, nil,
                ConvertNHCBError.countMismatch(
                    count: String(count), le: buckets[buckets.count - 1].le,
                    bucketCount: buckets[buckets.count - 1].count)
            )
        }
        return (rh.compact(maxEmptyBuckets: 2), nil, nil)
    }

    /// Go: `convertToFloatHistogram` — plain deltas, and `Compact(0)`.
    ///
    /// The differing `Compact` argument is not a slip: two adjacent empty buckets survive here and
    /// are merged in the integer path.
    private func convertToFloatHistogram() -> (Histogram?, FloatHistogram?, (any Error)?) {
        var rh = FloatHistogram(
            schema: HistogramSchema.customBuckets, count: count, sum: sum,
            positiveSpans: [Span(offset: 0, length: UInt32(buckets.count))],
            positiveBuckets: [Double](repeating: 0, count: buckets.count))
        if buckets.count > 1 {
            rh.customValues = [Double](repeating: 0, count: buckets.count - 1)
        }

        var prevCount = 0.0
        for (i, b) in buckets.enumerated() {
            rh.positiveBuckets[i] = b.count - prevCount
            prevCount = b.count
            if b.le != Double.infinity {
                rh.customValues![i] = b.le
            }
        }

        if count != buckets[buckets.count - 1].count {
            return (
                nil, nil,
                ConvertNHCBError.countMismatch(
                    count: GoFmt.g(count), le: buckets[buckets.count - 1].le,
                    bucketCount: buckets[buckets.count - 1].count)
            )
        }
        return (nil, rh.compact(maxEmptyBuckets: 0), nil)
    }
}

/// Go: `GetHistogramMetricBase` — the series a classic histogram's parts belong to.
///
/// Sets `__name__` to the base name and **deletes `le`**, so all of `foo_bucket{le=…}`, `foo_sum`
/// and `foo_count` map to one identity.
public func getHistogramMetricBase(_ m: Labels, _ name: String) -> Labels {
    var b = LabelsBuilder(m)
    b.set(LabelName.metricName, name)
    // Go: `labels.BucketLabel`, which is `"le"`.
    b.del(["le"])
    return b.labels()
}

/// Go: `SuffixType`.
public enum HistogramSuffix: Sendable, Equatable {
    case none
    case bucket
    case sum
    case count
}

/// Go: `GetHistogramMetricBaseName` — strip one of the three suffixes.
///
/// Tested in that order, so `foo_bucket_sum` loses `_sum`. `_created` is deliberately **not**
/// stripped: upstream's comment says the caller owns that.
public func getHistogramMetricBaseName(_ s: String) -> (HistogramSuffix, String) {
    if s.hasSuffix("_bucket") { return (.bucket, String(s.dropLast(7))) }
    if s.hasSuffix("_sum") { return (.sum, String(s.dropLast(4))) }
    if s.hasSuffix("_count") { return (.count, String(s.dropLast(6))) }
    return (.none, s)
}

/// Go: `sort.Search`.
func goSortSearchNHCB(_ n: Int, _ f: (Int) -> Bool) -> Int {
    var i = 0
    var j = n
    while i < j {
        let h = Int(UInt(i + j) >> 1)
        if !f(h) {
            i = h + 1
        } else {
            j = h
        }
    }
    return i
}
