//===----------------------------------------------------------------------===//
// A block's `meta.json`, compared byte for byte against `json.MarshalIndent`.
//
// This is the only JSON in the TSDB, so it is the only place `encoding/json`'s own behaviour is a
// compatibility surface — field order, `omitempty`, the tab indent, and Go's HTML-escaping. The port emits
// the JSON by hand for those reasons, and this is what says whether that was right.
//
// Hint strings travel as HEX: they are where the escaping cases live, and a JSON string field would repair
// exactly what is under test. The submatch and chunkenc corpora learnt the same lesson.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import Testing

struct BlockMetaIn: Codable, Sendable {
    var ulidHex: String
    var minTime: Int64
    var maxTime: Int64
    var numSamples: UInt64
    var numFloatSamples: UInt64
    var numHistogramSamples: UInt64
    var numSeries: UInt64
    var numChunks: UInt64
    var numTombstones: UInt64
    var level: Int
    var sourceHexes: [String]?
    var deletable: Bool
    var parentHexes: [String]?
    var parentTimes: [[Int64]]?
    var failed: Bool
    var hintHexes: [String]?
}

struct BlockMetaOut: Decodable, Equatable, Sendable {
    var jsonHex: String
    var ulidString: String
}

private func unhexB(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func hexB(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined()
}

@Suite("block: meta.json, byte for byte")
struct BlockMetaTests {

    @Test("every committed meta marshals exactly as Go marshals it")
    func matchesGo() throws {
        try Fixtures.check("block/meta.jsonl", FixtureCase<BlockMetaIn, BlockMetaOut>.self) {
            input in
            var m = BlockMeta(
                ulid: ULID(bytes: unhexB(input.ulidHex)), minTime: input.minTime,
                maxTime: input.maxTime)
            m.stats.numSamples = input.numSamples
            m.stats.numFloatSamples = input.numFloatSamples
            m.stats.numHistogramSamples = input.numHistogramSamples
            m.stats.numSeries = input.numSeries
            m.stats.numChunks = input.numChunks
            m.stats.numTombstones = input.numTombstones
            m.compaction.level = input.level
            m.compaction.deletable = input.deletable
            m.compaction.failed = input.failed
            m.compaction.sources = (input.sourceHexes ?? []).map { ULID(bytes: unhexB($0)) }
            for (i, h) in (input.parentHexes ?? []).enumerated() {
                let times = (input.parentTimes ?? [])
                let mint = i < times.count ? times[i][0] : 0
                let maxt = i < times.count ? times[i][1] : 0
                m.compaction.parents.append(
                    BlockDesc(ulid: ULID(bytes: unhexB(h)), minTime: mint, maxTime: maxt))
            }
            // A hint's bytes may not be valid UTF-8 in principle; Go's JSON would then emit U+FFFD, and the
            // port matches by decoding the same way.
            m.compaction.hints = (input.hintHexes ?? []).map {
                String(decoding: unhexB($0), as: UTF8.self)
            }

            return BlockMetaOut(
                jsonHex: hexB(m.encodeJSON()), ulidString: m.ulid.description)
        }
    }
}
