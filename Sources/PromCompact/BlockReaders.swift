//===----------------------------------------------------------------------===//
// Ported from tsdb/block.go @ v3.13.2 — `BlockReader`, `IndexWriter`, `ChunkWriter`, and the adapters that
// let a `RangeHead` stand in for a block.
//
// `LeveledCompactor.write` takes `blocks ...BlockReader`, and `BlockReader` is the ONE interface that a
// `*Block`, a `*Head` and a `*RangeHead` all satisfy. It is what makes "compact a block" and "flush the head
// into a block" the same code path, so it is the seam this slice needs first.
//
// ## The name collision with `tsdb.Block`, settled here
//
// §6m ported `tsdb.Block`'s reading half and called the class `BlockReader`, which was always a misnomer —
// upstream keeps that name for the *interface*, and its own doc comment said "Go: `tsdb.Block`". §7i(a) is
// the first slice that needs the interface and §7j needs it again (`NewBlockQuerier` takes one, and so does
// the retention loop), so rather than invent a third name the class was renamed:
//
//     PromBlock.Block          = tsdb.Block        (the concrete thing `OpenBlock` returns)
//     PromCompact.BlockReader  = tsdb.BlockReader  (the interface `*Block`, `*Head`, `*RangeHead` satisfy)
//
// The three sub-readers cannot take Go's names the same way, because `PromChunks` already has a class
// `ChunkReader` (Go's `chunks.Reader`, a different type from `tsdb.ChunkReader`) and `PromIndex` owns the
// index-reading surface. They are `BlockIndexReader`, `BlockChunkReader` and `BlockTombstoneReader` — "the
// index/chunk/tombstone reader a `BlockReader` hands out", which is exactly what they are.
//
// ## The three reader protocols are narrowed to what `PopulateBlock` actually calls
//
// `tsdb.IndexReader` has seventeen methods; `PopulateBlock` calls four of them (`Symbols`, `Postings`,
// `SortedPostings`, `Series`) and `Close`. Narrowing follows the precedent `PostingsIndex` and
// `LabelQueryIndex` set in §6n — a protocol per call site rather than one per Go interface — and it is what
// lets `HeadIndexReader` satisfy this without also satisfying the label-query half. §7j will widen them as
// `db.go` needs more; widening a protocol whose only conformers live in this repo is additive.
//
// ## `RangeHead` is the compaction input, not `Head`
//
// `db.go` wraps the head in a `RangeHead` per block interval before handing it to the compactor, and
// `BlockWriter` does the same thing implicitly by asking for the head's whole range. The important
// consequence for this port is `RangeHead.Chunks()`: it opens an ISOLATION STATE, and the state has to be
// closed or head truncation blocks forever on it (§7f(a)). `write`'s `closers` list is what does that, so
// the `close()` on these protocols is load-bearing rather than boilerplate.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunks
public import PromHead
public import PromIndex
public import PromLabels
public import PromStorage
public import PromTombstones

/// Go: `tsdb.IndexReader`, narrowed to what `PopulateBlock` calls. See the file header.
public protocol BlockIndexReader: SeriesIndex {
    /// Go: `Symbols() index.StringIter` — sorted, de-duplicated. The port's readers already answer an array
    /// (§7g), so there is no iterator to wrap.
    func symbols() -> [String]
    /// Go: `Postings(ctx, name, values...)`.
    func postings(name: String, values: [String]) throws -> any Postings
    /// Go: `SortedPostings(p)` — by LABEL SET. The identity for a block (its index is already in label
    /// order); a real re-sort for the Head.
    func sortedPostings(_ p: any Postings) -> any Postings
    /// Go: `Close`.
    func close() throws
}

/// Go: `tsdb.ChunkReader`, as `PopulateBlock` reaches it — through the populate iterators, so the surface is
/// §6t's ``BlockChunkSource`` plus `Close`.
public protocol BlockChunkReader: BlockChunkSource {
    /// Go: `Close`. For a head chunk reader this releases the isolation state; see the file header.
    func close() throws
}

/// Go: `tombstones.Reader`, as `PopulateBlock` reaches it — `Get` and `Close`.
public protocol BlockTombstoneReader {
    /// Go: `Get(ref)`.
    func get(_ ref: SeriesRef) throws -> [DeletionInterval]
    /// Go: `Close`.
    func close() throws
}

/// Go: `tsdb.BlockReader`.
public protocol BlockReader {
    /// Go: `Index()`.
    func indexReader() throws -> any BlockIndexReader
    /// Go: `Chunks()`.
    func chunkReader() throws -> any BlockChunkReader
    /// Go: `Tombstones()`.
    func tombstoneReader() throws -> any BlockTombstoneReader
    /// Go: `Meta()`.
    func meta() -> BlockMeta
    /// Go: `Size()`.
    func size() -> Int64
}

// MARK: - The Head, seen as a block

/// Go: `headIndexReader` satisfying `IndexReader`.
///
/// Two shape conversions and nothing else, both of them the "protocol reconciliation" §7g's write-up
/// predicted this slice would need:
///
///   * `Labels` to the `(name, value)` pairs `SeriesIndex` speaks, because §6s was written against the index
///     decoder's output rather than against `PromLabels`;
///   * `chunks.Meta` to ``DecodedChunkMeta``. The `chunk` payload a head meta *could* carry is dropped, which
///     is correct: `appendSeriesChunks` never fills it, and the compactor resolves every meta through the
///     chunk reader.
///
/// `storage.ErrNotFound` becomes `nil`, which is `blockBaseSeriesSet`'s "postings may be stale" SKIP (§6s).
/// Any other error propagates.
public struct HeadBlockIndexReader: BlockIndexReader {
    let reader: HeadIndexReader

    public init(_ reader: HeadIndexReader) { self.reader = reader }

    public func symbols() -> [String] { reader.symbols() }

    public func postings(name: String, values: [String]) throws -> any Postings {
        try reader.postings(name: name, values: values)
    }

    public func sortedPostings(_ p: any Postings) -> any Postings { reader.sortedPostings(p) }

    public func series(_ ref: SeriesRef) throws -> (
        labels: [(name: String, value: String)], chunks: [DecodedChunkMeta]
    )? {
        let resolved: (labels: Labels, chunks: [Meta])
        do {
            resolved = try reader.series(ref)
        } catch StorageError.notFound {
            return nil
        }
        return (
            resolved.labels.map { (name: $0.name, value: $0.value) },
            resolved.chunks.map {
                DecodedChunkMeta(ref: $0.ref.rawValue, minTime: $0.minTime, maxTime: $0.maxTime)
            }
        )
    }

    public func close() throws { try reader.close() }
}

/// Go: `headChunkReader` satisfying `ChunkReader` **and** `ChunkReaderWithCopy`.
///
/// The `copyHeadChunk` flag is what picks between the two, and the third return of the WithCopy form is the
/// open chunk's real `MaxTime` — see ``ChunkOrIterable/maxTime`` and quirk 195. Getting this wrong does not
/// fail loudly: the block is written, `OpenBlock` accepts it, and every last chunk claims it ends at
/// `MaxInt64`.
public struct HeadBlockChunkReader: BlockChunkReader {
    let reader: HeadChunkReader

    public init(_ reader: HeadChunkReader) { self.reader = reader }

    public func chunkOrIterable(_ meta: DecodedChunkMeta, copyHeadChunk: Bool) throws
        -> ChunkOrIterable
    {
        let m = Meta(
            ref: ChunkRef(rawValue: meta.ref), minTime: meta.minTime, maxTime: meta.maxTime)
        if copyHeadChunk {
            let (chunk, iterable, maxTime) = try reader.chunkOrIterableWithCopy(meta: m)
            guard let chunk else {
                return ChunkOrIterable(chunk: nil, iterable: iterable, maxTime: nil)
            }
            return ChunkOrIterable(
                chunk: (encoding: chunk.encoding, bytes: chunk.bytes), iterable: iterable,
                maxTime: maxTime)
        }
        let (chunk, iterable) = try reader.chunkOrIterable(meta: m)
        guard let chunk else {
            return ChunkOrIterable(chunk: nil, iterable: iterable, maxTime: nil)
        }
        return ChunkOrIterable(
            chunk: (encoding: chunk.encoding, bytes: chunk.bytes), iterable: iterable, maxTime: nil)
    }

    public func close() throws { try reader.close() }
}

/// Go: `*tombstones.MemTombstones` satisfying `tombstones.Reader`.
///
/// A wrapper rather than a conformance on `MemTombstones` itself, because `PromTombstones` sits four tiers
/// below this target and must not learn about compaction.
public struct MemTombstoneBlockReader: BlockTombstoneReader {
    let tombstones: MemTombstones

    public init(_ tombstones: MemTombstones) { self.tombstones = tombstones }

    public func get(_ ref: SeriesRef) throws -> [DeletionInterval] { try tombstones.get(ref) }
    public func close() throws { try tombstones.close() }
}

/// Go: `*RangeHead` satisfying `BlockReader`.
///
/// `db.go` is what builds one — a `RangeHead` per block interval — so this is §7j's entry point rather than
/// this slice's. `BlockWriter.Flush` passes the **`*Head` itself** (blockwriter.go:110), which is
/// ``HeadBlockReader``; both are here because the pair is one line apart upstream and leaving one out would
/// invite the next slice to invent a different shape.
public struct RangeHeadBlockReader: BlockReader {
    public let rangeHead: RangeHead

    public init(_ rangeHead: RangeHead) { self.rangeHead = rangeHead }

    public func indexReader() throws -> any BlockIndexReader {
        HeadBlockIndexReader(rangeHead.index())
    }

    public func chunkReader() throws -> any BlockChunkReader {
        HeadBlockChunkReader(try rangeHead.chunks())
    }

    /// Go: `RangeHead.Tombstones` — the HEAD's tombstones, unfiltered by the range (head.go:1608).
    public func tombstoneReader() throws -> any BlockTombstoneReader {
        MemTombstoneBlockReader(rangeHead.tombstonesReader())
    }

    /// Go: `RangeHead.Meta` — its own ULID sentinel, and `NumSeries` is the whole head's.
    public func meta() -> BlockMeta { rangeHead.meta() }

    /// Go: `RangeHead.Size`, which is `h.head.Size()`.
    public func size() -> Int64 { rangeHead.size() }
}

/// Go: `*Head` satisfying `BlockReader` — the reader `BlockWriter.Flush` actually passes.
///
/// Note what that means for the range: `Head.Index()`/`Head.Chunks()` are the WHOLE head, not a window, and
/// `Flush` narrows the block instead through the `mint`/`maxt` it passes to `Write`. The narrowing therefore
/// happens in `PopulateBlock`'s series set (`meta.MinTime`, `meta.MaxTime-1`) and nowhere else.
///
/// `Head.Chunks()` opens an isolation state over `[MinInt64, MaxInt64]`, which `write`'s closer list releases.
public struct HeadBlockReader: BlockReader {
    public let head: Head

    public init(_ head: Head) { self.head = head }

    public func indexReader() throws -> any BlockIndexReader {
        HeadBlockIndexReader(head.index())
    }

    public func chunkReader() throws -> any BlockChunkReader {
        HeadBlockChunkReader(try head.chunks())
    }

    public func tombstoneReader() throws -> any BlockTombstoneReader {
        MemTombstoneBlockReader(head.tombstonesReader())
    }

    /// Go: `Head.Meta` — `headULID`, the head's live min/max, and `NumSeries`. Upstream's own comment: "The
    /// head is dynamic so will return dynamic results."
    public func meta() -> BlockMeta { head.meta() }

    public func size() -> Int64 { head.size() }
}
