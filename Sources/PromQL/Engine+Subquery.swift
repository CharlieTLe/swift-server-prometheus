//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `runSubquery` (:1846), `evalSubquery` (:1918), and the
// `SubqueryExpr` arm of `eval` (:2553).
//
// A subquery evaluates its inner expression on **its own step grid** and materialises the result
// as a range vector. `foo[5m:1m]` is `foo` sampled every minute over five minutes, handed to the
// caller as if it had come from storage — which is exactly what `evalSubquery` builds: a synthetic
// `MatrixSelector` over `StorageSeries`, with no name and no matchers.
//
// ## The subquery's grid is snapped UP, and the parent's end is snapped DOWN
//
// Two alignments, in opposite directions, and both are load-bearing:
//
//	subqStart = subqInterval * ((start - offset - range) / subqInterval)
//	if subqStart <= start - offset - range { subqStart += subqInterval }
//
// Integer division truncates toward zero, so the multiply lands *at or below* the target and the
// `<=` bumps it to the first grid point **strictly after** it. That is what makes the subquery's
// window half-open at the bottom, matching a range selector's `(mint, maxt]` — and the `<=` rather
// than `<` is what excludes a sample exactly on the boundary. For a negative target the
// truncation goes the other way, which is why the correction is a test rather than a `+ 1`.
//
//	parentEnd = start + ((end - start) / interval) * interval      when interval > 0
//	subqEnd   = parentEnd - offset
//
// The parent's end is snapped **down** to its own step grid first. Upstream's comment says why:
// "so the subquery does not evaluate past the parent's last actual evaluation point when the
// caller supplied an end timestamp that is not step-aligned". A range query from 0 to 150s at a
// 60s step really ends at 120s, and without this the subquery would run 30s further than any
// parent step can read.
//
// ## `setOffsetForAtModifier` runs AGAIN, and only when the start moved
//
// `if subqStart != ev.startTimestamp { setOffsetForAtModifier(subqStart, e.Expr) }`. The `@`
// rewrite is measured from the evaluator's start time (quirk 76), and the subquery has a
// different one — so the inner selectors have to be re-rewritten against it.
//
// The **guard** is a pure optimisation, and the control for it says so: the rewrite recomputes
// `Offset` from `originalOffset` every time, so running it again with the *same* start is
// idempotent. Running it with a different one is what is required, and dropping the call entirely
// breaks.
//
// ## The synthetic selector's `Offset` is recomputed for `@`, and the ORIGINAL is kept
//
// `evalSubquery` copies `subq.OriginalOffset` and `subq.Offset` onto the vector selector, and then
// — only when the subquery had an `@` — overwrites `Offset` with
// `OriginalOffset + (parentStart - timestamp)`. Upstream's comment: "The offset of subquery is not
// modified in case of @ modifier. Hence we take care of that here for the result." Without it a
// pinned subquery's materialised matrix would be read at the wrong window by the outer call.
//
// ## Counter reset hints are DELIBERATELY erased
//
// Every `NotCounterReset` and `CounterReset` hint in the result becomes `UnknownCounterReset`.
// Upstream's comment runs to twelve lines and the reasoning is worth keeping: a subquery may skip
// the sample where a reset happened, or return it several times at a high resolution, so an
// explicit hint is more likely to be wrong than absent. It "intentionally does not attempt to be
// clever" — and the port must not either, because `rate` over a subquery would otherwise get a
// hint the underlying data does not support.
//
// Go copies the histogram (`h := *hp.H`) to avoid mutating the shared pointer; `FloatHistogram` is
// a Swift struct, so the assignment is already a copy.
//
// ## The `Call` arm REPLACES its argument in the AST, and cleans up afterwards
//
// `e.Args[i] = val` — the synthetic `MatrixSelector` is written back over the `SubqueryExpr`, so
// the rest of the `Call` arm treats it as an ordinary range selector. Go then `defer`s clearing
// `vs.Series` and subtracting the subquery's samples from `currentSamples`.
//
// The mutation is visible through `Statement()` after `Exec`: a subquery argument renders as a
// range selector with no metric name — `rate([5m])` rather than `rate(foo[5m:1m])`. That is
// upstream's, and the corpus pins it rather than tidying it away.
//
// ## Deliberately not here
//
//   * **`samplesStats`** — `UpdatePeakFromSubquery` and `MergeSamplesReadFromSubquery` are
//     observability, and the whole stats surface is dropped (PORTING.md). `evalSubquery` still
//     returns the sample count, because the `defer` needs it.
//
// ## 22 negative controls, 13 break, and the nine survivors in three kinds
//
// `Scripts/controls-subquery.sh` re-runs them. **Proofs**:
//
//   * **the parent's snap-down is an optimisation, not a semantic fix.** The largest `maxt` any
//     outer window can ask for is `lastStep - offset`, and the last step *is* `parentEnd` — so
//     `parentEnd - offset` is exactly the snapped `subqEnd`. Points the un-snapped version would
//     add lie beyond every window and are filtered. Upstream's comment frames it as correctness
//     ("so the subquery does not evaluate past the parent's last actual evaluation point"), and
//     what it actually buys is not computing them. A negative offset does not change this: it
//     moves `subqEnd` and the window's `maxt` by the same amount.
//   * `if interval > 0` versus `>= 0` — `interval` is never 0 in an evaluation (an instant query
//     uses 1), so the two are the same test.
//   * re-running `setOffsetForAtModifier` **unconditionally** is harmless: it recomputes `Offset`
//     from `originalOffset`, so a second run at the same start is idempotent. The guard is an
//     optimisation; dropping the *call* breaks.
//
// **Blocked by the float-only corpus**: the counter-reset erasure, and its exact case list
// (whether `GaugeType` is flattened too). Both need histogram input, which the differential corpus
// deliberately has none of.
//
// **Transcribed and not yet witnessed**, said plainly rather than implied:
//
//   * the synthetic selector's `Offset` recomputation for `@`. `setOffsetForAtModifier` has already
//     set `subq.Offset` to `originalOffset + (statementStart - timestamp)`, and this recomputes it
//     against the *current* evaluator's start — so the two agree unless the evaluator's start has
//     moved, which needs a subquery nested inside a subquery or inside a shifted step-invariant
//     wrapper. Reachable in principle; not reached here.
//   * the `defer` that releases the subquery's samples and clears its series. It should be
//     visible to an enclosing `rangeEval` reading `currentSamples` as its `tempNumSamples`, the
//     way quirk 81's tail is, and the `sum(rate(sq[…]))` sample-limit sweep does not separate them.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromLabels
internal import PromQLParser
internal import PromStorage

extension Evaluator {
    /// Go: `runSubquery` — evaluate the inner expression on the subquery's own step grid.
    ///
    /// Returns the value and the child's final `currentSamples`, which the caller adopts. Go
    /// passes `ev.currentSamples` in and copies it back out; the same here, explicitly.
    func runSubquery(_ ctx: GoContext, _ e: SubqueryExpr, _ ws: inout Annotations) throws
        -> any Value
    {
        let offsetMillis = durationMilliseconds(e.offset)
        let rangeMillis = durationMilliseconds(e.range)

        // The parent's end, snapped DOWN to its own step grid — see the file header.
        var parentEnd = endTimestamp
        if interval > 0 {
            parentEnd = startTimestamp + ((endTimestamp - startTimestamp) / interval) * interval
        }
        let subqEnd = parentEnd - offsetMillis

        let subqInterval: Int64
        if e.step.nanoseconds != 0 {
            subqInterval = durationMilliseconds(e.step)
        } else {
            // Where the engine's default subquery interval finally lands.
            subqInterval = noStepSubqueryIntervalFn?(rangeMillis) ?? 0
        }
        let target = startTimestamp - offsetMillis - rangeMillis
        var subqStart = subqInterval * (target / subqInterval)
        // Snapped UP to the first grid point strictly after the target, which is what makes the
        // window half-open at the bottom. `<=`, not `<`.
        if subqStart <= target {
            subqStart += subqInterval
        }

        let newEv = Evaluator(
            startTimestamp: subqStart, endTimestamp: subqEnd, interval: subqInterval,
            currentSamples: currentSamples, maxSamples: maxSamples, lookbackDelta: lookbackDelta,
            noStepSubqueryIntervalFn: noStepSubqueryIntervalFn,
            enableDelayedNameRemoval: enableDelayedNameRemoval,
            enableTypeAndUnitLabels: enableTypeAndUnitLabels,
            useStartTimestamps: useStartTimestamps)

        if subqStart != startTimestamp {
            // The `@` rewrite is measured from the evaluator's start time, and this evaluator has
            // a different one. The GUARD is a pure optimisation — the rewrite recomputes `Offset`
            // from `originalOffset`, so re-running it with the same start is idempotent — but the
            // call itself is required.
            setOffsetForAtModifier(subqStart, e.expr)
        }

        let res = try newEv.evalNode(ctx, e.expr, &ws)
        currentSamples = newEv.currentSamples
        return res
    }

    /// Go: `evalSubquery` — run the subquery and hand back an equivalent `MatrixSelector`.
    ///
    /// "Note that the Name and LabelMatchers are not set", which is why the rewritten AST renders
    /// as a nameless range selector.
    func evalSubquery(_ ctx: GoContext, _ subq: SubqueryExpr, _ ws: inout Annotations) throws
        -> (MatrixSelector, Int)
    {
        let val = try runSubquery(ctx, subq, &ws)
        guard var mat = val as? Matrix else {
            throw EvaluatorNotPorted(
                nodeType: "SubqueryExpr", detail: "inner expression is not a matrix")
        }

        let vs = VectorSelector()
        vs.originalOffset = subq.originalOffset
        vs.offset = subq.offset
        vs.timestamp = subq.timestamp
        if let t = subq.timestamp {
            // "The offset of subquery is not modified in case of @ modifier. Hence we take care of
            // that here for the result."
            vs.offset = GoDuration(
                nanoseconds: subq.originalOffset.nanoseconds + (startTimestamp - t) * 1_000_000)
        }
        let ms = MatrixSelector(vectorSelector: vs, range: subq.range)

        var series: [any PromStorage.Series] = []
        series.reserveCapacity(mat.series.count)
        for si in mat.series.indices {
            // Erase every explicit counter reset hint. A subquery may skip the sample where a
            // reset happened or return it several times, so an explicit hint is more likely wrong
            // than absent — see the file header for upstream's full reasoning.
            for i in mat.series[si].histograms.indices {
                switch mat.series[si].histograms[i].h.counterResetHint {
                case .notCounterReset, .counterReset:
                    // Go shallow-copies to avoid mutating the shared pointer; a Swift struct
                    // assignment already is that copy.
                    mat.series[si].histograms[i].h.counterResetHint = .unknownCounterReset
                default:
                    break
                }
            }
            series.append(StorageSeries(mat.series[si]))
        }
        vs.series = series
        return (ms, mat.totalSamples)
    }
}
