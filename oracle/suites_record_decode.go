package main

// record/decode — the Decoder over bytes an Encoder will not write.
//
// This is where the other half of record.go's behaviour lives, and none of it is reachable from
// `record/encode`:
//
//   - a **type byte that does not match the method**, which is three different error messages: the bare
//     `invalid record type` for Series/Metadata/Tombstones/Exemplars/MmapMarkers, a NUMERIC one for
//     Samples, and a NAMED one for the histogram decoders, because `Samples` binds the byte while
//     `HistogramSamples` binds the `Type`;
//   - a **truncated record**, which reports `decode error after N samples: invalid size` — and the order of
//     the two tail checks decides that it is not reported as "unexpected N bytes left";
//   - **trailing bytes** that are not enough for another entry but do not fail a read either;
//   - an **ST marker byte outside 0..2**, which `readSTMarker`'s `default` reads as `explicitST`;
//   - **out-of-order labels**, which `DecodeLabels` returns unsorted because it never calls `Sort()`;
//   - an **unknown histogram schema**, which SKIPS the sample with a log line and keeps going;
//   - a **reserved exponential schema above 8**, which triggers `ReduceResolution` — so the decoded
//     histogram is not the one the bytes describe;
//   - a **Metadata field name that is neither UNIT nor HELP**, which must still be consumed so the next
//     entry stays aligned, and a `numFields` of 0.
//
// Records are built with `encoding.Encbuf` directly, which is what the encoder uses — so a case here is a
// statement about the format, not about a hand-typed hex string. Where a case is a truncation it names the
// number of bytes to keep, so a change in the format upstream shows up as a changed fixture rather than a
// silently different test.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/tsdb/encoding"
	"github.com/prometheus/prometheus/tsdb/record"
)

type recordDecodeIn struct {
	// The record, hex. Built by the generator with `encoding.Encbuf`, then committed verbatim, so the
	// Swift side decodes exactly these bytes.
	Bytes string `json:"bytes"`
	// Which decoder to call: series metadata samples tombstones exemplars mmapmarkers histograms
	// floathistograms.
	Call string `json:"call"`
	// What the case is for, in the fixture rather than only in this file.
	Note string `json:"note"`
}

type recordDecodeOut struct {
	// `Decoder.Type` over the bytes, which is independent of `Call` and is how a caller dispatches.
	Type    string   `json:"type"`
	Decoded []string `json:"decoded"`
	Err     string   `json:"err"`
	// The `skipping histogram with unknown schema` warnings, in order. See `capturingLogger`.
	Warnings []string `json:"warnings"`
}

func genRecordDecode(e *emitter) {
	n := 0
	emit := func(call, note string, rec []byte) {
		var warnings []string
		dec := record.NewDecoder(nil, capturingLogger(&warnings))
		out := recordDecodeOut{Decoded: []string{}, Warnings: []string{}}

		switch call {
		case "series":
			got, err := dec.Series(rec, nil)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderSeries(s))
			}
		case "metadata":
			got, err := dec.Metadata(rec, nil)
			out.Err = errString(err)
			for _, m := range got {
				out.Decoded = append(out.Decoded, renderMetadata(m))
			}
		case "samples":
			got, err := dec.Samples(rec, nil)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderSample(s))
			}
		case "tombstones":
			got, err := dec.Tombstones(rec, nil)
			out.Err = errString(err)
			for _, s := range got {
				out.Decoded = append(out.Decoded, renderStone(s))
			}
		case "exemplars":
			got, err := dec.Exemplars(rec, nil)
			out.Err = errString(err)
			for _, x := range got {
				out.Decoded = append(out.Decoded, renderExemplar(x))
			}
		case "mmapmarkers":
			got, err := dec.MmapMarkers(rec, nil)
			out.Err = errString(err)
			for _, m := range got {
				out.Decoded = append(out.Decoded, renderMarker(m))
			}
		case "histograms":
			got, err := dec.HistogramSamples(rec, nil)
			out.Err = errString(err)
			for _, h := range got {
				out.Decoded = append(out.Decoded, renderHistogramSample(h))
			}
		case "floathistograms":
			got, err := dec.FloatHistogramSamples(rec, nil)
			out.Err = errString(err)
			for _, h := range got {
				out.Decoded = append(out.Decoded, renderFloatHistogramSample(h))
			}
		default:
			panic("unknown call " + call)
		}
		out.Type = dec.Type(rec).String()
		if warnings != nil {
			out.Warnings = warnings
		}

		in := recordDecodeIn{Bytes: hex.EncodeToString(rec), Call: call, Note: note}
		e.emit(fmt.Sprintf("decode/%03d/%s/%s", n, call, note), in, out)
		n++
	}

	genRecordDecodeWrongType(emit)
	genRecordDecodeTruncation(emit)
	genRecordDecodeLabels(emit)
	genRecordDecodeMetadataFields(emit)
	genRecordDecodeSTMarkers(emit)
	genRecordDecodeSchemas(emit)
}

// ---------------------------------------------------------------------------
// Record builders
// ---------------------------------------------------------------------------

// A well-formed one-sample V1 record, so truncations of it are truncations of something real.
func buildSamplesV1(ref uint64, t int64, v float64, extra int) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.Samples))
	buf.PutBE64(ref)
	buf.PutBE64int64(t)
	buf.PutVarint64(0)
	buf.PutVarint64(0)
	buf.PutBE64(math.Float64bits(v))
	for i := 0; i < extra; i++ {
		buf.PutByte(0x7f)
	}
	return buf.Get()
}

// A V2 samples record whose second entry's ST marker byte is `marker`, so the `default` arm of
// `readSTMarker` is reachable.
func buildSamplesV2WithMarker(marker byte, stDelta int64) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.SamplesV2))
	// first: ref, t, st, value — all raw.
	buf.PutVarint64(10)
	buf.PutVarint64(1000)
	buf.PutVarint64(500)
	buf.PutBE64(math.Float64bits(1))
	// second: dref, dt, marker[, delta], value.
	buf.PutVarint64(1)
	buf.PutVarint64(1)
	buf.PutByte(marker)
	if marker != 0 && marker != 1 {
		buf.PutVarint64(stDelta)
	}
	buf.PutBE64(math.Float64bits(2))
	return buf.Get()
}

func buildSeriesWithLabels(ref uint64, pairs [][2]string) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.Series))
	buf.PutBE64(ref)
	buf.PutUvarint(len(pairs))
	for _, p := range pairs {
		buf.PutUvarintStr(p[0])
		buf.PutUvarintStr(p[1])
	}
	return buf.Get()
}

func buildMetadata(ref uint64, typ byte, fields [][2]string, declaredCount int) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.Metadata))
	buf.PutUvarint64(ref)
	buf.PutByte(typ)
	buf.PutUvarint(declaredCount)
	for _, f := range fields {
		buf.PutUvarintStr(f[0])
		buf.PutUvarintStr(f[1])
	}
	return buf.Get()
}

// A V1 integer-histogram record carrying one histogram at the given schema, so the unknown-schema skip and
// the resolution reduction are both reachable without an encoder that would refuse the schema.
func buildIntHistogramV1(schema int32, second bool) []byte {
	h := intHistogramFromWire(hExp(0, schema))
	var buf encoding.Encbuf
	buf.PutByte(byte(record.HistogramSamples))
	buf.PutBE64(1)
	buf.PutBE64int64(1000)
	buf.PutVarint64(0)
	buf.PutVarint64(0)
	record.EncodeHistogram(&buf, h)
	if second {
		// A second, ordinary histogram, to show that the skip continues rather than aborting — and
		// that its deltas are still against the base pair.
		h2 := intHistogramFromWire(hExp(1, 0))
		buf.PutVarint64(1)
		buf.PutVarint64(1)
		record.EncodeHistogram(&buf, h2)
	}
	return buf.Get()
}

func buildFloatHistogramV1(schema int32) []byte {
	h := floatHistogramFromWire(hExpFloat(0, schema))
	var buf encoding.Encbuf
	buf.PutByte(byte(record.FloatHistogramSamples))
	buf.PutBE64(1)
	buf.PutBE64int64(1000)
	buf.PutVarint64(0)
	buf.PutVarint64(0)
	record.EncodeFloatHistogram(&buf, h)
	return buf.Get()
}

// A V2 integer-histogram record with two entries, the first at `schema1`. Reaches the assertion that
// `prevRef`/`prevST` advance even when the histogram is SKIPPED.
func buildIntHistogramV2(schema1, schema2 int32) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.HistogramSamplesV2))
	buf.PutVarint64(10)   // first ref
	buf.PutVarint64(1000) // first t
	buf.PutVarint64(500)  // first st
	record.EncodeHistogram(&buf, intHistogramFromWire(hExp(0, schema1)))
	buf.PutVarint64(5) // dref against PREV (which is the skipped one)
	buf.PutVarint64(1) // dt against first
	buf.PutByte(1)     // sameST -> prevST, which the skipped entry set
	record.EncodeHistogram(&buf, intHistogramFromWire(hExp(0, schema2)))
	return buf.Get()
}

// A V1 integer-histogram record whose histogram sits in the reduction band AND whose span layout makes the
// reduction FAIL. This is the only way `error reducing resolution of histogram #%d` is reachable, and it
// took a surviving control to notice: `ReduceResolution`'s own three guards (custom buckets in, custom
// buckets out, target not smaller) are all excluded by the caller's `schema > 8 && schema <= 52` test, so
// the failure has to come from `reduceResolution`'s two INNER errors — a non-first span with a negative
// offset (generic.go:810) and a span set needing more buckets than exist (:817).
//
// `precededByGood` puts a decodable histogram in front, which is what pins the index as ONE-based: with it
// the message says #2, and a zero-based port says #1.
func buildIntHistogramReduceFailure(kind string, precededByGood bool) []byte {
	var buf encoding.Encbuf
	buf.PutByte(byte(record.HistogramSamples))
	buf.PutBE64(1)
	buf.PutBE64int64(1000)
	if precededByGood {
		buf.PutVarint64(0)
		buf.PutVarint64(0)
		record.EncodeHistogram(&buf, intHistogramFromWire(hExp(0, 9)))
	}
	bad := intHistogramFromWire(hExp(0, 9))
	switch kind {
	case "negative-offset":
		// The SECOND span's offset is negative. Only `n > 0` is checked, so the first span's may be.
		bad.PositiveSpans = []histogram.Span{{Offset: 0, Length: 2}, {Offset: -1, Length: 2}}
		bad.PositiveBuckets = []int64{1, 0, 0, 0}
	case "too-few-buckets":
		bad.PositiveSpans = []histogram.Span{{Offset: 0, Length: 4}}
		bad.PositiveBuckets = []int64{1, 0}
	default:
		panic("unknown reduce-failure kind " + kind)
	}
	buf.PutVarint64(0)
	buf.PutVarint64(1)
	record.EncodeHistogram(&buf, bad)
	return buf.Get()
}

func buildFloatHistogramReduceFailure() []byte {
	fh := floatHistogramFromWire(hExpFloat(0, 9))
	fh.PositiveSpans = []histogram.Span{{Offset: 0, Length: 1}, {Offset: -2, Length: 1}}
	fh.PositiveBuckets = []float64{1, 2}
	var buf encoding.Encbuf
	buf.PutByte(byte(record.FloatHistogramSamples))
	buf.PutBE64(1)
	buf.PutBE64int64(1000)
	buf.PutVarint64(0)
	buf.PutVarint64(0)
	record.EncodeFloatHistogram(&buf, fh)
	return buf.Get()
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

func genRecordDecodeWrongType(emit func(call, note string, rec []byte)) {
	// The empty record, through every decoder: `dec.Byte()` latches the error and returns 0, so each
	// method sees type 0.
	for _, call := range []string{
		"series", "metadata", "samples", "tombstones", "exemplars", "mmapmarkers", "histograms",
		"floathistograms",
	} {
		emit(call, "empty-record", []byte{})
		// A record whose only byte is the type of a DIFFERENT record.
		emit(call, "wrong-type-series", []byte{byte(record.Series)})
		emit(call, "wrong-type-samples", []byte{byte(record.Samples)})
		emit(call, "wrong-type-255", []byte{255})
		emit(call, "wrong-type-0", []byte{0})
	}
	// The type bytes each histogram decoder DOES accept, with no payload.
	emit("histograms", "type-custombuckets-empty", []byte{byte(record.CustomBucketsHistogramSamples)})
	emit("histograms", "type-v2-empty", []byte{byte(record.HistogramSamplesV2)})
	emit("floathistograms", "type-custombuckets-empty",
		[]byte{byte(record.CustomBucketsFloatHistogramSamples)})
	emit("floathistograms", "type-v2-empty", []byte{byte(record.FloatHistogramSamplesV2)})
	emit("samples", "type-v2-empty", []byte{byte(record.SamplesV2)})
	// A float-histogram record handed to the integer decoder and vice versa: the NAMED error.
	emit("histograms", "wrong-type-floathist", []byte{byte(record.FloatHistogramSamples)})
	emit("floathistograms", "wrong-type-inthist", []byte{byte(record.HistogramSamples)})
}

func genRecordDecodeTruncation(emit func(call, note string, rec []byte)) {
	full := buildSamplesV1(7, 1000, 1.5, 0)
	// Every prefix from "type byte only" to one short of complete. The interesting boundaries are 1
	// (`dec.Len() == 0`, a clean empty result), 9 (base ref read, base time short) and 25 (the value's
	// last byte missing).
	for keep := 1; keep < len(full); keep++ {
		emit("samples", fmt.Sprintf("truncated-%02d", keep), full[:keep])
	}
	// Trailing bytes: enough to start a varint pair but not to finish the entry.
	emit("samples", "trailing-1", buildSamplesV1(7, 1000, 1.5, 1))
	emit("samples", "trailing-3", buildSamplesV1(7, 1000, 1.5, 3))

	// The same for a Series record, whose tail checks return the BARE Decbuf error rather than a
	// wrapped one — a different message for the same condition.
	series := buildSeriesWithLabels(3, [][2]string{{"a", "b"}})
	for keep := 1; keep < len(series); keep++ {
		emit("series", fmt.Sprintf("truncated-%02d", keep), series[:keep])
	}

	// A Tombstones record cut mid-varint, and one with a stray byte.
	var ts encoding.Encbuf
	ts.PutByte(byte(record.Tombstones))
	ts.PutBE64(1)
	ts.PutVarint64(10)
	ts.PutVarint64(20)
	tsFull := ts.Get()
	emit("tombstones", "complete", tsFull)
	emit("tombstones", "truncated-09", tsFull[:9])
	emit("tombstones", "trailing", append(append([]byte{}, tsFull...), 0x01))

	// An MmapMarkers record with 8 bytes for the ref and nothing for the mmap ref.
	var mm encoding.Encbuf
	mm.PutByte(byte(record.MmapMarkers))
	mm.PutBE64(42)
	emit("mmapmarkers", "half-entry", mm.Get())

	// An Exemplars record whose label section is truncated.
	var ex encoding.Encbuf
	ex.PutByte(byte(record.Exemplars))
	ex.PutBE64(1)
	ex.PutBE64int64(100)
	ex.PutVarint64(0)
	ex.PutVarint64(0)
	ex.PutBE64(math.Float64bits(1))
	ex.PutUvarint(2) // claims two labels
	ex.PutUvarintStr("a")
	ex.PutUvarintStr("b")
	emit("exemplars", "labels-short", ex.Get())
}

func genRecordDecodeLabels(emit func(call, note string, rec []byte)) {
	// OUT OF ORDER. `DecodeLabels` never sorts, so this decodes to `{"z"=…,"a"=…}` — and any port that
	// builds a sorted `Labels` disagrees.
	emit("series", "labels-unsorted",
		buildSeriesWithLabels(1, [][2]string{{"z", "1"}, {"a", "2"}, {"m", "3"}}))
	// A duplicate name, which `ScratchBuilder.Add` does not reject.
	emit("series", "labels-duplicate",
		buildSeriesWithLabels(1, [][2]string{{"a", "1"}, {"a", "2"}}))
	// An empty NAME, which `labels.Labels` treats as invalid but the codec writes and reads.
	emit("series", "labels-empty-name",
		buildSeriesWithLabels(1, [][2]string{{"", "v"}}))
	// Zero labels: a valid series record with an empty label set.
	emit("series", "labels-none", buildSeriesWithLabels(1, nil))
	// A label count of zero followed by a second series, so the parser has to be aligned.
	var b encoding.Encbuf
	b.PutByte(byte(record.Series))
	b.PutBE64(1)
	b.PutUvarint(0)
	b.PutBE64(2)
	b.PutUvarint(1)
	b.PutUvarintStr("x")
	b.PutUvarintStr("y")
	emit("series", "two-series-first-empty", b.Get())
}

func genRecordDecodeMetadataFields(emit func(call, note string, rec []byte)) {
	// The ordinary shape the encoder writes.
	emit("metadata", "unit-help",
		buildMetadata(1, 2, [][2]string{{"UNIT", "s"}, {"HELP", "h"}}, 2))
	// HELP before UNIT — order is not significant, the switch is on the name.
	emit("metadata", "help-unit",
		buildMetadata(1, 2, [][2]string{{"HELP", "h"}, {"UNIT", "s"}}, 2))
	// A THIRD field with an unrecognised name, which must be consumed rather than skipped.
	emit("metadata", "extra-field",
		buildMetadata(1, 2, [][2]string{{"UNIT", "s"}, {"XXXX", "ignored"}, {"HELP", "h"}}, 3))
	// numFields = 0 with no fields: unit and help stay empty.
	emit("metadata", "no-fields", buildMetadata(1, 3, nil, 0))
	// numFields UNDERSTATED: the declared count is 1 but two pairs follow, so the second pair is read
	// as the next metadata ENTRY and misparses.
	emit("metadata", "count-understated",
		buildMetadata(1, 2, [][2]string{{"UNIT", "s"}, {"HELP", "h"}}, 1))
	// numFields OVERSTATED: the reader runs off the end.
	emit("metadata", "count-overstated",
		buildMetadata(1, 2, [][2]string{{"UNIT", "s"}}, 2))
	// Case matters — `unit` is not `UNIT`.
	emit("metadata", "lowercase-names",
		buildMetadata(1, 2, [][2]string{{"unit", "s"}, {"help", "h"}}, 2))
}

func genRecordDecodeSTMarkers(emit func(call, note string, rec []byte)) {
	emit("samples", "marker-nost", buildSamplesV2WithMarker(0, 0))
	emit("samples", "marker-samest", buildSamplesV2WithMarker(1, 0))
	emit("samples", "marker-explicit", buildSamplesV2WithMarker(2, 25))
	emit("samples", "marker-explicit-negative", buildSamplesV2WithMarker(2, -400))
	// Out of range: `default` catches it, so 3, 47 and 255 all behave as `explicitST`.
	emit("samples", "marker-3", buildSamplesV2WithMarker(3, 7))
	emit("samples", "marker-47", buildSamplesV2WithMarker(47, 7))
	emit("samples", "marker-255", buildSamplesV2WithMarker(255, 7))
}

func genRecordDecodeSchemas(emit func(call, note string, rec []byte)) {
	// Known-good schemas, for contrast.
	emit("histograms", "schema-0", buildIntHistogramV1(0, false))
	emit("histograms", "schema-min", buildIntHistogramV1(histogram.ExponentialSchemaMin, false))
	emit("histograms", "schema-max", buildIntHistogramV1(histogram.ExponentialSchemaMax, false))
	emit("histograms", "schema-custombuckets",
		buildIntHistogramV1(histogram.CustomBucketsSchema, false))

	// Reserved but too fine: `IsKnownSchema` accepts it and the decoder REDUCES the resolution, so the
	// histogram that comes out is not the one the bytes describe.
	emit("histograms", "schema-9-reduced", buildIntHistogramV1(9, false))
	emit("histograms", "schema-52-reduced",
		buildIntHistogramV1(histogram.ExponentialSchemaMaxReserved, false))
	// Reserved on the coarse side: within `IsKnownSchema` and NOT reduced.
	emit("histograms", "schema-min-reserved",
		buildIntHistogramV1(histogram.ExponentialSchemaMinReserved, false))

	// Unknown: skipped with a warning, and the record still decodes.
	emit("histograms", "schema-53-skipped", buildIntHistogramV1(53, false))
	emit("histograms", "schema-neg10-skipped", buildIntHistogramV1(-10, false))
	emit("histograms", "schema-neg54-skipped", buildIntHistogramV1(-54, false))
	// Skipped, then a good one — so the skip continues rather than aborting, and the second entry's
	// deltas are still against the base pair.
	emit("histograms", "schema-53-then-good", buildIntHistogramV1(53, true))

	// The same axis for float histograms.
	emit("floathistograms", "schema-0", buildFloatHistogramV1(0))
	emit("floathistograms", "schema-9-reduced", buildFloatHistogramV1(9))
	emit("floathistograms", "schema-53-skipped", buildFloatHistogramV1(53))

	// The reduction FAILING, which is where `error reducing resolution of histogram #N` lives. Added
	// because the control on that message's index survived: nothing else in the corpus can produce it.
	emit("histograms", "reduce-fails-negative-offset",
		buildIntHistogramReduceFailure("negative-offset", false))
	emit("histograms", "reduce-fails-negative-offset-second",
		buildIntHistogramReduceFailure("negative-offset", true))
	emit("histograms", "reduce-fails-too-few-buckets",
		buildIntHistogramReduceFailure("too-few-buckets", false))
	emit("histograms", "reduce-fails-too-few-buckets-second",
		buildIntHistogramReduceFailure("too-few-buckets", true))
	emit("floathistograms", "reduce-fails-negative-offset", buildFloatHistogramReduceFailure())

	// V2: the skipped entry still advances `prevRef` and `prevST`, so the second entry's ref is
	// relative to a sample that is not in the output.
	emit("histograms", "v2-skip-advances-prev", buildIntHistogramV2(53, 0))
	emit("histograms", "v2-both-good", buildIntHistogramV2(0, 0))
	emit("histograms", "v2-second-skipped", buildIntHistogramV2(0, 53))
}
