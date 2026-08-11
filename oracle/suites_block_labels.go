package main

// Differential coverage for `labelValuesWithMatchers` and `labelNamesWithMatchers`, reached the only honest
// way: through a REAL block, opened by `tsdb.OpenBlock`, queried through `tsdb.NewBlockQuerier`.
//
// **Why not an adapter.** Both functions are unexported. The obvious shortcut is a type satisfying
// `tsdb.BlockReader` by delegating to `index.Reader`, but `Block.Index()` returns `blockIndexReader`, and
// `blockIndexReader.LabelValues` is precisely what decides between `ir.LabelValues` (no matchers) and
// `labelValuesWithMatchers` (matchers). An adapter returning the raw reader would bypass the code under
// test; an adapter reproducing `blockIndexReader` would put upstream logic in the oracle. So the oracle
// writes the three files a block is and lets upstream open it — see `blockfixture.go`.
//
// What has to be reached:
//
//   - the NO-MATCHERS path, which does not go through `labelValuesWithMatchers` at all, so it is the control
//     for the others rather than a case in its own right;
//   - the "matcher on the queried name" filter, which prunes values BEFORE fetching postings — upstream's
//     comment cites `__name__` with `{__name__="xyz"}`, and it reuses `allValues[:0]` in place, a pattern
//     that is safe only because the read index stays ahead of the write index;
//   - `hasMatchersForOtherLabels == false`, which returns the filtered values WITHOUT touching postings, and
//     applies the limit there;
//   - the `FindIntersectingPostings` path, where the limit is applied while collecting rather than by
//     truncating — so a limit interacts with which values survive;
//   - `len(allValues) == 0` returning nil EARLY, before postings;
//   - `SortedLabelValues` versus `LabelValues`: with matchers the former sorts the latter's output, so the
//     two differ in order and the corpus records both.
//
// `LabelNames` is thinner but has its own asymmetry: with no matchers it goes to `b.LabelNames()`, with
// matchers to `labelNamesWithMatchers` → `PostingsForMatchers` → `LabelNamesFor`. And the LIMIT is applied by
// `blockBaseQuerier.LabelNames` after the fact, not inside.

import (
	"context"
	"fmt"
	"os"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
)

type labelQueryIn struct {
	// One entry per series: a flat list of name/value pairs.
	Series [][]string `json:"series"`
	// `LabelValues` queries: name, then a limit (0 = none), then the matchers.
	ValueQueries []labelValueQuery `json:"valueQueries"`
	// `LabelNames` queries: a limit and the matchers.
	NameQueries []labelNameQuery `json:"nameQueries"`
	// The block's files, hex. INPUT: Go writes them, the port reads them.
	IndexHex string   `json:"indexHex"`
	MetaHex  string   `json:"metaHex"`
	SegHexes []string `json:"segHexes"`
}

type labelValueQuery struct {
	Name     string      `json:"name"`
	Limit    int         `json:"limit"`
	Matchers [][3]string `json:"matchers"`
}

type labelNameQuery struct {
	Limit    int         `json:"limit"`
	Matchers [][3]string `json:"matchers"`
}

type labelQueryOut struct {
	// Per value query: the values `Querier.LabelValues` returned (which is SortedLabelValues), and the
	// values `IndexReader.LabelValues` returned (unsorted), so the sort is visible as a difference.
	Values       [][]string `json:"values"`
	ValuesUnsort [][]string `json:"valuesUnsort"`
	ValueErrs    []string   `json:"valueErrs"`
	Names        [][]string `json:"names"`
	NameErrs     []string   `json:"nameErrs"`
	OpenErr      string     `json:"openErr"`
}

func genBlockLabelQueries(e *emitter) {
	n := 0
	emit := func(in labelQueryIn) {
		out := labelQueryOut{
			Values: [][]string{}, ValuesUnsort: [][]string{}, ValueErrs: []string{},
			Names: [][]string{}, NameErrs: []string{},
		}

		dir, err := os.MkdirTemp("", "blockq")
		if err != nil {
			out.OpenErr = err.Error()
			e.emit(fmt.Sprintf("blocklabels/%d", n), in, out)
			n++
			return
		}
		defer os.RemoveAll(dir)

		series := []blockSeries2{}
		for i, flat := range in.Series {
			series = append(series, blockSeries2{
				Labels: labels.FromStrings(flat...),
				// One trivial chunk each: these queries never read samples, but a block with no chunks at
				// all is a different shape and not the one under test.
				Chunks: [][]blockSample{{{T: int64(i) * 1000, V: float64(i)}}},
			})
		}

		b, ih, mh, sh, err := openOracleBlock(dir, series)
		if err != nil {
			out.OpenErr = err.Error()
			e.emit(fmt.Sprintf("blocklabels/%d", n), in, out)
			n++
			return
		}
		defer b.Close()
		in.IndexHex, in.MetaHex, in.SegHexes = ih, mh, sh

		q, err := tsdb.NewBlockQuerier(b, b.Meta().MinTime, b.Meta().MaxTime)
		if err != nil {
			out.OpenErr = err.Error()
			e.emit(fmt.Sprintf("blocklabels/%d", n), in, out)
			n++
			return
		}
		defer q.Close()
		ir, err := b.Index()
		if err != nil {
			out.OpenErr = err.Error()
			e.emit(fmt.Sprintf("blocklabels/%d", n), in, out)
			n++
			return
		}
		defer ir.Close()

		for _, vq := range in.ValueQueries {
			ms := make([]*labels.Matcher, 0, len(vq.Matchers))
			bad := ""
			for _, spec := range vq.Matchers {
				m, merr := parsePFMMatcher(spec)
				if merr != nil {
					bad = merr.Error()
					break
				}
				ms = append(ms, m)
			}
			if bad != "" {
				out.Values = append(out.Values, []string{})
				out.ValuesUnsort = append(out.ValuesUnsort, []string{})
				out.ValueErrs = append(out.ValueErrs, bad)
				continue
			}
			var hints *storage.LabelHints
			if vq.Limit > 0 {
				hints = &storage.LabelHints{Limit: vq.Limit}
			}
			vals, _, verr := q.LabelValues(context.Background(), vq.Name, hints, ms...)
			if vals == nil {
				vals = []string{}
			}
			out.Values = append(out.Values, vals)
			// The UNSORTED form, straight off the index reader, so the sort that
			// `SortedLabelValues` applies is visible as a difference rather than invisible.
			uvals, uerr := ir.LabelValues(context.Background(), vq.Name, hints, ms...)
			if uvals == nil {
				uvals = []string{}
			}
			out.ValuesUnsort = append(out.ValuesUnsort, uvals)
			switch {
			case verr != nil:
				out.ValueErrs = append(out.ValueErrs, verr.Error())
			case uerr != nil:
				out.ValueErrs = append(out.ValueErrs, uerr.Error())
			default:
				out.ValueErrs = append(out.ValueErrs, "")
			}
		}

		for _, nq := range in.NameQueries {
			ms := make([]*labels.Matcher, 0, len(nq.Matchers))
			bad := ""
			for _, spec := range nq.Matchers {
				m, merr := parsePFMMatcher(spec)
				if merr != nil {
					bad = merr.Error()
					break
				}
				ms = append(ms, m)
			}
			if bad != "" {
				out.Names = append(out.Names, []string{})
				out.NameErrs = append(out.NameErrs, bad)
				continue
			}
			var hints *storage.LabelHints
			if nq.Limit > 0 {
				hints = &storage.LabelHints{Limit: nq.Limit}
			}
			names, _, nerr := q.LabelNames(context.Background(), hints, ms...)
			if names == nil {
				names = []string{}
			}
			out.Names = append(out.Names, names)
			if nerr != nil {
				out.NameErrs = append(out.NameErrs, nerr.Error())
			} else {
				out.NameErrs = append(out.NameErrs, "")
			}
		}

		e.emit(fmt.Sprintf("blocklabels/%d", n), in, out)
		n++
	}

	M := func(t, nm, v string) [3]string { return [3]string{t, nm, v} }
	vq := func(name string, limit int, ms ...[3]string) labelValueQuery {
		return labelValueQuery{Name: name, Limit: limit, Matchers: ms}
	}
	nq := func(limit int, ms ...[3]string) labelNameQuery {
		return labelNameQuery{Limit: limit, Matchers: ms}
	}

	base := [][]string{
		{"__name__", "up", "job", "api", "l", "a"},
		{"__name__", "up", "job", "api", "l", "b"},
		{"__name__", "up", "job", "web", "l", "ab"},
		{"__name__", "up", "job", "web"},
		{"__name__", "down", "job", "web", "l", ""},
		{"__name__", "down", "job", "db", "l", "1"},
		{"__name__", "down", "l", "2"},
	}

	// No matchers: the path that does NOT go through `labelValuesWithMatchers`. The control for the rest.
	emit(labelQueryIn{Series: base, ValueQueries: []labelValueQuery{
		vq("__name__", 0), vq("job", 0), vq("l", 0), vq("nosuch", 0),
		vq("__name__", 1), vq("job", 2), vq("l", 100),
	}, NameQueries: []labelNameQuery{nq(0), nq(1), nq(2), nq(100)}})

	// A matcher ON the queried name, which prunes values before any postings are fetched.
	emit(labelQueryIn{Series: base, ValueQueries: []labelValueQuery{
		vq("l", 0, M("=", "l", "a")),
		vq("l", 0, M("=~", "l", "a|b")),
		vq("l", 0, M("!=", "l", "a")),
		vq("l", 0, M("=~", "l", "a.*")),
		vq("l", 0, M("=", "l", "zzz")),
		// Two matchers on the queried name: the filter runs once per matcher, reusing the slice.
		vq("l", 0, M("=~", "l", "a.*"), M("!=", "l", "ab")),
		vq("__name__", 0, M("=", "__name__", "up")),
		vq("__name__", 0, M("=~", "__name__", "up|down")),
	}})

	// Matchers on OTHER labels only, which is the `FindIntersectingPostings` path.
	emit(labelQueryIn{Series: base, ValueQueries: []labelValueQuery{
		vq("l", 0, M("=", "job", "api")),
		vq("l", 0, M("=", "job", "web")),
		vq("l", 0, M("=", "__name__", "down")),
		vq("l", 0, M("=", "job", "nosuch")),
		vq("job", 0, M("=", "l", "a")),
		vq("job", 0, M("=~", "l", "a|b|ab")),
		vq("__name__", 0, M("=", "job", "web")),
	}})

	// BOTH: a matcher on the queried name AND on another, so the filter runs and then the intersection.
	emit(labelQueryIn{Series: base, ValueQueries: []labelValueQuery{
		vq("l", 0, M("=~", "l", "a.*"), M("=", "job", "api")),
		vq("l", 0, M("=~", "l", "a.*"), M("=", "job", "web")),
		vq("l", 0, M("!=", "l", ""), M("=", "__name__", "up")),
		vq("job", 0, M("=", "job", "api"), M("=", "l", "b")),
	}})

	// LIMITS, which are applied in two DIFFERENT places: by truncation when there are no other-label
	// matchers, and while collecting when there are. So the same limit can keep different values.
	emit(labelQueryIn{Series: base, ValueQueries: []labelValueQuery{
		vq("l", 1, M("=~", "l", "a.*")),
		vq("l", 2, M("=~", "l", "a.*")),
		vq("l", 1, M("=", "job", "api")),
		vq("l", 2, M("=", "job", "api")),
		vq("l", 1, M("=~", "l", "a.*"), M("=", "job", "api")),
		vq("l", 99, M("=", "job", "api")),
	}, NameQueries: []labelNameQuery{
		nq(0, M("=", "job", "api")),
		nq(1, M("=", "job", "api")),
		nq(2, M("=", "job", "api")),
		nq(0, M("=", "__name__", "down")),
		nq(0, M("=", "job", "nosuch")),
		nq(0, M("=~", "l", ".+")),
	}})

	// Many values, so the pruning matters and the sorted/unsorted difference is visible.
	{
		many := [][]string{}
		for i := range 30 {
			many = append(many, []string{
				"__name__", "m", "l", fmt.Sprintf("v%02d", 29-i),
				"grp", fmt.Sprintf("g%d", i%3),
			})
		}
		emit(labelQueryIn{Series: many, ValueQueries: []labelValueQuery{
			vq("l", 0),
			vq("l", 0, M("=~", "l", "v0.")),
			vq("l", 0, M("=", "grp", "g0")),
			vq("l", 0, M("=~", "l", "v1."), M("=", "grp", "g1")),
			vq("l", 5, M("=", "grp", "g0")),
			vq("l", 5, M("=~", "l", "v0.")),
			vq("grp", 0, M("=~", "l", "v0.")),
		}, NameQueries: []labelNameQuery{nq(0, M("=", "grp", "g2"))}})
	}

	// A single series, and a name that only some series carry.
	emit(labelQueryIn{Series: [][]string{{"__name__", "only", "x", "1"}},
		ValueQueries: []labelValueQuery{
			vq("x", 0), vq("x", 0, M("=", "__name__", "only")),
			vq("x", 0, M("=", "__name__", "nope")), vq("y", 0),
		},
		NameQueries: []labelNameQuery{nq(0), nq(0, M("=", "x", "1"))}})
}
