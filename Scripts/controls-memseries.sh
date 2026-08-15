#!/usr/bin/env bash
# Negative controls for `memSeries`' chunk state — the four cut grounds, the linked list, `appendable`'s
# verdicts, m-mapping and truncation.
#
# The corpus IS differential (a lift of the unexported upstream code, see `oracle/probe/headmemseries`), so
# this sweep asks the other question: does every line of the port have a case that can SEE it? A survivor here
# is a hypothesis about the corpus, not a pass — quirks 159/160/163/166 say which four things it can mean.
#
# The search sides use perl's \Q...\E so the Swift source can be pasted literally; a pattern that stops
# matching after an edit reports SKIP, which is loud.
set -uo pipefail
cd "$(dirname "$0")/.."
MS=Sources/PromHead/MemSeries.swift
cp "$MS" /tmp/ms-ms.orig
restore() { cp /tmp/ms-ms.orig "$MS"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$MS" /tmp/ms-ms.orig
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'MemSeriesTests' 64
  restore
}

echo "=== rangeForTimestamp (db.go's, and quirk 184) ==="
perl -0pi -e 's~\Q    (t / width) * width + width\E~    Int64((Double(t) / Double(width)).rounded(.down)) * width + width~' "$MS"; run "rangeForTimestamp floors instead of truncating toward zero"
perl -0pi -e 's~\Q    (t / width) * width + width\E~    (t / width) * width~' "$MS"; run "rangeForTimestamp returns the window START, not the next one"

echo "=== computeChunkEndTime ==="
perl -0pi -e 's~\Q    if n <= 1 {\E~    if n < 1 {~' "$MS"; run "computeChunkEndTime's n<=1 short circuit is strict"
perl -0pi -e 's~\Q/ n.rounded(.down))\E~/ n.rounded(.up))~' "$MS"; run "computeChunkEndTime rounds n up"
perl -0pi -e 's~\Q/ n.rounded(.down))\E~/ n)~' "$MS"; run "computeChunkEndTime does not floor n at all"
perl -0pi -e 's~\QDouble(cur &- start &+ 1)\E~Double(cur &- start)~' "$MS"; run "computeChunkEndTime drops the +1 on the elapsed span"

echo "=== overlapsClosedInterval and the linked list ==="
perl -0pi -e 's~\Q    mint1 <= maxt2 && mint2 <= maxt1\E~    mint1 < maxt2 \&\& mint2 < maxt1~' "$MS"; run "overlapsClosedInterval is open at both ends"
perl -0pi -e 's~\Q        if offset == 1 { return prev }\E~        if offset == 1 { return self }~' "$MS"; run "atOffset(1) returns the element itself"
perl -0pi -e 's~\Q        if offset < 0 { return nil }\E~        if offset < 0 { return self }~' "$MS"; run "a negative atOffset answers the head rather than nil"
perl -0pi -e 's~\Q        if prev == nil { return 1 }\E~        if prev == nil { return 0 }~' "$MS"; run "len() of a single-element list is 0"
perl -0pi -e 's~\Q    hc.reverse()\E~~' "$MS"; run "collectHeadChunks leaves the list newest-first"
perl -0pi -e 's~\Q    while let p = elem.prev { elem = p }\E~    if let p = elem.prev { elem = p }~' "$MS"; run "oldest() walks back exactly one link"

echo "=== minTime / maxTime ==="
perl -0pi -e 's~\Q        if !mmappedChunks.isEmpty {\E\n\Q            return mmappedChunks[0].minTime\E\n\Q        }\E\n\Q        if let headChunks {\E\n\Q            return headChunks.oldest().minTime\E\n\Q        }\E~        if let headChunks {\n            return headChunks.oldest().minTime\n        }\n        if !mmappedChunks.isEmpty {\n            return mmappedChunks[0].minTime\n        }~' "$MS"; run "minTime prefers the head chunks over the mmapped ones"
perl -0pi -e 's~\Q            return headChunks.oldest().minTime\E~            return headChunks.minTime~' "$MS"; run "minTime reads the NEWEST head chunk's minTime"
perl -0pi -e 's~\Q            return mmappedChunks[0].minTime\E~            return mmappedChunks[mmappedChunks.count - 1].minTime~' "$MS"; run "minTime reads the last mmapped chunk"
perl -0pi -e 's~\Q        if let headChunks {\E\n\Q            return headChunks.maxTime\E\n\Q        }\E\n\Q        if let last = mmappedChunks.last {\E\n\Q            return last.maxTime\E\n\Q        }\E~        if let last = mmappedChunks.last {\n            return last.maxTime\n        }\n        if let headChunks {\n            return headChunks.maxTime\n        }~' "$MS"; run "maxTime prefers the mmapped chunks over the head chunk"
perl -0pi -e 's~\Q        if let last = mmappedChunks.last {\E~        if let last = mmappedChunks.first {~' "$MS"; run "maxTime reads the FIRST mmapped chunk"

echo "=== truncateChunksBefore ==="
perl -0pi -e 's~\Q                if c.maxTime < mint {\E~                if c.maxTime <= mint {~' "$MS"; run "truncate drops a head chunk whose maxTime IS mint"
perl -0pi -e 's~\Q                    removedInOrder = c.len() + mmappedChunks.count\E~                    removedInOrder = c.len()~' "$MS"; run "the head-chunk branch does not count the mmapped chunks"
perl -0pi -e 's~\Q                    mmappedChunks = []\E~~' "$MS"; run "truncating a head chunk keeps the mmapped chunks"
perl -0pi -e 's~\Q                    if i == 0 {\E~                    if i != 0 {~' "$MS"; run "the first-chunk test in the head walk is inverted"
perl -0pi -e 's~\Q                        nextChk?.prev = nil\E~~' "$MS"; run "the truncated tail is never unlinked"
perl -0pi -e 's~\Q                        headChunkCount = i\E~                        headChunkCount = 0~' "$MS"; run "a partial head truncation zeroes the chunk count"
perl -0pi -e 's~\Q                if c.maxTime < mint {\E\n\Q                    // If any head chunk is truncated, we can truncate all mmapped chunks.\E\n\Q                    removedInOrder = c.len() + mmappedChunks.count\E\n\Q                    firstChunkID = HeadChunkID(\E\n\Q                        rawValue: firstChunkID.rawValue &+ UInt64(removedInOrder))\E~                if c.maxTime < mint {\n                    // If any head chunk is truncated, we can truncate all mmapped chunks.\n                    removedInOrder = c.len() + mmappedChunks.count~' "$MS"; run "the head branch does not advance firstChunkID"
perl -0pi -e 's~\Q                if c.maxTime >= mint { break }\E~                if c.maxTime > mint { break }~' "$MS"; run "the mmapped scan keeps a chunk whose maxTime IS mint"
perl -0pi -e 's~\Q                removedInOrder = i + 1\E~                removedInOrder = i~' "$MS"; run "the mmapped scan is off by one"
perl -0pi -e 's~\Q            firstChunkID = HeadChunkID(rawValue: firstChunkID.rawValue &+ UInt64(removedInOrder))\E~~' "$MS"; run "the mmapped branch does not advance firstChunkID"
perl -0pi -e 's~\Q            mmappedChunks = Array(mmappedChunks[removedInOrder...])\E~            mmappedChunks = Array(mmappedChunks.dropLast(removedInOrder))~' "$MS"; run "truncate drops mmapped chunks from the END"

echo "=== appendable ==="
perl -0pi -e 's~\Q        if t >= minValidTime {\E~        if t > minValidTime {~' "$MS"; run "appendable's minValidTime bound is exclusive"
perl -0pi -e 's~\Q            if headChunks == nil {\E\n\Q                // The series has no sample and was freshly created.\E\n\Q                return (false, 0, nil)\E\n\Q            }\E~~' "$MS"; run "appendable does not special-case a series with no chunk"
perl -0pi -e 's~\Q            if t > msMaxt {\E~            if t >= msMaxt {~' "$MS"; run "appendable treats a duplicate timestamp as newer"
perl -0pi -e 's~\Q                if lastValue.bitPattern != v.bitPattern {\E~                if lastValue != v {~' "$MS"; run "the duplicate check compares values rather than bits"
perl -0pi -e 's~\Q                if lastHistogramValue != nil || lastFloatHistogramValue != nil {\E~                if lastHistogramValue != nil \&\& lastFloatHistogramValue != nil {~' "$MS"; run "the histogram duplicate needs BOTH last values set"
perl -0pi -e 's~\Q                        DuplicateSampleForTimestampError.duplicateFloat(\E\n\Q                            t: t, existing: lastValue, newValue: v)\E~                        DuplicateSampleForTimestampError.duplicateFloat(\n                            t: t, existing: v, newValue: lastValue)~' "$MS"; run "the duplicate error swaps existing and new"
perl -0pi -e 's~\Q        if oooTimeWindow > 0 && t >= headMaxt - oooTimeWindow {\E~        if oooTimeWindow > 0 \&\& t > headMaxt - oooTimeWindow {~' "$MS"; run "the OOO window's lower bound is exclusive"
perl -0pi -e 's~\Q            return (true, headMaxt - t, StorageError.tooOldSample)\E~            return (false, headMaxt - t, StorageError.tooOldSample)~' "$MS"; run "a too-old sample is not reported as OOO"
perl -0pi -e 's~\Q            return (false, headMaxt - t, StorageError.outOfBounds)\E~            return (false, headMaxt - t, StorageError.outOfOrderSample)~' "$MS"; run "out-of-bounds and out-of-order are swapped"
perl -0pi -e 's~\Q        return (false, headMaxt - t, StorageError.outOfOrderSample)\E~        return (false, t - headMaxt, StorageError.outOfOrderSample)~' "$MS"; run "the oooDelta is negated on the out-of-order path"

echo "=== append ==="
perl -0pi -e 's~\Q        if !sampleInOrder {\E\n\Q            return (sampleInOrder, chunkCreated)\E\n\Q        }\E~~' "$MS"; run "append writes the sample even when it is out of order"
perl -0pi -e 's~\Q        app!.append(st, t, v)\E~        app!.append(0, t, v)~' "$MS"; run "append discards the start timestamp before the appender sees it"
perl -0pi -e 's~\Q        c!.maxTime = t\E~~' "$MS"; run "append does not advance the chunk's maxTime"
perl -0pi -e 's~\Q        lastValue = v\E~~' "$MS"; run "append does not remember the last value"
perl -0pi -e 's~\Q        lastHistogramValue = nil\E\n\Q        lastFloatHistogramValue = nil\E~~' "$MS"; run "a float append leaves the last histogram values in place"
perl -0pi -e 's~\Q        if appendID > 0 {\E~        if appendID >= 0 {~' "$MS"; run "an appendID of 0 is still added to the isolation ring"

echo "=== appendPreprocessor: the rejection routes ==="
perl -0pi -e 's~\Q            if let last = mmappedChunks.last, last.maxTime >= t {\E~            if let last = mmappedChunks.last, last.maxTime > t {~' "$MS"; run "the mmapped out-of-order guard is strict"
perl -0pi -e 's~\Q            if let last = mmappedChunks.last, last.maxTime >= t {\E\n\Q                // Out of order sample: the timestamp is already in the mmapped chunks, so ignore it.\E\n\Q                return (c, false, false)\E\n\Q            }\E~~' "$MS"; run "there is no mmapped out-of-order guard at all"
perl -0pi -e 's~\Q        if c!.maxTime >= t {\E~        if c!.maxTime > t {~' "$MS"; run "a sample at the chunk's maxTime is accepted"

echo "=== appendPreprocessor: the four cut grounds ==="
perl -0pi -e 's~\Q        if !chunkCreated && c!.chunk.bytes.count > ChunkLimits.maxBytesPerXORChunkBeforeAppend {\E~        if !chunkCreated \&\& c!.chunk.bytes.count > ChunkLimits.maxBytesPerXORChunk {~' "$MS"; run "the size rule uses the hard cap rather than the before-append one"
perl -0pi -e 's~\Q        if !chunkCreated && c!.chunk.bytes.count > ChunkLimits.maxBytesPerXORChunkBeforeAppend {\E\n\Q            c = cutNewHeadChunk(mint: t, e: e, chunkRange: o.chunkRange)\E\n\Q            chunkCreated = true\E\n\Q        }\E~~' "$MS"; run "there is no size rule"
perl -0pi -e 's~\Q        if c!.chunk.encoding != e && (!compatibleValues(c!.chunk.encoding, e) || o.storeST) {\E~        if c!.chunk.encoding != e {~' "$MS"; run "any encoding change cuts, compatible or not"
perl -0pi -e 's~\Q(!compatibleValues(c!.chunk.encoding, e) || o.storeST)\E~(!compatibleValues(c!.chunk.encoding, e))~' "$MS"; run "storeST does not force a cut across compatible encodings"
perl -0pi -e 's~\Q            nextAt = rangeForTimestamp(c!.minTime, o.chunkRange)\E~~' "$MS"; run "an empty chunk does not reset nextAt"
perl -0pi -e 's~\Q            c!.minTime = t\E~~' "$MS"; run "an empty chunk's minTime is not fixed to the sample"
perl -0pi -e 's~\Q        if numSamples == o.samplesPerChunk / 4 {\E~        if numSamples >= o.samplesPerChunk / 4 {~' "$MS"; run "the quarter-mark prediction fires on every later sample too"
perl -0pi -e 's~\Q        if numSamples == o.samplesPerChunk / 4 {\E\n\Q            nextAt = computeChunkEndTime(\E\n\Q                start: c!.minTime, cur: c!.maxTime, maxT: nextAt, ratioToFull: 4)\E\n\Q        }\E~~' "$MS"; run "there is no quarter-mark prediction"
perl -0pi -e 's~\Q                start: c!.minTime, cur: c!.maxTime, maxT: nextAt, ratioToFull: 4)\E~                start: c!.minTime, cur: t, maxT: nextAt, ratioToFull: 4)~' "$MS"; run "the prediction uses THIS sample's timestamp, not the previous one"
perl -0pi -e 's~\Q                start: c!.minTime, cur: c!.maxTime, maxT: nextAt, ratioToFull: 4)\E~                start: c!.minTime, cur: c!.maxTime, maxT: nextAt, ratioToFull: 2)~' "$MS"; run "the prediction assumes the chunk is half full rather than a quarter"
perl -0pi -e 's~\Q        if t >= nextAt || numSamples >= o.samplesPerChunk * 2 {\E~        if t > nextAt || numSamples >= o.samplesPerChunk * 2 {~' "$MS"; run "the time rule's bound is exclusive"
perl -0pi -e 's~\Q        if t >= nextAt || numSamples >= o.samplesPerChunk * 2 {\E~        if t >= nextAt {~' "$MS"; run "there is no sample-count fallback"
perl -0pi -e 's~\Q        if t >= nextAt || numSamples >= o.samplesPerChunk * 2 {\E~        if numSamples >= o.samplesPerChunk * 2 {~' "$MS"; run "there is no time rule"
perl -0pi -e 's~\Q|| numSamples >= o.samplesPerChunk * 2 {\E~|| numSamples >= o.samplesPerChunk * 3 {~' "$MS"; run "the sample-count fallback is three times the target"
perl -0pi -e 's~\Q        return (c, true, chunkCreated)\E~        return (c, true, false)~' "$MS"; run "appendPreprocessor never reports that it cut a chunk"

echo "=== cutNewHeadChunk ==="
perl -0pi -e 's~\Q        let mc = MemChunk(chunk: chunk, minTime: mint, maxTime: Int64.min, prev: headChunks)\E~        let mc = MemChunk(chunk: chunk, minTime: mint, maxTime: mint, prev: headChunks)~' "$MS"; run "a fresh chunk starts with maxTime == minTime"
perl -0pi -e 's~\Q        let mc = MemChunk(chunk: chunk, minTime: mint, maxTime: Int64.min, prev: headChunks)\E~        let mc = MemChunk(chunk: chunk, minTime: mint, maxTime: Int64.min, prev: nil)~' "$MS"; run "the new chunk does not link to the previous one"
perl -0pi -e 's~\Q        headChunkCount += 1\E~~' "$MS"; run "cutting a chunk does not increment the count"
perl -0pi -e 's~\Q        nextAt = rangeForTimestamp(mint, chunkRange)\E\n\Q\E\n\Q        do {\E\n\Q            app = try mc.chunk.makeAppender()\E~        do {\n            app = try mc.chunk.makeAppender()~' "$MS"; run "cutNewHeadChunk does not reset nextAt"
perl -0pi -e 's~\Q            app = try mc.chunk.makeAppender()\E~            if app == nil { app = try mc.chunk.makeAppender() }~' "$MS"; run "the appender is not replaced when a new chunk is cut"
perl -0pi -e 's~\Q            chunk = try newEmptyChunk(e)\E~            chunk = XORChunk()~' "$MS"; run "cutNewHeadChunk always builds an XOR chunk"
perl -0pi -e 's~\Q        } else {\E\n\Q            chunk = XORChunk()\E\n\Q        }\E~        } else {\n            chunk = XOR2Chunk()\n        }~' "$MS"; run "the invalid-encoding fallback builds an XOR2 chunk"

echo "=== mmapChunks ==="
perl -0pi -e 's~\Q        guard let head = headChunks, head.prev != nil else {\E~        guard let head = headChunks else {~' "$MS"; run "mmapChunks does not stop at a single head chunk"
perl -0pi -e 's~\Q        while i > 0 {\E~        while i >= 0 {~' "$MS"; run "mmapChunks m-maps the newest chunk too"
perl -0pi -e 's~\Q        var i = head.len() - 1\E\n\Q        while i > 0 {\E~        var i = 1\n        while i < head.len() {~' "$MS"; run "mmapChunks writes newest-first instead of oldest-first"
perl -0pi -e 's~\Q                    ref: chunkRef, numSamples: UInt16(chk.chunk.numSamples),\E~                    ref: chunkRef, numSamples: 0,~' "$MS"; run "the mmapped record does not carry the sample count"
perl -0pi -e 's~\Q                seriesRef: ref, mint: chk.minTime, maxt: chk.maxTime,\E~                seriesRef: ref, mint: chk.maxTime, maxt: chk.minTime,~' "$MS"; run "the chunk file gets mint and maxt the wrong way round"
perl -0pi -e 's~\Q        head.prev = nil\E~~' "$MS"; run "the m-mapped tail stays on the list"
perl -0pi -e 's~\Q        headChunkCount = 1\E~        headChunkCount = 0~' "$MS"; run "after m-mapping the head chunk count is 0"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q        var removedInOrder = 0\E~        var removedInOrder = 0\n        _ = removedInOrder~' "$MS"; run "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 77 controls: 71 broke, 6 SURVIVED, 0 SKIP, 0 COMPILE.
#
# One survivor is DELIBERATE — `harness check` inserts a genuinely inert `_ = removedInOrder` and must
# survive, proving `broke` is not the harness's default answer (see `lib/control-run.sh`). The other
# five are proofs, and they split two ways.
#
# TAUTOLOGIES — the perturbed code computes the same answer:
#
#   * `computeChunkEndTime's n<=1 short circuit is strict`. Weakening `n <= 1` to `n < 1` can only
#     matter at n == 1 exactly, and there the two arms AGREE: the guard returns `maxT`, and the
#     computed branch returns `start + (maxT-start)/floor(1)` = `start + (maxT-start)` = `maxT`. The
#     `=` in upstream's `<=` is therefore redundant given the `floor`, which is worth knowing: the
#     guard's real job is stopping `floor(n) == 0` from dividing by zero, and `n < 1` still does that.
#
#   * `mmapChunks does not stop at a single head chunk`. Dropping `head.prev != nil` from the guard
#     leaves a loop that runs from `len()-1 == 0` down to 1 — i.e. not at all — followed by
#     `head.prev = nil` (already nil) and `headChunkCount = 1` (already 1, because a one-element list
#     can only be reached through a cut or through a truncation that sets the count to 1). So there is
#     nothing left for the perturbation to change. The guard is an early return, not a correctness
#     condition.
#
# UNREACHABLE ARMS, each with a named owner:
#
#   * `an empty chunk does not reset nextAt` and `an empty chunk's minTime is not fixed to the sample`
#     — the two statements under `if numSamples == 0`. The only route to a head chunk with no samples
#     at that point is a cut EARLIER IN THE SAME CALL, and `cutNewHeadChunk` has already set
#     `minTime = t` and `nextAt = rangeForTimestamp(t, chunkRange)`. Upstream's own comment names the
#     exception: *"It could be the new chunk created after reading the chunk snapshot"* — the chunk
#     snapshot is `EnableMemorySnapshotOnShutdown`, a declared §7f omission. When that lands, these two
#     controls must break; until then they are dead code faithfully carried.
#
#   * `the invalid-encoding fallback builds an XOR2 chunk` — `cutNewHeadChunk`'s `else` arm. The only
#     caller is `appendPreprocessor`, which derives the encoding from
#     `ValueType.float.chunkEncoding(useXOR2:)` and therefore hands it `.xor` or `.xor2`, both valid.
#     Reaching the arm needs a caller that passes `.none`, which arrives with the histogram append path
#     (`ValueType.none.chunkEncoding` is `.none`). Kept because upstream keeps it, and because the
#     fallback is a decision — it does NOT fail on a bad encoding.
