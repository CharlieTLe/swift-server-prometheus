package main

// Differential coverage for `tsdb/chunks`' ChunkDiskMapper — the Head's chunk files.
//
// ## The shape, and why it reopens
//
// Each case is a program of writes against a fresh mapper, and then it **closes and reopens** the directory
// before iterating. That is not incidental: `IterateAllChunks`'s own doc comment says it "needs to be called
// at least once after creating ChunkDiskMapper", and the Head calls it exactly there — on a mapper that has
// just opened an existing directory. Calling it mid-write would read the *pre-allocated* region of an mmapped
// file, where the buffered bytes have not landed yet, so it would pin an unsupported usage. Reopening also
// buys the `openMMapFiles` path for free: the gap check, the header checks and `repairLastChunkFile`.
//
// So the committed output has two halves — what the writer produced (the files, byte for byte) and what a
// fresh reader makes of them (`IterateAllChunks`'s tuples, and `Chunk` at every ref).
//
// ## The chunk is a FAKE, on purpose
//
// `WriteChunk` takes a `chunkenc.Chunk` and only ever calls `Bytes()` and `Encoding()` on it, so the corpus
// passes a stub with explicit bytes. Two reasons that is better than a real XOR chunk here: it decouples this
// suite from the encoder (already pinned by `chunkenc/xor`), and it lets a case choose the first two bytes of
// the chunk data — which is what `IterateAllChunks` reads as `numSamples`, a field this format does not have
// (quirk 181). A real chunk would make that byte pair a consequence rather than an input.

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

// A `chunkenc.Chunk` that is just an encoding and some bytes. Only `Bytes()` and `Encoding()` are reached by
// the write path; the rest panic so that a caller reaching them is a loud failure rather than a silent zero.
type fakeChunk struct {
	enc   chunkenc.Encoding
	bytes []byte
}

func (f fakeChunk) Bytes() []byte                { return f.bytes }
func (f fakeChunk) Encoding() chunkenc.Encoding  { return f.enc }
func (fakeChunk) Appender() (chunkenc.Appender, error) { panic("fakeChunk.Appender") }
func (fakeChunk) Iterator(chunkenc.Iterator) chunkenc.Iterator {
	panic("fakeChunk.Iterator")
}
func (fakeChunk) NumSamples() int  { panic("fakeChunk.NumSamples") }
func (fakeChunk) Compact()         { panic("fakeChunk.Compact") }
func (fakeChunk) Reset([]byte)     { panic("fakeChunk.Reset") }

type hcOp struct {
	// writeChunk | cutNewFile | truncate
	Op string `json:"op"`
	// For `writeChunk`.
	SeriesRef uint64 `json:"seriesRef,omitempty"`
	Mint      int64  `json:"mint,omitempty"`
	Maxt      int64  `json:"maxt,omitempty"`
	Encoding  uint8  `json:"encoding,omitempty"`
	// rle-hex, reusing the wal suite's codec.
	Data  string `json:"data,omitempty"`
	IsOOO bool   `json:"isOOO,omitempty"`
	// For `truncate`.
	FileNo uint32 `json:"fileNo,omitempty"`
}

// A file planted in the chunk directory BEFORE the mapper is constructed, so `openMMapFiles`,
// `repairLastChunkFile` and the header checks see something they did not write.
type hcSeedFile struct {
	Name  string `json:"name"`
	Bytes string `json:"bytes"`
}

type hcIn struct {
	// Must be >= 64KiB and a multiple of 1024, so the corpus uses the minimum to keep the
	// bigger-than-the-buffer cases small enough to commit.
	WriteBufferSize int    `json:"writeBufferSize"`
	Ops             []hcOp `json:"ops"`
	// Planted before construction. Omitted from the cases that do not use it.
	PreSeed []hcSeedFile `json:"preSeed,omitempty"`
	// Read every ref on the FIRST mapper, before Close. That is ordinary usage upstream and it is the only
	// way to reach the `chunkBuffer` — a reopened mapper's buffer is empty, so a corpus that only reads after
	// reopening cannot see the buffer, the flush decisions, or which of the two serves a chunk.
	ReadBeforeClose bool `json:"readBeforeClose,omitempty"`
	// Extra refs to read, on top of the ones the writer returned. Arbitrary values, so the bounds checks and
	// the CRC verification in `Chunk` are reachable at all — every ref a writer hands back is valid by
	// construction, which is the same blindness `wal/segments` had before `wal/corrupt`.
	ExtraReadRefs []uint64 `json:"extraReadRefs,omitempty"`
}

type hcFileOut struct {
	Name  string `json:"name"`
	Size  int    `json:"size"`
	Bytes string `json:"bytes"`
}

// One `IterateAllChunks` callback invocation.
type hcIterOut struct {
	SeriesRef  uint64 `json:"seriesRef"`
	ChunkRef   uint64 `json:"chunkRef"`
	Mint       int64  `json:"mint"`
	Maxt       int64  `json:"maxt"`
	NumSamples uint16 `json:"numSamples"`
	Encoding   uint8  `json:"encoding"`
	IsOOO      bool   `json:"isOOO"`
}

// One `Chunk(ref)` read.
type hcReadOut struct {
	Ref      uint64 `json:"ref"`
	Encoding uint8  `json:"encoding"`
	Bytes    string `json:"bytes"`
	Err      string `json:"err"`
}

type hcOut struct {
	// The refs `WriteChunk` handed back, in order.
	Refs []uint64 `json:"refs"`
	// The error the callback received, per write, empty when nil.
	WriteErrs []string `json:"writeErrs"`
	OpErr     string   `json:"opErr"`
	// After Close.
	Files []hcFileOut `json:"files"`
	Size  int64       `json:"size"`
	// Reads on the FIRST mapper, before Close — empty unless `ReadBeforeClose`.
	LiveReads []hcReadOut `json:"liveReads"`
	// After the REOPEN.
	ReopenErr string      `json:"reopenErr"`
	Iter      []hcIterOut `json:"iter"`
	IterErr   string      `json:"iterErr"`
	Reads     []hcReadOut `json:"reads"`
}

func genHeadChunks(e *emitter) {
	n := 0
	emit := func(name string, in hcIn) {
		dir, err := os.MkdirTemp("", "promoracle-hc")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		chunkDir := filepath.Join(dir, "chunks_head")

		out := hcOut{
			Refs: []uint64{}, WriteErrs: []string{}, Files: []hcFileOut{},
			Iter: []hcIterOut{}, Reads: []hcReadOut{}, LiveReads: []hcReadOut{},
		}

		if err := os.MkdirAll(chunkDir, 0o777); err != nil {
			panic(err)
		}
		for _, sf := range in.PreSeed {
			if err := os.WriteFile(filepath.Join(chunkDir, sf.Name), unrleHex(sf.Bytes), 0o666); err != nil {
				panic(err)
			}
		}

		cdm, err := chunks.NewChunkDiskMapper(nil, chunkDir, chunkenc.NewPool(), in.WriteBufferSize, 0)
		if err != nil {
			out.OpErr = scrubDir(err.Error(), dir)
			e.emit(fmt.Sprintf("hc/%03d/%s", n, name), in, out)
			n++
			return
		}

		for _, op := range in.Ops {
			switch op.Op {
			case "writeChunk":
				chk := fakeChunk{enc: chunkenc.Encoding(op.Encoding), bytes: unrleHex(op.Data)}
				var cbErr string
				ref := cdm.WriteChunk(
					chunks.HeadSeriesRef(op.SeriesRef), op.Mint, op.Maxt, chk, op.IsOOO,
					func(err error) {
						if err != nil {
							cbErr = scrubDir(err.Error(), dir)
						}
					})
				out.Refs = append(out.Refs, uint64(ref))
				out.WriteErrs = append(out.WriteErrs, cbErr)
			case "cutNewFile":
				cdm.CutNewFile()
			case "truncate":
				if err := cdm.Truncate(op.FileNo); err != nil && out.OpErr == "" {
					out.OpErr = scrubDir(err.Error(), dir)
				}
			default:
				panic("unknown head chunk op " + op.Op)
			}
		}

		if in.ReadBeforeClose {
			for _, r := range append(append([]uint64{}, out.Refs...), in.ExtraReadRefs...) {
				out.LiveReads = append(out.LiveReads, hcRead(cdm, r, dir))
			}
		}

		if sz, err := cdm.Size(); err == nil {
			out.Size = sz
		}
		if err := cdm.Close(); err != nil && out.OpErr == "" {
			out.OpErr = scrubDir(err.Error(), dir)
		}

		out.Files = readHeadChunkDir(chunkDir)

		// The REOPEN, which is how the Head uses this: open, iterate to set every file's maxt, then read.
		cdm2, err := chunks.NewChunkDiskMapper(nil, chunkDir, chunkenc.NewPool(), in.WriteBufferSize, 0)
		if err != nil {
			out.ReopenErr = scrubDir(err.Error(), dir)
			e.emit(fmt.Sprintf("hc/%03d/%s", n, name), in, out)
			n++
			return
		}
		iterErr := cdm2.IterateAllChunks(func(
			seriesRef chunks.HeadSeriesRef, chunkRef chunks.ChunkDiskMapperRef,
			mint, maxt int64, numSamples uint16, encoding chunkenc.Encoding, isOOO bool,
		) error {
			out.Iter = append(out.Iter, hcIterOut{
				SeriesRef: uint64(seriesRef), ChunkRef: uint64(chunkRef), Mint: mint, Maxt: maxt,
				NumSamples: numSamples, Encoding: uint8(encoding), IsOOO: isOOO,
			})
			return nil
		})
		if iterErr != nil {
			out.IterErr = scrubDir(iterErr.Error(), dir)
		}

		// Every ref the writer returned, plus the deliberately invalid ones, through the reopened mapper.
		for _, r := range append(append([]uint64{}, out.Refs...), in.ExtraReadRefs...) {
			out.Reads = append(out.Reads, hcRead(cdm2, r, dir))
		}
		cdm2.Close()

		e.emit(fmt.Sprintf("hc/%03d/%s", n, name), in, out)
		n++
	}

	genHeadChunkCases(emit)
}

func hcRead(cdm *chunks.ChunkDiskMapper, r uint64, dir string) hcReadOut {
	ro := hcReadOut{Ref: r}
	chk, err := cdm.Chunk(chunks.ChunkDiskMapperRef(r))
	if err != nil {
		ro.Err = scrubDir(err.Error(), dir)
		return ro
	}
	ro.Encoding = uint8(chk.Encoding())
	ro.Bytes = rleHex(chk.Bytes())
	return ro
}

// The temp directory differs every run and `CorruptionErr` embeds it, so it has to go or the fixture is not
// reproducible (PORTING.md on corpus reproducibility).
//
// The parent is stripped ENTIRELY rather than replaced with a placeholder, which leaves the message relative —
// `chunks_head/000001`. That is what the port can produce: its `PromFS` is rooted, so its directory really is
// `chunks_head` with no prefix to scrub. Replacing the parent with `<dir>` instead would pin an absolute path
// the port cannot spell, which is how the first run of this suite failed.
func scrubDir(s, dir string) string {
	return strings.ReplaceAll(s, dir+string(filepath.Separator), "")
}

func readHeadChunkDir(dir string) []hcFileOut {
	out := []hcFileOut{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	names := []string{}
	for _, en := range entries {
		names = append(names, en.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		out = append(out, hcFileOut{Name: name, Size: len(b), Bytes: rleHex(b)})
	}
	return out
}

// A chunk body whose first two bytes are a chosen BE16 — which is what `IterateAllChunks` reports as
// `numSamples` (quirk 181) — followed by markers so a misplaced boundary moves something visible.
func chunkData(numSamples uint16, extra int, tag byte) string {
	b := make([]byte, 2+extra)
	b[0] = byte(numSamples >> 8)
	b[1] = byte(numSamples)
	for k := 0; k < extra; k++ {
		b[2+k] = tag + byte(k%13)
	}
	return rleHex(b)
}

func genHeadChunkCases(emit func(string, hcIn)) {
	const buf = 64 * 1024 // MinWriteBufferSize, so the over-the-buffer cases stay committable.

	write := func(seriesRef uint64, mint, maxt int64, enc uint8, data string) hcOp {
		return hcOp{
			Op: "writeChunk", SeriesRef: seriesRef, Mint: mint, Maxt: maxt,
			Encoding: enc, Data: data,
		}
	}
	prog := func(ops ...hcOp) hcIn { return hcIn{WriteBufferSize: buf, Ops: ops} }

	xor := uint8(chunkenc.EncXOR)

	// The buffer-size validation, which happens before the directory is touched.
	emit("buffer-too-small", hcIn{WriteBufferSize: 1024, Ops: nil})
	emit("buffer-too-big", hcIn{WriteBufferSize: 16 * 1024 * 1024, Ops: nil})
	emit("buffer-not-multiple-of-1024", hcIn{WriteBufferSize: 64*1024 + 1, Ops: nil})

	// Nothing written: no file is cut until the first chunk, so the directory is EMPTY and the reopen has
	// nothing to iterate.
	emit("no-writes", prog())

	// One chunk. `offset == 0` makes this the first file, so `toNewFile` takes seq to 1 — file `000001`,
	// never `000000`.
	emit("one-chunk", prog(write(1, 100, 200, xor, chunkData(3, 10, 0x40))))
	// A zero-length chunk body is representable: the uvarint length is 0 and the CRC covers the header only.
	emit("empty-chunk-data", prog(write(1, 0, 0, xor, "")))
	// mint/maxt that are negative and extreme, because they travel as BE64 of a signed value.
	emit("negative-timestamps", prog(write(7, -5000, -1, xor, chunkData(1, 4, 0x50))))
	emit("extreme-timestamps", prog(
		write(9, -9223372036854775808, 9223372036854775807, xor, chunkData(2, 4, 0x51))))

	// Several chunks in one file, so `chunkPos` accumulates and the refs are not guessable from the first.
	emit("three-chunks", prog(
		write(1, 100, 200, xor, chunkData(5, 20, 0x60)),
		write(2, 150, 250, xor, chunkData(6, 30, 0x70)),
		write(3, 200, 300, xor, chunkData(7, 40, 0x80)),
	))

	// The OOO mask: written into the encoding byte, and `IterateAllChunks` has to split it back out.
	emit("ooo-chunk", hcIn{WriteBufferSize: buf, Ops: []hcOp{
		{Op: "writeChunk", SeriesRef: 4, Mint: 10, Maxt: 20, Encoding: xor,
			Data: chunkData(2, 8, 0x90), IsOOO: true},
	}})
	emit("ooo-and-in-order", hcIn{WriteBufferSize: buf, Ops: []hcOp{
		write(1, 10, 20, xor, chunkData(2, 8, 0x91)),
		{Op: "writeChunk", SeriesRef: 2, Mint: 30, Maxt: 40, Encoding: xor,
			Data: chunkData(3, 8, 0x92), IsOOO: true},
		write(3, 50, 60, xor, chunkData(4, 8, 0x93)),
	}})

	// `CutNewFile` only takes effect on the NEXT chunk, so cutting twice in a row does not make two files
	// and cutting with nothing after it makes none.
	emit("cut-then-write", prog(
		write(1, 10, 20, xor, chunkData(2, 8, 0xa0)),
		hcOp{Op: "cutNewFile"},
		write(2, 30, 40, xor, chunkData(3, 8, 0xa1)),
	))
	emit("cut-with-no-write-after", prog(
		write(1, 10, 20, xor, chunkData(2, 8, 0xa2)),
		hcOp{Op: "cutNewFile"},
	))
	emit("cut-twice", prog(
		write(1, 10, 20, xor, chunkData(2, 8, 0xa3)),
		hcOp{Op: "cutNewFile"},
		hcOp{Op: "cutNewFile"},
		write(2, 30, 40, xor, chunkData(3, 8, 0xa4)),
	))
	emit("cut-before-any-write", prog(
		hcOp{Op: "cutNewFile"},
		write(1, 10, 20, xor, chunkData(2, 8, 0xa5)),
	))

	// A chunk at least as big as the write buffer takes the flush-AFTER path and skips the flush-before, which
	// is the pair of conditions in `writeChunk`. One under, one over.
	emit("chunk-just-under-buffer", prog(
		write(1, 10, 20, xor, chunkData(9, buf-chunks.MaxHeadChunkMetaSize-3, 0xb0))))
	emit("chunk-at-buffer", prog(
		write(1, 10, 20, xor, chunkData(9, buf-chunks.MaxHeadChunkMetaSize-2, 0xb1))))
	emit("chunk-over-buffer", prog(
		write(1, 10, 20, xor, chunkData(9, buf+100, 0xb2))))
	// Two chunks that together exceed the buffer, so the second triggers the flush-before path.
	emit("two-chunks-crossing-buffer", prog(
		write(1, 10, 20, xor, chunkData(4, buf/2, 0xc0)),
		write(2, 30, 40, xor, chunkData(5, buf/2, 0xc1)),
	))

	// An encoding the pool does not know: the write succeeds (the mapper does not validate it) and the READ
	// fails, which is the only way to reach `pool.Get`'s error arm.
	emit("unknown-encoding", prog(write(1, 10, 20, 99, chunkData(2, 8, 0xd0))))

	// Truncate: below, at and above the files that exist, plus one that removes everything.
	rotated := []hcOp{
		write(1, 10, 20, xor, chunkData(2, 8, 0xe0)),
		{Op: "cutNewFile"},
		write(2, 30, 40, xor, chunkData(3, 8, 0xe1)),
		{Op: "cutNewFile"},
		write(3, 50, 60, xor, chunkData(4, 8, 0xe2)),
	}
	for _, fileNo := range []uint32{0, 1, 2, 3, 5} {
		ops := append([]hcOp{}, rotated...)
		ops = append(ops, hcOp{Op: "truncate", FileNo: fileNo})
		emit(fmt.Sprintf("truncate-%d", fileNo), hcIn{WriteBufferSize: buf, Ops: ops})
	}
	// Truncate on an idle mapper: `curFileSize() > HeadChunkFileHeaderSize` is false right after a cut, so no
	// new file is created.
	emit("truncate-after-cut", prog(
		write(1, 10, 20, xor, chunkData(2, 8, 0xf0)),
		hcOp{Op: "cutNewFile"},
		hcOp{Op: "truncate", FileNo: 1},
	))
	// Truncate with nothing written at all.
	emit("truncate-empty", prog(hcOp{Op: "truncate", FileNo: 1}))

	// ---- Reads on the LIVE mapper, which is the only way to reach the `chunkBuffer`. ----
	live := func(ops ...hcOp) hcIn {
		return hcIn{WriteBufferSize: buf, Ops: ops, ReadBeforeClose: true}
	}
	// Unflushed: both chunks are still in the buffer, so `Chunk` serves them from memory.
	emit("live-read-buffered", live(
		write(1, 10, 20, xor, chunkData(2, 8, 0x20)),
		write(2, 30, 40, xor, chunkData(3, 8, 0x21)),
	))
	// A chunk bigger than the buffer flushes itself, so the buffer is CLEARED and the read comes off the
	// file — the two halves of `flushBuffer` in one case.
	emit("live-read-after-forced-flush", live(
		write(1, 10, 20, xor, chunkData(4, buf+50, 0x22)),
		write(2, 30, 40, xor, chunkData(5, 8, 0x23)),
	))
	// A cut mid-program: the first file's chunk is no longer in the buffer, the second file's is.
	emit("live-read-across-a-cut", live(
		write(1, 10, 20, xor, chunkData(2, 8, 0x24)),
		hcOp{Op: "cutNewFile"},
		write(2, 30, 40, xor, chunkData(3, 8, 0x25)),
	))

	// ---- Invalid refs, so `Chunk`'s bounds checks and its CRC verification are reachable at all. ----
	// Every ref a writer returns is valid by construction; this is the same blindness `wal/segments` had.
	bogus := func(refs []uint64, ops ...hcOp) hcIn {
		return hcIn{WriteBufferSize: buf, Ops: ops, ExtraReadRefs: refs}
	}
	one := []hcOp{write(1, 10, 20, xor, chunkData(3, 40, 0x30))}
	// seq 1 with an offset deep inside the pre-allocated zeros: the length field reads 0 and the CRC fails.
	emit("read-ref-into-padding", bogus([]uint64{(1 << 32) | 5000}, one...))
	// An offset a few bytes off the real chunk, so the length field is misaligned.
	emit("read-ref-misaligned", bogus([]uint64{(1 << 32) | 9, (1 << 32) | 12}, one...))
	// An offset past the end of the file entirely.
	emit("read-ref-past-file-end", bogus([]uint64{(1 << 32) | 200000}, one...))
	// A file that does not exist, below and above the current sequence.
	emit("read-ref-missing-file", bogus([]uint64{(9 << 32) | 8}, one...))
	// Offset 0, which lands on the segment header rather than a chunk.
	emit("read-ref-at-header", bogus([]uint64{1 << 32}, one...))

	// A chunk whose SERIES REF is 0 but whose timestamps are not — which separates the real end-of-content
	// marker (all three zero) from a test of the series ref alone.
	emit("series-ref-zero-nonzero-timestamps", prog(
		write(0, 500, 600, xor, chunkData(2, 8, 0x40)),
		write(1, 700, 800, xor, chunkData(3, 8, 0x41)),
	))

	// A write AFTER a truncate, so the new file `Truncate` asked for actually gets created.
	emit("truncate-then-write", prog(
		write(1, 10, 20, xor, chunkData(2, 8, 0x50)),
		hcOp{Op: "cutNewFile"},
		write(2, 30, 40, xor, chunkData(3, 8, 0x51)),
		hcOp{Op: "truncate", FileNo: 2},
		write(3, 50, 60, xor, chunkData(4, 8, 0x52)),
	))

	// ---- A pre-seeded directory: `openMMapFiles`, `repairLastChunkFile` and the header checks. ----
	seeded := func(seed []hcSeedFile, ops ...hcOp) hcIn {
		return hcIn{WriteBufferSize: buf, Ops: ops, PreSeed: seed}
	}
	goodHeader := rleHex([]byte{0x01, 0x30, 0xbc, 0x91, 0x01, 0, 0, 0})
	// A well-formed empty file, which the mapper adopts and numbers past.
	emit("seeded-one-good-file", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: goodHeader}},
		write(1, 10, 20, xor, chunkData(2, 8, 0x60))))
	// A ZERO-length last file is repaired away — that is what `repairLastChunkFile` is for.
	emit("seeded-empty-last-file", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: goodHeader}, {Name: "000002", Bytes: ""}},
		write(1, 10, 20, xor, chunkData(2, 8, 0x61))))
	// A last file whose magic is ZERO is also repaired away.
	emit("seeded-zero-magic-last-file", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: goodHeader}, {Name: "000002", Bytes: rleHex(make([]byte, 8))}},
		write(1, 10, 20, xor, chunkData(2, 8, 0x62))))
	// A last file with the WRONG magic is NOT repaired — it has to travel up so the Head can react.
	emit("seeded-wrong-magic-last-file", seeded(
		[]hcSeedFile{
			{Name: "000001", Bytes: goodHeader},
			{Name: "000002", Bytes: rleHex([]byte{0xde, 0xad, 0xbe, 0xef, 0x01, 0, 0, 0})},
		}))
	// File 000001 alone with the wrong magic: `lastFile <= 0` does not apply, so repair inspects it and the
	// magic is non-zero, so it survives to fail the header check.
	emit("seeded-wrong-magic-only-file", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: rleHex([]byte{0xde, 0xad, 0xbe, 0xef, 0x01, 0, 0, 0})}}))
	// A wrong format VERSION.
	emit("seeded-wrong-version", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: rleHex([]byte{0x01, 0x30, 0xbc, 0x91, 0x09, 0, 0, 0})}}))
	// A file too SHORT to hold a header at all, and not last, so repair leaves it.
	emit("seeded-short-header", seeded(
		[]hcSeedFile{
			{Name: "000001", Bytes: rleHex([]byte{0x01, 0x30, 0xbc})},
			{Name: "000002", Bytes: goodHeader},
		}))
	// A GAP in the indices.
	emit("seeded-gap", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: goodHeader}, {Name: "000003", Bytes: goodHeader}}))
	// A non-numeric name is SKIPPED, not an error — which is how a `checkpoint.NNNNNN` sits alongside.
	emit("seeded-non-numeric-name", seeded(
		[]hcSeedFile{{Name: "000001", Bytes: goodHeader}, {Name: "checkpoint.000123", Bytes: ""}},
		write(1, 10, 20, xor, chunkData(2, 8, 0x63))))
	// File 000000: `lastFile <= 0` returns early, so file 0 is NOT repaired even though it is the last one.
	// It is planted SHORT-but-non-empty rather than empty on purpose: `fileutil.OpenMmapFile` fails on a
	// zero-length file with `mmap, size 0: invalid argument` *before* the header check runs, and that error is
	// mmap's, which ADR-15 declines. Pinning it would pin an OS error string the port cannot spell — see
	// exception 22 and the Swift-side assertion. Three bytes reaches the same header check on both sides.
	emit("seeded-file-zero-short", seeded(
		[]hcSeedFile{{Name: "000000", Bytes: rleHex([]byte{0x01, 0x30, 0xbc})}}))

	// Many chunks, so several files' worth of `chunkPos` arithmetic runs and the reopen sees a sequence.
	var many []hcOp
	for i := 0; i < 40; i++ {
		many = append(many, write(uint64(i+1), int64(i*10), int64(i*10+5), xor,
			chunkData(uint16(i), 20+i, byte(0x10+i%16))))
		if i%9 == 8 {
			many = append(many, hcOp{Op: "cutNewFile"})
		}
	}
	emit("many-chunks-many-files", hcIn{WriteBufferSize: buf, Ops: many})
}
