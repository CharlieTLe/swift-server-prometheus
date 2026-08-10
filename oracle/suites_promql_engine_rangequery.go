package main

// Differential coverage for promql/engine.go's RANGE evaluation — `execEvalStmt`'s second
// half, `rangeEval`'s multi-step series assembly, `addToSeries`, and `StepInvariantExpr`'s
// step duplication.
//
// This is deliberately a separate suite from `promql/exec` rather than three more fields on
// it: `Fixtures.check` decodes a whole file with one pair of types (HANDOFF §4), and a range
// query needs `start`/`end`/`step` where an instant query needs `ts`.
//
// ## Why a range query is not just "the instant path, N times"
//
// Four behaviours exist ONLY here, and none of them can be witnessed by a single-step corpus:
//
//	the map-based assembly    `rangeEval`'s instant shortcut returns before it. With more than
//	                         one step the output series are accumulated in a map keyed by
//	                         label hash, and the point for each step is appended by
//	                         `addToSeries`.
//	gatherVector's CONSUME   `input[i].Floats = series.Floats[1:]` only matters when a later
//	                         step re-reads the same matrix. Step 0 works either way.
//	the step duplication     `StepInvariantExpr` evaluates once and copies its single point to
//	                         every remaining timestamp, with a NEW timestamp each time.
//	the always-Matrix tail   a range query returns a `Matrix` whatever the expression's type,
//	                         so `1` comes back as a one-series matrix with a point per step
//	                         rather than as a `Scalar`. The instant path's three type tails
//	                         have no counterpart.
//
// Plus two shapes that are errors rather than answers:
//
//	the inverted range       `end < start` returns an EMPTY matrix, not an error — engine.go's
//	                         `eval` checks it before the switch. Unreachable from an instant
//	                         query, where start == end by construction.
//	the type rejection       `NewRangeQuery` refuses anything but scalar and instant vector, so
//	                         `"a string"` and `foo[5m]` are legal instant queries and illegal
//	                         range ones.
//
// ## The sort warning needs a range query to exist at all
//
// `sort`/`sort_desc`/`sort_by_label`/`sort_by_label_desc` add
// `NewSortInRangeQueryWarning` when `startTimestamp != endTimestamp` — the one annotation in
// the evaluator that an instant query can never produce. Its position range is the CALL's, so
// the corpus passes the query text to `AsStrings` and the `(line:col)` suffix is part of the
// comparison.
//
// ## What is NOT here, and why
//
// Matrix selectors and subqueries still throw by name in the port, so `rate(foo[5m])` over a
// range query would be a fixture that can never pass. Aggregations and vector binops the same.
// This suite covers the range machinery over the arms that already work — which is what makes
// it landable before `matrixSelector`.
//
// One behaviour is transcribed and NOT pinned, and the honest place to say so is here: the
// duplicate-labelset error in the multi-step assembly (`ss.ts == ts`) needs one step's result
// vector to hold two samples with the same label hash. A selector cannot produce that — two
// series with one label set are one series to the storage — and none of the ported functions
// drops a differing label. It becomes reachable with `label_replace` and the aggregations.

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/storage"
)

type execRangeIn struct {
	Query string `json:"query"`
	// Milliseconds.
	Start string `json:"start"`
	End   string `json:"end"`
	// Nanoseconds, as a time.Duration.
	Step string `json:"step"`
	// Nanoseconds.
	Lookback   string            `json:"lookback"`
	MaxSamples int               `json:"maxSamples"`
	Series     []memSeriesInJSON `json:"series"`
}

type execRangeOut struct {
	ValueType string   `json:"valueType"`
	Value     string   `json:"value"`
	Err       string   `json:"err"`
	Warnings  []string `json:"warnings"`
	Stmt      string   `json:"stmt"`
}

func runExecRangeCase(in execRangeIn) execRangeOut {
	eng := promql.NewEngine(promql.EngineOpts{
		MaxSamples:               in.MaxSamples,
		Timeout:                  time.Minute,
		LookbackDelta:            time.Duration(parseI64(in.Lookback)),
		EnableAtModifier:         true,
		EnableNegativeOffset:     true,
		NoStepSubqueryIntervalFn: func(int64) int64 { return int64(time.Minute / time.Millisecond) },
		Parser: parser.NewParser(parser.Options{
			EnableExperimentalFunctions: true,
		}),
	})
	start := time.UnixMilli(parseI64(in.Start)).UTC()
	end := time.UnixMilli(parseI64(in.End)).UTC()
	var queryable storage.Queryable = execEmptyQueryable{}
	if len(in.Series) > 0 {
		st := loadMemStorage(in.Series)
		defer st.Close()
		queryable = st
	}
	q, err := eng.NewRangeQuery(
		context.Background(), queryable, nil, in.Query, start, end,
		time.Duration(parseI64(in.Step)))
	if err != nil {
		return execRangeOut{Err: err.Error(), Warnings: []string{}}
	}
	res := q.Exec(context.Background())
	out := execRangeOut{Warnings: []string{}}
	if res.Err != nil {
		out.Err = res.Err.Error()
	}
	if res.Value != nil {
		out.ValueType = string(res.Value.Type())
		out.Value = res.Value.String()
	}
	warnings, infos := res.Warnings.AsStrings(in.Query, 0, 0)
	out.Warnings = append(append([]string{}, warnings...), infos...)
	// Annotations is a Go map, so its order is randomised per run.
	sort.Strings(out.Warnings)
	out.Stmt = q.Statement().String()
	return out
}

func genPromQLExecRange(e *emitter) {
	n := 0
	emit := func(in execRangeIn) {
		if in.MaxSamples == 0 {
			in.MaxSamples = 50_000_000
		}
		if in.Series == nil {
			in.Series = []memSeriesInJSON{}
		}
		e.emit(fmt.Sprintf("exec-range/%d", n), in, runExecRangeCase(in))
		n++
	}

	minute := int64(time.Minute)

	// --- Storage-free expressions. Every one of these is step-invariant in VALUE, so what
	// the case pins is the TIMESTAMPS: a range query has to produce one point per step, with
	// the step's own timestamp, and a port that returned a single point would still render a
	// plausible-looking matrix.
	storageFree := []string{
		`1`, `-1`, `1.5`, `NaN`, `Inf`,
		`1 + 2`, `2 ^ 10`, `7 % 3`, `1 / 0`, `1 atan2 -1`,
		`1 == bool 1`, `1 > bool 2`,
		`(1)`, `-(1)`, `- -1`,
		`vector(1)`, `vector(NaN)`, `-vector(1)`,
		// `time()` is the one storage-free expression whose value MOVES with the step, so it
		// is the case that separates "one point per step" from "the same point per step".
		`time()`, `time() + 1`, `timestamp(vector(1))`,
		`pi()`, `abs(-3)`, `ceil(vector(1.2))`, `round(vector(1.5), 2)`,
		`scalar(vector(42))`,
		// The sort warning depends on the evaluator's OWN timestamps, and `preprocessExpr`
		// decides what those are: `sort(vector(1))` is step-invariant, so it is wrapped and
		// evaluated by a child evaluator whose start equals its end — no warning, even in a
		// range query. `sort(vector(time()))` is not, because `time` is at-modifier-unsafe, so
		// it reaches the Call arm with the outer timestamps and warns. The pair is what makes
		// "the condition is on the timestamps, not on the entry point" a tested claim.
		`sort(vector(1))`, `sort(vector(time()))`, `sort_desc(vector(time()))`,
		// The date functions read the evaluation time, so they move with the step too.
		`hour()`, `minute()`, `day_of_week()`, `year()`, `days_in_month()`,
		// `@` on a selector-free expression is a PARSE error — "@ modifier must be preceded
		// by an instant vector selector or range vector selector or a subquery" — so these
		// are cases about the error, not about step invariance. The step-duplication path is
		// reached through `http_requests @ 60` in the selector block below, where the
		// telltale is that step 1 reports step 0's value: with the wrapper the selector is
		// evaluated once, and without it `setOffsetForAtModifier`'s rewritten offset would
		// make every step read a *different* sample.
		`time() @ 100`, `time() @ start()`, `time() @ end()`, `vector(time() @ 100)`,
		`(time() @ 100) + time()`,
	}
	for _, q := range storageFree {
		// A three-step and a one-step-wide range. The second is NOT the instant path:
		// `start == end` with a non-zero interval still takes the range branch, where the
		// result is a Matrix rather than a Scalar — which is the cheapest way to separate the
		// two tails.
		for _, r := range []struct{ start, end, step int64 }{
			{0, 120_000, minute},
			{0, 0, minute},
			{1_600_000_000_000, 1_600_000_120_000, minute},
			// A step that does not divide the range: the last step lands before `end`, so
			// there are three points and not four.
			{0, 150_000, minute},
			// A negative start, where the timestamps are negative too.
			{-120_000, 0, minute},
		} {
			emit(execRangeIn{
				Query: q, Start: i64(r.start), End: i64(r.end), Step: i64(r.step),
				Lookback: i64(5 * minute),
			})
		}
	}

	// The INVERTED range: `end < start`. engine.go:2057 returns an empty matrix before the
	// expression switch, so this is not an error and not a one-step evaluation. Unreachable
	// from an instant query.
	for _, q := range []string{`1`, `time()`, `vector(1)`, `time() @ 100`} {
		emit(execRangeIn{
			Query: q, Start: i64(120_000), End: i64(0), Step: i64(minute),
			Lookback: i64(5 * minute),
		})
	}

	// The TYPE rejection, which is `NewRangeQuery`'s alone: a string and a range vector are
	// both legal instant queries.
	for _, q := range []string{`"a string"`, `foo[5m]`, `max_over_time(foo[5m])[1h:1m]`} {
		emit(execRangeIn{
			Query: q, Start: i64(0), End: i64(120_000), Step: i64(minute),
			Lookback: i64(5 * minute),
		})
	}

	// A query that fails to build comes back through Result, as in the instant suite.
	for _, q := range []string{`1 +`, `foo[`} {
		emit(execRangeIn{
			Query: q, Start: i64(0), End: i64(120_000), Step: i64(minute),
			Lookback: i64(5 * minute),
		})
	}

	// --- SELECTORS over a real tsdb.DB. This is where `gatherVector`'s consume, the map
	// assembly and the lookback window per step all become observable at once.
	fs := func(labels []string, points ...[2]int64) memSeriesInJSON {
		out := memSeriesInJSON{Labels: labels}
		for _, p := range points {
			out.T = append(out.T, i64(p[0]))
			out.ST = append(out.ST, i64(0))
			out.F = append(out.F, fbits(float64(p[1])))
		}
		return out
	}
	// Three series sharing a name and NOT sharing a shape: `c` stops after one sample, so a
	// later step sees two series where an earlier one saw three. That is what makes the
	// per-series accumulation visible — a port that assembled one row per step would produce
	// ragged output here.
	threeSeries := []memSeriesInJSON{
		fs([]string{"__name__", "http_requests", "job", "b"},
			[2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 3}),
		fs([]string{"__name__", "http_requests", "job", "a"},
			[2]int64{0, 10}, [2]int64{60_000, 20}, [2]int64{120_000, 30}),
		fs([]string{"__name__", "http_requests", "job", "c"}, [2]int64{0, 100}),
	}
	// A series with a hole in the middle, so some steps have a point and some do not — the
	// only shape where a series' float slice is SHORTER than the number of steps.
	holed := []memSeriesInJSON{
		fs([]string{"__name__", "holed"},
			[2]int64{0, 1}, [2]int64{600_000, 2}, [2]int64{1_200_000, 3}),
	}
	// A stale marker in the middle: the step that would read it produces nothing, and the
	// steps after it fall back through the lookback window to the sample BEFORE the marker.
	staleMid := []memSeriesInJSON{
		{
			Labels: []string{"__name__", "stale"},
			T:      []string{i64(0), i64(60_000), i64(120_000)},
			ST:     []string{i64(0), i64(0), i64(0)},
			F:      []string{fbits(1), "7ff0000000000002", fbits(3)},
		},
	}
	// Two series differing in one label, for the sorts: `sort` orders by VALUE, which the
	// final `sort.Sort(Matrix)` then overrides — which is precisely why upstream warns.
	twoValued := []memSeriesInJSON{
		fs([]string{"__name__", "metric", "job", "high"}, [2]int64{0, 100}, [2]int64{60_000, 1}),
		fs([]string{"__name__", "metric", "job", "low"}, [2]int64{0, 1}, [2]int64{60_000, 100}),
	}

	selectorCases := []struct {
		query            string
		series           []memSeriesInJSON
		start, end, step int64
	}{
		// A bare selector across three steps, then across steps that run past the data — so
		// the lookback window carries the last sample forward and then stops.
		{`http_requests`, threeSeries, 0, 120_000, minute},
		// The inverted range over real series: `eval` returns before it ever reads the
		// selector, so the answer is an empty matrix rather than "every series, backwards".
		{`http_requests`, threeSeries, 120_000, 0, minute},
		{`sort(metric)`, twoValued, 60_000, 0, minute},
		{`http_requests`, threeSeries, 0, 600_000, minute},
		{`http_requests`, threeSeries, 60_000, 180_000, minute},
		// A step SMALLER than the sample interval: several steps read the same sample, which
		// is the case a `gatherVector` that consumed too eagerly would get wrong.
		{`http_requests`, threeSeries, 0, 120_000, 30 * int64(time.Second)},
		{`http_requests`, threeSeries, 0, 60_000, 10 * int64(time.Second)},
		// A step LARGER than the sample interval, so samples are skipped entirely.
		{`http_requests`, threeSeries, 0, 240_000, 2 * minute},
		// A matcher selecting one series and one selecting none.
		{`http_requests{job="a"}`, threeSeries, 0, 120_000, minute},
		{`http_requests{job="zzz"}`, threeSeries, 0, 120_000, minute},
		// `offset`, which shifts every step's reference time by the same amount.
		{`http_requests offset 1m`, threeSeries, 60_000, 180_000, minute},
		{`http_requests offset -1m`, threeSeries, 0, 120_000, minute},
		// `@`, which makes the selector step-invariant: ONE evaluation, duplicated. The
		// values are identical across steps and the timestamps are not, which is the
		// duplication path over more than one series.
		{`http_requests @ 60`, threeSeries, 0, 120_000, minute},
		{`http_requests @ 0`, threeSeries, 300_000, 600_000, minute},
		{`-(http_requests @ 60)`, threeSeries, 0, 120_000, minute},
		// A gap and the lookback boundary, per step.
		{`holed`, holed, 0, 1_200_000, 2 * minute},
		{`holed`, holed, 250_000, 350_000, 50 * int64(time.Second)},
		// A stale marker mid-series.
		{`stale`, staleMid, 0, 180_000, minute},
		// Unary minus over several series across steps: `DropName` and the metadata drop
		// apply once per series, not once per point.
		{`-http_requests`, threeSeries, 0, 120_000, minute},
		{`(http_requests)`, threeSeries, 0, 120_000, minute},
		// A function over a selector — the ordinary Call path, with a matrix input to gather
		// from at every step.
		{`abs(-http_requests)`, threeSeries, 0, 120_000, minute},
		{`ceil(http_requests)`, threeSeries, 0, 120_000, minute},
		{`clamp_max(http_requests, 25)`, threeSeries, 0, 120_000, minute},
		// `scalar` over a multi-member vector is NaN at every step; over a single member it
		// is that member. Both are one-series matrices with `{}` for a metric.
		{`scalar(http_requests)`, threeSeries, 0, 120_000, minute},
		{`scalar(http_requests{job="a"})`, threeSeries, 0, 120_000, minute},
		// `timestamp(<selector>)` goes through the dedicated path, which reports the
		// SAMPLE's timestamp — so with a step smaller than the sample interval consecutive
		// steps report the SAME value.
		{`timestamp(http_requests)`, threeSeries, 0, 120_000, minute},
		{`timestamp(http_requests)`, threeSeries, 0, 120_000, 30 * int64(time.Second)},
		{`timestamp(http_requests @ 60)`, threeSeries, 0, 120_000, minute},
		// The four sorts, which are the only functions that WARN in a range query. The
		// annotation's position range is the call's, and the query text is passed to
		// AsStrings so the `(line:col)` suffix is compared.
		{`sort(metric)`, twoValued, 0, 60_000, minute},
		{`sort_desc(metric)`, twoValued, 0, 60_000, minute},
		{`sort_by_label(metric, "job")`, twoValued, 0, 60_000, minute},
		{`sort_by_label_desc(metric, "job")`, twoValued, 0, 60_000, minute},
		// The same four as ONE-step range queries. `start == end` with a non-zero interval
		// still means `startTimestamp == endTimestamp`, so the warning is NOT emitted — the
		// comparison is on the timestamps, not on which entry point was called.
		{`sort(metric)`, twoValued, 0, 0, minute},
		{`sort_desc(metric)`, twoValued, 0, 0, minute},
	}
	for _, c := range selectorCases {
		emit(execRangeIn{
			Query: c.query, Start: i64(c.start), End: i64(c.end), Step: i64(c.step),
			Lookback: i64(5 * minute), Series: c.series,
		})
	}

	// The sample limit across steps. `rangeEval` resets `currentSamples` to `tempNumSamples`
	// at the top of every step and `tempNumSamples` GROWS by each step's result — so a range
	// query's peak rises with the number of steps even though each step's own work does not.
	// That is the accounting a single-step corpus cannot see, and these boundaries pin it.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10} {
		for _, q := range []string{`1`, `vector(1)`, `time()`} {
			emit(execRangeIn{
				Query: q, Start: i64(0), End: i64(120_000), Step: i64(minute),
				Lookback: i64(5 * minute), MaxSamples: maxSamples,
			})
		}
	}
	// NESTED rangeEval under a limit, which is the only shape that can see the line
	// `ev.currentSamples = originalNumSamples + mat.TotalSamples()` at the very end of
	// `rangeEval`. At the end of the step loop `currentSamples` still carries the LAST step's
	// gathered inputs; that assignment drops them. Nothing reads `currentSamples` after a
	// top-level `rangeEval`, so the difference is invisible — unless an *enclosing* rangeEval
	// reads it as its own `tempNumSamples`, which it does immediately after evaluating its
	// arguments. `time()` rather than `1` on the inside because a literal is step-invariant and
	// would be evaluated by a one-step child instead.
	for _, maxSamples := range []int{3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18} {
		for _, q := range []string{
			`(time() + 1) + 1`, `((time() + 1) + 1) + 1`, `(time() + 1) + (time() + 1)`,
		} {
			emit(execRangeIn{
				Query: q, Start: i64(0), End: i64(120_000), Step: i64(minute),
				Lookback: i64(5 * minute), MaxSamples: maxSamples,
			})
		}
	}
	// The same over three real series, where each step costs one per series.
	for _, maxSamples := range []int{1, 3, 5, 6, 7, 8, 9, 12, 15} {
		emit(execRangeIn{
			Query: `http_requests`, Start: i64(0), End: i64(120_000), Step: i64(minute),
			Lookback: i64(5 * minute), MaxSamples: maxSamples, Series: threeSeries,
		})
	}
	// And the step-duplication path under a limit, which counts inside its own loop rather
	// than through `rangeEval` — so the error can come from a step that does no evaluation.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 7} {
		emit(execRangeIn{
			Query: `http_requests @ 60`, Start: i64(0), End: i64(120_000), Step: i64(minute),
			Lookback: i64(5 * minute), MaxSamples: maxSamples, Series: threeSeries,
		})
	}
}
