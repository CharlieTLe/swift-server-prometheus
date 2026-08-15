package main

// Differential coverage for the Head's GARBAGE COLLECTION and DELETION — `Delete`, `Tombstones`, `Truncate`,
// and the `stripeSeries.gc` underneath them. Driven through the real `tsdb.Head`, whose `Delete`, `Truncate`
// and `Tombstones` are all exported.
//
// ## What a case is
//
// Appends (in phases, so several chunks exist), then a program of `delete`/`truncate` operations, and after each
// one the whole visible state: the accessors, the tombstones, the series that survive, and their chunk metas.
// Reading the metas after a truncation is what pins `firstChunkID`'s advance — a chunk ref handed out before a
// truncation must still name the same chunk, or be out of range.
//
// ## Two decisions the cases are built around
//
//   * **`Delete` clamps TWICE**: the requested interval against the head's range, and then again per series
//     against that series' own range. So two series matched by one call can get different tombstones, and a
//     series with no samples gets none at all.
//   * **`Truncate` on an UNINITIALISED head still moves the bounds** but skips the GC, which is how `db.go`
//     seeds `minValidTime` from the last persisted block. A case with no appends at all covers it.
//
// `WaitForPendingReadersInTimeRange` is absent from the port (no concurrency), and the corpus cannot see it
// either: it blocks, it does not answer.

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
	"github.com/prometheus/prometheus/tsdb/tombstones"
	"github.com/prometheus/prometheus/tsdb/wlog"
	"github.com/prometheus/prometheus/util/compression"
)

type hgOp struct {
	// delete | truncate
	Op string `json:"op"`
	// For `delete`.
	Mint        int64  `json:"mint,omitempty"`
	Maxt        int64  `json:"maxt,omitempty"`
	MatcherKind string `json:"matcherKind,omitempty"`
	// For `truncate`.
	TruncateMint int64 `json:"truncateMint,omitempty"`
}

type hgIn struct {
	ChunkRange      int64        `json:"chunkRange"`
	SamplesPerChunk int          `json:"samplesPerChunk"`
	Phases          [][]hrSample `json:"phases"`
	Ops             []hgOp       `json:"ops"`
	// A WAL, so `Delete`'s tombstone record is committed as bytes.
	WithWAL bool `json:"withWAL,omitempty"`
}

type hgTombstone struct {
	Ref       uint64    `json:"ref"`
	Intervals [][]int64 `json:"intervals"`
}

type hgSeriesOut struct {
	Ref    uint64            `json:"ref"`
	Labels map[string]string `json:"labels"`
	Chunks []hrChunkMeta     `json:"chunks"`
}

type hgState struct {
	MinTime    int64  `json:"minTime"`
	MaxTime    int64  `json:"maxTime"`
	NumSeries  uint64 `json:"numSeries"`
	NumStale   uint64 `json:"numStale"`
	Appendable int64  `json:"appendableMinValidTime"`
	AppendOK   bool   `json:"appendableOK"`
	// SORTED by ref, because `MemTombstones.Iter` ranges a Go map.
	Tombstones     []hgTombstone `json:"tombstones"`
	TombstoneTotal uint64        `json:"tombstoneTotal"`
	Series         []hgSeriesOut `json:"series"`
	// The RAW postings refs, before `Series` is asked about them — a ref the GC failed to remove is invisible
	// in `Series` (which skips it) but not here.
	AllPostings []uint64 `json:"allPostings"`
	// `Postings(name, value)` for the label pairs the appended series use, which is what `affected` decides.
	LabelPostings   [][]uint64 `json:"labelPostings"`
	ChunkDirEntries []string   `json:"chunkDirEntries"`
	Err             string     `json:"err"`
}

type hgOut struct {
	// One state per op, then the final one.
	States   []hgState   `json:"states"`
	WALFiles []haFileOut `json:"walFiles"`
	CloseErr string      `json:"closeErr"`
}

func genHeadGC(e *emitter) {
	n := 0
	emit := func(name string, in hgIn) {
		dir, err := os.MkdirTemp("", "promoracle-hgc")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		opts := tsdb.DefaultHeadOptions()
		opts.ChunkDirRoot = dir
		opts.ChunkRange = in.ChunkRange
		opts.SamplesPerChunk = in.SamplesPerChunk

		var wal *wlog.WL
		if in.WithWAL {
			wal, err = wlog.New(nil, nil, filepath.Join(dir, "wal"), compression.None)
			if err != nil {
				panic(err)
			}
		}

		h, err := tsdb.NewHead(nil, nil, wal, nil, opts, nil)
		if err != nil {
			panic(err)
		}

		out := hgOut{States: []hgState{}, WALFiles: []haFileOut{}}

		for _, phase := range in.Phases {
			app := h.Appender(context.Background())
			for _, s := range phase {
				if _, err := app.Append(0, labels.FromMap(s.Labels), s.T, fbitsToFloat(s.V)); err != nil {
					panic(err)
				}
			}
			if err := app.Commit(); err != nil {
				panic(err)
			}
		}

		snapshot := func(opErr string) hgState {
			st := hgState{
				MinTime: h.MinTime(), MaxTime: h.MaxTime(), NumSeries: h.NumSeries(),
				NumStale: h.NumStaleSeries(), Tombstones: []hgTombstone{},
				Series: []hgSeriesOut{}, AllPostings: []uint64{}, LabelPostings: [][]uint64{},
				ChunkDirEntries: []string{}, Err: opErr,
			}
			st.Appendable, st.AppendOK = h.AppendableMinValidTime()

			tr, err := h.Tombstones()
			if err == nil {
				_ = tr.Iter(func(ref storage.SeriesRef, ivs tombstones.Intervals) error {
					t := hgTombstone{Ref: uint64(ref), Intervals: [][]int64{}}
					for _, iv := range ivs {
						t.Intervals = append(t.Intervals, []int64{iv.Mint, iv.Maxt})
					}
					st.Tombstones = append(st.Tombstones, t)
					return nil
				})
				st.TombstoneTotal = tr.Total()
			}
			// `Iter` ranges a Go map, so sort before committing (exception 11's situation).
			sort.Slice(st.Tombstones, func(i, j int) bool { return st.Tombstones[i].Ref < st.Tombstones[j].Ref })

			ir, err := h.Index()
			if err == nil {
				allName, allValue := index.AllPostingsKey()
				p, err := ir.Postings(context.Background(), allName, allValue)
				if err == nil {
					refs, _ := index.ExpandPostings(ir.SortedPostings(p))
					for _, r := range refs {
						st.AllPostings = append(st.AllPostings, uint64(r))
					}
					for _, q := range [][2]string{
						{"__name__", "m1"}, {"__name__", "m2"}, {"job", "a"}, {"job", "b"},
					} {
						lp, err := ir.Postings(context.Background(), q[0], q[1])
						out := []uint64{}
						if err == nil {
							lrefs, _ := index.ExpandPostings(lp)
							for _, r := range lrefs {
								out = append(out, uint64(r))
							}
						}
						st.LabelPostings = append(st.LabelPostings, out)
					}
					for _, r := range refs {
						var builder labels.ScratchBuilder
						var chks []chunks.Meta
						if err := ir.Series(r, &builder, &chks); err != nil {
							continue
						}
						so := hgSeriesOut{
							Ref: uint64(r), Labels: builder.Labels().Map(), Chunks: []hrChunkMeta{},
						}
						for _, c := range chks {
							so.Chunks = append(so.Chunks, hrChunkMeta{
								Ref: uint64(c.Ref), MinTime: c.MinTime, MaxTime: c.MaxTime,
							})
						}
						st.Series = append(st.Series, so)
					}
				}
				_ = ir.Close()
			}

			entries, err := os.ReadDir(filepath.Join(dir, "chunks_head"))
			if err == nil {
				for _, ent := range entries {
					st.ChunkDirEntries = append(st.ChunkDirEntries, ent.Name())
				}
			}
			return st
		}

		for _, op := range in.Ops {
			var opErr string
			switch op.Op {
			case "delete":
				if err := h.Delete(context.Background(), op.Mint, op.Maxt, hrMatchers(op.MatcherKind)...); err != nil {
					opErr = err.Error()
				}
			case "truncate":
				if err := h.Truncate(op.TruncateMint); err != nil {
					opErr = scrubDir(err.Error(), dir)
				}
			default:
				panic("unknown head gc op " + op.Op)
			}
			out.States = append(out.States, snapshot(opErr))
		}
		out.States = append(out.States, snapshot(""))

		if err := h.Close(); err != nil {
			out.CloseErr = scrubDir(err.Error(), dir)
		}
		if in.WithWAL {
			out.WALFiles = readDirRLE(filepath.Join(dir, "wal"))
		}

		e.emit(fmt.Sprintf("hgc/%03d/%s", n, name), in, out)
		n++
	}

	const twoHours = int64(2 * 60 * 60 * 1000)
	sample := func(name, job string, t int64, v float64) hrSample {
		return hrSample{Labels: map[string]string{"__name__": name, "job": job}, T: t, V: fbits(v)}
	}
	del := func(mint, maxt int64, kind string) hgOp {
		return hgOp{Op: "delete", Mint: mint, Maxt: maxt, MatcherKind: kind}
	}
	trunc := func(mint int64) hgOp { return hgOp{Op: "truncate", TruncateMint: mint} }

	// A series with three chunks, and a second series with one — in ONE phase, because a second appender's
	// `appendableMinValidTime` has already moved to `maxTime - chunkRange/2` and would reject the older
	// timestamps as out of bounds. (That is the moving floor `head/append` pins; here it is a constraint on how
	// the corpus can be built.)
	both := []hrSample{}
	for i := 0; i < 12; i++ {
		both = append(both, sample("m1", "a", int64(i)*1000, float64(i)))
		if i < 4 {
			both = append(both, sample("m2", "b", int64(i)*1000, float64(100+i)))
		}
	}
	twoSeries := [][]hrSample{both}

	base := func(ops ...hgOp) hgIn {
		return hgIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: twoSeries, Ops: ops}
	}

	// --- Truncate on an empty head ------------------------------------------------------------------

	// No appends: `truncateMemory` runs, moves both bounds, and skips the GC. This is `db.go` seeding
	// `minValidTime` before any sample exists.
	emit("truncate-uninitialised", hgIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: [][]hrSample{}, Ops: []hgOp{trunc(5000)}})

	// And twice, so the second call sees an initialised head whose MinTime is already at the point.
	emit("truncate-uninitialised-twice", hgIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Phases: [][]hrSample{},
		Ops: []hgOp{trunc(5000), trunc(5000), trunc(1000)}})

	// --- Truncate with data ------------------------------------------------------------------------

	// Below everything: the early return, because MinTime is already >= mint.
	emit("truncate-below-data", base(trunc(-1000)))
	// Inside the first chunk: no chunk can be dropped (its maxTime is above mint), so the GC keeps
	// everything and `actualMint` pulls MinTime back up to the real minimum.
	emit("truncate-inside-first-chunk", base(trunc(2000)))
	// Past the first chunk: it goes, and `firstChunkID` advances — the surviving refs must not shift.
	emit("truncate-drops-first-chunk", base(trunc(4000)))
	// Past everything one series holds: that series is DELETED, which removes it from the postings.
	emit("truncate-deletes-a-series", base(trunc(8000)))
	// Past everything: both series go, and `actualMint` falls back to the requested mint.
	emit("truncate-deletes-everything", base(trunc(1_000_000)))
	// Two truncations in a row.
	emit("truncate-twice", base(trunc(4000), trunc(8000)))

	// --- A stale series the GC deletes -------------------------------------------------------------

	// `numStaleSeries` counts SERIES and only the GC decrements it, so the case needs a stale series that the
	// truncation then removes entirely.
	staleV := math.Float64frombits(value.StaleNaN)
	stalePhase := []hrSample{}
	for i := 0; i < 4; i++ {
		stalePhase = append(stalePhase, sample("m1", "a", int64(i)*1000, float64(i)))
		stalePhase = append(stalePhase, sample("m2", "b", int64(i)*1000, float64(i)))
	}
	stalePhase = append(stalePhase, sample("m2", "b", 4000, staleV))
	emit("truncate-deletes-a-stale-series", hgIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{stalePhase},
		Ops: []hgOp{trunc(10_000)}})

	// --- The appendable-window clamp ---------------------------------------------------------------

	// `truncateSeriesAndChunkDiskMapper` moves `minTime` up to the GC's `actualMint` — but NOT past
	// `appendableMinValidTime()`. Distinguishing the two branches needs a surviving series whose minimum is
	// ABOVE that floor: with samples at 0-1000 and 20000-21000 and a chunk range of 4000, a truncation at
	// 15000 leaves `actualMint` at 20000 while the floor is 19000, so the clamped answer (19000) and the
	// unclamped one (20000) differ.
	gapPhase := []hrSample{}
	for i := 0; i < 2; i++ {
		gapPhase = append(gapPhase, sample("m1", "a", int64(i)*1000, float64(i)))
	}
	for i := 20; i < 22; i++ {
		gapPhase = append(gapPhase, sample("m1", "a", int64(i)*1000, float64(i)))
	}
	emit("truncate-clamps-to-the-appendable-window", hgIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{gapPhase},
		Ops: []hgOp{trunc(15_000)}})

	// --- Delete ------------------------------------------------------------------------------------

	// A window inside the data, matching one series.
	emit("delete-one-series", base(del(2000, 5000, "eq")))
	// The same window, matching both.
	emit("delete-all-series", base(del(2000, 5000, "all")))
	// A window the head does not cover: the clamp pulls it in, so the tombstone is the head's range.
	emit("delete-clamped-to-head", base(del(math.MinInt64, math.MaxInt64, "all")))
	// A window ENTIRELY below the data: after clamping it is [MinTime, MinTime], so a tombstone still lands.
	emit("delete-below-data", base(del(math.MinInt64, -1, "all")))
	// A window entirely above it.
	emit("delete-above-data", base(del(1_000_000, 2_000_000, "all")))
	// Two deletes that overlap: `Intervals.Add` must merge them into one.
	emit("delete-overlapping-merges", base(del(1000, 3000, "eq"), del(2000, 5000, "eq")))
	// Two that do not touch: two intervals for the same series.
	emit("delete-disjoint-keeps-two", base(del(1000, 2000, "eq"), del(6000, 7000, "eq")))
	// A matcher that selects nothing.
	emit("delete-matches-nothing", base(del(1000, 5000, "neq")))

	// --- Delete then truncate ----------------------------------------------------------------------

	// `gc` prunes tombstones for deleted series AND everything elapsed, so a truncation past a tombstone
	// removes it.
	emit("delete-then-truncate-prunes-tombstones", base(
		del(1000, 3000, "all"), trunc(4000), trunc(8000)))

	// A tombstone that survives the truncation because it extends past it.
	emit("delete-then-truncate-keeps-tombstone", base(
		del(1000, 9000, "eq"), trunc(4000)))

	// --- The WAL record Delete writes --------------------------------------------------------------

	withWAL := base(del(2000, 5000, "all"))
	withWAL.WithWAL = true
	emit("delete-logs-tombstones", withWAL)

	// A delete that matches nothing STILL logs — an empty tombstones record.
	emptyWAL := base(del(1000, 5000, "neq"))
	emptyWAL.WithWAL = true
	emit("delete-nothing-still-logs", emptyWAL)
}
