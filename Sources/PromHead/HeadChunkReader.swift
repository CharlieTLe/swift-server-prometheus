//===----------------------------------------------------------------------===//
// Ported from tsdb/head_read.go @ v3.13.2 — `headChunkReader`, and the ISOLATION-aware chunk iterator.
//
// The other half of §7g. `HeadIndexReader` hands out chunk metas; this turns one back into a chunk, and it is
// where the Head's isolation finally does something visible: a reader must not see samples from an append that
// was still open when the read started, so the iterator is TRUNCATED rather than the chunk being hidden.
//
// ## `memSeries.chunk`'s index arithmetic, which is the whole file in four lines
//
//     ix := int(id) - int(s.firstChunkID)
//
// That maps a `HeadChunkID` onto the concatenation `mmappedChunks ++ headChunks`, and the two halves are stored
// in OPPOSITE orders: `mmappedChunks[0]` is the oldest, while `headChunks` is a list whose FIRST element is the
// newest. So the head-chunk lookup reverses the index (`offset = headChunksLen - ix - 1`), and upstream's
// comment draws the picture. Getting this wrong swaps a series' chunks silently — nothing else would notice.
//
// ## What `stopAfter` counts, and why it is samples rather than chunks
//
// `memSeries.iterator` walks every chunk of the series to work out how many samples precede this one, then
// subtracts the append IDs that belong to later chunks from the ring's count. What is left is how many of this
// chunk's samples were written by appends the reader is allowed to see — and the first append ID the isolation
// state rejects sets `stopAfter`. Three outcomes: 0 (a nop iterator, the chunk is entirely invisible),
// `numSamples` (the plain iterator), or something in between (a `stopIterator`).
//
// ## What is deliberately absent, and where each one goes
//
//   * **The head-chunk CACHE** (`enableCache`, `cachedSeriesRef` and the four fingerprint fields). It is a
//     memoisation of `collectHeadChunks` whose own doc comment says it exists to avoid an O(n²) walk on range
//     queries; the fingerprint (head pointer, mmap length, `firstChunkID`) detects the three ways the layout
//     can change. Pure performance, and the port's `chunk(id:)` takes the same optional pre-collected slice, so
//     the seam is there when it is wanted.
//   * **`ChunkOrIterableWithCopy` and the chunk POOL.** `copyLastChunk` exists so a caller can take the open
//     chunk's bytes without racing an appender; with no concurrency there is nothing to race, and
//     `opts.ChunkPool` is exception 4. The parameter is kept so the two entry points stay distinguishable.
//   * **`memSeries.oooChunk`, `wrapOOOHeadChunk`** — Phase 10.
//   * **`safeHeadChunk`'s locking.** The type stays, because it is what carries the series and chunk ID down to
//     `iterator`; its `Lock`/`Unlock` do not.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromHistogram
public import PromStorage

/// Go: `errors.New("can't read from a closed head")`.
public enum HeadReadError: Error, CustomStringConvertible, Equatable {
    case closedHead

    public var description: String {
        switch self {
        case .closedHead: return "can't read from a closed head"
        }
    }
}

/// Go: `headChunkReader` — "chunk reading for the head block. Not safe for concurrent use."
public final class HeadChunkReader {
    let head: Head
    public let mint: Int64
    public let maxt: Int64
    /// Go: `isoState` — nil means "no isolation for this read", which is not the same as isolation being
    /// disabled: a nil state skips the truncation entirely.
    let isoState: IsolationState?

    init(head: Head, mint: Int64, maxt: Int64, isoState: IsolationState?) {
        self.head = head
        self.mint = mint
        self.maxt = maxt
        self.isoState = isoState
    }

    /// Go: `Close` — closes the isolation state, which is what releases the low-watermark pin that head
    /// truncation waits on. A reader that is never closed blocks truncation forever.
    public func close() throws {
        isoState?.close()
    }

    /// Go: `ChunkOrIterable`. The `Iterable` half is always nil for a head chunk — see ADR-16 on why the
    /// two-result shape is kept anyway.
    public func chunkOrIterable(meta: Meta) throws -> (chunk: (any Chunk)?, iterable: (any ChunkIterable)?) {
        let (chk, _) = try chunk(meta: meta, copyLastChunk: false)
        return (chk, nil)
    }

    /// Go: `ChunkOrIterableWithCopy` — same, plus the chunk's max time. The copy itself is absent (see the file
    /// header); the max time is not, because §6t's populate iterators use it to trim.
    public func chunkOrIterableWithCopy(meta: Meta) throws -> (
        chunk: (any Chunk)?, iterable: (any ChunkIterable)?, maxTime: Int64
    ) {
        let (chk, maxTime) = try chunk(meta: meta, copyLastChunk: true)
        return (chk, nil, maxTime)
    }

    /// Go: `headChunkReader.chunk`.
    func chunk(meta: Meta, copyLastChunk: Bool) throws -> (chunk: any Chunk, maxTime: Int64) {
        let (sid, cid, isOOO) = unpackHeadChunkRef(meta.ref)

        guard let s = head.series.getByID(sid) else {
            // The series has been garbage collected.
            throw StorageError.notFound
        }
        if isOOO {
            // Phase 10. Upstream would answer from `oooMmappedChunks`; a ref with bit 23 set cannot be produced
            // by this port's index reader, so reaching here means a caller invented one.
            throw StorageError.notFound
        }
        return try head.chunkFromSeries(
            s, cid: cid, mint: mint, maxt: maxt, isoState: isoState, copyLastChunk: copyLastChunk)
    }
}

extension Head {

    /// Go: `Head.Chunks` — the whole range, with a fresh isolation state over the whole range.
    public func chunks() throws -> HeadChunkReader {
        try chunksRange(mint: Int64.min, maxt: Int64.max, isoState: iso.state(mint: Int64.min, maxt: Int64.max))
    }

    /// Go: `Head.chunksRange`. Refuses a CLOSED head, and clamps `mint` the same way `indexRange` does.
    public func chunksRange(mint: Int64, maxt: Int64, isoState: IsolationState?) throws -> HeadChunkReader {
        if closed {
            throw HeadReadError.closedHead
        }
        var mint = mint
        let hmin = minTime()
        if hmin > mint {
            mint = hmin
        }
        return HeadChunkReader(head: self, mint: mint, maxt: maxt, isoState: isoState)
    }

    /// Go: `Head.chunkFromSeries` (the in-order half).
    ///
    /// The range check is on the CHUNK, not on the samples: a chunk that does not overlap `[mint, maxt]` is
    /// `ErrNotFound` rather than an empty chunk — and since the index reader reports the open chunk's maxTime as
    /// `MaxInt64`, the two agree about which chunks a querier will ask for.
    func chunkFromSeries(
        _ s: MemSeries, cid: HeadChunkID, mint: Int64, maxt: Int64, isoState: IsolationState?,
        copyLastChunk: Bool
    ) throws -> (chunk: any Chunk, maxTime: Int64) {
        let (c, isHeadChunk, isOpen) = try s.chunk(id: cid, chunkDiskMapper: chunkDiskMapper)

        // This means that the chunk is outside the specified range.
        if !c.overlapsClosedInterval(mint, maxt) {
            throw StorageError.notFound
        }

        var chk = c.chunk
        let maxTime = c.maxTime
        if isHeadChunk && isOpen && copyLastChunk {
            // Upstream copies the bytes here so a caller can take them without racing an appender, and gets the
            // replacement chunk from `opts.ChunkPool`. With no concurrency and no pool, the copy is a `reset`
            // onto a fresh chunk of the same encoding — which is the same value, and keeps the call site's
            // intent visible.
            chk = try newEmptyChunk(c.chunk.encoding)
            chk.reset(c.chunk.bytes)
        }

        return (
            SafeHeadChunk(chunk: chk, series: s, cid: cid, isoState: isoState), maxTime
        )
    }
}

extension MemSeries {

    /// Go: `memSeries.chunk` — the chunk for a `HeadChunkID`, from memory or by m-mapping it back.
    ///
    /// Returns what upstream returns minus the pooling: the chunk, whether it came from the head list, and
    /// whether it is the OPEN one. See the file header for the index arithmetic and why the head half is
    /// reversed.
    ///
    /// `headChunks` is upstream's optional pre-collected slice (the reader's cache). Passing nil takes the
    /// linked-list walk, which is what the port always does.
    public func chunk(
        id: HeadChunkID, chunkDiskMapper: ChunkDiskMapper, headChunks: [MemChunk]? = nil
    ) throws -> (chunk: MemChunk, isHeadChunk: Bool, isOpen: Bool) {
        var ix = Int(id.rawValue) - Int(firstChunkID.rawValue)

        var headChunksLen = 0
        if let headChunks {
            headChunksLen = headChunks.count
        } else if let headChunksList = self.headChunks {
            headChunksLen = headChunksList.len()
        }

        if ix < 0 || ix > mmappedChunks.count + headChunksLen - 1 {
            throw StorageError.notFound
        }

        if ix < mmappedChunks.count {
            // Upstream PANICS on a `CorruptionErr` here and returns any other error; the port's
            // `chunk(ref:)` throws either way, and §7d's corpus pins which is which.
            let (encoding, bytes) = try chunkDiskMapper.chunk(ref: mmappedChunks[ix].ref)
            let chk = try newEmptyChunk(encoding)
            chk.reset(bytes)
            return (
                MemChunk(
                    chunk: chk, minTime: mmappedChunks[ix].minTime,
                    maxTime: mmappedChunks[ix].maxTime, prev: nil),
                false, false
            )
        }

        // Head chunk lookup.
        ix -= mmappedChunks.count

        if let headChunks {
            // Fast path: the pre-collected slice is oldest-first, so it indexes directly.
            if ix >= headChunks.count {
                throw StorageError.notFound
            }
            return (headChunks[ix], true, ix == headChunks.count - 1)
        }

        // The list runs NEWEST first while the ID space runs oldest first, so the index is reversed.
        let offset = headChunksLen - ix - 1
        guard let elem = headChunks?.first ?? self.headChunks?.atOffset(offset) else {
            // "This should never really happen and would mean that headChunksLen value is NOT equal to the
            // length of the headChunks list."
            throw StorageError.notFound
        }
        return (elem, true, offset == 0)
    }

    /// Go: `memSeries.iterator` — the chunk's iterator, truncated to what this read is allowed to see.
    ///
    /// See the file header for what `stopAfter` counts. Two guards upstream reaches first: a nil isolation
    /// state, and an isolation state whose isolation is DISABLED — the second is why `IsolationState` keeps
    /// tracking reads even when writes are not isolated (§7f(a)).
    public func iterator(
        id: HeadChunkID, chunk c: any Chunk, isoState: IsolationState?, reuse: (any ChunkIterator)?
    ) -> any ChunkIterator {
        var ix = Int(id.rawValue) - Int(firstChunkID.rawValue)

        let numSamples = c.numSamples
        var stopAfter = numSamples

        if let isoState, !isoState.isolationDisabled {
            var totalSamples = 0  // Total samples in this series.
            var previousSamples = 0  // Samples before this chunk.

            for (j, d) in mmappedChunks.enumerated() {
                totalSamples += Int(d.numSamples)
                if j < ix {
                    previousSamples += Int(d.numSamples)
                }
            }

            ix -= mmappedChunks.count
            if let headChunksList = headChunks {
                // Iterate all head chunks from the oldest to the newest.
                let headChunksLen = headChunksList.len()
                for j in stride(from: headChunksLen - 1, through: 0, by: -1) {
                    guard let chk = headChunksList.atOffset(j) else { continue }
                    let chkSamples = chk.chunk.numSamples
                    totalSamples += chkSamples
                    // The chunk ID is `len(mmappedChunks) + position in the head list`, where position 0 is the
                    // OLDEST chunk — so the list offset is reversed here too.
                    if headChunksLen - 1 - j < ix {
                        previousSamples += chkSamples
                    }
                }
            }

            // Drop the append IDs that belong to samples AFTER this chunk.
            let appendIDsToConsider = Int(txs?.count ?? 0) - (totalSamples - (previousSamples + numSamples))

            // Find the first append ID the isolation state says not to return.
            if var it = txs?.iterator() {
                for index in 0..<max(appendIDsToConsider, 0) {
                    let appendID = it.at()
                    if appendID <= isoState.maxAppendID {  // Easy check first.
                        if !isoState.incompleteAppends.contains(appendID) {
                            it.next()
                            continue
                        }
                    }
                    // Stopped in a previous chunk.
                    stopAfter = max(numSamples - (appendIDsToConsider - index), 0)
                    break
                }
            }
        }

        if stopAfter == 0 {
            return newNopIterator()
        }
        if stopAfter == numSamples {
            return c.iterator(reuse)
        }
        return makeStopIterator(chunk: c, reuse: reuse, stopAfter: stopAfter)
    }
}

/// Go: `safeHeadChunk` — "makes sure that the chunk can be accessed without a race condition".
///
/// What it really does, and what survives the port, is carry the SERIES and the chunk ID alongside the chunk,
/// so `Iterator` can build an isolation-aware iterator instead of the chunk's own. The locking is absent (see
/// the file header) but the indirection is not: without it, a querier holding a chunk could not know which
/// series' append ring to consult.
public final class SafeHeadChunk: Chunk {
    let underlying: any Chunk
    let series: MemSeries
    let cid: HeadChunkID
    let isoState: IsolationState?

    init(chunk: any Chunk, series: MemSeries, cid: HeadChunkID, isoState: IsolationState?) {
        self.underlying = chunk
        self.series = series
        self.cid = cid
        self.isoState = isoState
    }

    public var bytes: [UInt8] { underlying.bytes }
    public var encoding: Encoding { underlying.encoding }
    public var numSamples: Int { underlying.numSamples }
    public func makeAppender() throws -> any ChunkAppender { try underlying.makeAppender() }
    public func compact() { underlying.compact() }
    public func reset(_ stream: [UInt8]) { underlying.reset(stream) }

    /// Go: `safeHeadChunk.Iterator` — the one method that is not a forward.
    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        series.iterator(id: cid, chunk: underlying, isoState: isoState, reuse: reuse)
    }
}

/// Go: `stopIterator` — an iterator that yields only the first `stopAfter` values.
///
/// The `i == -1` start is load-bearing: `Next` tests `i+1 >= stopAfter` BEFORE advancing, so a `stopAfter` of 1
/// yields exactly one sample. It also means the wrapped iterator is never advanced past the limit, which is
/// what keeps the XOR decoder from reading a partially written sample.
public final class StopIterator: ChunkIterator {
    var inner: any ChunkIterator
    var i: Int
    var stopAfter: Int

    init(inner: any ChunkIterator, i: Int, stopAfter: Int) {
        self.inner = inner
        self.i = i
        self.stopAfter = stopAfter
    }

    public func next() -> ValueType {
        if i + 1 >= stopAfter {
            return .none
        }
        i += 1
        return inner.next()
    }

    /// Everything else forwards. Note `seek` is NOT overridden upstream either — the embedded interface
    /// provides it — so a `Seek` past the limit is **not** truncated. That is a real hole in the isolation
    /// guarantee, and it is upstream's: `stopIterator` only bounds `Next`.
    public func seek(_ t: Int64) -> ValueType { inner.seek(t) }
    public func at() -> (Int64, Double) { inner.at() }
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) { inner.atHistogram(reuse) }
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        inner.atFloatHistogram(reuse)
    }
    public func atT() -> Int64 { inner.atT() }
    public func atST() -> Int64 { inner.atST() }
    public func err() -> (any Error)? { inner.err() }
}

/// Go: `makeStopIterator` — reuses the passed iterator when it is already a `stopIterator`, which is the reuse
/// contract `chunkenc.Iterator` callers rely on.
public func makeStopIterator(
    chunk c: any Chunk, reuse: (any ChunkIterator)?, stopAfter: Int
) -> any ChunkIterator {
    if let stopIter = reuse as? StopIterator {
        stopIter.inner = c.iterator(stopIter.inner)
        stopIter.i = -1
        stopIter.stopAfter = stopAfter
        return stopIter
    }
    return StopIterator(inner: c.iterator(reuse), i: -1, stopAfter: stopAfter)
}
