//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `selectSeriesSet`, and with it `blockQuerier.Select` /
// `blockChunkQuerier.Select`.
//
// The last piece of Phase 6's read path: assemble `PostingsForMatchers` (§6n), `BlockBaseSeriesSet` (§6s) and
// the populate iterators (§6t, §6u) into the shape the engine's `Querier` protocol expects.
//
// ## The HINTS override the querier's own range, and that is the surprising part
//
// `newBlockBaseQuerier` stored `mint`/`maxt` at construction, but `selectSeriesSet` throws them away when
// hints are present:
//
//     if hints != nil {
//         mint = hints.Start
//         maxt = hints.End
//         disableTrimming = hints.DisableTrimming
//     }
//
// So a querier built for [0, 100] and selected with hints of [200, 300] reads [200, 300]. The engine relies on
// this — `Select` is called once per selector with per-selector hints — but it means the querier's range is a
// DEFAULT rather than a bound, which is the opposite of what the constructor's signature suggests.
//
// **This override is NOT yet pinned, and the reason is precise.** `block/seriesset.jsonl` builds each
// querier for `[q.Mint, q.Maxt]` and passes hints of exactly the same range, so overriding and not overriding
// are indistinguishable. Removing the two assignments survives; removing `disableTrimming = hints
// .DisableTrimming` breaks. Closing it needs one query per case whose hints DIFFER from the querier's range —
// a two-field addition to `seriesSetQuery` (`hintStart`/`hintEnd`) and the same on the port side. Declared
// here rather than left implicit, in the shape §6s used for its trimming gaps.
//
// ## `Func == "series"` swaps in a chunk reader that returns an empty chunk
//
// Upstream's comment: "When you're only looking up metadata (for example series API), you don't need to load
// any chunks." `newNopChunkReader` returns a shared empty `XORChunk` for every meta — not an error, and not a
// nil chunk. So a series-API query still produces series with chunks that iterate to nothing, rather than
// series with no chunks (which `blockBaseSeriesSet` would have SKIPPED, quirk 166's rule 2). The distinction
// is the whole reason it is a nop reader rather than a nil one.
//
// ## `sortSeries` and sharding are index concerns, not this function's
//
// `SortedPostings` is the identity for a block — `func (*Reader) SortedPostings(p Postings) Postings { return
// p }` — because a block's postings are already in series-ref order and refs are assigned in label order. So
// `sortSeries` is honoured by doing nothing, which is correct rather than unimplemented. `ShardedPostings`
// needs the label hash and belongs with the Head; a sharded hint here throws rather than silently returning
// unsharded results.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromIndex
public import PromLabels
public import PromStorage

/// Go: `storage.SelectHints`, reduced to the fields `selectSeriesSet` reads.
public struct BlockSelectHints: Sendable {
    public var start: Int64
    public var end: Int64
    public var disableTrimming: Bool
    /// Go: `hints.Func`. `"series"` swaps in the nop chunk reader — see the file header.
    public var function: String
    public var shardCount: UInt64

    public init(
        start: Int64, end: Int64, disableTrimming: Bool = false, function: String = "",
        shardCount: UInt64 = 0
    ) {
        self.start = start
        self.end = end
        self.disableTrimming = disableTrimming
        self.function = function
        self.shardCount = shardCount
    }
}

public enum BlockSelectError: Error, CustomStringConvertible {
    /// Not upstream's: `ShardedPostings` needs the label hash and belongs with the Head. Throwing beats
    /// silently returning unsharded results.
    case shardingNotSupported(shardCount: UInt64)

    public var description: String {
        switch self {
        case .shardingNotSupported(let n):
            return "sharded postings (shardCount \(n)) need the Head's label hashing"
        }
    }
}

/// A chunk source that returns an EMPTY chunk for every meta.
///
/// Go: `nopChunkReader`. Deliberately a chunk rather than nil or an error — see the file header on why the
/// distinction matters to `blockBaseSeriesSet`'s skip rules.
public struct NopChunkSource: BlockChunkSource {
    /// Go builds one `chunkenc.NewXORChunk()` and shares it. The bytes of an empty XOR chunk are the two-byte
    /// zero sample count, which is what makes this safe to share.
    private static let emptyXOR: [UInt8] = XORChunk().bytes

    public init() {}

    public func chunkOrIterable(_ meta: DecodedChunkMeta, copyHeadChunk: Bool) throws
        -> ChunkOrIterable
    {
        ChunkOrIterable(chunk: (encoding: .xor, bytes: Self.emptyXOR))
    }
}

/// Go: `selectSeriesSet` — the shared body of `blockQuerier.Select` and `blockChunkQuerier.Select`.
///
/// Returns the series set; the caller wraps it in the sample or chunk iterator it wants (§6t, §6u), which is
/// the only difference between the two queriers upstream.
public func blockSelect(
    index: any SeriesIndex & PostingsIndex, chunks: any BlockChunkSource,
    mint: Int64, maxt: Int64, matchers: [Matcher], sortSeries: Bool = false,
    hints: BlockSelectHints? = nil,
    tombstonesFor: @escaping (SeriesRef) throws -> [DeletionInterval] = { _ in [] }
) throws -> (set: BlockBaseSeriesSet, chunks: any BlockChunkSource) {
    var mint = mint
    var maxt = maxt
    var disableTrimming = false

    if let hints, hints.shardCount > 0 {
        throw BlockSelectError.shardingNotSupported(shardCount: hints.shardCount)
    }

    let p = try postingsForMatchers(index, matchers)
    // `sortSeries` is honoured by doing nothing: `Reader.SortedPostings` is the identity for a block. See
    // the file header — this is correct, not unimplemented.
    _ = sortSeries

    var source = chunks
    if let hints {
        // The hints OVERRIDE the querier's range. See the file header.
        mint = hints.start
        maxt = hints.end
        disableTrimming = hints.disableTrimming
        if hints.function == "series" {
            // Metadata only: no chunks are loaded, but each series still gets an EMPTY chunk rather than
            // none, so it is not skipped.
            source = NopChunkSource()
        }
    }

    let set = BlockBaseSeriesSet(
        index: index, postings: p, mint: mint, maxt: maxt, disableTrimming: disableTrimming,
        tombstonesFor: tombstonesFor)
    return (set, source)
}
