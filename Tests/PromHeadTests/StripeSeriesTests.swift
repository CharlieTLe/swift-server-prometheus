//===----------------------------------------------------------------------------------------------===//
// `seriesHashmap` and `stripeSeries` — the Head's series index.
//
// **Not differential, and verified against a Go probe instead**, the same way `IsolationTests` is. `head.go`
// cannot be lifted into a probe package wholesale — it imports half of Prometheus — but `seriesHashmap` can:
// it touches only `memSeries.ref`, `memSeries.labels()` and `labels.Equal`, so reducing `memSeries` to two
// fields and `labels.Equal` to a string compare leaves the three methods **verbatim**. That probe produced
// every expectation below, and three of them are worth naming because a reading of the source could plausibly
// go the other way:
//
//   * `set` gives the `unique` slot to the FIRST writer. A second series with the same hash and different
//     labels does not displace it — the incumbent stays and the newcomer joins `conflicts`.
//   * `del` on the series holding `unique` **promotes `conflicts[0]` into the slot** rather than clearing it.
//   * when a conflict list empties, the `conflicts` KEY is deleted rather than left holding an empty array.
//     `del C (in conflicts)` in the probe shows the key going absent.
//
// §7g is where the Head becomes queryable and this becomes differentially pinned.
//===----------------------------------------------------------------------------------------------===//

import PromChunks
import PromLabels
import Testing

@testable import PromHead

@Suite("head: the series index")
struct StripeSeriesTests {

    static func ref(_ n: UInt64) -> HeadSeriesRef { HeadSeriesRef(rawValue: n) }
    static func series(_ n: UInt64, _ name: String) -> MemSeries {
        MemSeries(ref: ref(n), labels: Labels([Label("l", name)]))
    }
    static func lset(_ name: String) -> Labels { Labels([Label("l", name)]) }

    /// `set` gives the `unique` slot to the FIRST writer; a colliding series with different labels leaves the
    /// incumbent alone and joins `conflicts`. Probe: `set A` → `unique=1/A`, then `set B` → `unique=1/A,
    /// conflicts=[2/B]`.
    @Test("the first writer keeps the unique slot and collisions queue behind it")
    func firstWriterKeepsUnique() {
        var m = SeriesHashmap()
        let a = Self.series(1, "A")
        let b = Self.series(2, "B")
        let c = Self.series(3, "C")

        m.set(hash: 7, a)
        #expect(m.unique[7]?.ref == Self.ref(1))
        // `conflicts` is nil until it is needed, exactly as upstream initialises it on demand.
        #expect(m.conflicts == nil)

        m.set(hash: 7, b)
        #expect(m.unique[7]?.ref == Self.ref(1))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(2)])

        m.set(hash: 7, c)
        #expect(m.unique[7]?.ref == Self.ref(1))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(2), Self.ref(3)])
    }

    /// Setting the SAME label set again replaces in place — in `unique` if that is where it lives, and at its
    /// existing index in `conflicts` otherwise, which preserves the order. Probe: `set B'` leaves
    /// `conflicts=[9/B 3/C]`, not `[3/C 9/B]`.
    @Test("re-setting a label set replaces in place and keeps conflict order")
    func reSetReplacesInPlace() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.set(hash: 7, Self.series(2, "B"))
        m.set(hash: 7, Self.series(3, "C"))

        m.set(hash: 7, Self.series(9, "B"))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(9), Self.ref(3)])
        m.set(hash: 7, Self.series(8, "A"))
        #expect(m.unique[7]?.ref == Self.ref(8))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(9), Self.ref(3)])
    }

    /// `get` must check the labels on a `unique` hit and fall through to `conflicts` when they differ — a
    /// colliding series legitimately occupies the slot.
    @Test("get falls through from a colliding unique entry to conflicts")
    func getFallsThrough() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.set(hash: 7, Self.series(2, "B"))
        m.set(hash: 7, Self.series(3, "C"))

        #expect(m.get(hash: 7, labels: Self.lset("A"))?.ref == Self.ref(1))
        #expect(m.get(hash: 7, labels: Self.lset("B"))?.ref == Self.ref(2))
        #expect(m.get(hash: 7, labels: Self.lset("C"))?.ref == Self.ref(3))
        #expect(m.get(hash: 7, labels: Self.lset("D")) == nil)
        // A hash that was never stored.
        #expect(m.get(hash: 99, labels: Self.lset("A")) == nil)
    }

    /// **The middle case of `del`.** Removing the series that holds `unique` promotes `conflicts[0]` into the
    /// slot and keeps the rest. Probe: `del A (unique holder)` → `unique=2/B, conflicts=[3/C]`.
    @Test("deleting the unique holder promotes the first conflict")
    func delPromotesFirstConflict() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.set(hash: 7, Self.series(2, "B"))
        m.set(hash: 7, Self.series(3, "C"))

        m.del(hash: 7, ref: Self.ref(1))
        #expect(m.unique[7]?.ref == Self.ref(2))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(3)])

        // Deleting from `conflicts` empties the list, and the KEY goes with it.
        m.del(hash: 7, ref: Self.ref(3))
        #expect(m.unique[7]?.ref == Self.ref(2))
        #expect(m.conflicts?[7] == nil)

        // Deleting the last one clears `unique` too.
        m.del(hash: 7, ref: Self.ref(2))
        #expect(m.unique[7] == nil)
    }

    /// The promotion also applies with exactly one conflict, and then the list is empty so the key is dropped.
    @Test("deleting the unique holder with one conflict promotes and drops the key")
    func delWithSingleConflict() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.set(hash: 7, Self.series(2, "B"))
        m.del(hash: 7, ref: Self.ref(1))
        #expect(m.unique[7]?.ref == Self.ref(2))
        #expect(m.conflicts?[7] == nil)
    }

    /// An unknown hash and an unknown ref both leave the map untouched — `del` returns on the missing `unique`
    /// lookup, and the conflict filter simply keeps everything.
    @Test("deleting an unknown hash or ref changes nothing")
    func delUnknown() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.set(hash: 7, Self.series(2, "B"))

        m.del(hash: 99, ref: Self.ref(1))
        #expect(m.unique[7]?.ref == Self.ref(1))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(2)])

        m.del(hash: 7, ref: Self.ref(42))
        #expect(m.unique[7]?.ref == Self.ref(1))
        #expect(m.conflicts?[7]?.map(\.ref) == [Self.ref(2)])
    }

    /// A series with no conflicts deletes cleanly.
    @Test("deleting the only series clears the slot")
    func delOnlySeries() {
        var m = SeriesHashmap()
        m.set(hash: 7, Self.series(1, "A"))
        m.del(hash: 7, ref: Self.ref(1))
        #expect(m.unique[7] == nil)
        #expect(m.conflicts?[7] == nil)
    }

    // MARK: - stripeSeries

    /// The two shardings use DIFFERENT keys — `series` by ref, `hashes` by hash — so a series is generally in
    /// two unrelated stripes. Asserted because sharding both by the ref would still pass every lookup test
    /// while changing which lock protects what, and upstream's `setUnlessAlreadySet` exists to take both.
    @Test("series shard by ref and hashes shard by hash, independently")
    func twoShardings() {
        let s = StripeSeries(stripeSize: 8)
        // 9 & 7 == 1, and 12 & 7 == 4: a series with ref 9 and hash 12 lands in different stripes.
        #expect(s.refStripe(Self.ref(9)) == 1)
        #expect(s.hashStripe(12) == 4)
        // The mask IS a modulo for a power-of-two size.
        #expect(s.refStripe(Self.ref(8)) == 0)
        #expect(s.refStripe(Self.ref(15)) == 7)
        #expect(s.hashStripe(16) == 0)
    }

    /// `setUnlessAlreadySet` returns the EXISTING series and `false` rather than overwriting, which is what
    /// makes it safe for two appenders racing to create the same series.
    @Test("setUnlessAlreadySet returns the incumbent rather than replacing it")
    func setUnlessAlreadySetKeepsIncumbent() {
        let s = StripeSeries(stripeSize: 8)
        let first = Self.series(1, "A")
        let r1 = s.setUnlessAlreadySet(hash: 7, labels: Self.lset("A"), first)
        #expect(r1.created)
        #expect(r1.series.ref == Self.ref(1))

        // Same labels, different ref: the incumbent wins and nothing is created.
        let second = Self.series(2, "A")
        let r2 = s.setUnlessAlreadySet(hash: 7, labels: Self.lset("A"), second)
        #expect(!r2.created)
        #expect(r2.series.ref == Self.ref(1))
        // And the ref map never learned about the loser.
        #expect(s.getByID(Self.ref(2)) == nil)
        #expect(s.getByID(Self.ref(1))?.ref == Self.ref(1))

        // A colliding hash with DIFFERENT labels is a real creation.
        let other = Self.series(3, "B")
        let r3 = s.setUnlessAlreadySet(hash: 7, labels: Self.lset("B"), other)
        #expect(r3.created)
        #expect(s.getByHash(hash: 7, labels: Self.lset("B"))?.ref == Self.ref(3))
        #expect(s.getByHash(hash: 7, labels: Self.lset("A"))?.ref == Self.ref(1))
    }

    /// Both lookups find the same series, and a miss on either is nil rather than a trap.
    @Test("getByID and getByHash agree, and miss cleanly")
    func lookupsAgree() {
        let s = StripeSeries(stripeSize: 16)
        let a = Self.series(100, "A")
        s.setUnlessAlreadySet(hash: 1234, labels: Self.lset("A"), a)

        #expect(s.getByID(Self.ref(100))?.ref == Self.ref(100))
        #expect(s.getByHash(hash: 1234, labels: Self.lset("A"))?.ref == Self.ref(100))
        #expect(s.getByID(Self.ref(101)) == nil)
        #expect(s.getByHash(hash: 1234, labels: Self.lset("Z")) == nil)
        #expect(s.getByHash(hash: 4321, labels: Self.lset("A")) == nil)
    }

    /// The mmap-ready counter is per-stripe and sharded by REF, so two series in the same stripe share a
    /// counter and the Head's total is the sum.
    @Test("the mmap-ready counter is per-stripe and sums")
    func mmapReadyCounter() {
        let s = StripeSeries(stripeSize: 4)
        // 1 & 3 == 1 and 5 & 3 == 1: same stripe.
        #expect(s.refStripe(Self.ref(1)) == s.refStripe(Self.ref(5)))
        s.incMmapReady(Self.ref(1))
        s.incMmapReady(Self.ref(5))
        s.incMmapReady(Self.ref(2))
        #expect(s.mmapReadyTotal == 3)
        s.decMmapReady(Self.ref(1))
        #expect(s.mmapReadyTotal == 2)
        // It is a plain counter, so it can go negative — nothing upstream guards it either.
        s.decMmapReady(Self.ref(2))
        s.decMmapReady(Self.ref(2))
        #expect(s.mmapReadyTotal == 0)
    }

    /// `SeriesLifecycleCallback` is a no-op in Prometheus, and `postCreation` reaches it. Asserted only so the
    /// wiring exists; §7f's plan says not to build anything on it.
    @Test("the lifecycle callback is reached")
    func lifecycleCallback() {
        final class Recorder: SeriesLifecycleCallback {
            var created: [Labels] = []
            func preCreation(_: Labels) throws {}
            func postCreation(_ l: Labels) { created.append(l) }
            func postDeletion(_: [HeadSeriesRef: Labels]) {}
        }
        let rec = Recorder()
        let s = StripeSeries(stripeSize: 2, seriesCallback: rec)
        s.postCreation(labels: Self.lset("A"))
        #expect(rec.created.count == 1)
    }
}
