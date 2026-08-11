//===----------------------------------------------------------------------===//
// Ported from github.com/bboreham/go-loser @ v0.0.0-20230920113527 — a loser tree (tournament tree),
// the k-way merge structure `tsdb/index`'s `Merge` is built on.
//
// A third-party algorithm Prometheus depends on, so it lives in `GoCompat` beside `GoHeap`
// (`container/heap`) and `GoSort` (pdqsort) for the same reason: the merge order it produces is
// observable, and reimplementing it "equivalently" is how orderings drift.
//
// ## Why not a heap
//
// A loser tree is a complete binary tree over the k sequences where each internal node stores the
// **loser** of the contest beneath it and node 0 stores the overall **winner**. Advancing the winner
// then costs one walk from its leaf to the root — `replayGames` — instead of a heap's sift-down with
// two comparisons per level. Same asymptotics, half the comparisons, and a different tie-breaking
// order, which is the part that matters here.
//
// ## The layout, and the `index == -1` overloading
//
// Leaves live at `M...2M-1` and internal nodes at `1...M-1`, so nodes `N` and `N+1` share parent
// `N/2`. `nodes[0]` is not part of the tree: its `index` is the winner's position and its `value` the
// winner's value.
//
// `index == -1` means two different things depending on where it is:
//
//   * on `nodes[0]`, "the tree has not been initialised yet" — `New` sets it deliberately so the first
//     `Next` runs `initialize`;
//   * on a leaf, "this sequence is exhausted", set by `moveNext` along with `value = maxVal`.
//
// So `nodes[nodes[0].index].index == -1` reads as "the winner's sequence is exhausted", which is how
// `Next`, `IsEmpty` and `Fix` all test for done-ness. Two meanings on one field is not a shape to
// tidy: `initialize` is what disambiguates them, and it is only ever called when `nodes[0].index` is
// -1.
//
// ## `maxVal` must exceed every real value
//
// An exhausted sequence is given `maxVal` so it always loses. `Merge` passes
// `SeriesRef(UInt64.max)`, and upstream's comment says it "must be higher than all real values used
// in the tree" — a real series ref that large would sort as exhausted and vanish from the merge.
//===----------------------------------------------------------------------===//

/// Go: `loser.Sequence` — the minimum a loser tree needs from a sequence.
///
/// Deliberately smaller than an iterator: no `Err`, no `Seek`. `mergedPostings` reaches past the tree
/// to the sequence itself (`Winner().Seek(...)`) when it needs more, which is why `Winner` is public.
public protocol LoserSequence<Element>: AnyObject {
    associatedtype Element: Comparable
    /// The current value. Valid only after a `next()` that returned true.
    func at() -> Element
    func next() -> Bool
}

/// Go: `loser.Tree`.
///
/// A `final class` because the tree mutates its nodes in place and the sequences it holds are
/// reference types whose position advances — value semantics would silently fork both.
public final class LoserTree<Element: Comparable, S: LoserSequence<Element>> {
    private struct Node {
        /// The LOSER for every node except `nodes[0]`, where it is the winner. `-1` is overloaded; see
        /// the file header.
        var index: Int = 0
        var value: Element
        /// Only populated for leaves.
        var items: S?
    }

    private let maxVal: Element
    private var nodes: [Node]

    /// Go: `loser.New`.
    public init(_ sequences: [S], maxVal: Element) {
        self.maxVal = maxVal
        let n = sequences.count
        self.nodes = [Node](repeating: Node(value: maxVal, items: nil), count: n * 2)
        for (i, s) in sequences.enumerated() {
            nodes[i + n].items = s
            // Every sequence must be advanced once so `at()` has a value.
            _ = moveNext(i + n)
        }
        if n > 0 {
            // The flag meaning "initialise on the first `next()`".
            nodes[0].index = -1
        }
    }

    private func moveNext(_ index: Int) -> Bool {
        guard let items = nodes[index].items else {
            nodes[index].value = maxVal
            nodes[index].index = -1
            return false
        }
        if items.next() {
            nodes[index].value = items.at()
            return true
        }
        nodes[index].value = maxVal
        nodes[index].index = -1
        return false
    }

    /// Go: `Winner` — the sequence currently at the front, so a caller can advance it directly.
    public func winner() -> S? {
        nodes[nodes[0].index].items
    }

    /// Go: `At`.
    public func at() -> Element {
        nodes[0].value
    }

    /// Go: `Next`.
    public func next() -> Bool {
        if nodes.isEmpty { return false }
        if nodes[0].index == -1 {
            initialize()
            return nodes[nodes[0].index].index != -1
        }
        if nodes[nodes[0].index].index == -1 {
            // Already exhausted.
            return false
        }
        _ = moveNext(nodes[0].index)
        replayGames(nodes[0].index)
        return nodes[nodes[0].index].index != -1
    }

    /// Go: `Fix` — the winner was advanced by the caller, so the tree needs re-settling.
    ///
    /// `closed` means that advance exhausted it. `mergedPostings.Seek` is the only caller, and it
    /// passes `!Winner().Seek(id)`.
    public func fix(_ closed: Bool) {
        let winnerIdx = nodes[0].index
        if closed {
            nodes[winnerIdx].value = maxVal
            nodes[winnerIdx].index = -1
        } else if let items = nodes[winnerIdx].items {
            nodes[winnerIdx].value = items.at()
        }
        replayGames(winnerIdx)
    }

    /// Go: `IsEmpty` — note it INITIALISES the tree if that has not happened, so it is not a pure
    /// query. `mergedPostings.Seek` relies on that.
    public func isEmpty() -> Bool {
        if nodes.isEmpty { return true }
        if nodes[0].index == -1 {
            initialize()
        }
        return nodes[nodes[0].index].index == -1
    }

    private func initialize() {
        let winner = playGame(1)
        nodes[0].index = winner
        nodes[0].value = nodes[winner].value
    }

    /// Go: `playGame` — the winner beneath `pos`, storing the loser at each internal node.
    private func playGame(_ pos: Int) -> Int {
        if pos >= nodes.count / 2 {
            return pos
        }
        let left = playGame(pos * 2)
        let right = playGame(pos * 2 + 1)
        let loser: Int
        let winner: Int
        // Note `<`, not `<=`: on a tie the LEFT node loses, and that decides the order equal values
        // come out in.
        if nodes[left].value < nodes[right].value {
            loser = right
            winner = left
        } else {
            loser = left
            winner = right
        }
        nodes[pos].index = loser
        nodes[pos].value = nodes[loser].value
        return winner
    }

    /// Go: `replayGames` — walk from a new winner up to the root, swapping where it now loses.
    private func replayGames(_ pos: Int) {
        var pos = pos
        var winningValue = nodes[pos].value
        var n = pos >> 1
        while n != 0 {
            if nodes[n].value < winningValue {
                // The stored loser actually beats the incoming winner, so they swap.
                let oldIndex = nodes[n].index
                nodes[n].index = pos
                pos = oldIndex
                let oldValue = nodes[n].value
                nodes[n].value = winningValue
                winningValue = oldValue
            }
            n = n >> 1
        }
        nodes[0].index = pos
        nodes[0].value = winningValue
    }
}
