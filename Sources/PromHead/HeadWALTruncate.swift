//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go @ v3.13.2 — the WAL half of truncation: `walExpiries`, `getWALExpiry`,
// `updateWALExpiry`, `keepSeriesInWALCheckpointFn` and `truncateWAL`.
//
// §7h(a) landed `Truncate`'s memory half and left the WAL call site as a named gap; this closes it, and with it
// the last of `Head.Truncate`. §7h(b) landed the replay; this is what stops the WAL growing without bound
// underneath it.
//
// ## The two-thirds rule, and why the last segment is untouchable
//
//     last--                       // Never consider last segment for checkpoint.
//     last = first + (last-first)*2/3
//
// The live segment is excluded because an appender is writing into it. Then only the **lower two thirds** of
// what remains is checkpointed, so a low-volume TSDB does not rewrite its whole WAL on every truncation —
// upstream's comment puts the effect at "up to around 3h worth of WAL segments" with the default 2h blocks.
// `last <= first` after that division means there is not enough to be worth doing, and the function returns
// having done nothing but cut a new segment.
//
// ## `walExpiries` is what keeps a DELETED series' record alive
//
// `Head.gc` records `walExpiries[ref] = actualInOrderMint` for every series it removed, because the series'
// samples are usually still in the WAL — and a replay that met those samples without their series record would
// have no labels for them. `keepSeriesInWALCheckpointFn` therefore keeps a record when the series still exists
// **or** when its expiry has not passed. Both halves matter: dropping the first loses live series, dropping the
// second loses the labels of samples that are still being replayed.
//
// The map is pruned at the end of `truncateWAL`, after the checkpoint has been written — the order is the point,
// because the checkpoint is what makes the expiry unnecessary.
//
// ## What is absent
//
//   * **The OOO half** (`truncateOOO`, the WBL) — Phase 10.
//   * **The chunk snapshot** and `EnableMemorySnapshotOnShutdown`.
//   * The metrics and the logger, as everywhere. Note `truncateWAL` LOGS a failed `wal.Truncate` and carries on
//     — *"If truncating fails, we'll just try again at the next checkpoint"* — so that failure is swallowed
//     here too, deliberately.
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromWAL

extension Head {

    /// Go: `getWALExpiry`.
    public func walExpiry(_ id: HeadSeriesRef) -> (Int64, Bool) {
        guard let keepUntil = walExpiries[id] else { return (0, false) }
        return (keepUntil, true)
    }

    /// Go: `updateWALExpiry` — and it takes the MAXIMUM, never lowering an expiry that is already set. A
    /// duplicate series record's later samples can only extend how long its record must be kept.
    public func updateWALExpiry(_ id: HeadSeriesRef, keepUntil: Int64) {
        walExpiries[id] = max(keepUntil, walExpiries[id] ?? Int64.min)
    }

    /// Go: `keepSeriesInWALCheckpointFn`.
    ///
    /// Reads as two independent reasons to keep a series record, and both are load-bearing — see the file
    /// header. The expiry test is `>= mint`, so a series whose samples end exactly at the truncation point keeps
    /// its record.
    public func keepSeriesInWALCheckpointFn(mint: Int64) -> (HeadSeriesRef) -> Bool {
        { id in
            // Keep the record if the series exists in the head.
            if self.series.getByID(id) != nil {
                return true
            }
            // Keep the record if the series has an expiry set.
            let (keepUntil, ok) = self.walExpiry(id)
            return ok && keepUntil >= mint
        }
    }

    /// Go: `Head.truncateWAL`.
    ///
    /// Four steps, and the first two happen even when the third and fourth do not: the truncation time is
    /// recorded, and a **new segment is always cut** — that is what makes the live segment excludable. Only then
    /// does the two-thirds rule decide whether a checkpoint is worth writing.
    ///
    /// `mint <= lastWALTruncationTime` is the idempotence guard: a second truncation at the same point does
    /// nothing, which is why `Truncate` can be called on every tick.
    public func truncateWAL(mint: Int64) throws {
        guard let wal, mint > lastWALTruncationTime else {
            return
        }
        lastWALTruncationTime = mint

        var (first, last) = try walSegments(fsStorage, wal.dir)
        // Start a new segment, so a low-ingestion TSDB does not keep more WAL than it needs.
        _ = try wal.nextSegment()

        last -= 1  // Never consider the last segment for a checkpoint.
        if last < 0 {
            return  // No segments yet.
        }
        // The lower two thirds should be mostly obsolete samples; fewer than two segments is not worth it.
        last = first + (last - first) * 2 / 3
        if last <= first {
            return
        }

        do {
            try checkpoint(
                fs: fsStorage, wal: wal, from: first, to: last,
                keep: keepSeriesInWALCheckpointFn(mint: mint), mint: mint,
                enableSTStorage: opts.enableSTStorage)
        } catch {
            throw HeadTruncateError.createCheckpoint(error)
        }

        // A failed segment truncation is LOGGED and swallowed upstream: the next checkpoint will try again, and
        // leftover segments are ignored once a checkpoint supersedes them.
        try? wal.truncate(last + 1)

        // The checkpoint is written and data before `mint` is gone, so stop tracking expired series.
        for (ref, keepUntil) in walExpiries where keepUntil < mint {
            walExpiries.removeValue(forKey: ref)
        }

        // Delete the checkpoints this one supersedes. Upstream logs a failure and continues.
        try? deleteCheckpoints(fsStorage, wal.dir, maxIndex: last)
    }
}
