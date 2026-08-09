//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/chunks.go @ v3.13.2
//
// **Minimal.** Only what `storage`'s chunk-query protocols refer to: the chunk
// reference, `Meta`, and the chunk iterator. The segment file reader and writer,
// `ChunkDiskMapper`, `ChunkFromSamples` and the ref bit-packing helpers arrive
// with Phase 6, where the on-disk format is the subject.
//===----------------------------------------------------------------------===//

public import PromChunkEnc

/// Go: `chunks.ChunkRef` — an opaque reference a `ChunkReader` can resolve.
public struct ChunkRef: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Go: `chunks.Meta` — information about one or more chunks.
///
/// Either `ref` resolves to the data through a `ChunkReader`, or `chunk` holds it
/// directly. `chunk` being nil means "call `chunkOrIterable(ref)`"; that call may
/// return an iterable spanning several chunks, in which case `chunk` cannot be
/// filled in at all.
public struct Meta {
    public var ref: ChunkRef
    public var chunk: (any Chunk)?

    /// Time range the data covers. `maxTime == Int64.max` means the chunk is
    /// still open and being appended to.
    public var minTime: Int64
    public var maxTime: Int64

    public init(
        ref: ChunkRef = ChunkRef(rawValue: 0), chunk: (any Chunk)? = nil,
        minTime: Int64, maxTime: Int64
    ) {
        self.ref = ref
        self.chunk = chunk
        self.minTime = minTime
        self.maxTime = maxTime
    }

    /// Go: `Meta.OverlapsClosedInterval`. Both intervals are closed.
    public func overlapsClosedInterval(mint: Int64, maxt: Int64) -> Bool {
        minTime <= maxt && mint <= maxTime
    }
}

/// Go: `chunks.Iterator` — iterates the chunks of a single time series.
///
/// `AnyObject` for the same reason as `ChunkIterator`: cursor state, mutated in
/// place.
public protocol ChunkMetaIterator: AnyObject {
    /// Go: `At`. Whether the returned `Meta` has its chunk populated is
    /// implementation-dependent.
    func at() -> Meta
    /// Go: `Next`.
    func next() -> Bool
    /// Go: `Err` — set when `next()` returned false because of a failure.
    func err() -> (any Error)?
}
