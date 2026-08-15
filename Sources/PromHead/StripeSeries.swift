//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go @ v3.13.2 — `seriesHashmap` and `stripeSeries`, the Head's series index.
//
// Two lookups, and the Head uses both: by `HeadSeriesRef` (an integer ID, the fast path) and by label set
// (via a 64-bit hash, the path an appender takes when it is handed labels rather than a ref). `stripeSeries`
// shards both, and `seriesHashmap` is what handles the case the hash does not settle.
//
// ## `seriesHashmap` is TWO maps because a 64-bit hash can collide
//
// `unique[hash]` holds the common case. When a second series hashes the same, it goes to
// `conflicts[hash]` — a list — and **each series is in exactly one of the two maps**. That is why `get` has
// to check the label sets rather than trusting the hash: a hit in `unique` whose labels differ is not the
// series you asked for, and the answer may still be in `conflicts`.
//
// The rule in `set` is the one to read twice:
//
//     if existing, found := m.unique[hash]; !found || labels.Equal(existing.labels(), s.labels())
//
// so a new series takes the `unique` slot when the slot is EMPTY or already holds the same label set (an
// update). A *different* series with the same hash leaves the incumbent in `unique` and goes to `conflicts`.
// First writer keeps the fast slot.
//
// `del` then has to undo that, and its middle case is the subtle one: deleting the series that occupies
// `unique` **promotes `conflicts[0]` into the slot** and keeps the rest. Deleting from `conflicts` filters by
// ref. Note `del` compares REFS only, never labels — it is called with a ref that is already known.
//
// ## The two shardings use the same MASK over DIFFERENT keys, and `setUnlessAlreadySet` takes both locks
//
// `series` is sharded by `ref & (size-1)`; `hashes` is sharded by `hash & (size-1)`. Same arithmetic,
// different key — so one series generally sits in two unrelated stripes, which is why `setUnlessAlreadySet`
// locks the hash stripe, writes the hash map, releases, then locks the ref stripe and writes the ref map.
// **`size` must be a power of two** for the mask to be a modulo; `HeadOptions.StripeSize`'s doc comment
// requires it and nothing upstream validates it, so the port has a `precondition`.
//
// ## What is deliberately absent
//
//   * **The locks.** `stripeLock` is a `sync.RWMutex` padded with `[40]byte` to keep locks off one cache
//     line, and `paddedAtomicInt32` is padded with `[60]byte` for the same reason. Both are pure contention
//     engineering with no observable behaviour, and the port has no concurrency yet — see `Isolation.swift`
//     on why a lock here would be a claim about a design that has not been made. The *padding* is worth
//     recording rather than reproducing: it is a statement about cache lines, not about semantics.
//   * **`gc`, `gcStaleSeries` and `iterForDeletion`.** All three walk `memSeries`'s chunk state, which
//     arrives with the rest of `memSeries`. They are the next step, not this one.
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromLabels

/// Go: `DefaultStripeSize` — `1 << 14`.
public let defaultStripeSize = 1 << 14

/// Go: `memSeries`, as much of its IDENTITY as the series index needs.
///
/// **This is a partial port and says so.** `stripeSeries` and `seriesHashmap` only ever read a series' `ref`
/// and its labels, so those are what is here; the chunk state (`headChunks`, `mmappedChunks`, the append
/// bookkeeping and `txRing`) arrives with `memSeries.append`, and `stripeSeries.gc` waits for it. Growing this
/// type is the next step of §7f.
public final class MemSeries {
    /// Go: `ref` — the Head's own ID for the series, and the key of `stripeSeries.series`.
    public let ref: HeadSeriesRef
    /// Go: `lset`, reached through `labels()`.
    public let lset: Labels

    public init(ref: HeadSeriesRef, labels lset: Labels) {
        self.ref = ref
        self.lset = lset
    }

    /// Go: `labels()`.
    public func labels() -> Labels { lset }
}

/// Go: `seriesHashmap` — find a `memSeries` by label set, tolerating hash collisions.
public struct SeriesHashmap {
    /// Go: `unique` — one series per hash, the common case.
    var unique: [UInt64: MemSeries] = [:]
    /// Go: `conflicts` — the extras when a hash is shared. **Nil until needed**, initialised on demand in
    /// `set`, exactly as upstream does.
    var conflicts: [UInt64: [MemSeries]]?

    public init() {}

    /// Go: `get`.
    ///
    /// The label comparison on the `unique` hit is not defensive: a colliding series legitimately sits there,
    /// and the one being asked for may be in `conflicts`. Skipping the check would return the wrong series.
    public func get(hash: UInt64, labels lset: Labels) -> MemSeries? {
        if let s = unique[hash], s.labels() == lset {
            return s
        }
        for s in conflicts?[hash] ?? [] where s.labels() == lset {
            return s
        }
        return nil
    }

    /// Go: `set`.
    ///
    /// Takes the `unique` slot when it is empty or already holds this label set; otherwise the incumbent keeps
    /// it and this series joins `conflicts`, replacing an equal-labelled entry **in place** if one is there.
    public mutating func set(hash: UInt64, _ s: MemSeries) {
        if let existing = unique[hash] {
            if existing.labels() == s.labels() {
                unique[hash] = s
                return
            }
        } else {
            unique[hash] = s
            return
        }
        if conflicts == nil { conflicts = [:] }
        var l = conflicts![hash] ?? []
        for i in l.indices where l[i].labels() == s.labels() {
            l[i] = s
            conflicts![hash] = l
            return
        }
        l.append(s)
        conflicts![hash] = l
    }

    /// Go: `del` — by REF, not by labels.
    ///
    /// Three cases, and the middle one is the interesting one: removing the series that holds `unique`
    /// **promotes `conflicts[0]`** into the slot and keeps `conflicts[1...]`. An unknown hash returns without
    /// touching anything.
    public mutating func del(hash: UInt64, ref: HeadSeriesRef) {
        var rem: [MemSeries] = []
        guard let uniqueSeries = unique[hash] else {
            // The hash is not stored at all.
            return
        }
        if uniqueSeries.ref == ref {
            let c = conflicts?[hash] ?? []
            if c.isEmpty {
                // Exactly one series with this hash was stored.
                unique.removeValue(forKey: hash)
                return
            }
            unique[hash] = c[0]  // First remaining series goes in `unique`.
            rem = Array(c.dropFirst())  // Keep the rest.
        } else {
            // Somewhere in `conflicts`. Keep the ones that do not match.
            for s in conflicts?[hash] ?? [] where s.ref != ref {
                rem.append(s)
            }
        }
        if rem.isEmpty {
            conflicts?.removeValue(forKey: hash)
        } else {
            if conflicts == nil { conflicts = [:] }
            conflicts![hash] = rem
        }
    }
}

/// Go: `stripeSeries` — series by ref and by label hash, both sharded.
///
/// Not locked; see the file header. `size` **must be a power of two**, because both shardings are a bitmask.
public final class StripeSeries {

    let size: Int
    /// Go: `series` — sharded by REF.
    var series: [[HeadSeriesRef: MemSeries]]
    /// Go: `hashes` — sharded by label HASH. A different sharding of the same series.
    var hashes: [SeriesHashmap]
    /// Go: `mmapReady` — per-stripe count of series with two or more head chunks, i.e. ready to be mmapped.
    /// Padded to 64 bytes upstream to avoid false sharing; the padding is contention engineering, not
    /// behaviour.
    var mmapReady: [Int32]
    let seriesLifecycleCallback: any SeriesLifecycleCallback

    /// Go: `newStripeSeries`.
    public init(
        stripeSize: Int = defaultStripeSize,
        seriesCallback: any SeriesLifecycleCallback = NoopSeriesLifecycleCallback()
    ) {
        precondition(
            stripeSize > 0 && (stripeSize & (stripeSize - 1)) == 0,
            "stripeSize must be a power of two: both shardings are a bitmask, and HeadOptions.StripeSize's "
                + "doc comment requires it while nothing upstream validates it")
        self.size = stripeSize
        self.series = Array(repeating: [:], count: stripeSize)
        // `conflicts` stays nil per shard until `set` needs it, as upstream's comment says.
        self.hashes = Array(repeating: SeriesHashmap(), count: stripeSize)
        self.mmapReady = Array(repeating: 0, count: stripeSize)
        self.seriesLifecycleCallback = seriesCallback
    }

    /// Go: `refStripe` — `ref & (size-1)`.
    func refStripe(_ ref: HeadSeriesRef) -> Int {
        Int(ref.rawValue & UInt64(size - 1))
    }

    /// The hash sharding.
    ///
    /// **This is the SAME function as `refStripe` — only the key differs.** An earlier version of this comment
    /// said the two were independent, which reads as "different arithmetic" and is wrong: both are
    /// `x & (size-1)`. A control that routed `hashStripe` through `refStripe` survived the sweep and that is
    /// what corrected it. What is genuinely independent is *which value* is masked — a series is filed under
    /// `ref & (size-1)` in `series` and under `hash & (size-1)` in `hashes`, so it generally sits in two
    /// unrelated stripes, and that is why `setUnlessAlreadySet` has to touch both.
    ///
    /// It stays a separate function because upstream writes the hash mask inline at each of its three call
    /// sites while giving the ref one a name, and keeping both makes each call site say which key it is using.
    func hashStripe(_ hash: UInt64) -> Int {
        Int(hash & UInt64(size - 1))
    }

    /// Go: `incMmapReady` / `decMmapReady`.
    public func incMmapReady(_ ref: HeadSeriesRef) { mmapReady[refStripe(ref)] += 1 }
    public func decMmapReady(_ ref: HeadSeriesRef) { mmapReady[refStripe(ref)] -= 1 }
    /// The total across stripes, which is what the Head reports.
    public var mmapReadyTotal: Int32 { mmapReady.reduce(0, +) }

    /// Go: `getByID` — the preferred lookup, per upstream's comment on `stripeSeries`.
    public func getByID(_ id: HeadSeriesRef) -> MemSeries? {
        series[refStripe(id)][id]
    }

    /// Go: `getByHash`.
    public func getByHash(hash: UInt64, labels lset: Labels) -> MemSeries? {
        hashes[hashStripe(hash)].get(hash: hash, labels: lset)
    }

    /// Go: `setUnlessAlreadySet` — returns the EXISTING series and `false` when one is already there.
    ///
    /// The two writes go to different stripes (hash, then ref), which is the whole reason this is one function
    /// rather than two: upstream needs the pair to happen under the right locks in the right order.
    @discardableResult
    public func setUnlessAlreadySet(
        hash: UInt64, labels lset: Labels, _ newSeries: MemSeries
    ) -> (series: MemSeries, created: Bool) {
        let i = hashStripe(hash)
        if let prev = hashes[i].get(hash: hash, labels: lset) {
            return (prev, false)
        }
        hashes[i].set(hash: hash, newSeries)

        let stripe = refStripe(newSeries.ref)
        series[stripe][newSeries.ref] = newSeries

        return (newSeries, true)
    }

    /// Go: `postCreation`.
    public func postCreation(labels lset: Labels) {
        seriesLifecycleCallback.postCreation(lset)
    }
}

/// Go: `SeriesLifecycleCallback`.
///
/// Upstream's own comment: *"It is always a no-op in Prometheus and mainly meant for external users who import
/// TSDB."* So the protocol is ported and nothing is built on it — see §7f's plan.
public protocol SeriesLifecycleCallback {
    /// A non-nil error means the series must not be created.
    func preCreation(_ labels: Labels) throws
    func postCreation(_ labels: Labels)
    func postDeletion(_ series: [HeadSeriesRef: Labels])
}

/// Go: `noopSeriesLifecycleCallback` — what every Prometheus `Head` actually runs.
public struct NoopSeriesLifecycleCallback: SeriesLifecycleCallback {
    public init() {}
    public func preCreation(_: Labels) throws {}
    public func postCreation(_: Labels) {}
    public func postDeletion(_: [HeadSeriesRef: Labels]) {}
}
