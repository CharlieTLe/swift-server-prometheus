package main

// Differential coverage for `ReadTombstones`' and `Decode`'s REJECTION paths — the half `tombstones/file`
// cannot reach, modelled on `wal/corrupt` (HANDOFF §7c).
//
// ## Why a second input shape exists at all
//
// `tombstones/file` is a writer -> reader round trip, so every byte the reader sees was produced by
// `WriteFile` one call earlier and is well-formed *by construction*. That makes every validation in
// `ReadTombstones` unreachable: the header-size guard, the magic comparison, the checksum, the format byte
// and every `Decbuf` under-run could be deleted outright and nothing would fail. §7c's lesson, restated —
// **a write program cannot express "one bit flipped"**.
//
// So this suite's input is not a program, it is a **file description**: the magic, the version byte, the
// body and the CRC as four independently overridable or omittable parts, plus a trailer and a truncation.
// Every one of those is a corruption a real disk produces — a torn write truncates, a bad sector flips a
// bit, a half-finished `fileutil.Replace` leaves a short file.
//
// ## The four things worth knowing before reading the expectations
//
// **1. An 8-byte file PANICS.** `ReadTombstones` guards `len(b) < 5` and then slices `d.Get()[1:]` with no
// guard. After `Be32` has taken the magic, `d.Get()` is `len(b) - 8` bytes, so exactly eight leaves it empty
// and Go's slice rule (`low <= high`, `high` defaulting to `len`) rejects `[1:0]`. `OpenBlock` has no
// recover, so a truncated tombstone file takes Prometheus down. Recorded as PORTING.md quirk 210, recovered
// here into the `panic` field, and raised as an error with Go's text by the port.
//
// **2. The CRC does not cover the version byte.** Both ends slice `[tombstoneFormatVersionSize:]`, with the
// comment "we do this for compatibility". So corrupting the version byte does NOT fail the checksum — it
// gets all the way to `Decode` and answers `invalid tombstone format 2`. Quirk 211.
//
// **3. A 5-to-7-byte file answers `invalid magic number 0`, not a size error.** `Be32` under-runs, latches
// `ErrInvalidSize`, and *returns 0* — and the magic comparison is checked before `d.Err()` is. Quirk 212.
//
// **4. `Decode` on an EMPTY buffer answers `invalid tombstone format 0` for the same reason**, which is why
// both of the file's `if d.Err() != nil` checks are dead code. Quirk 213.
//
// ## What is deliberately NOT expressible here
//
// A body longer than the file: there is no length prefix anywhere in this format, so "a length that
// overruns" has no field to live in. The equivalent corruption is a body that ends mid-triple, which is what
// `body-*-truncated` reaches, and a trailer whose bytes get eaten as the CRC, which is `trailer-*`.

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"

	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

var tombstoneCastagnoli = crc32.MakeTable(crc32.Castagnoli)

// Sentinels for the three overridable header fields. -1 means "the correct value", -2 means "omit these
// bytes entirely", anything else is written verbatim.
const (
	tsKeep = -1
	tsOmit = -2
)

type tsCorruptIn struct {
	// The file is not created at all, so `os.IsNotExist` decides.
	Absent bool `json:"absent"`
	// BE32 magic. tsKeep writes MagicTombstone, tsOmit writes nothing.
	Magic int64 `json:"magic"`
	// The format version byte. tsKeep writes 1, tsOmit writes nothing.
	Version int `json:"version"`
	// The bytes after the version byte, hex. This is exactly the CRC's input.
	Body string `json:"body"`
	// BE32 CRC trailer. tsKeep computes CRC-32C over Body, tsOmit writes nothing.
	CRC int64 `json:"crc"`
	// Appended after the CRC, hex — bytes a reader will mistake for the checksum.
	Trailer string `json:"trailer"`
	// Cut the assembled file to this many bytes. -1 leaves it whole.
	TruncateTo int `json:"truncateTo"`
}

type tsCorruptOut struct {
	// The bytes actually written, hex — so a fixture line is readable without re-running the assembler.
	File string `json:"file"`

	// `ReadTombstones`. `Panic` is the recovered runtime error; the port raises it as an error carrying the
	// same text, so the Swift side sorts by the `runtime error: ` prefix.
	Err     string    `json:"err"`
	Panic   string    `json:"panic"`
	Size    int64     `json:"size"`
	Total   uint64    `json:"total"`
	Entries []tsEntry `json:"entries"`

	// `Decode` on `version || body` directly, which stays reachable when the framing is broken.
	DecodeErr     string    `json:"decodeErr"`
	DecodePanic   string    `json:"decodePanic"`
	DecodeTotal   uint64    `json:"decodeTotal"`
	DecodeEntries []tsEntry `json:"decodeEntries"`
}

// The assembler, mirrored byte for byte in `TombstoneCorruptTests`. Kept separate from the writer on purpose:
// the point of this corpus is bytes `WriteFile` would never produce.
func tsAssemble(in tsCorruptIn) []byte {
	body, err := hex.DecodeString(in.Body)
	if err != nil {
		panic(err)
	}
	trailer, err := hex.DecodeString(in.Trailer)
	if err != nil {
		panic(err)
	}

	var buf []byte
	if in.Magic != tsOmit {
		mg := uint32(tombstones.MagicTombstone)
		if in.Magic != tsKeep {
			mg = uint32(in.Magic)
		}
		m4 := make([]byte, 4)
		binary.BigEndian.PutUint32(m4, mg)
		buf = append(buf, m4...)
	}
	if in.Version != tsOmit {
		v := byte(1)
		if in.Version != tsKeep {
			v = byte(in.Version)
		}
		buf = append(buf, v)
	}
	buf = append(buf, body...)
	if in.CRC != tsOmit {
		c := crc32.Checksum(body, tombstoneCastagnoli)
		if in.CRC != tsKeep {
			c = uint32(in.CRC)
		}
		c4 := make([]byte, 4)
		binary.BigEndian.PutUint32(c4, c)
		buf = append(buf, c4...)
	}
	buf = append(buf, trailer...)

	if in.TruncateTo >= 0 && in.TruncateTo < len(buf) {
		buf = buf[:in.TruncateTo]
	}
	return buf
}

// The bytes `Decode` is called with: the version byte, if present, then the body. Independent of the
// truncation, which is a property of the FILE and not of the payload.
func tsDecodeInput(in tsCorruptIn) []byte {
	body, err := hex.DecodeString(in.Body)
	if err != nil {
		panic(err)
	}
	var buf []byte
	if in.Version != tsOmit {
		v := byte(1)
		if in.Version != tsKeep {
			v = byte(in.Version)
		}
		buf = append(buf, v)
	}
	return append(buf, body...)
}

// `Encode`'s body for a set of triples, WITHOUT the leading version byte — i.e. exactly the CRC's input.
// Built with an `Encbuf` through the real `Encode` so the corpus's "well-formed" baseline is upstream's own
// and not a second implementation of the format.
func tsBody(adds ...tsAdd) string {
	mem := tombstones.NewMemTombstones()
	for _, a := range adds {
		mem.AddInterval(storage.SeriesRef(a.Ref), tombstones.Interval{Mint: a.Mint, Maxt: a.Maxt})
	}
	b, err := tombstones.Encode(newOrderedTombstones(mem, -1))
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[1:])
}

func genTombstoneCorrupt(e *emitter) {
	n := 0
	emit := func(name string, in tsCorruptIn) {
		dir, err := os.MkdirTemp("", "promoracle-tscorrupt")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		out := tsCorruptOut{Entries: []tsEntry{}, DecodeEntries: []tsEntry{}}

		if !in.Absent {
			b := tsAssemble(in)
			out.File = hex.EncodeToString(b)
			if err := os.WriteFile(
				filepath.Join(dir, tombstones.TombstonesFilename), b, 0o666,
			); err != nil {
				panic(err)
			}
		}

		func() {
			defer func() {
				if r := recover(); r != nil {
					out.Panic = fmt.Sprint(r)
				}
			}()
			tr, size, err := tombstones.ReadTombstones(dir)
			if err != nil {
				out.Err = err.Error()
				return
			}
			out.Size = size
			out.Total = tr.Total()
			out.Entries = flattenTombstoneReader(tr)
		}()

		func() {
			defer func() {
				if r := recover(); r != nil {
					out.DecodePanic = fmt.Sprint(r)
				}
			}()
			tr, err := tombstones.Decode(tsDecodeInput(in))
			if err != nil {
				out.DecodeErr = err.Error()
				return
			}
			out.DecodeTotal = tr.Total()
			out.DecodeEntries = flattenTombstoneReader(tr)
		}()

		e.emit(fmt.Sprintf("tscorrupt/%02d-%s", n, name), in, out)
		n++
	}

	add := func(ref uint64, mint, maxt int64) tsAdd { return tsAdd{Ref: ref, Mint: mint, Maxt: maxt} }
	// A well-formed baseline every corruption below is a perturbation of.
	good := tsBody(add(7, 1, 5), add(9, 100, 200))
	base := func() tsCorruptIn {
		return tsCorruptIn{Magic: tsKeep, Version: tsKeep, Body: good, CRC: tsKeep, TruncateTo: -1}
	}
	raw := func(body string) tsCorruptIn {
		return tsCorruptIn{Magic: tsKeep, Version: tsKeep, Body: body, CRC: tsKeep, TruncateTo: -1}
	}

	// ── The inert controls ──────────────────────────────────────────────────────────────────────────
	// A file with no deletions and a file with two series, both well-formed. If either of these ever
	// reports an error the corpus is measuring the assembler rather than the reader.
	emit("ok-empty", raw(""))
	emit("ok-two-series", base())

	// ── The file is not there ───────────────────────────────────────────────────────────────────────
	// `os.IsNotExist` -> an empty reader and a size of ZERO, with no error at all. A block with no
	// deletions relies on this; so does one whose `tombstones` file a compaction never wrote.
	emit("absent", tsCorruptIn{Absent: true, Magic: tsKeep, Version: tsKeep, CRC: tsKeep, TruncateTo: -1})

	// ── Shorter than the header ─────────────────────────────────────────────────────────────────────
	// `len(b) < tombstonesHeaderSize` -> `tombstones header: invalid size`. Note the guard is 5, not 9:
	// it admits files that cannot possibly be valid, which is what the next family is about.
	for _, k := range []int{0, 1, 2, 3, 4} {
		in := base()
		in.TruncateTo = k
		emit(fmt.Sprintf("short-%d", k), in)
	}

	// ── Long enough to pass the guard, too short to be a file ───────────────────────────────────────
	// 5, 6, 7: `Be32` under-runs, returns 0, and the MAGIC arm answers. Quirk 212.
	// 8:       `d.Get()` is empty and `[1:]` PANICS. Quirk 210, and the reason this suite exists.
	for _, k := range []int{5, 6, 7, 8} {
		in := base()
		in.TruncateTo = k
		emit(fmt.Sprintf("short-%d", k), in)
	}
	// Nine bytes of a longer file: the magic and the version survive, the body is gone and its last four
	// bytes are read as the CRC — so this is a checksum failure rather than a size one.
	for _, k := range []int{9, 10, 12} {
		in := base()
		in.TruncateTo = k
		emit(fmt.Sprintf("short-%d", k), in)
	}
	// One byte short of the whole file: the CRC's last byte is missing, so the four bytes read as the
	// checksum straddle the body.
	{
		in := base()
		in.TruncateTo = len(tsAssemble(base())) - 1
		emit("truncate-one-byte", in)
	}
	// The smallest VALID file is nine bytes: magic, `01`, no entries, and the CRC-32C of nothing, which is
	// zero. Truncating an empty file to eight reaches the panic from the other side.
	{
		in := raw("")
		in.TruncateTo = 8
		emit("empty-file-truncated-to-8", in)
	}
	{
		in := raw("")
		in.TruncateTo = 9
		emit("empty-file-untruncated", in)
	}

	// ── The ORDER of the three guards, which is the part a port gets wrong ──────────────────────────
	// Eight bytes AND a bad magic: the magic arm answers, so the panic is not reached. A port that
	// checked the remaining length first would report a size error here and pass every other case.
	{
		in := base()
		in.Magic = 0
		in.TruncateTo = 8
		emit("order-short-8-bad-magic", in)
	}
	// Four bytes AND a bad magic: the size guard answers, so the magic is never read.
	{
		in := base()
		in.Magic = 0
		in.TruncateTo = 4
		emit("order-short-4-bad-magic", in)
	}
	// A bad version AND a bad checksum: the CHECKSUM answers, because `Decode` runs last.
	{
		in := base()
		in.Version = 2
		in.CRC = 0
		emit("order-bad-version-bad-crc", in)
	}

	// ── The magic ───────────────────────────────────────────────────────────────────────────────────
	// `%x` on a uint32: lowercase, unpadded, so zero prints as a single `0`.
	for _, m := range []int64{
		0,
		1,
		0x0130BA31,             // one bit off in the low byte
		0x0130BA20,             // one bit off in the middle
		0x8130BA30,             // the high bit set
		0x30BA3001,             // byte-swapped, i.e. a little-endian writer
		0xFFFFFFFF,             // all ones
		int64(0x0130BA30) >> 8, // shifted, i.e. a reader one byte out of phase
	} {
		in := base()
		in.Magic = m
		emit(fmt.Sprintf("magic-%08x", uint32(m)), in)
	}
	// No magic at all: the version byte and the body slide four bytes forward.
	{
		in := base()
		in.Magic = tsOmit
		emit("magic-omitted", in)
	}

	// ── The version byte, which the CRC does NOT cover ──────────────────────────────────────────────
	// Every one of these passes the checksum and is rejected by `Decode`. Quirk 211.
	for _, v := range []int{0, 2, 3, 0x7F, 0x80, 0xFF} {
		in := base()
		in.Version = v
		emit(fmt.Sprintf("version-%02x", v), in)
	}
	// No version byte: the first body byte is read as the format, and the CRC — computed over the body —
	// no longer matches what the reader hashes, because the reader skips a byte that is now payload.
	{
		in := base()
		in.Version = tsOmit
		emit("version-omitted", in)
	}

	// ── The checksum ────────────────────────────────────────────────────────────────────────────────
	{
		in := base()
		in.CRC = 0
		emit("crc-zero", in)
	}
	{
		in := base()
		in.CRC = int64(crc32.Checksum(mustHex(good), tombstoneCastagnoli)) ^ 1
		emit("crc-one-bit", in)
	}
	{
		in := base()
		in.CRC = 0xFFFFFFFF
		emit("crc-all-ones", in)
	}
	{
		// Byte-swapped: a little-endian writer's checksum.
		c := crc32.Checksum(mustHex(good), tombstoneCastagnoli)
		swapped := uint32(0)
		for i := range 4 {
			swapped |= uint32(byte(c>>(8*uint(i)))) << (8 * uint(3-i))
		}
		in := base()
		in.CRC = int64(swapped)
		emit("crc-byteswapped", in)
	}
	{
		// No checksum at all: the last four BODY bytes are taken as one, so this is both a short body and
		// a wrong checksum, and the checksum arm answers first.
		in := base()
		in.CRC = tsOmit
		emit("crc-omitted", in)
	}
	{
		// The checksum computed over the version byte AND the body — the mistake a port makes if it reads
		// `hash.Write(bytes)` instead of `hash.Write(bytes[1:])`. It must be REJECTED.
		withVersion := append([]byte{1}, mustHex(good)...)
		in := base()
		in.CRC = int64(crc32.Checksum(withVersion, tombstoneCastagnoli))
		emit("crc-over-version-too", in)
	}
	{
		// And over the magic as well, which is the other plausible wrong range.
		m4 := make([]byte, 4)
		binary.BigEndian.PutUint32(m4, uint32(tombstones.MagicTombstone))
		whole := append(append(m4, 1), mustHex(good)...)
		in := base()
		in.CRC = int64(crc32.Checksum(whole, tombstoneCastagnoli))
		emit("crc-over-whole-header", in)
	}

	// ── A bit flipped in the BODY, so the checksum is the only thing that can notice ─────────────────
	{
		b := mustHex(good)
		b[0] ^= 1
		in := base()
		in.Body = hex.EncodeToString(b)
		in.CRC = int64(crc32.Checksum(mustHex(good), tombstoneCastagnoli)) // the ORIGINAL body's checksum
		emit("body-bit-flip-first", in)
	}
	{
		b := mustHex(good)
		b[len(b)-1] ^= 0x80
		in := base()
		in.Body = hex.EncodeToString(b)
		in.CRC = int64(crc32.Checksum(mustHex(good), tombstoneCastagnoli))
		emit("body-bit-flip-last", in)
	}

	// ── Trailing bytes ──────────────────────────────────────────────────────────────────────────────
	// The CRC is the LAST four bytes, so anything appended is read as the checksum and the real one
	// becomes payload. A file that grew is as broken as one that shrank.
	{
		in := base()
		in.Trailer = "aa"
		emit("trailer-one-byte", in)
	}
	{
		in := base()
		in.Trailer = "0000000000000000"
		emit("trailer-eight-zeros", in)
	}

	// ── A well-formed frame around a MALFORMED body ─────────────────────────────────────────────────
	// The CRC is computed over whatever the body is, so these all reach `Decode`.
	emit("body-ref-only", raw("07"))              // a ref and nothing else
	emit("body-ref-mint-only", raw("0702"))       // no maxt
	emit("body-triple-plus-one", raw("07020a07")) // one whole triple, then a stray ref
	emit("body-triple-plus-two", raw("07020a0702"))
	emit("body-dangling-varint", raw("07020a80")) // a continuation byte with nothing after it
	emit("body-all-continuations", raw("8080808080808080808080")) // 11 bytes that never terminate
	emit("body-overlong-uvarint", raw("ffffffffffffffffffff7f"))  // > 64 bits of uvarint
	emit("body-single-zero", raw("00"))                           // ref 0, then nothing

	// Well-formed but SEMANTICALLY odd bodies — accepted, because the codec validates nothing.
	emit("body-inverted-interval", raw(hexTriple(1, 10, 1)))
	emit("body-duplicate-ref", raw(hexTriple(1, 1, 5)+hexTriple(1, 1, 5)))
	emit("body-adjacent-merge", raw(hexTriple(1, 1, 5)+hexTriple(1, 6, 9)))
	emit("body-unsorted-refs", raw(hexTriple(9, 1, 5)+hexTriple(1, 1, 5)))
	// Intervals for one ref in DESCENDING order, which `Encode` can never produce — `Intervals.Add` keeps
	// them sorted — so this is the only way to see that `Decode` re-sorts rather than appending.
	emit("body-descending-intervals", raw(hexTriple(1, 20, 25)+hexTriple(1, 1, 5)+hexTriple(1, 10, 15)))
	emit("body-ref-maxuint64", raw(hexTriple(math.MaxUint64, math.MinInt64, math.MaxInt64)))

	// ── `Decode` reached directly, with no file at all ──────────────────────────────────────────────
	// The version byte omitted AND an empty body is `Decode([])`, which answers `invalid tombstone
	// format 0` rather than `invalid size` — quirk 213, and the reason both `d.Err()` checks are dead.
	{
		in := tsCorruptIn{Absent: true, Magic: tsKeep, Version: tsOmit, Body: "", CRC: tsKeep, TruncateTo: -1}
		emit("decode-empty-buffer", in)
	}
	{
		in := tsCorruptIn{Absent: true, Magic: tsKeep, Version: tsKeep, Body: "", CRC: tsKeep, TruncateTo: -1}
		emit("decode-version-only", in)
	}
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// One `[uvarint ref][varint mint][varint maxt]` triple, hex. Hand-assembled rather than routed through
// `Encode`, because several cases need a triple `Intervals.Add` would have merged or reordered away.
func hexTriple(ref uint64, mint, maxt int64) string {
	var b []byte
	b = binary.AppendUvarint(b, ref)
	b = binary.AppendVarint(b, mint)
	b = binary.AppendVarint(b, maxt)
	return hex.EncodeToString(b)
}
