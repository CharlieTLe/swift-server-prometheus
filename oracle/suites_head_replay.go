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
//     has. The replay must not resurrect them. Past a threshold this also writes a CHECKPOINT (see below).
//   * `deleteBeforeClose` — a `Delete`, so a tombstone record is in the WAL and the replay has to reapply it.
//   * `phases` — several appender transactions, so several WAL segments' worth of records and several chunks.
//
// ## The checkpoint, and why a case needs five phases to get one
//
// `Head.truncateWAL` cuts a new segment on every truncation but only writes a checkpoint when
// `first + (last-first)*2/3 > first` — where `last` has already been decremented, because the segment an
// appender is writing into is never checkpointed. So with `first == 0` a checkpoint needs `(last-1)*2/3 >= 1`,
// i.e. **at least four segments** in the directory. `cutSegmentBetweenPhases` puts each phase in its own
// segment, so five phases is the smallest case that produces one.
//
// When a checkpoint IS written, three more things are committed:
//
//   * `checkpoint.name` — the directory name, which encodes the `to` segment index and is therefore the
//     two-thirds rule's arithmetic stated as a string.
//   * `checkpoint.files` — its segments as RLE-hex, so the COMPACTION is asserted as bytes. A dropped series
//     record or a dropped sample is a byte difference here, not a counter.
//   * the WAL directory listing after truncation, in `walSegments` — which is read after the `Truncate`, so it
//     shows which segments went and that the checkpoint directory is what replaced them.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
	"github.com/prometheus/prometheus/tsdb/record"
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
	// A SECOND `Truncate`, at a higher point. The only route to the checkpoint's dropped-SERIES arm: the first
	// truncation records `walExpiries[ref] = actualInOrderMint` for the series it collected, and the second —
	// whose `mint` is above that — finds the expiry stale, so `keep` finally answers false. It is also the only
	// case with TWO checkpoints in sequence, so it is what exercises `Checkpoint`'s range replacement (`from`
	// becomes the previous checkpoint's index + 1, and that checkpoint's directory is prepended to the read).
	TruncateTwice *int64 `json:"truncateTwice,omitempty"`
	// A `Delete` on the first head before it is closed, over [mint, maxt] with the `all` matcher.
	DeleteBeforeClose []int64 `json:"deleteBeforeClose,omitempty"`
	// Perform that `Delete` after this PHASE instead of at the end, so the tombstone record lands in a segment
	// the checkpoint will cover. Without it the tombstone goes into the live segment, which is never
	// checkpointed, and the checkpoint's tombstone filter is unreachable.
	DeleteAfterPhase *int `json:"deleteAfterPhase,omitempty"`
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
	// The checkpoint the truncation wrote, if it wrote one — its directory NAME and its segments as bytes.
	// Absent when the two-thirds rule declined, which is itself the assertion for the cases that do not
	// produce one.
	Checkpoint *hwCheckpointOut `json:"checkpoint,omitempty"`
	// True when the two heads' series (labels, samples and chunk layout) are identical — the contract, stated
	// as one boolean so a mismatch is obvious before the diff is read.
	Equivalent bool `json:"equivalent"`
}

// The checkpoint directory, as a name plus bytes. `Files` reuses `readDirRLE` because a checkpoint IS a WAL
// directory — same segment framing, same long runs of pre-allocated zeros.
type hwCheckpointOut struct {
	Name  string      `json:"name"`
	Files []haFileOut `json:"files"`
	// The same segments DECODED. The bytes above are the contract; this is that contract in a form a diff can
	// be read — which is what makes "the checkpoint kept m2's series record although the head no longer has
	// m2" visible rather than buried in hex.
	Records []hwCPRecord `json:"records"`
}

// One record from the checkpoint, in the order the reader met it.
type hwCPRecord struct {
	Type string `json:"type"`
	// Series records: `ref=labelset`, so a dropped series is a missing entry rather than a smaller number.
	Series []string `json:"series,omitempty"`
	// Sample records: `ref@t=floatbits`.
	Samples []string `json:"samples,omitempty"`
	// Tombstone records: `ref:[mint,maxt]…`.
	Stones []string `json:"stones,omitempty"`
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

	// The checkpoint directory, if the truncation wrote one. Named `checkpoint.NNNNNNNN`; the LAST one is what
	// `Head.Init` reads, and normally it is the only one because `truncateWAL` deletes the ones it supersedes —
	// so a second directory would show up in `walSegments` rather than being hidden here.
	readCheckpoint := func(dir string) *hwCheckpointOut {
		entries, err := os.ReadDir(filepath.Join(dir, "wal"))
		if err != nil {
			return nil
		}
		name := ""
		for _, ent := range entries {
			if ent.IsDir() && strings.HasPrefix(ent.Name(), "checkpoint.") {
				name = ent.Name() // ReadDir is sorted, so the last match is the highest index.
			}
		}
		if name == "" {
			return nil
		}
		cpdir := filepath.Join(dir, "wal", name)
		out := &hwCheckpointOut{
			Name: name, Files: readDirRLE(cpdir), Records: []hwCPRecord{},
		}
		// Decoded through the same reader `Head.Init` uses, which is the point: a checkpoint is a WAL
		// directory and nothing special is needed to read one.
		sr, err := wlog.NewSegmentsReader(cpdir)
		if err != nil {
			panic(err)
		}
		r := wlog.NewReader(sr)
		dec := record.NewDecoder(labels.NewSymbolTable(), nil)
		for r.Next() {
			rec := r.Record()
			cr := hwCPRecord{Type: dec.Type(rec).String()}
			switch dec.Type(rec) {
			case record.Series:
				ss, err := dec.Series(rec, nil)
				if err != nil {
					panic(err)
				}
				for _, s := range ss {
					cr.Series = append(cr.Series, fmt.Sprintf("%d=%s", s.Ref, s.Labels.String()))
				}
			case record.Samples, record.SamplesV2:
				ss, err := dec.Samples(rec, nil)
				if err != nil {
					panic(err)
				}
				for _, s := range ss {
					cr.Samples = append(cr.Samples, fmt.Sprintf("%d@%d=%s", s.Ref, s.T, fbits(s.V)))
				}
			case record.Tombstones:
				ts, err := dec.Tombstones(rec, nil)
				if err != nil {
					panic(err)
				}
				for _, s := range ts {
					cr.Stones = append(cr.Stones, fmt.Sprintf("%d:%v", s.Ref, s.Intervals))
				}
			}
			out.Records = append(out.Records, cr)
		}
		if err := r.Err(); err != nil {
			panic(err)
		}
		_ = sr.Close()
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
		deleteAll := func() {
			if err := h1.Delete(context.Background(), in.DeleteBeforeClose[0], in.DeleteBeforeClose[1], hrMatchers("all")...); err != nil {
				panic(err)
			}
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
			if in.DeleteAfterPhase != nil && *in.DeleteAfterPhase == pi {
				deleteAll()
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
		if in.TruncateTwice != nil {
			if err := h1.Truncate(*in.TruncateTwice); err != nil {
				panic(err)
			}
		}
		if len(in.DeleteBeforeClose) == 2 && in.DeleteAfterPhase == nil {
			deleteAll()
		}

		out := hwOut{}
		out.Original = readHead(h1, dir, "")
		out.Checkpoint = readCheckpoint(dir)
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

	// --- A truncation before the close: §7h(c) -----------------------------------------------------
	//
	// `Head.Truncate` truncates the WAL as well as the memory: `truncateWAL` always cuts a new segment, and
	// past the two-thirds threshold it also writes a checkpoint. This first case is BELOW the threshold — one
	// segment, so `last--` takes it to -1 and the function returns having only cut segment 00000001. The
	// committed `walSegments` is what says so, and `checkpoint` is absent.
	//
	// Note also what a truncation does NOT do: it does not remove samples from the segment they are in. The
	// replay brings all twelve back, and only `minValidTime` (above) refuses them.
	trunc8000 := int64(8000)
	emit("truncated-then-replayed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		TruncateBeforeClose: &trunc8000})
	emit("truncated-then-replayed-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many}, CloseFirst: true,
		TruncateBeforeClose: &trunc8000})

	// --- A real CHECKPOINT: five segments, so the two-thirds rule fires ----------------------------
	//
	// Five phases, each cut into its own segment, so `Segments` reports first=0 last=4. `truncateWAL` cuts
	// segment 5, decrements to 3, and `0 + 3*2/3 = 2` — a checkpoint over segments 0..2, then `Truncate(3)`
	// removes them. What is committed is the compaction itself: the checkpoint's name (`checkpoint.00000002`,
	// which is the arithmetic), its segment bytes, and the WAL listing that shows 0..2 gone.
	//
	// The timestamps step one chunk per phase and stay inside the appendable window —
	// `appendableMinValidTime` is `maxTime - chunkRange/2`, so 4,000 apart with a 4,000 chunk range is the
	// widest safe stride.
	stepped := func(phases int, extra func(p int) []hrSample) [][]hrSample {
		out := [][]hrSample{}
		for p := 0; p < phases; p++ {
			phase := []hrSample{}
			for i := 0; i < 4; i++ {
				t := int64(p)*4000 + int64(i)*1000
				phase = append(phase, sample("m1", "a", t, float64(p*10+i)))
			}
			if extra != nil {
				phase = append(phase, extra(p)...)
			}
			out = append(out, phase)
		}
		return out
	}
	// `m2` only ever gets samples in phase 0, so any truncation above 3000 garbage-collects it.
	onlyInPhaseZero := func(p int) []hrSample {
		if p != 0 {
			return nil
		}
		out := []hrSample{}
		for i := 0; i < 4; i++ {
			out = append(out, sample("m2", "b", int64(i)*1000, float64(100+i)))
		}
		return out
	}

	five := stepped(5, nil)
	// mint 8000 is the boundary of the third chunk, so the checkpoint keeps the samples from segment 2 and
	// drops the eight below it — visible as a shorter samples record in the checkpoint's records and bytes.
	emit("checkpoint-five-segments", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc8000})
	emit("checkpoint-five-segments-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		CloseFirst: true, TruncateBeforeClose: &trunc8000})
	// A truncation past everything the checkpoint covers: every sample in segments 0..2 is below `mint`, so
	// the checkpoint keeps the SERIES record and no samples at all.
	trunc16000 := int64(16000)
	emit("checkpoint-drops-every-sample", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc16000})
	// Below the threshold even with five phases, because nothing cut a segment: one segment, no checkpoint.
	emit("five-phases-one-segment-no-checkpoint", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, TruncateBeforeClose: &trunc8000})

	// --- A series DELETED by the truncation, whose records the checkpoint must keep -----------------
	//
	// A truncation at 16000 garbage-collects `m2` — and `gc` records `walExpiries[m2] = actualInOrderMint`.
	// That expiry is the ONLY reason `keepSeriesInWALCheckpointFn` keeps `m2`'s series record, since `m2` is no
	// longer in the head. The checkpoint's records are where that shows: `m2`'s series record is there with no
	// samples at all, and dropping the expiry arm takes it away.
	withM2 := stepped(5, onlyInPhaseZero)
	emit("checkpoint-keeps-a-gcd-series-record", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: withM2, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc16000})
	emit("checkpoint-keeps-a-gcd-series-record-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: withM2, CutSegmentBetweenPhases: true,
		CloseFirst: true, TruncateBeforeClose: &trunc16000})

	// --- TWO checkpoints, and the only case that DROPS a series record ------------------------------
	//
	// Eight segments, so the two-thirds rule fires twice: `0 + 6*2/3 = 4` writes `checkpoint.00000004` and
	// truncates to segment 5, then `5 + 2*2/3 = 6` writes `checkpoint.00000006`. The second checkpoint READS
	// the first — `Checkpoint` replaces `from` with the previous index + 1 and prepends that directory to the
	// range — which is why `checkpoint.00000006` holds records that came from segments 0..4.
	//
	// And it is the only place `keep` answers FALSE. `m2` was collected by the first truncation with an expiry
	// of 8000; the second truncation's `mint` of 16000 is above it, and the expiries are pruned only AFTER the
	// checkpoint is written — so the checkpoint sees a stale expiry and drops `m2`'s series record for good.
	eightWithM2 := stepped(8, onlyInPhaseZero)
	emit("two-checkpoints-drop-a-series-record", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: eightWithM2, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc8000, TruncateTwice: &trunc16000})
	emit("two-checkpoints-drop-a-series-record-closed", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: eightWithM2, CutSegmentBetweenPhases: true,
		CloseFirst: true, TruncateBeforeClose: &trunc8000, TruncateTwice: &trunc16000})
	// The same two truncations without `m2`, so the second checkpoint's content is only about the range
	// replacement: `checkpoint.00000006` carries `m1`'s samples from 16000 up, including the ones that reached
	// it through `checkpoint.00000004` rather than through a live segment.
	emit("two-checkpoints-include-the-first", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: stepped(8, nil), CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc8000, TruncateTwice: &trunc16000})
	// A second truncation at the SAME point is the idempotence guard (`mint <= lastWALTruncationTime`): it
	// does nothing at all, not even cut a segment.
	emit("second-truncation-at-the-same-point-is-a-no-op", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc8000, TruncateTwice: &trunc8000})

	// --- A TOMBSTONE inside the checkpointed range --------------------------------------------------
	//
	// The delete happens after a phase rather than at the end, so its record is in a segment the checkpoint
	// covers — which is the only way the checkpoint's tombstone filter is reachable at all. A stone is kept
	// when ANY of its intervals reaches `mint` and dropped otherwise, all-or-nothing rather than trimmed.
	//
	// Note the delete's interval is CLAMPED to the head's range first, so the stone that reaches the WAL is
	// [9000, 11000] rather than what was asked for — and `maxt` 11000 is what carries it past `mint` 8000.
	afterPhase2 := 2
	emit("checkpoint-keeps-a-tombstone", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		DeleteBeforeClose: []int64{9000, 20000}, DeleteAfterPhase: &afterPhase2,
		TruncateBeforeClose: &trunc8000})
	// The same machinery, dropping instead: the stone's `maxt` of 3000 is below the truncation point. It is
	// gone from the head too (`truncateBefore`), so the checkpoint's bytes are the only place the drop shows.
	afterPhase1 := 1
	emit("checkpoint-drops-a-tombstone", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		DeleteBeforeClose: []int64{1000, 3000}, DeleteAfterPhase: &afterPhase1,
		TruncateBeforeClose: &trunc8000})

	// --- The checkpoint is what the replay reads FIRST ---------------------------------------------
	//
	// Replayed twice, so the second `Init` proves the checkpoint plus the surviving segments are a complete
	// account: the same head comes back both times.
	emit("checkpoint-replayed-twice", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		CloseFirst: true, TruncateBeforeClose: &trunc8000, ReplayTwice: true})
	// And with a `minValidTime` above part of what the checkpoint holds, so the replay's own filter runs on
	// records that already survived the checkpoint's.
	emit("checkpoint-then-min-valid-time", hwIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: five, CutSegmentBetweenPhases: true,
		TruncateBeforeClose: &trunc8000, MinValidTime: 12000})

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
