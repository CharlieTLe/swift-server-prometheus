package main

// Differential coverage for promql/engine.go's EXECUTION path, as far as it is ported:
// `Exec` → `exec` → `execEvalStmt`'s instant branch → `evaluator.Eval` → `rangeEval` and
// the arms that need no storage.
//
// Every case here is an instant query over a Queryable whose querier returns nothing, so
// the answer depends only on the expression — which is exactly the subset the port
// implements. Selectors, aggregations, subqueries, matrix arguments and the vector binops
// are NOT in the corpus: the port throws for them by name, and a fixture asserting Go's
// answer for something the port refuses would be a fixture that can never pass.
//
// ## The observables
//
//	valueType  Vector, scalar, string — which of execEvalStmt's three tails ran
//	value      Value.String(), which is the ported value.go rendering
//	err        Go's error text, "" when the query succeeded
//	warnings   sorted, because Annotations is a map (PORTING.md exception 7)
//	stmt       the statement's String() AFTER Exec, which is how setOffsetForAtModifier's
//	           in-place AST rewrite becomes visible
//
// ## What has to be reached
//
//   - all three result tails: a scalar (`1+2`), an instant vector (`vector(1)`), a string;
//   - `rangeEval`'s instant shortcut, which builds the matrix in the RESULT VECTOR's order
//     rather than through a hash map — load-bearing for `sort`;
//   - the sample limit, which is checked AFTER the function call, so a query that exceeds it
//     is computed in full first;
//   - `maxSamples` of 0 and 1, where even a one-sample result is rejected or barely fits;
//   - unary minus, whose metadata-label drop and `DropName` are visible through the
//     rendering;
//   - `@` on a selector-free expression — `time() @ 100` — where setOffsetForAtModifier has
//     nothing to rewrite but the step-invariant wrapper still shows in the statement;
//   - every scalar comparison, which returns 1 or 0 rather than filtering;
//   - division and modulo by zero, and NaN operands, where the rendering is `GoFloat`'s.

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/storage"
)

type execIn struct {
	Query string `json:"query"`
	// `EnableDelayedNameRemoval`, which `promqltest` sets TRUE (test.go:111) — so it is what the
	// exit gate runs, and the server's default of false is the *other* case. It changes the result
	// of every function that drops `__name__`: with it on, the labels survive until
	// `cleanupMetricLabels` at the top of `Eval`, so an intermediate result keeps its name and a
	// nested expression can still match on it.
	Delayed bool `json:"delayed"`
	// Milliseconds.
	Ts string `json:"ts"`
	// Nanoseconds.
	Lookback   string `json:"lookback"`
	MaxSamples int    `json:"maxSamples"`
	// The series to load before running. Empty means the querier returns nothing, which is
	// all the selector-free arms need.
	Series []memSeriesInJSON `json:"series"`
}

type execOut struct {
	ValueType string   `json:"valueType"`
	Value     string   `json:"value"`
	Err       string   `json:"err"`
	Warnings  []string `json:"warnings"`
	Stmt      string   `json:"stmt"`
}

// execEmptyQueryable hands out a querier that knows nothing, which is all the ported arms
// need: none of them reads it.
type execEmptyQueryable struct{}

func (execEmptyQueryable) Querier(int64, int64) (storage.Querier, error) {
	return storage.NoopQuerier(), nil
}

func runExecCase(in execIn) execOut {
	eng := promql.NewEngine(promql.EngineOpts{
		MaxSamples:               in.MaxSamples,
		Timeout:                  time.Minute,
		LookbackDelta:            time.Duration(parseI64(in.Lookback)),
		EnableAtModifier:         true,
		EnableNegativeOffset:     true,
		EnableDelayedNameRemoval: in.Delayed,
		NoStepSubqueryIntervalFn: func(int64) int64 { return int64(time.Minute / time.Millisecond) },
		Parser: parser.NewParser(parser.Options{
			EnableExperimentalFunctions: true,
			// `anchored` and `smoothed` on a range selector, which `matrixSelector`'s
			// `extendFloats` path needs. Parser-only: the engine has no matching flag.
			EnableExtendedRangeSelectors: true,
			// `fill`/`fill_left`/`fill_right` on a binary operator.
			EnableBinopFillModifiers: true,
		}),
	})
	ts := time.UnixMilli(parseI64(in.Ts)).UTC()
	var queryable storage.Queryable = execEmptyQueryable{}
	if len(in.Series) > 0 {
		// A real tsdb.DB through util/teststorage, which is what the Swift side's in-memory
		// Queryable is itself pinned against (PR #20).
		st := loadMemStorage(in.Series)
		defer st.Close()
		queryable = st
	}
	q, err := eng.NewInstantQuery(
		context.Background(), queryable, nil, in.Query, ts)
	if err != nil {
		return execOut{Err: err.Error(), Warnings: []string{}}
	}
	res := q.Exec(context.Background())
	out := execOut{Warnings: []string{}}
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
	// AFTER Exec: execEvalStmt rewrote the AST in place, and this is where that shows.
	out.Stmt = q.Statement().String()
	return out
}

func genPromQLExec(e *emitter) {
	n := 0
	emit := func(in execIn) {
		if in.MaxSamples == 0 {
			in.MaxSamples = 50_000_000
		}
		if in.Series == nil {
			in.Series = []memSeriesInJSON{}
		}
		e.emit(fmt.Sprintf("exec/%d", n), in, runExecCase(in))
		n++
	}

	queries := []string{
		// Literals, and the three result tails.
		`1`, `-1`, `0`, `1.5`, `1e100`, `Inf`, `-Inf`, `NaN`,
		`"a string"`, `""`, `"ünïcödé"`,
		`vector(1)`, `vector(0)`, `vector(NaN)`,
		// Parens and unary minus, including double negation.
		`(1)`, `((1))`, `-(1)`, `- -1`, `-(vector(1))`, `-vector(NaN)`,
		// Every scalar binary operator. The comparisons are ARITHMETIC here — `1 > 2` is 0,
		// not "no data" — which is the whole reason scalar comparisons exist.
		`1 + 2`, `1 - 2`, `2 * 3`, `7 / 2`, `7 % 3`, `2 ^ 10`,
		// A scalar comparison needs `bool` — "comparisons between scalars must use BOOL
		// modifier" — so the bare forms are parse errors and the `bool` forms are what
		// actually reach scalarBinop's comparison arms. Both are in the corpus: the parse
		// error is a real answer, and without the `bool` forms six arms would be untested.
		`1 == 1`, `1 > 2`,
		`1 == bool 1`, `1 == bool 2`, `1 != bool 2`, `1 != bool 1`,
		`1 > bool 2`, `2 > bool 1`, `1 < bool 2`, `2 < bool 1`,
		`1 >= bool 1`, `1 >= bool 2`, `1 <= bool 0`, `1 <= bool 1`,
		`NaN == bool NaN`, `NaN != bool NaN`, `NaN > bool 1`, `Inf > bool 1`,
		// Right-associativity of `^`, and precedence against unary minus.
		`2 ^ 3 ^ 2`, `-2 ^ 2`, `(-2) ^ 2`,
		// Division and modulo by zero, and NaN operands — the rendering is GoFloat's.
		// atan2, PromQL's only binary math operator: the sign of zero and the quadrant are
		// what its nine ordered special cases decide.
		`1 atan2 1`, `-1 atan2 1`, `1 atan2 -1`, `-1 atan2 -1`,
		`0 atan2 0`, `0 atan2 -1`, `1 atan2 0`, `-1 atan2 0`,
		`Inf atan2 Inf`, `Inf atan2 -Inf`, `NaN atan2 1`, `1 atan2 NaN`,
		`1 / 0`, `-1 / 0`, `0 / 0`, `1 % 0`, `NaN + 1`, `NaN == NaN`, `NaN != NaN`,
		`Inf - Inf`, `Inf / Inf`, `Inf * 0`,
		// Functions with no matrix argument, over scalars and over `vector()`.
		`time()`, `pi()`, `abs(-3)`, `ceil(vector(1.2))`, `floor(vector(1.8))`,
		`round(vector(1.5))`, `round(vector(1.5), 2)`, `sqrt(vector(16))`,
		`exp(vector(0))`, `ln(vector(1))`, `log2(vector(8))`, `log10(vector(1000))`,
		`sgn(vector(-2))`, `clamp(vector(5), 1, 3)`, `clamp_min(vector(5), 7)`,
		`scalar(vector(42))`, `scalar(vector(NaN))`,
		// The date functions, which read the evaluation time when given no argument.
		`day_of_week()`, `day_of_month()`, `days_in_month()`, `hour()`, `minute()`,
		`month()`, `year()`, `day_of_year()`,
		`day_of_week(vector(0))`, `year(vector(1e9))`,
		// The trigonometry and hyperbolics, which are GoMath's own algorithms.
		`sin(vector(1))`, `cos(vector(1))`, `tan(vector(1))`, `asin(vector(0.5))`,
		`sinh(vector(1))`, `tanh(vector(1))`, `atan(vector(1))`,
		`rad(vector(180))`, `deg(vector(3.14159))`,
		// timestamp over a scalar-producing expression.
		`timestamp(vector(1))`,
		// Nested calls and mixed arithmetic.
		`abs(-1) + ceil(vector(0.5))`,
		`scalar(vector(3)) * 2`,
		`(1 + 2) * (3 - 4)`,
		// `@` with no selector to rewrite: setOffsetForAtModifier walks and finds nothing,
		// but the step-invariant wrapper shows in the statement.
		`time() @ 100`,
		`time() @ start()`,
		`vector(time() @ 100)`,
		// A histogram-producing function over a synthesised vector is NOT here: it needs a
		// selector. Neither is `sort`, whose input has to come from storage.
	}

	for _, q := range queries {
		for _, ts := range []int64{0, 1_600_000_000_000, -1_000} {
			emit(execIn{
				Query: q, Ts: i64(ts), Lookback: i64(int64(5 * time.Minute)),
			})
		}
	}

	// The sample limit. It is checked AFTER the call, so the result is computed in full and
	// then rejected — and `maxSamples: 1` is enough for a one-sample result while 0 is not.
	for _, maxSamples := range []int{0, 1, 2} {
		for _, q := range []string{`1`, `vector(1)`, `1 + 2`, `"a string"`} {
			emit(execIn{
				Query: q, Ts: i64(1_600_000_000_000),
				Lookback: i64(int64(5 * time.Minute)), MaxSamples: maxSamples,
			})
		}
	}

	// The sample-limit BOUNDARY per shape, because gatherVector's counting makes the peak
	// higher than the result alone: `vector(1)` needs 3 and `1 + 2` needs 5.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6} {
		// `vector(1) + 1` is deliberately absent: a vector/scalar binop is not ported, so a
		// case for it could never pass. It arrives with the selectors.
		for _, q := range []string{`vector(1)`, `1 + 2`, `(1 + 2) * 3`, `scalar(vector(1)) + 1`} {
			emit(execIn{
				Query: q, Ts: i64(1_600_000_000_000),
				Lookback: i64(int64(5 * time.Minute)), MaxSamples: maxSamples,
			})
		}
	}

	// --- SELECTORS, over a real tsdb.DB. This is where the lookback window, the offset and
	// the multi-series behaviours become observable — several negative controls for
	// rangeEval and execEvalStmt could not fail without more than one series.
	fs := func(labels []string, points ...[2]int64) memSeriesInJSON {
		out := memSeriesInJSON{Labels: labels}
		for _, p := range points {
			out.T = append(out.T, i64(p[0]))
			out.ST = append(out.ST, i64(0))
			out.F = append(out.F, fbits(float64(p[1])))
		}
		return out
	}
	// Three series sharing a name, so the vector has several members and their ORDER — which
	// rangeEval's instant shortcut takes from the result vector — is pinned.
	threeSeries := []memSeriesInJSON{
		fs([]string{"__name__", "http_requests", "job", "b"}, [2]int64{0, 1}, [2]int64{60_000, 2}),
		fs([]string{"__name__", "http_requests", "job", "a"}, [2]int64{0, 10}, [2]int64{60_000, 20}),
		fs([]string{"__name__", "http_requests", "job", "c"}, [2]int64{0, 100}),
	}
	// Two appends with the SAME label set, which the storage merges into one series before
	// PromQL ever sees them — so this shows why the evaluator's own merge is unreachable here.
	collide := []memSeriesInJSON{
		fs([]string{"__name__", "collide", "a", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "collide", "a", "1"}, [2]int64{60_000, 2}),
	}
	// Two series differing in one label at the same timestamp: dropping `__name__` leaves them
	// still distinct, so there is nothing to merge.
	clash := []memSeriesInJSON{
		fs([]string{"__name__", "clash", "b", "1"}, [2]int64{60_000, 1}),
		fs([]string{"__name__", "clash", "b", "2"}, [2]int64{60_000, 2}),
	}

	// A single series with a gap, for the lookback boundary.
	gapped := []memSeriesInJSON{
		fs([]string{"__name__", "gap"}, [2]int64{0, 1}, [2]int64{600_000, 2}),
	}
	// A stale marker, which drops the sample as if it were absent.
	staleSeries := []memSeriesInJSON{
		{
			Labels: []string{"__name__", "stale"},
			T:      []string{i64(0), i64(60_000)},
			ST:     []string{i64(0), i64(0)},
			F:      []string{fbits(1), "7ff0000000000002"},
		},
	}

	selectorCases := []struct {
		query  string
		series []memSeriesInJSON
		ts     int64
	}{
		// A bare selector at a sample, between samples, and past the lookback window.
		{`http_requests`, threeSeries, 0},
		{`http_requests`, threeSeries, 60_000},
		{`http_requests`, threeSeries, 120_000},
		// 5m lookback: 300_000 still sees the 60s sample, 360_001 does not.
		{`http_requests`, threeSeries, 359_999},
		{`http_requests`, threeSeries, 360_000},
		{`http_requests`, threeSeries, 360_001},
		// A matcher that selects one series, and one that selects none.
		{`http_requests{job="a"}`, threeSeries, 60_000},
		{`http_requests{job="zzz"}`, threeSeries, 60_000},
		{`{__name__="http_requests", job=~"a|b"}`, threeSeries, 60_000},
		// `offset`, which shifts the reference time.
		{`http_requests offset 1m`, threeSeries, 60_000},
		{`http_requests offset -1m`, threeSeries, 0},
		// `@`, which setOffsetForAtModifier turns into an offset — and this is the first
		// corpus case where that rewrite changes an ANSWER rather than just an AST.
		{`http_requests @ 0`, threeSeries, 300_000},
		{`http_requests @ 60`, threeSeries, 0},
		// The lookback boundary in isolation, which is half-open: a sample exactly
		// lookbackDelta old is EXCLUDED.
		{`gap`, gapped, 300_000},
		{`gap`, gapped, 300_001},
		{`gap`, gapped, 600_000},
		{`gap`, gapped, 900_000},
		{`gap`, gapped, 900_001},
		// A stale marker: no sample, not a NaN sample.
		{`stale`, staleSeries, 60_000},
		{`stale`, staleSeries, 0},
		// The selector-consuming arms that ARE ported: parens, unary minus over several
		// series (where DropName and the metadata drop finally show), and `scalar` over a
		// multi-member vector (which is NaN, not the first value).
		{`(http_requests)`, threeSeries, 60_000},
		{`-http_requests`, threeSeries, 60_000},
		{`scalar(http_requests)`, threeSeries, 60_000},
		{`scalar(http_requests{job="a"})`, threeSeries, 60_000},
		// `timestamp(<selector>)` goes through rangeEvalTimestampFunctionOverVectorSelector,
		// which reports the SAMPLE's timestamp where a matrix evaluation reports the STEP's.
		// The three series' last samples differ, so the two paths disagree here — which is
		// exactly why the case is worth having.
		{`timestamp(http_requests)`, threeSeries, 60_000},
		{`timestamp(http_requests)`, threeSeries, 120_000},
		{`timestamp(gap)`, gapped, 300_000},
		// That path builds its iterator with `lookbackDelta - 1`, where evalSeries uses the
		// full delta — so a sample exactly at the boundary is visible to one and not the
		// other. These two straddle it.
		{`timestamp(gap)`, gapped, 299_999},
		{`timestamp(gap)`, gapped, 300_001},
		// With `@` the selector's offset is rewritten every step (upstream issue 8433).
		{`timestamp(http_requests @ 0)`, threeSeries, 300_000},
		{`timestamp(http_requests @ 60)`, threeSeries, 0},
		// Unary minus over series that are candidates for collision — and the finding is
		// that they are NOT. `mergeSeriesWithSameLabelset` turns out to be UNREACHABLE
		// through a selector: two series with identical label sets are one series to the
		// storage (which is what `collide` demonstrates — it arrives already merged), and two
		// series that differ in any label still differ after `__name__` is dropped (`clash`).
		// Reaching the merge needs a function that drops a DIFFERING label — label_replace, or
		// an aggregation — so its own corpus arrives with those. Both cases stay, because
		// "these do not collide" is exactly what a future reader will want to know.
		{`-collide`, collide, 60_000},
		{`-clash`, clash, 60_000},
		// A function over a selector, which is the ordinary Call path.
		{`abs(-http_requests)`, threeSeries, 60_000},
		{`ceil(http_requests)`, threeSeries, 60_000},
	}
	for _, c := range selectorCases {
		emit(execIn{
			Query: c.query, Ts: i64(c.ts), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}

	// The sample limit over real series, where each series costs one.
	for _, maxSamples := range []int{1, 2, 3, 4} {
		emit(execIn{
			Query: `http_requests`, Ts: i64(60_000),
			Lookback: i64(int64(5 * time.Minute)), MaxSamples: maxSamples,
			Series: threeSeries,
		})
	}

	// --- MATRIX SELECTORS. `foo[5m]` as a value in its own right, which is `matrixSelector`
	// plus `matrixIterSlice`. Its window is `(mint, maxt]` — HALF-OPEN at the bottom and CLOSED
	// at the top — so a point exactly on `mint` is excluded and one exactly on `maxt` is not.
	// The `[2m]` cases at ts=120000 straddle that boundary on purpose.
	//
	// Note what a bare matrix selector does NOT go through: `rangeEval`. The `MatrixSelector`
	// arm returns `matrixSelector`'s output directly, so the sample accounting here is
	// `matrixIterSlice`'s alone.
	matrixSeries := []memSeriesInJSON{
		fs([]string{"__name__", "m", "job", "b"},
			[2]int64{0, 1}, [2]int64{60_000, 2}, [2]int64{120_000, 3}),
		fs([]string{"__name__", "m", "job", "a"},
			[2]int64{0, 10}, [2]int64{60_000, 20}, [2]int64{120_000, 30}),
		fs([]string{"__name__", "m", "job", "c"}, [2]int64{0, 100}),
	}
	// A stale marker inside the window: the point is dropped, and it does not count against
	// the sample limit either.
	matrixStale := []memSeriesInJSON{
		{
			Labels: []string{"__name__", "ms"},
			T:      []string{i64(0), i64(60_000), i64(120_000)},
			ST:     []string{i64(0), i64(0), i64(0)},
			F:      []string{fbits(1), "7ff0000000000002", fbits(3)},
		},
	}
	// Samples at irregular offsets, which is what makes `anchored` and `smoothed` differ from
	// the plain form at all: with samples on the step grid the synthetic boundary points
	// coincide with real ones.
	matrixIrregular := []memSeriesInJSON{
		fs([]string{"__name__", "mi"},
			[2]int64{10_000, 1}, [2]int64{47_000, 5}, [2]int64{83_000, 9},
			[2]int64{131_000, 20}),
	}

	// A chunk that SPANS the anchored window with no sample inside it. The querier admits the
	// series (visibility is at chunk granularity) and then trims it to nothing (quirk 34), so
	// `extendFloats` is handed an EMPTY slice — and `floats[len(floats)-1]` on an empty slice is
	// an index out of range. Included to find out what upstream actually does.
	matrixGap := []memSeriesInJSON{
		fs([]string{"__name__", "mg"}, [2]int64{0, 1}, [2]int64{1_000_000, 2}),
	}
	// A sample exactly on the ORIGINAL maxt with a further sample inside the smoothed widening.
	// That is the only shape where `extendFloats`' upper search can tell `>= maxt` from
	// `> maxt`: with the boundary sample at the last index both spellings agree.
	matrixTail := []memSeriesInJSON{
		fs([]string{"__name__", "mt"},
			[2]int64{10_000, 1}, [2]int64{47_000, 5}, [2]int64{83_000, 9},
			[2]int64{131_000, 20}, [2]int64{200_000, 50}),
	}

	matrixCases := []struct {
		query  string
		series []memSeriesInJSON
		ts     int64
	}{
		// The boundary. At ts=120000 with `[2m]`, mint is 0 (EXCLUDED) and maxt is 120000
		// (INCLUDED) — so `c`, whose only sample is at 0, disappears entirely.
		{`m[2m]`, matrixSeries, 120_000},
		// `[2m1ms]` moves mint to -1000, which lets the sample at 0 back in.
		{`m[2m1ms]`, matrixSeries, 120_000},
		// Windows that hold everything, one point, and nothing.
		{`m[10m]`, matrixSeries, 120_000},
		{`m[1m]`, matrixSeries, 120_000},
		{`m[1s]`, matrixSeries, 120_000},
		{`m[10m]`, matrixSeries, 0},
		{`m[10m]`, matrixSeries, 1_000_000},
		{`m[5m]`, matrixSeries, 60_000},
		// A matcher selecting one series, and one selecting none.
		{`m{job="a"}[10m]`, matrixSeries, 120_000},
		{`m{job="zzz"}[10m]`, matrixSeries, 120_000},
		// `offset` shifts both ends of the window by the same amount.
		{`m[2m] offset 1m`, matrixSeries, 180_000},
		{`m[2m] offset -1m`, matrixSeries, 60_000},
		// `@`, which `setOffsetForAtModifier` turns into an offset before evaluation — so the
		// window is pinned and the evaluation time is irrelevant.
		{`m[2m] @ 120`, matrixSeries, 1_000_000},
		{`m[2m] @ 60`, matrixSeries, 0},
		// A stale marker in the middle of the window.
		{`ms[10m]`, matrixStale, 120_000},
		{`ms[10m]`, matrixStale, 60_000},
		// Irregular sample times, plain.
		{`mi[2m]`, matrixIrregular, 120_000},
		{`mi[2m]`, matrixIrregular, 131_000},
		// `anchored`: `extendFloats` adds a point at each end of the ORIGINAL window, taking
		// the nearest sample at or before it. The buffer is widened by one lookbackDelta to
		// find that sample, which is the storage-side half of quirk 68.
		{`mi[2m] anchored`, matrixIrregular, 120_000},
		{`mi[1m] anchored`, matrixIrregular, 120_000},
		{`mi[10m] anchored`, matrixIrregular, 131_000},
		{`m[2m] anchored`, matrixSeries, 120_000},
		// A window whose samples are ALL at or before mint: `extendFloats` returns empty, and
		// the series is then dropped for having no points.
		{`mi[1s] anchored`, matrixIrregular, 120_000},
		// `smoothed`: two lookbackDeltas of buffer, mint back and maxt FORWARD, and the
		// boundary points are interpolated rather than picked.
		{`mi[2m] smoothed`, matrixIrregular, 120_000},
		{`mi[1m] smoothed`, matrixIrregular, 120_000},
		{`mi[10m] smoothed`, matrixIrregular, 131_000},
		{`m[2m] smoothed`, matrixSeries, 120_000},
		{`mi[1s] smoothed`, matrixIrregular, 120_000},
		// The empty-window probe.
		{`mg[2m] anchored`, matrixGap, 500_000},
		{`mg[2m] smoothed`, matrixGap, 500_000},
		{`mg[2m]`, matrixGap, 500_000},
		// The smoothed upper-boundary search, where a sample sits exactly on the original maxt
		// and another lies inside the widening.
		{`mt[2m] smoothed`, matrixTail, 131_000},
		{`mt[1m] smoothed`, matrixTail, 131_000},
		{`mt[2m] anchored`, matrixTail, 131_000},
		{`mt[2m]`, matrixTail, 131_000},
	}
	for _, c := range matrixCases {
		emit(execIn{
			Query: c.query, Ts: i64(c.ts), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}
	// The sample limit against a matrix selector, which counts per POINT rather than per
	// series — nine points across three series at `[10m]`, so the boundary is at 9.
	for _, maxSamples := range []int{1, 2, 3, 5, 6, 7, 8, 9, 10} {
		emit(execIn{
			Query: `m[10m]`, Ts: i64(120_000),
			Lookback: i64(int64(5 * time.Minute)), MaxSamples: maxSamples,
			Series: matrixSeries,
		})
		// And with a stale marker in the window, where the dropped point does not count.
		emit(execIn{
			Query: `ms[10m]`, Ts: i64(120_000),
			Lookback: i64(int64(5 * time.Minute)), MaxSamples: maxSamples,
			Series: matrixStale,
		})
	}

	// --- VECTOR BINARY OPERATORS. Four shapes — vector/vector, vector/scalar, scalar/vector and
	// the three set operators — plus the matching modifiers.
	//
	// The join key is turned into a small integer ORDINAL once per node, across both sides at
	// once, so every case here exercises `rangeEval`'s signature machinery as well as the
	// operator. Two label sets that agree on the join labels share an ordinal, and that sharing
	// is the entire mechanism.
	binL := []memSeriesInJSON{
		fs([]string{"__name__", "left", "job", "a", "inst", "1"}, [2]int64{0, 10}),
		fs([]string{"__name__", "left", "job", "a", "inst", "2"}, [2]int64{0, 20}),
		fs([]string{"__name__", "left", "job", "b", "inst", "1"}, [2]int64{0, 30}),
		fs([]string{"__name__", "right", "job", "a", "inst", "1"}, [2]int64{0, 2}),
		fs([]string{"__name__", "right", "job", "a", "inst", "2"}, [2]int64{0, 4}),
		fs([]string{"__name__", "right", "job", "c", "inst", "1"}, [2]int64{0, 8}),
	}
	// A "one" side with a single series per job, for group_left/group_right.
	binOne := []memSeriesInJSON{
		fs([]string{"__name__", "many", "job", "a", "inst", "1"}, [2]int64{0, 10}),
		fs([]string{"__name__", "many", "job", "a", "inst", "2"}, [2]int64{0, 20}),
		fs([]string{"__name__", "many", "job", "b", "inst", "1"}, [2]int64{0, 30}),
		fs([]string{"__name__", "one", "job", "a", "extra", "x"}, [2]int64{0, 2}),
		fs([]string{"__name__", "one", "job", "b", "extra", "y"}, [2]int64{0, 4}),
	}
	// TWO series on the "one" side of the same match group, which is the many-to-many error.
	binDup := []memSeriesInJSON{
		fs([]string{"__name__", "many", "job", "a", "inst", "1"}, [2]int64{0, 10}),
		fs([]string{"__name__", "one", "job", "a", "k", "1"}, [2]int64{0, 2}),
		fs([]string{"__name__", "one", "job", "a", "k", "2"}, [2]int64{0, 3}),
	}
	// Two lefts that reduce to the SAME result label set under `ignoring`, which is the
	// one-to-one "many-to-one matching must be explicit" error.
	binAmbig := []memSeriesInJSON{
		fs([]string{"__name__", "l", "job", "a", "x", "1"}, [2]int64{0, 10}),
		fs([]string{"__name__", "l", "job", "a", "x", "2"}, [2]int64{0, 20}),
		fs([]string{"__name__", "r", "job", "a"}, [2]int64{0, 2}),
	}
	// Values that make the comparisons discriminate, and a zero for division.
	binCmp := []memSeriesInJSON{
		fs([]string{"__name__", "cl", "k", "lo"}, [2]int64{0, 1}),
		fs([]string{"__name__", "cl", "k", "hi"}, [2]int64{0, 100}),
		fs([]string{"__name__", "cr", "k", "lo"}, [2]int64{0, 50}),
		fs([]string{"__name__", "cr", "k", "hi"}, [2]int64{0, 50}),
		fs([]string{"__name__", "cr", "k", "zero"}, [2]int64{0, 0}),
		fs([]string{"__name__", "cl", "k", "zero"}, [2]int64{0, 7}),
	}

	// Two label sets whose join keys CONCATENATE ambiguously if the encoder omits the separator
	// after each value: `j=x, bc=y` and `j=xb, c=y` both render as `j <SEP> xbc <SEP> y` without
	// it. The framing is `name SEP value SEP` for exactly this reason.
	binAmbigBytes := []memSeriesInJSON{
		fs([]string{"__name__", "ab", "j", "x", "bc", "y"}, [2]int64{0, 10}),
		fs([]string{"__name__", "ab2", "j", "xb", "c", "y"}, [2]int64{0, 20}),
	}
	// Two "many" series differing ONLY in `__name__`, so the arithmetic result — which drops the
	// name — collides. That is the many-to-one "grouping labels must ensure unique matches" error,
	// and it needs the RESULT hash rather than the input's to be detected.
	binNameCollide := []memSeriesInJSON{
		fs([]string{"__name__", "m1", "job", "a"}, [2]int64{0, 10}),
		fs([]string{"__name__", "m2", "job", "a"}, [2]int64{0, 20}),
		fs([]string{"__name__", "one", "job", "a", "extra", "x"}, [2]int64{0, 2}),
	}
	// Two "many" series differing only in a label that `group_left(extra)` OVERWRITES from the one
	// side, plus a comparison that is false for both — so `keep` is false and the duplicate check
	// still has to fire. That is what orders the check before the filter.
	binIncludeCollide := []memSeriesInJSON{
		fs([]string{"__name__", "m", "job", "a", "extra", "p"}, [2]int64{0, 1}),
		fs([]string{"__name__", "m", "job", "a", "extra", "q"}, [2]int64{0, 2}),
		fs([]string{"__name__", "one", "job", "a", "extra", "x"}, [2]int64{0, 99}),
	}

	// All three schema metadata labels, so "drops the name" and "drops the metadata" are separable.
	metaSeries := []memSeriesInJSON{
		fs([]string{"__name__", "meta", "__type__", "counter", "__unit__", "seconds", "job", "a"},
			[2]int64{0, 10}, [2]int64{60_000, 20}),
		fs([]string{"__name__", "meta", "__type__", "gauge", "__unit__", "bytes", "job", "b"},
			[2]int64{0, 30}, [2]int64{60_000, 60}),
	}

	binopCases := []struct {
		query  string
		series []memSeriesInJSON
	}{
		// vector/vector arithmetic. The default matching is `ignoring()` with one-to-one, so the
		// join key is every label except `__name__` — and the RESULT loses `__name__` too,
		// because `changesMetricSchema` is true for the arithmetic operators.
		{`left + right`, binL},
		{`left - right`, binL},
		{`left * right`, binL},
		{`left / right`, binL},
		{`left % right`, binL},
		{`left ^ right`, binL},
		{`left atan2 right`, binL},
		// ...and the comparisons, which KEEP `__name__` because they do not change the schema,
		// and which filter rather than compute.
		{`cl > cr`, binCmp},
		{`cl < cr`, binCmp},
		{`cl >= cr`, binCmp},
		{`cl <= cr`, binCmp},
		{`cl == cr`, binCmp},
		{`cl != cr`, binCmp},
		// `bool` turns a filter into arithmetic AND drops the name.
		{`cl > bool cr`, binCmp},
		{`cl == bool cr`, binCmp},
		{`cl != bool cr`, binCmp},
		// `on` and `ignoring`, which pick the join labels — and therefore which series pair up.
		{`left + on(job) right`, binL},
		{`left + on(inst) right`, binL},
		{`left + on(job, inst) right`, binL},
		{`left + ignoring(inst) right`, binL},
		{`left + ignoring(job) right`, binL},
		{`left + on() right`, binL},
		// `group_left`/`group_right` with and without an include list. `Include` is taken from
		// the "one" side, and an EMPTY value there deletes the label rather than leaving it.
		{`many * on(job) group_left one`, binOne},
		{`many * on(job) group_left(extra) one`, binOne},
		{`many * on(job) group_left(nosuch) one`, binOne},
		{`one * on(job) group_right many`, binOne},
		{`one * on(job) group_right(extra) many`, binOne},
		{`many / ignoring(inst) group_left one`, binOne},
		// The three duplicate-match errors, each with its own message.
		{`many * on(job) group_left one`, binDup},
		{`many * on(job) one`, binDup},
		{`l + ignoring(x) r`, binAmbig},
		{`l + ignoring(x) group_left r`, binAmbig},
		// The set operators. `and` keeps the LEFT's samples untouched — no label surgery at all —
		// `or` fills in the right's unmatched groups, and `unless` is the complement of `and`.
		{`left and right`, binL},
		{`left or right`, binL},
		{`left unless right`, binL},
		{`left and on(job) right`, binL},
		{`left or on(job) right`, binL},
		{`left unless on(job) right`, binL},
		{`left and ignoring(inst) right`, binL},
		{`left or ignoring(inst) right`, binL},
		// One side empty, for each set operator: the short-circuits are NOT symmetric.
		{`left and nothing`, binL},
		{`nothing and left`, binL},
		{`left or nothing`, binL},
		{`nothing or left`, binL},
		{`left unless nothing`, binL},
		{`nothing unless left`, binL},
		// vector/scalar and scalar/vector. The metric always comes from the vector, and for a
		// comparison with the scalar on the LEFT the value is still the vector element's.
		{`left + 1`, binL},
		{`1 + left`, binL},
		{`left - 1`, binL},
		{`1 - left`, binL},
		{`left / 0`, binL},
		{`0 / left`, binL},
		{`left > 15`, binL},
		{`15 < left`, binL},
		{`left > bool 15`, binL},
		{`15 < bool left`, binL},
		{`left % 7`, binL},
		{`left ^ 2`, binL},
		{`left atan2 1`, binL},
		// A scalar-valued subexpression rather than a literal, so the scalar arm is reached
		// through `scalar()` too.
		{`left * scalar(cl{k="lo"})`, binCmp},
		// The join-key framing: these two agree on `j`+`bc`+`c` only if the encoder loses a
		// separator, so `on(j, bc, c)` must NOT pair them.
		{`ab + on(j, bc, c) ab2`, binAmbigBytes},
		{`{__name__=~"ab|ab2"} + on(j, bc, c) {__name__=~"ab|ab2"}`, binAmbigBytes},
		// A NON-COMMUTATIVE operator with group_right, which is the only shape that can see the
		// second of `VectorBinop`'s two swaps: `*` and `+` give the same answer either way round.
		{`one / on(job) group_right many`, binOne},
		{`one - on(job) group_right many`, binOne},
		{`one ^ on(job) group_right many`, binOne},
		{`one % on(job) group_right many`, binOne},
		{`one atan2 on(job) group_right many`, binOne},
		// ...and the same operators with group_left, so the pair differs only in direction.
		{`many / on(job) group_left one`, binOne},
		{`many - on(job) group_left one`, binOne},
		// The many-to-one result collision, which needs the RESULT's hash: two lefts differing
		// only in `__name__`, which the arithmetic drops.
		{`{__name__=~"m1|m2"} * on(job) group_left one`, binNameCollide},
		{`{__name__=~"m1|m2"} + on(job) group_left(extra) one`, binNameCollide},
		// ...and a comparison, which does NOT drop the name, so the same shape succeeds.
		{`{__name__=~"m1|m2"} > on(job) group_left one`, binNameCollide},
		// The duplicate check ORDER: `group_left(extra)` overwrites the only label that
		// distinguishes the two lefts, and the comparison is false for both — so `keep` is false
		// and the check has to fire anyway.
		{`m < on(job) group_left(extra) one`, binIncludeCollide},
		{`m > on(job) group_left(extra) one`, binIncludeCollide},
		{`m < bool on(job) group_left(extra) one`, binIncludeCollide},
		// An include label the "one" side does NOT have: the empty value DELETES it from the
		// result rather than leaving the many side's.
		{`many * on(job) group_left(inst) one`, binOne},
		{`many * on(job) group_left(inst, extra) one`, binOne},
		// Nested binops, where the inner result's dropped `__name__` changes the outer join.
		{`(left + right) + right`, binL},
		{`(left > right) + 1`, binL},
		{`left + right + left`, binL},
	}
	for _, c := range binopCases {
		emit(execIn{
			Query: c.query, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}
	// The sample limit against a binop, where `gatherVector` counts BOTH sides' inputs before the
	// operator runs — so the peak is inputs plus result, not result alone.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14} {
		for _, q := range []string{`left + right`, `left and right`, `left + 1`} {
			emit(execIn{
				Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
				MaxSamples: maxSamples, Series: binL,
			})
		}
	}

	// --- AGGREGATIONS. The nine one-row-per-group operators, over shapes chosen so the grouping,
	// the Kahan compensation and the histogram rejections are each visible.
	//
	// `by ()` with no labels hashes to 0 WITHOUT touching the metric, so `sum(x)` is one group;
	// `without (...)` drops `__name__` on top of the named labels, in BOTH the key and the output
	// labels, and by two different mechanisms.
	aggSeries := []memSeriesInJSON{
		fs([]string{"__name__", "m", "job", "a", "inst", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "m", "job", "a", "inst", "2"}, [2]int64{0, 2}),
		fs([]string{"__name__", "m", "job", "b", "inst", "1"}, [2]int64{0, 4}),
		fs([]string{"__name__", "m", "job", "b", "inst", "2"}, [2]int64{0, 8}),
		fs([]string{"__name__", "m", "job", "c", "inst", "1"}, [2]int64{0, 16}),
	}
	// Magnitudes that make Kahan compensation visible, and the magnitude MATTERS: `1e100` plus
	// twenty 1s is indistinguishable either way, because `1e100 ± 20` is not representable — the
	// compensation is computed and then rounded straight back off. At `1e16` the ULP is 2, so a
	// compensation of 20 survives the final add and the two spellings differ. HANDOFF §3's "a
	// short series pins the algebra and not the compensation", in its magnitude form.
	aggKahan := []memSeriesInJSON{
		{Labels: []string{"__name__", "k", "i", "00"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(1e16)}},
	}
	for i := 1; i <= 20; i++ {
		aggKahan = append(aggKahan, memSeriesInJSON{
			Labels: []string{"__name__", "k", "i", fmt.Sprintf("%02d", i)},
			T:      []string{i64(0)}, ST: []string{i64(0)}, F: []string{fbits(1)},
		})
	}
	// The same trick at a second magnitude, and alternating signs — the shape HANDOFF §3 records
	// for `varianceOverTime`'s compensation.
	aggKahan2 := []memSeriesInJSON{}
	for i := 0; i < 30; i++ {
		v := 1.0
		if i%2 == 0 {
			v = 1e17
		}
		aggKahan2 = append(aggKahan2, memSeriesInJSON{
			Labels: []string{"__name__", "k2", "i", fmt.Sprintf("%02d", i)},
			T:      []string{i64(0)}, ST: []string{i64(0)}, F: []string{fbits(v)},
		})
	}
	// INEXACT values, which is what a fused multiply-add needs to be visible at all: with small
	// integers both the product and the sum are exact and unfusing changes nothing (quirk 54).
	aggInexact := []memSeriesInJSON{
		{Labels: []string{"__name__", "ix", "i", "1"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(0.1)}},
		{Labels: []string{"__name__", "ix", "i", "2"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(1.0 / 3.0)}},
		{Labels: []string{"__name__", "ix", "i", "3"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(1e8 + 0.7)}},
		{Labels: []string{"__name__", "ix", "i", "4"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(2.0 / 7.0)}},
		{Labels: []string{"__name__", "ix", "i", "5"}, T: []string{i64(0)},
			ST: []string{i64(0)}, F: []string{fbits(1e-9)}},
	}
	// Values that overflow a direct sum, which is what flips `avg` to its incremental mean. Two
	// samples at MaxFloat64 * 0.6 sum to +Inf; their mean does not.
	aggOverflow := []memSeriesInJSON{
		{Labels: []string{"__name__", "ov", "i", "1"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(1.0e308)}},
		{Labels: []string{"__name__", "ov", "i", "2"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(1.1e308)}},
		{Labels: []string{"__name__", "ov", "i", "3"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(1.2e308)}},
	}
	// NaN and infinities, which seed `stdvar`/`stddev` with NaN and which `min`/`max` treat
	// asymmetrically — a NaN seed is REPLACED by a real value, which needs the `|| IsNaN` clause.
	aggSpecial := []memSeriesInJSON{
		{Labels: []string{"__name__", "sp", "i", "1"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{"7ff8000000000001"}},
		{Labels: []string{"__name__", "sp", "i", "2"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(5)}},
		{Labels: []string{"__name__", "sp", "i", "3"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(3)}},
	}
	aggInf := []memSeriesInJSON{
		{Labels: []string{"__name__", "inf", "i", "1"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{"7ff0000000000000"}},
		{Labels: []string{"__name__", "inf", "i", "2"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(1)}},
	}
	// Series with DIFFERENT names, so `without()` and `by()` group them together where the
	// `__name__` drop is what makes the labels collide.
	aggNames := []memSeriesInJSON{
		fs([]string{"__name__", "n1", "job", "a"}, [2]int64{0, 1}),
		fs([]string{"__name__", "n2", "job", "a"}, [2]int64{0, 2}),
	}

	aggCases := []struct {
		query  string
		series []memSeriesInJSON
	}{
		// The nine operators over one group.
		{`sum(m)`, aggSeries},
		{`avg(m)`, aggSeries},
		{`min(m)`, aggSeries},
		{`max(m)`, aggSeries},
		{`count(m)`, aggSeries},
		{`group(m)`, aggSeries},
		{`stddev(m)`, aggSeries},
		{`stdvar(m)`, aggSeries},
		{`quantile(0.5, m)`, aggSeries},
		{`quantile(0, m)`, aggSeries},
		{`quantile(1, m)`, aggSeries},
		{`quantile(0.25, m)`, aggSeries},
		// The grouping. `by ()` is one group; `by (job)` is three; `without (inst)` drops
		// `__name__` as well as `inst`.
		{`sum by () (m)`, aggSeries},
		{`sum by (job) (m)`, aggSeries},
		{`sum by (inst) (m)`, aggSeries},
		{`sum by (job, inst) (m)`, aggSeries},
		{`sum by (nosuch) (m)`, aggSeries},
		{`sum without (inst) (m)`, aggSeries},
		{`sum without (job) (m)`, aggSeries},
		{`sum without () (m)`, aggSeries},
		{`sum without (job, inst) (m)`, aggSeries},
		{`count by (job) (m)`, aggSeries},
		{`avg by (job) (m)`, aggSeries},
		{`quantile by (job) (0.5, m)`, aggSeries},
		{`stddev by (job) (m)`, aggSeries},
		// `without` groups two DIFFERENT metric names together, because it drops `__name__`.
		{`sum without (job) ({__name__=~"n1|n2"})`, aggNames},
		{`sum by (job) ({__name__=~"n1|n2"})`, aggNames},
		{`sum({__name__=~"n1|n2"})`, aggNames},
		// Kahan compensation: 1e100 plus three 1s. A naive sum loses the 1s entirely; the
		// compensated one is added back at the end.
		{`sum(k)`, aggKahan},
		{`avg(k)`, aggKahan},
		{`stddev(k)`, aggKahan},
		{`stdvar(k)`, aggKahan},
		{`sum(k2)`, aggKahan2},
		{`avg(k2)`, aggKahan2},
		{`stddev(k2)`, aggKahan2},
		{`stdvar(k2)`, aggKahan2},
		{`quantile(0.5, k2)`, aggKahan2},
		// INEXACT values, for Welford's fused multiply-add. With small integers the product and
		// the sum are both exact and unfusing it changes nothing.
		{`stdvar(ix)`, aggInexact},
		{`stddev(ix)`, aggInexact},
		{`avg(ix)`, aggInexact},
		{`sum(ix)`, aggInexact},
		{`quantile(0.5, ix)`, aggInexact},
		{`quantile(0.3, ix)`, aggInexact},
		// A group of ONE series whose value is NaN or infinite, which is the only shape where the
		// variance SEED is observable: with a second sample the Welford loop poisons the value to
		// NaN anyway, so the seed only shows when `groupCount` stays 1.
		{`stdvar by (i) (sp)`, aggSpecial},
		{`stddev by (i) (sp)`, aggSpecial},
		{`stdvar by (i) (inf)`, aggInf},
		{`stddev by (i) (inf)`, aggInf},
		// `group` seeds its value to 1, and `group(m)`'s first sample happens to BE 1 — so the
		// seed is only visible per-group, where some group's first sample is not.
		{`group by (job) (m)`, aggSeries},
		{`group by (inst) (m)`, aggSeries},
		{`group by (i) (sp)`, aggSpecial},
		// The overflow switch to an incremental mean. The direct sum goes +Inf; the mean is
		// finite, so a port that never switched would answer +Inf.
		{`avg(ov)`, aggOverflow},
		{`sum(ov)`, aggOverflow},
		{`avg by (i) (ov)`, aggOverflow},
		// NaN and infinity handling. `min`/`max` replace a NaN seed with a real value;
		// `stdvar`/`stddev` are seeded to NaN by a NaN or infinite FIRST sample.
		{`min(sp)`, aggSpecial},
		{`max(sp)`, aggSpecial},
		{`sum(sp)`, aggSpecial},
		{`avg(sp)`, aggSpecial},
		{`count(sp)`, aggSpecial},
		{`stddev(sp)`, aggSpecial},
		{`stdvar(sp)`, aggSpecial},
		{`quantile(0.5, sp)`, aggSpecial},
		{`min(inf)`, aggInf},
		{`max(inf)`, aggInf},
		{`stddev(inf)`, aggInf},
		{`stdvar(inf)`, aggInf},
		{`sum(inf)`, aggInf},
		{`avg(inf)`, aggInf},
		// A quantile outside [0, 1] and a NaN quantile, each with its own warning — and the
		// warnings are NOT exclusive.
		{`quantile(1.5, m)`, aggSeries},
		{`quantile(-0.5, m)`, aggSeries},
		{`quantile(NaN, m)`, aggSeries},
		{`quantile(scalar(m{inst="1", job="a"}), m)`, aggSeries},
		// An aggregation over a range function, and over another aggregation.
		{`sum(rate(m[5m]))`, aggSeries},
		{`sum by (job) (rate(m[5m]))`, aggSeries},
		{`max(sum by (job) (m))`, aggSeries},
		{`sum(sum by (job) (m))`, aggSeries},
		{`count(count by (job) (m))`, aggSeries},
		// An aggregation over a binop, and a binop over an aggregation.
		{`sum(m + m)`, aggSeries},
		{`sum by (job) (m) + on(job) sum by (job) (m)`, aggSeries},
		{`sum(m) + 1`, aggSeries},
		// An empty input: no groups, so no output and no error.
		{`sum(nothing)`, aggSeries},
		{`avg by (job) (nothing)`, aggSeries},
		{`quantile(0.5, nothing)`, aggSeries},
	}
	for _, c := range aggCases {
		emit(execIn{
			Query: c.query, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}
	// The sample limit against an aggregation, which is checked per STEP after the whole
	// aggregation — and `rangeEvalAgg` resets to `tempNumSamples` first, so the peak includes the
	// input matrix the inner expression left behind.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 7, 8, 10, 12} {
		for _, q := range []string{`sum(m)`, `sum by (job) (m)`, `count(m)`} {
			emit(execIn{
				Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
				MaxSamples: maxSamples, Series: aggSeries,
			})
		}
	}

	// --- topk / bottomk / limitk / limit_ratio / count_values. The four that return **k of the
	// input** — so their output labels are the INPUT's, not the grouping's — and the one that
	// returns a row per distinct value.
	//
	// The heap's internal order is observable: `limitk` and `limit_ratio` emit it unsorted, and
	// `topk`/`bottomk` sort it with a comparator that is not a strict weak ordering, so the heap
	// order is the sort's input. Ties and NaNs are therefore the interesting inputs, not just
	// distinct values.
	kSeries := []memSeriesInJSON{
		fs([]string{"__name__", "t", "job", "a", "i", "1"}, [2]int64{0, 5}),
		fs([]string{"__name__", "t", "job", "a", "i", "2"}, [2]int64{0, 3}),
		fs([]string{"__name__", "t", "job", "a", "i", "3"}, [2]int64{0, 9}),
		fs([]string{"__name__", "t", "job", "b", "i", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "t", "job", "b", "i", "2"}, [2]int64{0, 7}),
		fs([]string{"__name__", "t", "job", "b", "i", "3"}, [2]int64{0, 2}),
		fs([]string{"__name__", "t", "job", "c", "i", "1"}, [2]int64{0, 4}),
	}
	// TIES, which is where the heap order decides the answer — with distinct values any correct
	// heap gives the same top-k.
	kTies := []memSeriesInJSON{
		fs([]string{"__name__", "tt", "i", "1"}, [2]int64{0, 5}),
		fs([]string{"__name__", "tt", "i", "2"}, [2]int64{0, 5}),
		fs([]string{"__name__", "tt", "i", "3"}, [2]int64{0, 5}),
		fs([]string{"__name__", "tt", "i", "4"}, [2]int64{0, 5}),
		fs([]string{"__name__", "tt", "i", "5"}, [2]int64{0, 1}),
	}
	// NaNs, which both comparators sort FIRST — so `topk` needs its extra
	// `IsNaN(heap[0]) && !IsNaN(s)` clause or a NaN root is never displaced.
	kNaN := []memSeriesInJSON{
		{Labels: []string{"__name__", "tn", "i", "1"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{"7ff8000000000001"}},
		{Labels: []string{"__name__", "tn", "i", "2"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(3)}},
		{Labels: []string{"__name__", "tn", "i", "3"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{fbits(7)}},
		{Labels: []string{"__name__", "tn", "i", "4"}, T: []string{i64(0)}, ST: []string{i64(0)},
			F: []string{"7ff8000000000001"}},
	}
	// Distinct and repeated VALUES, for count_values.
	cvSeries := []memSeriesInJSON{
		fs([]string{"__name__", "cv", "job", "a", "i", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "cv", "job", "a", "i", "2"}, [2]int64{0, 1}),
		fs([]string{"__name__", "cv", "job", "a", "i", "3"}, [2]int64{0, 2}),
		fs([]string{"__name__", "cv", "job", "b", "i", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "cv", "job", "b", "i", "2"}, [2]int64{0, 3}),
	}

	kCases := []struct {
		query  string
		series []memSeriesInJSON
	}{
		// k below, at and above the input size — `k` is CLAMPED to the input size, so
		// `topk(100, t)` is every series and `topk(0, t)` is nothing.
		{`topk(0, t)`, kSeries},
		{`topk(1, t)`, kSeries},
		{`topk(2, t)`, kSeries},
		{`topk(3, t)`, kSeries},
		{`topk(7, t)`, kSeries},
		{`topk(100, t)`, kSeries},
		{`topk(-1, t)`, kSeries},
		{`bottomk(0, t)`, kSeries},
		{`bottomk(1, t)`, kSeries},
		{`bottomk(2, t)`, kSeries},
		{`bottomk(3, t)`, kSeries},
		{`bottomk(100, t)`, kSeries},
		{`limitk(1, t)`, kSeries},
		{`limitk(2, t)`, kSeries},
		{`limitk(3, t)`, kSeries},
		{`limitk(100, t)`, kSeries},
		{`limitk(0, t)`, kSeries},
		// Grouped, which is where `groupsRemaining` and the per-group heaps do work.
		{`topk by (job) (1, t)`, kSeries},
		{`topk by (job) (2, t)`, kSeries},
		{`bottomk by (job) (1, t)`, kSeries},
		{`bottomk by (job) (2, t)`, kSeries},
		{`limitk by (job) (1, t)`, kSeries},
		{`limitk by (job) (2, t)`, kSeries},
		{`topk without (i) (2, t)`, kSeries},
		{`topk by (i) (1, t)`, kSeries},
		// TIES: the heap order is the answer.
		{`topk(1, tt)`, kTies},
		{`topk(2, tt)`, kTies},
		{`topk(3, tt)`, kTies},
		{`topk(4, tt)`, kTies},
		{`bottomk(2, tt)`, kTies},
		{`bottomk(3, tt)`, kTies},
		{`bottomk(4, tt)`, kTies},
		{`limitk(2, tt)`, kTies},
		{`limitk(3, tt)`, kTies},
		// NaNs, which sort first under BOTH comparators.
		{`topk(1, tn)`, kNaN},
		{`topk(2, tn)`, kNaN},
		{`topk(3, tn)`, kNaN},
		{`topk(4, tn)`, kNaN},
		{`bottomk(1, tn)`, kNaN},
		{`bottomk(2, tn)`, kNaN},
		{`bottomk(3, tn)`, kNaN},
		{`limitk(2, tn)`, kNaN},
		// `limit_ratio`, whose membership is decided by `Labels.Hash` — deterministic, and the
		// negative form takes the COMPLEMENT.
		{`limit_ratio(0, t)`, kSeries},
		{`limit_ratio(1, t)`, kSeries},
		{`limit_ratio(-1, t)`, kSeries},
		{`limit_ratio(0.5, t)`, kSeries},
		{`limit_ratio(-0.5, t)`, kSeries},
		{`limit_ratio(0.2, t)`, kSeries},
		{`limit_ratio(2, t)`, kSeries},
		{`limit_ratio(-2, t)`, kSeries},
		{`limit_ratio by (job) (0.5, t)`, kSeries},
		// A NaN k and a NaN ratio, each with its own error.
		{`topk(NaN, t)`, kSeries},
		{`bottomk(NaN, t)`, kSeries},
		{`limitk(NaN, t)`, kSeries},
		{`limit_ratio(NaN, t)`, kSeries},
		// The Int64 guards, which use the largest Int64 exactly representable as a Double.
		{`topk(1e19, t)`, kSeries},
		{`topk(-1e19, t)`, kSeries},
		{`topk(9223372036854774784, t)`, kSeries},
		{`topk(9223372036854774783, t)`, kSeries},
		{`limitk(1e19, t)`, kSeries},
		// A k that is a SERIES rather than a literal — the min/max checks then span every step.
		{`topk(scalar(t{job="c"}), t)`, kSeries},
		{`limitk(scalar(t{job="c"}), t)`, kSeries},
		// An empty input.
		{`topk(3, nothing)`, kSeries},
		{`limit_ratio(0.5, nothing)`, kSeries},
		// count_values. A bare one is only deterministic where it yields ONE row, because Go
		// ranges a map; `sort_by_label` makes the multi-row cases comparable.
		{`count_values("v", cv{job="b", i="1"})`, cvSeries},
		{`sort_by_label(count_values("v", cv), "v")`, cvSeries},
		{`sort_by_label(count_values by (job) ("v", cv), "job", "v")`, cvSeries},
		{`sort_by_label(count_values without (i) ("v", cv), "job", "v")`, cvSeries},
		{`sort_by_label(count_values without (job, i) ("v", cv), "v")`, cvSeries},
		{`sort_by_label(count_values("v", t), "v")`, kSeries},
		// A value label that is not a valid label name, and one that collides with an existing
		// label. `a.b` is valid under UTF8 validation and NOT under legacy, which is what says
		// which scheme `count_values` uses.
		{`count_values("", cv)`, cvSeries},
		{`sort_by_label(count_values("a.b", cv), "a.b")`, cvSeries},
		{`sort_by_label(count_values("é", cv), "é")`, cvSeries},
		// `a b` is VALID under UTF8 validation — a space is fine — so this succeeds with three
		// rows, and a bare `count_values` exposes the Go map's order. It has to be sorted, and two
		// local reruns agreeing does not establish otherwise: with three entries Go's randomised
		// map order repeats by chance often enough to fool a pair of runs. CI caught it.
		{`sort_by_label(count_values("a b", cv), "a b")`, cvSeries},
		// A value whose `'f'` and `'g'` renderings DIFFER — `1e-9` is `0.000000001` under `'f'`
		// and `1e-09` under `'g'`. One output row, so the order is not in question.
		{`count_values("v", ix{i="5"})`, aggInexact},
		{`count_values("v", ix{i="3"})`, aggInexact},
		{`sort_by_label(count_values("job", cv), "job")`, cvSeries},
		{`sort_by_label(count_values("i", cv), "i")`, cvSeries},
		// The float formatting of the value label is `'f'` with shortest precision, so a large
		// value is a long integer string rather than an exponent.
		{`sort_by_label(count_values("v", sp), "v")`, aggSpecial},
		{`sort_by_label(count_values("v", inf), "v")`, aggInf},
		// NOT `count_values` over `aggInexact`: `natsort.Compare` treats `0.1` and `0.000000001`
		// as EQUAL (it compares the digit chunks numerically, and `1` == `000000001`), so
		// `sort_by_label` leaves them in whatever order `count_values`' Go **map** produced.
		// Sorting does not rescue a nondeterministic order when the sort key is ambiguous — the
		// case was in the corpus and differed between regenerations. Exception 7's trap in a
		// second disguise.
		// An aggregation over the k operators, and vice versa.
		{`sum(topk(2, t))`, kSeries},
		{`topk(2, sum by (job) (t))`, kSeries},
		{`count(limitk(3, t))`, kSeries},
	}
	for _, c := range kCases {
		emit(execIn{
			Query: c.query, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}
	for _, maxSamples := range []int{1, 2, 3, 4, 6, 8, 10} {
		for _, q := range []string{`topk(3, t)`, `limitk(2, t)`, `count_values("v", cv)`} {
			emit(execIn{
				Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
				MaxSamples: maxSamples, Series: kSeries,
			})
		}
	}

	// --- SUBQUERIES. `foo[5m:1m]` is `foo` sampled on the subquery's OWN step grid and handed
	// back as a range vector, so the alignment arithmetic is the whole subject.
	//
	// The grid is snapped UP — `subqInterval * (target / subqInterval)` then `+= subqInterval`
	// when it landed at or below the target — which makes the window half-open at the bottom,
	// matching a range selector. The parent's end is snapped DOWN to the parent's own step grid
	// first, so a subquery cannot run past the last step that could read it.
	sqSeries := []memSeriesInJSON{
		fs([]string{"__name__", "sq", "job", "a"},
			[2]int64{0, 1}, [2]int64{30_000, 2}, [2]int64{60_000, 4}, [2]int64{90_000, 8},
			[2]int64{120_000, 16}, [2]int64{150_000, 32}, [2]int64{180_000, 64}),
		fs([]string{"__name__", "sq", "job", "b"},
			[2]int64{0, 100}, [2]int64{60_000, 200}, [2]int64{120_000, 300}),
	}
	// Samples OFF the grid, so the snap-up boundary is not sitting on a real sample.
	sqOff := []memSeriesInJSON{
		fs([]string{"__name__", "sqo"},
			[2]int64{7_000, 1}, [2]int64{43_000, 3}, [2]int64{79_000, 7}, [2]int64{131_000, 15}),
	}

	sqCases := []struct {
		query  string
		series []memSeriesInJSON
		ts     int64
	}{
		// A bare subquery, at several resolutions. The step decides how many points come back and
		// the snap-up decides where the first one is.
		{`sq[2m:1m]`, sqSeries, 180_000},
		{`sq[2m:30s]`, sqSeries, 180_000},
		{`sq[2m:10s]`, sqSeries, 180_000},
		{`sq[1m:1m]`, sqSeries, 180_000},
		{`sq[3m:1m]`, sqSeries, 180_000},
		{`sq[2m:1m]`, sqSeries, 120_000},
		{`sq[2m:1m]`, sqSeries, 90_000},
		// A step the range does not divide, so the snap-up lands mid-window.
		{`sq[2m:45s]`, sqSeries, 180_000},
		{`sq[100s:35s]`, sqSeries, 180_000},
		// No step at all: `noStepSubqueryIntervalFn` supplies one — a minute, here.
		{`sq[5m:]`, sqSeries, 180_000},
		{`sq[2m:]`, sqSeries, 180_000},
		// Off-grid samples, where the boundary is not a real sample.
		{`sqo[2m:1m]`, sqOff, 131_000},
		{`sqo[2m:30s]`, sqOff, 131_000},
		{`sqo[2m:1m]`, sqOff, 120_000},
		// `offset` on the subquery, which shifts both ends of its grid.
		{`sq[2m:1m] offset 1m`, sqSeries, 180_000},
		{`sq[2m:1m] offset -1m`, sqSeries, 120_000},
		// `@` on the subquery, which pins the grid — and the synthetic selector's `Offset` has to
		// be recomputed for it, or the outer read lands on the wrong window.
		{`sq[2m:1m] @ 120`, sqSeries, 1_000_000},
		{`sq[2m:1m] @ 60`, sqSeries, 0},
		{`rate(sq[2m:1m] @ 120)`, sqSeries, 1_000_000},
		// `@` on the INNER selector, which `setOffsetForAtModifier` has to re-rewrite against the
		// subquery's own start.
		{`sq @ 60 [2m:1m]`, sqSeries, 180_000},
		{`rate(sq @ 60 [2m:1m])`, sqSeries, 180_000},
		// A function over a subquery, which is the `Call` arm's AST replacement — and the
		// rewritten statement renders as a NAMELESS range selector.
		{`rate(sq[2m:1m])`, sqSeries, 180_000},
		{`increase(sq[2m:1m])`, sqSeries, 180_000},
		{`max_over_time(sq[2m:1m])`, sqSeries, 180_000},
		{`min_over_time(sq[2m:1m])`, sqSeries, 180_000},
		{`avg_over_time(sq[2m:1m])`, sqSeries, 180_000},
		{`count_over_time(sq[2m:1m])`, sqSeries, 180_000},
		// `sort_by_label`, not a bare `sum_over_time`: `sq` has two series, and an UNSORTED
		// `Select` has no contractual order (PORTING.md exception 11) — the head returns append
		// order, which is not a promise. A bare version of this case was stable for many
		// regenerations and then flipped. Every multi-series case in these suites is exposed to
		// that; see HANDOFF §4.
		{`sort_by_label(sum_over_time(sq[2m:1m]), "job")`, sqSeries, 180_000},
		{`last_over_time(sq[2m:1m])`, sqSeries, 180_000},
		{`quantile_over_time(0.5, sq[2m:1m])`, sqSeries, 180_000},
		{`absent_over_time(sq[2m:1m])`, sqSeries, 180_000},
		{`absent_over_time(nothing[2m:1m])`, sqSeries, 180_000},
		{`resets(sq[2m:1m])`, sqSeries, 180_000},
		{`changes(sq[2m:1m])`, sqSeries, 180_000},
		{`deriv(sq[2m:1m])`, sqSeries, 180_000},
		{`predict_linear(sq[2m:1m], 60)`, sqSeries, 180_000},
		// A subquery over an AGGREGATION and over a binop, which is the shape that needs the
		// inner expression to be more than a selector.
		{`sum_over_time(sum(sq)[2m:1m])`, sqSeries, 180_000},
		{`max_over_time(sum by (job) (sq)[2m:1m])`, sqSeries, 180_000},
		{`sum(sq)[2m:1m]`, sqSeries, 180_000},
		// `sort_by_label`-wrapped: the subquery's inner expression is a BINOP, so it goes through
		// `rangeEval`'s multi-step assembly, which ranges a Go map — the third instance of the risk
		// HANDOFF §4 records, and it flapped in CI after passing locally. A subquery over a plain
		// selector is safe (`evalSeries` is ordered); one over a binop or an aggregation is not.
		{`sort_by_label(sum_over_time((sq + sq)[2m:1m]), "job")`, sqSeries, 180_000},
		{`max_over_time(rate(sq[1m])[2m:1m])`, sqSeries, 180_000},
		{`avg_over_time(topk(1, sq)[2m:1m])`, sqSeries, 180_000},
		// A NESTED subquery, where the inner one's grid is derived from the outer one's.
		{`max_over_time(max_over_time(sq[1m:30s])[2m:1m])`, sqSeries, 180_000},
		{`sum_over_time(sum_over_time(sq[1m:30s])[2m:1m])`, sqSeries, 180_000},
		// An aggregation over a subquery, and a binop.
		{`sum(rate(sq[2m:1m]))`, sqSeries, 180_000},
		{`rate(sq[2m:1m]) + rate(sq[2m:1m])`, sqSeries, 180_000},
		{`topk(1, rate(sq[2m:1m]))`, sqSeries, 180_000},
	}
	for _, c := range sqCases {
		emit(execIn{
			Query: c.query, Ts: i64(c.ts), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}
	// The sample limit against a subquery, where the child's samples are counted and then
	// RELEASED when the outer call returns — so the peak is the child plus the outer result.
	for _, maxSamples := range []int{1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20} {
		for _, q := range []string{`sq[2m:1m]`, `rate(sq[2m:1m])`, `sum(rate(sq[2m:1m]))`} {
			emit(execIn{
				Query: q, Ts: i64(180_000), Lookback: i64(int64(5 * time.Minute)),
				MaxSamples: maxSamples, Series: sqSeries,
			})
		}
	}

	// --- label_join. Works on SERIES, so the evaluator reaches it directly rather than through
	// `FunctionCalls` — its table entry is nil (quirk 62).
	//
	// It is also the first caller that can reach `mergeSeriesWithSameLabelset`: joining a
	// *differing* label away is exactly the collision quirk 78 said needed `label_replace` or an
	// aggregation, and here it is.
	// TWO samples each, so `rate` produces output — with one sample it produces none, and the
	// `__name__`-resets-DropName case was silently degenerate.
	ljSeries := []memSeriesInJSON{
		fs([]string{"__name__", "lj", "a", "1", "b", "x"}, [2]int64{0, 10}, [2]int64{60_000, 20}),
		fs([]string{"__name__", "lj", "a", "2", "b", "y"}, [2]int64{0, 20}, [2]int64{60_000, 40}),
		fs([]string{"__name__", "lj", "a", "3"}, [2]int64{0, 30}, [2]int64{60_000, 60}),
	}
	// Two series differing in ONE label, so joining that label away makes them identical — which
	// is `mergeSeriesWithSameLabelset`'s first reachable caller, and at equal timestamps its
	// duplicate-point error.
	ljCollide := []memSeriesInJSON{
		fs([]string{"__name__", "lj2", "a", "1"}, [2]int64{0, 1}),
		fs([]string{"__name__", "lj2", "a", "2"}, [2]int64{0, 2}),
	}
	ljCollideCases := []string{
		// Joining the only distinguishing label away: both series become `{__name__="lj2"}`, and
		// two points at the SAME timestamp is the merge's duplicate error rather than a sum.
		`label_join(lj2, "a", "-", "nosuch")`,
		`label_join(lj2, "a", "-")`,
		// ...and the same shape where the join keeps them distinct, for the pair.
		`label_join(lj2, "d", "-", "a")`,
		`label_join(lj2, "a", "-", "a")`,
	}
	for _, q := range ljCollideCases {
		emit(execIn{
			Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)), Series: ljCollide,
		})
	}

	ljCases := []string{
		// A single source, several sources, and a separator.
		`label_join(lj, "d", "-", "a")`,
		`label_join(lj, "d", "-", "a", "b")`,
		`label_join(lj, "d", "", "a", "b")`,
		`label_join(lj, "d", "::", "a", "b")`,
		// A source the series does not have joins as the EMPTY string, so the separator survives.
		`label_join(lj, "d", "-", "a", "nosuch")`,
		`label_join(lj, "d", "-", "nosuch", "a")`,
		`label_join(lj, "d", "-", "nosuch")`,
		// NO sources at all: the destination is set to the empty string, which DELETES it.
		`label_join(lj, "d", "-")`,
		`label_join(lj, "a", "-")`,
		// Overwriting an existing label, including one of the sources.
		`label_join(lj, "a", "-", "a", "b")`,
		`label_join(lj, "b", "-", "a")`,
		// Writing `__name__`, which resets DropName — visible through a rate, whose name is
		// otherwise dropped.
		`label_join(lj, "__name__", "-", "a")`,
		`label_join(rate(lj[5m]), "__name__", "", "a")`,
		`label_join(rate(lj[5m]), "d", "", "a")`,
		// A UTF8-only destination and source name.
		`label_join(lj, "a.b", "-", "a")`,
		`label_join(lj, "d", "-", "a.b")`,
		// Invalid names, each with its own message.
		`label_join(lj, "", "-", "a")`,
		// COLLISION: joining `a` away makes two series identical, which is
		// `mergeSeriesWithSameLabelset`'s first reachable caller.
		`label_join(lj, "a", "-", "nosuch")`,
		`sort_by_label(label_join(lj, "a", "-", "nosuch"), "b")`,
		`label_join(rate(lj[5m]), "d", "-", "a")`,
		`label_join(rate(lj[5m]), "__name__", "-", "b")`,
		// Nested, and over an aggregation.
		`label_join(label_join(lj, "d", "-", "a"), "e", "-", "d", "b")`,
		`label_join(sum by (a) (lj), "d", "-", "a")`,
		`sum by (d) (label_join(lj, "d", "-", "b"))`,
	}
	for _, q := range ljCases {
		emit(execIn{
			Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)), Series: ljSeries,
		})
	}

	// --- `smoothed` on a BARE selector, and the binop FILL modifiers.
	//
	// `foo smoothed` is a different function from `foo[5m] smoothed`: it interpolates the
	// selector's own samples onto the step grid, using a window that reaches FORWARD by a lookback
	// delta — which is what no other selector window does.
	//
	// Off-grid samples are essential: on the grid every step is an exact hit and the interpolation,
	// the carry-forward and the skip are all invisible.
	smSeries := []memSeriesInJSON{
		fs([]string{"__name__", "sm"},
			[2]int64{17_000, 1}, [2]int64{53_000, 5}, [2]int64{101_000, 13}),
	}
	// A gap wider than the lookback, so some steps have no window at all.
	smGap := []memSeriesInJSON{
		fs([]string{"__name__", "smg"}, [2]int64{0, 1}, [2]int64{900_000, 10}),
	}
	smCases := []struct {
		query  string
		series []memSeriesInJSON
		ts     int64
	}{
		// An exact hit, an interpolation, a carry-forward past the end, and a skip before the
		// start — the four cases of the binary search, chosen by where `ts` falls.
		{`sm smoothed`, smSeries, 17_000},
		{`sm smoothed`, smSeries, 35_000},
		{`sm smoothed`, smSeries, 53_000},
		{`sm smoothed`, smSeries, 77_000},
		{`sm smoothed`, smSeries, 101_000},
		{`sm smoothed`, smSeries, 120_000},
		{`sm smoothed`, smSeries, 300_000},
		{`sm smoothed`, smSeries, 400_001},
		{`sm smoothed`, smSeries, 0},
		{`sm smoothed`, smSeries, 16_999},
		// `offset`, which shifts the data timestamp and therefore which pair is interpolated.
		{`sm smoothed offset 1m`, smSeries, 95_000},
		// An EXACT hit with a non-zero offset, which is the only shape where the re-stamping is
		// visible: with no offset `evalTS == dataTS == sample.T`, so keeping the sample's own
		// timestamp gives the same answer.
		{`sm smoothed offset 1m`, smSeries, 113_000},
		{`sm smoothed offset 1m`, smSeries, 77_000},
		{`sm smoothed offset -1m`, smSeries, 41_000},
		{`sum(sm smoothed offset 1m)`, smSeries, 113_000},
		{`sm smoothed offset -1m`, smSeries, 0},
		// A gap wider than the lookback: nothing at all.
		{`smg smoothed`, smGap, 450_000},
		{`smg smoothed`, smGap, 100_000},
		// Through a function and an aggregation, so the interpolated matrix is consumed.
		{`sm smoothed + 1`, smSeries, 35_000},
		{`sum(sm smoothed)`, smSeries, 35_000},
		{`abs(sm smoothed)`, smSeries, 35_000},

		// --- The FILL modifiers. A match group only one side has still produces output, and the
		// synthesised sample's metric is the JOIN LABELS ONLY.
		{`left + fill_right (0) right`, binL, 0},
		{`left + fill_right (100) right`, binL, 0},
		{`left + fill_left (0) right`, binL, 0},
		{`left + fill (0) right`, binL, 0},
		{`left + on(job) fill_right (0) right`, binL, 0},
		{`left + on(job) fill (7) right`, binL, 0},
		{`left / fill (1) right`, binL, 0},
		{`left - fill (0) right`, binL, 0},
		// One side EMPTY, where the short-circuit would otherwise return nothing.
		{`left + fill_right (0) nothing`, binL, 0},
		{`nothing + fill_left (0) right`, binL, 0},
		{`left + fill (0) nothing`, binL, 0},
		{`nothing + fill (0) nothing`, binL, 0},
		// A comparison with a fill, where `keep` decides whether the filled pair survives.
		{`left > fill_right (0) right`, binL, 0},
		{`left > bool fill_right (0) right`, binL, 0},
		{`cl > fill (50) cr`, binCmp, 0},
	}
	for _, c := range smCases {
		emit(execIn{
			Query: c.query, Ts: i64(c.ts), Lookback: i64(int64(5 * time.Minute)),
			Series: c.series,
		})
	}

	// --- The DELAYED-name-removal axis, which is what `promqltest` runs with and therefore what
	// the exit gate exercises. Every case above ran with it OFF (the server's default), where each
	// body strips the three schema metadata labels itself. With it ON the labels survive until
	// `cleanupMetricLabels` at the top of `Eval`.
	//
	// The shapes that separate the two are the ones where an INTERMEDIATE result's name matters:
	// a nested expression can still match on it, and only the final answer loses it. Plus the two
	// arms of `cleanupMetricLabels`, which are asymmetric — a Matrix result MERGES colliding series
	// and a Vector result is REJECTED.
	delayedQueries := []struct {
		query  string
		series []memSeriesInJSON
	}{
		// A single name-dropping function, where the two settings agree on the answer.
		{`abs(-left)`, binL},
		{`rate(lj[5m])`, ljSeries},
		{`ceil(left)`, binL},
		// NESTED name-dropping, where the inner result's name is visible to the outer expression
		// only with the flag on.
		{`abs(abs(-left))`, binL},
		{`sum by (__name__) (abs(-left))`, binL},
		{`count by (__name__) (rate(lj[5m]))`, ljSeries},
		{`abs(-left) + on(__name__) abs(-left)`, binL},
		{`sum(abs(-left))`, binL},
		{`topk(1, abs(-left))`, binL},
		// A binop, which drops the name for arithmetic and keeps it for a comparison.
		{`left + right`, binL},
		{`left > right`, binL},
		{`left > bool right`, binL},
		{`left + 1`, binL},
		{`left > bool 1`, binL},
		// A COLLISION that `cleanupMetricLabels` has to resolve: two series differing only in
		// `__name__`, name-dropped. A vector result is rejected; a matrix result merges.
		{`abs({__name__=~"n1|n2"})`, aggNames},
		{`rate({__name__=~"n1|n2"}[5m])`, aggNames},
		{`-{__name__=~"n1|n2"}`, aggNames},
		{`sort({__name__=~"n1|n2"} + 0)`, aggNames},
		// `label_join` writing `__name__`, which RESETS DropName — so the deferred drop must not
		// happen.
		{`label_join(rate(lj[5m]), "__name__", "-", "a")`, ljSeries},
		{`label_join(rate(lj[5m]), "d", "-", "a")`, ljSeries},
		// The three metadata labels, not just `__name__`.
		{`abs(-meta)`, metaSeries},
		{`rate(meta[5m])`, metaSeries},
		{`sum by (__type__) (abs(-meta))`, metaSeries},
	}
	// A series carrying all three schema metadata labels, so "drops the name" versus "drops the
	// metadata" is separable.
	for _, delayed := range []bool{false, true} {
		for _, c := range delayedQueries {
			emit(execIn{
				Query: c.query, Ts: i64(0), Lookback: i64(int64(5 * time.Minute)),
				Series: c.series, Delayed: delayed,
			})
		}
	}

	// A query that fails to build still comes back through Exec's Result, not as a panic.
	for _, q := range []string{`1 +`, `foo[`, `sum(`} {
		emit(execIn{Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute))})
	}
}
