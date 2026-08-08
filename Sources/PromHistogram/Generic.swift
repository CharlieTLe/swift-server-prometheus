//===----------------------------------------------------------------------===//
// Ported from model/histogram/generic.go @ v3.13.2
//
// ADR-7: Go constrains its generics with type unions — `BucketCount` is
// `float64 | uint64` and `InternalBucketCount` is `float64 | int64`. Swift cannot
// express those, so each becomes a protocol carrying the arithmetic the algorithms
// actually use. That works cleanly here; nothing needed duplicating.
//
// `Histogram` stores bucket *deltas* while `FloatHistogram` stores absolute
// counts, and Go threads that difference through as a `deltaBuckets` boolean
// rather than by specialising. That shape is preserved.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Namespace for the generated bounds table.
public enum HistogramTables {}

/// Go: `BucketCount` — the count in a bucket: `Double` for `FloatHistogram`,
/// `UInt64` for `Histogram`.
public protocol BucketCountValue: Numeric, Comparable, Sendable {
    init(_ value: Double)
    /// Go's `BC(ibc)` conversion where `IBC` is `int64`.
    init(reinterpreting value: Int64)
    var asDouble: Double { get }
}

extension Double: BucketCountValue {
    public init(reinterpreting value: Int64) { self = Double(value) }
    public var asDouble: Double { self }
}
extension UInt64: BucketCountValue {
    // generic.go:202 — `BC(b.currCount)` is Go's numeric conversion, so a negative
    // delta becomes a huge uint64 by two's complement rather than clamping to 0.
    // Only reachable from an invalid histogram, but the iterator must not paper
    // over it: that would hide a divergence rather than surface it.
    public init(reinterpreting value: Int64) { self = UInt64(bitPattern: value) }
    public var asDouble: Double { Double(self) }
}

/// Go: `InternalBucketCount` — what a histogram stores internally: absolute
/// counts (`Double`) or deltas between buckets (`Int64`).
public protocol InternalBucketCountValue: SignedNumeric, Comparable, Sendable {
    var asDouble: Double { get }
    var asInt64: Int64 { get }
    /// Go's `BC(ibc)` conversion at the internal-to-external boundary. Dispatching
    /// through the *source* type keeps it exact: routing `Int64` through `Double`
    /// would lose precision above 2^53.
    func asBucketCount<BC: BucketCountValue>(_: BC.Type) -> BC
}

extension Double: InternalBucketCountValue {
    public var asInt64: Int64 { Int64(self) }
    public func asBucketCount<BC: BucketCountValue>(_: BC.Type) -> BC { BC(self) }
}
extension Int64: InternalBucketCountValue {
    public var asDouble: Double { Double(self) }
    public var asInt64: Int64 { self }
    public func asBucketCount<BC: BucketCountValue>(_: BC.Type) -> BC {
        BC(reinterpreting: self)
    }
}

// MARK: - Schemas

public enum HistogramSchema: Sendable {
    /// Go: `ExponentialSchemaMax`.
    public static let exponentialMax: Int32 = 8
    /// Go: `ExponentialSchemaMaxReserved`.
    public static let exponentialMaxReserved: Int32 = 52
    /// Go: `ExponentialSchemaMin`.
    public static let exponentialMin: Int32 = -4
    /// Go: `ExponentialSchemaMinReserved`.
    public static let exponentialMinReserved: Int32 = -9
    /// Go: `CustomBucketsSchema` — native histograms with custom bucket bounds (NHCB).
    public static let customBuckets: Int32 = -53
}

@inlinable
public func isCustomBucketsSchema(_ s: Int32) -> Bool { s == HistogramSchema.customBuckets }

@inlinable
public func isExponentialSchema(_ s: Int32) -> Bool {
    s >= HistogramSchema.exponentialMin && s <= HistogramSchema.exponentialMax
}

@inlinable
public func isExponentialSchemaReserved(_ s: Int32) -> Bool {
    s >= HistogramSchema.exponentialMinReserved && s <= HistogramSchema.exponentialMaxReserved
}

@inlinable
public func isValidSchema(_ s: Int32) -> Bool {
    isCustomBucketsSchema(s) || isExponentialSchema(s)
}

/// Go: `IsKnownSchema` — accepted, but the resolution must be reduced to the
/// nearest supported schema.
@inlinable
public func isKnownSchema(_ s: Int32) -> Bool {
    isCustomBucketsSchema(s) || isExponentialSchemaReserved(s)
}

/// Go: `CustomBucketBoundsMatch`.
public func customBucketBoundsMatch(_ c1: [Double], _ c2: [Double]) -> Bool {
    guard c1.count == c2.count else { return false }
    for (a, b) in zip(c1, c2) where a != b { return false }
    return true
}

// MARK: - Errors

/// Go: the `Err*` sentinel values in generic.go. The `description` reproduces
/// Go's message text, which surfaces through scrape and API errors.
///
/// Go composes these with `fmt.Errorf("...: %w", err)`. Wrapping is modelled two
/// ways, mirroring where Go puts the detail: cases that always carry their own
/// context spell out the whole message (`spansBucketsMismatch`), while the
/// caller-supplied prefixes that `Validate` adds are a separate `wrapped` case.
public indirect enum HistogramError: Error, Equatable, CustomStringConvertible {
    case countNotBigEnough
    case countMismatch
    case negativeCount
    case negativeBucketCount(index: Int, count: Double)
    case spanNegativeOffset(span: Int, offset: Int32)
    case spansBucketsMismatch(need: Int, have: Int)
    /// Go: generic.go:817 — `reduceResolution` runs out of buckets mid-span and
    /// reports what it has rather than what it needs, unlike every other
    /// spans/buckets mismatch.
    case spansNeedMoreBuckets(have: Int)
    case customBucketsMismatch(defined: Int, needed: Int)
    case customBucketsInvalid(previous: Double, current: Double)
    case customBucketsInfinite
    case customBucketsNaN
    case incompatibleSchema
    case customBucketsZeroCount
    case customBucketsZeroThresh
    case customBucketsNegSpans
    case customBucketsNegBuckets
    case expSchemaCustomBounds
    case invalidSchema(Int32)
    case unknownSchema(Int32)
    /// Go: `histogram.go:470` — the observation-count checks prepend the two
    /// counts to the sentinel message.
    case countMismatchDetail(sumOfBuckets: UInt64, count: UInt64, notBigEnough: Bool)
    /// Go: `fmt.Errorf("%s: %w", prefix, err)` — `Validate` labels which side of
    /// the histogram failed.
    case wrapped(prefix: String, HistogramError)

    public var description: String {
        switch self {
        case .countNotBigEnough:
            return
                "histogram's observation count should be at least the number of observations found in the buckets"
        case .countMismatch:
            return
                "histogram's observation count should equal the number of observations found in the buckets (in absence of NaN)"
        case .negativeCount:
            return "histogram's observation count is negative"
        case .negativeBucketCount(let i, let c):
            return
                "bucket number \(i) has observation count of \(GoFloat.formatG(c)): histogram has a bucket whose observation count is negative"
        case .spanNegativeOffset(let n, let o):
            return "span number \(n) with offset \(o): histogram has a span whose offset is negative"
        case .spansBucketsMismatch(let need, let have):
            return
                "spans need \(need) buckets, have \(have) buckets: histogram spans specify different number of buckets than provided"
        case .spansNeedMoreBuckets(let have):
            return
                "have \(have) buckets but spans need more: histogram spans specify different number of buckets than provided"
        case .customBucketsMismatch(let defined, let needed):
            return
                "only \(defined) custom bounds defined which is insufficient to cover total span length of \(needed): histogram custom bounds are too few"
        case .customBucketsInvalid(let prev, let curr):
            return
                "previous bound is \(GoFloat.format(prev, .f, precision: 6)) and current is \(GoFloat.format(curr, .f, precision: 6)): histogram custom bounds must be in strictly increasing order"
        case .customBucketsInfinite:
            return
                "last +Inf bound must not be explicitly defined: histogram custom bounds must be finite"
        case .customBucketsNaN:
            return "histogram custom bounds must not be NaN"
        case .incompatibleSchema:
            return
                "cannot apply this operation on histograms with a mix of exponential and custom bucket schemas"
        case .customBucketsZeroCount:
            return "custom buckets: must have zero count of 0"
        case .customBucketsZeroThresh:
            return "custom buckets: must have zero threshold of 0"
        case .customBucketsNegSpans:
            return "custom buckets: must not have negative spans"
        case .customBucketsNegBuckets:
            return "custom buckets: must not have negative buckets"
        case .expSchemaCustomBounds:
            return "histogram with exponential schema must not have custom bounds"
        case .invalidSchema(let s):
            return
                "histogram has an invalid schema, which must be between \(HistogramSchema.exponentialMin) and \(HistogramSchema.exponentialMax) for exponential buckets, or \(HistogramSchema.customBuckets) for custom buckets, got schema \(s)"
        case .unknownSchema(let s):
            return
                "histogram has an unknown schema, which must be between \(HistogramSchema.exponentialMinReserved) and \(HistogramSchema.exponentialMaxReserved) for exponential buckets, or \(HistogramSchema.customBuckets) for custom buckets, got schema \(s)"
        case .countMismatchDetail(let sumOfBuckets, let count, let notBigEnough):
            let base: HistogramError = notBigEnough ? .countNotBigEnough : .countMismatch
            return
                "\(sumOfBuckets) observations found in buckets, but the Count field is \(count): \(base.description)"
        case .wrapped(let prefix, let inner):
            return "\(prefix): \(inner.description)"
        }
    }
}

// MARK: - Span and Bucket

/// Go: `histogram.Span` — a run of consecutive buckets, offset from the previous run.
public struct Span: Sendable, Hashable {
    /// Gap to the previous span, or to zero for the first span.
    public var offset: Int32
    /// Number of consecutive buckets.
    public var length: UInt32

    public init(offset: Int32, length: UInt32) {
        self.offset = offset
        self.length = length
    }
}

/// Go: `histogram.Bucket` — lower and upper limit with inclusivity, plus the count.
///
/// For a cumulative bucket, `lower` is -Inf and `count` includes every smaller bucket.
public struct Bucket<Count: BucketCountValue>: Sendable {
    public var lower: Double
    public var upper: Double
    public var lowerInclusive: Bool
    public var upperInclusive: Bool
    public var count: Count
    /// Index within the schema, for comparing buckets of the same schema and sign.
    /// Irrelevant for the zero bucket.
    public var index: Int32

    public init(
        lower: Double, upper: Double, lowerInclusive: Bool, upperInclusive: Bool,
        count: Count, index: Int32
    ) {
        self.lower = lower
        self.upper = upper
        self.lowerInclusive = lowerInclusive
        self.upperInclusive = upperInclusive
        self.count = count
        self.index = index
    }
}

extension Bucket: CustomStringConvertible {
    /// Go: `Bucket.String()` — mathematical interval notation.
    public var description: String {
        var s = lowerInclusive ? "[" : "("
        s += GoFloat.formatG(lower) + "," + GoFloat.formatG(upper)
        s += upperInclusive ? "]" : ")"
        // Go prints the count with %v: an integer count has no decimal point.
        if let d = count as? Double {
            s += ":" + GoFloat.formatG(d)
        } else {
            s += ":\(count)"
        }
        return s
    }
}

// MARK: - Bounds

/// Go: `getBound`.
public func getBound(_ idx: Int32, _ schema: Int32, _ customValues: [Double]) -> Double {
    if isCustomBucketsSchema(schema) {
        let length = Int32(customValues.count)
        if idx > length || idx < -1 {
            preconditionFailure(
                "index \(idx) out of bounds for custom bounds of length \(length)")
        }
        if idx == length { return .infinity }
        if idx == -1 { return -.infinity }
        return customValues[Int(idx)]
    }
    return getBoundExponential(idx, schema)
}

/// Go: `getBoundExponential`.
///
/// The last regular bucket needs special handling. Applying the usual formula
/// would give +Inf as its upper bound, because `Double.greatestFiniteMagnitude`
/// is not itself a bucket boundary — but ±Inf observations belong in the *next*
/// bucket. So that one boundary is clamped to `greatestFiniteMagnitude`.
public func getBoundExponential(_ idx: Int32, _ schema: Int32) -> Double {
    if schema < 0 {
        let exp = Int(idx) << Int(-schema)
        if exp == 1024 {
            // Last bucket before the ±Inf overflow bucket.
            return .greatestFiniteMagnitude
        }
        return Double(sign: .plus, exponent: exp, significand: 1)
    }
    let fracIdx = idx & ((1 << schema) - 1)
    let frac = HistogramTables.exponentialBound(schema: schema, index: fracIdx)
    let exp = (Int(idx) >> Int(schema)) + 1
    if frac == 0.5 && exp == 1025 {
        // Last bucket before the ±Inf overflow bucket.
        return .greatestFiniteMagnitude
    }
    return Double(sign: .plus, exponent: exp, significand: frac)
}

extension HistogramTables {
    /// The precalculated bound in [0.5, 1). Data lives in
    /// Generated/HistogramBounds.swift, recovered from Go rather than transcribed.
    public static func exponentialBound(schema: Int32, index: Int32) -> Double {
        Double(bitPattern: exponentialBoundBits[Int(schema)][Int(index)])
    }
}

/// Go: `targetIdx` — the index in `targetSchema` of a bucket at `idx` in `originSchema`.
@inlinable
public func targetIdx(_ idx: Int32, _ originSchema: Int32, _ targetSchema: Int32) -> Int32 {
    ((idx - 1) >> (originSchema - targetSchema)) + 1
}

// MARK: - Validation helpers

/// Go: `checkHistogramSpans`.
func checkHistogramSpans(_ spans: [Span], _ numBuckets: Int) throws {
    var spanBuckets = 0
    for (n, span) in spans.enumerated() {
        if n > 0 && span.offset < 0 {
            throw HistogramError.spanNegativeOffset(span: n + 1, offset: span.offset)
        }
        spanBuckets += Int(span.length)
    }
    if spanBuckets != numBuckets {
        throw HistogramError.spansBucketsMismatch(need: spanBuckets, have: numBuckets)
    }
}

/// Go: `checkHistogramBuckets`. Accumulates the observed total into `count`.
func checkHistogramBuckets<BC: BucketCountValue, IBC: InternalBucketCountValue>(
    _ buckets: [IBC], _ count: inout BC, deltas: Bool
) throws {
    if buckets.isEmpty { return }
    var last = IBC.zero
    for i in buckets.indices {
        let c = deltas ? last + buckets[i] : buckets[i]
        if c < IBC.zero {
            throw HistogramError.negativeBucketCount(index: i + 1, count: c.asDouble)
        }
        last = c
        // Go: *count += BC(c) — the conversion is from the internal type, not via
        // Double, so an Int64 delta above 2^53 stays exact.
        count += c.asBucketCount(BC.self)
    }
}

/// Go: `checkHistogramCustomBounds`.
func checkHistogramCustomBounds(_ bounds: [Double], _ spans: [Span], _ numBuckets: Int) throws {
    var prev = -Double.infinity
    for (i, curr) in bounds.enumerated() {
        if curr.isNaN { throw HistogramError.customBucketsNaN }
        if i > 0 && curr <= prev {
            throw HistogramError.customBucketsInvalid(previous: prev, current: curr)
        }
        prev = curr
    }
    if prev == .infinity { throw HistogramError.customBucketsInfinite }

    var spanBuckets = 0
    var totalSpanLength = 0
    for (n, span) in spans.enumerated() {
        if span.offset < 0 {
            throw HistogramError.spanNegativeOffset(span: n + 1, offset: span.offset)
        }
        spanBuckets += Int(span.length)
        totalSpanLength += Int(span.length) + Int(span.offset)
    }
    if spanBuckets != numBuckets {
        throw HistogramError.spansBucketsMismatch(need: spanBuckets, have: numBuckets)
    }
    if bounds.count + 1 < totalSpanLength {
        throw HistogramError.customBucketsMismatch(
            defined: bounds.count, needed: totalSpanLength)
    }
}
