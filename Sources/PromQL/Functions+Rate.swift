//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — `extrapolatedRate` and
// `histogramRate`, and with them `rate`, `increase` and `delta`.
//
// The `anchored`/`smoothed` dispatch is here; `extendedRate` itself is in
// `Functions+ExtendedRate.swift`. **`extendedHistogramRate` is still deferred** and
// its branch reaches a `preconditionFailure`, so a histogram query with those
// modifiers fails loudly rather than silently taking the float path.
//
// ## Extrapolation is the whole function, and it is not a slope
//
// `rate` does **not** fit a line. It takes `last - first`, adds back the pre-reset
// value at every counter reset, and then scales that difference by
//
//     (sampledInterval + durationToStart + durationToEnd) / sampledInterval
//
// where the two durations are how far the first and last samples sit inside the
// range. So the extrapolation assumes regular spacing, and "close enough to the
// boundary" means within **1.1×** the average gap between samples — above that it
// only extrapolates by half a gap, on the theory that the series genuinely starts or
// ends inside the range.
//
// The counter clamp is the subtle part. If the value went up, the zero point of the
// counter is extrapolated backwards, and if that lands *later* than `durationToStart`
// it is used instead — which is what stops `rate` extrapolating a counter to a
// negative value. Note the guard is `resultFloat > 0 && samples.Floats[0].F >= 0`:
// a first sample of exactly 0 still qualifies.
//
// ## Two groupings from the fusion map
//
// `functions.go:564` and `:569` are `sampledInterval * (a / b)` — **not**
// `sampledInterval * a / b`. Nothing in this file is fused; those two parenthesised
// divisions are load-bearing anyway. See docs/HANDOFF.md §5.
//
// ## Four behaviours are transcribed but UNWITNESSED
//
// 14 of 18 negative controls break the committed fixtures. These four do not, and are
// recorded here rather than left looking verified:
//
//   * the `sampledInterval * (a / b)` grouping. Both spellings agree on every corpus
//     value; distinguishing them needs a ratio whose two roundings compound.
//   * `rangeEnd`'s `- durationMilliseconds(vs.Offset)` term. With an offset large
//     enough to matter, `durationToEnd` exceeds the extrapolation threshold either way
//     and collapses to the same half-gap.
//   * `minSchema := min(last.Schema, prev.Schema)` taking `prev` into account. Needs a
//     range whose FIRST histogram has a finer schema than its last.
//   * `histogramRate`'s gauge warning for `delta` using `||` rather than `&&`. Needs a
//     range where exactly one of the first and last histograms is a gauge; every
//     gauge case in the corpus has both.
//
// Each is what Go computes; none is guesswork. They are the next four cases to add.
//
// ## `histogramRate` nulls out its first sample
//
// If there is a counter reset between the first and second histogram, the first is
// replaced by an **empty** histogram carrying the second's schema and custom values —
// so its bucket layout is deliberately ignored rather than checked for
// compatibility. That is why the custom-buckets test that follows compares against
// `usingCustomBuckets`, which may have been reassigned from the *second* sample.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromPosRange
public import PromQLParser

internal import GoCompat
internal import PromModel

/// Go: `histogramRate` — `last - first` over a range of histograms, with resets added
/// back.
///
/// Returns nil when the histograms are not compatible with each other, in which case
/// the annotation says which way they disagreed.
func histogramRate(
    _ points: [HPoint], _ startTimestamps: [Int64], _ isCounter: Bool,
    _ metric: Labels, _ pos: PositionRange
) -> (FloatHistogram?, Annotations) {
    var annos = Annotations()
    var prev = points[0].h
    var usingCustomBuckets = prev.usesCustomBuckets
    let last = points[points.count - 1].h

    // The loop below skips the first and last points, so their hints are checked here.
    if isCounter
        && (prev.counterResetHint == .gaugeType || last.counterResetHint == .gaugeType)
    {
        annos.add(newNativeHistogramNotCounterWarning(getMetricName(metric), pos))
    }

    // Null out the first sample when there is a reset between it and the second: its
    // bucket layout is then irrelevant, so any incompatibility in it is ignored.
    if isCounter && points.count > 1 {
        let second = points[1].h
        let stReset =
            startTimestamps.count > 1
            && isStartTimestampReset(
                startTimestamps[0], points[0].t, startTimestamps[1], points[1].t)
        if stReset || second.detectReset(prev) {
            var empty = FloatHistogram()
            empty.schema = second.schema
            empty.customValues = second.customValues
            prev = empty
            usingCustomBuckets = second.usesCustomBuckets
        }
    }

    if last.usesCustomBuckets != usingCustomBuckets {
        annos.add(newMixedExponentialCustomHistogramsWarning(getMetricName(metric), pos))
        return (nil, annos)
    }

    // First pass: the smallest relevant schema, and the gauge-hint warnings.
    var minSchema = Swift.min(last.schema, prev.schema)
    if points.count > 2 {
        for currPoint in points[1..<(points.count - 1)] {
            let curr = currPoint.h
            if !isCounter {
                continue
            }
            if curr.counterResetHint == .gaugeType {
                annos.add(newNativeHistogramNotCounterWarning(getMetricName(metric), pos))
            }
            if curr.schema < minSchema {
                minSchema = curr.schema
            }
            if curr.usesCustomBuckets != usingCustomBuckets {
                var only = Annotations()
                only.add(
                    newMixedExponentialCustomHistogramsWarning(getMetricName(metric), pos))
                return (nil, only)
            }
        }
    }

    var h = last.copyToSchema(minSchema)
    // The subtraction may deliberately carry conflicting counter resets: resets are
    // handled explicitly here, so the collision flag is ignored.
    do {
        let result = try h.sub(prev)
        if result.nhcbBoundsReconciled {
            annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .sub))
        }
    } catch {
        var only = Annotations()
        only.add(newMixedExponentialCustomHistogramsWarning(getMetricName(metric), pos))
        return (nil, only)
    }

    if isCounter {
        // Second pass: add back the pre-reset value at every reset.
        for (i, currPoint) in points.dropFirst().enumerated() {
            let curr = currPoint.h
            let stReset =
                i + 1 < startTimestamps.count
                && isStartTimestampReset(
                    startTimestamps[i], points[i].t, startTimestamps[i + 1], currPoint.t)
            if stReset || curr.detectReset(prev) {
                do {
                    let result = try h.add(prev)
                    if result.nhcbBoundsReconciled {
                        annos.add(newMismatchedCustomBucketsHistogramsInfo(pos, .add))
                    }
                } catch {
                    var only = Annotations()
                    only.add(
                        newMixedExponentialCustomHistogramsWarning(getMetricName(metric), pos))
                    return (nil, only)
                }
            }
            prev = curr
        }
    } else if points[0].h.counterResetHint != .gaugeType
        || points[points.count - 1].h.counterResetHint != .gaugeType
    {
        // `delta` is for gauges, and the test is on the FIRST and LAST hints only.
        annos.add(newNativeHistogramNotGaugeWarning(getMetricName(metric), pos))
    }

    h.counterResetHint = .gaugeType
    return (h.compact(maxEmptyBuckets: 0), annos)
}

/// Go: `extrapolatedRate` — the shared body of `rate`, `increase` and `delta`.
///
/// `isCounter` adds reset handling and the negative-value clamp; `isRate` divides by
/// the range in seconds. So `rate` is both, `increase` is counter-only and `delta` is
/// neither.
func extrapolatedRate(
    _ vals: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper,
    _ isCounter: Bool, _ isRate: Bool
) -> (Vector, Annotations) {
    guard let ms = args[0] as? MatrixSelector,
        let vs = ms.vectorSelector as? VectorSelector
    else {
        preconditionFailure("rate/increase/delta's argument is a matrix selector")
    }
    // Go indexes `vals[0]` in both branches with no emptiness check, so an empty
    // matrix panics — the fourth such latent crash in this file (see PORTING.md
    // exception 9 and quirk 58). Unreachable from a query, guarded clearly.
    precondition(
        !vals.isEmpty,
        "rate/increase/delta: an empty matrix; Go indexes vals[0] and panics")
    if vs.anchored || vs.smoothed {
        let samples = vals[0]
        if !samples.histograms.isEmpty && !samples.floats.isEmpty {
            var annos = Annotations()
            annos.add(
                newMixedFloatsHistogramsWarning(
                    getMetricName(samples.metric), args[0].positionRange))
            return (enh.out, annos)
        }
        if !samples.histograms.isEmpty {
            // `extendedHistogramRate` is still deferred: it needs six more helpers of
            // its own (`validateHistogramRange`, the two histogram interpolators,
            // `correctForCounterResetsHistogram`, the add/sub annotation wrappers and
            // `annosFromInterpolationError`). Loud rather than silently taking a float
            // path. See `Functions+ExtendedRate.swift`.
            preconditionFailure(
                "rate/increase/delta over an anchored or smoothed range of HISTOGRAMS "
                    + "needs extendedHistogramRate, which is not ported yet")
        }
        if !samples.floats.isEmpty {
            return extendedRate(vals, args, enh, isCounter, isRate)
        }
        // Not enough samples.
        return (enh.out, Annotations())
    }

    let samples = vals[0]
    let rangeStart =
        enh.ts
        - durationMilliseconds(
            GoDuration(nanoseconds: ms.range.nanoseconds + vs.offset.nanoseconds))
    let rangeEnd = enh.ts - durationMilliseconds(vs.offset)
    var resultFloat = 0.0
    var resultHistogram: FloatHistogram? = nil
    var firstT: Int64 = 0
    var lastT: Int64 = 0
    var numSamplesMinusOne = 0
    var annos = Annotations()

    // Either two or more histograms and no floats, or two or more floats and no
    // histograms. Anything else is dropped.
    if !samples.histograms.isEmpty && !samples.floats.isEmpty {
        annos.add(
            newMixedFloatsHistogramsWarning(getMetricName(samples.metric), args[0].positionRange))
        return (enh.out, annos)
    }

    if samples.histograms.count > 1 {
        numSamplesMinusOne = samples.histograms.count - 1
        firstT = samples.histograms[0].t
        lastT = samples.histograms[numSamplesMinusOne].t
        let startTimestamps = enh.startTimestamps?.histograms ?? []
        let (h, newAnnos) = histogramRate(
            samples.histograms, startTimestamps, isCounter, samples.metric,
            args[0].positionRange)
        annos.merge(newAnnos)
        guard let h else {
            // The histograms are not compatible with each other.
            return (enh.out, annos)
        }
        resultHistogram = h
    } else if samples.floats.count > 1 {
        numSamplesMinusOne = samples.floats.count - 1
        firstT = samples.floats[0].t
        lastT = samples.floats[numSamplesMinusOne].t
        resultFloat = samples.floats[numSamplesMinusOne].f - samples.floats[0].f
        if isCounter {
            let startTimestamps = enh.startTimestamps?.floats ?? []
            for (i, currPoint) in samples.floats.dropFirst().enumerated() {
                let prevPoint = samples.floats[i]
                let stReset =
                    i + 1 < startTimestamps.count
                    && isStartTimestampReset(
                        startTimestamps[i], prevPoint.t, startTimestamps[i + 1], currPoint.t)
                if currPoint.f < prevPoint.f || stReset {
                    // Add back the value the counter had before the reset.
                    resultFloat += prevPoint.f
                }
            }
        }
    } else {
        // Fewer than two samples of a single kind. TODO upstream: a
        // RangeTooShortWarning.
        return (enh.out, annos)
    }

    // How far the first and last samples sit inside the range.
    var durationToStart = Double(firstT - rangeStart) / 1000
    var durationToEnd = Double(rangeEnd - lastT) / 1000

    let sampledInterval = Double(lastT - firstT) / 1000
    let averageDurationBetweenSamples = sampledInterval / Double(numSamplesMinusOne)

    // "Close enough to the boundary" is within 1.1x the average gap; beyond that,
    // extrapolate only half a gap, assuming the series starts or ends inside the range.
    let extrapolationThreshold = averageDurationBetweenSamples * 1.1
    if durationToStart >= extrapolationThreshold {
        durationToStart = averageDurationBetweenSamples / 2
    }
    if isCounter {
        // Counters cannot be negative: if there is any slope, extrapolate the zero
        // point and use it when it is nearer than the range boundary.
        var durationToZero = durationToStart
        if resultFloat > 0 && !samples.floats.isEmpty && samples.floats[0].f >= 0 {
            // `sampledInterval * (a / b)`, NOT `sampledInterval * a / b` — the
            // parenthesised division is load-bearing (functions.go:564).
            durationToZero = sampledInterval * (samples.floats[0].f / resultFloat)
        } else if let rh = resultHistogram, rh.count > 0, !samples.histograms.isEmpty,
            samples.histograms[0].h.count >= 0
        {
            durationToZero = sampledInterval * (samples.histograms[0].h.count / rh.count)
        }
        if durationToZero < durationToStart {
            durationToStart = durationToZero
        }
    }

    if durationToEnd >= extrapolationThreshold {
        durationToEnd = averageDurationBetweenSamples / 2
    }

    var factor = (sampledInterval + durationToStart + durationToEnd) / sampledInterval
    if isRate {
        factor /= ms.range.seconds
    }
    if var rh = resultHistogram {
        _ = rh.mul(factor)
        resultHistogram = rh
    } else {
        resultFloat *= factor
    }

    var out = enh.out
    var sample = Sample(f: resultFloat)
    sample.h = resultHistogram
    out.append(sample)
    return (out, annos)
}

/// Go: `funcDelta` — neither a counter nor a rate, so no reset handling and no
/// per-second division.
func funcDelta(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    extrapolatedRate(m, args, enh, false, false)
}

/// Go: `funcRate` — a counter *and* a rate.
func funcRate(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    extrapolatedRate(m, args, enh, true, true)
}

/// Go: `funcIncrease` — a counter but not a rate, so the extrapolated difference
/// without the per-second division.
func funcIncrease(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    extrapolatedRate(m, args, enh, true, false)
}

// MARK: - absent

/// Go: `createLabelsForAbsentFunction` (functions.go:2746) — the labels `absent` gives
/// its synthetic sample, derived from the selector's matchers.
///
/// The `has` map exists for backwards compatibility and upstream's own comment says so:
/// only the **first** `=` matcher for a name contributes, and a *second* matcher on the
/// same name — of any type — deletes it again. So
/// `absent(x{job="a",job="b",foo="bar"})` drops `job` entirely, and upstream notes that
/// `absent(x{job="a",job="a",foo="bar"})` therefore does too, which is "arguably wrong"
/// but is the behaviour.
///
/// `__name__` matchers are skipped outright, and anything that is not a selector yields
/// no labels at all.
func createLabelsForAbsentFunction(_ expr: any Expr) -> Labels {
    var b = LabelsBuilder(.empty)

    // `labelMatchers` is `[Matcher?]` because the parser records a nil for a matcher
    // it could not build after reporting the error; Go's slice cannot hold one, so the
    // nils are dropped here rather than reproduced.
    var matchers: [Matcher?]
    if let vs = expr as? VectorSelector {
        matchers = vs.labelMatchers
    } else if let ms = expr as? MatrixSelector, let vs = ms.vectorSelector as? VectorSelector {
        matchers = vs.labelMatchers
    } else {
        return .empty
    }

    var has: [String: Bool] = [:]
    for case let ma? in matchers {
        if ma.name == LabelName.metricName {
            continue
        }
        if ma.type == .equal && has[ma.name] != true {
            b.set(ma.name, ma.value)
            has[ma.name] = true
        } else {
            // A repeat, or a non-`=` matcher: the label is removed rather than left.
            b.del([ma.name])
        }
    }
    return b.labels()
}

/// Go: `funcAbsent` — 1 with the selector's equality labels when the vector is empty,
/// and nothing when it is not.
///
/// Note it indexes `vectorVals[0]` before any guard, so it must be called with an
/// argument; `rangeEval` always does.
func funcAbsent(_ v: [Vector], _: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if !v[0].isEmpty {
        return (enh.out, Annotations())
    }
    var out = enh.out
    out.append(Sample(f: 1, metric: createLabelsForAbsentFunction(args[0])))
    return (out, Annotations())
}
