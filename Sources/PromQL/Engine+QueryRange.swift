//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `FindMinMaxTime`,
// `getTimeRangesForSelector`, `subqueryTimes` and the `HashRatioSampler`.
//
// The first three are the query planner's arithmetic: given an `EvalStmt`, what span of
// time does the storage have to be asked for? Nothing here evaluates anything, which is
// why it can be ported and pinned before the evaluator exists — and it has to be right
// first, because a selector handed too narrow a window silently returns too few samples.
//
// ## Every one of the ±1 millisecond adjustments is deliberate
//
// The lookback window is **half-open**: a sample exactly `lookbackDelta` before the
// evaluation time is *excluded*, so the start moves back by `lookbackDelta - 1` rather
// than `lookbackDelta`. A range selector is the same shape — `start -= range - 1` — for
// the same reason at the other end. Getting either "right" by dropping the `- 1` widens
// the window by a millisecond and changes results at boundaries only.
//
// ## `anchored` and `smoothed` widen it further, and asymmetrically
//
// | selector | start | end |
// |---|---|---|
// | instant, plain | `- (lookbackDelta - 1)` | unchanged |
// | instant, `smoothed` | `- (lookbackDelta - 1)` | **`+ lookbackDelta`** |
// | range, plain | `- (range - 1)` | unchanged |
// | range, `anchored` | `- (lookbackDelta + range - 1)` | unchanged |
// | range, `smoothed` | `- (lookbackDelta + range - 1)` | **`+ lookbackDelta`** |
//
// So `smoothed` is the only modifier that reaches *forward* in time, which is what lets
// `extendedRate` interpolate to a boundary that sits after the last sample in the range.
// Note the instant-selector `smoothed` case extends the end by the full `lookbackDelta`
// while the start gets `lookbackDelta - 1`: the asymmetry is upstream's.
//
// The instant rows are **reachable**, which is not obvious: `foo smoothed` parses on its
// own, without a range. The corpus had no such case at first and the negative control for
// that branch could not fail — it read as dead code and is not.
//
// ## The `@` modifier overrides everything, and a subquery's `@` overrides the offsets
//
// Precedence, from the code: a selector's own `@` replaces both start and end and skips
// the offset arithmetic entirely; failing that, an enclosing subquery's `@` replaces
// them. `subqueryTimes` accumulates offsets and ranges *outward*, and an `@` on a
// subquery **resets** the accumulation to that subquery's own offset and range — because
// the timestamp makes everything inside it absolute.
//
// The two offset subtractions are not the same one applied twice. The subquery offset is
// removed inside the `n.Timestamp == nil` branch; the selector's own `OriginalOffset` is
// removed at the very end, unconditionally — so a selector with both an `@` and an
// `offset` gets the offset applied to the pinned timestamp.
//
// ## `HashRatioSampler` is `limit_ratio`'s determinism
//
// `SampleOffset` is `Hash(labels) / float64(MaxUint64)`, so which series a `limit_ratio`
// keeps depends on the label-set hash — which is `Labels.Hash`, the stringlabels one per
// ADR-1, and *not* portable across Prometheus's own label implementations. A negative
// ratio takes the complement: `>= 1 + ratioLimit` rather than `< ratioLimit`, which is
// how `limit_ratio(-0.1, …)` selects the series `limit_ratio(0.9, …)` drops.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromQLParser

internal import GoCompat
internal import PromModel

/// Go: `subqueryTimes` — the accumulated offset and range of the subqueries on `path`,
/// plus the innermost `@` timestamp if there is one.
///
/// Returns nil for the timestamp when no subquery on the path carries one; Go signals
/// that with a `*int64` left nil, using `math.MaxInt64` as the sentinel internally — so a
/// subquery genuinely pinned to `MaxInt64` would be indistinguishable from none. That is
/// upstream's, and unreachable in practice because `@` takes a float seconds value.
func subqueryTimes(_ path: [any Node]) -> (
    offset: GoDuration, range: GoDuration, timestamp: Int64?
) {
    var subqOffset = GoDuration(nanoseconds: 0)
    var subqRange = GoDuration(nanoseconds: 0)
    var ts = Int64.max

    for node in path {
        guard let n = node as? SubqueryExpr else { continue }
        subqOffset = GoDuration(nanoseconds: subqOffset.nanoseconds &+ n.originalOffset.nanoseconds)
        subqRange = GoDuration(nanoseconds: subqRange.nanoseconds &+ n.range.nanoseconds)
        if let t = n.timestamp {
            // An `@` on a subquery makes everything inside it absolute, so the offsets and
            // ranges accumulated so far are discarded rather than added to.
            subqOffset = n.originalOffset
            subqRange = n.range
            ts = t
        }
    }
    return (subqOffset, subqRange, ts == Int64.max ? nil : ts)
}

/// Go: `getTimeRangesForSelector` — the millisecond span the storage must cover for one
/// selector, given the statement it sits in and the range of any enclosing matrix
/// selector.
///
/// `evalRange` is zero for an instant selector and the matrix selector's range otherwise;
/// the caller threads it in because `parser.Inspect` visits the `MatrixSelector` before
/// the `VectorSelector` inside it.
func getTimeRangesForSelector(
    _ s: EvalStmt, _ n: VectorSelector, _ path: [any Node], _ evalRange: GoDuration
) -> (Int64, Int64) {
    var start = Timestamp.fromTime(s.start)
    var end = Timestamp.fromTime(s.end)
    let (subqOffset, subqRange, subqTs) = subqueryTimes(path)

    if let subqTs {
        // The subquery's timestamp overrides the statement's range.
        start = subqTs
        end = subqTs
    }

    if let t = n.timestamp {
        // The selector's own timestamp overrides everything — including the subquery's.
        start = t
        end = t
    } else {
        let offsetMilliseconds = durationMilliseconds(subqOffset)
        start = start - offsetMilliseconds - durationMilliseconds(subqRange)
        end -= offsetMilliseconds
    }

    if evalRange.nanoseconds == 0 {
        // One fewer millisecond than the lookback delta: a sample exactly `lookbackDelta`
        // before the evaluation time is excluded.
        start -= durationMilliseconds(s.lookbackDelta) - 1
        if n.smoothed {
            end += durationMilliseconds(s.lookbackDelta)
        }
    } else {
        // A range selector needs the range itself, and the extended modifiers need the
        // lookback delta on top: `anchored` to find the last sample at or before the
        // start, `smoothed` to interpolate to both boundaries — which is why only
        // `smoothed` also reaches forward.
        if n.anchored {
            start -=
                durationMilliseconds(
                    GoDuration(nanoseconds: s.lookbackDelta.nanoseconds + evalRange.nanoseconds))
                - 1
        } else if n.smoothed {
            start -=
                durationMilliseconds(
                    GoDuration(nanoseconds: s.lookbackDelta.nanoseconds + evalRange.nanoseconds))
                - 1
            end += durationMilliseconds(s.lookbackDelta)
        } else {
            start -= durationMilliseconds(evalRange) - 1
        }
    }

    // The selector's own offset, applied last and unconditionally — so it shifts a
    // pinned `@` timestamp too.
    let offsetMilliseconds = durationMilliseconds(n.originalOffset)
    start -= offsetMilliseconds
    end -= offsetMilliseconds

    return (start, end)
}

/// Go: `FindMinMaxTime` — the union of every selector's span in the statement.
///
/// With **no selector at all** the answer is `(0, 0)` rather than
/// `(MaxInt64, MinInt64)`: upstream detects the untouched maximum and resets both.
public func findMinMaxTime(_ s: EvalStmt) -> (Int64, Int64) {
    var minTimestamp = Int64.max
    var maxTimestamp = Int64.min
    // Set when a MatrixSelector is visited, and consumed — and cleared — by the
    // VectorSelector inside it. So the two nodes communicate through this one variable,
    // which is why the traversal order matters.
    var evalRange = GoDuration(nanoseconds: 0)

    inspect(s.expr) { node, path in
        if let n = node as? VectorSelector {
            let (start, end) = getTimeRangesForSelector(s, n, path, evalRange)
            if start < minTimestamp {
                minTimestamp = start
            }
            if end > maxTimestamp {
                maxTimestamp = end
            }
            evalRange = GoDuration(nanoseconds: 0)
        } else if let n = node as? MatrixSelector {
            evalRange = n.range
        }
    }

    if maxTimestamp == Int64.min {
        // No selector, so no time range to select.
        minTimestamp = 0
        maxTimestamp = 0
    }

    return (minTimestamp, maxTimestamp)
}

// MARK: - limit_ratio's sampler

/// Go: `RatioSampler` — the seam that lets `limit_ratio` be unit-tested.
public protocol RatioSampler: Sendable {
    func sampleOffset(_ metric: Labels) -> Double
    func addRatioSample(_ ratioLimit: Double, _ sample: Sample) -> Bool
    func addRatioSampleWithOffset(_ ratioLimit: Double, _ sampleOffset: Double) -> Bool
}

/// Go: `HashRatioSampler` — `Hash(labels) / MaxUint64` as a deterministic value in
/// `[0, 1)`.
public struct HashRatioSampler: RatioSampler {
    public init() {}

    /// Go: `SampleOffset`. The divisor is `float64(math.MaxUint64)`, which is not exactly
    /// `2^64 - 1` — it rounds to `2^64` — so the quotient can be exactly 1.0 for a hash
    /// near the top of the range. Reproduced rather than corrected.
    public func sampleOffset(_ metric: Labels) -> Double {
        let float64MaxUint64 = Double(UInt64.max)
        return Double(metric.goHash()) / float64MaxUint64
    }

    public func addRatioSample(_ ratioLimit: Double, _ sample: Sample) -> Bool {
        addRatioSampleWithOffset(ratioLimit, sampleOffset(sample.metric))
    }

    /// Go: `AddRatioSampleWithOffset`. A negative limit takes the complement of the
    /// positive one, so `limit_ratio(-0.1, …)` keeps exactly what `limit_ratio(0.9, …)`
    /// drops.
    ///
    /// Kept as Go's single boolean expression rather than an `if`/`else`: with a NaN limit
    /// **both** halves are false, and the `if` form only reaches that answer by accident
    /// of `1.0 + NaN` comparing false too.
    public func addRatioSampleWithOffset(_ ratioLimit: Double, _ sampleOffset: Double) -> Bool {
        (ratioLimit >= 0 && sampleOffset < ratioLimit)
            || (ratioLimit < 0 && sampleOffset >= (1.0 + ratioLimit))
    }
}

/// Go: `var ratiosampler RatioSampler = NewHashRatioSampler()` — the package-level
/// instance `limit_ratio` uses.
let ratiosampler: any RatioSampler = HashRatioSampler()

// MARK: - 21 negative controls, 19 of which break
//
// Two survivors, both provable rather than gaps:
//
//   * testing `n.Smoothed` before `n.Anchored` instead of after. A selector cannot be
//     both — `foo[5m] anchored smoothed` is a parse error, "anchored and smoothed
//     modifiers cannot be used together" — so the order is unobservable by construction.
//   * writing the ratio divisor as the literal `18446744073709551616.0` instead of
//     `Double(UInt64.max)`. Those are the same number: `float64(math.MaxUint64)` rounds
//     UP to 2^64, which is also why `SampleOffset` can return exactly 1.0 rather than
//     something just below it.
//
// Two others looked like proofs and were corpus gaps, both found by asking what shape
// would separate them:
//
//   * `if n.Smoothed` in the instant branch needed an instant `smoothed` selector, and
//     `foo smoothed` turns out to parse.
//   * clearing `evalRange` after each `VectorSelector` needed a range selector followed by
//     an instant one whose OFFSET makes it the global minimum. In `rate(foo[10m]) + bar`
//     the leaked range gives `bar` the same start `foo` already had, so the bug is
//     invisible; `rate(foo[10m]) + bar offset 1h` separates them.
