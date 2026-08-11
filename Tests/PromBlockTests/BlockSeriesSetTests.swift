//===----------------------------------------------------------------------===//
// `blockBaseSeriesSet.Next` — from a postings list to selected series.
//
// The oracle drives upstream's own `NewBlockChunkSeriesSet` (exported) over a real block written by
// `oracle/blockfixture.go`, so both sides run real code end to end.
//
// **Extended by §6t to cover trimming.** It began as label sets and errors only — `Next`'s selection — because
// the trimming it computes is observable only through the populate iterators. With those ported the suite now
// records three things per query: the label sets, the per-chunk trimmed RANGES, and the flat SAMPLE
// timestamps. The Go side gets the ranges from `blockChunkSeriesSet` and the samples through
// `blockQuerier.Select`, which is the exported route to `populateWithDelSeriesIterator`; `SelectHints` is what
// carries `DisableTrimming` through it.
//
// The port derives each chunk's trimmed range from the first and last SURVIVING sample, which is what
// `populateWithDelChunkSeriesIterator` does to set a rewritten meta's bounds. The re-encoded chunk BYTES are
// the part that iterator additionally produces, and they are not pinned here — a narrowing recorded in §6t.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromChunkEnc
import PromChunks
import PromEncoding
import PromFS
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
    /// Per query, per series: the chunk metas the iterator yielded. Where TRIMMING becomes visible.
    var chunkRanges: [[[[Int64]]]]
    /// Per query, per series: the sample timestamps the flat sample iterator yielded.
    var sampleTimes: [[[Int64]]]
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
            var out = SeriesSetOut(
                labelSets: [], chunkRanges: [], sampleTimes: [], errs: [], openErr: "")
            let ix = try SeriesSetFileIndex(unhexSS(input.indexHex))
            // The chunk segments, in the sorted order that defines the reference index space (quirk 142).
            let source = try SegmentChunkSource(segmentHexes: input.segHexes ?? [])

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
                    var ranges: [[[Int64]]] = []
                    var times: [[Int64]] = []
                    while ss.next() {
                        guard let cur = ss.current else { continue }
                        sets.append(
                            Labels(cur.labels.map { Label($0.name, $0.value) }).description)

                        // The CHUNK view: `populateWithDelChunkSeriesIterator`'s metas. Not ported yet, so
                        // the trimmed range is derived the way that iterator derives it — from the first and
                        // last surviving sample of each chunk. That is a deliberate narrowing recorded in
                        // §6t: the re-encoded BYTES are what the chunk iterator additionally produces, and
                        // they are pinned when it lands.
                        var rs: [[Int64]] = []
                        for meta in cur.chunks {
                            let flat = PopulateWithDelSeriesIterator(
                                blockID: "", source: source, metas: [meta],
                                intervals: cur.intervals)
                            var first: Int64?
                            var last: Int64 = 0
                            while flat.next() != .none {
                                if first == nil { first = flat.atT() }
                                last = flat.atT()
                            }
                            // A chunk whose every sample was deleted yields no meta at all.
                            if let f = first { rs.append([f, last]) }
                        }
                        ranges.append(rs)

                        // The SAMPLE view, over all of the series' chunks at once.
                        let flat = PopulateWithDelSeriesIterator(
                            blockID: "", source: source, metas: cur.chunks,
                            intervals: cur.intervals)
                        var ts: [Int64] = []
                        while flat.next() != .none { ts.append(flat.atT()) }
                        times.append(ts)
                    }
                    out.labelSets.append(sets)
                    out.chunkRanges.append(ranges)
                    out.sampleTimes.append(times)
                    out.errs.append(ss.err().map { String(describing: $0) } ?? "")
                } catch {
                    out.labelSets.append([])
                    out.chunkRanges.append([])
                    out.sampleTimes.append([])
                    out.errs.append(String(describing: error))
                }
            }
            return out
        }
    }
}

/// A `BlockChunkSource` over a block's chunk segments.
///
/// ADR-16's block implementation: always a chunk, never an iterable, `copyHeadChunk` ignored. Four lines of
/// substance, which is the ADR's third argument for keeping the pair shape now.
private struct SegmentChunkSource: BlockChunkSource {
    let reader: ChunkReader

    init(segmentHexes: [String]) throws {
        let fs = InMemoryFS()
        try fs.createDirectory("chunks")
        // Names matter: `ChunkReader` sorts them, and that sorted order is the reference index space
        // (quirk 142). The oracle emits the segments already sorted, so the six-digit names reproduce it.
        for (i, hex) in segmentHexes.enumerated() {
            let w = try fs.createFile(String(format: "chunks/%06d", i + 1))
            try w.append(unhexSS(hex))
            try w.close()
        }
        self.reader = try ChunkReader(fs: fs, dir: "chunks")
    }

    func chunkOrIterable(_ meta: DecodedChunkMeta, copyHeadChunk: Bool) throws -> ChunkOrIterable {
        ChunkOrIterable(chunk: try reader.chunk(ref: ChunkRef(rawValue: meta.ref)))
    }
}
