package main

// Differential coverage for promql/durations.go and PreprocessExpr.
//
// `PreprocessExpr` is engine.go's query-preparation pass: it resolves everything
// fixed for a given (start, end, step) before evaluation begins. Four rewrites, in
// this order, and the order is observable:
//
//	detectHistogramStatsDecoding  -> VectorSelector.SkipHistogramBuckets
//	foldQueryContextFunctions     -> start()/end()/range()/step() become literals
//	durationVisitor (durations.go)-> OriginalOffset / Range / Step get concrete values
//	preprocessExprHelper          -> StepInvariantExpr wrapping, @ start()/end()
//
// Why this suite exists at all: `durationVisitor` is unexported, so it cannot be
// driven from here directly — but `PreprocessExpr` is exported and is its only
// caller (engine.go:4491). Going through it therefore pins the visitor *and* the
// whole step-invariance optimiser in one corpus, which is the tighter test anyway
// since the four passes interact.
//
// The serialiser below is deliberately NOT translateAST. Two reasons:
//
//  1. translateAST panics on `*parser.StepInvariantExpr` — the HTTP API never sees
//     one, because it serialises the tree as parsed — and it omits
//     SkipHistogramBuckets for the same reason.
//  2. Its header says it is kept structurally identical to upstream's
//     translate_ast.go so a diff against a future pin stays readable. Adding
//     fields would break that, and would churn all 6,154 promql/parse cases for
//     an unrelated reason.
//
// So this emits a targeted shape: the tree structure, plus exactly the fields the
// four passes write. High signal — a diff points at a preprocessing bug rather
// than at an unrelated field.

import (
	"fmt"
	"os"
	"time"

	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
)

// ---------------------------------------------------------- the (start,end,step) triples

// Chosen to reach every branch of the four passes rather than to look realistic.
var preprocessTimeRanges = []struct {
	name  string
	start time.Time
	end   time.Time
	step  time.Duration
}{
	// An instant query: start == end, so `step()` folds to 0 through its
	// `!start.Equal(end)` branch rather than by reading step.
	{"instant", time.Unix(1600000000, 0), time.Unix(1600000000, 0), 0},
	// The same, but with a non-zero step — which must STILL fold to 0. If the
	// port reads `step` unconditionally this is the case that catches it.
	{"instant-nonzero-step", time.Unix(1600000000, 0), time.Unix(1600000000, 0), time.Minute},
	// An ordinary range query.
	{"range", time.Unix(1600000000, 0), time.Unix(1600003600, 0), time.Minute},
	// A range whose length and step are not whole seconds, so range() and step()
	// fold to values that expose Duration.Seconds()'s whole/fractional split.
	{"range-subsecond", time.Unix(1600000000, 123456789), time.Unix(1600007200, 987654321),
		1500 * time.Millisecond},
	// The Unix epoch, where FromTime is 0 and start()/end() fold to 0.
	{"epoch", time.Unix(0, 0), time.Unix(0, 0), 0},
	// Pre-epoch, so FromTime is negative and the folded literals are too.
	{"pre-epoch", time.Unix(-2000000000, 0), time.Unix(-1000000000, 0), time.Hour},
	// A very long range, so range() is large enough that a duration expression
	// built from it can overflow the out-of-range bound.
	{"huge-range", time.Unix(0, 0), time.Unix(200000000000, 0), 24 * time.Hour},
}

// ---------------------------------------------------------- the serialiser

func translatePreprocessed(node parser.Expr) any {
	if node == nil {
		return nil
	}

	switch n := node.(type) {
	case *parser.StepInvariantExpr:
		// The node the whole optimiser exists to produce. translateAST panics
		// here; where the wrapping lands is the primary thing this suite pins.
		return map[string]any{
			"type": "stepInvariant",
			"expr": translatePreprocessed(n.Expr),
		}

	case *parser.VectorSelector:
		return map[string]any{
			"type":       "vectorSelector",
			"name":       n.Name,
			"offsetMS":   n.OriginalOffset.Milliseconds(),
			"timestamp":  n.Timestamp,
			"startOrEnd": getStartOrEnd(n.StartOrEnd),
			// Written by detectHistogramStatsDecoding. Absent from translateAST.
			"skipHistogramBuckets": n.SkipHistogramBuckets,
			// The duration *expression* must survive folding, not be cleared —
			// durationVisitor writes OriginalOffset and leaves this in place. A
			// port that cleared it would still get offsetMS right, so the bool is
			// what catches that.
			"hasOffsetExpr": n.OriginalOffsetExpr != nil,
		}

	case *parser.MatrixSelector:
		vs := n.VectorSelector.(*parser.VectorSelector)
		return map[string]any{
			"type":                 "matrixSelector",
			"rangeMS":              n.Range.Milliseconds(),
			"hasRangeExpr":         n.RangeExpr != nil,
			"name":                 vs.Name,
			"offsetMS":             vs.OriginalOffset.Milliseconds(),
			"timestamp":            vs.Timestamp,
			"startOrEnd":           getStartOrEnd(vs.StartOrEnd),
			"skipHistogramBuckets": vs.SkipHistogramBuckets,
			"hasOffsetExpr":        vs.OriginalOffsetExpr != nil,
		}

	case *parser.SubqueryExpr:
		return map[string]any{
			"type":          "subquery",
			"expr":          translatePreprocessed(n.Expr),
			"rangeMS":       n.Range.Milliseconds(),
			"hasRangeExpr":  n.RangeExpr != nil,
			"stepMS":        n.Step.Milliseconds(),
			"hasStepExpr":   n.StepExpr != nil,
			"offsetMS":      n.OriginalOffset.Milliseconds(),
			"hasOffsetExpr": n.OriginalOffsetExpr != nil,
			"timestamp":     n.Timestamp,
			"startOrEnd":    getStartOrEnd(n.StartOrEnd),
		}

	case *parser.NumberLiteral:
		// Hex bits, not FormatFloat: a folded range()/step() is an arbitrary
		// float64 and this is the repo's convention for exactness (ADR-4's
		// neighbourhood). `duration` is carried because a folded literal must NOT
		// acquire it.
		return map[string]any{
			"type":     "numberLiteral",
			"bits":     hexFloat(n.Val),
			"duration": n.Duration,
		}

	case *parser.Call:
		args := []any{}
		for _, arg := range n.Args {
			args = append(args, translatePreprocessed(arg))
		}
		return map[string]any{
			"type": "call",
			"func": n.Func.Name,
			"args": args,
		}

	case *parser.AggregateExpr:
		return map[string]any{
			"type":     "aggregation",
			"op":       n.Op.String(),
			"expr":     translatePreprocessed(n.Expr),
			"param":    translatePreprocessed(n.Param),
			"grouping": sanitizeList(n.Grouping),
			"without":  n.Without,
		}

	case *parser.BinaryExpr:
		return map[string]any{
			"type": "binaryExpr",
			"op":   n.Op.String(),
			"lhs":  translatePreprocessed(n.LHS),
			"rhs":  translatePreprocessed(n.RHS),
		}

	case *parser.ParenExpr:
		// Kept in the output: preprocessExprHelper strips parens only around
		// function and aggregation *parameters*, so a ParenExpr surviving
		// elsewhere is correct and its disappearance would be a bug.
		return map[string]any{
			"type": "parenExpr",
			"expr": translatePreprocessed(n.Expr),
		}

	case *parser.UnaryExpr:
		return map[string]any{
			"type": "unaryExpr",
			"op":   n.Op.String(),
			"expr": translatePreprocessed(n.Expr),
		}

	case *parser.StringLiteral:
		return map[string]any{
			"type": "stringLiteral",
			"val":  fmt.Sprintf("%x", n.Val),
		}

	case *parser.DurationExpr:
		// Reachable only if a DurationExpr is left somewhere the walk above
		// descends into, which no parsed tree does. Emitted rather than panicked
		// on so an unexpected shape shows up as a diff.
		return map[string]any{
			"type": "durationExpr",
			"op":   n.Op.String(),
			"lhs":  translatePreprocessed(n.LHS),
			"rhs":  translatePreprocessed(n.RHS),
		}
	}
	return map[string]any{"type": "UNHANDLED", "goType": fmt.Sprintf("%T", node)}
}

// ---------------------------------------------------------- promql/preprocess

type preprocessIn struct {
	// Hex-encoded: a query can hold invalid UTF-8 and JSON cannot (ADR-9).
	Query string `json:"query"`
	Opts  string `json:"opts"`
	Range string `json:"range"`
}

type preprocessOut struct {
	// Err is PreprocessExpr's error text, byte for byte. Only the duration
	// visitor can fail, and its messages carry a `start:end` BYTE-OFFSET prefix —
	// not the `line:col` that ParseErr uses.
	Err string `json:"err"`
	OK  bool   `json:"ok"`
	AST any    `json:"ast"`
	// String() of the preprocessed tree. A StepInvariantExpr prints as its inner
	// expression, so this is a weaker check than AST — but it catches a wrapper
	// placed around the wrong node when the shapes happen to serialise alike.
	Str string `json:"str"`
	// Set when PreprocessExpr panicked. Both foldQueryContextFunctions and
	// preprocessExprHelper have unreachable-by-construction panics; if the corpus
	// ever reaches one, this makes it a visible fixture value instead of a dead
	// generator.
	Panic string `json:"panic"`
}

func genPromQLPreprocess(e *emitter) {
	corpus := exprCorpus()

	// Only the two ends of the option-set list. The single-flag sets multiply the
	// corpus for no extra signal here: PreprocessExpr does not read parser
	// options, so a query that parses identically under two sets preprocesses
	// identically too. "off" is kept because it changes *which* queries parse at
	// all, and therefore which trees reach this code.
	sets := []struct {
		name string
		opts parser.Options
	}{
		{"all", parser.Options{
			EnableExperimentalFunctions:  true,
			ExperimentalDurationExpr:     true,
			EnableExtendedRangeSelectors: true,
			EnableBinopFillModifiers:     true,
		}},
		{"off", parser.Options{}},
	}

	for _, set := range sets {
		p := parser.NewParser(set.opts)
		for i, q := range corpus {
			for _, tr := range preprocessTimeRanges {
				// "off" only gets the default range: it exists to vary the tree
				// shape, not the time arithmetic.
				if set.name == "off" && tr.name != "range" {
					continue
				}
				// Every case reparses. PreprocessExpr MUTATES the tree in place,
				// so reusing one across ranges would compound the rewrites and
				// silently make the corpus meaningless.
				expr, err := p.ParseExpr(q)
				if err != nil || expr == nil {
					continue
				}
				e.emit(
					fmt.Sprintf("pp/%s/%s/%d", set.name, tr.name, i),
					preprocessIn{Query: fmt.Sprintf("%x", q), Opts: set.name, Range: tr.name},
					runPreprocess(expr, tr.start, tr.end, tr.step))
			}
		}
	}

	// The duration-expression error paths. The extracted corpus reaches some of
	// these by luck; these are here on purpose, because the messages are a
	// byte-exact contract and each one is a distinct branch of
	// calculateDuration/evaluateDurationExpr.
	p := parser.NewParser(parser.Options{
		ExperimentalDurationExpr:    true,
		EnableExperimentalFunctions: true,
	})
	for i, q := range durationErrorCorpus() {
		for _, tr := range preprocessTimeRanges {
			expr, err := p.ParseExpr(q)
			if err != nil || expr == nil {
				// Reported so a pin bump that changes what parses cannot quietly
				// shrink this list.
				fmt.Fprintf(os.Stderr, "preprocess: duration-error case %q did not parse: %v\n", q, err)
				continue
			}
			e.emit(
				fmt.Sprintf("pperr/%s/%d", tr.name, i),
				preprocessIn{Query: fmt.Sprintf("%x", q), Opts: "durexpr", Range: tr.name},
				runPreprocess(expr, tr.start, tr.end, tr.step))
		}
	}
}

func runPreprocess(expr parser.Expr, start, end time.Time, step time.Duration) (out preprocessOut) {
	defer func() {
		if r := recover(); r != nil {
			out = preprocessOut{Panic: fmt.Sprintf("%v", r)}
		}
	}()

	result, err := promql.PreprocessExpr(expr, start, end, step)
	if err != nil {
		return preprocessOut{Err: err.Error()}
	}
	return preprocessOut{OK: true, AST: translatePreprocessed(result), Str: result.String()}
}

// durationErrorCorpus is one query per error branch, plus the boundaries.
//
// Written by hand because the extracted parser corpus was not built to cover
// these: it exists to pin *parse* errors, and a duration expression that parses
// fine but fails to evaluate is invisible to it.
//
// **The parser constant-folds a duration expression whose operands are all
// literals, and reports its own error when that fails.** So `foo[1h % 0]` never
// reaches durationVisitor at all — it is `1:8: parse error: modulo by zero`, a
// ParseErr with a line:col prefix, owned by the promql/parse suite. The visitor's
// own `4:17: modulo by zero`, with a byte-offset prefix, needs an operand the
// parser could not fold: `foo[1h % (1h - 1h)]`. The same trap hides
// `duration is out of range` behind `parse error: duration out of range` for
// `foo[1e308 * 1e308]`. Every case below is chosen to survive parsing.
func durationErrorCorpus() []string {
	// The out-of-range bound is Go's `1<<63/1e9`, which as a float64 is
	// 9223372036.854776. Expressed in seconds inside a duration expression.
	const justOver = "9223372036.8547764"
	const justUnder = "9223372036.8547754"

	return []string{
		// division by zero / modulo by zero. The divisor must not be a literal, or
		// the parser folds it and reports first — see the note above.
		"foo[1h / (1h - 1h)]",
		"foo[1h % (1h - 1h)]",
		"foo offset (1h / (1h - 1h))",
		"foo offset (1h % (1h - 1h))",
		"foo[5m:1m] offset (1h % (1h - 1h))",
		"foo[(1h % (1h - 1h)):1m]",
		"foo[5m:(1h % (1h - 1h))]",
		// The same through step()/range(), which are opaque to the parser's folder
		// by construction.
		"foo[1h % (step() - step())]",
		"foo[1h / (range() - range())]",
		// duration must be greater than 0 — every position where negatives are
		// rejected, which is everything except an offset.
		//
		// Every one of these needs a non-foldable operand for the same reason as
		// above: `foo[0s]`, `foo[-1h]` and `foo[5m:0s]` are all rejected by the
		// PARSER ("1:5: parse error: duration must be greater than 0"), so they
		// never reach the visitor and belong to the promql/parse suite.
		"foo[1h - 1h]",
		"foo[1h - 2h]",
		"foo[5m:(1m - 1m)]",
		"foo[(1m - 1m):1m]",
		"foo[step() - step()]",
		"foo[5m:(step() - step())]",
		// ... and an offset, where a negative IS allowed, so these must succeed.
		"foo offset (1h - 2h)",
		"foo offset -1h",
		"foo offset (0s)",
		"foo[5m:1m] offset (1m - 2m)",
		// NaN and the infinities, rejected before the bounds check because NaN
		// compares false against everything. `0 ^ -1` is the cheapest +Inf the
		// parser will not fold; Inf - Inf and Inf * 0 give NaN.
		"foo[0 ^ -1]",
		"foo[-(0 ^ -1)]",
		"foo[1h * (0 ^ -1)]",
		"foo[(0^-1) * 1s]",
		"foo[(0^-1) - (0^-1)]",
		"foo[(0^-1) * 0]",
		"foo offset (0 ^ -1)",
		"foo offset ((0^-1) - (0^-1))",
		// min_of/max_of with a non-finite operand, which is also how GoMath.min /
		// GoMath.max's NaN and ±Inf handling reaches this suite.
		"foo[max_of(0 ^ -1, 1h)]",
		"foo[min_of(-(0^-1), 1h)]",
		"foo[max_of((0^-1) - (0^-1), 1h)]",
		"foo[min_of((0^-1) - (0^-1), 1h)]",
		// out of range, and the boundary either side of it
		"foo[" + justOver + "]",
		"foo[" + justUnder + "]",
		"foo offset " + justOver,
		"foo offset -" + justOver,
		"foo[1h ^ 20]",
		"foo[(1h ^ 20) - (1h ^ 20)]",
		// The operators, exercised for their arithmetic rather than their errors.
		"foo[1h + 30m]",
		"foo[2h * 0.5]",
		"foo[1h ^ 2]",
		"foo[7h % 3h]",
		"foo[max_of(1h, 30m)]",
		"foo[min_of(1h, 30m)]",
		"foo[+1h]",
		"foo offset +1h",
		"foo offset -(30m)",
		// step() and range(), which read the visitor's own fields — and which
		// therefore vary across preprocessTimeRanges where nothing else does.
		"foo[step()]",
		"foo[range()]",
		"foo[step() * 2]",
		"foo[range() / 2]",
		"foo offset step()",
		"foo offset range()",
		"foo[5m:step()]",
		// NOT "foo[range():step()]": the grammar rejects a call as the subquery
		// range before a colon ("unexpected colon before duration in duration
		// expression"), so it never reaches the visitor.
		"foo[max_of(step(), 1m)]",
		"foo[min_of(range(), 1h)]",
		// range() on an instant query is 0, so this must be rejected as
		// non-positive in a range position and accepted in an offset.
		"foo[range() * 1]",
		"foo offset (range() * 1)",
		// detectHistogramStatsDecoding's branches, which have nothing to do with
		// durations but do need a corpus that reaches them.
		"histogram_count(foo)",
		"histogram_sum(foo)",
		"histogram_avg(foo)",
		"histogram_quantile(0.5, foo)",
		"histogram_fraction(0, 1, foo)",
		"histogram_count(histogram_quantile(0.5, foo))",
		"histogram_quantile(0.5, histogram_count(foo))",
		"histogram_count(rate(foo[5m]))",
		"histogram_count(sum_over_time(foo[5m:1m]))",
		"histogram_sum(foo) </ 0.5",
		"histogram_sum(foo) >/ 0.5",
		"histogram_count(foo </ 0.5)",
		"histogram_count(foo >/ 0.5)",
		// The step-invariance cases upstream's own tests care about.
		"foo @ 1",
		"foo @ start()",
		"foo @ end()",
		"foo[5m] @ start()",
		"foo[5m:1m] @ start()",
		"timestamp(foo @ 1)",
		"timestamp(abs(foo @ 1))",
		"timestamp(foo)",
		"abs(foo @ 1)",
		"foo @ 1 + bar @ 2",
		"foo @ 1 + bar",
		"sum(foo @ 1)",
		"sum((foo @ 1))",
		"rate(foo[5m] @ 1)",
		"start()",
		"end()",
		"step()",
		"range()",
		"start() + end()",
		"vector(start())",
		"time()",
		"day_of_week(foo @ 1)",
		"predict_linear(foo[5m] @ 1, 10)",
	}
}
