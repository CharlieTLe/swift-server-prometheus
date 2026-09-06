//===----------------------------------------------------------------------===//
// §7i(a) — `BlockWriter` and `LeveledCompactor`'s write path, pinned against the block upstream writes.
//
// `oracle/blockfixture.go` in reverse: the corpus is a block that a real `tsdb.BlockWriter` (or a real
// `tsdb.LeveledCompactor.Write`) produced, and the port has to produce the same bytes from the same samples.
// Four observables per case — the file bytes, the directory listing, the block read back, and `Flush`'s
// return — for the reasons `oracle/suites_block_write.go`'s header sets out.
//
// ## The ULID is injected, not reproduced
//
// Upstream names its block from the wall clock and `crypto/rand` with no seam (quirk 196), so the fixture
// SCRUBS the real identifier to a constant and the port is handed the same constant. See exception 27; the
// index and the chunk segments carry no ULID at all and are compared untouched.
//
// ## The `tombstones` file is the one declared difference
//
// `LeveledCompactor.write` finishes with `tombstones.WriteFile(…, NewMemTombstones())`, and the file codec is
// a separate slice (exception 26). Rather than let the block listing quietly differ, the port's listing has
// the name spliced back in by ``expectedBlockFiles`` — which is deliberately a named function with the
// exception number on it — and a second test asserts the port really does NOT write the file, so the splice
// cannot hide a change of behaviour later.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromBlock
import PromChunkEnc
import PromFS
import PromHead
import PromIndex
import PromLabels
import PromStorage
import Testing

@testable import PromCompact

// MARK: - Wire types

struct BWSample: Codable, Equatable, Sendable {
    var t: Int64
    var v: String
}

struct BWSeries: Codable, Sendable {
    var labels: [String: String]
    /// `appendSTZeroSample` before the samples — the only way to get a start timestamp into a chunk.
    var stZero: Int64?
    var samples: [BWSample]
}

struct BWDelete: Codable, Sendable {
    var matchers: [String]
    var mint: Int64
    var maxt: Int64
}

struct BWBase: Codable, Sendable {
    var ulid: String
    var minTime: Int64
    var maxTime: Int64
    var hints: [String]?
}

struct BWIn: Codable, Sendable {
    var mode: String
    var blockSize: Int64
    var samplesPerChunk: Int
    var useXOR2: Bool?
    var storeST: Bool?
    /// Optional because Go emits `null` for an empty slice.
    var series: [BWSeries]?
    var deletes: [BWDelete]?
    var fullRange: Bool?
    var mint: Int64?
    var maxt: Int64?
    var base: BWBase?
    var truncateBefore: Int64?
}

struct BWFile: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var bytes: String
}

struct BWChunkOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var minTime: Int64
    var maxTime: Int64
}

struct BWSeriesOut: Codable, Equatable, Sendable {
    var labels: [String: String]
    var chunks: [BWChunkOut]
    var samples: [BWSample]
}

struct BWOut: Codable, Equatable, Sendable {
    var flushErr: String
    var ulid: String
    var destEntries: [String]
    var blockFiles: [String]
    var metaJSON: String
    var indexBytes: String
    var chunkFiles: [BWFile]
    var openErr: String
    var series: [BWSeriesOut]
}

/// The ULID the fixture scrubbed every real one to. See the file header and exception 27.
private let pinnedBlockULID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

/// `DefaultBlockDuration`, spelled as the value it denotes rather than as `2 * 60 * 60 * 1000`.
///
/// HANDOFF §4: on the Swift 6.1 floor an untyped integer *expression* does not coerce inside an array
/// literal — `ranges: [2 * 60 * 60 * 1000]` is `cannot convert value of type 'Int' to expected element type
/// 'Int64'` there and compiles silently on 6.4. CI caught it; a named `Int64` is the fix.
let twoHoursMS: Int64 = 7_200_000

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func fhex(_ d: Double) -> String {
    let s = String(d.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

/// Splice `tombstones` into the port's block listing at the position upstream writes it.
///
/// **Exception 26.** `tsdb/tombstones`' `WriteFile`/`Encode` is not ported, so `LeveledCompactor.write` runs
/// with no ``TombstoneFileWriter`` installed and the block carries no `tombstones` file. `OpenBlock` tolerates
/// its absence — `ReadTombstones` answers an empty `MemTombstones` for a missing file — so the block is fully
/// readable; only the listing differs. `blockDirHasNoTombstonesFile` asserts the other side of this.
private func expectedBlockFiles(_ portFiles: [String]) -> [String] {
    if portFiles.isEmpty { return portFiles }
    return (portFiles + ["tombstones"]).sorted()
}

@Suite("compact: BlockWriter and LeveledCompactor.Write, byte for byte against upstream's block")
struct BlockWriteTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("block/write.jsonl", FixtureCase<BWIn, BWOut>.self) { input in
            try runCase(input)
        }
    }

    /// The other half of exception 26: the port writes no `tombstones` file, and that is asserted rather than
    /// only compensated for in ``expectedBlockFiles``.
    @Test("the port writes no tombstones file, which is exception 26")
    func blockDirHasNoTombstonesFile() throws {
        let fs = InMemoryFS()
        let w = try BlockWriter(
            fs: fs, dir: "dest", blockSize: twoHoursMS, chunkDir: "head",
            newULID: { ULID(pinnedBlockULID)! })
        let app = w.appender()
        _ = try app.append(ref: SeriesRef(rawValue: 0), labels: Labels(strings: "__name__", "a"), t: 1000, v: 1)
        try app.commit()
        let uid = try #require(try w.flush())
        try w.close()

        let names = try fs.list("dest/" + uid.description).sorted()
        #expect(names == ["chunks", "index", "meta.json"])
        #expect(!names.contains(tombstonesFilename))
    }

    /// `LeveledCompactor.write` refuses more than one reader rather than silently writing the first one.
    /// See ``CompactError/verticalCompactionUnported`` — merging is `storage/merge.go`'s and §7j's.
    @Test("more than one input reader is refused, not half-written")
    func verticalCompactionIsRefused() throws {
        let fs = InMemoryFS()
        var meta = BlockMeta(ulid: ULID(pinnedBlockULID)!, minTime: 0, maxTime: 10)
        let compactor = try LeveledCompactor(fs: fs, ranges: [twoHoursMS])
        let head = try makeHead(fs: fs, chunkDirRoot: "head", chunkRange: twoHoursMS)
        defer { try? head.close() }
        #expect(throws: (any Error).self) {
            try compactor.writeBlock(
                dest: "dest", meta: &meta, populator: DefaultBlockPopulator(),
                blocks: [HeadBlockReader(head), HeadBlockReader(head)])
        }
    }

    /// Go: `NewLeveledCompactorWithOptions`' one surviving validation.
    @Test("an empty range list is refused")
    func emptyRangesRefused() {
        let fs = InMemoryFS()
        #expect(throws: (any Error).self) { try LeveledCompactor(fs: fs, ranges: []) }
    }

    /// Go: `ExponentialBlockRanges(minSize, steps, stepSize)`, and the `db.go` default `(2h, 10, 3)`.
    @Test("exponentialBlockRanges matches Go's sequence")
    func exponentialRanges() {
        let got = exponentialBlockRanges(minSize: twoHoursMS, steps: 10, stepSize: 3)
        var want: [Int64] = []
        var cur = twoHoursMS
        for _ in 0..<10 {
            want.append(cur)
            cur *= 3
        }
        #expect(got == want)
        #expect(exponentialBlockRanges(minSize: 5, steps: 0, stepSize: 3) == [])
    }

    /// `ErrNoSeriesAppended` is declared in `blockwriter.go` and never returned by it. Quirk 203 — the check
    /// is that the port carries the string, not that anything raises it.
    @Test("ErrNoSeriesAppended carries Go's message")
    func noSeriesAppendedMessage() {
        #expect(BlockWriterError.noSeriesAppended.description == "no series appended, aborting")
    }
}

// MARK: - Driving one case

private func makeHead(
    fs: any PromFS, chunkDirRoot: String, chunkRange: Int64, samplesPerChunk: Int = 120,
    useXOR2: Bool = false, storeST: Bool = false
) throws -> Head {
    let opts = HeadOptions.default()
    opts.chunkDirRoot = chunkDirRoot
    opts.chunkRange = chunkRange
    opts.samplesPerChunk = samplesPerChunk
    if useXOR2 { opts.floatChunkEncoding = .xor2 }
    opts.enableSTStorage = storeST
    let head = try Head(fs: fs, wal: nil, opts: opts, stats: HeadStats())
    // `BlockWriter.initHead` does exactly this: a backfill accepts arbitrarily old samples.
    try head.initialize(minValidTime: Int64.min)
    return head
}

private func runCase(_ input: BWIn) throws -> BWOut {
    let fs = InMemoryFS()
    try fs.createDirectory("dest")

    var out = BWOut(
        flushErr: "", ulid: "", destEntries: [], blockFiles: [], metaJSON: "", indexBytes: "",
        chunkFiles: [], openErr: "", series: [])

    let pinned = ULID(pinnedBlockULID)!
    var uid: ULID?

    switch input.mode {
    case "blockwriter":
        uid = try runBlockWriter(fs: fs, input: input, pinned: pinned, out: &out)
    case "compactor":
        uid = try runCompactorWrite(fs: fs, input: input, pinned: pinned, out: &out)
    default:
        Issue.record("unknown mode \(input.mode)")
    }

    out.destEntries = ((try? fs.list("dest")) ?? []).sorted()
    if uid != nil {
        out.ulid = pinnedBlockULID
    }

    guard let uid else { return out }

    let blockDir = "dest/" + uid.description
    out.blockFiles = expectedBlockFiles(listBlockFiles(fs, blockDir))
    out.metaJSON = String(decoding: try readFile(fs, blockDir + "/meta.json"), as: UTF8.self)
    out.indexBytes = RLEHex.encode(try readFile(fs, blockDir + "/index"))
    for name in ((try? fs.list(blockDir + "/chunks")) ?? []).sorted() {
        let bytes = try readFile(fs, blockDir + "/chunks/" + name)
        out.chunkFiles.append(
            BWFile(name: name, size: bytes.count, bytes: RLEHex.encode(bytes)))
    }

    // Observable (3): read it back with the port's own block reader — §6m's `OpenBlock`.
    do {
        let block = try PromBlock.Block(fs: fs, dir: blockDir)
        let key = allPostingsKey()
        for ref in try block.postings(name: key.name, values: [key.value]) {
            let s = try block.series(ref)
            var so = BWSeriesOut(labels: [:], chunks: [], samples: [])
            for l in s.labels { so.labels[l.name] = l.value }
            for c in s.chunks {
                so.chunks.append(BWChunkOut(ref: c.ref, minTime: c.minTime, maxTime: c.maxTime))
            }
            for (t, v) in try block.samples(ref) {
                so.samples.append(BWSample(t: t, v: fhex(v)))
            }
            out.series.append(so)
        }
    } catch {
        out.openErr = "\(error)"
    }

    return out
}

private func runBlockWriter(
    fs: any PromFS, input: BWIn, pinned: ULID, out: inout BWOut
) throws -> ULID? {
    // `NewBlockWriter` takes only the block size: `SamplesPerChunk` and `FloatChunkEncoding` come from
    // `DefaultHeadOptions()` and are unreachable through it, exactly as in the oracle.
    let w = try BlockWriter(
        fs: fs, dir: "dest", blockSize: input.blockSize, chunkDir: "head",
        newULID: { pinned })
    let app = w.appender()
    for s in input.series ?? [] {
        for sm in s.samples {
            do {
                _ = try app.append(
                    ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: sm.t, v: fbits(sm.v))
            } catch {
                out.flushErr = "\(error)"
                try? w.close()
                return nil
            }
        }
    }
    do {
        try app.commit()
    } catch {
        out.flushErr = "\(error)"
        try? w.close()
        return nil
    }

    var uid: ULID?
    do {
        uid = try w.flush()
    } catch {
        out.flushErr = "\(error)"
    }
    do {
        try w.close()
    } catch {
        if out.flushErr.isEmpty { out.flushErr = "\(error)" }
    }
    return uid
}

private func runCompactorWrite(
    fs: any PromFS, input: BWIn, pinned: ULID, out: inout BWOut
) throws -> ULID? {
    let head = try makeHead(
        fs: fs, chunkDirRoot: "head", chunkRange: input.blockSize,
        samplesPerChunk: input.samplesPerChunk, useXOR2: input.useXOR2 ?? false,
        storeST: input.storeST ?? false)
    defer { try? head.close() }

    let app = head.appender()
    for s in input.series ?? [] {
        if let st = s.stZero, let first = s.samples.first,
            let sta = app as? any StartTimestampAppender
        {
            let (_, err) = sta.appendSTZeroSample(
                ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: first.t, st: st)
            if let err {
                out.flushErr = "\(err)"
                try? app.rollback()
                return nil
            }
        }
        for sm in s.samples {
            do {
                _ = try app.append(
                    ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: sm.t, v: fbits(sm.v))
            } catch {
                out.flushErr = "\(error)"
                try? app.rollback()
                return nil
            }
        }
    }
    do {
        try app.commit()
    } catch {
        out.flushErr = "\(error)"
        return nil
    }

    for d in input.deletes ?? [] {
        let matchers = try d.matchers.map { m -> Matcher in
            let parts = m.split(separator: "=", maxSplits: 1).map(String.init)
            return try Matcher(.equal, parts[0], parts[1])
        }
        do {
            try head.delete(mint: d.mint, maxt: d.maxt, matchers: matchers)
        } catch {
            out.flushErr = "\(error)"
            return nil
        }
    }

    if let tb = input.truncateBefore {
        do {
            try head.truncate(mint: tb)
        } catch {
            out.flushErr = "\(error)"
            return nil
        }
    }

    var mint = input.mint ?? 0
    var maxt = input.maxt ?? 0
    if input.fullRange ?? false {
        mint = head.minTime()
        maxt = head.maxTime() &+ 1
    }

    var options = LeveledCompactorOptions()
    options.newULID = { pinned }
    let compactor = try LeveledCompactor(fs: fs, ranges: [input.blockSize], options: options)

    var base: BlockMeta?
    if let b = input.base {
        var m = BlockMeta(ulid: ULID(b.ulid)!, minTime: b.minTime, maxTime: b.maxTime)
        m.compaction.hints = b.hints ?? []
        base = m
    }

    do {
        let ids = try compactor.write(
            dest: "dest", block: HeadBlockReader(head), mint: mint, maxt: maxt, base: base)
        return ids.first
    } catch {
        out.flushErr = "\(error)"
        return nil
    }
}

private func listBlockFiles(_ fs: any PromFS, _ blockDir: String) -> [String] {
    var names: [String] = []
    for name in (try? fs.list(blockDir)) ?? [] {
        if let children = try? fs.list(blockDir + "/" + name) {
            for c in children { names.append(name + "/" + c) }
        } else {
            names.append(name)
        }
    }
    return names.sorted()
}

private func readFile(_ fs: any PromFS, _ path: String) throws -> [UInt8] {
    let h = try fs.openForReading(path)
    defer { try? h.close() }
    return try h.read(offset: 0, length: h.size)
}
