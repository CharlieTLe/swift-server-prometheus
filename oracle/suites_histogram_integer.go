package main

// Differential coverage for model/histogram/histogram.go — the integer Histogram.
//
// Five suites share one corpus:
//
//	histogram/integer          String, both bucket iterators, the cumulative
//	                           iterator, ZeroBucket, Copy, CopyTo, ToFloat
//	histogram/integer-compact  Compact at several maxEmptyBuckets
//	histogram/integer-reduce   ReduceResolution, including the post-error state
//	histogram/integer-validate Validate's error strings
//	histogram/integer-equals   Equals over all pairs of a span-layout corpus
//
// The value corpus holds only histograms that Validate accepts, because Go
// panics rather than errors on some invalid input: String reaches ZeroBucket
// (which panics for custom buckets) and getBound (which panics on an
// out-of-range custom index). Invalid input is confined to the suites that can
// take it — validate, and the deliberately inconsistent tail of reduce.

import (
	"fmt"
	"math"
	"math/rand"

	"github.com/prometheus/prometheus/model/histogram"
)

// MARK: - Wire format

type spanJSON struct {
	Offset int32  `json:"o"`
	Length uint32 `json:"l"`
}

// histJSON is a Histogram on the wire. Floats travel as hex bit patterns so NaN
// and -0 survive the round trip and comparison is bit-exact (ADR-4).
//
// Span and bucket slices are normalised to non-nil: Go cannot distinguish nil
// from empty for them (slices.Equal and len agree), so the Swift port uses
// plain arrays. CustomValues is NOT normalised — histogram.go:456 tests it
// against nil, so `null` and `[]` mean different things there.
type histJSON struct {
	CRH      uint8      `json:"crh"`
	Schema   int32      `json:"schema"`
	ZT       string     `json:"zt"`
	ZC       uint64     `json:"zc"`
	Count    uint64     `json:"count"`
	Sum      string     `json:"sum"`
	PSpans   []spanJSON `json:"psp"`
	NSpans   []spanJSON `json:"nsp"`
	PBuckets []int64    `json:"pb"`
	NBuckets []int64    `json:"nb"`
	CV       []string   `json:"cv"`
}

type floatHistJSON struct {
	CRH      uint8      `json:"crh"`
	Schema   int32      `json:"schema"`
	ZT       string     `json:"zt"`
	ZC       string     `json:"zc"`
	Count    string     `json:"count"`
	Sum      string     `json:"sum"`
	PSpans   []spanJSON `json:"psp"`
	NSpans   []spanJSON `json:"nsp"`
	PBuckets []string   `json:"pb"`
	NBuckets []string   `json:"nb"`
	CV       []string   `json:"cv"`
}

func hexFloat(v float64) string { return fmt.Sprintf("%016x", math.Float64bits(v)) }

// hexFloatsKeepNil preserves the nil/empty distinction, for CustomValues.
func hexFloatsKeepNil(fs []float64) []string {
	if fs == nil {
		return nil
	}
	out := make([]string, 0, len(fs))
	for _, f := range fs {
		out = append(out, hexFloat(f))
	}
	return out
}

func hexFloats(fs []float64) []string {
	out := make([]string, 0, len(fs))
	for _, f := range fs {
		out = append(out, hexFloat(f))
	}
	return out
}

func spansJSON(spans []histogram.Span) []spanJSON {
	out := make([]spanJSON, 0, len(spans))
	for _, s := range spans {
		out = append(out, spanJSON{Offset: s.Offset, Length: s.Length})
	}
	return out
}

func int64s(bs []int64) []int64 {
	out := make([]int64, 0, len(bs))
	out = append(out, bs...)
	return out
}

func toHistJSON(h *histogram.Histogram) histJSON {
	return histJSON{
		CRH:      uint8(h.CounterResetHint),
		Schema:   h.Schema,
		ZT:       hexFloat(h.ZeroThreshold),
		ZC:       h.ZeroCount,
		Count:    h.Count,
		Sum:      hexFloat(h.Sum),
		PSpans:   spansJSON(h.PositiveSpans),
		NSpans:   spansJSON(h.NegativeSpans),
		PBuckets: int64s(h.PositiveBuckets),
		NBuckets: int64s(h.NegativeBuckets),
		CV:       hexFloatsKeepNil(h.CustomValues),
	}
}

func toFloatHistJSON(fh *histogram.FloatHistogram) floatHistJSON {
	return floatHistJSON{
		CRH:      uint8(fh.CounterResetHint),
		Schema:   fh.Schema,
		ZT:       hexFloat(fh.ZeroThreshold),
		ZC:       hexFloat(fh.ZeroCount),
		Count:    hexFloat(fh.Count),
		Sum:      hexFloat(fh.Sum),
		PSpans:   spansJSON(fh.PositiveSpans),
		NSpans:   spansJSON(fh.NegativeSpans),
		PBuckets: hexFloats(fh.PositiveBuckets),
		NBuckets: hexFloats(fh.NegativeBuckets),
		CV:       hexFloatsKeepNil(fh.CustomValues),
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// MARK: - Corpus

// structuralHistograms are the hand-picked shapes: the cases upstream's own
// tests use, plus the span pathologies that the fuzzer reaches only by luck.
func structuralHistograms() []*histogram.Histogram {
	return []*histogram.Histogram{
		// Empty.
		{},
		// histogram_test.go TestHistogramString — the canonical shape.
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
			PositiveBuckets: []int64{1, 1, -1, 0},
			NegativeSpans: []histogram.Span{
				{Offset: 0, Length: 4},
				{Offset: 1, Length: 1},
			},
			NegativeBuckets: []int64{1, 2, -2, 1, -1},
		},
		// Zero bucket only.
		{Schema: 0, Count: 4, Sum: 0.0004, ZeroThreshold: 0.001, ZeroCount: 4},
		// Positive only, single bucket at a negative index.
		{
			Schema:          2,
			Count:           1,
			Sum:             0.7,
			PositiveSpans:   []histogram.Span{{Offset: -2, Length: 1}},
			PositiveBuckets: []int64{1},
		},
		// Empty buckets inside a span — Compact's mid-span path.
		{
			Schema:          0,
			Count:           6,
			Sum:             3,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 7}},
			PositiveBuckets: []int64{2, -2, 0, 0, 2, -2, 0},
		},
		// Leading and trailing empty buckets — Compact trims these unconditionally.
		{
			Schema:          0,
			Count:           4,
			Sum:             2,
			PositiveSpans:   []histogram.Span{{Offset: 1, Length: 5}},
			PositiveBuckets: []int64{0, 0, 4, -4, 0},
		},
		// Zero-length spans, which spansMatch has to fold away.
		{
			Schema: 0,
			Count:  4,
			Sum:    2,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 0},
				{Offset: 2, Length: 2},
				{Offset: 0, Length: 0},
			},
			PositiveBuckets: []int64{2, 0},
		},
		// Adjacent spans separated by a small offset — Compact merges these.
		{
			Schema: 0,
			Count:  4,
			Sum:    2,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 2},
				{Offset: 1, Length: 2},
			},
			PositiveBuckets: []int64{1, 0, 0, 0},
		},
		// A wide gap between spans — Compact must leave it alone.
		{
			Schema: 0,
			Count:  2,
			Sum:    2,
			PositiveSpans: []histogram.Span{
				{Offset: 0, Length: 1},
				{Offset: 40, Length: 1},
			},
			PositiveBuckets: []int64{1, 0},
		},
		// The extreme indices, where getBound clamps to MaxFloat64.
		{
			Schema:          0,
			Count:           2,
			Sum:             math.MaxFloat64,
			PositiveSpans:   []histogram.Span{{Offset: 1023, Length: 2}},
			PositiveBuckets: []int64{1, 0},
		},
		{
			Schema:          -4,
			Count:           2,
			Sum:             1,
			PositiveSpans:   []histogram.Span{{Offset: 63, Length: 2}},
			PositiveBuckets: []int64{1, 0},
		},
		// NaN sum: Validate then only lower-bounds the count.
		{
			Schema:          0,
			Count:           10,
			Sum:             math.NaN(),
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{1},
		},
		// Stale-marker-adjacent float values.
		{Schema: 0, Sum: math.Inf(1)},
		{Schema: 0, Sum: math.Inf(-1)},
		{Schema: 0, Sum: math.Copysign(0, -1)},
		// Counter reset hints.
		{Schema: 0, CounterResetHint: histogram.CounterReset},
		{Schema: 0, CounterResetHint: histogram.NotCounterReset},
		{Schema: 0, CounterResetHint: histogram.GaugeType},
		// Custom buckets (NHCB).
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           5,
			Sum:             19.4,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		// Custom buckets landing exactly on the implicit +Inf bound.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           3,
			Sum:             10,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []int64{1, 1, -1},
			CustomValues:    []float64{0.5, 1},
		},
		// Custom buckets with a -Inf first bound, which Validate allows.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           1,
			Sum:             1,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{1},
			CustomValues:    []float64{math.Inf(-1), 1},
		},
		// Custom buckets with more bounds than buckets.
		{
			Schema:          histogram.CustomBucketsSchema,
			Count:           2,
			Sum:             4,
			PositiveSpans:   []histogram.Span{{Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 0},
			CustomValues:    []float64{1, 2, 3, 4, 5, 6, 7, 8},
		},
		// A high-resolution schema, where the bound table does the work.
		{
			Schema:          8,
			Count:           3,
			Sum:             3,
			PositiveSpans:   []histogram.Span{{Offset: 100, Length: 3}},
			PositiveBuckets: []int64{1, 0, 0},
		},
		// Non-nil but empty bucket and span slices.
		{
			Schema:          0,
			PositiveSpans:   []histogram.Span{},
			PositiveBuckets: []int64{},
		},
		// Spans whose total length is zero.
		{
			Schema:          0,
			PositiveSpans:   []histogram.Span{{Offset: 3, Length: 0}},
			PositiveBuckets: []int64{},
		},
	}
}

// randSpans generates a span layout. Only the first span may carry a negative
// offset, matching what checkHistogramSpans accepts for exponential schemas.
func randSpans(r *rand.Rand, allowNegativeFirst, allowZeroLength bool) []histogram.Span {
	n := 1 + r.Intn(3)
	spans := make([]histogram.Span, 0, n)
	for i := 0; i < n; i++ {
		offset := int32(r.Intn(5))
		if i == 0 && allowNegativeFirst && r.Intn(2) == 0 {
			offset = -offset
		}
		length := uint32(1 + r.Intn(4))
		if allowZeroLength && r.Intn(7) == 0 {
			length = 0
		}
		spans = append(spans, histogram.Span{Offset: offset, Length: length})
	}
	return spans
}

func spanTotals(spans []histogram.Span) (buckets int, totalLength int) {
	for _, s := range spans {
		buckets += int(s.Length)
		totalLength += int(s.Length) + int(s.Offset)
	}
	return buckets, totalLength
}

// randDeltas builds n deltas whose running total never goes negative, since
// Validate rejects a negative absolute bucket count. Zeros are common on
// purpose: they are what Compact reacts to.
func randDeltas(r *rand.Rand, n int) []int64 {
	absolute := make([]int64, n)
	for i := range absolute {
		if r.Intn(3) == 0 {
			absolute[i] = 0
		} else {
			absolute[i] = int64(r.Intn(20))
		}
	}
	deltas := make([]int64, n)
	var prev int64
	for i, a := range absolute {
		deltas[i] = a - prev
		prev = a
	}
	return deltas
}

func sumBuckets(deltas []int64) uint64 {
	var total uint64
	var current int64
	for _, d := range deltas {
		current += d
		total += uint64(current)
	}
	return total
}

var corpusSums = []float64{
	0, 1, 19.4, -3.5, 1234.5, math.NaN(), math.Inf(1), math.Inf(-1),
	math.Copysign(0, -1), 4.9e-324, math.MaxFloat64, 0.1,
}

var corpusZeroThresholds = []float64{0, 0.001, 1, 2.938735877055719e-39}

// randomHistograms generates histograms that Validate accepts.
func randomHistograms(r *rand.Rand, n int) []*histogram.Histogram {
	out := make([]*histogram.Histogram, 0, n)
	for len(out) < n {
		h := &histogram.Histogram{
			CounterResetHint: histogram.CounterResetHint(r.Intn(4)),
			Sum:              corpusSums[r.Intn(len(corpusSums))],
		}
		if r.Intn(5) == 0 {
			// Custom buckets: no zero bucket, no negative side, and every span
			// offset must be non-negative.
			h.Schema = histogram.CustomBucketsSchema
			h.PositiveSpans = randSpans(r, false, r.Intn(3) == 0)
			nBuckets, totalLength := spanTotals(h.PositiveSpans)
			h.PositiveBuckets = randDeltas(r, nBuckets)
			// bounds+1 must cover the total span length; add slack sometimes.
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
			h.ZeroCount = uint64(r.Intn(6))
			h.PositiveSpans = randSpans(r, true, r.Intn(3) == 0)
			pBuckets, _ := spanTotals(h.PositiveSpans)
			h.PositiveBuckets = randDeltas(r, pBuckets)
			if r.Intn(3) > 0 {
				h.NegativeSpans = randSpans(r, true, r.Intn(3) == 0)
				nBuckets, _ := spanTotals(h.NegativeSpans)
				h.NegativeBuckets = randDeltas(r, nBuckets)
			}
		}
		h.Count = h.ZeroCount + sumBuckets(h.PositiveBuckets) + sumBuckets(h.NegativeBuckets)
		if err := h.Validate(); err != nil {
			// The generator is meant to produce valid histograms; a miss means the
			// generator is wrong, not the corpus.
			panic(fmt.Errorf("generated invalid histogram: %w", err))
		}
		out = append(out, h)
	}
	return out
}

func valueCorpus() []*histogram.Histogram {
	r := rand.New(rand.NewSource(20260808))
	return append(structuralHistograms(), randomHistograms(r, 400)...)
}

// MARK: - histogram/integer

// genHistogramInteger pins the read-only surface: String, the bucket iterators,
// ZeroBucket, Copy, CopyTo and ToFloat.
func genHistogramInteger(e *emitter) {
	type out struct {
		Str string `json:"str"`
		// Bucket.String() for each bucket, which folds in the bounds, the
		// inclusivity flags and the decoded count.
		Pos []string `json:"pos"`
		Neg []string `json:"neg"`
		// nil when the histogram has negative buckets, where Go panics.
		Cum []string `json:"cum"`
		// nil for custom buckets, where ZeroBucket panics.
		Zero     *string       `json:"zero"`
		Copy     histJSON      `json:"copy"`
		CopyTo   histJSON      `json:"copyTo"`
		Float    floatHistJSON `json:"float"`
		Validate string        `json:"validate"`
	}

	// CopyTo's destination is deliberately dirty and of a different schema, so a
	// field the source fails to overwrite shows up as a mismatch.
	dirty := func() *histogram.Histogram {
		return &histogram.Histogram{
			CounterResetHint: histogram.GaugeType,
			Schema:           3,
			ZeroThreshold:    7.5,
			ZeroCount:        99,
			Count:            123,
			Sum:              -0.5,
			PositiveSpans:    []histogram.Span{{Offset: 5, Length: 3}},
			PositiveBuckets:  []int64{9, 9, 9},
			NegativeSpans:    []histogram.Span{{Offset: 2, Length: 2}},
			NegativeBuckets:  []int64{4, 4},
			CustomValues:     []float64{11, 22},
		}
	}

	for i, h := range valueCorpus() {
		o := out{Str: h.String(), Validate: errString(h.Validate())}
		// Non-nil so an empty iteration encodes as [] rather than null: the Swift
		// side has plain arrays here, and only Cum uses null as a signal.
		o.Pos = []string{}
		o.Neg = []string{}
		for it := h.PositiveBucketIterator(); it.Next(); {
			o.Pos = append(o.Pos, it.At().String())
		}
		for it := h.NegativeBucketIterator(); it.Next(); {
			o.Neg = append(o.Neg, it.At().String())
		}
		if len(h.NegativeBuckets) == 0 {
			o.Cum = []string{}
			for it := h.CumulativeBucketIterator(); it.Next(); {
				o.Cum = append(o.Cum, it.At().String())
			}
		}
		if !h.UsesCustomBuckets() {
			s := h.ZeroBucket().String()
			o.Zero = &s
		}

		o.Copy = toHistJSON(h.Copy())
		to := dirty()
		h.CopyTo(to)
		o.CopyTo = toHistJSON(to)
		o.Float = toFloatHistJSON(h.ToFloat(nil))

		e.emit(fmt.Sprintf("h/%d", i), toHistJSON(h), o)
	}
}

// MARK: - histogram/integer-compact

func genHistogramCompact(e *emitter) {
	type in struct {
		H               histJSON `json:"h"`
		MaxEmptyBuckets int      `json:"maxEmptyBuckets"`
	}
	i := 0
	for _, h := range valueCorpus() {
		for _, maxEmpty := range []int{0, 1, 2, 3, 10} {
			// Compact mutates, so each probe gets its own copy.
			c := h.Copy()
			e.emit(fmt.Sprintf("c/%d", i),
				in{H: toHistJSON(h), MaxEmptyBuckets: maxEmpty},
				toHistJSON(c.Compact(maxEmpty)))
			i++
		}
	}
}

// MARK: - histogram/integer-reduce

// inconsistentHistograms are the shapes reduceResolution rejects. They are
// invalid, but safely so: reduceResolution returns an error rather than
// panicking, unlike String or the iterators.
func inconsistentHistograms() []*histogram.Histogram {
	return []*histogram.Histogram{
		// Spans need more buckets than provided — the mid-loop error, whose
		// message differs from the one reported after the loop.
		{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 4}},
			PositiveBuckets: []int64{1, 1},
		},
		// More buckets than the spans account for — the after-loop error.
		{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{1, 1, 1},
		},
		// A negative offset on a later span.
		{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}, {Offset: -3, Length: 1}},
			PositiveBuckets: []int64{1, 1},
		},
		// Positive side fine, negative side broken: Go assigns the reduced
		// positive side before the negative side fails, so the histogram is left
		// half-converted with the original schema.
		{
			Schema:          2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []int64{1, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 4}},
			NegativeBuckets: []int64{1},
		},
	}
}

func genHistogramReduce(e *emitter) {
	type in struct {
		H            histJSON `json:"h"`
		TargetSchema int32    `json:"targetSchema"`
	}
	type out struct {
		// The histogram after the call, error or not: Go mutates it either way.
		H   histJSON `json:"h"`
		Err string   `json:"err"`
	}

	i := 0
	corpus := append(valueCorpus(), inconsistentHistograms()...)
	for _, h := range corpus {
		targets := []int32{
			h.Schema - 1, h.Schema - 2, h.Schema - 4, h.Schema - 13,
			h.Schema, h.Schema + 1,
			histogram.CustomBucketsSchema, -10,
		}
		for _, target := range targets {
			c := h.Copy()
			err := c.ReduceResolution(target)
			e.emit(fmt.Sprintf("r/%d", i),
				in{H: toHistJSON(h), TargetSchema: target},
				out{H: toHistJSON(c), Err: errString(err)})
			i++
		}
	}
}

// MARK: - histogram/integer-validate

// invalidHistograms are transcribed from histogram_test.go TestHistogramValidation
// (the real specification) plus the schema and custom-bound edges around it.
func invalidHistograms() []*histogram.Histogram {
	return []*histogram.Histogram{
		// Count higher than the buckets, without NaN.
		{
			ZeroCount:       2,
			Count:           4,
			Sum:             333,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{1},
		},
		// Count lower than the buckets.
		{
			Count:           0,
			NegativeSpans:   []histogram.Span{{Offset: -1, Length: 1}},
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 1}},
			NegativeBuckets: []int64{1},
			PositiveBuckets: []int64{1},
		},
		// The zero bucket left out of the count.
		{
			Count:           2,
			ZeroCount:       1,
			NegativeSpans:   []histogram.Span{{Offset: -1, Length: 1}},
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 1}},
			NegativeBuckets: []int64{1},
			PositiveBuckets: []int64{1},
		},
		// Too few / too many buckets, each side.
		{NegativeSpans: []histogram.Span{{Offset: 0, Length: 1}}, NegativeBuckets: []int64{}},
		{PositiveSpans: []histogram.Span{{Offset: 0, Length: 1}}, PositiveBuckets: []int64{}},
		{NegativeSpans: []histogram.Span{{Offset: 0, Length: 1}}, NegativeBuckets: []int64{1, 2}},
		{PositiveSpans: []histogram.Span{{Offset: 0, Length: 1}}, PositiveBuckets: []int64{1, 2}},
		// A negative offset on a later span, each side.
		{
			NegativeSpans:   []histogram.Span{{Offset: -1, Length: 1}, {Offset: -1, Length: 1}},
			NegativeBuckets: []int64{1, 2},
		},
		{
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 1}, {Offset: -1, Length: 1}},
			PositiveBuckets: []int64{1, 2},
		},
		// A negative bucket count, each side.
		{NegativeSpans: []histogram.Span{{Offset: -1, Length: 1}}, NegativeBuckets: []int64{-1}},
		{PositiveSpans: []histogram.Span{{Offset: -1, Length: 1}}, PositiveBuckets: []int64{-1}},
		// A negative count that only appears once the deltas are accumulated.
		{
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []int64{2, -3, 5},
		},
		// Custom-buckets schema carrying exponential-only fields.
		{
			Count:           12,
			ZeroCount:       2,
			ZeroThreshold:   0.001,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			NegativeBuckets: []int64{1, 1, -1, 0},
		},
		{
			Count:           12,
			ZeroCount:       2,
			ZeroThreshold:   0.001,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			NegativeBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		// Zero threshold but no zero count, custom buckets.
		{
			Count:           2,
			ZeroThreshold:   0.001,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 1}},
			PositiveBuckets: []int64{2},
			CustomValues:    []float64{1, 2},
		},
		// Exponential schema carrying custom bounds — a nil check, so an empty
		// non-nil slice must be rejected too.
		{
			Count:           5,
			Sum:             19.4,
			Schema:          0,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		{Schema: 0, CustomValues: []float64{}},
		// Custom buckets: negative offsets, first span and later.
		{
			Count:           5,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		{
			Count:           5,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: -1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		// Custom buckets: bucket count mismatch, and too few bounds.
		{
			Count:           5,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1},
			CustomValues:    []float64{1, 2, 3, 4},
		},
		{
			Count:           5,
			Sum:             19.4,
			Schema:          histogram.CustomBucketsSchema,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			CustomValues:    []float64{1, 2, 3},
		},
		// Custom bounds: non-increasing, explicit +Inf, NaN.
		{Schema: histogram.CustomBucketsSchema, CustomValues: []float64{0, 0}},
		{Schema: histogram.CustomBucketsSchema, CustomValues: []float64{2, 1}},
		{Schema: histogram.CustomBucketsSchema, CustomValues: []float64{1, math.Inf(1)}},
		{Schema: histogram.CustomBucketsSchema, CustomValues: []float64{1, math.NaN(), 3}},
		{Schema: histogram.CustomBucketsSchema, CustomValues: []float64{math.NaN()}},
		// Schemas outside the valid range, including the reserved range that is
		// known but not valid.
		{Schema: 9},
		{Schema: 10},
		{Schema: -5},
		{Schema: -10},
		{Schema: 52},
		{Schema: -52},
		{Schema: math.MaxInt32},
		{Schema: math.MinInt32},
	}
}

func genHistogramValidate(e *emitter) {
	corpus := append(valueCorpus(), invalidHistograms()...)
	for i, h := range corpus {
		e.emit(fmt.Sprintf("v/%d", i), toHistJSON(h), errString(h.Validate()))
	}
}

// MARK: - histogram/integer-equals

// equalsCorpus is a set of histograms that differ from one another in exactly
// one respect, so every pair is a targeted probe. The span variants matter most:
// spansMatch folds zero-length spans together, so layouts that look different
// can still be equal.
func equalsCorpus() []*histogram.Histogram {
	base := func() *histogram.Histogram {
		return &histogram.Histogram{
			Schema:          0,
			Count:           10,
			Sum:             2.7,
			ZeroThreshold:   0.001,
			ZeroCount:       2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
			PositiveBuckets: []int64{1, 1, -1, 0},
			NegativeSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			NegativeBuckets: []int64{2, 0},
		}
	}
	var out []*histogram.Histogram
	add := func(mutate func(*histogram.Histogram)) {
		h := base()
		mutate(h)
		out = append(out, h)
	}

	out = append(out, base())
	// One field different at a time.
	add(func(h *histogram.Histogram) { h.Schema = 1 })
	add(func(h *histogram.Histogram) { h.Count = 11 })
	add(func(h *histogram.Histogram) { h.Sum = 2.8 })
	add(func(h *histogram.Histogram) { h.Sum = math.NaN() })
	add(func(h *histogram.Histogram) { h.Sum = math.Copysign(0, -1) })
	add(func(h *histogram.Histogram) { h.Sum = 0 })
	add(func(h *histogram.Histogram) { h.ZeroThreshold = 0.002 })
	add(func(h *histogram.Histogram) { h.ZeroCount = 3 })
	add(func(h *histogram.Histogram) { h.CounterResetHint = histogram.GaugeType })
	add(func(h *histogram.Histogram) { h.PositiveBuckets = []int64{1, 1, -1, 1} })
	add(func(h *histogram.Histogram) { h.NegativeBuckets = []int64{2, 1} })
	// Span layouts that describe the same buckets, spelled differently.
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 0}, {Offset: 0, Length: 2}, {Offset: 1, Length: 2},
		}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 1, Length: 2}, {Offset: 0, Length: 0},
		}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 0, Length: 0}, {Offset: 1, Length: 2},
		}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 1, Length: 0}, {Offset: 0, Length: 2},
		}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{
			{Offset: 0, Length: 2}, {Offset: 0, Length: 0}, {Offset: 0, Length: 0},
			{Offset: 1, Length: 2},
		}
	})
	// Genuinely different layouts.
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{{Offset: 0, Length: 4}}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{{Offset: 1, Length: 2}, {Offset: 1, Length: 2}}
	})
	add(func(h *histogram.Histogram) {
		h.PositiveSpans = []histogram.Span{{Offset: 0, Length: 2}, {Offset: 2, Length: 2}}
	})
	// Empty and nil sides.
	add(func(h *histogram.Histogram) { h.NegativeSpans = nil; h.NegativeBuckets = nil })
	add(func(h *histogram.Histogram) {
		h.NegativeSpans = []histogram.Span{}
		h.NegativeBuckets = []int64{}
	})
	add(func(h *histogram.Histogram) {
		h.NegativeSpans = []histogram.Span{{Offset: 0, Length: 0}}
		h.NegativeBuckets = []int64{}
	})

	// Custom-buckets variants, where CustomBucketBoundsMatch takes over and the
	// negative side and zero bucket are ignored by the schema (but still compared).
	custom := func() *histogram.Histogram {
		return &histogram.Histogram{
			Schema:          histogram.CustomBucketsSchema,
			Count:           4,
			Sum:             3.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []int64{2, 0},
			CustomValues:    []float64{1, 2, 3},
		}
	}
	addCustom := func(mutate func(*histogram.Histogram)) {
		h := custom()
		mutate(h)
		out = append(out, h)
	}
	out = append(out, custom())
	addCustom(func(h *histogram.Histogram) { h.CustomValues = []float64{1, 2, 4} })
	addCustom(func(h *histogram.Histogram) { h.CustomValues = []float64{1, 2} })
	addCustom(func(h *histogram.Histogram) { h.CustomValues = []float64{1, 2, 3, 4} })
	addCustom(func(h *histogram.Histogram) { h.CustomValues = nil })
	addCustom(func(h *histogram.Histogram) { h.CustomValues = []float64{} })
	addCustom(func(h *histogram.Histogram) { h.CustomValues = []float64{1, math.NaN(), 3} })
	addCustom(func(h *histogram.Histogram) { h.ZeroCount = 1 })
	addCustom(func(h *histogram.Histogram) { h.ZeroThreshold = 0.001 })

	return out
}

func genHistogramEquals(e *emitter) {
	type in struct {
		A histJSON `json:"a"`
		B histJSON `json:"b"`
	}
	corpus := equalsCorpus()
	i := 0
	for _, a := range corpus {
		for _, b := range corpus {
			e.emit(fmt.Sprintf("e/%d", i), in{A: toHistJSON(a), B: toHistJSON(b)}, a.Equals(b))
			i++
		}
	}
}
