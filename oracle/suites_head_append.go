package main

// Differential coverage for the Head's FLOAT append path — `Appender`, `Append`, `Commit`, `Rollback` — driven
// through the real `tsdb.Head`, and asserted in the three places a committed sample lands.
//
// ## The three observables, and why all three are needed
//
//  1. **The accessors**: `MinTime`/`MaxTime` (so `updateMinMaxTime`'s two independent halves are visible),
//     `NumSeries`, `NumStaleSeries` and `AppendableMinValidTime`.
//  2. **The WAL bytes**, byte for byte. This is what pins `log()`: the series record, the sample record, their
//     ORDER, and the fact that a rollback logs nothing at all.
//  3. **The chunk files**, after `Close` m-maps the tail. This is what pins the hand-off from `commitFloats`
//     down through `memSeries.append` into `ChunkDiskMapper`.
//
// A corpus with only (1) would pass on a port that never wrote a byte; one with only (2) would pass on a port
// whose chunks were empty. §7f(d) pinned the series-level chunk arithmetic — this suite pins that the Head
// drives it with the right arguments.
//
// ## The shape
//
// A program of appender transactions. Each transaction opens an appender, performs a list of appends (some by
// label set, some by a REF returned earlier, which is the path `GetRef` exists for), and then commits or rolls
// back. Per-append the corpus commits the returned ref and the error; per transaction, the commit error; at the
// end, the accessors, the WAL and the chunk files.
//
// Two details the cases are built around:
//
//   * The FIRST appender of a fresh head is an `initAppender`, and it is a different code path: `initTime`
//     establishes the time window from the first sample. A case that appends nothing at all through it, then
//     commits, is what proves the no-op branch.
//   * `appendableMinValidTime` MOVES as `maxTime` grows (`maxTime - chunkRange/2`), so a second transaction's
//     bounds depend on the first's. That is why this has to be a program rather than a list of appends: it is
//     the only way to reach `ErrOutOfBounds` from a sample that would have been fine a moment earlier.

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/wlog"
	"github.com/prometheus/prometheus/util/compression"
)

type haAppend struct {
	// Labels for the sample. Empty means "use the ref from a previous append in this program".
	Labels map[string]string `json:"labels,omitempty"`
	// Labels as a flat name/value list, for the one thing a map cannot express: a DUPLICATE label name, which
	// `labels.FromStrings` will happily build and `getOrCreate` then rejects.
	LabelPairs []string `json:"labelPairs,omitempty"`
	// 1-based index into the refs collected so far; 0 means "pass ref 0", i.e. look the series up by labels.
	UseRef int    `json:"useRef,omitempty"`
	T      int64  `json:"t"`
	V      string `json:"v"`
	// `AppendSTZeroSample` instead of `Append`, with this start timestamp.
	STZero *int64 `json:"stZero,omitempty"`
	// `SetOptions(&storage.AppendOptions{DiscardOutOfOrder: true})` before this append.
	DiscardOOO bool `json:"discardOOO,omitempty"`
	// `GetRef` for these labels instead of an append.
	GetRef bool `json:"getRef,omitempty"`
}

type haTxn struct {
	Appends []haAppend `json:"appends"`
	// "commit" | "rollback" | "commit,commit" | "commit,rollback" — the doubled forms reach ErrAppenderClosed.
	Finish string `json:"finish"`
}

type haIn struct {
	ChunkRange      int64 `json:"chunkRange"`
	SamplesPerChunk int   `json:"samplesPerChunk"`
	UseXOR2         bool  `json:"useXOR2,omitempty"`
	StoreST         bool  `json:"storeST,omitempty"`
	OOOTimeWindow   int64 `json:"oooTimeWindow,omitempty"`
	// A WAL is created unless this is set: most cases want the bytes.
	NoWAL bool `json:"noWAL,omitempty"`
	// `SetMinValidTime` before the first transaction, which is what `Init` would have done.
	MinValidTime int64 `json:"minValidTime,omitempty"`
	// Open EVERY transaction's appender before appending anything, so two appenders overlap. That is what makes
	// `commitFloats`' second `appendable` check observable: the first transaction's commit can turn the second
	// transaction's already-accepted sample into a duplicate.
	Interleaved bool    `json:"interleaved,omitempty"`
	Txns        []haTxn `json:"txns"`
}

type haAppendOut struct {
	Ref uint64 `json:"ref"`
	Err string `json:"err"`
	// For `getRef`.
	RefLabels map[string]string `json:"refLabels,omitempty"`
}

type haTxnOut struct {
	Appends   []haAppendOut `json:"appends"`
	FinishErr []string      `json:"finishErr"`
	// The head's answers immediately after this transaction, so a rollback's non-effect is visible.
	MinTime   int64  `json:"minTime"`
	MaxTime   int64  `json:"maxTime"`
	NumSeries uint64 `json:"numSeries"`
	NumStale  uint64 `json:"numStale"`
}

type haFileOut struct {
	Name  string `json:"name"`
	Size  int    `json:"size"`
	Bytes string `json:"bytes"`
}

type haOut struct {
	Txns []haTxnOut `json:"txns"`

	MinTime                int64  `json:"minTime"`
	MaxTime                int64  `json:"maxTime"`
	NumSeries              uint64 `json:"numSeries"`
	NumStale               uint64 `json:"numStale"`
	AppendableMinValidTime int64  `json:"appendableMinValidTime"`
	AppendableOK           bool   `json:"appendableOK"`
	Size                   int64  `json:"size"`

	// After Close, which m-maps the tail and flushes.
	WALFiles   []haFileOut `json:"walFiles"`
	ChunkFiles []haFileOut `json:"chunkFiles"`
	CloseErr   string      `json:"closeErr"`
}

func genHeadAppend(e *emitter) {
	n := 0
	emit := func(name string, in haIn) {
		dir, err := os.MkdirTemp("", "promoracle-happ")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		opts := tsdb.DefaultHeadOptions()
		opts.ChunkDirRoot = dir
		opts.ChunkRange = in.ChunkRange
		opts.SamplesPerChunk = in.SamplesPerChunk
		opts.OutOfOrderTimeWindow.Store(in.OOOTimeWindow)
		opts.EnableSTStorage.Store(in.StoreST)
		if in.UseXOR2 {
			opts.FloatChunkEncoding.Store(uint32(chunkenc.EncXOR2))
		}

		var wal *wlog.WL
		if !in.NoWAL {
			wal, err = wlog.New(nil, nil, filepath.Join(dir, "wal"), compression.None)
			if err != nil {
				panic(err)
			}
		}

		h, err := tsdb.NewHead(nil, nil, wal, nil, opts, nil)
		if err != nil {
			panic(err)
		}
		h.SetMinValidTime(in.MinValidTime)

		out := haOut{Txns: []haTxnOut{}, WALFiles: []haFileOut{}, ChunkFiles: []haFileOut{}}

		// With `Interleaved`, all appenders are opened up front (before any append), which is what overlaps
		// them. Otherwise each is opened when its transaction runs.
		var openApps []storage.Appender
		if in.Interleaved {
			for range in.Txns {
				openApps = append(openApps, h.Appender(context.Background()))
			}
		}

		var refs []storage.SeriesRef
		for ti, txn := range in.Txns {
			var app storage.Appender
			if in.Interleaved {
				app = openApps[ti]
			} else {
				app = h.Appender(context.Background())
			}
			to := haTxnOut{Appends: []haAppendOut{}, FinishErr: []string{}}

			for _, a := range txn.Appends {
				lset := labels.FromMap(a.Labels)
				if len(a.LabelPairs) > 0 {
					lset = labels.FromStrings(a.LabelPairs...)
				}
				var ref storage.SeriesRef
				if a.UseRef > 0 && a.UseRef <= len(refs) {
					ref = refs[a.UseRef-1]
				}

				if a.GetRef {
					ao := haAppendOut{}
					if g, ok := app.(storage.GetRef); ok {
						r, ls := g.GetRef(lset, lset.Hash())
						ao.Ref = uint64(r)
						ao.RefLabels = ls.Map()
					}
					to.Appends = append(to.Appends, ao)
					continue
				}

				if a.DiscardOOO {
					app.SetOptions(&storage.AppendOptions{DiscardOutOfOrder: true})
				}

				var got storage.SeriesRef
				var aerr error
				if a.STZero != nil {
					got, aerr = app.AppendSTZeroSample(ref, lset, a.T, *a.STZero)
				} else {
					got, aerr = app.Append(ref, lset, a.T, fbitsToFloat(a.V))
				}
				ao := haAppendOut{Ref: uint64(got)}
				if aerr != nil {
					ao.Err = aerr.Error()
				}
				to.Appends = append(to.Appends, ao)
				if got != 0 {
					refs = append(refs, got)
				}
			}

			for _, step := range splitFinish(txn.Finish) {
				var ferr error
				switch step {
				case "commit":
					ferr = app.Commit()
				case "rollback":
					ferr = app.Rollback()
				default:
					panic("unknown finish step " + step)
				}
				if ferr != nil {
					to.FinishErr = append(to.FinishErr, ferr.Error())
				} else {
					to.FinishErr = append(to.FinishErr, "")
				}
			}

			to.MinTime, to.MaxTime = h.MinTime(), h.MaxTime()
			to.NumSeries, to.NumStale = h.NumSeries(), h.NumStaleSeries()
			out.Txns = append(out.Txns, to)
		}

		out.MinTime, out.MaxTime = h.MinTime(), h.MaxTime()
		out.NumSeries, out.NumStale = h.NumSeries(), h.NumStaleSeries()
		out.AppendableMinValidTime, out.AppendableOK = h.AppendableMinValidTime()
		out.Size = h.Size()

		if err := h.Close(); err != nil {
			out.CloseErr = scrubDir(err.Error(), dir)
		}

		out.WALFiles = readDirRLE(filepath.Join(dir, "wal"))
		out.ChunkFiles = readDirRLE(filepath.Join(dir, "chunks_head"))

		e.emit(fmt.Sprintf("happ/%03d/%s", n, name), in, out)
		n++
	}

	// --- helpers ------------------------------------------------------------------------------------

	const twoHours = int64(2 * 60 * 60 * 1000)
	base := func(txns ...haTxn) haIn {
		return haIn{ChunkRange: twoHours, SamplesPerChunk: 120, Txns: txns}
	}
	ap := func(name string, t int64, v float64) haAppend {
		return haAppend{Labels: map[string]string{"__name__": name}, T: t, V: fbits(v)}
	}
	apRef := func(ref int, t int64, v float64) haAppend {
		return haAppend{UseRef: ref, T: t, V: fbits(v)}
	}
	commit := func(as ...haAppend) haTxn { return haTxn{Appends: as, Finish: "commit"} }
	rollback := func(as ...haAppend) haTxn { return haTxn{Appends: as, Finish: "rollback"} }

	// --- The init appender --------------------------------------------------------------------------

	// An appender that appends NOTHING and commits: the init appender's `a.app == nil` branch, which must
	// leave the head uninitialised.
	emit("init-appender-empty-commit", base(commit()))
	emit("init-appender-empty-rollback", base(rollback()))

	// The first sample establishes the window through `initTime`, and both bounds become its timestamp.
	emit("first-sample", base(commit(ap("a", 1000, 1))))

	// A second transaction then goes through the REAL appender, whose minValidTime is derived from maxTime.
	emit("two-transactions", base(
		commit(ap("a", 1000, 1)),
		commit(ap("a", 2000, 2))))

	// --- Series creation and refs -------------------------------------------------------------------

	// The ref returned by the first append is usable in the second, and skips the hash lookup.
	emit("append-by-ref", base(
		commit(ap("a", 1000, 1)),
		commit(apRef(1, 2000, 2), apRef(1, 3000, 3))))

	// A ref that no longer resolves falls back to the label set — and with no labels either, `getOrCreate`
	// rejects the empty label set.
	emit("unknown-ref-no-labels", base(
		commit(haAppend{UseRef: 0, T: 1000, V: fbits(1)})))

	// `WithoutEmpty` runs BEFORE the empty check, so a label set of only empty values is an empty labelset.
	emit("only-empty-labels", base(commit(
		haAppend{Labels: map[string]string{"foo": ""}, T: 1000, V: fbits(1)})))

	// Empty VALUES are dropped, and the series keeps the rest.
	emit("empty-value-dropped", base(commit(
		haAppend{Labels: map[string]string{"__name__": "a", "foo": ""}, T: 1000, V: fbits(1)})))

	// Several series in one transaction: the WAL's series record carries them all, in creation order.
	emit("three-series-one-txn", base(commit(
		ap("a", 1000, 1), ap("b", 1000, 2), ap("c", 1000, 3))))

	// `GetRef` before and after the series exists.
	emit("getref", base(
		haTxn{Appends: []haAppend{
			{Labels: map[string]string{"__name__": "a"}, GetRef: true},
			ap("a", 1000, 1),
			{Labels: map[string]string{"__name__": "a"}, GetRef: true},
		}, Finish: "commit"},
		haTxn{Appends: []haAppend{
			{Labels: map[string]string{"__name__": "a"}, GetRef: true},
			{Labels: map[string]string{"__name__": "zzz"}, GetRef: true},
		}, Finish: "commit"}))

	// --- Rejections ---------------------------------------------------------------------------------

	// Out of bounds: the fast-fail in `Append`, before any series lookup — so NO series is created.
	oob := base(commit(ap("a", 1000, 1)), commit(ap("b", -100, 2)))
	oob.MinValidTime = 500
	emit("out-of-bounds-creates-no-series", oob)

	// Out of order against the series' own maxTime.
	emit("out-of-order", base(
		commit(ap("a", 2000, 1)),
		commit(ap("a", 1000, 2))))

	// The duplicate rules from `appendable`, now through the appender: same value is accepted (and silently
	// dropped at commit), a different value is an error.
	emit("duplicate-same-value", base(
		commit(ap("a", 1000, 1)),
		commit(ap("a", 1000, 1))))
	emit("duplicate-different-value", base(
		commit(ap("a", 1000, 1)),
		commit(ap("a", 1000, 2))))

	// With OOO enabled, a sample inside the window is accepted by `Append` — and `DiscardOutOfOrder` is what
	// turns it back into an error. (The OOO commit path itself is Phase 10; this pins the Append-side verdict.)
	ooo := base(
		commit(ap("a", 10_000, 1)),
		commit(haAppend{Labels: map[string]string{"__name__": "a"}, T: 9_500, V: fbits(2), DiscardOOO: true}))
	ooo.OOOTimeWindow = 5_000
	emit("ooo-discarded-by-hint", ooo)

	// Too old, with OOO enabled but outside the window.
	tooOld := base(
		commit(ap("a", 100_000, 1)),
		commit(ap("a", 1_000, 2)))
	tooOld.OOOTimeWindow = 5_000
	emit("too-old", tooOld)

	// A duplicate label NAME cannot come from labels.FromMap, so this case is the empty-labelset sibling: an
	// appender that is closed twice.
	emit("commit-twice", base(haTxn{Appends: []haAppend{ap("a", 1000, 1)}, Finish: "commit,commit"}))
	emit("commit-then-rollback", base(haTxn{Appends: []haAppend{ap("a", 1000, 1)}, Finish: "commit,rollback"}))
	emit("rollback-twice", base(haTxn{Appends: []haAppend{ap("a", 1000, 1)}, Finish: "rollback,rollback"}))

	// --- Rollback -----------------------------------------------------------------------------------

	// A rollback logs NOTHING and moves no bound — but the series it created stays in the index, which is why
	// `NumSeries` is 1 afterwards.
	emit("rollback-keeps-series", base(rollback(ap("a", 1000, 1))))

	// A rollback after a successful transaction: the first transaction's samples stay.
	emit("rollback-after-commit", base(
		commit(ap("a", 1000, 1)),
		rollback(ap("a", 2000, 2)),
		commit(ap("a", 3000, 3))))

	// --- Staleness ----------------------------------------------------------------------------------

	// `numStaleSeries` counts SERIES, not samples: it moves on the transition into and out of staleness.
	staleV := math.Float64frombits(value.StaleNaN)
	emit("stale-transitions", base(
		commit(ap("a", 1000, 1)),
		commit(ap("a", 2000, staleV)),
		commit(ap("a", 3000, staleV)),
		commit(ap("a", 4000, 5))))

	// A series whose FIRST sample is stale.
	emit("stale-first-sample", base(commit(ap("a", 1000, staleV))))

	// --- Chunks -------------------------------------------------------------------------------------

	// Enough samples to cut chunks, so `onChunkCreated`, `mmapHeadChunks` (via Close) and the chunk files all
	// take part. chunkRange 4000 with 1s samples cuts every 4 samples.
	manyOps := []haAppend{}
	for i := 0; i < 12; i++ {
		manyOps = append(manyOps, ap("a", int64(i)*1000, float64(i)))
	}
	emit("chunks-cut-and-mmapped", haIn{
		ChunkRange: 4000, SamplesPerChunk: 120,
		Txns: []haTxn{{Appends: manyOps, Finish: "commit"}}})

	// The same, one sample per transaction, so every append sees a head whose maxTime has moved — and
	// `appendableMinValidTime` moves with it.
	perTxn := []haTxn{}
	for i := 0; i < 12; i++ {
		perTxn = append(perTxn, commit(ap("a", int64(i)*1000, float64(i))))
	}
	emit("one-sample-per-transaction", haIn{
		ChunkRange: 4000, SamplesPerChunk: 120, Txns: perTxn})

	// XOR2, which is what `promqltest` configures (quirk 36) — the chunk bytes differ and so does the WAL,
	// because `EnableSTStorage` selects the V2 sample record.
	xor2 := haIn{ChunkRange: 4000, SamplesPerChunk: 120, UseXOR2: true, StoreST: true,
		Txns: []haTxn{{Appends: manyOps, Finish: "commit"}}}
	emit("xor2-and-st-storage", xor2)

	// `AppendSTZeroSample`: the synthetic zero, its `st >= t` rejection, and its OOO verdict.
	st := int64(500)
	stLate := int64(2000)
	emit("st-zero-sample", base(haTxn{Appends: []haAppend{
		{Labels: map[string]string{"__name__": "a"}, T: 1000, V: fbits(0), STZero: &st},
		ap("a", 1000, 7),
	}, Finish: "commit"}))
	emit("st-zero-newer-than-sample", base(haTxn{Appends: []haAppend{
		{Labels: map[string]string{"__name__": "a"}, T: 1000, V: fbits(0), STZero: &stLate},
	}, Finish: "commit"}))

	// --- The compaction-window boundary, and the OOO fast fail --------------------------------------

	// `appendableMinValidTime` is `max(maxTime - chunkRange/2, minValidTime)`, so with maxTime at 11_000 and a
	// chunk range of 4_000 the appender's floor is 9_000 — well above `minValidTime`. A sample at 8_000 is
	// therefore out of bounds even though the head holds older samples than that.
	windowOps := []haTxn{}
	for i := 0; i <= 11; i++ {
		windowOps = append(windowOps, commit(ap("a", int64(i)*1000, float64(i))))
	}
	windowOps = append(windowOps, commit(ap("a", 8_000, 99)))
	emit("compaction-window-floor", haIn{ChunkRange: 4000, SamplesPerChunk: 120, Txns: windowOps})

	// With OOO ENABLED the fast fail is skipped, so a sample below `minValidTime` reaches `appendable` and is
	// classified there — as OOO-accepted inside the window rather than as out of bounds.
	fastFail := haIn{ChunkRange: twoHours, SamplesPerChunk: 120, OOOTimeWindow: 5_000, MinValidTime: 5_000,
		Txns: []haTxn{commit(ap("a", 10_000, 1)), commit(ap("a", 4_000, 2))}}
	emit("ooo-skips-the-out-of-bounds-fast-fail", fastFail)

	// `headMaxt` is a SNAPSHOT of the head's maxTime, and it appears in exactly one decision: the OOO window's
	// lower bound, `t >= headMaxt - oooTimeWindow`. Distinguishing it from any other bound needs a head whose
	// minTime is far below its maxTime and a sample just OUTSIDE the real window — with maxTime at 100_000 and
	// a window of 5_000, a sample at 90_000 is too old, while the same sample measured against minTime (1_000)
	// would look perfectly in-window.
	headMaxtCase := haIn{ChunkRange: twoHours, SamplesPerChunk: 120, OOOTimeWindow: 5_000,
		Txns: []haTxn{
			commit(ap("a", 1_000, 1)),
			commit(ap("a", 100_000, 2)),
			commit(ap("a", 90_000, 3)),
			commit(ap("a", 97_000, 4)),
		}}
	emit("ooo-window-is-measured-from-headMaxt", headMaxtCase)

	// --- A duplicate label NAME, which only a pair list can build -----------------------------------

	emit("duplicate-label-name", base(commit(haAppend{
		LabelPairs: []string{"__name__", "a", "dup", "1", "dup", "2"}, T: 1000, V: fbits(1)})))

	// --- AppendSTZeroSample's two boundaries --------------------------------------------------------

	stEqual := int64(1000)
	emit("st-zero-equal-to-sample", base(haTxn{Appends: []haAppend{
		{Labels: map[string]string{"__name__": "a"}, T: 1000, V: fbits(0), STZero: &stEqual},
	}, Finish: "commit"}))

	// An ST that is out of order for the series: the series already has a sample at 2000, so an ST of 1500 is
	// OOO — and the error comes back WITH the series ref.
	stOOO := int64(1500)
	emit("st-zero-out-of-order", haIn{ChunkRange: twoHours, SamplesPerChunk: 120, OOOTimeWindow: 5_000,
		Txns: []haTxn{
			commit(ap("a", 2000, 1)),
			{Appends: []haAppend{
				{Labels: map[string]string{"__name__": "a"}, T: 3000, V: fbits(0), STZero: &stOOO},
			}, Finish: "commit"},
		}})

	// --- Two appenders overlapping ------------------------------------------------------------------

	// The second appender accepts its sample (the head has nothing at that timestamp yet), and by the time it
	// commits the first has made it a duplicate with a DIFFERENT value — which only `commitFloats`' second
	// `appendable` check can notice.
	emit("interleaved-duplicate-becomes-error", haIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Interleaved: true,
		Txns: []haTxn{commit(ap("a", 1000, 1)), commit(ap("a", 1000, 2))}})

	// The same, with an out-of-order sample rather than a duplicate.
	emit("interleaved-out-of-order-at-commit", haIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Interleaved: true,
		Txns: []haTxn{commit(ap("a", 5000, 1)), commit(ap("a", 3000, 2))}})

	// Interleaved, with the SECOND appender committing samples the first one's series created.
	emit("interleaved-two-series", haIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Interleaved: true,
		Txns: []haTxn{
			commit(ap("a", 1000, 1), ap("b", 1000, 2)),
			commit(ap("a", 2000, 3), ap("b", 2000, 4)),
		}})

	// --- Several series, enough samples to cut chunks in each ---------------------------------------

	// Two series and twelve samples each: a case where committing every sample to the wrong series of the
	// batch would still produce the same WAL but different CHUNK files.
	twoSeries := []haAppend{}
	for i := 0; i < 12; i++ {
		twoSeries = append(twoSeries, ap("a", int64(i)*1000, float64(i)))
		twoSeries = append(twoSeries, ap("b", int64(i)*1000, float64(100+i)))
	}
	emit("two-series-many-chunks", haIn{ChunkRange: 4000, SamplesPerChunk: 120,
		Txns: []haTxn{{Appends: twoSeries, Finish: "commit"}}})

	// --- No WAL -------------------------------------------------------------------------------------

	// `log()` is a no-op with a nil WAL, and everything else still happens.
	noWAL := base(commit(ap("a", 1000, 1)), commit(ap("a", 2000, 2)))
	noWAL.NoWAL = true
	emit("no-wal", noWAL)

	// --- Many series, several transactions ----------------------------------------------------------

	big := []haTxn{}
	for txn := 0; txn < 3; txn++ {
		as := []haAppend{}
		for s := 0; s < 4; s++ {
			as = append(as, ap(fmt.Sprintf("series_%d", s), int64(txn)*15_000, float64(txn*10+s)))
		}
		big = append(big, commit(as...))
	}
	emit("four-series-three-transactions", haIn{
		ChunkRange: twoHours, SamplesPerChunk: 120, Txns: big})
}

// splitFinish turns "commit,rollback" into its steps.
func splitFinish(s string) []string {
	out := []string{}
	cur := ""
	for _, c := range s {
		if c == ',' {
			out = append(out, cur)
			cur = ""
			continue
		}
		cur += string(c)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

func fbitsToFloat(s string) float64 {
	var u uint64
	if _, err := fmt.Sscanf(s, "%016x", &u); err != nil {
		panic("bad float bits " + s)
	}
	return math.Float64frombits(u)
}

// readDirRLE lists a directory as RLE-hex files, sorted by name. Used for both the WAL and the chunk files,
// whose pre-allocated regions are long runs of zeros (quirks 176, 182).
func readDirRLE(dir string) []haFileOut {
	out := []haFileOut{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, ent.Name()))
		if err != nil {
			continue
		}
		out = append(out, haFileOut{Name: ent.Name(), Size: len(b), Bytes: rleHex(b)})
	}
	return out
}
