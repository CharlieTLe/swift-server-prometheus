//===----------------------------------------------------------------------===//
// The Head's WAL REPLAY, pinned against the real `tsdb.Head` — `Init`, `loadMmappedChunks`, `loadWAL` and
// `resetSeriesWithMMappedChunks`.
//
// Every case builds a Head, writes samples through it, then opens a SECOND Head on the same directory and calls
// `Init`. The committed output is the state of BOTH, so the fixture asserts the contract §7f named directly:
//
//     a Head built by replaying a WAL == a Head built by appending the same samples
//
// The `equivalent` flag says whether the two agreed, and the cases where it is deliberately FALSE are the
// interesting ones: `minValidTime` discards the older samples, and a `minValidTime` past everything replays a
// full WAL into an empty head.
//
// See `oracle/suites_head_replay.go` for the case list, including why the unclean-shutdown cases never close
// the first head (two live chunk mappers on one directory make upstream's own writer panic).
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import PromIndex
import PromLabels
import PromRecord
import PromStorage
import PromTombstones
import PromWAL
import Testing

@testable import PromHead

// MARK: - Wire types

struct HWIn: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var phases: [[HRSample]]
    var closeFirst: Bool
    var minValidTime: Int64?
    var truncateBeforeClose: Int64?
    var deleteBeforeClose: [Int64]?
    var replayTwice: Bool?
    var corruptChunkFile: Bool?
    var cutSegmentBetweenPhases: Bool?
    var storeST: Bool?
}

struct HWSeriesOut: Codable, Equatable, Sendable {
    var labels: [String: String]
    var samples: [HRReadSample]
    var chunks: [HRChunkMeta]
}

struct HWHeadOut: Codable, Equatable, Sendable {
    var minTime: Int64
    var maxTime: Int64
    var numSeries: UInt64
    var numStale: UInt64
    var series: [HWSeriesOut]
    var tombstones: [HGTombstone]
    var chunkDirEntries: [String]
    var walSegments: [String]
    var initErr: String
}

struct HWOut: Codable, Equatable, Sendable {
    var original: HWHeadOut
    var replayed: HWHeadOut
    var again: HWHeadOut?
    var equivalent: Bool
}

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hbits(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }

@Suite("head: WAL replay, and the equivalence it has to preserve")
struct HeadReplayTests {

    /// Read a head the way the corpus does: every series, sorted by metric name, with its samples decoded and
    /// its chunk layout — but WITHOUT the chunk refs, because a replay may legitimately assign different series
    /// ids and the ref encodes one.
    static func readHead(_ head: Head, _ fs: InMemoryFS, initErr: String) -> HWHeadOut {
        var out = HWHeadOut(
            minTime: head.minTime(), maxTime: head.maxTime(), numSeries: head.seriesCount(),
            numStale: head.staleSeriesCount(), series: [], tombstones: [], chunkDirEntries: [],
            walSegments: [], initErr: initErr)

        let ir = head.index()
        if let cr = try? head.chunks() {
            let (allName, allValue) = allPostingsKey()
            if let p = try? ir.postings(name: allName, values: [allValue]),
                let refs = try? expandPostings(ir.sortedPostings(p))
            {
                for r in refs {
                    guard let (lset, metas) = try? ir.series(r) else { continue }
                    var so = HWSeriesOut(labels: lset.map(), samples: [], chunks: [])
                    for m in metas {
                        so.chunks.append(
                            HRChunkMeta(ref: 0, minTime: m.minTime, maxTime: m.maxTime))
                        guard let (chk, _) = try? cr.chunkOrIterable(meta: m), let chk else {
                            continue
                        }
                        let it = chk.iterator(nil)
                        while it.next() == .float {
                            let (t, v) = it.at()
                            so.samples.append(HRReadSample(t: t, v: hbits(v)))
                        }
                    }
                    out.series.append(so)
                }
            }
            try? cr.close()
        }
        try? ir.close()
        out.series.sort { ($0.labels["__name__"] ?? "") < ($1.labels["__name__"] ?? "") }

        let tr = head.tombstonesReader()
        try? tr.iter { ref, ivs in
            out.tombstones.append(
                HGTombstone(ref: ref.rawValue, intervals: ivs.map { [$0.mint, $0.maxt] }))
        }
        out.tombstones.sort { $0.ref < $1.ref }

        out.chunkDirEntries = ((try? fs.list("head/chunks_head")) ?? []).sorted()
        out.walSegments = ((try? fs.list("head/wal")) ?? []).sorted()
        return out
    }

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/replay.jsonl", FixtureCase<HWIn, HWOut>.self) { input in
            let fs = InMemoryFS()

            var lastWAL: WL?
            func newHead() throws -> Head {
                let opts = HeadOptions.default()
                opts.chunkDirRoot = "head"
                opts.chunkRange = input.chunkRange
                opts.samplesPerChunk = input.samplesPerChunk
                if input.storeST ?? false {
                    opts.enableSTStorage = true
                    opts.floatChunkEncoding = .xor2
                }
                let w = try WL(fs: fs, dir: "head/wal")
                lastWAL = w
                return try Head(fs: fs, wal: w, opts: opts)
            }

            // --- The original head -------------------------------------------------------------

            let h1 = try newHead()
            try h1.initialize(minValidTime: 0)
            for (pi, phase) in input.phases.enumerated() {
                let app = h1.appender()
                for s in phase {
                    try app.append(
                        ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: s.t,
                        v: fbits(s.v))
                }
                try app.commit()
                if (input.cutSegmentBetweenPhases ?? false) && pi < input.phases.count - 1 {
                    _ = try lastWAL!.nextSegment()
                }
            }
            if let t = input.truncateBeforeClose {
                try h1.truncate(mint: t)
            }
            if let d = input.deleteBeforeClose, d.count == 2 {
                try h1.delete(
                    mint: d[0], maxt: d[1], matchers: [try Matcher(.regexp, "__name__", ".*")])
            }

            var out = HWOut(
                original: Self.readHead(h1, fs, initErr: ""),
                replayed: HWHeadOut(
                    minTime: 0, maxTime: 0, numSeries: 0, numStale: 0, series: [], tombstones: [],
                    chunkDirEntries: [], walSegments: [], initErr: ""),
                again: nil, equivalent: false)

            if input.closeFirst {
                try h1.close()
                out.original.chunkDirEntries = ((try? fs.list("head/chunks_head")) ?? []).sorted()
            }

            if input.corruptChunkFile ?? false {
                // The HEADER stays intact: the mapper validates the magic number when it opens the directory,
                // so a wholly garbled file would fail construction instead of reaching `Init`.
                for name in ((try? fs.list("head/chunks_head")) ?? []) {
                    let path = "head/chunks_head/\(name)"
                    guard let h = try? fs.openForReading(path),
                        let b = try? h.read(offset: 0, length: h.size), b.count >= 8
                    else { continue }
                    try? h.close()
                    let corrupted = Array(b[0..<8]) + [UInt8](repeating: 0xff, count: b.count - 8)
                    let wh = try fs.createFile(path)
                    try wh.append(corrupted)
                    try wh.close()
                }
            }

            // --- The replayed head -------------------------------------------------------------

            let h2 = try newHead()
            var initErr = ""
            do { try h2.initialize(minValidTime: input.minValidTime ?? 0) } catch {
                initErr = String(describing: error)
            }
            out.replayed = Self.readHead(h2, fs, initErr: initErr)

            if input.replayTwice ?? false {
                let h3 = try newHead()
                var initErr3 = ""
                do { try h3.initialize(minValidTime: input.minValidTime ?? 0) } catch {
                    initErr3 = String(describing: error)
                }
                out.again = Self.readHead(h3, fs, initErr: initErr3)
                try? h3.close()
            }

            out.equivalent = out.original.series == out.replayed.series

            try? h2.close()
            // The unclean cases deliberately leave `h1` open — see the suite header.
            return out
        }
    }

    /// `mmMaxTime` is what stops a replay re-appending samples already in a chunk file, and it is the field the
    /// corpus can only see the consequences of. Asserted directly: after a replay of a CLOSED head, every series
    /// knows how far its m-mapped chunks reach, and a second replay adds nothing.
    @Test("mmMaxTime is set from the m-mapped chunks and stops the samples being replayed twice")
    func mmMaxTimeStopsDoubleCounting() throws {
        let fs = InMemoryFS()
        func newHead() throws -> Head {
            let opts = HeadOptions.default()
            opts.chunkDirRoot = "head"
            opts.chunkRange = 4000
            let w = try WL(fs: fs, dir: "head/wal")
            return try Head(fs: fs, wal: w, opts: opts)
        }

        let lset = Labels([Label("__name__", "a")])
        let h1 = try newHead()
        try h1.initialize(minValidTime: 0)
        let app = h1.appender()
        for i in 0..<12 {
            try app.append(
                ref: SeriesRef(rawValue: 0), labels: lset, t: Int64(i) * 1000, v: Double(i))
        }
        try app.commit()
        try h1.close()  // M-maps the two older chunks.

        let h2 = try newHead()
        try h2.initialize(minValidTime: 0)
        let s = h2.series.getByHash(hash: lset.goHash(), labels: lset)!
        // Two chunks came from the files, so `mmMaxTime` is the second one's maxTime — and the WAL's samples up
        // to that point were skipped rather than re-appended.
        #expect(s.mmappedChunks.count == 2)
        #expect(s.mmMaxTime == 7000)
        #expect(s.headChunks != nil)
        #expect(s.headChunks!.chunk.numSamples == 4)  // Only 8000..11000 came from the WAL.

        // Every sample is readable exactly once.
        let ir = h2.index()
        let cr = try h2.chunks()
        let (_, metas) = try ir.series(SeriesRef(rawValue: 1))
        var seen: [Int64] = []
        for m in metas {
            let (chk, _) = try cr.chunkOrIterable(meta: m)
            let it = chk!.iterator(nil)
            while it.next() == .float { seen.append(it.at().0) }
        }
        #expect(seen == (0..<12).map { Int64($0) * 1000 })
        try cr.close()
        try h2.close()
    }

    /// A DUPLICATE series record — the same label set under two refs — must not split the series in two. The
    /// replay records `multiRef[oldRef] = existingRef` and remaps every later record. The corpus cannot build
    /// such a WAL through the appender (it never writes a second series record for a label set it already has),
    /// so this writes the records by hand.
    @Test("a duplicate series record is remapped rather than split")
    func duplicateSeriesRecordIsRemapped() throws {
        let fs = InMemoryFS()
        let lset = Labels([Label("__name__", "a")])

        // A WAL with the series under ref 1, then again under ref 7, and samples under BOTH refs.
        let w = try WL(fs: fs, dir: "head/wal")
        let enc = RecordEncoder()
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: lset)]))
        try w.log(
            enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), st: 0, t: 1000, v: 1)]))
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 7), labels: lset)]))
        try w.log(
            enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 7), st: 0, t: 2000, v: 2)]))
        try w.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        try head.initialize(minValidTime: 0)

        // ONE series, with both samples.
        #expect(head.seriesCount() == 1)
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.ref.rawValue == 1)  // The first record won the ref.
        #expect(s.headChunks!.chunk.numSamples == 2)
        // And `lastSeriesID` moved to the HIGHEST ref the WAL named, so the next created series is 8.
        #expect(head.lastSeriesID == 7)
        let (next, _) = try head.getOrCreate(
            hash: Labels([Label("__name__", "b")]).goHash(),
            labels: Labels([Label("__name__", "b")]), pendingCommit: false)
        #expect(next.ref.rawValue == 8)
        try head.close()
    }

    /// The postings are built UNORDERED during replay and sorted once by `Init`'s deferred `EnsureOrder`, which
    /// only matters when the WAL names refs out of order — a checkpoint, or a compaction, does exactly that.
    @Test("replay sorts the postings even when the WAL names refs descending")
    func replaySortsPostings() throws {
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "head/wal")
        let enc = RecordEncoder()
        // Series records in DESCENDING ref order, each with a sample.
        for ref in [UInt64(9), 5, 2] {
            let lset = Labels([Label("__name__", "m"), Label("i", "\(ref)")])
            try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: ref), labels: lset)]))
            try w.log(
                enc.samples([RefSample(ref: HeadSeriesRef(rawValue: ref), st: 0, t: 1000, v: 1)]))
        }
        try w.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        try head.initialize(minValidTime: 0)

        // `Postings` is documented as ordered, and after `EnsureOrder` it is — even though the refs arrived 9,
        // 5, 2.
        let ir = head.index()
        let refs = try expandPostings(try ir.postings(name: "__name__", values: ["m"]))
        #expect(refs.map(\.rawValue) == [2, 5, 9])
        try head.close()
    }

    /// A WAL whose FIRST series ref is not 1 proves the replay uses the WAL's refs rather than allocating its
    /// own: a fresh allocation would give the series ref 1, and the sample record naming ref 7 would then be
    /// unknown and dropped.
    @Test("replay adopts the WAL's series refs rather than allocating new ones")
    func replayAdoptsWALRefs() throws {
        let fs = InMemoryFS()
        let lset = Labels([Label("__name__", "a")])
        let w = try WL(fs: fs, dir: "head/wal")
        let enc = RecordEncoder()
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 7), labels: lset)]))
        try w.log(
            enc.samples([
                RefSample(ref: HeadSeriesRef(rawValue: 7), st: 0, t: 1000, v: 1),
                RefSample(ref: HeadSeriesRef(rawValue: 7), st: 0, t: 2000, v: 2),
            ]))
        try w.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        try head.initialize(minValidTime: 0)

        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.ref.rawValue == 7)
        #expect(s.headChunks?.chunk.numSamples == 2)
        #expect(head.minTime() == 1000)
        #expect(head.maxTime() == 2000)
        try head.close()
    }

    /// A sample record naming a ref with no series record is COUNTED and skipped, not an error — a WAL whose
    /// series record was checkpointed away is the normal case. Written by hand for the same reason as above.
    @Test("a sample for an unknown series is skipped rather than failing the replay")
    func unknownSeriesRefIsSkipped() throws {
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "head/wal")
        let enc = RecordEncoder()
        // A sample under a ref no series record ever named.
        try w.log(
            enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 99), st: 0, t: 1000, v: 1)]))
        // And a tombstone for another unknown ref.
        try w.log(
            enc.tombstones([
                Stone(
                    ref: SeriesRef(rawValue: 42),
                    intervals: [DeletionInterval(mint: 0, maxt: 100)])
            ]))
        try w.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        try head.initialize(minValidTime: 0)  // Must not throw.

        #expect(head.seriesCount() == 0)
        #expect(head.tombstonesReader().total() == 0)
        // The head stays UNINITIALISED, because nothing was appended.
        #expect(head.initialized() == false)
        try head.close()
    }
}
