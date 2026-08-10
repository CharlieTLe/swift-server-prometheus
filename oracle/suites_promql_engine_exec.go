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
		NoStepSubqueryIntervalFn: func(int64) int64 { return int64(time.Minute / time.Millisecond) },
		Parser: parser.NewParser(parser.Options{
			EnableExperimentalFunctions: true,
			// `anchored` and `smoothed` on a range selector, which `matrixSelector`'s
			// `extendFloats` path needs. Parser-only: the engine has no matching flag.
			EnableExtendedRangeSelectors: true,
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

	// A query that fails to build still comes back through Exec's Result, not as a panic.
	for _, q := range []string{`1 +`, `foo[`, `sum(`} {
		emit(execIn{Query: q, Ts: i64(0), Lookback: i64(int64(5 * time.Minute))})
	}
}
