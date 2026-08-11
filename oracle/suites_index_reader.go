package main

// Differential coverage for tsdb/index's HEADER, TABLE OF CONTENTS and SYMBOL TABLE.
//
// **The seam is the interesting part.** `index.Writer` is file-based (ADR-15's subject) and the port has
// no writer, so the oracle writes a REAL index file with Go's own writer, emits its bytes as hex, and the
// port parses them. The port is therefore pinned against upstream's serialiser without owning one — the
// same trick §6e used for the chunk-segment batching, generalised to a whole file format.
//
// `NewReader`, `NewTOCFromByteSlice` and `NewSymbols` all take a `ByteSlice`, so the reading side needs no
// filesystem at all.
//
// What has to be reached:
//   - the TOC's six offsets and its own CRC, plus a truncated file (invalid size) and a corrupted TOC CRC;
//   - the symbol table's sparse index at `symbolFactor` = 32, which means >32 symbols to have more than
//     one offset, and >1024 to have more than 32;
//   - `Lookup` at, just before, and just after a sparse boundary;
//   - `ReverseLookup` for a symbol ON a boundary — the `if i > 0 { i-- }` case — for the first and last
//     symbols, and for one that is absent;
//   - symbols whose ordering differs between Go's byte comparison and Unicode collation (ADR-10), because
//     the table is sorted by the former and searched by binary search.

import (
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
)

type indexReaderIn struct {
	// The symbols to put in the file, as label VALUES on generated series. The writer requires symbols
	// added in sorted order, so the generator sorts them.
	Symbols []string `json:"symbols"`
	// Lookups to perform, by ordinal.
	Lookups []uint32 `json:"lookups"`
	// Reverse lookups to perform.
	Reverse []string `json:"reverse"`
	// Series IDs to read back, which for format v2 are byte positions divided by 16.
	SeriesIDs []uint64 `json:"seriesIDs"`
	// Chunk metas to attach to each generated series, as (mint, maxt, ref) triples. The writer requires
	// them ordered, so the generator sorts nothing and the cases supply them ordered.
	ChunkMetas [][3]int64 `json:"chunkMetas"`
	// Truncate the file to this many bytes before parsing; 0 means don't.
	TruncateTo int `json:"truncateTo"`
	// Flip one bit in the TOC's CRC, to reach the checksum path.
	CorruptTOCCRC bool `json:"corruptTOCCRC"`
	// **The generated file's bytes, hex.** This is INPUT, not output: the port has no index writer
	// (ADR-15 defers the file layer), so the oracle writes the file with Go's own `index.Writer` and hands
	// the bytes over. Putting it in the output instead would have the port compare against itself.
	FileHex string `json:"fileHex"`
}

type indexReaderOut struct {
	TOC struct {
		Symbols           uint64 `json:"symbols"`
		Series            uint64 `json:"series"`
		LabelIndices      uint64 `json:"labelIndices"`
		LabelIndicesTable uint64 `json:"labelIndicesTable"`
		Postings          uint64 `json:"postings"`
		PostingsTable     uint64 `json:"postingsTable"`
	} `json:"toc"`
	TOCErr      string   `json:"tocErr"`
	SymbolCount int      `json:"symbolCount"`
	SymbolSize  int      `json:"symbolSize"`
	AllSymbols  []string `json:"allSymbols"`
	SymbolsErr  string   `json:"symbolsErr"`
	LookedUp    []string `json:"lookedUp"`
	LookupErrs  []string `json:"lookupErrs"`
	Reversed    []uint32 `json:"reversed"`
	ReverseErrs []string `json:"reverseErrs"`
	// Per requested series ID: its labels as name/value pairs, its chunk metas, and any error.
	SeriesLabels [][]string `json:"seriesLabels"`
	SeriesChunks [][][3]int64 `json:"seriesChunks"`
	SeriesErrs   []string   `json:"seriesErrs"`
}

// `realByteSlice` is unexported, but `index.ByteSlice` is an exported interface with two methods — so the
// oracle supplies its own. That is the same "reach the exported seam" move §6a used for `bstream`.
type oracleByteSlice []byte

func (b oracleByteSlice) Len() int                    { return len(b) }
func (b oracleByteSlice) Range(start, end int) []byte { return b[start:end] }

func genIndexReader(e *emitter) {
	n := 0
	emit := func(in indexReaderIn) {
		out := indexReaderOut{
			AllSymbols: []string{}, LookedUp: []string{}, LookupErrs: []string{},
			Reversed: []uint32{}, ReverseErrs: []string{},
			SeriesLabels: [][]string{}, SeriesChunks: [][][3]int64{}, SeriesErrs: []string{},
		}

		dir, err := os.MkdirTemp("", "index")
		if err != nil {
			out.TOCErr = err.Error()
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}
		defer os.RemoveAll(dir)
		fn := filepath.Join(dir, "index")

		w, err := index.NewWriter(context.Background(), fn)
		if err != nil {
			out.TOCErr = err.Error()
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}
		// Symbols must be added in sorted order, and every label name/value used by a series must be a
		// symbol. So the symbol set is the values plus the one label name.
		syms := append([]string{}, in.Symbols...)
		syms = append(syms, "l")
		sort.Strings(syms)
		// De-duplicate: AddSymbol rejects repeats.
		uniq := syms[:0]
		for i, s := range syms {
			if i == 0 || s != syms[i-1] {
				uniq = append(uniq, s)
			}
		}
		syms = uniq
		for _, s := range syms {
			if err := w.AddSymbol(s); err != nil {
				out.TOCErr = err.Error()
				break
			}
		}
		if out.TOCErr == "" {
			// Series must be added in strictly increasing label order, so the SERIES list is de-duplicated
			// and sorted too — not just the symbol list. A repeated value makes `AddSeries` fail with
			// "out-of-order series added", the file is never written, and the case has nothing for the port
			// to parse. That is a corpus-generation flaw rather than a finding, and de-duplicating here is
			// the fix; the duplicate symbols the case was written for still reach the symbol TABLE, because
			// `AddSymbol` sees them before this.
			seriesVals := []string{}
			for _, s := range syms {
				if s != "l" {
					seriesVals = append(seriesVals, s)
				}
			}
			// **Chunk references must increase GLOBALLY, across series, not just within one** — they are
			// byte offsets into chunk segments, so the writer rejects "unsorted chunk reference: 1,
			// previous: 2" when a second series restarts them. Hence the per-series offset. The time
			// ranges, by contrast, are checked per series.
			for i, s := range seriesVals {
				metas := []chunks.Meta{}
				for _, m := range in.ChunkMetas {
					metas = append(metas, chunks.Meta{
						MinTime: m[0], MaxTime: m[1],
						Ref: chunks.ChunkRef(m[2] + int64(i)*1_000_000),
					})
				}
				if err := w.AddSeries(storage.SeriesRef(i+1), labels.FromStrings("l", s), metas...); err != nil {
					out.TOCErr = err.Error()
					break
				}
			}
		}
		if out.TOCErr == "" {
			if err := w.Close(); err != nil {
				out.TOCErr = err.Error()
			}
		} else {
			_ = w.Close()
		}
		if out.TOCErr != "" {
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}

		raw, err := os.ReadFile(fn)
		if err != nil {
			out.TOCErr = err.Error()
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}
		if in.CorruptTOCCRC && len(raw) > 0 {
			raw[len(raw)-1] ^= 0x01
		}
		if in.TruncateTo > 0 && in.TruncateTo < len(raw) {
			raw = raw[:in.TruncateTo]
		}
		in.FileHex = hex.EncodeToString(raw)

		bs := oracleByteSlice(raw)
		toc, err := index.NewTOCFromByteSlice(bs)
		if err != nil {
			out.TOCErr = err.Error()
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}
		out.TOC.Symbols = toc.Symbols
		out.TOC.Series = toc.Series
		out.TOC.LabelIndices = toc.LabelIndices
		out.TOC.LabelIndicesTable = toc.LabelIndicesTable
		out.TOC.Postings = toc.Postings
		out.TOC.PostingsTable = toc.PostingsTable

		sy, err := index.NewSymbols(bs, index.FormatV2, int(toc.Symbols))
		if err != nil {
			out.SymbolsErr = err.Error()
			e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
			n++
			return
		}
		out.SymbolSize = sy.Size()
		it := sy.Iter()
		for it.Next() {
			out.AllSymbols = append(out.AllSymbols, it.At())
			out.SymbolCount++
		}
		if it.Err() != nil {
			out.SymbolsErr = it.Err().Error()
		}
		for _, o := range in.Lookups {
			s, err := sy.Lookup(o)
			out.LookedUp = append(out.LookedUp, s)
			if err != nil {
				out.LookupErrs = append(out.LookupErrs, err.Error())
			} else {
				out.LookupErrs = append(out.LookupErrs, "")
			}
		}
		for _, s := range in.Reverse {
			o, err := sy.ReverseLookup(s)
			out.Reversed = append(out.Reversed, o)
			if err != nil {
				out.ReverseErrs = append(out.ReverseErrs, err.Error())
			} else {
				out.ReverseErrs = append(out.ReverseErrs, "")
			}
		}

		// Series records, read back through the reader so the symbol lookups and chunk-meta
		// double-delta decoding are both exercised.
		if len(in.SeriesIDs) > 0 {
			r, rerr := index.NewReader(bs, index.DecodePostingsRaw)
			if rerr != nil {
				out.SeriesErrs = append(out.SeriesErrs, rerr.Error())
			} else {
				for _, id := range in.SeriesIDs {
					var b labels.ScratchBuilder
					var chks []chunks.Meta
					err := r.Series(storage.SeriesRef(id), &b, &chks)
					if err != nil {
						out.SeriesLabels = append(out.SeriesLabels, []string{})
						out.SeriesChunks = append(out.SeriesChunks, [][3]int64{})
						out.SeriesErrs = append(out.SeriesErrs, err.Error())
						continue
					}
					pairs := []string{}
					b.Labels().Range(func(l labels.Label) {
						pairs = append(pairs, l.Name, l.Value)
					})
					cm := [][3]int64{}
					for _, c := range chks {
						cm = append(cm, [3]int64{c.MinTime, c.MaxTime, int64(c.Ref)})
					}
					out.SeriesLabels = append(out.SeriesLabels, pairs)
					out.SeriesChunks = append(out.SeriesChunks, cm)
					out.SeriesErrs = append(out.SeriesErrs, "")
				}
				_ = r.Close()
			}
		}

		e.emit(fmt.Sprintf("indexreader/%d", n), in, out)
		n++
	}

	// --- Series records, with chunk metas whose double-delta encoding is the interesting part.
	//
	// The first chunk is framed differently from the rest (signed mint, unsigned maxt delta, unsigned
	// ref) and every later one uses deltas — including a SIGNED reference delta, so a reference can move
	// backwards between chunks. Cases below make it do so.
	emit(indexReaderIn{
		Symbols: []string{"a", "b"}, SeriesIDs: []uint64{1, 2, 3},
		ChunkMetas: [][3]int64{{0, 100, 500}},
	})
	// The writer enforces `mint > prev.maxt` STRICTLY ("chunk minT 100 is not higher than previous chunk
	// maxT 100"), so the ranges below never touch.
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{1},
		ChunkMetas: [][3]int64{{0, 100, 500}, {101, 200, 700}, {201, 300, 900}},
	})
	// **The writer also enforces INCREASING references** ("unsorted chunk reference: 500, previous:
	// 9000") — even though `Decoder.Series` decodes the reference delta as a SIGNED varint, which could
	// represent a decrease. So the signed delta is defensive: no file the writer produces exercises it.
	// A case with a backwards reference is therefore unwritable, and that asymmetry is the finding.
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{1},
		ChunkMetas: [][3]int64{{0, 100, 500}, {101, 200, 9000}, {201, 300, 20000}},
	})
	// Negative and zero timestamps.
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{1},
		ChunkMetas: [][3]int64{{-1000, -500, 1}, {-499, -400, 2}, {-399, 0, 3}},
	})
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{1},
		ChunkMetas: [][3]int64{{0, 0, 0}},
	})
	// Large values, so the varints are wide.
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{1},
		ChunkMetas: [][3]int64{{1 << 40, 1 << 41, 1 << 42}, {(1 << 41) + 1, 1 << 42, (1 << 42) + 7}},
	})
	// No chunks at all, which takes the `k == 0` early return.
	emit(indexReaderIn{Symbols: []string{"a", "b"}, SeriesIDs: []uint64{1, 2}})
	// An out-of-range series ID.
	emit(indexReaderIn{
		Symbols: []string{"a"}, SeriesIDs: []uint64{0, 99999},
		ChunkMetas: [][3]int64{{0, 1, 1}},
	})
	// Many series, so the IDs are spread across the padded records.
	{
		syms := []string{}
		for i := range 40 {
			syms = append(syms, fmt.Sprintf("s%03d", i))
		}
		ids := []uint64{}
		for i := 1; i <= 40; i++ {
			ids = append(ids, uint64(i))
		}
		emit(indexReaderIn{
			Symbols: syms, SeriesIDs: ids, ChunkMetas: [][3]int64{{0, 10, 1}, {11, 20, 2}},
		})
	}

	// A handful of symbols: one sparse offset only.
	emit(indexReaderIn{Symbols: []string{"a", "b", "c"}, Lookups: []uint32{0, 1, 2, 3},
		Reverse: []string{"a", "b", "c", "zz"}})
	emit(indexReaderIn{Symbols: []string{"a"}, Lookups: []uint32{0, 1}, Reverse: []string{"a", "b"}})

	// Exactly at and around the sparse factor of 32.
	for _, count := range []int{31, 32, 33, 64, 65, 100} {
		syms := make([]string, 0, count)
		for i := range count {
			syms = append(syms, fmt.Sprintf("s%04d", i))
		}
		lookups := []uint32{0, 1, 30, 31, 32, 33, 63, 64, uint32(count - 1), uint32(count)}
		rev := []string{"s0000", "s0031", "s0032", fmt.Sprintf("s%04d", count-1), "nope"}
		emit(indexReaderIn{Symbols: syms, Lookups: lookups, Reverse: rev})
	}

	// Past 1024 symbols, so the sparse table itself has more than 32 entries.
	{
		syms := make([]string, 0, 1100)
		for i := range 1100 {
			syms = append(syms, fmt.Sprintf("v%05d", i))
		}
		emit(indexReaderIn{
			Symbols: syms,
			Lookups: []uint32{0, 32, 512, 1023, 1024, 1099, 1100},
			Reverse: []string{"v00000", "v00512", "v01099", "v99999"},
		})
	}

	// Symbols where Go's BYTE ordering and Unicode collation disagree (ADR-10). The table is sorted by
	// the former and binary-searched, so a port comparing by collation searches a differently-ordered
	// array.
	emit(indexReaderIn{
		Symbols: []string{"Z", "a", "é", "é", "z", "É"},
		Lookups: []uint32{0, 1, 2, 3, 4, 5},
		Reverse: []string{"Z", "a", "z", "é", "é", "É"},
	})
	// Empty and near-empty symbols, and ones with a NUL.
	emit(indexReaderIn{Symbols: []string{"", "a", "a\x00b"},
		Lookups: []uint32{0, 1, 2}, Reverse: []string{"", "a", "a\x00b"}})

	// A corrupted TOC CRC, and a truncated file.
	emit(indexReaderIn{Symbols: []string{"a", "b"}, CorruptTOCCRC: true})
	emit(indexReaderIn{Symbols: []string{"a", "b"}, TruncateTo: 10})
	emit(indexReaderIn{Symbols: []string{"a", "b"}, TruncateTo: 51})
}
