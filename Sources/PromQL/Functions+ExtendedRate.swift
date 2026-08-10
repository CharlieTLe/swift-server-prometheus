//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — `extendedRate` and the three helpers
// it needs: `interpolate`, `pickOrInterpolateLeft`/`Right` and
// `correctForCounterResets`.
//
// This is the `anchored`/`smoothed` branch of `rate`, `increase` and `delta` for
// **float** ranges. `extendedHistogramRate` is still deferred: it needs
// `validateHistogramRange`, `pickOrInterpolateLeft`/`RightHistogram`,
// `interpolateHistograms`, `correctForCounterResetsHistogram`,
// `add`/`subHistogramWithAnnotations` and `annosFromInterpolationError` — six more
// helpers and its own annotation vocabulary. The dispatch reaches a
// `preconditionFailure` for it, so a histogram query with those modifiers fails
// loudly rather than silently taking a float path.
//
// ## `anchored` and `smoothed` are different modifiers with one code path
//
// Both make the selector return samples from *outside* the range. What they do with
// them differs, and `smoothed` is the only one that interpolates:
//
// | | `anchored` | `smoothed` |
// |---|---|---|
// | left boundary | the last sample at or before `rangeStart`, used as-is | **interpolated** to `rangeStart` |
// | right boundary | the last sample in the range | **interpolated** to `rangeEnd` |
// | `lastSampleIndex` | `len(f) - 1` | searched back to the first sample at or after `rangeEnd` |
// | early exit | `f[last].T <= rangeStart` | that, plus `f[first].T > rangeEnd` |
//
// So `anchored` is "extend the difference to the true starting value" and `smoothed`
// is "extrapolate linearly to both boundaries". Unlike `extrapolatedRate` neither
// scales by a factor: the boundaries *are* the range, so `isRate` divides by the
// range and nothing else.
//
// ## The counter-reset correction excludes both boundary samples, deliberately
//
// `pickOrInterpolateLeft`/`Right` already fold in a reset at the boundary they touch
// — `interpolate` zeroes `y1` when `y2 < y1` — so including those samples again would
// double-count. Hence the two `if` statements that walk the indices inward before
// slicing. Getting them wrong is invisible on a monotonic series and doubles the
// correction on a reset at a boundary.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromLabels
public import PromQLParser

internal import GoCompat

/// Go: `interpolate` — the linear value at `t` between two points.
///
/// `isCounter` models a reset by treating the earlier value as **0** when the later
/// one is smaller, so the interpolated boundary value sits on the post-reset ramp
/// rather than on a line that runs backwards.
///
/// The grouping `y1 + (y2-y1)*Δt/ΔT` is **left-associated** and load-bearing: it is
/// not `(y2-y1)*(Δt/ΔT)`. Nothing here is fused. See docs/HANDOFF.md §5.
func interpolate(_ p1: FPoint, _ p2: FPoint, _ t: Int64, _ isCounter: Bool) -> Double {
    var y1 = p1.f
    let y2 = p2.f
    if isCounter && y2 < y1 {
        y1 = 0
    }
    return y1 + (y2 - y1) * Double(t - p1.t) / Double(p2.t - p1.t)
}

/// Go: `pickOrInterpolateLeft` — the value at the left boundary.
///
/// Interpolates only when `smoothed` **and** the first sample is genuinely before the
/// range start; otherwise the first sample's value is used unchanged. Note it indexes
/// `floats[first+1]`, so a `smoothed` range whose first sample is before the start
/// must have a second sample — which the caller's early exits guarantee.
func pickOrInterpolateLeft(
    _ floats: [FPoint], _ first: Int, _ rangeStart: Int64, _ smoothed: Bool, _ isCounter: Bool
) -> Double {
    if smoothed && floats[first].t < rangeStart {
        return interpolate(floats[first], floats[first + 1], rangeStart, isCounter)
    }
    return floats[first].f
}

/// Go: `pickOrInterpolateRight` — the value at the right boundary.
///
/// The extra `last > 0` guard is not symmetric with the left helper's: it stops
/// `floats[last-1]` underflowing when the window's last sample is index 0.
func pickOrInterpolateRight(
    _ floats: [FPoint], _ last: Int, _ rangeEnd: Int64, _ smoothed: Bool, _ isCounter: Bool
) -> Double {
    if smoothed && last > 0 && floats[last].t > rangeEnd {
        return interpolate(floats[last - 1], floats[last], rangeEnd, isCounter)
    }
    return floats[last].f
}

/// Go: `correctForCounterResets` — the total that must be added back for the resets
/// strictly *inside* the boundaries.
///
/// The running comparison starts at `left`, not at the first point, and finishes by
/// comparing `right` against the last point — so a reset at either boundary is caught
/// even though the boundary samples themselves are not in `points`.
func correctForCounterResets(_ left: Double, _ right: Double, _ points: [FPoint]) -> Double {
    var correction = 0.0
    var prev = left
    for p in points {
        if p.f < prev {
            correction += prev
        }
        prev = p.f
    }
    if right < prev {
        correction += prev
    }
    return correction
}

/// Go: `extendedRate` — `rate`/`increase`/`delta` over an `anchored` or `smoothed`
/// range of floats.
func extendedRate(
    _ vals: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper,
    _ isCounter: Bool, _ isRate: Bool
) -> (Vector, Annotations) {
    guard let ms = args[0] as? MatrixSelector,
        let vs = ms.vectorSelector as? VectorSelector
    else {
        preconditionFailure("extendedRate's argument is a matrix selector")
    }
    let samples = vals[0]
    let f = samples.floats
    var lastSampleIndex = f.count - 1
    let rangeStart =
        enh.ts
        - durationMilliseconds(
            GoDuration(nanoseconds: ms.range.nanoseconds + vs.offset.nanoseconds))
    let rangeEnd = enh.ts - durationMilliseconds(vs.offset)
    let annos = Annotations()
    let smoothed = vs.smoothed

    // Note both searches are bounded by `lastSampleIndex`, not by `f.count`, so the
    // final sample is never a search result — Go's `sort.Search(lastSampleIndex, …)`.
    var firstSampleIndex = Swift.max(
        0, lowerBound(lastSampleIndex, { f[$0].t > rangeStart }) - 1)
    if smoothed {
        lastSampleIndex = lowerBound(lastSampleIndex, { f[$0].t >= rangeEnd })
    }

    if f[lastSampleIndex].t <= rangeStart {
        return (enh.out, annos)
    }
    if smoothed && f[firstSampleIndex].t > rangeEnd {
        return (enh.out, annos)
    }

    let left = pickOrInterpolateLeft(f, firstSampleIndex, rangeStart, smoothed, isCounter)
    let right = pickOrInterpolateRight(f, lastSampleIndex, rangeEnd, smoothed, isCounter)

    var resultFloat = right - left

    if isCounter {
        // Only samples strictly inside the range need reset correction:
        // `pickOrInterpolateLeft`/`Right` already folded in a reset at the boundary
        // they touched, so including those samples would double-count.
        if f[firstSampleIndex].t <= rangeStart {
            firstSampleIndex += 1
        }
        if f[lastSampleIndex].t >= rangeEnd {
            lastSampleIndex -= 1
        }
        let inside =
            firstSampleIndex <= lastSampleIndex
            ? Array(f[firstSampleIndex...lastSampleIndex]) : []
        resultFloat += correctForCounterResets(left, right, inside)
    }
    if isRate {
        resultFloat /= ms.range.seconds
    }

    var out = enh.out
    out.append(Sample(f: resultFloat))
    return (out, annos)
}

/// Go: `sort.Search` — the first index in `0..<n` for which `pred` holds, or `n`.
///
/// Duplicated from `Functions+Counters.swift` rather than shared: the two are separate
/// `sort.Search` call sites upstream and keeping them local means each reads against
/// its own Go line.
private func lowerBound(_ n: Int, _ pred: (Int) -> Bool) -> Int {
    var low = 0
    var high = n
    while low < high {
        let mid = low + (high - low) / 2
        if pred(mid) {
            high = mid
        } else {
            low = mid + 1
        }
    }
    return low
}
