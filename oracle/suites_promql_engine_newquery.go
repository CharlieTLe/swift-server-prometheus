package main

// Differential coverage for promql/engine.go's front door: `NewInstantQuery` and
// `NewRangeQuery` up to — but not including — `Exec`. So parse, `validateOpts`, the
// range-query type check, and `PreprocessExpr`, plus `newQuery`'s lookback-delta
// defaulting.
//
// Everything here is exported and none of it touches the storage, so the Queryable can be
// one that is never asked for anything. That is what makes this slice portable before the
// evaluator exists — and it is worth pinning on its own, because every error a query can
// produce BEFORE evaluation is decided here.
//
// ## The observable
//
// Either an error string, or the `EvalStmt` the engine built: the preprocessed
// expression's `String()`, and the four statement fields. `PreprocessExpr` rewrites the
// AST — folding `start()`/`end()` into literals, wrapping step-invariant subtrees — so the
// rendered expression is a real check on the whole pipeline and not just on the parser.
//
// ## What has to be reached
//
//   - both entry points for the same query, since only the range form type-checks;
//   - `@`, `@ start()`, `@ end()` and negative offsets, with the two engine flags in all
//     four combinations. The early return needs BOTH flags, so three of the four run the
//     walk;
//   - a query using an `@` AND a negative offset, where the reported error depends on
//     traversal order rather than on which feature is disabled;
//   - the `@` on a subquery and on a matrix selector, which are separate cases in the
//     visitor — and the matrix selector's inner VectorSelector is visited twice;
//   - a parse error together with a disabled feature, which pins the ORDER: parse first;
//   - every expression type for the range form: scalar and instant vector pass, string and
//     range vector are rejected with a message naming the DocumentedType;
//   - the lookback delta: a positive per-query one wins, a zero or NEGATIVE one falls back
//     to the engine's, and nil opts behave as zero;
//   - a range query whose interval is zero, which is legal here even though it would
//     divide by zero later.

import (
	"context"
	"fmt"
	"time"

	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/storage"
)

type engineIn struct {
	Query string `json:"query"`
	// "instant" or "range".
	Kind string `json:"kind"`
	// Milliseconds, decimal strings.
	Start string `json:"start"`
	End   string `json:"end"`
	// Nanoseconds, decimal strings.
	Interval string `json:"interval"`
	// Engine options that change behaviour here.
	EngineLookback        string `json:"engineLookback"`
	EnableAtModifier      bool   `json:"enableAt"`
	EnableNegativeOffset  bool   `json:"enableNegOffset"`
	EnableExperimentalFns bool   `json:"enableExperimental"`
	EnableExtendedRange   bool   `json:"enableExtendedRange"`
	// The parser flags are the ENGINE's, so `foo[1m+30s]` fails to PARSE when this is
	// off — a different error, and a different code path, from the two validation ones.
	EnableDurationExpr bool `json:"enableDurationExpr"`
	// Per-query options. `queryLookback` is nanoseconds; `nilOpts` passes nil instead of
	// a PrometheusQueryOpts at all.
	QueryLookback string `json:"queryLookback"`
	NilOpts       bool   `json:"nilOpts"`
}

type engineOut struct {
	// Go's error text, or "" when the query was built.
	Err string `json:"err"`
	// The preprocessed expression's String(), and the statement fields.
	Expr     string `json:"expr"`
	Start    string `json:"start"`
	End      string `json:"end"`
	Interval string `json:"interval"`
	Lookback string `json:"lookback"`
}

// engineNopQueryable is a Queryable that is never queried: this slice stops before Exec.
type engineNopQueryable struct{}

func (engineNopQueryable) Querier(int64, int64) (storage.Querier, error) {
	return nil, nil
}

func runEngineCase(in engineIn) engineOut {
	eng := promql.NewEngine(promql.EngineOpts{
		MaxSamples:               50_000_000,
		Timeout:                  time.Minute,
		LookbackDelta:            time.Duration(parseI64(in.EngineLookback)),
		EnableAtModifier:         in.EnableAtModifier,
		EnableNegativeOffset:     in.EnableNegativeOffset,
		NoStepSubqueryIntervalFn: func(int64) int64 { return int64(time.Minute / time.Millisecond) },
		Parser: parser.NewParser(parser.Options{
			EnableExperimentalFunctions:  in.EnableExperimentalFns,
			EnableExtendedRangeSelectors: in.EnableExtendedRange,
			ExperimentalDurationExpr:     in.EnableDurationExpr,
		}),
	})

	var opts promql.QueryOpts
	if !in.NilOpts {
		opts = promql.NewPrometheusQueryOpts(false, time.Duration(parseI64(in.QueryLookback)))
	}

	start := time.UnixMilli(parseI64(in.Start)).UTC()
	end := time.UnixMilli(parseI64(in.End)).UTC()

	var (
		q   promql.Query
		err error
	)
	switch in.Kind {
	case "instant":
		q, err = eng.NewInstantQuery(
			context.Background(), engineNopQueryable{}, opts, in.Query, start)
	case "range":
		q, err = eng.NewRangeQuery(
			context.Background(), engineNopQueryable{}, opts, in.Query, start, end,
			time.Duration(parseI64(in.Interval)))
	default:
		panic("unknown kind " + in.Kind)
	}
	if err != nil {
		return engineOut{Err: err.Error()}
	}
	es := q.Statement().(*parser.EvalStmt)
	return engineOut{
		Expr:     es.Expr.String(),
		Start:    i64(es.Start.UnixMilli()),
		End:      i64(es.End.UnixMilli()),
		Interval: i64(int64(es.Interval)),
		Lookback: i64(int64(es.LookbackDelta)),
	}
}

func genPromQLEngineNewQuery(e *emitter) {
	n := 0
	emit := func(in engineIn) {
		e.emit(fmt.Sprintf("%s/%d", in.Kind, n), in, runEngineCase(in))
		n++
	}

	queries := []string{
		// Types: scalar and instant vector pass the range check, string and range vector
		// do not.
		`1`,
		`1 + 2`,
		`foo`,
		`"a string"`,
		`foo[5m]`,
		`max_over_time(foo[5m])`,
		`max_over_time(foo[5m])[1h:1m]`,
		// The `@` modifier in every position the visitor handles separately.
		`foo @ 100`,
		`foo @ start()`,
		`foo @ end()`,
		`rate(foo[5m] @ 100)`,
		`rate(foo[5m] @ start())`,
		`max_over_time(foo[5m:1m] @ 100)`,
		`max_over_time(foo[5m:1m] @ start())`,
		// Negative offsets, likewise.
		`foo offset -5m`,
		`rate(foo[5m] offset -5m)`,
		`max_over_time(foo[5m:1m] offset -5m)`,
		// BOTH, in both orders. The error depends on traversal order, not on which flag is
		// off — so these two disagree with each other whenever exactly one flag is
		// disabled.
		`foo @ 100 + bar offset -5m`,
		`foo offset -5m + bar @ 100`,
		// Both on the SAME selector.
		`foo @ 100 offset -5m`,
		// A parse error together with a disabled feature: the parse error wins, because
		// NewInstantQuery parses before it validates.
		`foo @ 100 +`,
		`) @ 100`,
		// `start()`/`end()` fold into literals during preprocessing, which the rendered
		// expression shows.
		`time() @ 100`,
		`vector(time())`,
		// Step-invariant subtrees get wrapped, and the wrapper prints.
		`foo @ 100 + bar`,
		`rate(foo[5m] @ 100)`,
		// A subquery with no step, which NoStepSubqueryIntervalFn fills in.
		`max_over_time(foo[5m:])`,
		// Duration arithmetic, which preprocessing evaluates.
		`foo[1m+30s]`,
		`max_over_time(foo[2m-1m])`,
		// `step()` in duration position, which PREPROCESSING folds using the query's step —
		// so this is the only shape where passing the wrong step to PreprocessExpr shows.
		// An instant query's step is zero, which is itself an error for a range.
		`max_over_time(foo[step()])`,
		`max_over_time(foo[step()*4])`,
		// A query that fails BOTH preprocessing and validation: the range folds to zero,
		// which PreprocessExpr rejects, and the `@` is a validation error. Which message
		// comes back pins the ORDER of the two, and nothing else in the corpus does.
		`rate(foo[1m-1m] @ 100)`,
		`rate(foo[1m-1m] offset -5m)`,
	}

	type flags struct{ at, neg bool }
	flagCombos := []flags{{false, false}, {true, false}, {false, true}, {true, true}}

	for _, q := range queries {
		for _, f := range flagCombos {
			for _, kind := range []string{"instant", "range"} {
				emit(engineIn{
					Query: q, Kind: kind,
					Start:                 i64(1_600_000_000_000),
					End:                   i64(1_600_000_060_000),
					Interval:              i64(int64(15 * time.Second)),
					EngineLookback:        i64(int64(5 * time.Minute)),
					EnableAtModifier:      f.at,
					EnableNegativeOffset:  f.neg,
					EnableExperimentalFns: true,
					EnableExtendedRange:   true,
					EnableDurationExpr:    true,
					QueryLookback:         i64(0),
				})
			}
		}
	}

	// The lookback-delta defaulting, which is `<= 0` and not `== 0`.
	for _, ql := range []int64{
		0, int64(time.Minute), int64(time.Millisecond), 1,
		// Negative: asks for the engine's default, NOT for a negative window.
		-1, int64(-time.Minute),
	} {
		for _, nilOpts := range []bool{false, true} {
			// The engine's own lookback delta, including a NEGATIVE one. NewEngine
			// defaults a lookback of exactly ZERO to five minutes, testing `== 0` where
			// newQuery tests `<= 0` — so a negative engine lookback SURVIVES while a
			// negative per-query one is discarded. That asymmetry is only visible with
			// both signs in the corpus.
			for _, el := range []int64{int64(5 * time.Minute), 0, -1, int64(-time.Minute)} {
				emit(engineIn{
					Query: `foo`, Kind: "instant",
					Start:                 i64(1_600_000_000_000),
					End:                   i64(1_600_000_000_000),
					Interval:              i64(0),
					EngineLookback:        i64(el),
					EnableAtModifier:      true,
					EnableNegativeOffset:  true,
					EnableExperimentalFns: true,
					EnableExtendedRange:   true,
					EnableDurationExpr:    true,
					QueryLookback:         i64(ql),
					NilOpts:               nilOpts,
				})
			}
		}
	}

	// A range query with a zero interval, and one whose start is after its end: both are
	// accepted here and only bite later.
	for _, iv := range []int64{0, int64(time.Hour)} {
		emit(engineIn{
			Query: `foo`, Kind: "range",
			Start:                 i64(1_600_000_060_000),
			End:                   i64(1_600_000_000_000),
			Interval:              i64(iv),
			EngineLookback:        i64(int64(5 * time.Minute)),
			EnableAtModifier:      true,
			EnableNegativeOffset:  true,
			EnableExperimentalFns: true,
			EnableExtendedRange:   true,
			EnableDurationExpr:    true,
			QueryLookback:         i64(0),
		})
	}

	// The parser options are the ENGINE's, so a query needing experimental functions fails
	// to parse when they are off — a different error from the validation ones.
	for _, q := range []string{`limitk(1, foo)`, `rate(foo[5m] anchored)`, `foo[1m+30s]`} {
		for _, on := range []bool{false, true} {
			emit(engineIn{
				Query: q, Kind: "instant",
				Start:                 i64(1_600_000_000_000),
				End:                   i64(1_600_000_000_000),
				Interval:              i64(0),
				EngineLookback:        i64(int64(5 * time.Minute)),
				EnableAtModifier:      true,
				EnableNegativeOffset:  true,
				EnableExperimentalFns: on,
				EnableExtendedRange:   on,
				EnableDurationExpr:    on,
				QueryLookback:         i64(0),
			})
		}
	}
}
