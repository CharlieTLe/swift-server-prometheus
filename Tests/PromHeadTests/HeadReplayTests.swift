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
    var truncateTwice: Int64?
    var deleteBeforeClose: [Int64]?
    var deleteAfterPhase: Int?
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

/// One record from the checkpoint, decoded. The `files` bytes are the contract; this is the same thing in a
/// form a failure message can be read — which is what makes "the checkpoint kept a series record for a series
/// the head no longer has" legible rather than buried in hex.
///
/// The three payload arrays are OPTIONAL because Go's `omitempty` drops them when empty, so a record with no
/// entries must decode to `nil` here rather than `[]` or the `==` comparison fails.
struct HWCPRecord: Codable, Equatable, Sendable {
    var type: String
    var series: [String]?
    var samples: [String]?
    var stones: [String]?
}

struct HWCheckpointOut: Codable, Equatable, Sendable {
    var name: String
    var files: [HAFileOut]
    var records: [HWCPRecord]
}

struct HWOut: Codable, Equatable, Sendable {
    var original: HWHeadOut
    var replayed: HWHeadOut
    var again: HWHeadOut?
    var checkpoint: HWCheckpointOut?
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

    /// The checkpoint directory, if the truncation wrote one, read through the same reader `Init` uses — which
    /// is the point: a checkpoint is a WAL directory and nothing special is needed to open one.
    ///
    /// The LAST `checkpoint.*` is the one taken, matching Go's sorted `ReadDir` walk. Normally there is only
    /// one, because `truncateWAL` deletes the checkpoints it supersedes; a second would show up in
    /// `walSegments` rather than being hidden here.
    static func readCheckpoint(_ fs: InMemoryFS) -> HWCheckpointOut? {
        let names = ((try? fs.list("head/wal")) ?? []).sorted()
        guard let name = names.last(where: { $0.hasPrefix("checkpoint.") }) else { return nil }
        let cpdir = "head/wal/\(name)"
        var out = HWCheckpointOut(
            name: name, files: HeadAppendTests.readDir(fs, cpdir), records: [])

        guard let sr = try? newWALSegmentsReader(fs, cpdir) else { return out }
        let r = WALReader(sr)
        var dec = RecordDecoder()
        while r.next() {
            let rec = r.record
            var cr = HWCPRecord(type: recordType(rec).description)
            switch recordType(rec) {
            case .series:
                let ss = (try? dec.series(rec)) ?? []
                cr.series = ss.isEmpty ? nil : ss.map { "\($0.ref.rawValue)=\($0.labels)" }
            case .samples, .samplesV2:
                let ss = (try? dec.samples(rec)) ?? []
                cr.samples =
                    ss.isEmpty
                    ? nil : ss.map { "\($0.ref.rawValue)@\($0.t)=\(hbits($0.v))" }
            case .tombstones:
                let ts = (try? dec.tombstones(rec)) ?? []
                // Go prints `tombstones.Intervals` with `%v`, so a stone reads `1:[{9000 11000}]`.
                cr.stones =
                    ts.isEmpty
                    ? nil
                    : ts.map { stone in
                        let ivs = stone.intervals.map { "{\($0.mint) \($0.maxt)}" }
                            .joined(separator: " ")
                        return "\(stone.ref.rawValue):[\(ivs)]"
                    }
            default:
                break
            }
            out.records.append(cr)
        }
        try? sr.close()
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
            func deleteAll() throws {
                let d = input.deleteBeforeClose!
                try h1.delete(
                    mint: d[0], maxt: d[1], matchers: [try Matcher(.regexp, "__name__", ".*")])
            }
            for (pi, phase) in input.phases.enumerated() {
                let app = h1.appender()
                for s in phase {
                    try app.append(
                        ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: s.t,
                        v: fbits(s.v))
                }
                try app.commit()
                if input.deleteAfterPhase == pi {
                    try deleteAll()
                }
                if (input.cutSegmentBetweenPhases ?? false) && pi < input.phases.count - 1 {
                    _ = try lastWAL!.nextSegment()
                }
            }
            if let t = input.truncateBeforeClose {
                try h1.truncate(mint: t)
            }
            if let t = input.truncateTwice {
                try h1.truncate(mint: t)
            }
            if let d = input.deleteBeforeClose, d.count == 2, input.deleteAfterPhase == nil {
                try deleteAll()
            }

            var out = HWOut(
                original: Self.readHead(h1, fs, initErr: ""),
                replayed: HWHeadOut(
                    minTime: 0, maxTime: 0, numSeries: 0, numStale: 0, series: [], tombstones: [],
                    chunkDirEntries: [], walSegments: [], initErr: ""),
                again: nil, checkpoint: Self.readCheckpoint(fs), equivalent: false)

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

    // MARK: - §7h(c): truncateWAL, the two-thirds rule, and the WAL expiries

    /// Build a head on `fs` with `chunkRange` 4000 and a real WAL.
    private static func newTruncHead(_ fs: InMemoryFS) throws -> Head {
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        return try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
    }

    /// `updateWALExpiry` takes the MAXIMUM, never lowering an expiry already set — a duplicate series record's
    /// later samples can only extend how long its record must be kept. And an absent ref answers `(0, false)`,
    /// where the flag rather than the zero is what `keepSeriesInWALCheckpointFn` reads.
    ///
    /// Unreachable from the corpus: `gc` only ever writes one expiry per series per truncation, so no case
    /// writes the same ref twice.
    @Test("updateWALExpiry takes the max, and an absent ref reports not-found rather than zero")
    func walExpiryTakesTheMax() throws {
        let fs = InMemoryFS()
        let head = try Self.newTruncHead(fs)
        let ref = HeadSeriesRef(rawValue: 7)

        var (keepUntil, ok) = head.walExpiry(ref)
        #expect(keepUntil == 0)
        #expect(ok == false)

        head.updateWALExpiry(ref, keepUntil: 5000)
        (keepUntil, ok) = head.walExpiry(ref)
        #expect(keepUntil == 5000)
        #expect(ok == true)

        // Lower: ignored.
        head.updateWALExpiry(ref, keepUntil: 1000)
        #expect(head.walExpiry(ref).0 == 5000)
        // Higher: taken.
        head.updateWALExpiry(ref, keepUntil: 9000)
        #expect(head.walExpiry(ref).0 == 9000)
        // A negative expiry on a fresh ref is stored as itself, not clamped to zero — the `Int64.min` seed is
        // what makes that work, and `0` would have swallowed it.
        head.updateWALExpiry(HeadSeriesRef(rawValue: 8), keepUntil: -50)
        #expect(head.walExpiry(HeadSeriesRef(rawValue: 8)) == (-50, true))
        try head.close()
    }

    /// `keepSeriesInWALCheckpointFn`'s two arms, in isolation. The corpus reaches both through `Truncate`, but
    /// only in combination; here each is on its own, including the boundary — the expiry test is `>= mint`, so a
    /// series whose samples end exactly at the truncation point keeps its record.
    @Test("a series record is kept because the series exists, or because its expiry has not passed")
    func keepSeriesBothArms() throws {
        let fs = InMemoryFS()
        let head = try Self.newTruncHead(fs)
        try head.initialize(minValidTime: 0)
        let app = head.appender()
        try app.append(
            ref: SeriesRef(rawValue: 0), labels: Labels([Label("__name__", "live")]), t: 1000, v: 1)
        try app.commit()
        let live = head.series.getByHash(
            hash: Labels([Label("__name__", "live")]).goHash(),
            labels: Labels([Label("__name__", "live")]))!

        let keep = head.keepSeriesInWALCheckpointFn(mint: 5000)
        // First arm: the series is in the head, and no expiry is needed.
        #expect(keep(live.ref) == true)
        #expect(head.walExpiry(live.ref).1 == false)
        // Neither arm: gone from the head, no expiry.
        #expect(keep(HeadSeriesRef(rawValue: 99)) == false)
        // Second arm, at the boundary and either side of it.
        head.updateWALExpiry(HeadSeriesRef(rawValue: 99), keepUntil: 5000)
        #expect(keep(HeadSeriesRef(rawValue: 99)) == true)
        head.walExpiries[HeadSeriesRef(rawValue: 99)] = 4999
        #expect(keep(HeadSeriesRef(rawValue: 99)) == false)
        try head.close()
    }

    /// The two-thirds rule at its threshold. `last` is decremented first — the live segment is never
    /// checkpointed — and then `first + (last-first)*2/3` has to come out ABOVE `first` for the checkpoint to be
    /// worth writing. With `first == 0` that needs FOUR segments: three gives `(2-1)*2/3 == 0`.
    ///
    /// The corpus has the five-segment case and the one-segment case; this is the boundary between them, which
    /// no corpus case sits on.
    @Test("three segments is not enough for a checkpoint and four is")
    func twoThirdsRuleThreshold() throws {
        for (segments, wantCheckpoint) in [(3, false), (4, true)] {
            let fs = InMemoryFS()
            let head = try Self.newTruncHead(fs)
            try head.initialize(minValidTime: 0)
            // One phase per segment, so every segment has records in it.
            for s in 0..<segments {
                let app = head.appender()
                try app.append(
                    ref: SeriesRef(rawValue: 0), labels: Labels([Label("__name__", "m")]),
                    t: Int64(s) * 4000, v: Double(s))
                try app.commit()
                if s < segments - 1 {
                    _ = try head.wal!.nextSegment()
                }
            }

            try head.truncateWAL(mint: 4000)
            let names = ((try? fs.list("head/wal")) ?? []).sorted()
            let checkpoints = names.filter { $0.hasPrefix("checkpoint.") }
            if wantCheckpoint {
                // last = 3, decremented to 2, `0 + 2*2/3 = 1` — so segments 0 and 1, and `Truncate(2)`.
                #expect(checkpoints == ["checkpoint.00000001"])
                #expect(names.filter { !$0.hasPrefix("checkpoint.") } == ["00000002", "00000003", "00000004"])
            } else {
                #expect(checkpoints.isEmpty)
                // A new segment is cut EITHER WAY: that happens before the rule is consulted.
                #expect(names == ["00000000", "00000001", "00000002", "00000003"])
            }
            try head.close()
        }
    }

    /// `mint <= lastWALTruncationTime` is the idempotence guard, and it is why `Truncate` can be called on every
    /// tick. A second truncation at the same point does nothing at all — not even cut a segment.
    @Test("a truncation at or below the last one does nothing, not even cut a segment")
    func truncateWALIsIdempotent() throws {
        let fs = InMemoryFS()
        let head = try Self.newTruncHead(fs)
        try head.initialize(minValidTime: 0)
        let app = head.appender()
        try app.append(
            ref: SeriesRef(rawValue: 0), labels: Labels([Label("__name__", "m")]), t: 1000, v: 1)
        try app.commit()

        try head.truncateWAL(mint: 2000)
        #expect(head.lastWALTruncationTime == 2000)
        let after = ((try? fs.list("head/wal")) ?? []).sorted()
        #expect(after == ["00000000", "00000001"])

        try head.truncateWAL(mint: 2000)  // Equal: refused.
        try head.truncateWAL(mint: 1000)  // Lower: refused.
        #expect(((try? fs.list("head/wal")) ?? []).sorted() == after)
        #expect(head.lastWALTruncationTime == 2000)

        try head.truncateWAL(mint: 3000)  // Higher: another segment.
        #expect(((try? fs.list("head/wal")) ?? []).sorted() == ["00000000", "00000001", "00000002"])
        try head.close()
    }

    /// The expiries are pruned at the END of `truncateWAL`, after the checkpoint — the order is the whole point,
    /// because the checkpoint is what makes the expiry unnecessary. Only expiries strictly BELOW `mint` go, so
    /// one exactly at `mint` survives to be read by the next checkpoint.
    ///
    /// And they are pruned ONLY when a checkpoint was written: every early return above sits before the prune,
    /// so a truncation that declined to checkpoint leaves every expiry in place. Both halves are asserted here,
    /// because the difference is what stops a series record being dropped before its samples are gone.
    @Test("truncateWAL prunes the expiries below mint, and only once it has written a checkpoint")
    func expiriesArePrunedAfterTheCheckpoint() throws {
        // Four segments, so the two-thirds rule fires.
        func seed(_ head: Head) throws {
            try head.initialize(minValidTime: 0)
            for s in 0..<4 {
                let app = head.appender()
                try app.append(
                    ref: SeriesRef(rawValue: 0), labels: Labels([Label("__name__", "m")]),
                    t: Int64(s) * 4000, v: Double(s))
                try app.commit()
                if s < 3 { _ = try head.wal!.nextSegment() }
            }
            head.updateWALExpiry(HeadSeriesRef(rawValue: 10), keepUntil: 1999)
            head.updateWALExpiry(HeadSeriesRef(rawValue: 11), keepUntil: 2000)
            head.updateWALExpiry(HeadSeriesRef(rawValue: 12), keepUntil: 2001)
        }

        let fs = InMemoryFS()
        let head = try Self.newTruncHead(fs)
        try seed(head)
        try head.truncateWAL(mint: 2000)
        #expect(((try? fs.list("head/wal")) ?? []).contains("checkpoint.00000001"))
        #expect(head.walExpiries.keys.map(\.rawValue).sorted() == [11, 12])
        try head.close()

        // The same expiries, but a truncation that returns before checkpointing: nothing is pruned.
        let fs2 = InMemoryFS()
        let head2 = try Self.newTruncHead(fs2)
        try head2.initialize(minValidTime: 0)
        let app = head2.appender()
        try app.append(
            ref: SeriesRef(rawValue: 0), labels: Labels([Label("__name__", "m")]), t: 1000, v: 1)
        try app.commit()
        head2.updateWALExpiry(HeadSeriesRef(rawValue: 10), keepUntil: 1999)
        try head2.truncateWAL(mint: 2000)
        #expect(((try? fs2.list("head/wal")) ?? []).allSatisfy { !$0.hasPrefix("checkpoint.") })
        #expect(head2.walExpiries.keys.map(\.rawValue) == [10])
        try head2.close()
    }

    /// `Init` replays the CHECKPOINT first and then only the segments above it, and the checkpoint's records are
    /// what carry a series whose live segment is gone. Driven directly rather than through `Truncate`, so the
    /// checkpoint's content is chosen rather than derived.
    @Test("Init reads the checkpoint before the segments, and skips the ones it covers")
    func initBackfillsTheCheckpoint() throws {
        let fs = InMemoryFS()
        let enc = RecordEncoder()
        let lset = Labels([Label("__name__", "m")])

        // Live segments 2 and 3 with the samples. Neither carries a series record — the checkpoint is the only
        // place the labels for ref 4 exist, so a replay that skipped it would drop these samples entirely.
        let w = try WL(fs: fs, dir: "head/wal")
        _ = try w.nextSegment()  // 1
        _ = try w.nextSegment()  // 2
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 4), t: 2000, v: 2)]))
        _ = try w.nextSegment()  // 3
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 4), t: 3000, v: 3)]))
        try w.close()
        // Segments 0 and 1 are the ones the checkpoint covers, so they are gone.
        try fs.remove("head/wal/00000000")
        try fs.remove("head/wal/00000001")

        // The checkpoint, holding the series record and the sample from the segments that went.
        let cp = try WL(fs: fs, dir: "head/wal/checkpoint.00000001")
        try cp.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 4), labels: lset)]))
        try cp.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 4), t: 1000, v: 1)]))
        try cp.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        try head.initialize(minValidTime: 0)

        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)
        #expect(s?.ref.rawValue == 4)
        // Every sample the checkpoint and the surviving segments hold, and each exactly once — the checkpoint's
        // t=1000 is not replayed a second time by a segment scan that started too low.
        var seen: [Int64] = []
        let ir = head.index()
        let cr = try head.chunks()
        if let s, let (_, metas) = try? ir.series(SeriesRef(rawValue: s.ref.rawValue)) {
            for m in metas {
                guard let (chk, _) = try? cr.chunkOrIterable(meta: m), let chk else { continue }
                let it = chk.iterator(nil)
                while it.next() == .float { seen.append(it.at().0) }
            }
        }
        #expect(seen == [1000, 2000, 3000])
        try cr.close()
        try head.close()
    }

    /// Upstream takes only `endAt` from `Segments` — `startFrom` is the CHECKPOINT's index, or 0. So a WAL whose
    /// oldest segment is above 0 with NO checkpoint asks for segment 0 and fails, rather than quietly starting
    /// at whatever is there. The port used the directory's first index before §7h(c) and this is what pins the
    /// difference; it is unreachable in normal operation, because `truncateWAL` always leaves a checkpoint
    /// behind when it removes segments.
    @Test("a WAL missing its low segments with no checkpoint fails rather than skipping them")
    func missingLowSegmentsWithoutACheckpointFails() throws {
        let fs = InMemoryFS()
        let enc = RecordEncoder()
        let w = try WL(fs: fs, dir: "head/wal")
        try w.log(
            enc.series([
                RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: Labels([Label("n", "a")]))
            ]))
        _ = try w.nextSegment()
        _ = try w.nextSegment()
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 1000, v: 1)]))
        try w.close()
        // Remove the low segments WITHOUT writing a checkpoint, which is the state `wlog.Truncate` alone leaves.
        try fs.remove("head/wal/00000000")
        try fs.remove("head/wal/00000001")

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        do {
            try head.initialize(minValidTime: 0)
            Issue.record("expected a missing-segment failure")
        } catch let e as HeadReplayError {
            #expect(e.description.hasPrefix("open WAL segment: 0: "))
        }
        try head.close()
    }

    /// A corrupt CHECKPOINT is a hard error, not a recovery: *"There's likely little data that can be recovered
    /// anyway"* — the head cannot know which series records it lost. Wrapped as `backfill checkpoint`.
    @Test("a corrupt checkpoint fails Init rather than being skipped")
    func corruptCheckpointFailsInit() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("head/wal")
        let cp = try WL(fs: fs, dir: "head/wal/checkpoint.00000000")
        // A `series` type byte the decoder cannot finish.
        try cp.log([RecordType.series.rawValue, 0x01, 0x02])
        try cp.close()

        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, wal: try WL(fs: fs, dir: "head/wal"), opts: opts)
        do {
            try head.initialize(minValidTime: 0)
            Issue.record("expected a backfill failure")
        } catch let e as HeadReplayError {
            #expect(e.description.hasPrefix("backfill checkpoint: "))
        }
        try head.close()
    }
}
