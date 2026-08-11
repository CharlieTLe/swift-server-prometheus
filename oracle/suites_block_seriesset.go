package main

// Differential coverage for `blockBaseSeriesSet.Next` — the step from a postings list to selected series.
//
// The seam is `tsdb.NewBlockChunkSeriesSet`, which is EXPORTED and takes exactly the pieces a real block
// hands over (`b.Index()`, `b.Chunks()`, `b.Tombstones()`), so this drives upstream's own set over upstream's
// own block. `oracle/blockfixture.go` writes the block.
//
// What has to be reached:
//
//   - the THREE skip rules, which are the interesting part because each makes a ref vanish silently rather
//     than error: a series with no chunks, a series whose chunks are all out of range, and (unreachable from
//     a written block, so noted rather than covered) a stale postings ref.
//   - the STRICT boundary comparisons. Chunk ranges and requested ranges are both CLOSED, so `chk.MaxTime <
//     mint` and `chk.MinTime > maxt` keep a chunk that merely touches a boundary. Cases put chunk edges
//     exactly on `mint` and `maxt`, one step inside and one step outside.
//   - the trimming flags, which are set only for KEPT chunks and only when `disableTrimming` is false. Both
//     settings of the flag are recorded for every query, because it is the only way to see that the flag
//     changes what `Next` decides rather than only what a later iterator does.
//   - series ORDER, which is the postings order, which for a block is by series ref — and refs are assigned
//     in label-set order by the writer, so the two coincide and a port that sorted by labels would pass. The
//     cases therefore include a block whose label order and ref order differ (see below).
//
// The observable output is deliberately narrow: the label sets of the selected series, in order, plus the
// error. **The chunk METAS are not recorded, and that is a scoping decision rather than an oversight.** They
// come out of `populateWithDelChunkSeriesIterator` — the next slice — and they are where the trimming becomes
// visible (a query at [120,120] against a chunk spanning [100,120] yields a meta of [120,120] with trimming
// on and [100,120] with it off). Recording them here would mean the port had to implement that iterator to
// make this suite pass, which is the opposite of slicing. This suite is extended when the iterator lands.
//
// So `disableTrimming` is still passed both ways for every query, because `Next`'s own decisions depend on it
// — a chunk fully outside the range is skipped either way, but the flag decides whether the synthetic
// intervals are added, and a port that ignored the flag entirely would build the wrong `SeriesData`.

import (
	"context"
	"fmt"
	"os"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/index"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

type seriesSetIn struct {
	// One entry per series: labels as a flat name/value list, then the chunks, each a list of [t, v] pairs.
	Series []seriesSetSeries `json:"series"`
	// One entry per query.
	Queries []seriesSetQuery `json:"queries"`
	// The block's files, hex. INPUT — Go writes them, the port reads them.
	IndexHex string   `json:"indexHex"`
	MetaHex  string   `json:"metaHex"`
	SegHexes []string `json:"segHexes"`
}

type seriesSetSeries struct {
	Labels [][2]string  `json:"labels"`
	Chunks [][][2]int64 `json:"chunks"`
}

type seriesSetQuery struct {
	Mint     int64       `json:"mint"`
	Maxt     int64       `json:"maxt"`
	Matchers [][3]string `json:"matchers"`
	// Both settings are run for every query; this field selects which one this entry records.
	DisableTrimming bool `json:"disableTrimming"`
}

type seriesSetOut struct {
	// Per query: the label sets of the selected series, in the order returned.
	LabelSets [][]string `json:"labelSets"`
	Errs      []string   `json:"errs"`
	OpenErr   string     `json:"openErr"`
}

func genBlockSeriesSet(e *emitter) {
	n := 0
	emit := func(in seriesSetIn) {
		out := seriesSetOut{LabelSets: [][]string{}, Errs: []string{}}

		dir, err := os.MkdirTemp("", "blockss")
		if err != nil {
			out.OpenErr = err.Error()
			e.emit(fmt.Sprintf("blockseriesset/%d", n), in, out)
			n++
			return
		}
		defer os.RemoveAll(dir)

		series := []blockSeries2{}
		for _, s := range in.Series {
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
			e.emit(fmt.Sprintf("blockseriesset/%d", n), in, out)
			n++
			return
		}
		defer b.Close()
		in.IndexHex, in.MetaHex, in.SegHexes = ih, mh, sh

		for _, q := range in.Queries {
			ir, ierr := b.Index()
			if ierr != nil {
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, ierr.Error())
				continue
			}
			cr, cerr := b.Chunks()
			if cerr != nil {
				ir.Close()
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, cerr.Error())
				continue
			}
			tr, terr := b.Tombstones()
			if terr != nil {
				ir.Close()
				cr.Close()
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, terr.Error())
				continue
			}

			ms := make([]*labels.Matcher, 0, len(q.Matchers))
			bad := ""
			for _, spec := range q.Matchers {
				m, merr := parsePFMMatcher(spec)
				if merr != nil {
					bad = merr.Error()
					break
				}
				ms = append(ms, m)
			}
			if bad == "" && len(ms) == 0 {
				// No matchers means "everything": the all-postings key.
				k, v := index.AllPostingsKey()
				p, perr := ir.Postings(context.Background(), k, v)
				if perr != nil {
					bad = perr.Error()
				} else {
					bad = runSeriesSet(&out, b, ir, cr, tr, p, q)
				}
			} else if bad == "" {
				p, perr := tsdb.PostingsForMatchers(context.Background(), ir, ms...)
				if perr != nil {
					bad = perr.Error()
				} else {
					bad = runSeriesSet(&out, b, ir, cr, tr, p, q)
				}
			}
			if bad != "" {
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, bad)
			}
			ir.Close()
			cr.Close()
			tr.Close()
		}

		e.emit(fmt.Sprintf("blockseriesset/%d", n), in, out)
		n++
	}

	// Helpers for building cases.
	L := func(pairs ...string) [][2]string {
		out := [][2]string{}
		for i := 0; i+1 < len(pairs); i += 2 {
			out = append(out, [2]string{pairs[i], pairs[i+1]})
		}
		return out
	}
	ch := func(ts ...int64) [][2]int64 {
		out := [][2]int64{}
		for i, t := range ts {
			out = append(out, [2]int64{t, int64(i)})
		}
		return out
	}
	M := func(t, nm, v string) [3]string { return [3]string{t, nm, v} }

	// Both trimming settings for every query, so the flag's effect on `Next` is visible.
	both := func(qs ...seriesSetQuery) []seriesSetQuery {
		out := []seriesSetQuery{}
		for _, q := range qs {
			a := q
			a.DisableTrimming = false
			bq := q
			bq.DisableTrimming = true
			out = append(out, a, bq)
		}
		return out
	}
	q := func(mint, maxt int64, ms ...[3]string) seriesSetQuery {
		return seriesSetQuery{Mint: mint, Maxt: maxt, Matchers: ms}
	}

	// Chunks at [0,20], [30,50], [60,80] — so boundaries are easy to place exactly.
	threeChunks := [][][2]int64{ch(0, 10, 20), ch(30, 40, 50), ch(60, 70, 80)}

	// A series with NO CHUNKS AT ALL — the shape a compactor produces for a series whose every chunk was
	// deleted. `index.Writer.AddSeries` accepts a series with no chunk metas, so the block is legal.
	//
	// These were added to close a surviving control (removing skip rule 2) and DID NOT close it, which turned
	// out to be the right answer: rules 2 and 3 are redundant for a chunk-less series, since an empty
	// `bufChks` makes the prefilter append nothing and rule 3 skips it anyway. Kept because they exercise the
	// shape, and because removing rule 3 does break — the redundancy runs one way only.
	withChunkless := []seriesSetSeries{
		{Labels: L("__name__", "empty"), Chunks: [][][2]int64{}},
		{Labels: L("__name__", "full"), Chunks: [][][2]int64{ch(0, 10, 20)}},
		{Labels: L("__name__", "zempty2"), Chunks: [][][2]int64{}},
	}
	emit(seriesSetIn{Series: withChunkless, Queries: both(
		q(0, 100), q(0, 0), q(100, 200), q(0, 100, M("=~", "__name__", ".+")),
	)})

	base := []seriesSetSeries{
		{Labels: L("__name__", "a", "job", "x"), Chunks: threeChunks},
		{Labels: L("__name__", "b", "job", "y"), Chunks: [][][2]int64{ch(0, 10, 20)}},
		{Labels: L("__name__", "c", "job", "y"), Chunks: [][][2]int64{ch(60, 70, 80)}},
	}

	// The whole range, and ranges that exclude series entirely — skip rule 3.
	emit(seriesSetIn{Series: base, Queries: both(
		q(0, 100), q(0, 80), q(0, 0), q(80, 80), q(100, 200), q(-100, -1),
		q(0, 25), q(25, 55), q(55, 100), q(21, 29),
	)})

	// EXACT boundaries: chunk edges on mint and maxt, one step inside, one step outside. The comparisons
	// are strict, so a chunk touching a boundary is kept.
	emit(seriesSetIn{Series: base, Queries: both(
		q(20, 30), q(21, 29), q(19, 31), q(20, 20), q(30, 30),
		q(0, 19), q(0, 20), q(0, 21), q(80, 100), q(81, 100),
	)})

	// With matchers, so selection and the range filter compose.
	emit(seriesSetIn{Series: base, Queries: both(
		q(0, 100, M("=", "job", "y")),
		q(0, 25, M("=", "job", "y")),
		q(55, 100, M("=", "job", "y")),
		q(0, 100, M("=", "__name__", "a")),
		q(0, 100, M("=", "job", "nosuch")),
		q(30, 50, M("=", "job", "y")),
	)})

	// Series ORDER when label order and ref order coincide (they always do for a written block, since
	// `AddSeries` assigns refs in label order) — recorded so a later Head-based suite can contrast it.
	{
		many := []seriesSetSeries{}
		for i := range 8 {
			many = append(many, seriesSetSeries{
				Labels: L("__name__", "m", "i", fmt.Sprintf("%02d", 7-i)),
				Chunks: [][][2]int64{ch(int64(i)*10, int64(i)*10+5)},
			})
		}
		emit(seriesSetIn{Series: many, Queries: both(
			q(0, 100), q(0, 25), q(25, 50), q(70, 100), q(0, 100, M("=~", "i", "0.")),
		)})
	}

	// A single series with ONE chunk, and a query that lands entirely inside it — so trimming is needed at
	// both ends at once.
	emit(seriesSetIn{
		Series: []seriesSetSeries{
			{Labels: L("__name__", "one"), Chunks: [][][2]int64{ch(0, 10, 20, 30, 40, 50)}},
		},
		Queries: both(q(15, 35), q(0, 50), q(10, 40), q(20, 20), q(51, 60)),
	})

	// Many chunks on one series, so the prefilter keeps a middle subset.
	{
		chunks := [][][2]int64{}
		for i := range 10 {
			base := int64(i) * 100
			chunks = append(chunks, ch(base, base+10, base+20))
		}
		emit(seriesSetIn{
			Series:  []seriesSetSeries{{Labels: L("__name__", "many"), Chunks: chunks}},
			Queries: both(q(0, 1000), q(250, 650), q(120, 120), q(115, 125), q(950, 2000)),
		})
	}
}

// runSeriesSet drives the set and appends one query's worth of output. Returns an error string, or "".
func runSeriesSet(
	out *seriesSetOut, b *tsdb.Block, ir tsdb.IndexReader, cr tsdb.ChunkReader,
	tr tombstones.Reader, p index.Postings, q seriesSetQuery,
) string {
	ss := tsdb.NewBlockChunkSeriesSet(
		b.Meta().ULID, ir, cr, tr, p, q.Mint, q.Maxt, q.DisableTrimming)

	sets := []string{}
	for ss.Next() {
		s := ss.At()
		sets = append(sets, s.Labels().String())
	}
	out.LabelSets = append(out.LabelSets, sets)
	if ss.Err() != nil {
		out.Errs = append(out.Errs, ss.Err().Error())
	} else {
		out.Errs = append(out.Errs, "")
	}
	return ""
}
