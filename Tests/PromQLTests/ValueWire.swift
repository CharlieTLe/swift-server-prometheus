//===----------------------------------------------------------------------===//
// Wire types and replay harness for the promql/value fixtures.
//
// Mirrors oracle/suites_promql_value.go and oracle/corpus_promql_value.go. The
// float-histogram catalogue and the iterator step shape are duplicated from
// Tests/PromStorageTests, as HistogramWire.swift and ParserWire.swift already are
// — a shared version would have to live outside Tests/.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromHistogram
import PromLabels
import PromQLParser
import Testing

@testable import PromQL

// MARK: - Wire

struct PointJSON: Decodable, Sendable {
    let t: String
    let f: String
}

struct HPointJSON: Decodable, Sendable {
    let t: String
    /// Index into ``floatHistogramCatalogue``.
    let hist: Int
}

struct SampleJSONValue: Decodable, Sendable {
    let metric: [String]?
    let t: String
    let f: String
    let hist: Int
    let dropName: Bool
}

struct SeriesJSON: Decodable, Sendable {
    let metric: [String]?
    let floats: [PointJSON]?
    let histograms: [HPointJSON]?
    let dropName: Bool
}

struct StringValueJSON: Decodable, Sendable {
    let t: String
    let v: String
}

struct ValueIn: Decodable, Sendable {
    let kind: String
    let str: StringValueJSON?
    let scalar: PointJSON?
    let point: PointJSON?
    let hpoint: HPointJSON?
    let sample: SampleJSONValue?
    let series: SeriesJSON?
    let vector: [SampleJSONValue]?
    let matrix: [SeriesJSON]?
}

struct ValueOut: Decodable, Equatable, Sendable {
    var string: String
    var type: String
    var totalSamples: Int?
    var sameLabelset: Bool?
    var size: Int?

    init(
        string: String, type: String = "", totalSamples: Int? = nil,
        sameLabelset: Bool? = nil, size: Int? = nil
    ) {
        self.string = string
        self.type = type
        self.totalSamples = totalSamples
        self.sameLabelset = sameLabelset
        self.size = size
    }
}

struct SortIn: Decodable, Sendable {
    let matrix: [SeriesJSON]
}

struct SortOut: Decodable, Equatable, Sendable {
    let order: [String]
}

struct StorageSeriesIn: Decodable, Sendable {
    let series: SeriesJSON
    let ops: [ValueIterOp]
}

struct ValueIterOp: Decodable, Sendable {
    let op: String
    let arg: String
}

/// The same step shape as `Tests/PromStorageTests/IteratorWire.swift`; duplicated
/// because the two test targets cannot share it.
struct ValueIterStep: Decodable, Equatable, Sendable {
    var op: String
    var ret: Int
    var t: String
    var st: String
    var f: String
    var hist: String?
    var ok: Bool?
    var bool: Bool?
    var buf: [ValueIterStep]?
    var err: String

    init(
        op: String, ret: Int = -1, t: String = "", st: String = "", f: String = "",
        hist: String? = nil, ok: Bool? = nil, bool: Bool? = nil,
        buf: [ValueIterStep]? = nil, err: String = ""
    ) {
        self.op = op
        self.ret = ret
        self.t = t
        self.st = st
        self.f = f
        self.hist = hist
        self.ok = ok
        self.bool = bool
        self.buf = buf
        self.err = err
    }
}

struct ValueIterOut: Decodable, Equatable, Sendable {
    let steps: [ValueIterStep]
}

// MARK: - Helpers

func valueI64(_ s: String) -> Int64 {
    if s.isEmpty { return 0 }
    guard let v = Int64(s) else { preconditionFailure("not an Int64: \(s)") }
    return v
}

func valueHexBits(_ v: Double) -> String { String(format: "%016lx", v.bitPattern) }

func valueDoubleFromHex(_ s: String) -> Double {
    guard let bits = UInt64(s, radix: 16) else { return 0 }
    return Double(bitPattern: bits)
}

/// Duplicated verbatim from `floatHistogram` in oracle/suites_storage_iterators.go
/// and Tests/PromStorageTests/IteratorWire.swift. Cannot drift silently: every
/// output carries the histogram's rendering.
func valueFloatHistogramCatalogue(_ idx: Int) -> FloatHistogram? {
    switch idx {
    case 3:
        return FloatHistogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 1.5, count: 11.5, sum: 22.25,
            positiveSpans: [Span(offset: 0, length: 2)],
            negativeSpans: [Span(offset: 2, length: 1)],
            positiveBuckets: [4, 6],
            negativeBuckets: [2])
    case 4:
        return FloatHistogram(
            schema: 1, count: 3, sum: Double.nan,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 2])
    case 5:
        return FloatHistogram(
            schema: HistogramSchema.customBuckets, count: 6, sum: 14,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [2, 4],
            customValues: [2, 4])
    default:
        return nil
    }
}

func valueLabels(_ ss: [String]?) -> Labels {
    guard let ss, !ss.isEmpty else { return .empty }
    return Labels(strings: ss)
}

func buildFPoints(_ in_: [PointJSON]?) -> [FPoint] {
    (in_ ?? []).map { FPoint(t: valueI64($0.t), f: valueDoubleFromHex($0.f)) }
}

func buildHPoints(_ in_: [HPointJSON]?) -> [HPoint] {
    (in_ ?? []).map { p in
        guard let fh = valueFloatHistogramCatalogue(p.hist) else {
            preconditionFailure("catalogue index \(p.hist) is not a float histogram")
        }
        return HPoint(t: valueI64(p.t), h: fh)
    }
}

func buildSeries(_ in_: SeriesJSON) -> Series {
    Series(
        metric: valueLabels(in_.metric),
        floats: buildFPoints(in_.floats),
        histograms: buildHPoints(in_.histograms),
        dropName: in_.dropName)
}

func buildSample(_ in_: SampleJSONValue) -> Sample {
    var h: FloatHistogram?
    if in_.hist != 0 {
        guard let fh = valueFloatHistogramCatalogue(in_.hist) else {
            preconditionFailure("catalogue index \(in_.hist) is not a float histogram")
        }
        h = fh
    }
    return Sample(
        t: valueI64(in_.t), f: valueDoubleFromHex(in_.f), h: h,
        metric: valueLabels(in_.metric), dropName: in_.dropName)
}

// MARK: - Replay: promql/value

func runValueCase(_ input: ValueIn) -> ValueOut {
    switch input.kind {
    case "string":
        let v = StringValue(t: valueI64(input.str!.t), v: input.str!.v)
        return ValueOut(string: v.description, type: v.type.rawValue)
    case "scalar":
        let v = Scalar(t: valueI64(input.scalar!.t), v: valueDoubleFromHex(input.scalar!.f))
        return ValueOut(string: v.description, type: v.type.rawValue)
    case "fpoint":
        let p = FPoint(t: valueI64(input.point!.t), f: valueDoubleFromHex(input.point!.f))
        return ValueOut(string: p.description)
    case "hpoint":
        let p = buildHPoints([input.hpoint!])[0]
        // The oracle observes the unexported size() through a one-element
        // Matrix's TotalSamples, which routes through totalHPointSize. Same route
        // here, so the two agree on the formula rather than on a reimplementation.
        let m = Matrix([Series(histograms: [p])])
        return ValueOut(string: p.description, size: m.totalSamples)
    case "sample":
        return ValueOut(string: buildSample(input.sample!).description)
    case "series":
        return ValueOut(string: buildSeries(input.series!).description)
    case "vector":
        let vec = Vector((input.vector ?? []).map(buildSample))
        return ValueOut(
            string: vec.description, type: vec.type.rawValue,
            totalSamples: vec.totalSamples, sameLabelset: vec.containsSameLabelset)
    case "matrix":
        let m = Matrix((input.matrix ?? []).map(buildSeries))
        return ValueOut(
            string: m.description, type: m.type.rawValue,
            totalSamples: m.totalSamples, sameLabelset: m.containsSameLabelset)
    default:
        preconditionFailure("unknown value kind \(input.kind)")
    }
}

// MARK: - Replay: promql/value-sort

func runSortCase(_ input: SortIn) -> SortOut {
    var m = Matrix(input.matrix.map(buildSeries))
    m.sort()
    return SortOut(order: m.series.map { $0.metric.description })
}

// MARK: - Replay: promql/storageseries

func runStorageSeriesOps(_ input: StorageSeriesIn) -> ValueIterOut {
    let ss = StorageSeries(buildSeries(input.series))
    let it = ss.iterator(nil)

    var steps = [ValueIterStep]()
    for op in input.ops {
        var step = ValueIterStep(op: op.op)
        switch op.op {
        case "next":
            step.ret = Int(it.next().rawValue)
        case "seek":
            step.ret = Int(it.seek(valueI64(op.arg)).rawValue)
        case "at":
            let (t, f) = it.at()
            step.t = String(t)
            step.f = valueHexBits(f)
        case "atT":
            step.t = String(it.atT())
        case "atST":
            step.st = String(it.atST())
        case "atFloatHistogram":
            let (t, fh) = it.atFloatHistogram(nil)
            step.t = String(t)
            step.hist = fh?.description
        case "err":
            if let e = it.err() { step.err = "\(e)" }
        default:
            preconditionFailure("unknown storageseries op \(op.op)")
        }
        steps.append(step)
    }
    return ValueIterOut(steps: steps)
}
