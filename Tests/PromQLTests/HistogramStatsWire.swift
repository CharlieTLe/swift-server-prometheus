//===----------------------------------------------------------------------===//
// Wire types and the replay harness for the promql/histogram-stats fixtures.
//
// Mirrors oracle/suites_promql_histstats.go. Duplicated rather than shared, as
// Tests/PromStorageTests/IteratorWire.swift and
// Tests/PromQLParserTests/ParserWire.swift already are — a shared target would have
// to live outside Tests/ and pull PromHistogram into every test target.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromHistogram
import PromModel
import PromStorage
import Testing

@testable import PromQL

// MARK: - Wire

struct StatsSample: Decodable, Sendable {
    /// "h", "fh" or "f".
    let kind: String
    let t: String
    /// "std", "custom" or "stale". Ignored for kind "f".
    let gen: String
    let n: Int64
    /// `CounterResetHint` raw value.
    let hint: Int
    /// Hex bit pattern, for kind "f".
    let f: String
}

struct StatsIterOp: Decodable, Sendable {
    let op: String
    /// Int64 as a decimal string, "" when the op takes no argument.
    let arg: String
}

struct StatsIn: Decodable, Sendable {
    let samples: [StatsSample]?
    let ops: [StatsIterOp]
}

struct StatsStep: Decodable, Equatable, Sendable {
    var op: String
    /// `ValueType` raw value, or -1 where the op does not return one.
    var ret: Int = -1
    var t: String = ""
    var st: String = ""
    var f: String = ""
    /// The returned histogram's `description`. Shows whether the buckets were
    /// stripped; nil when the op returns no histogram.
    var hist: String?
    /// `counterResetHint`, which `description` does **not** render, plus the three
    /// other fields that survive stripping. -1 / "" when absent.
    var hint: Int = -1
    var count: String = ""
    var sum: String = ""
    var schema: Int = -1
    var err: String = ""
}

struct StatsOut: Decodable, Equatable, Sendable {
    let steps: [StatsStep]
}

func statsI64(_ v: Int64) -> String { String(v) }

func statsParseI64(_ s: String) -> Int64 {
    if s.isEmpty { return 0 }
    guard let v = Int64(s) else {
        preconditionFailure("not an Int64: \(s)")
    }
    return v
}

func statsHexBits(_ v: Double) -> String { String(format: "%016lx", v.bitPattern) }

func statsDoubleFromHex(_ s: String) -> Double {
    guard let bits = UInt64(s, radix: 16) else { return 0 }
    return Double(bitPattern: bits)
}

// MARK: - The generators

/// Ported verbatim from `tsdbutil.GenerateTestHistogram`, and duplicated from
/// `genTestHistogram` in oracle/suites_promql_histstats.go.
///
/// Counts and sum scale with `i`, which is what makes `i` ascending a
/// no-counter-reset series and `i` descending a reset. The duplication cannot drift
/// silently: every step carries the resulting count, sum and rendering.
func genTestHistogram(_ i: Int64) -> Histogram {
    Histogram(
        schema: 1,
        zeroThreshold: 0.001,
        zeroCount: UInt64(2 + i),
        count: UInt64(12 + i * 9),
        sum: 18.4 * Double(i + 1),
        positiveSpans: [Span(offset: 0, length: 2), Span(offset: 1, length: 2)],
        negativeSpans: [Span(offset: 0, length: 2), Span(offset: 1, length: 2)],
        positiveBuckets: [i + 1, 1, -1, 0],
        negativeBuckets: [i + 1, 1, -1, 0])
}

/// `tsdbutil.GenerateTestCustomBucketsHistogram`.
func genTestCustomBucketsHistogram(_ i: Int64) -> Histogram {
    Histogram(
        schema: HistogramSchema.customBuckets,
        count: UInt64(5 + i * 4),
        sum: 18.4 * Double(i + 1),
        positiveSpans: [Span(offset: 0, length: 2), Span(offset: 1, length: 2)],
        positiveBuckets: [i + 1, 1, -1, 0],
        customValues: [0, 1, 2, 3, 4])
}

/// The stale marker exactly as histogram_stats_iterator_test.go:70 spells it: a
/// histogram with nothing but the stale sum, so its count is 0.
func genStaleHistogram() -> Histogram {
    Histogram(sum: PromValue.staleNaN)
}

/// Mirrors `genFixedTotalHistogram` — count and sum are the same for every `i` and
/// only the bucket distribution moves, so `detectReset` can decide only from the
/// buckets. Not an upstream generator; it exists because it is the only shape that
/// distinguishes a FULL baseline from a stripped one. See the oracle's comment.
func genFixedTotalHistogram(_ i: Int64) -> Histogram {
    Histogram(
        schema: 0,
        count: 10,
        sum: 20,
        positiveSpans: [Span(offset: 0, length: 2)],
        positiveBuckets: [i, 10 - 2 * i])
}

func statsHistogram(_ gen: String, _ n: Int64, _ hint: Int) -> Histogram {
    var h: Histogram
    switch gen {
    case "std": h = genTestHistogram(n)
    case "custom": h = genTestCustomBucketsHistogram(n)
    case "fixedTotal": h = genFixedTotalHistogram(n)
    case "stale": h = genStaleHistogram()
    default: preconditionFailure("unknown histogram generator \(gen)")
    }
    guard let resolved = CounterResetHint(rawValue: UInt8(hint)) else {
        preconditionFailure("unknown counter reset hint \(hint)")
    }
    h.counterResetHint = resolved
    return h
}

// MARK: - The corpus's own sample type

/// Mirrors `oracleSample`, and duplicated from `CorpusSample` in
/// Tests/PromStorageTests/IteratorWire.swift. Deliberately looser than
/// `FSample`/`HSample`: `f` does not trap for a histogram sample.
struct StatsCorpusSample: PromChunks.Sample {
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

    func copy() -> any PromChunks.Sample {
        StatsCorpusSample(
            st: st, t: t, fValue: fValue, hValue: hValue?.copy(), fhValue: fhValue?.copy())
    }
}

func buildStatsSamples(_ in_: [StatsSample]?) -> SampleSlice {
    var out = [any PromChunks.Sample]()
    for s in in_ ?? [] {
        var sample = StatsCorpusSample(
            st: 0, t: statsParseI64(s.t), fValue: 0, hValue: nil, fhValue: nil)
        switch s.kind {
        case "f":
            sample.fValue = statsDoubleFromHex(s.f)
        case "h":
            sample.hValue = statsHistogram(s.gen, s.n, s.hint)
        case "fh":
            sample.fhValue = statsHistogram(s.gen, s.n, s.hint).toFloat()
        default:
            preconditionFailure("unknown sample kind \(s.kind)")
        }
        out.append(sample)
    }
    return SampleSlice(out)
}

// MARK: - Replay

/// Mirrors `dirtyReuseBuffer`: a FULL histogram of the *other* schema family than
/// the samples use, so every field `copy(to:)` must clear is dirty on the way in.
func dirtyReuseBuffer() -> FloatHistogram {
    genTestCustomBucketsHistogram(7).toFloat()
}

func runHistogramStatsOps(_ input: StatsIn) -> StatsOut {
    let it = HistogramStatsIterator(newListSeriesIterator(buildStatsSamples(input.samples)))

    func record(_ step: inout StatsStep, _ t: Int64, _ fh: FloatHistogram?) {
        step.t = statsI64(t)
        guard let fh else {
            step.hint = -1
            step.schema = -1
            return
        }
        step.hist = fh.description
        step.hint = Int(fh.counterResetHint.rawValue)
        step.count = statsHexBits(fh.count)
        step.sum = statsHexBits(fh.sum)
        step.schema = Int(fh.schema)
    }

    var steps = [StatsStep]()
    for op in input.ops {
        var step = StatsStep(op: op.op)
        switch op.op {
        case "next":
            step.ret = Int(it.next().rawValue)
        case "seek":
            step.ret = Int(it.seek(statsParseI64(op.arg)).rawValue)
        case "at":
            let (t, f) = it.at()
            step.t = statsI64(t)
            step.f = statsHexBits(f)
        case "atT":
            step.t = statsI64(it.atT())
        case "atST":
            step.st = statsI64(it.atST())
        case "atFH":
            let (t, fh) = it.atFloatHistogram(nil)
            record(&step, t, fh)
        case "atFHReuse":
            let (t, fh) = it.atFloatHistogram(dirtyReuseBuffer())
            record(&step, t, fh)
        case "reset":
            it.reset(newListSeriesIterator(buildStatsSamples(input.samples)))
        case "err":
            if let e = it.err() { step.err = "\(e)" }
        default:
            preconditionFailure("unknown histogram-stats op \(op.op)")
        }
        steps.append(step)
    }
    return StatsOut(steps: steps)
}
