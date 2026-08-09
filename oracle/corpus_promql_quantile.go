package main

// The corpus for the quantile suites.
//
// Every case exists to reach a specific branch. The interesting axes are:
//
//   - which interpolation runs: linear (custom buckets, or the zero bucket) versus
//     exponential (everything else), and the negative mirror of the latter
//   - which iterator direction HistogramQuantile picks: forward for a NaN Sum or
//     q < 0.5, reverse otherwise
//   - the monotonicity pass: a real decrease, a decrease small enough to be
//     absorbed as precision noise, both, and neither
//   - the special exits, each of which returns before the interpolation

import (
	"fmt"
	"math"
)

type bucketQuantileCase struct {
	id string
	in bucketQuantileIn
}

type bucketFractionCase struct {
	id string
	in bucketFractionIn
}

type histQuantileCase struct {
	id string
	in histQuantileIn
}

type histFractionCase struct {
	id string
	in histFractionIn
}

// The quantiles worth asking for: the special exits, the 0.5 boundary where
// HistogramQuantile flips iterator direction, and the interior.
func quantileValues() []float64 {
	return []float64{
		math.NaN(), -0.1, 0, 0.1, 0.25,
		math.Nextafter(0.5, math.Inf(-1)), 0.5, math.Nextafter(0.5, math.Inf(1)),
		0.75, 0.9, 0.95, 0.99, 1, 1.1,
	}
}

func bkt(upper, count float64) bucketJSON {
	return bucketJSON{UpperBound: fbits(upper), Count: fbits(count)}
}

// ---------------------------------------------------- BucketQuantile corpus

func bucketQuantileCases() []bucketQuantileCase {
	var cases []bucketQuantileCase
	add := func(id string, in bucketQuantileIn) {
		cases = append(cases, bucketQuantileCase{id: id, in: in})
	}

	inf := math.Inf(1)

	// A textbook cumulative histogram.
	normal := []bucketJSON{bkt(1, 10), bkt(2, 30), bkt(5, 45), bkt(10, 50), bkt(inf, 50)}
	// Only one real bucket beside +Inf, so `b == len-1` reports the second highest
	// bound.
	twoBucket := []bucketJSON{bkt(1, 5), bkt(inf, 5)}
	// A lowest bound at or below zero, which takes the `b == 0 && bound <= 0` exit.
	negativeLowest := []bucketJSON{bkt(-5, 4), bkt(0, 8), bkt(5, 12), bkt(inf, 12)}
	// Unsorted input, which the function sorts in place.
	unsorted := []bucketJSON{bkt(inf, 50), bkt(2, 30), bkt(10, 50), bkt(1, 10), bkt(5, 45)}
	// Two buckets sharing an upper bound, which coalesceBuckets merges. Exactly
	// two, never three: the sort is not stable, and summing three counts in an
	// unspecified order is not reproducible.
	duplicateBound := []bucketJSON{bkt(1, 10), bkt(1, 5), bkt(5, 30), bkt(inf, 30)}
	// A real decrease, forcing monotonicity.
	nonMonotonic := []bucketJSON{bkt(1, 20), bkt(2, 10), bkt(5, 30), bkt(inf, 30)}
	// Several decreases, so minBucket, maxBucket and maxDiff all differ.
	multiDecrease := []bucketJSON{
		bkt(1, 100), bkt(2, 40), bkt(5, 90), bkt(10, 20), bkt(20, 95), bkt(inf, 95),
	}
	// A decrease small enough for almost.Equal to absorb at 1e-12, so
	// fixedPrecision is set and forcedMonotonic is not.
	tinyDecrease := []bucketJSON{
		bkt(1, 100), bkt(2, 100*(1-1e-14)), bkt(5, 200), bkt(inf, 200),
	}
	// Both corrections in one input.
	bothFixes := []bucketJSON{
		bkt(1, 100), bkt(2, 100*(1-1e-14)), bkt(5, 50), bkt(10, 300), bkt(inf, 300),
	}
	// Zero observations, which exits NaN *after* the monotonicity pass.
	zeroObservations := []bucketJSON{bkt(1, 0), bkt(2, 0), bkt(inf, 0)}
	// A single bucket, so len < 2 after coalescing — again after the pass.
	onlyInf := []bucketJSON{bkt(inf, 10)}
	// No +Inf bucket at all, which exits NaN before the pass.
	noInf := []bucketJSON{bkt(1, 10), bkt(2, 20)}
	// Fractional counts, which is what a rate() of a histogram produces.
	fractional := []bucketJSON{
		bkt(0.1, 0.5), bkt(1, 1.25), bkt(10, 2.0/3.0+1), bkt(inf, 3.7),
	}
	// All buckets at the same count, so the search hits index 0.
	flat := []bucketJSON{bkt(1, 10), bkt(2, 10), bkt(5, 10), bkt(inf, 10)}

	named := []struct {
		name    string
		buckets []bucketJSON
	}{
		{"normal", normal},
		{"two-bucket", twoBucket},
		{"negative-lowest", negativeLowest},
		{"unsorted", unsorted},
		{"duplicate-bound", duplicateBound},
		{"non-monotonic", nonMonotonic},
		{"multi-decrease", multiDecrease},
		{"tiny-decrease", tinyDecrease},
		{"both-fixes", bothFixes},
		{"zero-observations", zeroObservations},
		{"only-inf", onlyInf},
		{"no-inf", noInf},
		{"fractional", fractional},
		{"flat", flat},
	}

	for _, n := range named {
		for qi, q := range quantileValues() {
			// BucketQuantile sorts and rewrites its input, so each case needs its
			// own copy.
			b := make([]bucketJSON, len(n.buckets))
			copy(b, n.buckets)
			add(fmt.Sprintf("%s/q%d", n.name, qi), bucketQuantileIn{Q: fbits(q), Buckets: b})
		}
	}

	return cases
}

// ---------------------------------------------------- BucketFraction corpus

func bucketFractionCases() []bucketFractionCase {
	var cases []bucketFractionCase
	add := func(id string, in bucketFractionIn) {
		cases = append(cases, bucketFractionCase{id: id, in: in})
	}

	inf := math.Inf(1)
	normal := []bucketJSON{bkt(1, 10), bkt(2, 30), bkt(5, 45), bkt(10, 50), bkt(inf, 50)}
	negative := []bucketJSON{bkt(-5, 4), bkt(0, 8), bkt(5, 12), bkt(inf, 12)}
	noInf := []bucketJSON{bkt(1, 10), bkt(2, 20)}
	zero := []bucketJSON{bkt(1, 0), bkt(inf, 0)}

	// The bound pairs: inside one bucket, spanning several, on a boundary exactly,
	// the infinite forms that skip interpolation, and the degenerate orders.
	bounds := [][2]float64{
		{math.Inf(-1), inf}, {math.Inf(-1), 2}, {2, inf},
		{0, 1}, {1, 2}, {1.5, 1.75}, {1, 1}, {2, 1},
		{-10, -1}, {-5, 0}, {0, 0}, {-1, 1},
		{0.5, 7.5}, {1, 10}, {10, 20},
		{math.NaN(), 1}, {1, math.NaN()}, {math.NaN(), math.NaN()},
	}

	named := []struct {
		name    string
		buckets []bucketJSON
	}{
		{"normal", normal}, {"negative", negative}, {"no-inf", noInf}, {"zero", zero},
	}

	for _, n := range named {
		for bi, b := range bounds {
			bs := make([]bucketJSON, len(n.buckets))
			copy(bs, n.buckets)
			add(fmt.Sprintf("%s/b%d", n.name, bi), bucketFractionIn{
				Lower: fbits(b[0]), Upper: fbits(b[1]), Buckets: bs,
			})
		}
	}

	return cases
}

// ------------------------------------------------ native histogram corpus

func span(offset int32, length uint32) spanJSON {
	return spanJSON{Offset: offset, Length: length}
}

func fbitsAll(vs ...float64) []string {
	out := make([]string, 0, len(vs))
	for _, v := range vs {
		out = append(out, fbits(v))
	}
	return out
}

// The histogram shapes that matter for interpolation.
func histSpecs() []struct {
	name string
	h    histSpecJSON
} {
	nan := math.NaN()
	return []struct {
		name string
		h    histSpecJSON
	}{
		// Positive exponential buckets only, so the zero bucket's lower bound
		// becomes 0 and the exponential path runs.
		{"positive-only", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(12), Sum: fbits(30),
			PositiveSpans:   []spanJSON{span(0, 3)},
			PositiveBuckets: fbitsAll(4, 5, 3),
		}},
		// Negative buckets only, which mirrors the interpolation.
		{"negative-only", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(9), Sum: fbits(-20),
			NegativeSpans:   []spanJSON{span(0, 3)},
			NegativeBuckets: fbitsAll(3, 4, 2),
		}},
		// Both sides plus a zero bucket, so a quantile can land in the zero bucket
		// and take the linear path.
		{"both-sides", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(6),
			Count: fbits(20), Sum: fbits(5),
			PositiveSpans:   []spanJSON{span(0, 2)},
			PositiveBuckets: fbitsAll(4, 3),
			NegativeSpans:   []spanJSON{span(0, 2)},
			NegativeBuckets: fbitsAll(5, 2),
		}},
		// A fine schema, where the bucket bounds are close together and the
		// exponential interpolation is most sensitive.
		{"schema-8", histSpecJSON{
			Schema: 8, ZeroThreshold: fbits(0.001), ZeroCount: fbits(1),
			Count: fbits(11), Sum: fbits(15),
			PositiveSpans:   []spanJSON{span(0, 5)},
			PositiveBuckets: fbitsAll(2, 3, 1, 4, 1),
		}},
		// A coarse schema, where they are far apart.
		{"schema-minus4", histSpecJSON{
			Schema: -4, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(7), Sum: fbits(1000),
			PositiveSpans:   []spanJSON{span(0, 3)},
			PositiveBuckets: fbitsAll(3, 2, 2),
		}},
		// Custom buckets, which always interpolate linearly and have their own
		// first/last-bucket exits.
		{"custom-buckets", histSpecJSON{
			Schema: -53, ZeroThreshold: fbits(0), ZeroCount: fbits(0),
			Count: fbits(10), Sum: fbits(25),
			PositiveSpans:   []spanJSON{span(0, 3)},
			PositiveBuckets: fbitsAll(4, 3, 3),
			CustomValues:    fbitsAll(1, 5, 10),
		}},
		// Custom buckets whose first bound is negative, so the -Inf lower bound
		// with a non-positive upper takes the early return.
		{"custom-negative", histSpecJSON{
			Schema: -53, ZeroThreshold: fbits(0), ZeroCount: fbits(0),
			Count: fbits(6), Sum: fbits(-10),
			PositiveSpans:   []spanJSON{span(0, 2)},
			PositiveBuckets: fbitsAll(4, 2),
			CustomValues:    fbitsAll(-5, 0),
		}},
		// A NaN Sum with a bucket total BELOW Count, which is the real
		// NaN-observation case: the forward iterator is forced and the skew
		// annotation fires.
		{"nan-sum-skewed", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(20), Sum: fbits(nan),
			PositiveSpans:   []spanJSON{span(0, 3)},
			PositiveBuckets: fbitsAll(4, 5, 3),
		}},
		// A NaN Sum whose buckets DO account for every observation, which means
		// the histogram merely saw -Inf and +Inf. No skew annotation.
		{"nan-sum-exact", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(12), Sum: fbits(nan),
			PositiveSpans:   []spanJSON{span(0, 3)},
			PositiveBuckets: fbitsAll(4, 5, 3),
		}},
		// Zero observations, the first special exit.
		{"empty", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(0), Sum: fbits(0),
		}},
		// A zero bucket only, so every quantile lands in it and interpolates
		// linearly between -threshold and +threshold.
		{"zero-bucket-only", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.5), ZeroCount: fbits(8),
			Count: fbits(8), Sum: fbits(0),
		}},
		// Empty buckets interleaved with populated ones, which the `count == 0`
		// skip has to step over.
		{"sparse", histSpecJSON{
			Schema: 0, ZeroThreshold: fbits(0.001), ZeroCount: fbits(0),
			Count: fbits(9), Sum: fbits(40),
			PositiveSpans:   []spanJSON{span(0, 2), span(3, 2)},
			PositiveBuckets: fbitsAll(4, 0, 3, 2),
		}},
	}
}

func histogramQuantileCases() []histQuantileCase {
	var cases []histQuantileCase
	add := func(id string, in histQuantileIn) {
		cases = append(cases, histQuantileCase{id: id, in: in})
	}

	for _, spec := range histSpecs() {
		for qi, q := range quantileValues() {
			add(fmt.Sprintf("%s/q%d", spec.name, qi), histQuantileIn{
				Q: fbits(q), H: spec.h, MetricName: "http_request_duration_seconds",
				Start: 0, End: 5,
			})
		}
		// An empty metric name changes the annotation text, via maybeAddMetricName.
		add(fmt.Sprintf("%s/no-name", spec.name), histQuantileIn{
			Q: fbits(0.9), H: spec.h, MetricName: "", Start: 0, End: 5,
		})
	}

	return cases
}

func histogramFractionCases() []histFractionCase {
	var cases []histFractionCase
	add := func(id string, in histFractionIn) {
		cases = append(cases, histFractionCase{id: id, in: in})
	}

	inf := math.Inf(1)
	bounds := [][2]float64{
		{math.Inf(-1), inf}, {math.Inf(-1), 1}, {1, inf},
		{0, 1}, {0.5, 2}, {1, 2}, {1, 1}, {2, 1},
		{-2, -0.5}, {-1, 1}, {0, 0}, {-inf, 0}, {0, inf},
		{0.25, 0.75}, {1.5, 4}, {2, 8},
		{math.NaN(), 1}, {1, math.NaN()},
	}

	for _, spec := range histSpecs() {
		for bi, b := range bounds {
			add(fmt.Sprintf("%s/b%d", spec.name, bi), histFractionIn{
				Lower: fbits(b[0]), Upper: fbits(b[1]), H: spec.h,
				MetricName: "http_request_duration_seconds", Start: 0, End: 5,
			})
		}
		add(fmt.Sprintf("%s/no-name", spec.name), histFractionIn{
			Lower: fbits(math.Inf(-1)), Upper: fbits(inf), H: spec.h,
			MetricName: "", Start: 0, End: 5,
		})
	}

	return cases
}
