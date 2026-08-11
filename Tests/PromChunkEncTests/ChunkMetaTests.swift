//===----------------------------------------------------------------------===//
// The chunk-metadata corpus: which samples share a chunk, what header each chunk gets, and what
// `CounterResetHint` a query reads back.
//
// Driven through the same seam the oracle uses. `appendable` is unexported upstream, so the fixture
// compares the *composition* — layout, headers, read-back hints — which is what the storage and the
// engine actually observe anyway. See `oracle/suites_chunkmeta.go`.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromHistogram
import Testing

struct CHHist: Codable, Sendable {
    var schema: Int32
    var count: String
    var sum: String
    var zt: String
    var zc: String
    var pspans: [String]
    var pbuckets: [String]
    var nspans: [String]
    var nbuckets: [String]
    var cv: [String]
    var hint: String
}

struct ChunkMetaIn: Codable, Sendable {
    var samples: [CHHist]
    var cutBefore: [Int]
}

struct ChunkMetaOut: Decodable, Equatable, Sendable {
    var chunkOf: [Int]
    var headers: [String]
    var hints: [String]
    var err: String
}

private func bits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

private func parseSpans(_ ss: [String]) -> [Span] {
    ss.map { s in
        let body = s.dropFirst().dropLast()
        let parts = body.split(separator: ",")
        return Span(offset: Int32(parts[0])!, length: UInt32(parts[1])!)
    }
}

private func toFH(_ w: CHHist) -> FloatHistogram {
    var h = FloatHistogram()
    h.schema = w.schema
    h.count = bits(w.count)
    h.sum = bits(w.sum)
    h.zeroThreshold = bits(w.zt)
    h.zeroCount = bits(w.zc)
    h.positiveSpans = parseSpans(w.pspans)
    h.negativeSpans = parseSpans(w.nspans)
    h.positiveBuckets = w.pbuckets.map(bits)
    h.negativeBuckets = w.nbuckets.map(bits)
    h.customValues = w.cv.isEmpty ? nil : w.cv.map(bits)
    switch w.hint {
    case "reset": h.counterResetHint = .counterReset
    case "not_reset": h.counterResetHint = .notCounterReset
    case "gauge": h.counterResetHint = .gaugeType
    default: h.counterResetHint = .unknownCounterReset
    }
    return h
}

private func headerName(_ h: CounterResetHeader) -> String {
    switch h {
    case .counterReset: return "reset"
    case .notCounterReset: return "not_reset"
    case .gaugeType: return "gauge"
    case .unknownCounterReset: return "unknown"
    }
}

private func hintName(_ h: CounterResetHint) -> String {
    switch h {
    case .counterReset: return "reset"
    case .notCounterReset: return "not_reset"
    case .gaugeType: return "gauge"
    case .unknownCounterReset: return "unknown"
    }
}

@Suite("chunkenc: chunk layout, headers and the hints they imply")
struct ChunkMetaTests {

    @Test("every committed case matches Go")
    func matchesGo() throws {
        try Fixtures.check("chunkenc/chunkmeta.jsonl", FixtureCase<ChunkMetaIn, ChunkMetaOut>.self) {
            input in
            let plan = planFloatHistogramChunks(
                input.samples.map(toFH), cutBefore: Set(input.cutBefore))
            return ChunkMetaOut(
                chunkOf: plan.chunkOf,
                headers: plan.headers.map(headerName),
                hints: plan.hints.map(hintName),
                err: "")
        }
    }
}
