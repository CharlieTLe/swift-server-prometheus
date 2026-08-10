package main

// Differential coverage for promql/functions.go's float-only range aggregations,
// through `FunctionCalls`. Reuses the wire types of
// oracle/suites_promql_functions_elementwise.go, with its `matrix` field.
//
// ## What has to be reached
//
// The interesting behaviour of this family is almost entirely in its *guards*, not
// its arithmetic:
//
//   - an empty matrix, which yields nothing
//   - a float-only range, a histogram-only range and a MIXED one. The three behave
//     differently and not symmetrically: histogram-only yields nothing from
//     `max_over_time` **without** an annotation, while mixed yields the float answer
//     **with** a HistogramIgnoredInMixedRangeInfo
//   - a series with neither floats nor histograms, which `ts_of_first_over_time`
//     answers with MaxInt64/1000 and `ts_of_last_over_time` with 0 — the two
//     defaults are asymmetric
//   - equal timestamps across the float and histogram lists, where `first_over_time`
//     and `last_over_time` both prefer the HISTOGRAM
//   - a MULTI-SERIES matrix. `rangeEval` never produces one, so only the oracle can;
//     it is here because a port that looped over the matrix instead of reading
//     `matrixVal[0]` would be wrong nowhere else.
//
// ## NaN placement is the whole story for max/min
//
// `compareFn` is `(cur > maxVal) || IsNaN(maxVal)`, so a NaN running value is always
// replaced but a NaN *candidate* never wins. Leading NaNs are therefore skipped and
// trailing ones ignored, and the result is NaN only when every sample is. The corpus
// puts NaN first, last, in the middle, and everywhere.
//
// And `ts_of_max_over_time` uses `>=` where `max_over_time` uses `>`, so the two
// disagree about which of several equal maxima is reported — first versus last. Every
// plateau case below exists for that.

import (
	"fmt"
	"math"
)

// otSeries builds one series' worth of samples: `metric` plus alternating
// timestamp/value pairs, with a nil value meaning "a histogram here instead".
func otSeries(metric []string, points []otPoint) []fnSampleIn {
	out := make([]fnSampleIn, 0, len(points))
	for _, p := range points {
		s := fnSampleIn{Metric: metric, T: i64(p.t)}
		if p.hist != "" {
			s.HistRaw = p.hist
		} else {
			s.F = fbits(p.f)
		}
		out = append(out, s)
	}
	return out
}

// otSeriesRun builds `n` samples at `base + i*step`, one second apart. A long run at
// a large base is what makes the Kahan compensation observable.
func otSeriesRun(metric []string, base float64, n int, step float64) []fnSampleIn {
	pts := make([]otPoint, 0, n)
	for i := 0; i < n; i++ {
		pts = append(pts, otPoint{t: int64(i+1) * 1000, f: base + float64(i)*step})
	}
	return otSeries(metric, pts)
}

// otSeriesAlternating alternates a large and a small value, which is the case a
// naive running sum loses entirely.
func otSeriesAlternating(metric []string, big, small float64, n int) []fnSampleIn {
	pts := make([]otPoint, 0, n)
	for i := 0; i < n; i++ {
		v := small
		if i%2 == 0 {
			v = big
		}
		pts = append(pts, otPoint{t: int64(i+1) * 1000, f: v})
	}
	return otSeries(metric, pts)
}

type otPoint struct {
	t    int64
	f    float64
	hist string
}

func genPromQLFunctionsOverTime(e *emitter) {
	names := []string{
		"count_over_time", "present_over_time", "absent_over_time",
		"first_over_time", "last_over_time",
		"ts_of_first_over_time", "ts_of_last_over_time",
		"max_over_time", "min_over_time",
		"ts_of_max_over_time", "ts_of_min_over_time",
		"stddev_over_time", "stdvar_over_time",
	}

	metric := []string{"__name__", "http_requests_total", "job", "j"}
	withMetadata := []string{
		"__name__", "http_requests_total", "__type__", "counter", "__unit__", "seconds",
		"job", "j",
	}

	matrices := [][][]fnSampleIn{
		// No series at all.
		{},
		// One empty series: no floats, no histograms. The ts_of_* defaults diverge here.
		{otSeries(metric, nil)},
		// Ordinary ascending floats.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: 2}, {t: 3000, f: 3}})},
		// Descending, so max is first and min is last.
		{otSeries(metric, []otPoint{{t: 1000, f: 3}, {t: 2000, f: 2}, {t: 3000, f: 1}})},
		// A single sample.
		{otSeries(metric, []otPoint{{t: 5000, f: 42}})},
		// A plateau: three equal maxima, which is where `>` and `>=` disagree.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 7}, {t: 3000, f: 7}, {t: 4000, f: 7}, {t: 5000, f: 2},
		})},
		// NaN first, so the running value starts NaN and must be replaced.
		{otSeries(metric, []otPoint{{t: 1000, f: math.NaN()}, {t: 2000, f: 2}, {t: 3000, f: 1}})},
		// NaN last, which must NOT be adopted.
		{otSeries(metric, []otPoint{{t: 1000, f: 2}, {t: 2000, f: 1}, {t: 3000, f: math.NaN()}})},
		// NaN in the middle.
		{otSeries(metric, []otPoint{{t: 1000, f: 2}, {t: 2000, f: math.NaN()}, {t: 3000, f: 5}})},
		// Every sample NaN, the only way the result is NaN.
		{otSeries(metric, []otPoint{{t: 1000, f: math.NaN()}, {t: 2000, f: math.NaN()}})},
		// Infinities, and a mix with finite values.
		{otSeries(metric, []otPoint{
			{t: 1000, f: math.Inf(-1)}, {t: 2000, f: 0}, {t: 3000, f: math.Inf(1)},
		})},
		// Signed zeros, where `>` cannot tell them apart but the timestamps can.
		{otSeries(metric, []otPoint{{t: 1000, f: math.Copysign(0, -1)}, {t: 2000, f: 0}})},
		// Values whose variance needs the Kahan compensation to come out right: a
		// large offset with small deviations is the classic catastrophic-cancellation
		// case for a naive sum-of-squares.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1e8 + 4}, {t: 2000, f: 1e8 + 7}, {t: 3000, f: 1e8 + 13},
			{t: 4000, f: 1e8 + 16},
		})},
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1e15 + 1}, {t: 2000, f: 1e15 + 2}, {t: 3000, f: 1e15 + 3},
		})},
		// The Kahan compensation terms have to be NON-NEGLIGIBLE for varianceOverTime's
		// shape to be pinned at all: four negative controls — dropping the aux
		// compensation, taking delta against the uncompensated mean in either place,
		// and turning `delta/count` into `delta*(1/count)` — all passed until these
		// series existed. What makes them bite is a long run at a large offset, where
		// the running mean accumulates rounding that `cMean` is carrying, plus a count
		// whose reciprocal is inexact.
		{otSeriesRun(metric, 1e16, 50, 1)},
		{otSeriesRun(metric, 1e16, 7, 3)},
		{otSeriesRun(metric, 1e10, 101, 7)},
		{otSeriesRun(metric, 0, 7, 1.0/3.0)},
		{otSeriesRun(metric, 1e300, 9, 1e290)},
		// Alternating large and small, which is where a naive sum loses the small ones
		// entirely and the compensation is the only thing keeping them.
		{otSeriesAlternating(metric, 1e17, 1, 21)},
		// A wide dynamic range, where the order of accumulation matters.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1e300}, {t: 2000, f: 1}, {t: 3000, f: -1e300}, {t: 4000, f: 1},
		})},
		// Histogram-only: nothing at all from max/min, and no annotation.
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/0"}, {t: 2000, hist: "std/1"}})},
		// Mixed, floats first: the annotation fires and the floats are used.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 5}, {t: 2000, f: 3}, {t: 3000, hist: "std/1"},
		})},
		// Mixed with the metadata labels, so the annotation's metric name is visible.
		{otSeries(withMetadata, []otPoint{
			{t: 1000, f: 5}, {t: 2000, hist: "std/1"},
		})},
		// A histogram EARLIER than every float, which changes first_over_time.
		{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/2"}, {t: 2000, f: 5}, {t: 3000, f: 3},
		})},
		// A histogram LATER than every float, which changes last_over_time.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 5}, {t: 2000, f: 3}, {t: 9000, hist: "std/2"},
		})},
		// EQUAL timestamps in both lists: the histogram wins, both ends.
		{otSeries(metric, []otPoint{{t: 1000, f: 5}, {t: 1000, hist: "std/2"}})},
		// Two series. rangeEval never produces this; a port that loops is wrong only
		// here.
		{
			otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: 2}}),
			otSeries([]string{"__name__", "other"}, []otPoint{{t: 1000, f: 100}}),
		},
		// A series whose only float is at the same timestamp as its only histogram,
		// with the histogram list longer.
		{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/0"}, {t: 1000, f: 5}, {t: 2000, hist: "std/1"},
		})},
		// Negative and zero timestamps, and one at the Int64 extremes, which the
		// ts_of_* division by 1000 has to survive.
		{otSeries(metric, []otPoint{{t: -3000, f: 1}, {t: 0, f: 2}, {t: 3000, f: 3}})},
		{otSeries(metric, []otPoint{{t: math.MinInt64, f: 1}, {t: math.MaxInt64, f: 2}})},
	}

	n := 0
	emit := func(in fnIn) {
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
		for i := range in.MatrixIn {
			for j := range in.MatrixIn[i] {
				if in.MatrixIn[i][j].Metric == nil {
					in.MatrixIn[i][j].Metric = []string{}
				}
			}
		}
		if in.Seed == nil {
			in.Seed = []fnSampleIn{}
		}
		e.emit(fmt.Sprintf("%s/%d", in.Fn, n), in, runFnCase(in))
		n++
	}

	// quantile_over_time and mad_over_time both go through `promql.quantile`, whose
	// comparator is not a strict weak ordering: `Less` returns true for a NaN left
	// operand unconditionally, so NaN compares less than itself and `sort.Sort`'s
	// result is UNSPECIFIED with two or more NaNs. Those matrices are therefore
	// excluded from these two functions rather than pinned — Go has no answer to be
	// exact against. PORTING.md exception 5's reasoning, applied to a sort.
	multiNaN := map[int]bool{}
	for i, m := range matrices {
		if len(m) == 0 {
			continue
		}
		nans := 0
		for _, smp := range m[0] {
			if smp.HistRaw == "" && math.IsNaN(unfbits(smp.F)) {
				nans++
			}
		}
		if nans > 1 {
			multiNaN[i] = true
		}
	}

	quantiles := []float64{
		0, 0.25, 0.5, 0.9, 1,
		// Out of range and NaN: a warning, and a result all the same.
		-0.1, 1.1, math.NaN(), math.Inf(1), math.Inf(-1),
	}
	for _, q := range quantiles {
		for i, m := range matrices {
			if multiNaN[i] {
				continue
			}
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: "quantile_over_time", Delayed: delayed, Ts: "1500",
					Expr:     "quantile_over_time(0.5, http_requests_total[5m])",
					Args:     [][]fnSampleIn{{{F: fbits(q)}}},
					MatrixIn: m,
				})
			}
		}
	}
	// The guard: no scalar argument at all, and an empty one.
	emit(fnIn{
		Fn: "quantile_over_time", Ts: "1500",
		Expr:     "quantile_over_time(0.5, http_requests_total[5m])",
		Args:     [][]fnSampleIn{{}},
		MatrixIn: matrices[2],
	})

	for i, m := range matrices {
		if multiNaN[i] {
			continue
		}
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "mad_over_time", Delayed: delayed, Ts: "1500",
				Expr:     "mad_over_time(http_requests_total[5m])",
				Args:     [][]fnSampleIn{},
				MatrixIn: m,
			})
		}
	}

	// --- deriv, predict_linear and double_exponential_smoothing.
	//
	// `linearRegression`'s constant-series short-circuit is the interesting part: an
	// exactly flat series returns (0, initY) without touching the sums, and a flat
	// INFINITE series returns (NaN, NaN). Both are in `regressionMatrices` below,
	// along with series long and large enough for the four Kahan accumulators to
	// carry a non-negligible compensation — the lesson from varianceOverTime.
	regressionMatrices := [][][]fnSampleIn{
		{},
		{otSeries(metric, nil)},
		// Fewer than two floats: nothing, and the ONE-float-plus-histogram case
		// annotates where the zero-float case is silent.
		{otSeries(metric, []otPoint{{t: 1000, f: 5}})},
		{otSeries(metric, []otPoint{{t: 1000, f: 5}, {t: 2000, hist: "std/1"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}})},
		// A clean straight line, where the slope is exact.
		{otSeriesRun(metric, 0, 10, 2)},
		// Flat: the constY short-circuit.
		{otSeriesRun(metric, 7, 10, 0)},
		// Flat and infinite: (NaN, NaN).
		{otSeries(metric, []otPoint{
			{t: 1000, f: math.Inf(1)}, {t: 2000, f: math.Inf(1)}, {t: 3000, f: math.Inf(1)},
		})},
		{otSeries(metric, []otPoint{
			{t: 1000, f: math.Inf(-1)}, {t: 2000, f: math.Inf(-1)},
		})},
		// Flat except for the LAST sample, so constY is cleared late.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 3}, {t: 2000, f: 3}, {t: 3000, f: 3}, {t: 4000, f: 4},
		})},
		// Descending, and non-monotonic.
		{otSeriesRun(metric, 100, 8, -3)},
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 9}, {t: 3000, f: 2}, {t: 4000, f: 8},
			{t: 5000, f: 3},
		})},
		// Long runs at large magnitude: the Kahan compensation in all four sums.
		{otSeriesRun(metric, 1e15, 60, 1)},
		{otSeriesRun(metric, 1e10, 101, 7)},
		{otSeriesAlternating(metric, 1e17, 1, 21)},
		// NaN, which propagates through the sums.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: math.NaN()}, {t: 3000, f: 3}})},
		// Sub-second spacing, so `x` keeps its fractional part.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 1001, f: 2}, {t: 1002, f: 4}})},
		// Negative timestamps, and a span wide enough that the interceptTime choice
		// matters.
		{otSeries(metric, []otPoint{{t: -5000, f: 1}, {t: 0, f: 2}, {t: 5000, f: 4}})},
		{otSeries(metric, []otPoint{{t: 1_700_000_000_000, f: 1}, {t: 1_700_000_060_000, f: 2}})},
		// Mixed, so the annotation fires alongside a real answer.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 3}, {t: 3000, hist: "std/1"},
		})},
		{otSeries(withMetadata, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 3}, {t: 3000, hist: "std/1"},
		})},
		// `varX := sumX2 - sumX*sumX/n` is catastrophic cancellation when the x values
		// are nearly equal — a tight cluster of samples FAR from interceptTime, which
		// only predict_linear can produce because its interceptTime is enh.Ts. Without
		// this, hoisting `1/n` out of that one expression was invisible while the same
		// change to covXY was caught.
		{otSeries(metric, []otPoint{
			{t: 1_700_000_000_000, f: 1}, {t: 1_700_000_000_001, f: 2},
			{t: 1_700_000_000_002, f: 4}, {t: 1_700_000_000_003, f: 7},
			{t: 1_700_000_000_004, f: 11},
		})},
		{otSeries(metric, []otPoint{
			{t: 1_700_000_000_000, f: 1e9 + 1}, {t: 1_700_000_000_007, f: 1e9 + 3},
			{t: 1_700_000_000_013, f: 1e9 + 2}, {t: 1_700_000_000_029, f: 1e9 + 9},
		})},
		// Values with no exact binary representation and a wide dynamic range, which is
		// what makes calcTrendValue's fused `tf*(s1-s0) + (1-tf)*b` observable: with
		// tidy inputs both products are exact and the fusion cannot be seen.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 0.1}, {t: 2000, f: 0.3}, {t: 3000, f: 0.7},
			{t: 4000, f: 1.0 / 3.0}, {t: 5000, f: 1e8 + 0.7}, {t: 6000, f: 0.2},
			{t: 7000, f: 1e-8}, {t: 8000, f: 12345.6789},
		})},
		{otSeriesRun(metric, 1.0/7.0, 30, 1.0/13.0)},
	}

	for _, m := range regressionMatrices {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "deriv", Delayed: delayed, Ts: "1500",
				Expr:     "deriv(http_requests_total[5m])",
				Args:     [][]fnSampleIn{},
				MatrixIn: m,
			})
		}
		// predict_linear's interceptTime is enh.Ts, so the timestamp is part of the
		// answer and not just context.
		for _, ts := range []string{"0", "1500", "3000", "-1500"} {
			for _, d := range []float64{0, 60, -60, 3600, 1e6, math.Inf(1), math.NaN()} {
				emit(fnIn{
					Fn: "predict_linear", Ts: ts,
					Expr:     "predict_linear(http_requests_total[5m], 60)",
					Args:     [][]fnSampleIn{{{F: fbits(d)}}},
					MatrixIn: m,
				})
			}
		}
		// Only VALID factors: Go panics outside (0, 1), which would take the fixture
		// generator down. The panic is a contract and is pinned Swift-side instead.
		for _, sf := range []float64{0.1, 0.5, 0.9, 0.3, 1.0 / 7.0} {
			for _, tf := range []float64{0.1, 0.5, 0.9, 0.7, 1.0 / 3.0} {
				emit(fnIn{
					Fn: "double_exponential_smoothing", Ts: "1500",
					Expr: "double_exponential_smoothing(http_requests_total[5m], 0.5, 0.5)",
					Args: [][]fnSampleIn{
						{{F: fbits(sf)}}, {{F: fbits(tf)}},
					},
					MatrixIn: m,
				})
			}
		}
	}
	// The guards: a missing scalar argument in each position.
	emit(fnIn{
		Fn: "predict_linear", Ts: "1500",
		Expr:     "predict_linear(http_requests_total[5m], 60)",
		Args:     [][]fnSampleIn{{}},
		MatrixIn: regressionMatrices[5],
	})
	emit(fnIn{
		Fn: "double_exponential_smoothing", Ts: "1500",
		Expr:     "double_exponential_smoothing(http_requests_total[5m], 0.5, 0.5)",
		Args:     [][]fnSampleIn{{{F: fbits(0.5)}}, {}},
		MatrixIn: regressionMatrices[5],
	})

	// --- irate and idelta.
	//
	// The two-sample selection is the whole function, and the four-way histogram merge
	// is where it lives. These matrices exist to reach every arm of it: a histogram
	// older than both floats (discarded), newer than both (shifts ss[1] down), between
	// them, and at an EQUAL timestamp — which lands ss[0] = histogram, ss[1] = float
	// and so produces a mixed-kind warning rather than a value.
	//
	// The hint tests are not mirror images: irate warns if EITHER histogram is a
	// gauge, idelta warns if either is NOT one. Every hint combination is here.
	instantMatrices := [][][]fnSampleIn{
		{},
		// Fewer than two samples of any kind: nothing.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}})},
		// Two floats, rising: a plain rate.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: 5}})},
		// More than two, so only the last two are read.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 100}, {t: 2000, f: 1}, {t: 3000, f: 5}, {t: 4000, f: 11},
		})},
		// A counter RESET between the last two: irate leaves ss[1], idelta subtracts.
		{otSeries(metric, []otPoint{{t: 1000, f: 10}, {t: 2000, f: 3}})},
		// Equal values, so the difference is zero.
		{otSeries(metric, []otPoint{{t: 1000, f: 7}, {t: 2000, f: 7}})},
		// NaN, which is neither less than nor greater than anything.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: math.NaN()}})},
		{otSeries(metric, []otPoint{{t: 1000, f: math.NaN()}, {t: 2000, f: 1}})},
		// Infinities.
		{otSeries(metric, []otPoint{{t: 1000, f: math.Inf(-1)}, {t: 2000, f: math.Inf(1)}})},
		// Sub-second and multi-second intervals, which the per-second division scales.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 1001, f: 2}})},
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 61000, f: 2}})},
		// EQUAL timestamps between the last two floats: sampledInterval is 0, so
		// nothing is returned at all.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 1000, f: 5}})},
		// Two histograms.
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, hist: "std/3"}})},
		// A histogram counter reset (n descending), which irate skips and idelta does
		// not.
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/3"}, {t: 2000, hist: "std/1"}})},
		// Custom buckets on both sides, and mismatched against exponential — the
		// incompatible-schema warning.
		{otSeries(metric, []otPoint{{t: 1000, hist: "custom"}, {t: 2000, hist: "custom"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, hist: "custom"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "custom"}, {t: 2000, hist: "std/1"}})},
		// A mix of a float and a histogram as the last two: the warning path.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, hist: "std/1"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, f: 1}})},
		// The four-way merge. Two floats plus a histogram older than both: discarded,
		// so the floats win.
		{otSeries(metric, []otPoint{
			{t: 500, hist: "std/1"}, {t: 1000, f: 1}, {t: 2000, f: 5},
		})},
		// A histogram NEWER than both floats: it becomes ss[1] and the newer float
		// becomes ss[0], so the result is mixed.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 5}, {t: 3000, hist: "std/1"},
		})},
		// A histogram BETWEEN the two floats: it overwrites ss[0].
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 1500, hist: "std/1"}, {t: 2000, f: 5},
		})},
		// Equal timestamps across the kinds, the "irregular" case upstream calls out.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: 5}, {t: 2000, hist: "std/1"}})},
		// Two histograms and two floats, all four in play.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 5}, {t: 3000, hist: "std/1"}, {t: 4000, hist: "std/3"},
		})},
		// With the metadata labels, so the warnings' metric name is visible.
		{otSeries(withMetadata, []otPoint{{t: 1000, f: 1}, {t: 2000, hist: "std/1"}})},
		// GAUGE-hinted histograms, in every combination with a counter. irate warns
		// when EITHER is a gauge and idelta when either is NOT, so the two conditions
		// are indistinguishable until a gauge exists at all.
		{otSeries(metric, []otPoint{{t: 1000, hist: "gauge"}, {t: 2000, hist: "gauge2"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "gauge"}, {t: 2000, hist: "std/3"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, hist: "gauge2"}})},
		// A gauge pair in descending order, so the reset detection and the hint
		// warnings interact.
		{otSeries(metric, []otPoint{{t: 1000, hist: "gauge2"}, {t: 2000, hist: "gauge"}})},
	}
	for _, fn := range []string{"irate", "idelta"} {
		for _, m := range instantMatrices {
			if len(m) == 0 {
				// instantValue indexes vals[0] before any guard, so an empty matrix
				// panics in Go too. Not a case, and noted in the port.
				continue
			}
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: fn, Delayed: delayed, Ts: "1500",
					Expr:     fn + "(http_requests_total[5m])",
					Args:     [][]fnSampleIn{},
					MatrixIn: m,
				})
			}
		}
	}

	// --- resets and changes.
	//
	// Both walk the range sample by sample across BOTH kinds, and their merge loop is
	// where the behaviour is. Equal timestamps across the kinds are excluded on
	// purpose: they match neither of Go's two cases, so no index advances and Go loops
	// FOREVER. The port raises a precondition there instead, which is exception 9's
	// treatment of an unreachable-in-practice crash.
	//
	// `resets` counts a change of kind, a float decrease, a histogram DetectReset, or
	// a start-timestamp reset. `changes` counts a change of kind, a float inequality
	// (unless BOTH are NaN) or a histogram inequality — and never reads start
	// timestamps at all.
	//
	// The `anchored` modifier drives pickFirstSampleIndices, so each case runs against
	// both `[5m]` and `[5m] anchored`.
	counterMatrices := [][][]fnSampleIn{
		{},
		{otSeries(metric, nil)},
		{otSeries(metric, []otPoint{{t: 1000, f: 1}})},
		// Monotonic: no resets, every step a change.
		{otSeriesRun(metric, 0, 6, 1)},
		// One reset.
		{otSeries(metric, []otPoint{{t: 1000, f: 5}, {t: 2000, f: 1}, {t: 3000, f: 3}})},
		// Several, including equal values (a reset needs <, a change needs !=).
		{otSeries(metric, []otPoint{
			{t: 1000, f: 5}, {t: 2000, f: 5}, {t: 3000, f: 1}, {t: 4000, f: 1},
			{t: 5000, f: 0}, {t: 6000, f: 7},
		})},
		// NaN: two in a row are NOT a change, but NaN after a number is, and a number
		// after NaN is. And NaN is never less than anything, so no reset.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: math.NaN()}, {t: 3000, f: math.NaN()},
			{t: 4000, f: 2},
		})},
		{otSeries(metric, []otPoint{{t: 1000, f: math.NaN()}, {t: 2000, f: math.NaN()}})},
		// Signed zeros, which are equal but not identical.
		{otSeries(metric, []otPoint{{t: 1000, f: 0}, {t: 2000, f: math.Copysign(0, -1)}})},
		// Infinities.
		{otSeries(metric, []otPoint{
			{t: 1000, f: math.Inf(1)}, {t: 2000, f: math.Inf(1)}, {t: 3000, f: math.Inf(-1)},
		})},
		// Histograms only: ascending n is no reset, descending is.
		{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/0"}, {t: 2000, hist: "std/1"}, {t: 3000, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/2"}, {t: 2000, hist: "std/1"}, {t: 3000, hist: "std/0"},
		})},
		// Identical histograms: no reset AND no change.
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, hist: "std/1"}})},
		// A change of KIND, in both directions, which counts for both functions.
		{otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, hist: "std/1"}})},
		{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}, {t: 2000, f: 1}})},
		// Kinds alternating, so the merge loop switches on every step.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, hist: "std/1"}, {t: 3000, f: 2},
			{t: 4000, hist: "std/2"}, {t: 5000, f: 3},
		})},
		// A block of floats then a block of histograms, so the loop drains one list
		// before the other.
		{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 2}, {t: 3000, hist: "std/1"}, {t: 4000, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/1"}, {t: 2000, hist: "std/2"}, {t: 3000, f: 1}, {t: 4000, f: 2},
		})},
		// Gauge-hinted histograms, where DetectReset behaves differently.
		{otSeries(metric, []otPoint{{t: 1000, hist: "gauge2"}, {t: 2000, hist: "gauge"}})},
		// Custom buckets against exponential: not equal, and DetectReset has to cope.
		{otSeries(metric, []otPoint{{t: 1000, hist: "custom"}, {t: 2000, hist: "std/1"}})},
		// Samples spread either side of the anchored range start, which for ts=1500
		// and [5m] is 1500 - 300000 = -298500. Everything above is inside the range, so
		// these reach the "no anchor" arm; the ones below reach the anchor arms.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -350_000, f: 2}, {t: -100_000, f: 3}, {t: 0, f: 4},
		})},
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -350_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"},
		})},
		// Both kinds straddling the range start, so the anchor choice between them
		// matters — the `floats[lastFloatLE].T >= histograms[lastHistLE].T` test.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -350_000, hist: "std/0"}, {t: -100_000, f: 3},
			{t: 0, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -350_000, f: 1}, {t: -100_000, f: 3},
		})},
		// Every sample BEFORE the range start: nothing to measure, so `found` is false
		// and the result is absent rather than 0.
		{otSeries(metric, []otPoint{{t: -400_000, f: 1}, {t: -350_000, f: 2}})},
	}

	// A float and a histogram at the SAME timestamp at the anchor position, which is
	// what makes `pickFirstSampleIndices`' tie test (`>=`, so the float wins) visible
	// at all.
	//
	// These run against `[5m] anchored` ONLY, and the reason is worth recording:
	// with a plain `[5m]` the merge loop starts at (0, 0), reaches the two
	// equal-timestamp samples, matches NEITHER of its two cases, advances no index —
	// and Go loops forever. That is not a thought experiment; it hung the fixture
	// generator. Anchored, the loop starts after the tie and terminates.
	anchorTieMatrices := [][][]fnSampleIn{
		{otSeries(metric, []otPoint{
			{t: -350_000, f: 1}, {t: -350_000, hist: "std/0"}, {t: -100_000, f: 3},
			{t: 0, f: 4},
		})},
		{otSeries(metric, []otPoint{
			{t: -350_000, hist: "std/0"}, {t: -350_000, f: 1}, {t: -100_000, hist: "std/2"},
		})},
	}
	for _, fn := range []string{"resets", "changes"} {
		// The offset is part of `rangeStart`, so a selector carrying one moves the
		// anchor — and without an offset case that term of the expression is dead.
		for _, sel := range []string{
			"[5m]", "[5m] anchored", "[5m] anchored offset 1m", "[10m] anchored",
		} {
			cases := counterMatrices
			// Only `[5m] anchored` puts the range start (ts - 5m = -298500) *after* the
			// tie at -350000, so the merge loop begins past it. A wider range or an
			// offset moves the start earlier, `pickFirstSampleIndices` finds no anchor
			// and returns (0, 0) — and then the loop reaches the equal timestamps and
			// hangs. Empirically, not hypothetically.
			if sel == "[5m] anchored" {
				cases = append(append([][][]fnSampleIn{}, counterMatrices...), anchorTieMatrices...)
			}
			for _, m := range cases {
				for _, delayed := range []bool{false, true} {
					emit(fnIn{
						Fn: fn, Delayed: delayed, Ts: "1500",
						Expr:     fn + "(http_requests_total" + sel + ")",
						Args:     [][]fnSampleIn{},
						MatrixIn: m,
					})
				}
			}
		}
	}

	for _, fn := range names {
		for _, m := range matrices {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: fn, Delayed: delayed, Ts: "1500",
					Expr:     fn + "(http_requests_total[5m])",
					Args:     [][]fnSampleIn{},
					MatrixIn: m,
				})
			}
		}
	}

	// A non-empty enh.Out, to pin that every one of these appends rather than
	// returning a fresh vector.
	for _, fn := range names {
		emit(fnIn{
			Fn: fn, Ts: "1500",
			Expr: fn + "(http_requests_total[5m])",
			Args: [][]fnSampleIn{},
			Seed: []fnSampleIn{{Metric: []string{"job", "seed"}, T: "111", F: fbits(-99)}},
			MatrixIn: [][]fnSampleIn{
				otSeries(metric, []otPoint{{t: 1000, f: 1}, {t: 2000, f: 4}}),
			},
		})
	}
}
