//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — the `matrixArg` half of `eval`'s `Call` arm
// (:2118-2455).
//
// This is what makes all 82 ported `FunctionCalls` bodies reachable: `rate(foo[5m])`,
// `sum_over_time(foo[1h])`, `histogram_quantile(0.9, foo)`, `absent_over_time(foo[5m])`. Every
// one of those bodies has been pinned in isolation for several slices now — the oracle calls
// them directly, because `FunctionCall` and every type in its signature are exported — so what
// this adds is not the arithmetic but the **plumbing**: which window each step sees, what is
// reused between steps, and what the accounting does.
//
// Read HANDOFF §3's warning about plumbing before touching this: *when a layer's job is
// plumbing, its corpus needs values chosen to make the layer below distinguishable, not values
// that are interesting to the layer below.*
//
// ## One series at a time, all steps — not one step at a time, all series
//
// The loop nesting is the opposite of `rangeEval`'s, and it is the reason `matrixIterSlice`
// takes reusable slices at all. `rangeEval` is `for ts { for series }`; this is
// `for series { for ts }`. So one series' whole time range is computed before the next series
// is touched, which lets the buffer and the point slices be reused across *steps* rather than
// thrown away per step.
//
// Consequences that a single-step query cannot show:
//
//   * `it.ReduceDelta(stepRange)` shrinks the buffer's retention after the first step, where
//     `stepRange = min(selRange, ev.interval)` — so a step **larger** than the range stops
//     buffering the whole range;
//   * `matrixIterSlice`'s retention actually runs, with all the accounting quirk 82 describes;
//   * `enh.Out = outVec[:0]` hands the body's own output back as next step's scratch.
//
// ## `refetch` is why an `@`-pinned range selector is evaluated once
//
// `refetch := ts == ev.startTimestamp || selVS.Timestamp == nil`. With `@` the window does not
// move, so the matrix is fetched at step 0 and **reused verbatim** for every later step —
// `floats`/`histograms` are simply not touched again. Without `@` every step refetches. This is
// the range-selector counterpart of `StepInvariantExpr`'s duplication (quirk 80), reached by a
// different mechanism: the same *input*, not the same *output*.
//
// ## `dropName` is decided by the function, then ORed with the input's
//
// `last_over_time` and `first_over_time` keep the metric name — they behave like `offset` — and
// every other range function drops it. Then `inputDropName` is ORed in, read off a
// `*StorageSeries` when the input came from a subquery that had already dropped it. With
// `enableDelayedNameRemoval` false the labels are stripped here; with it true only the flag is
// set.
//
// ## The sample limit is checked ONCE PER SERIES, after all its steps
//
// Not per step. `ev.currentSamples + len(ss.Floats) + histSamples > ev.maxSamples` runs after
// the step loop, so a series is computed in full and then rejected — and the running total only
// includes *previous* series plus the current `floats`/`histograms` window. `matrixIterSlice`
// does its own per-point check on top, so as in `rangeEval` the limit is enforced in two places
// with different granularities (quirk 74).
//
// After the last series, `ev.currentSamples -= len(floats) + totalHPointSize(histograms)`
// releases the final window — the mirror of `rangeEval`'s tail assignment (quirk 81).
//
// ## `absent_over_time` rewrites the whole result, and its early exits are order-dependent
//
// It has to return 0 or 1 series where the matrix holds many, so it runs *after* the loop and
// looks for a timestamp no series covered. Two early exits, and the second is inside the loop:
//
//   * any single series with `len(Floats)+len(Histograms) == steps` → empty result;
//   * while accumulating the covered timestamps, `if i > 0 && len(found) == steps` → empty.
//
// The `i > 0` is load-bearing: with one series the first exit already covered it, and the guard
// stops the second from firing on `i == 0` before its own `found` is complete. `dropName` is
// carried onto the synthetic series even though it has no name to drop.
//
// ## The rate/increase non-counter info reads the INPUT's name, after the output exists
//
// `inMatrix[0].Metric` — the *unmodified* selector labels, not `ss.Metric`, which may have had
// `__name__` dropped. Two spellings depending on `enableTypeAndUnitLabels`: with it on the
// `__type__` label must be `counter` or `histogram`, with it off the name must end in `_total`,
// `_sum`, `_count` or `_bucket`. Guarded by `len(ss.Floats) > 0`, so a series that produced only
// histograms never warns.
//
// ## Deliberately not here
//
//   * **`SubqueryExpr` as the matrix argument** — needs `evalSubquery`/`runSubquery`, which are
//     a slice of their own. `matrixFromSubquery` and the `defer` that releases the subquery's
//     samples are therefore absent too, and a subquery argument still throws by name.
//   * **`label_replace`, `label_join`, `info`** — they work on series rather than samples and
//     are reached by the evaluator directly, not through `FunctionCalls` (quirk 62).
//   * **`samplesStats`** — observability; `countSamplesAfter` exists only to feed it, so it is
//     not ported either.
//
// ## 31 negative controls, 22 break, and the nine survivors each have an argument
//
// `Scripts/controls-callmatrix.sh` re-runs them. Four of the survivors are **proofs**:
//
//   * `stepRange = min(selRange, ev.interval)` versus either operand alone, and dropping
//     `ReduceDelta` entirely, are all **provably unobservable**. Every one of those spellings
//     leaves the buffer's delta *greater than or equal to* the correct value, `ReduceDelta`
//     refuses to raise a delta, and `matrixIterSlice` appends only `t > mintFloats` — so extra
//     buffered points are filtered out. `ReduceDelta` is a memory optimisation and nothing else,
//     which is worth knowing before "fixing" it.
//   * taking the **last** range argument rather than the first cannot differ: no entry in
//     `FunctionCalls` takes two.
//   * taking the **last** sample of the output vector rather than the first cannot differ
//     either: a range function returns nought or one sample, and the many-sample bodies
//     (`histogram_quantile`, the sorts) have no matrix argument.
//   * incrementing `currentSamples` **before** appending to the matrix rather than after is
//     inert: the limit check precedes both and nothing between them reads either. Go's order is
//     kept because Go's `prevSS = &mat[len(mat)-1]` sits between them, and that is pool sizing.
//   * `absent_over_time`'s `i > 0` guard is **redundant**. After `i == 0`, `found` holds exactly
//     series 0's timestamps, so `found.count == steps` implies series 0 has `steps` points —
//     which the *first* early exit has already caught. Upstream's, and harmless.
//
// Two are unreachable rather than unobservable, and will become testable:
//
//   * `inputDropName` needs a `StorageSeries` input, which only a **subquery** produces;
//   * `absent_over_time`'s synthetic series carrying `dropName` is invisible because
//     `createLabelsForAbsentFunction` skips `__name__`, so there is no name to drop, and
//     `Matrix.String()` does not render the flag. It becomes observable when something
//     downstream reads `DropName` — the delayed-name-removal cleanup, or an outer aggregation.
//
// ## What the corpus had to gain before four of the others would break
//
// Worth reading before adding to it, because each was a *different* kind of blindness:
//
//   * **off-grid samples**, for `smoothed`'s `maxt += lookback`. With samples on the step grid
//     the interpolated boundary coincides with a real sample.
//   * **sparse** off-grid samples, for `anchored`'s buffer widening. Dense samples mean the
//     unwidened buffer still catches a boundary sample; the widening only does work when the
//     nearest one is more than a `selRange` away.
//   * a scalar argument that **moves with the step** (`scalar(vector(time() / 400))`), for the
//     per-step `evalVals[j][0].Floats[step]` lookup. Every constant argument reads the same.
//   * an at-modifier-**unsafe** function with an `@`-pinned range (`predict_linear(foo[2m] @ 120,
//     3600)`), for `refetch`'s `selVS.Timestamp == nil` clause. `rate(foo[2m] @ 120)` cannot do
//     it: the whole Call is step-invariant, so `preprocessExpr` wraps it and the child evaluator
//     has one step, where `ts == ev.startTimestamp` is always true anyway.
//   * a **single-sample** series, for the non-counter info's `len(ss.Floats) > 0` guard — `rate`
//     needs two points, so the series contributes nothing and the check still runs.
//   * a range function **nested inside another** `rangeEval` under a tight `maxSamples`, for the
//     final window release. Same mechanism as quirk 81.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromChunkEnc
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromQLParser
internal import PromSchema
internal import PromStorage

extension Evaluator {
    /// Go: the second half of `eval`'s `*parser.Call` arm — a function with a range-vector
    /// argument.
    ///
    /// `matrixArgIndex` is found by the caller; everything from "evaluate any non-matrix
    /// arguments" onwards is here.
    func evalCallWithMatrixArg(
        _ ctx: GoContext, _ e: Call, _ call: FunctionCall, _ matrixArgIndex: Int,
        _ warnings: inout Annotations
    ) throws -> Matrix {
        let funcName = e.function?.name ?? ""

        // The non-matrix arguments are evaluated in full, once, and then read per step. They
        // are scalars, so each is a one-series matrix with a point per step — which is why the
        // step NUMBER indexes them safely below.
        var evalVals = [Matrix?](repeating: nil, count: e.args.count)
        for (i, arg) in e.args.enumerated() where i != matrixArgIndex {
            let val = try evalNode(ctx, arg, &warnings)
            guard let m = val as? Matrix else {
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "non-matrix argument is not a matrix")
            }
            evalVals[i] = m
        }

        guard let sel = e.args[matrixArgIndex] as? MatrixSelector,
            let selVS = sel.vectorSelector as? VectorSelector
        else {
            throw EvaluatorNotPorted(
                nodeType: "Call", detail: "\(funcName) over a subquery needs evalSubquery")
        }

        // The extended range modifiers are only meaningful for a handful of functions, and the
        // error names the permitted ones SORTED — `slices.Sorted(maps.Keys(...))`, because the
        // set is a Go map and the message would otherwise be nondeterministic.
        if selVS.anchored {
            if !anchoredSafeFunctions.contains(funcName) {
                throw EvaluationError.modifierNotSafeForFunction(
                    modifier: "anchored", permitted: anchoredSafeFunctions.sorted(),
                    function: funcName)
            }
        } else if selVS.smoothed {
            if !smoothedSafeFunctions.contains(funcName) {
                throw EvaluationError.modifierNotSafeForFunction(
                    modifier: "smoothed", permitted: smoothedSafeFunctions.sorted(),
                    function: funcName)
            }
        }

        do {
            _ = warnings.merge(try checkAndExpandSeriesSet(ctx, sel))
        } catch {
            var carried = warnings
            throw ErrWithWarnings(
                StorageExpansionError(underlying: error), carried.merge(Annotations()))
        }

        var mat = Matrix()
        mat.series.reserveCapacity(selVS.series.count)
        let offset = durationMilliseconds(selVS.offset)
        let selRange = durationMilliseconds(sel.range)
        let lookback = durationMilliseconds(lookbackDelta)

        // How much the buffer keeps from the second step on. `min` with the interval: when the
        // step is smaller than the range the range wins, and when it is larger the step does —
        // so a sparse range query stops retaining a full window it will never reuse.
        let stepRange: Int64
        var bufferRange = selRange
        if selVS.anchored {
            stepRange = Swift.min(selRange + lookback, interval)
            bufferRange += lookback
        } else if selVS.smoothed {
            stepRange = Swift.min(selRange + 2 * lookback, interval)
            bufferRange += 2 * lookback
        } else {
            stepRange = Swift.min(selRange, interval)
        }

        // Reused across steps AND across series — the point of the whole loop nesting.
        var floats: [FPoint]? = nil
        var histograms: [HPoint]? = nil
        var inMatrix = Matrix([Series(metric: .empty)])
        let enh = EvalNodeHelper()
        enh.enableDelayedNameRemoval = enableDelayedNameRemoval
        let it = newBuffer(delta: bufferRange)
        var chkIter: (any ChunkIterator)? = nil

        // Only four functions read start timestamps, and only when the engine has them on.
        var startTimestamps: StartTimestamps? = nil
        if useStartTimestamps
            && ["rate", "irate", "increase", "resets"].contains(funcName)
        {
            startTimestamps = StartTimestamps()
        }

        // `last_over_time`/`first_over_time` act like `offset`, so they keep the name.
        let dropName = funcName != "last_over_time" && funcName != "first_over_time"
        var vectorVals = [Vector](repeating: Vector(), count: Swift.max(e.args.count - 1, 0))

        for s in selVS.series {
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            // Release the previous series' window before reusing the slices.
            currentSamples -= (floats?.count ?? 0) + totalHPointSize(histograms ?? [])
            if floats != nil {
                floats = []
            }
            if histograms != nil {
                histograms = []
            }
            startTimestamps?.reset()

            chkIter = s.iterator(chkIter)
            it.reset(chkIter!)

            // A subquery's result carries its own `DropName`, and it wins even for
            // `last_over_time`. Reachable only once subqueries land; transcribed because the OR
            // is the contract rather than the lookup.
            var inputDropName = false
            if let storageSeries = s as? StorageSeries {
                inputDropName = storageSeries.promSeries.dropName
            }
            let seriesDropName = dropName || inputDropName

            var metric = s.labels()
            if !enableDelayedNameRemoval && seriesDropName {
                metric = metric.dropReserved(isMetadataLabel)
            }
            var ss = Series(metric: metric, dropName: seriesDropName)
            // The UNMODIFIED labels, which the rate/increase info below reads.
            inMatrix.series[0].metric = s.labels()

            var ts = startTimestamp
            var step = -1
            while ts <= endTimestamp {
                step += 1
                // The scalar arguments for this step. They have no gaps, so the step number is
                // a safe index into each one's point list.
                var counter = 0
                for j in e.args.indices where j != matrixArgIndex {
                    vectorVals[counter] = Vector([
                        Sample(f: evalVals[j]!.series[0].floats[step].f)
                    ])
                    counter += 1
                }

                // With `@` the window never moves, so it is fetched once and reused.
                let refetch = ts == startTimestamp || selVS.timestamp == nil
                if refetch {
                    var maxt = ts - offset
                    var mint = maxt - selRange
                    if selVS.anchored {
                        mint -= lookback
                    } else if selVS.smoothed {
                        mint -= lookback
                        maxt += lookback
                    }
                    try matrixIterSlice(it, mint, maxt, &floats, &histograms, &startTimestamps)
                }
                if (floats?.count ?? 0) + (histograms?.count ?? 0) == 0 {
                    ts += interval
                    continue
                }

                inMatrix.series[0].floats = floats ?? []
                inMatrix.series[0].histograms = histograms ?? []
                enh.ts = ts
                enh.startTimestamps = startTimestamps

                let (outVec, annos) = try call(vectorVals, inMatrix, e.args, enh)
                _ = warnings.merge(annos)

                // The body's own output becomes next step's scratch.
                enh.out = Vector()
                if let first = outVec.samples.first {
                    if first.h == nil {
                        ss.floats.append(FPoint(t: ts, f: first.f))
                    } else {
                        ss.histograms.append(HPoint(t: ts, h: first.h!))
                    }
                }
                // From the second step on the buffer only needs `stepRange`.
                it.reduceDelta(stepRange)
                ts += interval
            }

            let histSamples = totalHPointSize(ss.histograms)
            if ss.floats.count + histSamples > 0 {
                // Checked once per series, after every step of it has been computed.
                if currentSamples + ss.floats.count + histSamples > maxSamples {
                    throw QueryError.tooManySamples(evaluationEnv)
                }
                mat.series.append(ss)
                currentSamples += ss.floats.count + histSamples
            }

            if funcName == "rate" || funcName == "increase" {
                // The INPUT's name, not the output's — `ss.metric` may have lost `__name__`.
                let metricName = inMatrix.series[0].metric[LabelName.metricName]
                if !metricName.isEmpty && !ss.floats.isEmpty {
                    if enableTypeAndUnitLabels {
                        let typeLabel = inMatrix.series[0].metric["__type__"]
                        if typeLabel != MetricType.counter.rawValue
                            && typeLabel != MetricType.histogram.rawValue
                        {
                            _ = warnings.add(
                                newPossibleNonCounterLabelInfo(
                                    metricName, typeLabel, e.args[0].positionRange))
                        }
                    } else if !metricName.hasSuffix("_total") && !metricName.hasSuffix("_sum")
                        && !metricName.hasSuffix("_count") && !metricName.hasSuffix("_bucket")
                    {
                        _ = warnings.add(
                            newPossibleNonCounterInfo(metricName, e.args[0].positionRange))
                    }
                }
            }
        }

        // Release the last series' window.
        currentSamples -= (floats?.count ?? 0) + totalHPointSize(histograms ?? [])

        if funcName == "absent_over_time" {
            return absentOverTimeResult(mat, e, dropName)
        }

        if !enableDelayedNameRemoval && mat.containsSameLabelset {
            throw EvaluationError.duplicateLabelset
        }
        return mat
    }

    /// Go: the `absent_over_time` tail of the `Call` arm — turn a many-series matrix into the
    /// 0-or-1 series the function is documented to return.
    ///
    /// The two early exits are both "some timestamp is covered everywhere", found two different
    /// ways: a single complete series, or the union across series. The second is guarded by
    /// `i > 0` because with one series the first pass already answered.
    private func absentOverTimeResult(_ mat: Matrix, _ e: Call, _ dropName: Bool) -> Matrix {
        let steps = Int(1 + (endTimestamp - startTimestamp) / interval)

        for s in mat.series where s.floats.count + s.histograms.count == steps {
            return Matrix()
        }

        var found = Set<Int64>()
        for (i, s) in mat.series.enumerated() {
            for p in s.floats {
                found.insert(p.t)
            }
            for p in s.histograms {
                found.insert(p.t)
            }
            if i > 0 && found.count == steps {
                return Matrix()
            }
        }

        var newp = [FPoint]()
        newp.reserveCapacity(Swift.max(steps - found.count, 0))
        var ts = startTimestamp
        while ts <= endTimestamp {
            if !found.contains(ts) {
                newp.append(FPoint(t: ts, f: 1))
            }
            ts += interval
        }

        return Matrix([
            Series(
                metric: createLabelsForAbsentFunction(e.args[0]), floats: newp,
                dropName: dropName)
        ])
    }
}
