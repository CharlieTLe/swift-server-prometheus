//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `aggregationK` (:3956) and
// `aggregationCountValues` (:4176), plus `functions.go`'s two heap comparators (:2684, :2717).
//
// The four operators that return **k of the input** rather than one row per group, and the one
// that returns as many rows as there are distinct values. Between them they complete the
// aggregation family.
//
// ## The heap's internal order is observable, so the heap has to be Go's
//
// `limitk` and `limit_ratio` emit `aggr.heap` **in heap order** — no sort at all — so the sift
// directions decide the answer. `topk`/`bottomk` do sort, but through `sort.Sort` over a
// comparator that is not a strict weak ordering (`Less` returns true for a NaN on the left, even
// against another NaN), so the heap order is the sort's *input* and therefore still decides the
// output for tied or NaN values. `GoHeap` and `GoSort` are both ported for this reason.
//
// The two comparators differ only in the direction of the `<`, and both special-case a NaN on the
// left to "true". So a NaN sorts first under *both*, which is why `topk` and `bottomk` treat NaN
// asymmetrically from every other value: `math.IsNaN(heap[0].F) && !math.IsNaN(s.F)` is an extra
// clause in the replacement test, and without it a NaN at the root would never be displaced.
//
// ## `k` is clamped to the input size, and the early return DISCARDS the current step
//
// `k = min(int64(fParam), int64(len(inputMatrix)))`, and if `k < 1` the whole step returns nil —
// but only after `advanceRemainingSeries` has consumed this timestamp from every *remaining*
// series. That call is guarded by `enh.Ts != ev.endTimestamp`, so on the last step it is skipped.
//
// This matters because `nextValues` consumes: a series whose point is not consumed at step N is
// still at the head of its slice at step N+1, where it would be read as N+1's value. So the
// "discard" is not an optimisation — omitting it corrupts every later step. Same for `limitk`'s
// early `break seriesLoop` once every group has its k elements.
//
// ## `limit_ratio` decides membership by HASH, not by position
//
// `AddRatioSample(r, &s)` is `HashRatioSampler`, whose offset comes from `Labels.Hash` (ADR-1) —
// so which series survive is deterministic across steps and independent of order, which is the
// whole point of the operator. A negative ratio takes the *complement*. `r` is clamped to
// [-1, 1] here, and `rangeEvalAgg` has already warned for anything outside it.
//
// ## The instant and range paths build the result differently, on purpose
//
// For an instant query `add` appends straight to a local matrix, "so the result is in consistent
// order" — the heap-then-sort order, which is what `topk` exists to produce. For a range query it
// accumulates into `seriess` keyed by label hash, and `rangeEvalAgg` assembles that at the end.
// Upstream's `seriess` is a Go map, so its order is random; the port keeps insertion order
// (PORTING.md exception 14's situation again) and the top-level sort hides it.
//
// ## `count_values` recomputes the grouping key per step, and says why
//
// It has to: the key includes the *value* label, which changes per sample. Upstream's comment —
// "considering the count_values() operator is less frequently used than other aggregations, we're
// fine having to re-compute the grouping key on each step" — is the justification, and it is why
// this one operator does not go through `rangeEvalAgg`'s pre-pass at all. It runs through plain
// `rangeEval` instead.
//
// The value label is `strconv.FormatFloat(f, 'f', -1, 64)` for a float and
// `FloatHistogram.String()` for a histogram. Both are byte-exact surfaces the port already has
// (`GoFloat.formatF`, ADR-4).
//
// `sortedGrouping` gets the value label **appended and re-sorted** for `by (...)`, and is left
// alone for `without (...)` — so `count_values by (job) ("v", m)` groups by job *and* v, while
// `count_values without (job) ("v", m)` groups by everything except job, which includes v.
//
// ## 31 negative controls, 23 break, and all seven survivors are proofs
//
// `Scripts/controls-aggregationk.sh` re-runs them. Four rest on `Fix` only ever being called at
// **index 0**:
//
//   * `Fix`'s `down`-then-`up` fallback, and `down`'s return value that decides it, are both inert
//     there — `up(0)` computes its parent as `(0 - 1) / 2 == 0` and breaks on `i == j`;
//   * the `if k > 1` guard around `Fix` is inert for the same reason: on a one-element heap `down`
//     breaks immediately and `up(0)` does nothing.
//
// Two rest on the clamp being slack rather than load-bearing:
//
//   * `k = min(fParam, len(inputMatrix))` — the heap can hold at most `len(inputMatrix)` samples,
//     so `len(heap) < k` behaves identically for **any** k at or above the input size;
//   * `r` clamped to [-1, 1] — the hash offset is in [0, 1), so every sample passes for any
//     `|r| >= 1` either way.
//
// And two rest on the series order being fixed, which is the sharpest of the seven:
//
//   * **`limitk`'s `advanceRemainingSeries` is unobservable, and its early `break` with it.**
//     `limitk` fills its heap from the *first* series in the matrix order, so the same series wins
//     at every step; the ones it skips are never emitted, and at the next step `nextValues`
//     rejects their stale points anyway (`floats[0].T != ts`, so `ok` is false and the series is
//     skipped). Contrast `k < 1`'s early return, whose advance control **does** break — there the
//     whole step is discarded, so the next step really would read the stale points. The two look
//     like the same defensive call and only one of them is.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromQLParser

/// Go: `vectorByValueHeap.Less` (functions.go:2690) and `vectorByReverseValueHeap.Less` (:2723).
///
/// **Neither is a strict weak ordering**: a NaN on the left is "less" than everything, itself
/// included. That is why the heap and the sort above it are both Go's own algorithms — with such a
/// comparator the output is decided by the algorithm, not by the order relation.
func vectorHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    if a.f.isNaN {
        return true
    }
    return a.f < b.f
}

/// Go: `vectorByReverseValueHeap.Less` — the same NaN clause, the opposite `<`.
func vectorReverseHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    if a.f.isNaN {
        return true
    }
    return a.f > b.f
}

extension Evaluator {
    /// Go: `aggregationK` — one step of `topk`, `bottomk`, `limitk` or `limit_ratio`.
    ///
    /// Returns a matrix for an instant query and accumulates into `seriess` for a range one.
    func aggregationK(
        _ e: AggregateExpr, _ fParam: Double, _ inputMatrix: inout Matrix,
        _ seriesToResult: [Int], _ groups: inout [GroupedAggregation], _ enh: EvalNodeHelper,
        _ seriess: inout [UInt64: Series], _ seriessOrder: inout [UInt64],
        _ sampler: any RatioSampler
    ) throws -> (Matrix, Annotations) {
        let op = e.op
        var annos = Annotations()
        // `limitk`'s short-cut counter: once every group holds k elements there is nothing left
        // to look at.
        var groupsRemaining = groups.count
        for i in groups.indices {
            groups[i].seen = false
        }

        // Consume this timestamp from every remaining series. NOT an optimisation: `nextValues`
        // consumes, so a point left unread at step N is read as step N+1's value.
        func advanceRemainingSeries(_ ts: Int64, _ startIdx: Int) {
            var i = startIdx
            while i < inputMatrix.series.count {
                _ = nextValues(ts, &inputMatrix.series[i])
                i += 1
            }
        }

        seriesLoop: for si in inputMatrix.series.indices {
            let (f, h, ok) = nextValues(enh.ts, &inputMatrix.series[si])
            if !ok {
                continue
            }
            let s = Sample(
                f: f, h: h, metric: inputMatrix.series[si].metric,
                dropName: inputMatrix.series[si].dropName)

            var k: Int64 = 0
            var r = 0.0
            switch op {
            case .topk, .bottomk, .limitk:
                // Clamped to the input size, so `topk(100, x)` over three series is k = 3.
                k = Swift.min(GoConv.int64(fParam), Int64(inputMatrix.series.count))
                if k < 1 {
                    if enh.ts != endTimestamp {
                        advanceRemainingSeries(enh.ts, si + 1)
                    }
                    return (Matrix(), annos)
                }
            case .limitRatio:
                if fParam == 0 {
                    if enh.ts != endTimestamp {
                        advanceRemainingSeries(enh.ts, si + 1)
                    }
                    return (Matrix(), annos)
                } else if fParam < -1.0 {
                    r = -1.0
                } else if fParam > 1.0 {
                    r = 1.0
                } else {
                    r = fParam
                }
            default:
                break
            }

            let idx = seriesToResult[si]
            if !groups[idx].seen {
                var group = GroupedAggregation()
                group.seen = true
                switch op {
                case .limitRatio:
                    // A special case, because this very sample may not join the heap and the
                    // final size is unknown.
                    if sampler.addRatioSample(r, s) {
                        group.heapSamples.append(s)
                        GoHeap.pushed(
                            count: group.heapSamples.count,
                            less: { vectorHeapLess(group.heapSamples[$0], group.heapSamples[$1]) },
                            swap: { group.heapSamples.swapAt($0, $1) })
                    }
                case .limitk:
                    group.heapSamples = [s]
                case .topk:
                    if s.h != nil {
                        group.seen = false
                        _ = annos.add(
                            newHistogramIgnoredInAggregationInfo("topk", e.positionRange))
                    } else {
                        group.heapSamples = [s]
                    }
                case .bottomk:
                    if s.h != nil {
                        group.seen = false
                        _ = annos.add(
                            newHistogramIgnoredInAggregationInfo("bottomk", e.positionRange))
                    } else {
                        group.heapSamples = [s]
                    }
                default:
                    break
                }
                groups[idx] = group
                continue
            }

            switch op {
            case .topk:
                // A heap of at most k, SMALLEST at the root — so the root is what a bigger
                // element displaces.
                if s.h != nil {
                    _ = annos.add(newHistogramIgnoredInAggregationInfo("topk", e.positionRange))
                } else if Int64(groups[idx].heapSamples.count) < k {
                    groups[idx].heapSamples.append(s)
                    heapUp(&groups[idx].heapSamples, reverse: false)
                } else if groups[idx].heapSamples[0].f < s.f
                    || (groups[idx].heapSamples[0].f.isNaN && !s.f.isNaN)
                {
                    // The NaN clause is what lets a real value displace a NaN root; without it a
                    // NaN would sit there forever, because every `<` against it is false.
                    groups[idx].heapSamples[0] = s
                    if k > 1 {
                        heapFix(&groups[idx].heapSamples, reverse: false)
                    }
                }

            case .bottomk:
                // A heap of at most k, BIGGEST at the root.
                if s.h != nil {
                    _ = annos.add(
                        newHistogramIgnoredInAggregationInfo("bottomk", e.positionRange))
                } else if Int64(groups[idx].heapSamples.count) < k {
                    groups[idx].heapSamples.append(s)
                    heapUp(&groups[idx].heapSamples, reverse: true)
                } else if groups[idx].heapSamples[0].f > s.f
                    || (groups[idx].heapSamples[0].f.isNaN && !s.f.isNaN)
                {
                    groups[idx].heapSamples[0] = s
                    if k > 1 {
                        heapFix(&groups[idx].heapSamples, reverse: true)
                    }
                }

            case .limitk:
                if Int64(groups[idx].heapSamples.count) < k {
                    groups[idx].heapSamples.append(s)
                    heapUp(&groups[idx].heapSamples, reverse: false)
                }
                // Once every group has k, there is nothing further to read — but the remaining
                // series still have to be advanced, or the next step reads their stale points.
                if !groups[idx].groupAggrComplete
                    && Int64(groups[idx].heapSamples.count) == k
                {
                    groups[idx].groupAggrComplete = true
                    groupsRemaining -= 1
                    if groupsRemaining == 0 {
                        if enh.ts != endTimestamp {
                            advanceRemainingSeries(enh.ts, si + 1)
                        }
                        break seriesLoop
                    }
                }

            case .limitRatio:
                if sampler.addRatioSample(r, s) {
                    groups[idx].heapSamples.append(s)
                    heapUp(&groups[idx].heapSamples, reverse: false)
                }

            default:
                throw EvaluatorNotPorted(
                    nodeType: "AggregateExpr", detail: "unexpected operator \(op.description)")
            }
        }

        var mat = Matrix()
        // The instant path appends directly, "so the result is in consistent order" — the
        // heap-then-sort order, which is the whole point of `topk`.
        func add(_ lbls: Labels, _ f: Double, _ h: FloatHistogram?, _ dropName: Bool) {
            if endTimestamp == startTimestamp {
                if let h {
                    mat.series.append(
                        Series(
                            metric: lbls, histograms: [HPoint(t: enh.ts, h: h)],
                            dropName: dropName))
                } else {
                    mat.series.append(
                        Series(metric: lbls, floats: [FPoint(t: enh.ts, f: f)], dropName: dropName)
                    )
                }
                return
            }
            let hash = lbls.goHash()
            var ss = seriess[hash] ?? {
                seriessOrder.append(hash)
                return Series(metric: lbls, dropName: dropName)
            }()
            addToSeries(&ss, enh.ts, f, h)
            seriess[hash] = ss
        }

        for aggr in groups where aggr.seen {
            switch op {
            case .topk:
                // The heap keeps the lowest on top, so reverse it. `sort.Sort(sort.Reverse(...))`
                // over a comparator that is not a strict weak ordering — hence `GoSort`.
                var samples = aggr.heapSamples
                if samples.count > 1 {
                    GoSort.sort(
                        count: samples.count,
                        less: { vectorHeapLess(samples[$1], samples[$0]) },
                        swap: { samples.swapAt($0, $1) })
                }
                for v in samples {
                    add(v.metric, v.f, v.h, v.dropName)
                }
            case .bottomk:
                var samples = aggr.heapSamples
                if samples.count > 1 {
                    GoSort.sort(
                        count: samples.count,
                        less: { vectorReverseHeapLess(samples[$1], samples[$0]) },
                        swap: { samples.swapAt($0, $1) })
                }
                for v in samples {
                    add(v.metric, v.f, v.h, v.dropName)
                }
            case .limitk, .limitRatio:
                // NO sort: emitted in HEAP order, which is why `GoHeap` has to be Go's.
                for v in aggr.heapSamples {
                    add(v.metric, v.f, v.h, v.dropName)
                }
            default:
                break
            }
        }

        return (mat, annos)
    }

    /// Go: `aggregationCountValues` — one row per distinct value per group.
    ///
    /// Reached through plain `rangeEval`, not `rangeEvalAgg`: the grouping key depends on the
    /// sample *value*, so it cannot be precomputed. Upstream says so in a comment and accepts the
    /// per-step cost.
    func aggregationCountValues(
        _ e: AggregateExpr, _ grouping: [String], _ valueLabel: String, _ vec: Vector,
        _ enh: EvalNodeHelper
    ) -> (Vector, Annotations) {
        var counts: [UInt64: (labels: Labels, count: Int)] = [:]
        // Go ranges a map to build the output, so its order is randomised; insertion order is the
        // port's deterministic choice (PORTING.md exception 14's situation).
        var order: [UInt64] = []

        for s in vec.samples {
            enh.resetBuilder(s.metric)
            if s.h == nil {
                // `strconv.FormatFloat(f, 'f', -1, 64)` — shortest 'f', not 'g'. So 1e21 becomes
                // a 22-digit integer string rather than an exponent (ADR-4).
                enh.lb.set(valueLabel, GoFloat.formatF(s.f))
            } else {
                enh.lb.set(valueLabel, s.h!.description)
            }
            let metric = enh.lb.labels()

            let groupingKey = generateGroupingKey(metric, grouping, e.without)
            if counts[groupingKey] == nil {
                counts[groupingKey] = (
                    labels: generateGroupingLabels(enh, metric, e.without, grouping), count: 1
                )
                order.append(groupingKey)
                continue
            }
            counts[groupingKey]!.count += 1
        }

        var out = enh.out
        for key in order {
            let aggr = counts[key]!
            out.append(Sample(f: Double(aggr.count), metric: aggr.labels))
        }
        return (out, Annotations())
    }
}

/// `heap.Push` over a `[Sample]`, after the append.
///
/// A free function rather than inline, because Swift's exclusivity rules forbid passing
/// `groups[idx].heapSamples` to a closure that also mutates it — so the array is taken `inout` and
/// the closures capture it locally.
private func heapUp(_ samples: inout [Sample], reverse: Bool) {
    let less = reverse ? vectorReverseHeapLess : vectorHeapLess
    var local = samples
    GoHeap.pushed(
        count: local.count,
        less: { less(local[$0], local[$1]) },
        swap: { local.swapAt($0, $1) })
    samples = local
}

/// `heap.Fix(h, 0)` over a `[Sample]`.
private func heapFix(_ samples: inout [Sample], reverse: Bool) {
    let less = reverse ? vectorReverseHeapLess : vectorHeapLess
    var local = samples
    GoHeap.fix(
        0, count: local.count,
        less: { less(local[$0], local[$1]) },
        swap: { local.swapAt($0, $1) })
    samples = local
}
