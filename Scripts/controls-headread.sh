#!/usr/bin/env bash
# Negative controls for the Head's READ path — `HeadIndexReader`, `RangeHead`, `HeadChunkReader`,
# `memSeries.chunk`, `memSeries.iterator` and `stopIterator`.
#
# Two source files, so `run` takes the file it perturbed. The corpus is differential against the real
# `tsdb.Head`; the isolation-truncation case is the one that makes `memSeries.iterator` observable at all.
set -uo pipefail
cd "$(dirname "$0")/.."
IR=Sources/PromHead/HeadIndexReader.swift
CR=Sources/PromHead/HeadChunkReader.swift
cp "$IR" /tmp/hr-ir.orig
cp "$CR" /tmp/hr-cr.orig
restore() { cp /tmp/hr-ir.orig "$IR"; cp /tmp/hr-cr.orig "$CR"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$IR") orig=/tmp/hr-ir.orig ;;
    "$CR") orig=/tmp/hr-cr.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'HeadReadTests' 64
  restore
}

echo "=== indexRange's clamp, and the window checks ==="
perl -0pi -e 's~\Q        if hmin > mint {\E\n\Q            mint = hmin\E\n\Q        }\E~~' "$IR"; run "$IR" "indexRange does not clamp mint to the head's start"
perl -0pi -e 's~\Q        if hmin > mint {\E~        if hmin < mint {~' "$IR"; run "$IR" "the mint clamp is inverted"
perl -0pi -e 's~\Q        if maxt < head.minTime() || mint > head.maxTime() {\E\n\Q            return []\E\n\Q        }\E\n\Q\E\n\Q        if matchers.isEmpty {\E\n\Q            return head.postings.labelValues\E~        if matchers.isEmpty {\n            return head.postings.labelValues~' "$IR"; run "$IR" "LabelValues has no window check"
perl -0pi -e 's~\Q        if maxt < head.minTime() || mint > head.maxTime() {\E\n\Q            return []\E\n\Q        }\E\n\Q\E\n\Q        if matchers.isEmpty {\E\n\Q            var names = head.postings.labelNames()\E~        if matchers.isEmpty {\n            var names = head.postings.labelNames()~' "$IR"; run "$IR" "LabelNames has no window check"
perl -0pi -e 's~\Q            return head.postings.labelValues(name: name, limit: hints?.limit ?? 0)\E~            return head.postings.labelValues(name: name, limit: 1)~' "$IR"; run "$IR" "LabelValues always limits to one value"
perl -0pi -e 's~\Q            var names = head.postings.labelNames()\E\n\Q            names.sort()\E~            var names = head.postings.labelNames()~' "$IR"; run "$IR" "LabelNames does not sort"
perl -0pi -e 's~\Q        var values = try labelValues(name: name, hints: hints, matchers: matchers)\E\n\Q        values.sort()\E~        let values = try labelValues(name: name, hints: hints, matchers: matchers)~' "$IR"; run "$IR" "SortedLabelValues does not sort"

echo "=== SortedPostings ==="
perl -0pi -e 's~\Q        series.sort {\E[^\n]*~~' "$IR"; run "$IR" "SortedPostings does not sort"
perl -0pi -e 's~\Q        series.sort {\E[^\n]*~        series.sort { Labels.compare(\$1.labels(), \$0.labels()) < 0 }~' "$IR"; run "$IR" "SortedPostings sorts descending"
perl -0pi -e 's~\Q        series.sort {\E[^\n]*~        series.sort { \$0.ref.rawValue < \$1.ref.rawValue }~' "$IR"; run "$IR" "SortedPostings sorts by ref rather than by labels"
perl -0pi -e 's~\Q            if let s = head.series.getByID(HeadSeriesRef(rawValue: p.at().rawValue)) {\E\n\Q                series.append(s)\E\n\Q            } else {\E\n\Q                notFoundSeriesCount += 1\E\n\Q            }\E~            series.append(head.series.getByID(HeadSeriesRef(rawValue: p.at().rawValue))!)~' "$IR"; run "$IR" "SortedPostings traps on a missing series instead of dropping it"

echo "=== Series and its chunk metas ==="
perl -0pi -e 's~\Q        return (s.labels(), appendSeriesChunks(s, mint: mint, maxt: maxt, into: []))\E~        return (s.labels(), [])~' "$IR"; run "$IR" "Series never reports any chunks"
perl -0pi -e 's~\Q        return (s.labels(), appendSeriesChunks(s, mint: mint, maxt: maxt, into: []))\E~        return (s.labels(), appendSeriesChunks(s, mint: Int64.min, maxt: Int64.max, into: []))~' "$IR"; run "$IR" "Series ignores the reader's window"
perl -0pi -e 's~\Q        if !c.overlapsClosedInterval(mint, maxt) {\E\n\Q            continue\E\n\Q        }\E~~' "$IR"; run "$IR" "an mmapped chunk outside the window is still reported"
perl -0pi -e 's~\Q                    minTime: head.minTime, maxTime: Int64.max))\E~                    minTime: head.minTime, maxTime: head.maxTime))~' "$IR"; run "$IR" "the single open chunk reports its real maxTime"
perl -0pi -e 's~\Q        if i == buf.count - 1 {\E\n\Q            maxTime = Int64.max  // Open (newest) chunk.\E\n\Q        }\E~~' "$IR"; run "$IR" "the newest chunk in the list reports its real maxTime"
perl -0pi -e 's~\Q        if i == buf.count - 1 {\E~        if i == 0 {~' "$IR"; run "$IR" "the OLDEST chunk in the list is treated as open"
perl -0pi -e 's~\Q    if head.prev == nil {\E~    if false {~' "$IR"; run "$IR" "the single-head-chunk fast path is skipped"
perl -0pi -e 's~\Q                    ref: headChunkRef(s.ref, s.headChunkID(s.mmappedChunks.count + i)),\E~                    ref: headChunkRef(s.ref, s.headChunkID(i)),~' "$IR"; run "$IR" "head chunk refs do not skip the mmapped chunks"
perl -0pi -e 's~\Q        HeadChunkID(rawValue: UInt64(pos) &+ firstChunkID.rawValue)\E~        HeadChunkID(rawValue: UInt64(pos))~' "$IR"; run "$IR" "headChunkID ignores firstChunkID"

echo "=== LabelNamesFor ==="
perl -0pi -e 's~\Q            guard let s = head.series.getByID(HeadSeriesRef(rawValue: series.at().rawValue)) else {\E\n\Q                continue\E\n\Q            }\E~            let s = head.series.getByID(HeadSeriesRef(rawValue: series.at().rawValue))!~' "$IR"; run "$IR" "LabelNamesFor traps on a missing series"
perl -0pi -e 's~\Q        return namesMap.sorted()\E~        return Array(namesMap)~' "$IR"; run "$IR" "LabelNamesFor does not sort"

echo "=== RangeHead ==="
perl -0pi -e 's~\Q    public func blockMaxTime() -> Int64 { maxTime() &+ 1 }\E~    public func blockMaxTime() -> Int64 { maxTime() }~' "$IR"; run "$IR" "BlockMaxTime forgets the half-open +1"
perl -0pi -e 's~\Q    public func numSeries() -> UInt64 { head.seriesCount() }\E~    public func numSeries() -> UInt64 { 0 }~' "$IR"; run "$IR" "RangeHead reports no series"
perl -0pi -e 's~\Q        head.indexRange(mint: mint, maxt: maxt)\E~        head.index()~' "$IR"; run "$IR" "RangeHead's index ignores its window"
perl -0pi -e 's~\Q        return try head.chunksRange(mint: mint, maxt: maxt, isoState: isoState)\E~        return try head.chunksRange(mint: Int64.min, maxt: Int64.max, isoState: isoState)~' "$IR"; run "$IR" "RangeHead's chunk reader ignores its window"
perl -0pi -e 's~\Q        if !isolationOff {\E~        if isolationOff {~' "$IR"; run "$IR" "RangeHead inverts its isolation switch"
perl -0pi -e 's~\Q    public var description: String { "range head (mint: \(minTime()), maxt: \(maxTime()))" }\E~    public var description: String { "range head" }~' "$IR"; run "$IR" "RangeHead's String drops its window"
perl -0pi -e 's~\Q    guard let u = ULID("0000000000XXXXXXXRANGEHEAD") else {\E~    guard let u = ULID("0000000000XXXXXXXXXXXXHEAD") else {~' "$IR"; run "$IR" "RangeHead uses the Head's ULID"

echo "=== chunksRange and the closed head ==="
perl -0pi -e 's~\Q        if closed {\E\n\Q            throw HeadReadError.closedHead\E\n\Q        }\E~~' "$CR"; run "$CR" "a closed head still hands out chunk readers"
perl -0pi -e 's~\Q        if hmin > mint {\E\n\Q            mint = hmin\E\n\Q        }\E\n\Q        return HeadChunkReader\E~        return HeadChunkReader~' "$CR"; run "$CR" "chunksRange does not clamp mint"
# The message contains an apostrophe, so the pattern matches a SUBSTRING after it — a single-quoted perl
# program cannot carry one.
perl -0pi -e 's~\Qt read from a closed head\E~t read from a shut head~g' "$CR"; run "$CR" "the closed-head message is reworded"
perl -0pi -e 's~\Q        isoState?.close()\E~~' "$CR"; run "$CR" "the chunk reader does not close its isolation state"

echo "=== chunkFromSeries ==="
perl -0pi -e 's~\Q        if !c.overlapsClosedInterval(mint, maxt) {\E\n\Q            throw StorageError.notFound\E\n\Q        }\E~~' "$CR"; run "$CR" "a chunk outside the reader's window is returned anyway"
perl -0pi -e 's~\Q        if isHeadChunk && isOpen && copyLastChunk {\E~        if isHeadChunk \&\& isOpen \&\& !copyLastChunk {~' "$CR"; run "$CR" "the copy path is taken when a copy was NOT asked for"
perl -0pi -e 's~\Q            chk = try newEmptyChunk(c.chunk.encoding)\E\n\Q            chk.reset(c.chunk.bytes)\E~            chk = try newEmptyChunk(c.chunk.encoding)~' "$CR"; run "$CR" "the copied chunk is empty"
perl -0pi -e 's~\Q            SafeHeadChunk(chunk: chk, series: s, cid: cid, isoState: isoState), maxTime\E~            chk, maxTime~' "$CR"; run "$CR" "the chunk is returned unwrapped, so isolation cannot truncate it"
perl -0pi -e 's~\Q        let maxTime = c.maxTime\E~        let maxTime = Int64.max~' "$CR"; run "$CR" "the returned maxTime is always MaxInt64"

echo "=== memSeries.chunk's index arithmetic ==="
perl -0pi -e 's~\Q        var ix = Int(id.rawValue) - Int(firstChunkID.rawValue)\E\n\Q\E\n\Q        var headChunksLen = 0\E~        var ix = Int(id.rawValue)\n\n        var headChunksLen = 0~' "$CR"; run "$CR" "chunk(id:) ignores firstChunkID"
perl -0pi -e 's~\Q        if ix < 0 || ix > mmappedChunks.count + headChunksLen - 1 {\E~        if ix < 0 || ix > mmappedChunks.count + headChunksLen {~' "$CR"; run "$CR" "the chunk-id bound is off by one"
perl -0pi -e 's~\Q        if ix < mmappedChunks.count {\E~        if ix <= mmappedChunks.count {~' "$CR"; run "$CR" "the mmapped/head split is off by one"
perl -0pi -e 's~\Q        let offset = headChunksLen - ix - 1\E~        let offset = ix~' "$CR"; run "$CR" "the head-chunk index is not reversed"
perl -0pi -e 's~\Q        return (elem, true, offset == 0)\E~        return (elem, true, offset == headChunksLen - 1)~' "$CR"; run "$CR" "the OLDEST head chunk is reported as the open one"
perl -0pi -e 's~\Q                    chunk: chk, minTime: mmappedChunks[ix].minTime,\E\n\Q                    maxTime: mmappedChunks[ix].maxTime, prev: nil),\E~                    chunk: chk, minTime: mmappedChunks[ix].maxTime,\n                    maxTime: mmappedChunks[ix].minTime, prev: nil),~' "$CR"; run "$CR" "an mmapped chunk's times are swapped"
perl -0pi -e 's~\Q            return (headChunks[ix], true, ix == headChunks.count - 1)\E~            return (headChunks[ix], true, false)~' "$CR"; run "$CR" "the pre-collected path never reports the open chunk"

echo "=== memSeries.iterator and stopAfter ==="
perl -0pi -e 's~\Q        if let isoState, !isoState.isolationDisabled {\E~        if let isoState, isoState.isolationDisabled {~' "$CR"; run "$CR" "the isolation truncation runs only when isolation is DISABLED"
perl -0pi -e 's~\Q        if let isoState, !isoState.isolationDisabled {\E~        if false, let isoState, !isoState.isolationDisabled {~' "$CR"; run "$CR" "there is no isolation truncation at all"
perl -0pi -e 's~\Q                if j < ix {\E\n\Q                    previousSamples += Int(d.numSamples)\E\n\Q                }\E~~' "$CR"; run "$CR" "mmapped samples are not counted as preceding"
perl -0pi -e 's~\Q                    if headChunksLen - 1 - j < ix {\E~                    if j < ix {~' "$CR"; run "$CR" "the head-chunk position is not reversed when counting"
perl -0pi -e 's~\Q            let appendIDsToConsider = Int(txs?.count ?? 0) - (totalSamples - (previousSamples + numSamples))\E~            let appendIDsToConsider = Int(txs?.count ?? 0)~' "$CR"; run "$CR" "every append ID is considered, not just this chunk's"
perl -0pi -e 's~\Q                    if appendID <= isoState.maxAppendID {  // Easy check first.\E~                    if appendID < isoState.maxAppendID {  \/\/ Easy check first.~' "$CR"; run "$CR" "the appender's own ID is treated as invisible"
perl -0pi -e 's~\Q                        if !isoState.incompleteAppends.contains(appendID) {\E~                        if isoState.incompleteAppends.contains(appendID) {~' "$CR"; run "$CR" "the incomplete-append test is inverted"
perl -0pi -e 's~\Q                    stopAfter = max(numSamples - (appendIDsToConsider - index), 0)\E~                    stopAfter = 0~' "$CR"; run "$CR" "any invisible append hides the whole chunk"
perl -0pi -e 's~\Q        if stopAfter == 0 {\E\n\Q            return newNopIterator()\E\n\Q        }\E~~' "$CR"; run "$CR" "a fully invisible chunk returns a real iterator"
perl -0pi -e 's~\Q        if stopAfter == numSamples {\E\n\Q            return c.iterator(reuse)\E\n\Q        }\E~~' "$CR"; run "$CR" "a fully visible chunk goes through the stop iterator"

echo "=== stopIterator ==="
perl -0pi -e 's~\Q        if i + 1 >= stopAfter {\E~        if i >= stopAfter {~' "$CR"; run "$CR" "stopIterator yields one sample too many"
perl -0pi -e 's~\Q        i += 1\E\n\Q        return inner.next()\E~        return inner.next()~' "$CR"; run "$CR" "stopIterator never advances its counter"
perl -0pi -e 's~\Q    return StopIterator(inner: c.iterator(reuse), i: -1, stopAfter: stopAfter)\E~    return StopIterator(inner: c.iterator(reuse), i: 0, stopAfter: stopAfter)~' "$CR"; run "$CR" "stopIterator starts at 0 rather than -1"
perl -0pi -e 's~\Q    if let stopIter = reuse as? StopIterator {\E~    if false, let stopIter = reuse as? StopIterator {~' "$CR"; run "$CR" "a reusable stop iterator is not reused"
perl -0pi -e 's~\Q        stopIter.i = -1\E~~' "$CR"; run "$CR" "a reused stop iterator keeps its old position"

echo "=== SafeHeadChunk ==="
perl -0pi -e 's~\Q        series.iterator(id: cid, chunk: underlying, isoState: isoState, reuse: reuse)\E~        underlying.iterator(reuse)~' "$CR"; run "$CR" "SafeHeadChunk hands out the chunk's own iterator"
perl -0pi -e 's~\Q    public var numSamples: Int { underlying.numSamples }\E~    public var numSamples: Int { 0 }~' "$CR"; run "$CR" "SafeHeadChunk reports no samples"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q        var stopAfter = numSamples\E~        var stopAfter = numSamples\n        _ = stopAfter~' "$CR"; run "$CR" "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 63 controls: 51 broke, 12 SURVIVED, 0 SKIP, 0 COMPILE.
#
# (The closed-head-message control needed `/g`: the message appears in a doc comment BEFORE the code, and
# perl's default single replacement was perturbing the comment. A control that patches a comment measures
# nothing and reads exactly like a corpus gap — worth remembering.)
#
# The first run scored 34/63, and the gap was almost all corpus: a read-path corpus that never
# M-MAPS, never closes the head, never opens a reader before the first commit and never asks for a
# window that excludes a chunk is measuring one code path out of four. What closed them:
#
#   * **`mmapHeadChunks` is unexported upstream** and its only callers are `db.go`'s goroutine and
#     `Close` — so the mmapped read path CANNOT be reached differentially through the Head, and the
#     assertions for it are hand-written on top of facts the corpus does pin (§7d's chunk files,
#     §7f(d)'s bookkeeping, this suite's in-memory metas).
#   * **Two head chunks alongside mmapped ones** is the only state where `appendSeriesChunks` has to add
#     `mmappedChunks.count` to the head position; with a single head chunk the fast path hides it.
#   * **A reader's window can be EMPTY**: `chunksRange` clamps `mint` up to `MinTime()`, which is
#     `MaxInt64` on an uninitialised head — so a reader opened before the first sample rejects every
#     chunk as out of range rather than truncating it. That is a different code path from
#     `stopAfter == 0`, and reaching the latter needs a later commit to cut a NEW chunk.
#
# One survivor is DELIBERATE (the harness check). The other twelve split four ways.
#
# METRICS OR LOGS ONLY:
#
#   * `SortedPostings traps on a missing series instead of dropping it` and `LabelNamesFor traps on a
#     missing series`. Both skip-and-continue arms exist for one reason: compaction can garbage-collect
#     a series between a caller taking the refs and using them. Upstream counts the misses and logs at
#     debug level; nothing else observes them, and the port has no logger. Reaching them needs `gc()`,
#     which is §7h. Until then a missing series is unreachable and the guard is unobservable.
#
# TAUTOLOGIES:
#
#   * `a fully visible chunk goes through the stop iterator`. Removing the `stopAfter == numSamples`
#     shortcut makes every read build a `StopIterator` bounded at exactly `numSamples` — which yields
#     exactly the same samples. The shortcut is an allocation, not a decision.
#   * `the copy path is taken when a copy was NOT asked for`. `copyLastChunk` exists so a caller can take
#     the open chunk's bytes without racing an appender. The port's copy is `newEmptyChunk` + `reset`,
#     which produces an equal chunk, and with no concurrency there is nothing to race — so taking the
#     path unconditionally changes an allocation. (The copy being EMPTY *does* break, now that the
#     corpus reads the copied chunk rather than only its max time.)
#   * `the single-head-chunk fast path is skipped`. The fast path and the list walk agree for a
#     one-element list: both report `minTime` and `MaxInt64`. Upstream keeps it to avoid the walk.
#   * `the chunk-id bound is off by one`. `ix > mmappedChunks.count + headChunksLen - 1` versus
#     `>= ...`: the extra id the weaker test admits then fails the head-chunk lookup below
#     (`atOffset` walks off the list and answers nil), so both answer `ErrNotFound`. Two guards, one
#     outcome — which is worth knowing, because it means the bound is not the safety property.
#
# UNREACHED FEATURES, each with its owner:
#
#   * `the pre-collected path never reports the open chunk`. The head-chunk CACHE (`enableCache` and its
#     four fingerprint fields) is not ported — pure memoisation — so nothing passes the optional
#     pre-collected slice and its branch is dead. The seam is kept because that is where the cache goes.
#   * `the head-chunk position is not reversed when counting` in `memSeries.iterator`. Distinguishing
#     `headChunksLen - 1 - j < ix` from `j < ix` needs an invisible append whose samples sit in a MIDDLE
#     head chunk — i.e. three or more head chunks with the isolation boundary inside the second. The
#     corpus can build the state but not the boundary, because a commit always appends to the newest
#     chunk. `head_wal.go`'s replay (§7h) can, since it installs chunks directly.
#   * `RangeHead's chunk reader ignores its window` and `chunksRange does not clamp mint` — wait, the
#     second one now breaks; the first survives because every `RangeHead` case whose window excludes a
#     chunk excludes it at the INDEX level too, so the chunk reader is never asked. Asking it directly
#     is what `mmappedReadPath` does for the Head's own reader.
#   * `the chunk reader does not close its isolation state`. Leaking a read pin is observable only to a
#     head truncation that waits for readers (`WaitForPendingReadersInTimeRange`), which is §7h/§7j —
#     the same argument as the appender's `closeAppend` (see `controls-headappend.sh`).
#
