package main

// Differential coverage for model/histogram/float_histogram.go, slice 6:
// TrimBuckets.
//
// The interesting risk here is not control flow but arithmetic. computeSplit's
// exponential branch calls math.Log2, which in Go is a PURE GO implementation
// (frexp, then Log(frac)*(1/Ln2)+exp, with an exact shortcut for frac == 0.5) —
// not a call into libm. If Swift's libm log2 disagrees by even one ULP, the
// interpolated bucket counts and the re-estimated Sum diverge, and only a
// bit-pattern comparison over a wide corpus will show it. Hence the trim points
// below cover many positions inside many buckets.

import (
	"fmt"
	"math"
	"math/rand"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/labels"
)

// trimCorpus are histograms whose buckets straddle interesting trim points.
func trimCorpus() []*histogram.FloatHistogram {
	var out []*histogram.FloatHistogram

	// Exponential, positive only, wide index range so bucket widths vary.
	for _, schema := range []int32{-4, -1, 0, 1, 3, 8} {
		buckets := make([]float64, 12)
		for i := range buckets {
			buckets[i] = float64(i+1) * 1.5
		}
		var count float64
		for _, v := range buckets {
			count += v
		}
		out = append(out, &histogram.FloatHistogram{
			Schema: schema, ZeroThreshold: 0.001, ZeroCount: 2,
			Count: count + 2, Sum: count * 2,
			PositiveSpans:   []histogram.Span{{Offset: -6, Length: 12}},
			PositiveBuckets: buckets,
		})
		// With negative buckets too, which use the mirrored interpolation.
		withNeg := out[len(out)-1].Copy()
		withNeg.NegativeSpans = []histogram.Span{{Offset: -6, Length: 12}}
		withNeg.NegativeBuckets = buckets
		withNeg.Count += count
		out = append(out, withNeg)
		// Negative only, so the zero bucket's upper half is clamped to 0.
		negOnly := &histogram.FloatHistogram{
			Schema: schema, ZeroThreshold: 0.001, ZeroCount: 2,
			Count: count + 2, Sum: -count,
			NegativeSpans:   []histogram.Span{{Offset: -6, Length: 12}},
			NegativeBuckets: buckets,
		}
		out = append(out, negOnly)
	}

	// Zero bucket only, so neither half is clamped.
	out = append(out, &histogram.FloatHistogram{
		Schema: 0, ZeroThreshold: 0.5, ZeroCount: 10, Count: 10, Sum: 0,
	})
	// A zero bucket with a zero threshold, where the interval is degenerate.
	out = append(out, &histogram.FloatHistogram{
		Schema: 0, ZeroThreshold: 0, ZeroCount: 10, Count: 10, Sum: 0,
	})

	// Buckets with empty ones interleaved, which TrimBuckets skips but Compact
	// then removes.
	out = append(out, &histogram.FloatHistogram{
		Schema: 0, Count: 6, Sum: 12,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 5}},
		PositiveBuckets: []float64{2, 0, 2, 0, 2},
	})
	// Multiple spans, so the iterator index and the bucket slice index diverge if
	// the port gets the cursor wrong.
	out = append(out, &histogram.FloatHistogram{
		Schema: 0, Count: 6, Sum: 12,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 3, Length: 2}},
		PositiveBuckets: []float64{1, 2, 2, 1},
		NegativeSpans:   []histogram.Span{{Offset: 1, Length: 2}, {Offset: 2, Length: 1}},
		NegativeBuckets: []float64{1, 1, 1},
	})

	// NHCB: linear interpolation, and the implicit ±Inf buckets that
	// handleInfinityBuckets deals with.
	out = append(out, &histogram.FloatHistogram{
		Schema: histogram.CustomBucketsSchema, Count: 10, Sum: 30,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 5}},
		PositiveBuckets: []float64{1, 2, 3, 3, 1},
		CustomValues:    []float64{1, 2, 5, 10},
	})
	// An NHCB whose first bucket starts at -Inf (index 0 with a -Inf lower bound)
	// and whose last is the implicit +Inf bucket.
	out = append(out, &histogram.FloatHistogram{
		Schema: histogram.CustomBucketsSchema, Count: 6, Sum: 6,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
		PositiveBuckets: []float64{1, 2, 3},
		CustomValues:    []float64{0.5, 1},
	})
	// NHCB with an explicit -Inf bound.
	out = append(out, &histogram.FloatHistogram{
		Schema: histogram.CustomBucketsSchema, Count: 6, Sum: 6,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
		PositiveBuckets: []float64{1, 2, 3},
		CustomValues:    []float64{math.Inf(-1), 2},
	})
	// NHCB with negative bounds, so the kept interval can be entirely negative.
	out = append(out, &histogram.FloatHistogram{
		Schema: histogram.CustomBucketsSchema, Count: 6, Sum: -6,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 4}},
		PositiveBuckets: []float64{1, 2, 2, 1},
		CustomValues:    []float64{-10, -5, -1},
	})
	// Fractional counts, so the interpolated fraction is not a round number.
	out = append(out, &histogram.FloatHistogram{
		Schema: 0, Count: 1.75, Sum: 3.5,
		PositiveSpans:   []histogram.Span{{Offset: -2, Length: 4}},
		PositiveBuckets: []float64{0.25, 0.5, 0.75, 0.25},
	})

	// A seeded fuzz.
	r := rand.New(rand.NewSource(20260812))
	for i := 0; i < 60; i++ {
		spans := randSpans(r, true, false)
		n, _ := spanTotals(spans)
		buckets := make([]float64, n)
		var count float64
		for j := range buckets {
			buckets[j] = float64(r.Intn(40)) / 4
			count += buckets[j]
		}
		nSpans := randSpans(r, true, false)
		nn, _ := spanTotals(nSpans)
		nBuckets := make([]float64, nn)
		for j := range nBuckets {
			nBuckets[j] = float64(r.Intn(40)) / 4
			count += nBuckets[j]
		}
		zc := float64(r.Intn(8)) / 2
		out = append(out, &histogram.FloatHistogram{
			Schema:        int32(r.Intn(9)) - 4,
			ZeroThreshold: corpusZeroThresholds[r.Intn(len(corpusZeroThresholds))],
			ZeroCount:     zc,
			Count:         count + zc,
			Sum:           count,
			PositiveSpans: spans, PositiveBuckets: buckets,
			NegativeSpans: nSpans, NegativeBuckets: nBuckets,
		})
	}

	return out
}

// trimPoints are the rhs values. They deliberately land on bucket boundaries, at
// many positions strictly inside buckets (to exercise interpolation), and outside
// the histogram entirely.
var trimPoints = []float64{
	0, 1, 2, 4, 8, 16, 0.5, 0.25, 0.125,
	-1, -2, -4, -0.5, -0.25,
	// Strictly inside schema-0 buckets, at several fractions of the width.
	1.5, 2.5, 3, 3.5, 5, 6, 7, 12, 1.1, 1.9, 2.1, 3.9,
	-1.5, -2.5, -3, -5, -6, -1.1, -3.9,
	// Inside the zero bucket for the thresholds in use.
	0.0005, 0.001, 0.0015, 0.3, 0.4999, -0.0005, -0.3,
	// Irrational-ish points, where Log2 precision shows up.
	1.0 / 3.0, 2.0 / 3.0, 1.7320508075688772, 2.718281828459045, 3.141592653589793,
	// Extremes.
	math.Inf(1), math.Inf(-1), math.MaxFloat64, -math.MaxFloat64,
	4.9e-324, math.Copysign(0, -1), math.NaN(),
}

func genFloatHistogramTrim(e *emitter) {
	type in struct {
		H           floatHistJSON `json:"h"`
		Rhs         string        `json:"rhs"`
		IsUpperTrim bool          `json:"isUpperTrim"`
	}
	i := 0
	for _, h := range trimCorpus() {
		for _, rhs := range trimPoints {
			for _, isUpperTrim := range []bool{true, false} {
				e.emit(fmt.Sprintf("t/%d", i),
					in{H: toFloatHistJSON(h), Rhs: hexFloat(rhs), IsUpperTrim: isUpperTrim},
					toFloatHistJSON(h.TrimBuckets(rhs, isUpperTrim)))
				i++
			}
		}
	}
}

// genGoLog2 isolates Go's math.Log2 over the values computeSplit feeds it.
//
// Go implements Log2 itself rather than calling libm, so a platform libm log2 can
// differ by an ULP. If the trim suite ever disagrees, this suite says immediately
// whether the cause is Log2 or the surrounding logic.
func genGoLog2(e *emitter) {
	seen := map[float64]bool{}
	emit := func(v float64) {
		if seen[v] {
			return
		}
		seen[v] = true
		e.emit(fmt.Sprintf("l/%d", len(seen)-1), hexFloat(v), hexFloat(math.Log2(v)))
	}
	// Every bucket bound computeSplit can see, across schemas and indices.
	for _, schema := range []int32{-4, -1, 0, 1, 3, 8} {
		h := &histogram.FloatHistogram{
			Schema:          schema,
			PositiveSpans:   []histogram.Span{{Offset: -20, Length: 40}},
			PositiveBuckets: make([]float64, 40),
		}
		for it := h.PositiveBucketIterator(); it.Next(); {
			b := it.At()
			emit(math.Abs(b.Lower))
			emit(math.Abs(b.Upper))
		}
	}
	// Every trim point, as computeSplit takes Abs(rhs).
	for _, v := range trimPoints {
		emit(math.Abs(v))
	}
	// Exact powers of two, which take Go's frac == 0.5 shortcut, plus their
	// neighbours, which do not.
	for exp := -30; exp <= 30; exp++ {
		v := math.Ldexp(1, exp)
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
	}
	// Subnormals and the extremes.
	emit(4.9e-324)
	emit(math.SmallestNonzeroFloat64 * 3)
	emit(math.MaxFloat64)
	emit(0)
	emit(math.Inf(1))
	emit(math.NaN())
	// A seeded spread across the whole exponent range.
	r := rand.New(rand.NewSource(20260813))
	for i := 0; i < 2000; i++ {
		emit(math.Ldexp(1+r.Float64(), r.Intn(600)-300))
	}
}

// MARK: - histogram/nhcb-classic

// genNHCBToClassic pins convert.go's ConvertNHCBToClassic, for both the integer
// and the float histogram, by recording every series it emits in order.
func genNHCBToClassic(e *emitter) {
	type series struct {
		Labels string `json:"labels"`
		Value  string `json:"value"`
	}
	type in struct {
		// Exactly one of these is set, mirroring Go's `nhcb any` parameter.
		Int   *histJSON      `json:"int"`
		Float *floatHistJSON `json:"float"`
		Lset  string         `json:"lset"`
	}
	type out struct {
		Series []series `json:"series"`
		Err    string   `json:"err"`
	}

	labelSets := []labels.Labels{
		labels.FromStrings("__name__", "http_request_duration_seconds"),
		labels.FromStrings("__name__", "rq", "job", "api", "instance", "a:1"),
		// No metric name, which is rejected.
		labels.FromStrings("job", "api"),
		// A name that needs quoting when rendered, and a UTF-8 label.
		labels.FromStrings("__name__", "with.dot", "héllo", "wörld"),
	}

	// Integer NHCBs, including deltas, gaps between spans, and a leading offset —
	// the integer branch walks span offsets explicitly to fill the gaps.
	intHists := []*histogram.Histogram{
		{
			Schema: histogram.CustomBucketsSchema, Count: 6, Sum: 19.4,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []int64{1, 1, 1},
			CustomValues:    []float64{1, 2, 5},
		},
		// A leading offset and a gap between spans: the integer branch fills the
		// gap buckets with the running total, unlike the float branch.
		{
			Schema: histogram.CustomBucketsSchema, Count: 5, Sum: 10,
			PositiveSpans:   []histogram.Span{{Offset: 1, Length: 2}, {Offset: 1, Length: 1}},
			PositiveBuckets: []int64{2, 0, -1},
			CustomValues:    []float64{0.5, 1, 2.5, 10},
		},
		// The +Inf bucket carries everything, since no bound covers it.
		{
			Schema: histogram.CustomBucketsSchema, Count: 3, Sum: 300,
			PositiveSpans:   []histogram.Span{{Offset: 2, Length: 1}},
			PositiveBuckets: []int64{3},
			CustomValues:    []float64{1, 2},
		},
		// Empty, and an invalid one that Validate rejects.
		{Schema: histogram.CustomBucketsSchema},
		{
			Schema: histogram.CustomBucketsSchema, Count: 99,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []int64{1, 1},
			CustomValues:    []float64{1, 2},
		},
		// An exponential histogram, which is not an NHCB.
		{
			Schema: 0, Count: 2, PositiveSpans: []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{2},
		},
	}

	// Float NHCBs. The float branch skips gaps instead of filling them, so the
	// same layouts exercise a different code path.
	floatHists := []*histogram.FloatHistogram{
		{
			Schema: histogram.CustomBucketsSchema, Count: 6, Sum: 19.4,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{1, 2, 3},
			CustomValues:    []float64{1, 2, 5},
		},
		// The same layout as the integer case above, so the two branches' differing
		// treatment of span gaps is visible side by side.
		{
			Schema: histogram.CustomBucketsSchema, Count: 5, Sum: 10,
			PositiveSpans:   []histogram.Span{{Offset: 1, Length: 2}, {Offset: 1, Length: 1}},
			PositiveBuckets: []float64{2, 2, 1},
			CustomValues:    []float64{0.5, 1, 2.5, 10},
		},
		{
			Schema: histogram.CustomBucketsSchema, Count: 3, Sum: 300,
			PositiveSpans:   []histogram.Span{{Offset: 2, Length: 1}},
			PositiveBuckets: []float64{3},
			CustomValues:    []float64{1, 2},
		},
		{Schema: histogram.CustomBucketsSchema},
		// Fractional and extreme values, where FormatOpenMetricsFloat matters.
		{
			Schema: histogram.CustomBucketsSchema, Count: 3, Sum: 1.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{0.25, 0.5, 2.25},
			CustomValues:    []float64{0.001, 1, 1e300},
		},
		{
			Schema: 0, Count: 2, PositiveSpans: []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []float64{2},
		},
	}

	i := 0
	run := func(input in, nhcb any, lset labels.Labels) {
		builder := labels.NewBuilder(labels.FromStrings("pre", "existing"))
		var emitted []series
		err := histogram.ConvertNHCBToClassic(nhcb, lset, builder,
			func(l labels.Labels, v float64) error {
				emitted = append(emitted, series{Labels: l.String(), Value: hexFloat(v)})
				return nil
			})
		o := out{Series: emitted, Err: errString(err)}
		if o.Series == nil {
			o.Series = []series{}
		}
		e.emit(fmt.Sprintf("nc/%d", i), input, o)
		i++
	}

	for _, lset := range labelSets {
		for _, h := range intHists {
			j := toHistJSON(h)
			run(in{Int: &j, Lset: lset.String()}, h, lset)
		}
		for _, h := range floatHists {
			j := toFloatHistJSON(h)
			run(in{Float: &j, Lset: lset.String()}, h, lset)
		}
	}
}
