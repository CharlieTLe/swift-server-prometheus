package main

// Differential coverage for tsdb/record/record.go — the WAL's wire format.
//
// Three suites, because §4 of the handoff says one fixture file holds one in/out shape:
//
//	record/types    the type-byte table and the two MetricType conversions
//	record/encode   Encoder -> bytes -> Decoder, for every record kind
//	record/decode   raw bytes -> Decoder, for the shapes an encoder cannot produce
//
// `record/encode` is the load-bearing one and it is a *round trip*: the bytes pin the encoder and the
// decoded rendering pins the decoder against those same bytes, so neither can be wrong in a way the other
// hides. `record/decode` exists because half of this file's behaviour is only reachable from bytes an
// encoder will not write — a truncated record, a type byte that does not match the method, trailing bytes,
// an ST marker outside 0..2, out-of-order labels, an unknown histogram schema, a reserved schema that has
// to have its resolution reduced.
//
// What has to be reached, and why each is here rather than assumed:
//
//   - **the empty list** for every record: Samples V1/V2 return a one-byte record, and
//     HistogramSamples-with-only-custom-buckets returns a ZERO-byte one because of `buf.Reset()`;
//   - **the first sample written twice** in Samples V1 — the loop starts at 0, so a one-sample record
//     carries its ref and timestamp both as a BE64 base pair and as a zero delta;
//   - **negative ref and timestamp deltas**, because both are zigzag varints and a batch's refs are not
//     monotonic. Refs that straddle 2^63 too, so the signed/unsigned spelling difference between
//     `samplesV1` (`int64(baseRef) + dref`) and `histogramSamplesV1` (`baseRef + uint64(dref)`) is
//     exercised on values where a naive port would trap or differ;
//   - **all three ST markers**, and the `st == 0 && prevST == 0` case that distinguishes `noST` from
//     `sameST` — Go's switch tests `case 0` first, so the two are not interchangeable;
//   - **V2 with a pre-seeded accumulator**, which is the `len(samples) == 0` bug at
//     `wlog/checkpoint.go:204`. Go is the one that says what comes out; the port reproduces it;
//   - **custom-buckets histograms mixed with exponential ones**, both orders, because the base pair is
//     written from `histograms[0]` whether or not that histogram survives the split;
//   - **NaN, ±Inf and -0** in every float position, since values travel as raw BE64 bits and the payload
//     is observable (quirk 74's `goNaN` lesson applies to the sum and the bucket counts too);
//   - **the counter reset hint**, rendered as its own field — `FloatHistogram.String()` does not print it
//     and quirk 56 records what that cost the last time a corpus rendered histograms with `String()`.

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"strings"

	"github.com/prometheus/common/model"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/tsdb/record"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

// ---------------------------------------------------------------------------
// record/types
// ---------------------------------------------------------------------------

type recordTypesIn struct {
	// The byte fed to `Decoder.Type` as a one-byte record, to `Type(...).String()`, and to
	// `ToMetricType`.
	Byte uint8 `json:"byte"`
	// Fed to `GetMetricType`. The empty string is a real `model.MetricType` value and is included.
	MetricType string `json:"metricType"`
	// When set, `Decoder.Type` is called with a ZERO-length record instead — the `len(rec) < 1` arm.
	EmptyRecord bool `json:"emptyRecord"`
}

type recordTypesOut struct {
	// `Decoder.Type(rec)`, rendered through `Type.String()`, plus its numeric value so a wrong
	// mapping to `Unknown` (255) cannot hide behind the shared name.
	DecoderType    string `json:"decoderType"`
	DecoderTypeNum uint8  `json:"decoderTypeNum"`
	// `Type(b).String()` directly — differs from the above for a byte that is not a record type.
	TypeString string `json:"typeString"`
	// `record.GetMetricType(model.MetricType(in.MetricType))`.
	GetMetricType uint8 `json:"getMetricType"`
	// `record.ToMetricType(in.Byte)`, a `model.MetricType`, i.e. a string.
	ToMetricType string `json:"toMetricType"`
}

func genRecordTypes(e *emitter) {
	// Every `model.MetricType` upstream declares, plus two that are not: the empty string (which
	// `GetMetricType` must map to 0) and a made-up one.
	metricTypes := []string{
		string(model.MetricTypeCounter), string(model.MetricTypeGauge),
		string(model.MetricTypeHistogram), string(model.MetricTypeGaugeHistogram),
		string(model.MetricTypeSummary), string(model.MetricTypeInfo),
		string(model.MetricTypeStateset), string(model.MetricTypeUnknown),
		"", "not-a-type",
	}

	var dec record.Decoder
	emit := func(in recordTypesIn) {
		rec := []byte{in.Byte}
		if in.EmptyRecord {
			rec = []byte{}
		}
		dt := dec.Type(rec)
		e.emit(
			fmt.Sprintf("types/b%d/%s/empty%v", in.Byte, in.MetricType, in.EmptyRecord),
			in,
			recordTypesOut{
				DecoderType:    dt.String(),
				DecoderTypeNum: uint8(dt),
				TypeString:     record.Type(in.Byte).String(),
				GetMetricType:  record.GetMetricType(model.MetricType(in.MetricType)),
				ToMetricType:   string(record.ToMetricType(in.Byte)),
			})
	}

	// Every byte, so `Unknown = 255` and the gap at 0 are both covered rather than sampled.
	for b := 0; b < 256; b++ {
		emit(recordTypesIn{Byte: uint8(b), MetricType: "counter"})
	}
	for _, mt := range metricTypes {
		emit(recordTypesIn{Byte: 1, MetricType: mt})
	}
	emit(recordTypesIn{Byte: 1, MetricType: "counter", EmptyRecord: true})
	emit(recordTypesIn{Byte: 0, MetricType: "", EmptyRecord: true})
}

// ---------------------------------------------------------------------------
// Shared wire types for the encode/decode suites
// ---------------------------------------------------------------------------

type wireLabel [2]string

type wireSeries struct {
	Ref    uint64      `json:"ref"`
	Labels []wireLabel `json:"labels"`
}

type wireSample struct {
	Ref uint64 `json:"ref"`
	ST  int64  `json:"st"`
	T   int64  `json:"t"`
	// A 16-hex-digit bit pattern, so NaN payloads and -0 travel exactly (§4).
	V string `json:"v"`
}

type wireMetadata struct {
	Ref  uint64 `json:"ref"`
	Type uint8  `json:"type"`
	Unit string `json:"unit"`
	Help string `json:"help"`
}

type wireStone struct {
	Ref       uint64     `json:"ref"`
	Intervals [][2]int64 `json:"intervals"`
}

type wireExemplar struct {
	Ref    uint64      `json:"ref"`
	T      int64       `json:"t"`
	V      string      `json:"v"`
	Labels []wireLabel `json:"labels"`
}

type wireMarker struct {
	Ref     uint64 `json:"ref"`
	MmapRef uint64 `json:"mmapRef"`
}

type wireSpan struct {
	Offset int32  `json:"offset"`
	Length uint32 `json:"length"`
}

// wireHistogram carries every field of both histogram flavours as bits, including the counter reset
// hint, which `String()` does not print (quirk 56).
type wireHistogram struct {
	Hint          uint8      `json:"hint"`
	Schema        int32      `json:"schema"`
	ZeroThreshold string     `json:"zeroThreshold"`
	ZeroCount     string     `json:"zeroCount"`
	Count         string     `json:"count"`
	Sum           string     `json:"sum"`
	PositiveSpans []wireSpan `json:"positiveSpans"`
	NegativeSpans []wireSpan `json:"negativeSpans"`
	// Integer histograms use the *Int fields, float ones the plain ones. Both are hex so an integer
	// bucket of -1 and a float bucket of -1 render distinguishably.
	PositiveBucketsInt []int64  `json:"positiveBucketsInt"`
	NegativeBucketsInt []int64  `json:"negativeBucketsInt"`
	PositiveBuckets    []string `json:"positiveBuckets"`
	NegativeBuckets    []string `json:"negativeBuckets"`
	CustomValues       []string `json:"customValues"`
}

type wireHistogramSample struct {
	Ref uint64        `json:"ref"`
	ST  int64         `json:"st"`
	T   int64         `json:"t"`
	H   wireHistogram `json:"h"`
}

func labelsFromWire(ls []wireLabel) labels.Labels {
	b := labels.NewScratchBuilder(len(ls))
	for _, l := range ls {
		b.Add(l[0], l[1])
	}
	// NOT sorted: the encoder ranges whatever it is given, and `labels.New` would reorder. The
	// corpus supplies sorted input for the ordinary cases and relies on record/decode for the
	// out-of-order ones.
	return b.Labels()
}

func wireFromLabels(l labels.Labels) []wireLabel {
	out := []wireLabel{}
	l.Range(func(lbl labels.Label) { out = append(out, wireLabel{lbl.Name, lbl.Value}) })
	return out
}

func intHistogramFromWire(w wireHistogram) *histogram.Histogram {
	h := &histogram.Histogram{
		CounterResetHint: histogram.CounterResetHint(w.Hint),
		Schema:           w.Schema,
		ZeroThreshold:    unfbits(w.ZeroThreshold),
		ZeroCount:        uint64(unfbits(w.ZeroCount)),
		Count:            uint64(unfbits(w.Count)),
		Sum:              unfbits(w.Sum),
		PositiveBuckets:  w.PositiveBucketsInt,
		NegativeBuckets:  w.NegativeBucketsInt,
	}
	for _, s := range w.PositiveSpans {
		h.PositiveSpans = append(h.PositiveSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, s := range w.NegativeSpans {
		h.NegativeSpans = append(h.NegativeSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, v := range w.CustomValues {
		h.CustomValues = append(h.CustomValues, unfbits(v))
	}
	return h
}

func floatHistogramFromWire(w wireHistogram) *histogram.FloatHistogram {
	h := &histogram.FloatHistogram{
		CounterResetHint: histogram.CounterResetHint(w.Hint),
		Schema:           w.Schema,
		ZeroThreshold:    unfbits(w.ZeroThreshold),
		ZeroCount:        unfbits(w.ZeroCount),
		Count:            unfbits(w.Count),
		Sum:              unfbits(w.Sum),
	}
	for _, s := range w.PositiveSpans {
		h.PositiveSpans = append(h.PositiveSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, s := range w.NegativeSpans {
		h.NegativeSpans = append(h.NegativeSpans, histogram.Span{Offset: s.Offset, Length: s.Length})
	}
	for _, v := range w.PositiveBuckets {
		h.PositiveBuckets = append(h.PositiveBuckets, unfbits(v))
	}
	for _, v := range w.NegativeBuckets {
		h.NegativeBuckets = append(h.NegativeBuckets, unfbits(v))
	}
	for _, v := range w.CustomValues {
		h.CustomValues = append(h.CustomValues, unfbits(v))
	}
	return h
}

// ---------------------------------------------------------------------------
// Renderings — the decoded side of every case
// ---------------------------------------------------------------------------
//
// A string per decoded value rather than a typed struct, so all record kinds share one Out shape. Every
// float is rendered as its bit pattern and every histogram field is named, so nothing is invisible.

func renderLabels(l labels.Labels) string {
	var sb strings.Builder
	sb.WriteByte('{')
	first := true
	l.Range(func(lbl labels.Label) {
		if !first {
			sb.WriteByte(',')
		}
		first = false
		fmt.Fprintf(&sb, "%q=%q", lbl.Name, lbl.Value)
	})
	sb.WriteByte('}')
	return sb.String()
}

func renderSeries(s record.RefSeries) string {
	return fmt.Sprintf("ref=%d labels=%s", uint64(s.Ref), renderLabels(s.Labels))
}

func renderSample(s record.RefSample) string {
	return fmt.Sprintf("ref=%d st=%d t=%d v=%s", uint64(s.Ref), s.ST, s.T, fbits(s.V))
}

func renderMetadata(m record.RefMetadata) string {
	return fmt.Sprintf("ref=%d type=%d unit=%q help=%q", uint64(m.Ref), m.Type, m.Unit, m.Help)
}

func renderStone(s tombstones.Stone) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "ref=%d intervals=[", uint64(s.Ref))
	for i, iv := range s.Intervals {
		if i > 0 {
			sb.WriteByte(' ')
		}
		fmt.Fprintf(&sb, "%d..%d", iv.Mint, iv.Maxt)
	}
	sb.WriteByte(']')
	return sb.String()
}

func renderExemplar(x record.RefExemplar) string {
	return fmt.Sprintf(
		"ref=%d t=%d v=%s labels=%s", uint64(x.Ref), x.T, fbits(x.V), renderLabels(x.Labels))
}

func renderMarker(m record.RefMmapMarker) string {
	return fmt.Sprintf("ref=%d mmapRef=%d", uint64(m.Ref), uint64(m.MmapRef))
}

func renderSpans(ss []histogram.Span) string {
	parts := make([]string, 0, len(ss))
	for _, s := range ss {
		parts = append(parts, fmt.Sprintf("%d:%d", s.Offset, s.Length))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func renderInt64s(vs []int64) string {
	parts := make([]string, 0, len(vs))
	for _, v := range vs {
		parts = append(parts, fmt.Sprintf("%d", v))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func renderFbits(vs []float64) string {
	parts := make([]string, 0, len(vs))
	for _, v := range vs {
		parts = append(parts, fbits(v))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func renderIntHistogram(h *histogram.Histogram) string {
	if h == nil {
		return "<nil>"
	}
	// `hint` first and explicitly: `String()` omits it, which is quirk 56.
	return fmt.Sprintf(
		"hint=%d schema=%d zt=%s zc=%d count=%d sum=%s ps=%s ns=%s pb=%s nb=%s cv=%s",
		uint8(h.CounterResetHint), h.Schema, fbits(h.ZeroThreshold), h.ZeroCount, h.Count,
		fbits(h.Sum), renderSpans(h.PositiveSpans), renderSpans(h.NegativeSpans),
		renderInt64s(h.PositiveBuckets), renderInt64s(h.NegativeBuckets),
		renderFbits(h.CustomValues))
}

func renderFloatHistogram(h *histogram.FloatHistogram) string {
	if h == nil {
		return "<nil>"
	}
	return fmt.Sprintf(
		"hint=%d schema=%d zt=%s zc=%s count=%s sum=%s ps=%s ns=%s pb=%s nb=%s cv=%s",
		uint8(h.CounterResetHint), h.Schema, fbits(h.ZeroThreshold), fbits(h.ZeroCount),
		fbits(h.Count), fbits(h.Sum), renderSpans(h.PositiveSpans), renderSpans(h.NegativeSpans),
		renderFbits(h.PositiveBuckets), renderFbits(h.NegativeBuckets),
		renderFbits(h.CustomValues))
}

func renderHistogramSample(s record.RefHistogramSample) string {
	return fmt.Sprintf(
		"ref=%d st=%d t=%d h=(%s)", uint64(s.Ref), s.ST, s.T, renderIntHistogram(s.H))
}

func renderFloatHistogramSample(s record.RefFloatHistogramSample) string {
	return fmt.Sprintf(
		"ref=%d st=%d t=%d fh=(%s)", uint64(s.Ref), s.ST, s.T, renderFloatHistogram(s.FH))
}

// ---------------------------------------------------------------------------
// The logger seam
// ---------------------------------------------------------------------------
//
// `record.NewDecoder` takes a `*slog.Logger` and uses it for exactly one thing: warning that a histogram
// with an unknown schema was SKIPPED. The port models that as `RecordDecoder.onUnknownSchema`, so the
// oracle needs a handler that records the calls rather than discarding them — otherwise the only evidence
// of a skip is a shorter result list, and a decoder that dropped the sample for the wrong reason would
// look identical.

type captureHandler struct {
	warnings *[]string
}

func (h captureHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h captureHandler) Handle(_ context.Context, r slog.Record) error {
	var schema, ts string
	r.Attrs(func(a slog.Attr) bool {
		switch a.Key {
		case "schema":
			schema = a.Value.String()
		case "timestamp":
			ts = a.Value.String()
		}
		return true
	})
	*h.warnings = append(*h.warnings, fmt.Sprintf("%s schema=%s timestamp=%s", r.Message, schema, ts))
	return nil
}

func (h captureHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h captureHandler) WithGroup(string) slog.Handler      { return h }

func capturingLogger(warnings *[]string) *slog.Logger {
	return slog.New(captureHandler{warnings: warnings})
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}
