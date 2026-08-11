//===----------------------------------------------------------------------===//
// `blockBaseSeriesSet.Next` — from a postings list to selected series.
//
// The oracle drives upstream's own `NewBlockChunkSeriesSet` (exported) over a real block written by
// `oracle/blockfixture.go`, so both sides run real code end to end.
//
// **Scope: the label sets and their ORDER, plus the error.** The chunk metas are where trimming becomes
// visible, and they come out of `populateWithDelChunkSeriesIterator` — the next slice. Comparing them here
// would force that iterator to exist for this suite to pass, which is the opposite of slicing. `Next`'s own
// decisions are what this pins: the three skip rules, the strict boundary comparisons, and the fact that
// `disableTrimming` changes what `SeriesData` it builds.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromEncoding
import PromIndex
import PromLabels
import PromStorage
import Testing

struct SeriesSetSeriesIn: Codable, Sendable {
    var labels: [[String]]
    var chunks: [[[Int64]]]?
}

struct SeriesSetQuery: Codable, Sendable {
    var mint: Int64
    var maxt: Int64
    var matchers: [[String]]?
    var disableTrimming: Bool
}

struct SeriesSetIn: Codable, Sendable {
    var series: [SeriesSetSeriesIn]?
    var queries: [SeriesSetQuery]?
    var indexHex: String
    var metaHex: String
    var segHexes: [String]?
}

struct SeriesSetOut: Decodable, Equatable, Sendable {
    var labelSets: [[String]]
    var errs: [String]
    var openErr: String
}

/// A `SeriesIndex` and `LabelQueryIndex` over one index file's bytes.
///
/// The same shim `BlockLabelQueryTests` uses, extended with `series(_:)`. It stays a test type until the
/// querier slice gives `BlockReader` these conformances for real.
private struct SeriesSetFileIndex: SeriesIndex, PostingsIndex {
    let bytes: [UInt8]
    let toc: IndexTOC
    let sparse: [String: [PostingOffset]]
    let symbols: IndexSymbols

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        (self.toc, self.sparse, self.symbols) = try bytes.withUnsafeBytes { buf in
            let bs = ByteSlice(buf)
            let toc = try IndexTOC(byteSlice: bs)
            return (
                toc,
                try buildPostingsOffsetIndex(bs, postingsTable: toc.postingsTable),
                try IndexSymbols(byteSlice: bs, version: indexFormatV2, off: Int(toc.symbols))
            )
        }
    }

    func postings(name: String, values: [String]) throws -> any Postings {
        try bytes.withUnsafeBytes { buf in
            merge(
                try indexPostings(
                    ByteSlice(buf), postingsTable: toc.postingsTable, sparse: sparse, name: name,
                    values: values))
        }
    }

    func postingsForLabelMatching(name: String, match: @escaping (String) -> Bool) throws
        -> any Postings
    {
        try bytes.withUnsafeBytes { buf in
            try indexPostingsForLabelMatching(
                ByteSlice(buf), postingsTable: toc.postingsTable, sparse: sparse, name: name,
                match: match)
        }
    }

    func postingsForAllLabelValues(name: String) throws -> any Postings {
        try bytes.withUnsafeBytes { buf in
            try indexPostingsForLabelMatching(
                ByteSlice(buf), postingsTable: toc.postingsTable, sparse: sparse, name: name,
                match: nil)
        }
    }

    func series(_ ref: SeriesRef) throws -> (
        labels: [(name: String, value: String)], chunks: [DecodedChunkMeta]
    )? {
        try bytes.withUnsafeBytes { buf in
            let decoded = try readSeries(
                ByteSlice(buf), id: ref.rawValue, version: indexFormatV2,
                lookupSymbol: { try symbols.lookup($0) })
            return (decoded.labels, decoded.chunks)
        }
    }
}

private func unhexSS(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count / 2)
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func matcherSS(_ spec: [String]) throws -> Matcher {
    let type: MatchType
    switch spec[0] {
    case "=": type = .equal
    case "!=": type = .notEqual
    case "=~": type = .regexp
    case "!~": type = .notRegexp
    default: fatalError("unknown matcher type \(spec[0])")
    }
    return try Matcher(type, spec[1], spec[2])
}

@Suite("block: blockBaseSeriesSet selection")
struct BlockSeriesSetTests {

    @Test("every committed query selects the same series in the same order as Go")
    func matchesGo() throws {
        try Fixtures.check("block/seriesset.jsonl", FixtureCase<SeriesSetIn, SeriesSetOut>.self) {
            input in
            var out = SeriesSetOut(labelSets: [], errs: [], openErr: "")
            let ix = try SeriesSetFileIndex(unhexSS(input.indexHex))

            for q in input.queries ?? [] {
                do {
                    let ms = try (q.matchers ?? []).map { try matcherSS($0) }
                    let p: any Postings
                    if ms.isEmpty {
                        // Go: `index.AllPostingsKey()`.
                        let (k, v) = allPostingsKey()
                        p = try ix.postings(name: k, values: [v])
                    } else {
                        p = try postingsForMatchers(ix, ms)
                    }
                    let ss = BlockBaseSeriesSet(
                        index: ix, postings: p, mint: q.mint, maxt: q.maxt,
                        disableTrimming: q.disableTrimming)
                    var sets: [String] = []
                    while ss.next() {
                        guard let cur = ss.current else { continue }
                        sets.append(
                            Labels(cur.labels.map { Label($0.name, $0.value) }).description)
                    }
                    out.labelSets.append(sets)
                    out.errs.append(ss.err().map { String(describing: $0) } ?? "")
                } catch {
                    out.labelSets.append([])
                    out.errs.append(String(describing: error))
                }
            }
            return out
        }
    }
}
