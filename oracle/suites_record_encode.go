package main

// record/encode — the Encoder, and the Decoder over the Encoder's own bytes.
//
// See suites_record.go for what the three record suites are between them meant to reach.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/record"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

type recordEncodeIn struct {
	// One of: series samples metadata tombstones exemplars mmapmarkers histograms floathistograms
	// custombucketshistograms custombucketsfloathistograms.
	Kind string `json:"kind"`
	// `Encoder.EnableSTStorage`, which selects the V2 record types.
	V2 bool `json:"v2"`

	Series          []wireSeries          `json:"series,omitempty"`
	Samples         []wireSample          `json:"samples,omitempty"`
	Metadata        []wireMetadata        `json:"metadata,omitempty"`
	Stones          []wireStone           `json:"stones,omitempty"`
	Exemplars       []wireExemplar        `json:"exemplars,omitempty"`
	Markers         []wireMarker          `json:"markers,omitempty"`
	Histograms      []wireHistogramSample `json:"histograms,omitempty"`
	FloatHistograms []wireHistogramSample `json:"floatHistograms,omitempty"`

	// Pre-seeds the decoder's output slice, which is what `wlog/checkpoint.go:204` effectively does.
	// For `samples` under V2 this changes the decode, because `samplesV2` asks `len(samples) == 0` of
	// the COMBINED slice; for the histogram V2 records it does not, because they track `hasPrev`.
	SeedSamples    []wireSample          `json:"seedSamples,omitempty"`
	SeedSeries     []wireSeries          `json:"seedSeries,omitempty"`
	SeedHistograms []wireHistogramSample `json:"seedHistograms,omitempty"`
}

type recordEncodeOut struct {
	// The encoded record, hex. `""` for the zero-length record `histogramSamplesV1` produces when every
	// histogram it was given uses custom buckets.
	Bytes string `json:"bytes"`
	// `Decoder.Type` over those bytes, so a wrong type byte fails loudly rather than through a decode
	// error twenty fields later.
	Type string `json:"type"`
	// One rendering per decoded value, including anything the seed contributed.
	Decoded []string `json:"decoded"`
	Err     string   `json:"err"`
	// The custom-buckets histograms `HistogramSamples`/`FloatHistogramSamples` split off, re-encoded
	// under their own record type and decoded back. Empty unless the split happened.
	LeftoverCount   int      `json:"leftoverCount"`
	LeftoverBytes   string   `json:"leftoverBytes"`
	LeftoverType    string   `json:"leftoverType"`
	LeftoverDecoded []string `json:"leftoverDecoded"`
	LeftoverErr     string   `json:"leftoverErr"`
}

func genRecordEncode(e *emitter) {
	n := 0
	emit := func(in recordEncodeIn) {
		enc := record.Encoder{EnableSTStorage: in.V2}
		dec := record.NewDecoder(nil, discardLogger())
		out := recordEncodeOut{Decoded: []string{}, LeftoverDecoded: []string{}}

		var rec []byte
		switch in.Kind {
		case "series":
			ss := make([]record.RefSeries, 0, len(in.Series))
			for _, s := range in.Series {
				ss = append(ss, record.RefSeries{
					Ref: chunks.HeadSeriesRef(s.Ref), Labels: labelsFromWire(s.Labels)})
			}
			rec = enc.Series(ss, nil)

			seed := make([]record.RefSeries, 0, len(in.SeedSeries))
			for _, s := range in.SeedSeries {
				seed = append(seed, record.RefSeries{
					Ref: chunks.HeadSeriesRef(s.Ref), Labels: labelsFromWire(s.Labels)})
			}
			got, err := dec.Series(rec, seed)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderSeries(s))
			}

		case "samples":
			ss := make([]record.RefSample, 0, len(in.Samples))
			for _, s := range in.Samples {
				ss = append(ss, record.RefSample{
					Ref: chunks.HeadSeriesRef(s.Ref), ST: s.ST, T: s.T, V: unfbits(s.V)})
			}
			rec = enc.Samples(ss, nil)

			// CAPACITY, deliberately generous. `samplesV1`/`samplesV2` start with
			//
			//	if minSize := dec.Len() / (1 + 1 + 8); cap(samples) < minSize {
			//		samples = make([]RefSample, 0, minSize)
			//	}
			//
			// which THROWS THE ACCUMULATOR AWAY when the caller's slice is not already big enough. That
			// is a capacity-dependent semantic and Swift's `Array` has no `make(len, cap)` to mirror it
			// with — `reserveCapacity` and Go's `append` growth curves disagree. PORTING.md exception 18
			// records the divergence; the corpus pins the branch the port CAN match, which is the one
			// every real caller takes (`head_wal.go` passes a pooled slice, `checkpoint.go` an
			// accumulated one, and both have ample capacity by the time it matters).
			seed := make([]record.RefSample, 0, 8192)
			for _, s := range in.SeedSamples {
				seed = append(seed, record.RefSample{
					Ref: chunks.HeadSeriesRef(s.Ref), ST: s.ST, T: s.T, V: unfbits(s.V)})
			}
			got, err := dec.Samples(rec, seed)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderSample(s))
			}

		case "metadata":
			ms := make([]record.RefMetadata, 0, len(in.Metadata))
			for _, m := range in.Metadata {
				ms = append(ms, record.RefMetadata{
					Ref: chunks.HeadSeriesRef(m.Ref), Type: m.Type, Unit: m.Unit, Help: m.Help})
			}
			rec = enc.Metadata(ms, nil)
			got, err := dec.Metadata(rec, nil)
			out.Err = errString(err)
			for _, m := range got {
				out.Decoded = append(out.Decoded, renderMetadata(m))
			}

		case "tombstones":
			ts := make([]tombstones.Stone, 0, len(in.Stones))
			for _, s := range in.Stones {
				st := tombstones.Stone{Ref: storage.SeriesRef(s.Ref)}
				for _, iv := range s.Intervals {
					st.Intervals = append(
						st.Intervals, tombstones.Interval{Mint: iv[0], Maxt: iv[1]})
				}
				ts = append(ts, st)
			}
			rec = enc.Tombstones(ts, nil)
			got, err := dec.Tombstones(rec, nil)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderStone(s))
			}

		case "exemplars":
			xs := make([]record.RefExemplar, 0, len(in.Exemplars))
			for _, x := range in.Exemplars {
				xs = append(xs, record.RefExemplar{
					Ref:    chunks.HeadSeriesRef(x.Ref),
					T:      x.T,
					V:      unfbits(x.V),
					Labels: labelsFromWire(x.Labels)})
			}
			rec = enc.Exemplars(xs, nil)
			got, err := dec.Exemplars(rec, nil)
			out.Err = errString(err)
			for _, x := range got {
				out.Decoded = append(out.Decoded, renderExemplar(x))
			}

		case "mmapmarkers":
			ms := make([]record.RefMmapMarker, 0, len(in.Markers))
			for _, m := range in.Markers {
				ms = append(ms, record.RefMmapMarker{
					Ref: chunks.HeadSeriesRef(m.Ref), MmapRef: chunks.ChunkDiskMapperRef(m.MmapRef)})
			}
			rec = enc.MmapMarkers(ms, nil)
			got, err := dec.MmapMarkers(rec, nil)
			out.Err = errString(err)
			for _, m := range got {
				out.Decoded = append(out.Decoded, renderMarker(m))
			}

		case "histograms", "custombucketshistograms":
			hs := make([]record.RefHistogramSample, 0, len(in.Histograms))
			for _, h := range in.Histograms {
				hs = append(hs, record.RefHistogramSample{
					Ref: chunks.HeadSeriesRef(h.Ref), ST: h.ST, T: h.T,
					H: intHistogramFromWire(h.H)})
			}
			var leftovers []record.RefHistogramSample
			if in.Kind == "histograms" {
				rec, leftovers = enc.HistogramSamples(hs, nil)
			} else {
				rec = enc.CustomBucketsHistogramSamples(hs, nil)
			}

			seed := make([]record.RefHistogramSample, 0, len(in.SeedHistograms))
			for _, h := range in.SeedHistograms {
				seed = append(seed, record.RefHistogramSample{
					Ref: chunks.HeadSeriesRef(h.Ref), ST: h.ST, T: h.T,
					H: intHistogramFromWire(h.H)})
			}
			got, err := dec.HistogramSamples(rec, seed)
			out.Err = errString(err)
			for _, h := range got {
				out.Decoded = append(out.Decoded, renderHistogramSample(h))
			}

			out.LeftoverCount = len(leftovers)
			if len(leftovers) > 0 {
				lb := enc.CustomBucketsHistogramSamples(leftovers, nil)
				out.LeftoverBytes = hex.EncodeToString(lb)
				out.LeftoverType = dec.Type(lb).String()
				lgot, lerr := dec.HistogramSamples(lb, nil)
				out.LeftoverErr = errString(lerr)
				for _, h := range lgot {
					out.LeftoverDecoded = append(out.LeftoverDecoded, renderHistogramSample(h))
				}
			}

		case "floathistograms", "custombucketsfloathistograms":
			hs := make([]record.RefFloatHistogramSample, 0, len(in.FloatHistograms))
			for _, h := range in.FloatHistograms {
				hs = append(hs, record.RefFloatHistogramSample{
					Ref: chunks.HeadSeriesRef(h.Ref), ST: h.ST, T: h.T,
					FH: floatHistogramFromWire(h.H)})
			}
			var leftovers []record.RefFloatHistogramSample
			if in.Kind == "floathistograms" {
				rec, leftovers = enc.FloatHistogramSamples(hs, nil)
			} else {
				rec = enc.CustomBucketsFloatHistogramSamples(hs, nil)
			}

			got, err := dec.FloatHistogramSamples(rec, nil)
			out.Err = errString(err)
			for _, h := range got {
				out.Decoded = append(out.Decoded, renderFloatHistogramSample(h))
			}

			out.LeftoverCount = len(leftovers)
			if len(leftovers) > 0 {
				lb := enc.CustomBucketsFloatHistogramSamples(leftovers, nil)
				out.LeftoverBytes = hex.EncodeToString(lb)
				out.LeftoverType = dec.Type(lb).String()
				lgot, lerr := dec.FloatHistogramSamples(lb, nil)
				out.LeftoverErr = errString(lerr)
				for _, h := range lgot {
					out.LeftoverDecoded = append(out.LeftoverDecoded, renderFloatHistogramSample(h))
				}
			}

		default:
			panic("unknown record kind " + in.Kind)
		}

		out.Bytes = hex.EncodeToString(rec)
		out.Type = dec.Type(rec).String()
		e.emit(fmt.Sprintf("encode/%03d/%s/v2=%v", n, in.Kind, in.V2), in, out)
		n++
	}

	genRecordEncodeSeries(emit)
	genRecordEncodeSamples(emit)
	genRecordEncodeMetadata(emit)
	genRecordEncodeTombstones(emit)
	genRecordEncodeExemplars(emit)
	genRecordEncodeMarkers(emit)
	genRecordEncodeHistograms(emit)
}

// ---------------------------------------------------------------------------

var (
	fNaN     = fbits(math.NaN())
	fInf     = fbits(math.Inf(1))
	fNegInf  = fbits(math.Inf(-1))
	fNegZero = fbits(math.Copysign(0, -1))
	fZero    = fbits(0)
	fOne     = fbits(1)
	// A value with bits in every byte, so a byte-order slip in the BE64 write is visible.
	fMessy = fbits(1.2345678901234567e-100)
)

func genRecordEncodeSeries(emit func(recordEncodeIn)) {
	emit(recordEncodeIn{Kind: "series"})
	emit(recordEncodeIn{Kind: "series", Series: []wireSeries{{Ref: 0, Labels: nil}}})
	emit(recordEncodeIn{Kind: "series", Series: []wireSeries{
		{Ref: 1, Labels: []wireLabel{{"__name__", "up"}}},
	}})
	emit(recordEncodeIn{Kind: "series", Series: []wireSeries{
		{Ref: 7, Labels: []wireLabel{{"__name__", "http_requests_total"}, {"code", "200"},
			{"job", "api"}}},
		// An empty value, which `EncodeLabels` writes as a zero-length uvarint string.
		{Ref: 8, Labels: []wireLabel{{"a", ""}, {"b", "c"}}},
		// Multi-byte UTF-8 in both positions; the length prefixes are BYTE counts.
		{Ref: 9, Labels: []wireLabel{{"héllo", "wörld"}, {"日本", "語"}, {"emoji", "🙂"}}},
	}})
	// Refs at the width boundaries: 2^32, 2^40 (`HeadChunkRef`'s field width), and 2^64-1.
	emit(recordEncodeIn{Kind: "series", Series: []wireSeries{
		{Ref: 1 << 32, Labels: []wireLabel{{"a", "1"}}},
		{Ref: 1 << 40, Labels: []wireLabel{{"a", "2"}}},
		{Ref: math.MaxUint64, Labels: []wireLabel{{"a", "3"}}},
	}})
	// A pre-seeded accumulator: Series appends, so the seed must survive in front.
	emit(recordEncodeIn{
		Kind:       "series",
		Series:     []wireSeries{{Ref: 2, Labels: []wireLabel{{"a", "b"}}}},
		SeedSeries: []wireSeries{{Ref: 99, Labels: []wireLabel{{"seed", "yes"}}}},
	})
	// A label set long enough that the count's uvarint takes two bytes.
	var many []wireLabel
	for i := 0; i < 130; i++ {
		many = append(many, wireLabel{fmt.Sprintf("l%03d", i), fmt.Sprintf("v%03d", i)})
	}
	emit(recordEncodeIn{Kind: "series", Series: []wireSeries{{Ref: 3, Labels: many}}})
}

func genRecordEncodeSamples(emit func(recordEncodeIn)) {
	for _, v2 := range []bool{false, true} {
		// Empty: V1 gives a one-byte record, V2 likewise, and both decode to nothing.
		emit(recordEncodeIn{Kind: "samples", V2: v2})
		// One sample. In V1 its ref and t are written twice — base pair plus a zero delta.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: 5, T: 1000, V: fOne},
		}})
		// Descending refs and timestamps, so both deltas go negative.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: 100, T: 5000, V: fOne},
			{Ref: 99, T: 4000, V: fZero},
			{Ref: 1, T: 1, V: fNegZero},
		}})
		// Every special float, since values are raw BE64 bits.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: 1, T: 0, V: fNaN},
			{Ref: 2, T: 1, V: fInf},
			{Ref: 3, T: 2, V: fNegInf},
			{Ref: 4, T: 3, V: fNegZero},
			{Ref: 5, T: 4, V: fMessy},
		}})
		// Refs straddling 2^63, which is where the signed/unsigned delta spelling could differ, and
		// timestamps at the Int64 extremes, where a delta overflows.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: math.MaxUint64, T: math.MaxInt64, V: fOne},
			{Ref: 1 << 63, T: math.MinInt64, V: fZero},
			{Ref: 0, T: 0, V: fOne},
		}})
		// The ST axis. Under V1 every one of these encodes identically — which is itself worth
		// pinning, because it proves the flag is what selects the format.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: 1, ST: 500, T: 1000, V: fOne}, // first: raw varint
			{Ref: 2, ST: 500, T: 1001, V: fOne}, // sameST
			{Ref: 3, ST: 0, T: 1002, V: fOne},   // noST, even though prevST is 500
			{Ref: 4, ST: 0, T: 1003, V: fOne},   // noST again, and prevST is now 0
			{Ref: 5, ST: 700, T: 1004, V: fOne}, // explicitST, delta 200 against firstST
			{Ref: 6, ST: 300, T: 1005, V: fOne}, // explicitST, NEGATIVE delta
			{Ref: 7, ST: 300, T: 1006, V: fOne}, // sameST at a non-first value
		}})
		// A first sample whose ST is 0, so `firstST` is 0 and every explicit delta is absolute.
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: []wireSample{
			{Ref: 1, ST: 0, T: 10, V: fOne},
			{Ref: 2, ST: 0, T: 11, V: fOne},
			{Ref: 3, ST: 42, T: 12, V: fOne},
		}})
		// THE ACCUMULATOR CASE. Under V2 this is `checkpoint.go:204`'s bug; under V1 it is benign.
		emit(recordEncodeIn{
			Kind: "samples", V2: v2,
			Samples:     []wireSample{{Ref: 10, ST: 5, T: 100, V: fOne}, {Ref: 11, ST: 5, T: 101, V: fZero}},
			SeedSamples: []wireSample{{Ref: 900, ST: 800, T: 700, V: fMessy}},
		})
		// Long enough that the deltas cross varint width boundaries (64, 8192, 2^21).
		var long []wireSample
		for i := 0; i < 200; i++ {
			long = append(long, wireSample{
				Ref: uint64(1000 + i*37), T: int64(1_700_000_000_000 + i*15_000),
				V: fbits(float64(i) * 1.5)})
		}
		emit(recordEncodeIn{Kind: "samples", V2: v2, Samples: long})
	}
}

func genRecordEncodeMetadata(emit func(recordEncodeIn)) {
	emit(recordEncodeIn{Kind: "metadata"})
	emit(recordEncodeIn{Kind: "metadata", Metadata: []wireMetadata{
		{Ref: 1, Type: 1, Unit: "seconds", Help: "How long"},
		// Both strings empty: the field is still written, as a zero-length uvarint string.
		{Ref: 2, Type: 0, Unit: "", Help: ""},
		// A ref large enough that the uvarint takes ten bytes — the field is a uvarint here and a
		// BE64 in every other record.
		{Ref: math.MaxUint64, Type: 7, Unit: "bytes", Help: "help with \"quotes\" and \n"},
		// Multi-byte UTF-8, and a type byte outside the declared table.
		{Ref: 3, Type: 200, Unit: "秒", Help: "説明"},
	}})
}

func genRecordEncodeTombstones(emit func(recordEncodeIn)) {
	emit(recordEncodeIn{Kind: "tombstones"})
	// A stone with no intervals contributes NOTHING — the inner loop never runs.
	emit(recordEncodeIn{Kind: "tombstones", Stones: []wireStone{{Ref: 1}}})
	emit(recordEncodeIn{Kind: "tombstones", Stones: []wireStone{
		{Ref: 1, Intervals: [][2]int64{{10, 20}}},
		// Three intervals on one stone: three wire entries, and three STONES back.
		{Ref: 2, Intervals: [][2]int64{{1, 2}, {5, 9}, {100, 200}}},
		// The extremes the querier's trimming actually uses.
		{Ref: 3, Intervals: [][2]int64{{math.MinInt64, -1}, {1, math.MaxInt64}}},
		// An inverted interval; the codec does not validate.
		{Ref: 4, Intervals: [][2]int64{{50, 10}}},
	}})
}

func genRecordEncodeExemplars(emit func(recordEncodeIn)) {
	emit(recordEncodeIn{Kind: "exemplars"})
	emit(recordEncodeIn{Kind: "exemplars", Exemplars: []wireExemplar{
		{Ref: 1, T: 1000, V: fOne, Labels: []wireLabel{{"trace_id", "abc"}}},
	}})
	emit(recordEncodeIn{Kind: "exemplars", Exemplars: []wireExemplar{
		{Ref: 100, T: 5000, V: fNaN, Labels: []wireLabel{{"trace_id", "deadbeef"}}},
		// A negative ref delta, which the decoder reads back through an UNSIGNED add.
		{Ref: 99, T: 4999, V: fNegZero, Labels: nil},
		{Ref: 1 << 40, T: 5001, V: fMessy, Labels: []wireLabel{{"a", ""}, {"b", "🙂"}}},
	}})
}

func genRecordEncodeMarkers(emit func(recordEncodeIn)) {
	emit(recordEncodeIn{Kind: "mmapmarkers"})
	emit(recordEncodeIn{Kind: "mmapmarkers", Markers: []wireMarker{
		{Ref: 1, MmapRef: 0},
		// seq/offset packed into the two halves, and the all-ones value.
		{Ref: 2, MmapRef: (3 << 32) | 4096},
		{Ref: math.MaxUint64, MmapRef: math.MaxUint64},
	}})
}

// ---------------------------------------------------------------------------
// Histograms
// ---------------------------------------------------------------------------

// hExp is an ordinary exponential integer histogram; hCustom uses custom buckets. Both are built here
// rather than by a generator parameterised on one axis, because quirk 59 records what that costs: a family
// that moves one field cannot distinguish branches that read another.
func hExp(hint uint8, schema int32) wireHistogram {
	return wireHistogram{
		Hint:          hint,
		Schema:        schema,
		ZeroThreshold: fbits(0.001),
		ZeroCount:     fbits(2),
		Count:         fbits(12),
		Sum:           fbits(18.4),
		PositiveSpans: []wireSpan{{Offset: 0, Length: 2}, {Offset: 1, Length: 2}},
		NegativeSpans: []wireSpan{{Offset: -3, Length: 1}},
		// Integer buckets are DELTAS, so negatives are ordinary and the zigzag matters.
		PositiveBucketsInt: []int64{1, 1, -1, 0},
		NegativeBucketsInt: []int64{2},
	}
}

func hExpFloat(hint uint8, schema int32) wireHistogram {
	w := hExp(hint, schema)
	w.PositiveBucketsInt = nil
	w.NegativeBucketsInt = nil
	// Float buckets are ABSOLUTE counts, and the specials are reachable through arithmetic upstream.
	w.PositiveBuckets = []string{fOne, fbits(2), fbits(2.5), fNaN}
	w.NegativeBuckets = []string{fInf}
	return w
}

func hCustom() wireHistogram {
	w := hExp(0, histogram.CustomBucketsSchema)
	w.ZeroCount = fZero
	w.ZeroThreshold = fZero
	w.NegativeSpans = nil
	w.NegativeBucketsInt = nil
	w.CustomValues = []string{fbits(0.5), fbits(1), fbits(2.5), fInf}
	return w
}

func hCustomFloat() wireHistogram {
	w := hCustom()
	w.PositiveBucketsInt = nil
	w.PositiveBuckets = []string{fOne, fbits(2), fbits(3), fbits(3)}
	return w
}

// A histogram with no spans and no buckets at all: every length prefix is a zero uvarint, and for the
// custom-buckets schema the CustomValues length is written while for an exponential one the field is
// absent entirely.
func hEmpty(schema int32) wireHistogram {
	return wireHistogram{
		Schema: schema, ZeroThreshold: fZero, ZeroCount: fZero, Count: fZero, Sum: fZero,
	}
}

func genRecordEncodeHistograms(emit func(recordEncodeIn)) {
	for _, v2 := range []bool{false, true} {
		// Empty list: a one-byte record for both flavours.
		emit(recordEncodeIn{Kind: "histograms", V2: v2})
		emit(recordEncodeIn{Kind: "floathistograms", V2: v2})
		emit(recordEncodeIn{Kind: "custombucketshistograms", V2: v2})
		emit(recordEncodeIn{Kind: "custombucketsfloathistograms", V2: v2})

		// A plain exponential batch, with the hint and schema both moving.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: 1, ST: 10, T: 1000, H: hExp(0, 0)},
			{Ref: 2, ST: 10, T: 1001, H: hExp(1, 3)},
			{Ref: 3, ST: 0, T: 1002, H: hExp(2, -4)},
			{Ref: 4, ST: 99, T: 1003, H: hExp(3, 8)},
			{Ref: 5, ST: 99, T: 1004, H: hEmpty(0)},
		}})
		emit(recordEncodeIn{Kind: "floathistograms", V2: v2, FloatHistograms: []wireHistogramSample{
			{Ref: 1, ST: 10, T: 1000, H: hExpFloat(0, 0)},
			{Ref: 2, ST: 10, T: 1001, H: hExpFloat(3, -2)},
			{Ref: 3, ST: 0, T: 1002, H: hEmpty(0)},
		}})

		// ALL custom buckets. Under V1 this is the `buf.Reset()` case and the record is ZERO bytes;
		// under V2 it is encoded inline under type 12.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: 1, ST: 5, T: 2000, H: hCustom()},
			{Ref: 2, ST: 5, T: 2001, H: hCustom()},
		}})
		emit(recordEncodeIn{Kind: "floathistograms", V2: v2, FloatHistograms: []wireHistogramSample{
			{Ref: 1, ST: 5, T: 2000, H: hCustomFloat()},
		}})

		// MIXED, custom FIRST — so the base pair comes from a histogram the record does not contain.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: 50, ST: 1, T: 9000, H: hCustom()},
			{Ref: 51, ST: 1, T: 9001, H: hExp(0, 2)},
			{Ref: 52, ST: 2, T: 9002, H: hCustom()},
			{Ref: 53, ST: 2, T: 9003, H: hExp(1, 2)},
		}})
		// MIXED, exponential first.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: 60, ST: 0, T: 9100, H: hExp(0, 1)},
			{Ref: 61, ST: 0, T: 9101, H: hCustom()},
		}})
		emit(recordEncodeIn{
			Kind: "floathistograms", V2: v2,
			FloatHistograms: []wireHistogramSample{
				{Ref: 70, ST: 3, T: 9200, H: hCustomFloat()},
				{Ref: 71, ST: 3, T: 9201, H: hExpFloat(0, 1)},
				{Ref: 72, ST: 4, T: 9202, H: hCustomFloat()},
			}})

		// The explicit custom-buckets record types, 9 and 10 — or 12 and 13 under V2.
		emit(recordEncodeIn{
			Kind: "custombucketshistograms", V2: v2,
			Histograms: []wireHistogramSample{
				{Ref: 1, ST: 7, T: 3000, H: hCustom()},
				{Ref: 2, ST: 7, T: 3001, H: hCustom()},
				{Ref: 3, ST: 8, T: 3002, H: hEmpty(histogram.CustomBucketsSchema)},
			}})
		emit(recordEncodeIn{
			Kind: "custombucketsfloathistograms", V2: v2,
			FloatHistograms: []wireHistogramSample{
				{Ref: 1, ST: 7, T: 3000, H: hCustomFloat()},
				{Ref: 2, ST: 0, T: 3001, H: hEmpty(histogram.CustomBucketsSchema)},
			}})

		// The ST marker sequence, on histograms this time — the V2 histogram records use the same
		// three-valued marker and their own `hasPrev` bookkeeping.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: 1, ST: 500, T: 100, H: hExp(0, 0)},
			{Ref: 2, ST: 500, T: 101, H: hExp(0, 0)},
			{Ref: 3, ST: 0, T: 102, H: hExp(0, 0)},
			{Ref: 4, ST: 900, T: 103, H: hExp(0, 0)},
			{Ref: 5, ST: 100, T: 104, H: hExp(0, 0)},
		}})

		// A SEEDED accumulator. The histogram V2 decoders track `hasPrev` rather than the slice
		// length, so unlike `samplesV2` this must decode correctly — which is the asymmetry worth
		// pinning rather than assuming.
		emit(recordEncodeIn{
			Kind: "histograms", V2: v2,
			Histograms:     []wireHistogramSample{{Ref: 1, ST: 5, T: 100, H: hExp(0, 0)}},
			SeedHistograms: []wireHistogramSample{{Ref: 900, ST: 800, T: 700, H: hExp(2, 1)}},
		})

		// Refs and timestamps at the extremes, so the unsigned delta add wraps.
		emit(recordEncodeIn{Kind: "histograms", V2: v2, Histograms: []wireHistogramSample{
			{Ref: math.MaxUint64, ST: math.MaxInt64, T: math.MaxInt64, H: hExp(0, 0)},
			{Ref: 0, ST: math.MinInt64, T: math.MinInt64, H: hExp(0, 0)},
		}})
	}
}
