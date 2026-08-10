//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — `irate`, `idelta` and the
// `instantValue` body they share, plus `isStartTimestampReset` from engine.go.
//
// These are the first two of the rate family. `rate`, `increase` and `delta` go
// through `extrapolatedRate`, which needs `interpolate`/`correctForCounterResets`
// and is a separate slice.
//
// ## The two-sample selection is the whole function
//
// `instantValue` takes the **last two samples overall**, and does it in two passes:
// the last two floats go into `ss` in order, then the last two histograms are
// *merged in* by timestamp with a four-way switch. The switch is not a sort — it
// is a hand-written insertion that keeps `ss` at length 2, and its cases are the
// interesting part:
//
//   * a histogram older than `ss[0]` is **discarded**;
//   * a histogram newer than `ss[1]` shifts `ss[1]` down to `ss[0]`;
//   * anything else — including an **equal** timestamp — overwrites `ss[0]`.
//
// So a float and a histogram at the same timestamp end up as `ss[0] = histogram`,
// `ss[1] = float`, which lands in the mixed-kind branch and yields a warning rather
// than a value. Upstream's comment calls that "a correct order, even in the
// (irregular) case of equal timestamps".
//
// ## `isRate` flips almost every decision
//
// | | `irate` | `idelta` |
// |---|---|---|
// | float counter reset (`ss[1].F < ss[0].F`) | result stays `ss[1]` | subtracted anyway |
// | histogram hint is `GaugeType` | warns (not a counter) | — |
// | histogram hint is *not* `GaugeType` | — | warns (not a gauge) |
// | histogram counter reset | subtraction skipped | subtracted anyway |
// | final | divided by the interval in seconds | left as a difference |
//
// The float reset case is easy to get wrong: on a reset the result is **left at
// `ss[1]`**, i.e. the raw newer value, not zero and not the difference. `resultSample`
// is seeded from `ss[1]` for exactly that reason.
//
// ## Position ranges come from the whole argument list
//
// Every annotation here is reported against `args.PositionRange()` — the range of
// the **`Expressions` slice**, not of `args[0]`. That is `Expressions.positionRange`
// in the port, and it is why an empty argument list would report -1/-1.
//
// ## Start timestamps
//
// `enh.StartTimestamps` is nil until Phases 6-7 bring the ST-aware selectors, so
// every `ST` here is 0 and `isStartTimestampReset` returns false on its first line.
// The helper is ported in full anyway — it is small, it is read by `resets` and
// `changes` too, and porting it later against a live caller is how the `quantile`
// bug happened (PORTING.md quirk 52).
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromQLParser

/// Go: `isStartTimestampReset` (engine.go) — whether an OTel start timestamp implies
/// a counter reset between two samples.
///
/// Five branches, and the order matters. An unset (`0`) or clearly invalid current
/// start timestamp is **never** a reset; a current start timestamp pointing at or
/// past the previous *sample* is; and the equal case falls through to asking whether
/// the previous start timestamp was known, because a cumulative series with an
/// unknown start is not a reset while a delta series is.
func isStartTimestampReset(
    _ prevStartTimestamp: Int64, _ prevTimestamp: Int64,
    _ currStartTimestamp: Int64, _ currTimestamp: Int64
) -> Bool {
    if currStartTimestamp == 0 || currStartTimestamp > currTimestamp {
        // Not set, or clearly invalid.
        return false
    }
    if currStartTimestamp < prevTimestamp {
        return false
    }
    if currStartTimestamp > prevTimestamp {
        return true
    }
    // The current start timestamp points at the previous datapoint. A previous start
    // timestamp beyond the previous sample is invalid, so treat it as unknown rather
    // than report a spurious reset.
    if prevStartTimestamp > prevTimestamp {
        return false
    }
    return prevStartTimestamp != 0
}

/// One of the two samples `instantValue` works on, plus its start timestamp.
private struct SampleWithST {
    var sample: Sample
    var st: Int64 = 0
}

/// Go: `instantValue` — the shared body of `irate` and `idelta`.
///
/// Note it indexes `vals[0]` **before** any guard, so an empty matrix traps. That
/// matches Go, which panics; no upstream caller can produce one, because `rangeEval`
/// only calls a range function for a series it found.
func instantValue(
    _ vals: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper, _ isRate: Bool
) -> (Vector, Annotations) {
    let samples = vals[0]
    var out = enh.out
    var ss: [SampleWithST] = []
    var annos = Annotations()
    let pos = Expressions.positionRange(args)

    // No sense computing a rate from fewer than two points.
    if samples.floats.count + samples.histograms.count < 2 {
        return (out, Annotations())
    }

    // The last two floats, in order.
    for i in max(0, samples.floats.count - 2)..<samples.floats.count {
        ss.append(
            SampleWithST(sample: Sample(t: samples.floats[i].t, f: samples.floats[i].f)))
    }

    // The last two histograms, merged in by timestamp. See the file header for why
    // the equal-timestamp case overwrites `ss[0]`.
    for i in max(0, samples.histograms.count - 2)..<samples.histograms.count {
        var s = SampleWithST(sample: Sample(t: samples.histograms[i].t))
        s.sample.h = samples.histograms[i].h
        if ss.isEmpty {
            ss.append(s)
        } else if ss.count == 1 {
            if s.sample.t < ss[0].sample.t {
                ss.insert(s, at: 0)
            } else {
                ss.append(s)
            }
        } else if s.sample.t < ss[0].sample.t {
            // Older than the first: discard.
        } else if s.sample.t > ss[1].sample.t {
            // Newest: shift the old second down.
            ss[0] = ss[1]
            ss[1] = s
        } else {
            ss[0] = s
        }
    }

    // Seeded from ss[1], which is what a float counter reset leaves in place.
    var resultSample = ss[1]
    let sampledInterval = ss[1].sample.t - ss[0].sample.t
    if sampledInterval == 0 {
        // Avoid dividing by 0.
        return (out, Annotations())
    }

    if ss[1].sample.h == nil && ss[0].sample.h == nil {
        let reset =
            ss[1].sample.f < ss[0].sample.f
            || isStartTimestampReset(
                ss[0].st, ss[0].sample.t, ss[1].st, ss[1].sample.t)
        if !isRate || !reset {
            // Gauge, or a counter without a reset, or a counter with a NaN value.
            resultSample.sample.f = ss[1].sample.f - ss[0].sample.f
        }
        // On a counter reset the result is left at ss[1] — the raw newer value.
    } else if let newer = ss[1].sample.h, let older = ss[0].sample.h {
        var result = newer.copy()
        // irate is for counters, idelta for gauges — and the two tests are not
        // mirror images: irate warns if EITHER is a gauge, idelta warns if either is
        // NOT a gauge.
        if isRate
            && (newer.counterResetHint == .gaugeType || older.counterResetHint == .gaugeType)
        {
            annos.add(newNativeHistogramNotCounterWarning(getMetricName(samples.metric), pos))
        }
        if !isRate
            && (newer.counterResetHint != .gaugeType || older.counterResetHint != .gaugeType)
        {
            annos.add(newNativeHistogramNotGaugeWarning(getMetricName(samples.metric), pos))
        }
        let stReset = isStartTimestampReset(ss[0].st, ss[0].sample.t, ss[1].st, ss[1].sample.t)
        if !isRate || (!stReset && !newer.detectReset(older)) {
            // The subtraction may deliberately carry conflicting counter resets:
            // resets are handled explicitly here, so `counterResetCollision` is
            // ignored on purpose.
            do {
                let r = try result.sub(older)
                if r.nhcbBoundsReconciled {
                    annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .sub))
                }
            } catch HistogramError.incompatibleSchema {
                annos.add(
                    newMixedExponentialCustomHistogramsWarning(
                        getMetricName(samples.metric), pos))
                return (out, annos)
            } catch {
                // `sub` throws only `incompatibleSchema`; anything else is a bug
                // rather than a behaviour to reproduce.
                preconditionFailure("FloatHistogram.sub threw \(error)")
            }
        }
        result.counterResetHint = .gaugeType
        _ = result.compact(maxEmptyBuckets: 0)
        resultSample.sample.h = result
    } else {
        // A float and a histogram.
        annos.add(newMixedFloatsHistogramsWarning(getMetricName(samples.metric), pos))
        return (out, annos)
    }

    if isRate {
        // Per-second.
        if resultSample.sample.h == nil {
            resultSample.sample.f /= Double(sampledInterval) / 1000
        } else {
            var h = resultSample.sample.h!
            _ = h.div(Double(sampledInterval) / 1000)
            resultSample.sample.h = h
        }
    }

    out.append(resultSample.sample)
    return (out, annos)
}

/// Go: `funcIrate` — the per-second rate from the last two samples.
func funcIrate(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    instantValue(m, args, enh, true)
}

/// Go: `funcIdelta` — the difference between the last two samples.
func funcIdelta(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    instantValue(m, args, enh, false)
}
