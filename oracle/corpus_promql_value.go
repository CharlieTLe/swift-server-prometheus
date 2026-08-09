package main

import (
	"fmt"
	"math"
)

// The corpus for the promql/value suites.
//
// Hand-built, because each case exists to reach one branch or one formatting edge.
//
// The float cases matter more than they look: this file's String() methods use
// strconv.FormatFloat(v, 'f', -1, 64), and the 'f' format has no exponent — so 1e21
// renders as 22 digits and 1e-7 as a long run of zeros, where the 'g' format used
// almost everywhere else in this port would give "1e+21". ADR-4.

type valueCase struct {
	id string
	in valueIn
}

type valueSortCase struct {
	id string
	in sortIn
}

type storageSeriesCase struct {
	id string
	in storageSeriesIn
}

// Float values chosen for the 'f' formatter's edges: signed zero, the exponent
// boundaries where 'f' stops being compact, the specials, and a value whose
// shortest representation needs 17 significant digits.
func valueFloats() []float64 {
	return []float64{
		0, negZero(), 1, -1, 0.5, -0.5, 1.5, 2, 3.1415926535897932,
		1e-7, 1e-5, 0.000012345, 1234.5, 1e21, 1e-21, 1.7976931348623157e308,
		5e-324, 0.1, 0.2, 0.3, 1.0000000000000002,
		nan(), inf(1), inf(-1),
	}
}

// math.Copysign, not `-1 * 0.0`: Go folds the latter with arbitrary-precision
// untyped constants, where -1 * 0 is exactly 0 and carries no sign, so it silently
// yields +0. Caught by the fixture showing "0" where "-0" was expected.
func negZero() float64 { return math.Copysign(0, -1) }

// Label sets chosen to discriminate BYTE ordering from Unicode collation, which is
// ADR-10's whole point: 'A' (0x41) sorts before 'a' (0x61) by byte, and "é"
// (0xC3 0xA9) sorts AFTER "z" (0x7A) by byte even though a collating sequence puts
// it next to "e".
func orderingMetrics() [][]string {
	return [][]string{
		{"__name__", "a"},
		{"__name__", "A"},
		{"__name__", "b"},
		{"__name__", "z"},
		{"__name__", "é"},
		{"__name__", "ab"},
		{"__name__", "a", "x", "1"},
		{"__name__", "a", "x", "2"},
		{"__name__", "a", "w", "9"},
		{"__name__", ""},
		{"x", "1"},
		{},
	}
}

// ------------------------------------------------------------- value corpus

func valueCases() []valueCase {
	var cases []valueCase
	add := func(id string, in valueIn) { cases = append(cases, valueCase{id: id, in: in}) }

	// StringValue: String() is the bare value, with the timestamp dropped
	// entirely. Includes an empty string and one that needs no escaping but
	// contains a newline, since nothing quotes it.
	for i, s := range []string{"", "hello", "with space", "with\nnewline", `with"quote`, "héllo"} {
		add(fmt.Sprintf("string/%d", i), valueIn{
			Kind: "string", Str: &stringValueJSON{T: i64(1000), V: s},
		})
	}
	add("string/negative-ts", valueIn{
		Kind: "string", Str: &stringValueJSON{T: i64(-1), V: "x"},
	})

	// Scalar and FPoint share the formatter but not the surrounding text.
	for i, f := range valueFloats() {
		add(fmt.Sprintf("scalar/%d", i), valueIn{
			Kind: "scalar", Scalar: &pointJSON{T: i64(1000), F: fbits(f)},
		})
		add(fmt.Sprintf("fpoint/%d", i), valueIn{
			Kind: "fpoint", Point: &pointJSON{T: i64(1000), F: fbits(f)},
		})
	}
	// Timestamp edges, which render through %v on an int64.
	for i, t := range []int64{0, 1, -1, 1000, -1000, 1136239445000, 9223372036854775807, -9223372036854775808} {
		add(fmt.Sprintf("scalar/ts/%d", i), valueIn{
			Kind: "scalar", Scalar: &pointJSON{T: i64(t), F: fbits(1.5)},
		})
	}

	// HPoint renders the histogram through its own String(), which Phase 3 pinned,
	// plus the timestamp. Its size() is observed through TotalSamples.
	for _, h := range []int{3, 4, 5} {
		add(fmt.Sprintf("hpoint/%d", h), valueIn{
			Kind: "hpoint", HPoint: &hpointJSON{T: i64(1000), Hist: h},
		})
	}

	// Sample: float and histogram forms, with and without a metric, and with
	// dropName set (which String() ignores — worth pinning that it does).
	add("sample/float", valueIn{Kind: "sample", Sample: &sampleJSONValue{
		Metric: []string{"__name__", "x", "job", "j"}, T: i64(1000), F: fbits(2.5),
	}})
	add("sample/float-empty-metric", valueIn{Kind: "sample", Sample: &sampleJSONValue{
		T: i64(1000), F: fbits(2.5),
	}})
	add("sample/float-dropname", valueIn{Kind: "sample", Sample: &sampleJSONValue{
		Metric: []string{"__name__", "x"}, T: i64(1000), F: fbits(2.5), DropName: true,
	}})
	add("sample/histogram", valueIn{Kind: "sample", Sample: &sampleJSONValue{
		Metric: []string{"__name__", "x"}, T: i64(1000), Hist: 3,
	}})
	add("sample/histogram-nan-sum", valueIn{Kind: "sample", Sample: &sampleJSONValue{
		Metric: []string{"__name__", "x"}, T: i64(1000), Hist: 4,
	}})
	for i, f := range []float64{nan(), inf(1), inf(-1), negZero()} {
		add(fmt.Sprintf("sample/special/%d", i), valueIn{Kind: "sample", Sample: &sampleJSONValue{
			Metric: []string{"__name__", "x"}, T: i64(1000), F: fbits(f),
		}})
	}

	// Series. The empty case is the interesting one: String() still emits the
	// trailing newline after "=>", so it ends with a blank line.
	add("series/empty", valueIn{Kind: "series", Series: &seriesJSON{
		Metric: []string{"__name__", "x"},
	}})
	add("series/floats", valueIn{Kind: "series", Series: &seriesJSON{
		Metric: []string{"__name__", "x"},
		Floats: []pointJSON{
			{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)},
			{T: i64(2000), F: fbits(3.5)},
		},
	}})
	add("series/histograms", valueIn{Kind: "series", Series: &seriesJSON{
		Metric:     []string{"__name__", "x"},
		Histograms: []hpointJSON{{T: i64(0), Hist: 3}, {T: i64(1000), Hist: 5}},
	}})
	// Mixed: floats are rendered first and then histograms, NOT merged by
	// timestamp — upstream's own TODO wonders about that, and this pins the
	// current behaviour.
	add("series/mixed", valueIn{Kind: "series", Series: &seriesJSON{
		Metric:     []string{"__name__", "x"},
		Floats:     []pointJSON{{T: i64(1000), F: fbits(1)}, {T: i64(3000), F: fbits(2)}},
		Histograms: []hpointJSON{{T: i64(0), Hist: 3}, {T: i64(2000), Hist: 4}},
	}})
	add("series/no-metric", valueIn{Kind: "series", Series: &seriesJSON{
		Floats: []pointJSON{{T: i64(0), F: fbits(1)}},
	}})

	// Vector. TotalSamples weighs histograms by H.Size()/16 — note WITHOUT the
	// +8 that HPoint.size applies, which is why the matrix cases below differ.
	add("vector/empty", valueIn{Kind: "vector", Vector: []sampleJSONValue{}})
	add("vector/one", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
	}})
	add("vector/two-distinct", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
		{Metric: []string{"__name__", "b"}, T: i64(1000), F: fbits(2)},
	}})
	// The len == 2 branch compares hashes directly rather than going through a map.
	add("vector/two-same", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(2)},
	}})
	// Three or more takes the map branch.
	add("vector/three-distinct", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
		{Metric: []string{"__name__", "b"}, T: i64(1000), F: fbits(2)},
		{Metric: []string{"__name__", "c"}, T: i64(1000), F: fbits(3)},
	}})
	add("vector/three-with-duplicate", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
		{Metric: []string{"__name__", "b"}, T: i64(1000), F: fbits(2)},
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(3)},
	}})
	add("vector/histograms", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), Hist: 3},
		{Metric: []string{"__name__", "b"}, T: i64(1000), Hist: 4},
	}})
	add("vector/mixed", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{Metric: []string{"__name__", "a"}, T: i64(1000), F: fbits(1)},
		{Metric: []string{"__name__", "b"}, T: i64(1000), Hist: 5},
	}})
	add("vector/empty-metrics", valueIn{Kind: "vector", Vector: []sampleJSONValue{
		{T: i64(1000), F: fbits(1)},
		{T: i64(1000), F: fbits(2)},
	}})

	// Matrix. TotalSamples here DOES go through HPoint.size, so the histogram
	// cases should not agree with the vector ones above.
	add("matrix/empty", valueIn{Kind: "matrix", Matrix: []seriesJSON{}})
	add("matrix/one", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(1)}}},
	}})
	add("matrix/two-distinct", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(1)}}},
		{Metric: []string{"__name__", "b"}, Floats: []pointJSON{{T: i64(0), F: fbits(2)}}},
	}})
	add("matrix/two-same", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(1)}}},
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(2)}}},
	}})
	add("matrix/three-with-duplicate", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(1)}}},
		{Metric: []string{"__name__", "b"}, Floats: []pointJSON{{T: i64(0), F: fbits(2)}}},
		{Metric: []string{"__name__", "a"}, Floats: []pointJSON{{T: i64(0), F: fbits(3)}}},
	}})
	add("matrix/histograms", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}, Histograms: []hpointJSON{
			{T: i64(0), Hist: 3}, {T: i64(1000), Hist: 4},
		}},
	}})
	add("matrix/mixed", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{
			Metric:     []string{"__name__", "a"},
			Floats:     []pointJSON{{T: i64(0), F: fbits(1)}},
			Histograms: []hpointJSON{{T: i64(1000), Hist: 5}},
		},
		{Metric: []string{"__name__", "b"}, Floats: []pointJSON{{T: i64(0), F: fbits(2)}}},
	}})
	add("matrix/empty-series", valueIn{Kind: "matrix", Matrix: []seriesJSON{
		{Metric: []string{"__name__", "a"}},
		{Metric: []string{"__name__", "b"}},
	}})

	return cases
}

// -------------------------------------------------------- value-sort corpus

func valueSortCases() []valueSortCase {
	var cases []valueSortCase
	add := func(id string, in sortIn) { cases = append(cases, valueSortCase{id: id, in: in}) }

	all := orderingMetrics()

	// Every pair, both ways round, so the comparator's sign is pinned in both
	// directions rather than only where the input happened to be sorted already.
	for i := range all {
		for j := range all {
			if i == j {
				continue
			}
			add(fmt.Sprintf("pair/%d-%d", i, j), sortIn{Matrix: []seriesJSON{
				{Metric: all[i]}, {Metric: all[j]},
			}})
		}
	}

	// The whole set at once, in the order given and reversed.
	forward := make([]seriesJSON, 0, len(all))
	backward := make([]seriesJSON, 0, len(all))
	for i := range all {
		forward = append(forward, seriesJSON{Metric: all[i]})
		backward = append(backward, seriesJSON{Metric: all[len(all)-1-i]})
	}
	add("all/forward", sortIn{Matrix: forward})
	add("all/backward", sortIn{Matrix: backward})
	add("empty", sortIn{Matrix: []seriesJSON{}})

	return cases
}

// ---------------------------------------------------- storage-series corpus

func storageSeriesCases() []storageSeriesCase {
	var cases []storageSeriesCase
	add := func(id string, in storageSeriesIn) {
		cases = append(cases, storageSeriesCase{id: id, in: in})
	}

	// A walk that reads BEFORE advancing would be wrong here: unlike the
	// look-back wrappers, this iterator starts before the first element, so the
	// first next() is required. And unlike them its At* read cached fields rather
	// than passing through, so reading after exhaustion is safe — currT simply
	// keeps its last value. Both directions are exercised below.
	walk := func(n int) []iterOp {
		ops := []iterOp{}
		for i := 0; i < n; i++ {
			ops = append(ops, op("next"), op("atT"), op("atST"), op("at"))
		}
		return append(ops, op("next"), op("atT"))
	}

	add("empty", storageSeriesIn{
		Series: seriesJSON{Metric: []string{"__name__", "x"}},
		Ops:    []iterOp{op("next"), op("atT"), op("err")},
	})
	add("floats-only", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{
				{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)},
				{T: i64(2000), F: fbits(3)},
			},
		},
		Ops: walk(3),
	})
	add("histograms-only", storageSeriesIn{
		Series: seriesJSON{
			Metric:     []string{"__name__", "x"},
			Histograms: []hpointJSON{{T: i64(0), Hist: 3}, {T: i64(1000), Hist: 4}},
		},
		Ops: []iterOp{
			op("next"), op("atT"), op("atFloatHistogram"),
			op("next"), op("atT"), op("atFloatHistogram"),
			op("next"), op("atT"),
		},
	})
	// Interleaved: the merge picks whichever stream is earlier.
	add("interleaved", storageSeriesIn{
		Series: seriesJSON{
			Metric:     []string{"__name__", "x"},
			Floats:     []pointJSON{{T: i64(1000), F: fbits(1)}, {T: i64(3000), F: fbits(2)}},
			Histograms: []hpointJSON{{T: i64(0), Hist: 3}, {T: i64(2000), Hist: 4}},
		},
		Ops: []iterOp{
			op("next"), op("atT"), op("next"), op("atT"), op("next"), op("atT"),
			op("next"), op("atT"), op("next"), op("atT"),
		},
	})
	// Ties: at an equal timestamp the FLOAT is yielded first (value.go:557-560).
	add("tie-float-wins", storageSeriesIn{
		Series: seriesJSON{
			Metric:     []string{"__name__", "x"},
			Floats:     []pointJSON{{T: i64(1000), F: fbits(7)}},
			Histograms: []hpointJSON{{T: i64(1000), Hist: 3}},
		},
		Ops: []iterOp{
			op("next"), op("atT"), op("at"),
			op("next"), op("atT"), op("atFloatHistogram"),
			op("next"), op("atT"),
		},
	})
	add("tie-repeated", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{
				{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)},
			},
			Histograms: []hpointJSON{{T: i64(0), Hist: 3}, {T: i64(1000), Hist: 4}},
		},
		Ops: []iterOp{
			op("next"), op("atT"), op("next"), op("atT"), op("next"), op("atT"),
			op("next"), op("atT"), op("next"), op("atT"),
		},
	})

	// Seek. Note the first seek on a fresh iterator always advances at least once,
	// because currT starts at math.MinInt64.
	add("seek/forward", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{
				{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)},
				{T: i64(2000), F: fbits(3)}, {T: i64(3000), F: fbits(4)},
			},
		},
		Ops: []iterOp{opArg("seek", 1500), op("atT"), op("at"), op("next"), op("atT")},
	})
	add("seek/exact", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)}},
		},
		Ops: []iterOp{opArg("seek", 1000), op("atT"), opArg("seek", 1000), op("atT")},
	})
	add("seek/backwards-is-a-noop", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{
				{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)},
				{T: i64(2000), F: fbits(3)},
			},
		},
		Ops: []iterOp{
			opArg("seek", 2000), op("atT"), opArg("seek", 0), op("atT"),
		},
	})
	add("seek/past-end", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{{T: i64(0), F: fbits(1)}, {T: i64(1000), F: fbits(2)}},
		},
		Ops: []iterOp{opArg("seek", 999999), opArg("seek", 0), op("next")},
	})
	add("seek/empty", storageSeriesIn{
		Series: seriesJSON{Metric: []string{"__name__", "x"}},
		Ops:    []iterOp{opArg("seek", 0), op("next")},
	})
	add("seek/onto-histogram", storageSeriesIn{
		Series: seriesJSON{
			Metric:     []string{"__name__", "x"},
			Floats:     []pointJSON{{T: i64(0), F: fbits(1)}},
			Histograms: []hpointJSON{{T: i64(2000), Hist: 3}},
		},
		Ops: []iterOp{
			opArg("seek", 1000), op("atT"), op("atFloatHistogram"), op("next"),
		},
	})
	add("seek/negative", storageSeriesIn{
		Series: seriesJSON{
			Metric: []string{"__name__", "x"},
			Floats: []pointJSON{{T: i64(-5000), F: fbits(1)}, {T: i64(0), F: fbits(2)}},
		},
		Ops: []iterOp{opArg("seek", -9223372036854775808), op("atT"), op("at")},
	})

	return cases
}
