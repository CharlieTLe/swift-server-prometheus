//===----------------------------------------------------------------------===//
// Ported from tsdb/block.go @ v3.13.2 — opening a block directory and joining its index to its chunks.
//
// This is composition rather than new format work: §6d-§6f ported the index reader, §6h and §6l the chunk
// writer and reader, §6k `meta.json`. What is here is the layout that ties them together, and the layout is
// itself a contract:
//
//     <ulid>/meta.json      the block's identity and time range
//     <ulid>/index          one file: symbols, series, postings
//     <ulid>/chunks/000001  one or more segment files
//     <ulid>/tombstones     deletions — NOT ported, see below
//
// ## `meta.json` is read FIRST and its version is checked
//
// `readMetaFile` rejects anything but version 1 with `unexpected meta file version %d`. So a block from a
// future Prometheus fails on the metadata rather than part-way through the index, which is the difference
// between a clear error and a confusing one.
//
// ## Tombstones are not ported, and that is a scoped omission
//
// `tombstones.ReadTombstones` reads a deletion-interval file that `Delete()` writes. Nothing in the port
// deletes yet, and `MemStorage`'s note already records that the interval subtraction has nothing to subtract
// (exception in PORTING.md). A block whose directory HAS a tombstones file still opens; its deletions are
// simply not applied, which is a divergence recorded here rather than a silent one.
//
// ## A series' chunks come from two files and the join is the reference
//
// The index gives a series its labels and its chunk METAS — time ranges plus `BlockChunkRef`s. The refs
// index into the sorted segment list (quirk 142). So reading a series' samples is: index reader for the
// metas, chunk reader for each ref, chunk decoder for the bytes. Nothing else knows how to get from a
// series to a sample.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromFS
public import PromIndex
public import PromStorage

internal import GoCompat
internal import PromEncoding

/// Go: the block reader's errors.
public enum BlockError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `fmt.Errorf("unexpected meta file version %d", m.Version)`.
    case unexpectedMetaVersion(Int)
    case malformedMeta(String)

    public var description: String {
        switch self {
        case .unexpectedMetaVersion(let v): return "unexpected meta file version \(v)"
        case .malformedMeta(let d): return "malformed meta.json: \(d)"
        }
    }
}

/// One series as a block holds it: labels, and the chunks it can be read from.
public struct BlockSeries: Sendable {
    public var labels: [(name: String, value: String)]
    public var chunks: [DecodedChunkMeta]
}

/// Go: `tsdb.Block`, reduced to reading.
public final class BlockReader {
    public let dir: String
    public let meta: BlockMeta
    private let fs: any PromFS
    private let indexBytes: [UInt8]
    private let chunks: ChunkReader

    /// The index's TOC and symbol table, parsed once at open — as `index.NewReader` does.
    private let toc: IndexTOC
    private let symbols: IndexSymbols
    /// The sparse postings index, also built once at open.
    private let sparse: [String: [PostingOffset]]

    /// Go: `OpenBlock`. Reads `meta.json`, then the index, then opens the chunk segments.
    public init(fs: any PromFS, dir: String) throws {
        self.fs = fs
        self.dir = dir

        // `meta.json` first, so a version mismatch fails before any index parsing.
        let metaHandle = try fs.openForReading(dir + "/meta.json")
        let metaBytes = try metaHandle.read(offset: 0, length: metaHandle.size)
        try metaHandle.close()
        self.meta = try BlockMeta(json: metaBytes)

        let indexHandle = try fs.openForReading(dir + "/index")
        self.indexBytes = try indexHandle.read(offset: 0, length: indexHandle.size)
        try indexHandle.close()

        // Parse the index's fixed structures once, the way `index.NewReader` does.
        (self.toc, self.symbols, self.sparse) = try Self.parseIndex(indexBytes)

        self.chunks = try ChunkReader(fs: fs, dir: dir + "/chunks")
    }

    private static func parseIndex(_ bytes: [UInt8]) throws -> (
        IndexTOC, IndexSymbols, [String: [PostingOffset]]
    ) {
        try bytes.withUnsafeBytes { buf in
            let bs = ByteSlice(buf)
            let toc = try IndexTOC(byteSlice: bs)
            let symbols = try IndexSymbols(
                byteSlice: bs, version: indexFormatV2, off: Int(toc.symbols))
            let sparse = try buildPostingsOffsetIndex(bs, postingsTable: toc.postingsTable)
            return (toc, symbols, sparse)
        }
    }

    /// Every label name in the block, sorted, excluding the all-postings key.
    public func labelNames() -> [String] {
        indexLabelNames(sparse)
    }

    /// Every value of one label, in table order.
    public func labelValues(_ name: String, limit: Int = 0) throws -> [String] {
        try indexBytes.withUnsafeBytes { buf in
            try indexLabelValues(
                ByteSlice(buf), postingsTable: toc.postingsTable, sparse: sparse, name: name,
                limit: limit)
        }
    }

    /// The series refs matching one label's values.
    public func postings(name: String, values: [String]) throws -> [SeriesRef] {
        try indexBytes.withUnsafeBytes { buf in
            let bs = ByteSlice(buf)
            let lists = try indexPostings(
                bs, postingsTable: toc.postingsTable, sparse: sparse, name: name, values: values)
            return try expandPostings(merge(lists))
        }
    }

    /// Go: `IndexReader.Series` — a series' labels and chunk metas.
    public func series(_ id: SeriesRef) throws -> BlockSeries {
        try indexBytes.withUnsafeBytes { buf in
            let bs = ByteSlice(buf)
            let decoded = try readSeries(
                bs, id: id.rawValue, version: indexFormatV2,
                lookupSymbol: { try symbols.lookup($0) })
            return BlockSeries(labels: decoded.labels, chunks: decoded.chunks)
        }
    }

    /// **The join.** A series' chunk meta names a segment and an offset; this resolves it to bytes.
    public func chunk(_ meta: DecodedChunkMeta) throws -> (encoding: Encoding, bytes: [UInt8]) {
        try chunks.chunk(ref: ChunkRef(rawValue: meta.ref))
    }

    /// Every sample of one series, in time order, by walking its chunks.
    ///
    /// A convenience the port needs and upstream spells differently (it hands out an iterator through
    /// `ChunkSeriesSet`). Kept simple here because the querier that wants the iterator shape is Phase 7's.
    public func samples(_ id: SeriesRef) throws -> [(t: Int64, v: Double)] {
        let s = try series(id)
        var out: [(t: Int64, v: Double)] = []
        for meta in s.chunks {
            let (enc, bytes) = try chunk(meta)
            // §6 skipped everything but XOR here, with a note that the dispatch "needs the same dispatch the
            // Head will need, which is Phase 7's". §7f(c) built it: `newEmptyChunk` plus the `Chunk`
            // conformance is that dispatch, so both float encodings now decode. The histogram encodings are
            // still absent from `PromChunkEnc` entirely, so `newEmptyChunk` reports them by name rather than
            // this silently skipping them — a block carrying one is now a loud failure instead of a short read.
            guard enc == .xor || enc == .xor2 else { continue }
            let c = try newEmptyChunk(enc)
            c.reset(bytes)
            let it = c.iterator(nil)
            while it.next() == .float {
                let (t, v) = it.at()
                out.append((t, v))
            }
            if let e = it.err() { throw e }
        }
        return out
    }
}
