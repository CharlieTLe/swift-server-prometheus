//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `populateWithDelGenericSeriesIterator` and
// `populateWithDelSeriesIterator`.
//
// The iterators that turn a `SeriesData` (§6s) into samples: walk the chunk metas, fetch each chunk, and apply
// the deletion intervals — including the synthetic trimming ones §6s computed. **This is where trimming
// becomes observable**, which is what closes five of `controls-blockseriesset.sh`'s declared gaps.
//
// ## `currDelIter` is nil or not, and that IS the decision
//
// `next(copyHeadChunk:)` ends in one of two states, and the whole design is in which:
//
//     currDelIter == nil  → the chunk is usable AS IS; the caller iterates `currMeta.Chunk` directly
//     currDelIter != nil  → the chunk must be re-read through `bufIter`, sample by sample
//
// It is nil only when a single chunk came back AND no deletion interval overlaps it. Everything else — an
// overlap, or an iterable instead of a chunk (ADR-16) — installs `bufIter`. Upstream's comment on the field
// says it outright: "If currDelIter is not nil, it means that the chunk in currMeta is invalid and a chunk
// rewrite is needed."
//
// ## The interval list is REBUILT per chunk, and that is what makes `DeletedIterator` safe to reuse
//
// `p.bufIter.Intervals = p.bufIter.Intervals[:0]` then, for each interval overlapping this chunk,
// `Add(interval)`. So `DeletedIterator`'s consuming behaviour (quirk 164) never bites: it gets a fresh,
// per-chunk list every time. **A port that hoisted the list out of the loop would work on the first chunk and
// silently under-delete on the rest** — the exact failure quirk 164 describes, arrived at from the other side.
//
// Note the filter is `OverlapsClosedInterval`, so an interval touching a chunk's boundary counts.
//
// ## `Next` resumes the current chunk before advancing, and `Seek` resumes before calling `Next`
//
// Both start with `if p.curr != nil { … }` — so the outer iterator is a flat view over concatenated chunks and
// a `Seek` never re-reads a chunk it has already passed. `Seek`'s loop then calls `p.Next()`, not `p.next()`:
// the exported one, which advances *samples*, so a seek target beyond the current chunk walks chunk by chunk
// through the same machinery rather than duplicating it.
//
// ## `i >= len(metas)-1` is the exhaustion test, and it is checked BEFORE the increment
//
// `p.i` starts at -1 and `next` returns false when `p.i >= len(p.metas)-1`. So a series with one meta admits
// exactly one `next`. Written as a post-increment bound it would be off by one, which is why the -1 start and
// the pre-check are one mechanism.
//
// ## `Err` on the outer iterator checks the generic one FIRST
//
// The populate error (`cannot populate chunk %d from block %s`) wins over the current chunk iterator's own.
// Reproduced: a caller that reports only the first error reports the more specific one.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromHistogram
public import PromIndex

/// Go: what `ChunkReader.ChunkOrIterable` returns — see ADR-16 for why both halves exist here when a block
/// only ever fills one.
public struct ChunkOrIterable {
    /// Non-nil when the meta names exactly one chunk, which is always true for a block.
    public var chunk: (encoding: Encoding, bytes: [UInt8])?
    /// Non-nil when the meta names SEVERAL chunks that must be merged on read — the out-of-order head's
    /// shape, Phase 7's. A block leaves this nil.
    public var iterable: (any ChunkIterable)?

    public init(
        chunk: (encoding: Encoding, bytes: [UInt8])? = nil, iterable: (any ChunkIterable)? = nil
    ) {
        self.chunk = chunk
        self.iterable = iterable
    }
}

/// The chunk source the populate iterators read through. ADR-16's seam.
public protocol BlockChunkSource {
    /// Go: `ChunkReader.ChunkOrIterable`.
    ///
    /// `copyHeadChunk` is threaded through and ignored by a block, exactly as upstream's
    /// `ChunkReaderWithCopy` type assertion fails for a block's chunk reader. Not dropped — see ADR-16.
    func chunkOrIterable(_ meta: DecodedChunkMeta, copyHeadChunk: Bool) throws -> ChunkOrIterable
}

/// Go: `fmt.Errorf("cannot populate chunk %d from block %s: %w", …)`.
public enum PopulateError: Error, CustomStringConvertible {
    case cannotPopulateChunk(ref: UInt64, block: String, underlying: any Error)
    /// Not upstream's: upstream never returns both nil, and a silent empty series is the failure mode the
    /// fidelity contract exists to prevent. See ADR-16.
    case neitherChunkNorIterable(ref: UInt64)

    public var description: String {
        switch self {
        case .cannotPopulateChunk(let r, let b, let e):
            return "cannot populate chunk \(r) from block \(b): \(e)"
        case .neitherChunkNorIterable(let r):
            return "chunk \(r) resolved to neither a chunk nor an iterable"
        }
    }
}

/// Go: `populateWithDelGenericSeriesIterator`.
public final class PopulateWithDelGenericSeriesIterator {
    private let blockID: String
    private let source: any BlockChunkSource
    private let metas: [DecodedChunkMeta]
    private let intervals: [DeletionInterval]

    /// Go: `i` — index into `metas`; -1 before the first advance. See the file header on the bound.
    private var i = -1
    private(set) var error: (any Error)?

    /// Go: `bufIter`, retained for reuse. `currDelIter` points here when it is not nil.
    private var bufIter: DeletedIterator?
    /// Go: `currDelIter`. Nil means "the chunk is usable as is".
    private(set) var currDelIter: (any ChunkIterator)?
    /// Go: `currMeta`, with its `Chunk` filled in by `next`.
    private(set) var currMeta: DecodedChunkMeta?
    private(set) var currChunk: (encoding: Encoding, bytes: [UInt8])?

    public init(
        blockID: String, source: any BlockChunkSource, metas: [DecodedChunkMeta],
        intervals: [DeletionInterval]
    ) {
        self.blockID = blockID
        self.source = source
        self.metas = metas
        self.intervals = intervals
    }

    /// Go: `next(copyHeadChunk bool)`.
    func next(copyHeadChunk: Bool) -> Bool {
        // Checked BEFORE the increment; see the file header.
        if error != nil || i >= metas.count - 1 {
            return false
        }
        i += 1
        let meta = metas[i]
        currMeta = meta

        // REBUILT per chunk — this is what makes `DeletedIterator`'s consumption safe. See the file header.
        var chunkIntervals: [DeletionInterval] = []
        for interval in intervals
        where overlapsClosedInterval(meta.minTime, meta.maxTime, interval.mint, interval.maxt) {
            chunkIntervals = chunkIntervals.addingInterval(interval)
        }

        let resolved: ChunkOrIterable
        do {
            // `copyHeadChunk` is honoured only when nothing is deleted, matching upstream's condition
            // `ok && copyHeadChunk && len(p.bufIter.Intervals) == 0`. A block ignores it either way.
            resolved = try source.chunkOrIterable(
                meta, copyHeadChunk: copyHeadChunk && chunkIntervals.isEmpty)
        } catch {
            self.error = PopulateError.cannotPopulateChunk(
                ref: meta.ref, block: blockID, underlying: error)
            return false
        }
        currChunk = resolved.chunk

        if let chunk = resolved.chunk {
            if chunkIntervals.isEmpty {
                // No overlap and a single chunk: take it as it is.
                currDelIter = nil
                return true
            }
            // Otherwise the chunk has to be re-read sample by sample.
            guard let it = iteratorFor(chunk) else {
                self.error = PopulateError.neitherChunkNorIterable(ref: meta.ref)
                return false
            }
            let del = DeletedIterator(iter: it, intervals: chunkIntervals)
            bufIter = del
            currDelIter = del
            return true
        }

        guard let iterable = resolved.iterable else {
            self.error = PopulateError.neitherChunkNorIterable(ref: meta.ref)
            return false
        }
        let del = DeletedIterator(iter: iterable.iterator(nil), intervals: chunkIntervals)
        bufIter = del
        currDelIter = del
        return true
    }

    /// Go: `chunkenc.Chunk.Iterator` after the pool lookup. Only XOR is decodable so far; the histogram
    /// encodings are Phase 7's, and returning nil here produces the explicit error above rather than an
    /// empty series.
    func iteratorFor(_ chunk: (encoding: Encoding, bytes: [UInt8])) -> (any ChunkIterator)? {
        guard chunk.encoding == .xor else { return nil }
        let c = XORChunk()
        c.reset(chunk.bytes)
        return BoxedXOR(c.iterator())
    }

    func err() -> (any Error)? { error }
}

/// Go: `chunks.Meta.OverlapsClosedInterval` — both ranges closed.
func overlapsClosedInterval(_ mint1: Int64, _ maxt1: Int64, _ mint2: Int64, _ maxt2: Int64) -> Bool {
    mint1 <= maxt2 && mint2 <= maxt1
}

/// Go: `populateWithDelSeriesIterator` — a flat sample view over a series' chunks.
public final class PopulateWithDelSeriesIterator: ChunkIterator {
    private let generic: PopulateWithDelGenericSeriesIterator
    /// Go: `curr` — the iterator for the chunk being read.
    private var curr: (any ChunkIterator)?

    public init(
        blockID: String, source: any BlockChunkSource, metas: [DecodedChunkMeta],
        intervals: [DeletionInterval]
    ) {
        self.generic = PopulateWithDelGenericSeriesIterator(
            blockID: blockID, source: source, metas: metas, intervals: intervals)
    }

    /// Go: `Next` — resume the current chunk first, then advance chunks.
    public func next() -> ValueType {
        if let curr {
            let vt = curr.next()
            if vt != .none { return vt }
        }
        while generic.next(copyHeadChunk: false) {
            if let del = generic.currDelIter {
                curr = del
            } else if let chunk = generic.currChunk, let it = generic.iteratorFor(chunk) {
                curr = it
            } else {
                return .none
            }
            let vt = curr!.next()
            if vt != .none { return vt }
        }
        return .none
    }

    /// Go: `Seek` — resume, then walk SAMPLES through `Next`, not chunks through `next`.
    public func seek(_ t: Int64) -> ValueType {
        if let curr {
            let vt = curr.seek(t)
            if vt != .none { return vt }
        }
        while next() != .none {
            if let vt = curr?.seek(t), vt != .none { return vt }
        }
        return .none
    }

    public func at() -> (Int64, Double) { curr?.at() ?? (0, 0) }
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        curr?.atHistogram(reuse) ?? (Int64.min, nil)
    }
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        curr?.atFloatHistogram(reuse) ?? (Int64.min, nil)
    }
    public func atT() -> Int64 { curr?.atT() ?? 0 }
    public func atST() -> Int64 { curr?.atST() ?? 0 }

    /// Go: the generic error wins over the current chunk's. See the file header.
    public func err() -> (any Error)? {
        if let e = generic.err() { return e }
        return curr?.err()
    }
}

/// A reference box around `XORIterator`, which is a value type. Same role as the one in the tests; here
/// because the populate iterators need it in the library.
final class BoxedXOR: ChunkIterator {
    private var it: XORIterator
    init(_ it: XORIterator) { self.it = it }
    func next() -> ValueType { it.next() }
    func seek(_ t: Int64) -> ValueType { it.seek(t) }
    func at() -> (Int64, Double) { it.at }
    func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) { (Int64.min, nil) }
    func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) { (Int64.min, nil) }
    func atT() -> Int64 { it.at.0 }
    /// `xorIterator.AtST` returns 0 — the protocol documents that as "unimplemented/unset".
    func atST() -> Int64 { 0 }
    func err() -> (any Error)? { it.err }
}
