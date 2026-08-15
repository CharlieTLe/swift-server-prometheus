package main

// Differential coverage for `memSeries`' in-order chunk state — the series-level half of the Head's write
// path, and the last prerequisite before `NewHead`.
//
// ## Where the Go side comes from
//
// Every type and method involved is unexported in `package tsdb`, and nothing on `Head`'s exported surface
// reaches them until `head_read.go`. So this suite drives `oracle/probe/headmemseries`, a LIFT of that code
// into its own package — read that package's header for the five deltas and why each one has no counterpart
// in the port either. §7f(a) and §7f(b) used throwaway probes for the same reason; committing this one means
// `verify-fixtures.sh` re-runs it on every upstream-pin bump.
//
// ## The shape: a program, with snapshots
//
// A case is `chunkOpts` plus a list of operations against one series. Chunk-cut behaviour is entirely a
// function of history — `nextAt` was set two cuts ago, the size rule reads the bytes accumulated so far, the
// sample rules count what is in the current chunk — so a per-call corpus could not express any of it.
//
// The committed output carries the chunk BYTES, which is what makes this differential rather than structural:
// a port could get every count and boundary right and still encode the samples differently.
//
// ## Two things worth knowing before reading the cases
//
//   - `samplesPerChunk: 0` is degenerate on purpose. `numSamples >= o.samplesPerChunk*2` is then `0 >= 0`, so
//     EVERY append cuts, and the first cut leaves an empty chunk behind. Nothing configures 0 upstream
//     (`DefaultSamplesPerChunk` is 120), but the arithmetic is upstream's and a port that reordered the
//     branches would diverge only here.
//   - Negative timestamps make `rangeForTimestamp` interesting: Go's integer division truncates toward zero,
//     so the windows are not aligned the same way below zero as above it. Quirk 184.

import (
	"fmt"
	"math"
	"os"
	"path/filepath"

	"promoracle/probe/headmemseries"

	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

type msOp = headmemseries.Op

func msAppend(t int64, v float64) msOp {
	return msOp{Op: "append", T: t, V: headmemseries.FBits(v)}
}

func msAppendST(st, t int64, v float64, appendID uint64) msOp {
	return msOp{Op: "append", ST: st, T: t, V: headmemseries.FBits(v), AppendID: appendID}
}

func msAppendable(t int64, v float64, headMaxt, minValidTime, oooTimeWindow int64) msOp {
	return msOp{
		Op: "appendable", T: t, V: headmemseries.FBits(v),
		HeadMaxt: headMaxt, MinValidTime: minValidTime, OOOTimeWindow: oooTimeWindow,
	}
}

func msSnapshot() msOp { return msOp{Op: "snapshot"} }

func genHeadMemSeries(e *emitter) {
	n := 0
	emit := func(name string, in headmemseries.In) {
		dir, err := os.MkdirTemp("", "promoracle-ms")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		chunkDir := filepath.Join(dir, "chunks_head")
		if err := os.MkdirAll(chunkDir, 0o777); err != nil {
			panic(err)
		}
		// The mapper exists for every case whether or not the program m-maps, so a case that adds an
		// `mmapChunks` op later does not also change the mapper's history.
		cdm, err := chunks.NewChunkDiskMapper(nil, chunkDir, chunkenc.NewPool(), chunks.DefaultWriteBufferSize, 0)
		if err != nil {
			panic(err)
		}
		out := headmemseries.Drive(in, cdm)
		if err := cdm.Close(); err != nil {
			panic(err)
		}
		// The files the program wrote, so `mmapChunks`' `mint`/`maxt` arguments land somewhere observable.
		// RLE-hex because of the 128 KiB pre-allocated tail (quirk 182).
		entries, err := os.ReadDir(chunkDir)
		if err != nil {
			panic(err)
		}
		for _, ent := range entries {
			b, err := os.ReadFile(filepath.Join(chunkDir, ent.Name()))
			if err != nil {
				panic(err)
			}
			out.Files = append(out.Files, headmemseries.FileState{
				Name: ent.Name(), Size: len(b), Bytes: rleHex(b),
			})
		}
		e.emit(fmt.Sprintf("ms/%03d/%s", n, name), in, out)
		n++
	}

	// The Head's real configuration, so the common path is the one the corpus spends most of its cases on.
	// `DefaultSamplesPerChunk` is 120 and `DefaultBlockDuration` is 2h in milliseconds.
	const spc = 120
	const twoHours = int64(2 * 60 * 60 * 1000)

	base := func(ops ...msOp) headmemseries.In {
		return headmemseries.In{
			ChunkRange: twoHours, SamplesPerChunk: spc, Ref: 7, Ops: ops,
		}
	}

	// --- Construction and the empty series -----------------------------------------------------------

	// `nextAt` starts at MinInt64, and so do minTime/maxTime: a series with no chunk has no times.
	emit("fresh", base(msSnapshot()))

	// Isolation disabled means `txs` is NIL, which is observably different from an empty ring.
	in := base(msSnapshot())
	in.IsolationDisabled = true
	emit("fresh-isolation-disabled", in)

	in = base(msSnapshot())
	in.PendingCommit = true
	in.ShardHash = 0xdeadbeef
	emit("fresh-pending-commit", in)

	// --- The first sample ----------------------------------------------------------------------------

	// One append: cuts the first chunk, fixes its minTime, and sets nextAt from the chunk RANGE.
	emit("single", base(msAppend(1000, 1.5), msSnapshot()))

	// The appendID path: 0 means "no isolation for this append" and must leave the ring empty.
	emit("single-appendid-zero", base(msAppendST(0, 1000, 1.5, 0), msSnapshot()))
	emit("single-appendid-one", base(msAppendST(0, 1000, 1.5, 1), msSnapshot()))

	// A start timestamp with XOR: discarded, because ST rides on XOR2 (quirk 36). The chunk bytes are the
	// proof — they must equal the no-ST case above.
	emit("single-st-xor", base(msAppendST(500, 1000, 1.5, 0), msSnapshot()))

	inXOR2 := base(msAppendST(500, 1000, 1.5, 0), msSnapshot())
	inXOR2.UseXOR2 = true
	emit("single-st-xor2", inXOR2)

	// --- Rejections: the two `sampleInOrder == false` routes ------------------------------------------

	// Same timestamp as the chunk's maxTime: `c.maxTime >= t` rejects, and NOTHING moves — not the value,
	// not the chunk, not the ring.
	emit("duplicate-timestamp", base(
		msAppend(1000, 1), msAppend(1000, 2), msSnapshot()))

	// Strictly older than the current chunk.
	emit("out-of-order", base(
		msAppend(2000, 1), msAppend(1000, 2), msSnapshot()))

	// The other rejection route needs the head chunk GONE and an mmapped chunk covering t: after a truncate
	// removes the head chunks, `appendPreprocessor` consults `mmappedChunks[last].maxTime`.
	seq := []msOp{}
	for i := 0; i < 12; i++ {
		seq = append(seq, msAppend(int64(i)*1000, float64(i)))
	}
	inMM := headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7}
	inMM.Ops = append(append([]msOp{}, seq...),
		msOp{Op: "mmapChunks"}, msSnapshot(),
		msAppend(5000, 99), msSnapshot())
	emit("mmapped-then-older", inMM)

	// --- The three cut rules, one case each -----------------------------------------------------------

	// (1) The chunk RANGE: `t >= s.nextAt`. chunkRange 4000 with samples 1000 apart cuts at each multiple.
	rangeOps := []msOp{}
	for i := 0; i < 10; i++ {
		rangeOps = append(rangeOps, msAppend(int64(i)*1000, float64(i)))
	}
	inR := headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7,
		Ops: append(rangeOps, msSnapshot())}
	emit("cut-by-range", inR)

	// (2) The sample COUNT: `numSamples >= o.samplesPerChunk*2`, with samplesPerChunk small enough to reach
	// it before the range does. samplesPerChunk 8 also puts `samplesPerChunk/4` at 2, so the
	// `computeChunkEndTime` prediction fires at the third sample of every chunk.
	countOps := []msOp{}
	for i := 0; i < 40; i++ {
		countOps = append(countOps, msAppend(int64(i)*1000, float64(i)))
	}
	inC := headmemseries.In{ChunkRange: twoHours, SamplesPerChunk: 8, Ref: 7,
		Ops: append(countOps, msSnapshot())}
	emit("cut-by-count", inC)

	// (3) The BYTE size: `len(c.chunk.Bytes()) > MaxBytesPerXORChunkBeforeAppend`. Poorly-compressing values
	// and a sample budget large enough that neither other rule fires first.
	sizeOps := []msOp{}
	for i := 0; i < 260; i++ {
		// Deliberately awkward for XOR's delta-of-delta: irregular timestamps and mantissa-heavy values.
		sizeOps = append(sizeOps, msAppend(int64(i)*1000+int64(i%7), math.Sin(float64(i))*float64(i)+0.123456789))
	}
	inS := headmemseries.In{ChunkRange: math.MaxInt64 / 4, SamplesPerChunk: 100000, Ref: 7,
		Ops: append(sizeOps, msSnapshot())}
	emit("cut-by-bytes", inS)

	// The prediction itself: `computeChunkEndTime`'s `n <= 1` arm returns maxT unchanged, which needs the
	// quarter-mark sample to be far from the chunk's start relative to the range.
	predOps := []msOp{msAppend(0, 0), msAppend(3_000_000, 1), msAppend(6_000_000, 2), msSnapshot()}
	inP := headmemseries.In{ChunkRange: twoHours, SamplesPerChunk: 8, Ref: 7, Ops: predOps}
	emit("prediction-n-le-1", inP)

	// The degenerate configuration: see the file header.
	inZ := headmemseries.In{ChunkRange: twoHours, SamplesPerChunk: 0, Ref: 7,
		Ops: []msOp{msAppend(1000, 1), msAppend(2000, 2), msAppend(3000, 3), msSnapshot()}}
	emit("samples-per-chunk-zero", inZ)

	// --- Negative timestamps, and Go's truncating division --------------------------------------------

	emit("negative-timestamps", headmemseries.In{ChunkRange: 1000, SamplesPerChunk: spc, Ref: 7,
		Ops: []msOp{
			msAppend(-2500, 1), msSnapshot(),
			msAppend(-1500, 2), msSnapshot(),
			msAppend(-500, 3), msSnapshot(),
			msAppend(500, 4), msSnapshot(),
		}})

	// --- The encoding-mismatch branch, reached the way upstream reaches it ----------------------------

	// XOR then XOR2 with ST storage OFF: `CompatibleValues` says the chunk keeps taking appends, so there is
	// NO cut and the chunk stays XOR — which means the ST of the later samples is discarded.
	emit("encoding-switch-compatible", base(
		msAppend(1000, 1), msAppend(2000, 2),
		msOp{Op: "setOpts", UseXOR2: boolPtr(true)},
		msAppendST(1500, 3000, 3, 0), msAppendST(2500, 4000, 4, 0), msSnapshot()))

	// Same switch with ST storage ON: `o.storeST` overrides the compatibility and forces the cut.
	inST := base(
		msAppend(1000, 1), msAppend(2000, 2),
		msOp{Op: "setOpts", UseXOR2: boolPtr(true), StoreST: boolPtr(true)},
		msAppendST(1500, 3000, 3, 0), msAppendST(2500, 4000, 4, 0), msSnapshot())
	emit("encoding-switch-storest", inST)

	// And the reverse, XOR2 -> XOR, which is compatible in the same way.
	inRev := base(
		msAppend(1000, 1), msAppend(2000, 2),
		msOp{Op: "setOpts", UseXOR2: boolPtr(false)},
		msAppend(3000, 3), msSnapshot())
	inRev.UseXOR2 = true
	emit("encoding-switch-reverse", inRev)

	// --- Special float values, which the chunk encodes bit-exactly -----------------------------------

	emit("special-values", base(
		msAppend(1000, math.NaN()),
		msAppend(2000, math.Float64frombits(value.StaleNaN)),
		msAppend(3000, math.Inf(1)),
		msAppend(4000, math.Inf(-1)),
		msAppend(5000, math.Copysign(0, -1)),
		msAppend(6000, 0),
		msSnapshot()))

	// --- m-mapping ----------------------------------------------------------------------------------

	// Nothing to m-map with a single head chunk: `headChunks.prev == nil` returns 0 and leaves the count at 1.
	emit("mmap-single-chunk", base(msAppend(1000, 1), msOp{Op: "mmapChunks"}, msSnapshot()))

	// Nothing to m-map with NO head chunk either.
	emit("mmap-empty", base(msOp{Op: "mmapChunks"}, msSnapshot()))

	// Three head chunks: the two oldest are written, OLDEST FIRST, and the newest survives with count 1.
	mmOps := []msOp{}
	for i := 0; i < 10; i++ {
		mmOps = append(mmOps, msAppend(int64(i)*1000, float64(i)))
	}
	emit("mmap-three-chunks", headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7,
		Ops: append(mmOps, msSnapshot(), msOp{Op: "mmapChunks"}, msSnapshot(),
			msOp{Op: "mmapChunks"}, msSnapshot())})

	// A second series ref, so the chunk file's series field is not always 7 and the refs differ.
	inRef := headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 0xabcdef,
		Ops: append(append([]msOp{}, mmOps...), msOp{Op: "mmapChunks"}, msSnapshot())}
	emit("mmap-other-ref", inRef)

	// --- truncateChunksBefore -----------------------------------------------------------------------

	truncBase := func(mints ...int64) headmemseries.In {
		ops := append([]msOp{}, mmOps...)
		ops = append(ops, msOp{Op: "mmapChunks"}, msSnapshot())
		for _, mint := range mints {
			ops = append(ops, msOp{Op: "truncateChunksBefore", Mint: mint}, msSnapshot())
		}
		return headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7, Ops: ops}
	}

	// Below everything: nothing is removed and firstChunkID does not move.
	emit("truncate-below-all", truncBase(-1))
	// Inside the mmapped range: only mmapped chunks go, and firstChunkID advances by exactly that many.
	emit("truncate-mid-mmapped", truncBase(5000))
	// Past the head chunk's maxTime: the head-chunk branch fires, which drops ALL mmapped chunks too —
	// "if any head chunk is truncated, we can truncate all mmapped chunks".
	emit("truncate-past-head", truncBase(1_000_000))
	// Twice, so the second call sees an already-empty series.
	emit("truncate-twice", truncBase(1_000_000, 1_000_000))

	// Truncation with the head chunks NOT m-mapped, so the `i == 0` / `i != 0` split in the head-chunk walk
	// is exercised: mint lands between two head chunks on the list.
	emit("truncate-unlinks-tail", headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7,
		Ops: append(append([]msOp{}, mmOps...),
			msSnapshot(), msOp{Op: "truncateChunksBefore", Mint: 5000}, msSnapshot())})

	// --- The linked list: atOffset, oldest, len, OverlapsClosedInterval -----------------------------

	listOps := append([]msOp{}, mmOps...)
	listOps = append(listOps,
		msOp{Op: "atOffset", Offset: 0},
		msOp{Op: "atOffset", Offset: 1},
		msOp{Op: "atOffset", Offset: 2},
		msOp{Op: "atOffset", Offset: 3},
		msOp{Op: "atOffset", Offset: 99},
		msOp{Op: "atOffset", Offset: -1},
		msOp{Op: "overlapsHead", Mint: 0, Maxt: 100},
		msOp{Op: "overlapsHead", Mint: 8000, Maxt: 9000},
		msOp{Op: "overlapsHead", Mint: 9000, Maxt: 9000},
		msOp{Op: "overlapsHead", Mint: math.MinInt64, Maxt: math.MaxInt64},
		msSnapshot())
	emit("list-navigation", headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7, Ops: listOps})

	// The same navigation on an empty series, where every answer is the zero one.
	emit("list-navigation-empty", base(
		msOp{Op: "atOffset", Offset: 0},
		msOp{Op: "overlapsHead", Mint: math.MinInt64, Maxt: math.MaxInt64},
		msSnapshot()))

	// --- appendable ---------------------------------------------------------------------------------

	// A freshly created series answers "in order" for anything at or after minValidTime, because it has no
	// chunk to compare against.
	emit("appendable-fresh", base(
		msAppendable(1000, 1, 0, 0, 0),
		msAppendable(-1, 1, 0, 0, 0),
		msSnapshot()))

	dupBase := func(ops ...msOp) headmemseries.In {
		return base(append([]msOp{msAppend(1000, 1), msAppend(2000, 2)}, ops...)...)
	}

	emit("appendable-newer", dupBase(msAppendable(3000, 5, 2000, 0, 0), msSnapshot()))

	// t == maxTime and the SAME bits: allowed, no error — federation produces these.
	emit("appendable-duplicate-same", dupBase(msAppendable(2000, 2, 2000, 0, 0), msSnapshot()))
	// t == maxTime with different bits: `NewDuplicateFloatErr`, whose message carries both values.
	emit("appendable-duplicate-diff", dupBase(msAppendable(2000, 3, 2000, 0, 0), msSnapshot()))
	// The bits comparison, not `==`: -0 and 0 are the same NUMBER and different BITS, so this is an error.
	emit("appendable-duplicate-zero-signs", base(
		msAppend(1000, 0), msAppendable(1000, math.Copysign(0, -1), 1000, 0, 0), msSnapshot()))
	// And the converse: NaN != NaN as numbers, but identical bits, so this is ALLOWED.
	emit("appendable-duplicate-nan", base(
		msAppend(1000, math.NaN()), msAppendable(1000, math.NaN(), 1000, 0, 0), msSnapshot()))

	// The histogram-to-float duplicate. `forceLastHistogram` is the probe's affordance for a field the
	// deferred histogram append path would set — see drive.go.
	emit("appendable-duplicate-histogram", dupBase(
		msOp{Op: "forceLastHistogram"},
		msAppendable(2000, 2, 2000, 0, 0), msSnapshot()))
	emit("appendable-duplicate-float-histogram", dupBase(
		msOp{Op: "forceLastFloatHistogram"},
		msAppendable(2000, 2, 2000, 0, 0), msSnapshot()))

	// A float `append` NILS both histogram fields, so the duplicate-histogram verdict above flips back once a
	// float sample lands. Without this case nothing observes the two assignments at the end of `append`.
	emit("append-clears-histogram-values", dupBase(
		msOp{Op: "forceLastHistogram"}, msSnapshot(),
		msAppend(3000, 3), msSnapshot(),
		msAppendable(3000, 3, 3000, 0, 0), msSnapshot()))

	// Below minValidTime with OOO off: out of bounds, and `oooDelta` is reported even on the error paths.
	emit("appendable-out-of-bounds", dupBase(msAppendable(500, 1, 2000, 1000, 0), msSnapshot()))
	// At or above minValidTime but older than the series: out of order.
	emit("appendable-out-of-order", dupBase(msAppendable(1500, 1, 2000, 0, 0), msSnapshot()))
	// OOO on and inside the window: routed to the OOO chunk, no error.
	emit("appendable-ooo-inside", dupBase(msAppendable(1500, 1, 2000, 0, 1000), msSnapshot()))
	// OOO on and outside it: too old — and note it still reports `isOOO == true`.
	emit("appendable-ooo-too-old", dupBase(msAppendable(100, 1, 2000, 0, 500), msSnapshot()))
	// The boundary: `t >= headMaxt-oooTimeWindow` is inclusive.
	emit("appendable-ooo-boundary", dupBase(
		msAppendable(1000, 1, 2000, 0, 1000),
		msAppendable(999, 1, 2000, 0, 1000), msSnapshot()))

	// --- Isolation: the ring's growth and cleanup ----------------------------------------------------

	ringOps := []msOp{}
	for i := 1; i <= 6; i++ {
		ringOps = append(ringOps, msAppendST(0, int64(i)*1000, float64(i), uint64(i)))
	}
	ringOps = append(ringOps, msSnapshot(),
		msOp{Op: "cleanupAppendIDsBelow", Bound: 4}, msSnapshot(),
		msOp{Op: "cleanupAppendIDsBelow", Bound: 99}, msSnapshot())
	emit("isolation-ring", base(ringOps...))

	// With isolation disabled, an appendID > 0 would dereference a nil ring, so upstream never passes one —
	// `newAppendID` returns 0 when disabled (§7f(a)). This case pins that a zero ID is safe on a nil ring.
	inNoIso := base(msAppendST(0, 1000, 1, 0), msOp{Op: "cleanupAppendIDsBelow", Bound: 5}, msSnapshot())
	inNoIso.IsolationDisabled = true
	emit("isolation-disabled-cleanup", inNoIso)

	// --- The realistic run: 15s scrapes into a 2h chunk range ---------------------------------------

	realOps := []msOp{}
	for i := 0; i < 700; i++ {
		realOps = append(realOps, msAppendST(0, int64(i)*15000, float64(i)*0.5, uint64(i+1)))
	}
	realOps = append(realOps, msSnapshot(), msOp{Op: "mmapChunks"}, msSnapshot())
	emit("realistic-15s-scrapes", base(realOps...))

	inRealXOR2 := base(realOps...)
	inRealXOR2.UseXOR2 = true
	inRealXOR2.StoreST = true
	emit("realistic-15s-scrapes-xor2", inRealXOR2)

	// --- The states only WAL replay can produce ------------------------------------------------------

	// `loadMmappedChunks` installs mmapped descriptors on a series with no head chunk (§7h), and that is the
	// only route to this state — `truncateChunksBefore` clears the mmapped array whenever it drops a head
	// chunk, so nothing in this slice can reach it. Three branches depend on it: `minTime`'s and `maxTime`'s
	// mmapped arms, and `appendPreprocessor`'s "the timestamp is already in the mmapped chunks" rejection.
	seedTwo := msOp{Op: "seedMmapped", Mmapped: []headmemseries.MmappedState{
		{Ref: 8, NumSamples: 5, MinTime: 1000, MaxTime: 2000},
		{Ref: 16, NumSamples: 7, MinTime: 3000, MaxTime: 4000},
	}}

	emit("seeded-mmapped-only", base(seedTwo, msSnapshot()))

	// A sample inside the seeded range is rejected without creating a chunk; one after it is accepted and cuts
	// the first head chunk. The boundary is `>=`, so `maxTime` itself is rejected.
	emit("seeded-mmapped-rejects-older", base(
		seedTwo,
		msAppend(3500, 1), msSnapshot(),
		msAppend(4000, 2), msSnapshot(),
		msAppend(4001, 3), msSnapshot()))

	// And `truncateChunksBefore` over seeded chunks with no head chunk at all: the head-chunk walk is skipped
	// entirely, so only the mmapped scan runs and `firstChunkID` moves by what it removed.
	emit("seeded-mmapped-truncate", base(
		seedTwo,
		msOp{Op: "truncateChunksBefore", Mint: 2000}, msSnapshot(),
		msOp{Op: "truncateChunksBefore", Mint: 2001}, msSnapshot(),
		msOp{Op: "truncateChunksBefore", Mint: 99999}, msSnapshot()))

	// --- Boundaries: mint EXACTLY on a chunk's maxTime -----------------------------------------------

	// Both truncation tests are `<` and `>=` against a chunk's maxTime, so a mint that equals one is the only
	// input that distinguishes them from `<=` and `>`. The MMAPPED test is the one this reaches, because
	// `truncBase` m-maps first and so leaves a single head chunk whose maxTime is far above any of these.
	emit("truncate-on-boundary", truncBase(3000, 7000))

	// The HEAD-chunk test needs the same equality against a head chunk, which means NOT m-mapping first: with
	// three head chunks ending at 3000, 7000 and 9000, a mint of exactly 3000 must leave all three alone.
	emit("truncate-head-on-boundary", headmemseries.In{ChunkRange: 4000, SamplesPerChunk: spc, Ref: 7,
		Ops: append(append([]msOp{}, mmOps...),
			msSnapshot(),
			msOp{Op: "truncateChunksBefore", Mint: 3000}, msSnapshot(),
			msOp{Op: "truncateChunksBefore", Mint: 3001}, msSnapshot(),
			msOp{Op: "truncateChunksBefore", Mint: 7000}, msSnapshot())})

	// --- appendable's remaining boundaries -----------------------------------------------------------

	// `t >= minValidTime` — equality is in bounds.
	emit("appendable-minvalidtime-boundary", base(
		msAppend(1000, 1), msAppend(2000, 2),
		msAppendable(1000, 9, 2000, 1000, 0),
		msAppendable(999, 9, 2000, 1000, 0), msSnapshot()))

	// The freshly-created guard is only observable at `Int64.min`: without it, `maxTime()` answers
	// `Int64.min` too, `t > msMaxt` is false, `t == msMaxt` is TRUE, and the duplicate check fires instead.
	emit("appendable-fresh-at-min-int", base(
		msOp{Op: "appendable", T: math.MinInt64, V: headmemseries.FBits(1),
			HeadMaxt: 0, MinValidTime: math.MinInt64}, msSnapshot()))

	// --- The sample-count fallback, with the prediction out of the way -------------------------------

	// `numSamples >= samplesPerChunk*2` only decides anything while `t < nextAt`, and the quarter-mark
	// prediction normally pulls `nextAt` down far enough that the TIME rule fires first. With
	// `samplesPerChunk < 4` the quarter mark is 0, so the prediction only ever runs on an empty chunk (where
	// it returns `nextAt` unchanged) and the count rule is what cuts.
	countOnly := []msOp{}
	for i := 0; i < 20; i++ {
		countOnly = append(countOnly, msAppend(int64(i)*1000, float64(i)))
	}
	emit("cut-by-count-only", headmemseries.In{ChunkRange: twoHours, SamplesPerChunk: 3, Ref: 7,
		Ops: append(countOnly, msSnapshot())})
}
