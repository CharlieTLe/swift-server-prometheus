//===----------------------------------------------------------------------===//
// Ported from tsdb/isolation.go @ v3.13.2 — the Head's append isolation.
//
// **Why this is the first file of the Head and not an optional extra:** `defaultIsolationDisabled` is
// `false` (head.go:65), so `newIsolation(false)` is what every `NewHead` runs. Every `memSeries.append`
// takes an `appendID` from here and every read takes an `isolationState`, so there is no version of the Head
// core that does not need it. §7f's scoping plan calls this out as the cost that surprises people.
//
// ## What it is for
//
// A query must not see a half-committed append. `isolation` hands each appender a monotonically increasing
// `appendID`, records which are still open, and hands each reader an `isolationState` naming the highest ID
// it may see plus the set of IDs that were still in flight when it started. A sample tagged with an ID above
// the maximum, or with one of the incomplete IDs, is invisible to that reader.
//
// ## The sentinel node doubles as the counter, and that is load-bearing
//
// Both lists are circular with a sentinel, and `appendsOpenList` — the sentinel — stores the **last issued
// appendID in its own `appendID` field**. So:
//
//   * `lastAppendID()` reads the SENTINEL, not any real appender;
//   * `appendsOpenList.next.appendID` is "the lowest open appender's ID, **or** the last issued ID if there
//     are none" — because with no appenders `next` points back at the sentinel. Upstream's comment says
//     exactly that, and it is the whole of `lowWatermarkLocked`'s second branch.
//
// A port that gave the counter its own field would have to special-case the empty list in two places, and
// would get `State()`'s `lowWatermark` wrong for a Head with no open appends — which is the common case.
//
// ## Insertion order decides which read the low watermark comes from
//
// `State()` links a new read in at `readsOpen.next`, so `next` is the NEWEST open read and `prev` is the
// OLDEST. `lowWatermarkLocked` returns `readsOpen.prev.lowWatermark` — the oldest read's — because that is
// the one still needing old append IDs kept around. Reading `next` instead would let the Head garbage-collect
// IDs a long-running query still depends on.
//
// ## Disabling isolation does NOT stop tracking reads
//
// `newAppendID` and `closeAppend` return early when disabled, and `lowWatermark` answers 0 — but `State()`
// runs in full either way. Upstream's comment gives the reason: head truncation has to wait for reads
// overlapping its range to finish, and that is true whether or not writes are isolated. So `disabled` means
// "writes are not tracked", not "nothing is tracked".
//
// ## What is deliberately absent
//
//   * **The mutexes.** `appendMtx` and `readMtx`, and the documented rule that `appendMtx` is taken first.
//     The port's Head is single-threaded for now and its concurrency story is that slice's to decide; a lock
//     here would be a claim about a design that has not been made. The lock ORDER is recorded in this comment
//     rather than in code so it is not lost.
//   * **`sync.Pool`** for `isolationAppender` — PORTING.md's standing exception.
//
// ## How this is tested, and why that is not a differential corpus
//
// `isolation`, `isolationState` and `txRing` are all **unexported** upstream, and nothing on `Head`'s
// exported surface reaches them until `head_read.go` (§7g) makes a Head queryable. So there is no exported
// entry point to drive from the oracle — the §5 question, asked and answered honestly. The tests here encode
// upstream's documented semantics directly, and §7g is where this becomes differentially pinned. That is a
// note to revisit, not a settled state: quirk 52's shape, and PORTING.md's own warning that "no Go
// counterpart" is a claim about the FILE rather than about the BEHAVIOUR.
//===----------------------------------------------------------------------===//

/// Go: `isolationState` — what one reader is allowed to see.
///
/// A node in `isolation`'s circular doubly-linked list of open reads. `close()` unlinks it, and a reader that
/// never closes pins the low watermark forever, which is what stops the Head garbage-collecting append IDs.
public final class IsolationState {
    /// Go: `maxAppendID` — appends above this are ignored.
    public internal(set) var maxAppendID: UInt64 = 0
    /// Go: `incompleteAppends` — in flight when this read started, and therefore also ignored.
    public internal(set) var incompleteAppends: Set<UInt64> = []
    /// Go: `lowWatermark` — the lowest of `incompleteAppends`/`maxAppendID`.
    public internal(set) var lowWatermark: UInt64 = 0
    /// Go: `mint`, `maxt` — the read's time range, which head truncation consults.
    public internal(set) var mint: Int64 = 0
    public internal(set) var maxt: Int64 = 0

    weak var isolation: Isolation?
    /// The list links. `next` is newer, `prev` is older; see the file header on why that matters.
    var next: IsolationState?
    var prev: IsolationState?

    init() {}

    /// Go: `isolationState.Close`.
    public func close() {
        next?.prev = prev
        prev?.next = next
    }

    /// Go: `isolationState.IsolationDisabled`.
    public var isolationDisabled: Bool { isolation?.disabled ?? false }
}

/// Go: `isolationAppender` — one open append, in a circular doubly-linked list.
final class IsolationAppender {
    var appendID: UInt64 = 0
    var minTime: Int64 = 0
    var prev: IsolationAppender?
    var next: IsolationAppender?
    init() {}
}

/// Go: `isolation` — the Head's global isolation state.
public final class Isolation {

    /// Go: `appendsOpen`.
    private var appendsOpen: [UInt64: IsolationAppender] = [:]
    /// Go: `appendsOpenList` — the SENTINEL, whose own `appendID` holds the last issued ID. See the header.
    private let appendsOpenList = IsolationAppender()
    /// Go: `readsOpen` — the sentinel of the open-reads list.
    private let readsOpen = IsolationState()
    /// Go: `disabled` — writes untracked, reads still tracked.
    public let disabled: Bool

    /// Go: `newIsolation`.
    public init(disabled: Bool) {
        self.disabled = disabled
        appendsOpenList.next = appendsOpenList
        appendsOpenList.prev = appendsOpenList
        readsOpen.next = readsOpen
        readsOpen.prev = readsOpen
    }

    /// Go: `lowWatermark` — the appendID below which per-ID tracking can be dropped.
    public func lowWatermark() -> UInt64 {
        if disabled { return 0 }
        return lowWatermarkLocked()
    }

    /// Go: `lowWatermarkLocked`.
    ///
    /// The OLDEST open read wins (`readsOpen.prev`), and with no open reads it falls back to the lowest open
    /// appender — or, with no appenders either, to the last issued ID, because `appendsOpenList.next` is then
    /// the sentinel itself.
    func lowWatermarkLocked() -> UInt64 {
        if disabled { return 0 }
        if readsOpen.prev !== readsOpen {
            return readsOpen.prev!.lowWatermark
        }
        return appendsOpenList.next!.appendID
    }

    /// Go: `lowestAppendTime` — `math.MaxInt64` when nothing is open.
    public func lowestAppendTime() -> Int64 {
        var lowest = Int64.max
        var a = appendsOpenList.next!
        while a !== appendsOpenList {
            if lowest > a.minTime { lowest = a.minTime }
            a = a.next!
        }
        return lowest
    }

    /// Go: `State(mint, maxt)` — **runs in full even when isolation is disabled**, because head truncation
    /// needs to know which time ranges are being read. Must be closed.
    public func state(mint: Int64, maxt: Int64) -> IsolationState {
        let isoState = IsolationState()
        isoState.maxAppendID = appendsOpenList.appendID
        // "Lowest appendID from appenders, or lastAppendId" — the sentinel makes both cases one expression.
        isoState.lowWatermark = appendsOpenList.next!.appendID
        isoState.incompleteAppends = Set(appendsOpen.keys)
        isoState.isolation = self
        isoState.mint = mint
        isoState.maxt = maxt

        // Linked in at `next`, so `next` is newest and `prev` is oldest.
        isoState.prev = readsOpen
        isoState.next = readsOpen.next
        readsOpen.next!.prev = isoState
        readsOpen.next = isoState
        return isoState
    }

    /// Go: `TraverseOpenReads` — stops early when `f` returns false. `f` must not mutate the state.
    public func traverseOpenReads(_ f: (IsolationState) -> Bool) {
        var s = readsOpen.next!
        while s !== readsOpen {
            if !f(s) { return }
            s = s.next!
        }
    }

    /// Go: `newAppendID` — returns the new ID and the low watermark, so a caller needs one call not two.
    ///
    /// **The first ID is 1**, because the sentinel starts at 0 and is pre-incremented. Disabled returns
    /// `(0, 0)`, which is why an appendID of 0 means "isolation off" rather than "the first append".
    @discardableResult
    public func newAppendID(minTime: Int64) -> (appendID: UInt64, lowWatermark: UInt64) {
        if disabled { return (0, 0) }

        // The last used appendID lives in the sentinel.
        appendsOpenList.appendID += 1

        let app = IsolationAppender()
        app.appendID = appendsOpenList.appendID
        app.minTime = minTime
        app.prev = appendsOpenList.prev
        app.next = appendsOpenList

        appendsOpenList.prev!.next = app
        appendsOpenList.prev = app

        appendsOpen[app.appendID] = app
        return (app.appendID, lowWatermarkLocked())
    }

    /// Go: `lastAppendID` — reads the SENTINEL's field, not any appender's.
    public func lastAppendID() -> UInt64 {
        if disabled { return 0 }
        return appendsOpenList.appendID
    }

    /// Go: `closeAppend` — unlink and forget. An unknown ID is silently ignored, which is what makes a double
    /// close harmless.
    public func closeAppend(_ appendID: UInt64) {
        if disabled { return }
        guard let app = appendsOpen[appendID] else { return }
        app.prev!.next = app.next
        app.next!.prev = app.prev
        appendsOpen.removeValue(forKey: appendID)
        // Go clears the struct and returns it to a `sync.Pool`; PORTING.md's standing exception drops the pool.
        app.prev = nil
        app.next = nil
    }
}

/// Go: `txRing` — the per-series ring of append IDs a sample might carry.
///
/// One per `memSeries`, so it has to stay small; `cleanupAppendIDsBelow` is what keeps it that way, driven by
/// the low watermark.
public struct TxRing {
    var txIDs: [UInt64]
    /// Go: `txIDFirst` — position of the first id in the ring.
    var txIDFirst: UInt32 = 0
    /// Go: `txIDCount` — how many ids are live.
    var txIDCount: UInt32 = 0

    public init(capacity: Int) {
        txIDs = [UInt64](repeating: 0, count: capacity)
    }

    public var count: Int { Int(txIDCount) }

    /// Go: `add`.
    ///
    /// Growth is a DOUBLING that also un-wraps the ring: the copy takes `txIDs[first...]` then `txIDs[..<first]`
    /// and resets `first` to 0. A port that grew with a plain append would leave the two halves in the wrong
    /// order — the same two-segment copy the look-back ring needed, and the HANDOFF records that perturbing it
    /// into the "obvious" logical-order copy broke 6 of 43 cases there.
    ///
    /// **`newLen == 0` becomes 4**, so a ring created with capacity 0 works rather than dividing by zero.
    public mutating func add(_ appendID: UInt64) {
        if Int(txIDCount) == txIDs.count {
            var newLen = txIDCount * 2
            if newLen == 0 { newLen = 4 }
            var newRing = [UInt64](repeating: 0, count: Int(newLen))
            var idx = 0
            for k in Int(txIDFirst)..<txIDs.count {
                newRing[idx] = txIDs[k]
                idx += 1
            }
            for k in 0..<Int(txIDFirst) {
                newRing[idx] = txIDs[k]
                idx += 1
            }
            txIDs = newRing
            txIDFirst = 0
        }
        txIDs[(Int(txIDFirst) + Int(txIDCount)) % txIDs.count] = appendID
        txIDCount += 1
    }

    /// Go: `cleanupAppendIDsBelow` — drop ids below `bound` from the front.
    ///
    /// It stops at the first id **at or above** the bound rather than scanning the whole ring, which is only
    /// correct because ids are added in increasing order. The trailing `txIDFirst %= len` is what brings the
    /// cursor back into range after it has walked past the end.
    public mutating func cleanupAppendIDsBelow(_ bound: UInt64) {
        if txIDs.isEmpty { return }
        var pos = Int(txIDFirst)

        while txIDCount > 0 {
            if txIDs[pos] >= bound { break }
            txIDFirst += 1
            txIDCount -= 1

            pos += 1
            if pos == txIDs.count { pos = 0 }
        }
        txIDFirst %= UInt32(txIDs.count)
    }

    /// Go: `iterator`.
    public func iterator() -> TxRingIterator {
        TxRingIterator(ids: txIDs, pos: txIDFirst)
    }
}

/// Go: `txRingIterator`, whose own comment is *"It doesn't terminate, it DOESN'T terminate."* — doubled
/// upstream, and worth keeping doubled here.
///
/// It wraps forever, so **the caller must bound the walk by `txIDCount`**. Every upstream caller does, and a
/// port that added a termination condition would be adding behaviour rather than reproducing it.
public struct TxRingIterator {
    let ids: [UInt64]
    var pos: UInt32

    public func at() -> UInt64 { ids[Int(pos)] }

    public mutating func next() {
        pos += 1
        if Int(pos) == ids.count { pos = 0 }
    }
}
