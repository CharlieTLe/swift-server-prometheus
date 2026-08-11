//===----------------------------------------------------------------------===//
// `tsdb.Block`, reduced to reading — the join from a series to its samples.
//
// **This is deliberately a round-trip test rather than a differential one, and the reason is that every
// piece it composes is ALREADY pinned against Go.** `index/batch.jsonl` says the index writer's bytes are
// Go's bytes and the index reader reads Go's files; `chunks/batch.jsonl` says the same of the chunk writer
// and reader, against Go's own segment files and Go's own refs; `block/meta.jsonl` says `meta.json` marshals
// as `encoding/json` marshals it. What is left un-pinned is only the *layout* — which file lives where under
// the block directory, and that a chunk meta's ref means what the chunk reader thinks it means.
//
// That last point is where the one real hazard is, and it is quirk 142: a `BlockChunkRef`'s file index is a
// position in the sorted segment list, not the segment's filename number. So the test forces a MULTI-SEGMENT
// block (a tiny segment size), because a single-segment block has file index 0 everywhere and would pass
// with the join wired to either meaning.
//===----------------------------------------------------------------------===//

import Foundation
import PromBlock
import PromChunkEnc
import PromChunks
import PromFS
import PromIndex
import PromStorage
import Testing

/// One series as the test wants to write it: labels, and the samples of each of its chunks.
private struct WantSeries {
    var labels: [(name: String, value: String)]
    var chunks: [[(t: Int64, v: Double)]]
}

/// Writes a whole block into `fs` and returns its directory.
///
/// The order here is the order upstream's `BlockWriter` uses and it is not arbitrary: the chunks are written
/// first because the index needs their refs, and `meta.json` is written last because its stats are counted
/// from what the other two produced.
private func writeBlock(
    _ fs: any PromFS, dir: String, series: [WantSeries], segmentSize: Int64
) throws -> BlockMeta {
    try fs.createDirectory(dir)

    // 1. Chunks. Every chunk of every series, in series order — which is what makes the refs ascending,
    //    and `AddSeries` rejects a chunk ref below the previous one.
    var encoded: [(encoding: Encoding, bytes: [UInt8])] = []
    var span: [(minTime: Int64, maxTime: Int64)] = []
    for s in series {
        for samples in s.chunks {
            let c = XORChunk()
            let app = try c.appender()
            for (t, v) in samples { app.append(t, v) }
            encoded.append((encoding: .xor, bytes: c.bytes))
            span.append((minTime: samples.first!.t, maxTime: samples.last!.t))
        }
    }
    let cw = try ChunkWriter(fs: fs, dir: dir + "/chunks", segmentSize: segmentSize)
    let refs = try cw.write(encoded)
    try cw.close()

    // 2. Index. Symbols first, in Go's byte order (ADR-10a: sorted as bytes, deduped as bytes — a
    //    `Set<String>` here would collide "e\u{301}" with "é" exactly as the writer's cache once did).
    let iw = try IndexWriter(fs: fs, path: dir + "/index")
    var symbolSet: Set<[UInt8]> = []
    for s in series {
        for l in s.labels {
            symbolSet.insert(Array(l.name.utf8))
            symbolSet.insert(Array(l.value.utf8))
        }
    }
    for sym in symbolSet.sorted(by: { a, b in
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }) {
        try iw.addSymbol(String(decoding: sym, as: UTF8.self))
    }

    var next = 0
    for (i, s) in series.enumerated() {
        var metas: [(minTime: Int64, maxTime: Int64, ref: UInt64)] = []
        for _ in s.chunks {
            metas.append((span[next].minTime, span[next].maxTime, refs[next].rawValue))
            next += 1
        }
        // Go: a series ID is the record's offset / 16, and the writer assigns them; the ref passed in must
        // be ascending. 1-based to match what a Head would hand it.
        try iw.addSeries(ref: UInt64(i + 1), labels: s.labels, chunks: metas)
    }
    try iw.close()

    // 3. `meta.json`, last, with the stats the other two produced.
    var meta = BlockMeta(
        ulid: ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!,
        minTime: span.map(\.minTime).min() ?? 0,
        maxTime: (span.map(\.maxTime).max() ?? 0) + 1)
    meta.stats.numSeries = UInt64(series.count)
    meta.stats.numChunks = UInt64(encoded.count)
    meta.stats.numSamples = UInt64(series.reduce(0) { $0 + $1.chunks.reduce(0) { $0 + $1.count } })
    meta.stats.numFloatSamples = meta.stats.numSamples
    meta.compaction.level = 1
    meta.compaction.sources = [meta.ulid]
    let h = try fs.createFile(dir + "/meta.json")
    try h.append(meta.encodeJSON())
    try h.close()

    return meta
}

/// Three series, the second with two chunks, over enough samples that a 256-byte segment cuts.
private let sampleSeries: [WantSeries] = [
    WantSeries(
        labels: [("__name__", "http_requests"), ("job", "api"), ("le", "0.1")],
        chunks: [(0..<120).map { (t: Int64($0) * 15_000, v: Double($0) * 1.5) }]),
    WantSeries(
        labels: [("__name__", "http_requests"), ("job", "web")],
        chunks: [
            (0..<90).map { (t: Int64($0) * 15_000, v: Double($0) + 0.25) },
            (90..<200).map { (t: Int64($0) * 15_000, v: Double($0) * -3.0) },
        ]),
    WantSeries(
        labels: [("__name__", "up"), ("job", "web")],
        chunks: [(0..<5).map { (t: Int64($0) * 30_000, v: 1) }]),
]

@Suite("block: opening a directory and joining index to chunks")
struct BlockReaderTests {

    @Test("a written block reopens, and every series' labels and samples survive")
    func roundTrip() throws {
        let fs = InMemoryFS()
        // 256 bytes forces a multi-segment block, which is the only shape that can catch quirk 142.
        let written = try writeBlock(fs, dir: "b1", series: sampleSeries, segmentSize: 256)

        let r = try BlockReader(fs: fs, dir: "b1")
        #expect(r.meta.ulid.description == written.ulid.description)
        #expect(r.meta.minTime == written.minTime)
        #expect(r.meta.maxTime == written.maxTime)
        #expect(r.meta.stats.numSeries == 3)
        #expect(r.meta.stats.numChunks == 4)
        #expect(r.meta.version == 1)

        // The premise of the test: more than one segment, so a file index is not trivially 0.
        #expect(try ChunkReader(fs: fs, dir: "b1/chunks").segmentNames.count > 1)

        #expect(r.labelNames() == ["__name__", "job", "le"])
        #expect(try r.labelValues("__name__") == ["http_requests", "up"])
        #expect(try r.labelValues("job") == ["api", "web"])

        let ids = try r.postings(name: "job", values: ["api", "web"])
        #expect(ids.count == 3)

        for (i, id) in ids.enumerated() {
            let s = try r.series(id)
            let want = sampleSeries[i]
            #expect(
                s.labels.map(\.name) == want.labels.map(\.name), "series \(i): label names")
            #expect(
                s.labels.map(\.value) == want.labels.map(\.value), "series \(i): label values")
            #expect(s.chunks.count == want.chunks.count, "series \(i): chunk count")

            let wantSamples = want.chunks.flatMap { $0 }
            let got = try r.samples(id)
            #expect(got.count == wantSamples.count, "series \(i): sample count")
            for (j, (g, w)) in zip(got, wantSamples).enumerated() {
                #expect(g.t == w.t, "series \(i) sample \(j): timestamp")
                #expect(g.v.bitPattern == w.v.bitPattern, "series \(i) sample \(j): value")
            }
        }
    }

    /// The same block through a real directory, because `RealFS` is the half no corpus exercises.
    @Test("the same block round-trips on a real filesystem")
    func roundTripOnDisk() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("promblock-\(ProcessInfo.processInfo.processIdentifier)")
            .path
        let fs = RealFS()
        try fs.createDirectory(base)
        defer { try? fs.remove(base) }

        _ = try writeBlock(fs, dir: base + "/01ARZ3NDEKTSV4RRFFQ69G5FAV", series: sampleSeries,
            segmentSize: 256)
        let r = try BlockReader(fs: fs, dir: base + "/01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let ids = try r.postings(name: "__name__", values: ["http_requests", "up"])
        #expect(ids.count == 3)
        #expect(try r.samples(ids[2]).count == 5)
        #expect(try r.samples(ids[1]).count == 200)
    }

    /// Go's `readMetaFile` checks the version and nothing else, and it checks it BEFORE the index is
    /// touched — so a future block fails on its metadata rather than part-way through a parse.
    @Test("a future meta version is rejected, and rejected first")
    func rejectsFutureVersion() throws {
        let fs = InMemoryFS()
        _ = try writeBlock(fs, dir: "b2", series: sampleSeries, segmentSize: 4096)

        // Bump the version and delete the index: if the version were not checked first, the missing index
        // would be the error instead.
        let h = try fs.openForReading("b2/meta.json")
        let text = String(decoding: try h.read(offset: 0, length: h.size), as: UTF8.self)
        try h.close()
        let bumped = text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        #expect(bumped != text, "the version field's spelling changed — the test is not testing anything")
        try fs.remove("b2/index")
        let w = try fs.createFile("b2/meta.json")
        try w.append(Array(bumped.utf8))
        try w.close()

        #expect(throws: BlockError.unexpectedMetaVersion(2)) {
            _ = try BlockReader(fs: fs, dir: "b2")
        }
    }

    /// Unknown fields are IGNORED, because `json.Unmarshal` ignores them — a block from a newer Prometheus
    /// with an extra key still opens. This is the reason the reader is hand-written rather than `Codable`.
    @Test("an unknown meta field does not stop the block opening")
    func toleratesUnknownFields() throws {
        let fs = InMemoryFS()
        _ = try writeBlock(fs, dir: "b3", series: sampleSeries, segmentSize: 4096)

        let h = try fs.openForReading("b3/meta.json")
        let text = String(decoding: try h.read(offset: 0, length: h.size), as: UTF8.self)
        try h.close()
        let extended = text.replacingOccurrences(
            of: "{\n", with: "{\n\t\"somethingNew\": {\"nested\": [1, 2]},\n", options: [],
            range: text.startIndex..<text.index(text.startIndex, offsetBy: 2))
        let w = try fs.createFile("b3/meta.json")
        try w.append(Array(extended.utf8))
        try w.close()

        let r = try BlockReader(fs: fs, dir: "b3")
        #expect(r.meta.stats.numSeries == 3)
        #expect(try r.samples(try r.postings(name: "__name__", values: ["up"])[0]).count == 5)
    }
}
