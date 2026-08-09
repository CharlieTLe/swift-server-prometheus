package main

// Differential coverage for the Phase 5 in-memory Queryable
// (Sources/PromTestStorage). There is no Go file to port here — upstream's
// `util/teststorage` is a wrapper over a real `tsdb.DB` — so this suite pins the
// *contract* rather than an implementation: it stands up a real `tsdb.DB` through
// `util/teststorage`, appends a fixed dataset, runs one `Select`, and emits the
// series and samples that come back.
//
// What that pins, all of it upstream behaviour the port has to reproduce:
//   - `hints.Start`/`hints.End` OVERRIDE the querier's mint/maxt rather than
//     narrowing them (tsdb/querier.go:205).
//   - the requested range is CLOSED at both ends (querier.go:479).
//   - a series with no sample in range is ABSENT from the set, not present and
//     empty (querier.go:503, `if len(chks) == 0 { continue }`).
//   - `DisableTrimming` leaves samples outside the range in place.
//   - matcher semantics, including that a matcher matching "" selects series that
//     LACK the label entirely.
//   - `SortedPostings` order, which is label order.
//
// Two deliberate restrictions, each with a reason:
//
//  1. **Every case selects with sortSeries=true.** Unsorted order is genuinely
//     nondeterministic upstream and therefore not a contract: with everything in
//     the Head and no persisted block, `db.Querier` yields a single querier, so
//     merge.go's "we need to sort for merge to work" never fires and postings come
//     back in series-ref order — which is append order — and `promqltest` appends
//     by ranging a Go MAP (`promqltest/test.go:918`). Emitting an unsorted order
//     would invent a contract that upstream does not have. The port's own
//     insertion order is asserted Swift-side instead. docs/PORTING.md exception 11.
//
//  2. **Float samples only.** A histogram appended to a real `tsdb.DB` comes back
//     through the histogram CHUNK ENCODING, which re-derives `CounterResetHint`
//     from the chunk header and so does not hand back the value that went in.
//     Pinning that would pin Phases 6-7's subject, not this target's: the
//     in-memory store has no chunks and returns the sample it was given.
//     Histogram and float-histogram carriage is covered Swift-side.
//
// Two suites, because one fixture file holds one in/out shape (docs/HANDOFF.md §4):
//   storage/mem-select   Select
//   storage/mem-labels   LabelValues / LabelNames

import (
	"context"
	"fmt"
	"sort"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/util/annotations"
	"github.com/prometheus/prometheus/util/teststorage"
)

// ---------------------------------------------------------------- wire types

type memMatcherJSON struct {
	// "=", "!=", "=~" or "!~".
	Type  string `json:"type"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type memSeriesInJSON struct {
	// Flat name/value pairs, for labels.FromStrings.
	Labels []string `json:"labels"`
	// Parallel arrays: timestamp, start timestamp, and value as a hex bit
	// pattern. Same length.
	T  []string `json:"t"`
	ST []string `json:"st"`
	F  []string `json:"f"`
}

type memHintsJSON struct {
	Start           string `json:"start"`
	End             string `json:"end"`
	DisableTrimming bool   `json:"disableTrimming"`
}

type memSelectIn struct {
	// Append order, which is deliberately not label order.
	Series []memSeriesInJSON `json:"series"`
	Mint   string            `json:"mint"`
	Maxt   string            `json:"maxt"`
	// nil means Select is called with no hints at all, so the querier's own
	// mint/maxt apply.
	Hints    *memHintsJSON    `json:"hints"`
	Matchers []memMatcherJSON `json:"matchers"`
}

type memSampleOutJSON struct {
	T  string `json:"t"`
	ST string `json:"st"`
	F  string `json:"f"`
	// chunkenc.ValueType, so a case would notice a float coming back as
	// something else.
	Type int `json:"type"`
}

type memSeriesOutJSON struct {
	// labels.Labels.String(), already proved byte-identical in Phase 1.
	Labels  string             `json:"labels"`
	Samples []memSampleOutJSON `json:"samples"`
}

type memSelectOut struct {
	Series   []memSeriesOutJSON `json:"series"`
	Err      string             `json:"err"`
	Warnings []string           `json:"warnings"`
}

type memLabelsIn struct {
	Series []memSeriesInJSON `json:"series"`
	Mint   string            `json:"mint"`
	Maxt   string            `json:"maxt"`
	// "names" or "values".
	Kind string `json:"kind"`
	// Only for "values".
	Name     string           `json:"name"`
	Limit    int              `json:"limit"`
	Matchers []memMatcherJSON `json:"matchers"`
}

type memLabelsOut struct {
	Result   []string `json:"result"`
	Err      string   `json:"err"`
	Warnings []string `json:"warnings"`
}

// ------------------------------------------------------------------- helpers

func memMatchType(s string) labels.MatchType {
	switch s {
	case "=":
		return labels.MatchEqual
	case "!=":
		return labels.MatchNotEqual
	case "=~":
		return labels.MatchRegexp
	case "!~":
		return labels.MatchNotRegexp
	}
	panic("unknown match type " + s)
}

func buildMemMatchers(in []memMatcherJSON) []*labels.Matcher {
	out := make([]*labels.Matcher, 0, len(in))
	for _, m := range in {
		out = append(out, labels.MustNewMatcher(memMatchType(m.Type), m.Name, m.Value))
	}
	return out
}

// loadMemStorage stands up a real tsdb.DB and appends the dataset in the order
// given. The caller must Close it.
//
// The two options are exactly what `promqltest`'s own `init()` sets
// (promqltest/test_test.go:33), and the second one is load-bearing rather than
// cosmetic: **start timestamps survive only through the XOR2 chunk encoding.**
// `EnableSTStorage` is a noop at this pin — tsdb/db.go:247 says so in as many
// words, "TODO(bwplotka): Implement this option as per PROM-60, currently it's
// noop" — so with the default `EncXOR` encoding every sample reads back with
// `AtST() == 0` and `start_timestamps.test` could not pass. Setting it here is
// what makes the `st/carried` case pin ST carriage rather than pin ST loss.
func loadMemStorage(in []memSeriesInJSON) *teststorage.TestStorage {
	s, err := teststorage.NewWithError(func(opts *tsdb.Options) {
		opts.EnableSTStorage = true
		opts.FloatChunkEncoding = chunkenc.EncXOR2
	})
	if err != nil {
		panic(err)
	}
	ctx := context.Background()
	a := s.AppenderV2(ctx)
	for _, ser := range in {
		lset := labels.FromStrings(ser.Labels...)
		for i := range ser.T {
			_, err := a.Append(
				0, lset, parseI64(ser.ST[i]), parseI64(ser.T[i]), unfbits(ser.F[i]),
				nil, nil, storage.AppendV2Options{},
			)
			if err != nil {
				panic(fmt.Sprintf("append %s t=%s: %v", lset.String(), ser.T[i], err))
			}
		}
	}
	if err := a.Commit(); err != nil {
		panic(err)
	}
	return s
}

// Warnings and infos, concatenated and SORTED. `Annotations` is a Go map, so
// AsStrings' order is randomised (docs/PORTING.md exception 7); sorting keeps the
// fixture reproducible. In practice a tsdb querier returns none of either for
// these queries, so this exists to make an unexpected one visible rather than to
// pin an order.
func annotationStrings(annos annotations.Annotations) []string {
	warns, infos := annos.AsStrings("", 0, 0)
	out := []string{}
	out = append(out, warns...)
	out = append(out, infos...)
	sort.Strings(out)
	return out
}

// ------------------------------------------------------- storage/mem-select

func runMemSelect(in memSelectIn) memSelectOut {
	s := loadMemStorage(in.Series)
	defer s.Close()

	q, err := s.Querier(parseI64(in.Mint), parseI64(in.Maxt))
	if err != nil {
		panic(err)
	}
	defer q.Close()

	var hints *storage.SelectHints
	if in.Hints != nil {
		hints = &storage.SelectHints{
			Start:           parseI64(in.Hints.Start),
			End:             parseI64(in.Hints.End),
			DisableTrimming: in.Hints.DisableTrimming,
		}
	}

	// sortSeries=true, always. See the file header for why unsorted is not a
	// contract worth emitting.
	set := q.Select(context.Background(), true, hints, buildMemMatchers(in.Matchers)...)

	out := memSelectOut{Series: []memSeriesOutJSON{}, Warnings: []string{}}
	for set.Next() {
		ser := set.At()
		row := memSeriesOutJSON{Labels: ser.Labels().String(), Samples: []memSampleOutJSON{}}
		it := ser.Iterator(nil)
		for vt := it.Next(); vt != chunkenc.ValNone; vt = it.Next() {
			t, f := it.At()
			row.Samples = append(row.Samples, memSampleOutJSON{
				T: i64(t), ST: i64(it.AtST()), F: fbits(f), Type: int(vt),
			})
		}
		if err := it.Err(); err != nil {
			out.Err = err.Error()
			return out
		}
		out.Series = append(out.Series, row)
	}
	if err := set.Err(); err != nil {
		out.Err = err.Error()
	}
	out.Warnings = annotationStrings(set.Warnings())
	return out
}

func genStorageMemSelect(e *emitter) {
	for _, c := range memSelectCorpus() {
		e.emit(c.id, c.in, runMemSelect(c.in))
	}
}

// ------------------------------------------------------- storage/mem-labels

func runMemLabels(in memLabelsIn) memLabelsOut {
	s := loadMemStorage(in.Series)
	defer s.Close()

	q, err := s.Querier(parseI64(in.Mint), parseI64(in.Maxt))
	if err != nil {
		panic(err)
	}
	defer q.Close()

	var hints *storage.LabelHints
	if in.Limit > 0 {
		hints = &storage.LabelHints{Limit: in.Limit}
	}
	ms := buildMemMatchers(in.Matchers)

	var res []string
	var annos annotations.Annotations
	var qerr error
	if in.Kind == "names" {
		res, annos, qerr = q.LabelNames(context.Background(), hints, ms...)
	} else {
		res, annos, qerr = q.LabelValues(context.Background(), in.Name, hints, ms...)
	}

	out := memLabelsOut{Result: []string{}, Warnings: []string{}}
	if qerr != nil {
		out.Err = qerr.Error()
		return out
	}
	if res != nil {
		out.Result = res
	}
	out.Warnings = annotationStrings(annos)
	return out
}

func genStorageMemLabels(e *emitter) {
	for _, c := range memLabelsCorpus() {
		e.emit(c.id, c.in, runMemLabels(c.in))
	}
}
