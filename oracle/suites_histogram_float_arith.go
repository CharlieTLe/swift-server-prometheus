package main

// Differential coverage for model/histogram/float_histogram.go, slices 2/4/5:
// Mul, Div, Add, Sub, KahanAdd, kahanCompact and ReduceResolution.
//
// Every float is compared by bit pattern, which is the whole point for the Kahan
// paths: `NaN != NaN` and `-0.0 == 0.0` would each let a real divergence through.
//
// One corpus constraint worth knowing: reconcileZeroBuckets loops on
// `otherZeroThreshold != h.ZeroThreshold`, so a NaN zero threshold on either side
// spins forever in Go. The pair corpus therefore never carries one.

import (
	"fmt"
	"math"
	"math/rand"

	"github.com/prometheus/prometheus/model/histogram"
)

// MARK: - Pair corpus

// arithmeticPairs are the (receiver, other) pairs the binary operations run on.
//
// Add/Sub/KahanAdd require both sides to be exponential or both NHCB, so the
// pairs are grouped accordingly, and the exponential pairs deliberately vary
// schema and zero threshold in both directions to reach the resolution-reduction
// and zero-bucket-reconciliation branches.
func arithmeticPairs() [][2]*histogram.FloatHistogram {
	exp := func(
		schema int32, zt float64, zc float64, spans []histogram.Span, buckets []float64,
		nSpans []histogram.Span, nBuckets []float64,
	) *histogram.FloatHistogram {
		var count float64
		for _, b := range buckets {
			count += b
		}
		for _, b := range nBuckets {
			count += b
		}
		return &histogram.FloatHistogram{
			Schema: schema, ZeroThreshold: zt, ZeroCount: zc,
			Count: count + zc, Sum: count * 1.5,
			PositiveSpans: spans, PositiveBuckets: buckets,
			NegativeSpans: nSpans, NegativeBuckets: nBuckets,
		}
	}
	nhcb := func(bounds []float64, spans []histogram.Span, buckets []float64) *histogram.FloatHistogram {
		var count float64
		for _, b := range buckets {
			count += b
		}
		return &histogram.FloatHistogram{
			Schema: histogram.CustomBucketsSchema,
			Count:  count, Sum: count * 2,
			PositiveSpans: spans, PositiveBuckets: buckets,
			CustomValues: bounds,
		}
	}

	oneSpan := []histogram.Span{{Offset: 0, Length: 3}}
	twoSpans := []histogram.Span{{Offset: 0, Length: 2}, {Offset: 2, Length: 2}}

	var pairs [][2]*histogram.FloatHistogram
	add := func(a, b *histogram.FloatHistogram) {
		pairs = append(pairs, [2]*histogram.FloatHistogram{a, b})
	}

	// Same schema, same layout: the plain componentwise path.
	add(
		exp(0, 0.001, 2, oneSpan, []float64{1, 2, 3}, nil, nil),
		exp(0, 0.001, 1, oneSpan, []float64{4, 5, 6}, nil, nil))
	// Both sides with negative buckets.
	add(
		exp(0, 0.001, 2, oneSpan, []float64{1, 2, 3}, oneSpan, []float64{1, 1, 1}),
		exp(0, 0.001, 1, oneSpan, []float64{4, 5, 6}, oneSpan, []float64{2, 2, 2}))
	// Disjoint layouts, so buckets have to be inserted: before all others,
	// after the end, and into a gap.
	add(
		exp(0, 0.001, 0, []histogram.Span{{Offset: 5, Length: 2}}, []float64{1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 0, Length: 2}}, []float64{2, 2}, nil, nil))
	add(
		exp(0, 0.001, 0, []histogram.Span{{Offset: 0, Length: 2}}, []float64{1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 9, Length: 2}}, []float64{2, 2}, nil, nil))
	add(
		exp(0, 0.001, 0, twoSpans, []float64{1, 1, 1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 2, Length: 2}}, []float64{2, 2}, nil, nil))
	// Adjacent-by-one on either side, which extends an existing span rather than
	// inserting a new one.
	add(
		exp(0, 0.001, 0, []histogram.Span{{Offset: 2, Length: 2}}, []float64{1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 1, Length: 1}}, []float64{2}, nil, nil))
	add(
		exp(0, 0.001, 0, []histogram.Span{{Offset: 2, Length: 2}}, []float64{1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 4, Length: 1}}, []float64{2}, nil, nil))
	// Receiver with no buckets at all.
	add(
		exp(0, 0.001, 0, nil, nil, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{1, 2, 3}, nil, nil))
	add(
		exp(0, 0.001, 0, oneSpan, []float64{1, 2, 3}, nil, nil),
		exp(0, 0.001, 0, nil, nil, nil, nil))
	// Differing schemas, both directions: the receiver or the other side gets its
	// resolution reduced.
	add(
		exp(2, 0.001, 1, []histogram.Span{{Offset: 0, Length: 8}},
			[]float64{1, 1, 1, 1, 1, 1, 1, 1}, nil, nil),
		exp(0, 0.001, 1, oneSpan, []float64{2, 2, 2}, nil, nil))
	add(
		exp(0, 0.001, 1, oneSpan, []float64{2, 2, 2}, nil, nil),
		exp(2, 0.001, 1, []histogram.Span{{Offset: 0, Length: 8}},
			[]float64{1, 1, 1, 1, 1, 1, 1, 1}, nil, nil))
	add(
		exp(3, 0.001, 0, []histogram.Span{{Offset: -4, Length: 12}},
			[]float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
			[]histogram.Span{{Offset: -2, Length: 4}}, []float64{1, 2, 3, 4}),
		exp(-1, 0.001, 0, []histogram.Span{{Offset: -1, Length: 3}}, []float64{1, 1, 1},
			[]histogram.Span{{Offset: 0, Length: 2}}, []float64{1, 1}))
	// Differing zero thresholds, both directions — reconcileZeroBuckets, which
	// swallows buckets into the zero bucket and trims them.
	add(
		exp(0, 0.001, 2, []histogram.Span{{Offset: -3, Length: 5}},
			[]float64{1, 1, 1, 1, 1}, nil, nil),
		exp(0, 0.5, 3, []histogram.Span{{Offset: 0, Length: 2}}, []float64{2, 2}, nil, nil))
	add(
		exp(0, 0.5, 3, []histogram.Span{{Offset: 0, Length: 2}}, []float64{2, 2}, nil, nil),
		exp(0, 0.001, 2, []histogram.Span{{Offset: -3, Length: 5}},
			[]float64{1, 1, 1, 1, 1}, nil, nil))
	// A threshold that lands inside a populated bucket, so it has to be raised —
	// including the negative-side restart of the outer loop.
	add(
		exp(0, 0.0625, 1, []histogram.Span{{Offset: -4, Length: 4}}, []float64{1, 1, 1, 1},
			[]histogram.Span{{Offset: -4, Length: 4}}, []float64{1, 1, 1, 1}),
		exp(0, 0.3, 1, []histogram.Span{{Offset: 0, Length: 2}}, []float64{2, 2},
			[]histogram.Span{{Offset: 0, Length: 2}}, []float64{2, 2}))
	// Both schema and threshold differ.
	add(
		exp(2, 0.001, 1, []histogram.Span{{Offset: -8, Length: 16}},
			[]float64{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}, nil, nil),
		exp(-2, 0.75, 2, []histogram.Span{{Offset: -1, Length: 3}}, []float64{3, 3, 3}, nil, nil))
	// Fractional and extreme values, where Kahan compensation actually matters.
	add(
		exp(0, 0.001, 0.5, oneSpan, []float64{0.1, 0.2, 0.3}, nil, nil),
		exp(0, 0.001, 0.25, oneSpan, []float64{0.7, 0.8, 0.9}, nil, nil))
	add(
		exp(0, 0.001, 0, oneSpan, []float64{1e100, 1, 1e-100}, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{1, 1e100, 1e-100}, nil, nil))
	add(
		exp(0, 0.001, 0, oneSpan, []float64{1, 1e16, 1}, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{1, 1, 1}, nil, nil))
	// Infinities and NaN in the counts (but never in a zero threshold).
	add(
		exp(0, 0.001, 0, oneSpan, []float64{math.Inf(1), 1, 1}, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{1, 1, 1}, nil, nil))
	add(
		exp(0, 0.001, 0, oneSpan, []float64{math.NaN(), 1, 1}, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{1, 1, 1}, nil, nil))
	add(
		exp(0, 0.001, 0, oneSpan, []float64{math.Copysign(0, -1), 1, 1}, nil, nil),
		exp(0, 0.001, 0, oneSpan, []float64{0, 1, 1}, nil, nil))
	// Zero-length spans in the mix.
	add(
		exp(0, 0.001, 0, []histogram.Span{{Offset: 0, Length: 0}, {Offset: 1, Length: 2}},
			[]float64{1, 1}, nil, nil),
		exp(0, 0.001, 0, []histogram.Span{{Offset: 1, Length: 2}, {Offset: 0, Length: 0}},
			[]float64{2, 2}, nil, nil))

	// NHCB with matching bounds.
	add(
		nhcb([]float64{1, 2, 3}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{1, 2, 3}),
		nhcb([]float64{1, 2, 3}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{4, 5, 6}))
	// NHCB with matching bounds but disjoint layouts.
	add(
		nhcb([]float64{1, 2, 3, 4}, []histogram.Span{{Offset: 0, Length: 2}}, []float64{1, 2}),
		nhcb([]float64{1, 2, 3, 4}, []histogram.Span{{Offset: 3, Length: 2}}, []float64{3, 4}))
	// NHCB with mismatched bounds: the intersection path.
	add(
		nhcb([]float64{1, 2, 3}, []histogram.Span{{Offset: 0, Length: 4}},
			[]float64{1, 2, 3, 4}),
		nhcb([]float64{1, 3, 5}, []histogram.Span{{Offset: 0, Length: 4}},
			[]float64{5, 6, 7, 8}))
	// Mismatched bounds with no overlap at all, so the intersection is empty.
	add(
		nhcb([]float64{1, 2}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{1, 2, 3}),
		nhcb([]float64{7, 8}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{4, 5, 6}))
	// Mismatched where one is a strict subset of the other.
	add(
		nhcb([]float64{1, 2, 3, 4, 5}, []histogram.Span{{Offset: 0, Length: 6}},
			[]float64{1, 1, 1, 1, 1, 1}),
		nhcb([]float64{2, 4}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{2, 2, 2}))
	// Mismatched with fractional bounds and gaps in the spans.
	add(
		nhcb([]float64{0.5, 1.5, 2.5, 3.5},
			[]histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			[]float64{0.1, 0.2, 0.3, 0.4}),
		nhcb([]float64{1.5, 3.5, 7.5}, []histogram.Span{{Offset: 1, Length: 3}},
			[]float64{0.5, 0.6, 0.7}))
	// One NHCB with no bounds at all.
	add(
		nhcb(nil, nil, nil),
		nhcb([]float64{1, 2}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{1, 2, 3}))

	// Mismatched schemas between exponential and NHCB: rejected outright.
	add(
		exp(0, 0.001, 0, oneSpan, []float64{1, 2, 3}, nil, nil),
		nhcb([]float64{1, 2, 3}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{1, 2, 3}))
	add(
		nhcb([]float64{1, 2, 3}, []histogram.Span{{Offset: 0, Length: 3}}, []float64{1, 2, 3}),
		exp(0, 0.001, 0, oneSpan, []float64{1, 2, 3}, nil, nil))

	// Every counter reset hint combination, to pin adjustCounterReset. The
	// layouts are identical so only the hint varies.
	hints := []histogram.CounterResetHint{
		histogram.UnknownCounterReset, histogram.CounterReset,
		histogram.NotCounterReset, histogram.GaugeType,
	}
	for _, ha := range hints {
		for _, hb := range hints {
			a := exp(0, 0.001, 1, oneSpan, []float64{1, 2, 3}, nil, nil)
			b := exp(0, 0.001, 1, oneSpan, []float64{4, 5, 6}, nil, nil)
			a.CounterResetHint = ha
			b.CounterResetHint = hb
			add(a, b)
		}
	}

	// A seeded fuzz on top, exponential and NHCB pairs kept separate.
	r := rand.New(rand.NewSource(20260810))
	for i := 0; i < 120; i++ {
		if i%4 == 0 {
			bounds := make([]float64, 0, 4)
			v := 0.0
			for j := 0; j < 2+r.Intn(4); j++ {
				v += 1 + float64(r.Intn(3))
				bounds = append(bounds, v)
			}
			otherBounds := make([]float64, 0, 4)
			v = 0.0
			for j := 0; j < 2+r.Intn(4); j++ {
				v += 1 + float64(r.Intn(3))
				otherBounds = append(otherBounds, v)
			}
			spansA := randSpans(r, false, false)
			nA, _ := spanTotals(spansA)
			spansB := randSpans(r, false, false)
			nB, _ := spanTotals(spansB)
			mk := func(bounds []float64, spans []histogram.Span, n int) *histogram.FloatHistogram {
				buckets := make([]float64, n)
				for j := range buckets {
					buckets[j] = float64(r.Intn(10)) / 2
				}
				return nhcb(bounds, spans, buckets)
			}
			add(mk(bounds, spansA, nA), mk(otherBounds, spansB, nB))
			continue
		}
		mk := func() *histogram.FloatHistogram {
			spans := randSpans(r, true, r.Intn(4) == 0)
			n, _ := spanTotals(spans)
			buckets := make([]float64, n)
			for j := range buckets {
				buckets[j] = float64(r.Intn(20)) / 4
			}
			nSpans := randSpans(r, true, false)
			nn, _ := spanTotals(nSpans)
			nBuckets := make([]float64, nn)
			for j := range nBuckets {
				nBuckets[j] = float64(r.Intn(20)) / 4
			}
			// Never a NaN zero threshold: reconcileZeroBuckets would spin forever.
			return exp(
				int32(r.Intn(9))-4,
				corpusZeroThresholds[r.Intn(len(corpusZeroThresholds))],
				float64(r.Intn(8))/2,
				spans, buckets, nSpans, nBuckets)
		}
		add(mk(), mk())
	}

	return pairs
}

// MARK: - histogram/float-scale

func genFloatHistogramScale(e *emitter) {
	type in struct {
		H      floatHistJSON `json:"h"`
		Factor string        `json:"factor"`
		IsDiv  bool          `json:"isDiv"`
	}
	factors := []float64{
		0, 1, -1, 2, 0.5, -3.5, 1e100, 1e-100, math.Inf(1), math.Inf(-1), math.NaN(),
		math.Copysign(0, -1),
	}
	i := 0
	for _, h := range floatValueCorpus() {
		for _, factor := range factors {
			for _, isDiv := range []bool{false, true} {
				c := h.Copy()
				if isDiv {
					c.Div(factor)
				} else {
					c.Mul(factor)
				}
				e.emit(fmt.Sprintf("s/%d", i),
					in{H: toFloatHistJSON(h), Factor: hexFloat(factor), IsDiv: isDiv},
					toFloatHistJSON(c))
				i++
			}
		}
	}
}

// MARK: - histogram/float-add

func genFloatHistogramAdd(e *emitter) {
	type in struct {
		A     floatHistJSON `json:"a"`
		B     floatHistJSON `json:"b"`
		IsSub bool          `json:"isSub"`
	}
	type out struct {
		H                     floatHistJSON `json:"h"`
		CounterResetCollision bool          `json:"crc"`
		NhcbBoundsReconciled  bool          `json:"nbr"`
		Err                   string        `json:"err"`
		// The result compacted, since Add deliberately leaves empty buckets and
		// adjacent spans behind.
		Compacted floatHistJSON `json:"compacted"`
	}
	i := 0
	for _, pair := range arithmeticPairs() {
		for _, isSub := range []bool{false, true} {
			a := pair[0].Copy()
			var (
				collision, reconciled bool
				err                   error
			)
			if isSub {
				_, collision, reconciled, err = a.Sub(pair[1])
			} else {
				_, collision, reconciled, err = a.Add(pair[1])
			}
			o := out{
				H: toFloatHistJSON(a), CounterResetCollision: collision,
				NhcbBoundsReconciled: reconciled, Err: errString(err),
			}
			o.Compacted = toFloatHistJSON(a.Copy().Compact(0))
			e.emit(fmt.Sprintf("a/%d", i),
				in{A: toFloatHistJSON(pair[0]), B: toFloatHistJSON(pair[1]), IsSub: isSub}, o)
			i++
		}
	}
}

// MARK: - histogram/float-kahanadd

func genFloatHistogramKahanAdd(e *emitter) {
	type in struct {
		A floatHistJSON `json:"a"`
		B floatHistJSON `json:"b"`
		// Whether a compensation histogram is supplied rather than created
		// internally. When true it is pre-seeded with small non-zero terms, so a
		// port that ignores the incoming compensation shows up.
		WithC bool `json:"withC"`
	}
	type out struct {
		H floatHistJSON `json:"h"`
		// Null when the add failed, where Go returns a nil updatedC.
		C                     *floatHistJSON `json:"c"`
		CounterResetCollision bool           `json:"crc"`
		NhcbBoundsReconciled  bool           `json:"nbr"`
		Err                   string         `json:"err"`
	}
	// kahanCompact is unexported and its only caller is trimBucketsInZeroBucket,
	// reached from KahanAdd when the other histogram has the larger zero
	// threshold. The pair corpus includes those, so it is pinned through the
	// resulting bucket and compensation layouts rather than directly.
	i := 0
	for _, pair := range arithmeticPairs() {
		for _, withC := range []bool{false, true} {
			a := pair[0].Copy()
			var seed *histogram.FloatHistogram
			if withC {
				seed = &histogram.FloatHistogram{
					CounterResetHint: a.CounterResetHint,
					Schema:           a.Schema,
					ZeroThreshold:    a.ZeroThreshold,
					CustomValues:     a.CustomValues,
					PositiveSpans:    a.PositiveSpans,
					NegativeSpans:    a.NegativeSpans,
					PositiveBuckets:  make([]float64, len(a.PositiveBuckets)),
					ZeroCount:        1e-17,
					Count:            2e-17,
					Sum:              3e-17,
				}
				for j := range seed.PositiveBuckets {
					seed.PositiveBuckets[j] = float64(j+1) * 1e-17
				}
				if !a.UsesCustomBuckets() {
					seed.NegativeBuckets = make([]float64, len(a.NegativeBuckets))
					for j := range seed.NegativeBuckets {
						seed.NegativeBuckets[j] = float64(j+1) * 1e-18
					}
				}
			}
			updatedC, collision, reconciled, err := a.KahanAdd(pair[1], seed)
			o := out{
				CounterResetCollision: collision, NhcbBoundsReconciled: reconciled,
				Err: errString(err), H: toFloatHistJSON(a),
			}
			if updatedC != nil {
				c := toFloatHistJSON(updatedC)
				o.C = &c
			}
			e.emit(fmt.Sprintf("k/%d", i),
				in{A: toFloatHistJSON(pair[0]), B: toFloatHistJSON(pair[1]), WithC: withC}, o)
			i++
		}
	}
}

// MARK: - histogram/float-reduce

func genFloatHistogramReduce(e *emitter) {
	type in struct {
		H            floatHistJSON `json:"h"`
		TargetSchema int32         `json:"targetSchema"`
	}
	type out struct {
		H   floatHistJSON `json:"h"`
		Err string        `json:"err"`
	}
	i := 0
	corpus := floatValueCorpus()
	// Deliberately inconsistent spans/buckets, which reduceResolution rejects
	// rather than panicking on.
	corpus = append(corpus,
		&histogram.FloatHistogram{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 4}},
			PositiveBuckets: []float64{1, 1},
		},
		&histogram.FloatHistogram{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []float64{1, 1, 1},
		},
		&histogram.FloatHistogram{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}, {Offset: -3, Length: 1}},
			PositiveBuckets: []float64{1, 1},
		},
		&histogram.FloatHistogram{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{1, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 4}},
			NegativeBuckets: []float64{1},
		})
	for _, h := range corpus {
		targets := []int32{
			h.Schema - 1, h.Schema - 2, h.Schema - 4, h.Schema - 13,
			h.Schema, h.Schema + 1,
			histogram.CustomBucketsSchema, -10,
		}
		for _, target := range targets {
			c := h.Copy()
			err := c.ReduceResolution(target)
			e.emit(fmt.Sprintf("fr/%d", i),
				in{H: toFloatHistJSON(h), TargetSchema: target},
				out{H: toFloatHistJSON(c), Err: errString(err)})
			i++
		}
	}
}
