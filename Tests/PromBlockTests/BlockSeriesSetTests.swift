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
    /// The `SelectHints` range when it differs from the querier's; 0/0 means "same as mint/maxt". These are
    /// what pin `selectSeriesSet`'s range OVERRIDE — see §6v.
    var hintStart: Int64
    var hintEnd: Int64

    /// Go: `hintStartOf` / `hintEndOf`.
    var effectiveHints: (start: Int64, end: Int64) {
        if hintStart == 0 && hintEnd == 0 { return (mint, maxt) }
        return (hintStart, hintEnd)
    }
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
    /// Per query, per series: the result of a fixed SEEK script over the flat sample iterator.
    var seekTimes: [[[Int64]]]
    /// Per query, per series: each chunk's BYTES, hex — pass-through or re-encoded. See §6u.
    var chunkBytes: [[[String]]]
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
                labelSets: [], chunkRanges: [], sampleTimes: [], seekTimes: [], chunkBytes: [],
                errs: [], openErr: "")
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
                    // **Two passes with DIFFERENT ranges, because the oracle uses two entry points.** The
                    // label-set and chunk-meta pass goes through `NewBlockChunkSeriesSet` on the Go side,
                    // which takes the range directly; the sample and seek passes go through
                    // `blockQuerier.Select`, which OVERRIDES that range with the hints'. Applying the hints
                    // to both made 1 of 8 cases mismatch the moment differing-hint cases were added — which
                    // is the gap §6v declared doing its job, on the harness rather than the port.
                    let ss = BlockBaseSeriesSet(
                        index: ix, postings: p, mint: q.mint, maxt: q.maxt,
                        disableTrimming: q.disableTrimming)
                    // The hint-driven set, used for the sample and seek passes below.
                    let selectMs = ms.isEmpty ? [try Matcher(.equal, "", "")] : ms
                    let hintSpec = BlockSelectHints(
                        start: q.effectiveHints.start, end: q.effectiveHints.end,
                        disableTrimming: q.disableTrimming)
                    var sets: [String] = []
                    var ranges: [[[Int64]]] = []
                    var times: [[Int64]] = []
                    var seeks: [[Int64]] = []
                    var allBytes: [[String]] = []
                    while ss.next() {
                        guard let cur = ss.current else { continue }
                        sets.append(
                            Labels(cur.labels.map { Label($0.name, $0.value) }).description)

                        // The CHUNK view, through the real `PopulateWithDelChunkSeriesIterator` rather
                        // than derived from the sample iterator — which is what makes `currDelIter`'s
                        // nil-ness observable: an undeleted chunk passes its ORIGINAL bytes through, a
                        // deleted one is re-encoded, and the meta's bounds come from the surviving samples.
                        _ = cur

                    }
                    // The sample and seek passes, as their own loop over the HINT-driven series — the hint
                    // range can select a DIFFERENT NUMBER of series than the querier's range, so they cannot
                    // be nested inside the label loop. That is what made 1 of 8 cases mismatch until the two
                    // passes were separated; the gap §6v declared caught a harness bug, not a port bug.
                    // The chunk view, through `blockChunkQuerierSelect`. The oracle drives this half with
                    // `NewBlockChunkSeriesSet` on the querier's OWN range, so no hints here — the split the
                    // previous commit's harness bug was about.
                    // Hints carrying the querier's OWN range — so the override is a no-op — but the real
                    // `disableTrimming`, which `NewBlockChunkSeriesSet` receives directly on the Go side and
                    // which `blockSelect` reads only from hints. Passing nil hints here defaults it to false
                    // and mismatched 6 of 8 cases: the flag has no other route in.
                    let chunkSet = try blockChunkQuerierSelect(
                        index: ix, chunks: source, mint: q.mint, maxt: q.maxt,
                        matchers: selectMs,
                        hints: BlockSelectHints(
                            start: q.mint, end: q.maxt, disableTrimming: q.disableTrimming))
                    while chunkSet.next() {
                        guard let cc = chunkSet.current else { continue }
                        var rs: [[Int64]] = []
                        var bs: [String] = []
                        while cc.iterator.next() {
                            guard let c = cc.iterator.current else { continue }
                            rs.append([c.meta.minTime, c.meta.maxTime])
                            bs.append(c.bytes.map { String(format: "%02x", $0) }.joined())
                        }
                        if let e = cc.iterator.err() { throw e }
                        ranges.append(rs)
                        allBytes.append(bs)
                    }
                    if let e = chunkSet.err() { throw e }

                    // Through `blockQuerierSelect` — the real entry point, so the sample/chunk distinction is
                    // exercised where a reader would look for it rather than assembled here.
                    let sampleSet = try blockQuerierSelect(
                        index: ix, chunks: source, mint: q.mint, maxt: q.maxt,
                        matchers: selectMs, hints: hintSpec)
                    while sampleSet.next() {
                        guard let cur2 = sampleSet.current else { continue }
                        var ts: [Int64] = []
                        while cur2.iterator.next() != .none { ts.append(cur2.iterator.atT()) }
                        times.append(ts)
                    }
                    if let e = sampleSet.err() { throw e }

                    // The seek script needs a fresh set: the one above is exhausted.
                    let seekSet = try blockQuerierSelect(
                        index: ix, chunks: source, mint: q.mint, maxt: q.maxt,
                        matchers: selectMs, hints: hintSpec)
                    while seekSet.next() {
                        guard let cur3 = seekSet.current else { continue }
                        let sk = cur3.iterator
                        var res: [Int64] = []
                        let hs = q.effectiveHints
                        let mid = hs.start + (hs.end - hs.start) / 2
                        func record(_ vt: ValueType) {
                            res.append(vt == .none ? -(1 << 62) : sk.atT())
                        }
                        record(sk.next())
                        record(sk.seek(hs.start))
                        record(sk.next())
                        record(sk.seek(mid))
                        record(sk.next())
                        record(sk.seek(hs.end))
                        record(sk.next())
                        record(sk.seek(hs.end + 1))
                        record(sk.next())
                        seeks.append(res)
                    }
                    if let e = seekSet.err() { throw e }

                    out.labelSets.append(sets)
                    out.chunkRanges.append(ranges)
                    out.sampleTimes.append(times)
                    out.seekTimes.append(seeks)
                    out.chunkBytes.append(allBytes)
                    out.errs.append(ss.err().map { String(describing: $0) } ?? "")
                } catch {
                    out.labelSets.append([])
                    out.chunkRanges.append([])
                    out.sampleTimes.append([])
                    out.seekTimes.append([])
                    out.chunkBytes.append([])
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
