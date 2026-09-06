#!/usr/bin/env bash
# Negative controls for the tombstone FILE CODEC — `tsdb/tombstones/tombstones.go`'s `Encode`, `Decode`,
# `WriteFile` and `ReadTombstones`.
#
# Two source files, so `run` takes the file it perturbed (the two-file helper from
# `Scripts/controls-headwaltruncate.sh`):
#
#   Sources/PromTombstones/TombstoneFile.swift   the codec
#   Sources/PromTombstones/MemTombstones.swift   `Iter`'s order, which is PORTING.md exception 29 and which
#                                                the file's byte order is a function of
#
# Two corpora, and the split is the point of the slice:
#
#   Fixtures/tombstones/file.jsonl     a write/read round trip — every byte well-formed by construction
#   Fixtures/tombstones/corrupt.jsonl  a file DESCRIPTION (magic, version, body, CRC, trailer, truncation),
#                                      because a write program cannot express "one bit flipped"
#
# Both suites run on every control: the codec is observable from either side, and several controls are
# visible in exactly one of them (the CRC's input range only in the round trip, the guard ORDER only in the
# corruption arm).
#
# The perl-escaping traps `controls-headwaltruncate.sh` paid for apply here too and one of them shaped this
# script: **a pattern can never contain a Swift string interpolation**, because `\Q…\E` eats the backslash.
# That is why "the encode error is not wrapped" is spelled as a swap to a DIFFERENT wrapper rather than as a
# deletion of `TombstoneFileError.encodingTombstones("\(err)")` — the line carries an interpolation and is
# unmatchable. Same reason nothing here touches the two `let path = ...` lines.
set -uo pipefail
cd "$(dirname "$0")/.."
TF=Sources/PromTombstones/TombstoneFile.swift
MT=Sources/PromTombstones/MemTombstones.swift
cp "$TF" /tmp/tsf-tf.orig
cp "$MT" /tmp/tsf-mt.orig
restore() { cp /tmp/tsf-tf.orig "$TF"; cp /tmp/tsf-mt.orig "$MT"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$TF") orig=/tmp/tsf-tf.orig ;;
    "$MT") orig=/tmp/tsf-mt.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-72s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'Tombstone(File|Corrupt)Tests' 72
  restore
}

echo "=== Encode: the version byte and the triple stream ==="
perl -0pi -e 's~\Q    buf.putByte(tombstoneFormatV1)\E~~' "$TF"; run "$TF" "the version byte is never written"
perl -0pi -e 's~\Q    buf.putByte(tombstoneFormatV1)\E~    buf.putByte(2)~' "$TF"; run "$TF" "the version byte is 2"
perl -0pi -e 's~\Q                buf.putUvarint64(ref.rawValue)\E~                buf.putVarint64(Int64(bitPattern: ref.rawValue))~' "$TF"; run "$TF" "the ref is a SIGNED varint"
perl -0pi -e 's~\Q                buf.putUvarint64(ref.rawValue)\E~                buf.putBE64(ref.rawValue)~' "$TF"; run "$TF" "the ref is a fixed BE64, as the WAL record writes it"
perl -0pi -e 's~\Q                buf.putVarint64(iv.mint)\E~                buf.putUvarint64(UInt64(bitPattern: iv.mint))~' "$TF"; run "$TF" "mint is an UNSIGNED varint, so the zigzag is gone"
perl -0pi -e 's~\Q                buf.putVarint64(iv.mint)\E\n\Q                buf.putVarint64(iv.maxt)\E~                buf.putVarint64(iv.maxt)\n                buf.putVarint64(iv.mint)~' "$TF"; run "$TF" "mint and maxt are written in the other order"
perl -0pi -e 's~\Q                buf.putVarint64(iv.maxt)\E~~' "$TF"; run "$TF" "maxt is not written"
perl -0pi -e 's~\Q            for iv in ivs {\E\n\Q                buf.putUvarint64(ref.rawValue)\E~            buf.putUvarint64(ref.rawValue)\n            for iv in ivs {~' "$TF"; run "$TF" "the ref is written once per SERIES rather than once per interval"
perl -0pi -e 's~\Q    return (buf.bytes, thrown)\E~    return (thrown == nil ? buf.bytes : [], thrown)~' "$TF"; run "$TF" "Encode discards the partial buffer when Iter fails"
perl -0pi -e 's~\Q        thrown = error\E~~' "$TF"; run "$TF" "the Iter error is swallowed"

echo "=== Decode: the format byte, the loop, and the sticky error ==="
perl -0pi -e 's~\Q        if flag != tombstoneFormatV1 {\E\n\Q            throw TombstoneFileError.invalidTombstoneFormat(flag)\E\n\Q        }\E~~' "$TF"; run "$TF" "the format byte is not checked"
perl -0pi -e 's~\Q        if flag != tombstoneFormatV1 {\E~        if flag == 0 {~' "$TF"; run "$TF" "the format check only rejects zero"
perl -0pi -e 's~\Q        let flag = d.byte()\E~        let flag = d.byte()\n        if let e0 = d.err { throw TombstoneFileError.decode(e0) }~' "$TF"; run "$TF" "the sticky-error check runs BEFORE the format check"
perl -0pi -e 's~\Q        while d.count > 0 {\E~        while d.count > 1 {~' "$TF"; run "$TF" "the entry loop stops with one byte left"
perl -0pi -e 's~\Q            if let e = d.err {\E\n\Q                throw TombstoneFileError.decode(e)\E\n\Q            }\E~~' "$TF"; run "$TF" "the per-entry error check is dropped"
perl -0pi -e 's~\Q            if let e = d.err {\E\n\Q                throw TombstoneFileError.decode(e)\E\n\Q            }\E\n\Q            stonesMap.addInterval(k, DeletionInterval(mint: mint, maxt: maxt))\E~            stonesMap.addInterval(k, DeletionInterval(mint: mint, maxt: maxt))\n            if let e = d.err {\n                throw TombstoneFileError.decode(e)\n            }~' "$TF"; run "$TF" "the error is noticed AFTER the interval is added"
perl -0pi -e 's~\Q            let k = SeriesRef(rawValue: d.uvarint64())\E~            let k = SeriesRef(rawValue: UInt64(bitPattern: d.varint64()))~' "$TF"; run "$TF" "the ref is read as a SIGNED varint"
perl -0pi -e 's~\Q            let mint = d.varint64()\E\n\Q            let maxt = d.varint64()\E~            let maxt = d.varint64()\n            let mint = d.varint64()~' "$TF"; run "$TF" "mint and maxt are read in the other order"
perl -0pi -e 's~\Q            stonesMap.addInterval(k, DeletionInterval(mint: mint, maxt: maxt))\E~            stonesMap.addInterval(k, DeletionInterval(mint: maxt, maxt: mint))~' "$TF"; run "$TF" "the decoded interval is inverted"
perl -0pi -e 's~\Q            stonesMap.addInterval(k, DeletionInterval(mint: mint, maxt: maxt))\E~~' "$TF"; run "$TF" "the decoded interval is never added"

echo "=== ReadTombstones: the four guards, and their ORDER ==="
perl -0pi -e 's~\Q            return (MemTombstones(), 0)\E~            throw e~' "$TF"; run "$TF" "a missing file is an error rather than an empty reader"
perl -0pi -e 's~\Q            return (MemTombstones(), 0)\E~            return (MemTombstones(), 1)~' "$TF"; run "$TF" "a missing file reports a non-zero size"
perl -0pi -e 's~\Q    if b.count < tombstonesHeaderSize {\E\n\Q        throw TombstoneFileError.header(.invalidSize)\E\n\Q    }\E~~' "$TF"; run "$TF" "the header-size guard is dropped"
perl -0pi -e 's~\Q    if b.count < tombstonesHeaderSize {\E~    if b.count <= tombstonesHeaderSize {~' "$TF"; run "$TF" "the header-size guard rejects a five-byte file too"
perl -0pi -e 's~\Q    if b.count < tombstonesHeaderSize {\E~    if b.count < 9 {~' "$TF"; run "$TF" "the header size is 9 (the smallest VALID file) rather than 5"
perl -0pi -e 's~\Q        var d = Decbuf(owner.bytes.range(0, b.count - tombstonesCRCSize))\E~        var d = Decbuf(owner.bytes)~' "$TF"; run "$TF" "the CRC trailer is left on the buffer the reader parses"
perl -0pi -e 's~\Q        if mg != magicTombstone {\E\n\Q            // For a 5-to-7-byte file \E[^\n]*\n[^\n]*\n\Q            throw TombstoneFileError.invalidMagicNumber(mg)\E\n\Q        }\E~~' "$TF"; run "$TF" "the magic number is not checked"
perl -0pi -e 's~\Q        if mg != magicTombstone {\E~        if mg != magicTombstone.byteSwapped {~' "$TF"; run "$TF" "the magic is compared byte-swapped"
perl -0pi -e 's~\Q        if d.count < tombstoneFormatVersionSize {\E\n\Q            throw TombstoneFileError.sliceBoundsOutOfRange(low: tombstoneFormatVersionSize, high: d.count)\E\n\Q        }\E~~' "$TF"; run "$TF" "the eight-byte panic guard is dropped (quirk 210)"
perl -0pi -e 's~\Q        if d.count < tombstoneFormatVersionSize {\E~        if d.count <= tombstoneFormatVersionSize {~' "$TF"; run "$TF" "the panic guard also rejects a nine-byte file"
perl -0pi -e 's~\Q        hash.update(Array(d.b.range(tombstoneFormatVersionSize, d.count).rawBuffer))\E~        hash.update(Array(d.b.range(0, d.count).rawBuffer))~' "$TF"; run "$TF" "the checksum COVERS the version byte on read (quirk 211)"
perl -0pi -e 's~\Q        if stored != hash.final() {\E\n\Q            throw TombstoneFileError.checksumDidNotMatch\E\n\Q        }\E~~' "$TF"; run "$TF" "the checksum is never compared"
perl -0pi -e 's~\Q        let stored = owner.bytes.loadBE32(at: b.count - tombstonesCRCSize)\E~        let stored = owner.bytes.loadBE32(at: 0)~' "$TF"; run "$TF" "the stored checksum is read from the FRONT of the file"
perl -0pi -e 's~\Q        return (stonesMap, Int64(b.count))\E~        return (stonesMap, Int64(b.count - tombstonesCRCSize))~' "$TF"; run "$TF" "the size returned excludes the CRC"
perl -0pi -e 's~\Q        let stonesMap = try decodeTombstones(Array(d.b.rawBuffer))\E~        let stonesMap = try decodeTombstones(Array(d.b.range(1, d.count).rawBuffer))~' "$TF"; run "$TF" "Decode is handed the body WITHOUT its version byte"

echo "=== WriteFile: the framing, the size, and the temporary file ==="
perl -0pi -e 's~\Q    buf.putBE32(magicTombstone)\E~~' "$TF"; run "$TF" "the magic is not written"
perl -0pi -e 's~\Q    buf.putBE32(magicTombstone)\E~    buf.putBE32(magicTombstone.byteSwapped)~' "$TF"; run "$TF" "the magic is written little-endian"
perl -0pi -e 's~\Q    hash.update(bytes[tombstoneFormatVersionSize...])\E~    hash.update(bytes[0...])~' "$TF"; run "$TF" "the checksum COVERS the version byte on write (quirk 211)"
perl -0pi -e 's~\Q    hash.update(bytes[tombstoneFormatVersionSize...])\E~~' "$TF"; run "$TF" "the checksum is over nothing at all"
perl -0pi -e 's~\Q    try f.append(sum)\E~~' "$TF"; run "$TF" "the CRC trailer is not written"
perl -0pi -e 's~\Q    size += buf.count\E~~' "$TF"; run "$TF" "the returned size omits the magic"
perl -0pi -e 's~\Q    size += bytes.count\E~~' "$TF"; run "$TF" "the returned size omits the body"
perl -0pi -e 's~\Q    size += sum.count\E~~' "$TF"; run "$TF" "the returned size omits the CRC"
perl -0pi -e 's~\Q        try? fs.remove(tmp)\E~~' "$TF"; run "$TF" "the temporary file is left behind"
perl -0pi -e 's~\Q    try copyTombstoneFile(fs, from: tmp, to: path)\E~~' "$TF"; run "$TF" "the temporary file is never copied to its final name"
perl -0pi -e 's~\Q        throw TombstoneFileError.encodingTombstones(\E~        throw TombstoneFileError.writingTombstones(~' "$TF"; run "$TF" "the Encode failure is wrapped with the WRITING prefix"
perl -0pi -e 's~\Q    if let encodeError {\E~    if false, let encodeError {~' "$TF"; run "$TF" "the Encode failure is not raised at all"

echo "=== MemTombstones.Iter, which is exception 29 and the file byte order ==="
perl -0pi -e 's~\Q        for ref in intervalGroups.keys.sorted() {\E~        for ref in intervalGroups.keys {~' "$MT"; run "$MT" "Iter is unsorted, as upstream Go-maps it"
perl -0pi -e 's~\Q        for ref in intervalGroups.keys.sorted() {\E~        for ref in intervalGroups.keys.sorted().reversed() {~' "$MT"; run "$MT" "Iter is DESCENDING by ref"

echo "=== Expected survivors: one inert by construction, the rest argued below ==="
perl -0pi -e 's~\Q    var buf = Encbuf(reservingCapacity: 3 \E\Q* 10)\E~    var buf = Encbuf()~' "$TF"; run "$TF" "the Encbuf capacity reservation is dropped (INERT — must survive)"
perl -0pi -e 's~\Q    try f.sync()\E~~' "$TF"; run "$TF" "the temporary file is never synced"
perl -0pi -e 's~\Q        if let e = d.err {\E\n\Q            throw TombstoneFileError.decode(e)\E\n\Q        }\E~~g' "$TF"; run "$TF" "both dead sticky-error checks are deleted (quirk 213)"

cat <<'ARGUMENT'

=== The score: 52 controls, 48 broke, 4 SURVIVED — and all four are proofs ===

1. **the error is noticed AFTER the interval is added.** Moving the per-entry `d.err` check below
   `addInterval` changes nothing, because `Decode` returns a reader only on the success path: any thrown
   error discards `stonesMap` entirely, so whether the last, half-read triple was appended to a map nobody
   will ever see is unobservable *in principle*, not merely uncovered. `readTombstones` propagates, so the
   same holds one level up. The neighbouring control — dropping the check outright — **hangs**, which is the
   other half of the argument: the check must exist (a latched `Decbuf` does not consume, so `d.count` never
   reaches zero), it just does not matter where in the iteration it sits.

2. **the Encbuf capacity reservation is dropped — the DELIBERATELY INERT control.** `Encbuf(reservingCapacity:
   3 * 10)` reproduces `encoding.Encbuf{B: make([]byte, 3*binary.MaxVarintLen64)}` from `tombstones.go:97`,
   which upstream immediately `Reset`s and then uses for four bytes. It is an allocation hint and nothing
   reads it back — there is no `cap()` on the wire. A sweep in which this broke would be measuring the
   harness, not the codec. Contrast PORTING.md exception 18, where a capacity heuristic in `record.go` IS
   observable, because it is measured rather than reserved.

3. **the temporary file is never synced.** `PromFS.sync` is a documented no-op (ADR-15: "durability is
   untestable in this harness and unobservable in a corpus"), so removing the call cannot change a byte.
   The call site is kept for the reason PORTING.md §4 gives — a later durability slice needs somewhere to
   put the real thing — and this control is what says the *shape* is all that is being kept.

4. **both dead sticky-error checks are deleted.** `tombstones.go:164` and `:217` each read `if d.Err() != nil
   { return nil, d.Err() }`, and neither can fire. In `Decode`, the only read above the check is `d.Byte()`,
   whose failure returns 0 and is answered by the FORMAT arm one line earlier — which is why an empty buffer
   says `invalid tombstone format 0` and not `invalid size` (quirk 213). In `ReadTombstones` the only read
   above is `d.Be32()`, whose failure returns 0 and is answered by the MAGIC arm — which is why a 5-to-7-byte
   file says `invalid magic number 0` (quirk 212). Both are ported anyway because a reader who found them
   missing would go looking, and both stay in the sweep because the argument is about the arms ABOVE them:
   if either of those arms is ever reordered, this control stops surviving, which is the alarm.

   Note this is not the same claim as control "the sticky-error check runs BEFORE the format check", which
   BREAKS. Together they say: the check is dead *where it is*, and moving it is observable.

Nine of the 48 that broke are reachable ONLY from `tombstones/corrupt.jsonl` — the four guards, their order,
the panic guard and the two CRC-range controls — which is the measurement the corruption arm was built to
make. Before it existed the round-trip corpus could see none of them.
ARGUMENT
