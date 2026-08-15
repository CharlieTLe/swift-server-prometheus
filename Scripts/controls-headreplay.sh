#!/usr/bin/env bash
# Negative controls for the Head's WAL replay — `Init`, `loadMmappedChunks`, `removeCorruptedMmappedChunks`,
# `loadWAL`, `resetSeriesWithMMappedChunks` and `appendChunkAndMmap`.
#
# The corpus is the equivalence contract: a head built by replaying a WAL against a head built by appending the
# same samples. This sweep asks whether every line of the replay is visible in that comparison.
set -uo pipefail
cd "$(dirname "$0")/.."
RP=Sources/PromHead/HeadReplay.swift
cp "$RP" /tmp/hrp-rp.orig
restore() { cp /tmp/hrp-rp.orig "$RP"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$RP" /tmp/hrp-rp.orig
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'HeadReplayTests' 64
  restore
}

echo "=== Init's order and its three deferred actions ==="
perl -0pi -e 's~\Q            postings.ensureOrder()\E~~' "$RP"; run "the postings are left unordered after replay"
perl -0pi -e 's~\Q        defer {\E\n\Q            gc()\E\n\Q        }\E~~' "$RP"; run "Init does not garbage-collect after replay"
perl -0pi -e 's~\Q            if minTime() < minValidTimeValue {\E\n\Q                minTimeValue = minValidTimeValue\E\n\Q            }\E~~' "$RP"; run "Init does not clamp minTime up to minValidTime"
perl -0pi -e 's~\Q            if minTime() < minValidTimeValue {\E~            if minTime() > minValidTimeValue {~' "$RP"; run "the minTime clamp is inverted"
perl -0pi -e 's~\Q        minValidTimeValue = minValidTime\E~~' "$RP"; run "Init ignores its minValidTime argument"
perl -0pi -e 's~\Q        if wal != nil {\E~        if wal == nil {~' "$RP"; run "the m-mapped chunks are loaded only when there is NO WAL"
perl -0pi -e 's~\Q                (mmappedChunks, _) = try loadMmappedChunks(refSeries: [:])\E~                mmappedChunks = [:]~' "$RP"; run "Init never loads the m-mapped chunks"

echo "=== the segment walk ==="
perl -0pi -e 's~\Q        if startFrom < 0 {\E\n\Q            return  // No segments at all.\E\n\Q        }\E~~' "$RP"; run "an empty WAL directory is walked anyway"
perl -0pi -e 's~\Q        for i in startFrom...endAt {\E~        for i in startFrom...startFrom {~' "$RP"; run "only the first WAL segment is replayed"
perl -0pi -e 's~\Q        for i in startFrom...endAt {\E~        for i in stride(from: endAt, through: startFrom, by: -1) {~' "$RP"; run "the segments are replayed newest-first"

echo "=== loadMmappedChunks ==="
perl -0pi -e 's~\Q                if !isOOO && maxt < minValidTimeValue {\E\n\Q                    return\E\n\Q                }\E~~' "$RP"; run "a chunk entirely below minValidTime is loaded anyway"
perl -0pi -e 's~\Q                if !isOOO && maxt < minValidTimeValue {\E~                if !isOOO \&\& mint < minValidTimeValue {~' "$RP"; run "the chunk filter tests minTime rather than maxTime"
perl -0pi -e 's~\Q                if !encoding.isValid {\E\n\Q                    return\E\n\Q                }\E~~' "$RP"; run "a chunk with an invalid encoding is loaded"
perl -0pi -e 's~\Q                if let last = slice.last, last.maxTime >= mint {\E~                if let last = slice.last, last.maxTime > mint {~' "$RP"; run "the out-of-sequence check allows an exact overlap"
perl -0pi -e 's~\Q                if let last = slice.last, last.maxTime >= mint {\E\n\Q                    throw HeadReplayError.outOfSequenceMmappedChunk(\E\n\Q                        seriesRef: seriesRef.rawValue, lastMinTime: last.minTime,\E\n\Q                        lastMaxTime: last.maxTime, mint: mint, maxt: maxt)\E\n\Q                }\E~~' "$RP"; run "there is no out-of-sequence check at all"
perl -0pi -e 's~\Q                    MmappedChunk(ref: chunkRef, numSamples: numSamples, minTime: mint, maxTime: maxt))\E~                    MmappedChunk(ref: chunkRef, numSamples: numSamples, minTime: maxt, maxTime: mint))~' "$RP"; run "the m-mapped chunk's times are swapped"
perl -0pi -e 's~\Q                secondLastRef = lastRef\E\n\Q                lastRef = chunkRef\E~                lastRef = chunkRef~' "$RP"; run "the second-to-last ref is not tracked"

echo "=== removeCorruptedMmappedChunks ==="
perl -0pi -e 's~\Q        resetInMemoryState()\E~~' "$RP"; run "the in-memory state is not reset before repair"
perl -0pi -e 's~\Q            try chunkDiskMapper.deleteCorrupted(error)\E~~' "$RP"; run "the corrupted chunk file is not deleted"
perl -0pi -e 's~\Q            try? chunkDiskMapper.truncate(fileNo: UInt32.max)\E\n\Q            return [:]\E\n\Q        }\E\n\Q\E\n\Q        do {\E~            return [:]\n        }\n\n        do {~' "$RP"; run "a failed deletion does not discard the chunk files"

echo "=== loadWAL: series records ==="
perl -0pi -e 's~\Q                    if lastSeriesID < walSeries.ref.rawValue {\E\n\Q                        lastSeriesID = walSeries.ref.rawValue\E\n\Q                    }\E~~' "$RP"; run "the series counter is not advanced past the WAL's refs"
perl -0pi -e 's~\Q                    if lastSeriesID < walSeries.ref.rawValue {\E~                    if lastSeriesID > walSeries.ref.rawValue {~' "$RP"; run "the series-counter comparison is inverted"
perl -0pi -e 's~\Q                    if !created {\E\n\Q                        // A duplicate series record: every later record for the OLD ref is remapped.\E\n\Q                        multiRef[walSeries.ref] = mSeries.ref\E\n\Q                    }\E~~' "$RP"; run "a duplicate series record is not remapped"
perl -0pi -e 's~\Q                    if !created {\E~                    if created {~' "$RP"; run "every series record is remapped, not just the duplicates"
perl -0pi -e 's~\Q                        id: walSeries.ref, hash: walSeries.labels.goHash(),\E~                        id: HeadSeriesRef(rawValue: 0), hash: walSeries.labels.goHash(),~' "$RP"; run "replay allocates fresh refs instead of using the WAL's"
perl -0pi -e 's~\Q                    resetSeriesWithMMappedChunks(\E\n\Q                        mSeries, mmc: mmappedChunks[walSeries.ref] ?? [],\E\n\Q                        walSeriesRef: walSeries.ref)\E~~' "$RP"; run "a replayed series never receives its m-mapped chunks"

echo "=== loadWAL: sample records ==="
perl -0pi -e 's~\Q                    if sam.t < minValidTimeValue {\E\n\Q                        continue  // Before minValidTime: discard.\E\n\Q                    }\E~~' "$RP"; run "samples below minValidTime are replayed"
perl -0pi -e 's~\Q                    if sam.t < minValidTimeValue {\E~                    if sam.t <= minValidTimeValue {~' "$RP"; run "a sample exactly at minValidTime is discarded"
perl -0pi -e 's~\Q                    if let r = multiRef[sam.ref] {\E\n\Q                        sam.ref = r\E\n\Q                    }\E~~' "$RP"; run "a sample for a remapped ref is not remapped"
perl -0pi -e 's~\Q                    if sam.t <= ms.mmMaxTime {\E\n\Q                        continue  // Already in an m-mapped chunk.\E\n\Q                    }\E~~' "$RP"; run "samples already in an m-mapped chunk are replayed again"
perl -0pi -e 's~\Q                    if sam.t <= ms.mmMaxTime {\E~                    if sam.t < ms.mmMaxTime {~' "$RP"; run "the m-mapped skip is off by one"
perl -0pi -e 's~\Q                            st: sam.st, t: sam.t, v: sam.v, appendID: 0, o: replayChunkOpts())\E~                            st: sam.st, t: sam.t, v: sam.v, appendID: 1, o: replayChunkOpts())~' "$RP"; run "replay appends with an isolation ID"
perl -0pi -e 's~\Q                    updateMinMaxTime(mint: sam.t, maxt: sam.t)\E~~' "$RP"; run "replay does not widen the head's window"
perl -0pi -e 's~\Q                    guard let ms = self.series.getByID(sam.ref) else {\E\n\Q                        unknownSampleRefs += 1\E\n\Q                        continue\E\n\Q                    }\E~                    let ms = self.series.getByID(sam.ref)!~' "$RP"; run "a sample for an unknown series traps"

echo "=== loadWAL: tombstone records ==="
perl -0pi -e 's~\Q                        tombstones.addInterval(SeriesRef(rawValue: ref.rawValue), itv)\E~~' "$RP"; run "tombstone records are not replayed"
perl -0pi -e 's~\Q                        if self.series.getByID(ref) == nil {\E\n\Q                            unknownTombstoneRefs += 1\E\n\Q                            continue\E\n\Q                        }\E~~' "$RP"; run "a tombstone for an unknown series is applied"
perl -0pi -e 's~\Q                        if let r = multiRef[ref] {\E\n\Q                            ref = r\E\n\Q                        }\E~~' "$RP"; run "a tombstone for a remapped ref is not remapped"

echo "=== replayChunkOpts, appendChunkAndMmap, resetSeriesWithMMappedChunks ==="
perl -0pi -e 's~\Q            storeST: opts.enableSTStorage)\E~            storeST: false)~' "$RP"; run "replay does not pass storeST, so an XOR chunk can be continued with XOR2"
perl -0pi -e 's~\Q            samplesPerChunk: opts.samplesPerChunk, useXOR2: opts.useXOR2FloatEncoding(),\E~            samplesPerChunk: 1, useXOR2: opts.useXOR2FloatEncoding(),~' "$RP"; run "replay cuts a chunk per sample"
perl -0pi -e 's~\Q            chunkDiskMapper: chunkDiskMapper, chunkRange: chunkRange,\E~            chunkDiskMapper: chunkDiskMapper, chunkRange: defaultBlockDuration,~' "$RP"; run "replay ignores the configured chunk range"
perl -0pi -e 's~\Q            _ = ms.mmapChunks(chunkDiskMapper: chunkDiskMapper)\E~~' "$RP"; run "replay never m-maps as it goes"
perl -0pi -e 's~\Q            if prev >= 2 {\E~            if prev >= 1 {~' "$RP"; run "the mmap-ready counter is decremented too eagerly during replay"
perl -0pi -e 's~\Q        mSeries.mmappedChunks = mmc\E~~' "$RP"; run "the m-mapped chunks are not assigned to the series"
perl -0pi -e 's~\Q            mSeries.mmMaxTime = mmc[mmc.count - 1].maxTime\E~            mSeries.mmMaxTime = mmc[0].minTime~' "$RP"; run "mmMaxTime is the FIRST chunk's minTime"
perl -0pi -e 's~\Q            mSeries.mmMaxTime = Int64.min\E~            mSeries.mmMaxTime = 0~' "$RP"; run "a series with no m-mapped chunks gets an mmMaxTime of 0"
perl -0pi -e 's~\Q            updateMinMaxTime(mint: mmc[0].minTime, maxt: mSeries.mmMaxTime)\E~~' "$RP"; run "the m-mapped range does not widen the head's window"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q        var unknownSampleRefs = 0\E~        var unknownSampleRefs = 0\n        _ = unknownSampleRefs~' "$RP"; run "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 47 controls: 32 broke, 15 SURVIVED, 0 SKIP, 0 COMPILE.
#
# The first run scored 27/47. What closed the gap: a case that CORRUPTS the chunk file body (so the
# recovery path runs), a case that cuts a second WAL SEGMENT between phases (so the segment walk has
# more than one segment with records in it), XOR2-with-ST cases, and two hand-written WALs — one whose
# series records name refs DESCENDING (so `EnsureOrder` matters) and one whose first ref is 7 (so
# adopting the WAL's refs matters).
#
# The corrupt-file case is worth keeping in mind: the chunk file's HEADER has to stay intact, because
# `NewChunkDiskMapper` validates the magic number when it opens the directory — a wholly garbled file
# fails construction and never reaches `Init`, so `removeCorruptedMmappedChunks` would not run at all.
#
# One survivor is DELIBERATE (the harness check). The other fourteen are proofs, and the biggest group
# is the same shape as the appender's: **a guard downstream already refuses what this one filters.**
#
#   * `samples already in an m-mapped chunk are replayed again` and `the m-mapped skip is off by one`.
#     Dropping the `s.T <= ms.mmMaxTime` skip does not change the head: `appendPreprocessor`'s FIRST
#     rejection route — "the timestamp is already in the mmapped chunks" — refuses every one of those
#     samples anyway. Which is a nice closing of a loop: §7f(d) recorded that route as unreachable
#     without replay, and replay is what reaches it. The `mmMaxTime` skip is a fast path, not a
#     correctness property.
#   * `a chunk entirely below minValidTime is loaded anyway`. Loading it widens `minTime`, and then
#     `Init`'s deferred clamp raises `minTime` back to `minValidTime` and the deferred `gc()` truncates
#     the chunk away. The filter and the clamp+GC agree.
#   * `a tombstone for an unknown series is applied`. `Init`'s deferred `gc()` calls
#     `tombstones.truncateBefore(minTime())`, and on a head with no series `minTime()` is `MaxInt64` —
#     which drops every tombstone. The guard and the GC agree.
#   * `the in-memory state is not reset before repair` and `the corrupted chunk file is not deleted`.
#     Both fallbacks converge: if `deleteCorrupted` does not run, the re-load fails again and
#     `truncate(MaxUint32)` discards the files — the same empty map, and the same samples recovered from
#     the WAL.
#   * `replay does not pass storeST`. `storeST` forces `appendPreprocessor` to cut when the desired
#     encoding differs from the chunk's. Every chunk a replay appends to is one the replay itself just
#     cut, so the encodings always agree and the override never decides. It would matter for a head
#     whose m-mapped chunks are XOR while ST storage is now on — which needs a config change across a
#     restart, i.e. §7j.
#
# UNREACHABLE WITHOUT A HAND-CRAFTED FILE:
#
#   * `a chunk with an invalid encoding is loaded`, `the out-of-sequence check allows an exact overlap`,
#     `there is no out-of-sequence check at all`. All three need a chunk FILE that a correct writer
#     cannot produce: an unknown encoding byte, or two chunks for one series whose ranges overlap.
#     §7d's corpus can seed such files but the Head's `Init` cannot be reached from there; a
#     seeded-chunk-file knob in `head/replay` would close them and is worth adding when something else
#     needs it.
#
# FIELDS AND GUARDS AWAITING THEIR READER:
#
#   * `the second-to-last ref is not tracked`. `secondLastRef` exists so a FAILED iteration reports the
#     ref before the failure; upstream returns it as `lastMmapRef`, which only the WBL replay (Phase 10)
#     consumes. The port computes and discards it, and says so.
#   * `an empty WAL directory is walked anyway`. `walSegments` answers `(-1, -1)` only for a directory
#     with no segments — and `WL.init` cuts segment 0, so a Head with a WAL always has one. The guard is
#     for a directory someone else emptied.
#   * `a tombstone for a remapped ref is not remapped` and `the mmap-ready counter is decremented too
#     eagerly during replay`. The first needs a WAL with both a duplicate series record and a tombstone
#     for the old ref; the second needs a replay that cuts a chunk on a series that already had two.
#     Both are constructible by hand and neither changes an answer the corpus reads — the mmap-ready
#     counter only shortcuts `mmapHeadChunks`, which `Close` calls anyway.
