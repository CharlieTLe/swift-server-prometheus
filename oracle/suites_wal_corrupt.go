package main

// Differential coverage for `wlog.Reader`'s REJECTION paths — the half `wal/segments` cannot reach.
//
// ## Why a second input shape exists at all
//
// `wal/segments` is a writer -> reader round trip: every byte the reader sees was produced by `WL.log` one
// call earlier, so it is well-formed *by construction*. That makes every validation in the reader
// unreachable, and the negative-control sweep said so out loud — 22 survivors, of which nine were this one
// gap: deleting `if c != crc` outright, or the length bound, or any arm of `validateRecord`, or the
// non-zero-padding check, failed **nothing**.
//
// A write program cannot express "one bit flipped". So this suite's input is not a program, it is
// **fragments**: an explicit type byte, an explicit payload, and optional overrides of the length and CRC
// fields. That is upstream's own `testReaderCases` vocabulary (reader_test.go:63) plus the three things it
// does not have, because `encodedRecord` always computes a correct CRC and never truncates:
//
//   - a **wrong CRC** (`crcOverride`);
//   - a **truncated stream** (`truncateTo`), which is what a torn write leaves behind;
//   - a **raw type byte**, so the invalid types 5/6/7 and the snappy/zstd flag bits are expressible.
//
// ## The one thing to know before reading the expectations
//
// **A truncated segment does not produce a short read, and that ERASES the torn-record signal.**
// `SegmentBufReader` fakes zero padding up to the page boundary when a segment's bytes run out mid-page,
// precisely so it does not advance `cur` and blame the wrong file. So a stream cut inside a header is fed
// *zeros* rather than ending, and the reader sees a **page terminator** — which overwrites `curRecTyp`.
// `Reader.Next`'s torn check reads `curRecTyp` after the loop, so by the time it runs the evidence is gone:
//
//   - `torn-after-first` (a `recFirst` fragment and nothing else) reports **no error at all**;
//   - `cut-after-first-fragment` likewise;
//   - only `cut-at-page-boundary`, where the truncation is page-ALIGNED and no padding is faked, answers
//     `last record is torn`.
//
// That is upstream's behaviour and this corpus pins it rather than the intuitive answer. It is also the
// mechanism behind two of the round-trip sweep's survivors, and it means the torn check is reachable from a
// segment file only via an aligned cut — `readFull`'s own two arms need a reader that is not a segment at
// all, which is asserted Swift-side in `WALCorruptTests`.
//
// Every case writes its bytes as segment `00000000` and reads the directory back through
// `NewSegmentsRangeReader` + `NewReader`, so the shared `walReadBack` does the observing and the output
// shape is identical to `wal/segments`'.

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
)

var walCastagnoli = crc32.MakeTable(crc32.Castagnoli)

// One fragment, written by hand. `Type` is the RAW header byte, not a masked record type, so a flag bit or
// an out-of-range type is expressible.
type walFrag struct {
	Type uint8 `json:"type"`
	// The payload, rle-hex.
	Payload string `json:"payload"`
	// Write this in the BE16 length field instead of the payload's real length. -1 for the real length.
	LenOverride int `json:"lenOverride"`
	// Write this in the BE32 CRC field instead of the payload's real checksum. -1 for the real checksum.
	CRCOverride int64 `json:"crcOverride"`
	// A page terminator is a bare type byte followed by padding rather than a header, so it is spelled as
	// its own thing: `PadZeros` bytes of padding after the type byte.
	PageTerm bool `json:"pageTerm"`
	PadZeros int  `json:"padZeros"`
	// Make the LAST padding byte non-zero, which is the `unexpected non-zero byte in padded page` path.
	PadDirty bool `json:"padDirty"`
}

type walCorruptIn struct {
	Frags []walFrag `json:"frags"`
	// Cut the assembled stream to this many bytes. -1 leaves it whole.
	TruncateTo int `json:"truncateTo"`
}

// Assemble the fragment list into the segment's bytes.
func walEncodeFrags(frags []walFrag) []byte {
	var buf []byte
	for _, f := range frags {
		if f.PageTerm {
			buf = append(buf, f.Type)
			pad := make([]byte, f.PadZeros)
			if f.PadDirty && f.PadZeros > 0 {
				pad[f.PadZeros-1] = 1
			}
			buf = append(buf, pad...)
			continue
		}
		payload := unrleHex(f.Payload)
		hdr := make([]byte, walRecordHeaderSize)
		hdr[0] = f.Type

		length := len(payload)
		if f.LenOverride >= 0 {
			length = f.LenOverride
		}
		binary.BigEndian.PutUint16(hdr[1:], uint16(length))

		crc := crc32.Checksum(payload, walCastagnoli)
		if f.CRCOverride >= 0 {
			crc = uint32(f.CRCOverride)
		}
		binary.BigEndian.PutUint32(hdr[3:], crc)

		buf = append(buf, hdr...)
		buf = append(buf, payload...)
	}
	return buf
}

func genWALCorrupt(e *emitter) {
	n := 0
	emit := func(name string, in walCorruptIn) {
		dir, err := os.MkdirTemp("", "promoracle-walc")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		bytes := walEncodeFrags(in.Frags)
		if in.TruncateTo >= 0 && in.TruncateTo < len(bytes) {
			bytes = bytes[:in.TruncateTo]
		}
		if err := os.WriteFile(filepath.Join(dir, "00000000"), bytes, 0o666); err != nil {
			panic(err)
		}

		out := walOut{Segments: []walSegmentOut{}, Read: []string{}}
		// The write-side fields have no meaning here: nothing was logged through a `WL`. They stay at their
		// zero values rather than being omitted, so the fixture keeps one shape per file (§4).
		walReadBack(dir, walIn{ReadFirst: -1, ReadLast: -1}, &out)

		e.emit(fmt.Sprintf("walc/%03d/%s", n, name), in, out)
		n++
	}

	genWALCorruptCases(emit)
}

// A fragment with a real length and a real CRC — the well-formed default the mutations deviate from.
func frag(typ uint8, payload string) walFrag {
	return walFrag{Type: typ, Payload: payload, LenOverride: -1, CRCOverride: -1}
}

func pageTerm(padZeros int) walFrag {
	return walFrag{Type: 0, PageTerm: true, PadZeros: padZeros, LenOverride: -1, CRCOverride: -1}
}

const (
	wtPageTerm uint8 = 0
	wtFull     uint8 = 1
	wtFirst    uint8 = 2
	wtMiddle   uint8 = 3
	wtLast     uint8 = 4
)

func genWALCorruptCases(emit func(string, walCorruptIn)) {
	whole := func(name string, frags ...walFrag) {
		emit(name, walCorruptIn{Frags: frags, TruncateTo: -1})
	}
	cut := func(name string, to int, frags ...walFrag) {
		emit(name, walCorruptIn{Frags: frags, TruncateTo: to})
	}

	maxFrag := walPageSize - walRecordHeaderSize
	small := smallRecord(1, 2, 3)

	// ---- The baseline. If these do not read cleanly the mutations below prove nothing. ----
	whole("valid-full", frag(wtFull, small))
	whole("valid-split", frag(wtFirst, smallRecord(1, 2)), frag(wtLast, smallRecord(3, 4)))
	whole("valid-three-part",
		frag(wtFirst, smallRecord(1)), frag(wtMiddle, smallRecord(2)), frag(wtLast, smallRecord(3)))
	whole("valid-zero-length", frag(wtFull, ""))
	whole("valid-max-fragment", frag(wtFull, markedRecord(maxFrag, 0x11)))

	// ---- validateRecord's four arms. Upstream's own invalid orderings, reader_test.go:117-141. ----
	whole("middle-at-position-0", frag(wtMiddle, small))
	whole("last-at-position-0", frag(wtLast, small))
	whole("full-after-first", frag(wtFirst, small), frag(wtFull, small))
	whole("full-after-first-middle",
		frag(wtFirst, small), frag(wtMiddle, small), frag(wtFull, small))
	whole("first-after-first", frag(wtFirst, small), frag(wtFirst, small))
	// A `first` that is never completed: the stream ends cleanly after it, which is the torn-record path
	// rather than a grammar error — `Next` swallows the EOF and `curRecTyp` is what reports it.
	whole("torn-after-first", frag(wtFirst, small))
	whole("torn-after-middle", frag(wtFirst, small), frag(wtMiddle, small))

	// ---- The record type itself. `recTypeFromHeader` masks to three bits, so 5/6/7 are reachable. ----
	whole("invalid-type-5", frag(5, small))
	whole("invalid-type-6", frag(6, small))
	whole("invalid-type-7", frag(7, small))
	// The mask matters: type 1 with the snappy flag is 0b1001 = 9, which masks to `full`.
	//
	// **The three compression-flag cases are deliberately NOT here**, and the reason is worth stating rather
	// than leaving as an absence. Upstream does not merely *notice* the flag, it **decompresses**: the answers
	// are `snappy: corrupt input` for the snappy bit and `unexpected EOF` for the zstd one, because `small` is
	// not a valid frame in either codec. The port rejects the record by name instead
	// (`unsupported compression type: snappy`, exception 20), so a fixture case would pin a disagreement the
	// port is *declared* to have. They are asserted Swift-side in `WALCorruptTests` instead — the same
	// treatment `ReaderHasNoSegments` gets, for the same reason: pin what upstream and the port can agree on,
	// and assert the declared divergence where it can be read next to its exception.
	//
	// The high bit is not a flag and is masked away, so this one DOES agree and stays.
	whole("full-with-high-bit", frag(wtFull|0x80, small))

	// ---- The CRC. ----
	whole("bad-crc", walFrag{Type: wtFull, Payload: small, LenOverride: -1, CRCOverride: 0})
	whole("bad-crc-nonzero", walFrag{Type: wtFull, Payload: small, LenOverride: -1, CRCOverride: 0xDEADBEEF})
	// A zero-length record's CRC is the checksum of nothing, which is 0 — so a zero-length record with a
	// non-zero CRC is the only way to reach the check on an empty payload.
	whole("bad-crc-zero-length", walFrag{Type: wtFull, Payload: "", LenOverride: -1, CRCOverride: 1})
	// The CRC covers the FRAGMENT, not the record: a split record whose second fragment carries the CRC of
	// the whole thing must fail.
	whole("bad-crc-second-fragment",
		frag(wtFirst, smallRecord(1, 2)),
		walFrag{Type: wtLast, Payload: smallRecord(3, 4), LenOverride: -1, CRCOverride: 0})

	// ---- The length field. ----
	// Above `pageSize - recordHeaderSize`, which is upstream's bound and the reader's buffer size.
	whole("length-one-over-bound",
		walFrag{Type: wtFull, Payload: small, LenOverride: maxFrag + 1, CRCOverride: -1})
	whole("length-at-bound-short-payload",
		walFrag{Type: wtFull, Payload: small, LenOverride: maxFrag, CRCOverride: -1})
	whole("length-max-uint16",
		walFrag{Type: wtFull, Payload: small, LenOverride: 65535, CRCOverride: -1})
	// A length SHORTER than the payload: the reader takes `length` bytes and the rest is read as the next
	// header, so this is how a length field desynchronises the stream rather than erroring at the record.
	whole("length-shorter-than-payload",
		walFrag{Type: wtFull, Payload: markedRecord(64, 0x22), LenOverride: 8, CRCOverride: -1})

	// ---- The page terminator and its padding. ----
	// A terminator whose padding runs to the end of the page, which is the ordinary case.
	whole("page-term-clean",
		frag(wtFull, small), pageTerm(walPageSize-walRecordHeaderSize-len(unrleHex(small))-1))
	// Upstream's own non-zero-after-termination case, reader_test.go:143.
	whole("page-term-dirty",
		frag(wtFull, smallRecord(1)),
		walFrag{
			Type: 0, PageTerm: true, PadZeros: walPageSize - walRecordHeaderSize - 1 - 1,
			PadDirty: true, LenOverride: -1, CRCOverride: -1,
		})
	// A terminator sitting in the page's very last byte, where `k == pageSize` and there is nothing to
	// verify. This is the arm the round-trip corpus DOES reach, kept here as the contrast.
	whole("page-term-final-byte",
		frag(wtFull, markedRecord(maxFrag-1, 0x33)), pageTerm(0))
	// A record continuing across a page terminator, which is what makes `i` not advance on a terminator.
	whole("split-across-page-term",
		frag(wtFirst, smallRecord(1, 2)),
		pageTerm(walPageSize-walRecordHeaderSize-2-1),
		frag(wtLast, smallRecord(3, 4)))

	// ---- Truncation. A torn write leaves a partial header or a partial payload. ----
	// Inside the first header.
	cut("cut-mid-header", 3, frag(wtFull, small))
	cut("cut-after-type-byte", 1, frag(wtFull, small))
	cut("cut-before-payload", walRecordHeaderSize, frag(wtFull, small))
	// Inside the payload.
	cut("cut-mid-payload", walRecordHeaderSize+1, frag(wtFull, markedRecord(64, 0x44)))
	// After a complete record, which is clean.
	cut("cut-after-full-record", walRecordHeaderSize+3, frag(wtFull, small), frag(wtFull, small))
	// After a `first` fragment, which is torn.
	cut("cut-after-first-fragment",
		walRecordHeaderSize+2, frag(wtFirst, smallRecord(1, 2)), frag(wtLast, smallRecord(3, 4)))
	// A whole page of a two-page stream, so the truncation is page-ALIGNED and the padding emulation does
	// not fire — this is the one that can still reach a genuine end-of-stream mid-record.
	cut("cut-at-page-boundary", walPageSize,
		frag(wtFirst, markedRecord(maxFrag, 0x55)), frag(wtLast, smallRecord(9)))

	// ---- An empty segment file, and one byte of nothing. ----
	whole("empty-segment")
	cut("single-zero-byte", 1, pageTerm(16))
}
