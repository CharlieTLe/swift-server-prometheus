//===----------------------------------------------------------------------===//
// The Head's READ path, pinned against the real `tsdb.Head` — `HeadIndexReader`, `HeadChunkReader`,
// `RangeHead`, and the isolation-aware chunk iterator.
//
// §7f(f) pinned what a commit writes; this pins what a reader SEES. The case that matters most is
// `isolation-hides-later-commits`: a reader opened between two commits gets a chunk with four samples and
// iterates only two, because `memSeries.iterator` computes a `stopAfter` from the append IDs the isolation
// state rejects. Nothing else in the port makes isolation observable.
//
// See `oracle/suites_head_read.go` for the case list and the shape of the program.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromChunkEnc
import PromChunks
import PromFS
import PromIndex
import PromLabels
import PromStorage
import Testing

@testable import PromHead

// MARK: - Wire types

struct HRSample: Codable, Sendable {
    var labels: [String: String]
    var t: Int64
    var v: String
}

struct HRIn: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var phases: [[HRSample]]?
    var readerAfterPhase: Int
    var rangeMint: Int64?
    var rangeMaxt: Int64?
    var rangeIsolationOff: Bool?
    var labelValueNames: [String]?
    var matcherKind: String?
    var postingsQueries: [[String]]?
    var closeBeforeRead: Bool?
    var bogusRefs: [UInt64]?
    var bogusChunkRefs: [UInt64]?
}

struct HRChunkMeta: Codable, Equatable, Sendable {
    var ref: UInt64
    var minTime: Int64
    var maxTime: Int64
}

struct HRSeriesOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var labels: [String: String]
    var chunks: [HRChunkMeta]
    var err: String
}

struct HRReadSample: Codable, Equatable, Sendable {
    var t: Int64
    var v: String
}

struct HRChunkOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var encoding: UInt8
    var numSamples: Int
    var bytes: String
    var maxTime: Int64
    var samples: [HRReadSample]
    var err: String
    var copyBytes: String
    var copyNumSamples: Int
    var copyErr: String
}

struct HRRangeMeta: Codable, Equatable, Sendable {
    var minTime: Int64
    var maxTime: Int64
    var blockMaxTime: Int64
    var numSeries: UInt64
    var ulid: String
    var string: String
}

struct HROut: Codable, Equatable, Sendable {
    var symbols: [String]
    var labelNames: [String]
    var labelNamesMatched: [String]
    var labelValues: [[String]]
    var sortedLabelValues: [[String]]
    var matchedValues: [[String]]
    var postings: [[UInt64]]
    var allPostings: [UInt64]
    var sortedPostings: [UInt64]
    var labelNamesFor: [String]
    var series: [HRSeriesOut]
    var chunks: [HRChunkOut]
    var indexMint: Int64
    var rangeMeta: HRRangeMeta?
    var readerErr: String
    var afterClose: UInt64
    var lowWatermark: UInt64
}

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hbits(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }
private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// The fixed matcher vocabulary; a closure cannot travel through JSON.
private func hrMatchers(_ kind: String) -> [Matcher] {
    switch kind {
    case "": return []
    case "eq": return [try! Matcher(.equal, "job", "a")]
    case "neq": return [try! Matcher(.notEqual, "job", "a")]
    case "re": return [try! Matcher(.regexp, "__name__", "m.*")]
    case "all": return [try! Matcher(.regexp, "__name__", ".*")]
    default: fatalError("unknown matcher kind \(kind)")
    }
}

@Suite("head: the read path, and isolation truncating an iterator")
struct HeadReadTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/read.jsonl", FixtureCase<HRIn, HROut>.self) { input in
            let fs = InMemoryFS()
            let opts = HeadOptions.default()
            opts.chunkDirRoot = "head"
            opts.chunkRange = input.chunkRange
            opts.samplesPerChunk = input.samplesPerChunk
            let head = try Head(fs: fs, opts: opts)

            var out = HROut(
                symbols: [], labelNames: [], labelNamesMatched: [], labelValues: [],
                sortedLabelValues: [], matchedValues: [], postings: [], allPostings: [],
                sortedPostings: [], labelNamesFor: [], series: [], chunks: [], indexMint: 0,
                rangeMeta: nil, readerErr: "", afterClose: 0, lowWatermark: 0)

            var ir: HeadIndexReader?
            var cr: HeadChunkReader?
            func openReaders() {
                if let lo = input.rangeMint, let hi = input.rangeMaxt {
                    let rh =
                        (input.rangeIsolationOff ?? false)
                        ? RangeHead.withIsolationDisabled(head: head, mint: lo, maxt: hi)
                        : RangeHead(head: head, mint: lo, maxt: hi)
                    ir = rh.index()
                    do { cr = try rh.chunks() } catch { out.readerErr = String(describing: error) }
                    out.rangeMeta = HRRangeMeta(
                        minTime: rh.minTime(), maxTime: rh.maxTime(), blockMaxTime: rh.blockMaxTime(),
                        numSeries: rh.numSeries(), ulid: rh.meta().ulid.description,
                        string: rh.description)
                } else {
                    ir = head.index()
                    do { cr = try head.chunks() } catch { out.readerErr = String(describing: error) }
                }
            }

            let phases = input.phases ?? []
            if input.readerAfterPhase == -2 {
                openReaders()
            }
            for (pi, phase) in phases.enumerated() {
                let app = head.appender()
                for s in phase {
                    try app.append(
                        ref: SeriesRef(rawValue: 0), labels: Labels(map: s.labels), t: s.t,
                        v: fbits(s.v))
                }
                try app.commit()
                if pi == input.readerAfterPhase {
                    openReaders()
                }
            }
            if input.readerAfterPhase == -1 || input.readerAfterPhase >= phases.count {
                if input.closeBeforeRead ?? false {
                    try head.close()
                }
                openReaders()
            }

            guard let ir, let cr, out.readerErr.isEmpty else {
                return out
            }

            // --- The index reader -------------------------------------------------------------

            out.symbols = ir.symbols()
            out.labelNames = (try? ir.labelNames()) ?? []
            if let kind = input.matcherKind, !kind.isEmpty {
                out.labelNamesMatched = (try? ir.labelNames(matchers: hrMatchers(kind))) ?? []
            }

            for name in input.labelValueNames ?? [] {
                do {
                    out.labelValues.append(try ir.labelValues(name: name, hints: nil, matchers: []))
                } catch {
                    out.labelValues.append(["ERR: \(error)"])
                }
                do {
                    out.sortedLabelValues.append(
                        try ir.sortedLabelValues(name: name, hints: nil, matchers: []))
                } catch {
                    out.sortedLabelValues.append(["ERR: \(error)"])
                }
                if let kind = input.matcherKind, !kind.isEmpty {
                    do {
                        out.matchedValues.append(
                            try ir.labelValues(name: name, hints: nil, matchers: hrMatchers(kind)))
                    } catch {
                        out.matchedValues.append(["ERR: \(error)"])
                    }
                }
            }

            for q in input.postingsQueries ?? [] {
                let refs =
                    (try? expandPostings(
                        try ir.postings(name: q[0], values: Array(q.dropFirst())))) ?? []
                out.postings.append(refs.map(\.rawValue))
            }

            let (allName, allValue) = allPostingsKey()
            let allRefs = try expandPostings(try ir.postings(name: allName, values: [allValue]))
            out.allPostings = allRefs.map(\.rawValue)

            let sortedRefs = try expandPostings(ir.sortedPostings(ListPostings(allRefs)))
            out.sortedPostings = sortedRefs.map(\.rawValue)

            out.labelNamesFor = (try? ir.labelNamesFor(ListPostings(allRefs))) ?? []

            // --- Series, and every chunk they name --------------------------------------------

            func readSeries(_ ref: SeriesRef) {
                var so = HRSeriesOut(ref: ref.rawValue, labels: [:], chunks: [], err: "")
                do {
                    let (lset, metas) = try ir.series(ref)
                    so.labels = lset.map()
                    so.chunks = metas.map {
                        HRChunkMeta(ref: $0.ref.rawValue, minTime: $0.minTime, maxTime: $0.maxTime)
                    }
                    out.series.append(so)
                    for m in metas {
                        out.chunks.append(Self.readChunk(cr, m))
                    }
                } catch {
                    so.err = String(describing: error)
                    out.series.append(so)
                }
            }

            for r in sortedRefs { readSeries(r) }
            for r in input.bogusRefs ?? [] { readSeries(SeriesRef(rawValue: r)) }
            for r in input.bogusChunkRefs ?? [] {
                out.chunks.append(
                    Self.readChunk(cr, Meta(ref: ChunkRef(rawValue: r), minTime: 0, maxTime: 0)))
            }

            // Go's `indexReaderMint` reports 0 — the clamp is asserted through the range cases' chunk
            // lists rather than through a number the exported API does not expose.
            out.indexMint = 0

            do { try cr.close() } catch { out.readerErr = String(describing: error) }
            try? ir.close()
            out.afterClose = head.seriesCount()

            return out
        }
    }

    static func readChunk(_ cr: HeadChunkReader, _ meta: Meta) -> HRChunkOut {
        var co = HRChunkOut(
            ref: meta.ref.rawValue, encoding: 0, numSamples: 0, bytes: "", maxTime: 0, samples: [],
            err: "", copyBytes: "", copyNumSamples: 0, copyErr: "")
        let chk: any Chunk
        do {
            let (c, iterable) = try cr.chunkOrIterable(meta: meta)
            guard let c else {
                co.err = iterable == nil ? "nil chunk and nil iterable" : "iterable, not chunk"
                return co
            }
            chk = c
        } catch {
            co.err = String(describing: error)
            return co
        }
        co.encoding = chk.encoding.rawValue
        co.numSamples = chk.numSamples
        co.bytes = hex(chk.bytes)

        let it = chk.iterator(nil)
        while it.next() == .float {
            let (t, v) = it.at()
            co.samples.append(HRReadSample(t: t, v: hbits(v)))
        }
        if let e = it.err() {
            co.err = String(describing: e)
        }

        do {
            let (cchk, _, maxTime) = try cr.chunkOrIterableWithCopy(meta: meta)
            if let cchk {
                co.maxTime = maxTime
                co.copyBytes = hex(cchk.bytes)
                co.copyNumSamples = cchk.numSamples
            }
        } catch {
            co.copyErr = String(describing: error)
        }
        return co
    }

    /// `memSeries.chunk`'s index arithmetic maps a `HeadChunkID` onto `mmappedChunks ++ headChunks`, and the two
    /// halves run in OPPOSITE orders. Asserted directly because the corpus only sees the result: a port that
    /// reversed the head half would return the right *number* of chunks with their contents swapped, and only
    /// the sample values would show it.
    @Test("chunk(id:) walks the mmapped array forwards and the head list backwards")
    func chunkIDArithmetic() throws {
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

        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.mmappedChunks.isEmpty)
        let listLen = s.headChunks!.len()
        #expect(listLen == 3)

        // ID 0 is the OLDEST chunk, which is the LAST element of the list.
        let (c0, isHead0, isOpen0) = try s.chunk(id: HeadChunkID(rawValue: 0), chunkDiskMapper: head.chunkDiskMapper)
        #expect(isHead0)
        #expect(isOpen0 == false)
        #expect(c0.minTime == 0)

        // The last ID is the OPEN chunk.
        let (cLast, isHeadLast, isOpenLast) = try s.chunk(
            id: HeadChunkID(rawValue: UInt64(listLen - 1)), chunkDiskMapper: head.chunkDiskMapper)
        #expect(isHeadLast)
        #expect(isOpenLast)
        #expect(cLast.minTime == 8000)

        // Out of range in both directions.
        #expect(throws: StorageError.notFound) {
            _ = try s.chunk(id: HeadChunkID(rawValue: UInt64(listLen)), chunkDiskMapper: head.chunkDiskMapper)
        }

        // After m-mapping, the same IDs resolve — the mmapped ones from disk, the survivor from memory.
        head.mmapHeadChunks()
        #expect(s.mmappedChunks.count == 2)
        let (m0, isHeadM0, _) = try s.chunk(
            id: HeadChunkID(rawValue: 0), chunkDiskMapper: head.chunkDiskMapper)
        #expect(isHeadM0 == false)  // From the chunk file now.
        #expect(m0.minTime == 0)
        #expect(m0.chunk.numSamples == c0.chunk.numSamples)
        try head.close()
    }

    /// The M-MAPPED read path, which the corpus cannot reach: `mmapHeadChunks` is unexported upstream and its
    /// only callers are `db.go`'s background goroutine and `Close`, so a differential case would have to close
    /// the head — and then it cannot be read. Everything here is a consequence of facts the corpus DOES pin
    /// (§7d's chunk files, §7f(d)'s `mmappedChunks` bookkeeping, and this suite's in-memory metas).
    @Test("after m-mapping, the metas, the refs and the samples all still line up")
    func mmappedReadPath() throws {
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

        // Before m-mapping: three head chunks, and only the newest reports MaxInt64.
        let ir = head.index()
        let (_, before) = try ir.series(SeriesRef(rawValue: 1))
        #expect(before.count == 3)
        #expect(before.map(\.minTime) == [0, 4000, 8000])
        #expect(before.map(\.maxTime) == [3000, 7000, Int64.max])

        head.mmapHeadChunks()

        // After: the same three metas with the same refs — the ref is `firstChunkID + position`, and m-mapping
        // moves chunks between the two halves without changing either.
        let (_, after) = try ir.series(SeriesRef(rawValue: 1))
        #expect(after.map(\.ref) == before.map(\.ref))
        #expect(after.map(\.minTime) == [0, 4000, 8000])
        #expect(after.map(\.maxTime) == [3000, 7000, Int64.max])

        // And every one of them reads back with the samples it had in memory.
        let cr = try head.chunks()
        var seen: [Int64] = []
        for m in after {
            let (chk, _) = try cr.chunkOrIterable(meta: m)
            let it = chk!.iterator(nil)
            while it.next() == .float { seen.append(it.at().0) }
        }
        #expect(seen == (0..<12).map { Int64($0) * 1000 })

        // A narrower reader drops the metas that do not overlap, and refuses the chunk if asked anyway.
        let narrow = head.indexRange(mint: 5000, maxt: 6000)
        let (_, windowed) = try narrow.series(SeriesRef(rawValue: 1))
        // Only the middle chunk. The open chunk's `MaxTime` is `MaxInt64`, but its MIN time is 8000 — above the
        // window — so the overlap test excludes it. "Open" does not mean "always overlaps".
        #expect(windowed.map(\.minTime) == [4000])
        let narrowCR = try head.chunksRange(mint: 5000, maxt: 6000, isoState: nil)
        #expect(throws: StorageError.notFound) {
            _ = try narrowCR.chunkOrIterable(meta: before[0])
        }

        // Truncation advances `firstChunkID` by what it dropped, so the SURVIVING chunks keep their refs.
        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        let droppedRefs = Array(after.prefix(1).map(\.ref))
        s.truncateChunksBefore(mint: 4000)
        #expect(s.firstChunkID.rawValue == 1)
        let (_, truncated) = try ir.series(SeriesRef(rawValue: 1))
        #expect(truncated.map(\.ref) == Array(after.dropFirst()).map(\.ref))
        // The dropped chunk's ref is now out of range rather than pointing at a different chunk.
        #expect(throws: StorageError.notFound) {
            _ = try cr.chunkOrIterable(meta: Meta(ref: droppedRefs[0], minTime: 0, maxTime: 3000))
        }

        try cr.close()
        try head.close()
    }

    /// Two head chunks ALONGSIDE mmapped ones, which the corpus cannot arrange (`mmapHeadChunks` is
    /// unexported) and which is the only state where `appendSeriesChunks`' multi-chunk branch has to add
    /// `mmappedChunks.count` to the position — the single-chunk fast path hides that arithmetic.
    @Test("head chunk refs count from after the mmapped ones")
    func headChunkRefsSkipTheMmapped() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        func appendRange(_ range: Range<Int>) throws {
            let app = head.appender()
            for i in range {
                try app.append(
                    ref: SeriesRef(rawValue: 0), labels: lset, t: Int64(i) * 1000, v: Double(i))
            }
            try app.commit()
        }

        try appendRange(0..<12)  // Three chunks.
        head.mmapHeadChunks()  // Two go to disk, one head chunk left.
        try appendRange(12..<20)  // Two more head chunks.

        let s = head.series.getByHash(hash: lset.goHash(), labels: lset)!
        #expect(s.mmappedChunks.count == 2)
        #expect(s.headChunks!.len() == 3)

        let ir = head.index()
        let (_, metas) = try ir.series(SeriesRef(rawValue: 1))
        // Five chunks: refs 0..4, in time order, and only the last is open.
        #expect(metas.count == 5)
        #expect(metas.map { unpackHeadChunkRef($0.ref).chunkID.rawValue } == [0, 1, 2, 3, 4])
        #expect(metas.map(\.minTime) == [0, 4000, 8000, 12000, 16000])
        #expect(metas.map(\.maxTime) == [3000, 7000, 11000, 15000, Int64.max])

        // Every one of them reads back, and the samples are in one continuous run.
        let cr = try head.chunks()
        var seen: [Int64] = []
        for m in metas {
            let (chk, _) = try cr.chunkOrIterable(meta: m)
            let it = chk!.iterator(nil)
            while it.next() == .float { seen.append(it.at().0) }
        }
        #expect(seen == (0..<20).map { Int64($0) * 1000 })

        // A ref one past the end is out of range, not a wrap onto the first chunk.
        #expect(throws: StorageError.notFound) {
            _ = try cr.chunkOrIterable(
                meta: Meta(
                    ref: headChunkRef(s.ref, HeadChunkID(rawValue: 5)), minTime: 0,
                    maxTime: Int64.max))
        }
        try cr.close()
        try head.close()
    }

    /// `memSeries.iterator`'s sample counting, with mmapped chunks in front of the head ones — the arm that
    /// adds `mmappedChunk.numSamples` and the one that reverses the head-list position. A reader opened before
    /// the last commit is what makes the count decide anything.
    @Test("isolation counts mmapped samples and reverses the head-list position")
    func isolationCountsAcrossBothHalves() throws {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = 4000
        let head = try Head(fs: fs, opts: opts)
        let lset = Labels([Label("__name__", "a")])

        func appendRange(_ range: Range<Int>) throws {
            let app = head.appender()
            for i in range {
                try app.append(
                    ref: SeriesRef(rawValue: 0), labels: lset, t: Int64(i) * 1000, v: Double(i))
            }
            try app.commit()
        }

        try appendRange(0..<12)
        head.mmapHeadChunks()
        try appendRange(12..<16)  // One more head chunk, all from append ID 2.

        // A reader opened NOW sees everything.
        let all = try head.chunks()
        let ir = head.index()
        let (_, metas) = try ir.series(SeriesRef(rawValue: 1))
        var seenAll: [Int64] = []
        for m in metas {
            let (chk, _) = try all.chunkOrIterable(meta: m)
            let it = chk!.iterator(nil)
            while it.next() == .float { seenAll.append(it.at().0) }
        }
        #expect(seenAll.count == 16)
        try all.close()

        // A reader opened now, then MORE samples committed: the new ones are invisible, and the boundary is
        // computed per chunk — so the older chunks are untouched and only the open one is truncated.
        let mid = try head.chunks()
        try appendRange(16..<20)
        let (_, metasAfter) = try ir.series(SeriesRef(rawValue: 1))
        var seenMid: [Int64] = []
        for m in metasAfter {
            let (chk, _) = try mid.chunkOrIterable(meta: m)
            let it = chk!.iterator(nil)
            while it.next() == .float { seenMid.append(it.at().0) }
        }
        #expect(seenMid == (0..<16).map { Int64($0) * 1000 })
        try mid.close()

        // A chunk ALL of whose samples are invisible answers a NOP iterator rather than an empty chunk —
        // `stopAfter == 0`. Reaching it needs the later commit to cut a NEW chunk, which the 4000 ms chunk range
        // does at 20000.
        let beforeNew = try head.chunks()
        try appendRange(20..<24)
        let (_, metasNew) = try ir.series(SeriesRef(rawValue: 1))
        let newest = metasNew.last!
        #expect(newest.minTime == 20000)
        let (chkNew, _) = try beforeNew.chunkOrIterable(meta: newest)
        #expect(chkNew!.numSamples == 4)  // The CHUNK has the samples...
        #expect(chkNew!.iterator(nil).next() == ValueType.none)  // ...and this reader sees none of them.
        try beforeNew.close()

        // And a reader opened on an UNINITIALISED head has an empty window, because `chunksRange` clamps `mint`
        // up to `MinTime()` — which is `MaxInt64` before the first sample. Every later chunk is then "outside
        // the range" rather than invisible, which is a different error from the one above.
        let fs2 = InMemoryFS()
        let opts2 = HeadOptions.default()
        opts2.chunkDirRoot = "head"
        let head2 = try Head(fs: fs2, opts: opts2)
        let early = try head2.chunks()
        #expect(early.mint == Int64.max)
        let app2 = head2.appender()
        try app2.append(ref: SeriesRef(rawValue: 0), labels: lset, t: 1000, v: 1)
        try app2.commit()
        let (_, m2) = try head2.index().series(SeriesRef(rawValue: 1))
        #expect(m2.count == 1)
        #expect(throws: StorageError.notFound) {
            _ = try early.chunkOrIterable(meta: m2[0])
        }
        try early.close()
        try head2.close()
        try head.close()
    }

    /// `stopIterator` bounds `Next` and **not** `Seek` — upstream embeds the iterator interface and overrides
    /// only `Next`, so a `Seek` past the limit returns a sample the isolation state meant to hide. Asserted
    /// because it is a hole worth knowing about, and because a port that "fixed" it would diverge.
    @Test("stopIterator truncates Next but not Seek")
    func stopIteratorOnlyBoundsNext() throws {
        let chunk = XORChunk()
        let app = try chunk.appender()
        for i in 0..<5 {
            app.append(Int64(i) * 1000, Double(i))
        }

        let it = makeStopIterator(chunk: chunk, reuse: nil, stopAfter: 2)
        #expect(it.next() == .float)
        #expect(it.at().0 == 0)
        #expect(it.next() == .float)
        #expect(it.at().0 == 1000)
        #expect(it.next() == ValueType.none)  // Truncated.

        // Seek is NOT truncated: it forwards straight to the underlying iterator.
        let it2 = makeStopIterator(chunk: chunk, reuse: nil, stopAfter: 2)
        #expect(it2.seek(4000) == .float)
        #expect(it2.at().0 == 4000)

        // A `stopIterator` handed back for reuse is re-armed rather than re-allocated — and RE-ARMED means its
        // position goes back to -1, so it yields from the start again rather than continuing where it stopped.
        let reused = makeStopIterator(chunk: chunk, reuse: it, stopAfter: 3)
        #expect(reused as AnyObject === it as AnyObject)
        #expect(reused.next() == .float)
        #expect(reused.at().0 == 0)
        #expect(reused.next() == .float)
        #expect(reused.at().0 == 1000)
        #expect(reused.next() == .float)
        #expect(reused.at().0 == 2000)
        #expect(reused.next() == ValueType.none)
    }
}
