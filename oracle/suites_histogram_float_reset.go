package main

// Differential coverage for model/histogram/float_histogram.go, slice 3:
// DetectReset.
//
// This suite carries a second job. floatBucketIterator's merge path
// (targetSchema < schema) and its absoluteStartValue skipping are unexported, and
// DetectReset is the only caller that reaches them from outside the package: it
// iterates BOTH histograms at the receiver's schema and from the receiver's zero
// threshold. So the pair corpus deliberately varies schema and zero threshold in
// both directions, and includes the layouts from upstream's
// TestFloatBucketIteratorTargetSchema.

import (
	"fmt"
	"math"
	"math/rand"

	"github.com/prometheus/prometheus/model/histogram"
)

// detectResetPairs are (previous, current) pairs.
func detectResetPairs() [][2]*histogram.FloatHistogram {
	var pairs [][2]*histogram.FloatHistogram
	add := func(previous, current *histogram.FloatHistogram) {
		pairs = append(pairs, [2]*histogram.FloatHistogram{previous, current})
	}

	// The multi-span, multi-schema shape from TestFloatBucketIteratorTargetSchema.
	// Iterated at a coarser schema by the receiver, this drives the mergeLoop.
	targetSchemaShape := func(schema int32) *histogram.FloatHistogram {
		return &histogram.FloatHistogram{
			Count:  405,
			Sum:    1008.4,
			Schema: schema,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 4},
				{Offset: 1, Length: 3},
				{Offset: 2, Length: 3},
			},
			PositiveBuckets: []float64{100, 344, 123, 55, 3, 63, 2, 54, 235, 33},
			NegativeSpans: []histogram.Span{
				{Offset: 0, Length: 3},
				{Offset: 7, Length: 4},
				{Offset: 1, Length: 3},
			},
			NegativeBuckets: []float64{10, 34, 1230, 54, 67, 63, 2, 554, 235, 33},
		}
	}

	base := func() *histogram.FloatHistogram {
		return &histogram.FloatHistogram{
			ZeroThreshold:   0.01,
			ZeroCount:       5.5,
			Count:           3493.3,
			Sum:             2349209.324,
			PositiveSpans:   []histogram.Span{{Offset: -2, Length: 1}, {Offset: 2, Length: 3}},
			PositiveBuckets: []float64{1, 3.3, 4.2, 0.1},
			NegativeSpans:   []histogram.Span{{Offset: 3, Length: 2}, {Offset: 3, Length: 2}},
			NegativeBuckets: []float64{3.1, 3, 1.234e5, 1000},
		}
	}

	// Transcribed from TestFloatHistogramDetectReset.
	add(&histogram.FloatHistogram{}, &histogram.FloatHistogram{})
	add(&histogram.FloatHistogram{}, base())
	add(base(), &histogram.FloatHistogram{})
	add(base(), base())

	// Each count decreased in turn.
	for _, mutate := range []func(*histogram.FloatHistogram){
		func(h *histogram.FloatHistogram) { h.Count-- },
		func(h *histogram.FloatHistogram) { h.ZeroCount-- },
		func(h *histogram.FloatHistogram) { h.PositiveBuckets[0] -= 0.5 },
		func(h *histogram.FloatHistogram) { h.PositiveBuckets[3] -= 0.05 },
		func(h *histogram.FloatHistogram) { h.NegativeBuckets[0] -= 0.5 },
		func(h *histogram.FloatHistogram) { h.NegativeBuckets[3] -= 1 },
		// Sum decreasing is explicitly NOT a reset.
		func(h *histogram.FloatHistogram) { h.Sum -= 1000 },
		// Buckets removed entirely.
		func(h *histogram.FloatHistogram) {
			h.PositiveSpans = []histogram.Span{{Offset: -2, Length: 1}}
			h.PositiveBuckets = []float64{1}
		},
		func(h *histogram.FloatHistogram) {
			h.NegativeSpans = nil
			h.NegativeBuckets = nil
		},
		// An empty bucket removed, which is not a reset.
		func(h *histogram.FloatHistogram) {
			h.PositiveSpans = []histogram.Span{{Offset: -2, Length: 1}, {Offset: 2, Length: 4}}
			h.PositiveBuckets = []float64{1, 3.3, 4.2, 0.1, 0}
		},
	} {
		current := base()
		mutate(current)
		add(base(), current)
		// And the reverse direction.
		previous := base()
		mutate(previous)
		add(previous, base())
	}

	// The quirk: a populated previous bucket hidden behind an empty one, with the
	// current histogram having no buckets at all. Go's drain loop only inspects
	// the first previous bucket, so this is NOT reported as a reset.
	add(
		&histogram.FloatHistogram{
			Count:           5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{0, 5},
		},
		&histogram.FloatHistogram{Count: 5})
	add(
		&histogram.FloatHistogram{
			Count:           5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{5, 0},
		},
		&histogram.FloatHistogram{Count: 5})
	// The same shape, but the current histogram stops short rather than being
	// empty, which reaches the second drain loop.
	add(
		&histogram.FloatHistogram{
			Count:           5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 4}},
			PositiveBuckets: []float64{1, 0, 0, 4},
		},
		&histogram.FloatHistogram{
			Count:           5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []float64{1},
		})

	// Every counter reset hint on the current histogram, which shortcuts.
	for _, hint := range []histogram.CounterResetHint{
		histogram.UnknownCounterReset, histogram.CounterReset,
		histogram.NotCounterReset, histogram.GaugeType,
	} {
		// Against an identical previous histogram, and against one that would
		// otherwise clearly signal a reset.
		current := base()
		current.CounterResetHint = hint
		add(base(), current)

		lower := base()
		lower.Count *= 10
		add(lower, current)
	}

	// Schema differences in both directions — the merge path.
	for _, schema := range []int32{-2, -1, 0, 1, 2, 3} {
		add(targetSchemaShape(3), targetSchemaShape(schema))
		add(targetSchemaShape(schema), targetSchemaShape(3))
		// With one side's counts reduced, so the merged comparison actually
		// decides something.
		reduced := targetSchemaShape(schema)
		for i := range reduced.PositiveBuckets {
			reduced.PositiveBuckets[i] /= 2
		}
		add(targetSchemaShape(3), reduced)
		add(reduced, targetSchemaShape(3))
	}

	// Zero threshold differences in both directions — absoluteStartValue skipping
	// and zeroCountForLargerThreshold.
	for _, threshold := range []float64{0, 0.001, 0.0625, 0.3, 0.5, 1, 4} {
		wide := base()
		wide.ZeroThreshold = threshold
		add(base(), wide)
		add(wide, base())

		// A threshold sitting inside a populated bucket, which shortcuts to true.
		straddling := &histogram.FloatHistogram{
			ZeroThreshold:   threshold,
			ZeroCount:       1,
			Count:           9,
			PositiveSpans:   []histogram.Span{{Offset: -4, Length: 4}},
			PositiveBuckets: []float64{1, 2, 3, 2},
			NegativeSpans:   []histogram.Span{{Offset: -4, Length: 4}},
			NegativeBuckets: []float64{1, 2, 3, 2},
		}
		other := straddling.Copy()
		other.ZeroThreshold = 0.0625
		add(straddling, other)
		add(other, straddling)
	}

	// Both schema and threshold differ.
	a := targetSchemaShape(3)
	a.ZeroThreshold = 0.001
	a.ZeroCount = 2
	b := targetSchemaShape(0)
	b.ZeroThreshold = 0.5
	b.ZeroCount = 3
	add(a, b)
	add(b, a)

	// NHCB: matching bounds, mismatched bounds, and NHCB against exponential.
	nhcb := func(bounds []float64, spans []histogram.Span, buckets []float64) *histogram.FloatHistogram {
		var count float64
		for _, v := range buckets {
			count += v
		}
		return &histogram.FloatHistogram{
			Schema: histogram.CustomBucketsSchema, Count: count, Sum: count,
			PositiveSpans: spans, PositiveBuckets: buckets, CustomValues: bounds,
		}
	}
	threeUp := []histogram.Span{{Offset: 0, Length: 3}}
	add(nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}))
	add(nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 1, 3}))
	add(nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 3, 3}))
	// Mismatched bounds: the on-the-fly reconciliation path.
	add(nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{1, 3, 5}, threeUp, []float64{1, 2, 3}))
	add(nhcb([]float64{1, 3, 5}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}))
	// Mismatched where the reconciled rollup decreases, and where it does not.
	add(nhcb([]float64{1, 2, 3, 4}, []histogram.Span{{Offset: 0, Length: 5}},
		[]float64{1, 1, 1, 1, 1}),
		nhcb([]float64{1, 3}, threeUp, []float64{1, 1, 1}))
	add(nhcb([]float64{1, 2, 3, 4}, []histogram.Span{{Offset: 0, Length: 5}},
		[]float64{1, 1, 1, 1, 1}),
		nhcb([]float64{1, 3}, threeUp, []float64{5, 5, 5}))
	// No overlap in bounds at all.
	add(nhcb([]float64{1, 2}, threeUp, []float64{1, 2, 3}),
		nhcb([]float64{7, 8}, threeUp, []float64{1, 2, 3}))
	// NHCB against exponential, both directions.
	add(base(), nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}))
	add(nhcb([]float64{1, 2, 3}, threeUp, []float64{1, 2, 3}), base())

	// A dense sweep aimed squarely at floatBucketIterator's merge path and its
	// absoluteStartValue skipping: every schema pairing against every zero
	// threshold. The bucket counts are distinct powers so that a mis-merge changes
	// the comparison outcome instead of cancelling out, and Count is forced not to
	// shortcut so the iterators are actually reached.
	mergeShape := func(schema int32, scale float64) *histogram.FloatHistogram {
		buckets := make([]float64, 16)
		for j := range buckets {
			buckets[j] = float64(int(1)<<uint(j%8)) * scale
		}
		var count float64
		for _, v := range buckets {
			count += v
		}
		return &histogram.FloatHistogram{
			Schema:          schema,
			ZeroThreshold:   0.001,
			ZeroCount:       1,
			Count:           count + 1,
			Sum:             count,
			PositiveSpans:   []histogram.Span{{Offset: -8, Length: 16}},
			PositiveBuckets: buckets,
			NegativeSpans:   []histogram.Span{{Offset: -8, Length: 16}},
			NegativeBuckets: buckets,
		}
	}
	schemas := []int32{-4, -2, 0, 1, 2, 3, 4, 8}
	for _, prevSchema := range schemas {
		for _, currSchema := range schemas {
			for _, threshold := range []float64{0, 0.001, 0.5, 2, 8, 1e10} {
				for _, scale := range []float64{1, 0.5, 2} {
					previous := mergeShape(prevSchema, 1)
					current := mergeShape(currSchema, scale)
					current.ZeroThreshold = threshold
					current.Count = math.Max(current.Count, previous.Count)
					add(previous, current)
				}
			}
		}
	}

	// A seeded fuzz over layouts, schemas and thresholds.
	r := rand.New(rand.NewSource(20260811))
	mk := func() *histogram.FloatHistogram {
		spans := randSpans(r, true, r.Intn(4) == 0)
		n, _ := spanTotals(spans)
		buckets := make([]float64, n)
		for j := range buckets {
			if r.Intn(4) == 0 {
				buckets[j] = 0
			} else {
				buckets[j] = float64(r.Intn(40)) / 4
			}
		}
		nSpans := randSpans(r, true, r.Intn(4) == 0)
		nn, _ := spanTotals(nSpans)
		nBuckets := make([]float64, nn)
		for j := range nBuckets {
			nBuckets[j] = float64(r.Intn(40)) / 4
		}
		var count float64
		for _, v := range buckets {
			count += v
		}
		for _, v := range nBuckets {
			count += v
		}
		zc := float64(r.Intn(8)) / 2
		return &histogram.FloatHistogram{
			CounterResetHint: histogram.CounterResetHint(r.Intn(4)),
			Schema:           int32(r.Intn(9)) - 4,
			ZeroThreshold:    corpusZeroThresholds[r.Intn(len(corpusZeroThresholds))],
			ZeroCount:        zc,
			Count:            count + zc,
			Sum:              count,
			PositiveSpans:    spans, PositiveBuckets: buckets,
			NegativeSpans: nSpans, NegativeBuckets: nBuckets,
		}
	}
	for i := 0; i < 250; i++ {
		add(mk(), mk())
	}

	return pairs
}

func genFloatHistogramDetectReset(e *emitter) {
	type in struct {
		Previous floatHistJSON `json:"previous"`
		Current  floatHistJSON `json:"current"`
	}
	type out struct {
		Reset bool `json:"reset"`
		// DetectReset must not mutate either histogram, despite folding previous's
		// buckets into its zero count and merging its schema along the way.
		PreviousUnmoved bool `json:"previousUnmoved"`
		CurrentUnmoved  bool `json:"currentUnmoved"`
	}
	for i, pair := range detectResetPairs() {
		previous, current := pair[0], pair[1]
		previousBefore := fmt.Sprint(toFloatHistJSON(previous))
		currentBefore := fmt.Sprint(toFloatHistJSON(current))
		reset := current.DetectReset(previous)
		e.emit(fmt.Sprintf("dr/%d", i),
			in{Previous: toFloatHistJSON(previous), Current: toFloatHistJSON(current)},
			out{
				Reset:           reset,
				PreviousUnmoved: previousBefore == fmt.Sprint(toFloatHistJSON(previous)),
				CurrentUnmoved:  currentBefore == fmt.Sprint(toFloatHistJSON(current)),
			})
	}
}
