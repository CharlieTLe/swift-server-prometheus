package main

// Differential coverage for `storage/merge.go`, `storage/lazy.go`, `storage/secondary.go` and
// `storage/generic.go`'s Part A — the VERTICAL merge.
//
// ## Everything is driven through the exported entry points
//
// `storage.NewMergeQuerier` and `storage.NewMergeChunkQuerier` are exported and take
// `[]storage.Querier` / `[]storage.ChunkQuerier`, so the whole file is reachable from outside the
// package. The queriers handed to them are **real block queriers** — `oracle/blockfixture.go` writes
// a block with upstream's own writer, `tsdb.OpenBlock` opens it and `tsdb.NewBlockQuerier` queries
// it. §6w's lesson is that a harness which assembles the pieces by hand hides exactly the bugs this
// kind of corpus exists to find, and it cost three commits there.
//
// The only hand-written queriers are the ones a real block CANNOT be: a querier that errors, one
// that warns, and one that closes badly. Upstream's own `merge_test.go` does the same thing for the
// same reason, and they are LEAVES — every line of merge logic above them is upstream's.
//
// ## What has to be reached, and how the cases reach it
//
//   - `NewMergeQuerier`'s four-arm switch, including `filterQueriers` dropping nils and
//     `noopQuerier`s BEFORE the arms are counted. Recorded as `querierKind`, the Go type name of
//     what the constructor returned, so a port that built a merge querier over one input fails.
//   - the level-2 heap. Cases put the same series in two, three and four queriers, with ranges that
//     are disjoint, adjacent, overlapping and identical.
//   - `chainSampleIterator`'s duplicate-timestamp rule — FIRST one wins. Cases give the two
//     queriers the same timestamp with DIFFERENT values, so the winner is visible in the value and
//     not only in the count. Those cases use PRIMARIES ONLY; see the determinism note below.
//   - `chainSampleIterator.Seek`, through a fixed script per series: next, then seeks landing
//     before / inside / after the cursor, each followed by a next. The `c.lastT >= t` no-op branch
//     and the cross-iterator branch are both on it.
//   - the CHUNK side, both mergers. `NewCompactingChunkSeriesMerger` decodes overlapping chunks,
//     merges the samples and re-encodes; `NewConcatenatingChunkSeriesMerger` does not. The chunk
//     BYTES are recorded, so the re-encoding is pinned rather than only its bounds — and so the
//     perfect-duplicate skip (same bounds AND same bytes) is distinguishable from a merge.
//   - `LabelValues`/`LabelNames`, whose `mergeResults` splits the queriers BY HALF and applies the
//     limit at every level of the recursion. Cases with 2, 3, 4 and 5 queriers, since the split
//     shape and therefore the truncation points change with the count.
//   - the ERROR and WARNING plumbing, which is the part a reading of the source does not settle: a
//     primary's error aborts the whole merge, a secondary's becomes a warning and empties that
//     querier's results, and `LabelValues`' error wrapper DROPS the warnings accumulated so far.
//
// ## Determinism, which is a finding rather than an obstacle
//
// `mergeGenericQuerier.Select` runs the per-querier selects in GOROUTINES whenever there is at
// least one secondary, and collects the sets off an unbuffered channel — so `seriesSets` ends up in
// completion order. That order seeds the level-2 heap, and the level-2 heap breaks ties between
// equal label sets, and `chainSampleIterator` resolves a duplicate timestamp by taking the first
// sample it sees. Upstream therefore has NO deterministic answer for "secondary querier + duplicate
// timestamp + different values".
//
// So the cases are built to keep the corpus on the deterministic side of that line:
//
//   - a case that has a secondary never has two sources carrying the same series with the same
//     timestamp and a different value, nor two chunks with identical bounds and different bytes;
//   - a case never has more than one ERRORING primary, since `newGenericMergeSeriesSet` returns on
//     the first one it meets;
//   - warnings are emitted SORTED, because `annotations.Annotations` is a Go map.
//
// The port does not reproduce the goroutines at all (PORTING.md exception 33); the constraints
// above are what make that unobservable.

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sort"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/util/annotations"
)

// ----------------------------------------------------------------- the wire shapes

// mergeSource is one querier the case merges. A "block" is real; everything else is a leaf stub
// whose only job is to produce a behaviour a block cannot.
type mergeSource struct {
	// "block" | "stub" | "noop" | "nil"
	Kind string `json:"kind"`
	// Secondary queriers are best-effort: their errors become warnings.
	Secondary bool `json:"secondary"`

	// Kind == "block".
	Series []seriesSetSeries `json:"series,omitempty"`
	// Filled in by Go: the block's three files, hex, so the port reads the same bytes.
	IndexHex string   `json:"indexHex,omitempty"`
	MetaHex  string   `json:"metaHex,omitempty"`
	SegHexes []string `json:"segHexes,omitempty"`

	// Kind == "stub". `ErrAfter` > 0 makes Select return a set that yields that many series and
	// only then reports `SelectErr` — the ONLY way to reach `genericMergeSeriesSet.Err()`, since a
	// set that errors on its first `Next()` is caught by `newGenericMergeSeriesSet`'s pre-advance
	// and collapses the whole merge into an `errorOnlySeriesSet` instead.
	ErrAfter   int      `json:"errAfter,omitempty"`
	SelectErr  string   `json:"selectErr,omitempty"`
	SelectWarn string   `json:"selectWarn,omitempty"`
	LabelErr   string   `json:"labelErr,omitempty"`
	LabelWarn  string   `json:"labelWarn,omitempty"`
	CloseErr   string   `json:"closeErr,omitempty"`
	Values     []string `json:"values,omitempty"`
	Names      []string `json:"names,omitempty"`
}

type mergeIn struct {
	Sources []mergeSource `json:"sources"`

	Mint int64 `json:"mint"`
	Maxt int64 `json:"maxt"`

	Matchers [][3]string `json:"matchers,omitempty"`
	// SelectHints.Limit. 0 disables.
	Limit int `json:"limit"`
	// When true, Select is called with NIL hints — so `limit` never reaches the merge.
	NilHints bool `json:"nilHints"`

	// "compact" or "concat".
	ChunkMerger string `json:"chunkMerger"`

	LabelName  string `json:"labelName"`
	LabelLimit int    `json:"labelLimit"`
	// When true, the label queries are called with nil hints.
	NilLabelHints bool `json:"nilLabelHints"`
}

type mergeOut struct {
	// The Go type of what `NewMergeQuerier` returned — the four-arm switch, and `filterQueriers`.
	QuerierKind      string `json:"querierKind"`
	ChunkQuerierKind string `json:"chunkQuerierKind"`

	// Per merged series.
	LabelSets   []string   `json:"labelSets"`
	SampleTimes [][]int64  `json:"sampleTimes"`
	SampleVals  [][]string `json:"sampleVals"`
	// Per merged series: the fixed seek script's timestamps, and the VALUES at them.
	//
	// The values are what make the no-op branch of `chainSampleIterator.Seek` observable: a seek
	// to a timestamp the cursor is already at returns that timestamp either way, and only the
	// value says whether the cursor stayed on the iterator it was on or was repositioned onto
	// another iterator carrying the same timestamp. Two controls survived without them.
	SeekTimes [][]int64  `json:"seekTimes"`
	SeekVals  [][]string `json:"seekVals"`
	SelectErr string    `json:"selectErr"`
	// Sorted; `annotations.Annotations` is a Go map.
	SelectWarnings []string `json:"selectWarnings"`
	// `Err()` and `Warnings()` read BEFORE the first `Next()`. This is what `lazy.go` is FOR: an
	// uninitialised `lazyGenericSeriesSet` answers nil to both rather than running the query, so
	// these are empty for every case — and a port whose `Select` was eager would populate them for
	// the erroring ones. A control that removed the laziness survived without them.
	PreSelectErr      string   `json:"preSelectErr"`
	PreSelectWarnings []string `json:"preSelectWarnings"`

	// The chunk querier.
	ChunkLabelSets []string     `json:"chunkLabelSets"`
	ChunkRanges    [][][2]int64 `json:"chunkRanges"`
	ChunkBytes     [][]string   `json:"chunkBytes"`
	ChunkErr       string       `json:"chunkErr"`
	ChunkWarnings  []string     `json:"chunkWarnings"`

	LabelValues         []string `json:"labelValues"`
	LabelValuesWarnings []string `json:"labelValuesWarnings"`
	LabelValuesErr      string   `json:"labelValuesErr"`
	LabelNames          []string `json:"labelNames"`
	LabelNamesWarnings  []string `json:"labelNamesWarnings"`
	LabelNamesErr       string   `json:"labelNamesErr"`

	CloseErr string `json:"closeErr"`
	OpenErr  string `json:"openErr"`
}

// ----------------------------------------------------------------- the leaf stubs

// stubQuerier is a LEAF: it produces the behaviours a real block cannot (an error, a warning, a
// failing Close). Every line of merge logic above it is upstream's.
type stubQuerier struct{ spec mergeSource }

func (s *stubQuerier) Select(_ context.Context, _ bool, _ *storage.SelectHints, _ ...*labels.Matcher) storage.SeriesSet {
	if s.spec.ErrAfter > 0 {
		return &delayedErrSeriesSet{n: s.spec.ErrAfter, msg: s.spec.SelectErr}
	}
	if s.spec.SelectErr != "" {
		return storage.ErrSeriesSet(errors.New(s.spec.SelectErr))
	}
	if s.spec.SelectWarn != "" {
		var ws annotations.Annotations
		return warnSeriesSet{ws: ws.Add(errors.New(s.spec.SelectWarn))}
	}
	return storage.EmptySeriesSet()
}

func (s *stubQuerier) LabelValues(_ context.Context, _ string, _ *storage.LabelHints, _ ...*labels.Matcher) ([]string, annotations.Annotations, error) {
	if s.spec.LabelErr != "" {
		return nil, nil, errors.New(s.spec.LabelErr)
	}
	var ws annotations.Annotations
	if s.spec.LabelWarn != "" {
		ws = ws.Add(errors.New(s.spec.LabelWarn))
	}
	return s.spec.Values, ws, nil
}

func (s *stubQuerier) LabelNames(_ context.Context, _ *storage.LabelHints, _ ...*labels.Matcher) ([]string, annotations.Annotations, error) {
	if s.spec.LabelErr != "" {
		return nil, nil, errors.New(s.spec.LabelErr)
	}
	var ws annotations.Annotations
	if s.spec.LabelWarn != "" {
		ws = ws.Add(errors.New(s.spec.LabelWarn))
	}
	return s.spec.Names, ws, nil
}

func (s *stubQuerier) Close() error {
	if s.spec.CloseErr != "" {
		return errors.New(s.spec.CloseErr)
	}
	return nil
}

// stubChunkQuerier is the same leaf on the chunk side.
type stubChunkQuerier struct{ spec mergeSource }

func (s *stubChunkQuerier) Select(_ context.Context, _ bool, _ *storage.SelectHints, _ ...*labels.Matcher) storage.ChunkSeriesSet {
	if s.spec.SelectErr != "" {
		return storage.ErrChunkSeriesSet(errors.New(s.spec.SelectErr))
	}
	if s.spec.SelectWarn != "" {
		var ws annotations.Annotations
		return warnChunkSeriesSet{ws: ws.Add(errors.New(s.spec.SelectWarn))}
	}
	return storage.EmptyChunkSeriesSet()
}

func (s *stubChunkQuerier) LabelValues(ctx context.Context, n string, h *storage.LabelHints, m ...*labels.Matcher) ([]string, annotations.Annotations, error) {
	return (&stubQuerier{spec: s.spec}).LabelValues(ctx, n, h, m...)
}

func (s *stubChunkQuerier) LabelNames(ctx context.Context, h *storage.LabelHints, m ...*labels.Matcher) ([]string, annotations.Annotations, error) {
	return (&stubQuerier{spec: s.spec}).LabelNames(ctx, h, m...)
}

func (s *stubChunkQuerier) Close() error { return (&stubQuerier{spec: s.spec}).Close() }

// delayedErrSeriesSet yields `n` one-sample series and then reports an error. A leaf, like the
// other stubs: it exists because a real block querier cannot fail halfway through an iteration and
// `genericMergeSeriesSet.Err()` is unreachable without one.
type delayedErrSeriesSet struct {
	n   int
	i   int
	msg string
}

func (d *delayedErrSeriesSet) Next() bool {
	if d.i >= d.n {
		return false
	}
	d.i++
	return true
}

func (d *delayedErrSeriesSet) At() storage.Series {
	return storage.NewListSeries(
		labels.FromStrings("__name__", fmt.Sprintf("late%02d", d.i-1)),
		[]chunks.Sample{delayedSample{t: int64(d.i) * 10, v: float64(d.i)}},
	)
}

func (d *delayedErrSeriesSet) Err() error {
	if d.i >= d.n && d.msg != "" {
		return errors.New(d.msg)
	}
	return nil
}

func (*delayedErrSeriesSet) Warnings() annotations.Annotations { return nil }

type delayedSample struct {
	t int64
	v float64
}

func (s delayedSample) T() int64                    { return s.t }
func (s delayedSample) F() float64                  { return s.v }
func (delayedSample) H() *histogram.Histogram       { return nil }
func (delayedSample) FH() *histogram.FloatHistogram { return nil }
func (delayedSample) Type() chunkenc.ValueType      { return chunkenc.ValFloat }
func (delayedSample) ST() int64                     { return 0 }
func (s delayedSample) Copy() chunks.Sample         { return s }

type warnSeriesSet struct{ ws annotations.Annotations }

func (warnSeriesSet) Next() bool                          { return false }
func (warnSeriesSet) At() storage.Series                  { return nil }
func (warnSeriesSet) Err() error                          { return nil }
func (s warnSeriesSet) Warnings() annotations.Annotations { return s.ws }

type warnChunkSeriesSet struct{ ws annotations.Annotations }

func (warnChunkSeriesSet) Next() bool                          { return false }
func (warnChunkSeriesSet) At() storage.ChunkSeries             { return nil }
func (warnChunkSeriesSet) Err() error                          { return nil }
func (s warnChunkSeriesSet) Warnings() annotations.Annotations { return s.ws }

// ----------------------------------------------------------------- helpers

// sortedWarnings renders an annotation set as a SORTED list of messages.
//
// `annotations.Annotations` is a `map[string]error`, so its iteration order is random and a fixture
// that recorded it would differ run to run — the same reasoning that shaped
// `Fixtures/promql/annotations-set.jsonl`. Sorting is not a narrowing here: the set is a set.
func sortedWarnings(ws annotations.Annotations) []string {
	out := []string{}
	for _, e := range ws.AsErrors() {
		out = append(out, e.Error())
	}
	sort.Strings(out)
	return out
}

func mergeMatchers(in mergeIn) []*labels.Matcher {
	if len(in.Matchers) == 0 {
		// Upstream's own "everything" spelling; `PostingsForMatchers` special-cases it.
		return []*labels.Matcher{labels.MustNewMatcher(labels.MatchEqual, "", "")}
	}
	ms := []*labels.Matcher{}
	for _, spec := range in.Matchers {
		m, err := parsePFMMatcher(spec)
		if err != nil {
			return nil
		}
		ms = append(ms, m)
	}
	return ms
}

func mergeSelectHints(in mergeIn) *storage.SelectHints {
	if in.NilHints {
		return nil
	}
	return &storage.SelectHints{Start: in.Mint, End: in.Maxt, Limit: in.Limit}
}

func mergeLabelHints(in mergeIn) *storage.LabelHints {
	if in.NilLabelHints {
		return nil
	}
	return &storage.LabelHints{Limit: in.LabelLimit}
}

// ----------------------------------------------------------------- the generator

func genStorageMerge(e *emitter) {
	n := 0

	emit := func(in mergeIn) {
		out := mergeOut{
			LabelSets: []string{}, SampleTimes: [][]int64{}, SampleVals: [][]string{},
			SeekTimes: [][]int64{}, SeekVals: [][]string{}, SelectWarnings: []string{},
			PreSelectWarnings: []string{},
			ChunkLabelSets: []string{}, ChunkRanges: [][][2]int64{}, ChunkBytes: [][]string{},
			ChunkWarnings: []string{}, LabelValues: []string{}, LabelValuesWarnings: []string{},
			LabelNames: []string{}, LabelNamesWarnings: []string{},
		}
		ctx := context.Background()

		// Open every block source once; the queriers below are built from these.
		blocks := make([]*tsdb.Block, len(in.Sources))
		for i := range in.Sources {
			if in.Sources[i].Kind != "block" {
				continue
			}
			dir, err := os.MkdirTemp("", "mergeblk")
			if err != nil {
				out.OpenErr = err.Error()
				e.emit(fmt.Sprintf("storagemerge/%d", n), in, out)
				n++
				return
			}
			defer os.RemoveAll(dir)

			series := []blockSeries2{}
			for _, s := range in.Sources[i].Series {
				flat := []string{}
				for _, l := range s.Labels {
					flat = append(flat, l[0], l[1])
				}
				chunks := [][]blockSample{}
				for _, ch := range s.Chunks {
					samples := []blockSample{}
					for _, sm := range ch {
						samples = append(samples, blockSample{T: sm[0], V: float64(sm[1])})
					}
					chunks = append(chunks, samples)
				}
				series = append(series, blockSeries2{Labels: labels.FromStrings(flat...), Chunks: chunks})
			}

			b, ih, mh, sh, err := openOracleBlock(dir, series)
			if err != nil {
				out.OpenErr = err.Error()
				e.emit(fmt.Sprintf("storagemerge/%d", n), in, out)
				n++
				return
			}
			defer b.Close()
			blocks[i] = b
			in.Sources[i].IndexHex, in.Sources[i].MetaHex, in.Sources[i].SegHexes = ih, mh, sh
		}

		// buildQueriers makes a FRESH set every time, because a secondary querier panics if it is
		// Select-ed after the first Next of any of its sets.
		buildQueriers := func() (primaries, secondaries []storage.Querier, bad string) {
			for i, s := range in.Sources {
				var q storage.Querier
				switch s.Kind {
				case "block":
					bq, err := tsdb.NewBlockQuerier(blocks[i], in.Mint, in.Maxt)
					if err != nil {
						return nil, nil, err.Error()
					}
					q = bq
				case "stub":
					q = &stubQuerier{spec: s}
				case "noop":
					q = storage.NoopQuerier()
				case "nil":
					q = nil
				}
				if s.Secondary {
					secondaries = append(secondaries, q)
				} else {
					primaries = append(primaries, q)
				}
			}
			return primaries, secondaries, ""
		}
		buildChunkQueriers := func() (primaries, secondaries []storage.ChunkQuerier, bad string) {
			for i, s := range in.Sources {
				var q storage.ChunkQuerier
				switch s.Kind {
				case "block":
					bq, err := tsdb.NewBlockChunkQuerier(blocks[i], in.Mint, in.Maxt)
					if err != nil {
						return nil, nil, err.Error()
					}
					q = bq
				case "stub":
					q = &stubChunkQuerier{spec: s}
				case "noop":
					q = storage.NoopChunkedQuerier()
				case "nil":
					q = nil
				}
				if s.Secondary {
					secondaries = append(secondaries, q)
				} else {
					primaries = append(primaries, q)
				}
			}
			return primaries, secondaries, ""
		}

		ms := mergeMatchers(in)
		hints := mergeSelectHints(in)

		// --- pass 1: the sample merge.
		{
			p, s, bad := buildQueriers()
			if bad != "" {
				out.OpenErr = bad
				e.emit(fmt.Sprintf("storagemerge/%d", n), in, out)
				n++
				return
			}
			q := storage.NewMergeQuerier(p, s, storage.ChainedSeriesMerge)
			out.QuerierKind = fmt.Sprintf("%T", q)
			set := q.Select(ctx, false, hints, ms...)
			// Before ANY Next: the lazy set has not initialised, so both are empty.
			out.PreSelectErr = errString(set.Err())
			out.PreSelectWarnings = sortedWarnings(set.Warnings())
			for set.Next() {
				sr := set.At()
				if sr == nil {
					// Unreachable upstream — `seriesSetAdapter.At()` type-asserts and would panic
					// first — and recorded rather than skipped precisely so a port that answers nil
					// where Go answers a series is a diff rather than a silently shorter loop.
					out.LabelSets = append(out.LabelSets, "<nil>")
					out.SampleTimes = append(out.SampleTimes, []int64{})
					out.SampleVals = append(out.SampleVals, []string{})
					continue
				}
				out.LabelSets = append(out.LabelSets, sr.Labels().String())
				ts := []int64{}
				vs := []string{}
				it := sr.Iterator(nil)
				for it.Next() != chunkenc.ValNone {
					t, v := it.At()
					ts = append(ts, t)
					vs = append(vs, fbits(v))
				}
				out.SampleTimes = append(out.SampleTimes, ts)
				out.SampleVals = append(out.SampleVals, vs)
			}
			out.SelectErr = errString(set.Err())
			out.SelectWarnings = sortedWarnings(set.Warnings())
			_ = q.Close()
		}

		// --- pass 2: the seek script, on fresh queriers.
		//
		// The anchors come from the MERGED series' own timestamps, recorded by pass 1, rather than
		// from the query range: a query range wide enough to be interesting for selection leaves
		// every seek past the end of the data, which pins nothing. §6t's seek script learnt the same
		// thing the same way.
		{
			p, s, _ := buildQueriers()
			q := storage.NewMergeQuerier(p, s, storage.ChainedSeriesMerge)
			set := q.Select(ctx, false, hints, ms...)
			idx := 0
			for set.Next() {
				if set.At() == nil {
					out.SeekTimes = append(out.SeekTimes, []int64{})
					out.SeekVals = append(out.SeekVals, []string{})
					idx++
					continue
				}
				t0, tmid, tlast := in.Mint, in.Mint+(in.Maxt-in.Mint)/2, in.Maxt
				if idx < len(out.SampleTimes) && len(out.SampleTimes[idx]) > 0 {
					ts := out.SampleTimes[idx]
					t0, tmid, tlast = ts[0], ts[len(ts)/2], ts[len(ts)-1]
				}
				it := set.At().Iterator(nil)
				res := []int64{}
				vals := []string{}
				record := func(vt chunkenc.ValueType) {
					if vt == chunkenc.ValNone {
						res = append(res, -1<<62)
						vals = append(vals, "")
					} else {
						t, v := it.At()
						res = append(res, t)
						vals = append(vals, fbits(v))
					}
				}
				record(it.Next())
				// At or before the cursor: the `c.lastT >= t` no-op branch.
				record(it.Seek(t0))
				record(it.Next())
				// Forward, usually into another base iterator.
				record(it.Seek(tmid))
				record(it.Next())
				// Backwards again, now that lastT has moved: the no-op branch a second time.
				record(it.Seek(t0))
				record(it.Next())
				record(it.Seek(tlast))
				record(it.Next())
				record(it.Seek(tlast + 1))
				record(it.Next())
				out.SeekTimes = append(out.SeekTimes, res)
				out.SeekVals = append(out.SeekVals, vals)
				idx++
			}
			_ = q.Close()
		}

		// --- pass 3: the chunk merge.
		{
			p, s, _ := buildChunkQueriers()
			var mf storage.VerticalChunkSeriesMergeFunc
			if in.ChunkMerger == "concat" {
				mf = storage.NewConcatenatingChunkSeriesMerger()
			} else {
				mf = storage.NewCompactingChunkSeriesMerger(storage.ChainedSeriesMerge)
			}
			cq := storage.NewMergeChunkQuerier(p, s, mf)
			out.ChunkQuerierKind = fmt.Sprintf("%T", cq)
			set := cq.Select(ctx, false, hints, ms...)
			for set.Next() {
				cs := set.At()
				if cs == nil {
					out.ChunkLabelSets = append(out.ChunkLabelSets, "<nil>")
					out.ChunkRanges = append(out.ChunkRanges, [][2]int64{})
					out.ChunkBytes = append(out.ChunkBytes, []string{})
					continue
				}
				out.ChunkLabelSets = append(out.ChunkLabelSets, cs.Labels().String())
				rs := [][2]int64{}
				bs := []string{}
				it := cs.Iterator(nil)
				for it.Next() {
					m := it.At()
					rs = append(rs, [2]int64{m.MinTime, m.MaxTime})
					if m.Chunk != nil {
						bs = append(bs, hex.EncodeToString(m.Chunk.Bytes()))
					} else {
						bs = append(bs, "")
					}
				}
				out.ChunkRanges = append(out.ChunkRanges, rs)
				out.ChunkBytes = append(out.ChunkBytes, bs)
			}
			out.ChunkErr = errString(set.Err())
			out.ChunkWarnings = sortedWarnings(set.Warnings())
			_ = cq.Close()
		}

		// --- pass 4: the label queries, and Close.
		{
			p, s, _ := buildQueriers()
			q := storage.NewMergeQuerier(p, s, storage.ChainedSeriesMerge)
			lh := mergeLabelHints(in)
			vals, ws, err := q.LabelValues(ctx, in.LabelName, lh, ms...)
			if vals == nil {
				vals = []string{}
			}
			out.LabelValues = vals
			out.LabelValuesWarnings = sortedWarnings(ws)
			out.LabelValuesErr = errString(err)

			names, ws2, err2 := q.LabelNames(ctx, lh, ms...)
			if names == nil {
				names = []string{}
			}
			out.LabelNames = names
			out.LabelNamesWarnings = sortedWarnings(ws2)
			out.LabelNamesErr = errString(err2)

			out.CloseErr = errString(q.Close())
		}

		e.emit(fmt.Sprintf("storagemerge/%d", n), in, out)
		n++
	}

	// ------------------------------------------------------------- case builders

	L := func(pairs ...string) [][2]string {
		out := [][2]string{}
		for i := 0; i+1 < len(pairs); i += 2 {
			out = append(out, [2]string{pairs[i], pairs[i+1]})
		}
		return out
	}
	// ch builds a chunk whose sample values are `base + i`, so two queriers can carry the SAME
	// timestamps with DIFFERENT values and the winner of a duplicate is visible.
	chv := func(base int64, ts ...int64) [][2]int64 {
		out := [][2]int64{}
		for i, t := range ts {
			out = append(out, [2]int64{t, base + int64(i)})
		}
		return out
	}
	block := func(series ...seriesSetSeries) mergeSource {
		return mergeSource{Kind: "block", Series: series}
	}
	secondary := func(s mergeSource) mergeSource { s.Secondary = true; return s }
	M := func(t, nm, v string) [3]string { return [3]string{t, nm, v} }

	base := func(in mergeIn) mergeIn {
		if in.Maxt == 0 {
			in.Maxt = 100
		}
		if in.LabelName == "" {
			in.LabelName = "job"
		}
		return in
	}

	// ---- 1. The constructor's switch, and filterQueriers.
	emit(base(mergeIn{Sources: []mergeSource{}}))
	emit(base(mergeIn{Sources: []mergeSource{{Kind: "noop"}}}))
	emit(base(mergeIn{Sources: []mergeSource{{Kind: "nil"}}}))
	emit(base(mergeIn{Sources: []mergeSource{{Kind: "noop"}, {Kind: "nil"}}}))
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
	}}))
	// One block plus a noop and a nil: `filterQueriers` drops both, so this is the PASSTHROUGH arm
	// and the constructor returns the block querier itself.
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "noop"},
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		{Kind: "nil"},
	}}))
	// A single SECONDARY: the third arm, which wraps rather than passes through.
	emit(base(mergeIn{Sources: []mergeSource{
		secondary(block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}})),
	}}))

	// ---- 2. Two blocks, DISJOINT series. The heap interleaves by label set.
	emit(base(mergeIn{Sources: []mergeSource{
		block(
			seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}},
			seriesSetSeries{Labels: L("__name__", "c", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}},
		),
		block(
			seriesSetSeries{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{chv(100, 5, 15, 25)}},
			seriesSetSeries{Labels: L("__name__", "d", "job", "y"), Chunks: [][][2]int64{chv(100, 5, 15, 25)}},
		),
	}}))

	// ---- 3. The SAME series in two blocks, disjoint timestamps: the chain interleaves samples.
	sameSeries := func(base1, base2 int64, ts1, ts2 []int64) []mergeSource {
		return []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "s", "job", "x"), Chunks: [][][2]int64{chv(base1, ts1...)}}),
			block(seriesSetSeries{Labels: L("__name__", "s", "job", "x"), Chunks: [][][2]int64{chv(base2, ts2...)}}),
		}
	}
	emit(base(mergeIn{Sources: sameSeries(0, 100, []int64{0, 20, 40}, []int64{10, 30, 50})}))
	emit(base(mergeIn{Sources: sameSeries(0, 100, []int64{0, 10, 20}, []int64{30, 40, 50})}))
	emit(base(mergeIn{Sources: sameSeries(0, 100, []int64{30, 40, 50}, []int64{0, 10, 20})}))

	// ---- 4. IDENTICAL timestamps with DIFFERENT values — the duplicate rule. Primaries only.
	emit(base(mergeIn{Sources: sameSeries(0, 1000, []int64{0, 10, 20}, []int64{0, 10, 20})}))
	// Partial overlap, so some timestamps are duplicated and some are not.
	emit(base(mergeIn{Sources: sameSeries(0, 1000, []int64{0, 10, 20, 30}, []int64{20, 30, 40, 50})}))
	// Three queriers over the same series, all overlapping.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20, 30)}}),
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(1000, 10, 20, 30, 40)}}),
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(2000, 20, 30, 40, 50)}}),
	}}))
	// Four queriers, two of them carrying an IDENTICAL series (same timestamps, same values).
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		block(seriesSetSeries{Labels: L("__name__", "t"), Chunks: [][][2]int64{chv(5, 5, 15)}}),
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 30, 40)}}),
	}}))

	// ---- 5. MULTI-CHUNK series, so the compacting chunk merger has overlaps to compact.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "m"), Chunks: [][][2]int64{
				chv(0, 0, 10, 20), chv(0, 40, 50, 60),
			}}),
			block(seriesSetSeries{Labels: L("__name__", "m"), Chunks: [][][2]int64{
				chv(0, 5, 15, 25), chv(0, 70, 80),
			}}),
		},
		ChunkMerger: "compact",
	}))
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "m"), Chunks: [][][2]int64{
				chv(0, 0, 10, 20), chv(0, 40, 50, 60),
			}}),
			block(seriesSetSeries{Labels: L("__name__", "m"), Chunks: [][][2]int64{
				chv(0, 5, 15, 25), chv(0, 70, 80),
			}}),
		},
		ChunkMerger: "concat",
	}))
	// PERFECT DUPLICATES: same bounds, same bytes. The compacting merger skips them without
	// decoding, so the output is one chunk with the ORIGINAL bytes rather than a re-encoded one.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "d"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "d"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "d"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		},
		ChunkMerger: "compact",
	}))
	// Adjacent but NOT overlapping: `next.MinTime > oMaxTime` breaks immediately, so nothing is
	// re-encoded even though both chunks belong to the same series.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "adj"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "adj"), Chunks: [][][2]int64{chv(0, 21, 30, 40)}}),
		},
		ChunkMerger: "compact",
	}))
	// TOUCHING at one timestamp: `next.MinTime == oMaxTime` does NOT break, so this compacts.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "touch"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "touch"), Chunks: [][][2]int64{chv(0, 20, 30, 40)}}),
		},
		ChunkMerger: "compact",
	}))
	// More than 120 samples in one compacted run, so `seriesToChunkEncoderSplit` cuts.
	{
		var ts1, ts2 []int64
		for i := int64(0); i < 90; i++ {
			ts1 = append(ts1, i*2)
			ts2 = append(ts2, i*2+1)
		}
		emit(base(mergeIn{
			Maxt: 1000,
			Sources: []mergeSource{
				block(seriesSetSeries{Labels: L("__name__", "big"), Chunks: [][][2]int64{chv(0, ts1...)}}),
				block(seriesSetSeries{Labels: L("__name__", "big"), Chunks: [][][2]int64{chv(500, ts2...)}}),
			},
			ChunkMerger: "compact",
		}))
	}

	// ---- 6. SelectHints.Limit — `genericMergeSeriesSet` counts MERGED series, not input series.
	manySeries := func(prefix string, n int, base int64) mergeSource {
		ss := []seriesSetSeries{}
		for i := 0; i < n; i++ {
			ss = append(ss, seriesSetSeries{
				Labels: L("__name__", fmt.Sprintf("%s%02d", prefix, i)),
				Chunks: [][][2]int64{chv(base, 0, 10, 20)},
			})
		}
		return block(ss...)
	}
	for _, lim := range []int{0, 1, 2, 3, 5, 20} {
		emit(base(mergeIn{
			Sources: []mergeSource{manySeries("a", 4, 0), manySeries("b", 4, 100)},
			Limit:   lim,
		}))
	}
	// Two queriers carrying the SAME four series: with a limit of 3 the merge returns three MERGED
	// series, not three of the eight inputs.
	emit(base(mergeIn{
		Sources: []mergeSource{manySeries("a", 4, 0), manySeries("a", 4, 0)},
		Limit:   3,
	}))
	// Nil hints, so the limit never arrives.
	emit(base(mergeIn{
		Sources:  []mergeSource{manySeries("a", 4, 0), manySeries("b", 4, 100)},
		Limit:    2,
		NilHints: true,
	}))

	// ---- 7. Matchers, so the merge composes with selection.
	twoJobs := []mergeSource{
		block(
			seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10)}},
			seriesSetSeries{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{chv(0, 0, 10)}},
		),
		block(
			seriesSetSeries{Labels: L("__name__", "a", "job", "y"), Chunks: [][][2]int64{chv(50, 20, 30)}},
			seriesSetSeries{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{chv(50, 20, 30)}},
		),
	}
	emit(base(mergeIn{Sources: twoJobs, Matchers: [][3]string{M("=", "job", "y")}}))
	emit(base(mergeIn{Sources: twoJobs, Matchers: [][3]string{M("=", "job", "nosuch")}}))
	emit(base(mergeIn{Sources: twoJobs, Matchers: [][3]string{M("=~", "__name__", "a|b")}}))

	// ---- 8. EMPTY queriers alongside a block: the empty ones never enter the heap.
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub"},
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub"},
	}}))
	// A block with no series at all.
	emit(base(mergeIn{Sources: []mergeSource{
		block(),
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
	}}))

	// ---- 9. ERRORS. One erroring primary only; see the determinism note.
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", SelectErr: "boom in select"},
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
	}}))
	// The erroring querier LAST, so the pre-advance reaches it after a successful one.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub", SelectErr: "boom in select"},
	}}))
	// The SAME error from a SECONDARY: demoted to a warning, and the merge still returns the
	// primary's series.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		secondary(mergeSource{Kind: "stub", SelectErr: "boom in select"}),
	}}))
	// Label-query errors, primary and secondary.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub", LabelErr: "boom in labels", Values: []string{"z"}, Names: []string{"z"}},
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		secondary(mergeSource{Kind: "stub", LabelErr: "boom in labels"}),
	}}))
	// A label-query error alongside a WARNING from another querier: the wrapper drops the warning.
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", LabelWarn: "careful", Values: []string{"a"}, Names: []string{"a"}},
		{Kind: "stub", LabelErr: "boom in labels"},
		{Kind: "stub", Values: []string{"b"}, Names: []string{"b"}},
	}}))
	// Close errors, from one querier and from two.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub", CloseErr: "close failed"},
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", CloseErr: "close failed 1"},
		{Kind: "stub", CloseErr: "close failed 2"},
		{Kind: "stub"},
	}}))
	// A SECONDARY's Close error is NOT demoted.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		secondary(mergeSource{Kind: "stub", CloseErr: "close failed"}),
	}}))

	// ---- 10. WARNINGS, from one side only and from both.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub", SelectWarn: "select warning", LabelWarn: "label warning", Values: []string{"w"}, Names: []string{"w"}},
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", SelectWarn: "warn one", LabelWarn: "lwarn one", Values: []string{"a"}, Names: []string{"a"}},
		{Kind: "stub", SelectWarn: "warn two", LabelWarn: "lwarn two", Values: []string{"b"}, Names: []string{"b"}},
	}}))
	// The SAME warning message from two queriers: `Annotations` deduplicates on the message.
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", SelectWarn: "same", LabelWarn: "same", Values: []string{"a"}, Names: []string{"a"}},
		{Kind: "stub", SelectWarn: "same", LabelWarn: "same", Values: []string{"b"}, Names: []string{"b"}},
	}}))
	// A secondary that merely runs out becomes a warnings-only set carrying its own warnings.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		secondary(mergeSource{Kind: "stub", SelectWarn: "secondary warning"}),
	}}))

	// ---- 11. mergeStrings and the label limits, on stubs with handcrafted lists.
	//
	// Stubs rather than blocks, because what has to be reached is `mergeResults`' SPLIT-BY-HALF
	// recursion and the three `truncateToLimit` calls per level — which depend on the querier COUNT
	// and on the exact value lists, neither of which a block gives control over.
	vals := func(v ...string) mergeSource {
		return mergeSource{Kind: "stub", Values: v, Names: v}
	}
	for _, lim := range []int{0, 1, 2, 3, 4, 7} {
		emit(base(mergeIn{
			Sources:    []mergeSource{vals("a", "b", "c"), vals("b", "c", "d")},
			LabelLimit: lim,
		}))
		emit(base(mergeIn{
			Sources:    []mergeSource{vals("a", "d"), vals("b", "e"), vals("c", "f")},
			LabelLimit: lim,
		}))
		emit(base(mergeIn{
			Sources: []mergeSource{
				vals("a", "b"), vals("c", "d"), vals("e", "f"), vals("g", "h"),
			},
			LabelLimit: lim,
		}))
		emit(base(mergeIn{
			Sources: []mergeSource{
				vals("a"), vals("b"), vals("c"), vals("d"), vals("e"),
			},
			LabelLimit: lim,
		}))
	}
	// Fully disjoint versus fully identical, so the de-duplication is visible in the count.
	emit(base(mergeIn{Sources: []mergeSource{vals("a", "b", "c"), vals("a", "b", "c")}}))
	emit(base(mergeIn{Sources: []mergeSource{vals("x", "y"), vals("a", "b")}}))
	// One side empty.
	emit(base(mergeIn{Sources: []mergeSource{vals(), vals("a", "b")}}))
	emit(base(mergeIn{Sources: []mergeSource{vals("a", "b"), vals()}}))
	// Nil label hints, so no truncation happens at all.
	emit(base(mergeIn{
		Sources:       []mergeSource{vals("a", "b", "c"), vals("b", "c", "d")},
		LabelLimit:    2,
		NilLabelHints: true,
	}))
	// Real blocks, so the label values are the index's own.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(
				seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0)}},
				seriesSetSeries{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{chv(0, 0)}},
			),
			block(
				seriesSetSeries{Labels: L("__name__", "c", "job", "y"), Chunks: [][][2]int64{chv(0, 0)}},
				seriesSetSeries{Labels: L("__name__", "d", "job", "z"), Chunks: [][][2]int64{chv(0, 0)}},
			),
		},
		LabelName: "job",
	}))
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "a", "job", "x", "inst", "1"), Chunks: [][][2]int64{chv(0, 0)}}),
			block(seriesSetSeries{Labels: L("__name__", "b", "job", "y", "zone", "2"), Chunks: [][][2]int64{chv(0, 0)}}),
		},
		LabelName:  "job",
		LabelLimit: 1,
	}))

	// ---- 12. Mixed primaries and secondaries with real data on both sides. No duplicate
	// timestamps with differing values, so the goroutine order cannot show.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a", "job", "x"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		secondary(block(seriesSetSeries{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{chv(100, 5, 15, 25)}})),
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		secondary(block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(50, 30, 40, 50)}})),
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
		secondary(block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}})),
	}}))

	// ---- 13. Query ranges that trim, so the merge sees partially-empty inputs.
	trimmable := []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(0, 0, 10, 20, 30, 40)}}),
		block(seriesSetSeries{Labels: L("__name__", "s"), Chunks: [][][2]int64{chv(100, 5, 15, 25, 35, 45)}}),
	}
	emit(base(mergeIn{Sources: trimmable, Mint: 12, Maxt: 33}))
	emit(base(mergeIn{Sources: trimmable, Mint: 0, Maxt: 0}))
	emit(base(mergeIn{Sources: trimmable, Mint: 46, Maxt: 100}))
	emit(base(mergeIn{Sources: trimmable, Mint: 20, Maxt: 20}))

	// ---- 14. Cases added to close negative controls the first sweep left surviving.

	// The CHUNK HEAP's tie-break, which orders equal min times by max time. Two chunks starting at
	// the same timestamp with different values, so which one becomes `curr` and which joins
	// `overlapping` decides the merged values. Primaries only: this is a tie-break, which is
	// exactly what the goroutine order would otherwise decide.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "tie"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "tie"), Chunks: [][][2]int64{chv(1000, 0, 10, 20, 30, 40)}}),
		},
		ChunkMerger: "compact",
	}))
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "tie3"), Chunks: [][][2]int64{chv(0, 0, 10, 20, 30, 40, 50)}}),
			block(seriesSetSeries{Labels: L("__name__", "tie3"), Chunks: [][][2]int64{chv(1000, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "tie3"), Chunks: [][][2]int64{chv(2000, 0, 10, 20, 30)}}),
		},
		ChunkMerger: "compact",
	}))

	// SAME BOUNDS, DIFFERENT BYTES — the perfect-duplicate test's second half. A merger that
	// compared only the bounds would drop the second chunk entirely.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "samebounds"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "samebounds"), Chunks: [][][2]int64{chv(1000, 0, 5, 20)}}),
		},
		ChunkMerger: "compact",
	}))

	// NESTED chunks — one chunk entirely inside another. This is the only shape that separates
	// `chunkIteratorHeap.Less`'s min-time ordering from a max-time one: for any two chunks where
	// neither contains the other, the two orders agree. A control that ordered by max time survived
	// the first sweep for exactly that reason.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "nested"), Chunks: [][][2]int64{chv(0, 0, 10, 20, 30, 40, 50)}}),
			block(seriesSetSeries{Labels: L("__name__", "nested"), Chunks: [][][2]int64{chv(1000, 10, 15, 20)}}),
		},
		ChunkMerger: "compact",
	}))
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "nested2"), Chunks: [][][2]int64{
				chv(0, 0, 10, 20, 30, 40, 50), chv(0, 60, 70),
			}}),
			block(seriesSetSeries{Labels: L("__name__", "nested2"), Chunks: [][][2]int64{
				chv(1000, 10, 15, 20), chv(1000, 25, 35),
			}}),
		},
		ChunkMerger: "compact",
	}))

	// TRANSITIVE overlap: C does not touch A, but B overlaps both, so all three join one run.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "trans"), Chunks: [][][2]int64{chv(0, 0, 10, 20)}}),
			block(seriesSetSeries{Labels: L("__name__", "trans"), Chunks: [][][2]int64{chv(1000, 15, 25, 35)}}),
			block(seriesSetSeries{Labels: L("__name__", "trans"), Chunks: [][][2]int64{chv(2000, 30, 40, 50)}}),
		},
		ChunkMerger: "compact",
	}))

	// PERFECT DUPLICATES longer than one re-encoded chunk. Skipping them yields the original
	// 130-sample chunk; merging them instead would re-encode into 120 + 10, so the skip is now
	// observable in the chunk COUNT rather than only in bytes that happen to agree.
	{
		var ts []int64
		for i := int64(0); i < 130; i++ {
			ts = append(ts, i)
		}
		emit(base(mergeIn{
			Maxt: 1000,
			Sources: []mergeSource{
				block(seriesSetSeries{Labels: L("__name__", "dup130"), Chunks: [][][2]int64{chv(0, ts...)}}),
				block(seriesSetSeries{Labels: L("__name__", "dup130"), Chunks: [][][2]int64{chv(0, ts...)}}),
			},
			ChunkMerger: "compact",
		}))
		// The same 130-sample chunk in ONE querier only, alongside a disjoint series: nothing
		// overlaps, so the early return keeps it whole rather than re-encoding it into 120 + 10.
		emit(base(mergeIn{
			Maxt: 1000,
			Sources: []mergeSource{
				block(seriesSetSeries{Labels: L("__name__", "solo130"), Chunks: [][][2]int64{chv(0, ts...)}}),
				block(seriesSetSeries{Labels: L("__name__", "zother"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
			},
			ChunkMerger: "compact",
		}))
	}

	// A set that yields series and THEN errors — the only route to `genericMergeSeriesSet.Err()`.
	// Note what it pins: the merge keeps returning the OTHER queriers' series and reports the
	// failure only through `Err()`, so a caller that ignores `Err()` silently sees a partial answer.
	emit(base(mergeIn{Sources: []mergeSource{
		block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
		{Kind: "stub", ErrAfter: 2, SelectErr: "boom after two"},
	}}))
	emit(base(mergeIn{Sources: []mergeSource{
		{Kind: "stub", ErrAfter: 3, SelectErr: "boom after three"},
		block(seriesSetSeries{Labels: L("__name__", "zz"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
	}}))
	// The same, with the series limit biting BEFORE the erroring set runs out: `Err()` still
	// reports, because it walks the sets rather than the iteration.
	emit(base(mergeIn{
		Sources: []mergeSource{
			block(seriesSetSeries{Labels: L("__name__", "a"), Chunks: [][][2]int64{chv(0, 0, 10)}}),
			{Kind: "stub", ErrAfter: 3, SelectErr: "boom after three"},
		},
		Limit: 1,
	}))
}
