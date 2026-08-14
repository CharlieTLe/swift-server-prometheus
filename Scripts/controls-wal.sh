#!/usr/bin/env bash
# Negative controls for `tsdb/wlog`'s segment format.
#
# The corpus already caught three real defects while this slice was being written — the reader stopping after
# the first segment (a `(0, nil)` read treated as EOF), `Close` flushing an empty page, and
# `LastSegmentAndOffset` returning `page.alloc` instead of `donePages*pageSize + page.alloc`. So the question
# this sweep answers is the one after that: which of the remaining lines can the corpus see at all?
#
# Three clusters, and they are not the same shape:
#
#   1. **the page arithmetic.** `full()`'s `< recordHeaderSize`, `remaining()`, the `left` calculation's
#      per-page header discount, and `flushPage`'s `alloc = pageSize` before the write. Each is an
#      off-by-a-header away from a plausible alternative, and the corpus has records sitting exactly on those
#      boundaries because nothing else can distinguish them.
#   2. **the fragment grammar.** Which of full/first/middle/last a fragment gets, and `validateRecord`'s four
#      arms. The type assignment is a four-way `switch` on two conditions, so the controls swap the arms
#      rather than deleting them.
#   3. **the reader's two EOFs.** `io.EOF` versus `io.ErrUnexpectedEOF`, and the torn-record check that reads
#      `curRecTyp` after the loop. This is where a port most easily loses the ability to detect a torn write.
set -uo pipefail
cd "$(dirname "$0")/.."
FMT=Sources/PromWAL/WALFormat.swift
WR=Sources/PromWAL/WALWriter.swift
RD=Sources/PromWAL/WALReader.swift
cp "$FMT" /tmp/wal-fmt.orig
cp "$WR" /tmp/wal-wr.orig
cp "$RD" /tmp/wal-rd.orig
restore() {
  cp /tmp/wal-fmt.orig "$FMT"
  cp /tmp/wal-wr.orig "$WR"
  cp /tmp/wal-rd.orig "$RD"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# `control_verdict` plus a check that the perturbation LANDED.
#
# `perl -0pi` whose pattern does not match exits 0 and changes nothing, so the control then reports SURVIVED
# and reads as a corpus gap. The first run of this sweep had two of those and they cost real time to
# diagnose — quirk 163's failure mode, in the harness rather than in the port. Diffing against the backups is
# two lines and makes it loud. Copy this `run()` rather than the older sweeps'.
run() {
  if cmp -s "$FMT" /tmp/wal-fmt.orig && cmp -s "$WR" /tmp/wal-wr.orig && cmp -s "$RD" /tmp/wal-rd.orig
  then
    printf "  %-60s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'WALSegmentTests' 60
  restore
}

echo "=== the page arithmetic ==="
perl -0pi -e 's/    var isFull: Bool \{ pageSize - alloc < recordHeaderSize \}/    var isFull: Bool { pageSize - alloc <= 0 }/' "$WR"; run "a page is full only when 0 bytes remain"
perl -0pi -e 's/    var isFull: Bool \{ pageSize - alloc < recordHeaderSize \}/    var isFull: Bool { pageSize - alloc <= recordHeaderSize }/' "$WR"; run "full() is <= rather than <"
perl -0pi -e 's/    var remaining: Int \{ pageSize - alloc \}/    var remaining: Int { pageSize - alloc - recordHeaderSize }/' "$WR"; run "remaining() already subtracts a header"
perl -0pi -e 's/        var left = page\.remaining - recordHeaderSize\n        left \+= \(pageSize - recordHeaderSize\) \* \(pagesPerSegment - donePages - 1\)/        var left = page.remaining\n        left += (pageSize - recordHeaderSize) * (pagesPerSegment - donePages - 1)/' "$WR"; run "the active page is not discounted by a header"
perl -0pi -e 's/        left \+= \(pageSize - recordHeaderSize\) \* \(pagesPerSegment - donePages - 1\)/        left += pageSize * (pagesPerSegment - donePages - 1)/' "$WR"; run "future pages are not discounted by a header"
perl -0pi -e 's/        left \+= \(pageSize - recordHeaderSize\) \* \(pagesPerSegment - donePages - 1\)/        left += (pageSize - recordHeaderSize) * (pagesPerSegment - donePages)/' "$WR"; run "the active page is counted twice"
perl -0pi -e 's/        if enc\.count > left \{/        if enc.count >= left {/' "$WR"; run "the rotation test is >= rather than >"
perl -0pi -e 's/        if shouldClear \{\n            page\.alloc = pageSize\n        \}/        \/\/ perturbed: no fill to end of page/' "$WR"; run "a cleared page does not write its padding"
perl -0pi -e 's/        let shouldClear = forceClear \|\| page\.isFull/        let shouldClear = forceClear/' "$WR"; run "a full page is not cleared unless forced"
perl -0pi -e 's/        donePages = seg\.size \/ pageSize/        donePages = 0/' "$WR"; run "donePages is not derived from the segment size"
perl -0pi -e 's/        page\.flushed \+= slice\.count/        page.flushed = 0/' "$WR"; run "flushed is not advanced"
perl -0pi -e 's/        let slice = Array\(page\.buf\[page\.flushed\.\.<page\.alloc\]\)/        let slice = Array(page.buf[0..<page.alloc])/' "$WR"; run "flushPage rewrites from the page start"

echo "=== the fragment grammar ==="
perl -0pi -e 's/            let l = min\(enc\.count - offset, \(pageSize - page\.alloc\) - recordHeaderSize\)/            let l = min(enc.count - offset, pageSize - page.alloc)/' "$WR"; run "a fragment may fill the page without room for its header"
perl -0pi -e 's/            if i == 0 && l == enc\.count - offset \{\n                typ = WALRecordType\.full\.rawValue\n            \} else if l == enc\.count - offset \{\n                typ = WALRecordType\.last\.rawValue/            if i == 0 \&\& l == enc.count - offset {\n                typ = WALRecordType.full.rawValue\n            } else if l == enc.count - offset {\n                typ = WALRecordType.full.rawValue/' "$WR"; run "the final fragment of a split record is full"
perl -0pi -e 's/            \} else if i == 0 \{\n                typ = WALRecordType\.first\.rawValue\n            \} else \{\n                typ = WALRecordType\.middle\.rawValue/            } else if i == 0 {\n                typ = WALRecordType.middle.rawValue\n            } else {\n                typ = WALRecordType.first.rawValue/' "$WR"; run "first and middle are swapped"
perl -0pi -e 's/        while i == 0 \|\| offset < enc\.count \{/        while offset < enc.count {/' "$WR"; run "a zero-length record writes nothing"
perl -0pi -e 's/        if final && page\.alloc > 0 \{/        if page.alloc > 0 {/' "$WR"; run "every record flushes, not just the batch's last"
perl -0pi -e 's/        if final && page\.alloc > 0 \{\n            try flushPage\(forceClear: false\)\n        \}//' "$WR"; run "the batch never flushes a partial page"
perl -0pi -e 's/        if final && page\.alloc > 0 \{\n            try flushPage\(forceClear: false\)/        if final \&\& page.alloc > 0 {\n            try flushPage(forceClear: true)/' "$WR"; run "the batch's final flush clears the page"
perl -0pi -e 's/            page\.buf\[base \+ 1\] = UInt8\(truncatingIfNeeded: len >> 8\)\n            page\.buf\[base \+ 2\] = UInt8\(truncatingIfNeeded: len\)/            page.buf[base + 1] = UInt8(truncatingIfNeeded: len)\n            page.buf[base + 2] = UInt8(truncatingIfNeeded: len >> 8)/' "$WR"; run "the fragment length is little-endian"
perl -0pi -e 's/            let crc = walCRC\(part\)/            let crc = walCRC(enc[0..<enc.count])/' "$WR"; run "the CRC covers the whole record, not the fragment"

echo "=== validateRecord's four arms ==="
perl -0pi -e 's/    case \.full:\n        if i != 0 \{ throw WALError\.unexpectedFullRecord \}/    case .full:\n        if i == 0 { throw WALError.unexpectedFullRecord }/' "$FMT"; run "a full record is only valid after a fragment"
perl -0pi -e 's/    case \.middle:\n        if i == 0 \{ throw WALError\.unexpectedMiddleRecord \}/    case .middle:\n        if i != 0 { throw WALError.unexpectedMiddleRecord }/' "$FMT"; run "a middle record is only valid at position 0"
perl -0pi -e 's/    case \.last:\n        if i == 0 \{ throw WALError\.unexpectedLastRecord \}//' "$FMT"; run "a last record is accepted anywhere"
perl -0pi -e 's/            try validateRecord\(curRecTyp, i\)//' "$RD"; run "the grammar is not validated at all"
perl -0pi -e 's/            \/\/ Only content fragments advance `i`; a page terminator does not, which is what lets a record\n            \/\/ cross a page boundary\.\n            i \+= 1/            i = 0/' "$RD"; run "i does not advance across fragments"
perl -0pi -e 's/        case \.unexpectedFirstRecord: return "unexpected first record, dropping buffer"/        case .unexpectedFirstRecord: return "unexpected first record"/' "$FMT"; run "the first-record message drops its suffix"
perl -0pi -e 's/        case .unexpectedRecordType\(let t\): return "unexpected record type \\\(t\)"/        case .unexpectedRecordType(let t): return "unexpected record type \\(WALRecordType(rawValue: t))"/' "$FMT"; run "the unexpected-type message names the type"

echo "=== the reader's two EOFs, and the torn check ==="
perl -0pi -e 's/            if n == 0 \{ return nil \}\n            throw WALError\.unexpectedEOF/            return nil/' "$RD"; run "a partial read is a clean EOF"
perl -0pi -e 's/        n \+= got\n    \}\n    return n/        if got == 0 { return n == 0 ? nil : n }\n        n += got\n    }\n    return n/' "$RD"; run "a zero-byte read ends the stream"
perl -0pi -e 's/                if curRecTyp == \.first \|\| curRecTyp == \.middle \{\n                    error = WALError\.lastRecordIsTorn\n                \}//' "$RD"; run "a torn last record is not detected"
perl -0pi -e 's/                if curRecTyp == \.first \|\| curRecTyp == \.middle \{/                if curRecTyp == .last || curRecTyp == .full {/' "$RD"; run "the torn check tests the wrong two types"
perl -0pi -e 's/            curRecTyp = walRecordType\(fromHeader: buf\[0\]\)/            curRecTyp = WALRecordType(rawValue: buf[0])/' "$RD"; run "the record type is not masked out of the header"
perl -0pi -e 's/            if Int\(length\) > pageSize - recordHeaderSize \{/            if Int(length) > pageSize {/' "$RD"; run "the length bound omits the header"
perl -0pi -e 's/            if c != crc \{\n                throw WALError\.unexpectedChecksum\(got: c, expected: crc\)\n            \}//' "$RD"; run "the CRC is not checked"
perl -0pi -e 's/            precomprBuf\.append\(contentsOf: buf\[payload\]\)\n            if curRecTyp == \.last \|\| curRecTyp == \.full \{/            precomprBuf.append(contentsOf: buf[payload])\n            if curRecTyp == .last {/' "$RD"; run "a full fragment does not complete a record"
perl -0pi -e 's/        precomprBuf\.removeAll\(keepingCapacity: true\)//' "$RD"; run "the fragment buffer is not reset per record"

echo "=== the page terminator ==="
perl -0pi -e 's/                let k = Int\(Int64\(pageSize\) - \(total % Int64\(pageSize\)\)\)\n                if k == pageSize \{/                let k = Int(Int64(pageSize) - (total % Int64(pageSize)))\n                if k == 0 {/' "$RD"; run "the whole-page terminator case tests k == 0"
perl -0pi -e 's/                let k = Int\(Int64\(pageSize\) - \(total % Int64\(pageSize\)\)\)/                let k = Int(Int64(pageSize) - ((total - 1) % Int64(pageSize)))/' "$RD"; run "k is measured before the type byte"
perl -0pi -e 's/                for c in buf\[1\.\.<\(1 \+ k\)\] where c != 0 \{\n                    throw WALError\.unexpectedNonZeroByteInPaddedPage\n                \}//' "$RD"; run "padding is not checked for non-zero bytes"
perl -0pi -e 's/            if curRecTyp == \.pageTerm \{/            if false {/' "$RD"; run "the page terminator is not skipped"

echo "=== the segment directory ==="
perl -0pi -e 's/    if refs\.isEmpty \{ return \(-1, -1\) \}/    if refs.isEmpty { return (0, 0) }/' "$WR"; run "an empty directory reports 0/0 rather than -1/-1"
perl -0pi -e 's/        let writeSegmentIndex = last == -1 \? 0 : last \+ 1/        let writeSegmentIndex = last == -1 ? 0 : last/' "$WR"; run "NewSize reuses the last segment index"
perl -0pi -e 's/    refs\.sort \{ \$0\.index < \$1\.index \}//' "$WR"; run "segments are not sorted numerically"
perl -0pi -e 's/        if refs\[i\]\.index \+ 1 != refs\[i \+ 1\]\.index \{\n            throw WALError\.segmentsNotSequential\n        \}//' "$WR"; run "a gap in the segment indices is accepted"
perl -0pi -e 's/            if r\.index >= i \{ break \}/            if r.index > i { break }/' "$WR"; run "Truncate keeps the segment at index i"
perl -0pi -e 's/            if r\.index >= i \{ break \}/            if r.index >= i { continue }/' "$WR"; run "Truncate continues past the boundary instead of breaking"
# ^ Expected to SURVIVE and provably: `listSegments` returns the indices sorted AND sequential, so once one
# is at or above `i` every later one is too — `break` and `continue` remove exactly the same set. The
# difference is only reachable for an unsorted or gappy list, and the sequentiality check above rejects
# those before this loop runs. That is quirk 160's shape: the pair of lines interlock, and the control that
# matters is the one on the check, which does break.
perl -0pi -e 's/        if page\.alloc > 0 \{\n            try flushPage\(forceClear: true\)\n        \}\n        let syncError/        try flushPage(forceClear: true)\n        let syncError/' "$WR"; run "Close flushes an empty page"
perl -0pi -e 's/        if page\.alloc > 0 \{\n            try flushPage\(forceClear: true\)\n        \}\n        guard let current = segment/        try flushPage(forceClear: true)\n        guard let current = segment/' "$WR"; run "nextSegment flushes an empty page"
perl -0pi -e 's/        return \(last, donePages \* pageSize \+ page\.alloc\)/        return (last, page.alloc)/' "$WR"; run "LastSegmentAndOffset omits the completed pages"
perl -0pi -e 's/        return \(last, donePages \* pageSize \+ page\.alloc\)/        return (last, donePages * pageSize)/' "$WR"; run "LastSegmentAndOffset omits the partial page"

echo "=== SegmentBufReader's padding emulation ==="
perl -0pi -e 's/        if off % pageSize != 0 \{/        if false {/' "$RD"; run "a short segment is not zero-padded to a page"
perl -0pi -e 's/            while n \+ i < range\.count && \(off \+ i\) % pageSize != 0 \{/            while n + i < range.count {/' "$RD"; run "the fake padding runs past the page boundary"
perl -0pi -e 's/        if cur \+ 1 >= segs\.count \{ return nil \}\n\n        cur \+= 1\n        off = 0\n        return n/        if cur + 1 >= segs.count { return nil }\n\n        cur += 1\n        return n/' "$RD"; run "the per-segment offset is not reset on advance"
perl -0pi -e 's/            if r\.first >= 0 && ref\.index < r\.first \{ continue \}/            if r.first >= 0 \&\& ref.index < r.first { break }/' "$RD"; run "the range's first bound breaks instead of continuing"
perl -0pi -e 's/            if r\.last >= 0 && ref\.index > r\.last \{ break \}/            if r.last >= 0 \&\& ref.index > r.last { continue }/' "$RD"; run "the range's last bound continues instead of breaking"
# ^ Both directions of the same asymmetry, and the second is expected to SURVIVE: `listSegments` is sorted,
# so `continue` and `break` reject the same set on the upper bound too. It is here as the contrast to the
# lower-bound control, which does break — because `break` there stops at the FIRST segment below `first`,
# i.e. at index 0, and returns nothing at all.
