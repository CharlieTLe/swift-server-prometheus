//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — `extendedHistogramRate` and the six
// helpers it needs: `interpolateHistograms`,
// `pickOrInterpolateLeft`/`RightHistogram`, `validateHistogramRange`,
// `correctForCounterResetsHistogram`, `add`/`subHistogramWithAnnotations` and
// `annosFromInterpolationError`.
//
// This is the `anchored`/`smoothed` branch of `rate`, `increase` and `delta` for
// **native histogram** ranges — the counterpart of `Functions+ExtendedRate.swift`,
// which handles floats. With this file the dispatch in `extrapolatedRate` no longer
// has a deferred arm.
//
// ## The float and histogram versions are the same shape, and differ in five places
//
// The index arithmetic, the two `sort.Search` bounds and both early exits are
// identical. Beyond that:
//
// | | float | histogram |
// |---|---|---|
// | pre-flight validation | none | `validateHistogramRange` over the window |
// | boundary interpolation | cannot fail | **fails** — a mix of exponential and custom-bucket schemas |
// | the not-a-gauge warning for `delta` | absent | on `left`/`right`, `\|\|` not `&&` |
// | the inward index walk | in `extendedRate` itself | inside `correctForCounterResetsHistogram` |
// | the result's hint | n/a | forced to `gaugeType`, then compacted |
//
// The fourth is the one to watch: `extendedRate` mutates `firstSampleIndex` and
// `lastSampleIndex` before slicing, while `extendedHistogramRate` passes the
// *unmodified* indices down and lets the callee do its own walking — and the callee's
// walk is not the same walk. See below.
//
// ## Why the histogram correction skips a *second* sample sometimes
//
// The float version excludes both boundary samples because `interpolate` already
// folded a boundary reset into the value it returned. Histograms need one more step.
// When the left interpolation spanned a reset — `smoothed`, the first sample is before
// `rangeStart`, and `h[first+1]` resets against `h[first]` — that reset is already
// accounted for, so `h[first+1]` is skipped as well *and becomes the comparison anchor*
// for whatever follows it. Both `first += 1` and `prev = h[first+1].H` matter, and they
// matter separately.
//
// The right boundary is excluded unconditionally, for a different reason than the
// left: `right` is either a copy of `h[last]` or an interpolation that **inherits its
// `CounterResetHint`**, so `right.DetectReset(h[last])` would self-detect on that hint.
// The final `right.DetectReset(prev)` after the loop is safe precisely because
// `h[last]` is no longer `prev`.
//
// `first > last+1` is therefore the "nothing left to check" test, and it is reached two
// ways: a single-sample window, or a two-sample window whose one reset interval the
// left interpolation already spanned.
//
// ## Upstream's own TODO: the schema is reduced on the fly here, not up front
//
// `histogramRate` pre-computes the minimum schema across the whole range and pulls
// every sample down to it before any arithmetic. `extendedHistogramRate` does not — it
// reduces during the pairwise `Sub`/`Add`. On a constant-schema range the two agree; on
// a mixed one the final schema still agrees (the global minimum wins either way) but
// intermediate values sit briefly at a higher resolution. Upstream calls aligning them
// a non-trivial change deserving its own PR (functions.go:364), and the corpus carries a
// mixed-schema range so the current behaviour is pinned rather than assumed.
//
// ## `annosFromInterpolationError`'s unrecognised-error branch is unreachable today
//
// It only annotates `ErrHistogramsIncompatibleSchema` and leaves `annos` alone
// otherwise — but `Add`/`Sub` return that error and no other, so the else is dead from
// every current caller. A claim about today's callers, not about the code (quirk 52).
//
// Stronger, and worth stating because it makes a whole family of `if err != nil` arms
// look untested: **once `validateHistogramRange` passes, nothing here can fail.** Every
// histogram the arithmetic touches — both interpolation operands, `left`, `right`, each
// `prev` and the accumulated correction — comes from the validated window, and
// `checkSchemaAndBounds` is the only source of an error. So both `err != nil` returns in
// `extendedHistogramRate`, both `catch` blocks in the add/sub wrappers, and
// `annosFromInterpolationError` itself are unreachable from this file. They are
// transcribed because upstream has them, not because a corpus case exercises them.
//
// ## 30 negative controls: 22 break, and the eight survivors all have proofs
//
// Four are unobservable no matter what the corpus does:
//
//   * the `last > 0` guard in `pickOrInterpolateRightHistogram` — reachable only when
//     `last == 0 && hists[0].T > rangeEnd`, which the caller's `h[first].T > rangeEnd`
//     exit has already returned on. The float version's guard is the same.
//   * `validateHistogramRange` anchoring `usingCustomBuckets` on `h[0]` versus the last
//     sample. Either anchor detects any mismatch — at a different iteration — and both
//     return false with the same annotation, so the choice cannot show.
//   * bounding the first `sort.Search` by `lastSampleIndex` rather than `len(h)`. The two
//     differ only when the predicate is false throughout, i.e. **every** sample is at or
//     before `rangeStart` — and then `h[lastSampleIndex].T <= rangeStart` exits before
//     the index is used. This also settles the same open control in the float file.
//   * `right.Copy()` before the subtraction. Go needs it; Swift's value semantics make
//     the copy unobservable by construction.
//
// The other four are two INTERLOCKED PAIRS, where each perturbation is absorbed by its
// partner and only the joint perturbation shows:
//
//   * `pickOrInterpolateLeftHistogram`'s `<` versus `<=` is invisible because at Δt = 0
//     `interpolateHistograms` short-circuits on `t == t1` and returns `h1.Copy()` — the
//     same thing the non-interpolating branch returns. Drop the short-circuit as well and
//     the arithmetic path runs: for NHCBs with different bounds it reconciles the two
//     layouts, so it yields h1's counts on *intersected* bounds and emits two extra
//     infos. The corpus carries that shape, and the joint control breaks on it.
//   * `>` versus `>=` on the right pairs with `t == t2` in exactly the same way, and is
//     witnessed by an NHCB sitting exactly on `rangeEnd`.
//
// Which is also the honest reading of the two short-circuits: from these two callers they
// are pure optimisations. The left interpolates only when `hists[first].T < rangeStart`,
// so `t == t1` cannot hold; and `t == t2` would need `hists[first+1].T == rangeStart`,
// which would have made *that* sample `firstSampleIndex`. Symmetrically on the right.
//===----------------------------------------------------------------------===//

// Every declaration here is internal — `extendedHistogramRate` is reached through the
// `functionCalls` table, never named — so nothing needs a `public import`.
internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromPosRange
internal import PromQLParser

/// Go: `errors.Is(err, histogram.ErrHistogramsIncompatibleSchema)`.
///
/// The chain walk stands in for `errors.Is`: nothing in the arithmetic path wraps
/// today (only `Validate` does), but a bare `==` would silently stop matching the day
/// one does.
private func isIncompatibleSchema(_ err: any Error) -> Bool {
    var cur = err as? HistogramError
    while let e = cur {
        if case .incompatibleSchema = e { return true }
        guard case .wrapped(_, let inner) = e else { return false }
        cur = inner
    }
    return false
}

/// Go: `annosFromInterpolationError` — turn an interpolation failure into the warning
/// that names it.
func annosFromInterpolationError(
    _ annos: inout Annotations, _ err: any Error, _ metricName: String, _ pos: PositionRange
) {
    if isIncompatibleSchema(err) {
        annos.add(newMixedExponentialCustomHistogramsWarning(metricName, pos))
    }
}

/// Go: `addHistogramWithAnnotations` — `base += other`, with the failure and the
/// bucket-bounds reconciliation both reported as annotations.
///
/// Returns false when the addition failed, in which case the caller abandons the
/// sample entirely. `base` is untouched on failure because the schema check is the
/// first thing `add` does.
func addHistogramWithAnnotations(
    _ base: inout FloatHistogram, _ other: FloatHistogram,
    _ annos: inout Annotations, _ metricName: String, _ pos: PositionRange
) -> Bool {
    do {
        if try base.add(other).nhcbBoundsReconciled {
            annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .add))
        }
    } catch {
        if isIncompatibleSchema(error) {
            annos.add(newMixedExponentialCustomHistogramsWarning(metricName, pos))
        }
        return false
    }
    return true
}

/// Go: `subHistogramWithAnnotations` — `base -= other`, otherwise identical to the
/// addition. Note the reconciliation info carries `HistogramSub`, so the two are
/// distinguishable in the output.
func subHistogramWithAnnotations(
    _ base: inout FloatHistogram, _ other: FloatHistogram,
    _ annos: inout Annotations, _ metricName: String, _ pos: PositionRange
) -> Bool {
    do {
        if try base.sub(other).nhcbBoundsReconciled {
            annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .sub))
        }
    } catch {
        if isIncompatibleSchema(error) {
            annos.add(newMixedExponentialCustomHistogramsWarning(metricName, pos))
        }
        return false
    }
    return true
}

/// Go: `interpolateHistograms` — the linear histogram at `t` between two points.
///
/// Three cases, in order: `t` on either endpoint returns a copy of it; a counter reset
/// returns `h2 * fraction`, modelling the counter as having restarted from zero; and
/// otherwise `h1 + (h2 - h1) * fraction`, spelled as a subtraction, a scale and an
/// addition — each of which may reconcile NHCB bounds and say so.
///
/// The endpoint short-circuits are what make `interpolateHistograms` total on a
/// zero-width interval: without them `fraction` would be `0/0`.
func interpolateHistograms(
    _ h1: FloatHistogram, _ t1: Int64, _ h2: FloatHistogram, _ t2: Int64, _ t: Int64,
    _ isCounter: Bool, _ annos: inout Annotations, _ pos: PositionRange
) throws -> FloatHistogram {
    if t == t1 {
        return h1.copy()
    }
    if t == t2 {
        return h2.copy()
    }
    let fraction = Double(t - t1) / Double(t2 - t1)

    if isCounter && h2.detectReset(h1) {
        // A reset: model the counter as starting from zero.
        var scaled = h2.copy()
        _ = scaled.mul(fraction)
        return scaled
    }

    // Result = H1 + (H2 - H1) * fraction.
    var result = h2.copy()
    if try result.sub(h1).nhcbBoundsReconciled {
        annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .sub))
    }
    _ = result.mul(fraction)
    if try result.add(h1).nhcbBoundsReconciled {
        annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .add))
    }
    return result
}

/// Go: `pickOrInterpolateLeftHistogram` — the histogram at the left boundary.
///
/// The non-interpolating path still **copies**: the caller subtracts it from the result
/// in place, so handing out the matrix's own histogram would corrupt the series.
func pickOrInterpolateLeftHistogram(
    _ hists: [HPoint], _ first: Int, _ rangeStart: Int64, _ smoothed: Bool, _ isCounter: Bool,
    _ annos: inout Annotations, _ pos: PositionRange
) throws -> FloatHistogram {
    if smoothed && hists[first].t < rangeStart {
        return try interpolateHistograms(
            hists[first].h, hists[first].t, hists[first + 1].h, hists[first + 1].t,
            rangeStart, isCounter, &annos, pos)
    }
    return hists[first].h.copy()
}

/// Go: `pickOrInterpolateRightHistogram` — the histogram at the right boundary.
///
/// The asymmetric `last > 0` guard is the float helper's, for the same reason: it stops
/// `hists[last-1]` underflowing.
func pickOrInterpolateRightHistogram(
    _ hists: [HPoint], _ last: Int, _ rangeEnd: Int64, _ smoothed: Bool, _ isCounter: Bool,
    _ annos: inout Annotations, _ pos: PositionRange
) throws -> FloatHistogram {
    if smoothed && last > 0 && hists[last].t > rangeEnd {
        return try interpolateHistograms(
            hists[last - 1].h, hists[last - 1].t, hists[last].h, hists[last].t,
            rangeEnd, isCounter, &annos, pos)
    }
    return hists[last].h.copy()
}

/// Go: `validateHistogramRange` — reject a window that mixes exponential and
/// custom-bucket schemas, and warn about gauge hints where a counter was expected.
///
/// The two checks are not alike: the schema mix **returns false** and abandons the
/// sample, while a gauge hint only annotates and the loop continues. So one window can
/// produce a warning per gauge sample and still yield a value — `Annotations` being a
/// map, they collapse to one.
func validateHistogramRange(
    _ h: [HPoint], _ isCounter: Bool, _ annos: inout Annotations,
    _ metricName: String, _ pos: PositionRange
) -> Bool {
    let usingCustomBuckets = h[0].h.usesCustomBuckets
    for p in h {
        if p.h.usesCustomBuckets != usingCustomBuckets {
            annos.add(newMixedExponentialCustomHistogramsWarning(metricName, pos))
            return false
        }
        if isCounter && p.h.counterResetHint == .gaugeType {
            annos.add(newNativeHistogramNotCounterWarning(metricName, pos))
        }
    }
    return true
}

/// Go: `correctForCounterResetsHistogram` — the histogram counterpart of
/// `correctForCounterResets`, returning the total to add back, the annotations it
/// collected, and false when combining two histograms failed.
///
/// The window walked is `h[first...last]` where `first` is *at least*
/// `firstSampleIndex + 1` and `last` is `lastSampleIndex - 1`. See the file header for
/// why the left may skip two samples and the right always skips one.
func correctForCounterResetsHistogram(
    _ h: [HPoint], _ firstSampleIndex: Int, _ lastSampleIndex: Int,
    _ left: FloatHistogram, _ right: FloatHistogram, _ rangeStart: Int64,
    _ smoothed: Bool, _ metricName: String, _ pos: PositionRange
) -> (FloatHistogram?, Annotations, Bool) {
    // `firstSampleIndex` is represented by `left`, so the loop starts one beyond.
    var first = firstSampleIndex + 1
    var prev = left
    if smoothed && h[firstSampleIndex].t < rangeStart
        && h[firstSampleIndex + 1].h.detectReset(h[firstSampleIndex].h)
    {
        // The left interpolation spanned this reset, so skip the sample AND use it as
        // the anchor for any reset immediately after it.
        prev = h[firstSampleIndex + 1].h
        first += 1
    }
    // `lastSampleIndex` is always excluded: `right` inherits its `counterResetHint`, so
    // including it would make `right.detectReset` self-detect.
    let last = lastSampleIndex - 1

    // Nothing between the two boundary samples: a single-sample window, or a two-sample
    // window whose only reset interval the left interpolation already covered.
    if first > last + 1 {
        return (nil, Annotations(), true)
    }

    var correction: FloatHistogram? = nil
    var annos = Annotations()

    func addCorrection(_ x: FloatHistogram) -> Bool {
        guard var c = correction else {
            correction = x.copy()
            return true
        }
        let ok = addHistogramWithAnnotations(&c, x, &annos, metricName, pos)
        correction = c
        return ok
    }

    // `first..<(last + 1)` rather than `first...last`: Go's `h[first:last+1]` is a legal
    // EMPTY slice when `first == last+1`, which the guard above deliberately lets
    // through, and a Swift closed range would trap on it.
    for p in h[first..<(last + 1)] {
        if p.h.detectReset(prev) {
            if !addCorrection(prev) {
                return (nil, annos, false)
            }
        }
        prev = p.h
    }
    if right.detectReset(prev) {
        if !addCorrection(prev) {
            return (nil, annos, false)
        }
    }
    return (correction, annos, true)
}

/// Go: `extendedHistogramRate` — `rate`/`increase`/`delta` over an `anchored` or
/// `smoothed` range of native histograms.
func extendedHistogramRate(
    _ vals: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper,
    _ isCounter: Bool, _ isRate: Bool
) -> (Vector, Annotations) {
    guard let ms = args[0] as? MatrixSelector,
        let vs = ms.vectorSelector as? VectorSelector
    else {
        preconditionFailure("extendedHistogramRate's argument is a matrix selector")
    }
    let samples = vals[0]
    let h = samples.histograms
    var lastSampleIndex = h.count - 1
    let rangeStart =
        enh.ts
        - durationMilliseconds(
            GoDuration(nanoseconds: ms.range.nanoseconds + vs.offset.nanoseconds))
    let rangeEnd = enh.ts - durationMilliseconds(vs.offset)
    var annos = Annotations()
    let metricName = getMetricName(samples.metric)
    let pos = args[0].positionRange
    let smoothed = vs.smoothed

    // Both searches are bounded by `lastSampleIndex` rather than by `h.count`, exactly
    // as in the float version.
    let firstSampleIndex = Swift.max(
        0, lowerBoundHist(lastSampleIndex, { h[$0].t > rangeStart }) - 1)
    if smoothed {
        lastSampleIndex = lowerBoundHist(lastSampleIndex, { h[$0].t >= rangeEnd })
    }

    if h[lastSampleIndex].t <= rangeStart {
        return (enh.out, annos)
    }
    if smoothed && h[firstSampleIndex].t > rangeEnd {
        return (enh.out, annos)
    }

    if !validateHistogramRange(
        Array(h[firstSampleIndex...lastSampleIndex]), isCounter, &annos, metricName, pos)
    {
        return (enh.out, annos)
    }

    let left: FloatHistogram
    let right: FloatHistogram
    do {
        left = try pickOrInterpolateLeftHistogram(
            h, firstSampleIndex, rangeStart, smoothed, isCounter, &annos, pos)
    } catch {
        annosFromInterpolationError(&annos, error, metricName, pos)
        return (enh.out, annos)
    }
    do {
        right = try pickOrInterpolateRightHistogram(
            h, lastSampleIndex, rangeEnd, smoothed, isCounter, &annos, pos)
    } catch {
        annosFromInterpolationError(&annos, error, metricName, pos)
        return (enh.out, annos)
    }

    // `delta` is for gauges, and — like `histogramRate` — the test is `||`, so one
    // non-gauge boundary is enough to warn.
    if !isCounter
        && (left.counterResetHint != .gaugeType || right.counterResetHint != .gaugeType)
    {
        annos.add(newNativeHistogramNotGaugeWarning(metricName, pos))
    }

    // Go copies `right` here so that `correctForCounterResetsHistogram` can still call
    // `right.DetectReset` without observing the subtraction. Swift's value semantics
    // make that free, but the call site is preserved (PORTING.md §4).
    var resultHistogram = right.copy()
    if !subHistogramWithAnnotations(&resultHistogram, left, &annos, metricName, pos) {
        return (enh.out, annos)
    }

    if isCounter {
        let (correction, newAnnos, ok) = correctForCounterResetsHistogram(
            h, firstSampleIndex, lastSampleIndex, left, right, rangeStart, smoothed,
            metricName, pos)
        _ = annos.merge(newAnnos)
        if !ok {
            return (enh.out, annos)
        }
        if let correction,
            !addHistogramWithAnnotations(
                &resultHistogram, correction, &annos, metricName, pos)
        {
            return (enh.out, annos)
        }
    }
    if isRate {
        _ = resultHistogram.div(ms.range.seconds)
    }

    resultHistogram.counterResetHint = .gaugeType
    var out = enh.out
    out.append(Sample(h: resultHistogram.compact(maxEmptyBuckets: 0)))
    return (out, annos)
}

/// Go: `sort.Search`. Local for the same reason as `Functions+ExtendedRate.swift`'s
/// copy: these are distinct upstream call sites and each reads against its own lines.
private func lowerBoundHist(_ n: Int, _ pred: (Int) -> Bool) -> Int {
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
