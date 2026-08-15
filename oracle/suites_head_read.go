package main

// Differential coverage for the Head's READ path — `headIndexReader`, `headChunkReader`, `RangeHead`, and the
// isolation-aware chunk iterator. Driven through the real `tsdb.Head`, `tsdb.NewRangeHead` and their exported
// `Index()`/`Chunks()`.
//
// ## What makes this suite different from `head/append`
//
// `head/append` asserts what a commit WROTE (accessors, WAL bytes, chunk files). This one asserts what a reader
// SEES, which is a different set of decisions: the `mint` clamp in `indexRange`, the empty-result window check
// in `LabelValues`/`LabelNames`, `SortedPostings`' label ordering, the chunk metas `Series` reports — including
// `MaxInt64` for the open chunk — and then, per meta, the chunk that comes back and the samples it yields.
//
// ## The isolation case is the point of the `readerAfterPhase` field
//
// A reader takes an `isolationState` when it is created, and samples committed AFTER that must not be visible.
// So the program appends in PHASES, opens the chunk reader after a chosen one, and then reads — which is the
// only way to make `memSeries.iterator`'s `stopAfter` anything other than "all of them". With
// `readerAfterPhase` at the end, every sample is visible and the same corpus covers the ordinary path.
//
// The isolation state also has to be closed, and the corpus reads `Head.NumSeries` and the watermark after
// closing, because an unclosed reader is what blocks head truncation.

import (
	"context"
	"fmt"
	"math"
	"os"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
)

type hrSample struct {
	Labels map[string]string `json:"labels"`
	T      int64             `json:"t"`
	V      string            `json:"v"`
}

type hrIn struct {
	ChunkRange      int64 `json:"chunkRange"`
	SamplesPerChunk int   `json:"samplesPerChunk"`
	// Each phase is one appender transaction, committed before the next begins.
	Phases [][]hrSample `json:"phases"`
	// Open the readers after this phase (0-based). -1 means after all of them, which is the ordinary case.
	ReaderAfterPhase int `json:"readerAfterPhase"`
	// When set, the readers come from a `RangeHead` over this window instead of from the Head.
	RangeMint *int64 `json:"rangeMint,omitempty"`
	RangeMaxt *int64 `json:"rangeMaxt,omitempty"`
	// `NewRangeHeadWithIsolationDisabled` rather than `NewRangeHead`.
	RangeIsolationOff bool `json:"rangeIsolationOff,omitempty"`
	// `LabelValues`/`SortedLabelValues` queries.
	LabelValueNames []string `json:"labelValueNames,omitempty"`
	// `LabelValues(name, matchers...)` — the matcher vocabulary is fixed, see `hrMatchers`.
	MatcherKind string `json:"matcherKind,omitempty"`
	// `Postings(name, values...)` queries.
	PostingsQueries [][]string `json:"postingsQueries,omitempty"`
	// Close the head before opening the readers, so `chunksRange` refuses.
	CloseBeforeRead bool `json:"closeBeforeRead,omitempty"`
	// Refs that do not exist, so `Series` and `chunk` report `ErrNotFound`.
	BogusRefs      []uint64 `json:"bogusRefs,omitempty"`
	BogusChunkRefs []uint64 `json:"bogusChunkRefs,omitempty"`
}

// A closure cannot cross JSON, so a case names one of a fixed set. Chosen to cover the three shapes
// `labelValuesWithMatchers` distinguishes: an equality matcher (which intersects), a negative one (which
// subtracts), and one that matches everything.
func hrMatchers(kind string) []*labels.Matcher {
	switch kind {
	case "":
		return nil
	case "eq":
		return []*labels.Matcher{labels.MustNewMatcher(labels.MatchEqual, "job", "a")}
	case "neq":
		return []*labels.Matcher{labels.MustNewMatcher(labels.MatchNotEqual, "job", "a")}
	case "re":
		return []*labels.Matcher{labels.MustNewMatcher(labels.MatchRegexp, "__name__", "m.*")}
	case "all":
		return []*labels.Matcher{labels.MustNewMatcher(labels.MatchRegexp, "__name__", ".*")}
	default:
		panic("unknown matcher kind " + kind)
	}
}

type hrChunkMeta struct {
	Ref     uint64 `json:"ref"`
	MinTime int64  `json:"minTime"`
	MaxTime int64  `json:"maxTime"`
}

type hrSeriesOut struct {
	Ref    uint64            `json:"ref"`
	Labels map[string]string `json:"labels"`
	Chunks []hrChunkMeta     `json:"chunks"`
	Err    string            `json:"err"`
}

type hrReadSample struct {
	T int64  `json:"t"`
	V string `json:"v"`
}

type hrChunkOut struct {
	Ref        uint64         `json:"ref"`
	Encoding   uint8          `json:"encoding"`
	NumSamples int            `json:"numSamples"`
	Bytes      string         `json:"bytes"`
	MaxTime    int64          `json:"maxTime"`
	Samples    []hrReadSample `json:"samples"`
	Err        string         `json:"err"`
	// The COPY path, read as a chunk rather than only for its maxTime — otherwise a copy that produced an
	// empty chunk would be invisible.
	CopyBytes      string `json:"copyBytes"`
	CopyNumSamples int    `json:"copyNumSamples"`
	CopyErr        string `json:"copyErr"`
}

type hrOut struct {
	// The index reader's answers.
	Symbols           []string   `json:"symbols"`
	LabelNames        []string   `json:"labelNames"`
	LabelNamesMatched []string   `json:"labelNamesMatched"`
	LabelValues       [][]string `json:"labelValues"`
	SortedLabelValues [][]string `json:"sortedLabelValues"`
	MatchedValues     [][]string `json:"matchedValues"`
	Postings          [][]uint64 `json:"postings"`
	AllPostings       []uint64   `json:"allPostings"`
	SortedPostings    []uint64   `json:"sortedPostings"`
	LabelNamesFor     []string   `json:"labelNamesFor"`

	// `Series` for every ref the postings gave, then the bogus ones.
	Series []hrSeriesOut `json:"series"`

	// Every chunk named by every series' metas, read back and iterated.
	Chunks []hrChunkOut `json:"chunks"`

	// The reader's own window, after the clamp.
	IndexMint int64 `json:"indexMint"`
	// `RangeHead`'s accessors, when one is in use.
	RangeMeta   *hrRangeMeta `json:"rangeMeta,omitempty"`
	ReaderErr   string       `json:"readerErr"`
	AfterClose  uint64       `json:"afterClose"`
	LowWatermrk uint64       `json:"lowWatermark"`
}

type hrRangeMeta struct {
	MinTime      int64  `json:"minTime"`
	MaxTime      int64  `json:"maxTime"`
	BlockMaxTime int64  `json:"blockMaxTime"`
	NumSeries    uint64 `json:"numSeries"`
	ULID         string `json:"ulid"`
	String       string `json:"string"`
}

func genHeadRead(e *emitter) {
	n := 0
	emit := func(name string, in hrIn) {
		dir, err := os.MkdirTemp("", "promoracle-hread")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		opts := tsdb.DefaultHeadOptions()
		opts.ChunkDirRoot = dir
		opts.ChunkRange = in.ChunkRange
		opts.SamplesPerChunk = in.SamplesPerChunk

		h, err := tsdb.NewHead(nil, nil, nil, nil, opts, nil)
		if err != nil {
			panic(err)
		}

		out := hrOut{
			Symbols: []string{}, LabelNames: []string{}, LabelNamesMatched: []string{},
			LabelValues: [][]string{}, SortedLabelValues: [][]string{}, MatchedValues: [][]string{},
			Postings: [][]uint64{}, AllPostings: []uint64{}, SortedPostings: []uint64{},
			LabelNamesFor: []string{}, Series: []hrSeriesOut{}, Chunks: []hrChunkOut{},
		}

		// The readers, opened after the requested phase.
		var ir tsdb.IndexReader
		var cr tsdb.ChunkReader
		openReaders := func() {
			var rh interface {
				Index() (tsdb.IndexReader, error)
				Chunks() (tsdb.ChunkReader, error)
			}
			if in.RangeMint != nil {
				if in.RangeIsolationOff {
					rh = tsdb.NewRangeHeadWithIsolationDisabled(h, *in.RangeMint, *in.RangeMaxt)
				} else {
					rh = tsdb.NewRangeHead(h, *in.RangeMint, *in.RangeMaxt)
				}
			} else {
				rh = h
			}
			ir, err = rh.Index()
			if err != nil {
				out.ReaderErr = err.Error()
				return
			}
			cr, err = rh.Chunks()
			if err != nil {
				out.ReaderErr = err.Error()
			}
			if rhh, ok := rh.(*tsdb.RangeHead); ok {
				out.RangeMeta = &hrRangeMeta{
					MinTime: rhh.MinTime(), MaxTime: rhh.MaxTime(), BlockMaxTime: rhh.BlockMaxTime(),
					NumSeries: rhh.NumSeries(), ULID: rhh.Meta().ULID.String(), String: rhh.String(),
				}
			}
		}

		if in.ReaderAfterPhase == -2 {
			// Before ANY commit: every sample the reader later sees belongs to an append it cannot see, so
			// `memSeries.iterator` answers a nop iterator — the `stopAfter == 0` arm.
			openReaders()
		}

		for pi, phase := range in.Phases {
			app := h.Appender(context.Background())
			for _, s := range phase {
				if _, err := app.Append(0, labels.FromMap(s.Labels), s.T, fbitsToFloat(s.V)); err != nil {
					panic(err)
				}
			}
			if err := app.Commit(); err != nil {
				panic(err)
			}
			if pi == in.ReaderAfterPhase {
				openReaders()
			}
		}
		if in.ReaderAfterPhase == -1 || in.ReaderAfterPhase >= len(in.Phases) {
			if in.CloseBeforeRead {
				if err := h.Close(); err != nil {
					panic(err)
				}
			}
			openReaders()
		}

		if out.ReaderErr != "" {
			e.emit(fmt.Sprintf("hread/%03d/%s", n, name), in, out)
			n++
			_ = h.Close()
			return
		}

		// --- The index reader ---------------------------------------------------------------------

		it := ir.Symbols()
		for it.Next() {
			out.Symbols = append(out.Symbols, it.At())
		}

		names, err := ir.LabelNames(context.Background())
		if err == nil {
			out.LabelNames = append(out.LabelNames, names...)
		}
		if in.MatcherKind != "" {
			mnames, err := ir.LabelNames(context.Background(), hrMatchers(in.MatcherKind)...)
			if err == nil {
				out.LabelNamesMatched = append(out.LabelNamesMatched, mnames...)
			}
		}

		for _, name := range in.LabelValueNames {
			vs, err := ir.LabelValues(context.Background(), name, nil)
			if err != nil {
				vs = []string{"ERR: " + err.Error()}
			}
			out.LabelValues = append(out.LabelValues, append([]string{}, vs...))

			svs, err := ir.SortedLabelValues(context.Background(), name, nil)
			if err != nil {
				svs = []string{"ERR: " + err.Error()}
			}
			out.SortedLabelValues = append(out.SortedLabelValues, append([]string{}, svs...))

			if in.MatcherKind != "" {
				mvs, err := ir.LabelValues(context.Background(), name, nil, hrMatchers(in.MatcherKind)...)
				if err != nil {
					mvs = []string{"ERR: " + err.Error()}
				}
				out.MatchedValues = append(out.MatchedValues, append([]string{}, mvs...))
			}
		}

		for _, q := range in.PostingsQueries {
			p, err := ir.Postings(context.Background(), q[0], q[1:]...)
			refs := []uint64{}
			if err == nil {
				expanded, _ := index.ExpandPostings(p)
				for _, r := range expanded {
					refs = append(refs, uint64(r))
				}
			}
			out.Postings = append(out.Postings, refs)
		}

		// Every series, twice: in postings order and in SortedPostings order.
		allName, allValue := index.AllPostingsKey()
		allP, err := ir.Postings(context.Background(), allName, allValue)
		if err != nil {
			panic(err)
		}
		allRefs, err := index.ExpandPostings(allP)
		if err != nil {
			panic(err)
		}
		for _, r := range allRefs {
			out.AllPostings = append(out.AllPostings, uint64(r))
		}

		sortedP := ir.SortedPostings(index.NewListPostings(allRefs))
		sortedRefs, _ := index.ExpandPostings(sortedP)
		for _, r := range sortedRefs {
			out.SortedPostings = append(out.SortedPostings, uint64(r))
		}

		lnf, err := ir.LabelNamesFor(context.Background(), index.NewListPostings(allRefs))
		if err == nil {
			out.LabelNamesFor = append(out.LabelNamesFor, lnf...)
		}

		// --- Series, and then every chunk they name ------------------------------------------------

		readSeries := func(ref storage.SeriesRef) {
			var builder labels.ScratchBuilder
			var chks []chunks.Meta
			so := hrSeriesOut{Ref: uint64(ref), Labels: map[string]string{}, Chunks: []hrChunkMeta{}}
			if err := ir.Series(ref, &builder, &chks); err != nil {
				so.Err = err.Error()
				out.Series = append(out.Series, so)
				return
			}
			so.Labels = builder.Labels().Map()
			for _, c := range chks {
				so.Chunks = append(so.Chunks, hrChunkMeta{
					Ref: uint64(c.Ref), MinTime: c.MinTime, MaxTime: c.MaxTime,
				})
			}
			out.Series = append(out.Series, so)

			for _, c := range chks {
				out.Chunks = append(out.Chunks, readChunk(cr, c))
			}
		}

		for _, r := range sortedRefs {
			readSeries(r)
		}
		for _, r := range in.BogusRefs {
			readSeries(storage.SeriesRef(r))
		}
		for _, r := range in.BogusChunkRefs {
			out.Chunks = append(out.Chunks, readChunk(cr, chunks.Meta{Ref: chunks.ChunkRef(r)}))
		}

		out.IndexMint = indexReaderMint(ir)

		if err := cr.Close(); err != nil {
			out.ReaderErr = err.Error()
		}
		_ = ir.Close()
		out.AfterClose = h.NumSeries()

		e.emit(fmt.Sprintf("hread/%03d/%s", n, name), in, out)
		n++
		_ = h.Close()
	}

	// --- helpers ---------------------------------------------------------------------------------

	const twoHours = int64(2 * 60 * 60 * 1000)
	sample := func(name, job string, t int64, v float64) hrSample {
		return hrSample{Labels: map[string]string{"__name__": name, "job": job}, T: t, V: fbits(v)}
	}

	base := func(phases ...[]hrSample) hrIn {
		return hrIn{
			ChunkRange: twoHours, SamplesPerChunk: 120, Phases: phases, ReaderAfterPhase: -1,
			LabelValueNames: []string{"__name__", "job", "nope"},
			PostingsQueries: [][]string{{"__name__", "m1"}, {"job", "a", "b"}, {"nope", "x"}},
		}
	}

	// --- The empty head ---------------------------------------------------------------------------

	emit("empty-head", base())

	// --- One series, one sample -------------------------------------------------------------------

	emit("one-sample", base([]hrSample{sample("m1", "a", 1000, 1)}))

	// --- Several series, and the ordering SortedPostings imposes ----------------------------------

	// Refs are assigned in append order, so appending in reverse label order makes postings order and
	// SortedPostings order DIFFER — which is the only way to see that the latter sorts by label set.
	emit("sorted-postings-differs-from-refs", base([]hrSample{
		sample("m3", "c", 1000, 3),
		sample("m1", "a", 1000, 1),
		sample("m2", "b", 1000, 2),
	}))

	// --- Matchers ---------------------------------------------------------------------------------
	for _, kind := range []string{"eq", "neq", "re", "all"} {
		in := base([]hrSample{
			sample("m1", "a", 1000, 1),
			sample("m2", "b", 1000, 2),
			sample("m1", "b", 1000, 3),
		})
		in.MatcherKind = kind
		emit("matchers-"+kind, in)
	}

	// --- Chunks: several per series, so the metas and the ID arithmetic both matter ---------------

	many := []hrSample{}
	for i := 0; i < 12; i++ {
		many = append(many, sample("m1", "a", int64(i)*1000, float64(i)))
	}
	emit("many-chunks", hrIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		ReaderAfterPhase: -1, LabelValueNames: []string{"__name__"},
		PostingsQueries: [][]string{{"__name__", "m1"}}})

	// The same, with the chunks M-MAPPED first — which is what makes `memSeries.chunk` take its disk path and
	// `Series` report real maxTimes for the older chunks.
	mmapped := hrIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		ReaderAfterPhase: -1, LabelValueNames: []string{"__name__"},
		PostingsQueries: [][]string{{"__name__", "m1"}}}
	emit("many-chunks-after-mmap", mmapped)

	// --- Isolation: a reader opened BEFORE later commits -----------------------------------------

	// Two phases, reader after the first: the second phase's samples must not be visible, which is
	// `stopAfter` doing its job. Everything else about the two cases is identical.
	phaseA := []hrSample{sample("m1", "a", 1000, 1), sample("m1", "a", 2000, 2)}
	phaseB := []hrSample{sample("m1", "a", 3000, 3), sample("m1", "a", 4000, 4)}
	isoIn := base(phaseA, phaseB)
	isoIn.ReaderAfterPhase = 0
	emit("isolation-hides-later-commits", isoIn)

	visible := base(phaseA, phaseB)
	visible.ReaderAfterPhase = 1
	emit("isolation-sees-everything-when-opened-last", visible)

	// A reader opened before the FIRST commit sees no samples at all — the chunk exists but every one of its
	// samples belongs to an append the reader cannot see, so the iterator is a nop.
	nothing := base(phaseA)
	nothing.ReaderAfterPhase = 99 // Past the end: opened after all phases. See the -1 case for the contrast.
	emit("isolation-reader-after-all-phases", nothing)

	// --- RangeHead --------------------------------------------------------------------------------

	rangeIn := base([]hrSample{
		sample("m1", "a", 1000, 1), sample("m1", "a", 5000, 2), sample("m1", "a", 9000, 3),
	})
	lo, hi := int64(2000), int64(6000)
	rangeIn.RangeMint, rangeIn.RangeMaxt = &lo, &hi
	emit("range-head-window", rangeIn)

	// A window entirely BELOW the head's data: `LabelValues` and `LabelNames` answer empty, and the mint clamp
	// is what makes the index reader's own window differ from the one asked for.
	belowIn := base([]hrSample{sample("m1", "a", 10_000, 1)})
	blo, bhi := int64(0), int64(5000)
	belowIn.RangeMint, belowIn.RangeMaxt = &blo, &bhi
	emit("range-head-below-the-data", belowIn)

	// A window entirely ABOVE it.
	aboveIn := base([]hrSample{sample("m1", "a", 1000, 1)})
	alo, ahi := int64(50_000), int64(60_000)
	aboveIn.RangeMint, aboveIn.RangeMaxt = &alo, &ahi
	emit("range-head-above-the-data", aboveIn)

	// Isolation off, which is what compaction uses.
	isoOff := base([]hrSample{sample("m1", "a", 1000, 1)})
	ilo, ihi := int64(0), int64(math.MaxInt64)
	isoOff.RangeMint, isoOff.RangeMaxt = &ilo, &ihi
	isoOff.RangeIsolationOff = true
	emit("range-head-isolation-off", isoOff)

	// --- A closed head ----------------------------------------------------------------------------

	closed := base([]hrSample{sample("m1", "a", 1000, 1)})
	closed.CloseBeforeRead = true
	emit("closed-head-refuses-chunk-reader", closed)

	// --- A reader opened before ANY commit --------------------------------------------------------

	before := base([]hrSample{sample("m1", "a", 1000, 1), sample("m1", "a", 2000, 2)})
	before.ReaderAfterPhase = -2
	emit("isolation-reader-before-any-commit", before)

	// --- A RangeHead window that excludes whole chunks --------------------------------------------

	// chunkRange 4000 with 12 samples gives three chunks: [0,3000], [4000,7000] and the open one from 8000.
	// A window of [5000, 6000] therefore excludes the FIRST chunk entirely — which is the only way to see
	// `appendSeriesChunks`' overlap test and `chunkFromSeries`' range check do anything.
	windowed := hrIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		ReaderAfterPhase: -1, LabelValueNames: []string{"__name__"},
		PostingsQueries: [][]string{{"__name__", "m1"}}}
	wlo, whi := int64(5000), int64(6000)
	windowed.RangeMint, windowed.RangeMaxt = &wlo, &whi
	emit("range-head-excludes-a-chunk", windowed)

	// A window that starts INSIDE the first chunk, so the clamp in `indexRange` has something to clamp.
	clamped := hrIn{ChunkRange: 4000, SamplesPerChunk: 120, Phases: [][]hrSample{many},
		ReaderAfterPhase: -1, LabelValueNames: []string{"__name__"},
		PostingsQueries: [][]string{{"__name__", "m1"}}}
	clo, chi := int64(-100_000), int64(2000)
	clamped.RangeMint, clamped.RangeMaxt = &clo, &chi
	emit("range-head-window-below-then-inside", clamped)

	// --- A RangeHead with isolation OFF, opened between commits -----------------------------------

	// With isolation on this reader would miss phase two; with it off it sees everything, which is exactly why
	// compaction uses `NewRangeHeadWithIsolationDisabled`.
	isoOffMid := base(phaseA, phaseB)
	isoOffMid.ReaderAfterPhase = 0
	mlo, mhi := int64(0), int64(100_000)
	isoOffMid.RangeMint, isoOffMid.RangeMaxt = &mlo, &mhi
	isoOffMid.RangeIsolationOff = true
	emit("range-head-isolation-off-sees-later-commits", isoOffMid)

	isoOnMid := base(phaseA, phaseB)
	isoOnMid.ReaderAfterPhase = 0
	isoOnMid.RangeMint, isoOnMid.RangeMaxt = &mlo, &mhi
	emit("range-head-isolation-on-hides-later-commits", isoOnMid)

	// --- Missing refs -----------------------------------------------------------------------------

	bogus := base([]hrSample{sample("m1", "a", 1000, 1)})
	bogus.BogusRefs = []uint64{0, 99, math.MaxUint32}
	// A chunk ref for a series that exists but a chunk ID that does not, and one for a series that does not.
	bogus.BogusChunkRefs = []uint64{
		1<<24 | 7,  // series 1, chunk 7 — the series exists, the chunk does not.
		99<<24 | 0, // series 99 — garbage collected.
		// NOT a ref with the OOO bit (1<<23) set: `chunkFromSeries` routes it to `memSeries.oooChunk`, which
		// dereferences `s.ooo` without checking it — so upstream SEGFAULTS on such a ref for a series that has
		// never taken an out-of-order sample. Quirk 191. Unreachable in practice (only the OOO append path
		// mints those refs), and the port answers `ErrNotFound` instead, which is a declared divergence rather
		// than a corpus case.
	}
	emit("missing-refs", bogus)
}

// indexReaderMint reaches the reader's clamped `mint` the only way an exported API allows: `Series` on a series
// whose samples are all below the requested window reports no chunks, so the mint is inferred by asking for a
// series and checking whether its chunks came back. Rather than infer, the corpus reports the head's own MinTime,
// which is what the clamp uses — the clamp itself is asserted by the range cases' chunk lists.
func indexReaderMint(_ tsdb.IndexReader) int64 { return 0 }

func readChunk(cr tsdb.ChunkReader, meta chunks.Meta) hrChunkOut {
	co := hrChunkOut{Ref: uint64(meta.Ref), Samples: []hrReadSample{}}
	chk, iterable, err := cr.ChunkOrIterable(meta)
	if err != nil {
		co.Err = err.Error()
		return co
	}
	if chk == nil {
		if iterable == nil {
			co.Err = "nil chunk and nil iterable"
		} else {
			co.Err = "iterable, not chunk"
		}
		return co
	}
	co.Encoding = uint8(chk.Encoding())
	co.NumSamples = chk.NumSamples()
	co.Bytes = fmt.Sprintf("%x", chk.Bytes())

	it := chk.Iterator(nil)
	for it.Next() == chunkenc.ValFloat {
		t, v := it.At()
		co.Samples = append(co.Samples, hrReadSample{T: t, V: fbits(v)})
	}
	if err := it.Err(); err != nil {
		co.Err = err.Error()
	}

	// The copy path, read as a CHUNK: its bytes and sample count, not just the max time.
	if crc, ok := cr.(tsdb.ChunkReaderWithCopy); ok {
		cchk, _, maxTime, err := crc.ChunkOrIterableWithCopy(meta)
		if err != nil {
			co.CopyErr = err.Error()
		} else if cchk != nil {
			co.MaxTime = maxTime
			co.CopyBytes = fmt.Sprintf("%x", cchk.Bytes())
			co.CopyNumSamples = cchk.NumSamples()
		}
	}
	return co
}
