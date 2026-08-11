//===----------------------------------------------------------------------===//
// Ported from Go's `container/heap` @ go1.26.5 — `Push`, `Fix`, `up` and `down`.
//
// `promql`'s `topk`/`bottomk`/`limitk`/`limit_ratio` build a binary heap of `k` samples through
// this package, and **the heap's internal array order is observable**:
//
//   * `limitk` and `limit_ratio` iterate `aggr.heap` directly and emit it in *heap* order;
//   * `topk`/`bottomk` sort it first, but with `sort.Sort` over a comparator that is not a strict
//     weak ordering (`vectorByValueHeap.Less` returns true for a NaN on the left, including
//     against another NaN), so the *input* order to that sort decides the output.
//
// So this is not "any heap will do". The sift directions, the parent formula and the
// left-child-first tie-break all have to be Go's, and `GoSort.sort` — the ported pdqsort — is what
// runs on top. Same reasoning as `GoNatsort` and `GoSort` (PORTING.md quirks 66-67): where the
// algorithm is the contract, port the algorithm.
//
// Pinned to a Go **toolchain** rather than to prometheus v3.13.2, like `GoSort`.
//
// ## `down` returns whether it moved, and `Fix` depends on it
//
// `Fix(h, i)` tries `down` first and falls back to `up` only if nothing moved. Doing both, or
// only one, gives a valid heap for most inputs and a *differently ordered* one for some — which
// for `limitk` is a different answer, not just a different layout.
//
// The `j1 < 0` guard in `down` is Go's overflow check for `2*i + 1`. Unreachable for any heap that
// fits in memory; kept because it is upstream's and costs nothing.
//===----------------------------------------------------------------------===//

/// Go: `container/heap`, over an index-addressed collection.
///
/// The interface is three closures rather than a protocol, matching ``GoSort``'s shape: the
/// caller owns the storage, so a heap over a `[Sample]` needs no wrapper type and no
/// `Interface` conformance.
public enum GoHeap: Sendable {

    /// Go: `heap.Push` — append, then sift up from the new last index.
    ///
    /// The append is the caller's, because Go's `Push` is a method on the *user's* type and does
    /// the append itself. Call this **after** appending.
    public static func pushed(
        count: Int, less: (Int, Int) -> Bool, swap: (Int, Int) -> Void
    ) {
        up(count - 1, less, swap)
    }

    /// Go: `heap.Fix` — restore the invariant after the element at `i` changed.
    ///
    /// `down` first, `up` only if `down` did not move it. Not both.
    public static func fix(
        _ i: Int, count: Int, less: (Int, Int) -> Bool, swap: (Int, Int) -> Void
    ) {
        if !down(i, count, less, swap) {
            up(i, less, swap)
        }
    }

    /// Go: `up`.
    static func up(_ j0: Int, _ less: (Int, Int) -> Bool, _ swap: (Int, Int) -> Void) {
        var j = j0
        while true {
            // Integer division, so for j == 0 the parent is 0 and the `i == j` test stops.
            let i = (j - 1) / 2
            if i == j || !less(j, i) {
                break
            }
            swap(i, j)
            j = i
        }
    }

    /// Go: `down` — returns true if the element moved at all, which is what `Fix` branches on.
    @discardableResult
    static func down(
        _ i0: Int, _ n: Int, _ less: (Int, Int) -> Bool, _ swap: (Int, Int) -> Void
    ) -> Bool {
        var i = i0
        while true {
            let j1 = 2 * i + 1
            // `j1 < 0` is Go's overflow guard; unreachable in practice, kept as upstream's.
            if j1 >= n || j1 < 0 {
                break
            }
            var j = j1
            let j2 = j1 + 1
            // The RIGHT child wins only on a strict `less`, so equal children keep the left —
            // and with an inconsistent comparator that tie-break is the answer.
            if j2 < n && less(j2, j1) {
                j = j2
            }
            if !less(j, i) {
                break
            }
            swap(i, j)
            i = j
        }
        return i > i0
    }
}
