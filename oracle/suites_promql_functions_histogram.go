package main

// Differential coverage for promql/functions.go's histogram family, through
// `FunctionCalls`. Reuses the wire types of
// oracle/suites_promql_functions_elementwise.go.
//
// ## Why these cases carry an `expr`
//
// The rest of `functions.go` reads only the argument *count*. This family reads the
// arguments themselves:
//
//	histogram_quantile   annotations against args[0] AND args[1] position ranges
//	histogram_quantiles  args[1].(*parser.StringLiteral).Val, and args[0]/args[1] positions
//	histogram_fraction   args[0] and args[2] position ranges
//
// A position range appears in the annotation text, so a placeholder AST would pin
// the wrong string. Each case therefore carries the PromQL call it models; both
// sides parse it and take `Call.Args`, which makes the positions agree by
// construction and exercises the parser-to-evaluator seam at the same time.
//
// ## Why the output samples are sorted
//
// `funcHistogramQuantile` and its siblings finish by ranging
// `enh.signatureToMetricWithBuckets`, a Go **map**. The order of classic-histogram
// results is randomised per run, so there is nothing to be byte-exact against —
// the same situation as `Annotations` (PORTING.md exception 7). The fixture sorts
// by rendered metric, and the port's own insertion order is asserted Swift-side.
// Exception 13.
//
// Annotations are sorted for the same reason: `Annotations` is a map too.
//
// ## What the corpus has to reach
//
//   - the classic/native split, and the conflict that drops BOTH series
//   - an unparseable `le`, which is a warning and a dropped sample
//   - `excludedLabels` — the stored metric loses `le` and the three metadata
//     labels, while the grouping signature loses only `le`
//   - both `enableDelayedNameRemoval` settings, which decide whether the warnings
//     carry a metric name — and, for the forced-monotonicity info, decide it the
//     OTHER way round
//   - non-monotonic classic buckets, so `forcedMonotonic` fires
//   - quantiles outside [0, 1] and NaN, which warn but still produce output
//   - custom-bucket, zero-bucket and negative-bucket histograms, which are
//     `histogramVariance`'s three cases

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
)

// histCustomBuckets is a custom-bucket (NHCB) float histogram, which is
// histogramVariance's arithmetic-mean branch.
func histCustomBuckets() *histogram.FloatHistogram {
	return &histogram.FloatHistogram{
		Schema:          -53,
		Count:           10,
		Sum:             25,
		CustomValues:    []float64{1, 2, 5, 10},
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 4}},
		PositiveBuckets: []float64{2, 3, 4, 1},
	}
}

// histWithZeroAndNegative reaches the two remaining histogramVariance branches:
// the zero bucket, and a bucket whose upper bound is negative (where the geometric
// mean's sign has to be restored).
func histWithZeroAndNegative() *histogram.FloatHistogram {
	return &histogram.FloatHistogram{
		Schema:          0,
		Count:           14,
		Sum:             3.5,
		ZeroThreshold:   0.5,
		ZeroCount:       4,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
		PositiveBuckets: []float64{2, 3, 1},
		NegativeSpans:   []histogram.Span{{Offset: 0, Length: 2}},
		NegativeBuckets: []float64{3, 1},
	}
}

// histEmpty has a zero count, which makes histogram_avg NaN and
// histogram_stdvar a division by zero.
func histEmpty() *histogram.FloatHistogram {
	return &histogram.FloatHistogram{Schema: 0}
}

// histNaNSum has a NaN sum with real buckets, which is what makes
// HistogramQuantile and HistogramFraction emit their *own* annotations
// (NativeHistogramQuantileNaNResultInfo, NaNSkewInfo, FractionNaNsInfo). Without a
// shape that annotates, the position range those are reported against — args[0]
// rather than args[1] — is invisible, and a negative control found exactly that.
func histNaNSum() *histogram.FloatHistogram {
	// Count EXCEEDS the bucket total: two observations were NaN, so they are in
	// Count but in no bucket. That inequality is what both annotations test —
	// `count < rank` for the NaN result and `count < h.Count` for the skew — and a
	// shape whose buckets sum to Count triggers neither.
	return &histogram.FloatHistogram{
		Schema:          0,
		Count:           12,
		Sum:             math.NaN(),
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
		PositiveBuckets: []float64{2, 5, 3},
	}
}

// histGauge and histGauge2 carry CounterResetHint = GaugeType, which is the ONLY
// way irate's not-a-counter warning and idelta's not-a-gauge warning can be told
// apart — every other shape here is a counter, so the two tests looked identical
// until these existed. Two of them, so a case can mix a gauge with a counter and
// reach the `either` half of each condition.
func histGauge() *histogram.FloatHistogram {
	h := genTestHistogram(1).ToFloat(nil)
	h.CounterResetHint = histogram.GaugeType
	return h
}

func histGauge2() *histogram.FloatHistogram {
	h := genTestHistogram(3).ToFloat(nil)
	h.CounterResetHint = histogram.GaugeType
	return h
}

// histNegativeOnly has all its observations below zero, which is the other branch
// of the NaN-skew check.
func histNegativeOnly() *histogram.FloatHistogram {
	return &histogram.FloatHistogram{
		Schema:          0,
		Count:           8,
		Sum:             math.NaN(),
		NegativeSpans:   []histogram.Span{{Offset: 0, Length: 3}},
		NegativeBuckets: []float64{1, 2, 3},
	}
}

// histNonMonotonicBuckets is not a histogram: it is the classic bucket series that
// makes BucketQuantile force monotonicity, spelled as the samples it arrives as.
func classicBuckets(name string, extra []string, counts map[string]float64) []fnSampleIn {
	// Deterministic order: the fixture is regenerated and diffed, so ranging a map
	// here would make it flaky.
	order := []string{"0.1", "0.5", "1", "2.5", "5", "10", "+Inf"}
	out := []fnSampleIn{}
	for _, le := range order {
		c, ok := counts[le]
		if !ok {
			continue
		}
		m := []string{"__name__", name}
		m = append(m, extra...)
		m = append(m, "le", le)
		out = append(out, fnSampleIn{Metric: m, T: "1000", F: fbits(c)})
	}
	return out
}

func genPromQLFunctionsHistogram(e *emitter) {
	n := 0
	emit := func(in fnIn) {
		in.Sorted = true
		if in.Args == nil {
			in.Args = [][]fnSampleIn{}
		}
		for i := range in.Args {
			if in.Args[i] == nil {
				in.Args[i] = []fnSampleIn{}
			}
			for j := range in.Args[i] {
				if in.Args[i][j].Metric == nil {
					in.Args[i][j].Metric = []string{}
				}
			}
		}
		if in.Seed == nil {
			in.Seed = []fnSampleIn{}
		}
		e.emit(fmt.Sprintf("%s/%d", in.Fn, n), in, runFnCase(in))
		n++
	}

	// --- the five direct readers, over every histogram shape plus a float sample
	// (which they skip) and an empty vector.
	histVectors := [][]fnSampleIn{
		{},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "std/0"}},
		{{Metric: []string{"__name__", "h", "job", "j"}, T: "1000", HistRaw: "std/3"}},
		{{Metric: []string{"__name__", "h", "__type__", "histogram", "__unit__", "s"}, T: "1000", HistRaw: "custom"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "zeroneg"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "empty"}},
		{
			{Metric: []string{"__name__", "f"}, T: "1000", F: fbits(2.5)},
			{Metric: []string{"__name__", "h"}, T: "2000", HistRaw: "std/1"},
			{Metric: []string{"__name__", "f2"}, T: "3000", F: fbits(math.NaN())},
		},
		{
			{Metric: []string{"__name__", "a"}, T: "1000", HistRaw: "std/0"},
			{Metric: []string{"__name__", "b"}, T: "1000", HistRaw: "custom"},
			{Metric: []string{"__name__", "c"}, T: "1000", HistRaw: "zeroneg"},
		},
	}
	for _, fn := range []string{
		"histogram_count", "histogram_sum", "histogram_avg",
		"histogram_stddev", "histogram_stdvar",
	} {
		for _, vec := range histVectors {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: fn, Delayed: delayed, Ts: "1500",
					Expr: fn + "(h)",
					Args: [][]fnSampleIn{vec},
				})
			}
		}
	}

	// --- histogram_quantile. The vector argument is second, so the guard is on
	// vectorVals[0] (the quantile) being empty.
	quantiles := []float64{
		0, 0.5, 0.9, 0.95, 1,
		// Outside [0, 1] and NaN: a warning, and output all the same.
		-0.1, 1.1, math.NaN(), math.Inf(1), math.Inf(-1),
	}
	// A classic bucket series, a monotonic one and a non-monotonic one.
	monotonic := classicBuckets("http_request_duration_seconds_bucket", nil, map[string]float64{
		"0.1": 1, "0.5": 3, "1": 6, "2.5": 8, "5": 9, "+Inf": 10,
	})
	nonMonotonic := classicBuckets("http_request_duration_seconds_bucket", nil, map[string]float64{
		"0.1": 5, "0.5": 3, "1": 6, "2.5": 4, "5": 9, "+Inf": 10,
	})
	noInf := classicBuckets("http_request_duration_seconds_bucket", nil, map[string]float64{
		"0.1": 1, "0.5": 3, "1": 6,
	})
	withMetadata := classicBuckets(
		"http_request_duration_seconds_bucket",
		[]string{"__type__", "histogram", "__unit__", "seconds", "job", "j"},
		map[string]float64{"0.1": 1, "1": 6, "+Inf": 10})
	badLe := []fnSampleIn{
		{Metric: []string{"__name__", "hb", "le", "not-a-number"}, T: "1000", F: fbits(1)},
		{Metric: []string{"__name__", "hb", "le", "1"}, T: "1000", F: fbits(2)},
		{Metric: []string{"__name__", "hb", "le", "+Inf"}, T: "1000", F: fbits(3)},
	}
	noLe := []fnSampleIn{
		{Metric: []string{"__name__", "hb"}, T: "1000", F: fbits(1)},
	}
	// A native histogram and a classic series with the SAME labels: the conflict
	// that drops both and warns.
	conflict := append(
		[]fnSampleIn{{Metric: []string{"__name__", "hb"}, T: "1000", HistRaw: "std/2"}},
		classicBuckets("hb", nil, map[string]float64{"0.1": 1, "1": 6, "+Inf": 10})...)
	// A native histogram whose name differs, so there is no conflict.
	noConflict := append(
		[]fnSampleIn{{Metric: []string{"__name__", "other"}, T: "1000", HistRaw: "std/2"}},
		classicBuckets("hb", nil, map[string]float64{"0.1": 1, "1": 6, "+Inf": 10})...)

	quantileVectors := [][]fnSampleIn{
		{},
		monotonic, nonMonotonic, noInf, withMetadata, badLe, noLe, conflict, noConflict,
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "std/3"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "custom"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "empty"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "nansum"}},
		{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "negonly"}},
		{
			{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "nansum"},
			{Metric: []string{"__name__", "h2"}, T: "1000", HistRaw: "negonly"},
		},
	}
	for _, q := range quantiles {
		for _, vec := range quantileVectors {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: "histogram_quantile", Delayed: delayed, Ts: "1500",
					Expr: "histogram_quantile(0.9, http_request_duration_seconds_bucket)",
					Args: [][]fnSampleIn{{{F: fbits(q)}}, vec},
				})
			}
		}
	}
	// The guard: fewer than two arguments, and an empty quantile vector.
	emit(fnIn{
		Fn: "histogram_quantile", Ts: "1500",
		Expr: "histogram_quantile(0.9, http_request_duration_seconds_bucket)",
		Args: [][]fnSampleIn{{}, monotonic},
	})

	// --- histogram_fraction. Three arguments, and the guard rejects an empty
	// BOUND rather than an empty input vector.
	bounds := [][2]float64{
		{0, 0.5}, {0.5, 0}, {math.Inf(-1), 1}, {0, math.Inf(1)},
		{math.Inf(-1), math.Inf(1)}, {math.NaN(), 1}, {0, math.NaN()},
		{0.1, 0.1}, {-1, 1},
	}
	for _, b := range bounds {
		for _, vec := range quantileVectors {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: "histogram_fraction", Delayed: delayed, Ts: "1500",
					Expr: "histogram_fraction(0, 0.5, http_request_duration_seconds_bucket)",
					Args: [][]fnSampleIn{{{F: fbits(b[0])}}, {{F: fbits(b[1])}}, vec},
				})
			}
		}
	}
	emit(fnIn{
		Fn: "histogram_fraction", Ts: "1500",
		Expr: "histogram_fraction(0, 0.5, http_request_duration_seconds_bucket)",
		Args: [][]fnSampleIn{{}, {{F: fbits(1)}}, monotonic},
	})
	emit(fnIn{
		Fn: "histogram_fraction", Ts: "1500",
		Expr: "histogram_fraction(0, 0.5, http_request_duration_seconds_bucket)",
		Args: [][]fnSampleIn{{{F: fbits(0)}}, {}, monotonic},
	})

	// --- histogram_quantiles. The vector is FIRST, the label name second, and the
	// quantiles from the third on — so its argument positions are the odd ones out.
	quantileSets := [][]float64{
		{0.5},
		{0.5, 0.9, 0.99},
		{0, 1},
		{math.NaN(), 0.5},
		{-1, 2},
		// The same quantile twice, which exercises the quantileStrs cache.
		{0.5, 0.5},
	}
	for _, qs := range quantileSets {
		for _, vec := range []([]fnSampleIn){
			monotonic, nonMonotonic, conflict,
			{{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "std/3"}},
			{
				{Metric: []string{"__name__", "h"}, T: "1000", HistRaw: "std/3"},
				{Metric: []string{"__name__", "h2"}, T: "1000", HistRaw: "custom"},
			},
		} {
			for _, delayed := range []bool{false, true} {
				args := [][]fnSampleIn{vec, {}}
				exprArgs := ""
				for _, q := range qs {
					args = append(args, []fnSampleIn{{F: fbits(q)}})
					exprArgs += ", 0.5"
				}
				emit(fnIn{
					Fn: "histogram_quantiles", Delayed: delayed, Ts: "1500",
					Expr: "histogram_quantiles(http_request_duration_seconds_bucket, \"quantile\"" +
						exprArgs + ")",
					Args: args,
				})
			}
		}
	}
}
