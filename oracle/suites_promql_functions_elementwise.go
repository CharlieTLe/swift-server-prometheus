package main

// Differential coverage for promql/functions.go's element-wise arithmetic slice,
// driven through the exported `promql.FunctionCalls` table.
//
// Why this is reachable at all: `FunctionCall` is
// `func([]Vector, Matrix, parser.Expressions, *EvalNodeHelper) (Vector, annotations.Annotations)`
// and every type in it is exported, so the ~100 bodies can be called directly with
// a synthetic helper and no running engine. Nothing in engine.go can be reached
// that way — `evaluator` is unexported — which is why functions.go comes first.
//
// ## The one unexported field, and why it has to be set
//
// `EvalNodeHelper.enableDelayedNameRemoval` is unexported, and it changes the
// result of every function in this file: false makes each body strip the three
// schema metadata labels itself, true leaves them and lets `DropName` carry the
// intent. Both settings are live —
//
//	cmd/prometheus defaults it to FALSE (a feature flag turns it on)
//	promqltest sets it to TRUE (test.go:111), so the exit gate runs with it on
//
// — so pinning only the zero value would leave the port's exit-gate behaviour
// untested. The oracle sets it with `reflect` + `unsafe`, which is contained to
// `setDelayedNameRemoval` below and is test-only infrastructure. The alternative
// was to pin one branch and assert the other Swift-side, i.e. to invent the
// contract instead of reading it.
//
// ## What the corpus is actually testing
//
// The per-value arithmetic of the 26 math wrappers is already pinned by
// `gocompat/{sin,cos,…}` over millions of inputs. What is *not* pinned anywhere
// else, and is what this corpus exists for:
//
//   - the plumbing — that `sin` is wired to Sin and not to Cos. A handful of values
//     per function is enough for that and it is why every wrapper gets the same
//     small value set rather than a big one.
//   - the metric handling: which labels are dropped, under which setting, and that
//     `DropName` is set (and, for `vector`, that it is not).
//   - the histogram skip. Every body here tests `el.H == nil` and drops the sample
//     — except `funcTimestamp`, which reads only `el.T` and so emits one.
//   - `enh.Out`: `funcPi` and `funcTime` return a fresh vector and ignore it;
//     everything else appends. Unreachable from a real query, where the evaluator
//     resets `Out` to empty first (engine.go:1523), but it is exported behaviour
//     and cheap to hold still.
//
// The histogram's *content* is not load-bearing: every reader looks only at
// `H != nil`. One generator value is used throughout, and this comment is the
// reason there is not a family of them.
//
// Floats travel as 16-hex-digit bit patterns: encoding/json refuses NaN, a decimal
// round trip is not bit-exact, and `funcScalar`'s NaN payload is part of the
// contract.

import (
	"fmt"
	"math"
	"reflect"
	"unsafe"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
)

// setDelayedNameRemoval writes EvalNodeHelper's unexported
// `enableDelayedNameRemoval` field. See the file header for why this is worth
// doing rather than pinning half the behaviour.
func setDelayedNameRemoval(enh *promql.EvalNodeHelper, v bool) {
	f := reflect.ValueOf(enh).Elem().FieldByName("enableDelayedNameRemoval")
	reflect.NewAt(f.Type(), unsafe.Pointer(f.UnsafeAddr())).Elem().SetBool(v)
}

// ------------------------------------------------------------------- wire types

type fnSampleIn struct {
	// Flattened label name/value pairs.
	Metric []string `json:"metric"`
	// Int64 as a decimal string.
	T string `json:"t"`
	// Hex bit pattern.
	F string `json:"f"`
	// When non-nil, the sample carries genTestHistogram(n).ToFloat(nil) and F is
	// ignored, exactly as Go ignores it when H != nil.
	Hist *int64 `json:"hist"`
}

type fnIn struct {
	Fn      string `json:"fn"`
	Delayed bool   `json:"delayed"`
	// enh.Ts, Int64 as a decimal string.
	Ts string `json:"ts"`
	// vectorVals: one entry per evaluated argument.
	Args [][]fnSampleIn `json:"args"`
	// len(parser.Expressions) handed to the call. Only funcRound reads it, and it
	// reads the LENGTH rather than the values, which is why nils suffice.
	NArgs int `json:"nargs"`
	// enh.Out seeded non-empty, to pin which bodies append to it and which ignore
	// it. Empty in every case that models a real query.
	Seed []fnSampleIn `json:"seed"`
}

type fnSampleOut struct {
	Metric string `json:"metric"`
	T      string `json:"t"`
	F      string `json:"f"`
	// The FloatHistogram's String(), or "" when the sample carries none. Always ""
	// in this slice — no body here emits a histogram — so a port that passes one
	// through fails here.
	Hist     string `json:"hist"`
	DropName bool   `json:"dropName"`
}

type fnOut struct {
	Samples []fnSampleOut `json:"samples"`
	// Always empty in this slice: every body returns nil annotations. Emitted so a
	// port that invents one fails.
	Annos []string `json:"annos"`
}

// --------------------------------------------------------------------- helpers

func fnBuildVector(in []fnSampleIn) promql.Vector {
	out := make(promql.Vector, 0, len(in))
	for _, s := range in {
		smp := promql.Sample{
			T:      parseI64(s.T),
			Metric: labels.FromStrings(s.Metric...),
		}
		if s.Hist != nil {
			smp.H = genTestHistogram(*s.Hist).ToFloat(nil)
		} else {
			smp.F = unfbits(s.F)
		}
		out = append(out, smp)
	}
	return out
}

func fnRenderVector(v promql.Vector) []fnSampleOut {
	out := make([]fnSampleOut, 0, len(v))
	for _, s := range v {
		hist := ""
		if s.H != nil {
			hist = s.H.String()
		}
		out = append(out, fnSampleOut{
			Metric:   s.Metric.String(),
			T:        i64(s.T),
			F:        fbits(s.F),
			Hist:     hist,
			DropName: s.DropName,
		})
	}
	return out
}

func runFnCase(in fnIn) fnOut {
	fn, ok := promql.FunctionCalls[in.Fn]
	if !ok {
		panic("no FunctionCalls entry for " + in.Fn)
	}
	vectorVals := make([]promql.Vector, 0, len(in.Args))
	for _, a := range in.Args {
		vectorVals = append(vectorVals, fnBuildVector(a))
	}
	enh := &promql.EvalNodeHelper{Ts: parseI64(in.Ts), Out: fnBuildVector(in.Seed)}
	setDelayedNameRemoval(enh, in.Delayed)

	args := make(parser.Expressions, in.NArgs)
	got, annos := fn(vectorVals, nil, args, enh)

	strs, _ := annos.AsStrings("", 0, 0)
	if strs == nil {
		strs = []string{}
	}
	return fnOut{Samples: fnRenderVector(got), Annos: strs}
}

// -------------------------------------------------------------------- corpora

// fnMetrics are the label sets every function is exercised with. The fourth is the
// one that matters most: it carries all three schema metadata labels, so the
// `delayed` axis is visible in the output rather than implied.
func fnMetrics() [][]string {
	return [][]string{
		{},
		{"__name__", "foo"},
		{"__name__", "foo", "job", "j"},
		{"__name__", "foo", "__type__", "counter", "__unit__", "seconds", "job", "j"},
		{"__type__", "gauge"},
		{"__unit__", "bytes", "le", "0.5"},
		{"job", "j", "instance", "i"},
	}
}

// fnValues is the shared value set. Small on purpose — the arithmetic is pinned by
// gocompat/*; this is here to catch a wrapper wired to the wrong function, so it
// needs values where the 26 functions actually disagree, plus the specials whose
// handling differs between them.
func fnValues() []float64 {
	out := []float64{
		0, math.Copysign(0, -1),
		1, -1, 0.5, -0.5, 2, -2, 21.5, 0.625,
		math.NaN(), math.Inf(1), math.Inf(-1),
		1e-9, 1e300, -1e300,
	}
	// Harvested witnesses: one per wrapper where **Swift's libm disagrees with Go**
	// for that function. Without them the corpus passes with `funcExp` delegating to
	// libm's `exp` — a negative control found exactly that — because none of the
	// round numbers above happens to be a value where the two differ. So these are
	// what make "this wrapper is wired to GoMath, not to the platform" a tested
	// claim rather than a comment.
	//
	// Several witness more than one function; 0x3ffa6d48991d5506 alone covers nine.
	// Listed per function anyway, so a future wrapper can be checked off by name.
	for _, b := range []uint64{
		0x3ffa6d48991d5506, // exp, log10, sin, cos, tan, sinh (and asin/acos/atanh out of domain)
		0x400565a5e47919fd, // ln
		0x40026d48991d5506, // log2
		0x3fe54d119c20199a, // asin
		0xbfe4eacf7091ecd3, // acos
		0x3ffff39a6a302667, // atan
		0x3fe4da91323aaa0c, // cosh
		0x3ff031d896be34ca, // tanh
		0x3ffd4ed9b6db6f60, // asinh
		0x3ffaa688ce100ccd, // acosh
		0x3feecb9410870643, // atanh
	} {
		out = append(out, math.Float64frombits(b))
	}
	return out
}

// fnElementwiseNames are the functions that go through simpleFloatFunc unchanged:
// one argument, no extra parameters, no state.
func fnElementwiseNames() []string {
	return []string{
		"abs", "ceil", "floor", "exp", "sqrt", "ln", "log2", "log10",
		"sin", "cos", "tan", "asin", "acos", "atan",
		"sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
		"rad", "deg", "sgn",
	}
}

func genPromQLFunctionsElementwise(e *emitter) {
	histN := int64(3)
	n := 0
	// Normalise before emitting: a nil Go slice marshals as JSON null, and a
	// fixture that says `null` where it means "no labels" is one more thing a
	// reader has to know. Every scalar argument below is written as `{F: …}` with
	// no Metric, so this fires often.
	normalise := func(in fnIn) fnIn {
		fix := func(ss []fnSampleIn) []fnSampleIn {
			if ss == nil {
				return []fnSampleIn{}
			}
			for i := range ss {
				if ss[i].Metric == nil {
					ss[i].Metric = []string{}
				}
			}
			return ss
		}
		if in.Args == nil {
			in.Args = [][]fnSampleIn{}
		}
		for i := range in.Args {
			in.Args[i] = fix(in.Args[i])
		}
		in.Seed = fix(in.Seed)
		return in
	}
	emit := func(in fnIn) {
		in = normalise(in)
		e.emit(fmt.Sprintf("%s/%d", in.Fn, n), in, runFnCase(in))
		n++
	}

	// --- the 23 single-argument wrappers, over every value and both settings.
	//
	// One metric per value rather than the cross product: the metric handling is
	// identical across these 23 (they all go through simpleFloatFunc), so the cross
	// product would multiply the fixture by seven for no new information. The full
	// metric set is exercised below on `abs`, which stands in for all of them.
	for _, fn := range fnElementwiseNames() {
		for _, delayed := range []bool{false, true} {
			samples := make([]fnSampleIn, 0, len(fnValues()))
			for i, v := range fnValues() {
				samples = append(samples, fnSampleIn{
					Metric: fnMetrics()[i%len(fnMetrics())],
					T:      i64(int64(i) * 1000),
					F:      fbits(v),
				})
			}
			emit(fnIn{Fn: fn, Delayed: delayed, Ts: "1500", Args: [][]fnSampleIn{samples}})
		}
	}

	// --- the metric cross product, on `abs`. Every label set against both
	// settings, one sample per case so a failure names the label set.
	for _, m := range fnMetrics() {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "abs", Delayed: delayed, Ts: "1500",
				Args: [][]fnSampleIn{{{Metric: m, T: "7000", F: fbits(-2.5)}}},
			})
		}
	}

	// --- the histogram skip, and mixed vectors. Every one-argument function here
	// drops histogram samples; `timestamp` does not, which is the point of running
	// it through the same shapes.
	mixed := [][]fnSampleIn{
		{{Metric: fnMetrics()[3], T: "1000", Hist: &histN}},
		{
			{Metric: fnMetrics()[3], T: "1000", Hist: &histN},
			{Metric: fnMetrics()[2], T: "2000", F: fbits(4)},
		},
		{
			{Metric: fnMetrics()[2], T: "1000", F: fbits(4)},
			{Metric: fnMetrics()[3], T: "2000", Hist: &histN},
			{Metric: fnMetrics()[1], T: "3000", F: fbits(-4)},
		},
		{}, // the empty vector
	}
	for _, fn := range []string{"abs", "sqrt", "sgn", "timestamp", "clamp_min", "round", "scalar"} {
		for _, args := range mixed {
			for _, delayed := range []bool{false, true} {
				in := fnIn{Fn: fn, Delayed: delayed, Ts: "1500", Args: [][]fnSampleIn{args}}
				// The two-argument shapes need their scalar.
				switch fn {
				case "clamp_min":
					in.Args = append(in.Args, []fnSampleIn{{F: fbits(0)}})
				case "round":
					in.Args = append(in.Args, []fnSampleIn{{F: fbits(1)}})
					in.NArgs = 2
				}
				emit(in)
			}
		}
	}

	// --- timestamp, on its own, across timestamps that are not whole seconds.
	for _, t := range []int64{0, 1, -1, 999, 1000, 1500, -1500, 1234567891011, math.MaxInt64, math.MinInt64} {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "timestamp", Delayed: delayed, Ts: "1500",
				Args: [][]fnSampleIn{{{Metric: fnMetrics()[3], T: i64(t), F: fbits(1)}}},
			})
		}
	}

	// --- time, over the same timestamps. Reads enh.Ts, not the samples.
	for _, ts := range []int64{0, 1, -1, 999, 1000, 1500, -1500, 1234567891011, math.MaxInt64, math.MinInt64} {
		emit(fnIn{Fn: "time", Ts: i64(ts), Args: [][]fnSampleIn{{}}})
	}

	// --- pi, which reads nothing at all.
	emit(fnIn{Fn: "pi", Ts: "1500", Args: [][]fnSampleIn{}})

	// --- scalar. The `found` logic is the whole function: zero floats, one float,
	// two floats, and one float among histograms.
	scalarArgs := [][]fnSampleIn{
		{},
		{{Metric: fnMetrics()[2], T: "1000", F: fbits(42)}},
		{{Metric: fnMetrics()[2], T: "1000", F: fbits(42)}, {Metric: fnMetrics()[1], T: "2000", F: fbits(7)}},
		{{Metric: fnMetrics()[3], T: "1000", Hist: &histN}, {Metric: fnMetrics()[2], T: "2000", F: fbits(42)}},
		{{Metric: fnMetrics()[3], T: "1000", Hist: &histN}},
		{{Metric: fnMetrics()[3], T: "1000", Hist: &histN}, {Metric: fnMetrics()[3], T: "2000", Hist: &histN}},
		// Three floats: the early return fires on the second, so the third is never
		// looked at. A port that counts first and decides after gets the same answer
		// here, which is why the two-float case above matters more.
		{
			{Metric: fnMetrics()[2], T: "1000", F: fbits(1)},
			{Metric: fnMetrics()[2], T: "2000", F: fbits(2)},
			{Metric: fnMetrics()[2], T: "3000", F: fbits(3)},
		},
		// A single NaN float, so the returned NaN is the SAMPLE's rather than Go's.
		{{Metric: fnMetrics()[2], T: "1000", F: fbits(math.NaN())}},
		// And a NaN with a payload no arithmetic would produce, which is how the
		// difference between "the value" and "math.NaN()" becomes visible.
		{{Metric: fnMetrics()[2], T: "1000", F: "7ff80000deadbeef"}},
	}
	for _, args := range scalarArgs {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{Fn: "scalar", Delayed: delayed, Ts: "1500", Args: [][]fnSampleIn{args}})
		}
	}

	// --- vector. Note DropName is false and the metric is the zero Labels, unlike
	// every other function here.
	for _, v := range fnValues() {
		emit(fnIn{
			Fn: "vector", Ts: "1500",
			Args: [][]fnSampleIn{{{Metric: fnMetrics()[3], T: "9000", F: fbits(v)}}},
		})
	}

	// --- max_of / min_of, which are math.Max/math.Min and therefore arm64
	// assembly: the ±Inf check runs before NaN handling, and FMAXD propagates NaN
	// where libm's fmax suppresses it. The operand order decides whose payload
	// survives, so every pair is emitted both ways round.
	pairs := [][2]float64{
		{1, 2}, {2, 1}, {0, math.Copysign(0, -1)}, {math.Copysign(0, -1), 0},
		{math.NaN(), 1}, {1, math.NaN()},
		{math.Inf(1), math.NaN()}, {math.NaN(), math.Inf(1)},
		{math.Inf(-1), math.NaN()}, {math.NaN(), math.Inf(-1)},
		{math.Inf(1), math.Inf(-1)}, {math.Inf(-1), math.Inf(1)},
		{math.NaN(), math.NaN()},
		{math.Float64frombits(0x7ff80000deadbeef), math.Float64frombits(0x7ff8000000000001)},
		{math.Float64frombits(0x7ff8000000000001), math.Float64frombits(0x7ff80000deadbeef)},
		{-1e300, 1e300}, {1e-300, -1e-300},
	}
	for _, fn := range []string{"max_of", "min_of"} {
		for _, p := range pairs {
			emit(fnIn{
				Fn: fn, Ts: "1500",
				Args: [][]fnSampleIn{
					{{F: fbits(p[0])}},
					{{F: fbits(p[1])}},
				},
			})
		}
	}

	// --- clamp. The inverted range, the degenerate equal range, and NaN in each of
	// the three positions.
	clampBounds := [][2]float64{
		{0, 1}, {1, 0}, {1, 1}, {-1, 1},
		{math.Inf(-1), math.Inf(1)}, {math.Inf(1), math.Inf(-1)},
		{math.NaN(), 1}, {0, math.NaN()}, {math.NaN(), math.NaN()},
		{0, math.Copysign(0, -1)}, {math.Copysign(0, -1), 0},
		// NaN bounds with payloads DISTINCT from the sample's, which is what makes
		// math.Max's and math.Min's operand order observable: FMAXD/FMIND decide
		// whose payload survives when both operands are NaN, and with one payload
		// throughout, swapping the operands changes nothing. A negative control
		// found the first corpus green with `Max(Min(f, max), min)` substituted for
		// `Max(min, Min(max, f))`, which is why these three are here.
		{math.Float64frombits(0x7ff80000cafef00d), 1},
		{0, math.Float64frombits(0x7ff80000cafef00d)},
		{math.Float64frombits(0x7ff80000cafef00d), math.Float64frombits(0x7ff8000000000001)},
		{math.Float64frombits(0x7ff8000000000001), math.Float64frombits(0x7ff80000cafef00d)},
	}
	clampValues := []fnSampleIn{
		{Metric: fnMetrics()[3], T: "1000", F: fbits(-5)},
		{Metric: fnMetrics()[2], T: "2000", F: fbits(0.5)},
		{Metric: fnMetrics()[1], T: "3000", F: fbits(5)},
		{Metric: fnMetrics()[0], T: "4000", F: fbits(math.NaN())},
		{Metric: fnMetrics()[4], T: "5000", F: fbits(math.Inf(1))},
		{Metric: fnMetrics()[5], T: "6000", F: fbits(math.Inf(-1))},
		{Metric: fnMetrics()[6], T: "7000", Hist: &histN},
		// A NaN sample whose payload is neither Go's nor any bound's.
		{Metric: fnMetrics()[1], T: "8000", F: "7ff80000deadbeef"},
	}
	for _, b := range clampBounds {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "clamp", Delayed: delayed, Ts: "1500",
				Args: [][]fnSampleIn{
					clampValues,
					{{F: fbits(b[0])}},
					{{F: fbits(b[1])}},
				},
			})
		}
	}
	// clamp_min and clamp_max, whose missing bound is a hard-coded infinity.
	for _, fn := range []string{"clamp_min", "clamp_max"} {
		for _, b := range []float64{0, 1, -1, math.NaN(), math.Inf(1), math.Inf(-1), math.Copysign(0, -1)} {
			emit(fnIn{
				Fn: fn, Ts: "1500",
				Args: [][]fnSampleIn{clampValues, {{F: fbits(b)}}},
			})
		}
	}

	// --- round. `toNearest` defaults to 1 and is read only when len(args) >= 2, so
	// the NArgs axis is behavioural rather than cosmetic: the same vectorVals with
	// NArgs 1 and 2 give different answers.
	roundValues := []fnSampleIn{
		{Metric: fnMetrics()[3], T: "1000", F: fbits(2.5)},
		{Metric: fnMetrics()[3], T: "1000", F: fbits(-2.5)},
		{Metric: fnMetrics()[3], T: "1000", F: fbits(2.4999999999999996)},
		{Metric: fnMetrics()[2], T: "2000", F: fbits(1.5)},
		{Metric: fnMetrics()[2], T: "2000", F: fbits(0.5)},
		{Metric: fnMetrics()[2], T: "2000", F: fbits(-0.5)},
		{Metric: fnMetrics()[1], T: "3000", F: fbits(123.456)},
		{Metric: fnMetrics()[1], T: "3000", F: fbits(-123.456)},
		{Metric: fnMetrics()[0], T: "4000", F: fbits(math.NaN())},
		{Metric: fnMetrics()[0], T: "4000", F: fbits(math.Inf(1))},
		{Metric: fnMetrics()[0], T: "4000", F: fbits(math.Inf(-1))},
		{Metric: fnMetrics()[4], T: "5000", F: fbits(0)},
		{Metric: fnMetrics()[4], T: "5000", F: fbits(math.Copysign(0, -1))},
		{Metric: fnMetrics()[5], T: "6000", F: fbits(1e300)},
		{Metric: fnMetrics()[5], T: "6000", F: fbits(1e-300)},
	}
	// The default: two vectorVals present but NArgs 1, so toNearest stays 1 and the
	// second argument is ignored. That is exactly the shape a `round(x)` call makes.
	emit(fnIn{
		Fn: "round", Ts: "1500", NArgs: 1,
		Args: [][]fnSampleIn{roundValues, {{F: fbits(0.001)}}},
	})
	for _, tn := range []float64{
		1, 0.1, 0.5, 5, 100, -1, -0.1, 0,
		math.NaN(), math.Inf(1), math.Inf(-1),
		1e-3, 1e300, 3, 7,
		// Where the inversion loses precision: 1/toNearest is inexact, which is the
		// whole reason upstream inverts and the reason the fused multiply-add is
		// observable.
		0.3, 0.7, 1.0 / 3.0,
	} {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "round", Delayed: delayed, Ts: "1500", NArgs: 2,
				Args: [][]fnSampleIn{roundValues, {{F: fbits(tn)}}},
			})
		}
	}

	// --- a non-empty enh.Out. Unreachable from a real query — engine.go:1523
	// resets it first — but it is the only thing that distinguishes `pi`/`time`,
	// which return a fresh vector, from everything else, which appends.
	seed := []fnSampleIn{
		{Metric: fnMetrics()[6], T: "111", F: fbits(-99)},
		{Metric: fnMetrics()[1], T: "222", F: fbits(-98)},
	}
	for _, fn := range []string{
		"abs", "sgn", "timestamp", "scalar", "vector", "clamp", "round",
		"max_of", "min_of", "pi", "time",
	} {
		in := fnIn{
			Fn: fn, Ts: "1500", Seed: seed,
			Args: [][]fnSampleIn{{{Metric: fnMetrics()[2], T: "1000", F: fbits(3.25)}}},
		}
		switch fn {
		case "clamp":
			in.Args = append(in.Args, []fnSampleIn{{F: fbits(0)}}, []fnSampleIn{{F: fbits(1)}})
		case "round":
			in.Args = append(in.Args, []fnSampleIn{{F: fbits(0.5)}})
			in.NArgs = 2
		case "max_of", "min_of":
			in.Args = append(in.Args, []fnSampleIn{{F: fbits(9)}})
		}
		emit(in)
	}
}

// --------------------------------------------------- promql/functioncallnames

func genPromQLFunctionCallNames(e *emitter) {
	// The full key set of FunctionCalls as a single case, so a function upstream
	// adds — or one the port invents — fails rather than going unchecked. Its own
	// suite because the shape differs from the per-call one, and separate from
	// `promql/functionnames` (which is `parser.Functions`) because the two lists are
	// not the same: the parser knows about functions the evaluator has no entry for.
	names := make([]string, 0, len(promql.FunctionCalls))
	for name := range promql.FunctionCalls {
		names = append(names, name)
	}
	sortStrings(names)
	e.emit("names", "", names)
}
