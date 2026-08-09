package main

// Differential coverage for promql/parser/lex.go and posrange.
//
// The probe records the whole token stream: type, byte position, raw value and
// Item.String() for each item. It stops at the first EOF or ERROR — a rule both
// sides implement identically, because Go's `state` field is unexported and some
// errorf paths return a non-nil state, so "lex until the state is nil" is not
// available from outside the package.
//
// NOT covered here: the series-description and histogram-description states.
// `Lex()` cannot set the unexported seriesDesc flag, so lexValueSequence,
// lexHistogram, lexHistogramDescriptor and lexBuckets are unreachable from
// outside the package. They are pinned in the parser slice through
// ParseSeriesDesc, which does set it.

import (
	"fmt"
	"sort"
	"strings"

	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/promql/parser/posrange"
)

// lexCorpus is the input set. Systematic coverage of every lexable construct,
// plus the shapes upstream's lex_test.go singles out, plus error paths.
func lexCorpus() []string {
	var out []string
	add := func(s ...string) { out = append(out, s...) }

	// Empty and whitespace.
	add("", " ", "\t", "\n", "\r", "  \t\n  ", "\r\n")

	// Comments, including one that never terminates and one holding invalid UTF-8.
	add("# a comment", "#", "1 # trailing", "# c1\n# c2", "1 #\n2",
		"# comment with \xff invalid utf8", "#\n")

	// Every single-character and multi-character operator.
	add("+", "-", "*", "/", "%", "^", "==", "!=", "<=", "<", ">=", ">", "=",
		"</", ">/", "=~", "!~", "@", ",", "(", ")", "[", "]", "{", "}", ":", ";", "_")

	// Operator sequences that stress the lookahead.
	add("=~", "!", "!=", "!~", "=!", "==-", "<<", ">>", "<=>", "1</2", "1>/2",
		"a=~\"b\"", "a!~\"b\"")

	// Every keyword, bare and as part of an expression.
	//
	// Keywords() iterates Go maps, so its order is randomised per run. Sorting is
	// what makes this corpus reproducible — without it verify-fixtures.sh reports
	// a diff on every regeneration. See PORTING.md on corpus reproducibility.
	keywords := parser.Keywords()
	sort.Strings(keywords)
	for _, kw := range keywords {
		add(kw, strings.ToUpper(kw), kw+"(x)", "foo "+kw+" bar", "{"+kw+"=\"1\"}")
	}

	// fill/fill_left/fill_right are only keywords when followed by '(' — the
	// context-sensitive path.
	add("fill", "fill(1)", "fill (1)", "fill\t(1)", "fill + fill", "fill_left(1)",
		"fill_left", "fill_right(1)", "fill_right + 1", "fill_left+fill_right")

	// Identifiers, metric identifiers and the colon rule.
	add("foo", "foo_bar", "_foo", "foo123", "abc:def", ":leading", "trailing:",
		"a:b:c", "上海", "fooé", "föö")

	// Numbers in every format scanNumber accepts, and several it rejects.
	add("1", "0", "0.0", ".5", "5.", "1e3", "1E3", "1e-3", "1e+3", "0x1f", "0X1F",
		"0x_1FFFP-16", "1_000", "1_000_000", "0b1010", "0o17", "1.2.3", "1e", "1e+",
		"1_", "1__0", "1._2", "1.e3", "0x1.8p3", "Inf", "inf", "+Inf", "-Inf", "NaN",
		"nan", "0xg", "1x", "1.5e", "..1", "1..2", "1e1e1", "0x")

	// Durations, valid and not.
	add("1s", "1m", "1h", "1d", "1w", "1y", "1ms", "5m30s", "1h30m", "1y2w3d4h5m6s7ms",
		"1", "1sm", "1hs", "1ys", "0s", "1.5s", "1s1", "1s2m", "1m1y", "100ms",
		"1e3s", "1_0s")

	// Strings: quoting styles, escapes, and every escape error path.
	add(`"foo"`, `'foo'`, "`foo`", `""`, `''`, "``",
		`"a\nb"`, `"a\tb"`, `"a\\b"`, `"a\"b"`, `'a\'b'`, `"a'b"`, `'a"b'`,
		`"\a\b\f\n\r\t\v"`, `"\0"`, `"\007"`, `"\x41"`, `"é"`, `"\U0001F600"`,
		`"\8"`, `"\x"`, `"\xg"`, `"\u"`, `"\uD800"`, `"\U00110000"`, `"\400"`,
		`"unterminated`, `'unterminated`, "`unterminated",
		"\"multi\nline\"", `"\`, "`raw \\n stays`", "`raw with \"quotes\"`",
		// Invalid UTF-8 in each string flavour, plus a validly encoded U+FFFD,
		// which Go also reports as invalid because it cannot tell them apart.
		"\"\xff\"", "'\xff'", "`\xff`", "\"�\"", "`�`")

	// Braces: label matchers, keywords-as-labels, and the error paths.
	add(`{}`, `{foo="bar"}`, `{foo!="bar"}`, `{foo=~"bar"}`, `{foo!~"bar"}`,
		`{foo="bar",baz="qux"}`, `{ foo = "bar" }`, `{foo}`, `{foo=}`, `{="bar"}`,
		`{foo="bar"`, `{{`, `{foo{`, `{foo!bar}`, `{foo#bar}`, `{,}`, `{foo=='bar'}`,
		`{"quoted"="value"}`, `{foo="bar"} # comment`, `{sum="1"}`, `{on="1"}`,
		`metric{}`, `metric{a="1"}[5m]`)

	// Parentheses and brackets, balanced and not.
	add("()", "(1)", "((1))", "(1", "1)", "[5m]", "[5m", "5m]", "[[5m]]", "[]",
		"foo[5m]", "foo[5m:1m]", "foo[5m:]", "foo[:1m]", "foo[5m::1m]", "foo[5m:1m:1m]",
		"sum(rate(foo[5m]))", "sum(rate(foo[5m])", "(((")

	// Duration expressions inside brackets, the newer lexDurationExpr state.
	add("foo[1m+1m]", "foo[2*step]", "foo[step]", "foo[range]", "foo[max_of(1m,2m)]",
		"foo[min_of(1m,2m)]", "foo[1m*2]", "foo[(1m+2m)*3]", "foo[1m/0]", "foo[-1m]",
		"foo[1m%2m]", "foo[1m^2]", "foo[step:step]", "foo[:step]", "foo[step:]",
		"foo[1m:2m:3m]", "foo[stepp]", "foo[rangex]", "foo[st]", "foo[]", "foo[ 1m ]",
		"foo[1m ]", "foo[ ]", "foo[:]", "foo[::]", "foo[1m:1m:]", "foo[1m,2m]")

	// The @ modifier and its preprocessors.
	add("foo @ 1", "foo @ start()", "foo @ end()", "foo @ 1.5", "foo @ -1", "foo@1",
		"foo @", "foo @ start", "foo offset 5m", "foo offset -5m", "foo offset 5m @ 1")

	// Aggregations and modifiers.
	add("sum by (a) (b)", "sum without (a) (b)", "sum(a) by (b)", "topk(5, a)",
		"quantile(0.5, a)", "count_values(\"x\", a)", "limitk(5, a)", "limit_ratio(0.5, a)",
		"a and b", "a or b", "a unless b", "a atan2 b", "a == bool b",
		"a on (x) group_left b", "a ignoring (x) group_right (y) b",
		"a + b fill_left(0)", "rate(a[5m] smoothed)", "rate(a[5m] anchored)")

	// Series-description syntax reached through the plain lexer. The histogram
	// states need seriesDesc, so these lex only up to where that matters.
	add("{{schema:0}}", "{{", "}}", "1x3", "1+1x3", "_", "1 _ 2", "stale")

	// Non-ASCII and control characters in odd places.
	add("é", "\x00", "\x7f", "a\x00b", "1 \x01 2", "\xc3", "\xe2\x82", "\xf0\x9f\x98",
		"\xed\xa0\x80", "€", "​")

	// Long values, for Item.String()'s %.10q truncation — including one where the
	// 10-rune cut lands inside a multi-byte character's neighbourhood.
	add("averyveryverylongidentifiername", `"a string longer than ten characters"`,
		"ééééééééééééé", `"ééééééééééééé"`, "0.12345678901234567890")

	return out
}

func genPromQLLex(e *emitter) {
	type itemJSON struct {
		Typ int32  `json:"typ"`
		Pos int32  `json:"pos"`
		Val string `json:"val"` // hex, since it can hold arbitrary bytes.
		Str string `json:"str"` // Item.String()
	}
	type out struct {
		Items []itemJSON `json:"items"`
	}

	for i, input := range lexCorpus() {
		l := parser.Lex(input)
		items := []itemJSON{}
		var item parser.Item
		// The cap only guards against a runaway; nothing in the corpus approaches it.
		for range 1000 {
			l.NextItem(&item)
			items = append(items, itemJSON{
				Typ: int32(item.Typ),
				Pos: int32(item.Pos),
				Val: hexBytes([]byte(item.Val)),
				Str: item.String(),
			})
			if item.Typ == parser.EOF || item.Typ == parser.ERROR {
				break
			}
		}
		e.emit(fmt.Sprintf("lex/%d", i), hexBytes([]byte(input)), out{Items: items})
	}
}

func hexBytes(b []byte) string {
	var sb strings.Builder
	const hexDigits = "0123456789abcdef"
	for _, c := range b {
		sb.WriteByte(hexDigits[c>>4])
		sb.WriteByte(hexDigits[c&0xF])
	}
	return sb.String()
}

// genPromQLPosRange pins PositionRange.StartPosInput, which renders the line:col
// prefix of every parse error.
func genPromQLPosRange(e *emitter) {
	type in struct {
		Query      string `json:"query"` // hex
		Start      int32  `json:"start"`
		End        int32  `json:"end"`
		LineOffset int    `json:"lineOffset"`
	}
	queries := []string{
		"", "a", "sum(rate(foo[5m]))",
		"line one\nline two\nline three",
		"\n", "\n\n", "a\nb", "a\r\nb",
		// Multi-byte, where a byte position lands mid-character.
		"ééé", "上海\n北京",
		"trailing newline\n",
	}
	i := 0
	for _, q := range queries {
		for _, start := range []int32{-1, 0, 1, 2, 3, 8, 9, 17, int32(len(q)), int32(len(q)) + 1} {
			for _, lineOffset := range []int{0, 1, 5} {
				p := posrange.PositionRange{Start: posrange.Pos(start), End: posrange.Pos(start)}
				e.emit(fmt.Sprintf("pr/%d", i),
					in{Query: hexBytes([]byte(q)), Start: start, End: start, LineOffset: lineOffset},
					p.StartPosInput(q, lineOffset))
				i++
			}
		}
	}
}
