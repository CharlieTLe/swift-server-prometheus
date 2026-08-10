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
