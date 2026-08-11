//===----------------------------------------------------------------------===//
// `PostingsForMatchers` — a query's label matchers to a postings list.
//
// **The corpus contains real index files and the answers upstream's own function gave on them.** The oracle
// writes each file with `index.Writer` and then calls `tsdb.PostingsForMatchers` against `index.Reader`
// directly — `*index.Reader` satisfies `tsdb.IndexReader` in full, so there is no mock anywhere in the
// comparison. That matters here more than in most suites, because the function's hardest behaviours are about
// what the index does NOT contain: a series with no `l` label has no posting under any value of `l`, and that
// absence is the entire reason `labelMustBeSet` exists.
//
// Each query's expected answer is checked twice over — by series ref AND by the label sets those refs
// resolve to. The refs alone would catch a wrong answer; the label sets say which series it got wrong, which
// is the difference between a five-minute diagnosis and an hour of one.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromEncoding
import PromIndex
import PromLabels
import Testing

struct PFMIn: Codable, Sendable {
    var series: [[String]]?
    var queries: [[[String]]]?
    var fileHex: String
}

struct PFMOut: Decodable, Equatable, Sendable {
    var refs: [[UInt64]]
    var labelSets: [[String]]
    var errs: [String]
    var writeErr: String
}

/// A `PostingsIndex` over one index file's bytes.
///
/// The three methods delegate to the pinned reader functions; nothing here decides anything, which is the
/// point — `PostingsForMatchers` is what is under test and this is the seam it needs. `BlockReader` will
/// grow the same conformance once the querier lands, and then this exists only for the corpus.
private struct FileIndex: PostingsIndex {
    let bytes: [UInt8]
    let toc: IndexTOC
    let sparse: [String: [PostingOffset]]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        (self.toc, self.sparse) = try bytes.withUnsafeBytes { buf in
            let bs = ByteSlice(buf)
            let toc = try IndexTOC(byteSlice: bs)
            return (toc, try buildPostingsOffsetIndex(bs, postingsTable: toc.postingsTable))
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
}

private func unhexPFM(_ s: String) -> [UInt8] {
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

private func matcherFromSpec(_ spec: [String]) throws -> Matcher {
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

@Suite("index: PostingsForMatchers")
struct PostingsForMatchersTests {

    @Test("every committed query returns exactly the series upstream returned")
    func matchesGo() throws {
        try Fixtures.check("index/pfm.jsonl", FixtureCase<PFMIn, PFMOut>.self) { input in
            var out = PFMOut(refs: [], labelSets: [], errs: [], writeErr: "")

            let bytes = unhexPFM(input.fileHex)
            let ix = try FileIndex(bytes)
            let symbols = try bytes.withUnsafeBytes { buf -> IndexSymbols in
                let bs = ByteSlice(buf)
                let toc = try IndexTOC(byteSlice: bs)
                return try IndexSymbols(
                    byteSlice: bs, version: indexFormatV2, off: Int(toc.symbols))
            }

            for q in input.queries ?? [] {
                do {
                    let ms = try q.map { try matcherFromSpec($0) }
                    let p = try postingsForMatchers(ix, ms)
                    let ids = try expandPostings(p)
                    out.refs.append(ids.map(\.rawValue))
                    // Resolve each ref to its labels, so a wrong answer names the series.
                    out.labelSets.append(
                        try bytes.withUnsafeBytes { buf -> [String] in
                            let bs = ByteSlice(buf)
                            return try ids.map { id in
                                let s = try readSeries(
                                    bs, id: id.rawValue, version: indexFormatV2,
                                    lookupSymbol: { try symbols.lookup($0) })
                                // `Labels.description` is the pinned port of `labels.Labels.String()`,
                                // quoting included — hand-rolling it here would be a second, unpinned
                                // implementation of a surface ADR-4's neighbour already covers.
                                return Labels(s.labels.map { Label($0.name, $0.value) })
                                    .description
                            }
                        })
                    out.errs.append("")
                } catch {
                    out.refs.append([])
                    out.labelSets.append([])
                    out.errs.append(String(describing: error))
                }
            }
            return out
        }
    }
}
