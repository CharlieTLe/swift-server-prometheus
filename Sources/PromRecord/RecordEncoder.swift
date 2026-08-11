//===----------------------------------------------------------------------===//
// Ported from tsdb/record/record.go @ v3.13.2 — `Encoder`.
//
// ## The `b []byte` parameter is dropped, and `Reset` is why that needs an argument
//
// Every Go encoder is `func (*Encoder) X(xs []X, b []byte) []byte` and starts `encoding.Encbuf{B: b}`, so
// it APPENDS to a buffer the caller supplies — `head_append.go` keeps one per commit and passes `buf[:0]`.
// That is `sync.Pool`'s reasoning (PORTING.md exception 4) and the port returns a fresh `[UInt8]`.
//
// It is worth one more sentence than the usual allocation-detail note, because `histogramSamplesV1` calls
// `buf.Reset()` — which is `e.B = e.B[:0]`, i.e. it truncates the CALLER's prefix as well as its own
// output. A caller that passed a non-empty `b` would lose it. No caller does, so dropping the parameter
// changes nothing observable; but the two facts have to be checked together, not separately.
//
// ## `histogramSamplesV1` writes a base pair it may then never use, and can return ZERO bytes
//
// It writes `histograms[0]`'s ref and timestamp as the delta base **before** the loop, and the loop then
// skips every custom-buckets histogram. So:
//
//   * the base pair can come from a histogram that is not in the record at all;
//   * if *every* histogram uses custom buckets, `buf.Reset()` runs and `Get()` returns an **empty**
//     slice — not a one-byte record, not a type byte, nothing. A reader is never handed it because
//     `head_append.go` checks the length, but the encoder's contract is "empty", and a port that returned
//     `[HistogramSamples]` would write a record Prometheus reads as an empty histogram batch.
//
// The custom-buckets ones come back as the second result, for `CustomBucketsHistogramSamples` to encode
// under type 9. `floatHistogramSamplesV1` is the same shape.
//
// ## Samples V1 is DELTA-encoded against the first sample, and the deltas are SIGNED
//
//     [type byte][BE64 first.Ref][BE64 first.T] then per sample:
//         [varint ref - first.Ref][varint t - first.T][BE64 float bits]
//
// Three things a reading of the format would get wrong:
//
//   1. **The first sample is written TWICE** — once as the base pair, then again in the loop as a delta of
//      zero. Not an off-by-one: the loop starts at index 0, so `samples[0]` contributes `varint(0)
//      varint(0)` plus its value.
//   2. **An empty sample list produces a ONE-BYTE record**, just the type. The base pair is written only
//      when there is a first sample, so `len(samples) == 0` returns early — and a decoder must handle a
//      record with no base.
//   3. **The value is `PutBE64(math.Float64bits(v))`, not a varint** — fixed 8 bytes, so a NaN or an
//      infinity round-trips bit-for-bit including its payload. `GoFloat.format` is not involved.
//
// The reference delta is signed because series refs are not monotonic within a batch, and the timestamp
// delta is signed because the WAL admits out-of-order appends. Both are `PutVarint64`, i.e. zigzag.
//
// ## V2 is a DIFFERENT record type byte, and its deltas have a different base
//
// `Samples` dispatches on `EnableSTStorage`: V1 writes type 2, V2 writes type 11. The flag is a format
// version, not an optimisation. And V2 changes which value each delta is against — the **ref** delta is
// against the *previous* sample while the **timestamp** delta is against the *first*:
//
//     buf.PutVarint64(int64(s.Ref) - int64(prev.Ref))
//     buf.PutVarint64(s.T - first.T)
//
// so the two fields in adjacent positions have different bases. The first sample's ref, t and st are all
// written raw as varints (not BE64 — another V1/V2 difference), st included even when it is 0.
//
// ## The ST marker byte is three-valued and its `explicitST` delta is against the FIRST st
//
//     0 noST        st is 0
//     1 sameST      st equals the PREVIOUS sample's st
//     2 explicitST  followed by varint(st - firstST)
//
// Two orderings matter. `writeSTMarker`'s switch tests `case 0` before `case prevST`, so an st of 0 is
// always `noST` even when `prevST` is also 0 — the two encodings are not interchangeable and the byte
// count differs. And `readSTMarker`'s `default` catches *every* byte that is not 0 or 1, so a marker of
// 200 is read as `explicitST`; there is no validation.
//===----------------------------------------------------------------------===//

public import PromHistogram
public import PromLabels
public import PromTombstones

public import PromEncoding

/// Go: `record.Encoder`. The zero value is ready to use.
public struct RecordEncoder: Sendable {

    /// Go: `Encoder.EnableSTStorage` — selects the V2 sample encodings, which carry a start timestamp
    /// per sample. A format version rather than a tuning knob; see the file header.
    public var enableSTStorage: Bool

    public init(enableSTStorage: Bool = false) {
        self.enableSTStorage = enableSTStorage
    }

    // MARK: - Series and metadata

    /// Go: `Encoder.Series`.
    public func series(_ series: [RefSeries]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.series.rawValue)
        for s in series {
            buf.putBE64(s.ref.rawValue)
            encodeLabels(&buf, s.labels)
        }
        return buf.bytes
    }

    /// Go: `Encoder.Metadata`.
    ///
    /// The ref is a **uvarint** here and a BE64 everywhere else, and the field count is hard-coded to 2:
    /// UNIT then HELP, both always written even when empty.
    public func metadata(_ metadata: [RefMetadata]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.metadata.rawValue)
        for m in metadata {
            buf.putUvarint64(m.ref.rawValue)
            buf.putByte(m.type)
            buf.putUvarint(2)
            buf.putUvarintStr(unitMetaName)
            buf.putUvarintStr(m.unit)
            buf.putUvarintStr(helpMetaName)
            buf.putUvarintStr(m.help)
        }
        return buf.bytes
    }

    // MARK: - Samples

    /// Go: `Encoder.Samples` — V1 or V2 depending on ``enableSTStorage``.
    public func samples(_ samples: [RefSample]) -> [UInt8] {
        enableSTStorage ? samplesV2(samples) : samplesV1(samples)
    }

    /// Go: `Encoder.samplesV1`.
    func samplesV1(_ samples: [RefSample]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.samples.rawValue)
        guard let first = samples.first else { return buf.bytes }

        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)

        // Starts at 0, so the first sample is written a second time as a pair of zero deltas.
        for s in samples {
            buf.putVarint64(
                Int64(bitPattern: s.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(s.t &- first.t)
            buf.putBE64(s.v.bitPattern)
        }
        return buf.bytes
    }

    /// Go: `Encoder.samplesV2`.
    func samplesV2(_ samples: [RefSample]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.samplesV2.rawValue)
        guard let first = samples.first else { return buf.bytes }

        buf.putVarint64(Int64(bitPattern: first.ref.rawValue))
        buf.putVarint64(first.t)
        buf.putVarint64(first.st)
        buf.putBE64(first.v.bitPattern)

        for i in 1..<samples.count {
            let s = samples[i]
            let prev = samples[i - 1]
            // The ref delta is against the PREVIOUS sample; the timestamp delta against the FIRST.
            buf.putVarint64(
                Int64(bitPattern: s.ref.rawValue) &- Int64(bitPattern: prev.ref.rawValue))
            buf.putVarint64(s.t &- first.t)
            writeSTMarker(&buf, s.st, first.st, prev.st)
            buf.putBE64(s.v.bitPattern)
        }
        return buf.bytes
    }

    // MARK: - Tombstones, exemplars and mmap markers

    /// Go: `Encoder.Tombstones`.
    ///
    /// One entry per **interval**, not per stone, so a stone with three intervals repeats its ref three
    /// times. `PromTombstones.Stone` documents the asymmetry that makes decoding not the inverse.
    public func tombstones(_ tstones: [Stone]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.tombstones.rawValue)
        for s in tstones {
            for iv in s.intervals {
                buf.putBE64(s.ref.rawValue)
                buf.putVarint64(iv.mint)
                buf.putVarint64(iv.maxt)
            }
        }
        return buf.bytes
    }

    /// Go: `Encoder.Exemplars`.
    public func exemplars(_ exemplars: [RefExemplar]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.exemplars.rawValue)
        if exemplars.isEmpty { return buf.bytes }
        encodeExemplarsIntoBuffer(exemplars, &buf)
        return buf.bytes
    }

    /// Go: `Encoder.EncodeExemplarsIntoBuffer`. Exported upstream because the remote-write path reuses it.
    ///
    /// It indexes `exemplars[0]` with no guard — `Exemplars` checks emptiness before calling, and this is
    /// the only other caller. Kept `throws`-free and unguarded so the shape matches; the caller's check is
    /// the contract.
    public func encodeExemplarsIntoBuffer(_ exemplars: [RefExemplar], _ buf: inout Encbuf) {
        let first = exemplars[0]
        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)
        for ex in exemplars {
            buf.putVarint64(
                Int64(bitPattern: ex.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(ex.t &- first.t)
            buf.putBE64(ex.v.bitPattern)
            encodeLabels(&buf, ex.labels)
        }
    }

    /// Go: `Encoder.MmapMarkers`.
    public func mmapMarkers(_ markers: [RefMmapMarker]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.mmapMarkers.rawValue)
        for s in markers {
            buf.putBE64(s.ref.rawValue)
            buf.putBE64(s.mmapRef.rawValue)
        }
        return buf.bytes
    }

    // MARK: - Integer histograms

    /// Go: `Encoder.HistogramSamples`. The second result is the custom-buckets histograms this record did
    /// **not** encode, for ``customBucketsHistogramSamples(_:)`` to write under type 9. In V2 mode
    /// there is no split and it is always empty.
    public func histogramSamples(_ histograms: [RefHistogramSample]) -> ([UInt8], [RefHistogramSample]) {
        if enableSTStorage {
            return (histogramSamplesV2(histograms), [])
        }
        return histogramSamplesV1(histograms)
    }

    /// Go: `Encoder.histogramSamplesV1`. See the file header on the base pair and the empty result.
    func histogramSamplesV1(
        _ histograms: [RefHistogramSample]
    ) -> ([UInt8], [RefHistogramSample]) {
        var buf = Encbuf()
        buf.putByte(RecordType.histogramSamples.rawValue)
        guard let first = histograms.first else { return (buf.bytes, []) }

        var customBucketHistograms: [RefHistogramSample] = []
        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)

        for h in histograms {
            if h.h.usesCustomBuckets {
                customBucketHistograms.append(h)
                continue
            }
            buf.putVarint64(
                Int64(bitPattern: h.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(h.t &- first.t)
            encodeHistogram(&buf, h.h)
        }

        // Every histogram was custom-buckets: the record becomes ZERO bytes, type byte included.
        if histograms.count == customBucketHistograms.count {
            buf.reset()
        }
        return (buf.bytes, customBucketHistograms)
    }

    /// Go: `Encoder.histogramSamplesV2`.
    func histogramSamplesV2(_ histograms: [RefHistogramSample]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.histogramSamplesV2.rawValue)
        guard let first = histograms.first else { return buf.bytes }

        buf.putVarint64(Int64(bitPattern: first.ref.rawValue))
        buf.putVarint64(first.t)
        buf.putVarint64(first.st)
        encodeHistogram(&buf, first.h)

        for i in 1..<histograms.count {
            let h = histograms[i]
            let prev = histograms[i - 1]
            buf.putVarint64(
                Int64(bitPattern: h.ref.rawValue) &- Int64(bitPattern: prev.ref.rawValue))
            buf.putVarint64(h.t &- first.t)
            writeSTMarker(&buf, h.st, first.st, prev.st)
            encodeHistogram(&buf, h.h)
        }
        return buf.bytes
    }

    /// Go: `Encoder.CustomBucketsHistogramSamples`. Note the V2 branch writes type **12**, not 9 — V2 has
    /// no separate custom-buckets record.
    public func customBucketsHistogramSamples(_ histograms: [RefHistogramSample]) -> [UInt8] {
        if enableSTStorage {
            return histogramSamplesV2(histograms)
        }
        return customBucketsHistogramSamplesV1(histograms)
    }

    /// Go: `Encoder.customBucketsHistogramSamplesV1`. Same as V1 without the split — and with no `Reset`,
    /// because everything here is meant to be custom-buckets.
    func customBucketsHistogramSamplesV1(_ histograms: [RefHistogramSample]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.customBucketsHistogramSamples.rawValue)
        guard let first = histograms.first else { return buf.bytes }

        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)
        for h in histograms {
            buf.putVarint64(
                Int64(bitPattern: h.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(h.t &- first.t)
            encodeHistogram(&buf, h.h)
        }
        return buf.bytes
    }

    // MARK: - Float histograms

    /// Go: `Encoder.FloatHistogramSamples`.
    public func floatHistogramSamples(
        _ histograms: [RefFloatHistogramSample]
    ) -> ([UInt8], [RefFloatHistogramSample]) {
        if enableSTStorage {
            return (floatHistogramSamplesV2(histograms), [])
        }
        return floatHistogramSamplesV1(histograms)
    }

    /// Go: `Encoder.floatHistogramSamplesV1`.
    func floatHistogramSamplesV1(
        _ histograms: [RefFloatHistogramSample]
    ) -> ([UInt8], [RefFloatHistogramSample]) {
        var buf = Encbuf()
        buf.putByte(RecordType.floatHistogramSamples.rawValue)
        guard let first = histograms.first else { return (buf.bytes, []) }

        var customBucketsFloatHistograms: [RefFloatHistogramSample] = []
        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)

        for h in histograms {
            if h.fh.usesCustomBuckets {
                customBucketsFloatHistograms.append(h)
                continue
            }
            buf.putVarint64(
                Int64(bitPattern: h.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(h.t &- first.t)
            encodeFloatHistogram(&buf, h.fh)
        }

        if histograms.count == customBucketsFloatHistograms.count {
            buf.reset()
        }
        return (buf.bytes, customBucketsFloatHistograms)
    }

    /// Go: `Encoder.floatHistogramSamplesV2`.
    func floatHistogramSamplesV2(_ histograms: [RefFloatHistogramSample]) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.floatHistogramSamplesV2.rawValue)
        guard let first = histograms.first else { return buf.bytes }

        buf.putVarint64(Int64(bitPattern: first.ref.rawValue))
        buf.putVarint64(first.t)
        buf.putVarint64(first.st)
        encodeFloatHistogram(&buf, first.fh)

        for i in 1..<histograms.count {
            let fh = histograms[i]
            let prev = histograms[i - 1]
            buf.putVarint64(
                Int64(bitPattern: fh.ref.rawValue) &- Int64(bitPattern: prev.ref.rawValue))
            buf.putVarint64(fh.t &- first.t)
            writeSTMarker(&buf, fh.st, first.st, prev.st)
            encodeFloatHistogram(&buf, fh.fh)
        }
        return buf.bytes
    }

    /// Go: `Encoder.CustomBucketsFloatHistogramSamples`.
    public func customBucketsFloatHistogramSamples(
        _ histograms: [RefFloatHistogramSample]
    ) -> [UInt8] {
        if enableSTStorage {
            return floatHistogramSamplesV2(histograms)
        }
        return customBucketsFloatHistogramSamplesV1(histograms)
    }

    /// Go: `Encoder.customBucketsFloatHistogramSamplesV1`.
    func customBucketsFloatHistogramSamplesV1(
        _ histograms: [RefFloatHistogramSample]
    ) -> [UInt8] {
        var buf = Encbuf()
        buf.putByte(RecordType.customBucketsFloatHistogramSamples.rawValue)
        guard let first = histograms.first else { return buf.bytes }

        buf.putBE64(first.ref.rawValue)
        buf.putBE64int64(first.t)
        for h in histograms {
            buf.putVarint64(
                Int64(bitPattern: h.ref.rawValue) &- Int64(bitPattern: first.ref.rawValue))
            buf.putVarint64(h.t &- first.t)
            encodeFloatHistogram(&buf, h.fh)
        }
        return buf.bytes
    }
}

// MARK: - The shared field codecs

/// Go: `record.EncodeLabels`. Shared by the Series and Exemplars records.
///
/// **ADR-9.** Go writes the label bytes verbatim with no validation, so an invalid-UTF-8 name round-trips
/// through the WAL. `Labels` here holds Swift `String`s, so the port cannot carry those bytes — see
/// PORTING.md exception 17, which is the same open question §6 of the handoff records for `Labels` as a
/// whole. Everything valid is byte-exact.
public func encodeLabels(_ buf: inout Encbuf, _ lbls: Labels) {
    buf.putUvarint(lbls.count)
    for l in lbls {
        buf.putUvarintStr(l.name)
        buf.putUvarintStr(l.value)
    }
}

/// Go: `record.writeSTMarker`. `case 0` is tested before `case prevST`; see the file header.
func writeSTMarker(_ buf: inout Encbuf, _ st: Int64, _ firstST: Int64, _ prevST: Int64) {
    if st == 0 {
        buf.putByte(stMarkerNoST)
    } else if st == prevST {
        buf.putByte(stMarkerSameST)
    } else {
        buf.putByte(stMarkerExplicitST)
        buf.putVarint64(st &- firstST)
    }
}

/// Go: the `noST`/`sameST`/`explicitST` iota block.
let stMarkerNoST: UInt8 = 0
let stMarkerSameST: UInt8 = 1
let stMarkerExplicitST: UInt8 = 2

/// Go: `record.EncodeHistogram`.
///
/// Note the asymmetry with ``encodeFloatHistogram(_:_:)``: the integer form writes `ZeroCount` and `Count`
/// as **uvarints** and only `ZeroThreshold`/`Sum` as BE64 floats, while the float form writes all four as
/// BE64. `CustomValues` is written only for the custom-buckets schema, and its length prefix is absent
/// rather than zero for every other schema — so the field is not skippable by a reader that does not know
/// the schema.
public func encodeHistogram(_ buf: inout Encbuf, _ h: Histogram) {
    buf.putByte(h.counterResetHint.rawValue)

    buf.putVarint64(Int64(h.schema))
    buf.putBE64(h.zeroThreshold.bitPattern)

    buf.putUvarint64(h.zeroCount)
    buf.putUvarint64(h.count)
    buf.putBE64(h.sum.bitPattern)

    buf.putUvarint(h.positiveSpans.count)
    for s in h.positiveSpans {
        buf.putVarint64(Int64(s.offset))
        buf.putUvarint32(s.length)
    }

    buf.putUvarint(h.negativeSpans.count)
    for s in h.negativeSpans {
        buf.putVarint64(Int64(s.offset))
        buf.putUvarint32(s.length)
    }

    buf.putUvarint(h.positiveBuckets.count)
    for b in h.positiveBuckets {
        buf.putVarint64(b)
    }

    buf.putUvarint(h.negativeBuckets.count)
    for b in h.negativeBuckets {
        buf.putVarint64(b)
    }

    if isCustomBucketsSchema(h.schema) {
        let values = h.customValues ?? []
        buf.putUvarint(values.count)
        for v in values {
            buf.putBEFloat64(v)
        }
    }
}

/// Go: `record.EncodeFloatHistogram`.
public func encodeFloatHistogram(_ buf: inout Encbuf, _ h: FloatHistogram) {
    buf.putByte(h.counterResetHint.rawValue)

    buf.putVarint64(Int64(h.schema))
    buf.putBEFloat64(h.zeroThreshold)

    buf.putBEFloat64(h.zeroCount)
    buf.putBEFloat64(h.count)
    buf.putBEFloat64(h.sum)

    buf.putUvarint(h.positiveSpans.count)
    for s in h.positiveSpans {
        buf.putVarint64(Int64(s.offset))
        buf.putUvarint32(s.length)
    }

    buf.putUvarint(h.negativeSpans.count)
    for s in h.negativeSpans {
        buf.putVarint64(Int64(s.offset))
        buf.putUvarint32(s.length)
    }

    buf.putUvarint(h.positiveBuckets.count)
    for b in h.positiveBuckets {
        buf.putBEFloat64(b)
    }

    buf.putUvarint(h.negativeBuckets.count)
    for b in h.negativeBuckets {
        buf.putBEFloat64(b)
    }

    if isCustomBucketsSchema(h.schema) {
        let values = h.customValues ?? []
        buf.putUvarint(values.count)
        for v in values {
            buf.putBEFloat64(v)
        }
    }
}
