//===----------------------------------------------------------------------===//
// Ported from tsdb/index/postings.go @ v3.13.2 — `MemPostings`, the Head's in-memory inverted index.
//
// `Postings.swift` has the algebra a query is compiled into; this is the container the Head fills. Every
// series the Head appends is added here under each of its label pairs, and every query reaches its series
// through `postings(name:values:)`. It is the reason `head.go` can answer a matcher without touching disk.
//
// ## The empty label is a real key, and it is how `All()` works
//
// `allPostingsKey` is `labels.Label{}` — name `""`, value `""`. `Add` inserts the series under every one of
// its labels **and** under that empty pair, so `all()` is just `postings(name: "", values: [""])`. Two
// consequences a port gets wrong quietly: `labelNames()` has to EXCLUDE `""`, and `delete` has to process
// the empty key explicitly after the affected set (it is never in `affected`).
//
// ## `lvs` is append-only and UNSORTED, and that is observable
//
// `m` is `[name: [value: [SeriesRef]]]`, and `lvs` is a parallel `[name: [String]]` holding the same values
// in **insertion order**. `labelValues` returns `lvs[name]` — so its order is the order the values were first
// seen, not sorted — and it applies `Limit` by TRUNCATION **before** any caller can sort. That is exactly
// quirk 35's shape for the block index, and it is why `MemQuerier` had to be written the same way.
//
// `delete` rebuilds `lvs[name]` from `m[name]`'s keys, which is a Go MAP — so after a deletion the order
// becomes arbitrary upstream. The corpus therefore never asserts `labelValues` order after a `delete`; see
// exception 23.
//
// ## Insertion repairs order with ONE pass, and the invariant is "the first n-1 are sorted"
//
// `addFor` appends and then bubbles the new element back while it is smaller than its predecessor. That is
// not a sort: it is correct only because the list was already sorted before the append. Upstream says so —
// "The invariant is that the first n-1 items in the list are already sorted" — and an unordered
// `MemPostings` (`newUnordered()`) skips the repair entirely until `ensureOrder()` sorts everything once.
//
// ## What is deliberately absent
//
//   * **All the locking.** `sync.RWMutex`, and `unlockWaitAndLockAgain` — which exists only to let readers
//     in during a long `Delete` and whose entire body is a lock dance plus a 1 ms sleep. The port's Head does
//     not exist yet and its concurrency story is that slice's to decide, so a lock here would be a claim
//     about a design that has not been made. `ensureOrder`'s worker pool goes with it: the concurrency is not
//     observable in the result, only in how long it takes.
//   * **`Stats`.** It needs `maxHeap` and its output depends on map iteration order for ties, and its only
//     caller is `web/api/v1`'s `/status/tsdb` — Phase 9. Deferred there with the rest of the HTTP API.
//   * **`Symbols`' `StringIter`.** The port returns the sorted array; the iterator wrapper belongs with the
//     index writer that consumes it.
//===----------------------------------------------------------------------===//

internal import GoCompat
public import PromLabels
public import PromStorage

/// Go: `defaultLabelNamesMapSize` — a capacity hint only, with no observable effect. Kept because it is the
/// kind of constant a reader goes looking for.
let defaultLabelNamesMapSize = 512
/// Go: `exponentialSliceGrowthFactor`. Growth strategy, not behaviour — but see `delete`, where it decides a
/// capacity that upstream then relies on for churn.
let exponentialSliceGrowthFactor = 2

/// Go: `index.MemPostings`.
///
/// Not `Sendable` and not internally locked — see the file header on why the mutex is absent rather than
/// guessed at.
public final class MemPostings {

    /// Go: `m` — postings by label name, then by label value.
    private var m: [String: [String: [SeriesRef]]] = [:]
    /// Go: `lvs` — the label values per name, in INSERTION order. Append-only while adding.
    private var lvs: [String: [String]] = [:]
    /// Go: `ordered` — whether every list is sorted, and therefore whether `addFor` repairs on insert.
    private var ordered: Bool

    /// Go: `NewMemPostings` — ready for reads and writes.
    public init() {
        ordered = true
    }

    /// Go: `NewUnorderedMemPostings` — **not safe to read** until `ensureOrder()` has been called once.
    /// Used by the WAL replay, which fills in whatever order the segments give it.
    public static func newUnordered() -> MemPostings {
        let p = MemPostings()
        p.ordered = false
        return p
    }

    // MARK: - Reading

    /// Go: `Symbols` — every unique name AND value, de-duplicated and sorted.
    ///
    /// Note it is built from `lvs`, not from `m`: the names come from `lvs`'s keys and the values from its
    /// slices, so a name whose values were all deleted contributes nothing.
    public func symbols() -> [String] {
        var symbols = Set<String>()
        for (n, labelValues) in lvs {
            symbols.insert(n)
            for v in labelValues { symbols.insert(v) }
        }
        return symbols.sorted()
    }

    /// Go: `SortedKeys` — every label pair, sorted by name then value.
    ///
    /// Built from `m`, so it DOES include the empty `allPostingsKey` pair, which sorts first. `labelNames`
    /// excludes it and this does not; that asymmetry is upstream's.
    public func sortedKeys() -> [Label] {
        var keys: [Label] = []
        for (n, e) in m {
            for v in e.keys {
                keys.append(Label(n, v))
            }
        }
        // `Label` is `Comparable` by name then value already — exactly `labels.Compare`'s order, which is
        // what upstream's inline `strings.Compare` pair spells out.
        keys.sort()
        return keys
    }

    /// Go: `LabelNames` — the unique names, EXCLUDING `allPostingsKey`'s empty name.
    ///
    /// Returns an empty list for an empty index. Upstream returns `nil` and sizes the result `n-1`, which is
    /// why the `n == 0` early return has to be there at all: `make([]string, 0, -1)` would panic.
    ///
    /// The order is Go's map order and therefore arbitrary; the port's is its dictionary's. Exception 23.
    public func labelNames() -> [String] {
        if m.isEmpty { return [] }
        var names: [String] = []
        for name in m.keys where name != allPostingsKey().name {
            names.append(name)
        }
        return names
    }

    /// Go: `LabelValues` — the values for a name, in **insertion order**, truncated to `limit` BEFORE the
    /// caller can sort. Returns a copy, because upstream's is shared and append-only.
    public func labelValues(name: String, limit: Int = 0) -> [String] {
        var values = lvs[name] ?? []
        if limit > 0 && values.count > limit {
            values = Array(values[0..<limit])
        }
        return values
    }

    /// Go: `All` — the postings under the empty label pair, which every series is added to.
    public func all() -> any Postings {
        postings(name: allPostingsKey().name, values: [allPostingsKey().value])
    }

    /// Go: `Postings(ctx, name, values...)` — merge the lists for whichever of `values` exist.
    ///
    /// A value with no list is SKIPPED rather than contributing an empty one, so `merge` never sees a nil.
    public func postings(name: String, values: [String]) -> any Postings {
        var res: [any Postings] = []
        let forName = m[name]
        for value in values {
            if let list = forName?[value] {
                res.append(ListPostings(list))
            }
        }
        return merge(res)
    }

    /// Go: `PostingsForAllLabelValues` — every value of one name, merged.
    ///
    /// Upstream skips a list that is EMPTY (`len(refs) > 0`), which can only happen transiently under its
    /// lock; the port keeps the check because a caller could otherwise see a difference if `delete` ever
    /// leaves an empty slice behind. It does not, and that is what makes the check a proof rather than a gap.
    public func postingsForAllLabelValues(name: String) -> any Postings {
        var its: [any Postings] = []
        for refs in (m[name] ?? [:]).values where !refs.isEmpty {
            its.append(ListPostings(refs))
        }
        return merge(its)
    }

    /// Go: `PostingsForLabelMatching` — match over the label VALUES, then merge the matches' lists.
    ///
    /// The match runs against `lvs[name]`, so in insertion order, and **if nothing matches the result is
    /// `emptyPostings()`** rather than an empty merge. That distinction is observable: `isEmptyPostingsType`
    /// compares by identity, and `intersect` short-circuits on it (see `Postings.swift`'s header).
    public func postingsForLabelMatching(
        name: String, match: (String) -> Bool
    ) -> any Postings {
        let readOnlyLabelValues = lvs[name] ?? []
        var vals: [String] = []
        for v in readOnlyLabelValues where match(v) {
            vals.append(v)
        }
        if vals.isEmpty { return emptyPostings() }

        var its: [any Postings] = []
        let e = m[name]
        for v in vals {
            if let refs = e?[v] {
                its.append(ListPostings(refs))
            }
        }
        return merge(its)
    }

    /// Go: `Iter` — call `f` for every label pair's postings, aborting on the first error.
    ///
    /// The order is Go's map order. The port iterates sorted, so that a caller which accumulates is
    /// deterministic; nothing upstream depends on the order and the corpus sorts before comparing.
    /// Exception 23.
    public func iter(_ f: (Label, any Postings) throws -> Void) throws {
        for n in m.keys.sorted() {
            for v in m[n]!.keys.sorted() {
                try f(Label(n, v), ListPostings(m[n]![v]!))
            }
        }
    }

    // MARK: - Writing

    /// Go: `Add` — every label of the series, then the empty `allPostingsKey`.
    public func add(id: SeriesRef, labels lset: Labels) {
        for l in lset {
            addFor(id: id, l)
        }
        addFor(id: id, Label(allPostingsKey().name, allPostingsKey().value))
    }

    /// Go: `addFor`.
    ///
    /// The tail is the interesting part: append, then bubble the new id back while it is smaller than its
    /// predecessor. **One pass, and it stops at the first ordered pair** — so it repairs a single
    /// out-of-order insertion into an already-sorted list and nothing more. That is the documented invariant,
    /// and it is why an unordered `MemPostings` must go through `ensureOrder()` rather than relying on this.
    private func addFor(id: SeriesRef, _ l: Label) {
        if m[l.name] == nil { m[l.name] = [:] }
        if m[l.name]![l.value] == nil {
            // A value seen for the first time joins `lvs` — which is what makes `lvs` insertion-ordered.
            lvs[l.name, default: []].append(l.value)
        }
        m[l.name]![l.value, default: []].append(id)

        if !ordered { return }

        // Repair a single order violation, walking the new element back.
        var list = m[l.name]![l.value]!
        var i = list.count - 1
        while i >= 1 {
            if list[i].rawValue >= list[i - 1].rawValue { break }
            list.swapAt(i, i - 1)
            i -= 1
        }
        m[l.name]![l.value] = list
    }

    /// Go: `EnsureOrder` — sort every list, once, and start repairing on insert from then on.
    ///
    /// Upstream shards the work across `GOMAXPROCS` goroutines in 1,024-list batches through a `sync.Pool`.
    /// None of that is observable in the result — a sorted list is a sorted list — so the port sorts inline
    /// and the `numberOfConcurrentProcesses` parameter is absent rather than ignored.
    public func ensureOrder() {
        if ordered { return }
        for (n, e) in m {
            for (v, list) in e {
                m[n]![v] = list.sorted { $0.rawValue < $1.rawValue }
            }
        }
        ordered = true
    }

    /// Go: `Delete` — remove every id in `deleted` from the lists of every label in `affected`.
    ///
    /// Three details that are load-bearing:
    ///
    ///  * `allPostingsKey` is processed **after** the affected set and unconditionally, because it is never
    ///    in `affected` and every series is in it;
    ///  * a value whose list becomes EMPTY is removed from `m[name]` entirely, and its name is recorded as
    ///    needing its `lvs` rebuilt — an empty slice is never left behind, which is what makes
    ///    `postingsForAllLabelValues`' non-empty check unreachable;
    ///  * a name whose values are all gone is removed from **both** `m` and `lvs`.
    ///
    /// `unlockWaitAndLockAgain` — the every-512-labels pause that lets readers in — is absent with the rest
    /// of the locking, and it has no effect on the result.
    public func delete(deleted: Set<SeriesRef>, affected: Set<Label>) {
        var affectedLabelNames = Set<String>()

        func process(_ l: Label) {
            guard let orig = m[l.name]?[l.value] else { return }
            var repl: [SeriesRef] = []
            repl.reserveCapacity(orig.count)
            for id in orig where !deleted.contains(id) {
                repl.append(id)
            }
            if !repl.isEmpty {
                m[l.name]![l.value] = repl
            } else {
                m[l.name]!.removeValue(forKey: l.value)
                affectedLabelNames.insert(l.name)
            }
        }

        // Sorted so the port is deterministic; the result does not depend on the order, because each label
        // pair's list is independent and `affectedLabelNames` is a set.
        for l in affected.sorted() {
            process(l)
        }
        process(Label(allPostingsKey().name, allPostingsKey().value))

        for name in affectedLabelNames.sorted() {
            if (m[name] ?? [:]).isEmpty {
                m.removeValue(forKey: name)
                lvs.removeValue(forKey: name)
                continue
            }
            // Rebuilt from `m[name]`'s keys, which upstream ranges as a MAP — so the resulting order is
            // arbitrary there. Sorted here; exception 23 records why the corpus cannot pin it.
            lvs[name] = m[name]!.keys.sorted()
        }
    }
}
