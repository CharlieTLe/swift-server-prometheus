//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the element-wise arithmetic slice
// — plus `EvalNodeHelper` and `EvalSeriesHelper` from promql/engine.go:1217-1263,
// which are `FunctionCall`'s parameter type and so have to come first.
//
// **Why `functions.go` is portable before `engine.go`.** `promql.FunctionCalls`
// and every type in `FunctionCall`'s signature are *exported*, so the oracle can
// call any of these bodies directly with a synthetic `EvalNodeHelper` and no
// running engine. `evaluator` is unexported, so nothing in `engine.go` can be
// reached that way. That inverts the obvious order — see docs/HANDOFF.md §5.
//
// ## What is here, and what is not
//
// Here: `simpleFloatFunc` and the 26 math wrappers, `clamp` and its three
// entry points, `funcRound`, `funcScalar`, `funcVector`, `funcTime`,
// `funcTimestamp`, `funcPi`, `funcSgn`, and `dateWrapper` plus the eight date
// functions.
//
// Deliberately not here, each with the reason:
//
//   * `sum_over_time`/`avg_over_time` (histogram Kahan arithmetic),
//     `resets`/`changes` (the start-timestamp machinery) and the rate family (`interpolate`,
//     `correctForCounterResets`). The float-only range aggregations that do not need
//     any of those are in `Functions+OverTime.swift`.
//   * `funcSort` and friends — they need Go's pdqsort ported, because the two
//     sorts are observably different and both comparators are invalid orderings.
//
// ## `enh.Out` is a reuse buffer, and it is always empty here
//
// engine.go:1523 does `enh.Out = result[:0]` before every call, so in a running
// engine `Out` is empty on entry and the `append(enh.Out, …)` in each body is
// simply "build a fresh vector". The port keeps the field anyway rather than
// dropping it like `sync.Pool` (PORTING.md exception 4), because it is *exported*
// and therefore part of the surface the oracle drives: `funcPi` and `funcTime`
// return a **fresh** `Vector{…}` and ignore `Out` entirely, while every other
// body appends to it. The corpus exercises a non-empty `Out` on a handful of cases
// to pin that difference; it is unreachable from a real query, and the fixture
// says so.
//
// ## Fusion
//
// One site in this slice, and it is from the evaluator's fusion map (see
// docs/HANDOFF.md §5, derived by disassembling all 239 functions of engine.go and
// functions.go): `funcRound`'s closure at functions.go:1099 fuses
// `f*toNearestInverse + 0.5` into a single `FMADDD`. Everything else is plain.
//
// ## Negative controls, and the two corpus gaps they found
//
// Sixty perturbations were run against the committed fixtures — the fusion, the
// metadata drop, `DropName`, the histogram skip, the delayed-removal condition,
// `clamp`'s bounds and operand order, `funcScalar`'s `found` logic, `funcSgn`'s
// default arm, the `enh.Out` distinction, and every wrapper rewired to a
// neighbour. **All sixty break it**, but two of them did not until the corpus was
// widened, and both gaps are the same shape: *a behaviour is only pinned if some
// input can tell the two spellings apart.*
//
//   * Every wrapper delegating to Swift's **libm** instead of `GoMath` passed the
//     first corpus. None of its round-number values — 0, ±1, ±0.5, ±2, 21.5, NaN,
//     ±Inf — is a value where libm and Go disagree, and the per-value arithmetic is
//     pinned elsewhere, so nothing noticed. The corpus now carries a harvested
//     witness per wrapper; `0x3ffa6d48991d5506` alone covers nine of them.
//   * `clamp`'s `Max(min, Min(max, f))` with the operands swapped passed too. The
//     order only decides *whose NaN payload survives*, and the first corpus used
//     `math.NaN()` for both the samples and the bounds — one payload, so no
//     observable difference. Bounds with distinct payloads fixed it.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromLabels
public import PromQLParser

internal import GoCompat
internal import PromSchema

// MARK: - The helpers FunctionCall carries

/// Go: `promql.EvalSeriesHelper` — per-series scratch space the evaluator fills
/// once per node and hands to every step.
///
/// One field so far, and it is only read by the binary-operator matching in
/// `engine.go`. Here because `rangeEval`'s `funcCall` signature names it and the
/// element-wise functions are the first callers to exist.
public struct EvalSeriesHelper: Sendable {
    /// Go: `sigOrdinal` — the ordinal of this series' join signature, mapping
    /// left-hand to right-hand in a binary operation. Series sharing a signature
    /// share an ordinal.
    public var sigOrdinal: Int

    public init(sigOrdinal: Int = 0) {
        self.sigOrdinal = sigOrdinal
    }
}

/// Go: `promql.EvalNodeHelper` — the caches and scratch space for evaluating one
/// AST node across every step of a range query.
///
/// **A `final class`, because Go passes `*EvalNodeHelper` and every body mutates
/// it in place.** The evaluator holds exactly one per node and threads the same
/// pointer through every step, which is what makes the caches worth having; a
/// struct would need `inout` on `FunctionCall` and would copy the caches on every
/// capture. Same reasoning as ADR-11's choice of classes for the AST.
///
/// The bucket caches live in `Functions+Histogram.swift`, next to their only
/// readers. What is still deferred, with its first caller, so nobody goes looking:
///
/// | deferred | first caller |
/// |---|---|
/// | `lb`, `lblBuf`, `lblResultBuf`, `resetBuilder` | `engine.go`'s label building |
/// | `rightSigs`, `sigsPresent`, `matchedSigs`, `matchedSigsPresent`, `resultMetric`, `numSigs`, and the four `reset*` helpers | binary vector matching |
/// | `rightStrSigs` | info-series matching |
/// | `StartTimestamps` | the ST-aware selectors of Phases 6-7 |
public final class EvalNodeHelper {

    /// Go: `Ts` — the evaluation timestamp in milliseconds.
    public var ts: Int64

    /// Go: `Out` — a vector the body may accumulate into.
    ///
    /// A reuse buffer: engine.go:1523 resets it to empty before each call. See the
    /// file header for why the port keeps it.
    public var out: Vector

    /// Go: `enableDelayedNameRemoval` — whether `__name__` removal is deferred to
    /// the last step of the query.
    ///
    /// **Unexported in Go, and it changes the result of every function in this
    /// file.** When false — the Prometheus server's default — each body strips the
    /// three metadata labels itself via `DropReserved(schema.IsMetadataLabel)`.
    /// When true — which is what `promqltest` uses (test.go:111), so it is what the
    /// exit gate runs — the labels are left alone and `DropName` alone records the
    /// intent. Both settings are pinned; the oracle reaches the field by
    /// reflection, which is why the corpus has a `delayed` axis.
    public var enableDelayedNameRemoval: Bool

    /// Go: `StartTimestamps` — OTel start timestamps aligned with the matrix samples.
    ///
    /// Nil until Phases 6-7 bring the ST-aware selectors. `resets` reads it; see
    /// ``isStartTimestampReset(_:_:_:_:)``.
    public var startTimestamps: StartTimestamps?

    /// Go: `signatureToMetricWithBuckets` — classic histogram bucket groups for this
    /// step, keyed by the label set with `le` removed.
    ///
    /// Go's is a `map[string]*metricWithBuckets` and it **ranges** it to produce
    /// output, so upstream's classic-histogram result order is randomised per run.
    /// ``signatureOrder`` keeps first-insertion order so the port's is not.
    /// PORTING.md exception 13.
    var signatureToMetricWithBuckets: [[UInt8]: MetricWithBuckets] = [:]

    /// First-insertion order of ``signatureToMetricWithBuckets``' keys. Not a Go
    /// field; see that property's note.
    var signatureOrder: [[UInt8]] = []

    /// Go: `nativeHistogramSamples` — the histogram samples of this step's input.
    ///
    /// A sample whose `h` has been set to nil is one that conflicted with a classic
    /// histogram of the same name; every reader skips those.
    var nativeHistogramSamples: [Sample] = []

    /// Go: `quantileStrs` — `labels.FormatOpenMetricsFloat` per quantile, cached
    /// across steps and **never cleared**.
    var quantileStrs: [Double: String] = [:]

    /// Go: `signatureToLabelsWithQuantile` — the output label set per (series,
    /// quantile), cached across steps.
    var signatureToLabelsWithQuantile: [[UInt8]: [Double: Labels]] = [:]

    public init(ts: Int64 = 0, out: Vector = Vector(), enableDelayedNameRemoval: Bool = false) {
        self.ts = ts
        self.out = out
        self.enableDelayedNameRemoval = enableDelayedNameRemoval
    }
}

/// Go: `promql.FunctionCall` — the type of a PromQL function implementation.
///
/// `vectorVals` holds one entry per evaluated argument: a `Vector` for an instant
/// vector, a one-sample `Vector` for a scalar, and nothing at all for a string
/// (string arguments are read from `args` instead). `matrixVals` is the single
/// range-vector argument, if any. `enh.out` is a vector the body may accumulate
/// into.
///
/// A range-vector function need only return the right *value* — the metric and
/// timestamp are filled in by the caller. An instant-vector function need only
/// return the right values and metrics. A scalar result is one sample in a
/// `Vector`.
public typealias FunctionCall = @Sendable (
    _ vectorVals: [Vector],
    _ matrixVals: Matrix,
    _ args: [any Expr],
    _ enh: EvalNodeHelper
) -> (Vector, Annotations)

// MARK: - simpleFloatFunc and the math wrappers

/// Go: `simpleFloatFunc` — applies `f` to every **float** sample of the first
/// argument, dropping the metric name.
///
/// Histogram samples are skipped entirely rather than passed through: a
/// `sinh(histogram)` produces no output sample for that series at all. That is not
/// an error and raises no annotation.
func simpleFloatFunc(
    _ vectorVals: [Vector], _ enh: EvalNodeHelper, _ f: (Double) -> Double
) -> Vector {
    for el in vectorVals[0] where el.h == nil {
        var metric = el.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(Sample(f: f(el.f), metric: metric, dropName: true))
    }
    return enh.out
}

/// Go: `funcAbs`. Swift's `abs` is the same hardware instruction as Go's
/// `math.Abs` — verified over 2,000,052 probe inputs — so there is no `GoMath.abs`.
func funcAbs(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { Swift.abs($0) }, Annotations())
}

/// Go: `funcCeil` — `math.Ceil`, which is `FRINTP`, same as Swift's.
func funcCeil(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { $0.rounded(.up) }, Annotations())
}

/// Go: `funcFloor` — `math.Floor`, which is `FRINTM`.
func funcFloor(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { $0.rounded(.down) }, Annotations())
}

/// Go: `funcExp` — `math.Exp`, ported from the arm64 assembly.
func funcExp(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.exp), Annotations())
}

/// Go: `funcSqrt` — `math.Sqrt`, which is `FSQRTD`, same as Swift's.
func funcSqrt(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { $0.squareRoot() }, Annotations())
}

/// Go: `funcMaxOf` — `math.Max` of two scalars.
///
/// Not `Swift.max` and not `Double.maximum`: `math.Max` is arm64 assembly whose
/// raw-bits ±Inf check runs *before* NaN handling, so `max_of(+Inf, NaN)` is
/// `+Inf`, and whose `FMAXD` propagates NaN where libm's `fmax` suppresses it.
/// PORTING.md quirk 28.
func funcMaxOf(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    enh.out.append(Sample(f: GoMath.max(v[0][0].f, v[1][0].f)))
    return (enh.out, Annotations())
}

/// Go: `funcMinOf` — `math.Min`, with the same assembly caveat as ``funcMaxOf``.
func funcMinOf(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    enh.out.append(Sample(f: GoMath.min(v[0][0].f, v[1][0].f)))
    return (enh.out, Annotations())
}

/// Go: `funcLn` — `math.Log`. PromQL spells the natural log `ln`.
func funcLn(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.log), Annotations())
}

/// Go: `funcLog2` — `math.Log2`.
func funcLog2(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.log2), Annotations())
}

/// Go: `funcLog10` — `math.Log10`.
func funcLog10(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.log10), Annotations())
}

/// Go: `funcSin` — `math.Sin`.
func funcSin(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.sin), Annotations())
}

/// Go: `funcCos` — `math.Cos`.
func funcCos(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.cos), Annotations())
}

/// Go: `funcTan` — `math.Tan`.
func funcTan(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.tan), Annotations())
}

/// Go: `funcAsin` — `math.Asin`.
func funcAsin(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.asin), Annotations())
}

/// Go: `funcAcos` — `math.Acos`.
func funcAcos(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.acos), Annotations())
}

/// Go: `funcAtan` — `math.Atan`.
func funcAtan(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.atan), Annotations())
}

/// Go: `funcSinh` — `math.Sinh`.
func funcSinh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.sinh), Annotations())
}

/// Go: `funcCosh` — `math.Cosh`.
func funcCosh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.cosh), Annotations())
}

/// Go: `funcTanh` — `math.Tanh`.
func funcTanh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.tanh), Annotations())
}

/// Go: `funcAsinh` — `math.Asinh`.
func funcAsinh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.asinh), Annotations())
}

/// Go: `funcAcosh` — `math.Acosh`.
func funcAcosh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.acosh), Annotations())
}

/// Go: `funcAtanh` — `math.Atanh`.
func funcAtanh(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh, GoMath.atanh), Annotations())
}

/// Go: `funcRad` — degrees to radians, `v * math.Pi / 180`.
///
/// Left-associated and **unfused**: there is no `FMADDD` in the function. Writing
/// it as `v * (math.Pi / 180)` would fold the divisor at compile time and change
/// the rounding.
func funcRad(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { $0 * Double.pi / 180 }, Annotations())
}

/// Go: `funcDeg` — radians to degrees, `v * 180 / math.Pi`. Left-associated, as
/// ``funcRad`` is.
func funcDeg(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleFloatFunc(v, enh) { $0 * 180 / Double.pi }, Annotations())
}

/// Go: `funcPi` — the only function that takes no arguments and reads nothing.
///
/// Returns a **fresh** `Vector`, ignoring `enh.Out`. Indistinguishable in a
/// running engine, where `Out` is always empty; see the file header.
func funcPi(_: [Vector], _: Matrix, _: [any Expr], _: EvalNodeHelper) -> (Vector, Annotations) {
    (Vector([Sample(f: Double.pi)]), Annotations())
}

/// Go: `funcSgn` — -1, +1, or the argument itself.
///
/// The default arm is `return v`, **not** `return 0`: it is what makes `sgn(-0)`
/// negative zero and `sgn(NaN)` a NaN with the argument's own payload.
func funcSgn(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    let out = simpleFloatFunc(v, enh) { value in
        if value < 0 { return -1 }
        if value > 0 { return 1 }
        return value
    }
    return (out, Annotations())
}

// MARK: - clamp

/// Go: `clamp` — the shared body of `clamp`, `clamp_min` and `clamp_max`.
///
/// Two things worth not getting backwards:
///
///   * `maxVal < minVal` returns `enh.Out` **unchanged and without an
///     annotation** — an inverted range yields an empty result, not an error.
///     Note the comparison is `<`, so `min == max` is a legal degenerate range.
///   * the clamping is `Max(minVal, Min(maxVal, f))`, and both are Go's
///     assembly `math.Max`/`math.Min` rather than Swift's. The operand order
///     decides which NaN payload survives (PORTING.md quirk 28), so
///     `clamp(NaN, 0, 1)` is not `Swift.max(0, Swift.min(1, .nan))`.
func clamp(
    _ vec: Vector, _ minVal: Double, _ maxVal: Double, _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if maxVal < minVal {
        return (enh.out, Annotations())
    }
    for el in vec where el.h == nil {
        var metric = el.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(
            Sample(
                f: GoMath.max(minVal, GoMath.min(maxVal, el.f)),
                metric: metric,
                dropName: true))
    }
    return (enh.out, Annotations())
}

/// Go: `funcClamp`.
func funcClamp(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    clamp(v[0], v[1][0].f, v[2][0].f, enh)
}

/// Go: `funcClampMax` — a clamp with no lower bound.
func funcClampMax(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    clamp(v[0], -.infinity, v[1][0].f, enh)
}

/// Go: `funcClampMin` — a clamp with no upper bound.
func funcClampMin(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    clamp(v[0], v[1][0].f, .infinity, enh)
}

// MARK: - round

/// Go: `funcRound` — round to the nearest multiple of `toNearest`, ties upward.
///
/// Two details that are not free choices:
///
///   * `toNearest` defaults to 1 and is read from the **second evaluated
///     argument** only when `len(args) >= 2` — so the `args` list, not
///     `vectorVals`, decides whether the default applies.
///   * upstream inverts the divisor once ("it seems to cause fewer floating point
///     accuracy issues") and the multiply-add is **fused**: functions.go:1099 is a
///     single `FMADDD` of `0.5 + f*toNearestInverse`. Rounding the product first
///     shifts results at ties.
func funcRound(_ v: [Vector], _: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    var toNearest = 1.0
    if args.count >= 2 {
        toNearest = v[1][0].f
    }
    // Hoisted out of the loop exactly as Go hoists it.
    let toNearestInverse = 1.0 / toNearest
    let out = simpleFloatFunc(v, enh) { f in
        (0.5).addingProduct(toNearestInverse, f).rounded(.down) / toNearestInverse
    }
    return (out, Annotations())
}

// MARK: - scalar, vector, time, timestamp

/// Go: `funcScalar` — the single float value of a one-sample vector, or NaN.
///
/// Histogram samples are **not counted**, so a vector holding one float and any
/// number of histograms still yields that float. Two or more floats yield NaN, and
/// so does none.
///
/// The NaN is Go's `math.NaN()`, `0x7FF8000000000001`. `Double.nan` would be
/// `…0000` and `promqltest` renders results as text, so the payload is observable.
func funcScalar(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    var value = 0.0
    var found = false
    for s in v[0] where s.h == nil {
        if found {
            // More than one float: NaN, and return immediately.
            enh.out.append(Sample(f: Double(bitPattern: GoFloat.goNaNBits)))
            return (enh.out, Annotations())
        }
        found = true
        value = s.f
    }
    if !found {
        enh.out.append(Sample(f: Double(bitPattern: GoFloat.goNaNBits)))
        return (enh.out, Annotations())
    }
    enh.out.append(Sample(f: value))
    return (enh.out, Annotations())
}

/// Go: `funcVector` — a scalar promoted to a one-sample instant vector with no
/// labels.
///
/// The metric is `labels.Labels{}`, the zero value, and `DropName` is **false** —
/// unlike every other function here. There is no name to drop.
func funcVector(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    enh.out.append(Sample(f: v[0][0].f, metric: .empty))
    return (enh.out, Annotations())
}

/// Go: `funcTime` — the evaluation timestamp in seconds.
///
/// `float64(enh.Ts) / 1000`, so the division is the only rounding and a
/// millisecond timestamp that is not a whole second comes back fractional.
/// Returns a fresh `Vector` and ignores `enh.Out`, as ``funcPi`` does.
func funcTime(_: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (Vector([Sample(f: Double(enh.ts) / 1000)]), Annotations())
}

/// Go: `funcTimestamp` — each sample's own timestamp, in seconds.
///
/// The one function here that does **not** skip histogram samples: it reads only
/// `el.T`, so `timestamp(histogram)` yields a float sample. Easy to normalise away
/// by copying `simpleFloatFunc`'s shape, which is why it is spelled out.
func funcTimestamp(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    for el in v[0] {
        var metric = el.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(Sample(f: Double(el.t) / 1000, metric: metric, dropName: true))
    }
    return (enh.out, Annotations())
}

// MARK: - The table

/// Go: `promql.FunctionCalls` — the name-to-implementation table.
///
/// **Partial**, and the gap has two different causes that the test keeps apart:
/// bodies not yet ported, and the **seven names Go maps to `nil`** — `start`, `end`,
/// `step`, `range` (folded into a `NumberLiteral` by `foldQueryContextFunctions`),
/// `info`, `label_replace` and `label_join` (reached by the evaluator directly, not
/// through this table). Those seven can never have an entry, so counting them as
/// "not ported" would make the table look permanently incomplete.
///
/// Only the element-wise arithmetic slice is populated; the entries
/// listed in the file header arrive with their slices. A lookup that misses is a
/// function that is parsed and type-checked but not yet evaluable, which is why
/// the evaluator must not assume this table is total until Phase 5 closes.
/// ``functionCallsComplete`` records the intended final size so a stale count is
/// visible.
public let functionCalls: [String: FunctionCall] = [
    "abs": funcAbs,
    "absent": funcAbsent,
    "absent_over_time": funcAbsentOverTime,
    "avg_over_time": funcAvgOverTime,
    "acos": funcAcos,
    "acosh": funcAcosh,
    "asin": funcAsin,
    "asinh": funcAsinh,
    "atan": funcAtan,
    "atanh": funcAtanh,
    "ceil": funcCeil,
    "clamp": funcClamp,
    "clamp_max": funcClampMax,
    "clamp_min": funcClampMin,
    "changes": funcChanges,
    "cos": funcCos,
    "count_over_time": funcCountOverTime,
    "cosh": funcCosh,
    "day_of_month": funcDayOfMonth,
    "day_of_week": funcDayOfWeek,
    "day_of_year": funcDayOfYear,
    "days_in_month": funcDaysInMonth,
    "deg": funcDeg,
    "delta": funcDelta,
    "deriv": funcDeriv,
    "double_exponential_smoothing": funcDoubleExponentialSmoothing,
    "exp": funcExp,
    "first_over_time": funcFirstOverTime,
    "floor": funcFloor,
    "histogram_avg": funcHistogramAvg,
    "histogram_count": funcHistogramCount,
    "histogram_fraction": funcHistogramFraction,
    "histogram_quantile": funcHistogramQuantile,
    "histogram_quantiles": funcHistogramQuantiles,
    "histogram_stddev": funcHistogramStdDev,
    "histogram_stdvar": funcHistogramStdVar,
    "histogram_sum": funcHistogramSum,
    "hour": funcHour,
    "idelta": funcIdelta,
    "increase": funcIncrease,
    "irate": funcIrate,
    "last_over_time": funcLastOverTime,
    "ln": funcLn,
    "log10": funcLog10,
    "log2": funcLog2,
    "max_of": funcMaxOf,
    "mad_over_time": funcMadOverTime,
    "max_over_time": funcMaxOverTime,
    "min_of": funcMinOf,
    "min_over_time": funcMinOverTime,
    "minute": funcMinute,
    "month": funcMonth,
    "pi": funcPi,
    "predict_linear": funcPredictLinear,
    "present_over_time": funcPresentOverTime,
    "quantile_over_time": funcQuantileOverTime,
    "rad": funcRad,
    "rate": funcRate,
    "resets": funcResets,
    "round": funcRound,
    "scalar": funcScalar,
    "sgn": funcSgn,
    "sin": funcSin,
    "sinh": funcSinh,
    "sqrt": funcSqrt,
    "sum_over_time": funcSumOverTime,
    "stddev_over_time": funcStddevOverTime,
    "stdvar_over_time": funcStdvarOverTime,
    "tan": funcTan,
    "tanh": funcTanh,
    "time": funcTime,
    "timestamp": funcTimestamp,
    "ts_of_first_over_time": funcTsOfFirstOverTime,
    "ts_of_last_over_time": funcTsOfLastOverTime,
    "ts_of_max_over_time": funcTsOfMaxOverTime,
    "ts_of_min_over_time": funcTsOfMinOverTime,
    "vector": funcVector,
    "year": funcYear,
]

/// How many entries Go's `FunctionCalls` has at this pin.
///
/// Not a hand-written number to be trusted: `Fixtures/promql/functioncallnames.jsonl`
/// carries the full key set from Go, and the test asserts that ``functionCalls`` is
/// a subset of it whose complement is exactly the deferred list. So a function that
/// upstream adds, or one this port invents, fails rather than going unnoticed.
public let functionCallsCountAtPin = 89

// MARK: - The date functions

/// Go: `dateWrapper` — the shared body of the eight date functions.
///
/// Three things here are load-bearing and none of them is obvious from the name:
///
///   * **With no arguments** — `days_in_month()` and friends, which PromQL allows —
///     it reads `enh.Ts` and emits one sample with **no labels and `DropName`
///     false**, like ``funcVector(_:_:_:_:)`` rather than like the argument form.
///     Note the timestamp is divided by 1000 *first*, so this form never reaches the
///     `Int64` extremes the argument form can.
///   * **`int64(el.F)` is unguarded**, on arbitrary sample data. `year(vector(NaN))`
///     is legal PromQL, and Swift's `Int64(_:)` would trap where Go's `FCVTZS`
///     saturates — hence ``GoCompat/GoConv/int64(_:)``. Go's answers: NaN is 1970,
///     `+Inf` is year 292277026596, and **`-Inf` is also 292277026596**, because
///     `Int64.min` lands in the band where Go's absolute-second count wraps
///     (PORTING.md quirk 46).
///   * histogram samples are **skipped**, as in ``simpleFloatFunc(_:_:_:)``.
func dateWrapper(
    _ vectorVals: [Vector], _ enh: EvalNodeHelper, _ f: (GoTime) -> Double
) -> Vector {
    if vectorVals.isEmpty {
        enh.out.append(
            Sample(f: f(GoTime.unix(enh.ts / 1000, 0)), metric: .empty))
        return enh.out
    }

    for el in vectorVals[0] where el.h == nil {
        let t = GoTime.unix(GoConv.int64(el.f), 0)
        var metric = el.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(Sample(f: f(t), metric: metric, dropName: true))
    }
    return enh.out
}

/// Go: `funcDaysInMonth` — the number of days in the sample's month.
///
/// `32 - time.Date(t.Year(), t.Month(), 32, …).Day()`, leaning on `time.Date`'s
/// normalisation of an out-of-range day. The whole expression is
/// ``GoCompat/GoTime/daysInMonth(year:month:)``, whose doc comment records why a
/// month-length table is *not* a legal shortcut at the years this can reach.
func funcDaysInMonth(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    let out = dateWrapper(v, enh) { t in
        let (year, month, _) = t.utcDate
        return Double(GoTime.daysInMonth(year: year, month: month))
    }
    return (out, Annotations())
}

/// Go: `funcDayOfMonth` — `t.Day()`, 1-based.
func funcDayOfMonth(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcDate.day) }, Annotations())
}

/// Go: `funcDayOfWeek` — `t.Weekday()`, with **Sunday as 0**.
func funcDayOfWeek(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcWeekday) }, Annotations())
}

/// Go: `funcDayOfYear` — `t.YearDay()`, 1-based, so January 1 is 1.
func funcDayOfYear(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcYearDay) }, Annotations())
}

/// Go: `funcHour` — `t.Hour()`, 0...23.
func funcHour(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcClock.hour) }, Annotations())
}

/// Go: `funcMinute` — `t.Minute()`, 0...59.
func funcMinute(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcClock.minute) }, Annotations())
}

/// Go: `funcMonth` — `t.Month()`, 1...12.
func funcMonth(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcDate.month) }, Annotations())
}

/// Go: `funcYear` — `t.Year()`, in astronomical numbering, so year 0 exists.
func funcYear(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (dateWrapper(v, enh) { Double($0.utcDate.year) }, Annotations())
}
