//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — the storage layout
// and the read-only surface: copying, rendering, equality, validation and the
// iterator factories.
//
// The arithmetic (Mul/Div/Add/Sub/KahanAdd), DetectReset, ReduceResolution, the
// NHCB reconciliation and TrimBuckets arrive in the following slices — see
// docs/HANDOFF.md §5b.
//
// `customValues` is `[Double]?` for the same reason as `Histogram`'s:
// float_histogram.go:966 tests it against nil, so an empty non-nil slice is an
// error there and nil is not. See docs/PORTING.md "Replicated Go quirks".
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `FloatHistogram` — like `Histogram`, but every count is a `Double` and
/// the bucket counts are absolute rather than deltas.
///
/// PromQL needs this because its operations can produce fractional counts. Since
/// counts are unlikely to be too large for a `Double` to hold exactly, this also
/// serves as the more general representation of an integer histogram.
///
/// Deliberately not `Equatable`: `equals(_:)` is data equality over bit
/// patterns, and it treats different span layouts describing the same buckets as
/// equal.
public struct FloatHistogram: Sendable {
    /// Counter reset information.
    public var counterResetHint: CounterResetHint
    /// `-4 <= n <= 8` for exponential buckets, or `-53` for custom buckets.
    public var schema: Int32
    /// Width of the zero bucket.
    public var zeroThreshold: Double
    /// Observations falling into the zero bucket. Must be zero or positive.
    public var zeroCount: Double
    /// Total number of observations. Must be zero or positive.
    public var count: Double
    /// Sum of observations. Also used as the stale marker.
    public var sum: Double
    /// Spans for positive and negative buckets.
    public var positiveSpans: [Span]
    public var negativeSpans: [Span]
    /// Observation counts in buckets. Each is an absolute count and must be zero
    /// or positive — unlike `Histogram`, these are not deltas.
    public var positiveBuckets: [Double]
    public var negativeBuckets: [Double]
    /// The custom (usually upper) bounds, otherwise nil. Interned upstream, to be
    /// treated as immutable. Strictly increasing. Only used when the schema is for
    /// custom buckets, in which case `zeroThreshold`, `zeroCount`,
    /// `negativeSpans` and `negativeBuckets` are unused.
    public var customValues: [Double]?

    public init(
        counterResetHint: CounterResetHint = .unknownCounterReset,
        schema: Int32 = 0,
        zeroThreshold: Double = 0,
        zeroCount: Double = 0,
        count: Double = 0,
        sum: Double = 0,
        positiveSpans: [Span] = [],
        negativeSpans: [Span] = [],
        positiveBuckets: [Double] = [],
        negativeBuckets: [Double] = [],
        customValues: [Double]? = nil
    ) {
        self.counterResetHint = counterResetHint
        self.schema = schema
        self.zeroThreshold = zeroThreshold
        self.zeroCount = zeroCount
        self.count = count
        self.sum = sum
        self.positiveSpans = positiveSpans
        self.negativeSpans = negativeSpans
        self.positiveBuckets = positiveBuckets
        self.negativeBuckets = negativeBuckets
        self.customValues = customValues
    }

    /// Go: `UsesCustomBuckets`.
    public var usesCustomBuckets: Bool { isCustomBucketsSchema(schema) }

    // MARK: - Copying

    /// Go: `Copy` — a deep copy. Fields the schema does not use are dropped.
    public func copy() -> FloatHistogram {
        var c = FloatHistogram(
            counterResetHint: counterResetHint, schema: schema, count: count, sum: sum)

        if usesCustomBuckets {
            // Custom values are interned, so no need to copy them.
            c.customValues = customValues
        } else {
            c.zeroThreshold = zeroThreshold
            c.zeroCount = zeroCount
            c.negativeSpans = negativeSpans
            c.negativeBuckets = negativeBuckets
        }

        c.positiveSpans = positiveSpans
        c.positiveBuckets = positiveBuckets

        return c
    }

    /// Go: `CopyTo` — a deep copy into an existing histogram, reusing its
    /// storage. Every field is written, so the destination's prior contents
    /// cannot leak through; the parameter is kept because ported call sites
    /// depend on the destination being updated in place (PORTING.md exception 4).
    public func copy(to destination: inout FloatHistogram) {
        destination.counterResetHint = counterResetHint
        destination.schema = schema
        destination.count = count
        destination.sum = sum

        if usesCustomBuckets {
            destination.zeroThreshold = 0
            destination.zeroCount = 0

            destination.negativeSpans = []
            destination.negativeBuckets = []
            // Custom values are interned, so no need to copy them.
            destination.customValues = customValues
        } else {
            destination.zeroThreshold = zeroThreshold
            destination.zeroCount = zeroCount

            destination.negativeSpans = negativeSpans
            destination.negativeBuckets = negativeBuckets
            // Custom values are interned, so no need to reset them.
            destination.customValues = nil
        }

        destination.positiveSpans = positiveSpans
        destination.positiveBuckets = positiveBuckets
    }

    /// Go: `CopyToSchema` — like `copy()`, but the result has `targetSchema`,
    /// which must be ≤ the current schema. Traps on a custom-buckets schema
    /// either side.
    ///
    /// Note that only the fast path preserves `counterResetHint`: Go builds the
    /// result with a struct literal that omits it, so a real reduction resets the
    /// hint to `unknownCounterReset` and drops `customValues`. Replicated.
    public func copyToSchema(_ targetSchema: Int32) -> FloatHistogram {
        if targetSchema == schema {
            // Fast path.
            return copy()
        }
        if usesCustomBuckets {
            preconditionFailure(
                "cannot reduce resolution to \(targetSchema) when there are custom buckets")
        }
        if isCustomBucketsSchema(targetSchema) {
            preconditionFailure("cannot reduce resolution to custom buckets schema")
        }
        if targetSchema > schema {
            preconditionFailure("cannot copy from schema \(schema) to \(targetSchema)")
        }
        var c = FloatHistogram(
            schema: targetSchema,
            zeroThreshold: zeroThreshold,
            zeroCount: zeroCount,
            count: count,
            sum: sum)

        (c.positiveSpans, c.positiveBuckets) = mustReduceResolution(
            originSpans: positiveSpans, originBuckets: positiveBuckets,
            originSchema: schema, targetSchema: targetSchema, deltaBuckets: false)
        (c.negativeSpans, c.negativeBuckets) = mustReduceResolution(
            originSpans: negativeSpans, originBuckets: negativeBuckets,
            originSchema: schema, targetSchema: targetSchema, deltaBuckets: false)

        return c
    }

    // MARK: - Rendering

    /// Go: `ZeroBucket`. Traps if the schema is for custom buckets.
    public func zeroBucket() -> Bucket<Double> {
        if usesCustomBuckets {
            preconditionFailure("histograms with custom buckets have no zero bucket")
        }
        return Bucket(
            lower: -zeroThreshold, upper: zeroThreshold,
            lowerInclusive: true, upperInclusive: true,
            // Index is irrelevant for the zero bucket.
            count: zeroCount, index: 0)
    }

    /// Go: `TestExpression` — the representation used by the PromQL testing
    /// framework and by promtool rules unit tests, e.g.
    /// `{{schema:0 count:4 sum:5 buckets:[1 2 1]}}`.
    ///
    /// This has to round-trip with the PromQL parser in Phase 4, because the
    /// conformance `.test` files are written in it.
    ///
    /// Traps for a histogram with more than one span per side, as Go does — the
    /// caller is expected to have compacted, which this does itself first.
    public func testExpression() -> String {
        var res = [String]()
        var m = copy()

        // Compact to reduce the number of positive and negative spans to 1.
        m.compact(maxEmptyBuckets: Int.max)

        if m.schema != 0 {
            res.append("schema:\(m.schema)")
        }
        if m.count != 0 {
            res.append("count:\(GoFloat.formatG(m.count))")
        }
        if m.sum != 0 {
            res.append("sum:\(GoFloat.formatG(m.sum))")
        }
        if m.zeroCount != 0 {
            res.append("z_bucket:\(GoFloat.formatG(m.zeroCount))")
        }
        if m.zeroThreshold != 0 {
            res.append("z_bucket_w:\(GoFloat.formatG(m.zeroThreshold))")
        }
        if m.usesCustomBuckets {
            // Go applies %g to the whole []float64, which prints as a
            // space-separated list in brackets.
            let values = (m.customValues ?? []).map(GoFloat.formatG).joined(separator: " ")
            res.append("custom_values:[\(values)]")
        }

        switch m.counterResetHint {
        case .unknownCounterReset:
            // Unknown is the default; don't add anything.
            break
        case .counterReset:
            res.append("counter_reset_hint:reset")
        case .notCounterReset:
            res.append("counter_reset_hint:not_reset")
        case .gaugeType:
            res.append("counter_reset_hint:gauge")
        }

        func addBuckets(
            _ kind: String, _ bucketsKey: String, _ offsetKey: String,
            _ buckets: [Double], _ spans: [Span]
        ) {
            if spans.count > 1 {
                preconditionFailure("histogram with multiple \(kind) spans not supported")
            }
            for span in spans where span.offset != 0 {
                res.append("\(offsetKey):\(span.offset)")
            }
            if !buckets.isEmpty {
                let bucketStr = buckets.map(GoFloat.formatG).joined(separator: " ")
                res.append("\(bucketsKey):[\(bucketStr)]")
            }
        }
        addBuckets("positive", "buckets", "offset", m.positiveBuckets, m.positiveSpans)
        addBuckets("negative", "n_buckets", "n_offset", m.negativeBuckets, m.negativeSpans)
        return "{{" + res.joined(separator: " ") + "}}"
    }

    // MARK: - Equality

    /// Go: `Equals` — true if the given float histogram matches exactly.
    ///
    /// An exact match means no new buckets (even empty ones), no missing buckets,
    /// and every bucket value equal. Spans may differ in where they place empty
    /// zero-length spans, as long as they describe the same layout. `sum`,
    /// `count`, `zeroCount` and the bucket values are compared by **bit
    /// pattern**: this is data equality, not mathematical equality. Note that
    /// `zeroThreshold` is *not* — Go compares it with `!=`, so a NaN threshold
    /// never equals itself there.
    public func equals(_ other: FloatHistogram) -> Bool {
        if schema != other.schema
            || count.bitPattern != other.count.bitPattern
            || sum.bitPattern != other.sum.bitPattern
        {
            return false
        }

        if usesCustomBuckets {
            if !customBucketBoundsMatch(customValues ?? [], other.customValues ?? []) {
                return false
            }
        }

        if zeroThreshold != other.zeroThreshold
            || zeroCount.bitPattern != other.zeroCount.bitPattern
        {
            return false
        }

        if !spansMatch(negativeSpans, other.negativeSpans) { return false }
        if !floatBucketsMatch(negativeBuckets, other.negativeBuckets) { return false }

        if !spansMatch(positiveSpans, other.positiveSpans) { return false }
        if !floatBucketsMatch(positiveBuckets, other.positiveBuckets) { return false }

        return true
    }

    /// Go: `Size` — the total size in bytes, including the pointer to the
    /// histogram, all its fields, and every element of its slices.
    ///
    /// This reports **Go's** 64-bit layout, not Swift's: callers use it as a
    /// stable memory-accounting number, so reporting Swift's own struct size
    /// would change TSDB accounting decisions rather than fix anything.
    public var size: Int {
        // 8 bytes per span (int32 + uint32) and per bucket or bound (float64).
        let posSpanSize = positiveSpans.count * 8
        let negSpanSize = negativeSpans.count * 8
        let posBucketSize = positiveBuckets.count * 8
        let negBucketSize = negativeBuckets.count * 8
        let customBoundSize = (customValues ?? []).count * 8

        // 8 for the pointer, 4 for CounterResetHint (1 byte + 3 padding), 4 for
        // Schema, 8 each for ZeroThreshold/ZeroCount/Count/Sum, and 24 for each
        // of the five slice headers.
        let structSize = 168

        return structSize + posSpanSize + negSpanSize + posBucketSize + negBucketSize
            + customBoundSize
    }

    /// Go: `HasOverflow` — whether any field holds an infinity, which can happen
    /// when aggregating enough histograms to exceed `Double`'s range.
    public var hasOverflow: Bool {
        if zeroCount.isInfinite || count.isInfinite || sum.isInfinite { return true }
        for v in positiveBuckets where v.isInfinite { return true }
        for v in negativeBuckets where v.isInfinite { return true }
        for v in customValues ?? [] where v.isInfinite { return true }
        return false
    }

    // MARK: - Operations

    /// Go: `Compact` — eliminates empty buckets at the beginning and end of each
    /// span, merges spans that are consecutive or at most `maxEmptyBuckets`
    /// apart, and splits spans containing more than `maxEmptyBuckets` consecutive
    /// empty buckets.
    ///
    /// The ideal `maxEmptyBuckets` depends on circumstances, and the tradeoffs
    /// are subtle: an extra `Span` and an extra bucket both cost 8 bytes, so with
    /// a single separating empty bucket the two layouts tie on storage and the
    /// single span is easier to iterate. In a TSDB chunk the span layout is
    /// stored once per chunk while the buckets are stored per histogram, which
    /// pushes the other way. The safe default is 0.
    @discardableResult
    public mutating func compact(maxEmptyBuckets: Int) -> FloatHistogram {
        (positiveBuckets, _, positiveSpans) = compactBuckets(
            primaryBuckets: positiveBuckets, compensationBuckets: nil,
            spans: positiveSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: false)
        (negativeBuckets, _, negativeSpans) = compactBuckets(
            primaryBuckets: negativeBuckets, compensationBuckets: nil,
            spans: negativeSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: false)
        return self
    }

    /// Go: `Validate` — checks consistency between the span and bucket slices,
    /// rejects negative counts, and rejects fields the schema does not permit.
    ///
    /// Unlike `Histogram.validate()`, this does **not** check `count` against the
    /// sum of the buckets: floating-point error would produce false positives.
    public func validate() throws {
        var nCount: Double = 0
        var pCount: Double = 0

        if isCustomBucketsSchema(schema) {
            do {
                try checkHistogramCustomBounds(
                    customValues ?? [], positiveSpans, positiveBuckets.count)
            } catch let e as HistogramError {
                throw HistogramError.wrapped(prefix: "custom buckets", e)
            }
            if zeroCount != 0 { throw HistogramError.customBucketsZeroCount }
            if zeroThreshold != 0 { throw HistogramError.customBucketsZeroThresh }
            if !negativeSpans.isEmpty { throw HistogramError.customBucketsNegSpans }
            if !negativeBuckets.isEmpty { throw HistogramError.customBucketsNegBuckets }
        } else if isExponentialSchema(schema) {
            do {
                try checkHistogramSpans(positiveSpans, positiveBuckets.count)
            } catch let e as HistogramError {
                throw HistogramError.wrapped(prefix: "positive side", e)
            }
            do {
                try checkHistogramSpans(negativeSpans, negativeBuckets.count)
            } catch let e as HistogramError {
                throw HistogramError.wrapped(prefix: "negative side", e)
            }
            do {
                try checkHistogramBuckets(negativeBuckets, &nCount, deltas: false)
            } catch let e as HistogramError {
                throw HistogramError.wrapped(prefix: "negative side", e)
            }
            if zeroCount < 0 {
                throw HistogramError.zeroBucketNegativeCount(count: zeroCount)
            }
            // float_histogram.go:966 — non-nil, not non-empty.
            if customValues != nil { throw HistogramError.expSchemaCustomBounds }
        } else {
            throw HistogramError.invalidSchema(schema)
        }
        if count < 0 {
            throw HistogramError.negativeCountDetail(count: count)
        }
        do {
            try checkHistogramBuckets(positiveBuckets, &pCount, deltas: false)
        } catch let e as HistogramError {
            throw HistogramError.wrapped(prefix: "positive side", e)
        }
        // nCount and pCount are accumulated but deliberately unused: Go computes
        // them and then does not compare against Count, for the reason above.
        _ = nCount
        _ = pCount
    }

    // MARK: - Iterators

    /// Go: `floatBucketIterator` — the low-level constructor.
    ///
    /// For exponential schemas, buckets whose upper boundary has an absolute
    /// value ≤ `absoluteStartValue` are skipped; for custom-bucket schemas
    /// `absoluteStartValue` is ignored and nothing is skipped.
    ///
    /// `targetSchema` must be ≤ this histogram's schema. Buckets are merged to
    /// match it while iterating, without mutating the histogram — but a
    /// custom-buckets schema cannot be merged with any other.
    func floatBucketIterator(
        positive: Bool, absoluteStartValue: Double, targetSchema: Int32
    ) -> FloatBucketIterator {
        if usesCustomBuckets && targetSchema != schema {
            preconditionFailure("cannot merge from custom buckets schema to exponential schema")
        }
        if !usesCustomBuckets && isCustomBucketsSchema(targetSchema) {
            preconditionFailure("cannot merge from exponential buckets schema to custom schema")
        }
        if targetSchema > schema {
            preconditionFailure("cannot merge from schema \(schema) to \(targetSchema)")
        }
        return FloatBucketIterator(
            spans: positive ? positiveSpans : negativeSpans,
            buckets: positive ? positiveBuckets : negativeBuckets,
            schema: schema,
            positive: positive,
            // Go only sets customValues on the positive side.
            customValues: positive ? (customValues ?? []) : [],
            targetSchema: targetSchema,
            absoluteStartValue: absoluteStartValue)
    }

    /// Go: `PositiveBucketIterator` — ascending, starting next to the zero bucket.
    public func positiveBucketIterator() -> FloatBucketIterator {
        floatBucketIterator(positive: true, absoluteStartValue: 0, targetSchema: schema)
    }

    /// Go: `NegativeBucketIterator` — descending, starting next to the zero bucket.
    public func negativeBucketIterator() -> FloatBucketIterator {
        floatBucketIterator(positive: false, absoluteStartValue: 0, targetSchema: schema)
    }

    /// Go: `PositiveReverseBucketIterator` — descending, from the highest bucket
    /// down towards the zero bucket.
    public func positiveReverseBucketIterator() -> ReverseFloatBucketIterator {
        ReverseFloatBucketIterator(
            spans: positiveSpans, buckets: positiveBuckets, schema: schema,
            positive: true, customValues: customValues ?? [])
    }

    /// Go: `NegativeReverseBucketIterator` — ascending, from the lowest bucket up
    /// towards the zero bucket.
    public func negativeReverseBucketIterator() -> ReverseFloatBucketIterator {
        ReverseFloatBucketIterator(
            spans: negativeSpans, buckets: negativeBuckets, schema: schema,
            positive: false, customValues: [])
    }

    /// Go: `AllBucketIterator` — every negative, zero and positive bucket in
    /// ascending order. Where the highest negative or lowest positive bucket
    /// overlaps the zero bucket, that boundary is clamped to the zero threshold.
    public func allBucketIterator() -> AllFloatBucketIterator {
        AllFloatBucketIterator(
            h: self,
            leftIter: ReverseFloatBucketIterator(
                spans: negativeSpans, buckets: negativeBuckets, schema: schema,
                positive: false, customValues: []),
            rightIter: floatBucketIterator(
                positive: true, absoluteStartValue: 0, targetSchema: schema))
    }

    /// Go: `AllReverseBucketIterator` — the same, in descending order.
    public func allReverseBucketIterator() -> AllFloatBucketIterator {
        AllFloatBucketIterator(
            h: self,
            leftIter: ReverseFloatBucketIterator(
                spans: positiveSpans, buckets: positiveBuckets, schema: schema,
                positive: true, customValues: customValues ?? []),
            rightIter: floatBucketIterator(
                positive: false, absoluteStartValue: 0, targetSchema: schema))
    }
}

// MARK: - String

extension FloatHistogram: CustomStringConvertible {
    /// Go: `FloatHistogram.String()`.
    public var description: String {
        var sb = "{count:\(GoFloat.formatG(count)), sum:\(GoFloat.formatG(sum))"

        var nBuckets = [Bucket<Double>]()
        var negative = negativeBucketIterator()
        while negative.next() {
            let bucket = negative.at()
            if bucket.count != 0 { nBuckets.append(bucket) }
        }
        for bucket in nBuckets.reversed() {
            sb += ", \(bucket)"
        }

        if zeroCount != 0 {
            sb += ", \(zeroBucket())"
        }

        var positive = positiveBucketIterator()
        while positive.next() {
            let bucket = positive.at()
            if bucket.count != 0 { sb += ", \(bucket)" }
        }

        sb += "}"
        return sb
    }
}

// MARK: - Helpers

/// Go: `floatBucketsMatch` — compares bucket values by bit pattern.
func floatBucketsMatch(_ b1: [Double], _ b2: [Double]) -> Bool {
    guard b1.count == b2.count else { return false }
    for (a, b) in zip(b1, b2) where a.bitPattern != b.bitPattern { return false }
    return true
}

/// Go: `mustReduceResolution` — `reduceResolution` for callers that know the
/// spans and buckets are valid. Traps rather than throwing.
func mustReduceResolution<IBC: InternalBucketCountValue>(
    originSpans: [Span],
    originBuckets: [IBC],
    originSchema: Int32,
    targetSchema: Int32,
    deltaBuckets: Bool
) -> (spans: [Span], buckets: [IBC]) {
    do {
        return try reduceResolution(
            originSpans: originSpans, originBuckets: originBuckets,
            originSchema: originSchema, targetSchema: targetSchema,
            deltaBuckets: deltaBuckets)
    } catch {
        preconditionFailure("\(error)")
    }
}
