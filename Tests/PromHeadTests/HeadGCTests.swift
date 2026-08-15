//===----------------------------------------------------------------------===//
// The Head's GC and DELETION path, pinned against the real `tsdb.Head` — `Delete`, `Tombstones`, `Truncate`
// and the `stripeSeries.gc` under them.
//
// Every case is a program: appends, then `delete`/`truncate` operations, with the whole visible state committed
// after each one. The chunk metas are in that state on purpose — reading them after a truncation is what pins
// `firstChunkID`'s advance, so a ref handed out before the truncation still names the same chunk.
//
// See `oracle/suites_head_gc.go` for the case list, including why both series have to be appended in ONE phase.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import PromIndex
import PromLabels
import PromModel
import PromStorage
import PromTombstones
import PromWAL
import Testing

@testable import PromHead

// MARK: - Wire types

struct HGOp: Codable, Sendable {
    var op: String
    var mint: Int64?
    var maxt: Int64?
    var matcherKind: String?
    var truncateMint: Int64?
}

struct HGIn: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var phases: [[HRSample]]
    var ops: [HGOp]
    var withWAL: Bool?
}

struct HGTombstone: Codable, Equatable, Sendable {
    var ref: UInt64
    var intervals: [[Int64]]
}

struct HGSeriesOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var labels: [String: String]
    var chunks: [HRChunkMeta]
}

struct HGState: Codable, Equatable, Sendable {
    var minTime: Int64
    var maxTime: Int64
    var numSeries: UInt64
    var numStale: UInt64
    var appendableMinValidTime: Int64
    var appendableOK: Bool
    var tombstones: [HGTombstone]
    var tombstoneTotal: UInt64
    var series: [HGSeriesOut]
    var allPostings: [UInt64]
    var labelPostings: [[UInt64]]
    var chunkDirEntries: [String]
    var err: String
}

struct HGOut: Codable, Equatable, Sendable {
    var states: [HGState]
    var walFiles: [HAFileOut]
    var closeErr: String
}

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

/// The same fixed vocabulary the read suite uses.
private func hgMatchers(_ kind: String) -> [Matcher] {
    switch kind {
    case "": return []
    case "eq": return [try! Matcher(.equal, "job", "a")]
    case "neq": return [try! Matcher(.notEqual, "job", "a")]
    case "re": return [try! Matcher(.regexp, "__name__", "m.*")]
    case "all": return [try! Matcher(.regexp, "__name__", ".*")]
    default: fatalError("unknown matcher kind \(kind)")
    }
}

@Suite("head: garbage collection, deletion and truncation")
struct HeadGCTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/gc.jsonl", FixtureCase<HGIn, HGOut>.self) { input in
            let fs = InMemoryFS()
            let opts = HeadOptions.default()
            opts.chunkDirRoot = "head"
            opts.chunkRange = input.chunkRange
            opts.samplesPerChunk = input.samplesPerChunk

            var wal: WL?
            if input.withWAL ?? false {
                wal = try WL(fs: fs, dir: "head/wal")
            }
            let head = try Head(fs: fs, wal: wal, opts: opts)

            var out = HGOut(states: [], walFiles: [], closeErr: "")

            for phase in input.phases {
                let app = head.appender()
                for s in phase {
                    try app.append(
                        ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: s.t,
                        v: fbits(s.v))
                }
                try app.commit()
            }

            func snapshot(_ opErr: String) -> HGState {
                var st = HGState(
                    minTime: head.minTime(), maxTime: head.maxTime(), numSeries: head.seriesCount(),
                    numStale: head.staleSeriesCount(), appendableMinValidTime: 0, appendableOK: false,
                    tombstones: [], tombstoneTotal: 0, series: [], allPostings: [],
                    labelPostings: [], chunkDirEntries: [], err: opErr)
                (st.appendableMinValidTime, st.appendableOK) =
                    head.appendableMinValidTimeIfInitialized()

                let tr = head.tombstonesReader()
                try? tr.iter { ref, ivs in
                    st.tombstones.append(
                        HGTombstone(ref: ref.rawValue, intervals: ivs.map { [$0.mint, $0.maxt] }))
                }
                st.tombstoneTotal = tr.total()
                // `iter` ranges a dictionary here and a Go map upstream, so both sort before committing.
                st.tombstones.sort { $0.ref < $1.ref }

                let ir = head.index()
                let (allName, allValue) = allPostingsKey()
                if let p = try? ir.postings(name: allName, values: [allValue]),
                    let refs = try? expandPostings(ir.sortedPostings(p))
                {
                    st.allPostings = refs.map(\.rawValue)
                    for q in [("__name__", "m1"), ("__name__", "m2"), ("job", "a"), ("job", "b")] {
                        let lrefs =
                            (try? expandPostings(try ir.postings(name: q.0, values: [q.1]))) ?? []
                        st.labelPostings.append(lrefs.map(\.rawValue))
                    }
                    for r in refs {
                        guard let (lset, metas) = try? ir.series(r) else { continue }
                        st.series.append(
                            HGSeriesOut(
                                ref: r.rawValue, labels: lset.map(),
                                chunks: metas.map {
                                    HRChunkMeta(
                                        ref: $0.ref.rawValue, minTime: $0.minTime,
                                        maxTime: $0.maxTime)
                                }))
                    }
                }
                try? ir.close()

                st.chunkDirEntries = ((try? fs.list("head/chunks_head")) ?? []).sorted()
                return st
            }

            for op in input.ops {
                var opErr = ""
                switch op.op {
                case "delete":
                    do {
                        try head.delete(
                            mint: op.mint ?? 0, maxt: op.maxt ?? 0,
                            matchers: hgMatchers(op.matcherKind ?? ""))
                    } catch {
                        opErr = String(describing: error)
                    }
                case "truncate":
                    do {
                        try head.truncate(mint: op.truncateMint ?? 0)
                    } catch {
                        opErr = String(describing: error)
                    }
                default:
                    Issue.record("unknown head gc op \(op.op)")
                }
                out.states.append(snapshot(opErr))
            }
            out.states.append(snapshot(""))

            do { try head.close() } catch { out.closeErr = String(describing: error) }
            if input.withWAL ?? false {
                out.walFiles = HeadAppendTests.readDir(fs, "head/wal")
            }
            return out
        }
    }

    /// `iterForDeletion` visits CONFLICTS before the unique slot, and upstream's comment says why: `del`
    /// promotes `conflicts[0]` into `unique`, so visiting `unique` first would move a conflict into a slot the
    /// walk has already passed — and leak a series that should have been deleted. Unreachable through the
    /// corpus, which cannot force a hash collision.
    @Test("iterForDeletion visits conflicts before the unique slot")
    func iterForDeletionOrder() throws {
        let s = StripeSeries(stripeSize: 1)
        let a = MemSeries(labels: Labels([Label("l", "a")]), ref: HeadSeriesRef(rawValue: 1))
        let b = MemSeries(labels: Labels([Label("l", "b")]), ref: HeadSeriesRef(rawValue: 2))
        // One hash for both: `a` takes the unique slot, `b` becomes a conflict.
        s.setUnlessAlreadySet(hash: 7, labels: a.lset, a)
        s.setUnlessAlreadySet(hash: 7, labels: b.lset, b)

        var order: [UInt64] = []
        s.iterForDeletion { _, _, series, _ in
            order.append(series.ref.rawValue)
        }
        #expect(order == [2, 1])  // The conflict first.

        // And a GC that deletes BOTH removes both, which is what the ordering protects: deleting the unique
        // holder first would promote `b` into the slot mid-walk.
        let s2 = StripeSeries(stripeSize: 1)
        let a2 = MemSeries(labels: Labels([Label("l", "a")]), ref: HeadSeriesRef(rawValue: 1))
        let b2 = MemSeries(labels: Labels([Label("l", "b")]), ref: HeadSeriesRef(rawValue: 2))
        s2.setUnlessAlreadySet(hash: 7, labels: a2.lset, a2)
        s2.setUnlessAlreadySet(hash: 7, labels: b2.lset, b2)
        let r = s2.gc(mint: 1000)  // Neither has any chunk, so both go.
        #expect(r.deleted.count == 2)
        #expect(s2.getByID(HeadSeriesRef(rawValue: 1)) == nil)
        #expect(s2.getByID(HeadSeriesRef(rawValue: 2)) == nil)
        #expect(s2.getByHash(hash: 7, labels: a2.lset) == nil)
        #expect(s2.getByHash(hash: 7, labels: b2.lset) == nil)
    }

    /// A series with a PENDING COMMIT survives a GC that would otherwise delete it — the guard that stops a
    /// truncation racing an appender into deleting a series whose samples have not landed.
    @Test("a pending commit keeps a chunkless series alive")
    func pendingCommitSurvivesGC() throws {
        let s = StripeSeries(stripeSize: 1)
        let a = MemSeries(labels: Labels([Label("l", "a")]), ref: HeadSeriesRef(rawValue: 1))
        a.pendingCommit = true
        s.setUnlessAlreadySet(hash: 7, labels: a.lset, a)

        let r = s.gc(mint: 1000)
        #expect(r.deleted.isEmpty)
        #expect(s.getByID(HeadSeriesRef(rawValue: 1)) != nil)
        // With no chunks its minTime is MinInt64, and that is what `actualMint` reports — which is how a
        // pending series can pull the head's minimum below the truncation point.
        #expect(r.actualMint == Int64.min)
    }

    /// A STALE series is counted separately when the GC deletes it, because `numStaleSeries` counts series and
    /// the GC is the only thing that decrements it. Three shapes: a stale float, and the two histogram fields —
    /// which are unreachable until the histogram append path lands, and are asserted here directly.
    @Test("the GC counts the stale series it deletes")
    func gcCountsStaleSeries() throws {
        let s = StripeSeries(stripeSize: 1)
        let plain = MemSeries(labels: Labels([Label("l", "a")]), ref: HeadSeriesRef(rawValue: 1))
        let stale = MemSeries(labels: Labels([Label("l", "b")]), ref: HeadSeriesRef(rawValue: 2))
        stale.lastValue = PromValue.staleNaN
        s.setUnlessAlreadySet(hash: 1, labels: plain.lset, plain)
        s.setUnlessAlreadySet(hash: 2, labels: stale.lset, stale)

        let r = s.gc(mint: 1000)
        #expect(r.deleted.count == 2)
        #expect(r.staleSeriesDeleted == 1)
    }

    /// The M-MAPPED half of the GC: the chunk FILES are truncated by `minMmapFile`, and the mmap-ready counter
    /// is adjusted when a series drops below two head chunks. Neither is reachable through the corpus, because
    /// `mmapHeadChunks` is unexported upstream (only `db.go` and `Close` call it).
    @Test("the GC truncates the chunk files and adjusts the mmap-ready counter")
    func gcTruncatesChunkFiles() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        let app = head.appender()
        for i in 0..<12 {
            try app.append(
                ref: SeriesRef(rawValue: 0), labels: lset, t: Int64(i) * 1000, v: Double(i))
        }
        try app.commit()

        // Two chunks to disk; the series is mmap-ready until then and not afterwards.
        #expect(head.series.mmapReadyTotal == 1)
        head.mmapHeadChunks()
        #expect(head.series.mmapReadyTotal == 0)
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.mmappedChunks.count == 2)
        #expect(((try? fs.list("head/chunks_head")) ?? []).count == 1)

        // A truncation that drops both mmapped chunks lets the mapper drop the file they were in.
        try head.truncate(mint: 8000)
        #expect(s.mmappedChunks.isEmpty)
        // The mapper truncates by FILE, and file 1 still holds the chunks of this run, so it survives until
        // `minMmapFile` names something above it — which is why the GC reports the number rather than deleting.
        #expect(((try? fs.list("head/chunks_head")) ?? []).count <= 1)

        // The series is still there (it has a head chunk), and its remaining chunk keeps its ref.
        #expect(head.seriesCount() == 1)
        try head.close()
    }

    /// The GC fires `postDeletion` (once per stripe, with everything it deleted there) and decrements the
    /// mmap-ready counter for a series that falls below two head chunks. `SeriesLifecycleCallback` is a noop in
    /// Prometheus — upstream says so — so only a custom callback can see the first.
    @Test("the GC reports its deletions and adjusts the mmap-ready counter")
    func gcReportsDeletionsAndCounters() throws {
        final class RecordingCallback: SeriesLifecycleCallback {
            var deletedBatches: [[HeadSeriesRef: Labels]] = []
            func preCreation(_: Labels) throws {}
            func postCreation(_: Labels) {}
            func postDeletion(_ series: [HeadSeriesRef: Labels]) {
                if !series.isEmpty { deletedBatches.append(series) }
            }
        }

        let fs = InMemoryFS()
        let cb = RecordingCallback()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        opts.seriesCallback = cb
        let head = try Head(fs: fs, opts: opts)

        let lset = Labels([Label("__name__", "a")])
        let app = head.appender()
        for i in 0..<12 {
            try app.append(
                ref: SeriesRef(rawValue: 0), labels: lset, t: Int64(i) * 1000, v: Double(i))
        }
        try app.commit()

        // Three head chunks, so the series counts as mmap-ready.
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.headChunks!.len() == 3)
        #expect(head.series.mmapReadyTotal == 1)

        // A truncation that leaves ONE head chunk crosses back below the threshold, and the GC is what notices.
        try head.truncate(mint: 8000)
        #expect(s.headChunks!.len() == 1)
        #expect(head.series.mmapReadyTotal == 0)
        #expect(cb.deletedBatches.isEmpty)  // Nothing deleted yet.

        // And a truncation past everything deletes the series, which the callback reports.
        try head.truncate(mint: 100_000)
        #expect(head.seriesCount() == 0)
        #expect(cb.deletedBatches.count == 1)
        #expect(cb.deletedBatches[0].keys.map(\.rawValue) == [1])
        try head.close()
    }

    /// A series with NO samples — created by an append that was then rejected — gets no tombstone, because
    /// `Delete` skips a series whose own range is empty. The corpus cannot build that state: every series it
    /// creates has a committed sample.
    @Test("Delete skips a series that has no samples")
    func deleteSkipsEmptySeries() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.outOfOrderTimeWindow = 5_000
        let head = try Head(fs: fs, opts: opts)

        // One real series, so the head is initialised.
        let real = Labels([Label("__name__", "m1"), Label("job", "a")])
        let a1 = head.appender()
        try a1.append(ref: SeriesRef(rawValue: 0), labels: real, t: 10_000, v: 1)
        try a1.commit()
        head.setMinValidTime(8_000)

        // A second series created by an append that is then REJECTED: it exists, in the postings, with no
        // samples and no chunks.
        let empty = Labels([Label("__name__", "m2"), Label("job", "a")])
        let a2 = head.appender() as! any StartTimestampAppender
        let (_, err) = a2.appendSTZeroSample(
            ref: SeriesRef(rawValue: 0), labels: empty, t: 12_000, st: 7_000)
        #expect(err != nil)
        try a2.commit()
        #expect(head.seriesCount() == 2)
        let s2 = head.series.getByHash(hash: empty.goHash(), labels: empty)!
        #expect(s2.headChunks == nil)
        #expect(s2.minTime() == Int64.min)

        // A delete matching BOTH: only the series with samples gets a tombstone.
        try head.delete(mint: Int64.min, maxt: Int64.max, matchers: [try Matcher(.equal, "job", "a")])
        let tr = head.tombstonesReader()
        #expect(tr.total() == 1)
        #expect(try tr.get(SeriesRef(rawValue: 1)).count == 1)
        #expect(try tr.get(SeriesRef(rawValue: 2)).isEmpty)
        try head.close()
    }

    /// `MemTombstones.truncateBefore` keeps an interval that STRADDLES the boundary whole, rather than trimming
    /// it — deleted data is not un-deleted by truncation. And when nothing qualifies, the `i+1` leaves the list
    /// untouched.
    @Test("truncateBefore drops elapsed tombstones and keeps straddling ones whole")
    func tombstoneTruncateBefore() throws {
        let t = MemTombstones()
        t.addInterval(SeriesRef(rawValue: 1), DeletionInterval(mint: 0, maxt: 100))
        t.addInterval(SeriesRef(rawValue: 1), DeletionInterval(mint: 200, maxt: 300))
        t.addInterval(SeriesRef(rawValue: 2), DeletionInterval(mint: 500, maxt: 600))
        #expect(t.total() == 3)

        // Below everything: nothing is dropped (the `i == -1` path).
        t.truncateBefore(-1)
        #expect(t.total() == 3)

        // Past the first interval of series 1 only.
        t.truncateBefore(150)
        #expect(try t.get(SeriesRef(rawValue: 1)) == [DeletionInterval(mint: 200, maxt: 300)])
        #expect(try t.get(SeriesRef(rawValue: 2)).count == 1)

        // EXACTLY at an interval's end: `beforeT > maxt` is false, so it is KEPT. This is the one input that
        // distinguishes `>` from `>=`, and getting it wrong drops a tombstone whose last millisecond still
        // matters.
        t.truncateBefore(300)
        #expect(try t.get(SeriesRef(rawValue: 1)) == [DeletionInterval(mint: 200, maxt: 300)])

        // Straddling series 2's interval: kept WHOLE, not trimmed.
        t.truncateBefore(550)
        #expect(try t.get(SeriesRef(rawValue: 2)) == [DeletionInterval(mint: 500, maxt: 600)])
        // And series 1's remaining interval is now elapsed, so its key is gone entirely.
        #expect(try t.get(SeriesRef(rawValue: 1)).isEmpty)

        // Adding the same interval twice is idempotent, because `Intervals.Add` merges.
        t.addInterval(SeriesRef(rawValue: 3), DeletionInterval(mint: 0, maxt: 10))
        t.addInterval(SeriesRef(rawValue: 3), DeletionInterval(mint: 0, maxt: 10))
        #expect(try t.get(SeriesRef(rawValue: 3)).count == 1)

        t.deleteTombstones([SeriesRef(rawValue: 3)])
        #expect(try t.get(SeriesRef(rawValue: 3)).isEmpty)
    }
}
