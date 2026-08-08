//===----------------------------------------------------------------------===//
// Ported from model/histogram/generic.go @ v3.13.2 — the bucket-iterator
// scaffolding shared by `Histogram` and `FloatHistogram`.
//
// Go embeds `baseBucketIterator` in each concrete iterator to inherit `At()`.
// Swift has no struct embedding, so the base is a stored property named `base`
// and each iterator forwards `at()` to it. The state fields are otherwise
// identical, including the deliberately mutable `currIdx`/`currCount` cursor.
//===----------------------------------------------------------------------===//

/// Go: `BucketIterator[BC]` — iterates over decoded buckets.
public protocol BucketIterator {
    associatedtype Count: BucketCountValue

    /// Go: `Next()` — advances the iterator by one.
    mutating func next() -> Bool
    /// Go: `At()` — returns the current bucket.
    func at() -> Bucket<Count>
}

/// Go: `strippedBucket` — a `Bucket` without the bound values, which are
/// expensive to calculate and unused in some call sites.
struct StrippedBucket<Count: BucketCountValue>: Sendable {
    var count: Count
    var index: Int32
}

/// Go: `baseBucketIterator[BC, IBC]`.
struct BaseBucketIterator<Count: BucketCountValue, Internal: InternalBucketCountValue>: Sendable {
    var schema: Int32
    var spans: [Span]
    var buckets: [Internal]

    /// Whether this is for positive buckets.
    var positive: Bool

    /// Current span within `spans`.
    var spansIdx: Int = 0
    /// Index in the current span. `0 <= idxInSpan < span.length`.
    var idxInSpan: UInt32 = 0
    /// Current bucket within `buckets`.
    var bucketsIdx: Int = 0

    /// Count in the current bucket.
    var currCount: Internal = .zero
    /// The actual bucket index.
    var currIdx: Int32 = 0

    /// Bounds (usually upper) for histograms with custom buckets.
    var customValues: [Double] = []

    func at() -> Bucket<Count> { at(schema) }

    /// Go: `at` — the internal version of `At`, so callers can substitute a schema.
    func at(_ schema: Int32) -> Bucket<Count> {
        var bucket = Bucket<Count>(
            lower: 0, upper: 0, lowerInclusive: false, upperInclusive: false,
            count: currCount.asBucketCount(Count.self), index: currIdx)
        if positive {
            bucket.upper = getBound(currIdx, schema, customValues)
            bucket.lower = getBound(currIdx - 1, schema, customValues)
        } else {
            bucket.lower = -getBound(currIdx, schema, customValues)
            bucket.upper = -getBound(currIdx - 1, schema, customValues)
        }
        if isCustomBucketsSchema(schema) {
            bucket.lowerInclusive = currIdx == 0
            bucket.upperInclusive = true
        } else {
            bucket.lowerInclusive = bucket.lower < 0
            bucket.upperInclusive = bucket.upper > 0
        }
        return bucket
    }

    /// Go: `strippedAt`.
    func strippedAt() -> StrippedBucket<Count> {
        StrippedBucket(count: currCount.asBucketCount(Count.self), index: currIdx)
    }
}
