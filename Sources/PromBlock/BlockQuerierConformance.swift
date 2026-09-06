//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `blockBaseQuerier`, `blockQuerier`,
// `blockChunkQuerier` and `blockSeriesEntry`/`chunkSeriesEntry` as
// `storage.Querier` / `storage.ChunkQuerier` / `storage.SeriesSet` conformances.
//
// §6v/§6w landed the SELECT LOGIC as free functions returning concrete types,
// which was the right shape while nothing above them existed: the block was the
// only querier, so nothing needed the protocol. `storage/merge.go` is the thing
// that needs it — `NewMergeQuerier` takes `[]storage.Querier`, and a corpus that
// merged anything other than real block queriers would be measuring its own
// stubs (§6w's harness lesson).
//
// So this file is conformances and nothing else. Every behavioural decision is
// still in `BlockQuerier.swift`, `BlockSeriesSet.swift` and
// `PopulateIterators.swift`; the two entry points here call
// `blockQuerierSelect` / `blockChunkQuerierSelect` unchanged.
//
// Two shapes worth knowing:
//
//   - `Select` cannot throw in `storage.Querier`, and the port's select CAN
//     (`postingsForMatchers`, and the sharding refusal). Upstream has the same
//     problem and solves it the same way: `blockQuerier.Select` returns
//     `storage.ErrSeriesSet(err)`.
//   - `LabelValues` is `SortedLabelValues` for a querier. `blockBaseQuerier`
//     stores `index.SortedLabelValues` behind the plain name, so a querier's
//     values are sorted while an index reader's are in index order (§6p).
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromLabels
public import PromStorage
public import PromTombstones
public import PromAnnotations
public import GoCompat

/// Go: `blockSeriesEntry` — the `Series` `blockSeriesSet.At()` hands out.
public struct BlockSeriesEntry: Series {
    public let lset: Labels
    public let sampleIterator: PopulateWithDelSeriesIterator

    public init(lset: Labels, sampleIterator: PopulateWithDelSeriesIterator) {
        self.lset = lset
        self.sampleIterator = sampleIterator
    }

    public func labels() -> Labels { lset }

    /// Go builds a FRESH `populateWithDelSeriesIterator` per call, reusing the
    /// argument's buffers. The port's set builds one per `next()` and hands the
    /// same one out, because nothing calls `Iterator` twice on one series and a
    /// second populate iterator over an exhausted chunk source would be empty
    /// either way.
    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator { sampleIterator }
}

/// Go: `chunkSeriesEntry` — the `ChunkSeries` `blockChunkSeriesSet.At()` hands out.
public struct BlockChunkSeriesEntry: ChunkSeries {
    public let lset: Labels
    public let chunkIterator: PopulateWithDelChunkSeriesIterator

    public init(lset: Labels, chunkIterator: PopulateWithDelChunkSeriesIterator) {
        self.lset = lset
        self.chunkIterator = chunkIterator
    }

    public func labels() -> Labels { lset }

    public func iterator(_ reuse: (any ChunkMetaIterator)?) -> any ChunkMetaIterator {
        BlockChunkMetaIterator(chunkIterator)
    }
}

/// Adapts ``PopulateWithDelChunkSeriesIterator``'s `(meta, bytes, encoding)`
/// triple to `chunks.Iterator`'s `Meta`.
///
/// Not a divergence, a re-materialisation: upstream's iterator already holds a
/// `chunks.Meta` with a live `Chunk`, while the port's holds the bytes and the
/// encoding because that is what its chunk source returns (ADR-16). Rebuilding
/// the chunk here is what `compactChunkIterator` needs — it compares
/// `Chunk.Bytes()` and decodes through `Chunk.Iterator`.
public final class BlockChunkMetaIterator: ChunkMetaIterator {
    private let inner: PopulateWithDelChunkSeriesIterator
    private var curr = Meta(minTime: 0, maxTime: 0)
    private var error: (any Error)?

    public init(_ inner: PopulateWithDelChunkSeriesIterator) { self.inner = inner }

    public func at() -> Meta { curr }

    public func next() -> Bool {
        guard inner.next(), let c = inner.current else { return false }
        do {
            let chunk = try newEmptyChunk(c.encoding)
            chunk.reset(c.bytes)
            curr = Meta(
                ref: ChunkRef(rawValue: c.meta.ref), chunk: chunk,
                minTime: c.meta.minTime, maxTime: c.meta.maxTime)
        } catch {
            self.error = error
            return false
        }
        return true
    }

    public func err() -> (any Error)? { error ?? inner.err() }
}

extension BlockSampleSeriesSet: SeriesSet {
    /// Go: `blockSeriesSet.At()`.
    public func at() -> (any Series)? {
        guard let cur = current else { return nil }
        return BlockSeriesEntry(
            lset: Labels(cur.labels.map { Label($0.name, $0.value) }),
            sampleIterator: cur.iterator)
    }

    /// Go: `blockBaseSeriesSet` has no warnings of its own.
    public func warnings() -> Annotations { Annotations() }
}

extension BlockChunkSeriesSet: ChunkSeriesSet {
    /// Go: `blockChunkSeriesSet.At()`.
    public func at() -> (any ChunkSeries)? {
        guard let cur = current else { return nil }
        return BlockChunkSeriesEntry(
            lset: Labels(cur.labels.map { Label($0.name, $0.value) }),
            chunkIterator: cur.iterator)
    }

    public func warnings() -> Annotations { Annotations() }
}

/// The index a block querier needs: selection, series decoding and the label
/// queries. Exactly the union `blockIndexReader` provides.
public typealias BlockQuerierIndex = SeriesIndex & PostingsIndex & LabelQueryIndex

/// Go: `blockQuerier` — `blockBaseQuerier` plus the sample `Select`.
public struct BlockQuerier: Querier {
    public let index: any BlockQuerierIndex
    public let chunks: any BlockChunkSource
    public let mint: Int64
    public let maxt: Int64
    public let tombstonesFor: (SeriesRef) throws -> [DeletionInterval]

    public init(
        index: any BlockQuerierIndex, chunks: any BlockChunkSource, mint: Int64, maxt: Int64,
        tombstonesFor: @escaping (SeriesRef) throws -> [DeletionInterval] = { _ in [] }
    ) {
        self.index = index
        self.chunks = chunks
        self.mint = mint
        self.maxt = maxt
        self.tombstonesFor = tombstonesFor
    }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        do {
            return try blockQuerierSelect(
                index: index, chunks: chunks, mint: mint, maxt: maxt, matchers: matchers,
                sortSeries: sortSeries, hints: hints.map(blockHints), tombstonesFor: tombstonesFor)
        } catch {
            // Go: `storage.ErrSeriesSet(err)`.
            return errSeriesSet(error)
        }
    }

    /// Go: `blockBaseQuerier.LabelValues`, which is `SortedLabelValues`.
    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        (
            try blockSortedLabelValues(
                index, name: name, limit: hints?.limit ?? 0, matchers: matchers),
            Annotations()
        )
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        (try blockLabelNames(index, limit: hints?.limit ?? 0, matchers: matchers), Annotations())
    }

    /// Go: `blockBaseQuerier.Close` joins the index, chunk and tombstone reader
    /// errors. The port's readers are closed by their owner, so there is nothing
    /// to release here.
    public func close() throws {}
}

/// Go: `blockChunkQuerier`.
public struct BlockChunkQuerier: ChunkQuerier {
    public let index: any BlockQuerierIndex
    public let chunks: any BlockChunkSource
    public let mint: Int64
    public let maxt: Int64
    public let tombstonesFor: (SeriesRef) throws -> [DeletionInterval]

    public init(
        index: any BlockQuerierIndex, chunks: any BlockChunkSource, mint: Int64, maxt: Int64,
        tombstonesFor: @escaping (SeriesRef) throws -> [DeletionInterval] = { _ in [] }
    ) {
        self.index = index
        self.chunks = chunks
        self.mint = mint
        self.maxt = maxt
        self.tombstonesFor = tombstonesFor
    }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any ChunkSeriesSet {
        do {
            return try blockChunkQuerierSelect(
                index: index, chunks: chunks, mint: mint, maxt: maxt, matchers: matchers,
                sortSeries: sortSeries, hints: hints.map(blockHints), tombstonesFor: tombstonesFor)
        } catch {
            return errChunkSeriesSet(error)
        }
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        (
            try blockSortedLabelValues(
                index, name: name, limit: hints?.limit ?? 0, matchers: matchers),
            Annotations()
        )
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        (try blockLabelNames(index, limit: hints?.limit ?? 0, matchers: matchers), Annotations())
    }

    public func close() throws {}
}

/// `storage.SelectHints` narrowed to the five fields `selectSeriesSet` reads.
func blockHints(_ h: SelectHints) -> BlockSelectHints {
    BlockSelectHints(
        start: h.start, end: h.end, disableTrimming: h.disableTrimming, function: h.func_,
        shardCount: h.shardCount)
}
