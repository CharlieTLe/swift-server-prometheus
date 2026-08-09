package main

// Differential coverage for promql/parser: ast.go, parse.go, printer.go,
// prettier.go, and model.Duration.
//
// Four surfaces are pinned, matching the Phase 4 exit gate in docs/ROADMAP.md:
//
//   1. The AST, as JSON. The translation is a copy of web/api/v1/translate_ast.go
//      @ v3.13.2 (that function is unexported, so it cannot be called from here).
//      Using upstream's own serialisation rather than inventing one means the
//      field set is upstream's choice, not this port's.
//   2. Parse errors: every message, its PositionRange, and the rendered
//      "line:col: parse error: ..." form. The whole list, in order — the parser
//      reports more than one.
//   3. Printing: String(), Prettify(), Tree(), and the String() of a reparse, so
//      parse(print(parse(x))) == parse(x) is pinned rather than merely asserted.
//   4. The series-description language, which is where the histogram lexer states
//      (lexValueSequence, lexHistogram, lexHistogramDescriptor, lexBuckets)
//      finally become reachable — Lex() cannot set seriesDesc, so the promql/lex
//      suite could not touch them.
//
// The AST is only emitted when the parse succeeded. On failure Go leaves a
// partially built tree behind, and translateAST dereferences fields that a
// partial tree leaves nil (Call.Func after "unknown function with name") — it
// panics rather than describing the wreckage. The errors are the contract in
// that case, and they are pinned in full.

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/prometheus/common/model"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql/parser"
)

// ---------------------------------------------------------------- option sets

// parserOptions are the four feature gates, which change which queries parse at
// all. Every one is exercised: the "off" set pins the "experimental and not
// enabled" refusals, the "all" set pins the grammar they unlock.
var parserOptionSets = []struct {
	name string
	opts parser.Options
}{
	{"off", parser.Options{}},
	{"all", parser.Options{
		EnableExperimentalFunctions:  true,
		ExperimentalDurationExpr:     true,
		EnableExtendedRangeSelectors: true,
		EnableBinopFillModifiers:     true,
	}},
	{"expfn", parser.Options{EnableExperimentalFunctions: true}},
	{"durexpr", parser.Options{ExperimentalDurationExpr: true}},
	{"extrange", parser.Options{EnableExtendedRangeSelectors: true}},
	{"fill", parser.Options{EnableBinopFillModifiers: true}},
}

// The single-flag sets multiply the corpus by four for little extra signal, so
// they only run over the inputs that mention a gated construct.
func isFeatureGatedInput(s string) bool {
	for _, needle := range []string{
		"limitk", "limit_ratio", "step(", "range(", "max_of", "min_of",
		"anchored", "smoothed", "fill", "info(", "double_exponential_smoothing",
		"mad_over_time", "ts_of_", "sort_by_label",
	} {
		if containsFold(s, needle) {
			return true
		}
	}
	return false
}

func containsFold(s, substr string) bool {
	ls, lsub := []byte(s), []byte(substr)
	lower := func(b byte) byte {
		if b >= 'A' && b <= 'Z' {
			return b + 32
		}
		return b
	}
	if len(lsub) == 0 {
		return true
	}
	for i := 0; i+len(lsub) <= len(ls); i++ {
		ok := true
		for j := range lsub {
			if lower(ls[i+j]) != lower(lsub[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------------ the corpus

// fixturesDir is where the committed corpus lives. The oracle runs with the
// repository root as its working directory (see Scripts/regen-fixtures.sh).
func fixturesDir() string {
	if d := os.Getenv("PROMQL_FIXTURES"); d != "" {
		return d
	}
	return filepath.Join("Fixtures", "promql")
}

// exprCorpus is upstream's own case list plus every query in the conformance
// suite plus the additions below.
func exprCorpus() []string {
	var out []string
	seen := map[string]bool{}
	add := func(ss ...string) {
		for _, s := range ss {
			if !seen[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
	}

	inputs, err := readParseCorpus(filepath.Join(fixturesDir(), "parse-corpus.txt"))
	if err != nil {
		panic(fmt.Sprintf("promql parse corpus: %v\n"+
			"Scripts/regen-fixtures.sh writes it during the copy phase, before generation.", err))
	}
	add(inputs...)

	exprs, _, err := testdataQueries(filepath.Join(fixturesDir(), "testdata"))
	if err != nil {
		panic(fmt.Sprintf("promql testdata: %v", err))
	}
	add(exprs...)

	// The two cases parse_test.go builds with fmt.Sprintf, so the mechanical
	// extraction cannot see them: the @ modifier's out-of-bounds guard.
	add(fmt.Sprintf(`foo @ %f`, float64(math.MaxInt64)+1))
	add(fmt.Sprintf(`foo @ %f`, float64(math.MinInt64)-1))

	// Systematic additions. These are shapes upstream's own table does not reach
	// but where a hand-written parser can plausibly diverge from an LALR one:
	// precedence and associativity at every level, and the boundary between
	// `expr` arithmetic and `duration_expr` arithmetic, which share operators.
	add(
		// Precedence, one pair per adjacent level in the %left/%right list.
		"1 or 2 and 3", "1 and 2 unless 3", "1 unless 2 or 3",
		"1 == 2 and 3", "1 and 2 == 3", "1 + 2 == 3", "1 == 2 + 3",
		"1 * 2 + 3", "1 + 2 * 3", "1 ^ 2 * 3", "1 * 2 ^ 3",
		"1 atan2 2 % 3", "1 % 2 atan2 3",
		// POW is the only right-associative operator.
		"1 ^ 2 ^ 3", "2 ^ 3 ^ 2 ^ 1", "1 - 2 - 3", "1 / 2 / 3", "1 % 2 % 3",
		"-1 ^ 2", "-1 ^ -2", "(-1) ^ 2", "1 ^ -2",
		// Unary chains: `unary_op expr %prec MUL`.
		"--1", "---1", "+-1", "-+1", "- -1", "-(1)", "-(-1)", "- - -foo",
		"-foo ^ 2", "-foo[5m]", "-sum(foo)",
		// OFFSET is %nonassoc, so a second one must be a syntax error, not a fold.
		"foo offset 5m offset 5m", "foo offset 5m offset -5m",
		"foo offset -5m", "foo offset 5m @ 10", "foo @ 10 offset 5m",
		"foo[5m] offset 5m", "foo[5m:1m] offset 5m", "sum(foo) offset 5m",
		// LEFT_BRACKET is %right, which is what makes a range always attempted.
		"foo[5m]", "foo[5m][5m]", "foo[5m:1m][5m:1m]", "foo[5m:]",
		"foo{a=\"b\"}[5m:1m] @ 10 offset 5m",
		// The @ modifier.
		"foo @ start()", "foo @ end()", "foo @ 1.5", "foo @ -1", "foo @ +1",
		"foo @ start() @ end()", "foo[5m] @ start()", "foo[5m:1m] @ end()",
		// Duration expressions, which overlap `expr` on every operator.
		"foo[1m+1m]", "foo[1m-30s]", "foo[2*1m]", "foo[1m/2]", "foo[1m%40s]",
		"foo[2^3s]", "foo[(1m)]", "foo[-(1m)]", "foo[step()]", "foo[range()]",
		"foo[max_of(1m,2m)]", "foo[min_of(1m, 2m)]", "foo[max_of(1m,2m):step()]",
		"foo[1m:step()]", "foo offset step()", "foo offset -step()",
		"foo offset max_of(1m,2m)", "foo offset -2^2", "foo[1m/0]", "foo[1m%0]",
		"step()", "range()", "max_of(1m,2m)", "(1m)", "1m + 1m", "1m",
		// Aggregations, including the modifier-after-body form and empty grouping.
		"sum by (a) (foo)", "sum (foo) by (a)", "sum without (a) (foo)",
		"sum by () (foo)", "sum by (a,) (foo)", "sum(foo)",
		"topk(5, foo)", "topk by (a) (5, foo)", "count_values(\"l\", foo)",
		"quantile(0.5, foo)", "limitk(5, foo)", "limit_ratio(0.5, foo)",
		"sum by (\"quoted\") (foo)", "sum by (a, \"b\") (foo)",
		// Vector matching, every cardinality and the group modifiers.
		"foo on (a) bar", "foo ignoring (a) bar", "foo on () bar",
		"foo on (a) group_left bar", "foo on (a) group_left (b) bar",
		"foo on (a) group_right (b) bar", "foo == bool bar",
		"foo == bool on (a) group_left (b) bar", "foo and on (a) bar",
		"foo unless ignoring (a) bar",
		// Fill modifiers, which only exist with EnableBinopFillModifiers.
		"foo fill (0) bar", "foo fill_left (1) bar", "foo fill_right (2) bar",
		"foo fill_left (1) fill_right (2) bar", "foo fill_right (2) fill_left (1) bar",
		"foo on (a) fill (0) bar", "foo fill (-1) bar", "foo fill (1m) bar",
		// Extended range selectors.
		"foo[5m] anchored", "foo[5m] smoothed", "foo anchored", "foo smoothed",
		"foo[5m] anchored smoothed", "rate(foo[5m] anchored)",
		// Selectors: quoted names, UTF-8 names, empty matchers, the __name__ rules.
		`{"foo"}`, `{"foo", a="b"}`, `{__name__="foo"}`, `{__name__=~"foo"}`,
		`foo{__name__="bar"}`, `{}`, `{a=""}`, `{a!=""}`, `{a=~""}`, `{a!~""}`,
		`{"a b"="c"}`, `{"日本"="x"}`, `日本`, `{a="b",}`, `{a="b" , b="c"}`,
		// Every match operator, and the error paths around them.
		`{a=~"[0-9]+"}`, `{a!~"["}`, `{a=~"("}`, `{a==="b"}`, `{a="b"c="d"}`,
		// Strings: all three quoting styles and their escapes.
		`"a"`, `'a'`, "`a`", `"\n"`, `'\n'`, "`\\n`", `"\xff"`, `"é"`,
		`"unterminated`, `'`, "`",
		// Function calls: arity, trailing commas, unknown names, experimental ones.
		"rate(foo[5m])", "rate()", "rate(foo[5m],)", "rate(foo[5m], 1)",
		"nonexistent_function(foo)", "mad_over_time(foo[5m])",
		"double_exponential_smoothing(foo[5m], 0.1, 0.1)",
		"info(foo)", "info(foo, {a=\"b\"})", "info(foo, bar)",
		"time()", "pi()", "scalar(foo)", "vector(1)", "label_replace(foo,\"a\",\"b\",\"c\",\"d\")",
		// Subqueries.
		"rate(foo[5m])[10m:1m]", "sum(foo)[5m:]", "foo[5m:1m] @ 100",
		"(foo)[5m:1m]", "foo[5m:1m:1m]",
		// Numbers, including the forms Go's ParseInt takes before ParseFloat.
		"0x1f", "0755", "0b101", "0o17", "1_000", "0x_1p-2", "Inf", "-Inf", "NaN",
		"1e309", "-1e309", "1e-400",
		// Empty and whitespace-only input, and comments.
		"", " ", "\n", "# c", "# c\n", "1 # c", "\t1\t",
		// Deep nesting, to shake out any recursion limit difference.
		"((((((((((1))))))))))",
		"1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1",
		"-------------------1",
		"sum(sum(sum(sum(sum(foo)))))",
	)

	// Probes for the two places an LALR parser's behaviour cannot be read off the
	// grammar, and where a hand-written parser plausibly diverges.
	//
	// First: `offset_duration_expr` and `duration_expr` both derive
	// `number_duration_literal`, a reduce/reduce conflict that goyacc settles by
	// taking the rule declared earlier — which is what makes `foo offset -2^2`
	// mean `(foo offset -2)^2`. These pin where the duration stops and ordinary
	// expression arithmetic takes over.
	add(
		"foo offset 1m+1m", "foo offset 1m + 1m", "foo offset -1m+1m",
		"foo offset (1m+1m)", "foo offset -(1m+1m)", "foo offset 2*1m",
		"foo offset step()*2", "foo offset -step()", "foo offset max_of(1m,2m)+1m",
		"foo offset 1m^2", "foo offset -1m^2", "foo offset +1m",
		"foo[1m+1m*2]", "foo[2^3^2s]", "foo[-1m]", "foo[+1m]", "foo[1m:-1m]",
		"foo[(1m+1m)*2]", "foo[step()+range()]", "foo[max_of(1m,2m)+min_of(1m,2m)]",
	)

	// Second: `lastClosing` is updated when a closing token is *lexed*, so by the
	// time an action runs it can already point past the token the node ends on.
	// `aggregate_op function_call_body` is the case where the grammar forces that
	// lookahead, and Go walks back with findPrevRightParen (upstream issue 16053).
	// Positions are only observable through errors, so each of these is a query
	// whose error is reported against the node whose end position is at stake.
	add(
		"(sum(foo, 1))", "((sum(foo, 1)))", "(sum(foo, 1)) + 1", "(topk(1))",
		"(sum(foo, 1))[5m:1m]", "sum(foo, 1) offset 5m",
		`({a=""} offset 5m)`, `({a=""})`, `({a=""}) + 1`,
		`(rate(foo[5m], 1))`, "(1[5m])", "((1[5m]))",
	)

	// The `@` modifier's preprocessor form has no `error` production of its own, so
	// a malformed one falls through to the catch-all. These pin which message wins.
	add("foo @ start", "foo @ end", "foo @ start(", "foo @ start)", "foo @ (start())")

	return out
}

// seriesCorpus is the series-description language: `load` bodies and `eval`
// expectations from the conformance suite, plus the shapes upstream's own
// testSeries table covers.
func seriesCorpus() []string {
	var out []string
	seen := map[string]bool{}
	add := func(ss ...string) {
		for _, s := range ss {
			if !seen[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
	}

	_, series, err := testdataQueries(filepath.Join(fixturesDir(), "testdata"))
	if err != nil {
		panic(fmt.Sprintf("promql testdata: %v", err))
	}
	add(series...)

	add(
		// Values, repetition and the blank.
		"metric 1", "metric 1 2 3", "metric _", "metric _ 1 _", "metric 1x3",
		"metric _x3", "metric 1+1x3", "metric 1-1x3", "metric 1 +1 -1",
		"metric stale", "metric 1 stale 2", "metric NaN", "metric Inf -Inf",
		"metric 1x0", "metric 1+0x3", "metric 0x3",
		// Labels.
		"metric{a=\"b\"} 1", "{a=\"b\"} 1", "metric{} 1", "{} 1",
		"metric{a=\"b\",c=\"d\"} 1", "{\"quoted\"} 1", "{\"a b\"=\"c\"} 1",
		// Histograms: every descriptor key, and the increase/decrease series.
		"metric {{}}", "metric {{ }}",
		"metric {{schema:0 sum:5 count:4 buckets:[1 2 1]}}",
		"metric {{schema:-53 custom_values:[1 2 3] buckets:[1 1 1]}}",
		"metric {{z_bucket:2 z_bucket_w:0.5}}",
		"metric {{n_buckets:[1 2] n_offset:2}}",
		"metric {{offset:3 buckets:[1]}}",
		"metric {{counter_reset_hint:gauge}}",
		"metric {{counter_reset_hint:reset}}",
		"metric {{counter_reset_hint:not_reset}}",
		"metric {{counter_reset_hint:unknown}}",
		"metric {{counter_reset_hint:bogus}}",
		"metric {{schema:0}}x3",
		"metric {{sum:1}}+{{sum:2}}x3",
		"metric {{sum:5}}-{{sum:1}}x3",
		"metric {{schema:0 sum:1}}+{{schema:1 sum:1}}x2",
		// Duplicate keys and malformed descriptors.
		"metric {{sum:1 sum:2}}", "metric {{bogus:1}}", "metric {{schema:x}}",
		"metric {{buckets:[1 2}}", "metric {{", "metric }}",
		// Error paths.
		"metric 1 2 bogus", "metric x", "metric", "", "metric{a=} 1",
		"metric{a 1", "metric 1x", "metric 1xx3", "metric 1x-1",
	)
	return out
}

// ------------------------------------------------------------------ AST as JSON

// The rest of this section is web/api/v1/translate_ast.go @ v3.13.2, copied
// because it is unexported. Kept structurally identical to upstream so a diff
// against a future pin is readable; the only change is the parser.* qualifier.

func translateAST(node parser.Expr) any {
	if node == nil {
		return nil
	}

	switch n := node.(type) {
	case *parser.AggregateExpr:
		return map[string]any{
			"type":     "aggregation",
			"op":       n.Op.String(),
			"expr":     translateAST(n.Expr),
			"param":    translateAST(n.Param),
			"grouping": sanitizeList(n.Grouping),
			"without":  n.Without,
		}
	case *parser.BinaryExpr:
		var matching any
		if m := n.VectorMatching; m != nil {
			matching = map[string]any{
				"card":    m.Card.String(),
				"labels":  sanitizeList(m.MatchingLabels),
				"on":      m.On,
				"include": sanitizeList(m.Include),
				// DEVIATION from translate_ast.go, which emits these as raw JSON
				// numbers. `fill (NaN)` is a legal query, and encoding/json refuses
				// to marshal NaN — upstream would fail the request. Hex bit patterns
				// carry the same information, and make the comparison exact rather
				// than decimal-rounded, which is what the rest of Fixtures/ does for
				// floats anyway.
				"fillValues": map[string]*string{
					"lhs": hexFloatPtr(m.FillValues.LHS),
					"rhs": hexFloatPtr(m.FillValues.RHS),
				},
			}
		}

		return map[string]any{
			"type":     "binaryExpr",
			"op":       n.Op.String(),
			"lhs":      translateAST(n.LHS),
			"rhs":      translateAST(n.RHS),
			"matching": matching,
			"bool":     n.ReturnBool,
		}
	case *parser.Call:
		args := []any{}
		for _, arg := range n.Args {
			args = append(args, translateAST(arg))
		}

		return map[string]any{
			"type": "call",
			"func": map[string]any{
				"name":       n.Func.Name,
				"argTypes":   n.Func.ArgTypes,
				"variadic":   n.Func.Variadic,
				"returnType": n.Func.ReturnType,
			},
			"args": args,
		}
	case *parser.MatrixSelector:
		vs := n.VectorSelector.(*parser.VectorSelector)
		return map[string]any{
			"type":       "matrixSelector",
			"name":       vs.Name,
			"range":      n.Range.Milliseconds(),
			"rangeExpr":  translateDurationExpr(n.RangeExpr),
			"offset":     vs.OriginalOffset.Milliseconds(),
			"offsetExpr": translateDurationExpr(vs.OriginalOffsetExpr),
			"matchers":   translateMatchers(vs.LabelMatchers),
			"timestamp":  vs.Timestamp,
			"startOrEnd": getStartOrEnd(vs.StartOrEnd),
			"anchored":   vs.Anchored,
			"smoothed":   vs.Smoothed,
		}
	case *parser.SubqueryExpr:
		return map[string]any{
			"type":       "subquery",
			"expr":       translateAST(n.Expr),
			"range":      n.Range.Milliseconds(),
			"rangeExpr":  translateDurationExpr(n.RangeExpr),
			"offset":     n.OriginalOffset.Milliseconds(),
			"offsetExpr": translateDurationExpr(n.OriginalOffsetExpr),
			"step":       n.Step.Milliseconds(),
			"stepExpr":   translateDurationExpr(n.StepExpr),
			"timestamp":  n.Timestamp,
			"startOrEnd": getStartOrEnd(n.StartOrEnd),
		}
	case *parser.DurationExpr:
		return translateDurationExpr(n)
	case *parser.NumberLiteral:
		return map[string]string{
			"type": "numberLiteral",
			"val":  strconv.FormatFloat(n.Val, 'f', -1, 64),
		}
	case *parser.ParenExpr:
		return map[string]any{
			"type": "parenExpr",
			"expr": translateAST(n.Expr),
		}
	case *parser.StringLiteral:
		return map[string]any{
			"type": "stringLiteral",
			"val":  n.Val,
		}
	case *parser.UnaryExpr:
		return map[string]any{
			"type": "unaryExpr",
			"op":   n.Op.String(),
			"expr": translateAST(n.Expr),
		}
	case *parser.VectorSelector:
		return map[string]any{
			"type":       "vectorSelector",
			"name":       n.Name,
			"offset":     n.OriginalOffset.Milliseconds(),
			"offsetExpr": translateDurationExpr(n.OriginalOffsetExpr),
			"matchers":   translateMatchers(n.LabelMatchers),
			"timestamp":  n.Timestamp,
			"startOrEnd": getStartOrEnd(n.StartOrEnd),
			"anchored":   n.Anchored,
			"smoothed":   n.Smoothed,
		}
	}
	panic("unsupported node type")
}

func translateDurationExpr(node parser.Expr) any {
	if node == nil {
		return nil
	}

	switch n := node.(type) {
	case *parser.DurationExpr:
		if n == nil {
			return nil
		}

		return map[string]any{
			"type":    "durationExpr",
			"op":      n.Op.String(),
			"lhs":     translateDurationExpr(n.LHS),
			"rhs":     translateDurationExpr(n.RHS),
			"wrapped": n.Wrapped,
		}
	case *parser.NumberLiteral:
		if n == nil {
			return nil
		}

		return map[string]any{
			"type":     "numberLiteral",
			"val":      strconv.FormatFloat(n.Val, 'f', -1, 64),
			"duration": n.Duration,
		}
	default:
		return translateAST(n)
	}
}

func sanitizeList(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

// hexFloatPtr preserves the nil/present distinction that a fill value carries:
// nil means "no fill for that side", which is different from a fill of 0.
func hexFloatPtr(f *float64) *string {
	if f == nil {
		return nil
	}
	s := hexFloat(*f)
	return &s
}

func translateMatchers(in []*labels.Matcher) any {
	out := []map[string]any{}
	for _, m := range in {
		out = append(out, map[string]any{
			"name":  m.Name,
			"value": m.Value,
			"type":  m.Type.String(),
		})
	}
	return out
}

func getStartOrEnd(startOrEnd parser.ItemType) any {
	if startOrEnd == 0 {
		return nil
	}

	return startOrEnd.String()
}

// ------------------------------------------------------------- error reporting

type parseErrJSON struct {
	Start int32 `json:"start"`
	End   int32 `json:"end"`
	// The error message alone.
	Msg string `json:"msg"`
	// ParseErr.Error(): "<line>:<col>: parse error: <msg>". Pins StartPosInput's
	// arithmetic against the same query the parser saw.
	Rendered string `json:"rendered"`
}

// describeErr splits whatever ParseExpr returned into the JSON shape. The
// distinction between the three cases matters: a ParseErrors list is the normal
// path, ErrUnexpected means Go recovered from a runtime panic, and anything else
// would be a bug worth seeing rather than folding away.
func describeErr(err error) (errs []parseErrJSON, unexpected bool, other string) {
	if err == nil {
		return nil, false, ""
	}
	if errors.Is(err, parser.ErrUnexpected) {
		return nil, true, ""
	}
	var list parser.ParseErrors
	if errors.As(err, &list) {
		for _, e := range list {
			errs = append(errs, parseErrJSON{
				Start:    int32(e.PositionRange.Start),
				End:      int32(e.PositionRange.End),
				Msg:      e.Err.Error(),
				Rendered: e.Error(),
			})
		}
		return errs, false, ""
	}
	return nil, false, err.Error()
}

// ----------------------------------------------------------- promql/parse

type exprParseOut struct {
	Errors     []parseErrJSON `json:"errors"`
	Unexpected bool           `json:"unexpected"`
	Other      string         `json:"other"`
	// Everything below is only produced for a clean parse: on failure Go leaves a
	// partial tree whose String() and translateAST() both panic.
	OK      bool   `json:"ok"`
	AST     any    `json:"ast"`
	Str     string `json:"str"`
	Pretty  string `json:"pretty"`
	Tree    string `json:"tree"`
	Type    string `json:"type"`
	Reparse string `json:"reparse"`
}

type exprParseIn struct {
	// Hex-encoded: a query can hold invalid UTF-8, and JSON cannot (ADR-9).
	Query string `json:"query"`
	Opts  string `json:"opts"`
}

func genPromQLParse(e *emitter) {
	corpus := exprCorpus()
	for _, set := range parserOptionSets {
		p := parser.NewParser(set.opts)
		for i, q := range corpus {
			if set.name != "off" && set.name != "all" && !isFeatureGatedInput(q) {
				continue
			}
			e.emit(fmt.Sprintf("parse/%s/%d", set.name, i),
				exprParseIn{Query: fmt.Sprintf("%x", q), Opts: set.name},
				runParse(p, q))
		}
	}
}

func runParse(p parser.Parser, q string) exprParseOut {
	expr, err := p.ParseExpr(q)
	errs, unexpected, other := describeErr(err)
	out := exprParseOut{Errors: errs, Unexpected: unexpected, Other: other}
	if err != nil || expr == nil {
		return out
	}

	out.OK = true
	out.AST = translateAST(expr)
	out.Str = expr.String()
	out.Pretty = parser.Prettify(expr)
	out.Tree = parser.Tree(expr)
	out.Type = string(expr.Type())

	// The round trip. printing then reparsing must reach the same text, which is
	// the property the exit gate states as parse(print(parse(x))) == parse(x).
	if reparsed, err := p.ParseExpr(out.Str); err == nil && reparsed != nil {
		out.Reparse = reparsed.String()
	} else {
		out.Reparse = "<reparse failed>"
	}
	return out
}

// ------------------------------------------------------- promql/seriesdesc

type seriesValueJSON struct {
	Value   string         `json:"value"` // hex float64 bits
	Omitted bool           `json:"omitted"`
	Hist    *floatHistJSON `json:"hist"`
	HintSet bool           `json:"hintSet"`
	Str     string         `json:"str"` // SequenceValue.String()
}

type seriesDescOut struct {
	Errors []parseErrJSON    `json:"errors"`
	Other  string            `json:"other"`
	OK     bool              `json:"ok"`
	Labels []string          `json:"labels"` // flattened name/value pairs, hex
	Values []seriesValueJSON `json:"values"`
}

func genPromQLSeriesDesc(e *emitter) {
	// The series-description language does not touch the feature gates, so one
	// option set is enough. It is the "all" set so a histogram descriptor that
	// happens to reach a gated construct is not refused for the wrong reason.
	p := parser.NewParser(parser.Options{
		EnableExperimentalFunctions:  true,
		ExperimentalDurationExpr:     true,
		EnableExtendedRangeSelectors: true,
		EnableBinopFillModifiers:     true,
	})
	for i, line := range seriesCorpus() {
		lbls, vals, err := p.ParseSeriesDesc(line)
		errs, _, other := describeErr(err)
		out := seriesDescOut{Errors: errs, Other: other}
		if err == nil {
			out.OK = true
			out.Labels = flattenLabels(lbls)
			out.Values = []seriesValueJSON{}
			for _, v := range vals {
				sv := seriesValueJSON{
					Value:   hexFloat(v.Value),
					Omitted: v.Omitted,
					HintSet: v.CounterResetHintSet,
					Str:     v.String(),
				}
				if v.Histogram != nil {
					h := toFloatHistJSON(v.Histogram)
					sv.Hist = &h
				}
				out.Values = append(out.Values, sv)
			}
		}
		e.emit(fmt.Sprintf("series/%d", i),
			map[string]string{"line": fmt.Sprintf("%x", line)}, out)
	}
}

func flattenLabels(l labels.Labels) []string {
	out := []string{}
	l.Range(func(lb labels.Label) {
		out = append(out, fmt.Sprintf("%x", lb.Name), fmt.Sprintf("%x", lb.Value))
	})
	return out
}

// ------------------------------------- promql/metric and promql/metricselector

type metricOut struct {
	Errors []parseErrJSON `json:"errors"`
	Other  string         `json:"other"`
	OK     bool           `json:"ok"`
	Labels []string       `json:"labels"`
}

type selectorOut struct {
	Errors   []parseErrJSON `json:"errors"`
	Other    string         `json:"other"`
	OK       bool           `json:"ok"`
	Matchers []string       `json:"matchers"` // Matcher.String(), in parse order
}

// metricCorpus is the label-set language reached through START_METRIC, which is
// a different grammar entry point from an expression: `metric` allows a bare
// label set and has its own error productions ("label set", not "label matching").
func metricCorpus() []string {
	var out []string
	seen := map[string]bool{}
	add := func(ss ...string) {
		for _, s := range ss {
			if !seen[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
	}
	add(
		"", "{}", "foo", "foo{}", `foo{a="b"}`, `foo{a="b",c="d"}`, `{a="b"}`,
		`{"foo"}`, `{"foo",a="b"}`, `{__name__="foo"}`, `foo{__name__="bar"}`,
		`{a="b",}`, `{a="b" c="d"}`, `{a=}`, `{a}`, `{=}`, `{a="b"`, `foo bar`,
		`{"a b"="c"}`, `{"日本"="x"}`, `日本`, `foo{a="\n"}`, `foo{a='b'}`,
		"foo{a=`b`}", `{a="b", "c"="d"}`, `sum`, `sum{a="b"}`, `by`, `offset`,
		`{a=~"b"}`, `{a!="b"}`, "{", "}", "foo{",
	)
	// Everything from the series corpus up to its first space is a metric.
	for _, s := range seriesCorpus() {
		if i := indexByte(s, ' '); i > 0 {
			add(s[:i])
		}
		if i := indexByte(s, '\t'); i > 0 {
			add(s[:i])
		}
	}
	return out
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func genPromQLMetric(e *emitter) {
	p := parser.NewParser(parser.Options{})
	for i, in := range metricCorpus() {
		lbls, err := p.ParseMetric(in)
		errs, _, other := describeErr(err)
		out := metricOut{Errors: errs, Other: other}
		if err == nil {
			out.OK = true
			out.Labels = flattenLabels(lbls)
		}
		e.emit(fmt.Sprintf("metric/%d", i),
			map[string]string{"input": fmt.Sprintf("%x", in)}, out)
	}
}

func genPromQLMetricSelector(e *emitter) {
	p := parser.NewParser(parser.Options{})
	// The selector entry point takes the same inputs plus the matcher operators,
	// which the metric grammar rejects.
	corpus := append(metricCorpus(),
		`{a=~"b+"}`, `{a!~"b"}`, `foo{a=~"b",c!~"d"}`, `{a=~"["}`,
		`foo offset 5m`, `foo[5m]`, `sum(foo)`, `foo @ 1`,
	)
	for i, in := range corpus {
		ms, err := p.ParseMetricSelector(in)
		errs, _, other := describeErr(err)
		out := selectorOut{Errors: errs, Other: other}
		if err == nil {
			out.OK = true
			out.Matchers = []string{}
			for _, m := range ms {
				out.Matchers = append(out.Matchers, m.String())
			}
		}
		e.emit(fmt.Sprintf("selector/%d", i),
			map[string]string{"input": fmt.Sprintf("%x", in)}, out)
	}
}

// ------------------------------------------------------- promql/modelduration

// model.Duration is a separate surface from time.Duration (pinned by
// gocompat/duration): PromQL's `1h30m` grammar with a 365d year, units required
// in descending order, and a String() that works in whole milliseconds. Both
// directions are user-facing — String() renders every offset and range in
// printer.go, and every parse error reaches ParseErr verbatim.
func genPromQLModelDuration(e *emitter) {
	var inputs []string
	add := func(ss ...string) { inputs = append(inputs, ss...) }

	// Valid, one per unit and in combination.
	add("0", "1ms", "1s", "1m", "1h", "1d", "1w", "1y",
		"5m", "90s", "1h30m", "1d12h", "1w2d", "1y2w3d4h5m6s7ms",
		"100ms", "999ms", "1000ms", "0s", "0ms", "0y",
		"2h30m10s", "1y365d", "10000d", "106751d")

	// Rejected: empty, no unit, unknown unit, wrong order, repeats, negatives,
	// fractions, and the overflow guard at ~292 years.
	add("", " ", "1", "1x", "1sm", "1ss", "ms", "s", "-1s", "+1s", "1.5s",
		"1m1y", "1s1m", "1m1m", "1h1h", "1ms1s", "1y1y",
		"1s ", " 1s", "1 s", "1S", "1M", "1H", "1D", "1W", "1Y",
		"292y", "293y", "3000y", "9223372036854775807s",
		"18446744073709551616s", "99999999999999999999999999s",
		"1e3s", "0x1s", "١s", "1s\x00", "\xffs")

	for i, s := range inputs {
		d, err := model.ParseDuration(s)
		out := map[string]any{}
		if err != nil {
			out["err"] = err.Error()
		} else {
			out["nanos"] = strconv.FormatInt(int64(d), 10)
			out["str"] = d.String()
		}
		e.emit(fmt.Sprintf("parse/%d", i),
			map[string]string{"op": "parse", "in": fmt.Sprintf("%x", s)}, out)
	}

	// Formatting, over the boundaries String()'s exact-division rule turns on.
	var nanos []int64
	nanos = append(nanos,
		0, 1, 999_999, 1_000_000, 1_500_000, -1, -1_000_000, -1_500_000,
		int64(time.Second), int64(time.Minute), int64(time.Hour),
		int64(24*time.Hour), int64(7*24*time.Hour), int64(365*24*time.Hour),
		int64(366*24*time.Hour), int64(90*24*time.Hour), int64(84*24*time.Hour),
		int64(2*365*24*time.Hour), int64(time.Second/2), -int64(time.Second/2),
		math.MaxInt64, math.MinInt64, math.MaxInt64-1, math.MinInt64+1,
	)
	// A deterministic spread, so the y/w exactness branches get hit by inputs
	// nobody chose by hand.
	for i := 1; i <= 400; i++ {
		nanos = append(nanos,
			int64(i)*int64(time.Millisecond),
			int64(i)*int64(time.Second)*37,
			int64(i)*int64(time.Hour)*13,
			-int64(i)*int64(time.Minute)*7,
		)
	}
	for i, n := range nanos {
		e.emit(fmt.Sprintf("format/%d", i),
			map[string]string{"op": "format", "in": strconv.FormatInt(n, 10)},
			map[string]any{"str": model.Duration(n).String()})
	}
}

// Silence the unused-import checker if a future edit drops the histogram use.
var _ = histogram.FloatHistogram{}
