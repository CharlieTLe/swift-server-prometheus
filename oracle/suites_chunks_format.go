package main

// Differential coverage for tsdb/chunks/chunks.go's PURE half: the two reference layouts, the per-chunk
// framing, the checksum, and `WriteChunks`' segment-batching arithmetic.
//
// The file/segment I/O is not ported (it needs a filesystem abstraction, which is an ADR not a
// transcription), so this pins what does not touch a disk. Everything here is exported except the
// batching, which is reached by calling `WriteChunks` against a real temporary directory and reading back
// which segment each chunk landed in — the batching's whole observable effect.
//
// What has to be reached:
//   - `NewHeadChunkRef`'s 40/24 split, both PANIC bounds, and round-tripping through `Unpack`;
//   - `NewBlockChunkRef`'s 32/32 split, which has NO bounds check, so an overlarge index bleeds;
//   - the framed bytes: uvarint length, encoding byte, data, big-endian CRC32-C — and that the CRC
//     covers the encoding and data but NOT the length prefix;
//   - `checkCRC32`'s hand-rolled big-endian reassembly and its error text;
//   - the batching, including the `firstBatch` clause that tops up a partially written segment, and the
//     worst-case length-field sizing that cuts a segment slightly early.

import (
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"
	"sort"

	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

type headRefIn struct {
	SeriesRef uint64 `json:"seriesRef"`
	ChunkID   uint64 `json:"chunkID"`
}

type headRefOut struct {
	Ref       uint64 `json:"ref"`
	SeriesRef uint64 `json:"seriesRef"`
	ChunkID   uint64 `json:"chunkID"`
	Panic     string `json:"panic"`
}

type blockRefIn struct {
	FileIndex  uint64 `json:"fileIndex"`
	FileOffset uint64 `json:"fileOffset"`
}

type blockRefOut struct {
	Ref        uint64 `json:"ref"`
	SegIndex   int    `json:"segIndex"`
	ChunkStart int    `json:"chunkStart"`
}

type framingIn struct {
	// Sample values appended to an XOR chunk, so the data is a real encoding rather than random bytes.
	//
	// HEX BIT PATTERNS, not floats: `encoding/json` cannot represent NaN and panics on it, and the same
	// trap bit the submatch corpus (where it silently replaced an invalid byte instead). A wire that
	// cannot carry the values under test is not a wire.
	Values []string `json:"values"`
	// A deliberately corrupted CRC, to reach checkCRC32's error path. Hex, 4 bytes, or empty.
	BadSum string `json:"badSum"`
}

type framingOut struct {
	DataHex   string `json:"dataHex"`
	FramedHex string `json:"framedHex"`
	HashInput string `json:"hashInputHex"`
	CRC       uint32 `json:"crc"`
	CheckErr  string `json:"checkErr"`
}

type batchIn struct {
	Sizes       []int `json:"sizes"`
	SegmentSize int64 `json:"segmentSize"`
}

type batchOut struct {
	// Per chunk, the segment index its ref decodes to — the batching's observable effect.
	SegmentOf []int `json:"segmentOf"`
	OffsetOf  []int `json:"offsetOf"`
	Err       string `json:"err"`
	// Every segment file the writer left behind: its name and its full contents, hex. This is what makes
	// the WRITER pinnable rather than just its arithmetic — the port writes to an in-memory filesystem and
	// the byte strings are compared.
	SegmentNames []string `json:"segmentNames"`
	SegmentHex   []string `json:"segmentHex"`
}

// Four generators, one fixture file each: `Fixtures.check` decodes every line of a file with one
// `In`/`Out` pair, so mixing shapes in one file would need an id filter in shared test infrastructure.
// Four files is the cheaper seam and matches the rest of the corpus.
func genChunksHeadRef(e *emitter) {
	n := 0
	emitHead := func(seriesRef, chunkID uint64) {
		in := headRefIn{SeriesRef: seriesRef, ChunkID: chunkID}
		out := headRefOut{}
		func() {
			defer func() {
				if r := recover(); r != nil {
					out.Panic = fmt.Sprint(r)
				}
			}()
			ref := chunks.NewHeadChunkRef(chunks.HeadSeriesRef(seriesRef), chunks.HeadChunkID(chunkID))
			out.Ref = uint64(ref)
			sr, cid := ref.Unpack()
			out.SeriesRef = uint64(sr)
			out.ChunkID = uint64(cid)
		}()
		e.emit(fmt.Sprintf("headref/%d", n), in, out)
		n++
	}
	for _, p := range [][2]uint64{
		{0, 0}, {1, 0}, {0, 1}, {1, 1}, {7, 12}, {123456, 789},
		{(1 << 40) - 1, (1 << 24) - 1}, // both at the maximum
		{(1 << 40) - 1, 0}, {0, (1 << 24) - 1},
		{1 << 40, 0},         // series ref one over: panics
		{0, 1 << 24},         // chunk ID one over: panics
		{math.MaxUint64, 0},  // far over
		{0, math.MaxUint64},  // far over
		{1 << 39, 1 << 23},
	} {
		emitHead(p[0], p[1])
	}

}

func genChunksBlockRef(e *emitter) {
	n := 0
	emitBlock := func(fileIndex, fileOffset uint64) {
		in := blockRefIn{FileIndex: fileIndex, FileOffset: fileOffset}
		ref := chunks.NewBlockChunkRef(fileIndex, fileOffset)
		si, cs := ref.Unpack()
		e.emit(fmt.Sprintf("blockref/%d", n), in,
			blockRefOut{Ref: uint64(ref), SegIndex: si, ChunkStart: cs})
		n++
	}
	for _, p := range [][2]uint64{
		{0, 0}, {1, 0}, {0, 1}, {1, 1}, {5, 4096}, {0, math.MaxUint32},
		{math.MaxUint32, 0}, {math.MaxUint32, math.MaxUint32},
		{1 << 32, 0},        // no bounds check: bleeds into nothing (shifts out)
		{1, math.MaxUint32}, // adjacent fields both full
		{1 << 33, 7},
	} {
		emitBlock(p[0], p[1])
	}

}

func genChunksFraming(e *emitter) {
	n := 0
	emitFraming := func(raw []float64, badSum string) {
		values := make([]string, 0, len(raw))
		for _, v := range raw {
			values = append(values, fbits(v))
		}
		in := framingIn{Values: values, BadSum: badSum}
		out := framingOut{}

		c := chunkenc.NewXORChunk()
		app, err := c.Appender()
		if err != nil {
			out.CheckErr = err.Error()
			e.emit(fmt.Sprintf("framing/%d", n), in, out)
			n++
			return
		}
		for i, v := range raw {
			app.Append(0, int64(i)*15000, v)
		}
		data := c.Bytes()
		out.DataHex = hex.EncodeToString(data)

		// `writeHash` feeds the encoding byte and the data — not the length prefix.
		hashInput := append([]byte{byte(c.Encoding())}, data...)
		out.HashInput = hex.EncodeToString(hashInput)
		table := crc32.MakeTable(crc32.Castagnoli)
		sum := crc32.Checksum(hashInput, table)
		out.CRC = sum

		framed := []byte{}
		var lenBuf [binary_MaxVarintLen32]byte
		ln := putUvarintInto(lenBuf[:], uint64(len(data)))
		framed = append(framed, lenBuf[:ln]...)
		framed = append(framed, byte(c.Encoding()))
		framed = append(framed, data...)
		framed = append(framed, byte(sum>>24), byte(sum>>16), byte(sum>>8), byte(sum))
		out.FramedHex = hex.EncodeToString(framed)

		// The check path, against either the real sum or a corrupted one.
		checkAgainst := []byte{byte(sum >> 24), byte(sum >> 16), byte(sum >> 8), byte(sum)}
		if badSum != "" {
			b, _ := hex.DecodeString(badSum)
			checkAgainst = b
		}
		if err := checkCRC32Mirror(hashInput, checkAgainst, table); err != nil {
			out.CheckErr = err.Error()
		}

		e.emit(fmt.Sprintf("framing/%d", n), in, out)
		n++
	}
	emitFraming(nil, "")
	emitFraming([]float64{1}, "")
	emitFraming([]float64{1, 2, 3}, "")
	emitFraming([]float64{0, 0, 0, 0, 0}, "")
	emitFraming([]float64{1e300, -1e300, math.NaN()}, "")
	{
		var vs []float64
		for i := range 300 {
			vs = append(vs, math.Sin(float64(i))*float64(i))
		}
		emitFraming(vs, "")
	}
	// Corrupted sums, to reach the error text and its %x formatting.
	emitFraming([]float64{1, 2, 3}, "00000000")
	emitFraming([]float64{1, 2, 3}, "ffffffff")
	emitFraming([]float64{1, 2, 3}, "0000000f")

}

func genChunksBatch(e *emitter) {
	n := 0
	emitBatch := func(sizes []int, segmentSize int64) {
		in := batchIn{Sizes: sizes, SegmentSize: segmentSize}
		out := batchOut{
			SegmentOf: []int{}, OffsetOf: []int{}, SegmentNames: []string{}, SegmentHex: []string{},
		}

		dir, err := os.MkdirTemp("", "chunks")
		if err != nil {
			out.Err = err.Error()
			e.emit(fmt.Sprintf("batch/%d", n), in, out)
			n++
			return
		}
		defer os.RemoveAll(dir)

		w, err := chunks.NewWriter(dir, chunks.WithSegmentSize(segmentSize))
		if err != nil {
			out.Err = err.Error()
			e.emit(fmt.Sprintf("batch/%d", n), in, out)
			n++
			return
		}
		metas := make([]chunks.Meta, 0, len(sizes))
		for _, sz := range sizes {
			c := chunkenc.NewXORChunk()
			app, _ := c.Appender()
			// Append until the encoded chunk is at least `sz` bytes, so the test controls the size.
			for i := 0; len(c.Bytes()) < sz; i++ {
				app.Append(0, int64(i)*15000, float64(i)*1.7)
				if i > 100000 {
					break
				}
			}
			metas = append(metas, chunks.Meta{Chunk: c, MinTime: 0, MaxTime: 1})
		}
		if err := w.WriteChunks(metas...); err != nil {
			out.Err = err.Error()
		}
		_ = w.Close()

		// Every file the writer left, in name order. `.tmp` files should not survive a successful close.
		entries, _ := os.ReadDir(dir)
		names := []string{}
		for _, en := range entries {
			names = append(names, en.Name())
		}
		sort.Strings(names)
		for _, nm := range names {
			b, rerr := os.ReadFile(filepath.Join(dir, nm))
			if rerr != nil {
				out.Err = rerr.Error()
				continue
			}
			out.SegmentNames = append(out.SegmentNames, nm)
			out.SegmentHex = append(out.SegmentHex, hex.EncodeToString(b))
		}

		for _, m := range metas {
			si, cs := chunks.BlockChunkRef(m.Ref).Unpack()
			out.SegmentOf = append(out.SegmentOf, si)
			out.OffsetOf = append(out.OffsetOf, cs)
		}
		e.emit(fmt.Sprintf("batch/%d", n), in, out)
		n++
	}
	// Small segments so boundaries are hit often, and sizes straddling them.
	emitBatch([]int{100}, 1024)
	emitBatch([]int{100, 100}, 1024)
	emitBatch([]int{500, 500}, 1024)
	emitBatch([]int{500, 500, 500}, 1024)
	emitBatch([]int{1000}, 1024)
	emitBatch([]int{200, 200, 200, 200, 200, 200}, 1024)
	emitBatch([]int{100, 900, 100}, 1024)
	emitBatch([]int{900, 100, 900}, 1024)
	emitBatch([]int{50, 50, 50, 50}, 256)
	emitBatch([]int{100, 100, 100, 100, 100, 100, 100, 100}, 512)
	emitBatch([]int{2000, 2000}, 1024) // each larger than a segment
	emitBatch([]int{10, 10, 10}, 64)   // segment barely larger than the header
}

const binary_MaxVarintLen32 = 5

func putUvarintInto(buf []byte, x uint64) int {
	i := 0
	for x >= 0x80 {
		buf[i] = byte(x) | 0x80
		x >>= 7
		i++
	}
	buf[i] = byte(x)
	return i + 1
}

// checkCRC32Mirror reproduces the unexported `checkCRC32`, whose error text is part of the contract.
func checkCRC32Mirror(data, sum []byte, table *crc32.Table) error {
	got := crc32.Checksum(data, table)
	want := uint32(sum[0])<<24 + uint32(sum[1])<<16 + uint32(sum[2])<<8 + uint32(sum[3])
	if got != want {
		return fmt.Errorf("checksum mismatch expected:%x, actual:%x", want, got)
	}
	return nil
}
