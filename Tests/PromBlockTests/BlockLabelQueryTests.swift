//===----------------------------------------------------------------------===//
// `labelValuesWithMatchers` and `labelNamesWithMatchers`, against a real block Go opened.
//
// **The corpus is generated through `tsdb.OpenBlock` and `tsdb.NewBlockQuerier`, not through an adapter.**
// Both functions are unexported, and the tempting shortcut — a Go type satisfying `tsdb.BlockReader` by
// delegating to `index.Reader` — would bypass the code under test, because `Block.Index()` returns
// `blockIndexReader` and that wrapper is exactly what decides between `ir.LabelValues` and
// `labelValuesWithMatchers`. So the oracle writes the three files a block is and lets upstream open it.
//
// The corpus records the SORTED and UNSORTED forms of every value query, because `SortedLabelValues` with
// matchers sorts what `LabelValues` returned while with no matchers it asks the reader for sorted values —
// two entry points, two orders, both reachable from `storage.Querier`.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromEncoding
import PromIndex
import PromLabels
import Testing

struct LabelValueQuery: Codable, Sendable {
    var name: String
    var limit: Int
    var matchers: [[String]]?
}

struct LabelNameQuery: Codable, Sendable {
    var limit: Int
    var matchers: [[String]]?
}

struct BlockLabelsIn: Codable, Sendable {
    var series: [[String]]?
    var valueQueries: [LabelValueQuery]?
    var nameQueries: [LabelNameQuery]?
    var indexHex: String
    var metaHex: String
    var segHexes: [String]?
}

struct BlockLabelsOut: Decodable, Equatable, Sendable {
    var values: [[String]]
    var valuesUnsort: [[String]]
    var valueErrs: [String]
    var names: [[String]]
    var nameErrs: [String]
    var openErr: String
}

/// A `LabelQueryIndex` over one index file's bytes.
///
/// Deliberately a *test* type rather than a method set on `BlockReader`: the querier slice that gives
/// `BlockReader` this conformance for real is the next one, and wiring it here first would leave the corpus
/// checking a shim it was about to replace.
private struct LabelFileIndex: LabelQueryIndex {
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

    func labelValues(name: String) throws -> [String] {
        try bytes.withUnsafeBytes { buf in
            try indexLabelValues(
                ByteSlice(buf), postingsTable: toc.postingsTable, sparse: sparse, name: name,
                limit: 0)
        }
    }

    func labelNamesFor(_ postings: any Postings) throws -> [String] {
        let ids = try expandPostings(postings).map(\.rawValue)
        return try bytes.withUnsafeBytes { buf in
            try indexLabelNamesFor(
                ByteSlice(buf), version: indexFormatV2, seriesIDs: ids,
                lookupSymbol: { try symbols.lookup($0) })
        }
    }

    func labelNames() throws -> [String] { indexLabelNames(sparse) }
}

private func unhexBL(_ s: String) -> [UInt8] {
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

private func matcherOf(_ spec: [String]) throws -> Matcher {
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

@Suite("block: LabelValues and LabelNames with matchers")
struct BlockLabelQueryTests {

    @Test("every committed query matches what a real block querier returned")
    func matchesGo() throws {
        try Fixtures.check("block/labels.jsonl", FixtureCase<BlockLabelsIn, BlockLabelsOut>.self) {
            input in
            var out = BlockLabelsOut(
                values: [], valuesUnsort: [], valueErrs: [], names: [], nameErrs: [], openErr: "")

            let ix = try LabelFileIndex(unhexBL(input.indexHex))

            for vq in input.valueQueries ?? [] {
                do {
                    let ms = try (vq.matchers ?? []).map { try matcherOf($0) }
                    out.values.append(
                        try blockSortedLabelValues(
                            ix, name: vq.name, limit: vq.limit, matchers: ms))
                    out.valuesUnsort.append(
                        try blockLabelValues(ix, name: vq.name, limit: vq.limit, matchers: ms))
                    out.valueErrs.append("")
                } catch {
                    out.values.append([])
                    out.valuesUnsort.append([])
                    out.valueErrs.append(String(describing: error))
                }
            }

            for nq in input.nameQueries ?? [] {
                do {
                    let ms = try (nq.matchers ?? []).map { try matcherOf($0) }
                    out.names.append(try blockLabelNames(ix, limit: nq.limit, matchers: ms))
                    out.nameErrs.append("")
                } catch {
                    out.names.append([])
                    out.nameErrs.append(String(describing: error))
                }
            }
            return out
        }
    }
}
