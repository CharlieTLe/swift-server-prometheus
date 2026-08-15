#!/usr/bin/env bash
# Negative controls for the Head's core — `NewHead`'s validation and option normalisation, the time-window
# sentinels, series creation, m-mapping and `Close`.
#
# The corpus here is differential against the REAL `tsdb.NewHead` (no probe package), plus four hand-written
# assertions for the unexported members whose corpus arrives with the appender: `compactable`,
# `updateMinMaxTime`, `getOrCreate`'s ID allocation and `mmapHeadChunks`' two tests. This sweep asks whether
# either kind of test can SEE each line.
#
# Search sides use perl's \Q...\E with `~` delimiters, so Swift source pastes literally and a stale pattern
# reports SKIP rather than silently matching nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
HD=Sources/PromHead/Head.swift
cp "$HD" /tmp/hd-hd.orig
restore() { cp /tmp/hd-hd.orig "$HD"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$HD" /tmp/hd-hd.orig
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'HeadCoreTests' 64
  restore
}

echo "=== NewHead's validation ==="
perl -0pi -e 's~\Qif capMax <= 0 || capMax > 255 {\E~if capMax < 0 || capMax > 255 {~' "$HD"; run "an OOOCapMax of 0 is accepted"
perl -0pi -e 's~\Qif capMax <= 0 || capMax > 255 {\E~if capMax <= 0 || capMax >= 255 {~' "$HD"; run "the OOOCapMax upper bound excludes 255"
perl -0pi -e 's~\Qthrow HeadError.invalidOOOCapMax(capMax)\E~throw HeadError.invalidChunkRange(capMax)~' "$HD"; run "the OOOCapMax failure reports the chunk-range message"
perl -0pi -e 's~\Qif opts.chunkRange < 1 {\E~if opts.chunkRange < 0 {~' "$HD"; run "a chunk range of 0 is accepted"
perl -0pi -e 's~\Qreturn "OOOCapMax of \(c) is invalid. must be > 0 and <= 255"\E~return "OOOCapMax of \(c) is invalid. must be > 0 and <= 255."~' "$HD"; run "the OOOCapMax message gains a full stop"
perl -0pi -e 's~\Qreturn "invalid chunk range \(r)"\E~return "invalid chunk range"~' "$HD"; run "the chunk-range message drops the value"
# The ORDER of the two checks: a Head with both invalid must report the OOO one.
perl -0pi -e 's~\Q        let capMax = opts.outOfOrderCapMax\E~        if opts.chunkRange < 1 {\n            throw HeadError.invalidChunkRange(opts.chunkRange)\n        }\n        let capMax = opts.outOfOrderCapMax~' "$HD"; run "the chunk range is validated BEFORE the OOO cap"

echo "=== NewHead's mutations of the options it was handed ==="
perl -0pi -e 's~\Q        if opts.outOfOrderTimeWindow < 0 {\E\n\Q            opts.outOfOrderTimeWindow = 0\E\n\Q        }\E~~' "$HD"; run "a negative OOO time window is not clamped"
perl -0pi -e 's~\Q            opts.outOfOrderTimeWindow = 0\E~            opts.outOfOrderTimeWindow = -opts.outOfOrderTimeWindow~' "$HD"; run "the negative OOO window is negated rather than zeroed"
perl -0pi -e 's~\Q        if !opts.enableExemplarStorage {\E\n\Q            opts.maxExemplars = 0\E\n\Q        }\E~~' "$HD"; run "MaxExemplars survives with exemplar storage disabled"
perl -0pi -e 's~\Q        if !opts.enableExemplarStorage {\E~        if opts.enableExemplarStorage {~' "$HD"; run "MaxExemplars is zeroed when exemplars are ENABLED"
perl -0pi -e 's~\Q        if opts.seriesCallback == nil {\E\n\Q            opts.seriesCallback = NoopSeriesLifecycleCallback()\E\n\Q        }\E~~' "$HD"; run "a nil series callback is left nil"
perl -0pi -e 's~\Q        if opts.walReplayConcurrency <= 0 {\E\n\Q            opts.walReplayConcurrency = Head.defaultWALReplayConcurrency\E\n\Q        }\E~~' "$HD"; run "a non-positive WAL replay concurrency is left alone"
perl -0pi -e 's~\Q        if opts.walReplayConcurrency <= 0 {\E~        if opts.walReplayConcurrency < 0 {~' "$HD"; run "a WAL replay concurrency of 0 is not replaced"

echo "=== The fresh state and its sentinels ==="
perl -0pi -e 's~\Q    var minTimeValue: Int64 = Int64.max\E~    var minTimeValue: Int64 = 0~' "$HD"; run "minTime starts at 0 rather than MaxInt64"
perl -0pi -e 's~\Q    var maxTimeValue: Int64 = Int64.min\E~    var maxTimeValue: Int64 = 0~' "$HD"; run "maxTime starts at 0 rather than MinInt64"
perl -0pi -e 's~\Q    var minOOOTimeValue: Int64 = Int64.max\E~    var minOOOTimeValue: Int64 = Int64.min~' "$HD"; run "minOOOTime starts at MinInt64"
perl -0pi -e 's~\Q    var maxOOOTimeValue: Int64 = Int64.min\E~    var maxOOOTimeValue: Int64 = Int64.max~' "$HD"; run "maxOOOTime starts at MaxInt64"
perl -0pi -e 's~\Q        self.chunkRange = opts.chunkRange\E~        self.chunkRange = defaultBlockDuration~' "$HD"; run "the head ignores the configured chunk range"
perl -0pi -e 's~\Q            stripeSize: opts.stripeSize,\E\n\Q            seriesCallback: opts.seriesCallback ?? NoopSeriesLifecycleCallback())\E\n\Q        self.postings\E~            stripeSize: defaultStripeSize,\n            seriesCallback: opts.seriesCallback ?? NoopSeriesLifecycleCallback())\n        self.postings~' "$HD"; run "the series index ignores the configured stripe size"
perl -0pi -e 's~\Q        self.postings = MemPostings.newUnordered()\E~        self.postings = MemPostings()~' "$HD"; run "the postings start ORDERED rather than unordered"

echo "=== initialized / compactable / the time window ==="
perl -0pi -e 's~\Q    public func initialized() -> Bool { minTime() != Int64.max }\E~    public func initialized() -> Bool { minTime() != Int64.min }~' "$HD"; run "initialized compares against MinInt64"
perl -0pi -e 's~\Q        return maxTime() - minTime() > chunkRange / 2 * 3\E~        return maxTime() - minTime() > chunkRange * 3 / 2~' "$HD"; run "compactable multiplies before dividing"
perl -0pi -e 's~\Q        return maxTime() - minTime() > chunkRange / 2 * 3\E~        return maxTime() - minTime() >= chunkRange / 2 * 3~' "$HD"; run "compactable's threshold is inclusive"
perl -0pi -e 's~\Q        if !initialized() {\E\n\Q            return false\E\n\Q        }\E\n\Q        return maxTime() - minTime() > chunkRange / 2 * 3\E~        return maxTime() - minTime() > chunkRange \/ 2 * 3~' "$HD"; run "compactable does not check initialized first"
perl -0pi -e 's~\Q        if mint < minTimeValue {\E\n\Q            minTimeValue = mint\E\n\Q        }\E~        minTimeValue = mint~' "$HD"; run "updateMinMaxTime overwrites minTime instead of widening"
perl -0pi -e 's~\Q        if maxt > maxTimeValue {\E\n\Q            maxTimeValue = maxt\E\n\Q        }\E~        maxTimeValue = maxt~' "$HD"; run "updateMinMaxTime overwrites maxTime instead of widening"
perl -0pi -e 's~\Q        if mint < minTimeValue {\E~        if mint > minTimeValue {~' "$HD"; run "updateMinMaxTime's minTime comparison is inverted"
perl -0pi -e 's~\Q        minTime() <= maxt && mint <= maxTime()\E~        minTime() < maxt \&\& mint < maxTime()~' "$HD"; run "OverlapsClosedInterval is open at both ends"

echo "=== appendableMinValidTime ==="
perl -0pi -e 's~\Q        let cwEnd = maxTime() - chunkRange / 2\E~        let cwEnd = maxTime() - chunkRange~' "$HD"; run "the compaction-window boundary uses the whole chunk range"
perl -0pi -e 's~\Q        return max(cwEnd, minValidTimeValue)\E~        return min(cwEnd, minValidTimeValue)~' "$HD"; run "appendableMinValidTime takes the MIN of its two boundaries"
perl -0pi -e 's~\Q        return max(cwEnd, minValidTimeValue)\E~        return minValidTimeValue~' "$HD"; run "appendableMinValidTime ignores the compaction window"
perl -0pi -e 's~\Q        if !initialized() {\E\n\Q            return (0, false)\E\n\Q        }\E~~' "$HD"; run "AppendableMinValidTime answers for an uninitialised head"
perl -0pi -e 's~\Q            return (0, false)\E~            return (minValidTimeValue, false)~' "$HD"; run "the uninitialised answer leaks minValidTime instead of 0"

echo "=== Meta, Size and the directory ==="
perl -0pi -e 's~\Q        var m = BlockMeta(ulid: headULID, minTime: minTime(), maxTime: maxTime())\E~        var m = BlockMeta(ulid: headULID, minTime: maxTime(), maxTime: minTime())~' "$HD"; run "Meta swaps the head's min and max times"
perl -0pi -e 's~\Q        m.stats.numSeries = numSeries\E~~' "$HD"; run "Meta does not report the series count"
perl -0pi -e 's~\Q    guard let u = ULID("0000000000XXXXXXXXXXXXHEAD") else {\E~    guard let u = ULID("0000000000XXXXXXXRANGEHEAD") else {~' "$HD"; run "the head ULID is the RangeHead sentinel"
perl -0pi -e 's~\Q    public var description: String { "head" }\E~    public var description: String { "Head" }~' "$HD"; run "String() is capitalised"
perl -0pi -e 's~\Q            walSize = (try? wal.size()) ?? 0\E~            walSize = 0~' "$HD"; run "Size ignores the WAL"
perl -0pi -e 's~\Q        return walSize + cdmSize\E~        return cdmSize~' "$HD"; run "Size returns the chunk files alone"
perl -0pi -e 's~\Q    dir.isEmpty ? "chunks_head" : "\(dir)/chunks_head"\E~    dir.isEmpty ? "chunks_head" : "\(dir)/chunks"~' "$HD"; run "the chunk directory is named chunks rather than chunks_head"

echo "=== getOrCreate ==="
perl -0pi -e 's~\Q        if let s = series.getByHash(hash: hash, labels: lset) {\E\n\Q            return (s, false)\E\n\Q        }\E~~' "$HD"; run "getOrCreate skips the hash lookup"
perl -0pi -e 's~\Q        var id = id\E\n\Q        if id.rawValue == 0 {\E\n\Q            lastSeriesID += 1\E\n\Q            id = HeadSeriesRef(rawValue: lastSeriesID)\E\n\Q        }\E~        var id = id\n        if id.rawValue == 0 {\n            id = HeadSeriesRef(rawValue: lastSeriesID)\n            lastSeriesID += 1\n        }~' "$HD"; run "the series ID is POST-incremented, so the first series is 0"
perl -0pi -e 's~\Q        if let callback = opts.seriesCallback {\E\n\Q            try callback.preCreation(lset)\E\n\Q        }\E~~' "$HD"; run "preCreation is never consulted"
perl -0pi -e 's~\Q        var shardHash: UInt64 = 0\E\n\Q        if opts.enableSharding {\E\n\Q            shardHash = lset.stableHash()\E\n\Q        }\E~        let shardHash: UInt64 = lset.stableHash()~' "$HD"; run "the shard hash is computed even without sharding"
perl -0pi -e 's~\Q        numSeries += 1\E~~' "$HD"; run "the series count does not move on creation"
perl -0pi -e 's~\Q        postings.add(id: SeriesRef(rawValue: id.rawValue), labels: lset)\E~~' "$HD"; run "a new series is not added to the postings"
perl -0pi -e 's~\Q        series.postCreation(labels: lset)\E~~' "$HD"; run "postCreation is not called"
perl -0pi -e 's~\Q        if !created {\E\n\Q            return (s, false)\E\n\Q        }\E~~' "$HD"; run "an existing series is counted as created"

echo "=== onChunkCreated and mmapHeadChunks ==="
perl -0pi -e 's~\Q        if prevHeadChunkCount < 2 && s.headChunkCount == 2 {\E~        if s.headChunkCount == 2 {~' "$HD"; run "the mmap-ready transition drops the previous-count test"
perl -0pi -e 's~\Q        if prevHeadChunkCount < 2 && s.headChunkCount == 2 {\E~        if prevHeadChunkCount < 2 \&\& s.headChunkCount >= 2 {~' "$HD"; run "the mmap-ready test fires on every chunk past the second"
perl -0pi -e 's~\Q            series.incMmapReady(s.ref)\E~            series.decMmapReady(s.ref)~' "$HD"; run "onChunkCreated decrements the mmap-ready counter"
perl -0pi -e 's~\Q            if series.mmapReady[i] == 0 {\E\n\Q                continue  // No series in this stripe needs m-mapping.\E\n\Q            }\E~~' "$HD"; run "mmapHeadChunks visits every stripe regardless of the counter"
perl -0pi -e 's~\Q                if s.headChunkCount < 2 {  // 0 or 1 head chunks: nothing to m-map.\E\n\Q                    continue\E\n\Q                }\E~~' "$HD"; run "mmapHeadChunks does not re-check the per-series count"
perl -0pi -e 's~\Q                if n > 0 {\E\n\Q                    count += n\E\n\Q                    series.decMmapReady(s.ref)\E\n\Q                }\E~                count += n~' "$HD"; run "the mmap-ready counter is never cleared"
perl -0pi -e 's~\Q                if n > 0 {\E~                if n >= 0 {~' "$HD"; run "the counter is cleared even when nothing was written"

echo "=== Close ==="
perl -0pi -e 's~\Q        mmapHeadChunks()\E~~' "$HD"; run "Close does not m-map before closing"
perl -0pi -e 's~\Q        do { try chunkDiskMapper.close() } catch { first = first ?? error }\E~~' "$HD"; run "Close leaves the chunk mapper open"
perl -0pi -e 's~\Q        closed = true\E~        closed = false~' "$HD"; run "Close does not mark the head closed"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q        var count = 0\E\n\Q        for i in 0..<series.size {\E~        var count = 0\n        _ = count\n        for i in 0..<series.size {~' "$HD"; run "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 60 controls: 54 broke, 6 SURVIVED, 0 SKIP, 0 COMPILE.
#
# The first run of this sweep scored 41/60, and the nineteen survivors were almost all corpus gaps
# rather than proofs — a fresh Head answers so little that the stripe size, the postings' order, the
# shard hash, both lifecycle callbacks, `Meta`'s series count, `appendableMinValidTime`'s two boundaries
# and everything `Close` does were unobserved. Thirteen of them closed by adding assertions for state
# the corpus cannot reach (a Head with samples in it) and one by committing the head DIRECTORY listing
# rather than only the chunk directory's contents, which is what makes the name `chunks_head` visible.
# That is the lesson to carry: **a constructor-only corpus measures a constructor, not a type.**
#
# One survivor is DELIBERATE — the `harness check` inserts an inert `_ = count`, proving `broke` is not
# the harness's default (see `lib/control-run.sh`). The other five are proofs.
#
# FOUR TAUTOLOGIES, all in the m-mapping bookkeeping, and together they say something worth knowing:
# `mmapReady` is a performance shortcut whose every test is redundant with a test somewhere else.
#
#   * `the mmap-ready test fires on every chunk past the second` — `prevHeadChunkCount < 2 &&
#     headChunkCount == 2` versus `>= 2`. The count rises by exactly one per cut, so `prev < 2` already
#     restricts the pair to the single transition 1 -> 2; widening the second test cannot add a case.
#
#   * `mmapHeadChunks visits every stripe regardless of the counter` — the stripe's counter is only
#     consulted to SKIP work. Every series it would have skipped is then rejected by the per-series
#     `headChunkCount < 2`, so removing the outer test changes the cost and not the answer. (It could
#     differ if the counter were stale LOW, i.e. if a caller cut chunks without calling
#     `onChunkCreated` — which upstream never does.)
#
#   * `mmapHeadChunks does not re-check the per-series count` — the mirror image: `memSeries.mmapChunks`
#     has the same guard internally (`headChunks.prev == nil` returns 0), so a series with one chunk
#     answers 0 either way.
#
#   * `the counter is cleared even when nothing was written` — `if n > 0` versus `n >= 0`. A series is
#     only reached when it has two or more head chunks, and `mmapChunks` on such a series always writes
#     at least one, so `n == 0` is unreachable at that point.
#
# ONE FIELD AWAITING ITS READER:
#
#   * `Close does not mark the head closed` — `closed` has no reader in the port yet. Upstream's only
#     one is `head_read.go:452`, where a `headChunkReader` refuses a closed Head, and that is §7g. The
#     field is carried rather than dropped for the same reason `memSeries.mmMaxTime` is; this control
#     must break once §7g lands.
