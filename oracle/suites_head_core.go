package main

// Differential coverage for `NewHead` and the Head's own accessors — **driven through the real exported
// `tsdb.NewHead`**, with no probe package.
//
// That is the point of this suite. §7f(a)-(d) each had to lift unexported upstream code into a package the
// oracle could call; `NewHead` and everything this asks about are exported, so this corpus drives upstream's
// actual constructor. It is also the correction HANDOFF §7f records: an earlier reading claimed the Head could
// only be pinned through `tsdb.DB`.
//
// ## What the cases are about
//
// Three groups, and the middle one is the interesting one:
//
//  1. **Validation.** `NewHead` rejects an `OutOfOrderCapMax` outside `(0, 255]` and a `ChunkRange < 1`, with
//     two exact messages, and it checks them in that order — so a call with both invalid reports the OOO one.
//  2. **The mutations `NewHead` performs on the options it was handed.** A negative `OutOfOrderTimeWindow`
//     becomes 0, `MaxExemplars` is zeroed unless exemplar storage is on, a nil `SeriesCallback` becomes the
//     noop, and a `WALReplayConcurrency <= 0` becomes `GOMAXPROCS(0)`. Every one of those fields is exported,
//     so the corpus reads them back AFTER construction. This is why the port's `HeadOptions` is a class:
//     `db.go` holds the same pointer and reads these later.
//  3. **What a fresh Head answers.** `MinTime` is `MaxInt64` and `MaxTime` is `MinInt64`, so `Meta()` reports
//     an INVERTED range and `AppendableMinValidTime` answers `(0, false)`. `Size()` is the WAL plus the chunk
//     files, and every error inside it is discarded.
//
// `WALReplayConcurrency` is the one field whose Go answer is machine-dependent (`GOMAXPROCS`), so the corpus
// commits **whether it changed**, not the number. The port fixes it at 1 and says so.
//
// Not reachable from here and deliberately not faked: `getOrCreate`, `updateMinMaxTime`, `mmapHeadChunks` and
// `compactable` are unexported and only move once samples exist, which is the appender slice's corpus.

import (
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/wlog"
	"github.com/prometheus/prometheus/util/compression"
)

type hdOpts struct {
	ChunkRange           int64 `json:"chunkRange"`
	SamplesPerChunk      int   `json:"samplesPerChunk"`
	StripeSize           int   `json:"stripeSize"`
	OutOfOrderTimeWindow int64 `json:"outOfOrderTimeWindow"`
	OutOfOrderCapMax     int64 `json:"outOfOrderCapMax"`
	IsolationDisabled    bool  `json:"isolationDisabled,omitempty"`
	EnableExemplars      bool  `json:"enableExemplarStorage,omitempty"`
	MaxExemplars         int64 `json:"maxExemplars,omitempty"`
	FloatChunkEncoding   uint8 `json:"floatChunkEncoding"`
	ChunkWriteBufferSize int   `json:"chunkWriteBufferSize"`
	WALReplayConcurrency int   `json:"walReplayConcurrency"`
	EnableSharding       bool  `json:"enableSharding,omitempty"`
	EnableSTStorage      bool  `json:"enableSTStorage,omitempty"`
	// "" leaves the callback as `DefaultHeadOptions` set it; "nil" clears it, which is what makes NewHead's
	// fill-in observable.
	SeriesCallback string `json:"seriesCallback,omitempty"`
}

type hdIn struct {
	Opts hdOpts `json:"opts"`
	// A real `wlog.WL` in the head's directory, and records logged into it before `Size()` is read. Without a
	// record the segment is zero bytes, so the size would not distinguish "no WAL" from "empty WAL".
	WithWAL    bool     `json:"withWAL,omitempty"`
	WALRecords []string `json:"walRecords,omitempty"`
	// `SetMinValidTime`, then `AppendableMinValidTime`.
	SetMinValidTime *int64 `json:"setMinValidTime,omitempty"`
	// `OverlapsClosedInterval` queries.
	Overlaps [][]int64 `json:"overlaps,omitempty"`
}

type hdOptsAfter struct {
	OutOfOrderTimeWindow int64 `json:"outOfOrderTimeWindow"`
	MaxExemplars         int64 `json:"maxExemplars"`
	SeriesCallbackSet    bool  `json:"seriesCallbackSet"`
	// GOMAXPROCS is machine-dependent, so what is committed is whether NewHead REPLACED the value.
	WALReplayConcurrencyChanged bool `json:"walReplayConcurrencyChanged"`
	ChunkPoolSet                bool `json:"chunkPoolSet"`
	UseXOR2FloatEncoding        bool `json:"useXOR2FloatEncoding"`
}

type hdOut struct {
	Err       string      `json:"err"`
	OptsAfter hdOptsAfter `json:"optsAfter"`

	MinTime    int64 `json:"minTime"`
	MaxTime    int64 `json:"maxTime"`
	MinOOOTime int64 `json:"minOOOTime"`
	MaxOOOTime int64 `json:"maxOOOTime"`

	NumSeries      uint64 `json:"numSeries"`
	NumStaleSeries uint64 `json:"numStaleSeries"`

	MetaULID      string `json:"metaULID"`
	MetaMinTime   int64  `json:"metaMinTime"`
	MetaMaxTime   int64  `json:"metaMaxTime"`
	MetaNumSeries uint64 `json:"metaNumSeries"`

	String string `json:"string"`
	Size   int64  `json:"size"`

	AppendableMinValidTime int64 `json:"appendableMinValidTime"`
	AppendableOK           bool  `json:"appendableOK"`

	Overlaps []bool `json:"overlaps"`

	// The head's chunk directory after construction: `NewChunkDiskMapper` creates it, and a fresh one is empty.
	ChunkDirEntries []string `json:"chunkDirEntries"`
	// The head DIRECTORY, so the name `mmappedChunksDir` chose is observable rather than only its contents.
	RootEntries []string `json:"rootEntries"`
	CloseErr    string   `json:"closeErr"`
}

func genHeadCore(e *emitter) {
	n := 0
	emit := func(name string, in hdIn) {
		dir, err := os.MkdirTemp("", "promoracle-head")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		opts := tsdb.DefaultHeadOptions()
		opts.ChunkDirRoot = dir
		opts.ChunkRange = in.Opts.ChunkRange
		opts.SamplesPerChunk = in.Opts.SamplesPerChunk
		opts.StripeSize = in.Opts.StripeSize
		opts.OutOfOrderTimeWindow.Store(in.Opts.OutOfOrderTimeWindow)
		opts.OutOfOrderCapMax.Store(in.Opts.OutOfOrderCapMax)
		opts.IsolationDisabled = in.Opts.IsolationDisabled
		opts.EnableExemplarStorage = in.Opts.EnableExemplars
		opts.MaxExemplars.Store(in.Opts.MaxExemplars)
		opts.FloatChunkEncoding.Store(uint32(in.Opts.FloatChunkEncoding))
		opts.ChunkWriteBufferSize = in.Opts.ChunkWriteBufferSize
		opts.ChunkWriteQueueSize = 0
		opts.WALReplayConcurrency = in.Opts.WALReplayConcurrency
		opts.EnableSharding = in.Opts.EnableSharding
		opts.EnableSTStorage.Store(in.Opts.EnableSTStorage)
		if in.Opts.SeriesCallback == "nil" {
			opts.SeriesCallback = nil
		}
		concurrencyBefore := opts.WALReplayConcurrency

		out := hdOut{Overlaps: []bool{}, ChunkDirEntries: []string{}, RootEntries: []string{}}

		var wal *wlog.WL
		if in.WithWAL {
			wal, err = wlog.New(nil, nil, filepath.Join(dir, "wal"), compression.None)
			if err != nil {
				panic(err)
			}
			for _, rec := range in.WALRecords {
				if err := wal.Log(unrleHex(rec)); err != nil {
					panic(err)
				}
			}
		}

		h, err := tsdb.NewHead(nil, nil, wal, nil, opts, nil)
		if err != nil {
			out.Err = scrubDir(err.Error(), dir)
			e.emit(fmt.Sprintf("head/%03d/%s", n, name), in, out)
			n++
			if wal != nil {
				_ = wal.Close()
			}
			return
		}

		out.OptsAfter = hdOptsAfter{
			OutOfOrderTimeWindow:        opts.OutOfOrderTimeWindow.Load(),
			MaxExemplars:                opts.MaxExemplars.Load(),
			SeriesCallbackSet:           opts.SeriesCallback != nil,
			WALReplayConcurrencyChanged: opts.WALReplayConcurrency != concurrencyBefore,
			ChunkPoolSet:                opts.ChunkPool != nil,
			UseXOR2FloatEncoding:        opts.UseXOR2FloatEncoding(),
		}

		if in.SetMinValidTime != nil {
			h.SetMinValidTime(*in.SetMinValidTime)
		}

		out.MinTime, out.MaxTime = h.MinTime(), h.MaxTime()
		out.MinOOOTime, out.MaxOOOTime = h.MinOOOTime(), h.MaxOOOTime()
		out.NumSeries, out.NumStaleSeries = h.NumSeries(), h.NumStaleSeries()

		meta := h.Meta()
		out.MetaULID = meta.ULID.String()
		out.MetaMinTime, out.MetaMaxTime = meta.MinTime, meta.MaxTime
		out.MetaNumSeries = meta.Stats.NumSeries

		out.String = h.String()
		out.Size = h.Size()

		out.AppendableMinValidTime, out.AppendableOK = h.AppendableMinValidTime()

		for _, iv := range in.Overlaps {
			out.Overlaps = append(out.Overlaps, h.OverlapsClosedInterval(iv[0], iv[1]))
		}

		entries, err := os.ReadDir(filepath.Join(dir, "chunks_head"))
		if err == nil {
			for _, ent := range entries {
				out.ChunkDirEntries = append(out.ChunkDirEntries, ent.Name())
			}
		}
		rootEntries, err := os.ReadDir(dir)
		if err == nil {
			for _, ent := range rootEntries {
				out.RootEntries = append(out.RootEntries, ent.Name())
			}
		}

		if err := h.Close(); err != nil {
			out.CloseErr = scrubDir(err.Error(), dir)
		}

		e.emit(fmt.Sprintf("head/%03d/%s", n, name), in, out)
		n++
	}

	// `DefaultHeadOptions`, spelled out so a case that changes one field says which.
	def := hdOpts{
		ChunkRange:           2 * 60 * 60 * 1000,
		SamplesPerChunk:      120,
		StripeSize:           1 << 14,
		OutOfOrderCapMax:     32,
		FloatChunkEncoding:   uint8(chunkenc.EncXOR),
		ChunkWriteBufferSize: 4 * 1024 * 1024,
		// A FIXED value, not `GOMAXPROCS(0)`: the input travels in the fixture, and a machine-dependent input
		// would make the committed corpus unreproducible on another host. The substitution NewHead performs is
		// covered by the two cases that pass 0 and -3.
		WALReplayConcurrency: 4,
	}

	// --- The fresh head, at the defaults ------------------------------------------------------------

	emit("defaults", hdIn{Opts: def, Overlaps: [][]int64{
		{0, 0}, {math.MinInt64, math.MaxInt64}, {-1000, 1000},
	}})

	// --- NewHead's validation, in its own order -----------------------------------------------------

	bad := def
	bad.OutOfOrderCapMax = 0
	emit("oooCapMax-zero", hdIn{Opts: bad})

	bad = def
	bad.OutOfOrderCapMax = -1
	emit("oooCapMax-negative", hdIn{Opts: bad})

	bad = def
	bad.OutOfOrderCapMax = 256
	emit("oooCapMax-too-large", hdIn{Opts: bad})

	bad = def
	bad.OutOfOrderCapMax = 255
	emit("oooCapMax-at-limit", hdIn{Opts: bad})

	bad = def
	bad.ChunkRange = 0
	emit("chunkRange-zero", hdIn{Opts: bad})

	bad = def
	bad.ChunkRange = -5
	emit("chunkRange-negative", hdIn{Opts: bad})

	bad = def
	bad.ChunkRange = 1
	emit("chunkRange-one", hdIn{Opts: bad})

	// BOTH invalid: the OOO check runs first, so that is the message.
	bad = def
	bad.ChunkRange = 0
	bad.OutOfOrderCapMax = 0
	emit("both-invalid-reports-ooo", hdIn{Opts: bad})

	// --- The mutations NewHead performs on its options ----------------------------------------------

	mut := def
	mut.OutOfOrderTimeWindow = -1
	emit("negative-ooo-window-clamped", hdIn{Opts: mut})

	mut = def
	mut.MaxExemplars = 100
	emit("max-exemplars-zeroed-when-disabled", hdIn{Opts: mut})

	mut = def
	mut.MaxExemplars = 100
	mut.EnableExemplars = true
	emit("max-exemplars-kept-when-enabled", hdIn{Opts: mut})

	mut = def
	mut.SeriesCallback = "nil"
	emit("nil-series-callback-filled", hdIn{Opts: mut})

	mut = def
	mut.WALReplayConcurrency = 0
	emit("zero-replay-concurrency-replaced", hdIn{Opts: mut})

	mut = def
	mut.WALReplayConcurrency = -3
	emit("negative-replay-concurrency-replaced", hdIn{Opts: mut})

	// The switch quirk 36 was waiting for.
	mut = def
	mut.FloatChunkEncoding = uint8(chunkenc.EncXOR2)
	emit("xor2-float-encoding", hdIn{Opts: mut})

	mut = def
	mut.FloatChunkEncoding = uint8(chunkenc.EncHistogram)
	emit("histogram-float-encoding-is-not-xor2", hdIn{Opts: mut})

	// --- minValidTime, and what AppendableMinValidTime does with it ---------------------------------

	mvt := int64(5000)
	emit("min-valid-time-set", hdIn{Opts: def, SetMinValidTime: &mvt})

	negMvt := int64(-5000)
	emit("min-valid-time-negative", hdIn{Opts: def, SetMinValidTime: &negMvt})

	// --- Size, with and without a WAL --------------------------------------------------------------

	emit("size-with-empty-wal", hdIn{Opts: def, WithWAL: true})

	emit("size-with-wal-records", hdIn{Opts: def, WithWAL: true, WALRecords: []string{
		rleHex([]byte("hello")), rleHex(make([]byte, 100)),
	}})

	// --- Other option shapes worth a case ----------------------------------------------------------

	small := def
	small.StripeSize = 1
	small.ChunkRange = 3
	small.SamplesPerChunk = 1
	emit("minimal-options", hdIn{Opts: small})

	iso := def
	iso.IsolationDisabled = true
	emit("isolation-disabled", hdIn{Opts: iso})

	shard := def
	shard.EnableSharding = true
	shard.EnableSTStorage = true
	emit("sharding-and-st-storage", hdIn{Opts: shard})

	buf := def
	buf.ChunkWriteBufferSize = 128 * 1024
	emit("small-chunk-write-buffer", hdIn{Opts: buf})
}
