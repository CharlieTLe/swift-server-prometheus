package main

// Differential coverage for the Head's WAL REPLAY — `Init`, `loadMmappedChunks`, `loadWAL` and
// `resetSeriesWithMMappedChunks`. Driven through the real `tsdb.NewHead` + `Init`, twice per case.
//
// ## The shape: build a head, then rebuild it from what it wrote
//
// Each case appends samples to a Head with a real WAL, closes it, then opens a SECOND Head on the same
// directory and calls `Init`. The committed output is the state of BOTH heads, read through the same
// accessors and the same index/chunk readers — so the fixture asserts the equivalence directly:
//
//     a Head built by replaying a WAL == a Head built by appending the same samples
//
// That is the contract §7f's HANDOFF entry named, and it is why a corpus for replay does not need to encode
// expected internals: the first head IS the expectation, and the samples are compared after decoding.
//
// ## What each knob is for
//
//   * `closeFirst` — whether the first head is CLOSED before the second opens. Closing m-maps the chunk tail,
//     so the replay then has to combine `loadMmappedChunks` with the WAL; not closing leaves everything in the
//     WAL alone. Both paths must produce the same samples, and only the chunk-file listing differs.
//   * `minValidTime` — passed to `Init`. Samples below it are DISCARDED by the replay, which is what makes a
//     replayed head legitimately smaller than the original.
//   * `truncateBeforeClose` — a `Truncate` on the first head, so the WAL still holds records the head no longer
//     has. The replay must not resurrect them.
//   * `deleteBeforeClose` — a `Delete`, so a tombstone record is in the WAL and the replay has to reapply it.
//   * `phases` — several appender transactions, so several WAL segments' worth of records and several chunks.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
	"github.com/prometheus/prometheus/tsdb/tombstones"
	"github.com/prometheus/prometheus/tsdb/wlog"
	"github.com/prometheus/prometheus/util/compression"
)

type hwIn struct {
	ChunkRange      int64        `json:"chunkRange"`
	SamplesPerChunk int          `json:"samplesPerChunk"`
	Phases          [][]hrSample `json:"phases"`
	// Close the first head before replaying, which m-maps its chunk tail.
	CloseFirst bool `json:"closeFirst"`
	// `Init(minValidTime)` on the replayed head.
	MinValidTime int64 `json:"minValidTime,omitempty"`
	// A `Truncate` on the first head before it is closed.
	TruncateBeforeClose *int64 `json:"truncateBeforeClose,omitempty"`
	// A `Delete` on the first head before it is closed, over [mint, maxt] with the `all` matcher.
	DeleteBeforeClose []int64 `json:"deleteBeforeClose,omitempty"`
	// Replay TWICE, so the second replay proves `mmMaxTime` stops the samples being counted again.
	ReplayTwice bool `json:"replayTwice,omitempty"`
	// Overwrite the chunk file with garbage before replaying, so `loadMmappedChunks` fails and
	// `removeCorruptedMmappedChunks` has to recover — from the WAL, which still holds everything.
	CorruptChunkFile bool `json:"corruptChunkFile,omitempty"`
	// Cut a new WAL segment between phases, so the replay has TWO segments with records in them.
	CutSegmentBetweenPhases bool `json:"cutSegmentBetweenPhases,omitempty"`
	// Start-timestamp storage plus XOR2, which is what `promqltest` configures (quirk 36).
	StoreST bool `json:"storeST,omitempty"`
}

type hwSeriesOut struct {
	Labels  map[string]string `json:"labels"`
	Samples []hrReadSample    `json:"samples"`
	// The chunk metas, so the CHUNK LAYOUT is compared too — a replay that produced the right samples in the
	// wrong number of chunks is a different head.
	Chunks []hrChunkMeta `json:"chunks"`
}

type hwHeadOut struct {
	MinTime   int64  `json:"minTime"`
	MaxTime   int64  `json:"maxTime"`
	NumSeries uint64 `json:"numSeries"`
	NumStale  uint64 `json:"numStale"`
	// SORTED by label set, so the two heads are comparable regardless of ref assignment.
	Series          []hwSeriesOut `json:"series"`
	Tombstones      []hgTombstone `json:"tombstones"`
	ChunkDirEntries []string      `json:"chunkDirEntries"`
	WALSegments     []string      `json:"walSegments"`
	InitErr         string        `json:"initErr"`
}

type hwOut struct {
	Original hwHeadOut  `json:"original"`
	Replayed hwHeadOut  `json:"replayed"`
	Again    *hwHeadOut `json:"again,omitempty"`
	// True when the two heads' series (labels, samples and chunk layout) are identical — the contract, stated
	// as one boolean so a mismatch is obvious before the diff is read.
	Equivalent bool `json:"equivalent"`
}

func genHeadReplay(e *emitter) {
	n := 0

	readHead := func(h *tsdb.Head, dir string, initErr string) hwHeadOut {
		out := hwHeadOut{
			MinTime: h.MinTime(), MaxTime: h.MaxTime(), NumSeries: h.NumSeries(),
			NumStale: h.NumStaleSeries(), Series: []hwSeriesOut{}, Tombstones: []hgTombstone{},
			ChunkDirEntries: []string{}, WALSegments: []string{}, InitErr: initErr,
		}

		ir, err := h.Index()
		if err == nil {
			cr, cerr := h.Chunks()
			allName, allValue := index.AllPostingsKey()
			p, perr := ir.Postings(context.Background(), allName, allValue)
			if perr == nil && cerr == nil {
				refs, _ := index.ExpandPostings(ir.SortedPostings(p))
				for _, r := range refs {
					var builder labels.ScratchBuilder
					var chks []chunks.Meta
					if err := ir.Series(r, &builder, &chks); err != nil {
						continue
					}
					so := hwSeriesOut{
						Labels: builder.Labels().Map(), Samples: []hrReadSample{},
						Chunks: []hrChunkMeta{},
					}
					for _, c := range chks {
						so.Chunks = append(so.Chunks, hrChunkMeta{
							// The REF is deliberately omitted from the comparison — it encodes the series id,
							// which a replay is free to assign differently. Only the times are the contract.
							MinTime: c.MinTime, MaxTime: c.MaxTime,
						})
						chk, _, err := cr.ChunkOrIterable(c)
						if err != nil || chk == nil {
							continue
						}
						it := chk.Iterator(nil)
						for it.Next() == chunkenc.ValFloat {
							t, v := it.At()
							so.Samples = append(so.Samples, hrReadSample{T: t, V: fbits(v)})
						}
					}
					out.Series = append(out.Series, so)
				}
			}
			if cerr == nil {
				_ = cr.Close()
			}
			_ = ir.Close()
		}
		// Sorted by the metric name, so the two heads line up regardless of ref order.
		sort.Slice(out.Series, func(i, j int) bool {
			return out.Series[i].Labels["__name__"] < out.Series[j].Labels["__name__"]
		})

		if tr, err := h.Tombstones(); err == nil {
			_ = tr.Iter(func(ref storage.SeriesRef, ivs tombstones.Intervals) error {
				t := hgTombstone{Ref: uint64(ref), Intervals: [][]int64{}}
				for _, iv := range ivs {
					t.Intervals = append(t.Intervals, []int64{iv.Mint, iv.Maxt})
				}
				out.Tombstones = append(out.Tombstones, t)
				return nil
			})
			sort.Slice(out.Tombstones, func(i, j int) bool {
				return out.Tombstones[i].Ref < out.Tombstones[j].Ref
			})
		}

		if entries, err := os.ReadDir(filepath.Join(dir, "chunks_head")); err == nil {
			for _, ent := range entries {
				out.ChunkDirEntries = append(out.ChunkDirEntries, ent.Name())
			}
		}
		if entries, err := os.ReadDir(filepath.Join(dir, "wal")); err == nil {
			for _, ent := range entries {
				out.WALSegments = append(out.WALSegments, ent.Name())
			}
		}
		return out
	}

	emit := func(name string, in hwIn) {
		dir, err := os.MkdirTemp("", "promoracle-hwal")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		var lastWAL *wlog.WL
		newHead := func() *tsdb.Head {
			opts := tsdb.DefaultHeadOptions()
			opts.ChunkDirRoot = dir
			opts.ChunkRange = in.ChunkRange
			opts.SamplesPerChunk = in.SamplesPerChunk
			if in.StoreST {
				opts.EnableSTStorage.Store(true)
				opts.FloatChunkEncoding.Store(uint32(chunkenc.EncXOR2))
			}
			w, err := wlog.New(nil, nil, filepath.Join(dir, "wal"), compression.None)
			if err != nil {
				panic(err)
			}
			lastWAL = w
			h, err := tsdb.NewHead(nil, nil, w, nil, opts, nil)
			if err != nil {
				panic(err)
			}
			return h
		}

		// --- The original head --------------------------------------------------------------------

		h1 := newHead()
		if err := h1.Init(0); err != nil {
			panic(err)
		}
		for pi, phase := range in.Phases {
			app := h1.Appender(context.Background())
			for _, s := range phase {
				if _, err := app.Append(0, labels.FromMap(s.Labels), s.T, fbitsToFloat(s.V)); err != nil {
					panic(err)
				}
			}
			if err := app.Commit(); err != nil {
				panic(err)
			}
			if in.CutSegmentBetweenPhases && pi < len(in.Phases)-1 {
				// `Head` does not expose its WAL, so the case cuts through the `wlog.WL` it created.
				if _, err := lastWAL.NextSegment(); err != nil {
					panic(err)
				}
			}
		}
		if in.TruncateBeforeClose != nil {
			if err := h1.Truncate(*in.TruncateBeforeClose); err != nil {
				panic(err)
			}
		}
		if len(in.DeleteBeforeClose) == 2 {
			if err := h1.Delete(context.Background(), in.DeleteBeforeClose[0], in.DeleteBeforeClose[1], hrMatchers("all")...); err != nil {
				panic(err)
			}
		}

		out := hwOut{}
		out.Original = readHead(h1, dir, "")
		if in.CloseFirst {
			if err := h1.Close(); err != nil {
				panic(err)
			}
			// Re-read the directory listing after the close, which is what m-maps the tail.
			out.Original.ChunkDirEntries = []string{}
			if entries, err := os.ReadDir(filepath.Join(dir, "chunks_head")); err == nil {
				for _, ent := range entries {
					out.Original.ChunkDirEntries = append(out.Original.ChunkDirEntries, ent.Name())
				}
			}
		}

		if in.CorruptChunkFile {
			entries, err := os.ReadDir(filepath.Join(dir, "chunks_head"))
			if err == nil {
				for _, ent := range entries {
					// The HEADER has to stay intact: `NewChunkDiskMapper` validates the magic number when it
					// opens the directory, so a wholly garbled file fails construction rather than reaching
					// `Init` — which means `removeCorruptedMmappedChunks` would never run. Corrupting the BODY
					// is what makes `IterateAllChunks` fail, which is the path that recovery exists for.
					name := filepath.Join(dir, "chunks_head", ent.Name())
					b, err := os.ReadFile(name)
					if err != nil || len(b) < 8 {
						continue
					}
					head := append([]byte{}, b[:8]...)
					body := make([]byte, len(b)-8)
					for i := range body {
						body[i] = 0xff
					}
					if err := os.WriteFile(name, append(head, body...), 0o666); err != nil {
						panic(err)
					}
				}
			}
		}

		// --- The replayed head --------------------------------------------------------------------

		h2 := newHead()
		initErr := ""
		if err := h2.Init(in.MinValidTime); err != nil {
			initErr = scrubDir(err.Error(), dir)
		}
		out.Replayed = readHead(h2, dir, initErr)

		if in.ReplayTwice {
			h3 := newHead()
			initErr3 := ""
			if err := h3.Init(in.MinValidTime); err != nil {
				initErr3 = scrubDir(err.Error(), dir)
			}
			again := readHead(h3, dir, initErr3)
			out.Again = &again
			_ = h3.Close()
		}

		// The contract, as one boolean over the parts that must agree.
		out.Equivalent = seriesEqual(out.Original.Series, out.Replayed.Series)

		_ = h2.Close()
		// The unclean case deliberately never closes `h1`: a crash does not close anything, and closing it
		// AFTER `h2` opened the same directory makes upstream's own mapper panic ("expected newly cut file to
		// have sequence:offset 1:8, got 2:8") — two live `ChunkDiskMapper`s on one directory is not a supported
		// state. Leaking it is what a crash looks like.

		e.emit(fmt.Sprintf("hwal/%03d/%s", n, name), in, out)
		n++
	}

	const twoHours = int64(2 * 60 * 60 * 1000)
	sample := func(name, job string, t int64, v float64) hrSample {
		return hrSample{Labels: map[string]string{"__name__": name, "job": job}, T: t, V: fbits(v)}
	}

	// --- The empty WAL ------------------------------------------------------------------------------

	emit("empty-wal", hwIn{ChunkRange: twoHours, SamplesPerChunk: 120, Phases: [][]hrSample{}})

	// --- One series, one sample ---------------------------------------------------------------------

	emit("one-sample", hwIn{ChunkRange: twoHours, SamplesPerChunk: 120,
		Phases: [][]hrSample{{sample("m1", "a", 1000, 1)}}})

	emit("one-sample-closed", hwIn{ChunkRange: twoHours, SamplesPerChunk: 120, CloseFirst: true,
		Phases: [][]hrSample{{sample("m1", "a", 1000, 1)}}})

	// --- Several series and several transactions ----------------------------------------------------

	phases := [][]hrSample{}
	for txn := 0; txn < 3; txn++ {
		phase := []hrSample{}
		for s := 0; s < 3; s++ {
			phase = append(phase, sample(fmt.Sprintf("m%d", s), "a", int64(txn)*15_000, float64(txn*10+s)))
		}
		phases = append(phases, phase)
	}
	emit("three-series-three-transactions", hwIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: phases})
	emit("three-series-three-transactions-closed", hwIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: phases, CloseFirst: true})

	// --- Enough samples to cut chunks, so the replay has to rebuild the LAYOUT ----------------------

	many := []hrSample{}
	for i := 0; i < 12; i++ {
		many = append(many, sample("m1", "a", int64(i)*1000, float64(i)))
	}
	emit("many-chunks", hwIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}})
	// Closed first, so the chunk FILES hold the older chunks and the replay must combine both sources.
	emit("many-chunks-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true})
	// And replayed twice: `mmMaxTime` is what stops the second replay double-counting.
	emit("many-chunks-closed-twice", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true,
		ReplayTwice: true})

	// --- minValidTime discards the older half ------------------------------------------------------

	emit("min-valid-time-discards", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, MinValidTime: 6000})
	emit("min-valid-time-discards-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true,
		MinValidTime: 6000})
	// Past everything: the replay produces an EMPTY head from a full WAL.
	emit("min-valid-time-past-everything", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, MinValidTime: 1_000_000})

	// --- A truncation before the close is §7h(c)'s, NOT this slice's -------------------------------
	//
	// `Head.Truncate` upstream also truncates the WAL — `truncateWAL` cuts a new segment and, past a threshold,
	// writes a checkpoint. The port's `Truncate` has only the memory half (§7h(a) left the WAL call site as a
	// named gap), so a case here would be committing that DIFFERENCE rather than a contract: Go's directory
	// would hold segment 00000001 and the port's would not. The case is written and left commented so §7h(c)
	// starts by uncommenting it.
	//
	//	trunc := int64(8000)
	//	emit("truncated-then-replayed", hwIn{
	//		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
	//		TruncateBeforeClose: &trunc})
	//
	// What IS pinned here is the other half of that story: a truncation does not remove samples from the
	// segment they are in, so a replay of an untruncated WAL brings them all back. The `min-valid-time` cases
	// above are how the port refuses them instead.

	// --- A CORRUPT chunk file, recovered from the WAL ----------------------------------------------

	emit("corrupt-chunk-file-recovered", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true,
		CorruptChunkFile: true})

	// --- Records in TWO segments -------------------------------------------------------------------

	emit("two-segments", hwIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: phases, CutSegmentBetweenPhases: true})
	emit("two-segments-closed", hwIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: phases, CutSegmentBetweenPhases: true,
		CloseFirst: true})

	// --- XOR2 with start-timestamp storage ---------------------------------------------------------

	emit("xor2-with-st-storage", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, StoreST: true})
	emit("xor2-with-st-storage-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, StoreST: true,
		CloseFirst: true})

	// --- A tombstone in the WAL --------------------------------------------------------------------

	emit("tombstone-replayed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		DeleteBeforeClose: []int64{2000, 5000}})
	emit("tombstone-replayed-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true,
		DeleteBeforeClose: []int64{2000, 5000}})
}

func seriesEqual(a, b []hwSeriesOut) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if len(a[i].Labels) != len(b[i].Labels) {
			return false
		}
		for k, v := range a[i].Labels {
			if b[i].Labels[k] != v {
				return false
			}
		}
		if len(a[i].Samples) != len(b[i].Samples) {
			return false
		}
		for j := range a[i].Samples {
			if a[i].Samples[j] != b[i].Samples[j] {
				return false
			}
		}
		if len(a[i].Chunks) != len(b[i].Chunks) {
			return false
		}
		for j := range a[i].Chunks {
			if a[i].Chunks[j] != b[i].Chunks[j] {
				return false
			}
		}
	}
	return true
}
