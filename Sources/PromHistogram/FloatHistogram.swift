//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — the storage layout
// only.
//
// `Histogram.toFloat()` has to produce this type, so the fields land with the
// integer histogram. The 2,454 lines of arithmetic (Mul/Div/Add/Sub, Compact,
// DetectReset, ReduceResolution, TestExpression, the iterators) arrive in the
// next slice of Phase 3 — see docs/ROADMAP.md and docs/HANDOFF.md §5b.
//===----------------------------------------------------------------------===//

/// Go: `FloatHistogram` — like `Histogram`, but the counts are floats and the
/// buckets hold absolute counts rather than deltas.
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
    /// Custom (usually upper) bounds, otherwise nil. See `Histogram.customValues`
    /// for why this is Optional rather than an empty array.
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
}
