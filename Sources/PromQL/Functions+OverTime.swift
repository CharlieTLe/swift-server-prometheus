//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the float-only range aggregations.
//
// `aggrOverTime` and the thirteen `FunctionCalls` entries that go through it or
// alongside it: `count_over_time`, `first_over_time`, `last_over_time`,
// `ts_of_first_over_time`, `ts_of_last_over_time`, `max_over_time`,
// `min_over_time`, `ts_of_max_over_time`, `ts_of_min_over_time`,
// `stddev_over_time`, `stdvar_over_time`, `present_over_time`,
// `absent_over_time`, `quantile_over_time` and `mad_over_time`.
//
// ## What is deliberately not here
//
//   * `sum_over_time` and `avg_over_time` — both have a **histogram** path built on
//     `FloatHistogram.KahanAdd`/`HasOverflow`/`Div`/`Mul`, and `avg_over_time`'s
//     switches from a direct mean to an incremental one the moment the running sum
//     overflows. That is its own slice.
//   * `resets` and `changes` — they read `enh.StartTimestamps` and go through
//     `pickFirstSampleIndices`/`isStartTimestampReset`, i.e. the start-timestamp
//     machinery that arrives with Phases 6-7.
//   * the rate family (`rate`, `increase`, `delta`, `irate`, `idelta`, `deriv`,
//     `predict_linear`, `double_exponential_smoothing`) — `interpolate`,
//     `correctForCounterResets` and four load-bearing groupings from the fusion map.
//
// ## Only the FIRST series is ever read
//
// Every function here takes a `Matrix` and looks at `matrixVal[0]` alone. That is
// not a simplification: `rangeEval` calls the function once per input series, so the
// matrix it hands over has exactly one entry. A port that looped over the matrix
// would produce one sample per series *per series* and be silently wrong only for
// multi-series input — which the oracle can construct even though the evaluator
// cannot, so the corpus pins it.
//
// ## The three guards are not the same guard
//
//   * `len(matrixVal) == 0` returns `enh.Out` — no series, no output.
//   * `len(samples.Floats) == 0` returns `enh.Out` **without an annotation**, so a
//     histogram-only range yields nothing at all from `max_over_time`.
//   * `len(samples.Histograms) > 0` *adds* `HistogramIgnoredInMixedRangeInfo` and
//     carries on with the floats.
//
// `count_over_time` and `present_over_time` have none of them and count both kinds;
// `first_over_time` and `last_over_time` compare timestamps across the two lists.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromLabels
public import PromQLParser

internal import PromMath
public import PromHistogram

/// Go: `aggrOverTime` — apply `aggrFn` to the matrix's single series.
///
/// Returns a `Sample` carrying only `F`: the caller fills in the metric and
/// timestamp, which is why this drops `el.Metric` on the floor.
func aggrOverTime(
    _ matrixVal: Matrix, _ enh: EvalNodeHelper, _ aggrFn: (Series) -> Double
) -> Vector {
    if matrixVal.isEmpty {
        return enh.out
    }
    let el = matrixVal[0]
    // Go writes `return append(enh.Out, …)` and does **not** assign back to the field,
    // so `enh.Out` keeps its original length. That is invisible for every caller that
    // returns this value straight through — and load-bearing for `funcSumOverTime`,
    // which on its error path returns `enh.Out` and thereby *discards* the sample this
    // appended. Four fixture cases depend on it.
    var out = enh.out
    out.append(Sample(f: aggrFn(el)))
    return out
}

/// Go: `funcCountOverTime` — the number of samples, **floats and histograms
/// together**.
func funcCountOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (aggrOverTime(m, enh) { Double($0.floats.count + $0.histograms.count) }, Annotations())
}

/// Go: `funcPresentOverTime` — 1 if the series exists at all.
///
/// It goes through `aggrOverTime`, so the empty-matrix guard is what makes it absent
/// rather than 0.
func funcPresentOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (aggrOverTime(m, enh) { _ in 1 }, Annotations())
}

/// Go: `funcAbsentOverTime` — always 1, reading nothing.
///
/// The *selection* is what makes `absent_over_time` meaningful: the evaluator only
/// calls it when the range matched nothing, and `createLabelsForAbsentFunction`
/// supplies the labels. So this body is unconditional and its metric is empty.
func funcAbsentOverTime(_: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    enh.out.append(Sample(f: 1))
    return (enh.out, Annotations())
}

/// Go: `funcFirstOverTime` — the earliest sample, whichever kind it is.
///
/// The tie-break reads oddly and is deliberate: `h.H == nil || (len(el.Floats) > 0 && f.T < h.T)`
/// picks the float when there is no histogram **or** when the float is strictly
/// earlier. So at an equal timestamp the **histogram** wins, and a range with no
/// floats at all still takes the float branch when it also has no histograms —
/// yielding `F = 0` rather than nothing.
func funcFirstOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let el = m[0]
    var f = FPoint(t: 0, f: 0)
    if !el.floats.isEmpty {
        f = el.floats[0]
    }
    var h: HPoint? = nil
    if !el.histograms.isEmpty {
        h = el.histograms[0]
    }
    if h == nil || (!el.floats.isEmpty && f.t < h!.t) {
        enh.out.append(Sample(f: f.f, metric: el.metric))
        return (enh.out, Annotations())
    }
    // `Copy()` is preserved even though the port has no `sync.Pool`: PORTING.md
    // exception 4 keeps every explicit copy, because the engine reuses histogram
    // pointers and aliasing here would be observable.
    var out = Sample(metric: el.metric)
    out.h = h!.h.copy()
    enh.out.append(out)
    return (enh.out, Annotations())
}

/// Go: `funcLastOverTime` — the latest sample.
///
/// The mirror of ``funcFirstOverTime(_:_:_:_:)``, and note the comparison flips to
/// `h.T < f.T`: at an equal timestamp the histogram wins here too.
func funcLastOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let el = m[0]
    var f = FPoint(t: 0, f: 0)
    if !el.floats.isEmpty {
        f = el.floats[el.floats.count - 1]
    }
    var h: HPoint? = nil
    if !el.histograms.isEmpty {
        h = el.histograms[el.histograms.count - 1]
    }
    if h == nil || (!el.floats.isEmpty && h!.t < f.t) {
        enh.out.append(Sample(f: f.f, metric: el.metric))
        return (enh.out, Annotations())
    }
    var out = Sample(metric: el.metric)
    out.h = h!.h.copy()
    enh.out.append(out)
    return (enh.out, Annotations())
}

/// Go: `funcTsOfFirstOverTime` — the earliest timestamp, in seconds.
///
/// Missing lists default to `math.MaxInt64` and the answer is `min(tf, th)`, so an
/// **empty** series (no floats, no histograms) reports `MaxInt64 / 1000` rather than
/// nothing. Reachable only from the oracle, but it is the behaviour.
func funcTsOfFirstOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let el = m[0]
    var tf = Int64.max
    if !el.floats.isEmpty {
        tf = el.floats[0].t
    }
    var th = Int64.max
    if !el.histograms.isEmpty {
        th = el.histograms[0].t
    }
    enh.out.append(Sample(f: Double(min(tf, th)) / 1000, metric: el.metric))
    return (enh.out, Annotations())
}

/// Go: `funcTsOfLastOverTime` — the latest timestamp, in seconds.
///
/// The defaults are **0** here rather than `MaxInt64`, and the answer is
/// `max(tf, th)`, so an empty series reports 0. Asymmetric with
/// ``funcTsOfFirstOverTime(_:_:_:_:)`` on purpose.
func funcTsOfLastOverTime(_: [Vector], _ m: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let el = m[0]
    var tf: Int64 = 0
    if !el.floats.isEmpty {
        tf = el.floats[el.floats.count - 1].t
    }
    var th: Int64 = 0
    if !el.histograms.isEmpty {
        th = el.histograms[el.histograms.count - 1].t
    }
    enh.out.append(Sample(f: Double(max(tf, th)) / 1000, metric: el.metric))
    return (enh.out, Annotations())
}

/// Go: `compareOverTime` — the shared body of `max_over_time`, `min_over_time` and
/// their `ts_of_` variants.
///
/// Two things worth pinning:
///
///   * the loop starts at `s.Floats[0]` and then iterates **from index 0 again**, so
///     the first sample is compared against itself. Harmless, and reproduced.
///   * `compareFn` is `(cur > maxVal) || IsNaN(maxVal)`, so a NaN running value is
///     always replaced. That makes `max_over_time` skip leading NaNs — but a NaN
///     *later* in the series is never adopted, because `NaN > x` is false. So the
///     result is NaN only if **every** sample is NaN.
///
/// `ts_of_max_over_time` uses `>=` where `max_over_time` uses `>`, so the former
/// reports the **last** occurrence of the maximum and the latter keeps the first.
func compareOverTime(
    _ matrixVal: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper,
    _ compareFn: (Double, Double) -> Bool, _ returnTimestamp: Bool
) -> (Vector, Annotations) {
    if matrixVal.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = matrixVal[0]
    var annos = Annotations()
    if samples.floats.isEmpty {
        // No annotation: a histogram-only range yields nothing at all.
        return (enh.out, Annotations())
    }
    if !samples.histograms.isEmpty {
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
    }
    let out = aggrOverTime(matrixVal, enh) { s in
        var maxVal = s.floats[0].f
        var tsOfMax = s.floats[0].t
        for f in s.floats where compareFn(f.f, maxVal) {
            maxVal = f.f
            tsOfMax = f.t
        }
        if returnTimestamp {
            return Double(tsOfMax) / 1000
        }
        return maxVal
    }
    return (out, annos)
}

/// Go: `funcMaxOverTime`.
func funcMaxOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    compareOverTime(m, args, enh, { cur, maxVal in cur > maxVal || maxVal.isNaN }, false)
}

/// Go: `funcMinOverTime`.
func funcMinOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    compareOverTime(m, args, enh, { cur, minVal in cur < minVal || minVal.isNaN }, false)
}

/// Go: `funcTsOfMaxOverTime` — note the `>=`, which makes this report the **last**
/// occurrence of the maximum where `max_over_time` keeps the first.
func funcTsOfMaxOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper)
    -> (Vector, Annotations)
{
    compareOverTime(m, args, enh, { cur, maxVal in cur >= maxVal || maxVal.isNaN }, true)
}

/// Go: `funcTsOfMinOverTime` — `<=`, so the last occurrence of the minimum.
func funcTsOfMinOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper)
    -> (Vector, Annotations)
{
    compareOverTime(m, args, enh, { cur, minVal in cur <= minVal || minVal.isNaN }, true)
}

/// Go: `varianceOverTime` — Welford's online variance, with **both** accumulators
/// Kahan-compensated.
///
/// The shape is not the textbook Welford and every part of it matters:
///
///   * `delta` is against `mean + cMean`, the *compensated* mean, not `mean`.
///   * the second Kahan term reads `mean + cMean` **again, after the update**, so it
///     uses the new mean. Hoisting either read changes the result.
///   * the divisor is `count`, not `count - 1`: PromQL's `stdvar_over_time` is the
///     population variance.
///
/// Neither `delta/count` nor `delta*(…)` may be fused into its Kahan step —
/// `util/kahansum` casts through `float64(...)` to forbid exactly that.
func varianceOverTime(
    _ matrixVal: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper,
    _ varianceToResult: ((Double) -> Double)?
) -> (Vector, Annotations) {
    if matrixVal.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = matrixVal[0]
    var annos = Annotations()
    if samples.floats.isEmpty {
        return (enh.out, Annotations())
    }
    if !samples.histograms.isEmpty {
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
    }
    let out = aggrOverTime(matrixVal, enh) { s in
        var count = 0.0
        var mean = 0.0
        var cMean = 0.0
        var aux = 0.0
        var cAux = 0.0
        for f in s.floats {
            count += 1
            let delta = f.f - (mean + cMean)
            (mean, cMean) = Kahan.inc(delta / count, mean, cMean)
            // `mean + cMean` re-read AFTER the update: the new mean, not the old.
            (aux, cAux) = Kahan.inc(delta * (f.f - (mean + cMean)), aux, cAux)
        }
        let variance = (aux + cAux) / count
        if let varianceToResult {
            return varianceToResult(variance)
        }
        return variance
    }
    return (out, annos)
}

/// Go: `funcStddevOverTime`.
func funcStddevOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper)
    -> (Vector, Annotations)
{
    varianceOverTime(m, args, enh) { $0.squareRoot() }
}

/// Go: `funcStdvarOverTime`.
func funcStdvarOverTime(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper)
    -> (Vector, Annotations)
{
    varianceOverTime(m, args, enh, nil)
}

// MARK: - The two that go through `quantile`

/// Go: `funcQuantileOverTime` — the φ-quantile of a range's float values.
///
/// Three things worth pinning:
///
///   * the guard is `len(vectorVals) == 0 || len(vectorVals[0]) == 0 || len(matrixVal) == 0`,
///     then a *separate* `len(el.Floats) == 0`. So a histogram-only range yields
///     nothing and raises **no** annotation, exactly as ``compareOverTime`` does.
///   * an out-of-range or NaN `q` warns and still computes, and the warning is
///     reported against **`args[0]`** — which is the quantile. So is the
///     mixed-range info, even though that one is about the *range*.
///   * this does **not** go through ``aggrOverTime(_:_:_:)``; it appends directly.
///     Indistinguishable in behaviour, and spelled as Go spells it.
///
/// The ordering caveat matters here: `promql.quantile` sorts with a comparator that
/// is not a strict weak ordering (`IsNaN(vi)` returns true unconditionally, so NaN
/// compares less than itself). With **two or more** NaNs in the range Go's own answer
/// is unspecified, so the corpus keeps to at most one — see
/// ``PromQL/quantile(_:_:)``.
func funcQuantileOverTime(
    _ v: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if v.isEmpty || v[0].isEmpty || m.isEmpty {
        return (enh.out, Annotations())
    }
    let q = v[0][0].f
    let el = m[0]
    if el.floats.isEmpty {
        return (enh.out, Annotations())
    }

    var annos = Annotations()
    if q.isNaN || q < 0 || q > 1 {
        annos.add(newInvalidQuantileWarning(q, args[0].positionRange))
    }
    if !el.histograms.isEmpty {
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(el.metric), args[0].positionRange))
    }
    enh.out.append(Sample(f: quantile(q, el.floats.map(\.f))))
    return (enh.out, annos)
}

/// Go: `funcMadOverTime` — the median absolute deviation.
///
/// Two passes over the same values, each building a fresh list and taking the
/// **median** through the same `quantile` as `quantile_over_time`: first the median
/// of the values, then the median of `|value - median|`.
///
/// Note the guards run *before* `aggrOverTime` and the annotation is attached to the
/// outer return, so a mixed range warns even though the histograms are then ignored.
func funcMadOverTime(
    _: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = m[0]
    var annos = Annotations()
    if samples.floats.isEmpty {
        return (enh.out, Annotations())
    }
    if !samples.histograms.isEmpty {
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
    }
    let out = aggrOverTime(m, enh) { s in
        let median = quantile(0.5, s.floats.map(\.f))
        return quantile(0.5, s.floats.map { Swift.abs($0.f - median) })
    }
    return (out, annos)
}

// MARK: - sum_over_time, and the histogram aggregation path

/// Go: `aggrHistOverTime` — ``aggrOverTime(_:_:_:)``'s histogram twin, propagating an
/// error out of the aggregation.
///
/// The error is *not* swallowed: `funcSumOverTime` maps an incompatible-schema failure
/// onto a warning, and returns the partial `Sample` regardless — so a failed
/// aggregation still appends whatever the closure got to.
func aggrHistOverTime(
    _ matrixVal: Matrix, _ enh: EvalNodeHelper,
    _ aggrFn: (Series) throws -> FloatHistogram?
) rethrows -> Vector {
    if matrixVal.isEmpty {
        return enh.out
    }
    let el = matrixVal[0]
    var sample = Sample()
    sample.h = try aggrFn(el)
    // Not written back to `enh.out` — see the note in ``aggrOverTime(_:_:_:)``.
    var out = enh.out
    out.append(sample)
    return out
}

/// Go: `funcSumOverTime` — the sum of a range, with a float path and a histogram path.
///
/// The three-way split at the top is the shape to get right:
///
///   * **both** kinds present → nothing, plus a `MixedFloatsHistogramsWarning`. Note
///     this is stricter than the `*_over_time` functions in the first half of this
///     file, which ignore the histograms and carry on with a *different* annotation.
///   * no floats → the histogram path.
///   * otherwise → the float path, which never looks at the histograms at all.
///
/// The float path's tail is not `sum + c`: an **infinite** sum returns `sum` unchanged,
/// because adding the compensation to ±Inf would produce NaN. That guard is the whole
/// difference between `sum_over_time(x)` being `+Inf` and being `NaN` once a value
/// overflows.
///
/// The histogram path accumulates with `KahanAdd` and folds the compensation in once at
/// the end with `Add`, and tracks two things across the whole range to decide its
/// annotations: whether it saw **both** a `CounterReset` and a `NotCounterReset` hint
/// (a collision), and whether any addition had to reconcile custom bucket bounds. Both
/// are reported once, after the loop — Go does it in a `defer`, so they fire even on the
/// error return.
func funcSumOverTime(
    _: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let firstSeries = m[0]
    if !firstSeries.floats.isEmpty && !firstSeries.histograms.isEmpty {
        var annos = Annotations()
        annos.add(
            newMixedFloatsHistogramsWarning(
                getMetricName(firstSeries.metric), args[0].positionRange))
        return (enh.out, annos)
    }

    if firstSeries.floats.isEmpty {
        var annos = Annotations()
        var counterResetSeen = false
        var notCounterResetSeen = false
        var nhcbBoundsReconciledSeen = false
        var failed = false

        // Go's `defer` runs on every exit, including the error one, so these two are
        // added after the loop whatever happened.
        func trackCounterReset(_ h: FloatHistogram) {
            switch h.counterResetHint {
            case .counterReset: counterResetSeen = true
            case .notCounterReset: notCounterResetSeen = true
            default: break
            }
        }

        let out = aggrHistOverTime(m, enh) { s -> FloatHistogram? in
            // Go indexes `s.Histograms[0]` with no guard, so a series with neither
            // floats nor histograms **panics** — `len(Floats) == 0` routes it here.
            // Unreachable from a query (`rangeEval` only calls a range function for a
            // series it found), and reported clearly rather than reproduced as a
            // crash, exactly as PORTING.md exception 9 does for `sampleRing`.
            precondition(
                !s.histograms.isEmpty,
                "sum_over_time: a series with no samples at all; Go panics here")
            var sum = s.histograms[0].h.copy()
            trackCounterReset(sum)
            var comp: FloatHistogram? = nil
            for hp in s.histograms.dropFirst() {
                trackCounterReset(hp.h)
                do {
                    let (updatedC, result) = try sum.kahanAdd(hp.h, comp)
                    comp = updatedC
                    if result.nhcbBoundsReconciled {
                        nhcbBoundsReconciledSeen = true
                    }
                } catch {
                    failed = true
                    return sum
                }
            }
            if var c = comp {
                do {
                    let result = try sum.add(c)
                    if result.nhcbBoundsReconciled {
                        nhcbBoundsReconciledSeen = true
                    }
                } catch {
                    failed = true
                }
                _ = c
            }
            return sum
        }

        if counterResetSeen && notCounterResetSeen {
            annos.add(newHistogramCounterResetCollisionWarning(args[0].positionRange, .agg))
        }
        if nhcbBoundsReconciledSeen {
            annos.add(newMismatchedCustomBucketsHistogramsInfo(args[0].positionRange, .agg))
        }
        if failed {
            // Go checks `errors.Is(err, ErrHistogramsIncompatibleSchema)` and replaces
            // the whole result — the partial sum is discarded and only the warning
            // survives.
            var only = Annotations()
            only.add(
                newMixedExponentialCustomHistogramsWarning(
                    getMetricName(firstSeries.metric), args[0].positionRange))
            return (enh.out, only)
        }
        return (out, annos)
    }

    let out = aggrOverTime(m, enh) { s in
        var sum = 0.0
        var c = 0.0
        for f in s.floats {
            (sum, c) = Kahan.inc(f.f, sum, c)
        }
        if sum.isInfinite {
            // Adding the compensation to ±Inf would give NaN.
            //
            // **Unwitnessed.** Removing this guard moves no case in
            // `promql/functions-overtime.jsonl`, including the runs that overflow with
            // small values interleaved: Kahan's compensation is already 0 or NaN by the
            // time the sum saturates. Kept because it is what Go does, and recorded
            // rather than presented as verified.
            return sum
        }
        return sum + c
    }
    return (out, Annotations())
}
