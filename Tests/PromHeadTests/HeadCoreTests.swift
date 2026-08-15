//===----------------------------------------------------------------------===//
// `NewHead` and the Head's accessors, pinned against the REAL `tsdb.NewHead` — no probe package.
//
// §7f(a)-(d) had to lift unexported upstream code to get a corpus; everything asked about here is exported, so
// `oracle/suites_head_core.go` drives upstream's own constructor. Three groups of cases: the two validation
// errors and the order they are checked in, the mutations `NewHead` performs on the options it was handed
// (which is why `HeadOptions` is a class), and what a fresh Head answers — including the inverted `Meta()`
// range that follows from `MinTime == MaxInt64` meaning "uninitialised".
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromBlock
import PromChunkEnc
import PromChunks
import PromFS
import PromIndex
import PromLabels
import PromStorage
import PromWAL
import Testing

@testable import PromHead

// MARK: - Wire types

struct HDOpts: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var stripeSize: Int
    var outOfOrderTimeWindow: Int64
    var outOfOrderCapMax: Int64
    var isolationDisabled: Bool?
    var enableExemplarStorage: Bool?
    var maxExemplars: Int64?
    var floatChunkEncoding: UInt8
    var chunkWriteBufferSize: Int
    var walReplayConcurrency: Int
    var enableSharding: Bool?
    var enableSTStorage: Bool?
    var seriesCallback: String?
}

struct HDIn: Codable, Sendable {
    var opts: HDOpts
    var withWAL: Bool?
    var walRecords: [String]?
    var setMinValidTime: Int64?
    var overlaps: [[Int64]]?
}

struct HDOptsAfter: Codable, Equatable, Sendable {
    var outOfOrderTimeWindow: Int64
    var maxExemplars: Int64
    var seriesCallbackSet: Bool
    var walReplayConcurrencyChanged: Bool
    var chunkPoolSet: Bool
    var useXOR2FloatEncoding: Bool
}

struct HDOut: Codable, Equatable, Sendable {
    var err: String
    var optsAfter: HDOptsAfter
    var minTime: Int64
    var maxTime: Int64
    var minOOOTime: Int64
    var maxOOOTime: Int64
    var numSeries: UInt64
    var numStaleSeries: UInt64
    var metaULID: String
    var metaMinTime: Int64
    var metaMaxTime: Int64
    var metaNumSeries: UInt64
    var string: String
    var size: Int64
    var appendableMinValidTime: Int64
    var appendableOK: Bool
    var overlaps: [Bool]
    var chunkDirEntries: [String]
    var rootEntries: [String]
    var closeErr: String
}

@Suite("head: NewHead, its option normalisation and a fresh Head's answers")
struct HeadCoreTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/core.jsonl", FixtureCase<HDIn, HDOut>.self) { input in
            let fs = InMemoryFS()

            let opts = HeadOptions.default()
            opts.chunkDirRoot = "head"
            opts.chunkRange = input.opts.chunkRange
            opts.samplesPerChunk = input.opts.samplesPerChunk
            opts.stripeSize = input.opts.stripeSize
            opts.outOfOrderTimeWindow = input.opts.outOfOrderTimeWindow
            opts.outOfOrderCapMax = input.opts.outOfOrderCapMax
            opts.isolationDisabled = input.opts.isolationDisabled ?? false
            opts.enableExemplarStorage = input.opts.enableExemplarStorage ?? false
            opts.maxExemplars = input.opts.maxExemplars ?? 0
            opts.floatChunkEncoding = Encoding(rawValue: input.opts.floatChunkEncoding)
            opts.chunkWriteBufferSize = input.opts.chunkWriteBufferSize
            opts.chunkWriteQueueSize = 0
            opts.walReplayConcurrency = input.opts.walReplayConcurrency
            opts.enableSharding = input.opts.enableSharding ?? false
            opts.enableSTStorage = input.opts.enableSTStorage ?? false
            if input.opts.seriesCallback == "nil" {
                opts.seriesCallback = nil
            }
            let concurrencyBefore = opts.walReplayConcurrency

            var out = HDOut(
                err: "",
                optsAfter: HDOptsAfter(
                    outOfOrderTimeWindow: 0, maxExemplars: 0, seriesCallbackSet: false,
                    walReplayConcurrencyChanged: false, chunkPoolSet: false,
                    useXOR2FloatEncoding: false),
                minTime: 0, maxTime: 0, minOOOTime: 0, maxOOOTime: 0,
                numSeries: 0, numStaleSeries: 0,
                metaULID: "", metaMinTime: 0, metaMaxTime: 0, metaNumSeries: 0,
                string: "", size: 0,
                appendableMinValidTime: 0, appendableOK: false,
                overlaps: [], chunkDirEntries: [], rootEntries: [], closeErr: "")

            var wal: WL?
            if input.withWAL ?? false {
                let w = try WL(fs: fs, dir: "head/wal")
                for rec in input.walRecords ?? [] {
                    try w.log(RLEHex.decode(rec))
                }
                wal = w
            }

            let head: Head
            do {
                head = try Head(fs: fs, wal: wal, opts: opts)
            } catch {
                out.err = String(describing: error)
                try? wal?.close()
                return out
            }

            out.optsAfter = HDOptsAfter(
                outOfOrderTimeWindow: opts.outOfOrderTimeWindow,
                maxExemplars: opts.maxExemplars,
                seriesCallbackSet: opts.seriesCallback != nil,
                walReplayConcurrencyChanged: opts.walReplayConcurrency != concurrencyBefore,
                // Go fills in `chunkenc.NewPool()` when the option is nil. PORTING.md exception 4 drops the
                // pools, so the port has no field to fill and answers Go's post-fill truth.
                chunkPoolSet: true,
                useXOR2FloatEncoding: opts.useXOR2FloatEncoding())

            if let mvt = input.setMinValidTime {
                head.setMinValidTime(mvt)
            }

            out.minTime = head.minTime()
            out.maxTime = head.maxTime()
            out.minOOOTime = head.minOOOTime()
            out.maxOOOTime = head.maxOOOTime()
            out.numSeries = head.seriesCount()
            out.numStaleSeries = head.staleSeriesCount()

            let meta = head.meta()
            out.metaULID = meta.ulid.description
            out.metaMinTime = meta.minTime
            out.metaMaxTime = meta.maxTime
            out.metaNumSeries = meta.stats.numSeries

            out.string = head.description
            out.size = head.size()

            let (amvt, ok) = head.appendableMinValidTimeIfInitialized()
            out.appendableMinValidTime = amvt
            out.appendableOK = ok

            for iv in input.overlaps ?? [] {
                out.overlaps.append(head.overlapsClosedInterval(mint: iv[0], maxt: iv[1]))
            }

            out.chunkDirEntries = ((try? fs.list("head/chunks_head")) ?? []).sorted()
            out.rootEntries = ((try? fs.list("head")) ?? []).sorted()

            do { try head.close() } catch { out.closeErr = String(describing: error) }

            return out
        }
    }

    /// `compactable` and `initialized` are unexported upstream and only move once samples exist, so the
    /// corpus above cannot reach them — the appender slice's will. What CAN be pinned here is the arithmetic,
    /// and the part worth pinning is that it divides FIRST: `chunkRange/2*3`, so an odd range loses a
    /// millisecond rather than gaining half of one.
    @Test("compactable needs 1.5 chunk ranges, and the division comes first")
    func compactableArithmetic() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 3  // 3/2*3 == 3, where 3*3/2 would be 4.
        let head = try Head(fs: fs, opts: opts)

        // Uninitialised: false through the guard, not through the arithmetic.
        #expect(head.initialized() == false)
        #expect(head.compactable() == false)

        head.updateMinMaxTime(mint: 0, maxt: 3)
        #expect(head.initialized())
        #expect(head.compactable() == false)  // 3 - 0 > 3 is false.

        head.updateMinMaxTime(mint: 0, maxt: 4)
        #expect(head.compactable())  // 4 - 0 > 3.
        try head.close()
    }

    /// `updateMinMaxTime` only ever WIDENS, and the two halves are independent — a commit whose samples are
    /// all older than `maxTime` moves `minTime` alone. Unexported upstream; pinned here because the appender
    /// depends on it and its corpus reads the result rather than the transitions.
    @Test("updateMinMaxTime widens in each direction independently")
    func updateMinMaxTimeWidens() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)

        head.updateMinMaxTime(mint: 100, maxt: 200)
        #expect((head.minTime(), head.maxTime()) == (100, 200))

        // Inside the window: nothing moves.
        head.updateMinMaxTime(mint: 150, maxt: 150)
        #expect((head.minTime(), head.maxTime()) == (100, 200))

        // Older only.
        head.updateMinMaxTime(mint: 50, maxt: 60)
        #expect((head.minTime(), head.maxTime()) == (50, 200))

        // Newer only.
        head.updateMinMaxTime(mint: 300, maxt: 400)
        #expect((head.minTime(), head.maxTime()) == (50, 400))
        try head.close()
    }

    /// `getOrCreate` allocates a PRE-incremented ID, so the first series is 1 — and it consumes an ID even
    /// when the series turns out to exist, which upstream's own comment calls out as wasted. Both facts are
    /// unexported upstream and become corpus-visible in the appender slice; asserted here because
    /// `getOrCreateWithOptionalID` is written now.
    @Test("series IDs start at 1, and a redundant allocation is wasted rather than reused")
    func getOrCreateAllocatesIDs() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)

        let a = Labels([Label("__name__", "a")])
        let b = Labels([Label("__name__", "b")])

        let (s1, created1) = try head.getOrCreate(hash: a.goHash(), labels: a, pendingCommit: false)
        #expect(created1)
        #expect(s1.ref.rawValue == 1)

        // The hash lookup short-circuits before any allocation.
        let (s1again, created1again) = try head.getOrCreate(
            hash: a.goHash(), labels: a, pendingCommit: false)
        #expect(created1again == false)
        #expect(s1again.ref.rawValue == 1)

        let (s2, created2) = try head.getOrCreate(hash: b.goHash(), labels: b, pendingCommit: false)
        #expect(created2)
        #expect(s2.ref.rawValue == 2)
        #expect(head.seriesCount() == 2)

        // Going through `getOrCreateWithOptionalID` with a hash that is already set BURNS an ID: the
        // allocation happens before `setUnlessAlreadySet` reports the series exists.
        let (s1third, created1third) = try head.getOrCreateWithOptionalID(
            id: HeadSeriesRef(rawValue: 0), hash: a.goHash(), labels: a, pendingCommit: false)
        #expect(created1third == false)
        #expect(s1third.ref.rawValue == 1)
        let (s3, _) = try head.getOrCreate(
            hash: Labels([Label("__name__", "c")]).goHash(),
            labels: Labels([Label("__name__", "c")]), pendingCommit: false)
        #expect(s3.ref.rawValue == 4)  // 3 was burned above.

        // An explicit ID is used as given, and it does NOT move the counter — which is what WAL replay needs.
        let d = Labels([Label("__name__", "d")])
        let (s99, created99) = try head.getOrCreateWithOptionalID(
            id: HeadSeriesRef(rawValue: 99), hash: d.goHash(), labels: d, pendingCommit: false)
        #expect(created99)
        #expect(s99.ref.rawValue == 99)
        let e = Labels([Label("__name__", "e")])
        let (s5, _) = try head.getOrCreate(hash: e.goHash(), labels: e, pendingCommit: false)
        #expect(s5.ref.rawValue == 5)

        try head.close()
    }

    /// The options that only show up in the objects `NewHead` builds: the stripe count, and postings that are
    /// deliberately UNORDERED because replay adds refs in segment order and `Init` sorts afterwards.
    @Test("NewHead passes the stripe size through and builds unordered postings")
    func constructionUsesOptions() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.stripeSize = 4
        let head = try Head(fs: fs, opts: opts)
        #expect(head.series.size == 4)

        // Unordered postings do NOT repair on insert, so `all()` comes back in insertion order. An ordered
        // `MemPostings` would have sorted these.
        for (i, ref) in [UInt64(9), 3, 7].enumerated() {
            let lset = Labels([Label("__name__", "m"), Label("i", "\(i)")])
            _ = try head.getOrCreateWithOptionalID(
                id: HeadSeriesRef(rawValue: ref), hash: lset.goHash(), labels: lset,
                pendingCommit: false)
        }
        let refs = try expandPostings(head.postings.all()).map(\.rawValue)
        #expect(refs == [9, 3, 7])
        head.postings.ensureOrder()
        #expect(try expandPostings(head.postings.all()).map(\.rawValue) == [3, 7, 9])
        try head.close()
    }

    /// `appendableMinValidTime` is the max of two boundaries with different jobs, and it is only reachable
    /// once the head is initialised — which the corpus above cannot arrange, because nothing there appends.
    @Test("appendableMinValidTime takes the max of the compaction window and minValidTime")
    func appendableMinValidTimeBoundaries() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 1000
        let head = try Head(fs: fs, opts: opts)

        #expect(head.appendableMinValidTimeIfInitialized() == (0, false))

        // maxTime 10_000, chunkRange 1000: the compaction window ends at 10_000 - 500 = 9_500, which wins.
        head.updateMinMaxTime(mint: 0, maxt: 10_000)
        head.setMinValidTime(0)
        #expect(head.appendableMinValidTimeIfInitialized() == (9_500, true))

        // A minValidTime above the window wins instead.
        head.setMinValidTime(9_999)
        #expect(head.appendableMinValidTimeIfInitialized() == (9_999, true))

        // And below it, the window still wins — this is the pair that a `min` would get wrong.
        head.setMinValidTime(-1_000)
        #expect(head.appendableMinValidTimeIfInitialized() == (9_500, true))
        try head.close()
    }

    /// What `getOrCreate` does besides handing back a series: the count, the postings, the shard hash and both
    /// lifecycle callbacks. `Meta()` reads the count, so it is asserted here too.
    @Test("creating a series moves the count, the postings and Meta, and fires the callbacks")
    func seriesCreationSideEffects() throws {
        final class RecordingCallback: SeriesLifecycleCallback {
            var refuse: String?
            var created: [Labels] = []
            var deleted = 0
            func preCreation(_ labels: Labels) throws {
                if let refuse, labels.value(for: "__name__") == refuse {
                    throw HeadError.invalidSample
                }
            }
            func postCreation(_ labels: Labels) { created.append(labels) }
            func postDeletion(_: [HeadSeriesRef: Labels]) { deleted += 1 }
        }

        let fs = InMemoryFS()
        let cb = RecordingCallback()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.seriesCallback = cb
        let head = try Head(fs: fs, opts: opts)

        let a = Labels([Label("__name__", "a")])
        let (s, _) = try head.getOrCreate(hash: a.goHash(), labels: a, pendingCommit: false)
        #expect(head.seriesCount() == 1)
        #expect(head.meta().stats.numSeries == 1)
        #expect(cb.created.count == 1)
        #expect(try expandPostings(head.postings.all()).map(\.rawValue) == [1])
        // Sharding is off, so the shard hash is 0 rather than `StableHash(lset)`.
        #expect(s.shardHash == 0)

        // `preCreation` can REFUSE, and then no series exists — the failure propagates out of getOrCreate.
        cb.refuse = "b"
        let b = Labels([Label("__name__", "b")])
        #expect(throws: HeadError.invalidSample) {
            _ = try head.getOrCreate(hash: b.goHash(), labels: b, pendingCommit: false)
        }
        #expect(head.seriesCount() == 1)
        #expect(cb.created.count == 1)
        try head.close()

        // With sharding on, the shard hash is the stable hash.
        let opts2 = HeadOptions.default()
        opts2.chunkDirRoot = "head2"
        opts2.enableSharding = true
        let sharded = try Head(fs: fs, opts: opts2)
        let (s2, _) = try sharded.getOrCreate(hash: a.goHash(), labels: a, pendingCommit: false)
        #expect(s2.shardHash == a.stableHash())
        #expect(s2.shardHash != 0)
        try sharded.close()
    }

    /// `Close` m-maps before closing the mapper — upstream's comment says "in case we're performing snapshot
    /// since that only takes samples from most recent head chunk" — and closing the mapper is what FLUSHES the
    /// buffered bytes to the file. Both are observable in the chunk file after the fact.
    @Test("Close m-maps the tail and flushes the chunk file")
    func closeMmapsAndFlushes() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, opts: opts)

        let lset = Labels([Label("__name__", "a")])
        let (s, _) = try head.getOrCreate(hash: lset.goHash(), labels: lset, pendingCommit: false)
        let o = ChunkOpts(
            chunkDiskMapper: head.chunkDiskMapper, chunkRange: 4000,
            samplesPerChunk: opts.samplesPerChunk)
        for i in 0..<12 {
            let prev = s.headChunkCount
            s.append(st: 0, t: Int64(i) * 1000, v: Double(i), appendID: 0, o: o)
            head.onChunkCreated(series: s, prevHeadChunkCount: prev)
        }
        #expect(s.headChunkCount >= 2)
        #expect(s.mmappedChunks.isEmpty)

        try head.close()

        // The chunks the Head had in memory are on disk now, and the mapper's buffer reached the file.
        #expect(s.mmappedChunks.isEmpty == false)
        let names = ((try? fs.list("head/chunks_head")) ?? []).sorted()
        #expect(names == ["000001"])
        let h = try fs.openForReading("head/chunks_head/000001")
        let bytes = try h.read(offset: 0, length: h.size)
        try h.close()
        // The header is 8 bytes; anything past it is chunk data, which only a flush puts there.
        #expect(bytes.count > 8)
        #expect(bytes[8...].contains { $0 != 0 })
    }

    /// `mmapHeadChunks` skips a whole stripe whose `mmapReady` counter is zero, and re-checks each series
    /// inside it. Both tests are needed: the counter can be stale HIGH, because `truncateChunksBefore` reduces
    /// a series' chunk count without touching it.
    @Test("mmapHeadChunks needs both the stripe counter and the per-series count")
    func mmapHeadChunksUsesBothTests() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, opts: opts)

        let lset = Labels([Label("__name__", "a")])
        let (s, _) = try head.getOrCreate(hash: lset.goHash(), labels: lset, pendingCommit: false)
        let o = ChunkOpts(
            chunkDiskMapper: head.chunkDiskMapper, chunkRange: 4000,
            samplesPerChunk: opts.samplesPerChunk)

        // Nothing to m-map yet: one head chunk, and the stripe counter is still 0.
        for i in 0..<3 {
            let prev = s.headChunkCount
            s.append(st: 0, t: Int64(i) * 1000, v: Double(i), appendID: 0, o: o)
            head.onChunkCreated(series: s, prevHeadChunkCount: prev)
        }
        #expect(s.headChunkCount == 1)
        #expect(head.mmapHeadChunks() == 0)

        // Crossing into a second chunk is what bumps the stripe counter, once.
        for i in 4..<12 {
            let prev = s.headChunkCount
            s.append(st: 0, t: Int64(i) * 1000, v: Double(i), appendID: 0, o: o)
            head.onChunkCreated(series: s, prevHeadChunkCount: prev)
        }
        #expect(s.headChunkCount >= 2)
        #expect(head.series.mmapReadyTotal == 1)

        let n = head.mmapHeadChunks()
        #expect(n >= 1)
        #expect(s.headChunkCount == 1)
        #expect(head.series.mmapReadyTotal == 0)

        // A second call finds nothing, through the stripe counter rather than the per-series count.
        #expect(head.mmapHeadChunks() == 0)
        try head.close()
    }
}
