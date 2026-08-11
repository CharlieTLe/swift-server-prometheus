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
			// `anchored`/`smoothed`, which the `Call` arm validates per function.
			EnableExtendedRangeSelectors: true,
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

	// --- FUNCTIONS OVER A RANGE SELECTOR, which is the `matrixArg` half of the `Call` arm.
	// This is the slice where a range query stops being optional: `matrixIterSlice`'s retention
	// only runs across steps, `it.ReduceDelta(stepRange)` only bites from the second step on, and
	// `refetch` only matters when there is more than one step to refetch for.
	//
	// The corpus varies the step against the range in BOTH directions on purpose. Step < range
	// gives overlapping windows, so the retention keeps points; step > range gives disjoint
	// windows, so it truncates — and `stepRange = min(selRange, interval)` picks a different
	// buffer size in each case.
	rangeFnSeries := []memSeriesInJSON{
		fs([]string{"__name__", "http_requests_total", "job", "b"},
			[2]int64{0, 1}, [2]int64{30_000, 3}, [2]int64{60_000, 6}, [2]int64{90_000, 10},
			[2]int64{120_000, 15}, [2]int64{150_000, 21}, [2]int64{180_000, 28}),
		fs([]string{"__name__", "http_requests_total", "job", "a"},
			[2]int64{0, 100}, [2]int64{60_000, 200}, [2]int64{120_000, 300},
			[2]int64{180_000, 400}),
	}
	// A counter that RESETS, so `rate`/`increase`/`resets`/`changes` all have something to find.
	resetSeries := []memSeriesInJSON{
		fs([]string{"__name__", "c_total"},
			[2]int64{0, 10}, [2]int64{30_000, 20}, [2]int64{60_000, 5}, [2]int64{90_000, 15},
			[2]int64{120_000, 2}, [2]int64{150_000, 8}),
	}
	// A name with NO counter suffix, which is what makes `rate` emit its possible-non-counter
	// info — and the info reads the INPUT's name, so a port that read the output's (with
	// `__name__` already dropped) would emit a nameless one.
	gaugeSeries := []memSeriesInJSON{
		fs([]string{"__name__", "plain_gauge"},
			[2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 3}, [2]int64{180_000, 4}),
	}
	// Samples that are NOT on the step grid. Every `anchored`/`smoothed` control needs this:
	// with samples at multiples of the step, the boundary sample the extended modifiers reach
	// back for sits exactly ON the boundary, so a buffer that was never widened still finds it
	// and the widening looks free. Off-grid samples make the lookback do work.
	offGrid := []memSeriesInJSON{
		fs([]string{"__name__", "og_total"},
			[2]int64{7_000, 1}, [2]int64{53_000, 4}, [2]int64{101_000, 12},
			[2]int64{149_000, 25}, [2]int64{197_000, 41}),
	}
	// SPARSE and off-grid: the boundary sample `anchored` reaches for is more than one
	// `selRange` before `maxt`, so a buffer that was not widened by the lookback delta cannot
	// see it. `offGrid` alone is not enough — its samples are dense enough that the unwidened
	// buffer still catches one.
	sparseTotal := []memSeriesInJSON{
		fs([]string{"__name__", "sp_total"}, [2]int64{7_000, 1}, [2]int64{197_000, 60}),
	}
	// A single sample, so `rate` can never produce output: two points are the minimum. That is
	// what makes the possible-non-counter info's `len(ss.Floats) > 0` guard observable — the
	// check runs even for a series that contributed nothing.
	singleGauge := []memSeriesInJSON{
		fs([]string{"__name__", "single_gauge"}, [2]int64{60_000, 5}),
	}
	// The three other suffixes the fallback accepts, which a `_total`-only test would warn for.
	suffixed := []memSeriesInJSON{
		fs([]string{"__name__", "a_sum"}, [2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 4}),
		fs([]string{"__name__", "b_count"}, [2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 4}),
		fs([]string{"__name__", "c_bucket"}, [2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 4}),
	}
	// Two series with a HOLE, so some steps yield no window at all and are skipped.
	holedFn := []memSeriesInJSON{
		fs([]string{"__name__", "h_total"}, [2]int64{0, 1}, [2]int64{600_000, 5}),
	}

	rangeFnCases := []struct {
		query            string
		series           []memSeriesInJSON
		start, end, step int64
	}{
		// `rate` at three step/range relationships.
		{`rate(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`rate(http_requests_total[1m])`, rangeFnSeries, 0, 180_000, minute},
		{`rate(http_requests_total[5m])`, rangeFnSeries, 0, 180_000, minute},
		// Step SMALLER than the range: overlapping windows, so the retention keeps points.
		{`rate(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, 30 * int64(time.Second)},
		{`rate(http_requests_total[2m])`, rangeFnSeries, 0, 120_000, 10 * int64(time.Second)},
		// Step LARGER than the range: disjoint windows, so it truncates every time and
		// `stepRange` is the interval rather than the range.
		{`rate(http_requests_total[1m])`, rangeFnSeries, 0, 180_000, 2 * minute},
		{`rate(http_requests_total[30s])`, rangeFnSeries, 0, 180_000, 3 * minute},
		// The rest of the counter family over the resetting series.
		{`increase(c_total[2m])`, resetSeries, 0, 150_000, minute},
		{`delta(c_total[2m])`, resetSeries, 0, 150_000, minute},
		{`idelta(c_total[2m])`, resetSeries, 0, 150_000, minute},
		{`irate(c_total[2m])`, resetSeries, 0, 150_000, minute},
		{`resets(c_total[2m])`, resetSeries, 0, 150_000, minute},
		{`changes(c_total[2m])`, resetSeries, 0, 150_000, minute},
		// The `*_over_time` family, which is where the aggregation bodies live.
		{`sum_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`avg_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`min_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`max_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`count_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`stddev_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`stdvar_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`mad_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`ts_of_min_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`ts_of_max_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`ts_of_last_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		// `last_over_time`/`first_over_time` KEEP the metric name where every other range
		// function drops it — the one place `dropName` is decided by the function.
		{`last_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`first_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		// A scalar argument alongside the matrix one, read by STEP NUMBER from a matrix
		// evaluated once up front.
		{`quantile_over_time(0.5, http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`quantile_over_time(0.9, http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`predict_linear(http_requests_total[2m], 3600)`, rangeFnSeries, 0, 180_000, minute},
		{`deriv(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], 0.5, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		// A step-invariant scalar argument, which `preprocessExpr` wraps — so the per-step
		// lookup reads a matrix produced by a ONE-step child evaluator. If the port indexed it
		// by step it would run off the end; Go does not, because the wrapper duplicates.
		{`quantile_over_time(scalar(vector(0.5)), http_requests_total[2m])`, rangeFnSeries,
			0, 180_000, minute},
		// `absent_over_time`, whose tail rewrites the whole result. Three shapes: a series that
		// covers every step (empty result), a hole (one synthetic series with the missing
		// timestamps), and nothing at all.
		{`absent_over_time(http_requests_total[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`absent_over_time(h_total[2m])`, holedFn, 0, 600_000, minute},
		{`absent_over_time(nothing[2m])`, rangeFnSeries, 0, 180_000, minute},
		{`absent_over_time({__name__="http_requests_total", job="a"}[2m])`, rangeFnSeries,
			0, 180_000, minute},
		// A hole in the middle: steps with no window are skipped entirely, so the output series
		// is shorter than the step count.
		{`rate(h_total[2m])`, holedFn, 0, 600_000, minute},
		{`count_over_time(h_total[2m])`, holedFn, 0, 600_000, minute},
		// The possible-non-counter info, which reads the INPUT's metric name.
		{`rate(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		{`increase(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		// ...and its absence for a `_total` name.
		{`rate(c_total[2m])`, resetSeries, 0, 150_000, minute},
		// `@` on the range selector: `refetch` is false from step 1 on, so ONE window feeds
		// every step and the values are identical while the timestamps advance.
		{`rate(http_requests_total[2m] @ 120)`, rangeFnSeries, 0, 180_000, minute},
		{`count_over_time(http_requests_total[2m] @ 120)`, rangeFnSeries, 0, 180_000, minute},
		{`last_over_time(http_requests_total[2m] @ 60)`, rangeFnSeries, 0, 180_000, minute},
		// `offset`, which moves the window without pinning it.
		{`rate(http_requests_total[2m] offset 1m)`, rangeFnSeries, 60_000, 180_000, minute},
		// The extended modifiers, restricted to the functions that accept them.
		{`rate(http_requests_total[2m] anchored)`, rangeFnSeries, 60_000, 180_000, minute},
		{`increase(http_requests_total[2m] anchored)`, rangeFnSeries, 60_000, 180_000, minute},
		{`delta(http_requests_total[2m] smoothed)`, rangeFnSeries, 60_000, 180_000, minute},
		{`rate(http_requests_total[2m] smoothed)`, rangeFnSeries, 60_000, 180_000, minute},
		{`resets(http_requests_total[2m] anchored)`, rangeFnSeries, 60_000, 180_000, minute},
		// ...and the errors for a function that does not. The message lists the permitted
		// names SORTED, which is upstream's own defence against ranging a map.
		{`sum_over_time(http_requests_total[2m] anchored)`, rangeFnSeries, 0, 180_000, minute},
		{`resets(http_requests_total[2m] smoothed)`, rangeFnSeries, 0, 180_000, minute},
		{`count_over_time(http_requests_total[2m] smoothed)`, rangeFnSeries, 0, 180_000, minute},
		// A histogram reader over a float series: no histograms, so no output.
		{`histogram_count(http_requests_total)`, rangeFnSeries, 0, 180_000, minute},
		// --- OFF-GRID samples with the extended modifiers. `anchored` and `smoothed` widen the
		// buffer by one and two lookback deltas respectively, and that widening is only
		// observable when the sample they reach for is strictly inside the widened span rather
		// than sitting on the original boundary.
		{`rate(og_total[2m] anchored)`, offGrid, 60_000, 200_000, minute},
		{`increase(og_total[2m] anchored)`, offGrid, 60_000, 200_000, minute},
		{`delta(og_total[2m] anchored)`, offGrid, 60_000, 200_000, minute},
		{`rate(og_total[2m] smoothed)`, offGrid, 60_000, 200_000, minute},
		{`increase(og_total[2m] smoothed)`, offGrid, 60_000, 200_000, minute},
		{`delta(og_total[2m] smoothed)`, offGrid, 60_000, 200_000, minute},
		{`rate(og_total[1m] anchored)`, offGrid, 60_000, 200_000, 30 * int64(time.Second)},
		{`rate(og_total[1m] smoothed)`, offGrid, 60_000, 200_000, 30 * int64(time.Second)},
		{`resets(og_total[2m] anchored)`, offGrid, 60_000, 200_000, minute},
		{`changes(og_total[2m] anchored)`, offGrid, 60_000, 200_000, minute},
		{`rate(og_total[2m])`, offGrid, 60_000, 200_000, minute},

		// --- A scalar argument that MOVES with the step. Every other scalar argument in this
		// suite is a constant, so reading `evalVals[j][0].Floats[0]` instead of `[step]` gives
		// the same answer and the per-step lookup goes untested. `time()` is
		// at-modifier-unsafe, so `preprocessExpr` cannot fold it into a step-invariant.
		{`quantile_over_time(scalar(vector(time() / 400)), http_requests_total[2m])`,
			rangeFnSeries, 0, 180_000, minute},
		{`predict_linear(http_requests_total[2m], time())`, rangeFnSeries, 0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], scalar(vector(time() / 400)), 0.5)`,
			rangeFnSeries, 0, 180_000, minute},
		{`clamp_max(rate(http_requests_total[2m]), time() / 100)`, rangeFnSeries,
			0, 180_000, minute},

		// --- An @-pinned range selector reaching a MULTI-STEP evaluator, which is the only way
		// `refetch`'s `selVS.Timestamp == nil` clause can be witnessed. `rate(foo[2m] @ 120)` is
		// wrapped whole in a StepInvariantExpr — a MatrixSelector is never wrapped on its own
		// (engine.go's `case *parser.MatrixSelector` returns `shouldWrap = false`, "functions
		// over range vectors evaluate those directly") — so the wrapper hands it a ONE-step
		// child and `ts == ev.startTimestamp` is always true.
		//
		// `predict_linear` is in `AtModifierUnsafeFunctions`, so the Call is NOT wrapped, and it
		// keeps the outer timestamps with a pinned window: refetch is false from step 1 on and
		// the same matrix feeds every step.
		{`predict_linear(http_requests_total[2m] @ 120, 3600)`, rangeFnSeries,
			0, 180_000, minute},
		{`predict_linear(og_total[2m] @ 120, 3600)`, offGrid, 0, 180_000, minute},
		{`predict_linear(http_requests_total[2m] @ 120, time())`, rangeFnSeries,
			0, 180_000, minute},
		// The same function without the `@`, so the pair differs only in whether the window
		// moves.
		{`predict_linear(http_requests_total[2m], 3600)`, rangeFnSeries, 0, 180_000, minute},

		// --- `double_exponential_smoothing`'s two PANICS, which are ordinary query errors:
		// Go `panic(fmt.Errorf(...))`s on a factor outside (0, 1) and `recover` passes a
		// panicked error through unchanged. `%f`, so six decimal places. The port had a
		// `preconditionFailure` here — safe while the oracle was the only caller, a crash the
		// moment a query could reach the body — and this is the case that found it.
		{`double_exponential_smoothing(http_requests_total[5m], 0, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], 1, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], 0.5, 0)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], 0.5, 1)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], -1, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], NaN, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		{`double_exponential_smoothing(http_requests_total[5m], 1.5, 0.5)`, rangeFnSeries,
			0, 180_000, minute},
		// The factor reaches the body only when the window is non-empty, so a query over a
		// series with nothing in range does NOT raise — the guard above the panic returns first.
		{`double_exponential_smoothing(nothing[5m], 0, 0.5)`, rangeFnSeries, 0, 180_000, minute},

		// --- The anchored buffer widening, which needs a boundary sample MORE than one
		// `selRange` before `maxt`. With dense samples the unwidened buffer catches one anyway
		// and the widening looks free.
		{`rate(sp_total[30s] anchored)`, sparseTotal, 190_000, 220_000, 10 * int64(time.Second)},
		{`increase(sp_total[30s] anchored)`, sparseTotal, 190_000, 220_000, 10 * int64(time.Second)},
		{`rate(sp_total[1m] anchored)`, sparseTotal, 190_000, 260_000, 30 * int64(time.Second)},
		{`rate(sp_total[30s] smoothed)`, sparseTotal, 190_000, 220_000, 10 * int64(time.Second)},
		{`rate(sp_total[30s])`, sparseTotal, 190_000, 220_000, 10 * int64(time.Second)},

		// --- The possible-non-counter info's own guards.
		// A single sample means `rate` produces nothing, so the series is never appended — and
		// the info check still runs. `len(ss.Floats) > 0` is what suppresses it.
		{`rate(single_gauge[2m])`, singleGauge, 0, 180_000, minute},
		{`increase(single_gauge[2m])`, singleGauge, 0, 180_000, minute},
		// The three suffixes besides `_total` that the fallback accepts.
		{`rate(a_sum[2m])`, suffixed, 0, 120_000, minute},
		{`rate(b_count[2m])`, suffixed, 0, 120_000, minute},
		{`rate(c_bucket[2m])`, suffixed, 0, 120_000, minute},
		{`rate({__name__=~"a_sum|b_count|c_bucket"}[2m])`, suffixed, 0, 120_000, minute},
		// ...and the functions that do NOT warn, however non-counter-ish the name.
		{`delta(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		{`idelta(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		{`irate(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		{`resets(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},
		{`avg_over_time(plain_gauge[2m])`, gaugeSeries, 0, 180_000, minute},

		// One-step range queries over the same shapes, so the step-dependent machinery is
		// compared against the case where it cannot fire.
		{`rate(http_requests_total[2m])`, rangeFnSeries, 120_000, 120_000, minute},
		{`absent_over_time(h_total[2m])`, holedFn, 300_000, 300_000, minute},
	}
	for _, c := range rangeFnCases {
		emit(execRangeIn{
			Query: c.query, Start: i64(c.start), End: i64(c.end), Step: i64(c.step),
			Lookback: i64(5 * minute), Series: c.series,
		})
	}
	// The sample limit against a range function, which is checked ONCE PER SERIES after all its
	// steps rather than per step. Two series times four steps is eight points, so the boundary
	// is not where a per-step check would put it.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 16, 20} {
		emit(execRangeIn{
			Query: `rate(http_requests_total[2m])`, Start: i64(0), End: i64(180_000),
			Step: i64(minute), Lookback: i64(5 * minute), MaxSamples: maxSamples,
			Series: rangeFnSeries,
		})
	}
	// A range function NESTED inside another rangeEval, which is the only shape that can see the
	// Call arm's final `ev.currentSamples -= len(floats) + totalHPointSize(histograms)`. Nothing
	// reads `currentSamples` after a top-level Call, but an enclosing `rangeEval` reads it as its
	// own `tempNumSamples` right after evaluating its arguments — the same mechanism as quirk 81.
	for _, maxSamples := range []int{4, 6, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24} {
		for _, q := range []string{
			`clamp_max(rate(http_requests_total[2m]), 10)`,
			`abs(rate(http_requests_total[2m]))`,
			`clamp_max(rate(http_requests_total[2m]), time() / 100)`,
		} {
			emit(execRangeIn{
				Query: q, Start: i64(0), End: i64(180_000), Step: i64(minute),
				Lookback: i64(5 * minute), MaxSamples: maxSamples, Series: rangeFnSeries,
			})
		}
	}

	// And with a step smaller than the range, where the retention keeps points across steps and
	// the running total therefore follows a different path to the same limit.
	for _, maxSamples := range []int{3, 5, 8, 10, 14, 20, 26} {
		emit(execRangeIn{
			Query: `count_over_time(http_requests_total[2m])`, Start: i64(0), End: i64(120_000),
			Step: i64(30 * int64(time.Second)), Lookback: i64(5 * minute),
			MaxSamples: maxSamples, Series: rangeFnSeries,
		})
	}

	// --- AGGREGATIONS over a range query. Everything in the aggregation that is per-STEP needs
	// this: `seen` being cleared, the empty-row removal, `currentSamples` being reset,
	// `nextValues` consuming its point, and `fParams.Next()` advancing.
	//
	// The shapes matter more than the count. A series with a HOLE is what makes `seen` observable —
	// a group with no sample at one step must produce no point there rather than repeating the
	// previous one — and a series that stops early is what makes the empty-row removal observable.
	aggRange := []memSeriesInJSON{
		fs([]string{"__name__", "ar", "job", "a"},
			[2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 3}, [2]int64{180_000, 4}),
		fs([]string{"__name__", "ar", "job", "b"},
			[2]int64{0, 10}, [2]int64{180_000, 40}),
		fs([]string{"__name__", "ar", "job", "c"}, [2]int64{0, 100}),
	}
	// A group whose ONLY series stops after the first step, so its output row is empty for every
	// later step — and with a lookback shorter than the gap, empty at the end too.
	aggEmptyRow := []memSeriesInJSON{
		fs([]string{"__name__", "ae", "job", "a"},
			[2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 3}),
		fs([]string{"__name__", "ae", "job", "z"}, [2]int64{0, 9}),
	}

	aggRangeCases := []struct {
		query            string
		series           []memSeriesInJSON
		start, end, step int64
		lookback         int64
	}{
		{`sum(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`sum by (job) (ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`avg(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`avg by (job) (ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`count(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`count by (job) (ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`min(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`max(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`group(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`stddev(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`stdvar(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`quantile(0.5, ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`sum without (job) (ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		// A SHORT lookback, so a step past a series' last sample sees nothing — which is what
		// makes `seen` and the empty-row removal do work.
		{`sum by (job) (ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		{`count by (job) (ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		{`avg by (job) (ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		{`min by (job) (ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		{`stddev by (job) (ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		{`quantile by (job) (0.5, ar)`, aggRange, 0, 180_000, minute, 90 * int64(time.Second)},
		// A group that is empty for every step but the first: its row must be dropped entirely
		// rather than emitted with one point... and it is NOT dropped, because one point is data.
		// Both shapes are here because "which one is empty" is the whole question.
		{`sum by (job) (ae)`, aggEmptyRow, 0, 180_000, minute, 30 * int64(time.Second)},
		{`sum by (job) (ae)`, aggEmptyRow, 120_000, 180_000, minute, 30 * int64(time.Second)},
		{`count by (job) (ae)`, aggEmptyRow, 120_000, 180_000, minute, 30 * int64(time.Second)},
		// A parameter that MOVES with the step, which is the only way `fParams.Next()`'s advance
		// is observable — a constant returns the same value forever without consuming.
		{`quantile(scalar(vector(time() / 200)), ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		{`quantile by (job) (scalar(vector(time() / 200)), ar)`, aggRange, 0, 180_000, minute,
			5 * minute},
		// ...and a parameter series SHORTER than the step count, so it runs out: `Next()` then
		// returns 0 rather than repeating the last value.
		{`quantile(scalar(ar{job="c"}), ar)`, aggRange, 0, 180_000, minute, 30 * int64(time.Second)},
		// A parameter series carrying a NaN *and* a value above 1, so both quantile warnings fire —
		// which is what says they are not exclusive.
		{`quantile(scalar(vector(time() / 60 - 1.5)), ar)`, aggRange, 0, 180_000, minute,
			5 * minute},
		// An aggregation over a range function and over another aggregation, across steps.
		{`sum(rate(ar[2m]))`, aggRange, 0, 180_000, minute, 5 * minute},
		{`sum by (job) (rate(ar[2m]))`, aggRange, 0, 180_000, minute, 5 * minute},
		{`max(sum by (job) (ar))`, aggRange, 0, 180_000, minute, 5 * minute},
		{`sum(ar) + sum(ar)`, aggRange, 0, 180_000, minute, 5 * minute},
		// A parameter series carrying a NaN *and* a value above 1 in the SAME query, which is what
		// makes the three quantile warnings non-exclusive — and the same shape is the only one
		// where `newFParams`' `math.Max`/`math.Min` differ from Swift's, since they disagree only
		// on NaN (quirk 28).
		{`quantile(scalar(vector((time() - 60) / (time() - 60) * 2)), ar)`, aggRange,
			0, 180_000, minute, 5 * minute},
		{`quantile by (job) (scalar(vector((time() - 60) / (time() - 60) * 2)), ar)`, aggRange,
			0, 180_000, minute, 5 * minute},
		// A single-step range query over the same shapes, for the pair.
		{`sum by (job) (ar)`, aggRange, 60_000, 60_000, minute, 5 * minute},
	}
	for _, c := range aggRangeCases {
		emit(execRangeIn{
			Query: c.query, Start: i64(c.start), End: i64(c.end), Step: i64(c.step),
			Lookback: i64(c.lookback), Series: c.series,
		})
	}
	// The sample limit against an aggregation across steps, which `rangeEvalAgg` checks after each
	// step having reset to `tempNumSamples` — so the peak includes the input matrix the inner
	// expression left behind.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 20} {
		for _, q := range []string{`sum(ar)`, `sum by (job) (ar)`, `count(ar)`} {
			emit(execRangeIn{
				Query: q, Start: i64(0), End: i64(180_000), Step: i64(minute),
				Lookback: i64(5 * minute), MaxSamples: maxSamples, Series: aggRange,
			})
		}
	}

	// --- The k-of-the-input aggregations over a RANGE query, which is the only way three things
	// are visible: `advanceRemainingSeries` (a point left unconsumed at step N is read as step
	// N+1's value), `limitk`'s early `break seriesLoop`, and the `seriess` accumulation that
	// replaces the instant path's direct matrix append.
	kRange := []memSeriesInJSON{
		fs([]string{"__name__", "kr", "job", "a", "i", "1"},
			[2]int64{0, 5}, [2]int64{60_000, 50}, [2]int64{120_000, 500}),
		fs([]string{"__name__", "kr", "job", "a", "i", "2"},
			[2]int64{0, 3}, [2]int64{60_000, 30}, [2]int64{120_000, 300}),
		fs([]string{"__name__", "kr", "job", "b", "i", "1"},
			[2]int64{0, 9}, [2]int64{60_000, 1}, [2]int64{120_000, 900}),
		fs([]string{"__name__", "kr", "job", "b", "i", "2"},
			[2]int64{0, 7}, [2]int64{60_000, 70}, [2]int64{120_000, 7}),
	}
	kRangeCases := []struct {
		query            string
		start, end, step int64
	}{
		// `k < 1` returns early from the WHOLE step, after advancing the remaining series — so
		// the next step must not read their stale points. A `k` that crosses 1 mid-query is what
		// separates advancing from not advancing.
		{`topk(scalar(vector(time() / 60 - 1)), kr)`, 0, 120_000, minute},
		{`limitk(scalar(vector(time() / 60 - 1)), kr)`, 0, 120_000, minute},
		{`limit_ratio(scalar(vector(time() / 120)), kr)`, 0, 120_000, minute},
		// A ratio series whose MAX is 0 while its min is negative, which is the only shape that
		// separates `max == 0 && min == 0` from `max == 0`: the negative ratios still select the
		// complement, so the query must NOT return early.
		{`limit_ratio(scalar(vector(0 - time() / 120)), kr)`, 0, 120_000, minute},
		{`limit_ratio(scalar(vector(time() / 120 - 1)), kr)`, 0, 120_000, minute},
		// `limitk`'s early break, which fires once every group has its k — and then has to
		// advance the rest.
		{`limitk(1, kr)`, 0, 120_000, minute},
		{`limitk by (job) (1, kr)`, 0, 120_000, minute},
		{`limitk(2, kr)`, 0, 120_000, minute},
		{`limitk(3, kr)`, 0, 120_000, minute},
		// The `seriess` accumulation: a series that is in the top k at one step and not at
		// another gets a ragged output row, which the instant path cannot show.
		{`topk(1, kr)`, 0, 120_000, minute},
		{`topk(2, kr)`, 0, 120_000, minute},
		{`bottomk(1, kr)`, 0, 120_000, minute},
		{`bottomk(2, kr)`, 0, 120_000, minute},
		{`topk by (job) (1, kr)`, 0, 120_000, minute},
		{`bottomk by (job) (1, kr)`, 0, 120_000, minute},
		{`limit_ratio(0.5, kr)`, 0, 120_000, minute},
		{`limit_ratio(-0.5, kr)`, 0, 120_000, minute},
		// count_values across steps, where the value label changes per step.
		{`sort_by_label(count_values("v", kr), "v")`, 0, 120_000, minute},
		{`sort_by_label(count_values by (job) ("v", kr), "job", "v")`, 0, 120_000, minute},
		// One-step range queries, so the instant shortcut is compared against its absence.
		{`topk(2, kr)`, 60_000, 60_000, minute},
		{`limitk(2, kr)`, 60_000, 60_000, minute},
	}
	for _, c := range kRangeCases {
		emit(execRangeIn{
			Query: c.query, Start: i64(c.start), End: i64(c.end), Step: i64(c.step),
			Lookback: i64(5 * minute), Series: kRange,
		})
	}

	// A NESTED aggregation under a limit, which is the only shape that can see the
	// `ev.currentSamples = originalNumSamples + result.TotalSamples()` at the end of the
	// `AggregateExpr` arm — the same mechanism as quirk 81's `rangeEval` tail.
	for _, maxSamples := range []int{4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28} {
		for _, q := range []string{
			`sum(sum by (job) (ar))`, `sum(ar) + sum(ar)`, `max(sum by (job) (ar))`,
			`abs(sum by (job) (ar))`,
		} {
			emit(execRangeIn{
				Query: q, Start: i64(0), End: i64(180_000), Step: i64(minute),
				Lookback: i64(5 * minute), MaxSamples: maxSamples, Series: aggRange,
			})
		}
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
