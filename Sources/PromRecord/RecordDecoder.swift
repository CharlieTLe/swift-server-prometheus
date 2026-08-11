//===----------------------------------------------------------------------===//
// Ported from tsdb/record/record.go @ v3.13.2 — `Decoder`.
//
// ## Every decoder APPENDS to a caller-supplied slice, and for `samplesV2` that is load-bearing
//
// Go's signature is `func (d *Decoder) Samples(rec []byte, samples []RefSample) ([]RefSample, error)`,
// and `samplesV2` decides whether an entry is the record's *first* by asking `len(samples) == 0` — of the
// combined slice. So handing it a non-empty accumulator makes it read the first entry with the
// second-entry framing: it takes `prev` from the CALLER's last sample, reads a ref delta and a timestamp
// delta against a `firstT` that is still 0 (the variable is declared outside the loop and only assigned in
// the branch that did not run), and reads an ST **marker byte** where the encoder wrote a raw varint. The
// result is misaligned garbage or a decode error, not a partially-correct answer.
//
// That is reachable upstream: `wlog/checkpoint.go:204` passes a `samples` that keeps its length across
// records, so a checkpoint over `SamplesV2` records decodes the second and later records wrongly.
// `head_wal.go:853` passes `pool.Get()[:0]` and is fine. The port reproduces it — `into:` defaults to
// empty, and the corpus carries the pre-seeded case so Go is the one saying what comes out.
//
// **`histogramSamplesV2` and `floatHistogramSamplesV2` do NOT have it**, because they track a local
// `hasPrev` instead of measuring the accumulator. Same shape, three implementations, one of them
// accumulator-sensitive: a port that unified them would either fix the bug or spread it.
//
// ## The one declared divergence: `samplesV1`/`samplesV2` size their output by CAPACITY
//
// Both open with
//
//     if minSize := dec.Len() / (1 + 1 + 8); cap(samples) < minSize {
//         samples = make([]RefSample, 0, minSize)
//     }
//
// which **throws the accumulator away** whenever the caller's slice is not already large enough — an
// allocation heuristic that decides a semantic. It also interacts with the paragraph above: when the reset
// fires, `len(samples)` becomes 0 and `samplesV2` then parses the first entry *correctly*, so which of the
// two bugs a caller gets depends on the capacity of the slice it happened to pass.
//
// Swift's `Array` has no `make(len, cap)` and its growth curve is not Go's, so this cannot be reproduced
// faithfully — `reserveCapacity(n)` and `append`-driven growth would agree with Go on some sizes and not
// others, which is worse than a stated divergence. PORTING.md exception 18 records it. The port always
// keeps the accumulator, which is the branch every real caller takes: `head_wal.go` passes a pooled slice
// and `checkpoint.go` an accumulated one, and both have ample capacity by the time it could matter. The
// corpus pins that branch by giving its seeds a generous capacity on the Go side.
//
// ## `Decbuf`'s sticky error is what terminates every loop
//
// The pattern is `for len(dec.B) > 0 && dec.Err() == nil`, then `if dec.Err() != nil` before
// `if len(dec.B) > 0`. A truncated record therefore reports the decode error, not "unexpected N bytes
// left" — the order of those two checks is the difference between a diagnosable corruption and a
// misleading one. A read that fails leaves `B` untouched, so the byte count in the second message is the
// count *including* the bytes the failed read wanted.
//
// ## An unknown schema SKIPS the sample, and a reserved-but-too-fine one REDUCES it
//
// `IsKnownSchema` admits the custom-buckets schema and the reserved exponential range −9…52. Outside that,
// the histogram is dropped with a log line and decoding continues — so a record can decode successfully to
// fewer histograms than it contains. Inside 9…52 (above `ExponentialSchemaMax` of 8) the resolution is
// reduced, and a failure there aborts the whole record with
// `error reducing resolution of histogram #N`, where **N is one-based and counts the accumulator too**.
//
// The port takes ``RecordDecoder/onUnknownSchema`` in place of the `*slog.Logger`, which is the only part
// of upstream's `Decoder` that is not the scratch builder.
//
// ## The ref arithmetic is spelled two different ways for the same result
//
// `samplesV1` computes `chunks.HeadSeriesRef(int64(baseRef) + dref)` — a signed add — while
// `histogramSamplesV1` and `ExemplarsFromBuffer` compute `baseRef + uint64(dref)` — an unsigned one. Both
// agree modulo 2^64, which is what Go's fixed-width arithmetic gives either way. Swift traps on both, so
// each site uses `&+` on the type Go used, keeping the spelling rather than normalising it.
//===----------------------------------------------------------------------===//

internal import PromChunks
public import PromHistogram
public import PromLabels
internal import PromStorage
public import PromTombstones

public import PromEncoding

/// Go: `record.Decoder`.
///
/// `NewDecoder`'s `*labels.SymbolTable` parameter is ignored upstream — the signature carries a `FIXME`
/// saying so — and `SetUnsafeAdd(true)` is a no-op under the default `stringlabels` build. Neither has
/// anything to port.
public struct RecordDecoder {

    /// Go: `Decoder.builder`, reused across every label set in a record.
    private var builder = ScratchBuilder()

    /// Stands in for `Decoder.logger`. Called with the offending schema and the sample's timestamp — the
    /// two structured fields of upstream's
    /// `logger.Warn("skipping histogram with unknown schema in WAL record", "schema", …, "timestamp", …)`.
    public var onUnknownSchema: (@Sendable (Int32, Int64) -> Void)?

    public init(onUnknownSchema: (@Sendable (Int32, Int64) -> Void)? = nil) {
        self.onUnknownSchema = onUnknownSchema
    }

    // MARK: - Series and metadata

    /// Go: `Decoder.Series`.
    public mutating func series(
        _ rec: [UInt8], into series: [RefSeries] = []
    ) throws -> [RefSeries] {
        var series = series
        try withDecbuf(rec) { dec in
            guard RecordType(rawValue: dec.byte()) == .series else {
                throw RecordError.invalidRecordType
            }
            while dec.count > 0 && dec.err == nil {
                let ref = SeriesRef(rawValue: dec.be64())
                let lset = decodeLabels(&dec)
                series.append(RefSeries(ref: HeadSeriesRef(rawValue: ref.rawValue), labels: lset))
            }
            if let e = dec.err { throw RecordError.decbuf(String(describing: e)) }
            if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        }
        return series
    }

    /// Go: `Decoder.Metadata`.
    ///
    /// `numFields` is read from the record and every field is consumed even when its name is neither UNIT
    /// nor HELP — the comment says why: skipping without decoding would lose the alignment for the next
    /// entry. An unrecognised field name is therefore tolerated, and a *count* that disagrees with the
    /// bytes is not.
    public mutating func metadata(
        _ rec: [UInt8], into metadata: [RefMetadata] = []
    ) throws -> [RefMetadata] {
        var metadata = metadata
        try withDecbuf(rec) { dec in
            guard RecordType(rawValue: dec.byte()) == .metadata else {
                throw RecordError.invalidRecordType
            }
            while dec.count > 0 && dec.err == nil {
                let ref = dec.uvarint64()
                let typ = dec.byte()
                let numFields = dec.uvarint()

                var unit = ""
                var help = ""
                for _ in 0..<max(0, numFields) {
                    let fieldName = dec.uvarintStr()
                    let fieldValue = dec.uvarintStr()
                    switch fieldName {
                    case unitMetaName: unit = fieldValue
                    case helpMetaName: help = fieldValue
                    default: break
                    }
                }

                metadata.append(
                    RefMetadata(
                        ref: HeadSeriesRef(rawValue: ref), type: typ, unit: unit, help: help))
            }
            if let e = dec.err { throw RecordError.decbuf(String(describing: e)) }
            if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        }
        return metadata
    }

    /// Go: `Decoder.DecodeLabels`.
    ///
    /// **Not sorted.** `ScratchBuilder.Labels()` returns the pairs in the order they were added, and the
    /// decoder never calls `Sort()`, so a record whose labels were written out of order decodes to an
    /// out-of-order `Labels`. That is upstream's behaviour and the encoder is the one that guarantees
    /// order, by ranging an already-sorted `labels.Labels`.
    public mutating func decodeLabels(_ dec: inout Decbuf) -> Labels {
        builder.reset()
        let nLabels = dec.uvarint()
        for _ in 0..<max(0, nLabels) {
            let name = dec.uvarintStr()
            let value = dec.uvarintStr()
            builder.add(name, value)
        }
        return builder.labels()
    }

    // MARK: - Samples

    /// Go: `Decoder.Samples` — dispatches on the type byte to V1 or V2.
    public mutating func samples(
        _ rec: [UInt8], into samples: [RefSample] = []
    ) throws -> [RefSample] {
        var out = samples
        try withDecbuf(rec) { dec in
            let typ = dec.byte()
            switch RecordType(rawValue: typ) {
            case .samples:
                out = try Self.samplesV1(&dec, out)
            case .samplesV2:
                out = try Self.samplesV2(&dec, out)
            default:
                // `%v` on a BYTE, so the message carries a number. See ``RecordError``.
                throw RecordError.invalidSamplesRecordType(typ)
            }
        }
        return out
    }

    /// Go: `Decoder.samplesV1`.
    static func samplesV1(_ dec: inout Decbuf, _ samples: [RefSample]) throws -> [RefSample] {
        var samples = samples
        if dec.count == 0 { return samples }

        let baseRef = dec.be64()
        let baseTime = dec.be64int64()
        // Go's `minSize` capacity heuristic is NOT reproduced. See the file header — it is a divergence,
        // not an omission, because it discards the accumulator.

        while dec.count > 0 && dec.err == nil {
            let dref = dec.varint64()
            let dtime = dec.varint64()
            let val = dec.be64()
            samples.append(
                RefSample(
                    // Go: `int64(baseRef) + dref` — a SIGNED add. See the file header.
                    ref: HeadSeriesRef(
                        rawValue: UInt64(bitPattern: Int64(bitPattern: baseRef) &+ dref)),
                    t: baseTime &+ dtime,
                    v: Double(bitPattern: val)))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(samples.count, "samples", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return samples
    }

    /// Go: `Decoder.samplesV2`.
    ///
    /// The `len(samples) == 0` test is against the COMBINED slice — see the file header. `firstT` and
    /// `firstST` live outside the loop and are only assigned in that branch, so a pre-seeded accumulator
    /// leaves both at 0 for the whole record.
    static func samplesV2(_ dec: inout Decbuf, _ samples: [RefSample]) throws -> [RefSample] {
        var samples = samples
        if dec.count == 0 { return samples }

        var firstT: Int64 = 0
        var firstST: Int64 = 0
        while dec.count > 0 && dec.err == nil {
            var ref: Int64 = 0
            var t: Int64 = 0
            var st: Int64 = 0

            if samples.isEmpty {
                ref = dec.varint64()
                firstT = dec.varint64()
                t = firstT
                st = dec.varint64()
                firstST = st
            } else {
                let prev = samples[samples.count - 1]
                ref = Int64(bitPattern: prev.ref.rawValue) &+ dec.varint64()
                t = firstT &+ dec.varint64()
                st = readSTMarker(&dec, prev.st, firstST)
            }

            let val = dec.be64()
            samples.append(
                RefSample(
                    ref: HeadSeriesRef(rawValue: UInt64(bitPattern: ref)), st: st, t: t,
                    v: Double(bitPattern: val)))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(samples.count, "samples", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return samples
    }

    // MARK: - Tombstones, exemplars and mmap markers

    /// Go: `Decoder.Tombstones`.
    ///
    /// One `Stone` per wire entry, each carrying exactly one interval — so a stone the encoder wrote from
    /// three intervals comes back as three stones. `PromTombstones.Stone` records why that is not a bug.
    public func tombstones(_ rec: [UInt8], into tstones: [Stone] = []) throws -> [Stone] {
        var tstones = tstones
        try withDecbuf(rec) { dec in
            guard RecordType(rawValue: dec.byte()) == .tombstones else {
                throw RecordError.invalidRecordType
            }
            while dec.count > 0 && dec.err == nil {
                // Go builds the composite literal left to right, so `Be64` runs before the two
                // `Varint64`s. Swift evaluates arguments in order too, but the reads are hoisted here
                // rather than relying on that.
                let ref = dec.be64()
                let mint = dec.varint64()
                let maxt = dec.varint64()
                tstones.append(
                    Stone(
                        ref: SeriesRef(rawValue: ref),
                        intervals: [DeletionInterval(mint: mint, maxt: maxt)]))
            }
            if let e = dec.err { throw RecordError.decbuf(String(describing: e)) }
            if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        }
        return tstones
    }

    /// Go: `Decoder.Exemplars`.
    public mutating func exemplars(
        _ rec: [UInt8], into exemplars: [RefExemplar] = []
    ) throws -> [RefExemplar] {
        var out = exemplars
        try withDecbuf(rec) { dec in
            guard RecordType(rawValue: dec.byte()) == .exemplars else {
                throw RecordError.invalidRecordType
            }
            out = try exemplarsFromBuffer(&dec, out)
        }
        return out
    }

    /// Go: `Decoder.ExemplarsFromBuffer` — exported upstream because remote-write shares it.
    public mutating func exemplarsFromBuffer(
        _ dec: inout Decbuf, _ exemplars: [RefExemplar]
    ) throws -> [RefExemplar] {
        var exemplars = exemplars
        if dec.count == 0 { return exemplars }

        let baseRef = dec.be64()
        let baseTime = dec.be64int64()
        while dec.count > 0 && dec.err == nil {
            let dref = dec.varint64()
            let dtime = dec.varint64()
            let val = dec.be64()
            let lset = decodeLabels(&dec)
            exemplars.append(
                RefExemplar(
                    // Go: `baseRef + uint64(dref)` — UNSIGNED here, unlike samplesV1.
                    ref: HeadSeriesRef(rawValue: baseRef &+ UInt64(bitPattern: dref)),
                    t: baseTime &+ dtime,
                    v: Double(bitPattern: val),
                    labels: lset))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(
                exemplars.count, "exemplars", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return exemplars
    }

    /// Go: `Decoder.MmapMarkers`.
    public func mmapMarkers(
        _ rec: [UInt8], into markers: [RefMmapMarker] = []
    ) throws -> [RefMmapMarker] {
        var markers = markers
        try withDecbuf(rec) { dec in
            guard RecordType(rawValue: dec.byte()) == .mmapMarkers else {
                throw RecordError.invalidRecordType
            }
            if dec.count == 0 { return }
            while dec.count > 0 && dec.err == nil {
                let ref = HeadSeriesRef(rawValue: dec.be64())
                let mmapRef = ChunkDiskMapperRef(rawValue: dec.be64())
                markers.append(RefMmapMarker(ref: ref, mmapRef: mmapRef))
            }
            if let e = dec.err {
                throw RecordError.decodeErrorAfter(
                    markers.count, "mmap markers", String(describing: e))
            }
            if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        }
        return markers
    }

    // MARK: - Integer histograms

    /// Go: `Decoder.HistogramSamples`. Type 9 (custom buckets) goes through the V1 path — the schema in
    /// the payload is what selects the custom-values field, not the record type.
    public func histogramSamples(
        _ rec: [UInt8], into histograms: [RefHistogramSample] = []
    ) throws -> [RefHistogramSample] {
        var out = histograms
        try withDecbuf(rec) { dec in
            let typ = RecordType(rawValue: dec.byte())
            switch typ {
            case .histogramSamples, .customBucketsHistogramSamples:
                out = try histogramSamplesV1(&dec, out)
            case .histogramSamplesV2:
                out = try histogramSamplesV2(&dec, out)
            default:
                // `%v` on a `Type`, so the message carries a NAME. See ``RecordError``.
                throw RecordError.invalidHistogramRecordType(typ)
            }
        }
        return out
    }

    /// Go: `Decoder.histogramSamplesV1`.
    func histogramSamplesV1(
        _ dec: inout Decbuf, _ histograms: [RefHistogramSample]
    ) throws -> [RefHistogramSample] {
        var histograms = histograms
        if dec.count == 0 { return histograms }

        let baseRef = dec.be64()
        let baseTime = dec.be64int64()
        while dec.count > 0 && dec.err == nil {
            let dref = dec.varint64()
            let dtime = dec.varint64()

            let ref = HeadSeriesRef(rawValue: baseRef &+ UInt64(bitPattern: dref))
            let t = baseTime &+ dtime
            var h = Histogram()
            decodeHistogram(&dec, &h)

            if !isKnownSchema(h.schema) {
                onUnknownSchema?(h.schema, t)
                continue
            }
            if h.schema > HistogramSchema.exponentialMax
                && h.schema <= HistogramSchema.exponentialMaxReserved
            {
                do {
                    try h.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
                } catch {
                    throw RecordError.reduceResolution(
                        histograms.count + 1, String(describing: error))
                }
            }
            histograms.append(RefHistogramSample(ref: ref, t: t, h: h))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(
                histograms.count, "histograms", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return histograms
    }

    /// Go: `Decoder.histogramSamplesV2`.
    ///
    /// `prevRef`/`prevST` are assigned from the sample under construction **before** the histogram is
    /// decoded, and therefore also before the unknown-schema `continue`. So a skipped histogram still
    /// advances the delta base: dropping a sample does not reset the chain.
    func histogramSamplesV2(
        _ dec: inout Decbuf, _ histograms: [RefHistogramSample]
    ) throws -> [RefHistogramSample] {
        var histograms = histograms
        if dec.count == 0 { return histograms }

        let firstRef = dec.varint64()
        let firstT = dec.varint64()
        let firstST = dec.varint64()
        var prevRef: Int64 = 0
        var prevST: Int64 = 0
        var hasPrev = false

        while dec.count > 0 && dec.err == nil {
            var ref: Int64 = 0
            var t: Int64 = 0
            var st: Int64 = 0
            if !hasPrev {
                (ref, t, st) = (firstRef, firstT, firstST)
                hasPrev = true
            } else {
                ref = prevRef &+ dec.varint64()
                t = firstT &+ dec.varint64()
                st = readSTMarker(&dec, prevST, firstST)
            }

            prevRef = ref
            prevST = st
            var h = Histogram()
            decodeHistogram(&dec, &h)

            if !isKnownSchema(h.schema) {
                onUnknownSchema?(h.schema, t)
                continue
            }
            if h.schema > HistogramSchema.exponentialMax
                && h.schema <= HistogramSchema.exponentialMaxReserved
            {
                do {
                    try h.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
                } catch {
                    throw RecordError.reduceResolution(
                        histograms.count + 1, String(describing: error))
                }
            }
            histograms.append(
                RefHistogramSample(
                    ref: HeadSeriesRef(rawValue: UInt64(bitPattern: ref)), st: st, t: t, h: h))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(
                histograms.count, "histograms", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return histograms
    }

    // MARK: - Float histograms

    /// Go: `Decoder.FloatHistogramSamples`.
    public func floatHistogramSamples(
        _ rec: [UInt8], into histograms: [RefFloatHistogramSample] = []
    ) throws -> [RefFloatHistogramSample] {
        var out = histograms
        try withDecbuf(rec) { dec in
            let typ = RecordType(rawValue: dec.byte())
            switch typ {
            case .floatHistogramSamples, .customBucketsFloatHistogramSamples:
                out = try floatHistogramSamplesV1(&dec, out)
            case .floatHistogramSamplesV2:
                out = try floatHistogramSamplesV2(&dec, out)
            default:
                throw RecordError.invalidHistogramRecordType(typ)
            }
        }
        return out
    }

    /// Go: `Decoder.floatHistogramSamplesV1`.
    func floatHistogramSamplesV1(
        _ dec: inout Decbuf, _ histograms: [RefFloatHistogramSample]
    ) throws -> [RefFloatHistogramSample] {
        var histograms = histograms
        if dec.count == 0 { return histograms }

        let baseRef = dec.be64()
        let baseTime = dec.be64int64()
        while dec.count > 0 && dec.err == nil {
            let dref = dec.varint64()
            let dtime = dec.varint64()

            let ref = HeadSeriesRef(rawValue: baseRef &+ UInt64(bitPattern: dref))
            let t = baseTime &+ dtime
            var fh = FloatHistogram()
            decodeFloatHistogram(&dec, &fh)

            if !isKnownSchema(fh.schema) {
                onUnknownSchema?(fh.schema, t)
                continue
            }
            if fh.schema > HistogramSchema.exponentialMax
                && fh.schema <= HistogramSchema.exponentialMaxReserved
            {
                do {
                    try fh.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
                } catch {
                    throw RecordError.reduceResolution(
                        histograms.count + 1, String(describing: error))
                }
            }
            histograms.append(RefFloatHistogramSample(ref: ref, t: t, fh: fh))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(
                histograms.count, "histograms", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return histograms
    }

    /// Go: `Decoder.floatHistogramSamplesV2`.
    func floatHistogramSamplesV2(
        _ dec: inout Decbuf, _ histograms: [RefFloatHistogramSample]
    ) throws -> [RefFloatHistogramSample] {
        var histograms = histograms
        if dec.count == 0 { return histograms }

        let firstRef = dec.varint64()
        let firstT = dec.varint64()
        let firstST = dec.varint64()
        var prevRef: Int64 = 0
        var prevST: Int64 = 0
        var hasPrev = false

        while dec.count > 0 && dec.err == nil {
            var ref: Int64 = 0
            var t: Int64 = 0
            var st: Int64 = 0
            if !hasPrev {
                (ref, t, st) = (firstRef, firstT, firstST)
                hasPrev = true
            } else {
                ref = prevRef &+ dec.varint64()
                t = firstT &+ dec.varint64()
                st = readSTMarker(&dec, prevST, firstST)
            }

            prevRef = ref
            prevST = st
            var fh = FloatHistogram()
            decodeFloatHistogram(&dec, &fh)

            if !isKnownSchema(fh.schema) {
                onUnknownSchema?(fh.schema, t)
                continue
            }
            if fh.schema > HistogramSchema.exponentialMax
                && fh.schema <= HistogramSchema.exponentialMaxReserved
            {
                do {
                    try fh.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
                } catch {
                    throw RecordError.reduceResolution(
                        histograms.count + 1, String(describing: error))
                }
            }
            histograms.append(
                RefFloatHistogramSample(
                    ref: HeadSeriesRef(rawValue: UInt64(bitPattern: ref)), st: st, t: t, fh: fh))
        }

        if let e = dec.err {
            throw RecordError.decodeErrorAfter(
                histograms.count, "histograms", String(describing: e))
        }
        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }
        return histograms
    }

    // MARK: - The Decbuf seam

}

/// `Decbuf` reads through a non-owning `ByteSlice` (ADR-8), so the record's memory has to be borrowed for
/// the whole decode.
///
/// A free function rather than a method, and that is forced: the closure body calls `decodeLabels`, which
/// is `mutating`, so a `mutating` enclosing method would be two overlapping exclusive accesses to `self`.
private func withDecbuf(_ rec: [UInt8], _ body: (inout Decbuf) throws -> Void) throws {
    try rec.withUnsafeBytes { raw in
        var dec = Decbuf(ByteSlice(raw))
        try body(&dec)
    }
}

// MARK: - The shared field codecs

/// Go: `record.readSTMarker`. The `default` arm catches **every** byte other than 0 and 1, so an
/// out-of-range marker is read as `explicitST` rather than rejected.
func readSTMarker(_ buf: inout Decbuf, _ prevST: Int64, _ firstST: Int64) -> Int64 {
    let marker = buf.byte()
    switch marker {
    case stMarkerNoST: return 0
    case stMarkerSameST: return prevST
    default: return firstST &+ buf.varint64()
    }
}

/// Go: `record.DecodeHistogram`.
///
/// Two things about the `if l > 0 { make(...) }` shape are contract rather than allocation detail, and both
/// are only visible if the caller REUSES a histogram — which it may, since the function is exported:
///
///   * when `l == 0` the slice is **left as it was**, and the `for i := range h.PositiveSpans` beneath it
///     then iterates the OLD length, reading that many spans out of the buffer. A zero count does not mean
///     "no spans read";
///   * `CustomValues` is read **only** for the custom-buckets schema, so a reused histogram carrying custom
///     values keeps them when decoding an exponential one.
///
/// `l` itself is unvalidated against the remaining bytes, upstream included: a corrupt record naming a huge
/// length allocates it and then fails every read. Reproduced rather than guarded, because a guard would be
/// a divergence and the outcome is a crash either way.
public func decodeHistogram(_ buf: inout Decbuf, _ h: inout Histogram) {
    h.counterResetHint = CounterResetHint(rawValue: buf.byte()) ?? .unknownCounterReset

    h.schema = Int32(truncatingIfNeeded: buf.varint64())
    h.zeroThreshold = Double(bitPattern: buf.be64())

    h.zeroCount = buf.uvarint64()
    h.count = buf.uvarint64()
    h.sum = Double(bitPattern: buf.be64())

    readSpans(&buf, &h.positiveSpans)
    readSpans(&buf, &h.negativeSpans)

    var l = buf.uvarint()
    if l > 0 { h.positiveBuckets = [Int64](repeating: 0, count: l) }
    for i in h.positiveBuckets.indices { h.positiveBuckets[i] = buf.varint64() }

    l = buf.uvarint()
    if l > 0 { h.negativeBuckets = [Int64](repeating: 0, count: l) }
    for i in h.negativeBuckets.indices { h.negativeBuckets[i] = buf.varint64() }

    if isCustomBucketsSchema(h.schema) {
        l = buf.uvarint()
        if l > 0 { h.customValues = [Double](repeating: 0, count: l) }
        for i in (h.customValues ?? []).indices { h.customValues![i] = buf.be64Float64() }
    }
}

/// Go: `record.DecodeFloatHistogram`.
public func decodeFloatHistogram(_ buf: inout Decbuf, _ fh: inout FloatHistogram) {
    fh.counterResetHint = CounterResetHint(rawValue: buf.byte()) ?? .unknownCounterReset

    fh.schema = Int32(truncatingIfNeeded: buf.varint64())
    fh.zeroThreshold = buf.be64Float64()

    fh.zeroCount = buf.be64Float64()
    fh.count = buf.be64Float64()
    fh.sum = buf.be64Float64()

    readSpans(&buf, &fh.positiveSpans)
    readSpans(&buf, &fh.negativeSpans)

    var l = buf.uvarint()
    if l > 0 { fh.positiveBuckets = [Double](repeating: 0, count: l) }
    for i in fh.positiveBuckets.indices { fh.positiveBuckets[i] = buf.be64Float64() }

    l = buf.uvarint()
    if l > 0 { fh.negativeBuckets = [Double](repeating: 0, count: l) }
    for i in fh.negativeBuckets.indices { fh.negativeBuckets[i] = buf.be64Float64() }

    if isCustomBucketsSchema(fh.schema) {
        l = buf.uvarint()
        if l > 0 { fh.customValues = [Double](repeating: 0, count: l) }
        for i in (fh.customValues ?? []).indices { fh.customValues![i] = buf.be64Float64() }
    }
}

/// The span pair both histogram decoders read identically: a uvarint count, then `(varint offset,
/// uvarint32 length)` per span. Factored out because the four copies in Go are byte-identical, including
/// the reuse behaviour documented on ``decodeHistogram(_:_:)``.
private func readSpans(_ buf: inout Decbuf, _ spans: inout [Span]) {
    let l = buf.uvarint()
    if l > 0 { spans = [Span](repeating: Span(offset: 0, length: 0), count: l) }
    for i in spans.indices {
        spans[i].offset = Int32(truncatingIfNeeded: buf.varint64())
        spans[i].length = buf.uvarint32()
    }
}
