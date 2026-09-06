#!/usr/bin/env bash
# Negative controls for §7i(a) — `tsdb/blockwriter.go` and `LeveledCompactor`'s write path.
#
# Six source files, so `run` takes the file it perturbed (the multi-file helper from
# `Scripts/controls-headwaltruncate.sh`):
#
#   Sources/PromCompact/LeveledCompactor.swift   NewLeveledCompactor, Write, write
#   Sources/PromCompact/PopulateBlock.swift      DefaultBlockPopulator.PopulateBlock, AllSortedPostings
#   Sources/PromCompact/BlockWriter.swift        blockwriter.go
#   Sources/PromCompact/BlockReaders.swift       the Head-as-a-block adapters
#   Sources/PromBlock/BlockMeta.swift            writeMetaFile
#   Sources/PromBlock/PopulateIterators.swift    the maxt fix-up and the re-encode
#
# The corpus is `Fixtures/block/write.jsonl` — 31 blocks that upstream's own `BlockWriter` /
# `LeveledCompactor.Write` produced, compared as file BYTES, as a directory listing, and read back through the
# port's block reader. `CompactSeamTests` carries the two behaviours the corpus provably cannot reach; both
# suites run, because a perturbation in `PopulateIterators.swift` is visible from either.
#
# Traps carried forward from the earlier sweeps, all still live here:
#
#   * `\Q…\E` cannot contain a `$` or a `\`, so a pattern can never contain a Swift string interpolation —
#     end the quoted run and use `[^\n]*` for the rest of the line.
#   * `\Q…\E` does not interpret `\n`; a multi-line pattern needs `\E\n\Q` between the lines.
#   * a control that patches a DOC COMMENT measures nothing. Include enough context to be unique.
#   * check the indentation — a pattern one indent level out reports SKIP, which is the only reason it gets
#     noticed at all.
set -uo pipefail
cd "$(dirname "$0")/.."
LC=Sources/PromCompact/LeveledCompactor.swift
PB=Sources/PromCompact/PopulateBlock.swift
BW=Sources/PromCompact/BlockWriter.swift
BR=Sources/PromCompact/BlockReaders.swift
BM=Sources/PromBlock/BlockMeta.swift
PI=Sources/PromBlock/PopulateIterators.swift
cp "$LC" /tmp/bwc-lc.orig
cp "$PB" /tmp/bwc-pb.orig
cp "$BW" /tmp/bwc-bw.orig
cp "$BR" /tmp/bwc-br.orig
cp "$BM" /tmp/bwc-bm.orig
cp "$PI" /tmp/bwc-pi.orig
restore() {
  cp /tmp/bwc-lc.orig "$LC"; cp /tmp/bwc-pb.orig "$PB"; cp /tmp/bwc-bw.orig "$BW"
  cp /tmp/bwc-br.orig "$BR"; cp /tmp/bwc-bm.orig "$BM"; cp /tmp/bwc-pi.orig "$PI"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$LC") orig=/tmp/bwc-lc.orig ;;
    "$PB") orig=/tmp/bwc-pb.orig ;;
    "$BW") orig=/tmp/bwc-bw.orig ;;
    "$BR") orig=/tmp/bwc-br.orig ;;
    "$BM") orig=/tmp/bwc-bm.orig ;;
    "$PI") orig=/tmp/bwc-pi.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-74s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'BlockWriteTests|CompactSeamTests' 74
  restore
}

echo "=== the INERT control: it must SURVIVE, or the harness reports broke by default ==="
perl -0pi -e 's~\Q    /// Go: `LeveledCompactor.Plan`. **§7j** — see the \E~    /// Go: LeveledCompactor Plan. See the ~' "$LC"; run "$LC" "INERT: a doc comment is reworded (MUST survive)"

echo "=== LeveledCompactor.Write: the meta it builds ==="
perl -0pi -e 's~\Q        meta.compaction.level = 1\E~        meta.compaction.level = 2~' "$LC"; run "$LC" "the block is written at compaction level 2"
perl -0pi -e 's~\Q        meta.compaction.sources = \E\Q[uid]\E~~' "$LC"; run "$LC" "a level-1 block records no source"
perl -0pi -e 's~\Q        var meta = BlockMeta(ulid: uid, minTime: mint, maxTime: maxt)\E~        var meta = BlockMeta(ulid: uid, minTime: mint, maxTime: maxt - 1)~' "$LC"; run "$LC" "meta.maxTime is the last sample rather than one past it"
perl -0pi -e 's~\Q        var meta = BlockMeta(ulid: uid, minTime: mint, maxTime: maxt)\E~        var meta = BlockMeta(ulid: uid, minTime: mint - 1, maxTime: maxt)~' "$LC"; run "$LC" "meta.minTime is one before the first sample"
perl -0pi -e 's~\Q        if meta.stats.numSamples == 0 {\E\n\Q            return \E\Q[]\E~        if false {\n            return []~' "$LC"; run "$LC" "Write reports a ULID for an empty block"

echo "=== Write's base: parents and the two hints ==="
perl -0pi -e 's~\Q            if base.compaction.fromOutOfOrder() {\E~            if false {~' "$LC"; run "$LC" "the out-of-order hint is not propagated from base"
perl -0pi -e 's~\Q            if base.compaction.fromStaleSeries() {\E~            if false {~' "$LC"; run "$LC" "the stale-series hint is not propagated from base"
perl -0pi -e 's~\Q                BlockDesc(ulid: base.ulid, minTime: base.minTime, maxTime: base.maxTime)\E~                BlockDesc(ulid: base.ulid, minTime: base.maxTime, maxTime: base.minTime)~' "$LC"; run "$LC" "the parent BlockDesc has its bounds swapped"
perl -0pi -e 's~\Q        if let base {\E~        if let base, false {~' "$LC"; run "$LC" "base is ignored entirely"
perl -0pi -e 's~\Q        hints.append(Self.hintFromOutOfOrder)\E\n\Q        hints.sort()\E~        hints.append(Self.hintFromOutOfOrder)~' "$BM"; run "$BM" "setOutOfOrder does not re-sort the hint list"
perl -0pi -e 's~\Q        if fromStaleSeries() { return }\E~        if false { return }~' "$BM"; run "$BM" "setStaleSeries is not idempotent"

echo "=== write: the temporary directory and the rename ==="
perl -0pi -e 's~\Qpublic let tmpForCreationBlockDirSuffix = ".tmp-for-creation"\E~public let tmpForCreationBlockDirSuffix = ".tmp"~' "$LC"; run "$LC" "the temporary suffix is .tmp rather than .tmp-for-creation"
perl -0pi -e 's~\Q        defer { removeAll(tmp) }\E~~' "$LC"; run "$LC" "the temporary directory is never removed"
perl -0pi -e 's~\Q        try replaceDirectory(from: tmp, to: dir)\E~        try copyTree(from: tmp, to: dir)~' "$LC"; run "$LC" "the temporary directory is copied but not removed"
perl -0pi -e 's~\Q        if meta.stats.numSamples == 0 {\E\n\Q            return\E\n\Q        }\E~~' "$LC"; run "$LC" "an empty block is written to disk anyway"
perl -0pi -e 's~\Q        try closeWriters()\E\n\n\Q        // Populated block is empty\E~        // Populated block is empty~' "$LC"; run "$LC" "the writers are not closed before the meta is written"

echo "=== write: the order of the files ==="
perl -0pi -e 's~\Q            try BlockMeta.writeMetaFile(fs: fs, dir: tmp, meta: &meta)\E~            try BlockMeta.writeMetaFile(fs: fs, dir: dir, meta: &meta)~' "$LC"; run "$LC" "meta.json is written to the final directory rather than the temporary one"
perl -0pi -e 's~\Q        meta.version = 1\E~~' "$BM"; run "$BM" "writeMetaFile does not force the version to 1"
perl -0pi -e 's~\Q        try? fs.remove(tmp)\E~~' "$BM"; run "$BM" "writeMetaFile leaves its own meta.json.tmp behind"

echo "=== NewLeveledCompactor's defaults and its one validation ==="
perl -0pi -e 's~\Q        if ranges.isEmpty {\E~        if false {~' "$LC"; run "$LC" "an empty range list is accepted"
perl -0pi -e 's~\Q            ? ChunkWriter.defaultSegmentSize : options.maxBlockChunkSegmentSize\E~            ? 512 : options.maxBlockChunkSegmentSize~' "$LC"; run "$LC" "the block chunk segment size defaults to 512 bytes"

echo "=== PopulateBlock: the symbols ==="
perl -0pi -e 's~\Q        for symbol in indexr.symbols() {\E~        for symbol in indexr.symbols().reversed() {~' "$PB"; run "$PB" "the symbols are written in reverse order"
perl -0pi -e 's~\Q        for symbol in indexr.symbols() {\E~        for symbol in [String]() {~' "$PB"; run "$PB" "no symbols are written at all"
perl -0pi -e 's~\Q        for symbol in indexr.symbols() {\E\n\Q            do {\E\n\Q                try indexw.addSymbol(symbol)\E~        for symbol in indexr.symbols() + \["zzz-unused"\] {\n            do {\n                try indexw.addSymbol(symbol)~' "$PB"; run "$PB" "one extra symbol nothing references is written"

echo "=== PopulateBlock: the series loop ==="
perl -0pi -e 's~\Q        var ref: UInt64 = 0\E~        var ref: UInt64 = 1~' "$PB"; run "$PB" "the series refs start at 1"
perl -0pi -e 's~\Q            if chks.isEmpty {\E\n\Q                continue\E~            if false {\n                continue~' "$PB"; run "$PB" "a series whose every chunk was deleted is still added"
perl -0pi -e 's~\Q            ref += 1\E~~' "$PB"; run "$PB" "the series ref never advances"
perl -0pi -e 's~\Q            postings: postings, mint: meta.minTime, maxt: meta.maxTime - 1,\E~            postings: postings, mint: meta.minTime, maxt: meta.maxTime,~' "$PB"; run "$PB" "the series set gets meta.maxTime rather than maxTime - 1"
perl -0pi -e 's~\Q            postings: postings, mint: meta.minTime, maxt: meta.maxTime - 1,\E~            postings: postings, mint: meta.minTime - 1, maxt: meta.maxTime - 1,~' "$PB"; run "$PB" "the series set gets minTime - 1"
perl -0pi -e 's~\Q            disableTrimming: false, tombstonesFor: tombsr.get)\E~            disableTrimming: true, tombstonesFor: tombsr.get)~' "$PB"; run "$PB" "trimming is disabled, so a straddling chunk is copied whole"
perl -0pi -e 's~\Q            disableTrimming: false, tombstonesFor: tombsr.get)\E~            disableTrimming: false)~' "$PB"; run "$PB" "the tombstones are not consulted"
perl -0pi -e 's~\Q        let postings = postingsFunc(indexr)\E~        let postings = try indexr.postings(name: "", values: \[""\])~' "$PB"; run "$PB" "the postings are not SORTED by label set"

echo "=== PopulateBlock: the stats ==="
perl -0pi -e 's~\Q            meta.stats.numChunks += UInt64(chks.count)\E~~' "$PB"; run "$PB" "numChunks is never accumulated"
perl -0pi -e 's~\Q            meta.stats.numSeries += 1\E~~' "$PB"; run "$PB" "numSeries is never accumulated"
perl -0pi -e 's~\Q                meta.stats.numSamples += samples\E~~' "$PB"; run "$PB" "numSamples is never accumulated"
perl -0pi -e 's~\Q                case .xor, .xor2:\E\n\Q                    meta.stats.numFloatSamples += samples\E~                case .xor, .xor2:\n                    break~' "$PB"; run "$PB" "numFloatSamples is never accumulated"
perl -0pi -e 's~\Q                case .histogram, .floatHistogram:\E\n\Q                    meta.stats.numHistogramSamples += samples\E~                case .histogram, .floatHistogram:\n                    meta.stats.numFloatSamples += samples~' "$PB"; run "$PB" "a histogram chunk counts as float samples"
perl -0pi -e 's~\Q                case .xor, .xor2:\E\n\Q                    meta.stats.numFloatSamples += samples\E~                case .xor, .xor2:\n                    meta.stats.numFloatSamples += 1~' "$PB"; run "$PB" "numFloatSamples counts chunks rather than samples"

echo "=== PopulateBlock: what the chunk writer and the index writer are given ==="
perl -0pi -e 's~\Q                    (minTime: chk.meta.minTime, maxTime: chk.meta.maxTime, ref: refs\E[^\n]*~                    (minTime: chk.meta.minTime, maxTime: chk.meta.maxTime, ref: 0))~' "$PB"; run "$PB" "every chunk is indexed at reference 0"
perl -0pi -e 's~\Q                refs = try chunkw.write(payload)\E~                refs = try chunkw.write(payload.reversed())~' "$PB"; run "$PB" "a series chunks are written to the segment in reverse"
perl -0pi -e 's~\Q                    (minTime: chk.meta.minTime, maxTime: chk.meta.maxTime, ref: refs\E[^\n]*~                    (minTime: chk.meta.maxTime, maxTime: chk.meta.maxTime, ref: refs\[i\].rawValue))~' "$PB"; run "$PB" "a chunk is indexed with its maxTime as its minTime"
perl -0pi -e 's~\Q            throw CompactError.noReaders\E~            return~' "$PB"; run "$PB" "no readers is silently an empty block"

echo "=== BlockWriter ==="
perl -0pi -e 's~\Q        let maxt = head.maxTime() &+ 1\E~        let maxt = head.maxTime()~' "$BW"; run "$BW" "Flush does not add the half-open +1"
perl -0pi -e 's~\Q        let maxt = head.maxTime() &+ 1\E~        let maxt = head.maxTime() &+ 2~' "$BW"; run "$BW" "Flush adds 2 instead of 1"
perl -0pi -e 's~\Q        let mint = head.minTime()\E~        let mint = head.minTime() &- 1~' "$BW"; run "$BW" "Flush starts the block one millisecond early"
perl -0pi -e 's~\Q        opts.chunkRange = blockSize\E~        opts.chunkRange = defaultBlockDuration~' "$BW"; run "$BW" "the head's chunk range ignores the block size"
perl -0pi -e 's~\Q        try head.initialize(minValidTime: Int64.min)\E~        try head.initialize(minValidTime: 0)~' "$BW"; run "$BW" "the head is initialised at 0 rather than MinInt64"
perl -0pi -e 's~\Q        let compactor = try LeveledCompactor(fs: fs, ranges: \E\Q[blockSize], options: options)\E~        let compactor = try LeveledCompactor(fs: fs, ranges: \[1\], options: options)~' "$BW"; run "$BW" "the compactor is built with a range of 1ms"
perl -0pi -e 's~\Q        return ids.first\E~        return nil~' "$BW"; run "$BW" "Flush never reports the ULID it wrote"

echo "=== the Head seen as a block ==="
perl -0pi -e 's~\Q        if copyHeadChunk {\E~        if false {~' "$BR"; run "$BR" "the WithCopy form is never used"
perl -0pi -e 's~\Q                chunk: (encoding: chunk.encoding, bytes: chunk.bytes), iterable: iterable,\E\n\Q                maxTime: maxTime)\E~                chunk: (encoding: chunk.encoding, bytes: chunk.bytes), iterable: iterable,\n                maxTime: nil)~' "$BR"; run "$BR" "the WithCopy form drops its maxTime"
perl -0pi -e 's~\Q        } catch StorageError.notFound {\E\n\Q            return nil\E~        } catch StorageError.notFound {\n            throw StorageError.notFound~' "$BR"; run "$BR" "a stale posting is an error rather than a skip"
perl -0pi -e 's~\Q    public func sortedPostings(_ p: any Postings) -> any Postings { reader.sortedPostings(p) }\E~    public func sortedPostings(_ p: any Postings) -> any Postings { p }~' "$BR"; run "$BR" "sortedPostings is the identity for the Head too"
perl -0pi -e 's~\Q    public func meta() -> BlockMeta { head.meta() }\E~    public func meta() -> BlockMeta { BlockMeta(ulid: headULID, minTime: 0, maxTime: 0) }~' "$BR"; run "$BR" "the Head reports an empty meta"

echo "=== the populate iterators, as this slice reaches them ==="
perl -0pi -e 's~\Q        if resolved.chunk != nil, let fixed = resolved.maxTime {\E~        if false, let fixed = resolved.maxTime {~' "$PI"; run "$PI" "the open chunk's MaxInt64 is never corrected"
perl -0pi -e 's~\Q            currMeta?.maxTime = fixed\E~            currMeta?.minTime = fixed~' "$PI"; run "$PI" "the WithCopy maxTime is written to minTime"
perl -0pi -e 's~\Q            newChunk = try newEmptyChunk(source.encoding)\E~            newChunk = XORChunk()~' "$PI"; run "$PI" "a re-encoded chunk is always XOR"
perl -0pi -e 's~\Q            let st = del.atST()\E~            let st: Int64 = 0~' "$PI"; run "$PI" "the re-encoded chunk drops the start timestamp"
perl -0pi -e 's~\Q        newMeta.minTime = del.atT()\E~~' "$PI"; run "$PI" "a re-encoded chunk keeps the original minTime"
perl -0pi -e 's~\Q        newMeta.maxTime = t\E~~' "$PI"; run "$PI" "a re-encoded chunk keeps the original maxTime"

echo
echo "==================================================================================="
echo "The survivors, argued. A survivor is a hypothesis until the argument is finished."
echo "==================================================================================="
cat <<'ARG'

  1. INERT: a doc comment is reworded.
     EXPECTED. It is the proof that `broke` is not this harness's default verdict: the same build, the
     same filter, the same corpus, one comment changed, and the sweep says SURVIVED. Every other
     SURVIVED below is only meaningful because this one exists.

  2. "the temporary directory is copied but not removed" — PROOF.
     `replaceDirectory`'s `removeAll(from)` is redundant with `write`'s `defer { removeAll(tmp) }`, which
     runs on every exit path including the successful one. Upstream has the same belt and braces the
     other way round: `fileutil.Replace` RENAMES, so its deferred `os.RemoveAll(tmp)` is the no-op.
     Whichever of the two does the deleting, the end state is one block directory and no temporary,
     which is what the corpus checks. The redundancy is exception 28's, and it is recorded in
     `LeveledCompactor.swift` next to the code.

  3. "the series refs start at 1"           — PROOF (both, same argument).
  4. "the series ref never advances"        — PROOF.
     This is quirk 197, arrived at from the other side. `index.Writer.AddSeries` reads `ref` for exactly
     one thing, `ref < lastSeriesRef && !lastSeries.isEmpty`, and the postings ordinals come from the
     series record's byte POSITION divided by 16 (quirk 133), not from `ref`. So ANY non-decreasing
     sequence produces byte-identical output: 0,1,2… and 1,2,3… and 0,0,0… are indistinguishable.
     A corpus cannot separate them, and it is not supposed to be able to — the number is not in the file.

  5. "a histogram chunk counts as float samples" — PROOF by unreachability.
     `headAppender.AppendHistogram` is a declared §7f deferral, so no ported caller can put a histogram
     chunk in a Head, and `PopulateBlock`'s `case .histogram, .floatHistogram` arm has no input. The
     control becomes live with the histogram appender (Phase 10) and this line is where it will be read.

  6. "the compactor is built with a range of 1ms" — PROOF by unreachability.
     `LeveledCompactor.ranges` has exactly two readers upstream, `plan` and `selectDirs`, and both are
     `db.go`'s scheduler (§7j). The write path reads it only through the `ranges.isEmpty` validation,
     which a separate control does break. Note the corollary the §7j scoping found: `selectDirs` opens
     with `if len(c.ranges) < 2 … return nil`, so `BlockWriter`'s single-element list would switch the
     planner off anyway.

  7. "a stale posting is an error rather than a skip" — PROOF.
     `blockBaseSeriesSet`'s `ErrNotFound` skip ("postings may be stale") is DEAD for a Head reader,
     because `AllSortedPostings` goes through `headIndexReader.SortedPostings`, which resolves every ref
     to a `memSeries` up front and DROPS the ones that are gone (§7g). Nothing can therefore reach
     `Series` with a ref the stripe series no longer holds. The skip is live for a *block* reader, whose
     `SortedPostings` is the identity, and §6s's corpus covers it there.

  8. "the Head reports an empty meta" — PROOF.
     `PopulateBlock` reads `b.Meta()` in three places and all three are unobservable here: the
     `open … reader for block %+v` error messages (no case fails to open a reader), the `blockID`
     interpolated into `cannot populate chunk %d from block %s` (no case fails to populate one), and the
     overlap detection, which is a metric plus a log line over a SINGLE reader and is not ported. It
     becomes load-bearing with `Compact`, §7j, where `Meta().MinTime`/`MaxTime` drive `globalMaxt`.

  9. "the re-encoded chunk drops the start timestamp" — PROOF, and this one took a probe.
     `populateCurrForSingleChunk` reads `AtST()` per sample (querier.go:976) and the port does too, and
     the corpus has XOR2 cases WITH `EnableSTStorage` and an `AppendSTZeroSample` — and the control still
     survives. The reason is upstream: **nothing in the append path ever sets `record.RefSample.ST`.**
     `headAppender.Append` builds `RefSample{Ref, T, V}` (head_append.go:496-500) and
     `AppendSTZeroSample` builds `RefSample{Ref, T: st, V: 0}` (head_append.go:540) — it stores the start
     timestamp as a synthetic sample's TIMESTAMP, not as an `ST`. The only writer of a non-zero `ST` is
     `loadWAL` (head_wal.go:717), which decodes it from a samples-V2 record. So every chunk a Head builds
     by APPENDING has `AtST() == 0` throughout, and this becomes observable the moment a compaction runs
     over a REPLAYED head — a §7j corpus, since this one builds its head by appending. Quirk 209.

ARG
