//===----------------------------------------------------------------------===//
// Ported from util/annotations/annotations.go @ v3.13.2
//
// The message strings here are a hard compatibility surface: `promqltest`
// asserts them verbatim, including the trailing `(line:col)`. They are pinned by
// Fixtures/promql/annotations.jsonl. Do not reword one without regenerating.
//===----------------------------------------------------------------------===//

public import PromPosRange
internal import GoCompat
internal import PromModel

/// Go: the `PromQLInfo` / `PromQLWarning` sentinels.
///
/// Go distinguishes the two by walking the `Unwrap` chain with `errors.Is`. Since
/// the only two sentinels are these, and nothing outside upstream's own tests
/// compares against a more specific base annotation (verified across the pin),
/// carrying the discriminator directly is equivalent and much cheaper than
/// reproducing Go's error wrapping.
///
/// Note the raw values: because every annotation is built as
/// `fmt.Errorf("%w: ...", PromQLWarning)`, the sentinel's text is literally the
/// message *prefix*.
public enum AnnotationKind: String, Sendable, Hashable {
    case info = "PromQL info"
    case warning = "PromQL warning"
}

/// Go: one of the package-level `var`s such as `InvalidRatioWarning` — the
/// message before any per-call detail is appended.
public struct AnnotationBase: Sendable, Hashable {
    public let kind: AnnotationKind
    /// The full rendered text, sentinel prefix included.
    public let text: String

    init(_ kind: AnnotationKind, _ suffix: String) {
        self.kind = kind
        self.text = "\(kind.rawValue): \(suffix)"
    }
}

/// Go: the `annoError` interface — an annotation that can carry position info and
/// merge with another of its own type.
///
/// `AnyObject`, because Go's implementations are pointer types that `SetQuery`
/// mutates in place while they sit in the `Annotations` collection.
///
/// **On `Sendable`.** Swift 6's `Error` refines `Sendable`, and these are mutable
/// classes, so the mutable state below is marked `nonisolated(unsafe)`. The
/// conformance cannot be dropped: the engine really does return annotations
/// through `error`-typed results (`vectorElemBinop`, checked by
/// `handleVectorBinopError`). It is safe for the same reason Go's `Annotations`
/// map is safe despite not being goroutine-safe — the evaluator that accumulates
/// them is synchronous and single-threaded by ADR-3.
public protocol AnnotationError: AnyObject, Error, CustomStringConvertible {
    /// Go: the `Unwrap` chain's terminal sentinel, used by `errors.Is`.
    var kind: AnnotationKind { get }
    /// Go: `SetQuery`. Called once, by ``Annotations/asStrings(query:maxWarnings:maxInfos:)``.
    func setQuery(_ query: String)
    /// Go: `Merge`. Called when an annotation with the same query-less message is
    /// already present.
    func merge(_ other: any AnnotationError) -> any AnnotationError
}

/// Go: `annoErr`.
public final class AnnoError: AnnotationError {
    /// Never reassigned after construction, as in Go.
    public let positionRange: PositionRange
    public let kind: AnnotationKind
    /// Go: `Err.Error()` — the message without position info.
    public let message: String
    public nonisolated(unsafe) private(set) var query: String = ""

    init(positionRange: PositionRange, kind: AnnotationKind, message: String) {
        self.positionRange = positionRange
        self.kind = kind
        self.message = message
    }

    public var description: String {
        if query.isEmpty {
            return message
        }
        return "\(message) (\(positionRange.startPosInput(query: query)))"
    }

    public func setQuery(_ query: String) {
        self.query = query
    }

    /// annotations.go:212 — generic annotations do not merge; the incoming error
    /// is discarded and the original kept.
    public func merge(_: any AnnotationError) -> any AnnotationError { self }
}

/// Go: `maybeAddMetricName`.
private func maybeAddMetricName(_ message: String, _ metricName: String) -> String {
    if metricName.isEmpty {
        return message
    }
    return "\(message) for metric name \(GoStrconv.quote(metricName))"
}

// MARK: - Base annotations

extension AnnotationBase {
    public static let invalidRatioWarning = AnnotationBase(
        .warning, "ratio value should be between -1 and 1")
    public static let invalidQuantileWarning = AnnotationBase(
        .warning, "quantile value should be between 0 and 1")
    public static let badBucketLabelWarning = AnnotationBase(
        .warning,
        "bucket label \(GoStrconv.quote(LabelName.bucket)) is missing or has a malformed value")
    public static let mixedFloatsHistogramsWarning = AnnotationBase(
        .warning, "encountered a mix of histograms and floats for")
    public static let mixedClassicNativeHistogramsWarning = AnnotationBase(
        .warning, "vector contains a mix of classic and native histograms")
    public static let nativeHistogramNotCounterWarning = AnnotationBase(
        .warning, "this native histogram metric is not a counter:")
    public static let nativeHistogramNotGaugeWarning = AnnotationBase(
        .warning, "this native histogram metric is not a gauge:")
    public static let mixedExponentialCustomHistogramsWarning = AnnotationBase(
        .warning,
        "vector contains a mix of histograms with exponential and custom buckets schemas for metric name"
    )
    public static let incompatibleBucketLayoutInBinOpWarning = AnnotationBase(
        .warning, "incompatible bucket layout encountered for binary operator")
    public static let sortInRangeQueryWarning = AnnotationBase(
        .warning,
        "sort is ineffective for range queries since results are always ordered by labels")
    public static let histogramCounterResetCollisionWarning = AnnotationBase(
        .warning, "conflicting counter resets during histogram")

    public static let possibleNonCounterInfo = AnnotationBase(
        .info, "metric might not be a counter, name does not end in _total/_sum/_count/_bucket:")
    public static let possibleNonCounterLabelInfo = AnnotationBase(
        .info, possibleNonCounterLabelSuffix)

    /// Split out of the initialiser above: a three-way concatenation of
    /// interpolated calls is the kind of expression the Swift 6.1 type checker
    /// gives up on (HANDOFF §4).
    private static let possibleNonCounterLabelSuffix: String = {
        var s = "metric might not be a counter, __type__ label is not set to "
        s += GoStrconv.quote(MetricType.counter.rawValue)
        s += " or "
        s += GoStrconv.quote(MetricType.histogram.rawValue)
        return s
    }()

    public static let histogramQuantileForcedMonotonicityInfo = AnnotationBase(
        .info, histogramQuantileForcedMonotonicitySuffix)

    private static let histogramQuantileForcedMonotonicitySuffix: String = {
        var s = "input to histogram_quantile needed to be fixed for monotonicity (see "
        s += "https://prometheus.io/docs/prometheus/latest/querying/functions/"
        s += "#histogram_quantile)"
        return s
    }()
    public static let incompatibleTypesInBinOpInfo = AnnotationBase(
        .info, "incompatible sample types encountered for binary operator")
    public static let histogramIgnoredInAggregationInfo = AnnotationBase(
        .info, "ignored histogram in")
    public static let histogramIgnoredInMixedRangeInfo = AnnotationBase(
        .info,
        "ignored histograms in a range containing both floats and histograms for metric name")
    public static let nativeHistogramQuantileNaNResultInfo = AnnotationBase(
        .info, "input to histogram_quantile has NaN observations, result is NaN")
    public static let nativeHistogramQuantileNaNSkewInfo = AnnotationBase(
        .info, "input to histogram_quantile has NaN observations, result is skewed higher")
    public static let nativeHistogramFractionNaNsInfo = AnnotationBase(
        .info,
        "input to histogram_fraction has NaN observations, which are excluded from all fractions")
    public static let mismatchedCustomBucketsHistogramsInfo = AnnotationBase(
        .info, "mismatched custom buckets were reconciled during")
}

/// Go: `HistogramOperation`.
public enum HistogramOperation: String, Sendable, Hashable {
    case add = "addition"
    case sub = "subtraction"
    case agg = "aggregation"

    /// Go: `HistogramOperation.String()`. Go's `default` branch returns
    /// "unknown operation", which a Swift enum cannot reach — the raw values are
    /// closed here where Go's named string type is open. Noted rather than
    /// faked: nothing upstream constructs an out-of-set operation.
    public var goString: String { rawValue }
}

// MARK: - Constructors

/// Go: `NewInvalidQuantileWarning`.
public func newInvalidQuantileWarning(_ q: Double, _ pos: PositionRange) -> any AnnotationError {
    let base = AnnotationBase.invalidQuantileWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text), got \(GoFloat.formatG(q))")
}

/// Go: `NewInvalidRatioWarning`.
public func newInvalidRatioWarning(
    _ q: Double, _ to: Double, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.invalidRatioWarning
    let message = "\(base.text), got \(GoFloat.formatG(q)), capping to \(GoFloat.formatG(to))"
    return AnnoError(positionRange: pos, kind: base.kind, message: message)
}

/// Go: `NewBadBucketLabelWarning`.
public func newBadBucketLabelWarning(
    _ metricName: String, _ label: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.badBucketLabelWarning
    let withLabel = "\(base.text) of \(GoStrconv.quote(label))"
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(withLabel, metricName))
}

/// Go: `NewMixedFloatsHistogramsWarning`.
public func newMixedFloatsHistogramsWarning(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.mixedFloatsHistogramsWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) metric name \(GoStrconv.quote(metricName))")
}

/// Go: `NewMixedFloatsHistogramsAggWarning`.
public func newMixedFloatsHistogramsAggWarning(_ pos: PositionRange) -> any AnnotationError {
    let base = AnnotationBase.mixedFloatsHistogramsWarning
    return AnnoError(positionRange: pos, kind: base.kind, message: "\(base.text) aggregation")
}

/// Go: `NewMixedClassicNativeHistogramsWarning`.
public func newMixedClassicNativeHistogramsWarning(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.mixedClassicNativeHistogramsWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(base.text, metricName))
}

/// Go: `NewNativeHistogramNotCounterWarning`.
public func newNativeHistogramNotCounterWarning(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.nativeHistogramNotCounterWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(GoStrconv.quote(metricName))")
}

/// Go: `NewNativeHistogramNotGaugeWarning`.
public func newNativeHistogramNotGaugeWarning(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.nativeHistogramNotGaugeWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(GoStrconv.quote(metricName))")
}

/// Go: `NewMixedExponentialCustomHistogramsWarning`.
public func newMixedExponentialCustomHistogramsWarning(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.mixedExponentialCustomHistogramsWarning
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(GoStrconv.quote(metricName))")
}

/// Go: `NewPossibleNonCounterInfo`.
public func newPossibleNonCounterInfo(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.possibleNonCounterInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(GoStrconv.quote(metricName))")
}

/// Go: `NewPossibleNonCounterLabelInfo`.
public func newPossibleNonCounterLabelInfo(
    _ metricName: String, _ typeLabel: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.possibleNonCounterLabelInfo
    var message = "\(base.text), got \(GoStrconv.quote(typeLabel))"
    message += ": \(GoStrconv.quote(metricName))"
    return AnnoError(positionRange: pos, kind: base.kind, message: message)
}

/// Go: `NewIncompatibleTypesInBinOpInfo`.
public func newIncompatibleTypesInBinOpInfo(
    _ lhsType: String, _ operatorName: String, _ rhsType: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.incompatibleTypesInBinOpInfo
    var message = "\(base.text) \(GoStrconv.quote(operatorName))"
    message += ": \(lhsType) \(operatorName) \(rhsType)"
    return AnnoError(positionRange: pos, kind: base.kind, message: message)
}

/// Go: `NewHistogramIgnoredInAggregationInfo`.
public func newHistogramIgnoredInAggregationInfo(
    _ aggregation: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.histogramIgnoredInAggregationInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(aggregation) aggregation")
}

/// Go: `NewHistogramIgnoredInMixedRangeInfo`.
public func newHistogramIgnoredInMixedRangeInfo(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.histogramIgnoredInMixedRangeInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: "\(base.text) \(GoStrconv.quote(metricName))")
}

/// Go: `NewIncompatibleBucketLayoutInBinOpWarning`.
public func newIncompatibleBucketLayoutInBinOpWarning(
    _ operatorName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.incompatibleBucketLayoutInBinOpWarning
    return AnnoError(
        positionRange: pos, kind: base.kind, message: "\(base.text) \(operatorName)")
}

/// Go: `NewSortInRangeQueryWarning`.
public func newSortInRangeQueryWarning(_ pos: PositionRange) -> any AnnotationError {
    let base = AnnotationBase.sortInRangeQueryWarning
    return AnnoError(positionRange: pos, kind: base.kind, message: base.text)
}

/// Go: `NewNativeHistogramQuantileNaNResultInfo`.
public func newNativeHistogramQuantileNaNResultInfo(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.nativeHistogramQuantileNaNResultInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(base.text, metricName))
}

/// Go: `NewNativeHistogramQuantileNaNSkewInfo`.
public func newNativeHistogramQuantileNaNSkewInfo(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.nativeHistogramQuantileNaNSkewInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(base.text, metricName))
}

/// Go: `NewNativeHistogramFractionNaNsInfo`.
public func newNativeHistogramFractionNaNsInfo(
    _ metricName: String, _ pos: PositionRange
) -> any AnnotationError {
    let base = AnnotationBase.nativeHistogramFractionNaNsInfo
    return AnnoError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(base.text, metricName))
}

/// Go: `NewHistogramCounterResetCollisionWarning`.
public func newHistogramCounterResetCollisionWarning(
    _ pos: PositionRange, _ operation: HistogramOperation
) -> any AnnotationError {
    let base = AnnotationBase.histogramCounterResetCollisionWarning
    return AnnoError(
        positionRange: pos, kind: base.kind, message: "\(base.text) \(operation.goString)")
}

/// Go: `NewMismatchedCustomBucketsHistogramsInfo`.
public func newMismatchedCustomBucketsHistogramsInfo(
    _ pos: PositionRange, _ operation: HistogramOperation
) -> any AnnotationError {
    let base = AnnotationBase.mismatchedCustomBucketsHistogramsInfo
    return AnnoError(
        positionRange: pos, kind: base.kind, message: "\(base.text) \(operation.goString)")
}

// MARK: - histogram_quantile monotonicity

/// Go: `histogramQuantileForcedMonotonicityErr`.
///
/// The only annotation with its own type, because it accumulates across samples:
/// repeated occurrences widen a timestamp and bucket range instead of
/// deduplicating away.
public final class HistogramQuantileForcedMonotonicityError: AnnotationError {
    public let positionRange: PositionRange
    public let kind: AnnotationKind
    public let message: String
    public nonisolated(unsafe) private(set) var query: String = ""

    // Widened by `merge`; see the note on `AnnotationError` about `Sendable`.
    nonisolated(unsafe) var minTs: Int64
    nonisolated(unsafe) var maxTs: Int64
    nonisolated(unsafe) var minBucket: Double
    nonisolated(unsafe) var maxBucket: Double
    nonisolated(unsafe) var maxDiff: Double
    nonisolated(unsafe) var count: Int

    init(
        positionRange: PositionRange, kind: AnnotationKind, message: String,
        minTs: Int64, maxTs: Int64, minBucket: Double, maxBucket: Double, maxDiff: Double,
        count: Int
    ) {
        self.positionRange = positionRange
        self.kind = kind
        self.message = message
        self.minTs = minTs
        self.maxTs = maxTs
        self.minBucket = minBucket
        self.maxBucket = maxBucket
        self.maxDiff = maxDiff
        self.count = count
    }

    public var description: String {
        if query.isEmpty {
            return message
        }
        // annotations.go:337 — `minTs/1000` is Go integer division, which
        // truncates toward zero, so -1001ms is second -1 rather than -2.
        let startTime = GoTime.unix(minTs / 1_000, 0).rfc3339UTC
        let endTime = GoTime.unix(maxTs / 1_000, 0).rfc3339UTC

        var out = message
        out += ", from buckets \(GoFloat.formatG(minBucket)) to \(GoFloat.formatG(maxBucket))"
        out += ", with a max diff of \(GoFloat.format(maxDiff, .g, precision: 2))"
        out += ", over \(count + 1) samples"
        out += " from \(startTime) to \(endTime)"
        out += " (\(positionRange.startPosInput(query: query)))"
        return out
    }

    public func setQuery(_ query: String) {
        self.query = query
    }

    /// annotations.go:350. Note what Go does here: `errors.As(other, &o)`
    /// *overwrites* `o` with `other`, so the widening below mutates the
    /// **already-stored** annotation and returns it. Replicated, because the
    /// count arithmetic (`o.count += e.count + 1`) depends on which object
    /// survives.
    public func merge(_ other: any AnnotationError) -> any AnnotationError {
        guard let o = other as? HistogramQuantileForcedMonotonicityError else {
            return self
        }
        if message != o.message {
            return self
        }
        if minTs < o.minTs { o.minTs = minTs }
        if maxTs > o.maxTs { o.maxTs = maxTs }
        if minBucket < o.minBucket { o.minBucket = minBucket }
        if maxBucket > o.maxBucket { o.maxBucket = maxBucket }
        if maxDiff > o.maxDiff { o.maxDiff = maxDiff }
        o.count += count + 1
        return o
    }
}

/// Go: `NewHistogramQuantileForcedMonotonicityInfo`.
public func newHistogramQuantileForcedMonotonicityInfo(
    _ metricName: String, _ pos: PositionRange, _ ts: Int64,
    _ minBucket: Double, _ maxBucket: Double, _ maxDiff: Double
) -> any AnnotationError {
    let base = AnnotationBase.histogramQuantileForcedMonotonicityInfo
    return HistogramQuantileForcedMonotonicityError(
        positionRange: pos, kind: base.kind,
        message: maybeAddMetricName(base.text, metricName),
        minTs: ts, maxTs: ts, minBucket: minBucket, maxBucket: maxBucket, maxDiff: maxDiff,
        count: 0)
}
