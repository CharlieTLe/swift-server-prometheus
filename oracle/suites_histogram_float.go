package main

// Differential coverage for model/histogram/float_histogram.go, slice 1: the
// read-only surface — Copy, CopyTo, CopyToSchema, String, TestExpression,
// Equals, Size, Validate and every publicly reachable bucket iterator.
//
// NOT covered here: floatBucketIterator's merge path (targetSchema < schema) and
// its absoluteStartValue skipping. Both are unexported in Go and the only caller
// outside the package boundary is DetectReset, so they are pinned in slice 3
// with a corpus that deliberately varies schema and zero threshold between the
// two histograms.

import (
	"fmt"
	"math"
	"math/rand"

	"github.com/prometheus/prometheus/model/histogram"
)

// MARK: - Corpus

// floatStructuralHistograms are the hand-picked shapes: what upstream's own
// tests use, plus the float-specific values an integer histogram cannot reach.
func floatStructuralHistograms() []*histogram.FloatHistogram {
	return []*histogram.FloatHistogram{
		// ALL-ZERO buckets, which the exit gate found nothing covers: `Compact(0)` KEEPS them in
		// Go (`hrhs.Copy().Mul(0).Compact(0)` leaves `(0,3) [0,0,0]`), and ~30 of the gate's
		// assertions turn on it. Quirk 59's lesson in a third setting — a corpus built from
		// interesting *values* never builds an uninteresting one.
		{
			Schema: 0, ZeroThreshold: 0.001, ZeroCount: 0, Count: 0, Sum: 0,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{0, 0, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			NegativeBuckets: []float64{0, 0, 0},
		},
		// Zeros with a GAP, so span merging and zero-stripping are separable.
		{
			Schema: 0, ZeroThreshold: 0.001, Count: 0, Sum: 0,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 3, Length: 2}},
			PositiveBuckets: []float64{0, 0, 0, 0},
		},
		// Leading and trailing zeros around a real bucket.
		{
			Schema: 0, ZeroThreshold: 0.001, Count: 5, Sum: 3,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 5}},
			PositiveBuckets: []float64{0, 0, 5, 0, 0},
		},
		// An all-zero CUSTOM-buckets histogram, since compaction differs for those.
		{
			Schema: -53, Count: 0, Sum: 0,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{0, 0, 0},
			CustomValues:    []float64{1, 2, 5},
		},
		{},
		// float_histogram_test.go TestFloatHistogramString.
		{
			Schema:        0,
			Count:         21,
			Sum:           1234.5,
			ZeroThreshold: 0.001,
			ZeroCount:     4,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 3},
				{Offset: 1, Length: 1},
			},
			PositiveBuckets: []float64{1, 2, 1, 1},
			NegativeSpans: []histogram.Span{
				{Offset: 0, Length: 4},
				{Offset: 1, Length: 1},
			},
			NegativeBuckets: []float64{1, 3, 1, 2, 1},
		},
		// Fractional counts — the whole reason FloatHistogram exists.
		{
			Schema:          0,
			Count:           3.5,
			Sum:             7.25,
			ZeroThreshold:   0.001,
			ZeroCount:       0.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{0.5, 1.25, 1.25},
		},
		// Very small and very large bucket counts, where %g switches format.
		{
			Schema:          0,
			Count:           1e-300,
			Sum:             1e300,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{4.9e-324, 1e-300, math.MaxFloat64},
		},
		// Infinite bucket counts: HasOverflow, and %g on an infinity.
		{
			Schema:          0,
			Count:           math.Inf(1),
			Sum:             math.Inf(1),
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{math.Inf(1), 1},
		},
		// Negative zero in a bucket: != 0 is false, so String skips it, but the
		// bit pattern differs from +0 for Equals.
		{
			Schema:          0,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{math.Copysign(0, -1), 1},
			Count:           1,
		},
		// NaN sum (the stale-marker neighbourhood) and NaN in a bucket.
		{
			Schema:          0,
			Count:           1,
			Sum:             math.NaN(),
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []float64{1},
		},
		// Zero bucket only, and a zero threshold that is not a bucket boundary.
		{Schema: 0, Count: 4, Sum: 0.0004, ZeroThreshold: 0.001, ZeroCount: 4},
		{Schema: 0, Count: 4, Sum: 0.0004, ZeroThreshold: 0.0015, ZeroCount: 4},
		// Buckets that straddle the zero threshold — the AllBucketIterator clamps
		// their inner boundary to it.
		{
			Schema:          0,
			Count:           6,
			Sum:             0,
			ZeroThreshold:   0.5,
			ZeroCount:       2,
			PositiveSpans:   []histogram.Span{{Offset: -2, Length: 3}},
			PositiveBuckets: []float64{1, 1, 1},
			NegativeSpans:   []histogram.Span{{Offset: -2, Length: 1}},
			NegativeBuckets: []float64{1},
		},
		// Empty buckets in the middle, start and end of a span: Compact and
		// TestExpression both react to these.
		{
			Schema:          0,
			Count:           4,
			Sum:             2,
			PositiveSpans:   []histogram.Span{{Offset: 1, Length: 5}},
			PositiveBuckets: []float64{0, 0, 4, 0, 0},
		},
		// Zero-length spans, which spansMatch folds away.
		{
			Schema: 0,
			Count:  2,
			Sum:    2,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 0},
				{Offset: 2, Length: 2},
				{Offset: 0, Length: 0},
			},
			PositiveBuckets: []float64{2, 0},
		},
		// Two spans with a gap, which TestExpression has to merge into one.
		{
			Schema: 0,
			Count:  3,
			Sum:    3,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 2},
				{Offset: 3, Length: 1},
			},
			PositiveBuckets: []float64{1, 1, 1},
		},
		// The extreme indices, where getBound clamps to MaxFloat64.
		{
			Schema:          0,
			Count:           2,
			Sum:             math.MaxFloat64,
			PositiveSpans:   []histogram.Span{{Offset: 1023, Length: 2}},
			PositiveBuckets: []float64{1, 1},
		},
		{
			Schema:          8,
			Count:           2,
			Sum:             2,
			PositiveSpans:   []histogram.Span{{Offset: 262143, Length: 2}},
			PositiveBuckets: []float64{1, 1},
		},
		// Every counter reset hint, because TestExpression renders them.
		{Schema: 0, CounterResetHint: histogram.CounterReset, Count: 1, Sum: 1},
		{Schema: 0, CounterResetHint: histogram.NotCounterReset, Count: 1, Sum: 1},
		{Schema: 0, CounterResetHint: histogram.GaugeType, Count: 1, Sum: 1},
		// Custom buckets (NHCB).
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           5,
			Sum:             19.4,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []float64{1, 2, 1, 1},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		// NHCB with fractional bounds, which TestExpression prints with %g.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           3,
			Sum:             1.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{1, 1, 1},
			CustomValues:    []float64{0.001, 0.5, 1e300},
		},
		// NHCB reaching the implicit +Inf bucket.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           3,
			Sum:             10,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []float64{1, 1, 1},
			CustomValues:    []float64{0.5, 1},
		},
		// NHCB with an explicit -Inf first bound, which Validate allows.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           1,
			Sum:             1,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []float64{1},
			CustomValues:    []float64{math.Inf(-1), 1},
		},
		// Negative schemas, which take getBound's Ldexp path.
		{
			Schema:          -4,
			Count:           2,
			Sum:             2,
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 2}},
			PositiveBuckets: []float64{1, 1},
		},
		// Non-nil but empty slices.
		{
			Schema:          0,
			PositiveSpans:   []histogram.Span{},
			PositiveBuckets: []float64{},
		},
		{
			Schema:          0,
			PositiveSpans:   []histogram.Span{{Offset: 3, Length: 0}},
			PositiveBuckets: []float64{},
		},
	}
}

var floatCorpusBucketValues = []float64{
	0, 0.5, 1, 2.5, 17, 1e-300, 1e300, 4.9e-324, math.MaxFloat64, 0.1, 1.0 / 3.0,
}

// randomFloatHistograms generates float histograms that Validate accepts.
func randomFloatHistograms(r *rand.Rand, n int) []*histogram.FloatHistogram {
	out := make([]*histogram.FloatHistogram, 0, n)
	randBuckets := func(count int) []float64 {
		buckets := make([]float64, count)
		for i := range buckets {
			if r.Intn(4) == 0 {
				buckets[i] = 0
			} else {
				buckets[i] = floatCorpusBucketValues[r.Intn(len(floatCorpusBucketValues))]
			}
		}
		return buckets
	}
	for len(out) < n {
		h := &histogram.FloatHistogram{
			CounterResetHint: histogram.CounterResetHint(r.Intn(4)),
			Sum:              corpusSums[r.Intn(len(corpusSums))],
			Count:            floatCorpusBucketValues[r.Intn(len(floatCorpusBucketValues))],
		}
		if r.Intn(5) == 0 {
			h.Schema = histogram.CustomBucketsSchema
			h.PositiveSpans = randSpans(r, false, r.Intn(3) == 0)
			nBuckets, totalLength := spanTotals(h.PositiveSpans)
			h.PositiveBuckets = randBuckets(nBuckets)
			bounds := totalLength - 1 + r.Intn(3)
			if bounds < 0 {
				bounds = 0
			}
			values := make([]float64, 0, bounds)
			v := float64(r.Intn(3)) - 1
			for i := 0; i < bounds; i++ {
				v += 0.5 + float64(r.Intn(4))
				values = append(values, v)
			}
			h.CustomValues = values
		} else {
			h.Schema = int32(r.Intn(13)) - 4
			h.ZeroThreshold = corpusZeroThresholds[r.Intn(len(corpusZeroThresholds))]
			h.ZeroCount = floatCorpusBucketValues[r.Intn(len(floatCorpusBucketValues))]
			h.PositiveSpans = randSpans(r, true, r.Intn(3) == 0)
			pBuckets, _ := spanTotals(h.PositiveSpans)
			h.PositiveBuckets = randBuckets(pBuckets)
			if r.Intn(3) > 0 {
				h.NegativeSpans = randSpans(r, true, r.Intn(3) == 0)
				nBuckets, _ := spanTotals(h.NegativeSpans)
				h.NegativeBuckets = randBuckets(nBuckets)
			}
		}
		if err := h.Validate(); err != nil {
			panic(fmt.Errorf("generated invalid float histogram: %w", err))
		}
		out = append(out, h)
	}
	return out
}

// floatValueCorpus is the structural set, plus every integer-histogram case run
// through ToFloat (which is already pinned, and gives a wide layout corpus for
// free), plus a seeded fuzz.
func floatValueCorpus() []*histogram.FloatHistogram {
	out := floatStructuralHistograms()
	for _, h := range valueCorpus() {
		out = append(out, h.ToFloat(nil))
	}
	r := rand.New(rand.NewSource(20260809))
	return append(out, randomFloatHistograms(r, 200)...)
}

// MARK: - histogram/float

func genFloatHistogram(e *emitter) {
	type out struct {
		Str      string `json:"str"`
		TestExpr string `json:"testExpr"`
		// Bucket.String() per bucket, which folds in the bounds, the inclusivity
		// flags and the count.
		Pos    []string `json:"pos"`
		Neg    []string `json:"neg"`
		PosRev []string `json:"posRev"`
		NegRev []string `json:"negRev"`
		All    []string `json:"all"`
		AllRev []string `json:"allRev"`
		// nil for custom buckets, where ZeroBucket panics.
		Zero        *string       `json:"zero"`
		Copy        floatHistJSON `json:"copy"`
		CopyTo      floatHistJSON `json:"copyTo"`
		Compact0    floatHistJSON `json:"compact0"`
		Validate    string        `json:"validate"`
		Size        int           `json:"size"`
		HasOverflow bool          `json:"hasOverflow"`
	}

	// A deliberately dirty CopyTo destination, of a different schema, so a field
	// the copy fails to overwrite shows up as a mismatch.
	dirty := func() *histogram.FloatHistogram {
		return &histogram.FloatHistogram{
			CounterResetHint: histogram.GaugeType,
			Schema:           3,
			ZeroThreshold:    7.5,
			ZeroCount:        99,
			Count:            123,
			Sum:              -0.5,
			PositiveSpans:    []histogram.Span{{Offset: 5, Length: 3}},
			PositiveBuckets:  []float64{9, 9, 9},
			NegativeSpans:    []histogram.Span{{Offset: 2, Length: 2}},
			NegativeBuckets:  []float64{4, 4},
			CustomValues:     []float64{11, 22},
		}
	}

	drain := func(it histogram.BucketIterator[float64]) []string {
		out := []string{}
		for it.Next() {
			out = append(out, it.At().String())
		}
		return out
	}

	for i, h := range floatValueCorpus() {
		o := out{
			Str:         h.String(),
			TestExpr:    h.TestExpression(),
			Pos:         drain(h.PositiveBucketIterator()),
			Neg:         drain(h.NegativeBucketIterator()),
			PosRev:      drain(h.PositiveReverseBucketIterator()),
			NegRev:      drain(h.NegativeReverseBucketIterator()),
			All:         drain(h.AllBucketIterator()),
			AllRev:      drain(h.AllReverseBucketIterator()),
			Validate:    errString(h.Validate()),
			Size:        h.Size(),
			HasOverflow: h.HasOverflow(),
		}
		if !h.UsesCustomBuckets() {
			s := h.ZeroBucket().String()
			o.Zero = &s
		}
		o.Copy = toFloatHistJSON(h.Copy())
		to := dirty()
		h.CopyTo(to)
		o.CopyTo = toFloatHistJSON(to)
		o.Compact0 = toFloatHistJSON(h.Copy().Compact(0))

		e.emit(fmt.Sprintf("f/%d", i), toFloatHistJSON(h), o)
	}
}

// MARK: - histogram/float-copytoschema

func genFloatHistogramCopyToSchema(e *emitter) {
	type in struct {
		H            floatHistJSON `json:"h"`
		TargetSchema int32         `json:"targetSchema"`
	}
	i := 0
	for _, h := range floatValueCorpus() {
		// CopyToSchema panics for a custom-buckets schema on either side, so only
		// the equal-schema fast path is probed for NHCB.
		targets := []int32{h.Schema}
		if !h.UsesCustomBuckets() {
			targets = append(targets, h.Schema-1, h.Schema-2, h.Schema-4, h.Schema-13)
		}
		for _, target := range targets {
			e.emit(fmt.Sprintf("cs/%d", i),
				in{H: toFloatHistJSON(h), TargetSchema: target},
				toFloatHistJSON(h.CopyToSchema(target)))
			i++
		}
	}
}

// MARK: - histogram/float-equals

// floatEqualsCorpus is a set of histograms differing from one another in exactly
// one respect, so every pair is a targeted probe. Bit-pattern comparisons are
// the point here: -0 vs +0 and NaN vs NaN both have to come out right, and
// ZeroThreshold is compared with != rather than by bits, unlike everything else.
func floatEqualsCorpus() []*histogram.FloatHistogram {
	base := func() *histogram.FloatHistogram {
		return &histogram.FloatHistogram{
			Schema:          0,
			Count:           10,
			Sum:             2.7,
			ZeroThreshold:   0.001,
			ZeroCount:       2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []float64{1, 2, 1, 1},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			NegativeBuckets: []float64{2, 2},
		}
	}
	var out []*histogram.FloatHistogram
	add := func(mutate func(*histogram.FloatHistogram)) {
		h := base()
		mutate(h)
		out = append(out, h)
	}

	out = append(out, base())
	add(func(h *histogram.FloatHistogram) { h.Schema = 1 })
	add(func(h *histogram.FloatHistogram) { h.Count = 11 })
	add(func(h *histogram.FloatHistogram) { h.Count = math.NaN() })
	add(func(h *histogram.FloatHistogram) { h.Sum = 2.8 })
	add(func(h *histogram.FloatHistogram) { h.Sum = math.NaN() })
	add(func(h *histogram.FloatHistogram) { h.Sum = 0 })
	add(func(h *histogram.FloatHistogram) { h.Sum = math.Copysign(0, -1) })
	// ZeroThreshold is compared with !=, so NaN here never equals itself.
	add(func(h *histogram.FloatHistogram) { h.ZeroThreshold = 0.002 })
	add(func(h *histogram.FloatHistogram) { h.ZeroThreshold = math.NaN() })
	add(func(h *histogram.FloatHistogram) { h.ZeroThreshold = 0 })
	add(func(h *histogram.FloatHistogram) { h.ZeroThreshold = math.Copysign(0, -1) })
	// ZeroCount and the buckets are compared by bit pattern.
	add(func(h *histogram.FloatHistogram) { h.ZeroCount = 3 })
	add(func(h *histogram.FloatHistogram) { h.ZeroCount = math.NaN() })
	add(func(h *histogram.FloatHistogram) { h.ZeroCount = math.Copysign(0, -1) })
	add(func(h *histogram.FloatHistogram) { h.ZeroCount = 0 })
	add(func(h *histogram.FloatHistogram) { h.CounterResetHint = histogram.GaugeType })
	add(func(h *histogram.FloatHistogram) { h.PositiveBuckets = []float64{1, 2, 1, 2} })
	add(func(h *histogram.FloatHistogram) { h.PositiveBuckets = []float64{1, 2, 1, math.NaN()} })
	add(func(h *histogram.FloatHistogram) {
		h.PositiveBuckets = []float64{1, 2, 1, math.Copysign(0, -1)}
	})
	add(func(h *histogram.FloatHistogram) { h.PositiveBuckets = []float64{1, 2, 1, 0} })
	add(func(h *histogram.FloatHistogram) { h.NegativeBuckets = []float64{2, 1} })
	// Span layouts that describe the same buckets, spelled differently.
	add(func(h *histogram.FloatHistogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 0}, {Offset: 0, Length: 2}, {Offset: 1, Length: 2},
		}
	})
	add(func(h *histogram.FloatHistogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 1, Length: 2}, {Offset: 0, Length: 0},
		}
	})
	add(func(h *histogram.FloatHistogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 0, Length: 0}, {Offset: 1, Length: 2},
		}
	})
	// Genuinely different layouts.
	add(func(h *histogram.FloatHistogram) {
		h.PositiveSpans = []histogram.Span{{Offset: 0, Length: 4}}
	})
	add(func(h *histogram.FloatHistogram) {
		h.PositiveSpans = []histogram.Span{{Offset: 0, Length: 2}, {Offset: 2, Length: 2}}
	})
	add(func(h *histogram.FloatHistogram) { h.NegativeSpans = nil; h.NegativeBuckets = nil })
	add(func(h *histogram.FloatHistogram) {
		h.NegativeSpans = []histogram.Span{}
		h.NegativeBuckets = []float64{}
	})

	custom := func() *histogram.FloatHistogram {
		return &histogram.FloatHistogram{
			Schema:          histogram.CustomBucketsSchema,
			Count:           4,
			Sum:             3.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{2, 2},
			CustomValues:    []float64{1, 2, 3},
		}
	}
	addCustom := func(mutate func(*histogram.FloatHistogram)) {
		h := custom()
		mutate(h)
		out = append(out, h)
	}
	out = append(out, custom())
	addCustom(func(h *histogram.FloatHistogram) { h.CustomValues = []float64{1, 2, 4} })
	addCustom(func(h *histogram.FloatHistogram) { h.CustomValues = []float64{1, 2} })
	addCustom(func(h *histogram.FloatHistogram) { h.CustomValues = nil })
	addCustom(func(h *histogram.FloatHistogram) { h.CustomValues = []float64{} })
	addCustom(func(h *histogram.FloatHistogram) {
		h.CustomValues = []float64{1, math.NaN(), 3}
	})
	addCustom(func(h *histogram.FloatHistogram) { h.ZeroCount = 1 })
	addCustom(func(h *histogram.FloatHistogram) { h.ZeroThreshold = 0.001 })

	return out
}

func genFloatHistogramEquals(e *emitter) {
	type in struct {
		A floatHistJSON `json:"a"`
		B floatHistJSON `json:"b"`
	}
	corpus := floatEqualsCorpus()
	i := 0
	for _, a := range corpus {
		for _, b := range corpus {
			e.emit(fmt.Sprintf("fe/%d", i),
				in{A: toFloatHistJSON(a), B: toFloatHistJSON(b)}, a.Equals(b))
			i++
		}
	}
}
