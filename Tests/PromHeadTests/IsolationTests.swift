//===----------------------------------------------------------------------------------------------===//
// `tsdb/isolation.go`'s semantics, asserted directly.
//
// **These are NOT differential.** `isolation`, `isolationState` and `txRing` are all unexported upstream, and
// nothing on `Head`'s exported surface reaches them until `head_read.go` (§7g) makes a Head queryable — so
// there is no exported entry point to drive from the oracle. §5's question, asked and answered honestly.
//
// Every expectation below is therefore traceable to a specific line or comment in upstream's source — and,
// more usefully, **every one of them was verified against real Go rather than read off the source.**
// `isolation.go` imports only `math` and `sync`, so it copies into a standalone package unchanged: change its
// `package tsdb` line, drop a `main.go` beside it, and the unexported types are directly callable. That probe
// confirmed all of the non-obvious answers below — the first ID being 1, `newAppendID` returning a post-insert
// watermark of `(1,1)` then `(2,1)`, the sentinel fallback making `lowWatermark == lastAppendID` with nothing
// open, the OLDEST read pinning it, `TraverseOpenReads` visiting newest-first, the growth un-wrap producing
// `[3,4,5,6,7]`, and a zero-capacity ring growing to 4. This is the HANDOFF's "write a five-line Go program in
// /tmp" habit, and it is what makes these assertions evidence instead of a plausible reading.
//
// §7g is where this becomes differentially pinned; PORTING.md's warning that "no Go counterpart" is a claim
// about the FILE rather than the BEHAVIOUR applies, and this file is the note to revisit rather than a settled
// state.
//===----------------------------------------------------------------------------------------------===//

import Testing

@testable import PromHead

@Suite("head: append isolation")
struct IsolationTests {

    /// `newAppendID`'s first ID is **1** — the sentinel starts at 0 and is pre-incremented — so an appendID of
    /// 0 means "isolation disabled" rather than "the first append". A port that returned 0 first would make
    /// the two indistinguishable.
    @Test("the first append ID is 1, and 0 means disabled")
    func firstAppendIDIsOne() {
        let iso = Isolation(disabled: false)
        #expect(iso.lastAppendID() == 0)
        #expect(iso.newAppendID(minTime: 0).appendID == 1)
        #expect(iso.newAppendID(minTime: 0).appendID == 2)
        #expect(iso.lastAppendID() == 2)

        let off = Isolation(disabled: true)
        #expect(off.newAppendID(minTime: 0) == (0, 0))
        #expect(off.lastAppendID() == 0)
        #expect(off.lowWatermark() == 0)
    }

    /// `lastAppendID` reads the SENTINEL's own field, so closing every appender does NOT reset it. That is the
    /// property that makes IDs monotonic across the Head's life.
    @Test("closing every append leaves the counter where it was")
    func counterSurvivesCloses() {
        let iso = Isolation(disabled: false)
        let a = iso.newAppendID(minTime: 0).appendID
        let b = iso.newAppendID(minTime: 0).appendID
        iso.closeAppend(a)
        iso.closeAppend(b)
        #expect(iso.lastAppendID() == 2)
        // And the next ID continues rather than restarting.
        #expect(iso.newAppendID(minTime: 0).appendID == 3)
        // An unknown id is silently ignored, which makes a double close harmless.
        iso.closeAppend(999)
        iso.closeAppend(a)
        #expect(iso.lastAppendID() == 3)
    }

    /// With no open appenders, `lowWatermark` is the LAST ISSUED id, because `appendsOpenList.next` is the
    /// sentinel itself — upstream's "Lowest appendID from appenders, or lastAppendId". With one open, it is
    /// that one's id.
    @Test("the low watermark falls back to the last issued id when nothing is open")
    func lowWatermarkFallsBackToSentinel() {
        let iso = Isolation(disabled: false)
        #expect(iso.lowWatermark() == 0)

        let a = iso.newAppendID(minTime: 0).appendID
        // One open appender: it is the lowest.
        #expect(iso.lowWatermark() == a)
        let b = iso.newAppendID(minTime: 0).appendID
        #expect(iso.lowWatermark() == a)

        // Closing the LOWER one moves the watermark up to the remaining one.
        iso.closeAppend(a)
        #expect(iso.lowWatermark() == b)
        // Closing the last one leaves the sentinel, i.e. the last issued id.
        iso.closeAppend(b)
        #expect(iso.lowWatermark() == b)
    }

    /// `newAppendID` returns the watermark computed AFTER its own insertion, so the second element of the pair
    /// already accounts for the append being opened. With no prior appends that makes it equal to the new id.
    @Test("newAppendID's returned watermark includes the append it just opened")
    func newAppendIDReturnsPostInsertWatermark() {
        let iso = Isolation(disabled: false)
        let first = iso.newAppendID(minTime: 0)
        #expect(first == (1, 1))
        let second = iso.newAppendID(minTime: 0)
        // Still 1: the first append is open and is the lowest.
        #expect(second == (2, 1))
    }

    /// `State()` captures the max as the sentinel's id and the incomplete set as the currently open ids, and
    /// **it runs in full even when isolation is disabled** — upstream's comment: head truncation has to wait
    /// for overlapping reads regardless.
    @Test("State captures the open appends, and runs even when disabled")
    func stateCapturesOpenAppends() {
        let iso = Isolation(disabled: false)
        let a = iso.newAppendID(minTime: 5).appendID
        let b = iso.newAppendID(minTime: 7).appendID

        let s = iso.state(mint: 10, maxt: 20)
        #expect(s.maxAppendID == b)
        #expect(s.incompleteAppends == [a, b])
        #expect(s.lowWatermark == a)
        #expect(s.mint == 10)
        #expect(s.maxt == 20)
        #expect(!s.isolationDisabled)
        s.close()

        // Disabled: no write tracking, but the read state still exists and still carries the range.
        let off = Isolation(disabled: true)
        let so = off.state(mint: 1, maxt: 2)
        #expect(so.mint == 1)
        #expect(so.maxt == 2)
        #expect(so.isolationDisabled)
        #expect(so.incompleteAppends.isEmpty)
        so.close()
    }

    /// The low watermark comes from the **OLDEST** open read, not the newest. `State` links in at
    /// `readsOpen.next`, so `prev` is the oldest — reading `next` instead would let the Head drop append IDs a
    /// long-running query still needs.
    @Test("an open read pins the watermark, and the oldest read wins")
    func oldestReadPinsWatermark() {
        let iso = Isolation(disabled: false)
        let a = iso.newAppendID(minTime: 0).appendID
        iso.closeAppend(a)

        // First read, taken while the watermark is 1.
        let older = iso.state(mint: 0, maxt: 0)
        #expect(older.lowWatermark == 1)

        // More appends happen and complete, so the bare watermark would move up.
        let b = iso.newAppendID(minTime: 0).appendID
        iso.closeAppend(b)
        let newer = iso.state(mint: 0, maxt: 0)
        #expect(newer.lowWatermark == 2)

        // But the OLDEST open read holds it down.
        #expect(iso.lowWatermark() == 1)

        // Close the older one and the newer one takes over.
        older.close()
        #expect(iso.lowWatermark() == 2)
        newer.close()
        // With no reads open it falls back to the appenders/sentinel.
        #expect(iso.lowWatermark() == 2)
    }

    /// `lowestAppendTime` is `Int64.max` with nothing open, and the minimum `minTime` otherwise.
    @Test("lowestAppendTime is MaxInt64 when nothing is open")
    func lowestAppendTime() {
        let iso = Isolation(disabled: false)
        #expect(iso.lowestAppendTime() == Int64.max)

        let a = iso.newAppendID(minTime: 100).appendID
        let b = iso.newAppendID(minTime: 40).appendID
        #expect(iso.lowestAppendTime() == 40)
        iso.closeAppend(b)
        #expect(iso.lowestAppendTime() == 100)
        iso.closeAppend(a)
        #expect(iso.lowestAppendTime() == Int64.max)
    }

    /// `TraverseOpenReads` stops early when the closure returns false, and visits newest-first because reads
    /// are linked in at `next`.
    @Test("TraverseOpenReads visits newest first and stops early")
    func traverseOpenReads() {
        let iso = Isolation(disabled: false)
        let s1 = iso.state(mint: 1, maxt: 1)
        let s2 = iso.state(mint: 2, maxt: 2)
        let s3 = iso.state(mint: 3, maxt: 3)

        var seen: [Int64] = []
        iso.traverseOpenReads { s in
            seen.append(s.mint)
            return true
        }
        #expect(seen == [3, 2, 1])

        // Early exit.
        var count = 0
        iso.traverseOpenReads { _ in
            count += 1
            return false
        }
        #expect(count == 1)

        s1.close()
        s2.close()
        s3.close()
        var after = 0
        iso.traverseOpenReads { _ in
            after += 1
            return true
        }
        #expect(after == 0)
    }

    // MARK: - txRing

    /// The ring grows by DOUBLING and un-wraps as it does: the copy takes `[first...]` then `[..<first]`. A
    /// plain append would leave the halves in the wrong order — the same two-segment copy the look-back ring
    /// needed, where perturbing it into the "obvious" logical-order copy broke 6 of 43 fixture cases.
    @Test("the ring grows by doubling and un-wraps in the right order")
    func ringGrowthUnwraps() {
        var r = TxRing(capacity: 4)
        for id in UInt64(1)...4 { r.add(id) }
        #expect(r.count == 4)

        // Drop the first two, then add two more so the live range WRAPS.
        r.cleanupAppendIDsBelow(3)
        #expect(r.count == 2)
        r.add(5)
        r.add(6)
        #expect(r.count == 4)

        // Now force a growth while wrapped, and read back in logical order.
        r.add(7)
        #expect(r.count == 5)
        var it = r.iterator()
        var got: [UInt64] = []
        for _ in 0..<r.count {
            got.append(it.at())
            it.next()
        }
        #expect(got == [3, 4, 5, 6, 7])
    }

    /// A ring created with capacity 0 must work rather than divide by zero: `newLen == 0` becomes 4.
    @Test("a zero-capacity ring grows to four")
    func zeroCapacityRing() {
        var r = TxRing(capacity: 0)
        r.add(1)
        #expect(r.count == 1)
        #expect(r.txIDs.count == 4)
        for id in UInt64(2)...4 { r.add(id) }
        #expect(r.count == 4)
        r.add(5)
        #expect(r.count == 5)
        #expect(r.txIDs.count == 8)

        var it = r.iterator()
        var got: [UInt64] = []
        for _ in 0..<r.count {
            got.append(it.at())
            it.next()
        }
        #expect(got == [1, 2, 3, 4, 5])
    }

    /// `cleanupAppendIDsBelow` stops at the first id **at or above** the bound rather than scanning, which is
    /// correct only because ids are added in increasing order.
    @Test("cleanup drops a prefix and stops at the first id at or above the bound")
    func cleanupDropsPrefix() {
        var r = TxRing(capacity: 8)
        for id in UInt64(1)...6 { r.add(id) }

        // Nothing below 1.
        r.cleanupAppendIDsBelow(1)
        #expect(r.count == 6)
        // Everything below 4 goes.
        r.cleanupAppendIDsBelow(4)
        #expect(r.count == 3)
        var it = r.iterator()
        #expect(it.at() == 4)
        // A bound above everything empties it.
        r.cleanupAppendIDsBelow(100)
        #expect(r.count == 0)
        // And cleanup on an empty ring is harmless.
        r.cleanupAppendIDsBelow(100)
        #expect(r.count == 0)
        // An empty-capacity ring returns early rather than dividing by zero.
        var empty = TxRing(capacity: 0)
        empty.cleanupAppendIDsBelow(5)
        #expect(empty.count == 0)
    }

    /// The iterator **does not terminate** — upstream's comment says so twice. It wraps forever, so the caller
    /// bounds the walk by the count. Asserted because a port that "fixed" it would be adding behaviour.
    @Test("the ring iterator wraps forever rather than ending")
    func iteratorDoesNotTerminate() {
        var r = TxRing(capacity: 2)
        r.add(7)
        r.add(8)
        var it = r.iterator()
        #expect(it.at() == 7)
        it.next()
        #expect(it.at() == 8)
        it.next()
        // Wrapped, not ended.
        #expect(it.at() == 7)
        it.next()
        #expect(it.at() == 8)
    }
}
