//===----------------------------------------------------------------------===//
// The two behaviours of the compaction write path that the `block/write` corpus cannot see, tested one level
// down — §3's rule: when the corpus cannot reach a layer, drop a level rather than contorting the corpus.
//
// ## `ChunkOrIterableWithCopy`'s `maxt` is invisible to a COMPACTION, and that took working out
//
// querier.go:734-737 overwrites the chunk meta's `MaxTime` with the third return of
// `ChunkOrIterableWithCopy`, because `appendSeriesChunks` reports the open head chunk's `MaxTime` as
// `math.MaxInt64`. The port was missing it (quirk 195). But the branch is guarded by
// `len(p.bufIter.Intervals) == 0`, and in a compaction the open chunk ALWAYS has an interval:
// `PopulateBlock` runs with `disableTrimming: false`, `MaxInt64` exceeds any `maxt`, so §6s's `trimBack`
// fires and adds `[maxt+1, MaxInt64]` — which sends the chunk down the re-encode path instead, where the
// meta's bounds come from the surviving samples. So `block/write` cannot distinguish the fix-up from its
// absence, and a negative control on it survives the whole corpus.
//
// It is reachable from the QUERIER, which is where `db.go` will meet it: `SelectHints.DisableTrimming` is
// what a `blockChunkQuerier` over a `RangeHead` sets, and with no synthetic interval the copy branch runs and
// `MaxInt64` has to be corrected. These two tests are that path, driven through the real `HeadChunkReader`.
//
// ## The `Compactor` protocol's two deferred methods
//
// `Plan` and `Compact` are declared so §7j is not forced to widen the protocol, and they throw. Asserting the
// message is what stops a later "implementation" that silently returns an empty slice — a TSDB whose
// scheduler never schedules anything looks exactly like a healthy one.
//===----------------------------------------------------------------------===//

import PromBlock
import PromChunkEnc
import PromChunks
import PromFS
import PromHead
import PromIndex
import PromStorage
import PromLabels
import Testing

@testable import PromCompact

@Suite("compact: what the block corpus cannot reach")
struct CompactSeamTests {

    /// A Head with one open chunk, and the index meta that reports it as `MaxInt64`.
    private func headWithOpenChunk() throws -> (fs: InMemoryFS, head: Head, metas: [DecodedChunkMeta]) {
        let fs = InMemoryFS()
        let opts = HeadOptions.default()
        opts.chunkDirRoot = "head"
        opts.chunkRange = twoHoursMS
        let head = try Head(fs: fs, wal: nil, opts: opts, stats: HeadStats())
        try head.initialize(minValidTime: Int64.min)

        let app = head.appender()
        for t in stride(from: Int64(1000), through: 5000, by: 1000) {
            _ = try app.append(
                ref: SeriesRef(rawValue: 0), labels: Labels(strings: "__name__", "a"), t: t,
                v: Double(t) / 1000)
        }
        try app.commit()

        let ir = head.index()
        let key = allPostingsKey()
        let p = try ir.postings(name: key.name, values: [key.value])
        var metas: [DecodedChunkMeta] = []
        while p.next() {
            let (_, chks) = try ir.series(p.at())
            for c in chks {
                metas.append(
                    DecodedChunkMeta(ref: c.ref.rawValue, minTime: c.minTime, maxTime: c.maxTime))
            }
        }
        return (fs, head, metas)
    }

    @Test("the head's index reports the open chunk as MaxInt64")
    func openChunkMetaIsMaxInt64() throws {
        let (_, head, metas) = try headWithOpenChunk()
        defer { try? head.close() }
        #expect(metas.count == 1)
        #expect(metas[0].maxTime == Int64.max)
    }

    /// Quirk 195. With no deletion intervals the WithCopy branch runs and `MaxInt64` is corrected to the
    /// chunk's real end; without the fix-up the meta the caller sees still says `MaxInt64`.
    @Test("ChunkOrIterableWithCopy's maxt corrects the open chunk's meta")
    func withCopyFixesMaxTime() throws {
        let (_, head, metas) = try headWithOpenChunk()
        defer { try? head.close() }

        let source = HeadBlockChunkReader(try head.chunks())
        defer { try? source.close() }

        let it = PopulateWithDelChunkSeriesIterator(
            blockID: "", source: source, metas: metas, intervals: [])
        #expect(it.next())
        let current = try #require(it.current)
        #expect(current.meta.maxTime == 5000)
        #expect(current.meta.minTime == 1000)
        #expect(it.err() == nil)
    }

    /// The other side of the same branch: the plain `ChunkOrIterable` form returns no `maxTime`, so the meta
    /// is left as the index gave it. That is what a *block*'s chunk reader does (it is not a
    /// `ChunkReaderWithCopy` upstream), and it is why the fix-up cannot simply be applied unconditionally.
    @Test("the plain ChunkOrIterable form leaves the meta alone")
    func plainFormLeavesMaxTime() throws {
        let (_, head, metas) = try headWithOpenChunk()
        defer { try? head.close() }

        let source = HeadBlockChunkReader(try head.chunks())
        defer { try? source.close() }

        let resolved = try source.chunkOrIterable(metas[0], copyHeadChunk: false)
        #expect(resolved.maxTime == nil)
        let withCopy = try source.chunkOrIterable(metas[0], copyHeadChunk: true)
        #expect(withCopy.maxTime == 5000)
    }

    @Test("Plan is declared and refuses, so db.go cannot compile into a TSDB that never compacts")
    func planIsDeclaredAndRefuses() throws {
        let fs = InMemoryFS()
        let c: any Compactor = try LeveledCompactor(fs: fs, ranges: [twoHoursMS])
        #expect(throws: CompactError.self) { _ = try c.plan(dir: "blocks") }
        #expect(
            CompactError.plannerUnported.description
                == "the compaction planner is db.go's and is not ported (HANDOFF §7j)")
    }

    @Test("Compact is declared and refuses")
    func compactIsDeclaredAndRefuses() throws {
        let fs = InMemoryFS()
        let c: any Compactor = try LeveledCompactor(fs: fs, ranges: [twoHoursMS])
        #expect(throws: CompactError.self) {
            _ = try c.compact(dest: "dest", dirs: ["a", "b"], open: [])
        }
    }

    /// `SetOutOfOrder`/`SetStaleSeries` are idempotent and re-SORT the list. Neither property is reachable
    /// from `Write`: it starts from a fresh meta so nothing is ever set twice, and it calls
    /// `SetOutOfOrder` before `SetStaleSeries` while `"from-out-of-order" < "from-stale-series"`, so the sort
    /// can never reorder anything. Both are pinned here instead of being argued away, because `db.go`'s
    /// out-of-order compaction (§7j, Phase 10) sets them from the other direction.
    @Test("the compaction hints are idempotent and sorted")
    func compactionHintsAreIdempotentAndSorted() {
        var c = BlockMetaCompaction()
        c.setStaleSeries()
        c.setOutOfOrder()
        #expect(c.hints == ["from-out-of-order", "from-stale-series"])
        c.setStaleSeries()
        c.setOutOfOrder()
        #expect(c.hints == ["from-out-of-order", "from-stale-series"])
        #expect(c.fromOutOfOrder())
        #expect(c.fromStaleSeries())

        var d = BlockMetaCompaction()
        d.hints = ["zzz"]
        d.setOutOfOrder()
        #expect(d.hints == ["from-out-of-order", "zzz"])
    }

    /// `writeMetaFile`'s first statement is `meta.Version = metaVersion1`, and it MUTATES the caller's meta.
    /// The port's `BlockMeta.version` already defaults to 1, so the compaction corpus cannot tell the
    /// assignment from its absence — every meta it writes was built by `Write` and is already version 1.
    /// A meta that arrives with any other version can. Quirk 201.
    @Test("writeMetaFile forces version 1 and mutates the caller's meta")
    func writeMetaFileForcesVersion() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("b")
        var meta = BlockMeta(ulid: ULID(pinnedULID)!, minTime: 1, maxTime: 2)
        meta.version = 7
        let n = try BlockMeta.writeMetaFile(fs: fs, dir: "b", meta: &meta)
        #expect(meta.version == 1)

        let h = try fs.openForReading("b/meta.json")
        let bytes = try h.read(offset: 0, length: h.size)
        try h.close()
        #expect(Int64(bytes.count) == n)
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"version\": 1"))
        // The temporary is removed on the SUCCESS path too — Go's `defer`.
        #expect(try fs.list("b").sorted() == ["meta.json"])
    }

    /// The temporary directory is always removed, so the corpus cannot see its NAME. `db.go`'s `Open` reaps
    /// leftovers by matching this exact suffix (db.go:66), so it is pinned as a constant rather than argued
    /// away as unobservable — the slice that reads it is §7j's.
    @Test("the block creation suffix is .tmp-for-creation")
    func tmpSuffixIsPinned() {
        #expect(tmpForCreationBlockDirSuffix == ".tmp-for-creation")
    }

    /// Go: `errors.New("cannot populate block from no readers")`. `Write` always passes exactly one reader,
    /// so nothing in the port can reach it — the check is what stops a future `Compact` from writing an
    /// empty block instead of failing.
    @Test("PopulateBlock refuses an empty reader list")
    func populateBlockRefusesNoReaders() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("tmp")
        var meta = BlockMeta(ulid: ULID(pinnedULID)!, minTime: 0, maxTime: 10)
        let chunkw = try ChunkWriter(fs: fs, dir: "tmp/chunks")
        let indexw = try IndexWriter(fs: fs, path: "tmp/index")
        defer {
            try? chunkw.close()
            try? indexw.close()
        }
        #expect(throws: CompactError.self) {
            try DefaultBlockPopulator().populateBlock(
                blocks: [], meta: &meta, indexw: indexw, chunkw: chunkw,
                postingsFunc: allSortedPostings)
        }
        #expect(CompactError.noReaders.description == "cannot populate block from no readers")
    }
}

private let pinnedULID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
