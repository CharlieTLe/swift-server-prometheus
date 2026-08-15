//===----------------------------------------------------------------------===//
// The Head's FLOAT append path, pinned against the real `tsdb.Head` — `Appender`, `Append`, `Commit`,
// `Rollback`, and the WAL and chunk bytes they produce.
//
// This is the suite that ties §7f together: every case is a program of appender transactions, and each one is
// asserted in three independent places — the accessors, the WAL files byte for byte, and the chunk files after
// `Close` m-maps the tail. See `oracle/suites_head_append.go` for why all three are needed.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import PromLabels
import PromStorage
import PromWAL
import Testing

@testable import PromHead

// MARK: - Wire types

struct HAAppend: Codable, Sendable {
    var labels: [String: String]?
    /// A flat name/value list, for the one thing a map cannot express: a duplicate label NAME.
    var labelPairs: [String]?
    var useRef: Int?
    var t: Int64
    var v: String
    var stZero: Int64?
    var discardOOO: Bool?
    var getRef: Bool?
}

struct HATxn: Codable, Sendable {
    /// Optional because Go emits `null` for an empty slice, and a transaction that appends nothing is a case.
    var appends: [HAAppend]?
    var finish: String
}

struct HAIn: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var useXOR2: Bool?
    var storeST: Bool?
    var oooTimeWindow: Int64?
    var noWAL: Bool?
    var minValidTime: Int64?
    /// Open every transaction's appender BEFORE any append, so two appenders overlap — the only way to reach
    /// `commitFloats`' second `appendable` check.
    var interleaved: Bool?
    var txns: [HATxn]
}

struct HAAppendOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var err: String
    var refLabels: [String: String]?
}

struct HATxnOut: Codable, Equatable, Sendable {
    var appends: [HAAppendOut]
    var finishErr: [String]
    var minTime: Int64
    var maxTime: Int64
    var numSeries: UInt64
    var numStale: UInt64
}

struct HAFileOut: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var bytes: String
}

struct HAOut: Codable, Equatable, Sendable {
    var txns: [HATxnOut]
    var minTime: Int64
    var maxTime: Int64
    var numSeries: UInt64
    var numStale: UInt64
    var appendableMinValidTime: Int64
    var appendableOK: Bool
    var size: Int64
    var walFiles: [HAFileOut]
    var chunkFiles: [HAFileOut]
    var closeErr: String
}

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

@Suite("head: the float append path, its WAL records and its chunks")
struct HeadAppendTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/append.jsonl", FixtureCase<HAIn, HAOut>.self) { input in
            let fs = InMemoryFS()

            let opts = HeadOptions.default()
            opts.chunkDirRoot = "head"
            opts.chunkRange = input.chunkRange
            opts.samplesPerChunk = input.samplesPerChunk
            opts.outOfOrderTimeWindow = input.oooTimeWindow ?? 0
            opts.enableSTStorage = input.storeST ?? false
            if input.useXOR2 ?? false {
                opts.floatChunkEncoding = .xor2
            }

            var wal: WL?
            if !(input.noWAL ?? false) {
                wal = try WL(fs: fs, dir: "head/wal")
            }

            let head = try Head(fs: fs, wal: wal, opts: opts)
            head.setMinValidTime(input.minValidTime ?? 0)

            var out = HAOut(
                txns: [], minTime: 0, maxTime: 0, numSeries: 0, numStale: 0,
                appendableMinValidTime: 0, appendableOK: false, size: 0,
                walFiles: [], chunkFiles: [], closeErr: "")

            var openApps: [any Appender] = []
            if input.interleaved ?? false {
                for _ in input.txns { openApps.append(head.appender()) }
            }

            var refs: [SeriesRef] = []
            for (ti, txn) in input.txns.enumerated() {
                let app = (input.interleaved ?? false) ? openApps[ti] : head.appender()
                var to = HATxnOut(
                    appends: [], finishErr: [], minTime: 0, maxTime: 0, numSeries: 0, numStale: 0)

                for a in txn.appends ?? [] {
                    var lset = Labels(map: a.labels ?? [:])
                    if let pairs = a.labelPairs, !pairs.isEmpty {
                        lset = Labels(strings: pairs)
                    }
                    var ref = SeriesRef(rawValue: 0)
                    if let ur = a.useRef, ur > 0, ur <= refs.count {
                        ref = refs[ur - 1]
                    }

                    if a.getRef ?? false {
                        var ao = HAAppendOut(ref: 0, err: "", refLabels: nil)
                        if let g = app as? any GetRef {
                            let (r, ls) = g.getRef(labels: lset, hash: lset.goHash())
                            ao.ref = r.rawValue
                            // Go emits `map[string]string`, and `omitempty` drops an EMPTY map — so the
                            // "no reference" answer has no `refLabels` key at all.
                            ao.refLabels = ls.isEmpty ? nil : ls.map()
                        }
                        to.appends.append(ao)
                        continue
                    }

                    if a.discardOOO ?? false {
                        app.setOptions(AppendOptions(discardOutOfOrder: true))
                    }

                    var ao = HAAppendOut(ref: 0, err: "", refLabels: nil)
                    if let st = a.stZero {
                        // The pair form, because this is the one method whose error carries a ref.
                        let (got, err) = (app as! any StartTimestampAppender).appendSTZeroSample(
                            ref: ref, labels: lset, t: a.t, st: st)
                        ao.ref = got.rawValue
                        if let err { ao.err = String(describing: err) }
                        if got.rawValue != 0 && err == nil { refs.append(got) }
                    } else {
                        do {
                            let got = try app.append(ref: ref, labels: lset, t: a.t, v: fbits(a.v))
                            ao.ref = got.rawValue
                            if got.rawValue != 0 { refs.append(got) }
                        } catch {
                            ao.err = String(describing: error)
                        }
                    }
                    to.appends.append(ao)
                }

                for step in txn.finish.split(separator: ",") {
                    do {
                        switch step {
                        case "commit": try app.commit()
                        case "rollback": try app.rollback()
                        default: Issue.record("unknown finish step \(step)")
                        }
                        to.finishErr.append("")
                    } catch {
                        to.finishErr.append(String(describing: error))
                    }
                }

                to.minTime = head.minTime()
                to.maxTime = head.maxTime()
                to.numSeries = head.seriesCount()
                to.numStale = head.staleSeriesCount()
                out.txns.append(to)
            }

            out.minTime = head.minTime()
            out.maxTime = head.maxTime()
            out.numSeries = head.seriesCount()
            out.numStale = head.staleSeriesCount()
            let (amvt, ok) = head.appendableMinValidTimeIfInitialized()
            out.appendableMinValidTime = amvt
            out.appendableOK = ok
            out.size = head.size()

            do { try head.close() } catch { out.closeErr = String(describing: error) }

            out.walFiles = Self.readDir(fs, "head/wal")
            out.chunkFiles = Self.readDir(fs, "head/chunks_head")
            return out
        }
    }

    /// RLE-hex, the same codec the WAL and head-chunk suites use, because both directories carry long runs of
    /// pre-allocated zeros (quirks 176, 182).
    static func readDir(_ fs: InMemoryFS, _ dir: String) -> [HAFileOut] {
        var out: [HAFileOut] = []
        for name in ((try? fs.list(dir)) ?? []).sorted() {
            guard let h = try? fs.openForReading("\(dir)/\(name)"),
                let b = try? h.read(offset: 0, length: h.size)
            else { continue }
            try? h.close()
            out.append(HAFileOut(name: name, size: b.count, bytes: RLEHex.encode(b)))
        }
        return out
    }

    /// `Append` COLLECTS; nothing reaches the series until `Commit`. Unobservable through the corpus, which can
    /// only look at a head between transactions — and it is the invariant the whole two-phase design rests on.
    @Test("Append collects and Commit is what writes")
    func appendCollectsCommitWrites() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)

        let lset = Labels([Label("__name__", "a")])
        let app = head.appender()
        try app.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: 1)

        // The series exists (getOrCreate ran), but it has no chunk yet and is marked pending.
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)
        #expect(s != nil)
        #expect(s?.headChunks == nil)
        #expect(s?.pendingCommit == true)
        #expect(head.maxTime() == 1000)  // initTime ran, but not from a committed sample.

        try app.commit()
        #expect(s?.headChunks != nil)
        #expect(s?.headChunks?.chunk.numSamples == 1)
        #expect(s?.pendingCommit == false)
        try head.close()
    }

    /// The isolation ID is taken per appender and released by BOTH endings, and the read watermark is what
    /// truncation waits on. Unexported upstream, and the corpus cannot see it.
    @Test("each appender takes an isolation ID and both endings release it")
    func isolationIDLifecycle() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        // First transaction: the init appender's inner appender takes ID 1.
        let a1 = head.appender()
        try a1.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: 1)
        #expect(head.iso.lastAppendID() == 1)
        try a1.commit()
        // With nothing open, the low watermark is the last issued ID (§7f(a)).
        #expect(head.iso.lowWatermark() == 1)

        let a2 = head.appender()
        try a2.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 2000, v: 2)
        #expect(head.iso.lastAppendID() == 2)
        try a2.rollback()
        #expect(head.iso.lowWatermark() == 2)

        // A rolled-back sample leaves the series' ring alone: only committed appends add IDs. The committed
        // one is then cleaned up by the SECOND appender's watermark, which is why the ring is empty rather
        // than holding ID 1 — `cleanupAppendIDsBelow` runs on every series a transaction touches.
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)
        #expect(s?.txs?.count == 0)
        try head.close()
    }

    /// `unmarkCreatedSeriesAsPendingCommit` is not redundant, and this is the case that shows it: a series
    /// created by an append that then FAILED has no sample in any batch, so `commitFloats` never sees it and
    /// only the sweep over `createdSeries` can clear its flag. `AppendSTZeroSample`'s out-of-order verdict is
    /// the reachable way there — it creates the series and then rejects the sample.
    @Test("a created series with no committed sample is still unmarked")
    func createdSeriesWithoutSampleIsUnmarked() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.outOfOrderTimeWindow = 5_000
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        // Establish the head at maxTime 10_000, and put the appender's floor at 8_000.
        let a1 = head.appender()
        try a1.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 10_000, v: 1)
        try a1.commit()
        head.setMinValidTime(8_000)

        // A NEW series whose only append is an ST that `appendable` accepts as out-of-order (below the floor
        // but inside the OOO window). The series is created and marked pending, and the sample is then
        // REJECTED — so no batch holds it and `commitFloats` will never see it.
        let other = Labels([Label("__name__", "b")])
        let a2 = head.appender() as! any StartTimestampAppender
        let (ref, err) = a2.appendSTZeroSample(
            ref: SeriesRef(rawValue: 0), labels: other, t: 12_000, st: 7_000)
        #expect(err != nil)
        #expect(ref.rawValue != 0)  // The ref travels WITH the error, uniquely here.
        let s = head.series.getByHash(hash: other.goHash(), labels: other)
        #expect(s?.pendingCommit == true)

        try a2.commit()
        // Only `unmarkCreatedSeriesAsPendingCommit` can have cleared this.
        #expect(s?.pendingCommit == false)

        // And the flag a series is BORN with: `getOrCreate` passes `pendingCommit: true`, which is the only
        // thing that sets it when `appendable` rejects the very first sample. A too-old sample takes that path.
        let third = Labels([Label("__name__", "c")])
        let a3 = head.appender()
        #expect(throws: (any Error).self) {
            try a3.append(ref: SeriesRef(rawValue: 0), labels: third, t: 1_000, v: 1)
        }
        let s3 = head.series.getByHash(hash: third.goHash(), labels: third)
        #expect(s3 != nil)
        #expect(s3?.pendingCommit == true)
        try a3.commit()
        #expect(s3?.pendingCommit == false)
        try head.close()
    }

    /// The isolation ring holds the appendID of every COMMITTED sample, and each later appender's watermark
    /// cleans out the ones no open read can still need. Neither is visible through the corpus.
    @Test("committed samples carry their appendID into the series ring, and later appends clean it")
    func committedSamplesCarryAppendIDs() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        let a1 = head.appender()
        try a1.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: 1)
        try a1.commit()
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)
        #expect(Self.ringIDs(s) == [1])

        let a2 = head.appender()
        try a2.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 2000, v: 2)
        try a2.commit()
        // ID 1 is below appender 2's watermark, so the cleanup dropped it.
        #expect(Self.ringIDs(s) == [2])
        try head.close()
    }

    /// `Rollback` clears the pending flag of every series whose samples it drops, and releases its append ID.
    @Test("rollback clears pending commits and closes its append")
    func rollbackClearsState() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        let a1 = head.appender()
        try a1.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: 1)
        try a1.commit()

        let a2 = head.appender()
        try a2.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 2000, v: 2)
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)
        #expect(s?.pendingCommit == true)
        // An open APPEND does not hold the watermark back — only an open READ does (§7f(a)), so this is 2 while
        // appender 2 is still running.
        #expect(head.iso.lowWatermark() == 2)

        try a2.rollback()
        #expect(s?.pendingCommit == false)
        // The rolled-back sample never reached the chunk, and the ring is now EMPTY rather than holding the
        // committed ID 1: `Rollback` runs `cleanupAppendIDsBelow` with appender 2's watermark, which is above
        // it. A rollback therefore still garbage-collects another transaction's IDs.
        #expect(Self.ringIDs(s) == [])
        try head.close()
    }

    static func ringIDs(_ s: MemSeries?) -> [UInt64] {
        guard let ring = s?.txs else { return [] }
        var it = ring.iterator()
        var out: [UInt64] = []
        for _ in 0..<ring.count {
            out.append(it.at())
            it.next()
        }
        return out
    }

    /// `getCurrentBatch` never cuts a second batch for a float-only append, because `stFloat` is deliberately
    /// not recorded in `typesInBatch`. That is the reason the WAL of a big append is ONE samples record.
    @Test("a float-only append uses exactly one batch")
    func floatOnlyAppendUsesOneBatch() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        let head = try Head(fs: fs, opts: opts)

        let app = head.appender() as! InitAppender
        for i in 0..<50 {
            let lset = Labels([Label("__name__", "m"), Label("i", "\(i)")])
            try app.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: Double(i))
        }
        let inner = app.app as! HeadAppender
        #expect(inner.batches.count == 1)
        #expect(inner.batches[0].floats.count == 50)
        #expect(inner.typesInBatch.isEmpty)
        try app.commit()
        try head.close()
    }
}
