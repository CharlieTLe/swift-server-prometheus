#!/usr/bin/env bash
# Negative controls for `tsdb/chunks`' ChunkDiskMapper.
#
# The corpus already caught four defects while this slice was being written, and they are worth naming because
# three of them came from ADR-15 rather than from the format:
#
#   1. `createFile` TRUNCATES, so re-opening the file for the append handle erased the segment header that
#      `cutSegmentFile` had just written — every file began with its first chunk.
#   2. Go PRE-ALLOCATES at cut time, so `Size()` reads 131,072 from the moment a file exists. Padding at close
#      instead reported 32,802.
#   3. `%0.6d` is a precision, not a width, so -1 is `-000001` and not `-00001`.
#   4. `bytesToWriteForChunk`'s fixed part is 29 bytes, not 28 — the CRC is easy to leave out of a count that
#      reads like a header.
#
# Five clusters: `chunkPos`'s arithmetic, the writer's field layout, the flush decisions, `iterateAllChunks`'s
# scan, and `chunk(ref:)`'s bounds and masks.
set -uo pipefail
cd "$(dirname "$0")/.."
HC=Sources/PromChunks/HeadChunks.swift
VA=Sources/GoCompat/GoVarint.swift
cp "$HC" /tmp/hc-hc.orig
cp "$VA" /tmp/hc-va.orig
restore() {
  cp /tmp/hc-hc.orig "$HC"
  cp /tmp/hc-va.orig "$VA"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# `control_verdict` plus the patch-landed check the wlog sweep introduced — a `perl -0pi` whose pattern does
# not match exits 0 and changes nothing, which reads as SURVIVED and wastes a diagnosis.
run() {
  if cmp -s "$HC" /tmp/hc-hc.orig && cmp -s "$VA" /tmp/hc-va.orig
  then
    printf "  %-62s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'HeadChunksTests' 62
  restore
}

echo "=== chunkPos's arithmetic ==="
perl -0pi -e 's/        var bytes = UInt64\(seriesRefSize\) \+ 2 \* UInt64\(mintMaxtSize\) \+ UInt64\(chunkEncodingSize\)/        var bytes = UInt64(seriesRefSize) + UInt64(mintMaxtSize) + UInt64(chunkEncodingSize)/' "$HC"; run "bytesToWriteForChunk counts one timestamp, not two"
perl -0pi -e 's/        bytes \+= UInt64\(GoVarint\.uvarintSize\(chkLen\)\)/        bytes += 1/' "$HC"; run "the length field is always one byte"
perl -0pi -e 's/        bytes \+= UInt64\(crc32Size\)\n        return bytes/        return bytes/' "$HC"; run "bytesToWriteForChunk omits the CRC"
perl -0pi -e 's/        bytes \+= chkLen\n/        \n/' "$HC"; run "bytesToWriteForChunk omits the chunk data"
perl -0pi -e 's/        seq \+= 1\n        offset = UInt64\(segmentHeaderSize\)/        offset = UInt64(segmentHeaderSize)/' "$HC"; run "toNewFile does not advance the sequence"
perl -0pi -e 's/        offset = UInt64\(segmentHeaderSize\)/        offset = 0/' "$HC"; run "a new file starts at offset 0, not past the header"
perl -0pi -e 's/        return offset == 0 \|\| offset \+ bytesToWrite > UInt64\(maxHeadChunkFileSize\)/        return offset + bytesToWrite > UInt64(maxHeadChunkFileSize)/' "$HC"; run "the first file is not recognised by offset == 0"
perl -0pi -e 's/        if cutFile \{ return true \}/        if false { return true }/' "$HC"; run "cutFileOnNextChunk is ignored"
perl -0pi -e 's/            toNewFile\(\)\n            cutFile = false/            toNewFile()/' "$HC"; run "the cut flag is not cleared after cutting"

echo "=== the ref packing ==="
perl -0pi -e 's/        self\.init\(rawValue: \(seq << 32\) \| offset\)/        self.init(rawValue: (offset << 32) | seq)/' "$HC"; run "the ref packs offset above seq"
perl -0pi -e 's/        \(Int\(rawValue >> 32\), Int\(\(rawValue << 32\) >> 32\)\)/        (Int((rawValue << 32) >> 32), Int(rawValue >> 32))/' "$HC"; run "unpack swaps the two halves"

echo "=== the writer's field layout ==="
perl -0pi -e 's/        appendBE64\(&header, UInt64\(bitPattern: Int64\(seriesRef\.rawValue\)\)\)\n        appendBE64\(&header, UInt64\(bitPattern: mint\)\)\n        appendBE64\(&header, UInt64\(bitPattern: maxt\)\)/        appendBE64(\&header, UInt64(bitPattern: Int64(seriesRef.rawValue)))\n        appendBE64(\&header, UInt64(bitPattern: maxt))\n        appendBE64(\&header, UInt64(bitPattern: mint))/' "$HC"; run "mint and maxt are written in the other order"
perl -0pi -e 's/        out\.append\(UInt8\(truncatingIfNeeded: v >> 56\)\)/        out.append(UInt8(truncatingIfNeeded: v))/' "$HC"; run "the BE64 writer starts from the low byte"
perl -0pi -e 's/        header\.append\(isOOO \? applyOutOfOrderMask\(encoding\)\.rawValue : encoding\.rawValue\)/        header.append(encoding.rawValue)/' "$HC"; run "the out-of-order mask is never written"
perl -0pi -e 's/        _ = GoVarint\.putUvarint\(&header, UInt64\(bytes\.count\)\)/        header.append(UInt8(truncatingIfNeeded: bytes.count))/' "$HC"; run "the data length is a single byte, not a uvarint"
perl -0pi -e 's/        try writeAndAppendToCRC32\(header\)\n        try writeAndAppendToCRC32\(bytes\)/        try writeAndAppendToCRC32(bytes)\n        try writeAndAppendToCRC32(header)/' "$HC"; run "the data is written before the header"
perl -0pi -e 's/        try writeAndAppendToCRC32\(header\)/        try write(header)/' "$HC"; run "the CRC does not cover the header"
perl -0pi -e 's/        try writeAndAppendToCRC32\(bytes\)/        try write(bytes)/' "$HC"; run "the CRC does not cover the chunk data"
perl -0pi -e 's/        out\.append\(UInt8\(truncatingIfNeeded: s >> 24\)\)\n        out\.append\(UInt8\(truncatingIfNeeded: s >> 16\)\)\n        out\.append\(UInt8\(truncatingIfNeeded: s >> 8\)\)\n        out\.append\(UInt8\(truncatingIfNeeded: s\)\)/        out.append(UInt8(truncatingIfNeeded: s))\n        out.append(UInt8(truncatingIfNeeded: s >> 8))\n        out.append(UInt8(truncatingIfNeeded: s >> 16))\n        out.append(UInt8(truncatingIfNeeded: s >> 24))/' "$HC"; run "the CRC is written little-endian"
perl -0pi -e 's/        crc\.reset\(\)/        \/\/ perturbed: no reset/' "$HC"; run "the CRC is not reset per chunk"

echo "=== the header, the pre-allocation and the flushes ==="
perl -0pi -e 's/        header\[4\] = headChunksFormatV1/        header[4] = 2/' "$HC"; run "the format version is 2"
perl -0pi -e 's/        header\[0\] = UInt8\(truncatingIfNeeded: magicHeadChunks >> 24\)/        header[0] = UInt8(truncatingIfNeeded: magicChunks >> 24)/' "$HC"; run "the magic number is the block chunks one"
perl -0pi -e 's/        if content\.count < headChunkFilePreallocationSize \{\n            content\.append\(\n                contentsOf: \[UInt8\]\(repeating: 0, count: headChunkFilePreallocationSize - content\.count\)\)\n        \}/        \/\/ perturbed: no pre-allocation/' "$HC"; run "the file is not pre-allocated"
perl -0pi -e 's/        curFileOffset = UInt64\(segmentHeaderSize\)\n        curFileMaxt = 0/        curFileOffset = 0\n        curFileMaxt = 0/' "$HC"; run "curFileOffset starts at 0 after a cut"
perl -0pi -e 's/        if bytes\.count \+ maxHeadChunkMetaSize < writeBufferSize,\n            writerAvailable < maxHeadChunkMetaSize \+ bytes\.count\n        \{\n            try flushBuffer\(\)\n        \}//' "$HC"; run "there is no flush before a chunk that will not fit"
perl -0pi -e 's/        if bytes\.count \+ maxHeadChunkMetaSize >= writeBufferSize \{\n            \/\/ Bigger than the buffer itself, so flush rather than keep a partial chunk in it\.\n            try flushBuffer\(\)\n        \}//' "$HC"; run "an over-sized chunk is not flushed after"
perl -0pi -e 's/        chunkBuffer\.put\(ref, encoding, bytes\)/        \/\/ perturbed: not buffered/' "$HC"; run "a written chunk is not kept in the buffer"
perl -0pi -e 's/        chunkBuffer\.clear\(\)/        \/\/ perturbed: buffer not cleared/' "$HC"; run "the chunk buffer is never cleared"
perl -0pi -e 's/        if maxt > curFileMaxt \{ curFileMaxt = maxt \}/        curFileMaxt = maxt/' "$HC"; run "curFileMaxt takes the last maxt rather than the greatest"

echo "=== iterateAllChunks's scan ==="
perl -0pi -e 's/            var idx = headChunkFileHeaderSize/            var idx = 0/' "$HC"; run "the scan starts at 0 rather than past the header"
perl -0pi -e 's/                let numSamples = UInt16\(b\[idx\]\) << 8 \| UInt16\(b\[idx \+ 1\]\)/                let numSamples = UInt16(b[idx + 1]) << 8 | UInt16(b[idx])/' "$HC"; run "numSamples is read little-endian"
perl -0pi -e 's/                idx \+= Int\(dataLen\)/                idx += Int(dataLen) + 2/' "$HC"; run "numSamples is treated as its own field"
perl -0pi -e 's/                if seriesRef\.rawValue == 0 && mint == 0 && maxt == 0 \{ break \}//' "$HC"; run "the all-zero series marker does not end the file"
perl -0pi -e 's/                if seriesRef\.rawValue == 0 && mint == 0 && maxt == 0 \{ break \}/                if seriesRef.rawValue == 0 { break }/' "$HC"; run "the end marker tests only the series ref"
perl -0pi -e 's/                    if allZeros \{ break \}//' "$HC"; run "an all-zero tail is a corruption"
perl -0pi -e 's/                    for k in idx\.\.<fileEnd where b\[k\] != 0 \{\n                        allZeros = false\n                        break\n                    \}//' "$HC"; run "the tail is assumed to be zeros without checking"
perl -0pi -e 's/            if segID == curFileSequence \{ fileEnd = Int\(curFileSize\) \}//' "$HC"; run "the current file is bounded by its length, not curFileSize"
perl -0pi -e 's/                    try checkCRC32\(Array\(b\[startIdx\.\.<idx\]\), sum\)/                    try checkCRC32(Array(b[(startIdx + seriesRefSize)..<idx]), sum)/' "$HC"; run "the scan's CRC skips the series ref"
perl -0pi -e 's/        for segID in mappedChunkFiles\.keys\.sorted\(\) \{/        for segID in mappedChunkFiles.keys {/' "$HC"; run "files are iterated in map order, not sorted"
perl -0pi -e 's/                let isOOO = isOutOfOrderChunk\(chkEnc\)\n                chkEnc = removeMasks\(chkEnc\)/                let isOOO = isOutOfOrderChunk(chkEnc)/' "$HC"; run "the scan does not strip the mask before reporting"

echo "=== chunk(ref:)'s bounds and masks ==="
perl -0pi -e 's/        chkStart \+= seriesRefSize \+ 2 \* mintMaxtSize/        chkStart += seriesRefSize + mintMaxtSize/' "$HC"; run "chunk() skips one timestamp, not two"
perl -0pi -e 's/        let chkEnc = removeMasks\(sourceEnc\)/        let chkEnc = sourceEnc/' "$HC"; run "chunk() returns the masked encoding"
perl -0pi -e 's/        if chkStart \+ maxChunkLengthFieldSize > b\.count \{/        if false {/' "$HC"; run "the size-field bound is not checked"
perl -0pi -e 's/        if chkDataEnd > b\.count \{/        if false {/' "$HC"; run "the chunk-data bound is not checked"
perl -0pi -e 's/        let covered = Array\(b\[\(chkStart - \(seriesRefSize \+ 2 \* mintMaxtSize\)\)\.\.<chkDataEnd\]\)/        let covered = Array(b[chkStart..<chkDataEnd])/' "$HC"; run "chunk()'s CRC starts at the encoding, not the series ref"
perl -0pi -e 's/            try checkCRC32\(covered, sum\)/            \/\/ perturbed: no CRC check/' "$HC"; run "chunk() does not verify the CRC"
perl -0pi -e 's/        if sgmIndex == curFileSequence, let c = chunkBuffer\.get\(ref\) \{\n            return c\n        \}//' "$HC"; run "chunk() never serves from the write buffer"
perl -0pi -e 's/            if sgmIndex > curFileSequence \{/            if false {/' "$HC"; run "a ref past the current file reports does-not-exist"
perl -0pi -e 's/        let data = Array\(b\[\(chkDataEnd - chkDataLenInt\)\.\.<chkDataEnd\]\)/        let data = Array(b[(chkDataLenStart + n)..<chkDataEnd])/' "$HC"; run "the data is taken from after the length rather than back from the end"

echo "=== the file name, truncate, and listing ==="
perl -0pi -e 's/    while s\.count < 6 \{ s = "0" \+ s \}/    while s.count < 5 { s = "0" + s }/' "$HC"; run "the segment name pads to five digits"
perl -0pi -e 's/    if negative \{ s = "-" \+ s \}/    if negative { s = "-" + String(s.dropFirst()) }/' "$HC"; run "the sign is padded into the six digits"
perl -0pi -e 's/            if seq == curFileSequence \|\| UInt32\(seq\) >= fileNo \{ break \}/            if UInt32(seq) >= fileNo { break }/' "$HC"; run "truncate may remove the file being written"
perl -0pi -e 's/            if seq == curFileSequence \|\| UInt32\(seq\) >= fileNo \{ break \}/            if seq == curFileSequence || UInt32(seq) > fileNo { break }/' "$HC"; run "truncate removes the file at fileNo too"
perl -0pi -e 's/        if curFileSize > UInt64\(headChunkFileHeaderSize\) \{\n            cutNewFile\(\)\n        \}//' "$HC"; run "truncate never cuts a new file"
perl -0pi -e 's/        if curFileSize > UInt64\(headChunkFileHeaderSize\) \{/        if true {/' "$HC"; run "truncate always cuts a new file"
perl -0pi -e 's/        if lastFile <= 0 \{ return files \}/        if lastFile < 0 { return files }/' "$HC"; run "repairLastChunkFile also repairs file 0"
perl -0pi -e 's/        if buf\.count < magicChunksSize \|\| magic == 0 \{/        if buf.count < magicChunksSize || magic != magicHeadChunks {/' "$HC"; run "a wrong magic number is repaired away rather than reported"
perl -0pi -e 's/            guard let seq = UInt64\(name\) else \{ continue \}/            guard let seq = UInt64(name) else { throw HeadChunksError.closed }/' "$HC"; run "a non-numeric filename is an error rather than skipped"
perl -0pi -e 's/            if seq != lastSeq \+ 1 \{/            if false {/' "$HC"; run "a gap in the file indices is accepted"

echo "=== GoVarint.uvarintSize ==="
perl -0pi -e 's/        if x == 0 \{ return 1 \}\n        return \(64 - x\.leadingZeroBitCount \+ 6\) \/ 7/        return (64 - x.leadingZeroBitCount + 6) \/ 7/' "$VA"; run "uvarintSize answers 0 for a zero-length chunk"
perl -0pi -e 's/        return \(64 - x\.leadingZeroBitCount \+ 6\) \/ 7/        return (64 - x.leadingZeroBitCount + 7) \/ 7/' "$VA"; run "uvarintSize rounds with 7 rather than 6"

# ---------------------------------------------------------------------------------------------------
# THE 10 SURVIVORS, and what each one is. 61 controls, 51 broke, 0 SKIP.
#
# The first sweep had 21 survivors. Eleven closed by widening the corpus rather than by argument, and the
# widening was the same shape §7c needed for `wlog`: read on the LIVE mapper (which is the only way to reach
# the `chunkBuffer` — a reopened mapper's is empty), read deliberately INVALID refs (every ref a writer hands
# back is valid by construction), and PLANT a directory (so `openMMapFiles`, `repairLastChunkFile` and the
# header checks see something the port did not write). Worth internalising as a rule: a corpus that only
# consumes its own writer's output cannot test any rejection path.
#
# PROOFS — these cannot fail, and the argument is the answer:
#
#   * `the data is taken from after the length rather than back from the end` — provably identical.
#     `chkDataEnd = chkDataLenStart + n + chkDataLenInt`, so `chkDataEnd - chkDataLenInt` IS
#     `chkDataLenStart + n`. The two spellings are the same integer; upstream uses the subtraction and the
#     port keeps it, but nothing can distinguish them.
#
#   * `there is no flush before a chunk that will not fit`, `an over-sized chunk is not flushed after` and
#     `the chunk buffer is never cleared` — flush TIMING is unobservable in this port. Upstream's flush moves
#     bytes from a `bufio.Writer` into the file, so *when* it happens decides what a concurrent reader sees;
#     the port persists the whole file on every flush and at finalize, so the bytes are identical whenever it
#     runs, and `chunkBuffer` holds the same bytes the file does. The three would separate only against a
#     reader that could observe a partially-written file, which ADR-15 does not offer. Note this is a claim
#     about the PORT's structure, not about upstream's — if `openForAppending` ever lands, re-run these.
#
# ARGUED, but weaker than a proof:
#
#   * `truncate always cuts a new file` — `cutNewFile()` only sets a flag, so cutting when the current file is
#     empty creates nothing until the next write. Distinguishing it needs a truncate on a mapper whose current
#     file is empty AND a write after it; `truncate-after-cut` has the first half and `truncate-then-write`
#     the second. Cheap to close and worth doing in the next slice.
#
#   * `an all-zero tail is a corruption` and `the tail is assumed to be zeros without checking` — both need
#     the scan to reach the `fileEnd - idx < maxHeadChunkMetaSize` branch, and it cannot: the
#     `seriesRef == 0 && mint == 0 && maxt == 0` marker fires first for every file whose content ends more
#     than 34 bytes before the pre-allocated end, which is every file the corpus can build. Reaching it needs
#     content ending within 34 bytes of exactly 128 KiB. That is constructible (a planted file) rather than
#     impossible, so it is a GAP, not a proof.
#
# GAPS with a named next step:
#
#   * `curFileMaxt takes the last maxt rather than the greatest` — `curFileMaxt` feeds only
#     `mappedChunkFiles[].maxt`, which has no public reader. Upstream uses it for size-based retention, which
#     is `db.go`'s. Closes when that lands and can read it.
#
#   * `the current file is bounded by its length, not curFileSize` — differs only when `iterateAllChunks` runs
#     on a mapper that is still writing, and upstream's own doc comment says to call it right after opening.
#     `curFileSize` is asserted directly in `HeadChunksTests` instead.
#
#   * `the chunk-data bound is not checked` — needs a ref whose `chkDataEnd` exceeds the file while the
#     size-field bound (which is checked first, and did break) still passes. That is a narrow window near the
#     very end of a file; the invalid-ref cases land either side of it.

