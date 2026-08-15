//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go @ v3.13.2 — the Head's GARBAGE COLLECTION and DELETION: `stripeSeries.gc`,
// `iterForDeletion`, `Head.gc`, `Head.Delete`, `Head.Tombstones`, `Truncate`/`truncateMemory` and
// `truncateSeriesAndChunkDiskMapper`.
//
// §7f made the Head ingest and §7g made it queryable. This is what makes it *forget*, which is the third thing
// `db.go` needs from it (the fourth, replay, is §7h's other half).
//
// ## `Truncate` is two truncations, and one of them is refused by an uninitialised head
//
// `Truncate(mint)` calls `truncateMemory` then `truncateWAL`, and **captures `initialized()` BEFORE the first**,
// because `truncateMemory` sets `minTime` and would make the second call look initialised. An uninitialised head
// still runs `truncateMemory` — that is how `db.go` seeds the head's `minValidTime` from the last persisted
// block before any sample arrives — but skips the WAL half, with the comment: *"We haven't read back the WAL
// yet, so do not attempt to truncate it."* `truncateWAL` is §7h's other half; this slice leaves the call site
// with a named gap.
//
// ## The GC decides per SERIES whether anything is left, and `actualMint` is the answer it reports
//
// `stripeSeries.gc` truncates each series' chunks and then asks whether the series still has anything at all —
// chunks, or a pending commit. A series that does contributes its `minTime()` to `actualMint`; one that does not
// is DELETED: removed from both stripes, its labels collected into `affected`, its ref into `deleted`. The Head
// then removes those refs from the postings and the tombstones.
//
// **`actualMint` starts at `MaxInt64` and falls back to `mint`** when every series is gone, which is what stops
// an empty head reporting `MaxInt64` as its start. And `truncateSeriesAndChunkDiskMapper` may then move
// `minTime` UP to it — but never past `appendableMinValidTime()`, because a `minTime` inside the appendable
// window would start rejecting samples the head is meant to accept.
//
// ## What is deliberately absent, and where each one goes
//
//   * **`WaitForPendingReadersInTimeRange`** and its OOO sibling. They block until overlapping readers close;
//     with no concurrency there is nothing to wait for, and the port's readers are closed by their caller. The
//     call sites keep a comment rather than a no-op function, so §7j sees the seam.
//   * **`truncateWAL`, `keepSeriesInWALCheckpointFn`, `walExpiries`** — the checkpoint machinery, §7h.
//   * **`gcStaleSeries`, `truncateStaleSeries`, `deleteSeriesByID`, `StaleHead`** — the stale-series feature,
//     whose reader is a compaction input (§7i).
//   * **OOO**: `minOOOMmapRef`, `truncateOOO`, and `gc`'s OOO arms. Phase 10.
//   * **The metrics and the logger**, as everywhere.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunks
public import PromIndex
public import PromLabels
public import PromModel
public import PromRecord
public import PromStorage
public import PromTombstones

extension StripeSeries {

    /// Go: `stripeSeries.iterForDeletion`.
    ///
    /// **Conflicts are visited BEFORE the unique slot**, and upstream's comment says why: `del` promotes
    /// `conflicts[0]` into `unique` when the unique holder goes, so visiting `unique` first would move a
    /// conflict into a slot the walk had already passed. Getting this backwards leaks a series that should have
    /// been deleted — invisibly, because it stays reachable by hash.
    ///
    /// The per-stripe `seriesSet` is handed to the lifecycle callback once per stripe, not once per series.
    @discardableResult
    public func iterForDeletion(
        _ checkDeleted: (Int, UInt64, MemSeries, inout [HeadSeriesRef: Labels]) -> Void
    ) -> Int {
        var totalDeletedSeries = 0
        for i in 0..<size {
            var seriesSet: [HeadSeriesRef: Labels] = [:]
            // Iterate conflicts first so the callback does not move them into `unique` after it has been read.
            for (hash, all) in hashes[i].conflicts ?? [:] {
                for series in all {
                    checkDeleted(i, hash, series, &seriesSet)
                }
            }
            for (hash, series) in hashes[i].unique {
                checkDeleted(i, hash, series, &seriesSet)
            }
            seriesLifecycleCallback.postDeletion(seriesSet)
            totalDeletedSeries += seriesSet.count
        }
        return totalDeletedSeries
    }

    /// Go: `stripeSeries.gc` — truncate every series' chunks before `mint`, and delete the ones left with
    /// nothing.
    ///
    /// The five results are all used by the Head: the deleted refs (for the postings and the tombstones), the
    /// affected labels (which postings lists to rebuild), how many chunks went, how many STALE series went, and
    /// `actualMint` — the real minimum the head now holds, which can be higher than the `mint` asked for.
    ///
    /// A series is kept when it still has `mmappedChunks`, a head chunk, **or a pending commit** — that last one
    /// is what stops a GC racing an appender into deleting a series whose samples have not landed yet.
    public func gc(mint: Int64) -> (
        deleted: Set<SeriesRef>, affected: Set<Label>, chunksRemoved: Int, staleSeriesDeleted: Int,
        actualMint: Int64, minMmapFile: Int
    ) {
        var deleted = Set<SeriesRef>()
        var affected = Set<Label>()
        var rmChunks = 0
        var staleSeriesDeleted = 0
        var actualMint = Int64.max
        var minMmapFile = Int(Int32.max)

        // For one series: truncate old chunks and check whether any are left. If not, mark it deleted.
        func check(
            _ hashShard: Int, _ hash: UInt64, _ series: MemSeries,
            _ deletedForCallback: inout [HeadSeriesRef: Labels]
        ) {
            let wasMmapReady = series.headChunkCount >= 2
            rmChunks += series.truncateChunksBefore(mint: mint)
            if wasMmapReady && series.headChunkCount < 2 {
                decMmapReady(series.ref)
            }

            if let first = series.mmappedChunks.first {
                let (seq, _) = first.ref.unpack()
                if seq < minMmapFile {
                    minMmapFile = seq
                }
            }

            if !series.mmappedChunks.isEmpty || series.headChunks != nil || series.pendingCommit {
                let seriesMint = series.minTime()
                if seriesMint < actualMint {
                    actualMint = seriesMint
                }
                return
            }

            // The series is gone entirely. Upstream takes the ref stripe's lock here as well as the hash
            // stripe's, "so that a series does not receive samples again while we are half-way into deleting
            // it"; the port has no locks, but the ORDER of the two removals is kept.
            let stripe = refStripe(series.ref)

            if PromValue.isStaleNaN(series.lastValue)
                || (series.lastHistogramValue.map { PromValue.isStaleNaN($0.sum) } ?? false)
                || (series.lastFloatHistogramValue.map { PromValue.isStaleNaN($0.sum) } ?? false)
            {
                staleSeriesDeleted += 1
            }

            deleted.insert(SeriesRef(rawValue: series.ref.rawValue))
            for l in series.lset {
                affected.insert(l)
            }
            hashes[hashShard].del(hash: hash, ref: series.ref)
            self.series[stripe].removeValue(forKey: series.ref)
            deletedForCallback[series.ref] = series.lset
        }

        iterForDeletion(check)

        if actualMint == Int64.max {
            actualMint = mint
        }

        return (deleted, affected, rmChunks, staleSeriesDeleted, actualMint, minMmapFile)
    }
}

extension Head {

    /// Go: `Head.Tombstones`.
    public func tombstonesReader() -> MemTombstones { tombstones }

    /// Go: `Head.gc` — the Head-level wrapper: run the series GC, then prune everything that pointed at the
    /// series it deleted.
    ///
    /// The order matters and is upstream's: postings first, then tombstones (both the deleted series' and
    /// everything elapsed), then the WAL-expiry note. `numSeries` and `numStaleSeries` are decremented by what
    /// the series GC reported, not recounted.
    @discardableResult
    public func gc() -> (actualInOrderMint: Int64, minMmapFile: Int) {
        // Only data strictly lower than this timestamp must be deleted.
        let mint = minTime()

        let r = series.gc(mint: mint)

        numSeries -= UInt64(r.deleted.count)
        numStaleSeries -= UInt64(r.staleSeriesDeleted)

        // Remove deleted series IDs from the postings lists.
        postings.delete(deleted: r.deleted, affected: r.affected)

        // Remove tombstones referring to the deleted series, and everything now elapsed.
        tombstones.deleteTombstones(r.deleted)
        tombstones.truncateBefore(mint)

        // Upstream also records `walExpiries[ref] = actualInOrderMint` for every deleted series, so WAL
        // checkpointing keeps their series records while the WAL still holds their samples — otherwise a replay
        // would meet a sample whose ref has no labels. That map and its reader are §7h's.

        return (r.actualMint, r.minMmapFile)
    }

    /// Go: `Head.Delete` — mark samples deleted with a tombstone; nothing is rewritten.
    ///
    /// Three things worth keeping in view:
    ///
    ///   * the requested interval is CLAMPED to the head's own range first, so a delete "from the beginning of
    ///     time" becomes a delete from the head's `MinTime`;
    ///   * a series whose own range is empty (`minTime() == MinInt64`) is SKIPPED, so a series that exists but
    ///     holds nothing gets no tombstone;
    ///   * the interval is clamped a SECOND time, per series, against that series' own range — which is why two
    ///     series matched by the same call can get different tombstones.
    ///
    /// The WAL record goes out BEFORE the in-memory tombstones are updated, so a crash cannot leave a deletion
    /// that replay does not know about.
    public func delete(mint: Int64, maxt: Int64, matchers: [Matcher]) throws {
        // Do not delete anything beyond the currently valid range.
        var (mint, maxt) = clampInterval(mint, maxt, minTime(), maxTime())

        let ir = indexRange(mint: mint, maxt: maxt)

        let p: any Postings
        do {
            p = try postingsForMatchers(ir, matchers)
        } catch {
            throw HeadDeleteError.selectSeries(error)
        }

        var stones: [Stone] = []
        while p.next() {
            guard let series = self.series.getByID(HeadSeriesRef(rawValue: p.at().rawValue)) else {
                // Upstream logs "Series not found in Head.Delete" at debug level.
                continue
            }

            let t0raw = series.minTime()
            let t1raw = series.maxTime()
            if t0raw == Int64.min || t1raw == Int64.min {
                continue
            }
            // Delete only until the current values and not beyond.
            let (t0, t1) = clampInterval(mint, maxt, t0raw, t1raw)
            stones.append(
                Stone(ref: p.at(), intervals: [DeletionInterval(mint: t0, maxt: t1)]))
        }
        if let err = p.err() {
            throw err
        }

        if let wal {
            let enc = RecordEncoder(enableSTStorage: opts.enableSTStorage)
            try wal.log(enc.tombstones(stones))
        }
        for s in stones {
            tombstones.addInterval(s.ref, s.intervals[0])
        }
    }

    /// Go: `Head.Truncate` — memory first, then the WAL.
    ///
    /// `initialized()` is captured BEFORE `truncateMemory`, because that call sets `minTime` and would make the
    /// head look initialised to the second half. See the file header.
    public func truncate(mint: Int64) throws {
        let wasInitialized = initialized()
        try truncateMemory(mint: mint)
        if !wasInitialized {
            return
        }
        // `truncateWAL(mint)` belongs here and is §7h's: it needs the checkpoint machinery and `walExpiries`.
    }

    /// Go: `Head.truncateMemory`.
    ///
    /// The early return is the interesting part: a head whose `MinTime` is already at or above `mint` does
    /// nothing **only if it is initialised**. An uninitialised head falls through and sets its bounds, which is
    /// how `db.go` seeds `minValidTime` from the last persisted block before any sample exists.
    ///
    /// Note `maxTime` is raised to `mint` if it was lower — so a truncation past everything the head holds
    /// leaves an EMPTY but well-formed window (`minTime == maxTime == mint`) rather than an inverted one.
    public func truncateMemory(mint: Int64) throws {
        let wasInitialized = initialized()

        if minTime() >= mint && wasInitialized {
            return
        }

        // The order of these two is upstream's: the truncation time is set before the in-process flag.
        lastMemoryTruncationTime = mint

        // Upstream waits here for readers overlapping [MinTime(), mint) — `WaitForPendingReadersInTimeRange`.
        // The port has no concurrency, so there is nothing to wait for; the seam is §7j's.

        minTimeValue = mint
        minValidTimeValue = mint

        // Ensure that max time is at least as high as min time.
        if maxTimeValue < mint {
            maxTimeValue = mint
        }

        // This was an initial call to Truncate after loading blocks on startup. The WAL has not been read yet,
        // so there is nothing to garbage-collect.
        if !wasInitialized {
            return
        }

        try truncateSeriesAndChunkDiskMapper(caller: "truncateMemory")
    }

    /// Go: `truncateSeriesAndChunkDiskMapper` — run the GC, then reconcile `minTime` with what the GC found, and
    /// truncate the chunk files.
    ///
    /// The `minTime` reconciliation is the subtle half. If the head's real minimum turned out HIGHER than the
    /// truncation point, `minTime` moves up to it — but never above `appendableMinValidTime()`, because a
    /// `minTime` inside the appendable window would make the head reject samples it is supposed to take. Both
    /// branches also move `minValidTime`, which is what actually does the rejecting.
    public func truncateSeriesAndChunkDiskMapper(caller: String) throws {
        let (actualMint, minMmapFile) = gc()

        if actualMint > minTimeValue {
            // The actual mint of the head is higher than the one asked to truncate.
            let appendableMinValid = appendableMinValidTime()
            if actualMint < appendableMinValid {
                minTimeValue = actualMint
                minValidTimeValue = actualMint
            } else {
                // The actual min time is in the appendable window, so clamp to that instead.
                minTimeValue = appendableMinValid
                minValidTimeValue = appendableMinValid
            }
        }

        // Truncate the chunk m-mapper.
        do {
            try chunkDiskMapper.truncate(fileNo: UInt32(truncatingIfNeeded: minMmapFile))
        } catch {
            throw HeadTruncateError.truncateChunks(error)
        }
    }
}

/// Go: `clampInterval` (querier.go) — narrow `[a, b]` to `[mint, maxt]`.
public func clampInterval(_ a: Int64, _ b: Int64, _ mint: Int64, _ maxt: Int64) -> (Int64, Int64) {
    var a = a, b = b
    if a < mint {
        a = mint
    }
    if b > maxt {
        b = maxt
    }
    return (a, b)
}

/// Go: `fmt.Errorf("select series: %w", err)` in `Head.Delete`.
public enum HeadDeleteError: Error, CustomStringConvertible {
    case selectSeries(any Error)

    public var description: String {
        switch self {
        case .selectSeries(let e): return "select series: \(e)"
        }
    }
}

/// Go: `fmt.Errorf("truncate chunks.HeadReadWriter by file number: %w", err)`.
public enum HeadTruncateError: Error, CustomStringConvertible {
    case truncateChunks(any Error)

    public var description: String {
        switch self {
        case .truncateChunks(let e): return "truncate chunks.HeadReadWriter by file number: \(e)"
        }
    }
}
