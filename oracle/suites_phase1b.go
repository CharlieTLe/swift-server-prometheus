package main

import (
	"encoding/hex"
	"fmt"
	"math"
	"math/rand"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/prometheus/model/labels"
)

// ---------------------------------------------------------------- floatparse

type strIn struct {
	// Hex-encoded so odd bytes survive JSON intact (see ADR-9).
	S string `json:"s"`
}

type parseOut struct {
	// "", "syntax" or "range" — Go returns a value alongside a range error.
	Err  string `json:"err"`
	Bits string `json:"bits"`
}

// floatStringCorpus mixes well-formed literals with the malformed neighbours
// that pin down Go's idiosyncrasies: signed NaN is rejected, hex requires a `p`
// exponent, underscores must separate digits, overflow is a range error while
// underflow is not.
func floatStringCorpus() []string {
	r := rand.New(rand.NewSource(8080))
	out := []string{
		"", " ", "1", "-1", "+1", "0", "-0", "1.", ".5", "-.5", "1.e5", "1.5e+300",
		".", "+.", "-.", "1e", "1e+", "1e-", "e5", "+", "-", "--1", "1-", "1+",
		"1e5", "1E5", "1e+5", "1e-5", "0.0e0", "00", "007", "1.2.3", "1..2",
		// Specials: case-insensitive, and "infinity" is accepted in full or as "inf".
		"inf", "Inf", "INF", "+inf", "-inf", "infinity", "Infinity", "-INFINITY",
		"infi", "infin", "infinit", "infinityy", "inf ",
		"nan", "NaN", "NAN", "+nan", "-nan", "nann", "na",
		// Hex: the p exponent is mandatory.
		"0x1p-2", "0X1P-2", "0x1.8p1", "0x.8p0", "0x1p0", "0x1", "0x", "0x1p",
		"0x1p+", "0xg1p0", "0x1.p0", "0x.p0",
		// Underscores.
		"1_000", "1_000.5", "1__0", "_1", "1_", "1._5", "1.5_", "0x_1p0", "1_e5",
		"1e_5", "1e5_", "0x1_8p0",
		// Range.
		"1e308", "1e309", "1e400", "-1e400", "1e-323", "1e-324", "1e-400",
		"17976931348623157e292", "179769313486231580e292",
		// Boundaries and long digit strings.
		"4.9406564584124654e-324", "2.2250738585072014e-308",
		"1.7976931348623157e308", "1.7976931348623159e308",
		strings.Repeat("9", 400), "0." + strings.Repeat("0", 400) + "1",
		"1" + strings.Repeat("0", 400),
	}
	// Round-trips of real doubles in every format Prometheus emits.
	for i, v := range floatCorpus() {
		if i%37 != 0 { // keep the fixture reviewable
			continue
		}
		out = append(out,
			strconv.FormatFloat(v, 'g', -1, 64),
			strconv.FormatFloat(v, 'e', -1, 64),
			strconv.FormatFloat(v, 'f', -1, 64))
	}
	// Random mutations of valid literals: the cheapest source of near-misses.
	base := []string{"1.5e10", "0x1p3", "123", "-0.001", "inf", "nan"}
	alphabet := []byte("0123456789.eEpPxX+-_abcdefABCDEF ")
	for i := 0; i < 1500; i++ {
		s := []byte(base[r.Intn(len(base))])
		for m := 0; m < 1+r.Intn(2); m++ {
			switch r.Intn(3) {
			case 0: // substitute
				if len(s) > 0 {
					s[r.Intn(len(s))] = alphabet[r.Intn(len(alphabet))]
				}
			case 1: // insert
				p := r.Intn(len(s) + 1)
				s = append(s[:p], append([]byte{alphabet[r.Intn(len(alphabet))]}, s[p:]...)...)
			default: // delete
				if len(s) > 0 {
					p := r.Intn(len(s))
					s = append(s[:p], s[p+1:]...)
				}
			}
		}
		out = append(out, string(s))
	}
	return out
}

func genFloatParse(e *emitter) {
	for i, s := range floatStringCorpus() {
		f, err := strconv.ParseFloat(s, 64)
		kind := ""
		if err != nil {
			if ne, ok := err.(*strconv.NumError); ok {
				switch ne.Err {
				case strconv.ErrSyntax:
					kind = "syntax"
				case strconv.ErrRange:
					kind = "range"
				}
			}
		}
		e.emit(fmt.Sprintf("fp/%d", i),
			strIn{S: hex.EncodeToString([]byte(s))},
			parseOut{Err: kind, Bits: fbits(f)})
	}
}

// ------------------------------------------------------------------- unquote

type unquoteOut struct {
	OK    bool   `json:"ok"`
	Bytes string `json:"bytes"`
}

func genUnquote(e *emitter) {
	r := rand.New(rand.NewSource(9090))
	var corpus []string

	// Round-trip every quote-suite case: Quote's output must Unquote back.
	for _, b := range byteStringCorpus() {
		corpus = append(corpus, strconv.Quote(string(b)))
	}

	corpus = append(corpus,
		// Well-formed.
		`""`, `"a"`, `"\n"`, `"\t\r\v\f\a\b"`, `"\\"`, `"\""`, `"\x41"`, `"\101"`,
		`"é"`, `"\U0001F600"`, `"café"`, "`raw`", "`raw\nwith\nnewlines`",
		"`raw\rcr`", `'a'`, `'\n'`, `'\''`, `'é'`,
		// Malformed.
		``, `"`, `'`, "`", `"unterminated`, `"\q"`, `"\x4"`, `"\xZZ"`, `"\u12"`,
		`"\U0011FFFF"`, `"\400"`, `"\8"`, `"\09"`, `"\'"`, `'\"'`, `''`, `'ab'`,
		`"a`+"\n"+`b"`, `"trailing"junk`, `no quotes`, `"\u{1F600}"`,
		// Surrogates are invalid runes.
		`"\ud800"`, `"𐀀"`,
		// \x may yield invalid UTF-8, which is legal and byte-preserving.
		`"\xff"`, `"\xff\xfe"`, `"a\x80b"`,
	)

	// Random mutations of valid literals.
	base := []string{`"abc"`, `"\n\t"`, `"\x41\x42"`, "`raw`", `'x'`, `"é"`}
	alphabet := []byte(`"'` + "`" + `\xuU0189abcnrtvf{}`)
	for i := 0; i < 1200; i++ {
		s := []byte(base[r.Intn(len(base))])
		for m := 0; m < 1+r.Intn(2); m++ {
			switch r.Intn(3) {
			case 0:
				if len(s) > 0 {
					s[r.Intn(len(s))] = alphabet[r.Intn(len(alphabet))]
				}
			case 1:
				p := r.Intn(len(s) + 1)
				s = append(s[:p], append([]byte{alphabet[r.Intn(len(alphabet))]}, s[p:]...)...)
			default:
				if len(s) > 0 {
					p := r.Intn(len(s))
					s = append(s[:p], s[p+1:]...)
				}
			}
		}
		corpus = append(corpus, string(s))
	}

	for i, s := range corpus {
		out, err := strconv.Unquote(s)
		e.emit(fmt.Sprintf("uq/%d", i),
			strIn{S: hex.EncodeToString([]byte(s))},
			unquoteOut{OK: err == nil, Bytes: hex.EncodeToString([]byte(out))})
	}
}

// ------------------------------------------------------------------ duration

type durationIn struct {
	// Decimal string: nanosecond counts exceed JSON's safe integer range.
	Nanos string `json:"nanos"`
}

func genDuration(e *emitter) {
	r := rand.New(rand.NewSource(1212))
	var ds []int64
	ds = append(ds,
		0, 1, -1, 999, 1000, 1001, 999999, 1000000, 1000000001,
		int64(time.Nanosecond), int64(time.Microsecond), int64(time.Millisecond),
		int64(time.Second), int64(time.Minute), int64(time.Hour),
		int64(time.Hour*24), int64(time.Hour*24*365),
		int64(90*time.Second), int64(3661*time.Second),
		int64(1500*time.Millisecond), int64(1500*time.Microsecond),
		int64(time.Second/2), -int64(time.Second/2),
		math.MaxInt64, math.MinInt64, math.MaxInt64-1, math.MinInt64+1,
	)
	for i := 0; i < 2000; i++ {
		switch r.Intn(4) {
		case 0:
			ds = append(ds, int64(r.Intn(1000000000))) // sub-second
		case 1:
			ds = append(ds, int64(r.Intn(1000))*int64(time.Second))
		case 2:
			ds = append(ds, r.Int63())
		default:
			ds = append(ds, -r.Int63())
		}
	}
	for i, d := range ds {
		e.emit(fmt.Sprintf("d/%d", i),
			durationIn{Nanos: strconv.FormatInt(d, 10)},
			time.Duration(d).String())
	}
}

// ------------------------------------------------------------- labels builder

type builderOp struct {
	Op string `json:"op"`
	// Hex-encoded names/values.
	Args []string `json:"args"`
}

type builderIn struct {
	Base labelsIn    `json:"base"`
	Ops  []builderOp `json:"ops"`
}

type builderOut struct {
	// Result of Labels().
	Labels labelsIn `json:"labels"`
	// Order Range() yields, which is base-then-add and NOT sorted.
	RangeOrder labelsIn `json:"rangeOrder"`
	// Get() probed against corpusNames, in order.
	Gets []string `json:"gets"`
}

func genLabelsBuilder(e *emitter) {
	corpus := labelSetCorpus()
	r := rand.New(rand.NewSource(2323))
	for i := 0; i < 2500; i++ {
		base := labels.New(corpus[r.Intn(len(corpus))]...)
		b := labels.NewBuilder(base)

		script := []builderOp{}
		for j := 0; j < r.Intn(6); j++ {
			switch r.Intn(4) {
			case 0:
				n := corpusNames[r.Intn(len(corpusNames))]
				b.Del(n)
				script = append(script, builderOp{Op: "del",
					Args: []string{hex.EncodeToString([]byte(n))}})
			case 1:
				n := corpusNames[r.Intn(len(corpusNames))]
				v := fmt.Sprintf("v%d", r.Intn(5))
				b.Set(n, v)
				script = append(script, builderOp{Op: "set",
					Args: []string{hex.EncodeToString([]byte(n)), hex.EncodeToString([]byte(v))}})
			case 2:
				// Setting an empty value deletes, which is easy to get wrong.
				n := corpusNames[r.Intn(len(corpusNames))]
				b.Set(n, "")
				script = append(script, builderOp{Op: "set",
					Args: []string{hex.EncodeToString([]byte(n)), ""}})
			default:
				k := r.Intn(3)
				keep := []string{}
				hexKeep := []string{}
				for x := 0; x < k; x++ {
					n := corpusNames[r.Intn(len(corpusNames))]
					keep = append(keep, n)
					hexKeep = append(hexKeep, hex.EncodeToString([]byte(n)))
				}
				b.Keep(keep...)
				script = append(script, builderOp{Op: "keep", Args: hexKeep})
			}
		}

		var gets []string
		for _, n := range corpusNames {
			gets = append(gets, hex.EncodeToString([]byte(b.Get(n))))
		}

		var rangeOrder labelsIn
		rangeOrder.Labels = [][2]string{}
		b.Range(func(l labels.Label) {
			rangeOrder.Labels = append(rangeOrder.Labels, [2]string{
				hex.EncodeToString([]byte(l.Name)),
				hex.EncodeToString([]byte(l.Value)),
			})
		})

		e.emit(fmt.Sprintf("b/%d", i),
			builderIn{Base: toLabelsIn(base), Ops: script},
			builderOut{
				Labels:     toLabelsIn(b.Labels()),
				RangeOrder: rangeOrder,
				Gets:       gets,
			})
	}
}

// ------------------------------------------------------------------- matcher

type matcherIn struct {
	Type  int    `json:"type"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type matcherOut struct {
	String     string   `json:"string"`
	TypeString string   `json:"typeString"`
	Matches    []bool   `json:"matches"`
	SetMatches []string `json:"setMatches"`
}

// matcherProbes are the subjects every matcher is evaluated against.
var matcherProbes = []string{"", "a", "b", "ab", "up", "node", "x|y", "A", "0"}

func genMatcher(e *emitter) {
	// Regex values are restricted to literals and literal alternations: Phase 1's
	// matcher deliberately supports only those exactly, and full regex parity
	// arrives with PromRegex in Phase 2. See ADR-6.
	names := []string{"__name__", "job", "a", "with.dot", "with space", "0lead", "", "üñ", "_x", "x9"}
	values := []string{"", "a", "b", "up", "a|b", "a|b|up", "node", "x|y", `q"uote`, "tab\there",
		"a|a", "b|a", "|a", "a|"}
	i := 0
	for _, mt := range []labels.MatchType{
		labels.MatchEqual, labels.MatchNotEqual, labels.MatchRegexp, labels.MatchNotRegexp,
	} {
		for _, n := range names {
			for _, v := range values {
				m, err := labels.NewMatcher(mt, n, v)
				if err != nil {
					continue
				}
				var ms []bool
				for _, p := range matcherProbes {
					ms = append(ms, m.Matches(p))
				}
				sm := m.SetMatches()
				if sm == nil {
					sm = []string{}
				}
				// SetMatches ORDER is not contractual: the slice-backed matcher
				// returns source order, but above
				// minEqualMultiStringMatcherMapThreshold alternates Go switches to a
				// map-backed matcher and iterates it, which is randomized per run.
				// Sort so this fixture is reproducible. Duplicates are preserved,
				// since the slice-backed matcher does return them ("a|a").
				sort.Strings(sm)
				hexed := make([]string, 0, len(sm))
				for _, s := range sm {
					hexed = append(hexed, hex.EncodeToString([]byte(s)))
				}
				e.emit(fmt.Sprintf("m/%d", i),
					matcherIn{
						Type:  int(mt),
						Name:  hex.EncodeToString([]byte(n)),
						Value: hex.EncodeToString([]byte(v)),
					},
					matcherOut{
						String:     m.String(),
						TypeString: mt.String(),
						Matches:    ms,
						SetMatches: hexed,
					})
				i++
			}
		}
	}
}

// --------------------------------------------------- stablehash / om float

func genStableHash(e *emitter) {
	for i, ls := range labelSetCorpus() {
		l := labels.New(ls...)
		e.emit(fmt.Sprintf("sh/%d", i), toLabelsIn(l),
			fmt.Sprintf("%016x", labels.StableHash(l)))
	}
}

func genOpenMetricsFloat(e *emitter) {
	for i, v := range floatCorpus() {
		if i%7 != 0 { // keep the fixture reviewable
			continue
		}
		e.emit(fmt.Sprintf("om/%d", i), floatFormatIn{Bits: fbits(v), Fmt: "g", Prec: -1},
			labels.FormatOpenMetricsFloat(v))
	}
	for i, v := range []float64{
		0, math.Copysign(0, -1), 1, -1, math.NaN(), math.Inf(1), math.Inf(-1),
		2, 10, 100, 1e6, 1e21, 0.5, 1.5,
	} {
		e.emit(fmt.Sprintf("omfix/%d", i), floatFormatIn{Bits: fbits(v), Fmt: "g", Prec: -1},
			labels.FormatOpenMetricsFloat(v))
	}
}
