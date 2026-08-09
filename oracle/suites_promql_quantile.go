package main

// Differential coverage for promql/quantile.go, plus math.Exp2.
//
// This is the highest silent-divergence risk in Phase 5: a wrong interpolation is
// a plausible-looking number, not a crash. Two things earn their own suites.
//
// gocompat/exp2. math.Exp2 is ASSEMBLY on arm64 (haveArchExp2 is true for
// `arm64 || loong64`, math/exp2_asm.go), which is the mirror image of math.Log —
// assembly on amd64, pure Go on arm64. The arm64 routine evaluates its polynomial
// with fused multiply-adds, so it does not agree with libm: Swift's own exp2
// differs from Go's on 19 of 93 probe values, always by one ULP, including 2**0.5
// where libm is the *more* accurate of the two. Every histogram_quantile over
// exponential buckets goes through it. See docs/PORTING.md quirk 0.
//
// The quantile suites are split by entry point because each has its own in/out
// shape:
//
//   promql/bucketquantile     BucketQuantile: quantile plus the five monotonicity
//                             outputs
//   promql/histogramquantile  HistogramQuantile, including the annotations
//   promql/histogramfraction  HistogramFraction
//   promql/bucketfraction     BucketFraction
//
// Not in the corpus: an empty bucket slice, which Go indexes past the end of, and
// `quantile(q, values)`, which is unexported. Both are pinned by Swift invariant
// tests instead.

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser/posrange"
)

// ------------------------------------------------------------ gocompat/exp2

func genGoExp2(e *emitter) {
	seen := map[float64]bool{}
	emit := func(v float64) {
		if seen[v] {
			return
		}
		seen[v] = true
		e.emit(fmt.Sprintf("e/%d", len(seen)-1), fbits(v), fbits(math.Exp2(v)))
	}

	// The realistic inputs: exp2 is only ever called on the output of the
	// logarithmic interpolation, i.e. logLower + (logUpper-logLower)*fraction for
	// bucket bounds of every schema. Generate exactly that.
	for _, schema := range []int32{-4, -1, 0, 1, 3, 8} {
		h := &histogram.FloatHistogram{
			Schema:          schema,
			PositiveSpans:   []histogram.Span{{Offset: -12, Length: 24}},
			PositiveBuckets: make([]float64, 24),
		}
		for it := h.PositiveBucketIterator(); it.Next(); {
			b := it.At()
			logLower := math.Log2(math.Abs(b.Lower))
			logUpper := math.Log2(math.Abs(b.Upper))
			for _, fraction := range []float64{0, 0.25, 1.0 / 3.0, 0.5, 0.75, 1} {
				emit(logLower + (logUpper-logLower)*fraction)
			}
		}
	}

	// The argument-reduction boundaries: k is int(x ± 0.5), so half-integers are
	// where the truncation flips.
	for i := -60; i <= 60; i++ {
		v := float64(i)
		emit(v)
		emit(v + 0.5)
		emit(v - 0.5)
		emit(math.Nextafter(v+0.5, math.Inf(1)))
		emit(math.Nextafter(v+0.5, math.Inf(-1)))
	}

	// The overflow and underflow thresholds, and the denormal path where the
	// inlined Ldexp needs its 2**-52 scaling.
	for _, v := range []float64{
		1.0239999999999999e+03, math.Nextafter(1.0239999999999999e+03, math.Inf(1)),
		math.Nextafter(1.0239999999999999e+03, math.Inf(-1)),
		-1.0740e+03, math.Nextafter(-1.0740e+03, math.Inf(1)),
		math.Nextafter(-1.0740e+03, math.Inf(-1)),
		-1022, -1023, -1074, -1075, 1023, 1024,
		0, math.Copysign(0, -1), math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		math.NaN(), math.Inf(1), math.Inf(-1),
	} {
		emit(v)
	}

	// A deterministic sweep across the useful range.
	for i := 0; i < 400; i++ {
		emit(float64(i)/400.0*80.0 - 40.0)
	}
}

// ------------------------------------------------------ promql/bucketquantile

type bucketJSON struct {
	// Hex bit patterns: bounds are +Inf and counts can be non-representable in
	// decimal.
	UpperBound string `json:"upperBound"`
	Count      string `json:"count"`
}

type bucketQuantileIn struct {
	Q       string       `json:"q"`
	Buckets []bucketJSON `json:"buckets"`
}

type bucketQuantileOut struct {
	Quantile        string `json:"quantile"`
	ForcedMonotonic bool   `json:"forcedMonotonic"`
	FixedPrecision  bool   `json:"fixedPrecision"`
	MinBucket       string `json:"minBucket"`
	MaxBucket       string `json:"maxBucket"`
	MaxDiff         string `json:"maxDiff"`
}

func buildBuckets(in []bucketJSON) promql.Buckets {
	out := make(promql.Buckets, 0, len(in))
	for _, b := range in {
		out = append(out, promql.Bucket{
			UpperBound: unfbits(b.UpperBound), Count: unfbits(b.Count),
		})
	}
	return out
}

func genPromQLBucketQuantile(e *emitter) {
	for _, c := range bucketQuantileCases() {
		q, forced, fixed, minB, maxB, maxDiff := promql.BucketQuantile(
			unfbits(c.in.Q), buildBuckets(c.in.Buckets))
		e.emit(c.id, c.in, bucketQuantileOut{
			Quantile:        fbits(q),
			ForcedMonotonic: forced,
			FixedPrecision:  fixed,
			MinBucket:       fbits(minB),
			MaxBucket:       fbits(maxB),
			MaxDiff:         fbits(maxDiff),
		})
	}
}

// --------------------------------------------------- promql/bucketfraction

type bucketFractionIn struct {
	Lower   string       `json:"lower"`
	Upper   string       `json:"upper"`
	Buckets []bucketJSON `json:"buckets"`
}

func genPromQLBucketFraction(e *emitter) {
	for _, c := range bucketFractionCases() {
		v := promql.BucketFraction(
			unfbits(c.in.Lower), unfbits(c.in.Upper), buildBuckets(c.in.Buckets))
		e.emit(c.id, c.in, fbits(v))
	}
}

// ------------------------------------------------ promql/histogramquantile

// histQuantileIn describes the histogram inline rather than by catalogue index:
// this suite needs far more shapes than the shared catalogue holds, and the
// interpolation depends on the exact bucket layout.
type histSpecJSON struct {
	Schema           int32  `json:"schema"`
	CounterResetHint uint8  `json:"counterResetHint"`
	ZeroThreshold    string `json:"zeroThreshold"`
	ZeroCount        string `json:"zeroCount"`
	Count            string `json:"count"`
	Sum              string `json:"sum"`
	// spanJSON is shared with the histogram suites, so its keys are "o"/"l".
	PositiveSpans   []spanJSON `json:"positiveSpans"`
	NegativeSpans   []spanJSON `json:"negativeSpans"`
	PositiveBuckets []string   `json:"positiveBuckets"`
	NegativeBuckets []string   `json:"negativeBuckets"`
	CustomValues    []string   `json:"customValues"`
}

type histQuantileIn struct {
	Q          string       `json:"q"`
	H          histSpecJSON `json:"h"`
	MetricName string       `json:"metricName"`
	Start      int          `json:"start"`
	End        int          `json:"end"`
}

type histQuantileOut struct {
	Value string `json:"value"`
	// Sorted: Annotations is a Go map. See docs/PORTING.md exception 7.
	Warnings []string `json:"warnings"`
	Infos    []string `json:"infos"`
}

func buildHistSpec(in histSpecJSON) *histogram.FloatHistogram {
	h := &histogram.FloatHistogram{
		CounterResetHint: histogram.CounterResetHint(in.CounterResetHint),
		Schema:           in.Schema,
		ZeroThreshold:    unfbits(in.ZeroThreshold),
		ZeroCount:        unfbits(in.ZeroCount),
		Count:            unfbits(in.Count),
		Sum:              unfbits(in.Sum),
	}
	for _, s := range in.PositiveSpans {
		h.PositiveSpans = append(h.PositiveSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, s := range in.NegativeSpans {
		h.NegativeSpans = append(h.NegativeSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, b := range in.PositiveBuckets {
		h.PositiveBuckets = append(h.PositiveBuckets, unfbits(b))
	}
	for _, b := range in.NegativeBuckets {
		h.NegativeBuckets = append(h.NegativeBuckets, unfbits(b))
	}
	if in.CustomValues != nil {
		h.CustomValues = []float64{}
		for _, v := range in.CustomValues {
			h.CustomValues = append(h.CustomValues, unfbits(v))
		}
	}
	return h
}

func genPromQLHistogramQuantile(e *emitter) {
	for _, c := range histogramQuantileCases() {
		pos := posrange.PositionRange{
			Start: posrange.Pos(c.in.Start), End: posrange.Pos(c.in.End),
		}
		v, annos := promql.HistogramQuantile(
			unfbits(c.in.Q), buildHistSpec(c.in.H), c.in.MetricName, pos)
		warns, infos := annosAsSortedStrings(annos, "q")
		e.emit(c.id, c.in, histQuantileOut{
			Value: fbits(v), Warnings: warns, Infos: infos,
		})
	}
}

// ----------------------------------------------- promql/histogramfraction

type histFractionIn struct {
	Lower      string       `json:"lower"`
	Upper      string       `json:"upper"`
	H          histSpecJSON `json:"h"`
	MetricName string       `json:"metricName"`
	Start      int          `json:"start"`
	End        int          `json:"end"`
}

func genPromQLHistogramFraction(e *emitter) {
	for _, c := range histogramFractionCases() {
		pos := posrange.PositionRange{
			Start: posrange.Pos(c.in.Start), End: posrange.Pos(c.in.End),
		}
		v, annos := promql.HistogramFraction(
			unfbits(c.in.Lower), unfbits(c.in.Upper), buildHistSpec(c.in.H),
			c.in.MetricName, pos)
		warns, infos := annosAsSortedStrings(annos, "q")
		e.emit(c.id, c.in, histQuantileOut{
			Value: fbits(v), Warnings: warns, Infos: infos,
		})
	}
}

// annosAsSortedStrings renders the annotations against `query` and sorts, because
// Annotations is a Go map and its iteration order is randomised. Never emits the
// truncating form.
func annosAsSortedStrings(annos interface {
	AsStrings(string, int, int) ([]string, []string)
}, query string) ([]string, []string) {
	warns, infos := annos.AsStrings(query, 0, 0)
	sortStrings(warns)
	sortStrings(infos)
	if warns == nil {
		warns = []string{}
	}
	if infos == nil {
		infos = []string{}
	}
	return warns, infos
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
