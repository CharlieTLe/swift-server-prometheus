//===----------------------------------------------------------------------===//
// Ported from model/histogram/histogram.go @ v3.13.2
//
// Two shape decisions worth knowing before reading:
//
// `customValues` is `[Double]?`, not `[Double]`. Everywhere else nil and empty
// are interchangeable (`slices.Equal` and `len()` cannot tell them apart), but
// histogram.go:456 tests `h.CustomValues != nil` to reject custom bounds on an
// exponential-schema histogram — so an empty non-nil slice is an error there and
// nil is not. Collapsing the two would be a silent divergence. Spans and bucket
// slices stay non-optional, where the distinction is unobservable.
//
// Go's `Copy`/`CopyTo` exist because `sync.Pool` reuses histograms; we dropped
// the pool but kept the call-site shapes, per docs/PORTING.md §4 exception 4.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `CounterResetHint` — what is known about a counter reset, or that this is
/// a gauge histogram where resets do not apply.
public enum CounterResetHint: UInt8, Sendable, Hashable {
    /// We cannot say whether this histogram signals a counter reset.
    case unknownCounterReset = 0
    /// There was definitely a counter reset starting from this histogram.
    case counterReset = 1
    /// There was definitely no counter reset with this histogram.
    case notCounterReset = 2
    /// This is a gauge histogram; counter resets do not happen.
    case gaugeType = 3
}

/// Go: `Histogram` — a sparse, high-resolution histogram.
///
/// The tricky part is how bucket indices represent real bucket boundaries. For
/// schema 0, where each bucket is twice as wide as the previous one:
///
///     Bucket boundaries →   [-2,-1) [-1,-0.5) [-0.5,-0.25) ... [-0.001,0.001] ... (0.25,0.5] (0.5,1] (1,2]
///                              ↑        ↑          ↑                 ↑                ↑         ↑     ↑
///     Zero bucket        →     |        |          |                 ZB               |         |     |
///     Positive indices   →     |        |          |                         ...      -1        0     1   2
///     Negative indices   →  3  2   1    0         -1      ...
///
/// Which indices are actually used is determined by the spans.
///
/// Deliberately not `Equatable`: `equals(_:)` is not structural equality — two
/// histograms with different span layouts can describe the same buckets.
public struct Histogram: Sendable {
    /// Counter reset information.
    public var counterResetHint: CounterResetHint
    /// `-4 <= n <= 8` for exponential buckets — all base-2 schemas where 1 is a
    /// boundary and each power of two is divided into `2^n` logarithmic buckets,
    /// so each boundary is the previous one times `2^(2^-n)`. Or `-53` for custom
    /// buckets, defined by `customValues`.
    public var schema: Int32
    /// Width of the zero bucket.
    public var zeroThreshold: Double
    /// Observations falling into the zero bucket.
    public var zeroCount: UInt64
    /// Total number of observations.
    public var count: UInt64
    /// Sum of observations. Also used as the stale marker.
    public var sum: Double
    /// Spans for positive and negative buckets.
    public var positiveSpans: [Span]
    public var negativeSpans: [Span]
    /// Observation counts in buckets. The first element is an absolute count; all
    /// following ones are deltas relative to the previous element.
    public var positiveBuckets: [Int64]
    public var negativeBuckets: [Int64]
    /// The custom (usually upper) bounds for bucket definitions, otherwise nil.
    /// Interned upstream, to be treated as immutable; Swift's copy-on-write makes
    /// that unobservable. Strictly increasing. Only used when the schema is for
    /// custom buckets, in which case `zeroThreshold`, `zeroCount`, `negativeSpans`
    /// and `negativeBuckets` are unused.
    public var customValues: [Double]?

    public init(
        counterResetHint: CounterResetHint = .unknownCounterReset,
        schema: Int32 = 0,
        zeroThreshold: Double = 0,
        zeroCount: UInt64 = 0,
        count: UInt64 = 0,
        sum: Double = 0,
        positiveSpans: [Span] = [],
        negativeSpans: [Span] = [],
        positiveBuckets: [Int64] = [],
        negativeBuckets: [Int64] = [],
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

    /// Go: `Copy` — a deep copy. Fields the schema does not use are dropped
    /// rather than carried over.
    public func copy() -> Histogram {
        var c = Histogram(
            counterResetHint: counterResetHint, schema: schema, count: count, sum: sum)

        if usesCustomBuckets {
            // Custom values are interned; copying by reference is fine.
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
    /// depend on the destination being updated in place.
    public func copy(to destination: inout Histogram) {
        destination.counterResetHint = counterResetHint
        destination.schema = schema
        destination.count = count
        destination.sum = sum

        if usesCustomBuckets {
            destination.zeroThreshold = 0
            destination.zeroCount = 0
            destination.negativeSpans = []
            destination.negativeBuckets = []
            // Custom values are interned; copying by reference is fine.
            destination.customValues = customValues
        } else {
            destination.zeroThreshold = zeroThreshold
            destination.zeroCount = zeroCount
            destination.negativeSpans = negativeSpans
            destination.negativeBuckets = negativeBuckets
            // Custom values are interned, no need to reset.
            destination.customValues = nil
        }

        destination.positiveSpans = positiveSpans
        destination.positiveBuckets = positiveBuckets
    }

    // MARK: - Buckets

    /// Go: `ZeroBucket`. Traps if the schema is for custom buckets.
    public func zeroBucket() -> Bucket<UInt64> {
        if usesCustomBuckets {
            preconditionFailure("histograms with custom buckets have no zero bucket")
        }
        return Bucket(
            lower: -zeroThreshold, upper: zeroThreshold,
            lowerInclusive: true, upperInclusive: true,
            count: zeroCount, index: 0)
    }

    /// Go: `PositiveBucketIterator` — ascending, starting next to the zero bucket
    /// and going up.
    public func positiveBucketIterator() -> RegularBucketIterator {
        RegularBucketIterator(
            spans: positiveSpans, buckets: positiveBuckets, schema: schema,
            positive: true, customValues: customValues ?? [])
    }

    /// Go: `NegativeBucketIterator` — descending, starting next to the zero
    /// bucket and going down.
    public func negativeBucketIterator() -> RegularBucketIterator {
        RegularBucketIterator(
            spans: negativeSpans, buckets: negativeBuckets, schema: schema,
            positive: false, customValues: [])
    }

    /// Go: `CumulativeBucketIterator` — a cumulative view. Only supports
    /// histograms without negative buckets and traps otherwise. Test-only
    /// upstream.
    public func cumulativeBucketIterator() -> CumulativeBucketIterator {
        if !negativeBuckets.isEmpty {
            preconditionFailure(
                "CumulativeBucketIterator called on Histogram with negative buckets")
        }
        return CumulativeBucketIterator(self)
    }

    // MARK: - Equality

    /// Go: `Equals` — true if the given histogram matches exactly.
    ///
    /// An exact match means no new buckets (even empty ones), no missing buckets,
    /// and every bucket value equal. Spans may differ in where they place empty
    /// zero-length spans, as long as they describe the same layout. `sum` is
    /// compared by bit pattern: this is data equality, not mathematical equality.
    ///
    /// Fields the schema does not use are ignored, except those where a
    /// difference could still cause unintended behaviour.
    public func equals(_ other: Histogram) -> Bool {
        if schema != other.schema || count != other.count
            || sum.bitPattern != other.sum.bitPattern
        {
            return false
        }

        if usesCustomBuckets {
            if !customBucketBoundsMatch(customValues ?? [], other.customValues ?? []) {
                return false
            }
        }

        if zeroThreshold != other.zeroThreshold || zeroCount != other.zeroCount {
            return false
        }

        if !spansMatch(negativeSpans, other.negativeSpans) { return false }
        if negativeBuckets != other.negativeBuckets { return false }

        if !spansMatch(positiveSpans, other.positiveSpans) { return false }
        if positiveBuckets != other.positiveBuckets { return false }

        return true
    }

    // MARK: - Operations

    /// Go: `Compact` — works like `FloatHistogram.Compact`; see there for the
    /// detailed explanation. Go returns the receiver so calls can be chained.
    @discardableResult
    public mutating func compact(maxEmptyBuckets: Int) -> Histogram {
        (positiveBuckets, _, positiveSpans) = compactBuckets(
            primaryBuckets: positiveBuckets, compensationBuckets: nil,
            spans: positiveSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: true)
        (negativeBuckets, _, negativeSpans) = compactBuckets(
            primaryBuckets: negativeBuckets, compensationBuckets: nil,
            spans: negativeSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: true)
        return self
    }

    /// Go: `ToFloat` — a deep copy as a `FloatHistogram`, with the bucket deltas
    /// accumulated into absolute counts.
    ///
    /// Go also takes a `*FloatHistogram` whose memory is reused. That is purely
    /// an allocation optimisation: every field is overwritten, so the result does
    /// not depend on what was there. `toFloat(into:)` keeps the reusing call
    /// shape available.
    public func toFloat() -> FloatHistogram {
        var fh = FloatHistogram()
        fh.counterResetHint = counterResetHint
        fh.schema = schema
        fh.count = Double(count)
        fh.sum = sum

        if usesCustomBuckets {
            fh.zeroThreshold = 0
            fh.zeroCount = 0
            fh.negativeSpans = []
            fh.negativeBuckets = []
            // Custom values are interned; copying by reference is fine.
            fh.customValues = customValues
        } else {
            fh.zeroThreshold = zeroThreshold
            fh.zeroCount = Double(zeroCount)

            fh.negativeSpans = negativeSpans
            fh.negativeBuckets = Self.accumulate(negativeBuckets)
            // Custom values are interned, no need to reset.
            fh.customValues = nil
        }

        fh.positiveSpans = positiveSpans
        fh.positiveBuckets = Self.accumulate(positiveBuckets)

        return fh
    }

    /// Go: `ToFloat(fh)` with a non-nil argument. See `toFloat()`.
    public func toFloat(into fh: inout FloatHistogram) {
        fh = toFloat()
    }

    /// Running total of the deltas, in `float64` throughout — Go accumulates into
    /// a `float64`, so a delta beyond 2^53 rounds there too.
    private static func accumulate(_ deltas: [Int64]) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(deltas.count)
        var current: Double = 0
        for b in deltas {
            current += Double(b)
            out.append(current)
        }
        return out
    }

    /// Go: `Validate` — checks consistency between the span and bucket slices,
    /// rejects negative bucket counts, and rejects fields that the schema does
    /// not permit.
    ///
    /// For histograms that have observed no NaN (tested via `sum.isNaN`), the
    /// strict `count == nCount + pCount + zeroCount` check is applied. Otherwise
    /// only the lower bound is checked, because a NaN observation increments
    /// `count` without incrementing any bucket.
    public func validate() throws {
        var nCount: UInt64 = 0
        var pCount: UInt64 = 0

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
                try checkHistogramBuckets(negativeBuckets, &nCount, deltas: true)
            } catch let e as HistogramError {
                throw HistogramError.wrapped(prefix: "negative side", e)
            }
            // histogram.go:456 — non-nil, not non-empty: see the file header.
            if customValues != nil { throw HistogramError.expSchemaCustomBounds }
        } else {
            throw HistogramError.invalidSchema(schema)
        }

        do {
            try checkHistogramBuckets(positiveBuckets, &pCount, deltas: true)
        } catch let e as HistogramError {
            throw HistogramError.wrapped(prefix: "positive side", e)
        }

        // Go adds these in uint64, so the wraparound on an overflowing histogram
        // is part of the behaviour.
        let sumOfBuckets = nCount &+ pCount &+ zeroCount
        if sum.isNaN {
            if sumOfBuckets > count {
                throw HistogramError.countMismatchDetail(
                    sumOfBuckets: sumOfBuckets, count: count, notBigEnough: true)
            }
        } else {
            if sumOfBuckets != count {
                throw HistogramError.countMismatchDetail(
                    sumOfBuckets: sumOfBuckets, count: count, notBigEnough: false)
            }
        }
    }

    /// Go: `ReduceResolution` — reduces the spans and buckets into `targetSchema`.
    ///
    /// Throws when the target schema is not smaller than the current one, when
    /// this histogram has custom buckets, when the target is a custom-buckets
    /// schema, when a span has an invalid offset, or when the spans are
    /// inconsistent with the buckets.
    public mutating func reduceResolution(targetSchema: Int32) throws {
        // Go returns plain errors rather than a histogram.Error for the first
        // three, because they are programming errors, not bad data. The distinct
        // error type preserves that.
        if usesCustomBuckets {
            throw HistogramOperationError.reduceResolutionFromCustomBuckets
        }
        if isCustomBucketsSchema(targetSchema) {
            throw HistogramOperationError.reduceResolutionToCustomBuckets
        }
        if targetSchema >= schema {
            throw HistogramOperationError.reduceResolutionSchema(
                from: schema, to: targetSchema)
        }

        // Module-qualified: the method name shadows the generic free function.
        //
        // histogram.go:642 assigns reduceResolution's result to the fields BEFORE
        // testing the error, and the failing call returns `nil, nil` — so a
        // rejected histogram is left with that side cleared, and with the schema
        // still unchanged even if the other side already succeeded. That is
        // observable, so it is replicated rather than tidied up.
        do {
            (positiveSpans, positiveBuckets) = try PromHistogram.reduceResolution(
                originSpans: positiveSpans, originBuckets: positiveBuckets,
                originSchema: schema, targetSchema: targetSchema, deltaBuckets: true)
        } catch {
            positiveSpans = []
            positiveBuckets = []
            throw error
        }
        do {
            (negativeSpans, negativeBuckets) = try PromHistogram.reduceResolution(
                originSpans: negativeSpans, originBuckets: negativeBuckets,
                originSchema: schema, targetSchema: targetSchema, deltaBuckets: true)
        } catch {
            negativeSpans = []
            negativeBuckets = []
            throw error
        }
        schema = targetSchema
    }
}

/// Go: the `errors.New`/`fmt.Errorf` values that `ReduceResolution` returns
/// directly. histogram.go:628 — these are deliberately *not* `histogram.Error`,
/// because they report a programming error rather than invalid data.
public enum HistogramOperationError: Error, Equatable, CustomStringConvertible {
    case reduceResolutionFromCustomBuckets
    case reduceResolutionToCustomBuckets
    case reduceResolutionSchema(from: Int32, to: Int32)

    public var description: String {
        switch self {
        case .reduceResolutionFromCustomBuckets:
            return "cannot reduce resolution when there are custom buckets"
        case .reduceResolutionToCustomBuckets:
            return "cannot reduce resolution to custom buckets schema"
        case .reduceResolutionSchema(let from, let to):
            return "cannot reduce resolution from schema \(from) to \(to)"
        }
    }
}

// MARK: - String

extension Histogram: CustomStringConvertible {
    /// Go: `Histogram.String()`.
    public var description: String {
        var sb = "{count:\(count), sum:\(GoFloat.formatG(sum))"

        var nBuckets = [Bucket<UInt64>]()
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

// MARK: - Span matching

/// Go: `spansMatch` — true if both span sets describe the same bucket layout
/// after folding zero-length spans into the next non-zero-length span.
func spansMatch(_ s1: [Span], _ s2: [Span]) -> Bool {
    if s1.isEmpty && s2.isEmpty { return true }

    var s1idx = 0
    var s2idx = 0
    while true {
        if s1idx >= s1.count { return allEmptySpans(s2[s2idx...]) }
        if s2idx >= s2.count { return allEmptySpans(s1[s1idx...]) }

        var currS1 = s1[s1idx]
        var currS2 = s2[s2idx]
        s1idx += 1
        s2idx += 1
        if currS1.length == 0 {
            // Zero length, so absorb consecutive such spans until a non-zero one.
            while s1idx < s1.count && s1[s1idx].length == 0 {
                currS1.offset += s1[s1idx].offset
                s1idx += 1
            }
            if s1idx < s1.count {
                currS1.offset += s1[s1idx].offset
                currS1.length = s1[s1idx].length
                s1idx += 1
            }
        }
        if currS2.length == 0 {
            while s2idx < s2.count && s2[s2idx].length == 0 {
                currS2.offset += s2[s2idx].offset
                s2idx += 1
            }
            if s2idx < s2.count {
                currS2.offset += s2[s2idx].offset
                currS2.length = s2[s2idx].length
                s2idx += 1
            }
        }

        if currS1.length == 0 && currS2.length == 0 {
            // Both sets end in zero-length spans, and everything before matched.
            return true
        }

        if currS1.offset != currS2.offset || currS1.length != currS2.length {
            return false
        }
    }
}

/// Go: `allEmptySpans`.
func allEmptySpans(_ spans: ArraySlice<Span>) -> Bool {
    for s in spans where s.length > 0 { return false }
    return true
}

// MARK: - Iterators

/// Go: `regularBucketIterator`.
public struct RegularBucketIterator: BucketIterator, Sendable {
    private var base: BaseBucketIterator<UInt64, Int64>

    init(spans: [Span], buckets: [Int64], schema: Int32, positive: Bool, customValues: [Double]) {
        base = BaseBucketIterator(
            schema: schema, spans: spans, buckets: buckets, positive: positive,
            customValues: customValues)
    }

    public func at() -> Bucket<UInt64> { base.at() }

    public mutating func next() -> Bool {
        if base.spansIdx >= base.spans.count { return false }
        var span = base.spans[base.spansIdx]
        // Seed currIdx for the first bucket.
        if base.bucketsIdx == 0 {
            base.currIdx = span.offset
        } else {
            base.currIdx += 1
        }
        while base.idxInSpan >= span.length {
            // The current span is exhausted, so find a new one. This also handles
            // pathological spans of length 0.
            base.idxInSpan = 0
            base.spansIdx += 1
            if base.spansIdx >= base.spans.count { return false }
            span = base.spans[base.spansIdx]
            base.currIdx += span.offset
        }

        // Guards against an out-of-range index, which only an invalid histogram
        // can produce.
        if base.bucketsIdx >= base.buckets.count { return false }
        base.currCount += base.buckets[base.bucketsIdx]
        base.idxInSpan += 1
        base.bucketsIdx += 1
        return true
    }
}

/// Go: `cumulativeBucketIterator`.
public struct CumulativeBucketIterator: BucketIterator, Sendable {
    private let h: Histogram

    /// Index in `h.positiveSpans`. -1 means the zero bucket.
    private var posSpansIdx: Int = -1
    /// Index in `h.positiveBuckets`.
    private var posBucketsIdx: Int = 0
    /// Index in the current span. `0 <= idxInSpan < span.length`.
    private var idxInSpan: UInt32 = 0

    private var initialized = false
    /// The actual bucket index, after decoding from the spans.
    private var currIdx: Int32 = 0
    /// The upper boundary of the current bucket.
    private var currUpper: Double = 0
    /// Current non-cumulative count. Does not apply to an empty bucket.
    private var currCount: Int64 = 0
    /// Current cumulative count.
    private var currCumulativeCount: UInt64 = 0

    /// Between two spans there can be empty buckets that still have to be counted
    /// for a cumulative view. On reaching the end of a span, this counts them out.
    private var emptyBucketCount: Int32 = 0

    init(_ h: Histogram) { self.h = h }

    public mutating func next() -> Bool {
        if posSpansIdx == -1 {
            // Zero bucket.
            posSpansIdx += 1
            if h.zeroCount == 0 { return next() }

            currUpper = h.zeroThreshold
            currCount = Int64(bitPattern: h.zeroCount)
            currCumulativeCount = UInt64(bitPattern: currCount)
            return true
        }

        if posSpansIdx >= h.positiveSpans.count { return false }

        if emptyBucketCount > 0 {
            // Currently traversing empty buckets between two spans.
            currUpper = getBound(currIdx, h.schema, h.customValues ?? [])
            currIdx += 1
            emptyBucketCount -= 1
            return true
        }

        let span = h.positiveSpans[posSpansIdx]
        if posSpansIdx == 0 && !initialized {
            currIdx = span.offset
            // The first bucket is an absolute value, not a delta off the zero bucket.
            currCount = 0
            initialized = true
        }

        // Guards against an out-of-range index, which only an invalid histogram
        // can produce.
        if posBucketsIdx >= h.positiveBuckets.count { return false }
        currCount += h.positiveBuckets[posBucketsIdx]
        currCumulativeCount &+= UInt64(bitPattern: currCount)
        currUpper = getBound(currIdx, h.schema, h.customValues ?? [])

        posBucketsIdx += 1
        idxInSpan += 1
        currIdx += 1
        if idxInSpan >= span.length {
            // This span is done; move to the next.
            posSpansIdx += 1
            idxInSpan = 0
            if posSpansIdx < h.positiveSpans.count {
                emptyBucketCount = h.positiveSpans[posSpansIdx].offset
            }
        }

        return true
    }

    public func at() -> Bucket<UInt64> {
        Bucket(
            lower: -.infinity, upper: currUpper,
            lowerInclusive: true, upperInclusive: true,
            count: currCumulativeCount, index: currIdx - 1)
    }
}
