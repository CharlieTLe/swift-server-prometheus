//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — `resets` and `changes`, plus
// `pickFirstSampleIndices`. `StartTimestamps` was already in `Value.swift`; this is
// its first reader.
//
// These two are the last `functions.go` entries that walk a range **sample by
// sample across both kinds**, and the merge loop they share is worth reading
// carefully: it is not a zip and not a sort.
//
// ## The merge loop's two cases are not exhaustive, and that is load-bearing
//
// Each iteration picks the next sample with:
//
//   case iHistogram >= len(histograms) || iFloat < len(floats) && floats[iFloat].T < histograms[iHistogram].T
//   case iFloat >= len(floats)         || iHistogram < len(histograms) && floats[iFloat].T > histograms[iHistogram].T
//
// A float and a histogram at the **equal** timestamp match *neither* case, so no
// index advances and `curSample` keeps its previous contents — and the loop
// condition is still true. In Go that is an infinite loop. The port reproduces the
// selection faithfully and adds a `precondition` on the case nothing matched, so a
// corpus that reaches it fails loudly instead of hanging. That is the same choice
// PORTING.md exception 9 records for `sampleRing`: reproduce the reachable
// behaviour, guard the crash.
//
// ## `iFloat + iHistogram == 1 + firstFloat + firstHistogram` is the first-sample test
//
// Not `i == 0`. Because both indices start wherever `pickFirstSampleIndices` put
// them and exactly one advances per iteration, their **sum** is a step counter — so
// the test means "this was the first step". Rewriting it as a boolean flag is
// equivalent; rewriting it as `iFloat + iHistogram == 1` is not.
//
// ## `resets` and `changes` differ in more than their comparison
//
// | | `resets` | `changes` |
// |---|---|---|
// | float pair | `cur < prev`, or a start-timestamp reset | `cur != prev`, unless **both** are NaN |
// | kind changes | counts | counts |
// | histogram pair | `DetectReset`, or a start-timestamp reset | `!Equals` |
// | start timestamps | read | **ignored entirely** |
//
// So two NaNs in a row are *not* a change (Go spells that
// `!(IsNaN(cur) && IsNaN(prev))`) but NaN following a number is; and `changes` never
// consults `enh.StartTimestamps` at all.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromQLParser

internal import GoCompat

/// Go: `pickFirstSampleIndices` — where `resets`/`changes` should start reading.
///
/// Without the `anchored` range modifier this is `(0, 0, true)` and nothing else
/// happens. With it, the range carries samples from *before* its start so that a
/// counter's value at the boundary is known, and this picks the **anchor**: the last
/// sample at or before the range start, of whichever kind is later.
///
/// Two subtleties:
///
///   * `found == false` when there is no sample strictly after the range start —
///     there is nothing to measure, so the function returns nothing rather than 0.
///   * the anchor's own kind is included from its index, while the *other* kind skips
///     everything up to and including its last pre-start sample. So exactly one
///     pre-start sample survives, and it is the anchor.
///
/// Reads `args[0]` as a `MatrixSelector` wrapping a `VectorSelector`, so the argument
/// must be a real range selector — a placeholder AST cannot drive this.
///
/// **The `vs.offset` term of `rangeStart` is unwitnessed.** Dropping it does not move
/// any case in `Fixtures/promql/functions-overtime.jsonl`, including the
/// `[5m] anchored offset 1m` ones. Kept because it is what Go computes; recorded here
/// rather than presented as verified.
func pickFirstSampleIndices(
    _ floats: [FPoint], _ histograms: [HPoint], _ args: [any Expr], _ enh: EvalNodeHelper
) -> (firstFloat: Int, firstHistogram: Int, found: Bool) {
    guard let ms = args[0] as? MatrixSelector,
        let vs = ms.vectorSelector as? VectorSelector
    else {
        preconditionFailure("resets/changes' argument is a matrix selector over a vector selector")
    }
    if !vs.anchored {
        return (0, 0, true)
    }
    let rangeStart = enh.ts
        - durationMilliseconds(
            GoDuration(nanoseconds: ms.range.nanoseconds + vs.offset.nanoseconds))

    // Index of the last float / histogram at or before the range start, or -1.
    let lastFloatLE = lowerBound(floats.count) { floats[$0].t > rangeStart } - 1
    let lastHistLE = lowerBound(histograms.count) { histograms[$0].t > rangeStart } - 1

    // Without a sample strictly after the range start there is nothing to measure.
    if lastFloatLE + 1 >= floats.count && lastHistLE + 1 >= histograms.count {
        return (0, 0, false)
    }

    if lastFloatLE < 0 && lastHistLE < 0 {
        // No anchor; every sample is after the range start.
        return (0, 0, true)
    }
    if lastHistLE < 0 || (lastFloatLE >= 0 && floats[lastFloatLE].t >= histograms[lastHistLE].t) {
        // The anchor is a float; pre-start histograms precede it and are skipped.
        return (lastFloatLE, lastHistLE + 1, true)
    }
    // The anchor is a histogram; pre-start floats are skipped.
    return (lastFloatLE + 1, lastHistLE, true)
}

/// Go: `durationMilliseconds` (engine.go:782) — `int64(d / (time.Millisecond / time.Nanosecond))`,
/// i.e. a truncating integer division of the nanosecond count by 1,000,000. Truncation
/// toward zero, not flooring, so a negative offset rounds toward zero.
func durationMilliseconds(_ d: GoDuration) -> Int64 {
    d.nanoseconds / 1_000_000
}

/// Go: `sort.Search` — the first index in `0..<n` for which `pred` is true, or `n`.
private func lowerBound(_ n: Int, _ pred: (Int) -> Bool) -> Int {
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

/// The sample the merge loop is currently looking at: a value or a histogram, plus
/// the start timestamp `resets` compares.
private struct MergedSample {
    var t: Int64 = 0
    var f: Double = 0
    var h: FloatHistogram? = nil
    var st: Int64 = 0
}

/// Go: `funcResets` — how many counter resets the range contains.
///
/// A change of *kind* counts as a reset, in either direction. For two histograms it
/// is `DetectReset`; for two floats it is `cur < prev`. Either pair can also be a
/// reset by start timestamp.
func funcResets(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let floats = m[0].floats
    let histograms = m[0].histograms
    var resets = 0
    if floats.isEmpty && histograms.isEmpty {
        return (enh.out, Annotations())
    }

    let floatSTs = enh.startTimestamps?.floats ?? []
    let histogramSTs = enh.startTimestamps?.histograms ?? []

    let (firstFloat, firstHistogram, found) = pickFirstSampleIndices(
        floats, histograms, args, enh)
    if !found {
        return (enh.out, Annotations())
    }

    var prev = MergedSample()
    var cur = MergedSample()
    var iFloat = firstFloat
    var iHistogram = firstHistogram
    while iFloat < floats.count || iHistogram < histograms.count {
        if iHistogram >= histograms.count
            || (iFloat < floats.count && floats[iFloat].t < histograms[iHistogram].t)
        {
            cur.t = floats[iFloat].t
            cur.f = floats[iFloat].f
            cur.h = nil
            cur.st = iFloat < floatSTs.count ? floatSTs[iFloat] : 0
            iFloat += 1
        } else if iFloat >= floats.count
            || (iHistogram < histograms.count && floats[iFloat].t > histograms[iHistogram].t)
        {
            cur.t = histograms[iHistogram].t
            cur.h = histograms[iHistogram].h
            cur.st = iHistogram < histogramSTs.count ? histogramSTs[iHistogram] : 0
            iHistogram += 1
        } else {
            // Equal timestamps across the two kinds match neither of Go's cases, so
            // no index advances and Go loops forever. See the file header.
            preconditionFailure(
                "resets: a float and a histogram share timestamp \(floats[iFloat].t); "
                    + "Go's merge loop does not terminate here")
        }

        // The first step: seed `prev` and compare nothing. The sum of the indices is
        // a step counter because exactly one advances per iteration.
        if iFloat + iHistogram == 1 + firstFloat + firstHistogram {
            prev = cur
            continue
        }

        if prev.h == nil && cur.h == nil {
            if cur.f < prev.f || isStartTimestampReset(prev.st, prev.t, cur.st, cur.t) {
                resets += 1
            }
        } else if (prev.h != nil) != (cur.h != nil) {
            // A change of kind, in either direction.
            resets += 1
        } else if let curH = cur.h, let prevH = prev.h {
            if isStartTimestampReset(prev.st, prev.t, cur.st, cur.t) || curH.detectReset(prevH) {
                resets += 1
            }
        }
        prev = cur
    }

    enh.out.append(Sample(f: Double(resets)))
    return (enh.out, Annotations())
}

/// Go: `funcChanges` — how many times the value changed.
///
/// **Two NaNs in a row are not a change**, which Go spells
/// `cur != prev && !(IsNaN(cur) && IsNaN(prev))` — the second clause exists precisely
/// because `NaN != NaN` is true. A NaN following a number *is* a change, and so is a
/// number following a NaN.
///
/// Unlike ``funcResets(_:_:_:_:)`` this never reads `enh.startTimestamps`.
func funcChanges(_: [Vector], _ m: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    if m.isEmpty {
        return (enh.out, Annotations())
    }
    let floats = m[0].floats
    let histograms = m[0].histograms
    var changes = 0
    if floats.isEmpty && histograms.isEmpty {
        return (enh.out, Annotations())
    }

    let (firstFloat, firstHistogram, found) = pickFirstSampleIndices(
        floats, histograms, args, enh)
    if !found {
        return (enh.out, Annotations())
    }

    var prev = MergedSample()
    var cur = MergedSample()
    var iFloat = firstFloat
    var iHistogram = firstHistogram
    while iFloat < floats.count || iHistogram < histograms.count {
        if iHistogram >= histograms.count
            || (iFloat < floats.count && floats[iFloat].t < histograms[iHistogram].t)
        {
            cur.f = floats[iFloat].f
            cur.h = nil
            iFloat += 1
        } else if iFloat >= floats.count
            || (iHistogram < histograms.count && floats[iFloat].t > histograms[iHistogram].t)
        {
            cur.h = histograms[iHistogram].h
            iHistogram += 1
        } else {
            preconditionFailure(
                "changes: a float and a histogram share timestamp \(floats[iFloat].t); "
                    + "Go's merge loop does not terminate here")
        }

        if iFloat + iHistogram == 1 + firstFloat + firstHistogram {
            prev = cur
            continue
        }

        if prev.h == nil && cur.h == nil {
            if cur.f != prev.f && !(cur.f.isNaN && prev.f.isNaN) {
                changes += 1
            }
        } else if (prev.h != nil) != (cur.h != nil) {
            changes += 1
        } else if let curH = cur.h, let prevH = prev.h {
            if !curH.equals(prevH) {
                changes += 1
            }
        }
        prev = cur
    }

    enh.out.append(Sample(f: Double(changes)))
    return (enh.out, Annotations())
}
