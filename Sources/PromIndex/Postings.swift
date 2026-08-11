//===----------------------------------------------------------------------===//
// Ported from tsdb/index/postings.go @ v3.13.2 — the postings algebra: iteration over ordered series
// references, and the set operations a query is compiled into.
//
// **`MemPostings` is deliberately NOT here.** That is the Head's in-memory index — locking,
// `EnsureOrder`, `Delete`, `Stats` — and it belongs with the Head in Phase 7. What is here is the
// algebra a querier evaluates: `Intersect`, `Merge`, `Without`, and the leaf iterators. Everything in
// this file is exported upstream, so it is pinnable directly rather than through a container.
//
// ## `Seek` is idempotent and may not move
//
// `Seek(v)` advances to the first value **>= v**, and if the iterator is already there it returns true
// **without advancing**. Every implementation opens with a variant of `if cur >= x { return true }`.
// Get that wrong and an intersection silently skips values, because `intersectPostings.Seek` calls
// `Seek` on the same iterator repeatedly with a target that may not have changed.
//
// ## `EmptyPostings()` is a SENTINEL, compared by identity
//
// `IsEmptyPostingsType` asks whether the value *is* the singleton, not whether it is empty — upstream's
// comment is explicit that a false answer does not mean non-empty. `Intersect` and `Without` test for
// it to take short-circuits, so an implementation that returns its own empty iterator instead of the
// sentinel is correct but slower. The port keeps the identity semantics with a single shared instance.
//
// ## `Intersect`'s `Next` is not `Seek` in a loop
//
// `Next` advances **every** iterator once and only then, if they disagree, falls into `Seek`. That is
// not an optimisation of "seek to the max": advancing all of them first is what lets a later iterator
// contribute a *higher* target than the first one, so one pass replaces what would otherwise be
// several rounds. Note it keeps scanning after finding a mismatch specifically to pick up that higher
// target.
//
// ## `Without`'s `Seek` recurses through `Next`
//
// `removedPostings.Seek` positions both sides and then calls its own `Next`, which is what applies the
// removal at the new position. A `Seek` that just positioned `full` would return a value that is in
// `drop`.
//===----------------------------------------------------------------------===//

public import PromStorage

internal import GoCompat

/// Go: `AllPostingsKey` — the label under which the "every series" postings list is stored.
///
/// `("", "")`, which cannot collide with a real label because a label name is never empty.
public func allPostingsKey() -> (name: String, value: String) { ("", "") }

/// Go: `index.Postings` — iterative access over an ORDERED list of series refs.
///
/// A class-bound protocol because every implementation is a `*struct` upstream whose position mutates,
/// and because `LoserTree` needs reference semantics to advance a sequence the tree is holding.
public protocol Postings: AnyObject {
    /// Advances, returning true if there was another value.
    func next() -> Bool
    /// Advances to the first value **>= v**, returning true if one was found. Returns true WITHOUT
    /// moving when the current value already satisfies it.
    func seek(_ v: SeriesRef) -> Bool
    /// The value at the current position. Only valid after a successful `next()` or `seek(_:)`.
    func at() -> SeriesRef
    func err() -> (any Error)?
}

/// Go: `errPostings` — empty, and always returns its error.
public final class ErrPostingsList: Postings, @unchecked Sendable {
    private let error: (any Error)?
    init(_ error: (any Error)?) { self.error = error }
    public func next() -> Bool { false }
    public func seek(_: SeriesRef) -> Bool { false }
    public func at() -> SeriesRef { SeriesRef(rawValue: 0) }
    public func err() -> (any Error)? { error }
}

/// Go: `emptyPostings`, the package-level singleton.
///
/// One shared instance, because `IsEmptyPostingsType` compares identity. See the file header.
///
/// `@unchecked Sendable` on the type: it is genuinely immutable — a single `let` holding an optional
/// error, no position to advance, every method a constant — but the compiler cannot see that through
/// the class. Go's equivalent is a package-level `var emptyPostings = errPostings{}` shared across
/// goroutines for the same reason.
private let emptyPostingsSingleton = ErrPostingsList(nil)

/// Go: `EmptyPostings`.
public func emptyPostings() -> any Postings { emptyPostingsSingleton }

/// Go: `IsEmptyPostingsType` — is this THE sentinel? A false answer does not mean non-empty.
public func isEmptyPostingsType(_ p: any Postings) -> Bool {
    p === emptyPostingsSingleton
}

/// Go: `ErrPostings`.
public func errPostings(_ err: any Error) -> any Postings { ErrPostingsList(err) }

/// Go: `ExpandPostings` — drain an iterator into an array, propagating its error.
public func expandPostings(_ p: any Postings) throws -> [SeriesRef] {
    var res: [SeriesRef] = []
    while p.next() {
        res.append(p.at())
    }
    if let e = p.err() { throw e }
    return res
}

/// Go: `listPostings` — over a plain ordered array.
public final class ListPostings: Postings {
    /// Go slices its `list` as it goes; the port keeps an index, which is the same traversal without
    /// re-slicing. `len(it.list)` becomes `list.count - i`, and `Len()` below preserves that meaning.
    private let list: [SeriesRef]
    private var i = 0
    private var cur = SeriesRef(rawValue: 0)

    /// Go: `NewListPostings`. The list MUST be ordered; nothing checks.
    public init(_ list: [SeriesRef]) { self.list = list }

    public func at() -> SeriesRef { cur }

    public func next() -> Bool {
        if i < list.count {
            cur = list[i]
            i += 1
            return true
        }
        // Go resets `cur` to 0 on exhaustion, which `Seek`'s `cur >= x` test then depends on.
        cur = SeriesRef(rawValue: 0)
        return false
    }

    public func seek(_ x: SeriesRef) -> Bool {
        if cur >= x { return true }
        if i >= list.count { return false }
        // Go checks the NEXT item before binary searching, because a seek one step forward is the
        // common case and a search would cost a log factor for nothing.
        var j = i
        if list[i] < x {
            j = lowerBound(list, x, from: i)
            if j >= list.count {
                // Off the end: terminate.
                i = list.count
                return false
            }
        }
        cur = list[j]
        i = j + 1
        return true
    }

    public func err() -> (any Error)? { nil }

    /// Go: `Len` — the number REMAINING, not the total.
    public var count: Int { list.count - i }
}

/// Go: `slices.BinarySearch` — the first index whose element is >= `x`.
private func lowerBound(_ a: [SeriesRef], _ x: SeriesRef, from: Int) -> Int {
    var lo = from
    var hi = a.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if a[mid] < x {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

/// Go: `Intersect`.
///
/// Three short-circuits before any work: no inputs is empty, one input is itself, and any input being
/// the empty SENTINEL makes the whole thing empty.
public func intersect(_ its: [any Postings]) -> any Postings {
    if its.isEmpty { return emptyPostings() }
    if its.count == 1 { return its[0] }
    if its.contains(where: { isEmptyPostingsType($0) }) { return emptyPostings() }
    return IntersectPostings(its)
}

/// Go: `intersectPostings`.
final class IntersectPostings: Postings {
    private let postings: [any Postings]
    private var current = SeriesRef(rawValue: 0)

    init(_ its: [any Postings]) { self.postings = its }

    func at() -> SeriesRef { current }

    func seek(_ target: SeriesRef) -> Bool {
        var target = target
        while true {
            var allEqual = true
            for p in postings {
                if !p.seek(target) { return false }
                if p.at() > target {
                    target = p.at()
                    allEqual = false
                }
            }
            if allEqual {
                current = target
                return true
            }
        }
    }

    func next() -> Bool {
        // Advance the first, and take its value as the target.
        if !postings[0].next() { return false }
        var target = postings[0].at()
        var allEqual = true
        // Then advance ALL the others — and keep going past a mismatch, because a later one may
        // contribute a higher target and save a round of seeking.
        for p in postings.dropFirst() {
            if !p.next() { return false }
            let a = p.at()
            if a > target {
                target = a
                allEqual = false
            } else if a < target {
                allEqual = false
            }
        }
        if allEqual {
            current = target
            return true
        }
        return seek(target)
    }

    func err() -> (any Error)? {
        for p in postings {
            if let e = p.err() { return e }
        }
        return nil
    }
}

/// Adapts a `Postings` to the loser tree's smaller `LoserSequence`.
final class PostingsSequence: LoserSequence {
    typealias Element = SeriesRef
    let p: any Postings
    init(_ p: any Postings) { self.p = p }
    func at() -> SeriesRef { p.at() }
    func next() -> Bool { p.next() }
}

/// Go: `Merge` — the union, over a loser tree.
///
/// Go takes a `context.Context` and ignores it (`_ context.Context`), so the port omits it.
public func merge(_ its: [any Postings]) -> any Postings {
    if its.isEmpty { return emptyPostings() }
    if its.count == 1 { return its[0] }
    return MergedPostings(its)
}

/// Go: `mergedPostings`.
final class MergedPostings: Postings {
    private let p: [any Postings]
    private let sequences: [PostingsSequence]
    private let tree: LoserTree<SeriesRef, PostingsSequence>
    private var cur = SeriesRef(rawValue: 0)

    init(_ p: [any Postings]) {
        self.p = p
        self.sequences = p.map(PostingsSequence.init)
        // Go: `maxVal` is `SeriesRef(math.MaxUint64)`, with the comment that it "must be higher than
        // all real values used in the tree". A real ref that large would read as exhausted.
        self.tree = LoserTree(sequences, maxVal: SeriesRef(rawValue: UInt64.max))
    }

    func next() -> Bool {
        while true {
            if !tree.next() { return false }
            // De-duplicate: the same ref may come from several inputs.
            let newItem = tree.at()
            if newItem != cur {
                cur = newItem
                return true
            }
        }
    }

    func seek(_ id: SeriesRef) -> Bool {
        // Advance the WINNER directly and let the tree re-settle — `Fix` rather than `Next`, because
        // the sequence moved behind the tree's back.
        while !tree.isEmpty() && tree.at() < id {
            let finished = !(tree.winner()?.p.seek(id) ?? false)
            tree.fix(finished)
        }
        if tree.isEmpty() { return false }
        cur = tree.at()
        return true
    }

    func at() -> SeriesRef { cur }

    func err() -> (any Error)? {
        for x in p {
            if let e = x.err() { return e }
        }
        return nil
    }
}

/// Go: `Without` — everything in `full` that is not in `drop`.
public func without(_ full: any Postings, _ drop: any Postings) -> any Postings {
    if isEmptyPostingsType(full) { return emptyPostings() }
    if isEmptyPostingsType(drop) { return full }
    return RemovedPostings(full, drop)
}

/// Go: `removedPostings`.
final class RemovedPostings: Postings {
    private let full: any Postings
    private let remove: any Postings
    private var cur = SeriesRef(rawValue: 0)
    private var initialized = false
    private var fok = false
    private var rok = false

    init(_ full: any Postings, _ remove: any Postings) {
        self.full = full
        self.remove = remove
    }

    func at() -> SeriesRef { cur }

    func next() -> Bool {
        if !initialized {
            fok = full.next()
            rok = remove.next()
            initialized = true
        }
        while true {
            if !fok { return false }
            if !rok {
                // Nothing left to remove, so the rest of `full` passes through.
                cur = full.at()
                fok = full.next()
                return true
            }
            let fcur = full.at()
            let rcur = remove.at()
            if fcur < rcur {
                cur = fcur
                fok = full.next()
                return true
            } else if rcur < fcur {
                // Bring the removal side up to where `full` is.
                rok = remove.seek(fcur)
            } else {
                // Equal: skip it.
                fok = full.next()
            }
        }
    }

    func seek(_ id: SeriesRef) -> Bool {
        if cur >= id { return true }
        fok = full.seek(id)
        rok = remove.seek(id)
        initialized = true
        // `next()` is what actually applies the removal at the new position — see the file header.
        return next()
    }

    func err() -> (any Error)? {
        if let e = full.err() { return e }
        return remove.err()
    }
}

/// Go: `bigEndianPostings` — over a byte stream of big-endian `uint32`s, which is the on-disk form.
///
/// Note the width: the file format stores 32-bit refs while `SeriesRef` is 64-bit, so a decoded ref is
/// always small. `newBigEndianPostings` is unexported upstream but the type is reachable through the
/// index reader, and it is here because the algebra above is what consumes it.
public final class BigEndianPostings: Postings {
    private let list: [UInt8]
    private var i = 0
    private var cur: UInt32 = 0

    public init(_ list: [UInt8]) { self.list = list }

    public func at() -> SeriesRef { SeriesRef(rawValue: UInt64(cur)) }

    public func next() -> Bool {
        if i + 4 <= list.count {
            cur = GoBigEndian.uint32(list, i)
            i += 4
            return true
        }
        return false
    }

    public func seek(_ x: SeriesRef) -> Bool {
        if UInt64(cur) >= x.rawValue { return true }
        // Go binary searches the remaining bytes in 4-byte strides.
        var lo = i / 4
        var hi = list.count / 4
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if UInt64(GoBigEndian.uint32(list, mid * 4)) < x.rawValue {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        i = lo * 4
        return next()
    }

    public func err() -> (any Error)? { nil }

    /// Go: `Len` — remaining entries.
    public var count: Int { (list.count - i) / 4 }
}
