//===----------------------------------------------------------------------===//
// Wire types and the replay harness for the promql/functions-elementwise fixtures.
//
// Mirrors oracle/suites_promql_functions_elementwise.go. Duplicated rather than
// shared, as HistogramStatsWire.swift and ValueWire.swift already are.
//
// `genTestHistogram` is reused from HistogramStatsWire.swift — same test module,
// so the generator is transcribed once.
//===----------------------------------------------------------------------===//

import PromHistogram
import PromLabels
import PromQLParser

@testable import PromQL

// MARK: - Wire

struct FnSampleIn: Decodable, Sendable {
    /// Flattened label name/value pairs.
    let metric: [String]
    /// Int64 as a decimal string.
    let t: String
    /// Hex bit pattern.
    let f: String
    /// When present, the sample carries `genTestHistogram(n).toFloat()` and `f` is
    /// ignored — exactly as Go ignores it when `H != nil`.
    let hist: Int64?
    /// A named histogram shape, for the cases where the *content* matters. The four
    /// names are transcribed from oracle/suites_promql_functions_histogram.go; a
    /// divergence shows up on the first case.
    let histRaw: String?
}

struct FnIn: Decodable, Sendable {
    let fn: String
    let delayed: Bool
    /// `enh.ts`, Int64 as a decimal string.
    let ts: String
    /// `vectorVals`: one entry per evaluated argument.
    let args: [[FnSampleIn]]
    /// The number of `Expr`s handed to the call. Only `funcRound` reads it, and it
    /// reads the *count*, which is why placeholders suffice.
    let nargs: Int
    /// `enh.out` seeded non-empty. Empty in every case that models a real query.
    let seed: [FnSampleIn]?
    /// A PromQL call expression whose parsed `Call.args` become the `args` the
    /// function receives. Set for the histogram family, which reads the arguments
    /// themselves — position ranges appear in its annotation text, and
    /// `histogram_quantiles` reads a `StringLiteral`.
    let expr: String?
    /// Sort the output samples and annotations before comparing. Set for the
    /// histogram family, whose classic results come out of a Go map.
    let sorted: Bool?
}

struct FnSampleOut: Decodable, Equatable, Sendable {
    var metric: String
    var t: String
    var f: String
    /// The histogram's `description`, or "" when the sample carries none. Always ""
    /// in this slice, so a port that passes one through fails here.
    var hist: String
    var dropName: Bool
}

struct FnOut: Decodable, Equatable, Sendable {
    var samples: [FnSampleOut]
    /// Always empty in this slice: every body returns no annotations.
    var annos: [String]
}

// MARK: - Replay

private func fnBuildVector(_ samples: [FnSampleIn]?) -> Vector {
    guard let samples else { return Vector() }
    var out = Vector()
    for s in samples {
        var smp = Sample(t: statsParseI64(s.t), metric: Labels(strings: s.metric))
        if let name = s.histRaw {
            smp.h = fnNamedHistogram(name)
        } else if let n = s.hist {
            smp.h = genTestHistogram(n).toFloat()
        } else {
            smp.f = statsDoubleFromHex(s.f)
        }
        out.append(smp)
    }
    return out
}

private func fnRenderVector(_ v: Vector) -> [FnSampleOut] {
    v.map { s in
        FnSampleOut(
            metric: s.metric.description,
            t: statsI64(s.t),
            f: statsHexBits(s.f),
            hist: s.h?.description ?? "",
            dropName: s.dropName
        )
    }
}

/// Runs one fixture case through ``PromQL/functionCalls``.
///
/// A missing entry is a hard failure, not a skip: the corpus only emits functions
/// this slice implements, so a lookup miss means the table lost one. The
/// *deferred* set is asserted separately, by name, against Go's full key list.
func runFnCase(_ input: FnIn) -> FnOut {
    guard let fn = functionCalls[input.fn] else {
        preconditionFailure("functionCalls has no entry for \(input.fn)")
    }
    let vectorVals = input.args.map { fnBuildVector($0) }
    let enh = EvalNodeHelper(
        ts: statsParseI64(input.ts),
        out: fnBuildVector(input.seed),
        enableDelayedNameRemoval: input.delayed
    )
    // Go hands `make(parser.Expressions, nargs)`, i.e. a slice of nil Exprs. The
    // port's `[any Expr]` cannot hold nil, and nothing in this slice dereferences
    // an element — `funcRound` reads only `args.count` — so a placeholder of the
    // right length is the faithful stand-in. Anything that starts reading the
    // elements has to carry real ASTs, and this comment is where to notice that.
    var args: [any Expr] = (0..<input.nargs).map { _ in NumberLiteral(val: 0) }
    if let source = input.expr, !source.isEmpty {
        // Experimental functions on, because `histogram_quantiles` is gated behind
        // that flag and the fixture needs its AST. The flag only widens which names
        // resolve, so nothing else in these corpora is affected.
        let parser = Parser(options: Options(enableExperimentalFunctions: true))
        guard let call = try? parser.parseExpr(source) as? Call else {
            preconditionFailure("fixture expr \(source) is not a parseable call")
        }
        args = call.args
    }
    let (got, annos) = fn(vectorVals, Matrix(), args, enh)
    // The `expr` is the query, so each annotation renders its (line:col). Without
    // it the bare message is emitted and which argument an annotation is reported
    // against becomes invisible.
    let (warnings, infos) = annos.asStrings(
        query: input.expr ?? "", maxWarnings: 0, maxInfos: 0)
    var samples = fnRenderVector(got)
    var strings = warnings + infos
    if input.sorted == true {
        samples.sort {
            if $0.metric != $1.metric { return $0.metric < $1.metric }
            return $0.f < $1.f
        }
        strings.sort()
    }
    return FnOut(samples: samples, annos: strings)
}

/// The four named histogram shapes `FnSampleIn.histRaw` can ask for, transcribed
/// from the oracle. `genTestHistogram` comes from HistogramStatsWire.swift.
func fnNamedHistogram(_ name: String) -> FloatHistogram {
    switch name {
    case "custom":
        // histogramVariance's arithmetic-mean branch: custom (NHCB) buckets.
        var h = FloatHistogram()
        h.schema = -53
        h.count = 10
        h.sum = 25
        h.customValues = [1, 2, 5, 10]
        h.positiveSpans = [Span(offset: 0, length: 4)]
        h.positiveBuckets = [2, 3, 4, 1]
        return h
    case "zeroneg":
        // The zero bucket, and a negative bucket where the geometric mean's sign
        // has to be restored.
        var h = FloatHistogram()
        h.schema = 0
        h.count = 14
        h.sum = 3.5
        h.zeroThreshold = 0.5
        h.zeroCount = 4
        h.positiveSpans = [Span(offset: 0, length: 3)]
        h.positiveBuckets = [2, 3, 1]
        h.negativeSpans = [Span(offset: 0, length: 2)]
        h.negativeBuckets = [3, 1]
        return h
    case "empty":
        var h = FloatHistogram()
        h.schema = 0
        return h
    case "nansum":
        // A NaN sum with real buckets, which is what makes histogramQuantile and
        // histogramFraction emit their own annotations — and so is what makes the
        // position range they report against observable.
        var h = FloatHistogram()
        h.schema = 0
        // Count EXCEEDS the bucket total: two observations were NaN, so they are in
        // count but in no bucket. That inequality is what both annotations test.
        h.count = 12
        h.sum = .nan
        h.positiveSpans = [Span(offset: 0, length: 3)]
        h.positiveBuckets = [2, 5, 3]
        return h
    case "negonly":
        var h = FloatHistogram()
        h.schema = 0
        h.count = 8
        h.sum = .nan
        h.negativeSpans = [Span(offset: 0, length: 3)]
        h.negativeBuckets = [1, 2, 3]
        return h
    default:
        guard name.hasPrefix("std/"), let n = Int64(name.dropFirst(4)) else {
            preconditionFailure("unknown histogram shape \(name)")
        }
        return genTestHistogram(n).toFloat()
    }
}
