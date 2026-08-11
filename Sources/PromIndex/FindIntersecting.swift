//===----------------------------------------------------------------------===//
// Ported from tsdb/index/postings.go @ v3.13.2 — `FindIntersectingPostings` and its heap.
//
// The question this answers is not "which series match" but **"which of these candidate lists have at least
// one series in common with `p`"** — it returns INDEXES into `candidates`, not series refs. That is what
// `labelValuesWithMatchers` needs: one candidate list per label value, and the answer is which values
// survive the matchers.
//
// ## The heap does not actually pop, and that is load-bearing
//
// `popIndex` marks the root `popped` and calls `heap.Fix` instead of `heap.Pop`. Upstream's comment says why:
// `Pop()` on Go's `heap.Interface` returns `any`, so a real pop costs an interface boxing allocation per
// candidate. The trick is in `Less`, which sorts **popped elements to the bottom**:
//
//     if h[i].popped != h[j].popped { return h[j].popped }
//     return h[i].p.At() < h[j].p.At()
//
// So a popped element compares as greater than every live one, `Fix` sinks it, and `empty()` — which tests
// `len == 0 || h[0].popped` — reports the heap exhausted once the root is a popped element. **`Len() > 0`
// therefore does not mean non-empty**, which upstream flags in a comment because it is exactly the wrong
// guess to make.
//
// ## `heap.Init`, not repeated pushes
//
// The candidates are appended and then `heap.Init` runs. `Init` sifts DOWN from the last internal node
// backwards; pushing each element sifts UP from the end. Both give a valid heap and they give DIFFERENT
// orders — and the order decides which index is popped first, which is the order of the returned slice. So
// `GoHeap.initialized` exists for this call site.
//
// ## The loop's two branches are not symmetric
//
// `p.Seek(h.at())` advances the query postings to the heap's minimum. Then:
//
//   - `p.At() == h.at()`  → that candidate intersects: pop its index and move on.
//   - otherwise           → `p.At()` overshot, so `seekHead(p.At())` advances the ROOT candidate only.
//
// The second branch does not pop. A candidate whose values are all below `p.At()` is advanced repeatedly
// until it either matches or exhausts, and only then does `seekHead` remove it. That is why `seekHead`
// contains the other `popIndex` call.
//
// ## The early return keeps partial results
//
// `if !p.Seek(...) { return indexes, p.Err() }` returns the indexes found SO FAR alongside the error, where
// every other error path in the function returns `nil`. Reproduced: a caller that ignores the error sees a
// truncated-but-valid answer rather than an empty one.
//===----------------------------------------------------------------------===//

public import PromStorage

internal import GoCompat

/// Go: `postingsWithIndex` — a candidate list, its original position, and whether it has been consumed.
private struct PostingsWithIndex {
    var index: Int
    var p: any Postings
    /// Marks the element as consumed WITHOUT removing it. See the file header.
    var popped: Bool = false
}

/// Go: `postingsWithIndexHeap`, on `GoHeap`.
///
/// A struct rather than an extension on `Array`, because the heap's mutating operations (`popIndex`,
/// `seekHead`) belong to it and because `Postings` is a class-like protocol whose `next()`/`seek()` mutate
/// the element in place — an `Array` of existentials makes that awkward to express safely.
private struct PostingsWithIndexHeap {
    var items: [PostingsWithIndex] = []

    /// Go: `empty()`. **Not** `items.isEmpty`: the heap is exhausted when its ROOT is popped, because
    /// `Less` sinks popped elements to the bottom. See the file header.
    var isEmptyHeap: Bool { items.isEmpty || items[0].popped }

    /// Go: `Less` — popped elements to the bottom, then by `At()`.
    private func less(_ i: Int, _ j: Int) -> Bool {
        if items[i].popped != items[j].popped {
            return items[j].popped
        }
        return items[i].p.at() < items[j].p.at()
    }

    private mutating func fix(_ i: Int) {
        // `less` and `swap` both need the array; `withUnsafeMutable…` would be the fast path but the
        // closures here read `items` through `self`, so the straightforward form is the correct one.
        GoHeap.fix(
            i, count: items.count,
            less: { self.less($0, $1) },
            swap: { items.swapAt($0, $1) })
    }

    mutating func initialize() {
        GoHeap.initialized(
            count: items.count,
            less: { self.less($0, $1) },
            swap: { items.swapAt($0, $1) })
    }

    /// Go: `at()` — where the root's postings currently points.
    func at() -> SeriesRef { items[0].p.at() }

    /// Go: `popIndex` — mark the root consumed, re-sink it, and return its original index.
    mutating func popIndex() -> Int {
        let index = items[0].index
        items[0].popped = true
        fix(0)
        return index
    }

    /// Go: `seekHead` — seek the ROOT only; remove it if that exhausts or fails it.
    mutating func seekHead(_ val: SeriesRef) throws {
        if items[0].p.seek(val) {
            fix(0)
            return
        }
        if let err = items[0].p.err() {
            throw FindIntersectingError.seekPostings(index: items[0].index, underlying: err)
        }
        _ = popIndex()
    }
}

/// Go: `fmt.Errorf("seek postings %d: %w", pi.index, err)`.
public enum FindIntersectingError: Error, CustomStringConvertible {
    case seekPostings(index: Int, underlying: any Error)

    public var description: String {
        switch self {
        case .seekPostings(let i, let e): return "seek postings \(i): \(e)"
        }
    }
}

/// Go: `FindIntersectingPostings` — the INDEXES of the candidates that intersect `p`.
///
/// Returns positions in `candidates`, not series refs. See the file header for why the heap never really
/// pops and why the two loop branches are asymmetric.
public func findIntersectingPostings(
    _ p: any Postings, _ candidates: [any Postings]
) throws -> [Int] {
    var h = PostingsWithIndexHeap()
    h.items.reserveCapacity(candidates.count)
    for (idx, it) in candidates.enumerated() {
        if it.next() {
            h.items.append(PostingsWithIndex(index: idx, p: it))
        } else if let err = it.err() {
            throw err
        }
    }
    if h.isEmptyHeap {
        // Go returns `nil, nil` here — an empty result, not an error.
        return []
    }
    h.initialize()

    var indexes: [Int] = []
    while !h.isEmptyHeap {
        if !p.seek(h.at()) {
            // The partial result is DELIBERATELY kept alongside the error. See the file header.
            if let err = p.err() {
                throw FindIntersectingError.seekPostings(index: -1, underlying: err)
            }
            return indexes
        }
        if p.at() == h.at() {
            indexes.append(h.popIndex())
        } else {
            try h.seekHead(p.at())
        }
    }
    return indexes
}
