//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the four float-only regression and
// smoothing functions: `deriv`, `predict_linear`, `double_exponential_smoothing`
// and the `linearRegression`/`calcTrendValue` helpers they share.
//
// These are the last `functions.go` entries that need no histogram arithmetic, no
// start timestamps and no sort. What is left after them is `sum`/`avg_over_time`,
// the rate family (`rate`, `increase`, `delta`, `irate`, `idelta`), `resets`,
// `changes`, and the four sorts.
//
// ## Fusion, and three groupings that are load-bearing without being fused
//
// From the evaluator's fusion map (docs/HANDOFF.md §5), derived by disassembling
// all 239 functions of engine.go and functions.go. Three of the five fused sites in
// those two files are here:
//
// | site | shape |
// |---|---|
// | functions.go:900, `calcTrendValue` | `((1 - tf) * b).addingProduct(tf, s1 - s0)` — `tf*(s1-s0)` is **never materialised** |
// | functions.go:956, the smoothing loop | `y.addingProduct(sf, floats[i].f)` — likewise for `sf*value` |
// | functions.go:1938/:1940, `predict_linear`'s two returns | `intercept.addingProduct(slope, duration)`; there is no `FMULD` in the function at all |
//
// And `linearRegression` has **no** fused site, yet three of its expressions cannot
// be rearranged:
//
//   * `covXY := sumXY - sumX*sumY/n`
//   * `varX := sumX2 - sumX*sumX/n`
//   * `intercept = sumY/n - slope*sumX/n`
//
// The division between the product and the subtraction is what prevents the
// compiler fusing them; hoisting `1/n` out would both fuse *and* reassociate.
//
// Its two Kahan terms — `x*sample.F` and `x*x` — must be rounded by a plain `*`
// before reaching the Kahan step, because `util/kahansum` casts its arguments
// through `float64(...)` expressly to forbid fusing across that boundary.
//
// ## `double_exponential_smoothing` panics on a bad factor
//
// `sf` and `tf` outside the open interval (0, 1) make Go **panic**, which the engine
// recovers into a query error. The port uses `preconditionFailure`, which is the
// same contract expressed the Swift way — and it is why the corpus only carries
// valid factors: an invalid one would take the fixture generator down with it.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromLabels
public import PromQLParser

internal import GoCompat
internal import PromMath

/// Go: `calcTrendValue` — the trend component of `double_exponential_smoothing`.
///
/// `i == 0` short-circuits to `b`, so the first iteration keeps the seeded trend.
/// The `x + y` return is a **fused** multiply-add: `tf*(s1-s0)` never exists as a
/// rounded value.
func calcTrendValue(_ i: Int, _ tf: Double, _ s0: Double, _ s1: Double, _ b: Double) -> Double {
    if i == 0 {
        return b
    }
    // Go: `x := tf * (s1 - s0); y := (1 - tf) * b; return x + y`, emitted as one
    // FMADDD. The subtraction rounds first; only the product and the add share a
    // rounding.
    return ((1 - tf) * b).addingProduct(tf, s1 - s0)
}

/// Go: `linearRegression` — least-squares slope and intercept over a range's floats,
/// with `interceptTime` chosen by the caller to keep `x` small.
///
/// Two behaviours that are not obvious from the shape:
///
///   * **a constant series short-circuits.** `constY` tracks whether every value
///     equals the first; if so the answer is `(0, initY)` without touching the sums
///     — and `(NaN, NaN)` when that constant is infinite. So `deriv` of a flat
///     series is exactly 0, not a rounding artefact, and `deriv` of a flat `+Inf`
///     series is NaN rather than 0.
///   * `x` is `(sample.T - interceptTime) / 1e3`, a **float** division by 1000, so
///     the sub-second part survives.
///
/// Four Kahan accumulators, and the two product terms are rounded before their Kahan
/// step. See the file header for why the three closing expressions cannot be
/// rearranged.
func linearRegression(_ samples: [FPoint], _ interceptTime: Int64) -> (
    slope: Double, intercept: Double
) {
    var n = 0.0
    var sumX = 0.0, cX = 0.0
    var sumY = 0.0, cY = 0.0
    var sumXY = 0.0, cXY = 0.0
    var sumX2 = 0.0, cX2 = 0.0
    let initY = samples[0].f
    var constY = true

    for (i, sample) in samples.enumerated() {
        // Go checks `constY && i > 0 && sample.F != initY`, so index 0 never clears
        // it — which matters only for a single-sample series, where it stays true.
        if constY && i > 0 && sample.f != initY {
            constY = false
        }
        n += 1.0
        let x = Double(sample.t - interceptTime) / 1e3
        (sumX, cX) = Kahan.inc(x, sumX, cX)
        (sumY, cY) = Kahan.inc(sample.f, sumY, cY)
        // Rounded by a plain `*` before the Kahan step.
        (sumXY, cXY) = Kahan.inc(x * sample.f, sumXY, cXY)
        (sumX2, cX2) = Kahan.inc(x * x, sumX2, cX2)
    }

    if constY {
        if initY.isInfinite {
            let nan = Double(bitPattern: GoFloat.goNaNBits)
            return (nan, nan)
        }
        return (0, initY)
    }

    sumX += cX
    sumY += cY
    sumXY += cXY
    sumX2 += cX2

    // The division sits between the product and the subtraction, which is what keeps
    // these three unfused. Do not hoist `1/n`.
    let covXY = sumXY - sumX * sumY / n
    let varX = sumX2 - sumX * sumX / n

    let slope = covXY / varX
    let intercept = sumY / n - slope * sumX / n
    return (slope, intercept)
}

/// Go: `funcDeriv` — the per-second derivative, as a least-squares slope.
///
/// The guard is `< 2` **floats**, and it splits: exactly one float alongside any
/// histogram returns nothing *with* a `HistogramIgnoredInMixedRangeInfo`, while zero
/// floats returns nothing silently. With two or more floats the annotation is added
/// only if histograms are also present.
///
/// `interceptTime` is `samples.Floats[0].T` — an arbitrary timestamp near the data,
/// chosen to avoid the precision loss of upstream issue 2674.
func funcDeriv(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = m[0]
    if samples.floats.count < 2 {
        if samples.floats.count == 1 && !samples.histograms.isEmpty {
            var annos = Annotations()
            annos.add(
                newHistogramIgnoredInMixedRangeInfo(
                    getMetricName(samples.metric), args[0].positionRange))
            return (enh.out, annos)
        }
        return (enh.out, Annotations())
    }
    let (slope, _) = linearRegression(samples.floats, samples.floats[0].t)
    enh.out.append(Sample(f: slope))
    if !samples.histograms.isEmpty {
        var annos = Annotations()
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
        return (enh.out, annos)
    }
    return (enh.out, Annotations())
}

/// Go: `funcPredictLinear` — the regression extrapolated `duration` seconds past the
/// evaluation timestamp.
///
/// `interceptTime` is **`enh.Ts`** here, not the first sample's timestamp as in
/// ``funcDeriv(_:_:_:_:)``, which is what makes `duration` measured from *now*.
///
/// `slope*duration + intercept` is **fused** — there is no `FMULD` anywhere in the
/// function.
func funcPredictLinear(
    _ v: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if v.isEmpty || v[0].isEmpty || m.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = m[0]
    let duration = v[0][0].f

    if samples.floats.count < 2 {
        if samples.floats.count == 1 && !samples.histograms.isEmpty {
            var annos = Annotations()
            annos.add(
                newHistogramIgnoredInMixedRangeInfo(
                    getMetricName(samples.metric), args[0].positionRange))
            return (enh.out, annos)
        }
        return (enh.out, Annotations())
    }

    let (slope, intercept) = linearRegression(samples.floats, enh.ts)
    enh.out.append(Sample(f: intercept.addingProduct(slope, duration)))
    if !samples.histograms.isEmpty {
        var annos = Annotations()
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
        return (enh.out, annos)
    }
    return (enh.out, Annotations())
}

/// Go: `funcDoubleExponentialSmoothing` — Holt-Winters without seasonality.
///
/// `sf` or `tf` outside (0, 1) **panics** in Go, recovered by the engine into a query
/// error; the port makes it a `preconditionFailure`, which is why the corpus carries
/// only valid factors.
///
/// The loop's `s1 = x + y` is a **fused** multiply-add with `x = sf * value` never
/// materialised, and `calcTrendValue`'s return is another. Note `b` is seeded from
/// the *difference* of the first two samples and `s0` starts at 0, so the first
/// iteration's `calcTrendValue(0, …)` returns the seed untouched.
func funcDoubleExponentialSmoothing(
    _ v: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if v.count < 2 || v[0].isEmpty || v[1].isEmpty || m.isEmpty {
        return (enh.out, Annotations())
    }
    let samples = m[0]
    let sf = v[0][0].f
    let tf = v[1][0].f

    precondition(
        sf > 0 && sf < 1,
        "invalid smoothing factor. Expected: 0 < sf < 1, got: \(sf)")
    precondition(
        tf > 0 && tf < 1,
        "invalid trend factor. Expected: 0 < tf < 1, got: \(tf)")

    let l = samples.floats.count
    if l < 2 {
        if l == 1 && !samples.histograms.isEmpty {
            var annos = Annotations()
            annos.add(
                newHistogramIgnoredInMixedRangeInfo(
                    getMetricName(samples.metric), args[0].positionRange))
            return (enh.out, annos)
        }
        return (enh.out, Annotations())
    }

    var s0 = 0.0
    var s1 = samples.floats[0].f
    var b = samples.floats[1].f - samples.floats[0].f

    for i in 1..<l {
        b = calcTrendValue(i - 1, tf, s0, s1, b)
        let y = (1 - sf) * (s1 + b)
        // Go: `x = sf * samples.Floats[i].F` then `s0, s1 = s1, x+y`, emitted as one
        // FMADDD — `x` never exists as a rounded value.
        let next = y.addingProduct(sf, samples.floats[i].f)
        s0 = s1
        s1 = next
    }

    enh.out.append(Sample(f: s1))
    if !samples.histograms.isEmpty {
        var annos = Annotations()
        annos.add(
            newHistogramIgnoredInMixedRangeInfo(
                getMetricName(samples.metric), args[0].positionRange))
        return (enh.out, annos)
    }
    return (enh.out, Annotations())
}
