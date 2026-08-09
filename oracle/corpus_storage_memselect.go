package main

// Corpus for storage/mem-select and storage/mem-labels. See
// suites_storage_memselect.go for what the two suites pin and why they are
// restricted to float samples and sorted output.

import "fmt"

type memSelectCase struct {
	id string
	in memSelectIn
}

type memLabelsCase struct {
	id string
	in memLabelsIn
}

// memSeriesIn builds one input series. Values are `base + i` so a wrong sample
// slice is obvious in a diff rather than merely unequal.
func memSeriesIn(base float64, ts []int64, sts []int64, lbls ...string) memSeriesInJSON {
	out := memSeriesInJSON{Labels: lbls}
	for i, t := range ts {
		out.T = append(out.T, i64(t))
		st := int64(0)
		if sts != nil {
			st = sts[i]
		}
		out.ST = append(out.ST, i64(st))
		out.F = append(out.F, fbits(base+float64(i)))
	}
	return out
}

// memDataset is the shared dataset. Its APPEND ORDER is deliberately not its
// label order — `instance="1"` is appended before `instance="0"`, and `up` before
// `metric_no_job` — so that sorted output is distinguishable from insertion order
// and a port that forgot to sort fails rather than passing by luck.
func memDataset() []memSeriesInJSON {
	return []memSeriesInJSON{
		memSeriesIn(10, []int64{0, 100, 200, 300, 400}, nil,
			"__name__", "http_requests", "instance", "1", "job", "api"),
		memSeriesIn(20, []int64{0, 100, 200, 300, 400}, nil,
			"__name__", "http_requests", "instance", "0", "job", "api"),
		// Starts late: a query over [0,100] must not return it at all.
		memSeriesIn(30, []int64{200, 300, 400}, nil,
			"__name__", "http_requests", "job", "web"),
		memSeriesIn(40, []int64{0, 100}, nil,
			"__name__", "up", "job", "api"),
		// No `job` label at all, which is what makes `job=""` and `job!="api"`
		// interesting.
		memSeriesIn(50, []int64{500, 600}, nil,
			"__name__", "metric_no_job"),
		// Start timestamps, to see whether they survive a real append+read.
		memSeriesIn(60, []int64{700, 800}, []int64{690, 700},
			"__name__", "with_st", "job", "api"),
	}
}

func eqm(name, value string) memMatcherJSON {
	return memMatcherJSON{Type: "=", Name: name, Value: value}
}

func memSelectCorpus() []memSelectCase {
	data := memDataset()
	httpReq := []memMatcherJSON{eqm("__name__", "http_requests")}

	var cases []memSelectCase
	add := func(id string, in memSelectIn) {
		in.Series = data
		cases = append(cases, memSelectCase{id: id, in: in})
	}

	// ---- the querier's own range, no hints at all.
	//
	// Whether hints are nil is itself the thing under test: querier.go:205 only
	// reassigns mint/maxt when they are non-nil.
	for _, r := range []struct {
		id         string
		mint, maxt int64
	}{
		{"full", 0, 1000},
		// Closed at both ends: t=0 and t=400 are both included.
		{"exact-bounds", 0, 400},
		// A single instant that is exactly a sample timestamp.
		{"instant-hit", 200, 200},
		// A single instant that is not.
		{"instant-miss", 250, 250},
		// Excludes the late-starting `job="web"` series entirely, which is the
		// skip-empty path (querier.go:503).
		{"early-window", 0, 100},
		// After every http_requests sample: the set must be empty.
		{"after-all", 401, 500},
		// Inverted range.
		{"inverted", 400, 0},
	} {
		add("nohints/"+r.id, memSelectIn{
			Mint: i64(r.mint), Maxt: i64(r.maxt), Matchers: httpReq,
		})
	}

	// ---- hints OVERRIDE the querier range, in both directions.
	for _, h := range []struct {
		id                     string
		mint, maxt, start, end int64
	}{
		// Hints narrower than the querier.
		{"narrower", 0, 1000, 200, 300},
		// Hints WIDER than the querier: if these were intersected rather than
		// overridden, t=0 and t=400 would be missing.
		{"wider", 200, 300, 0, 400},
		// Hints disjoint from the querier range, on the far side.
		{"disjoint", 0, 100, 300, 400},
	} {
		add("hints/"+h.id, memSelectIn{
			Mint: i64(h.mint), Maxt: i64(h.maxt),
			Hints:    &memHintsJSON{Start: i64(h.start), End: i64(h.end)},
			Matchers: httpReq,
		})
	}

	// ---- DisableTrimming. Nothing in promql sets it; pinned because the port
	// carries the field and a future caller would otherwise find it untested.
	add("hints/disable-trimming", memSelectIn{
		Mint: i64(0), Maxt: i64(1000),
		Hints:    &memHintsJSON{Start: i64(200), End: i64(300), DisableTrimming: true},
		Matchers: httpReq,
	})

	// ---- the two-stage filter, in its starkest form. The querier range decides
	// which series are VISIBLE (it is what the index reader was opened with); the
	// hints decide only how the visible ones are TRIMMED. Here only
	// `metric_no_job` spans [500,600], so widening the hints to [0,1000] cannot
	// bring any other series back — and it does not trim the one series either.
	add("hints/two-stage", memSelectIn{
		Mint: i64(500), Maxt: i64(600),
		Hints:    &memHintsJSON{Start: i64(0), End: i64(1000)},
		Matchers: []memMatcherJSON{{Type: "!=", Name: "__name__", Value: ""}},
	})

	// ---- matchers.
	for _, m := range []struct {
		id string
		ms []memMatcherJSON
	}{
		{"eq-name", httpReq},
		{"eq-two", []memMatcherJSON{eqm("__name__", "http_requests"), eqm("job", "api")}},
		// Matches the series that has no `job` label at all — the reason a
		// matcher must be applied to Labels.Get's "" for a missing label rather
		// than gated on Has.
		{"eq-empty-value", []memMatcherJSON{{Type: "=", Name: "job", Value: ""}}},
		{"neq", []memMatcherJSON{{Type: "!=", Name: "job", Value: "api"}}},
		// Also matches the label-less series, for the same reason.
		{"neq-nonempty", []memMatcherJSON{{Type: "!=", Name: "instance", Value: "0"}}},
		{"re-anchored", []memMatcherJSON{{Type: "=~", Name: "job", Value: "a.*"}}},
		{"re-alternation", []memMatcherJSON{
			{Type: "=~", Name: "__name__", Value: "http_requests|up"}}},
		{"re-empty", []memMatcherJSON{{Type: "=~", Name: "job", Value: ""}}},
		{"nre", []memMatcherJSON{{Type: "!~", Name: "job", Value: "a.*"}}},
		{"nre-empty", []memMatcherJSON{{Type: "!~", Name: "job", Value: ""}}},
		// No match at all.
		{"no-match", []memMatcherJSON{eqm("__name__", "nonexistent")}},
		// Everything, so the whole dataset comes back in label order. This is the
		// case that pins SortedPostings against insertion order.
		{"all", []memMatcherJSON{{Type: "!=", Name: "__name__", Value: ""}}},
	} {
		add("match/"+m.id, memSelectIn{Mint: i64(0), Maxt: i64(1000), Matchers: m.ms})
	}

	// ---- start timestamps, over the one series that carries them.
	add("st/carried", memSelectIn{
		Mint: i64(0), Maxt: i64(1000), Matchers: []memMatcherJSON{eqm("__name__", "with_st")},
	})

	return cases
}

func memLabelsCorpus() []memLabelsCase {
	data := memDataset()

	var cases []memLabelsCase
	add := func(id string, in memLabelsIn) {
		in.Series = data
		cases = append(cases, memLabelsCase{id: id, in: in})
	}

	// LabelNames, unfiltered and filtered. The time range is varied to record
	// whether these are time-filtered at all — upstream they go through the
	// index, which for a head-only DB is not narrowed per series.
	for _, r := range []struct {
		id         string
		mint, maxt int64
	}{
		{"full", 0, 1000},
		{"early", 0, 100},
		{"empty-range", 2000, 3000},
	} {
		add("names/"+r.id, memLabelsIn{
			Kind: "names", Mint: i64(r.mint), Maxt: i64(r.maxt),
		})
	}

	add("names/matched", memLabelsIn{
		Kind: "names", Mint: i64(0), Maxt: i64(1000),
		Matchers: []memMatcherJSON{eqm("__name__", "http_requests")},
	})
	add("names/limit", memLabelsIn{
		Kind: "names", Mint: i64(0), Maxt: i64(1000), Limit: 2,
	})

	// LabelValues.
	for _, name := range []string{"__name__", "job", "instance", "absent"} {
		add(fmt.Sprintf("values/%s", name), memLabelsIn{
			Kind: "values", Name: name, Mint: i64(0), Maxt: i64(1000),
		})
	}
	// The discriminating case for per-series time filtering: [0,100] overlaps the
	// head, but `metric_no_job` (t=500,600) and `with_st` (t=700,800) have no
	// sample in it. They still appear, because `headIndexReader.LabelValues` gates
	// on the HEAD's overall range (`h.maxt < h.head.MinTime()`, head_read.go:154)
	// and does not filter per series.
	add("values/narrow-range", memLabelsIn{
		Kind: "values", Name: "__name__", Mint: i64(0), Maxt: i64(100),
	})
	add("values/matched", memLabelsIn{
		Kind: "values", Name: "instance", Mint: i64(0), Maxt: i64(1000),
		Matchers: []memMatcherJSON{eqm("job", "api")},
	})
	add("values/matched-other-label", memLabelsIn{
		Kind: "values", Name: "job", Mint: i64(0), Maxt: i64(1000),
		Matchers: []memMatcherJSON{eqm("__name__", "http_requests")},
	})
	add("values/limit", memLabelsIn{
		Kind: "values", Name: "__name__", Mint: i64(0), Maxt: i64(1000), Limit: 2,
	})
	// The discriminating case for WHERE the limit is applied. `instance` is first
	// seen as "1" and then "0", so truncate-then-sort yields ["1"] while
	// sort-then-truncate would yield ["0"]. Go does the former:
	// `MemPostings.LabelValues` slices `p.lvs[name]` — an append-ordered slice —
	// before `SortedLabelValues` sorts what survives.
	add("values/limit-unsorted", memLabelsIn{
		Kind: "values", Name: "instance", Mint: i64(0), Maxt: i64(1000), Limit: 1,
	})
	add("values/empty-range", memLabelsIn{
		Kind: "values", Name: "job", Mint: i64(2000), Maxt: i64(3000),
	})

	return cases
}
