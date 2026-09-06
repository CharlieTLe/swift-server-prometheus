//===----------------------------------------------------------------------===//
// Ported from tsdb/compact.go @ v3.13.2 — `LeveledCompactor`'s WRITE path: `NewLeveledCompactor`, `Write`,
// `write`, `DefaultBlockPopulator.PopulateBlock` and `AllSortedPostings`.
//
// This is the first thing in the port that can produce a block outside a test. Everything under it is already
// pinned — `index.Writer` (§6i), `chunks.Writer` (§6h), `meta.json` and `ULID` (§6k), the populate iterators
// (§6t/§6u), `RangeHead` (§7g), `MemTombstones` (§7h(a)) — so what is new here is the ORCHESTRATION, and the
// orchestration is where the off-by-ones live.
//
// ## The three time bounds, and the two `+1`s that cancel
//
//     BlockWriter.Flush     maxt = head.MaxTime() + 1     block intervals are half-open  [min, max)
//     LeveledCompactor.Write   meta.MaxTime = maxt
//     PopulateBlock         series set maxt = meta.MaxTime - 1   the set's interval is CLOSED
//
// So a sample at exactly `head.MaxTime()` is included, and `meta.MaxTime` is one past it. Drop either
// adjustment and the block silently loses (or duplicates, on the next flush) its last millisecond. Quirk 199.
//
// ## An empty block writes NOTHING, and the check is after the files exist
//
// `write` creates `<dest>/<ulid>.tmp-for-creation`, writes the chunk segments and the index into it, and only
// then asks `meta.Stats.NumSamples == 0`. If it is zero it returns early — before `meta.json` and before the
// rename — and the deferred `os.RemoveAll(tmp)` takes the whole temporary directory with it. So a `Write` that
// produces no samples leaves the destination directory **untouched**, and `Write` reports no ULID rather than
// an error. Quirk 200.
//
// ## `writeMetaFile` runs AFTER `PopulateBlock`, which is what makes the stats real
//
// `meta` is a pointer all the way down: `Write` builds it, `PopulateBlock` accumulates `NumSeries`,
// `NumChunks`, `NumSamples`, `NumFloatSamples` and `NumHistogramSamples` into it, and `write` then serialises
// it. Reading `meta.Stats` before `PopulateBlock` gives zeros, which is exactly the bug an immutable `struct`
// port would introduce silently — hence `inout` on every hop. Quirk 201.
//
// ## What is deliberately NOT here, and where each goes
//
//   * **`Plan`, `plan`, `selectDirs`, `selectOverlappingDirs`, `splitByRange`** — that is `db.go`'s compaction
//     SCHEDULER, and it needs `blockDirs`/`readMetaFile` over a directory of blocks. §7j.
//   * **`Compact` and `CompactBlockMetas`** — merging N blocks into one. It needs
//     `storage.NewMergeChunkSeriesSet` and `storage/merge.go`, which the roadmap still lists as unported, and
//     its caller is the scheduler. §7j. `write` therefore refuses more than one input reader rather than
//     pretending; see ``CompactError/verticalCompactionUnported``.
//   * **Everything out-of-order** — `Compaction.SetOutOfOrder` is ported on `BlockMetaCompaction` because
//     `Write` reads the hint off `base`, but nothing produces an OOO block. Phase 10.
//   * **`CompactorMetrics` and `instrumentedChunkWriter`** — `client_golang` is not a dependency, and the
//     whole of `instrumentedChunkWriter` is three `Observe` calls around a delegating `WriteChunks`. Worth
//     one note rather than a type: it wraps the chunk writer **only when `Compaction.Level == 1`**, and
//     `Write` always sets level 1, so every block a `BlockWriter` produces goes through it and observes
//     nothing this port can see. Quirk 205.
//   * **`context` cancellation** — the port has no `GoContext`; the four `select { case <-ctx.Done() }`
//     checks have no ported equivalent, as everywhere else in the port.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunks
public import PromFS
public import PromIndex
public import PromStorage

internal import PromChunkEnc

/// Go: `db.go`'s `tmpForCreationBlockDirSuffix` (db.go:66). Named here because `compact.go` is its only
/// reader in this slice; `db.go`'s reaper for orphaned ones is §7j's.
public let tmpForCreationBlockDirSuffix = ".tmp-for-creation"

/// Go: `ExponentialBlockRanges(minSize, steps, stepSize)`.
///
/// `curRange *= int64(stepSize)` — a plain `int64` multiply, so it WRAPS rather than trapping. Written with
/// `&*` for that reason; the default call is `(2h, 10, 3)`, which tops out at 118,098 hours and comes nowhere
/// near it, but `db.go` lets a user set `MinBlockDuration`.
public func exponentialBlockRanges(minSize: Int64, steps: Int, stepSize: Int) -> [Int64] {
    var ranges: [Int64] = []
    ranges.reserveCapacity(steps)
    var curRange = minSize
    for _ in 0..<steps {
        ranges.append(curRange)
        curRange = curRange &* Int64(stepSize)
    }
    return ranges
}

/// Go: the errors `compact.go`'s write path returns, with their `%w` wrapping preserved.
public enum CompactError: Error, CustomStringConvertible {
    /// Go: `errors.New("at least one range must be provided")`.
    case noRanges
    /// Go: `errors.New("cannot populate block from no readers")`.
    case noReaders
    /// Go: `fmt.Errorf("open chunk writer: %w", err)`.
    case openChunkWriter(any Error)
    /// Go: `fmt.Errorf("open index writer: %w", err)`.
    case openIndexWriter(any Error)
    /// Go: `fmt.Errorf("populate block: %w", err)`.
    case populateBlock(any Error)
    /// Go: `fmt.Errorf("write merged meta: %w", err)`.
    case writeMergedMeta(any Error)
    /// Go: `fmt.Errorf("open index reader for block %+v: %w", b.Meta(), err)`.
    case openIndexReader(block: String, underlying: any Error)
    /// Go: `fmt.Errorf("open chunk reader for block %+v: %w", b.Meta(), err)`.
    case openChunkReader(block: String, underlying: any Error)
    /// Go: `fmt.Errorf("open tombstone reader for block %+v: %w", b.Meta(), err)`.
    case openTombstoneReader(block: String, underlying: any Error)
    /// Go: `fmt.Errorf("add symbol: %w", err)`.
    case addSymbol(any Error)
    /// Go: `fmt.Errorf("chunk iter: %w", err)`.
    case chunkIter(any Error)
    /// Go: `fmt.Errorf("write chunks: %w", err)`.
    case writeChunks(any Error)
    /// Go: `fmt.Errorf("add series: %w", err)`.
    case addSeries(any Error)
    /// Go: `fmt.Errorf("iterate compaction set: %w", err)`.
    case iterateCompactionSet(any Error)
    /// **Not upstream's.** `PopulateBlock` merges N inputs with `storage.NewMergeChunkSeriesSet`, and
    /// `storage/merge.go` is not ported (ROADMAP, "Still open"). Its only caller is `Compact`, which is
    /// §7j's, so this is unreachable from anything this slice ships — and it is an error rather than a
    /// silent first-block-only write, which is the failure mode the fidelity contract exists to prevent.
    case verticalCompactionUnported(readers: Int)
    /// **Not upstream's.** `Plan`/`plan`/`selectDirs`/`selectOverlappingDirs`/`splitByRange` are `db.go`'s
    /// compaction scheduler and land with §7j. See the ``Compactor`` protocol for why the method exists here
    /// at all.
    case plannerUnported

    public var description: String {
        switch self {
        case .noRanges: return "at least one range must be provided"
        case .noReaders: return "cannot populate block from no readers"
        case .openChunkWriter(let e): return "open chunk writer: \(e)"
        case .openIndexWriter(let e): return "open index writer: \(e)"
        case .populateBlock(let e): return "populate block: \(e)"
        case .writeMergedMeta(let e): return "write merged meta: \(e)"
        case .openIndexReader(let b, let e): return "open index reader for block \(b): \(e)"
        case .openChunkReader(let b, let e): return "open chunk reader for block \(b): \(e)"
        case .openTombstoneReader(let b, let e): return "open tombstone reader for block \(b): \(e)"
        case .addSymbol(let e): return "add symbol: \(e)"
        case .chunkIter(let e): return "chunk iter: \(e)"
        case .writeChunks(let e): return "write chunks: \(e)"
        case .addSeries(let e): return "add series: \(e)"
        case .iterateCompactionSet(let e): return "iterate compaction set: \(e)"
        case .verticalCompactionUnported(let n):
            return
                "vertical compaction of \(n) readers needs storage/merge.go, which is not ported (HANDOFF §7i(a))"
        case .plannerUnported:
            return "the compaction planner is db.go's and is not ported (HANDOFF §7j)"
        }
    }
}

/// Go: `tombstones.WriteFile(logger, dir, tombstones.NewMemTombstones())` — the last file `write` produces.
///
/// **Left as a seam on purpose (exception 26).** The tombstone FILE codec is `tsdb/tombstones`' and landed in
/// a parallel slice as `Sources/PromTombstones/TombstoneFile.swift`; conforming that to this protocol is a
/// two-line follow-up once both branches are on `main`. With no writer installed the block carries no
/// `tombstones` file at all, which `OpenBlock` tolerates — `ReadTombstones` answers an empty `MemTombstones`
/// for a missing file — and which the corpus asserts as a declared difference rather than discovering.
///
/// One thing worth knowing before that follow-up: **exception 29's ordering problem cannot arise here.**
/// `tombstones.Encode` ranges a Go map, so a multi-series tombstones file has no byte order and upstream's
/// own output is not reproducible — but `write` always calls it with a *freshly constructed, empty*
/// `MemTombstones` (there is nothing to delete in a block that has just been populated; the source's
/// deletions were applied by the populate iterators). An empty map has one encoding. So the file this seam
/// will produce IS byte-comparable against Go, and the corpus can be widened to compare its bytes rather
/// than only its name.
public protocol TombstoneFileWriter {
    /// Go: `WriteFile`, returning the byte count. Called with an EMPTY `MemTombstones`: a freshly written
    /// block has no deletions, because the populate iterators have already applied the source's.
    @discardableResult
    func writeEmptyTombstoneFile(fs: any PromFS, dir: String) throws -> Int64
}

/// Go: `LeveledCompactorOptions`, reduced to the fields the write path reads.
public struct LeveledCompactorOptions {
    /// Go: `MaxBlockChunkSegmentSize`. Zero means `chunks.DefaultChunkSegmentSize` — 512 MiB, which is the
    /// BLOCK's segment size and has nothing to do with the head's. Quirk 206.
    public var maxBlockChunkSegmentSize: Int64 = 0
    /// The tombstone file writer; see ``TombstoneFileWriter`` and exception 26.
    public var tombstoneWriter: (any TombstoneFileWriter)?
    /// **Not upstream's, and it is exception 27.** `Write` names its block
    /// `ulid.MustNew(ulid.Now(), rand.Reader)` with `crypto/rand` reached directly — there is no seam in
    /// v3.13.2, so a caller cannot make the identifier reproducible and neither can a corpus. The port takes
    /// the generator as a parameter whose default is the same wall-clock-plus-entropy value; injecting a
    /// fixed one is what lets the fixture compare `meta.json` and the directory NAME byte for byte instead
    /// of only the index and the chunks.
    public var newULID: @Sendable () -> ULID = { ULID.newRandom() }

    public init() {}
}

/// Go: `tsdb.Compactor` — **declared in full, with two of its three methods unimplemented on purpose.**
///
/// The scoping question this settles, because §7j is the caller and asked for it before it was written: a
/// `write`-only protocol would be smaller and honest about what §7i(a) ships, and it is still the wrong seam.
/// `db.go`'s `compactBlocks` calls `Plan` and `Compact`, `compactHead` calls `Write`, and all three go through
/// the same `db.compactor` field — so a narrow protocol would have to be *widened* when §7j lands, which is
/// source-breaking for every conformer and invites §7j to declare a second protocol beside this one instead.
/// Declaring the shape now costs three lines and one thrown error.
///
/// What the two deferred methods do is throw ``CompactError/plannerUnported`` and
/// ``CompactError/verticalCompactionUnported``, both of which name the slice that owns them. A `db.go` built
/// against this protocol before those land fails loudly at the scheduler rather than compiling into a TSDB
/// that silently never compacts.
public protocol Compactor {
    /// Go: `Plan(dir string) ([]string, error)` — "a set of directories that can be compacted concurrently".
    ///
    /// §7j. It needs `blockDirs`/`readMetaFile` over a directory of blocks, plus `plan`, `selectDirs`,
    /// `selectOverlappingDirs` and `splitByRange`, none of which is here.
    func plan(dir: String) throws -> [String]

    /// Go: `Write(dest string, b BlockReader, mint, maxt int64, base *BlockMeta) ([]ulid.ULID, error)`.
    ///
    /// "No Block is written when resulting Block has 0 samples and returns an empty slice."
    func write(
        dest: String, block: any BlockReader, mint: Int64, maxt: Int64, base: BlockMeta?
    ) throws -> [ULID]

    /// Go: `Compact(dest string, dirs []string, open []*Block) ([]ulid.ULID, error)`.
    ///
    /// §7j. It needs `CompactBlockMetas` and `storage.NewMergeChunkSeriesSet`, and `storage/merge.go` is not
    /// ported.
    func compact(dest: String, dirs: [String], open: [Block]) throws -> [ULID]
}

/// Go: `LeveledCompactor`.
public final class LeveledCompactor: Compactor {
    let fs: any PromFS
    /// Go: `ranges`. Read only by `plan`/`selectDirs`, which are §7j's — kept because
    /// `NewLeveledCompactorWithOptions` REJECTS an empty one, and that rejection is on the write path.
    public let ranges: [Int64]
    let maxBlockChunkSegmentSize: Int64
    let tombstoneWriter: (any TombstoneFileWriter)?
    let newULID: @Sendable () -> ULID

    /// Go: `NewLeveledCompactor` — `NewLeveledCompactorWithOptions` with `EnableOverlappingCompaction: true`
    /// and everything else defaulted.
    public convenience init(fs: any PromFS, ranges: [Int64]) throws {
        try self.init(fs: fs, ranges: ranges, options: LeveledCompactorOptions())
    }

    /// Go: `NewLeveledCompactorWithOptions`.
    ///
    /// The four defaults it fills in are `chunkenc.NewPool()` (dropped — exception 4, the port has no pool),
    /// `promslog.NewNopLogger()` (dropped — no logger), `storage.NewCompactingChunkSeriesMerger` (unported;
    /// see ``CompactError/verticalCompactionUnported``) and `index.EncodePostingsRaw`, which is the only
    /// encoder `PromIndex` has. What survives is the ONE validation: an empty range list is refused, before
    /// anything else.
    public init(fs: any PromFS, ranges: [Int64], options: LeveledCompactorOptions) throws {
        if ranges.isEmpty {
            throw CompactError.noRanges
        }
        self.fs = fs
        self.ranges = ranges
        self.maxBlockChunkSegmentSize =
            options.maxBlockChunkSegmentSize == 0
            ? ChunkWriter.defaultSegmentSize : options.maxBlockChunkSegmentSize
        self.tombstoneWriter = options.tombstoneWriter
        self.newULID = options.newULID
    }

    /// Go: `LeveledCompactor.Plan`. **§7j** — see the ``Compactor`` protocol.
    public func plan(dir: String) throws -> [String] {
        throw CompactError.plannerUnported
    }

    /// Go: `LeveledCompactor.Compact`. **§7j** — see the ``Compactor`` protocol.
    public func compact(dest: String, dirs: [String], open: [Block]) throws -> [ULID] {
        throw CompactError.verticalCompactionUnported(readers: dirs.count)
    }

    /// Go: `LeveledCompactor.Write(dest, b, mint, maxt, base)`.
    ///
    /// Returns `[]` — not an error — when the populated block turned out to have no samples. Upstream's own
    /// comment on the `Compactor` interface: "No Block is written when resulting Block has 0 samples and
    /// returns an empty slice."
    ///
    /// `base` is the block this one supersedes. It contributes a single `Parents` entry and, if it carries
    /// either hint, the hint — which is how an out-of-order block stays marked across a rewrite. Nothing in
    /// the port produces one yet; the arm is here because `Write`'s shape is the contract §7j will call.
    @discardableResult
    public func write(
        dest: String, block: any BlockReader, mint: Int64, maxt: Int64, base: BlockMeta?
    ) throws -> [ULID] {
        let uid = newULID()

        var meta = BlockMeta(ulid: uid, minTime: mint, maxTime: maxt)
        meta.compaction.level = 1
        // A level-1 block is its own source. `CompactBlockMetas` unions the sources of its inputs; `Write`
        // has no inputs to union, so the new ULID is the whole list.
        meta.compaction.sources = [uid]

        if let base {
            meta.compaction.parents = [
                BlockDesc(ulid: base.ulid, minTime: base.minTime, maxTime: base.maxTime)
            ]
            if base.compaction.fromOutOfOrder() {
                meta.compaction.setOutOfOrder()
            }
            if base.compaction.fromStaleSeries() {
                meta.compaction.setStaleSeries()
            }
        }

        try writeBlock(dest: dest, meta: &meta, populator: DefaultBlockPopulator(), blocks: [block])

        if meta.stats.numSamples == 0 {
            return []
        }
        return [uid]
    }

    /// Go: `LeveledCompactor.write(dest, meta, blockPopulator, blocks...)`.
    ///
    /// The name differs from Go's only because Swift has no lower/upper-case pair to distinguish it from
    /// ``write(dest:block:mint:maxt:base:)``.
    ///
    /// The `closers` discipline is upstream's and it is not tidiness: the writers are closed EXPLICITLY
    /// before the meta is written, with the deferred close left in place for the error paths. Upstream's
    /// comment says why — Windows cannot delete an open file — and the port keeps the ordering because
    /// `meta.Stats.NumSamples` is only trustworthy once `PopulateBlock` has returned, and the index file is
    /// only complete once `Close` has written its postings and TOC.
    func writeBlock(
        dest: String, meta: inout BlockMeta, populator: any BlockPopulator,
        blocks: [any BlockReader]
    ) throws {
        let dir = dest + "/" + meta.ulid.description
        let tmp = dir + tmpForCreationBlockDirSuffix

        // Go: `defer func() { … os.RemoveAll(tmp) … }()`. "RemoveAll returns no error when tmp doesn't
        // exist so it is safe to always run it" — which is why the successful path, having renamed `tmp`
        // away, still runs it.
        defer { removeAll(tmp) }

        removeAll(tmp)
        try fs.createDirectory(tmp)

        let chunkw: ChunkWriter
        do {
            chunkw = try ChunkWriter(
                fs: fs, dir: blockChunkDir(tmp), segmentSize: maxBlockChunkSegmentSize)
        } catch {
            throw CompactError.openChunkWriter(error)
        }
        // `meta.Compaction.Level == 1` wraps the writer in `instrumentedChunkWriter` here; see the file
        // header on why that is a comment rather than a type.

        let indexw: IndexWriter
        do {
            indexw = try IndexWriter(fs: fs, path: tmp + "/" + indexFilename)
        } catch {
            throw CompactError.openIndexWriter(error)
        }

        var closed = false
        // Go's `closers` slice, which the deferred `closeAll` drains on an error path.
        func closeWriters() throws {
            if closed { return }
            closed = true
            var errs: [any Error] = []
            do { try chunkw.close() } catch { errs.append(error) }
            do { try indexw.close() } catch { errs.append(error) }
            if let first = errs.first { throw first }
        }
        defer { try? closeWriters() }

        do {
            try populator.populateBlock(
                blocks: blocks, meta: &meta, indexw: indexw, chunkw: chunkw,
                postingsFunc: allSortedPostings)
        } catch {
            throw CompactError.populateBlock(error)
        }

        try closeWriters()

        // Populated block is empty, so exit early — see the file header, quirk 200.
        if meta.stats.numSamples == 0 {
            return
        }

        do {
            try BlockMeta.writeMetaFile(fs: fs, dir: tmp, meta: &meta)
        } catch {
            throw CompactError.writeMergedMeta(error)
        }

        // Go: `tombstones.WriteFile(c.logger, tmp, tombstones.NewMemTombstones())`. Exception 26.
        if let tombstoneWriter {
            try tombstoneWriter.writeEmptyTombstoneFile(fs: fs, dir: tmp)
        }

        try fs.syncDirectory(tmp)

        // Go: `fileutil.Replace(tmp, dir)`. ADR-15 has no rename, so the tree is copied and the source
        // removed — end state identical, crash window not. Exception 28.
        try replaceDirectory(from: tmp, to: dir)
    }

    /// Go's `os.RemoveAll` semantics: a path that does not exist is not an error.
    private func removeAll(_ path: String) {
        if fs.exists(path) {
            try? fs.remove(path)
        }
    }

    /// Go: `fileutil.Replace(from, to)`, as ADR-15 permits it. See exception 28.
    private func replaceDirectory(from: String, to: String) throws {
        removeAll(to)
        try copyTree(from: from, to: to)
        removeAll(from)
        try fs.syncDirectory(parentPath(to))
    }

    /// A recursive directory copy. `PromFS` has no "is this a directory" predicate, so the test is whether
    /// `list` succeeds — which is what both implementations answer for a directory and refuse for a file.
    private func copyTree(from: String, to: String) throws {
        try fs.createDirectory(to)
        for name in try fs.list(from) {
            let src = from + "/" + name
            let dst = to + "/" + name
            if (try? fs.list(src)) != nil {
                try copyTree(from: src, to: dst)
                continue
            }
            let r = try fs.openForReading(src)
            let bytes = try r.read(offset: 0, length: r.size)
            try r.close()
            let w = try fs.createFile(dst)
            try w.append(bytes)
            try w.flush()
            try w.sync()
            try w.close()
        }
    }

    private func parentPath(_ p: String) -> String {
        var parts = p.split(separator: "/").map(String.init)
        parts.removeLast()
        return parts.joined(separator: "/")
    }
}
