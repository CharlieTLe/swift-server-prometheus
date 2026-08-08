package main

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
)

type boundIn struct {
	Idx    int32 `json:"idx"`
	Schema int32 `json:"schema"`
	// Hex bit patterns for custom bucket bounds, empty for exponential schemas.
	CustomValues []string `json:"customValues"`
}

// genHistogramBounds pins getBound across every schema and a wide index range.
//
// The precalculated bound table is generated from Go, so it cannot disagree; what
// this actually tests is the surrounding logic — the MaxFloat64 clamp for the last
// regular bucket, the Ldexp path for negative schemas, and the ±Inf/-1 edges of
// custom-bucket lookup.
//
// getBound is unexported, so bounds are read back through the public bucket
// iterator. For a single span the iterator's currIdx IS the span offset, so a
// bucket at offset i has Upper == getBound(i) and Lower == getBound(i-1). That
// means custom-schema probes need i >= 0, since getBound panics below -1.
func genHistogramBounds(e *emitter) {
	i := 0
	emit := func(idx, schema int32, custom []float64) {
		h := &histogram.FloatHistogram{
			Schema:          schema,
			PositiveSpans:   []histogram.Span{{Offset: idx, Length: 1}},
			PositiveBuckets: []float64{1},
			CustomValues:    custom,
		}
		it := h.PositiveBucketIterator()
		if !it.Next() {
			return
		}
		b := it.At()
		cv := make([]string, 0, len(custom))
		for _, c := range custom {
			cv = append(cv, fmt.Sprintf("%016x", math.Float64bits(c)))
		}
		type out struct {
			Lower          string `json:"lower"`
			Upper          string `json:"upper"`
			LowerInclusive bool   `json:"lowerInclusive"`
			UpperInclusive bool   `json:"upperInclusive"`
		}
		e.emit(fmt.Sprintf("b/%d", i),
			boundIn{Idx: idx, Schema: schema, CustomValues: cv},
			out{
				Lower:          fmt.Sprintf("%016x", math.Float64bits(b.Lower)),
				Upper:          fmt.Sprintf("%016x", math.Float64bits(b.Upper)),
				LowerInclusive: b.LowerInclusive,
				UpperInclusive: b.UpperInclusive,
			})
		i++
	}

	// Exponential schemas, including the reserved-range edges Prometheus accepts.
	for schema := int32(-4); schema <= 8; schema++ {
		// Small indices, plus the region around the MaxFloat64 clamp.
		idxs := []int32{-2, -1, 0, 1, 2, 3, 7, 8, 16, 100, -100}
		// The clamp happens where the computed exponent reaches 1024/1025.
		if schema < 0 {
			idxs = append(idxs, 1024>>uint(-schema), (1024>>uint(-schema))+1, (1024>>uint(-schema))-1)
		} else {
			last := int32(1024) << uint(schema)
			idxs = append(idxs, last-1, last, last+1)
		}
		for _, idx := range idxs {
			emit(idx, schema, nil)
		}
	}

	// Custom bucket schema: the ±Inf and -1 edges plus ordinary lookups.
	// Valid range only: getBound PANICS for idx > len(customValues) or idx < -1,
	// and the iterator reads both getBound(idx) and getBound(idx-1), so idx must be
	// in [0, len]. idx == len yields +Inf.
	custom := []float64{0.5, 1, 2.5, 10, 1000}
	for idx := int32(0); idx <= int32(len(custom)); idx++ {
		emit(idx, histogram.CustomBucketsSchema, custom)
	}
}
