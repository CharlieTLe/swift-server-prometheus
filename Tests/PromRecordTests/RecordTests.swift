//===----------------------------------------------------------------------===//
// `tsdb/record` — the WAL's wire format, pinned against Go in both directions.
//
// Three suites mirroring `oracle/suites_record*.go`:
//
//   `record/types`   the type-byte table and the two MetricType conversions
//   `record/encode`  Encoder -> bytes -> Decoder, over the encoder's own output
//   `record/decode`  raw bytes -> Decoder, for the shapes an encoder will not write
//
// The renderings below have to agree with the Go ones character for character, so they are written
// against `fmt`'s verbs rather than Swift's defaults: `%q` is `GoStrconv.quote`, `%016x` is the float's
// bit pattern, and every integer is `%d`. ADR-4's rule about `Double.description` is the reason none of
// these interpolate a float directly.
//===----------------------------------------------------------------------===//

import Foundation
import GoCompat
import GoOracleSupport
import PromChunks
import PromHistogram
import PromLabels
import PromModel
import PromRecord
import PromStorage
import PromTombstones
import Testing

// MARK: - Wire types

struct WireSeries: Codable, Sendable {
    var ref: UInt64
    var labels: [[String]]?
}

struct WireSample: Codable, Sendable {
    var ref: UInt64
    var st: Int64?
    var t: Int64
    var v: String
}

struct WireMetadata: Codable, Sendable {
    var ref: UInt64
    var type: UInt8
    var unit: String
    var help: String
}

struct WireStone: Codable, Sendable {
    var ref: UInt64
    var intervals: [[Int64]]?
}

struct WireExemplar: Codable, Sendable {
    var ref: UInt64
    var t: Int64
    var v: String
    var labels: [[String]]?
}

struct WireMarker: Codable, Sendable {
    var ref: UInt64
    var mmapRef: UInt64
}

struct WireSpan: Codable, Sendable {
    var offset: Int32
    var length: UInt32
}

struct WireHistogram: Codable, Sendable {
    var hint: UInt8
    var schema: Int32
    var zeroThreshold: String
    var zeroCount: String
    var count: String
    var sum: String
    var positiveSpans: [WireSpan]?
    var negativeSpans: [WireSpan]?
    var positiveBucketsInt: [Int64]?
    var negativeBucketsInt: [Int64]?
    var positiveBuckets: [String]?
    var negativeBuckets: [String]?
    var customValues: [String]?
}

struct WireHistogramSample: Codable, Sendable {
    var ref: UInt64
    var st: Int64?
    var t: Int64
    var h: WireHistogram
}

// MARK: - Wire -> port

private func bits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

private func labelsFromWire(_ ls: [[String]]?) -> Labels {
    // A `ScratchBuilder`, not `Labels(_:)` — the latter sorts, and the encoder must range whatever it is
    // handed. `record/decode`'s `labels-unsorted` case is the one that tells the two apart.
    var b = ScratchBuilder()
    for l in ls ?? [] {
        b.add(l[0], l[1])
    }
    return b.labels()
}

private func spansFromWire(_ ss: [WireSpan]?) -> [Span] {
    (ss ?? []).map { Span(offset: $0.offset, length: $0.length) }
}

private func intHistogramFromWire(_ w: WireHistogram) -> Histogram {
    var h = Histogram()
    h.counterResetHint = CounterResetHint(rawValue: w.hint) ?? .unknownCounterReset
    h.schema = w.schema
    h.zeroThreshold = bits(w.zeroThreshold)
    h.zeroCount = UInt64(bits(w.zeroCount))
    h.count = UInt64(bits(w.count))
    h.sum = bits(w.sum)
    h.positiveSpans = spansFromWire(w.positiveSpans)
    h.negativeSpans = spansFromWire(w.negativeSpans)
    h.positiveBuckets = w.positiveBucketsInt ?? []
    h.negativeBuckets = w.negativeBucketsInt ?? []
    // Go leaves `CustomValues` nil when the corpus gives none, and `renderFbits(nil)` is `[]`, which is
    // also what an empty slice renders as — so nil and empty are indistinguishable in the fixture and
    // either is correct here.
    if let cv = w.customValues, !cv.isEmpty {
        h.customValues = cv.map(bits)
    }
    return h
}

private func floatHistogramFromWire(_ w: WireHistogram) -> FloatHistogram {
    var h = FloatHistogram()
    h.counterResetHint = CounterResetHint(rawValue: w.hint) ?? .unknownCounterReset
    h.schema = w.schema
    h.zeroThreshold = bits(w.zeroThreshold)
    h.zeroCount = bits(w.zeroCount)
    h.count = bits(w.count)
    h.sum = bits(w.sum)
    h.positiveSpans = spansFromWire(w.positiveSpans)
    h.negativeSpans = spansFromWire(w.negativeSpans)
    h.positiveBuckets = (w.positiveBuckets ?? []).map(bits)
    h.negativeBuckets = (w.negativeBuckets ?? []).map(bits)
    if let cv = w.customValues, !cv.isEmpty {
        h.customValues = cv.map(bits)
    }
    return h
}

// MARK: - Renderings, matching `fmt` exactly

private func fbits(_ d: Double) -> String {
    let hex = String(d.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}

private func q(_ s: String) -> String { GoStrconv.quote(s) }

private func renderLabels(_ l: Labels) -> String {
    var out = "{"
    var first = true
    for lbl in l {
        if !first { out += "," }
        first = false
        out += q(lbl.name)
        out += "="
        out += q(lbl.value)
    }
    out += "}"
    return out
}

private func renderSeries(_ s: RefSeries) -> String {
    "ref=\(s.ref.rawValue) labels=\(renderLabels(s.labels))"
}

private func renderSample(_ s: RefSample) -> String {
    "ref=\(s.ref.rawValue) st=\(s.st) t=\(s.t) v=\(fbits(s.v))"
}

private func renderMetadata(_ m: RefMetadata) -> String {
    var out = "ref=\(m.ref.rawValue) type=\(m.type) unit="
    out += q(m.unit)
    out += " help="
    out += q(m.help)
    return out
}

private func renderStone(_ s: Stone) -> String {
    var out = "ref=\(s.ref.rawValue) intervals=["
    for (i, iv) in s.intervals.enumerated() {
        if i > 0 { out += " " }
        out += "\(iv.mint)..\(iv.maxt)"
    }
    out += "]"
    return out
}

private func renderExemplar(_ x: RefExemplar) -> String {
    "ref=\(x.ref.rawValue) t=\(x.t) v=\(fbits(x.v)) labels=\(renderLabels(x.labels))"
}

private func renderMarker(_ m: RefMmapMarker) -> String {
    "ref=\(m.ref.rawValue) mmapRef=\(m.mmapRef.rawValue)"
}

private func renderSpans(_ ss: [Span]) -> String {
    "[" + ss.map { "\($0.offset):\($0.length)" }.joined(separator: " ") + "]"
}

private func renderInt64s(_ vs: [Int64]) -> String {
    "[" + vs.map { "\($0)" }.joined(separator: " ") + "]"
}

private func renderFbits(_ vs: [Double]) -> String {
    "[" + vs.map(fbits).joined(separator: " ") + "]"
}

private func renderIntHistogram(_ h: Histogram) -> String {
    // `hint` first and explicitly: `String()` omits it upstream, which is quirk 56.
    var out = "hint=\(h.counterResetHint.rawValue) schema=\(h.schema)"
    out += " zt=\(fbits(h.zeroThreshold)) zc=\(h.zeroCount) count=\(h.count)"
    out += " sum=\(fbits(h.sum))"
    out += " ps=\(renderSpans(h.positiveSpans)) ns=\(renderSpans(h.negativeSpans))"
    out += " pb=\(renderInt64s(h.positiveBuckets)) nb=\(renderInt64s(h.negativeBuckets))"
    out += " cv=\(renderFbits(h.customValues ?? []))"
    return out
}

private func renderFloatHistogram(_ h: FloatHistogram) -> String {
    var out = "hint=\(h.counterResetHint.rawValue) schema=\(h.schema)"
    out += " zt=\(fbits(h.zeroThreshold)) zc=\(fbits(h.zeroCount)) count=\(fbits(h.count))"
    out += " sum=\(fbits(h.sum))"
    out += " ps=\(renderSpans(h.positiveSpans)) ns=\(renderSpans(h.negativeSpans))"
    out += " pb=\(renderFbits(h.positiveBuckets)) nb=\(renderFbits(h.negativeBuckets))"
    out += " cv=\(renderFbits(h.customValues ?? []))"
    return out
}

private func renderHistogramSample(_ s: RefHistogramSample) -> String {
    "ref=\(s.ref.rawValue) st=\(s.st) t=\(s.t) h=(\(renderIntHistogram(s.h)))"
}

private func renderFloatHistogramSample(_ s: RefFloatHistogramSample) -> String {
    "ref=\(s.ref.rawValue) st=\(s.st) t=\(s.t) fh=(\(renderFloatHistogram(s.fh)))"
}

private func errString(_ body: () throws -> Void) -> String {
    do {
        try body()
        return ""
    } catch {
        return String(describing: error)
    }
}

// MARK: - record/types

struct RecordTypesIn: Codable, Sendable {
    var byte: UInt8
    var metricType: String
    var emptyRecord: Bool
}

struct RecordTypesOut: Codable, Equatable, Sendable {
    var decoderType: String
    var decoderTypeNum: UInt8
    var typeString: String
    var getMetricType: UInt8
    var toMetricType: String
}

@Suite("record: the type-byte table and the MetricType conversions")
struct RecordTypeTests {

    @Test("every byte, and every model.MetricType, matches Go")
    func matchesGo() throws {
        try Fixtures.check("record/types.jsonl", FixtureCase<RecordTypesIn, RecordTypesOut>.self) {
            input in
            let rec: [UInt8] = input.emptyRecord ? [] : [input.byte]
            let dt = recordType(rec)
            // An unrecognised string is `MetricTypeUnknown`, which is what Go's `model.MetricType`
            // conversion does implicitly by not matching any case.
            let mt = MetricType(rawValue: input.metricType) ?? .unknown
            return RecordTypesOut(
                decoderType: dt.description,
                decoderTypeNum: dt.rawValue,
                typeString: RecordType(rawValue: input.byte).description,
                getMetricType: getMetricType(mt),
                toMetricType: toMetricType(input.byte).rawValue)
        }
    }
}

// MARK: - record/encode

struct RecordEncodeIn: Codable, Sendable {
    var kind: String
    var v2: Bool
    var series: [WireSeries]?
    var samples: [WireSample]?
    var metadata: [WireMetadata]?
    var stones: [WireStone]?
    var exemplars: [WireExemplar]?
    var markers: [WireMarker]?
    var histograms: [WireHistogramSample]?
    var floatHistograms: [WireHistogramSample]?
    var seedSamples: [WireSample]?
    var seedSeries: [WireSeries]?
    var seedHistograms: [WireHistogramSample]?
}

struct RecordEncodeOut: Codable, Equatable, Sendable {
    var bytes: String
    var type: String
    var decoded: [String]
    var err: String
    var leftoverCount: Int
    var leftoverBytes: String
    var leftoverType: String
    var leftoverDecoded: [String]
    var leftoverErr: String
}

@Suite("record: Encoder bytes, and the Decoder over them")
struct RecordEncodeTests {

    @Test("every committed case matches Go, byte for byte and value for value")
    func matchesGo() throws {
        try Fixtures.check("record/encode.jsonl", FixtureCase<RecordEncodeIn, RecordEncodeOut>.self)
        { input in
            let enc = RecordEncoder(enableSTStorage: input.v2)
            var dec = RecordDecoder()
            var out = RecordEncodeOut(
                bytes: "", type: "", decoded: [], err: "", leftoverCount: 0, leftoverBytes: "",
                leftoverType: "", leftoverDecoded: [], leftoverErr: "")

            var rec: [UInt8] = []
            switch input.kind {
            case "series":
                let ss = (input.series ?? []).map {
                    RefSeries(ref: HeadSeriesRef(rawValue: $0.ref), labels: labelsFromWire($0.labels))
                }
                rec = enc.series(ss)
                let seed = (input.seedSeries ?? []).map {
                    RefSeries(ref: HeadSeriesRef(rawValue: $0.ref), labels: labelsFromWire($0.labels))
                }
                out.err = errString {
                    out.decoded = try dec.series(rec, into: seed).map(renderSeries)
                }

            case "samples":
                let ss = (input.samples ?? []).map {
                    RefSample(
                        ref: HeadSeriesRef(rawValue: $0.ref), st: $0.st ?? 0, t: $0.t,
                        v: bits($0.v))
                }
                rec = enc.samples(ss)
                let seed = (input.seedSamples ?? []).map {
                    RefSample(
                        ref: HeadSeriesRef(rawValue: $0.ref), st: $0.st ?? 0, t: $0.t,
                        v: bits($0.v))
                }
                out.err = errString {
                    out.decoded = try dec.samples(rec, into: seed).map(renderSample)
                }

            case "metadata":
                let ms = (input.metadata ?? []).map {
                    RefMetadata(
                        ref: HeadSeriesRef(rawValue: $0.ref), type: $0.type, unit: $0.unit,
                        help: $0.help)
                }
                rec = enc.metadata(ms)
                out.err = errString {
                    out.decoded = try dec.metadata(rec).map(renderMetadata)
                }

            case "tombstones":
                let ts = (input.stones ?? []).map { s in
                    Stone(
                        ref: SeriesRef(rawValue: s.ref),
                        intervals: (s.intervals ?? []).map {
                            DeletionInterval(mint: $0[0], maxt: $0[1])
                        })
                }
                rec = enc.tombstones(ts)
                out.err = errString {
                    out.decoded = try dec.tombstones(rec).map(renderStone)
                }

            case "exemplars":
                let xs = (input.exemplars ?? []).map {
                    RefExemplar(
                        ref: HeadSeriesRef(rawValue: $0.ref), t: $0.t, v: bits($0.v),
                        labels: labelsFromWire($0.labels))
                }
                rec = enc.exemplars(xs)
                out.err = errString {
                    out.decoded = try dec.exemplars(rec).map(renderExemplar)
                }

            case "mmapmarkers":
                let ms = (input.markers ?? []).map {
                    RefMmapMarker(
                        ref: HeadSeriesRef(rawValue: $0.ref),
                        mmapRef: ChunkDiskMapperRef(rawValue: $0.mmapRef))
                }
                rec = enc.mmapMarkers(ms)
                out.err = errString {
                    out.decoded = try dec.mmapMarkers(rec).map(renderMarker)
                }

            case "histograms", "custombucketshistograms":
                let hs = (input.histograms ?? []).map {
                    RefHistogramSample(
                        ref: HeadSeriesRef(rawValue: $0.ref), st: $0.st ?? 0, t: $0.t,
                        h: intHistogramFromWire($0.h))
                }
                var leftovers: [RefHistogramSample] = []
                if input.kind == "histograms" {
                    (rec, leftovers) = enc.histogramSamples(hs)
                } else {
                    rec = enc.customBucketsHistogramSamples(hs)
                }
                let seed = (input.seedHistograms ?? []).map {
                    RefHistogramSample(
                        ref: HeadSeriesRef(rawValue: $0.ref), st: $0.st ?? 0, t: $0.t,
                        h: intHistogramFromWire($0.h))
                }
                out.err = errString {
                    out.decoded = try dec.histogramSamples(rec, into: seed)
                        .map(renderHistogramSample)
                }
                out.leftoverCount = leftovers.count
                if !leftovers.isEmpty {
                    let lb = enc.customBucketsHistogramSamples(leftovers)
                    out.leftoverBytes = Hex.encode(lb)
                    out.leftoverType = recordType(lb).description
                    out.leftoverErr = errString {
                        out.leftoverDecoded = try dec.histogramSamples(lb)
                            .map(renderHistogramSample)
                    }
                }

            case "floathistograms", "custombucketsfloathistograms":
                let hs = (input.floatHistograms ?? []).map {
                    RefFloatHistogramSample(
                        ref: HeadSeriesRef(rawValue: $0.ref), st: $0.st ?? 0, t: $0.t,
                        fh: floatHistogramFromWire($0.h))
                }
                var leftovers: [RefFloatHistogramSample] = []
                if input.kind == "floathistograms" {
                    (rec, leftovers) = enc.floatHistogramSamples(hs)
                } else {
                    rec = enc.customBucketsFloatHistogramSamples(hs)
                }
                out.err = errString {
                    out.decoded = try dec.floatHistogramSamples(rec)
                        .map(renderFloatHistogramSample)
                }
                out.leftoverCount = leftovers.count
                if !leftovers.isEmpty {
                    let lb = enc.customBucketsFloatHistogramSamples(leftovers)
                    out.leftoverBytes = Hex.encode(lb)
                    out.leftoverType = recordType(lb).description
                    out.leftoverErr = errString {
                        out.leftoverDecoded = try dec.floatHistogramSamples(lb)
                            .map(renderFloatHistogramSample)
                    }
                }

            default:
                Issue.record("unknown record kind \(input.kind)")
            }

            out.bytes = Hex.encode(rec)
            out.type = recordType(rec).description
            return out
        }
    }
}

// MARK: - record/decode

struct RecordDecodeIn: Codable, Sendable {
    var bytes: String
    var call: String
    var note: String
}

struct RecordDecodeOut: Codable, Equatable, Sendable {
    var type: String
    var decoded: [String]
    var err: String
    var warnings: [String]
}

@Suite("record: the Decoder over bytes an Encoder will not write")
struct RecordDecodeTests {

    @Test("every malformed, unsorted and out-of-schema case matches Go")
    func matchesGo() throws {
        try Fixtures.check("record/decode.jsonl", FixtureCase<RecordDecodeIn, RecordDecodeOut>.self)
        { input in
            let rec = Hex.decode(input.bytes)
            // The warnings are collected through the port's stand-in for upstream's `*slog.Logger`,
            // and their text is reassembled here to match `capturingLogger`'s format. That the skip
            // HAPPENED is the point: without it, a decoder that dropped the sample for the wrong
            // reason would produce the same shortened list.
            let box = WarningBox()
            var dec = RecordDecoder(onUnknownSchema: { schema, t in
                box.add(
                    "skipping histogram with unknown schema in WAL record schema=\(schema) "
                        + "timestamp=\(t)")
            })
            var out = RecordDecodeOut(
                type: recordType(rec).description, decoded: [], err: "", warnings: [])

            switch input.call {
            case "series":
                out.err = errString { out.decoded = try dec.series(rec).map(renderSeries) }
            case "metadata":
                out.err = errString { out.decoded = try dec.metadata(rec).map(renderMetadata) }
            case "samples":
                out.err = errString { out.decoded = try dec.samples(rec).map(renderSample) }
            case "tombstones":
                out.err = errString { out.decoded = try dec.tombstones(rec).map(renderStone) }
            case "exemplars":
                out.err = errString { out.decoded = try dec.exemplars(rec).map(renderExemplar) }
            case "mmapmarkers":
                out.err = errString { out.decoded = try dec.mmapMarkers(rec).map(renderMarker) }
            case "histograms":
                out.err = errString {
                    out.decoded = try dec.histogramSamples(rec).map(renderHistogramSample)
                }
            case "floathistograms":
                out.err = errString {
                    out.decoded = try dec.floatHistogramSamples(rec)
                        .map(renderFloatHistogramSample)
                }
            default:
                Issue.record("unknown call \(input.call)")
            }
            out.warnings = box.all
            return out
        }
    }
}

/// A box for the decoder's warnings, because `onUnknownSchema` is `@Sendable` and cannot capture a local
/// `var`. `@unchecked Sendable` is sound here: the decode is single-threaded and the box outlives it.
private final class WarningBox: @unchecked Sendable {
    private(set) var all: [String] = []
    func add(_ s: String) { all.append(s) }
}
