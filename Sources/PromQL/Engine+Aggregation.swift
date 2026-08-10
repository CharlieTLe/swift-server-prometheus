//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — the aggregations: `rangeEvalAgg` (:1586),
// `aggregation` (:3657), `generateGroupingKey`, `generateGroupingLabels`, `nextValues`,
// `handleAggregationError`, and `value.go`'s `fParams`/`newFParams` (:585).
//
// `sum`, `avg`, `min`, `max`, `count`, `group`, `stddev`, `stdvar` and `quantile` — the nine
// operators that produce **one output series per group**. The four that produce *k of the input*
// (`topk`, `bottomk`, `limitk`, `limit_ratio`) go through `aggregationK`, and `count_values`
// through `aggregationCountValues`; both are separate slices and both throw by name.
//
// ## The output matrix is built BEFORE the step loop, and the groups are one-to-one with it
//
// `rangeEvalAgg` walks the input matrix once, assigns every input series a group index, and
// pre-populates `result` with the grouping labels. `groups[i]` then corresponds to
// `result[i]` for the whole query. So `aggregation` never allocates a series: it accumulates
// into `groups` and appends one point per step to the matching row.
//
// The consequence worth knowing: `seriesToResult` is by **input series index**, so it depends on
// the input matrix's order — which is the order the inner expression produced (HANDOFF §5:
// upstream's own matrix order is a Go map's for anything that went through `rangeEval`'s
// multi-step assembly). That order is what `aggregation`'s `for si` loop is, and therefore the
// order Kahan sums in.
//
// ## `seen` is reset per step, and a group that was never seen is skipped
//
// Every step clears `seen` on all groups, so a group whose series all have a gap at this
// timestamp produces no point at all rather than a zero. The empty rows are removed from the
// result at the very end, after every step — which is why a group with no data at *any* step
// disappears entirely.
//
// `seen` is also how the histogram rejections work: `stdvar`/`stddev`/`min`/`max`/`quantile` set
// `group.seen = false` when the group's **first** sample is a histogram, so the group is
// abandoned rather than mis-aggregated. A histogram arriving later just adds an info and
// `continue`s.
//
// ## `avg` and `sum` switch from a direct sum to an incremental mean ON OVERFLOW
//
// Upstream's own comment is thirty lines long and worth reading in place. The short version:
// direct mean (`sum / n`) is usually more accurate, but overflows `float64` for inputs the
// incremental form handles — so it starts direct, and the *first* step whose Kahan sum would go
// infinite flips `floatIncrementalMean` and converts the running sum into a mean by dividing
// both it and the compensation by `groupCount - 1`.
//
// Three details make that hard to get right and all three are load-bearing:
//
//   * the switch tests `kahansum.Inc(...)`'s **result**, not the running sum — so the decision is
//     made on the value that would have been stored;
//   * `q = (groupCount - 1) / groupCount` scales the previous mean *and* its compensation, and
//     the products `q*mean` and `q*c` are rounded before the Kahan step (`kahansum.Inc` casts
//     all three arguments through `float64(...)` expressly to forbid fusing — PORTING.md);
//   * the final value is `mean + c` in incremental mode and `value/n + c/n` — **two divisions,
//     then one add** — in direct mode. Not `(value + c) / n`.
//
// The histogram path mirrors it with `HasOverflow()` in place of `IsInf`, and its `q` scaling is
// three separate `Mul`/`Div` calls on histograms.
//
// ## `stdvar`/`stddev` are Welford, with one fused site
//
// `delta := f - mean; mean += delta/n; value += delta * (f - mean)` — the second `f - mean`
// reads the **updated** mean, so the two subtractions are different values. `engine.go:3838`'s
// `value += delta * (f - mean)` is the one FMA in the whole aggregation (HANDOFF §5's fusion
// map), so it is `addingProduct` with the subtraction rounded first.
//
// The seed is not zero: a NaN or infinite first sample seeds `floatValue` with **NaN**, and
// anything else with 0. So `stddev` over a series containing an infinity is NaN rather than an
// infinity.
//
// ## `fParams` is evaluated ONCE and consumed per step
//
// `topk(k, …)`'s `k` and `quantile(q, …)`'s `q` can be a *series*, not just a literal, so
// `newFParams` evaluates the parameter expression up front, records its min/max/has-NaN across
// every step, and `Next()` pops one value per step. The min/max are what the range checks use —
// so `topk(k, …)` with a series parameter is rejected if **any** step's k overflows, before any
// step is computed.
//
// A `NumberLiteral` parameter is flagged `isConstant` and `Next()` returns the same value
// forever without consuming; anything else consumes, and returns **0** once exhausted rather
// than repeating the last value.
//
// ## `generateGroupingKey` and `generateGroupingLabels` are not each other's inverse
//
//   * `by (...)` with an empty list hashes to **0 without touching the metric**, and the labels
//     are `EmptyLabels()`. So `sum(x)` puts everything in one group.
//   * `without (...)` hashes with `HashWithoutLabels`, which drops `__name__` *itself* on top of
//     the named labels — and `generateGroupingLabels` then deletes `__name__` explicitly as
//     well, because `Del(grouping...)` would not.
//
// That asymmetry is why the two functions each take `without` rather than sharing a filtered
// label list.
//
// ## 39 negative controls, 27 break, and the twelve survivors sort into four kinds
//
// `Scripts/controls-aggregation.sh` re-runs them. **Provably inert**, i.e. the line cannot change
// an answer:
//
//   * `by ()` with an empty list returning 0 versus hashing — `HashForLabels` over an empty name
//     list hashes an empty buffer, which is the same value for every series, so both spellings put
//     everything in one group. Likewise `Keep()` with no names leaves no labels, so returning
//     `EmptyLabels()` is the same thing.
//   * `rangeEvalAgg`'s per-step `currentSamples = tempNumSamples`. `aggregation` never touches
//     `currentSamples` — the accounting is entirely `nextValues` consuming points that were
//     already counted — so the reset restores a value that never moved, and the `> maxSamples`
//     check after each step compares the same number every time.
//   * a **constant** parameter being consumed like a series. `newFParams` gets its series from
//     `evalNode`, and a `NumberLiteral` yields the same value at every step, so consuming and not
//     consuming return the same number.
//
// **Provably unreachable** at this pin:
//
//   * `fParams.Next()`'s `return 0` for an exhausted series. The parameter is scalar-typed
//     (`checkAST` enforces it), and a scalar expression's matrix has exactly one point per step —
//     so the series is never shorter than the step count. Go's defensive branch, transcribed.
//   * the empty-output-row removal. A group exists only for an input series, an input series
//     exists only if `evalSeries` kept it (it drops a series with no point at any step), and any
//     kept series contributes at least one group point. The filter is reachable **only** through
//     the histogram rejections — `seen = false` for every step, or `incompatibleHistograms` — and
//     those need histogram input.
//   * `nextValues` preferring the float at an equal timestamp. A series cannot carry both a float
//     and a histogram at one timestamp through any storage the port has.
//
// **Blocked by the float-only corpus**, and honest about it: the incremental-mean compensation
// scaling, its final `mean + c`, `avg`'s `value/n + c/n` versus `(value + c)/n`, and the
// three-quantile-warning exclusivity all need either a histogram or an arithmetic shape hostile
// enough that the two spellings differ in the last bit. The Kahan magnitude lesson applies:
// `1e100` plus twenty 1s is *indistinguishable*, because the compensation is rounded straight back
// off; `1e16` is where it survives. Two of the four closed that way and two did not.
//
// **Unobservable through the rendering**: `DropName` on the output series. `Matrix.String()` does
// not print it, and nothing downstream reads it until the delayed-name-removal cleanup lands.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromLabels
internal import PromMath
internal import PromModel
internal import PromPosRange
internal import PromQLParser

/// Go: `groupedAggregation` — one output group's running state.
///
/// A `struct` here where Go uses `*groupedAggregation` taken out of a slice; the port writes back
/// explicitly (`groups[idx] = group`) at every mutation point, which is what `group := &groups[…]`
/// does implicitly. Getting that write-back wrong loses every accumulation, which is loud.
struct GroupedAggregation {
    var floatValue: Double = 0
    var floatMean: Double = 0
    /// Go: `floatKahanC` — the Kahan compensation.
    var floatKahanC: Double = 0
    var histogramValue: FloatHistogram? = nil
    var histogramMean: FloatHistogram? = nil
    var histogramKahanC: FloatHistogram? = nil
    var groupCount: Double = 0
    /// Go: `heap` — `quantile`'s collected values. Only the floats are needed, since
    /// `promql.quantile` reads `F` alone.
    var heap: [Double] = []

    /// Go: `seen` — was this group present in the input **at this timestamp**.
    var seen: Bool = false
    var hasFloat: Bool = false
    var hasHistogram: Bool = false
    var incompatibleHistograms: Bool = false
    var groupAggrComplete: Bool = false
    var floatIncrementalMean: Bool = false
    var histogramIncrementalMean: Bool = false
    var counterResetSeen: Bool = false
    var notCounterResetSeen: Bool = false
    var dropName: Bool = false
}

/// Go: `fParams` — an aggregation's scalar parameter, which may be a series.
struct FParams {
    var series: Series = Series(metric: .empty)
    var constValue: Double = 0
    var isConstant: Bool = false
    var minValue: Double = 0
    var maxValue: Double = 0
    var hasAnyNaN: Bool = false

    var max: Double { maxValue }
    var min: Double { minValue }

    /// Go: `Next` — the value for this step.
    ///
    /// A constant is returned without consuming; a series is consumed, and an **exhausted**
    /// series returns 0 rather than repeating its last value.
    mutating func next() -> Double {
        if isConstant {
            return constValue
        }
        if !series.floats.isEmpty {
            let v = series.floats[0].f
            series.floats.removeFirst()
            return v
        }
        return 0
    }
}

extension Evaluator {
    /// Go: `newFParams` — evaluate the parameter expression and summarise it.
    ///
    /// A nil parameter (every aggregation but `topk`/`bottomk`/`limitk`/`limit_ratio`/`quantile`)
    /// gives a zero `fParams`, whose `min`/`max` are both **0** — not ±MaxFloat64. That matters:
    /// `limit_ratio`'s "all r values are zero" early return would fire for a nil parameter, and
    /// it cannot be reached because the parser requires one.
    func newFParams(_ ctx: GoContext, _ expr: (any Expr)?, _ ws: inout Annotations) throws
        -> FParams
    {
        guard let expr else {
            return FParams()
        }
        let constParam = expr is NumberLiteral
        let val = try evalNode(ctx, expr, &ws)
        guard let mat = val as? Matrix, !mat.series.isEmpty else {
            return FParams()
        }
        var fp = FParams()
        fp.series = mat.series[0]
        fp.isConstant = constParam
        fp.minValue = Double.greatestFiniteMagnitude
        fp.maxValue = -Double.greatestFiniteMagnitude

        if constParam {
            fp.constValue = fp.series.floats[0].f
            fp.minValue = fp.constValue
            fp.maxValue = fp.constValue
            fp.hasAnyNaN = fp.constValue.isNaN
            return fp
        }

        for v in fp.series.floats {
            // `math.Max`/`math.Min`, which are arm64 assembly and do NOT agree with libm on NaN
            // (quirk 28) — so `GoMath`, not Swift's `max`/`min`.
            fp.maxValue = GoMath.max(fp.maxValue, v.f)
            fp.minValue = GoMath.min(fp.minValue, v.f)
            if v.f.isNaN {
                fp.hasAnyNaN = true
            }
        }
        return fp
    }

    /// Go: `nextValues` — the sample at `ts` from one input series, consuming it.
    ///
    /// Floats win a tie, and the point is removed so the next step does not rescan it — the same
    /// consume-as-you-go `gatherVector` does, and observable across steps for the same reason.
    func nextValues(_ ts: Int64, _ series: inout Series) -> (Double, FloatHistogram?, Bool) {
        if let f = series.floats.first, f.t == ts {
            series.floats.removeFirst()
            return (f.f, nil, true)
        }
        if let h = series.histograms.first, h.t == ts {
            series.histograms.removeFirst()
            return (0, h.h, true)
        }
        return (0, nil, false)
    }

    /// Go: `rangeEvalAgg` — the aggregation's own step loop.
    ///
    /// Separate from `rangeEval` because the grouping is computed once, before any step, and the
    /// output rows exist from the start. Note it does **not** go through `gatherVector`: the
    /// per-step sample extraction is `nextValues`, called from `aggregation`.
    func rangeEvalAgg(
        _ ctx: GoContext, _ aggExpr: AggregateExpr, _ sortedGrouping: [String],
        _ inputMatrixIn: Matrix, _ paramsIn: FParams
    ) throws -> (Matrix, Annotations) {
        var inputMatrix = inputMatrixIn
        var params = paramsIn
        var annos = Annotations()

        let enh = EvalNodeHelper()
        enh.enableDelayedNameRemoval = enableDelayedNameRemoval
        let tempNumSamples = currentSamples

        // Input series index -> output group index, plus the output rows themselves.
        var groupToResultIndex: [UInt64: Int] = [:]
        var seriesToResult = [Int](repeating: 0, count: inputMatrix.series.count)
        var result = Matrix()
        var groupCount = 0

        for (si, series) in inputMatrix.series.enumerated() {
            let groupingKey = generateGroupingKey(
                series.metric, sortedGrouping, aggExpr.without)
            if let index = groupToResultIndex[groupingKey] {
                seriesToResult[si] = index
                continue
            }
            // The four "k of the input" operators do not pre-populate rows — their output labels
            // are the *input's*, not the grouping's — so only the nine one-row operators do.
            if aggExpr.op != .topk && aggExpr.op != .bottomk && aggExpr.op != .limitk
                && aggExpr.op != .limitRatio
            {
                let m = generateGroupingLabels(
                    enh, series.metric, aggExpr.without, sortedGrouping)
                result.series.append(Series(metric: m))
            }
            groupToResultIndex[groupingKey] = groupCount
            seriesToResult[si] = groupCount
            groupCount += 1
        }
        var groups = [GroupedAggregation](repeating: GroupedAggregation(), count: groupCount)

        switch aggExpr.op {
        case .topk, .bottomk, .limitk, .limitRatio:
            throw EvaluatorNotPorted(
                nodeType: "AggregateExpr",
                detail: "\(aggExpr.op.description) needs aggregationK")
        case .quantile:
            // Three separate warnings, and they are not exclusive: a parameter series with a NaN
            // *and* a value above 1 produces both.
            if params.hasAnyNaN {
                _ = annos.add(
                    newInvalidQuantileWarning(Double(bitPattern: GoFloat.goNaNBits), aggExpr.param!.positionRange))
            }
            if params.max > 1 {
                _ = annos.add(newInvalidQuantileWarning(params.max, aggExpr.param!.positionRange))
            }
            if params.min < 0 {
                _ = annos.add(newInvalidQuantileWarning(params.min, aggExpr.param!.positionRange))
            }
        default:
            break
        }

        var ts = startTimestamp
        while ts <= endTimestamp {
            let fParam = params.next()
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            currentSamples = tempNumSamples
            enh.ts = ts
            let ws = try aggregation(
                aggExpr, fParam, &inputMatrix, &result, seriesToResult, &groups, enh)
            _ = annos.merge(ws)
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }
            ts += interval
        }

        // Remove the empty rows — a group with no data at any step. Go compacts in place with a
        // write index; the effect is a filter.
        result.series = result.series.filter { !$0.floats.isEmpty || !$0.histograms.isEmpty }
        return (result, annos)
    }

    /// Go: `aggregation` — one step of the nine one-row-per-group operators.
    ///
    /// `inputMatrix` is `inout` because `nextValues` consumes from it; `outputMatrix` because the
    /// step's point is appended to it. `groups` carries the running state.
    func aggregation(
        _ e: AggregateExpr, _ q: Double, _ inputMatrix: inout Matrix,
        _ outputMatrix: inout Matrix, _ seriesToResult: [Int],
        _ groups: inout [GroupedAggregation], _ enh: EvalNodeHelper
    ) throws -> Annotations {
        let op = e.op
        var annos = Annotations()
        // Go dereferences `e.Expr` unguarded; `checkAST` guarantees it is non-nil for every
        // aggregation the parser accepts, so the fallback is the aggregation's own range rather
        // than a throw — a position is not worth failing a query over.
        let pos = e.expr?.positionRange ?? e.positionRange
        for i in groups.indices {
            groups[i].seen = false
        }

        for si in inputMatrix.series.indices {
            let (f, h, ok) = nextValues(enh.ts, &inputMatrix.series[si])
            if !ok {
                continue
            }

            let idx = seriesToResult[si]

            // The first sample of this group at this timestamp REPLACES the whole struct, which
            // is what resets the previous step's accumulation.
            if !groups[idx].seen {
                var group = GroupedAggregation()
                group.seen = true
                group.floatValue = f
                group.floatMean = f
                group.groupCount = 1
                group.dropName = inputMatrix.series[si].dropName

                switch op {
                case .avg, .sum:
                    if h == nil {
                        group.hasFloat = true
                    } else {
                        group.histogramValue = h!.copy()
                        group.hasHistogram = true
                        switch h!.counterResetHint {
                        case .counterReset: group.counterResetSeen = true
                        case .notCounterReset: group.notCounterResetSeen = true
                        default: break
                        }
                    }
                case .stdvar, .stddev:
                    if h != nil {
                        // Abandon the group rather than mis-aggregate it.
                        group.seen = false
                        _ = annos.add(
                            newHistogramIgnoredInAggregationInfo(
                                op == .stdvar ? "stdvar" : "stddev", pos))
                    } else if f.isNaN || f.isInfinite {
                        // A NaN or infinite FIRST sample poisons the whole variance, so `stddev`
                        // over a series containing an infinity is NaN and not an infinity.
                        group.floatValue = Double(bitPattern: GoFloat.goNaNBits)
                    } else {
                        group.floatValue = 0
                    }
                case .quantile:
                    if h != nil {
                        group.seen = false
                        _ = annos.add(newHistogramIgnoredInAggregationInfo("quantile", pos))
                    }
                    group.heap = [f]
                case .group:
                    group.floatValue = 1
                case .min, .max:
                    if h != nil {
                        group.seen = false
                        _ = annos.add(
                            newHistogramIgnoredInAggregationInfo(
                                op == .min ? "min" : "max", pos))
                    }
                default:
                    break
                }
                groups[idx] = group
                continue
            }

            if groups[idx].incompatibleHistograms {
                continue
            }
            if inputMatrix.series[si].dropName {
                groups[idx].dropName = true
            }

            let metricName = inputMatrix.series[si].metric[LabelName.metricName]

            switch op {
            case .sum:
                if let h {
                    groups[idx].hasHistogram = true
                    if groups[idx].histogramValue != nil {
                        switch h.counterResetHint {
                        case .counterReset: groups[idx].counterResetSeen = true
                        case .notCounterReset: groups[idx].notCounterResetSeen = true
                        default: break
                        }
                        var v = groups[idx].histogramValue!
                        do {
                            let (c, res) = try v.kahanAdd(h, groups[idx].histogramKahanC)
                            groups[idx].histogramValue = v
                            groups[idx].histogramKahanC = c
                            if res.nhcbBoundsReconciled {
                                _ = annos.add(
                                    newMismatchedCustomBucketsHistogramsInfo(pos, .agg))
                            }
                        } catch {
                            handleAggregationError(error, pos, metricName, &annos)
                            groups[idx].incompatibleHistograms = true
                        }
                    }
                    // Otherwise the group already held floats and is invalid anyway; Go does not
                    // even copy the histogram in that case.
                } else {
                    groups[idx].hasFloat = true
                    (groups[idx].floatValue, groups[idx].floatKahanC) = Kahan.inc(
                        f, groups[idx].floatValue, groups[idx].floatKahanC)
                }

            case .avg:
                groups[idx].groupCount += 1
                if let h {
                    groups[idx].hasHistogram = true
                    if groups[idx].histogramValue != nil {
                        switch h.counterResetHint {
                        case .counterReset: groups[idx].counterResetSeen = true
                        case .notCounterReset: groups[idx].notCounterResetSeen = true
                        default: break
                        }
                        if !groups[idx].histogramIncrementalMean {
                            var v = groups[idx].histogramValue!.copy()
                            var c: FloatHistogram? = groups[idx].histogramKahanC?.copy()
                            do {
                                let (newC, res) = try v.kahanAdd(h, c)
                                c = newC
                                if res.nhcbBoundsReconciled {
                                    _ = annos.add(
                                        newMismatchedCustomBucketsHistogramsInfo(pos, .agg))
                                }
                            } catch {
                                handleAggregationError(error, pos, metricName, &annos)
                                groups[idx].incompatibleHistograms = true
                                continue
                            }
                            if !v.hasOverflow {
                                groups[idx].histogramValue = v
                                groups[idx].histogramKahanC = c
                                break
                            }
                            // The sum would overflow: convert it into a mean and continue
                            // incrementally from here.
                            groups[idx].histogramIncrementalMean = true
                            var mean = groups[idx].histogramValue!.copy()
                            _ = mean.div(groups[idx].groupCount - 1)
                            groups[idx].histogramMean = mean
                            if groups[idx].histogramKahanC != nil {
                                var kc = groups[idx].histogramKahanC!
                                _ = kc.div(groups[idx].groupCount - 1)
                                groups[idx].histogramKahanC = kc
                            }
                        }
                        let qq = (groups[idx].groupCount - 1) / groups[idx].groupCount
                        if groups[idx].histogramKahanC != nil {
                            var kc = groups[idx].histogramKahanC!
                            _ = kc.mul(qq)
                            groups[idx].histogramKahanC = kc
                        }
                        var toAdd = h.copy()
                        _ = toAdd.div(groups[idx].groupCount)
                        var scaledMean = groups[idx].histogramMean!
                        _ = scaledMean.mul(qq)
                        do {
                            let (newC, res) = try scaledMean.kahanAdd(
                                toAdd, groups[idx].histogramKahanC)
                            groups[idx].histogramMean = scaledMean
                            groups[idx].histogramKahanC = newC
                            if res.nhcbBoundsReconciled {
                                _ = annos.add(
                                    newMismatchedCustomBucketsHistogramsInfo(pos, .agg))
                            }
                        } catch {
                            handleAggregationError(error, pos, metricName, &annos)
                            groups[idx].incompatibleHistograms = true
                            continue
                        }
                    }
                } else {
                    groups[idx].hasFloat = true
                    if !groups[idx].floatIncrementalMean {
                        let (newV, newC) = Kahan.inc(
                            f, groups[idx].floatValue, groups[idx].floatKahanC)
                        if !newV.isInfinite {
                            // Still no overflow: keep the direct sum.
                            groups[idx].floatValue = newV
                            groups[idx].floatKahanC = newC
                            break
                        }
                        // It WOULD overflow, so revert to an incremental mean from here on.
                        groups[idx].floatIncrementalMean = true
                        groups[idx].floatMean =
                            groups[idx].floatValue / (groups[idx].groupCount - 1)
                        groups[idx].floatKahanC /= groups[idx].groupCount - 1
                    }
                    let qq = (groups[idx].groupCount - 1) / groups[idx].groupCount
                    // The two products are rounded BEFORE the Kahan step: `kahansum.Inc` casts
                    // all three arguments through `float64(...)` expressly to forbid fusing
                    // across the boundary (PORTING.md, prometheus/prometheus#16895).
                    (groups[idx].floatMean, groups[idx].floatKahanC) = Kahan.inc(
                        f / groups[idx].groupCount,
                        qq * groups[idx].floatMean,
                        qq * groups[idx].floatKahanC)
                }

            case .group:
                // Nothing to accumulate; the arm exists to avoid Go's `default:` panic.
                break

            case .max:
                if h != nil {
                    _ = annos.add(newHistogramIgnoredInAggregationInfo("max", pos))
                    continue
                }
                // `|| IsNaN(current)` is what lets a real value replace a NaN seed — without it a
                // group whose first sample was NaN would stay NaN forever.
                if groups[idx].floatValue < f || groups[idx].floatValue.isNaN {
                    groups[idx].floatValue = f
                }

            case .min:
                if h != nil {
                    _ = annos.add(newHistogramIgnoredInAggregationInfo("min", pos))
                    continue
                }
                if groups[idx].floatValue > f || groups[idx].floatValue.isNaN {
                    groups[idx].floatValue = f
                }

            case .count:
                groups[idx].groupCount += 1

            case .stdvar, .stddev:
                if h == nil {
                    // Welford. The second `f - mean` reads the UPDATED mean, and
                    // engine.go:3838's `value += delta * (f - mean)` is the one FMA in the whole
                    // aggregation — the subtraction rounds first, then the product and the add
                    // share a rounding.
                    groups[idx].groupCount += 1
                    let delta = f - groups[idx].floatMean
                    groups[idx].floatMean += delta / groups[idx].groupCount
                    groups[idx].floatValue = groups[idx].floatValue.addingProduct(
                        delta, f - groups[idx].floatMean)
                } else {
                    _ = annos.add(
                        newHistogramIgnoredInAggregationInfo(
                            op == .stdvar ? "stdvar" : "stddev", pos))
                }

            case .quantile:
                if h != nil {
                    _ = annos.add(newHistogramIgnoredInAggregationInfo("quantile", pos))
                    continue
                }
                groups[idx].heap.append(f)

            default:
                // Go panics with `expected aggregation operator but got %q`. The parser makes
                // this unreachable, and the four `k` operators are refused above.
                throw EvaluatorNotPorted(
                    nodeType: "AggregateExpr", detail: "unexpected operator \(op.description)")
            }
        }

        // Turn the running state into this step's output point.
        for ri in groups.indices {
            var aggr = groups[ri]
            if !aggr.seen {
                continue
            }
            switch op {
            case .avg:
                if aggr.hasFloat && aggr.hasHistogram {
                    _ = annos.add(newMixedFloatsHistogramsAggWarning(pos))
                    continue
                }
                if aggr.incompatibleHistograms {
                    continue
                } else if aggr.hasHistogram {
                    if aggr.histogramIncrementalMean {
                        if var c = aggr.histogramKahanC {
                            var mean = aggr.histogramMean!
                            // `Add` can in theory report an incompatible schema, but by here the
                            // earlier `KahanAdd`s have already succeeded — upstream discards it
                            // and so does this.
                            _ = try? mean.add(c)
                            aggr.histogramValue = mean
                            _ = c
                        } else {
                            aggr.histogramValue = aggr.histogramMean
                        }
                    } else {
                        var v = aggr.histogramValue!
                        _ = v.div(aggr.groupCount)
                        if var c = aggr.histogramKahanC {
                            _ = c.div(aggr.groupCount)
                            _ = try? v.add(c)
                        }
                        aggr.histogramValue = v
                    }
                    aggr.histogramValue = aggr.histogramValue?.compact(maxEmptyBuckets: 0)
                } else if aggr.floatIncrementalMean {
                    aggr.floatValue = aggr.floatMean + aggr.floatKahanC
                } else {
                    // TWO divisions then one add. Not `(value + c) / n`.
                    aggr.floatValue =
                        aggr.floatValue / aggr.groupCount + aggr.floatKahanC / aggr.groupCount
                }

            case .count:
                aggr.floatValue = aggr.groupCount

            case .stdvar:
                aggr.floatValue /= aggr.groupCount

            case .stddev:
                aggr.floatValue = (aggr.floatValue / aggr.groupCount).squareRoot()

            case .quantile:
                aggr.floatValue = PromQL.quantile(q, aggr.heap)

            case .sum:
                if aggr.hasFloat && aggr.hasHistogram {
                    _ = annos.add(newMixedFloatsHistogramsAggWarning(pos))
                    continue
                }
                if aggr.incompatibleHistograms {
                    continue
                } else if aggr.hasHistogram {
                    var v = aggr.histogramValue!
                    if let c = aggr.histogramKahanC {
                        _ = try? v.add(c)
                    }
                    // Note Go calls `Compact(0)` and DISCARDS the result here, unlike the AVG
                    // arm which assigns it. Reproduced: `compact` returns a new value, so the
                    // discarded call is a no-op, and the sum is emitted uncompacted.
                    _ = v.compact(maxEmptyBuckets: 0)
                    aggr.histogramValue = v
                } else {
                    aggr.floatValue += aggr.floatKahanC
                }

            default:
                // min, max and group already hold the right value.
                break
            }

            // Only AVG and SUM with histograms set these, but the flags are untouched elsewhere
            // so the check is unconditional — which is Go's own comment.
            if aggr.counterResetSeen && aggr.notCounterResetSeen {
                _ = annos.add(newHistogramCounterResetCollisionWarning(pos, .agg))
            }

            addToSeries(&outputMatrix.series[ri], enh.ts, aggr.floatValue, aggr.histogramValue)
            outputMatrix.series[ri].dropName = aggr.dropName
            groups[ri] = aggr
        }

        return annos
    }
}

/// Go: `generateGroupingKey` — the hash that decides which group a series belongs to.
///
/// Three cases, and the middle one is the surprise: `by ()` with **no labels** returns 0 without
/// hashing anything, so every series lands in one group. `without (...)` goes through
/// `HashWithoutLabels`, which drops `__name__` itself on top of the named labels.
func generateGroupingKey(_ metric: Labels, _ grouping: [String], _ without: Bool) -> UInt64 {
    if without {
        return metric.goHash(withoutNames: grouping)
    }
    if grouping.isEmpty {
        return 0
    }
    return metric.goHash(forNames: grouping)
}

/// Go: `generateGroupingLabels` — the output series' labels.
///
/// The `without` branch deletes `__name__` **explicitly**, in addition to the grouping labels —
/// `Del(grouping...)` would not, because `__name__` is not in the list. The `by ()` branch with
/// no labels returns empty labels rather than the metric.
func generateGroupingLabels(
    _ enh: EvalNodeHelper, _ metric: Labels, _ without: Bool, _ grouping: [String]
) -> Labels {
    enh.resetBuilder(metric)
    if without {
        enh.lb.del(grouping)
        enh.lb.del([LabelName.metricName])
        return enh.lb.labels()
    }
    if !grouping.isEmpty {
        enh.lb.keep(grouping)
        return enh.lb.labels()
    }
    return Labels.empty
}

/// Go: `handleAggregationError` — the one annotation an aggregation's histogram failure produces.
///
/// Only an incompatible schema is reported; every other error is silently dropped, which is why
/// the caller sets `incompatibleHistograms` itself rather than relying on this.
func handleAggregationError(
    _ err: any Error, _ pos: PositionRange, _ metricName: String, _ annos: inout Annotations
) {
    if (err as? HistogramError) == .incompatibleSchema {
        _ = annos.add(newMixedExponentialCustomHistogramsWarning(metricName, pos))
    }
}
