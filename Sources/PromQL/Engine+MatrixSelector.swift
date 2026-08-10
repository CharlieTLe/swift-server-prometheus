//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `matrixSelector` (:2806), `matrixIterSlice`
// (:2889), `extendFloats` (:4843), and the `MatrixSelector` arm of `eval` (:2547).
//
// This is the range selector: `foo[5m]` as a value in its own right. Landing it makes every
// range-vector *input* available; the `matrixArg` half of the `Call` arm, which feeds that
// input to the 82 ported `FunctionCalls` bodies, is the next slice.
//
// ## The buffer's range is NOT the selector's range
//
// Four numbers, and mixing them up loses samples silently:
//
//	maxt/mint          the window the CALLER sees, `[startTimestamp - offset - range, …]`
//	matrixMint/Maxt    copies of the originals, kept for `extendFloats`
//	bufferRange        how much look-back `storage.NewBuffer` retains
//	mint/maxt (moved)  what `matrixIterSlice` is actually asked for
//
// A plain selector leaves them equal. `anchored` adds **one** `lookbackDelta` to
// `bufferRange` and moves `mint` back by it; `smoothed` adds **two** and moves `mint` back
// *and* `maxt` forward. So the widened window feeds the iterator while `matrixMint`/
// `matrixMaxt` — the originals — decide what `extendFloats` trims back to. This is the
// storage-side counterpart of quirk 68's `getTimeRangesForSelector`, and the two must agree.
//
// ## `matrixIterSlice` reuses the caller's slices, and the accounting is asymmetric
//
// The point of the `floats`/`histograms` parameters is that a *later* step can keep the
// points a previous step already read. When the previous window overlaps, it drops the points
// at or before `mint` and appends only points after the last retained timestamp. When it does
// not overlap it truncates to empty.
//
// The two branches decrement `currentSamples` differently, and **the histogram overlap branch
// subtracts the size of the points it KEPT rather than the ones it dropped**:
//
//	floats,     overlap:  `ev.currentSamples -= drop`                      (the dropped count)
//	floats,     no overlap: `ev.currentSamples -= len(floats)`             (all of them)
//	histograms, overlap:  `ev.currentSamples -= totalHPointSize(histograms)` after truncation
//	                                                                       (the RETAINED size)
//	histograms, no overlap: `ev.currentSamples -= totalHPointSize(histograms)` before
//	                                                                       (all of them)
//
// The third line reads as an upstream slip — the float branch two dozen lines above uses the
// dropped count — and it is reproduced rather than corrected. It makes a histogram range
// query's sample accounting drift downward across steps, which is a limit that is *more*
// permissive than it looks. PORTING.md quirk 82.
//
// ## Go's nil-versus-empty slice is load-bearing here, exactly once
//
// `matrixSelector`'s anchored/smoothed guard is `if ss.Histograms != nil`, not a length test.
// `matrixIterSlice` allocates the histogram slice **before** it knows whether the sample is a
// stale marker, and drops it back to length 0 when it is — so a series whose only in-range
// histogram is stale comes back **non-nil and empty**, and `foo[5m] anchored` over it fails
// with "anchored modifier is not supported with histograms" despite having no histograms.
//
// That is why the two slices are modelled as `[FPoint]?`/`[HPoint]?` here rather than as
// empty arrays: the port drops `sync.Pool` (PORTING.md exception 4), and dropping the nil
// distinction with it would have silently corrected this. Quirk 83.
//
// ## What value semantics DO let us drop
//
// Go grows the histogram slice by hand (`if n < cap(h) { h = h[:n+1] } else { append(…, HPoint{H:
// &FloatHistogram{}}) }`) so that `AtFloatHistogram(h[n].H)` gets a non-nil destination and
// therefore deep-copies — upstream says as much in a comment at engine.go:3047. `FloatHistogram`
// is a Swift **struct**, so every assignment is already a copy and the destination dance has
// nothing to protect. Plain `append` is used, and the comment is here so the next reader does
// not go looking for the missing capacity juggling.
//
// The histogram overlap branch's three-way `copy` — "rotate the buffer around the drop index
// so that points before mint can be reused" — is the same thing: it moves the dropped points
// past the new length so the pool can reuse their `*FloatHistogram`s. Observably it is
// `removeFirst(drop)`.
//
// ## Two asymmetries in the stale-marker handling
//
//   * a stale **float** is skipped *before* the `t > mintFloats` test, so it never counts;
//   * a stale **histogram** is appended first and removed after, which is what leaves the
//     slice non-nil (above) and what means the sample-limit check never sees it.
//
// And in the sought-sample tail the float arm tests `t == maxt && !IsStaleNaN(f)` in one
// condition while the histogram arm tests `it.AtT() != maxt` first and staleness second.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromChunkEnc
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromQLParser
internal import PromStorage

extension Evaluator {
    /// Go: `matrixSelector` — one `Series` per input series, holding every point in the
    /// selector's window.
    ///
    /// Note it does **not** count against `maxSamples` itself; `matrixIterSlice` does, per
    /// point. A series that yields nothing is dropped rather than kept empty, and the test is
    /// on the *total size* — so a series with only stale markers disappears.
    func matrixSelector(_ ctx: GoContext, _ node: MatrixSelector) throws -> (Matrix, Annotations)
    {
        guard let vs = node.vectorSelector as? VectorSelector else {
            // Go type-asserts. `checkAST` guarantees the shape at parse time.
            throw EvaluatorNotPorted(
                nodeType: "MatrixSelector", detail: "inner expression is not a VectorSelector")
        }

        let offset = durationMilliseconds(vs.offset)
        var maxt = startTimestamp - offset
        var mint = maxt - durationMilliseconds(node.range)
        // The originals, which `extendFloats` trims back to.
        let matrixMint = mint
        let matrixMaxt = maxt
        var bufferRange = durationMilliseconds(node.range)
        let lookback = durationMilliseconds(lookbackDelta)

        if vs.anchored {
            bufferRange += lookback
            mint -= lookback
        } else if vs.smoothed {
            bufferRange += 2 * lookback
            mint -= lookback
            maxt += lookback
        }

        let it = newBuffer(delta: bufferRange)
        // Go builds `errWithWarnings{…, ws}` from the annotations
        // `checkAndExpandSeriesSet` returned *alongside* the error; a Swift throw carries only
        // the error, so there are none to carry — the same shape the `VectorSelector` arm uses.
        let ws: Annotations
        do {
            ws = try checkAndExpandSeriesSet(ctx, node)
        } catch {
            throw ErrWithWarnings(StorageExpansionError(underlying: error), Annotations())
        }

        var matrix = Matrix()
        matrix.series.reserveCapacity(vs.series.count)
        // Go threads one `chunkenc.Iterator` through every series so `s.Iterator(chkIter)` can
        // recycle it. `StorageSeriesIterator` honours that, so the call site is preserved
        // (PORTING.md §4 — copy-vs-alias semantics are not always allocation detail).
        var chkIter: (any ChunkIterator)? = nil

        for s in vs.series {
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            chkIter = s.iterator(chkIter)
            it.reset(chkIter!)

            // Fresh per series: `matrixSelector` passes nil in, unlike the `Call` arm which
            // reuses one pair across steps.
            var floats: [FPoint]? = nil
            var histograms: [HPoint]? = nil
            var startTimestamps: StartTimestamps? = nil
            try matrixIterSlice(it, mint, maxt, &floats, &histograms, &startTimestamps)

            var ss = Series(metric: s.labels())
            ss.floats = floats ?? []
            ss.histograms = histograms ?? []

            if vs.anchored {
                // `!= nil`, not `!isEmpty` — see the file header.
                if histograms != nil {
                    throw EvaluationError.anchoredWithHistograms
                }
                ss.floats = try extendFloats(ss.floats, matrixMint, matrixMaxt, false)
            } else if vs.smoothed {
                if histograms != nil {
                    throw EvaluationError.smoothedWithHistograms
                }
                ss.floats = try extendFloats(ss.floats, matrixMint, matrixMaxt, true)
            }

            let totalSize = ss.floats.count + totalHPointSize(ss.histograms)
            if totalSize > 0 {
                matrix.series.append(ss)
            }
        }
        return (matrix, ws)
    }

    /// Go: `matrixIterSlice` — fill `floats`/`histograms` with every point in `(mint, maxt]`,
    /// keeping whatever a previous call already put there.
    ///
    /// The range is **half-open at the bottom and closed at the top**: the loop appends only
    /// `t > mint`, and the sought sample is taken only when `t == maxt`. So a point exactly on
    /// `mint` is excluded and one exactly on `maxt` is included.
    ///
    /// `inout` rather than return values, which is Go's `floats = append(floats, …)` +
    /// `return floats` round trip with the copy removed: the caller owns the arrays across
    /// steps, which is the whole point of the parameter.
    func matrixIterSlice(
        _ it: BufferedSeriesIterator, _ mint: Int64, _ maxt: Int64,
        _ floats: inout [FPoint]?, _ histograms: inout [HPoint]?,
        _ startTimestamps: inout StartTimestamps?
    ) throws {
        var mintFloats = mint
        var mintHistograms = mint

        // First floats...
        if let existing = floats, !existing.isEmpty, existing[existing.count - 1].t > mint {
            // The previous window overlaps this one. Upstream's comment explains the linear
            // scan: the overlap is usually much larger than the step, or the point count is
            // small, so a binary search would not pay.
            var drop = 0
            while existing[drop].t <= mint {
                drop += 1
            }
            currentSamples -= drop
            floats!.removeFirst(drop)
            // Only points after the last one we kept are appended below.
            mintFloats = floats![floats!.count - 1].t

            if startTimestamps != nil {
                // Truncated at the same drop point, so the two stay aligned index for index.
                startTimestamps!.floats.removeFirst(drop)
            }
        } else {
            currentSamples -= floats?.count ?? 0
            if floats != nil {
                floats = []
            }
            if startTimestamps != nil {
                startTimestamps!.floats.removeAll(keepingCapacity: true)
            }
        }

        // ...then the same for histograms. Upstream's own `TODO(beorn7): Use generics?`.
        if let existing = histograms, !existing.isEmpty, existing[existing.count - 1].t > mint {
            var drop = 0
            while existing[drop].t <= mint {
                drop += 1
            }
            histograms!.removeFirst(drop)
            // The RETAINED size, not the dropped one — asymmetric with the float branch above
            // and reproduced deliberately. See the file header and quirk 82.
            currentSamples -= totalHPointSize(histograms!)
            mintHistograms = histograms![histograms!.count - 1].t

            if startTimestamps != nil {
                startTimestamps!.histograms.removeFirst(drop)
            }
        } else {
            currentSamples -= totalHPointSize(histograms ?? [])
            if histograms != nil {
                histograms = []
            }
            if startTimestamps != nil {
                startTimestamps!.histograms.removeAll(keepingCapacity: true)
            }
        }

        if mint == maxt {
            // Empty range: whatever the retention left is the answer.
            return
        }

        let soughtValueType = it.seek(maxt)
        if soughtValueType == .none {
            if let err = it.err() {
                throw err
            }
        }

        let buf = it.buffer()
        loop: while true {
            switch buf.next() {
            case .none:
                break loop
            case .floatHistogram, .histogram:
                let t = buf.atT()
                // Everything in the buffer is strictly older than maxt, which is why there is
                // no upper test here.
                if t > mintHistograms {
                    // Allocated BEFORE the staleness test, which is what can leave this
                    // non-nil and empty. Load-bearing; see the file header.
                    if histograms == nil {
                        histograms = []
                    }
                    let (ht, h) = buf.atFloatHistogram(nil)
                    guard let h else {
                        preconditionFailure("atFloatHistogram returned nil for a histogram sample")
                    }
                    if PromValue.isStaleNaN(h.sum) {
                        continue loop
                    }
                    let point = HPoint(t: ht, h: h)
                    histograms!.append(point)
                    currentSamples += point.size
                    if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    if startTimestamps != nil {
                        startTimestamps!.histograms.append(buf.atST())
                    }
                }
            case .float:
                let (t, f) = buf.at()
                // Note the order: staleness is tested BEFORE the timestamp, unlike the
                // histogram arm.
                if PromValue.isStaleNaN(f) {
                    continue loop
                }
                if t > mintFloats {
                    currentSamples += 1
                    if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    if floats == nil {
                        floats = []
                    }
                    floats!.append(FPoint(t: t, f: f))
                    if startTimestamps != nil {
                        startTimestamps!.floats.append(buf.atST())
                    }
                }
            default:
                break loop
            }
        }

        // The sought sample sits at or past maxt and is therefore not in the buffer; it counts
        // only when it lands exactly on maxt.
        switch soughtValueType {
        case .floatHistogram, .histogram:
            if it.atT() != maxt {
                break
            }
            if histograms == nil {
                histograms = []
            }
            let (ht, h) = it.atFloatHistogram(nil)
            guard let h else {
                preconditionFailure("atFloatHistogram returned nil for a histogram sample")
            }
            if PromValue.isStaleNaN(h.sum) {
                break
            }
            let point = HPoint(t: ht, h: h)
            histograms!.append(point)
            currentSamples += point.size
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }
            if startTimestamps != nil {
                startTimestamps!.histograms.append(it.atST())
            }
        case .float:
            let (t, f) = it.at()
            if t == maxt && !PromValue.isStaleNaN(f) {
                currentSamples += 1
                if currentSamples > maxSamples {
                    throw QueryError.tooManySamples(evaluationEnv)
                }
                if floats == nil {
                    floats = []
                }
                floats!.append(FPoint(t: t, f: f))
                if startTimestamps != nil {
                    startTimestamps!.floats.append(it.atST())
                }
            }
        default:
            break
        }
    }
}

/// Go: `extendFloats` — trim an `anchored`/`smoothed` matrix back to `[mint, maxt]`, adding a
/// synthetic point at each end.
///
/// The output always has a point exactly at `mint` and one exactly at `maxt`, which is the
/// whole purpose: `anchored` takes the nearest sample at or before the boundary, `smoothed`
/// interpolates. That is what makes `rate(foo[5m] anchored)` independent of where the samples
/// happen to fall.
///
/// Three details that are easy to lose:
///
///   * `sort.Search` is over `lastSampleIndex`, i.e. `len(floats) - 1`, **not** the whole
///     slice — the last point is never a candidate for `firstSampleIndex`;
///   * the `-1` and the `max(0, …)` mean `firstSampleIndex` is the point *at or before* `mint`
///     when there is one, and 0 otherwise;
///   * both boundary points are then *excluded* from the copied middle (`floats[first].T <=
///     mint` bumps `first`, `floats[last].T >= maxt` drops `last`) so the synthetic ones do not
///     duplicate a real sample.
///
/// The `isCounter` argument to both interpolators is hard-coded **false**; upstream's
/// `TODO: detect if the sample is a counter, based on __type__ or metadata` is why.
///
/// ## It panics on an empty slice, reachably, and the port reproduces the message
///
/// `floats[lastSampleIndex]` is unguarded, and `matrixSelector` calls this for **every** series
/// — including one the querier admitted and then trimmed to nothing (quirk 34: visibility is at
/// chunk granularity, trimming is per sample). A chunk that spans the anchored window with no
/// sample inside it is enough:
///
///     mg 1 @0 2 @1000000        mg[2m] anchored @ 500        -> index out of range [-1]
///                               mg[2m] smoothed @ 500        -> index out of range [0] with length 0
///                               mg[2m] @ 500                 -> (empty, no error)
///
/// The two modifiers differ because `smoothed` reassigns `lastSampleIndex` from
/// `sort.Search(-1, …)`, which is **0**, while `anchored` leaves it at `len - 1` = **-1** — and
/// Go's runtime prints a negative index without the length suffix. Both were confirmed against
/// Go rather than reasoned about. Quirk 84.
///
/// So this throws rather than trapping: a Swift trap is not catchable, and a reachable upstream
/// panic is part of the contract. `QueryError.unexpected` is what `recover`'s `runtime.Error`
/// arm produces, so the wrapping is applied here directly rather than through
/// `classifyEvaluationError`.
///
/// ## One control cannot fail, and it is a proof rather than a gap
///
/// Searching `lastSampleIndex` versus the whole slice is **provably** the same answer. The two
/// differ only when no element in `[0, count-1)` has `t > mint`, and then:
///
///   * if the last element does, both searches return `count - 1`;
///   * if none does — every sample is at or before `mint` — the searches differ, but the
///     `floats[lastSampleIndex].t <= mint` test that follows is then true for *any* index, so
///     both spellings return `[]`.
///
/// 24 of the slice's 25 negative controls break; this is the one that cannot, and the argument
/// above is why. `Scripts/controls-matrixselector.sh` re-runs them.
func extendFloats(_ floats: [FPoint], _ mint: Int64, _ maxt: Int64, _ smoothed: Bool) throws
    -> [FPoint]
{
    var lastSampleIndex = floats.count - 1

    var firstSampleIndex = Swift.max(
        0, goSortSearch(lastSampleIndex) { floats[$0].t > mint } - 1)
    if smoothed {
        lastSampleIndex = goSortSearch(lastSampleIndex) { floats[$0].t >= maxt }
    }

    // Go's first unguarded index read, and the one that panics. See above.
    guard lastSampleIndex >= 0 && lastSampleIndex < floats.count else {
        throw QueryError.unexpected(
            GoRuntimeError.indexOutOfRange(lastSampleIndex, length: floats.count))
    }

    if floats[lastSampleIndex].t <= mint {
        return []
    }

    let left = pickOrInterpolateLeft(floats, firstSampleIndex, mint, smoothed, false)
    let right = pickOrInterpolateRight(floats, lastSampleIndex, maxt, smoothed, false)

    // Drop the real samples that sit on the boundaries; the synthetic ones replace them.
    if floats[firstSampleIndex].t <= mint {
        firstSampleIndex += 1
    }
    if floats[lastSampleIndex].t >= maxt {
        lastSampleIndex -= 1
    }

    let count = Swift.max(lastSampleIndex - firstSampleIndex + 1, 0)
    var out = [FPoint]()
    out.reserveCapacity(count + 2)
    out.append(FPoint(t: mint, f: left))
    if count > 0 {
        out.append(contentsOf: floats[firstSampleIndex...lastSampleIndex])
    }
    out.append(FPoint(t: maxt, f: right))
    return out
}

/// Go: `sort.Search(n, f)` — the smallest `i` in `[0, n)` for which `f(i)` is true, or `n`.
///
/// Its own binary search rather than a `Collection` method, because `f` is not required to be
/// a predicate over a sorted slice in general and Go's exact convergence is the contract.
func goSortSearch(_ n: Int, _ f: (Int) -> Bool) -> Int {
    var i = 0
    var j = n
    while i < j {
        let h = Int(UInt(i + j) >> 1)
        if !f(h) {
            i = h + 1
        } else {
            j = h
        }
    }
    return i
}
