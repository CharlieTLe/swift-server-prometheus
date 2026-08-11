//===----------------------------------------------------------------------===//
// Ported from tsdb/record/record.go @ v3.13.2 — the types.
//
// **Phase 7's first slice.** The WAL is a sequence of records and this is their wire format: byte-exact,
// exported, and stateless, which makes it the one piece of the write path that can be pinned before any of
// `head.go`, `db.go` or `wlog` exists. A WAL the port writes has to be readable by Prometheus and vice
// versa, so these bytes are a compatibility surface in the strongest sense — ADR-5's neighbour.
//
// ## `Unknown` is 255, not 0
//
// The type byte 0 is not a record type at all; an unrecognised byte decodes to `Unknown = 255`. So a port
// that modelled the type as a Swift enum with a zero default would map an empty record to a
// `Series`-adjacent nonsense value instead of `Unknown`. Modelled as a `RawRepresentable` struct for the
// same reason `Encoding` is.
//
// ## `Type.String()` is reachable from an error message, and only for SOME records
//
// `Decoder.HistogramSamples` reports a wrong type as `fmt.Errorf("invalid record type %v", typ)` where
// `typ` is a `Type` — so `%v` calls `String()` and the message says `invalid record type samples`.
// `Decoder.Samples` binds the *byte* instead (`switch typ := dec.Byte(); Type(typ)`), so its message says
// `invalid record type 7, expected Samples(2) or SamplesV2(11)` — a number. Two records, two spellings of
// the same mistake; see ``RecordError``.
//
// ## `MetricType` is the record's own uint8 table, distinct from `model.MetricType`
//
// `model.MetricType` is a *string* type (`"counter"`, `"gauge"`, …) and the WAL cannot afford strings, so
// `record` keeps a parallel `uint8` enum and two conversion functions. `GetMetricType` maps an unknown
// string to `UnknownMT = 0` and `ToMetricType` maps an unknown byte to `MetricTypeUnknown`, so the pair
// is total in both directions but not injective — every unrecognised input collapses onto "unknown".
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromHistogram
public import PromLabels
public import PromModel

internal import PromEncoding

/// Go: `record.Type`.
///
/// A struct rather than an enum because `Unknown` is **255** — see the file header. A Swift enum's zero
/// case would be the wrong default for an unrecognised byte.
public struct RecordType: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unknown = RecordType(rawValue: 255)
    public static let series = RecordType(rawValue: 1)
    public static let samples = RecordType(rawValue: 2)
    public static let tombstones = RecordType(rawValue: 3)
    public static let exemplars = RecordType(rawValue: 4)
    public static let mmapMarkers = RecordType(rawValue: 5)
    public static let metadata = RecordType(rawValue: 6)
    public static let histogramSamples = RecordType(rawValue: 7)
    public static let floatHistogramSamples = RecordType(rawValue: 8)
    public static let customBucketsHistogramSamples = RecordType(rawValue: 9)
    public static let customBucketsFloatHistogramSamples = RecordType(rawValue: 10)
    public static let samplesV2 = RecordType(rawValue: 11)
    public static let histogramSamplesV2 = RecordType(rawValue: 12)
    public static let floatHistogramSamplesV2 = RecordType(rawValue: 13)

    /// Go: `Type.String()`.
    public var description: String {
        switch self {
        case .series: return "series"
        case .samples: return "samples"
        case .samplesV2: return "samples_v2"
        case .tombstones: return "tombstones"
        case .exemplars: return "exemplars"
        case .histogramSamples: return "histogram_samples"
        case .floatHistogramSamples: return "float_histogram_samples"
        case .customBucketsHistogramSamples: return "custom_buckets_histogram_samples"
        case .customBucketsFloatHistogramSamples: return "custom_buckets_float_histogram_samples"
        case .histogramSamplesV2: return "histogram_samples_v2"
        case .floatHistogramSamplesV2: return "float_histogram_samples_v2"
        case .mmapMarkers: return "mmapmarkers"
        case .metadata: return "metadata"
        default: return "unknown"
        }
    }
}

/// Go: `record.MetricType` — the compact form of ``PromModel/MetricType`` the Metadata record carries.
public struct RecordMetricType: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unknownMT = RecordMetricType(rawValue: 0)
    public static let counter = RecordMetricType(rawValue: 1)
    public static let gauge = RecordMetricType(rawValue: 2)
    /// Go: `HistogramSample`, named to avoid colliding with the record type of the same word.
    public static let histogramSample = RecordMetricType(rawValue: 3)
    public static let gaugeHistogram = RecordMetricType(rawValue: 4)
    public static let summary = RecordMetricType(rawValue: 5)
    public static let info = RecordMetricType(rawValue: 6)
    public static let stateset = RecordMetricType(rawValue: 7)
}

/// Go: `record.GetMetricType`. Anything unrecognised — including `MetricTypeUnknown` itself — is 0.
public func getMetricType(_ t: MetricType) -> UInt8 {
    switch t {
    case .counter: return RecordMetricType.counter.rawValue
    case .gauge: return RecordMetricType.gauge.rawValue
    case .histogram: return RecordMetricType.histogramSample.rawValue
    case .gaugeHistogram: return RecordMetricType.gaugeHistogram.rawValue
    case .summary: return RecordMetricType.summary.rawValue
    case .info: return RecordMetricType.info.rawValue
    case .stateset: return RecordMetricType.stateset.rawValue
    case .unknown: return RecordMetricType.unknownMT.rawValue
    }
}

/// Go: `record.ToMetricType`.
public func toMetricType(_ m: UInt8) -> MetricType {
    switch RecordMetricType(rawValue: m) {
    case .counter: return .counter
    case .gauge: return .gauge
    case .histogramSample: return .histogram
    case .gaugeHistogram: return .gaugeHistogram
    case .summary: return .summary
    case .info: return .info
    case .stateset: return .stateset
    default: return .unknown
    }
}

/// Go: `record.unitMetaName` / `helpMetaName`.
let unitMetaName = "UNIT"
let helpMetaName = "HELP"

// MARK: - The record payload types

/// Go: `record.RefSeries`.
public struct RefSeries: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var labels: Labels

    public init(ref: HeadSeriesRef, labels: Labels) {
        self.ref = ref
        self.labels = labels
    }
}

/// Go: `record.RefSample`.
///
/// `st` is only carried by the V2 records; a V1 record has no field for it and decoding one leaves it 0.
public struct RefSample: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var st: Int64
    public var t: Int64
    public var v: Double

    public init(ref: HeadSeriesRef, st: Int64 = 0, t: Int64, v: Double) {
        self.ref = ref
        self.st = st
        self.t = t
        self.v = v
    }

    /// Bit-pattern equality on the value, because the format stores raw float bits and a NaN must compare
    /// equal to the NaN that decoded from the same bytes.
    public static func == (a: RefSample, b: RefSample) -> Bool {
        a.ref == b.ref && a.st == b.st && a.t == b.t && a.v.bitPattern == b.v.bitPattern
    }
}

/// Go: `record.RefMetadata`.
public struct RefMetadata: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var type: UInt8
    public var unit: String
    public var help: String

    public init(ref: HeadSeriesRef, type: UInt8, unit: String, help: String) {
        self.ref = ref
        self.type = type
        self.unit = unit
        self.help = help
    }
}

/// Go: `record.RefExemplar`.
public struct RefExemplar: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var t: Int64
    public var v: Double
    public var labels: Labels

    public init(ref: HeadSeriesRef, t: Int64, v: Double, labels: Labels) {
        self.ref = ref
        self.t = t
        self.v = v
        self.labels = labels
    }

    public static func == (a: RefExemplar, b: RefExemplar) -> Bool {
        a.ref == b.ref && a.t == b.t && a.v.bitPattern == b.v.bitPattern && a.labels == b.labels
    }
}

/// Go: `record.RefHistogramSample`.
///
/// Go's field is a `*histogram.Histogram` and can be nil; a caller that hands the encoder a nil histogram
/// panics in `EncodeHistogram`, so the port takes a value and there is nothing to guard.
public struct RefHistogramSample: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var st: Int64
    public var t: Int64
    public var h: Histogram

    public init(ref: HeadSeriesRef, st: Int64 = 0, t: Int64, h: Histogram) {
        self.ref = ref
        self.st = st
        self.t = t
        self.h = h
    }

    public static func == (a: RefHistogramSample, b: RefHistogramSample) -> Bool {
        a.ref == b.ref && a.st == b.st && a.t == b.t && a.h.equals(b.h)
    }
}

/// Go: `record.RefFloatHistogramSample`.
public struct RefFloatHistogramSample: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var st: Int64
    public var t: Int64
    public var fh: FloatHistogram

    public init(ref: HeadSeriesRef, st: Int64 = 0, t: Int64, fh: FloatHistogram) {
        self.ref = ref
        self.st = st
        self.t = t
        self.fh = fh
    }

    public static func == (a: RefFloatHistogramSample, b: RefFloatHistogramSample) -> Bool {
        a.ref == b.ref && a.st == b.st && a.t == b.t && a.fh.equals(b.fh)
    }
}

/// Go: `record.RefMmapMarker`.
public struct RefMmapMarker: Sendable, Equatable {
    public var ref: HeadSeriesRef
    public var mmapRef: ChunkDiskMapperRef

    public init(ref: HeadSeriesRef, mmapRef: ChunkDiskMapperRef) {
        self.ref = ref
        self.mmapRef = mmapRef
    }
}

// MARK: - Errors

/// Go: the errors `record`'s decoders return, whose text `head_wal.go` surfaces into
/// `Head.Init`'s "read WAL" failure. Reproduced byte for byte.
public enum RecordError: Error, CustomStringConvertible, Equatable {
    /// Go: `errors.New("invalid record type")` — Series, Metadata, Tombstones, Exemplars, MmapMarkers.
    case invalidRecordType
    /// Go: `fmt.Errorf("invalid record type %v, expected Samples(2) or SamplesV2(11)", typ)`, where `typ`
    /// is the raw **byte**, so `%v` prints a number.
    case invalidSamplesRecordType(UInt8)
    /// Go: `fmt.Errorf("invalid record type %v", typ)`, where `typ` is a `Type`, so `%v` calls
    /// `String()` and prints a *name*. The histogram decoders only.
    case invalidHistogramRecordType(RecordType)
    /// Go: `fmt.Errorf("unexpected %d bytes left in entry", len(dec.B))`.
    case unexpectedBytesLeft(Int)
    /// Go: `fmt.Errorf("decode error after %d %s: %w", n, noun, dec.Err())`. The noun differs per record
    /// — `samples`, `exemplars`, `histograms`, `mmap markers` — and Series/Metadata/Tombstones return the
    /// bare `Decbuf` error with no wrapper at all, which is ``decbuf``.
    case decodeErrorAfter(Int, String, String)
    /// Go: the bare `dec.Err()`, returned unwrapped by Series, Metadata and Tombstones.
    case decbuf(String)
    /// Go: `fmt.Errorf("error reducing resolution of histogram #%d: %w", len(histograms)+1, err)`.
    case reduceResolution(Int, String)

    public var description: String {
        switch self {
        case .invalidRecordType:
            return "invalid record type"
        case .invalidSamplesRecordType(let b):
            return "invalid record type \(b), expected Samples(2) or SamplesV2(11)"
        case .invalidHistogramRecordType(let t):
            return "invalid record type \(t)"
        case .unexpectedBytesLeft(let n):
            return "unexpected \(n) bytes left in entry"
        case .decodeErrorAfter(let n, let noun, let inner):
            return "decode error after \(n) \(noun): \(inner)"
        case .decbuf(let s):
            return s
        case .reduceResolution(let n, let inner):
            return "error reducing resolution of histogram #\(n): \(inner)"
        }
    }
}

/// Go: `record.Decoder.Type` — the leading byte, or `Unknown` for an empty or unrecognised record.
public func recordType(_ rec: [UInt8]) -> RecordType {
    guard let first = rec.first else { return .unknown }
    let t = RecordType(rawValue: first)
    switch t {
    case .series, .samples, .samplesV2, .tombstones, .exemplars, .mmapMarkers, .metadata,
        .histogramSamples, .floatHistogramSamples, .customBucketsHistogramSamples,
        .customBucketsFloatHistogramSamples, .histogramSamplesV2, .floatHistogramSamplesV2:
        return t
    default:
        return .unknown
    }
}
