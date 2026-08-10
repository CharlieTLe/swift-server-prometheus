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
        if let n = s.hist {
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
    let args: [any Expr] = (0..<input.nargs).map { _ in NumberLiteral(val: 0) }
    let (got, annos) = fn(vectorVals, Matrix(), args, enh)
    let (warnings, infos) = annos.asStrings(query: "", maxWarnings: 0, maxInfos: 0)
    return FnOut(samples: fnRenderVector(got), annos: warnings + infos)
}
