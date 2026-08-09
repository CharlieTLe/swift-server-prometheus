//===----------------------------------------------------------------------===//
// Wire types and the replay harness for the storage iterator fixtures.
//
// Mirrors oracle/suites_storage_iterators.go and oracle/corpus_storage_iterators.go.
// Duplicated rather than shared, as Tests/PromHistogramTests/HistogramWire.swift
// and Tests/PromQLParserTests/ParserWire.swift already are — a shared target would
// have to live outside Tests/ and pull PromHistogram into every test target.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromHistogram
import Testing

@testable import PromStorage

// MARK: - Wire

struct SampleJSON: Decodable, Sendable {
    /// "f", "h" or "fh".
    let kind: String
    let st: String
    let t: String
    /// Hex bit pattern.
    let f: String
    /// Index into ``histogramCatalogue``. Ignored for kind "f".
    let hist: Int
}

struct IterOp: Decodable, Sendable {
    let op: String
    /// Int64 as a decimal string, "" when the op takes no argument.
    let arg: String
}

struct IterIn: Decodable, Sendable {
    let samples: [SampleJSON]?
    let delta: String
    let withCopy: Bool
    let ops: [IterOp]
}

struct IterStep: Decodable, Equatable, Sendable {
    var op: String
    /// `ValueType` raw value, or -1 where the op does not return one.
    var ret: Int
    var t: String
    var st: String
    var f: String
    /// The histogram's `description`, which Phase 3 already proved byte-identical.
    var hist: String?
    var ok: Bool?
    var bool: Bool?
    var buf: [IterStep]?
    var err: String

    init(
        op: String, ret: Int = -1, t: String = "", st: String = "", f: String = "",
        hist: String? = nil, ok: Bool? = nil, bool: Bool? = nil, buf: [IterStep]? = nil,
        err: String = ""
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

struct IterOut: Decodable, Equatable, Sendable {
    let steps: [IterStep]
}

func i64String(_ v: Int64) -> String { String(v) }

func parseI64(_ s: String) -> Int64 {
    if s.isEmpty { return 0 }
    guard let v = Int64(s) else {
        preconditionFailure("not an Int64: \(s)")
    }
    return v
}

func hexBits(_ v: Double) -> String { String(format: "%016lx", v.bitPattern) }

func doubleFromHex(_ s: String) -> Double {
    guard let bits = UInt64(s, radix: 16) else { return 0 }
    return Double(bitPattern: bits)
}

// MARK: - The histogram catalogue

/// Duplicated verbatim from `integerHistogram`/`floatHistogram` in
/// oracle/suites_storage_iterators.go. Index 0 is "no histogram".
///
/// The duplication cannot drift silently: every output step carries the
/// histogram's `description`, so a catalogue that disagrees with the oracle's fails
/// on the first case that touches it rather than passing on wrong data.
func integerHistogramCatalogue(_ idx: Int) -> Histogram? {
    switch idx {
    case 1:
        return Histogram(
            schema: 0, zeroThreshold: 0.001, zeroCount: 2, count: 12, sum: 18.4,
            positiveSpans: [Span(offset: 0, length: 2)],
            negativeSpans: [Span(offset: 1, length: 2)],
            positiveBuckets: [3, 1],
            negativeBuckets: [2, -1])
    case 2:
        return Histogram(
            counterResetHint: .gaugeType, schema: 2, count: 5, sum: -3.5,
            positiveSpans: [Span(offset: -1, length: 3)],
            positiveBuckets: [1, 1, -1])
    case 6:
        return Histogram(
            schema: HistogramSchema.customBuckets, count: 7, sum: 9,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [2, 1, -1],
            customValues: [1, 5, 10])
    default:
        return nil
    }
}

func floatHistogramCatalogue(_ idx: Int) -> FloatHistogram? {
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

// MARK: - The corpus's own sample type

/// Mirrors `oracleSample`. Deliberately looser than ``FSample``/``HSample``: `f`
/// does not trap for a histogram sample, so a case can ask for `at()` on one and
/// observe the zero it yields.
struct CorpusSample: Sample {
    var st: Int64
    var t: Int64
    var fValue: Double
    var hValue: Histogram?
    var fhValue: FloatHistogram?

    var f: Double { fValue }
    var h: Histogram? { hValue }

    /// Converts, as `storage.hSample.FH()` does.
    var fh: FloatHistogram? {
        if let fhValue { return fhValue }
        if let hValue { return hValue.toFloat() }
        return nil
    }

    var type: ValueType {
        if hValue != nil { return .histogram }
        if fhValue != nil { return .floatHistogram }
        return .float
    }

    func copy() -> any Sample {
        CorpusSample(
            st: st, t: t, fValue: fValue, hValue: hValue?.copy(), fhValue: fhValue?.copy())
    }
}

func buildSamples(_ in_: [SampleJSON]?) -> SampleSlice {
    var out = [any Sample]()
    for s in in_ ?? [] {
        var sample = CorpusSample(
            st: parseI64(s.st), t: parseI64(s.t), fValue: 0, hValue: nil, fhValue: nil)
        switch s.kind {
        case "f":
            sample.fValue = doubleFromHex(s.f)
        case "h":
            guard let h = integerHistogramCatalogue(s.hist) else {
                preconditionFailure("catalogue index \(s.hist) is not an integer histogram")
            }
            sample.hValue = h
        case "fh":
            guard let fh = floatHistogramCatalogue(s.hist) else {
                preconditionFailure("catalogue index \(s.hist) is not a float histogram")
            }
            sample.fhValue = fh
        default:
            preconditionFailure("unknown sample kind \(s.kind)")
        }
        out.append(sample)
    }
    return SampleSlice(out)
}

func histString(_ h: Histogram?, _ fh: FloatHistogram?) -> String? {
    if let h { return h.description }
    if let fh { return fh.description }
    return nil
}

// MARK: - Replay: storage/buffer

func runBufferOps(_ input: IterIn) -> IterOut {
    let src = newListSeriesIterator(buildSamples(input.samples))
    let it = newBufferIterator(src, delta: parseI64(input.delta))

    var steps = [IterStep]()
    for op in input.ops {
        var step = IterStep(op: op.op)
        switch op.op {
        case "next":
            step.ret = Int(it.next().rawValue)
        case "seek":
            step.ret = Int(it.seek(parseI64(op.arg)).rawValue)
        case "at":
            let (t, f) = it.at()
            step.t = i64String(t)
            step.f = hexBits(f)
        case "atT":
            step.t = i64String(it.atT())
        case "atST":
            step.st = i64String(it.atST())
        case "atFloatHistogram":
            let (t, fh) = it.atFloatHistogram(nil)
            step.t = i64String(t)
            step.hist = histString(nil, fh)
        case "peekBack":
            let s = it.peekBack(Int(parseI64(op.arg)))
            step.ok = s != nil
            if let s {
                step.t = i64String(s.t)
                step.st = i64String(s.st)
                switch s.type {
                case .float: step.f = hexBits(s.f)
                case .histogram: step.hist = histString(s.h, nil)
                case .floatHistogram: step.hist = histString(nil, s.fh)
                default: break
                }
                step.ret = Int(s.type.rawValue)
            }
        case "reduceDelta":
            step.bool = it.reduceDelta(parseI64(op.arg))
        case "bufferDrain":
            step.buf = drainBuffer(it)
        case "err":
            if let e = it.err() { step.err = "\(e)" }
        default:
            preconditionFailure("unknown buffer op \(op.op)")
        }
        steps.append(step)
    }
    return IterOut(steps: steps)
}

/// The whole look-back window, oldest first. The ORDER is the assertion that
/// matters: it is the only view the fixture has of the ring's index arithmetic.
func drainBuffer(_ it: BufferedSeriesIterator) -> [IterStep] {
    let buf = it.buffer()
    var steps = [IterStep]()
    while true {
        let vt = buf.next()
        if vt == .none {
            return steps
        }
        var step = IterStep(
            op: "bufNext", ret: Int(vt.rawValue), t: i64String(buf.atT()),
            st: i64String(buf.atST()))
        switch vt {
        case .float:
            let (_, f) = buf.at()
            step.f = hexBits(f)
        case .histogram:
            let (_, h) = buf.atHistogram()
            step.hist = histString(h, nil)
        case .floatHistogram:
            let (_, fh) = buf.atFloatHistogram(nil)
            step.hist = histString(nil, fh)
        default:
            break
        }
        steps.append(step)
    }
}

// MARK: - Replay: storage/memoized

func runMemoizedOps(_ input: IterIn) -> IterOut {
    let src = newListSeriesIterator(buildSamples(input.samples))
    let it = newMemoizedIterator(src, delta: parseI64(input.delta))

    var steps = [IterStep]()
    for op in input.ops {
        var step = IterStep(op: op.op)
        switch op.op {
        case "next":
            step.ret = Int(it.next().rawValue)
        case "seek":
            step.ret = Int(it.seek(parseI64(op.arg)).rawValue)
        case "at":
            let (t, f) = it.at()
            step.t = i64String(t)
            step.f = hexBits(f)
        case "atT":
            step.t = i64String(it.atT())
        case "atFloatHistogram":
            let (t, fh) = it.atFloatHistogram()
            step.t = i64String(t)
            step.hist = histString(nil, fh)
        case "peekPrev":
            let prev = it.peekPrev()
            step.ok = prev != nil
            // Go returns a zero-valued tuple with ok=false, so the fields are
            // written unconditionally to match.
            step.t = i64String(prev?.t ?? 0)
            step.f = hexBits(prev?.value ?? 0)
            step.hist = histString(nil, prev?.fh)
        case "err":
            if let e = it.err() { step.err = "\(e)" }
        default:
            preconditionFailure("unknown memoized op \(op.op)")
        }
        steps.append(step)
    }
    return IterOut(steps: steps)
}

// MARK: - Replay: storage/listseries

func runListSeriesOps(_ input: IterIn) -> IterOut {
    let samples = buildSamples(input.samples)
    let it: any ChunkIterator =
        input.withCopy
        ? newListSeriesIteratorWithCopy(samples) : newListSeriesIterator(samples)

    var steps = [IterStep]()
    for op in input.ops {
        var step = IterStep(op: op.op)
        switch op.op {
        case "next":
            step.ret = Int(it.next().rawValue)
        case "seek":
            step.ret = Int(it.seek(parseI64(op.arg)).rawValue)
        case "at":
            let (t, f) = it.at()
            step.t = i64String(t)
            step.f = hexBits(f)
        case "atT":
            step.t = i64String(it.atT())
        case "atST":
            step.st = i64String(it.atST())
        case "atHistogram":
            let (t, h) = it.atHistogram(nil)
            step.t = i64String(t)
            step.hist = histString(h, nil)
        case "atFloatHistogram":
            let (t, fh) = it.atFloatHistogram(nil)
            step.t = i64String(t)
            step.hist = histString(nil, fh)
        case "err":
            if let e = it.err() { step.err = "\(e)" }
        default:
            preconditionFailure("unknown listseries op \(op.op)")
        }
        steps.append(step)
    }
    return IterOut(steps: steps)
}
