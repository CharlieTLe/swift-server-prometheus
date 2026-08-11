//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `smoothSeries` (:1751), the `smoothed` arm of the
// `VectorSelector` case, and `VectorBinop`'s **fill modifiers** (:3294-3320).
//
// The two remaining arms of the evaluator that need nothing outside `PromQL`. What is left after
// this is `label_replace` (blocked on Pike VM capture tracking in `PromRegex`) and `info`.
//
// ## `smoothed` on a bare selector is not `smoothed` on a range selector
//
// `foo smoothed` interpolates the *selector's own* samples onto the step grid, where
// `foo[5m] smoothed` widens a range window and lets `extendFloats` add boundary points
// (`Engine+MatrixSelector.swift`). Different function, different result, same keyword.
//
// One buffer for the whole query, sized `(end - start) + 2 * lookbackDelta` — not per step. Each
// step then asks `matrixIterSlice` for `[dataTS - lookback, dataTS + lookback]`, a window that
// reaches **forward**, which is what makes interpolation possible at all: a plain selector can
// only look back.
//
// ## Four cases per step, and the binary search decides which
//
// `i = sort.Search(points, { points[i].T >= dataTS })` — the first point at or after the target:
//
//	i in range && T == dataTS   exact hit; the value is copied and RE-STAMPED with `evalTS`
//	0 < i < len                 interpolate between `i-1` and `i`
//	i == len (so i > 0)         no later point yet — CARRY FORWARD `i-1`'s value
//	i == 0                      no earlier point — skip the step entirely
//
// The third and fourth are the asymmetry: past the end of the data the last value is held, but
// *before* the data starts nothing is produced. And every emitted point carries `evalTS`, not the
// sample's own timestamp — the whole point is to land on the step grid.
//
// A carried-forward **histogram** has its `CounterResetHint` reset to `UnknownCounterReset`,
// because "the hint describes the relationship between consecutive samples, not the value". An
// exact hit does not, and neither does the interpolation, which computes its own.
//
// ## Histograms and floats in one window are refused, not merged
//
// `len(hists) > 0 && len(floats) > 0` adds `NewMixedFloatsHistogramsWarning` and skips the step.
// So a series that changes type mid-window loses that step rather than picking one. Note the
// order: the mixed check comes **before** either branch, so it wins over both.
//
// The histogram interpolation treats the pair as a **counter unless both** carry the gauge hint —
// `prev != GaugeType || next != GaugeType` — which is the opposite of what "unless either" would
// give, and it is deliberate: one gauge sample next to an unknown one is still counter-ish.
//
// ## The fill modifiers make an unmatched group produce output
//
// `fill_left`/`fill_right`/`fill` supply a value for a match group that only one side has. Two
// consequences that are easy to miss:
//
//   * the empty-side **short-circuit** at the top of `VectorBinop` is skipped when either fill is
//     set, so `foo + fill_right(0) bar` still runs with an empty `bar`;
//   * the synthesised sample's metric is `MatchLabels(on, matchingLabels...)` — the *join labels
//     only*, not the other side's full label set. So a filled result carries whatever
//     `resultMetric` then makes of that, which for one-to-one `on(job)` is just `{job=…}`.
//
// The left-hand fill loop runs **after** the main loop and skips any ordinal already matched —
// `matchedSigsPresent[sigOrd]` for one-to-one, `matchedSigs[sigOrd]` non-empty otherwise. So it
// only fires for right-hand groups the left never had.
//
// ## 9 negative controls, 7 break, and one survivor is a proof
//
// `sort.Search`'s boundary — `>= dataTS` versus `> dataTS` — cannot change an answer. With `>`, an
// exact hit is not found by the search, so `i - 1` *is* the exact sample and the interpolation
// branch runs with `prev.T == dataTS`, which returns `prev.F`; and for a trailing exact hit the
// carry-forward branch returns the same value. Both spellings agree at every point, and the
// timestamp is `evalTS` either way.
//
// The other survivor was a corpus gap and is closed: the exact-hit **re-stamping** needs a
// non-zero `offset`, because with no offset `evalTS == dataTS == sample.T` and keeping the
// sample's own timestamp gives the same answer.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromChunkEnc
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromPosRange
internal import PromQLParser
internal import PromStorage

extension Evaluator {
    /// Go: `smoothSeries` — interpolate a selector's samples onto the step grid.
    ///
    /// One buffer for the whole query, and a window that reaches **forward** by a lookback delta —
    /// which is what a plain selector cannot do and what interpolation needs.
    func smoothSeries(
        _ series: [any PromStorage.Series], _ offset: GoDuration, _ pos: PositionRange
    ) throws -> (Matrix, Annotations) {
        let dur = endTimestamp - startTimestamp
        let lb = durationMilliseconds(lookbackDelta)
        let it = newBuffer(delta: dur + 2 * lb)
        let offMS = durationMilliseconds(offset)
        let step = interval

        var chkIter: (any ChunkIterator)? = nil
        var mat = Matrix()
        mat.series.reserveCapacity(series.count)
        var annos = Annotations()

        for s in series {
            var ss = Series(metric: s.labels())
            chkIter = s.iterator(chkIter)
            it.reset(chkIter!)

            // Reused across steps, as in the `Call` arm — `matrixIterSlice`'s retention is what
            // keeps this linear.
            var floats: [FPoint]? = nil
            var hists: [HPoint]? = nil
            var sts: StartTimestamps? = nil
            let metricName = s.labels()[LabelName.metricName]

            var evalTS = startTimestamp
            while evalTS <= endTimestamp {
                defer { evalTS += step }
                let dataTS = evalTS - offMS
                // Reaches FORWARD as well as back, unlike every other selector window.
                try matrixIterSlice(it, dataTS - lb, dataTS + lb, &floats, &hists, &sts)
                let f = floats ?? []
                let h = hists ?? []
                if f.isEmpty && h.isEmpty {
                    continue
                }
                // Checked BEFORE either branch, so a type change mid-window loses the step
                // rather than picking a side.
                if !h.isEmpty && !f.isEmpty {
                    _ = annos.add(newMixedFloatsHistogramsWarning(metricName, pos))
                    continue
                }

                if !h.isEmpty {
                    let i = goSortSearch(h.count) { h[$0].t >= dataTS }
                    if i < h.count && h[i].t == dataTS {
                        // Exact hit, RE-STAMPED with the step's timestamp.
                        ss.histograms.append(HPoint(t: evalTS, h: h[i].h.copy()))
                    } else if i > 0 && i < h.count {
                        let prev = h[i - 1]
                        let next = h[i]
                        if prev.h.usesCustomBuckets != next.h.usesCustomBuckets {
                            _ = annos.add(
                                newMixedExponentialCustomHistogramsWarning(metricName, pos))
                            continue
                        }
                        // A COUNTER unless BOTH carry the gauge hint — not "unless either".
                        let isCounter =
                            prev.h.counterResetHint != .gaugeType
                            || next.h.counterResetHint != .gaugeType
                        do {
                            let interpolated = try interpolateHistograms(
                                prev.h, prev.t, next.h, next.t, dataTS, isCounter, &annos, pos)
                            ss.histograms.append(HPoint(t: evalTS, h: interpolated))
                        } catch {
                            annosFromInterpolationError(&annos, error, metricName, pos)
                            continue
                        }
                    } else if i > 0 {
                        // Past the end of the data: CARRY FORWARD, with the hint erased because
                        // "the hint describes the relationship between consecutive samples, not
                        // the value".
                        var carried = h[i - 1].h.copy()
                        carried.counterResetHint = .unknownCounterReset
                        ss.histograms.append(HPoint(t: evalTS, h: carried))
                    }
                    // i == 0: nothing earlier, so the step produces nothing. Note the asymmetry
                    // with the carry-forward above.
                } else {
                    let i = goSortSearch(f.count) { f[$0].t >= dataTS }
                    if i < f.count && f[i].t == dataTS {
                        ss.floats.append(FPoint(t: evalTS, f: f[i].f))
                    } else if i > 0 && i < f.count {
                        // `isCounter` is hard-coded false; upstream's
                        // `TODO: detect if the sample is a counter` is why.
                        let val = interpolate(f[i - 1], f[i], dataTS, false)
                        ss.floats.append(FPoint(t: evalTS, f: val))
                    } else if i > 0 {
                        ss.floats.append(FPoint(t: evalTS, f: f[i - 1].f))
                    }
                }
            }

            if !ss.floats.isEmpty || !ss.histograms.isEmpty {
                mat.series.append(ss)
            }
        }
        return (mat, annos)
    }
}
