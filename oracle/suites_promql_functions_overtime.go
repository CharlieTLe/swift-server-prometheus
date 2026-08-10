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

// otSeriesOverflowThen builds a series that overflows a running float64 sum on its
// second sample and then continues for `n` more at `tail`. That shape is what
// distinguishes reprocessing the overflowing sample from skipping it.
func otSeriesOverflowThen(metric []string, n int, tail float64) []fnSampleIn {
	pts := []otPoint{{t: 1000, f: 1e308}, {t: 2000, f: 1e308}}
	for i := 0; i < n; i++ {
		pts = append(pts, otPoint{t: int64(i+3) * 1000, f: tail})
	}
	return otSeries(metric, pts)
}

// otSeriesCompensateThenOverflow interleaves huge and tiny values so the Kahan
// compensation is non-zero, then overflows. Without a non-zero `kahanC` at the moment
// of the switch, dividing it by `count - 1` and zeroing it are indistinguishable.
func otSeriesCompensateThenOverflow(metric []string, n int) []fnSampleIn {
	pts := []otPoint{}
	for i := 0; i < n; i++ {
		v := 1e-300
		if i%2 == 0 {
			v = 1e300
		}
		pts = append(pts, otPoint{t: int64(i+1) * 1000, f: v})
	}
	pts = append(pts, otPoint{t: int64(n+1) * 1000, f: 1e308})
	pts = append(pts, otPoint{t: int64(n+2) * 1000, f: 1e308})
	pts = append(pts, otPoint{t: int64(n+3) * 1000, f: 1e-300})
	pts = append(pts, otPoint{t: int64(n+4) * 1000, f: 7})
	return otSeries(metric, pts)
}

// otSeriesAt builds `n` float samples starting at `start` ms, `step` ms apart, whose
// values start at `base` and rise by `slope` each time. Placing samples explicitly in
// time is what the extrapolation needs — moving them within the range changes the
// answer even when the values do not.
func otSeriesAt(metric []string, start, step int64, n int, base, slope float64) []fnSampleIn {
	pts := make([]otPoint, 0, n)
	for i := 0; i < n; i++ {
		pts = append(pts, otPoint{t: start + int64(i)*step, f: base + float64(i)*slope})
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

	// --- sum_over_time.
	//
	// Its three-way split is stricter than the rest of this family: BOTH kinds present
	// is a MixedFloatsHistogramsWarning and no output, where max_over_time would ignore
	// the histograms and warn differently. No floats takes the histogram path.
	//
	// The histogram path's annotations depend on what it saw across the WHOLE range —
	// a CounterReset hint together with a NotCounterReset one is a collision, and any
	// bound reconciliation is reported once. Go adds both in a `defer`, so they fire on
	// the error return too. The `hintPair` shapes below exist for that.
	// A series with NEITHER floats nor histograms is excluded: `len(Floats) == 0`
	// routes it to the histogram path, which indexes `Histograms[0]` with no guard, so
	// Go PANICS. It took the fixture generator down. Unreachable from a query, and
	// guarded with a clear precondition in the port instead.
	sumMatrices := [][][]fnSampleIn{}
	for _, m := range matrices {
		if len(m) == 1 && len(m[0]) == 0 {
			continue
		}
		sumMatrices = append(sumMatrices, m)
	}
	sumMatrices = append(sumMatrices,
		// Histogram-only, ascending and descending.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/0"}, {t: 2000, hist: "std/1"}, {t: 3000, hist: "std/2"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/3"}, {t: 2000, hist: "std/1"},
		})},
		// A single histogram: the loop body never runs and `comp` stays nil, so the
		// final `Add` is skipped.
		[][]fnSampleIn{otSeries(metric, []otPoint{{t: 1000, hist: "std/1"}})},
		// Custom buckets throughout, and mixed against exponential — the
		// incompatible-schema path, which discards the partial sum and keeps only the
		// warning.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "custom"}, {t: 2000, hist: "custom"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "std/1"}, {t: 2000, hist: "custom"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "custom"}, {t: 2000, hist: "std/1"}, {t: 3000, hist: "custom"},
		})},
		// Gauge hints, and the zero/negative shape.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "gauge"}, {t: 2000, hist: "gauge2"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "zeroneg"}, {t: 2000, hist: "zeroneg"},
		})},
		// Both kinds: the strict mixed warning, with and without the metadata labels.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, hist: "std/1"},
		})},
		[][]fnSampleIn{otSeries(withMetadata, []otPoint{
			{t: 1000, f: 1}, {t: 2000, hist: "std/1"},
		})},
		// Float sums that OVERFLOW, which is the one case where the compensation is
		// deliberately not added back.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: 1e308}, {t: 2000, f: 1e308}, {t: 3000, f: 1},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: -1e308}, {t: 2000, f: -1e308},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: math.Inf(1)}, {t: 2000, f: 1}, {t: 3000, f: 0.1},
		})},
		// Both counter-reset hints in one range: the ONLY way the collision warning
		// fires, since every other shape is unknown or gauge.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "crhint"}, {t: 2000, hist: "ncrhint"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "ncrhint"}, {t: 2000, hist: "crhint"}, {t: 3000, hist: "std/1"},
		})},
		// One hint only, so the collision must NOT fire.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "crhint"}, {t: 2000, hist: "crhint"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "ncrhint"}, {t: 2000, hist: "ncrhint"},
		})},
		// Custom buckets with DIFFERENT bounds, which forces a reconciliation and is
		// the only way the MismatchedCustomBuckets info fires.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "custom"}, {t: 2000, hist: "custom2"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "custom2"}, {t: 2000, hist: "custom"}, {t: 3000, hist: "custom2"},
		})},
		// Wildly different magnitudes, so the histogram Kahan compensation carries a
		// non-zero term and the final Add(comp) is not a no-op.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "huge"}, {t: 2000, hist: "tiny"}, {t: 3000, hist: "tiny"},
			{t: 4000, hist: "tiny"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "huge"}, {t: 2000, hist: "tiny"}, {t: 3000, hist: "huge"},
			{t: 4000, hist: "tiny"},
		})},
		// A float sum that overflows to +Inf while the compensation is non-zero, so
		// `sum + c` would be NaN and the guard is what keeps it +Inf.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: 1e308}, {t: 2000, f: 1e-308}, {t: 3000, f: 1e308},
			{t: 4000, f: 1e-308},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 1e308}, {t: 3000, f: 1e308}, {t: 4000, f: 0.5},
		})},
		// And sums where the compensation genuinely matters.
		[][]fnSampleIn{otSeriesRun(metric, 1e16, 50, 1)},
		[][]fnSampleIn{otSeriesAlternating(metric, 1e17, 1, 21)},
	)
	for _, m := range sumMatrices {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "sum_over_time", Delayed: delayed, Ts: "1500",
				Expr:     "sum_over_time(http_requests_total[5m])",
				Args:     [][]fnSampleIn{},
				MatrixIn: m,
			})
		}
	}

	// --- avg_over_time, on sum_over_time's matrices plus the ones that force the
	// mid-range switch from a direct mean to an incremental one.
	//
	// The switch triggers on the CANDIDATE sum, so the sample that would have
	// overflowed is reprocessed by the incremental branch in the same iteration rather
	// than skipped. A range that overflows early and then continues for many samples is
	// what distinguishes that from a `continue`.
	avgMatrices := append([][][]fnSampleIn{}, sumMatrices...)
	avgMatrices = append(avgMatrices,
		// Overflows on the second sample, then twenty more: everything after the switch
		// runs incrementally, and the reprocessed sample is the one that overflowed.
		[][]fnSampleIn{otSeriesOverflowThen(metric, 20, 1)},
		[][]fnSampleIn{otSeriesOverflowThen(metric, 20, 1e300)},
		[][]fnSampleIn{otSeriesOverflowThen(metric, 3, -1e300)},
		// Overflows on the LAST sample, so the incremental branch runs exactly once and
		// its seeding is all that matters.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, f: 1}, {t: 2000, f: 2}, {t: 3000, f: 1e308}, {t: 4000, f: 1e308},
		})},
		// Never overflows, but long and large enough that the direct path's
		// `sum/count + kahanC/count` differs from `(sum + kahanC) / count`.
		[][]fnSampleIn{otSeriesRun(metric, 1e16, 50, 1)},
		[][]fnSampleIn{otSeriesRun(metric, 1e10, 101, 7)},
		[][]fnSampleIn{otSeriesAlternating(metric, 1e17, 1, 21)},
		// A non-trivial Kahan compensation ALREADY accumulated when the overflow hits,
		// which is the only way the switch's `kahanC /= (count - 1)` can be told apart
		// from `kahanC = 0` — and the only way the closing
		// `sum/count + kahanC/count` can be told apart from `(sum + kahanC) / count`.
		// Three controls passed until this existed.
		[][]fnSampleIn{otSeriesCompensateThenOverflow(metric, 30)},
		[][]fnSampleIn{otSeriesCompensateThenOverflow(metric, 7)},
		// The same shape without the overflow, so only the closing two-divisions form
		// is exercised.
		[][]fnSampleIn{otSeriesAlternating(metric, 1e300, 1e-300, 31)},
		// Two samples only, so `count - 1` is 1 and the seeding division is the identity.
		[][]fnSampleIn{otSeries(metric, []otPoint{{t: 1000, f: 1e308}, {t: 2000, f: 1e308}})},
		// Histograms whose running sum overflows, which is the histogram path's switch.
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "overflow"}, {t: 2000, hist: "overflow"},
			{t: 3000, hist: "huge"}, {t: 4000, hist: "tiny"},
		})},
		[][]fnSampleIn{otSeries(metric, []otPoint{
			{t: 1000, hist: "overflow"}, {t: 2000, hist: "overflow"},
			{t: 3000, hist: "overflow"},
		})},
	)
	for _, m := range avgMatrices {
		for _, delayed := range []bool{false, true} {
			emit(fnIn{
				Fn: "avg_over_time", Delayed: delayed, Ts: "1500",
				Expr:     "avg_over_time(http_requests_total[5m])",
				Args:     [][]fnSampleIn{},
				MatrixIn: m,
			})
		}
	}

	// --- rate, increase and delta, through extrapolatedRate.
	//
	// Extrapolation, not a slope: `last - first` with the pre-reset value added back at
	// every reset, scaled by `(sampledInterval + durationToStart + durationToEnd) /
	// sampledInterval`, and divided by the range for `rate`. So the corpus has to move
	// the samples *within* the range, not just change their values:
	//
	//   - samples filling the range, so both durations are ~0 and the factor is ~1;
	//   - samples clustered at one end, so one duration exceeds the 1.1x threshold and
	//     collapses to half the average gap;
	//   - two samples only, where the average gap IS the sampled interval;
	//   - a first sample of exactly 0 with a rising counter, which is the boundary of
	//     the `samples.Floats[0].F >= 0` clamp guard;
	//   - a rising counter whose extrapolated zero point lands INSIDE durationToStart,
	//     which is the only way the clamp changes the answer.
	//
	// `anchored`/`smoothed` are excluded: they dispatch to `extendedRate`, which is not
	// ported, and the port raises a precondition there.
	// No empty matrix: `extrapolatedRate` indexes `vals[0]` with no check and Go
	// PANICS. It took the fixture generator down. Unreachable from a query, guarded
	// with a precondition in the port.
	rateMatrices := [][][]fnSampleIn{
		{otSeries(metric, nil)},
		// Fewer than two of a kind: dropped.
		{otSeries(metric, []otPoint{{t: -100_000, f: 5}})},
		{otSeries(metric, []otPoint{{t: -100_000, hist: "std/1"}})},
		// Both kinds: the mixed warning.
		{otSeries(metric, []otPoint{{t: -100_000, f: 5}, {t: -50_000, hist: "std/1"}})},
		// Filling the range (ts=1500, [5m] -> start -298500), evenly spaced.
		{otSeriesAt(metric, -298_000, 1000, 10, 0, 10)},
		{otSeriesAt(metric, -298_000, 30_000, 10, 0, 10)},
		// Clustered at the START, so durationToEnd blows the threshold.
		{otSeriesAt(metric, -298_000, 1000, 10, 0, 1)},
		// Clustered at the END, so durationToStart does.
		{otSeriesAt(metric, -20_000, 1000, 10, 0, 1)},
		// Two samples only.
		{otSeries(metric, []otPoint{{t: -200_000, f: 1}, {t: -100_000, f: 5}})},
		{otSeries(metric, []otPoint{{t: -298_000, f: 1}, {t: 1000, f: 5}})},
		// A first sample of exactly 0 with a rising counter: the clamp guard's boundary.
		{otSeriesAt(metric, -200_000, 10_000, 8, 0, 3)},
		// A NEGATIVE first sample, which disqualifies the clamp.
		{otSeriesAt(metric, -200_000, 10_000, 8, -5, 3)},
		// A rising counter whose zero point lands inside durationToStart, which is the
		// only shape where the clamp changes the answer.
		{otSeriesAt(metric, -100_000, 10_000, 5, 100, 1)},
		// Flat, so resultFloat is 0 and the clamp is skipped.
		{otSeriesAt(metric, -200_000, 10_000, 8, 7, 0)},
		// Counter RESETS, one and several.
		{otSeries(metric, []otPoint{
			{t: -200_000, f: 10}, {t: -150_000, f: 3}, {t: -100_000, f: 8},
		})},
		{otSeries(metric, []otPoint{
			{t: -250_000, f: 10}, {t: -200_000, f: 3}, {t: -150_000, f: 1},
			{t: -100_000, f: 9}, {t: -50_000, f: 2},
		})},
		// Decreasing throughout: every step a reset.
		{otSeriesAt(metric, -200_000, 10_000, 8, 100, -10)},
		// NaN and infinities in a counter.
		{otSeries(metric, []otPoint{{t: -200_000, f: 1}, {t: -100_000, f: math.NaN()}})},
		{otSeries(metric, []otPoint{{t: -200_000, f: math.NaN()}, {t: -100_000, f: 1}})},
		{otSeries(metric, []otPoint{{t: -200_000, f: 1}, {t: -100_000, f: math.Inf(1)}})},
		// Histograms: rising, falling (a reset), identical, gauge-hinted, custom.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/0"}, {t: -150_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/3"}, {t: -150_000, hist: "std/1"},
			{t: -100_000, hist: "std/0"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: -100_000, hist: "std/1"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "gauge"}, {t: -100_000, hist: "gauge2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "gauge"}, {t: -150_000, hist: "std/1"},
			{t: -100_000, hist: "gauge2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "custom"}, {t: -100_000, hist: "custom2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: -100_000, hist: "custom"},
		})},
		// A reset between the FIRST and SECOND histogram, which nulls out the first —
		// the branch whose whole point is to ignore the first sample's bucket layout.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "custom"}, {t: -150_000, hist: "std/0"},
			{t: -100_000, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/3"}, {t: -150_000, hist: "std/0"},
			{t: -100_000, hist: "std/2"},
		})},
		// Mixed schemas, so minSchema comes from a middle point.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: -150_000, hist: "zeroneg"},
			{t: -100_000, hist: "std/2"},
		})},
		// With the metadata labels, so the warnings carry a name.
		{otSeries(withMetadata, []otPoint{
			{t: -200_000, hist: "gauge"}, {t: -100_000, hist: "gauge2"},
		})},
	}
	for _, fn := range []string{"rate", "increase", "delta"} {
		for _, sel := range []string{"[5m]", "[2m]", "[5m] offset 1m"} {
			for _, m := range rateMatrices {
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

	// --- absent. Its labels come from the SELECTOR's matchers, so each case is a
	// different expression rather than a different input vector.
	//
	// The `has` map is backwards compatibility and upstream says so: only the FIRST `=`
	// matcher for a name contributes, and a second matcher on that name — of any type —
	// deletes it again. So `x{job="a",job="b"}` drops `job`, and upstream's own comment
	// notes `x{job="a",job="a"}` does too, which is "arguably wrong".
	absentExprs := []string{
		`absent(x)`,
		`absent(x{job="a"})`,
		`absent(x{job="a",foo="bar"})`,
		// A repeated name: dropped, both with different values and with the same one.
		`absent(x{job="a",job="b",foo="bar"})`,
		`absent(x{job="a",job="a",foo="bar"})`,
		// Non-equality matchers delete rather than set.
		`absent(x{job!="a",foo="bar"})`,
		`absent(x{job=~"a.*",foo="bar"})`,
		`absent(x{job!~"a.*",foo="bar"})`,
		// An `=` after a non-`=` on the same name: `has` is still false, so it SETS.
		`absent(x{job!="a",job="b"})`,
		// An `=` before a non-`=`: the second deletes what the first set.
		`absent(x{job="b",job!="a"})`,
		// __name__ matchers are skipped outright.
		`absent({__name__="x",job="a"})`,
		// `absent(x{__name__="y"})` does not parse — the parser rejects a metric name
		// set twice — so only the braces-only form reaches the __name__ skip.
		// An empty value, which is still an `=` matcher.
		`absent(x{job=""})`,
		// The MatrixSelector branch of createLabelsForAbsentFunction is NOT reachable
		// here: `absent(x[5m])` fails type-checking, and `absent_over_time`'s body
		// ignores its args entirely — the evaluator calls the helper for it directly.
		// Pinned Swift-side instead.
		// Not a selector at all: no labels.
		`absent(vector(1))`,
	}
	for _, e := range absentExprs {
		// Empty input yields the synthetic sample; non-empty yields nothing.
		for _, arg := range [][]fnSampleIn{
			{},
			{{Metric: []string{"__name__", "x", "job", "a"}, T: "1000", F: fbits(5)}},
		} {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: "absent", Delayed: delayed, Ts: "1500",
					Expr: e,
					Args: [][]fnSampleIn{arg},
				})
			}
		}
	}

	// --- rate/increase/delta over ANCHORED and SMOOTHED float ranges, i.e.
	// `extendedRate`.
	//
	// Neither modifier scales by a factor the way `extrapolatedRate` does: the
	// boundaries ARE the range, so `isRate` divides by the range and nothing else.
	// What they do differ in is the boundary values — `anchored` uses the last sample
	// at or before the start as-is, `smoothed` interpolates to both boundaries — so
	// every case below runs against both, and the interesting shapes are the ones with
	// samples STRADDLING each boundary.
	//
	// For ts=1500 and [5m], rangeStart is -298500 and rangeEnd is 1500.
	//
	// Histogram ranges are in `extendedHistMatrices` below, against
	// `extendedHistogramRate`.
	extendedMatrices := [][][]fnSampleIn{
		// One sample only, before the range: the `f[last].T <= rangeStart` exit.
		{otSeries(metric, []otPoint{{t: -400_000, f: 5}})},
		// One sample inside.
		{otSeries(metric, []otPoint{{t: -100_000, f: 5}})},
		// Straddling the START: one before, several inside. The left boundary is
		// interpolated when smoothed and taken as-is when anchored.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -200_000, f: 5}, {t: -100_000, f: 9},
		})},
		// Straddling the END too, so the right boundary interpolates as well.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -200_000, f: 5}, {t: -100_000, f: 9},
			{t: 100_000, f: 20},
		})},
		// Samples EXACTLY on each boundary, where the `<`/`<=` choices decide whether
		// the sample is interpolated and whether it is excluded from the correction.
		{otSeries(metric, []otPoint{
			{t: -298_500, f: 1}, {t: -100_000, f: 5}, {t: 1500, f: 9},
		})},
		{otSeries(metric, []otPoint{
			{t: -298_500, f: 1}, {t: 1500, f: 9},
		})},
		// Entirely before the range end but starting after the range start.
		{otSeries(metric, []otPoint{{t: -100_000, f: 1}, {t: -50_000, f: 5}})},
		// The LAST sample exactly at rangeStart, which is the `<=` in the
		// `f[last].T <= rangeStart` exit rather than a `<`.
		{otSeries(metric, []otPoint{{t: -400_000, f: 1}, {t: -298_500, f: 5}})},
		// A DECREASING pair whose first sample sits exactly on rangeStart. Interpolating
		// there is a no-op for a gauge (Δt is 0) but not for a counter: `interpolate`
		// zeroes y1 when y2 < y1, so the smoothed left boundary would become 0 instead
		// of the sample's value. Without this the `<` versus `<=` in
		// pickOrInterpolateLeft was invisible.
		{otSeries(metric, []otPoint{
			{t: -298_500, f: 10}, {t: -200_000, f: 2}, {t: -100_000, f: 6},
		})},
		// TWO samples after rangeEnd, so the smoothed search for `f[i].T >= rangeEnd`
		// actually finds one and moves lastSampleIndex. With a single trailing sample
		// the search is bounded out and the index does not move at all.
		{otSeries(metric, []otPoint{
			{t: -200_000, f: 1}, {t: -100_000, f: 5}, {t: 100_000, f: 9},
			{t: 200_000, f: 20},
		})},
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -100_000, f: 5}, {t: 50_000, f: 9},
			{t: 100_000, f: 12}, {t: 200_000, f: 30},
		})},
		// Entirely AFTER the range end, which is the smoothed-only
		// `f[first].T > rangeEnd` exit.
		{otSeries(metric, []otPoint{{t: 100_000, f: 1}, {t: 200_000, f: 5}})},
		// A counter reset strictly inside, which the correction must add back once.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -250_000, f: 10}, {t: -200_000, f: 3},
			{t: -100_000, f: 8}, {t: 100_000, f: 12},
		})},
		// A reset spanning the LEFT boundary, which `interpolate` folds in by zeroing
		// y1 — so the correction must NOT count it again. That double-counting is
		// invisible on a monotonic series.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 10}, {t: -200_000, f: 2}, {t: -100_000, f: 6},
		})},
		// A reset spanning the RIGHT boundary.
		{otSeries(metric, []otPoint{
			{t: -200_000, f: 2}, {t: -100_000, f: 9}, {t: 100_000, f: 1},
		})},
		// Resets at both boundaries.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 10}, {t: -200_000, f: 2}, {t: -100_000, f: 9},
			{t: 100_000, f: 1},
		})},
		// Decreasing throughout: every step a reset.
		{otSeriesAt(metric, -300_000, 50_000, 8, 100, -10)},
		// Flat.
		{otSeriesAt(metric, -300_000, 50_000, 8, 7, 0)},
		// Evenly spaced across the whole range.
		{otSeriesAt(metric, -298_000, 30_000, 11, 0, 10)},
		// Sub-second spacing at the boundary, where the interpolation's Δt is small.
		{otSeries(metric, []otPoint{
			{t: -298_501, f: 1}, {t: -298_499, f: 5}, {t: 1499, f: 9}, {t: 1501, f: 11},
		})},
		// NaN and infinities across a boundary.
		{otSeries(metric, []otPoint{
			{t: -400_000, f: math.NaN()}, {t: -100_000, f: 5}, {t: 100_000, f: 9},
		})},
		{otSeries(metric, []otPoint{
			{t: -400_000, f: 1}, {t: -100_000, f: math.Inf(1)}, {t: 100_000, f: 9},
		})},
	}
	for _, fn := range []string{"rate", "increase", "delta"} {
		for _, sel := range []string{
			"[5m] anchored", "[5m] smoothed", "[2m] anchored", "[2m] smoothed",
			"[5m] anchored offset 1m", "[5m] smoothed offset 1m",
		} {
			for _, m := range extendedMatrices {
				emit(fnIn{
					Fn: fn, Ts: "1500",
					Expr:     fn + "(http_requests_total" + sel + ")",
					Args:     [][]fnSampleIn{},
					MatrixIn: m,
				})
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

	// --- rate/increase/delta over ANCHORED and SMOOTHED HISTOGRAM ranges, i.e.
	// `extendedHistogramRate`.
	//
	// Same index arithmetic and the same two early exits as the float version, plus a
	// pre-flight `validateHistogramRange` over the window and a correction that walks its
	// own indices. Four things the float corpus could not reach:
	//
	//   - the schema mix, which ABANDONS the sample rather than annotating and continuing.
	//     Whether the mix lands inside the WINDOW is what matters, not whether it is in
	//     the series — so one case puts an NHCB after rangeEnd, where `smoothed` excludes
	//     it and `anchored` does not, and the two selectors disagree about the same input.
	//   - the gauge-hint warning, which for a counter is per-sample inside
	//     `validateHistogramRange` and for `delta` is on the two BOUNDARY values with
	//     `||` — so a range whose middle sample alone is a gauge distinguishes them.
	//   - `interpolateHistograms`' counter-reset branch, which returns `h2 * fraction`
	//     rather than interpolating; only a reset spanning a boundary reaches it.
	//   - `correctForCounterResetsHistogram` skipping a SECOND sample when the left
	//     interpolation already spanned a reset, and using that sample as the anchor.
	//     Needs `smoothed`, a first sample before rangeStart, and a reset from it to the
	//     next — and then a further reset right after, or the anchor choice is invisible.
	//
	// Two NHCBs with DIFFERENT bounds pass validation (both use custom buckets) and then
	// reconcile inside the arithmetic, so they are how the MismatchedCustomBuckets info
	// is reached from here — including from inside the interpolation itself.
	extendedHistMatrices := [][][]fnSampleIn{
		// One sample only, before the range: the `h[last].T <= rangeStart` exit.
		{otSeries(metric, []otPoint{{t: -400_000, hist: "std/1"}})},
		// One sample inside, so firstSampleIndex == lastSampleIndex and the correction
		// returns early on `first > last+1` with nothing to walk.
		{otSeries(metric, []otPoint{{t: -100_000, hist: "std/1"}})},
		// Straddling the START: interpolated when smoothed, taken as-is when anchored.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -200_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"},
		})},
		// Straddling the END too, so the right boundary interpolates as well.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -200_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"}, {t: 100_000, hist: "std/3"},
		})},
		// Samples EXACTLY on each boundary, where `<` versus `<=` decides whether the
		// sample is interpolated at all.
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "std/0"}, {t: -100_000, hist: "std/1"},
			{t: 1500, hist: "std/2"},
		})},
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "std/0"}, {t: 1500, hist: "std/2"},
		})},
		// TWO samples after rangeEnd, so the smoothed search actually moves
		// lastSampleIndex; with one it is bounded out and never moves.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/0"}, {t: -100_000, hist: "std/1"},
			{t: 100_000, hist: "std/2"}, {t: 200_000, hist: "std/3"},
		})},
		// Entirely AFTER the range end: the smoothed-only `h[first].T > rangeEnd` exit.
		{otSeries(metric, []otPoint{
			{t: 100_000, hist: "std/0"}, {t: 200_000, hist: "std/1"},
		})},
		// The last sample exactly at rangeStart: the `<=` in the first exit.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -298_500, hist: "std/1"},
		})},
		// A reset strictly inside, which the correction adds back once.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -250_000, hist: "std/3"},
			{t: -200_000, hist: "std/1"}, {t: -100_000, hist: "std/2"},
			{t: 100_000, hist: "std/3"},
		})},
		// A reset spanning the LEFT boundary: `interpolateHistograms` returns
		// `h2 * fraction`, and the correction must then skip h[first+1] as well.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/3"}, {t: -200_000, hist: "std/0"},
			{t: -100_000, hist: "std/2"},
		})},
		// The same, with a FURTHER reset immediately after — which is the only shape
		// where `prev = h[firstSampleIndex+1].H` differs from leaving prev at `left`.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/3"}, {t: -200_000, hist: "std/1"},
			{t: -150_000, hist: "std/0"}, {t: -100_000, hist: "std/2"},
		})},
		// A reset spanning the RIGHT boundary, which the final right.DetectReset catches.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: -100_000, hist: "std/3"},
			{t: 100_000, hist: "std/0"},
		})},
		// Resets at both boundaries.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/3"}, {t: -200_000, hist: "std/0"},
			{t: -100_000, hist: "std/3"}, {t: 100_000, hist: "std/0"},
		})},
		// Several resets inside, so the correction is ACCUMULATED — the `correction != nil`
		// half of addCorrection, which a single reset never reaches.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -250_000, hist: "std/3"},
			{t: -200_000, hist: "std/1"}, {t: -150_000, hist: "std/3"},
			{t: -120_000, hist: "std/0"}, {t: -100_000, hist: "std/2"},
			{t: 100_000, hist: "std/3"},
		})},
		// Identical histograms throughout: no reset, and the difference is empty.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/1"}, {t: -200_000, hist: "std/1"},
			{t: -100_000, hist: "std/1"}, {t: 100_000, hist: "std/1"},
		})},
		// A GAUGE hint on every sample, which is validateHistogramRange's warning for a
		// counter and no warning at all for delta.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "gauge"}, {t: -200_000, hist: "gauge2"},
			{t: -100_000, hist: "gauge"}, {t: 100_000, hist: "gauge2"},
		})},
		// A gauge hint on the MIDDLE sample only: a counter still warns (the loop sees it),
		// delta warns too (neither boundary is a gauge). The pair below is what separates
		// the per-sample loop from the two-boundary `||`.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/0"}, {t: -200_000, hist: "gauge"},
			{t: -100_000, hist: "std/2"}, {t: 100_000, hist: "std/3"},
		})},
		// Gauges at the BOUNDARIES and a counter in the middle: delta is silent, the
		// counter warns.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "gauge"}, {t: -200_000, hist: "std/1"},
			{t: -100_000, hist: "gauge2"}, {t: 100_000, hist: "gauge"},
		})},
		// The two explicit reset hints, which DetectReset reads before comparing buckets.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "crhint"}, {t: -200_000, hist: "ncrhint"},
			{t: -100_000, hist: "crhint"}, {t: 100_000, hist: "ncrhint"},
		})},
		// Custom buckets throughout, with the SAME bounds: no reconciliation.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "custom"}, {t: -200_000, hist: "custom"},
			{t: -100_000, hist: "custom"}, {t: 100_000, hist: "custom"},
		})},
		// Custom buckets with DIFFERENT bounds, straddling both boundaries — so the
		// reconciliation info comes out of the interpolation as well as the subtraction.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "custom"}, {t: -200_000, hist: "custom2"},
			{t: -100_000, hist: "custom"}, {t: 100_000, hist: "custom2"},
		})},
		// A GAUGE hint exactly ON rangeStart, followed by counters. This is the only shape
		// that can tell `pickOrInterpolateLeftHistogram`'s `<` from `<=`: interpolating at
		// Δt = 0 returns h1 unchanged in VALUE either way, but the arithmetic path runs
		// Sub/Mul/Add and the result's CounterResetHint is then adjusted rather than
		// inherited — and `delta`'s warning reads exactly that hint.
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "gauge"}, {t: -200_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"}, {t: 100_000, hist: "std/3"},
		})},
		// The same on the RIGHT: a gauge exactly ON rangeEnd, which is where `>` versus
		// `>=` decides whether `right` inherits the hint or has one computed for it.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: 1500, hist: "gauge"},
			{t: 100_000, hist: "std/2"},
		})},
		// An explicit counterReset hint exactly ON rangeStart. `left` becomes the
		// correction's first `prev`, so its hint — inherited or computed — is what
		// DetectReset reads for the first sample inside the range.
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "crhint"}, {t: -200_000, hist: "std/0"},
			{t: -100_000, hist: "std/2"}, {t: 100_000, hist: "std/3"},
		})},
		// A gauge exactly ON rangeStart with a gauge on rangeEnd too, and a COUNTER
		// between them. `delta`'s warning is `||`, so both boundaries must be gauges for it
		// to stay silent — and that silence is what the left boundary's hint can break.
		// This is the shape where `pickOrInterpolateLeftHistogram`'s `<=` becomes visible,
		// but only together with dropping interpolateHistograms' `t == t1` short-circuit:
		// each perturbation alone is absorbed by the other. See the port's header.
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "gauge"}, {t: -200_000, hist: "std/1"},
			{t: 1500, hist: "gauge2"},
		})},
		// NHCBs with DIFFERENT bounds whose first sample sits exactly ON rangeStart. This
		// is the shape where `pickOrInterpolateLeftHistogram`'s `<` versus `<=` finally
		// becomes visible — but only together with dropping interpolateHistograms'
		// `t == t1` short-circuit, because each perturbation alone is absorbed by the
		// other. At Δt = 0 the arithmetic path still RECONCILES the two bucket layouts,
		// so it returns h1's counts on intersected bounds and emits two extra infos,
		// where `h1.Copy()` keeps h1's own bounds and says nothing.
		{otSeries(metric, []otPoint{
			{t: -298_500, hist: "custom"}, {t: -200_000, hist: "custom2"},
			{t: -100_000, hist: "custom"}, {t: 100_000, hist: "custom2"},
		})},
		// The same interlock on the RIGHT: NHCBs with different bounds whose LAST in-window
		// sample sits exactly ON rangeEnd, so `>` versus `>=` and the `t == t2`
		// short-circuit protect each other the way the left pair does.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "custom"}, {t: 1500, hist: "custom2"},
			{t: 100_000, hist: "custom"},
		})},
		// A mix of exponential and custom INSIDE the window: validation fails and the
		// sample is abandoned.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/1"}, {t: -200_000, hist: "custom"},
			{t: -100_000, hist: "std/2"},
		})},
		// The mix only AFTER rangeEnd. `smoothed` pulls lastSampleIndex back to the first
		// sample at or after rangeEnd and never sees the NHCB; `anchored` keeps
		// len(h)-1 and fails validation. The same input, two answers.
		{otSeries(metric, []otPoint{
			{t: -200_000, hist: "std/1"}, {t: -100_000, hist: "std/2"},
			{t: 100_000, hist: "std/3"}, {t: 200_000, hist: "custom"},
		})},
		// A mix only BEFORE the window: two samples precede rangeStart and the earlier is
		// an NHCB, so firstSampleIndex shadows it and validation never sees it.
		{otSeries(metric, []otPoint{
			{t: -500_000, hist: "custom"}, {t: -400_000, hist: "std/1"},
			{t: -100_000, hist: "std/2"},
		})},
		// Mixed exponential SCHEMAS, which is upstream's own TODO: the schema is reduced
		// on the fly during the pairwise Sub/Add rather than pre-scanned as histogramRate
		// does. Pinned so the divergence cannot drift silently.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/1"}, {t: -200_000, hist: "zeroneg"},
			{t: -100_000, hist: "std/2"}, {t: 100_000, hist: "zeroneg"},
		})},
		// Zero and negative buckets across a boundary.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "zeroneg"}, {t: -100_000, hist: "zeroneg"},
			{t: 100_000, hist: "zeroneg"},
		})},
		// An EMPTY histogram in the middle, which is a reset against anything.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "std/2"}, {t: -200_000, hist: "empty"},
			{t: -100_000, hist: "std/1"}, {t: 100_000, hist: "std/2"},
		})},
		// A NaN sum, and tiny beside huge so the interpolation's fraction is applied to
		// buckets of wildly different magnitudes.
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "nansum"}, {t: -100_000, hist: "nansum"},
			{t: 100_000, hist: "negonly"},
		})},
		{otSeries(metric, []otPoint{
			{t: -400_000, hist: "tiny"}, {t: -200_000, hist: "huge"},
			{t: -100_000, hist: "tiny"}, {t: 100_000, hist: "huge"},
		})},
		// Sub-second spacing at both boundaries, where the interpolation's Δt is 1ms out
		// of 2ms — the fraction is 0.5 but the arithmetic runs on the real timestamps.
		{otSeries(metric, []otPoint{
			{t: -298_501, hist: "std/0"}, {t: -298_499, hist: "std/1"},
			{t: 1499, hist: "std/2"}, {t: 1501, hist: "std/3"},
		})},
		// With the metadata labels, so every warning above carries a metric name.
		{otSeries(withMetadata, []otPoint{
			{t: -400_000, hist: "std/1"}, {t: -200_000, hist: "custom"},
			{t: -100_000, hist: "std/2"},
		})},
	}
	for _, fn := range []string{"rate", "increase", "delta"} {
		for _, sel := range []string{
			"[5m] anchored", "[5m] smoothed", "[2m] anchored", "[2m] smoothed",
			"[5m] anchored offset 1m", "[5m] smoothed offset 1m",
		} {
			for _, m := range extendedHistMatrices {
				emit(fnIn{
					Fn: fn, Ts: "1500",
					Expr:     fn + "(http_requests_total" + sel + ")",
					Args:     [][]fnSampleIn{},
					MatrixIn: m,
				})
			}
		}
	}
}
