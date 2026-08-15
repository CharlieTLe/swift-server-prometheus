#!/usr/bin/env bash
# Negative controls for the Head's GC and deletion path — `stripeSeries.gc`, `iterForDeletion`, `Head.gc`,
# `Delete`, `Truncate`/`truncateMemory`, `truncateSeriesAndChunkDiskMapper`, and `MemTombstones`.
#
# Two files, so `run` takes the one it perturbed.
set -uo pipefail
cd "$(dirname "$0")/.."
GC=Sources/PromHead/HeadGC.swift
MT=Sources/PromTombstones/MemTombstones.swift
cp "$GC" /tmp/hgc-gc.orig
cp "$MT" /tmp/hgc-mt.orig
restore() { cp /tmp/hgc-gc.orig "$GC"; cp /tmp/hgc-mt.orig "$MT"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$GC") orig=/tmp/hgc-gc.orig ;;
    "$MT") orig=/tmp/hgc-mt.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'HeadGCTests' 64
  restore
}

echo "=== iterForDeletion ==="
perl -0pi -e 's~\Q            for (hash, all) in hashes[i].conflicts ?? [:] {\E~        for (hash, all) in [UInt64: [MemSeries]]() {~' "$GC"; run "$GC" "iterForDeletion never visits the conflicts"
perl -0pi -e 's~\Q            for (hash, all) in hashes[i].conflicts ?? [:] {\E\n\Q                for series in all {\E\n\Q                    checkDeleted(i, hash, series, &seriesSet)\E\n\Q                }\E\n\Q            }\E\n\Q            for (hash, series) in hashes[i].unique {\E\n\Q                checkDeleted(i, hash, series, &seriesSet)\E\n\Q            }\E~            for (hash, series) in hashes[i].unique {\n                checkDeleted(i, hash, series, \&seriesSet)\n            }\n            for (hash, all) in hashes[i].conflicts ?? [:] {\n                for series in all {\n                    checkDeleted(i, hash, series, \&seriesSet)\n                }\n            }~' "$GC"; run "$GC" "iterForDeletion visits the unique slot first"
perl -0pi -e 's~\Q            for (hash, series) in hashes[i].unique {\E\n\Q                checkDeleted(i, hash, series, &seriesSet)\E\n\Q            }\E~~' "$GC"; run "$GC" "iterForDeletion never visits the unique slot"
perl -0pi -e 's~\Q            seriesLifecycleCallback.postDeletion(seriesSet)\E~~' "$GC"; run "$GC" "the deletion callback is never called"

echo "=== stripeSeries.gc ==="
perl -0pi -e 's~\Q            rmChunks += series.truncateChunksBefore(mint: mint)\E~~' "$GC"; run "$GC" "the GC does not truncate any series' chunks"
perl -0pi -e 's~\Q            if !series.mmappedChunks.isEmpty || series.headChunks != nil || series.pendingCommit {\E~            if !series.mmappedChunks.isEmpty || series.headChunks != nil {~' "$GC"; run "$GC" "a pending commit does not save a series"
perl -0pi -e 's~\Q            if !series.mmappedChunks.isEmpty || series.headChunks != nil || series.pendingCommit {\E~            if series.headChunks != nil || series.pendingCommit {~' "$GC"; run "$GC" "mmapped chunks do not save a series"
perl -0pi -e 's~\Q                let seriesMint = series.minTime()\E\n\Q                if seriesMint < actualMint {\E\n\Q                    actualMint = seriesMint\E\n\Q                }\E~~' "$GC"; run "$GC" "the GC does not track the surviving minimum"
perl -0pi -e 's~\Q                if seriesMint < actualMint {\E~                if seriesMint > actualMint {~' "$GC"; run "$GC" "the surviving minimum is a maximum"
perl -0pi -e 's~\Q        if actualMint == Int64.max {\E\n\Q            actualMint = mint\E\n\Q        }\E~~' "$GC"; run "$GC" "an empty head reports MaxInt64 as its minimum"
perl -0pi -e 's~\Q            deleted.insert(SeriesRef(rawValue: series.ref.rawValue))\E~~' "$GC"; run "$GC" "deleted series are not reported"
perl -0pi -e 's~\Q            for l in series.lset {\E\n\Q                affected.insert(l)\E\n\Q            }\E~~' "$GC"; run "$GC" "the affected labels are not collected"
perl -0pi -e 's~\Q            hashes[hashShard].del(hash: hash, ref: series.ref)\E~~' "$GC"; run "$GC" "a deleted series stays in the hash map"
perl -0pi -e 's~\Q            self.series[stripe].removeValue(forKey: series.ref)\E~~' "$GC"; run "$GC" "a deleted series stays in the ref map"
perl -0pi -e 's~\Q            let wasMmapReady = series.headChunkCount >= 2\E~            let wasMmapReady = false~' "$GC"; run "$GC" "the mmap-ready counter is not adjusted by the GC"
perl -0pi -e 's~\Q                staleSeriesDeleted += 1\E~~' "$GC"; run "$GC" "deleted stale series are not counted"
perl -0pi -e 's~\Q            if PromValue.isStaleNaN(series.lastValue)\E~            if false, PromValue.isStaleNaN(series.lastValue)~' "$GC"; run "$GC" "a stale float is not recognised"
perl -0pi -e 's~\Q                if seq < minMmapFile {\E~                if seq > minMmapFile {~' "$GC"; run "$GC" "the minimum mmap file is a maximum"

echo "=== Head.gc ==="
perl -0pi -e 's~\Q        numSeries -= UInt64(r.deleted.count)\E~~' "$GC"; run "$GC" "the series count is not reduced by the GC"
perl -0pi -e 's~\Q        numStaleSeries -= UInt64(r.staleSeriesDeleted)\E~~' "$GC"; run "$GC" "the stale count is not reduced by the GC"
perl -0pi -e 's~\Q        postings.delete(deleted: r.deleted, affected: r.affected)\E~~' "$GC"; run "$GC" "deleted series stay in the postings"
perl -0pi -e 's~\Q        tombstones.deleteTombstones(r.deleted)\E~~' "$GC"; run "$GC" "a deleted series keeps its tombstones"
perl -0pi -e 's~\Q        tombstones.truncateBefore(mint)\E~~' "$GC"; run "$GC" "elapsed tombstones are not pruned"
perl -0pi -e 's~\Q        let mint = minTime()\E~        let mint = maxTime()~' "$GC"; run "$GC" "the GC truncates at maxTime rather than minTime"

echo "=== Head.Delete ==="
perl -0pi -e 's~\Q        var (mint, maxt) = clampInterval(mint, maxt, minTime(), maxTime())\E~        var (mint, maxt) = (mint, maxt)~' "$GC"; run "$GC" "Delete does not clamp to the head's range"
perl -0pi -e 's~\Q            let (t0, t1) = clampInterval(mint, maxt, t0raw, t1raw)\E~            let (t0, t1) = (mint, maxt)~' "$GC"; run "$GC" "Delete does not clamp per series"
perl -0pi -e 's~\Q            if t0raw == Int64.min || t1raw == Int64.min {\E\n\Q                continue\E\n\Q            }\E~~' "$GC"; run "$GC" "a series with no samples still gets a tombstone"
perl -0pi -e 's~\Q                Stone(ref: p.at(), intervals: [DeletionInterval(mint: t0, maxt: t1)]))\E~                Stone(ref: p.at(), intervals: [DeletionInterval(mint: t1, maxt: t0)]))~' "$GC"; run "$GC" "the tombstone's interval is inverted"
perl -0pi -e 's~\Q        for s in stones {\E\n\Q            tombstones.addInterval(s.ref, s.intervals[0])\E\n\Q        }\E~~' "$GC"; run "$GC" "Delete does not record its tombstones in memory"
perl -0pi -e 's~\Q            let enc = RecordEncoder(enableSTStorage: opts.enableSTStorage)\E\n\Q            try wal.log(enc.tombstones(stones))\E~            _ = RecordEncoder(enableSTStorage: opts.enableSTStorage)~' "$GC"; run "$GC" "Delete does not log its tombstones"
perl -0pi -e 's~\Q        let ir = indexRange(mint: mint, maxt: maxt)\E~        let ir = index()~' "$GC"; run "$GC" "Delete selects over the whole head rather than the interval"

echo "=== Truncate ==="
perl -0pi -e 's~\Q        let wasInitialized = initialized()\E\n\Q        try truncateMemory(mint: mint)\E~        try truncateMemory(mint: mint)\n        let wasInitialized = initialized()~' "$GC"; run "$GC" "Truncate reads initialized AFTER truncating memory"
perl -0pi -e 's~\Q        if minTime() >= mint && wasInitialized {\E~        if minTime() >= mint {~' "$GC"; run "$GC" "an uninitialised head refuses to truncate"
perl -0pi -e 's~\Q        if minTime() >= mint && wasInitialized {\E~        if minTime() > mint \&\& wasInitialized {~' "$GC"; run "$GC" "the truncation early return is strict"
perl -0pi -e 's~\Q        minTimeValue = mint\E\n\Q        minValidTimeValue = mint\E~        minTimeValue = mint~' "$GC"; run "$GC" "truncateMemory does not move minValidTime"
perl -0pi -e 's~\Q        if maxTimeValue < mint {\E\n\Q            maxTimeValue = mint\E\n\Q        }\E~~' "$GC"; run "$GC" "truncateMemory can leave an inverted window"
perl -0pi -e 's~\Q        if !wasInitialized {\E\n\Q            return\E\n\Q        }\E\n\Q\E\n\Q        try truncateSeriesAndChunkDiskMapper(caller: "truncateMemory")\E~        try truncateSeriesAndChunkDiskMapper(caller: "truncateMemory")~' "$GC"; run "$GC" "an uninitialised head runs the GC anyway"

echo "=== truncateSeriesAndChunkDiskMapper ==="
perl -0pi -e 's~\Q        if actualMint > minTimeValue {\E~        if actualMint < minTimeValue {~' "$GC"; run "$GC" "the minimum is reconciled in the wrong direction"
perl -0pi -e 's~\Q            if actualMint < appendableMinValid {\E~            if actualMint > appendableMinValid {~' "$GC"; run "$GC" "the appendable-window clamp is inverted"
perl -0pi -e 's~\Q            if actualMint < appendableMinValid {\E\n\Q                minTimeValue = actualMint\E\n\Q                minValidTimeValue = actualMint\E\n\Q            } else {\E~            if true {\n                minTimeValue = actualMint\n                minValidTimeValue = actualMint\n            } else {~' "$GC"; run "$GC" "the minimum is never clamped to the appendable window"
perl -0pi -e 's~\Q            try chunkDiskMapper.truncate(fileNo: UInt32(truncatingIfNeeded: minMmapFile))\E~~' "$GC"; run "$GC" "the chunk files are never truncated"
perl -0pi -e 's~\Q        let (actualMint, minMmapFile) = gc()\E~        let (actualMint, minMmapFile) = (minTimeValue, Int(Int32.max))~' "$GC"; run "$GC" "the truncation never runs the GC"

echo "=== MemTombstones ==="
perl -0pi -e 's~\Q                if beforeT > ivs[i].maxt {\E~                if beforeT >= ivs[i].maxt {~' "$MT"; run "$MT" "truncateBefore drops an interval ending exactly at the bound"
perl -0pi -e 's~\Q                if beforeT > ivs[i].maxt {\E~                if beforeT > ivs[i].mint {~' "$MT"; run "$MT" "truncateBefore tests the interval's START"
perl -0pi -e 's~\Q            let remaining = Array(ivs.dropFirst(i + 1))\E~            let remaining = Array(ivs.dropFirst(i))~' "$MT"; run "$MT" "truncateBefore is off by one and keeps an elapsed interval"
perl -0pi -e 's~\Q            let remaining = Array(ivs.dropFirst(i + 1))\E~            let remaining = Array(ivs.dropFirst(i + 2))~' "$MT"; run "$MT" "truncateBefore drops one interval too many"
perl -0pi -e 's~\Q            if remaining.isEmpty {\E\n\Q                intervalGroups.removeValue(forKey: ref)\E\n\Q            } else {\E~            if false {\n                intervalGroups.removeValue(forKey: ref)\n            } else {~' "$MT"; run "$MT" "an emptied tombstone list is stored rather than removed"
perl -0pi -e 's~\Q            group = group.addingInterval(itv)\E~            group.append(itv)~' "$MT"; run "$MT" "addInterval appends without merging"
perl -0pi -e 's~\Q            intervalGroups.removeValue(forKey: ref)\E\n\Q        }\E\n\Q    }\E\n\Q\E\n\Q    /// Go: `TruncateBefore`\E~        }\n    }\n\n    \/\/\/ Go: `TruncateBefore`~' "$MT"; run "$MT" "deleteTombstones does not remove anything"
perl -0pi -e 's~\Q        intervalGroups.values.reduce(0) {\E[^\n]*~        UInt64(intervalGroups.count)~' "$MT"; run "$MT" "Total counts series rather than intervals"
perl -0pi -e 's~\Q        intervalGroups[ref] ?? []\E~        []~' "$MT"; run "$MT" "Get always answers empty"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q        var rmChunks = 0\E~        var rmChunks = 0\n        _ = rmChunks~' "$GC"; run "$GC" "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 52 controls: 41 broke, 11 SURVIVED, 0 SKIP, 0 COMPILE.
#
# The first run scored 32/52. Two of the closures are worth naming because they generalise:
#
#   * **A GC corpus has to commit the RAW postings**, not only the series that resolve. A ref the GC failed
#     to remove is invisible through `Series` — which skips a missing series by design — so the leak reads
#     as "no change". Committing `allPostings` and the label-indexed postings is what made `postings.delete`
#     and its `affected` argument observable.
#   * **The appendable-window clamp needs a surviving series ABOVE the floor.** `truncateSeriesAndChunkDiskMapper`
#     moves `minTime` up to the GC's `actualMint` but never past `appendableMinValidTime()`, and with the
#     usual dense corpus the two are equal. Samples at 0-1000 and 20000-21000 with a truncation at 15000
#     separates them: the clamped answer is 19000 and the unclamped one 20000.
#
# One survivor is DELIBERATE (the harness check). The other ten are proofs, and six of them are the same
# kind of tautology: **a second clamp downstream makes the first one redundant.**
#
#   * `Delete does not clamp to the head's range`. `Delete` clamps the requested interval to
#     `[MinTime, MaxTime]` and then clamps AGAIN per series against that series' own range — and a series'
#     range can never be wider than the head's, so the second clamp subsumes the first. The head-level
#     clamp is documentation.
#   * `Delete selects over the whole head rather than the interval`. `indexRange(mint, maxt)`'s window only
#     affects `LabelValues`/`LabelNames` (which `PostingsForMatchers` does not call) and the chunk metas
#     `Series` reports (which `Delete` does not read). So passing the interval changes nothing that `Delete`
#     observes.
#   * `an empty head reports MaxInt64 as its minimum`. Removing the `actualMint == MaxInt64 -> mint`
#     fallback leaves `actualMint` at `MaxInt64`, which is then clamped to `appendableMinValidTime()` — and
#     after `truncateMemory` that equals the requested `mint`. The fallback and the clamp agree.
#   * `a deleted series keeps its tombstones`. A tombstone is clamped to its series' own range, so a series
#     the GC deleted (because everything it held is below `mint`) cannot have a tombstone reaching `mint` —
#     `tombstones.truncateBefore(mint)` removes it whether or not `deleteTombstones` ran.
#   * `the truncation early return is strict` (`>=` versus `>`). At `minTime() == mint` the strict version
#     proceeds, sets the same bounds, and runs a GC that finds the same `actualMint`. Same state, more work.
#   * `an uninitialised head runs the GC anyway`. A head with no series has nothing to collect, and
#     `chunkDiskMapper.truncate(MaxInt32)` on an empty directory is a no-op.
#
# THE REST NEED A LATER SLICE:
#
#   * `Truncate reads initialized AFTER truncating memory`. The captured flag decides only whether
#     `truncateWAL` runs — and that call is §7h's other half. This control MUST break once it lands; until
#     then the flag has no reader.
#   * `mmapped chunks do not save a series`. A series with mmapped chunks and NO head chunk is unreachable
#     from this slice's API (`truncateChunksBefore` clears the mmapped array whenever it drops a head
#     chunk); `head_wal.go`'s `loadMmappedChunks` is what builds it. Same family as §7f(d)'s survivor.
#   * `the minimum mmap file is a maximum` and `the chunk files are never truncated`. `minMmapFile` only
#     decides anything when two or more chunk FILES exist, and a file is 128 MiB — `cutNewFile` is what
#     forces a second one and nothing on the Head's surface calls it. `db.go`'s compaction is the caller
#     that ages files out (§7j).
