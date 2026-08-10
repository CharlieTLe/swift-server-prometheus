package main

// Differential coverage for promql/functions.go's four sorts, through `FunctionCalls`.
// Reuses the wire types of oracle/suites_promql_functions_elementwise.go.
//
// ## These cases must NOT set `Sorted`
//
// Every other family that could produce an ambiguous order sorts the fixture's samples
// before recording them, because the order came out of a Go map. Here the order IS the
// output. Sorting it would delete the entire behaviour under test.
//
// ## What has to be reached
//
//   - ties. A vector of distinct values pins nothing about the algorithm; equal values
//     with different metrics are the whole point, and there have to be enough of them to
//     get past insertion sort (>12) and into the ninther (>=50);
//   - NaN, which both value comparators special-case with a bare `return true`, so a NaN
//     compares "less" than everything including another NaN. Leading, trailing,
//     scattered, and all-NaN;
//   - histograms. `sort`/`sort_desc` DROP them through filterFloats with no annotation,
//     `sort_by_label`/`_desc` keep them — so a mixed vector separates the two families;
//   - a non-empty `enh.Out`, because all four ignore it rather than appending. Every
//     other function in the table appends;
//   - for sort_by_label: a label absent from some series (Get returns ""), several label
//     arguments where the first ties, NO label arguments at all (so the comparator falls
//     straight through to labels.Compare), and values whose natural order differs from
//     their lexical order;
//   - label values that tie under natsort but differ as strings — "a1" versus "a01" —
//     which is where the comparator returns -1 in both directions and the pdqsort's
//     tie-breaking becomes observable through PromQL itself.

import (
	"fmt"
	"math"
)

// sortFnSample is one input sample: a metric plus either a float or a histogram.
func sortFnVector(samples ...fnSampleIn) []fnSampleIn {
	return samples
}

func sortFnFloat(name string, extra []string, f float64) fnSampleIn {
	m := []string{"__name__", name}
	m = append(m, extra...)
	return fnSampleIn{Metric: m, T: "1000", F: fbits(f)}
}

func sortFnHist(name string, extra []string, hist string) fnSampleIn {
	m := []string{"__name__", name}
	m = append(m, extra...)
	return fnSampleIn{Metric: m, T: "1000", HistRaw: hist}
}

// sortFnTies builds `n` samples that all share one value but differ in `instance`, so the
// only thing distinguishing them in the output is the algorithm's permutation.
func sortFnTies(n int, f float64) []fnSampleIn {
	out := make([]fnSampleIn, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, sortFnFloat("m", []string{"instance", fmt.Sprintf("i%02d", i)}, f))
	}
	return out
}

// sortFnRun builds `n` samples whose values come from `vals[i % len(vals)]`, each with a
// distinct `instance` — so ties are visible and the shape is controllable.
func sortFnRun(n int, vals []float64) []fnSampleIn {
	out := make([]fnSampleIn, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, sortFnFloat(
			"m", []string{"instance", fmt.Sprintf("i%02d", i)}, vals[i%len(vals)]))
	}
	return out
}

func genPromQLFunctionsSort(e *emitter) {
	n := 0
	emit := func(in fnIn) {
		// Deliberately NOT Sorted: see the file header.
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

	nan := math.NaN()
	inf := math.Inf(1)
	ninf := math.Inf(-1)

	// --- sort and sort_desc. One argument, and the output is the sorted vector.
	valueVectors := [][]fnSampleIn{
		{},
		sortFnVector(sortFnFloat("m", nil, 1)),
		sortFnVector(
			sortFnFloat("a", nil, 3), sortFnFloat("b", nil, 1), sortFnFloat("c", nil, 2)),
		// Already ascending, and already descending: the hints choosePivot can return.
		sortFnRun(20, []float64{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
			17, 18, 19}),
		sortFnRun(20, []float64{19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4,
			3, 2, 1, 0}),
		// TIES: every element equal. Sizes across insertion sort's 12 and the ninther's
		// 50, because the permutation of tied elements is what the algorithm decides.
		sortFnTies(3, 5),
		sortFnTies(12, 5),
		sortFnTies(13, 5),
		sortFnTies(49, 5),
		sortFnTies(50, 5),
		sortFnTies(60, 5),
		// A few distinct values, so partitionEqual runs.
		sortFnRun(30, []float64{1, 2, 1, 2}),
		sortFnRun(60, []float64{1, 2, 3, 4, 5}),
		// NaN leading, trailing, scattered, and everywhere. The comparators' `return
		// true` for a NaN on the left is what puts them at the bottom after the reverse.
		sortFnVector(
			sortFnFloat("a", nil, nan), sortFnFloat("b", nil, 1), sortFnFloat("c", nil, 2)),
		sortFnVector(
			sortFnFloat("a", nil, 1), sortFnFloat("b", nil, 2), sortFnFloat("c", nil, nan)),
		sortFnRun(20, []float64{1, nan, 2, nan, 3}),
		sortFnRun(15, []float64{nan}),
		// Infinities and signed zeros.
		sortFnVector(
			sortFnFloat("a", nil, inf), sortFnFloat("b", nil, ninf),
			sortFnFloat("c", nil, 0), sortFnFloat("d", nil, math.Copysign(0, -1)),
			sortFnFloat("e", nil, nan)),
		// Histograms only, and mixed: filterFloats drops them, with NO annotation.
		sortFnVector(sortFnHist("h", nil, "std/1"), sortFnHist("h2", nil, "custom")),
		sortFnVector(
			sortFnFloat("a", nil, 2), sortFnHist("h", nil, "std/1"),
			sortFnFloat("b", nil, 1)),
		// Metadata labels present, which these four do NOT drop — unlike every
		// element-wise function.
		sortFnVector(
			sortFnFloat("a", []string{"__type__", "counter", "__unit__", "s"}, 2),
			sortFnFloat("b", nil, 1)),
	}
	for _, fn := range []string{"sort", "sort_desc"} {
		for _, vec := range valueVectors {
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: fn, Delayed: delayed, Ts: "1500",
					Expr: fn + "(m)",
					Args: [][]fnSampleIn{vec},
				})
			}
		}
	}
	// A seeded enh.Out, which all four ignore.
	emit(fnIn{
		Fn: "sort", Ts: "1500", Expr: "sort(m)",
		Args: [][]fnSampleIn{sortFnVector(
			sortFnFloat("a", nil, 2), sortFnFloat("b", nil, 1))},
		Seed: []fnSampleIn{{Metric: []string{"job", "seed"}, T: "111", F: fbits(-99)}},
	})
	emit(fnIn{
		Fn: "sort_desc", Ts: "1500", Expr: "sort_desc(m)",
		Args: [][]fnSampleIn{sortFnVector(
			sortFnFloat("a", nil, 2), sortFnFloat("b", nil, 1))},
		Seed: []fnSampleIn{{Metric: []string{"job", "seed"}, T: "111", F: fbits(-99)}},
	})

	// --- sort_by_label and sort_by_label_desc. The vector is first and the label names
	// follow, so the expression carries them and `args[1:]` is what the body reads.
	type labelCase struct {
		expr string
		vec  []fnSampleIn
	}
	byLabel := []labelCase{
		// No label arguments at all: the comparator falls straight through to
		// labels.Compare.
		{`sort_by_label(m)`, sortFnVector(
			sortFnFloat("m", []string{"job", "b"}, 1),
			sortFnFloat("m", []string{"job", "a"}, 2))},
		// One label, lexically ordered.
		{`sort_by_label(m, "job")`, sortFnVector(
			sortFnFloat("m", []string{"job", "c"}, 1),
			sortFnFloat("m", []string{"job", "a"}, 2),
			sortFnFloat("m", []string{"job", "b"}, 3))},
		// NATURAL versus lexical order: "instance10" after "instance9".
		{`sort_by_label(m, "instance")`, sortFnVector(
			sortFnFloat("m", []string{"instance", "host10"}, 1),
			sortFnFloat("m", []string{"instance", "host9"}, 2),
			sortFnFloat("m", []string{"instance", "host1"}, 3),
			sortFnFloat("m", []string{"instance", "host100"}, 4))},
		// Values that tie under natsort but differ as strings — Compare is true in BOTH
		// directions, so the comparator says -1 either way and pdqsort decides.
		{`sort_by_label(m, "v")`, sortFnVector(
			sortFnFloat("m", []string{"v", "a1"}, 1),
			sortFnFloat("m", []string{"v", "a01"}, 2),
			sortFnFloat("m", []string{"v", "a001"}, 3),
			sortFnFloat("m", []string{"v", "a0001"}, 4))},
		// The same, long enough to leave insertion sort.
		{`sort_by_label(m, "v")`, func() []fnSampleIn {
			out := []fnSampleIn{}
			for i := 0; i < 30; i++ {
				zeros := ""
				for j := 0; j < i%5; j++ {
					zeros += "0"
				}
				out = append(out, sortFnFloat(
					"m",
					[]string{"v", "a" + zeros + "1", "instance", fmt.Sprintf("i%02d", i)},
					float64(i)))
			}
			return out
		}()},
		// A label MISSING from some series, where Get returns "" and the empty value
		// chunks to nothing.
		{`sort_by_label(m, "job")`, sortFnVector(
			sortFnFloat("m", []string{"job", "a"}, 1),
			sortFnFloat("m", []string{"other", "x"}, 2),
			sortFnFloat("m", []string{"job", ""}, 3))},
		// TWO labels, where the first ties for several series.
		{`sort_by_label(m, "job", "instance")`, sortFnVector(
			sortFnFloat("m", []string{"job", "a", "instance", "i2"}, 1),
			sortFnFloat("m", []string{"job", "a", "instance", "i10"}, 2),
			sortFnFloat("m", []string{"job", "a", "instance", "i1"}, 3),
			sortFnFloat("m", []string{"job", "b", "instance", "i1"}, 4))},
		// Every named label equal, so ONLY the labels.Compare fallback orders them —
		// including its negation in the _desc variant.
		{`sort_by_label(m, "job")`, sortFnVector(
			sortFnFloat("m", []string{"job", "a", "zz", "2"}, 1),
			sortFnFloat("m", []string{"job", "a", "zz", "1"}, 2),
			sortFnFloat("m", []string{"job", "a", "aa", "1"}, 3))},
		// Histograms are KEPT here, unlike sort/sort_desc.
		{`sort_by_label(m, "job")`, sortFnVector(
			sortFnHist("m", []string{"job", "b"}, "std/1"),
			sortFnFloat("m", []string{"job", "a"}, 2))},
		// Ties in the FULL label set: two identical metrics, which PromQL calls
		// undefined and the algorithm resolves anyway.
		{`sort_by_label(m, "job")`, sortFnVector(
			sortFnFloat("m", []string{"job", "a"}, 1),
			sortFnFloat("m", []string{"job", "a"}, 2))},
		// Empty vector, and a single sample.
		{`sort_by_label(m, "job")`, []fnSampleIn{}},
		{`sort_by_label(m, "job")`, sortFnVector(sortFnFloat("m", []string{"job", "a"}, 1))},
		// Enough tied series to reach the ninther.
		{`sort_by_label(m, "job")`, func() []fnSampleIn {
			out := []fnSampleIn{}
			for i := 0; i < 55; i++ {
				out = append(out, sortFnFloat(
					"m", []string{"job", "a", "instance", fmt.Sprintf("i%02d", i)},
					float64(i)))
			}
			return out
		}()},
		// Overflowing digit runs, where Atoi fails and the chunks compare as strings.
		{`sort_by_label(m, "v")`, sortFnVector(
			sortFnFloat("m", []string{"v", "9999999999999999999"}, 1),
			sortFnFloat("m", []string{"v", "10000000000000000000"}, 2),
			sortFnFloat("m", []string{"v", "999"}, 3))},
	}
	for _, fn := range []string{"sort_by_label", "sort_by_label_desc"} {
		for _, c := range byLabel {
			expr := c.expr
			if fn == "sort_by_label_desc" {
				expr = "sort_by_label_desc" + expr[len("sort_by_label"):]
			}
			// nargs is not read by these bodies — they read args[1:] themselves — but
			// the expr is what supplies them.
			for _, delayed := range []bool{false, true} {
				emit(fnIn{
					Fn: fn, Delayed: delayed, Ts: "1500",
					Expr: expr,
					Args: [][]fnSampleIn{c.vec},
				})
			}
		}
	}
}
