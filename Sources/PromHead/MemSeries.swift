//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go and tsdb/head_append.go @ v3.13.2 — `memSeries`' in-order CHUNK STATE.
//
// §7f(b) landed `memSeries`' identity (`ref` and `lset`), which is all the series index reads. This is the
// other half: the chunks a series is accumulating, the rules that decide when to cut a new one, and the
// hand-off to `ChunkDiskMapper`. It is the last piece `NewHead` needs.
//
// ## The three cut rules, and the order they are checked in
//
// `appendPreprocessor` is the whole slice in one function, and it decides on FOUR grounds, in this order:
//
//  1. **Size** — `len(chunk.Bytes()) > MaxBytesPerXORChunkBeforeAppend` (1024-19), skipped when the chunk was
//     just created, because a fresh chunk cannot be too large and cutting again would loop.
//  2. **Encoding** — the desired encoding differs and either it is not `CompatibleValues` or ST storage is on.
//     XOR and XOR2 are mutually compatible *until* start timestamps are being stored, at which point mixing
//     them in one chunk would lose the ST of half the samples.
//  3. **Time** — `t >= s.nextAt`, where `nextAt` is an upper bound set at cut time from the chunk RANGE and
//     then revised downwards once, at the quarter-mark, by `computeChunkEndTime`.
//  4. **Count** — `numSamples >= samplesPerChunk*2`, the fallback for when the rate rose and the prediction
//     in (3) was left stale.
//
// Two of those interact in a way worth stating: the quarter-mark prediction reads `c.maxTime`, which is the
// PREVIOUS sample's timestamp, because `append` sets `c.maxTime = t` only after the preprocessor returns.
//
// ## What is deliberately absent, and where each one goes
//
//   * **Out-of-order.** No `ooo` field, no `insert`, no `cutNewOOOHeadChunk`. `OutOfOrderTimeWindow` defaults
//     to 0 and the OOO head is Phase 10. `appendable`'s `oooTimeWindow` parameter stays, because the
//     *decision* is in-order code and the Head passes it whether or not OOO is configured.
//   * **The histogram append path** (`appendHistogram`, `appendFloatHistogram`,
//     `histogramsAppendPreprocessor`) and with it `histogramChunkHasComputedEndTime`, which nothing else
//     reads. §7f defers histograms in the appender; the two `last*HistogramValue` fields are here because
//     `append` nils them and `appendable` branches on them.
//   * **The lock.** `memSeries` embeds a `sync.Mutex` and its doc comment says the caller must hold it. The
//     port has no concurrency yet — see `Isolation.swift` on why adding one would be a claim about a design
//     that has not been made.
//   * **`meta`**, written only by `headAppender.UpdateMetadata`.
//
// ## `rangeForTimestamp` lives in db.go upstream
//
// It is here because `appendPreprocessor` and `cutNewHeadChunk` are its only callers in this slice and §7j is
// a long way off. Move it when `db.go` lands rather than duplicating it.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromHistogram
public import PromLabels
internal import PromStorage

/// Go: `rangeForTimestamp` (db.go:2516) — the first timestamp of the window AFTER the one `t` falls in, so it
/// is an EXCLUSIVE bound and `nextAt` is compared with `>=`.
///
/// Go's integer division truncates toward zero rather than flooring, so the windows are not laid out the same
/// way below zero as above it: with a width of 1000, `t = -2500` gives -1000, three windows wide rather than
/// one. Quirk 184 — replicated, because a Swift `%`-based flooring version would move chunk boundaries for
/// pre-1970 timestamps.
public func rangeForTimestamp(_ t: Int64, _ width: Int64) -> Int64 {
    (t / width) * width + width
}

/// Go: `overlapsClosedInterval` — both intervals are closed at both ends.
func overlapsClosedInterval(_ mint1: Int64, _ maxt1: Int64, _ mint2: Int64, _ maxt2: Int64) -> Bool {
    mint1 <= maxt2 && mint2 <= maxt1
}

/// Go: `memChunk` — one in-memory chunk, and a link to the one before it.
///
/// A class because upstream's is a `*memChunk` in a singly-linked list that `cutNewHeadChunk` prepends to and
/// `mmapChunks` truncates; the identity matters (`appendPreprocessor` returns the chunk it decided on and
/// `append` then mutates that same object's `maxTime`).
public final class MemChunk {
    public var chunk: any Chunk
    public var minTime: Int64
    public var maxTime: Int64
    /// Go: `prev` — the OLDER chunk. The list runs newest-first.
    public var prev: MemChunk?

    public init(chunk: any Chunk, minTime: Int64, maxTime: Int64, prev: MemChunk?) {
        self.chunk = chunk
        self.minTime = minTime
        self.maxTime = maxTime
        self.prev = prev
    }

    /// Go: `len` — the length of the list from here, INCLUDING this element.
    public func len() -> Int {
        if prev == nil { return 1 }
        var count = 0
        var elem: MemChunk? = self
        while let e = elem {
            count += 1
            elem = e.prev
        }
        return count
    }

    /// Go: `oldest`.
    public func oldest() -> MemChunk {
        var elem = self
        while let p = elem.prev { elem = p }
        return elem
    }

    /// Go: `atOffset` — the Nth element walking `prev`, or nil past the end.
    ///
    /// The `0` and `1` fast paths and the `offset < 0` guard are all upstream's, in that order. A negative
    /// offset answers nil rather than trapping, which is what makes `mmapChunks`' downward loop safe to read.
    public func atOffset(_ offset: Int) -> MemChunk? {
        if offset == 0 { return self }
        if offset == 1 { return prev }
        if offset < 0 { return nil }

        var i = 0
        var elem: MemChunk? = self
        while i < offset {
            i += 1
            elem = elem?.prev
            if elem == nil { break }
        }
        return elem
    }

    /// Go: `OverlapsClosedInterval`.
    public func overlapsClosedInterval(_ mint: Int64, _ maxt: Int64) -> Bool {
        PromHead.overlapsClosedInterval(minTime, maxTime, mint, maxt)
    }
}

/// Go: `collectHeadChunks` — the list flattened OLDEST first, which is the reverse of how it is stored.
///
/// Upstream walks once and reverses, with a comment saying the pointer-chasing is what costs and the reverse
/// is free. Kept as one walk plus a reverse for the same reason, and because `buf` is a caller-supplied
/// scratch slice that the result is appended to rather than replacing.
public func collectHeadChunks(_ head: MemChunk?, _ buf: [MemChunk] = []) -> [MemChunk] {
    guard let head else { return buf }
    var hc = buf
    var elem: MemChunk? = head
    while let e = elem {
        hc.append(e)
        elem = e.prev
    }
    hc.reverse()
    return hc
}

/// Go: `mmappedChunk` — a head chunk that has been written to a chunk file.
public struct MmappedChunk: Sendable, Hashable {
    public var ref: ChunkDiskMapperRef
    public var numSamples: UInt16
    public var minTime: Int64
    public var maxTime: Int64

    public init(ref: ChunkDiskMapperRef, numSamples: UInt16, minTime: Int64, maxTime: Int64) {
        self.ref = ref
        self.numSamples = numSamples
        self.minTime = minTime
        self.maxTime = maxTime
    }

    /// Go: `OverlapsClosedInterval`.
    public func overlapsClosedInterval(_ mint: Int64, _ maxt: Int64) -> Bool {
        PromHead.overlapsClosedInterval(minTime, maxTime, mint, maxt)
    }
}

/// Go: `chunkOpts` — the chunk-level options an appender carries down to a series.
///
/// Rebuilt per appender from `HeadOptions` upstream, which is why a configuration change between two appends
/// legitimately changes `useXOR2` mid-series and reaches `appendPreprocessor`'s encoding branch.
public struct ChunkOpts {
    public var chunkDiskMapper: ChunkDiskMapper?
    public var chunkRange: Int64
    public var samplesPerChunk: Int
    /// Selects XOR2 encoding for float chunks.
    public var useXOR2: Bool
    /// Whether start-timestamp storage is enabled.
    public var storeST: Bool

    public init(
        chunkDiskMapper: ChunkDiskMapper? = nil, chunkRange: Int64, samplesPerChunk: Int,
        useXOR2: Bool = false, storeST: Bool = false
    ) {
        self.chunkDiskMapper = chunkDiskMapper
        self.chunkRange = chunkRange
        self.samplesPerChunk = samplesPerChunk
        self.useXOR2 = useXOR2
        self.storeST = storeST
    }
}

/// Go: `computeChunkEndTime` — revise `nextAt` downwards so the rest of the chunk range is filled by equally
/// sized chunks.
///
/// `n` is how many more chunks of the current density fit before `maxT`. Note the `+1` on the elapsed span,
/// which is what keeps `n` finite when the first two samples share a timestamp, and that `n <= 1` returns
/// `maxT` unchanged rather than something smaller.
///
/// **The subtractions WRAP, and that is reachable rather than theoretical.** `cur` is the chunk's `maxTime`,
/// which is `Int64.min` on a chunk that has no sample yet — and `appendPreprocessor` calls this with such a
/// chunk whenever `samplesPerChunk/4 == 0`. Go's `-` wraps silently, making `cur-start+1` a huge positive
/// number, `n` tiny, and the answer `maxT` unchanged. Swift's `-` would trap, so the operators here are `&-`
/// and `&+`: reproducing the wrap is what keeps the two ports' cut decisions identical.
public func computeChunkEndTime(start: Int64, cur: Int64, maxT: Int64, ratioToFull: Double) -> Int64 {
    let n = Double(maxT &- start) / (Double(cur &- start &+ 1) * ratioToFull)
    if n <= 1 {
        return maxT
    }
    return Int64(Double(start) + Double(maxT &- start) / n.rounded(.down))
}

/// Go: `handleChunkWriteError` — a write error panics unless the mapper is simply closed.
///
/// PORTING.md exception 9's treatment: this is reachable (a full disk), and upstream's own TODO says so
/// (*"Propagate errors correctly, even when they are async"*), so the port traps with the error rather than
/// swallowing it. Trapping is what upstream does; propagating would be a different contract from the one the
/// callers were written against.
func handleChunkWriteError(_ error: (any Error)?) {
    guard let error else { return }
    if let e = error as? HeadChunksError, e == .closed { return }
    preconditionFailure("chunk write failed: \(error)")
}

/// Go: `memSeries` — the in-memory representation of a series.
///
/// §7f(b) landed the identity half. Everything below the labels is the chunk state; see the file header for
/// what is deliberately absent.
public final class MemSeries {
    /// Go: `ref` — the Head's own ID for the series, and the key of `stripeSeries.series`.
    public let ref: HeadSeriesRef
    /// Go: `lset`, reached through `labels()`.
    public let lset: Labels
    /// Go: `shardHash` — always 0 unless sharding was explicitly enabled, which `EnableSharding` does and
    /// §7f does not port. Kept because `newMemSeries` takes it and `stripeSeries` will pass it through.
    public let shardHash: UInt64

    /// Go: `mmappedChunks` — immutable chunks on disk that have not gone into a block yet, oldest first.
    public var mmappedChunks: [MmappedChunk] = []
    /// Go: `headChunks` — the NEWEST in-memory chunk; `prev` walks to older ones.
    public var headChunks: MemChunk?
    /// Go: `firstChunkID` — the `HeadChunkID` of `mmappedChunks[0]`. Compaction shifts the array and this
    /// advances to compensate, so chunk IDs stay stable across truncation.
    public var firstChunkID: HeadChunkID = HeadChunkID(rawValue: 0)

    /// Go: `mmMaxTime` — max time of any mmapped chunk, only used during WAL replay (§7h).
    public var mmMaxTime: Int64 = 0

    /// Go: `nextAt` — the timestamp at which the next chunk must be cut. Starts at `MinInt64`, which no
    /// sample can be below, so the first append always cuts.
    public var nextAt: Int64 = Int64.min
    /// Go: `pendingCommit` — whether samples are waiting to be committed to this series.
    public var pendingCommit: Bool

    /// Go: `headChunkCount` — the number of head chunks. An atomic upstream, and the comment there explains
    /// it is `sync/atomic.Uint32` to fit existing struct padding; there is nothing to reproduce in that.
    public var headChunkCount: UInt32 = 0

    /// Go: `lastValue` — kept alongside the chunk so `appendable` can detect duplicates.
    public var lastValue: Double = 0

    /// Go: `lastHistogramValue` / `lastFloatHistogramValue`. Never SET in this slice — the histogram append
    /// path is deferred — but `append` nils them and `appendable` branches on them, so a port without them
    /// would silently lose the histogram-to-float duplicate error.
    public var lastHistogramValue: Histogram?
    public var lastFloatHistogramValue: FloatHistogram?

    /// Go: `app` — the appender for the current head chunk. Nil only while `headChunks` is nil (upstream's
    /// comment notes the one exception: a rolled-back commit that created the series but no chunk).
    public var app: (any ChunkAppender)?

    /// Go: `txs` — nil when isolation is disabled, which is not the same as an empty ring.
    public var txs: TxRing?

    /// Go: `newMemSeries`.
    public init(
        labels lset: Labels, ref: HeadSeriesRef, shardHash: UInt64 = 0,
        isolationDisabled: Bool = false, pendingCommit: Bool = false
    ) {
        self.lset = lset
        self.ref = ref
        self.shardHash = shardHash
        self.pendingCommit = pendingCommit
        if !isolationDisabled {
            // Capacity 0: the ring grows to 4 on its first add. §7f(a) pinned that.
            self.txs = TxRing(capacity: 0)
        }
    }

    /// Go: `labels()`.
    public func labels() -> Labels { lset }

    /// Go: `minTime` — the mmapped chunks come first because they are older than anything in memory.
    public func minTime() -> Int64 {
        if !mmappedChunks.isEmpty {
            return mmappedChunks[0].minTime
        }
        if let headChunks {
            return headChunks.oldest().minTime
        }
        return Int64.min
    }

    /// Go: `maxTime` — the head chunk first, since the highest timestamps are always there.
    public func maxTime() -> Int64 {
        if let headChunks {
            return headChunks.maxTime
        }
        if let last = mmappedChunks.last {
            return last.maxTime
        }
        return Int64.min
    }

    /// Go: `truncateChunksBefore` — drop every chunk with no timestamp at or after `mint`. Chunk IDs are
    /// unchanged, which is what `firstChunkID` is for.
    ///
    /// The head-chunk branch is the one to read twice: **if any head chunk is truncated, ALL mmapped chunks
    /// go too**, because they are all older. That makes the returned count `chk.len() + mmappedChunks.count`
    /// and leaves the mmapped array empty before the second block can look at it.
    ///
    /// Upstream's OOO block is absent along with the rest of OOO, so the return value is the in-order count
    /// alone rather than `removedInOrder + removedOOO`.
    @discardableResult
    public func truncateChunksBefore(mint: Int64) -> Int {
        var removedInOrder = 0
        if headChunks != nil {
            var i: UInt32 = 0
            var nextChk: MemChunk?
            var chk = headChunks
            while let c = chk {
                if c.maxTime < mint {
                    // If any head chunk is truncated, we can truncate all mmapped chunks.
                    removedInOrder = c.len() + mmappedChunks.count
                    firstChunkID = HeadChunkID(
                        rawValue: firstChunkID.rawValue &+ UInt64(removedInOrder))
                    if i == 0 {
                        // This is the first chunk on the list so we need to remove the entire list.
                        headChunks = nil
                        headChunkCount = 0
                    } else {
                        // This is NOT the first chunk, unlink it from parent.
                        nextChk?.prev = nil
                        headChunkCount = i
                    }
                    mmappedChunks = []
                    break
                }
                nextChk = c
                chk = c.prev
                i += 1
            }
        }
        if !mmappedChunks.isEmpty {
            for (i, c) in mmappedChunks.enumerated() {
                if c.maxTime >= mint { break }
                removedInOrder = i + 1
            }
            mmappedChunks = Array(mmappedChunks[removedInOrder...])
            firstChunkID = HeadChunkID(rawValue: firstChunkID.rawValue &+ UInt64(removedInOrder))
        }
        return removedInOrder
    }

    /// Go: `cleanupAppendIDsBelow`.
    public func cleanupAppendIDsBelow(_ bound: UInt64) {
        txs?.cleanupAppendIDsBelow(bound)
    }

    /// Go: `appendable` — is this sample valid for this series, and does it belong in the OOO chunk?
    ///
    /// Returns Go's three results rather than throwing: `oooDelta` is meaningful on the error paths too, and
    /// `handleAppendableError` upstream reads both.
    ///
    /// Two details that look like bugs and are not:
    ///
    ///   * the duplicate check compares `Float64bits`, not values, so **-0 and 0 are a duplicate ERROR** while
    ///     **NaN against the identical NaN is allowed**;
    ///   * a sample that is too old still reports `isOOO == true` alongside the error, because the OOO chunk
    ///     is where it *would* have gone.
    public func appendable(
        t: Int64, v: Double, headMaxt: Int64, minValidTime: Int64, oooTimeWindow: Int64
    ) -> (isOOO: Bool, oooDelta: Int64, error: (any Error)?) {
        // Check if we can append in the in-order chunk.
        if t >= minValidTime {
            if headChunks == nil {
                // The series has no sample and was freshly created.
                return (false, 0, nil)
            }
            let msMaxt = maxTime()
            if t > msMaxt {
                return (false, 0, nil)
            }
            if t == msMaxt {
                // Exact duplicates are allowed: federation produces them and erroring would be noisy. Only
                // the latest in-order sample is checked.
                if lastHistogramValue != nil || lastFloatHistogramValue != nil {
                    return (
                        false, 0,
                        DuplicateSampleForTimestampError.duplicateHistogramToFloat(t: t, newValue: v)
                    )
                }
                if lastValue.bitPattern != v.bitPattern {
                    return (
                        false, 0,
                        DuplicateSampleForTimestampError.duplicateFloat(
                            t: t, existing: lastValue, newValue: v)
                    )
                }
                // Identical timestamp and value as the most current sample.
                return (false, 0, nil)
            }
        }

        // The sample cannot go in the in-order chunk. Check if it can go in the out-of-order chunk.
        if oooTimeWindow > 0 && t >= headMaxt - oooTimeWindow {
            return (true, headMaxt - t, nil)
        }

        // The sample cannot go in either.
        if oooTimeWindow > 0 {
            return (true, headMaxt - t, StorageError.tooOldSample)
        }
        if t < minValidTime {
            return (false, headMaxt - t, StorageError.outOfBounds)
        }
        return (false, headMaxt - t, StorageError.outOfOrderSample)
    }

    /// Go: `append` — add `(t, v)` to the series, with `appendID` for isolation (0 disables it).
    ///
    /// `st` reaches the chunk appender and the XOR appender throws it away, which is quirk 36 in one line.
    @discardableResult
    public func append(
        st: Int64, t: Int64, v: Double, appendID: UInt64, o: ChunkOpts
    ) -> (sampleInOrder: Bool, chunkCreated: Bool) {
        let (c, sampleInOrder, chunkCreated) = appendPreprocessor(
            t: t, e: ValueType.float.chunkEncoding(useXOR2: o.useXOR2), o: o)
        if !sampleInOrder {
            return (sampleInOrder, chunkCreated)
        }
        app!.append(st, t, v)

        c!.maxTime = t

        lastValue = v
        lastHistogramValue = nil
        lastFloatHistogramValue = nil

        if appendID > 0 {
            txs!.add(appendID)
        }

        return (true, chunkCreated)
    }

    /// Go: `appendPreprocessor` — cut new XOR chunks as needed and answer whether the sample is in order.
    ///
    /// See the file header for the four cut grounds and their order. The returned chunk is the one the sample
    /// must go into; it is nil only on the first rejection route, where there is no chunk at all.
    public func appendPreprocessor(
        t: Int64, e: Encoding, o: ChunkOpts
    ) -> (c: MemChunk?, sampleInOrder: Bool, chunkCreated: Bool) {
        var c = headChunks
        var chunkCreated = false

        if c == nil {
            if let last = mmappedChunks.last, last.maxTime >= t {
                // Out of order sample: the timestamp is already in the mmapped chunks, so ignore it.
                return (c, false, false)
            }
            // There is no head chunk in this series yet, create the first chunk for the sample.
            c = cutNewHeadChunk(mint: t, e: e, chunkRange: o.chunkRange)
            chunkCreated = true
        }

        // Out of order sample.
        if c!.maxTime >= t {
            return (c, false, chunkCreated)
        }

        // Check the chunk size, unless we just created it, and cut if it is too large.
        if !chunkCreated && c!.chunk.bytes.count > ChunkLimits.maxBytesPerXORChunkBeforeAppend {
            c = cutNewHeadChunk(mint: t, e: e, chunkRange: o.chunkRange)
            chunkCreated = true
        }

        // XOR and XOR2 are compatible float encodings when ST storage is disabled: switching between them
        // does not require cutting. When ST storage is on the two differ in their start-timestamp support and
        // must not be mixed in one chunk, so `storeST` forces the cut that `compatibleValues` would skip.
        if c!.chunk.encoding != e && (!compatibleValues(c!.chunk.encoding, e) || o.storeST) {
            c = cutNewHeadChunk(mint: t, e: e, chunkRange: o.chunkRange)
            chunkCreated = true
        }

        let numSamples = c!.chunk.numSamples
        if numSamples == 0 {
            // Could be a new chunk created after reading the chunk snapshot, so fix its minTime here.
            c!.minTime = t
            nextAt = rangeForTimestamp(c!.minTime, o.chunkRange)
        }

        // At 25% of a chunk's desired sample count, predict an end time that distributes the remaining
        // samples evenly across the rest of the chunk range. `c.maxTime` here is the PREVIOUS sample's
        // timestamp — `append` has not written this one yet.
        if numSamples == o.samplesPerChunk / 4 {
            nextAt = computeChunkEndTime(
                start: c!.minTime, cur: c!.maxTime, maxT: nextAt, ratioToFull: 4)
        }
        // If the rate rose, the prediction above is stale; cut at twice the desired count as a fallback and
        // let the next chunk recompute for the new rate.
        if t >= nextAt || numSamples >= o.samplesPerChunk * 2 {
            c = cutNewHeadChunk(mint: t, e: e, chunkRange: o.chunkRange)
            chunkCreated = true
        }

        return (c, true, chunkCreated)
    }

    /// Go: `cutNewHeadChunk` — prepend a chunk to the list and make its appender current.
    ///
    /// The new chunk's `maxTime` starts at `MinInt64` so the very next append is in order, and `nextAt` is
    /// reset from the chunk RANGE — the quarter-mark prediction can only lower it later.
    ///
    /// An INVALID encoding falls back to an XOR chunk rather than failing; that is upstream's, and it is why
    /// `newEmptyChunk` is only ever asked about valid ones. A valid encoding this port has no chunk type for
    /// (the two histogram encodings) traps, matching upstream's `panic(err)` — see `newEmptyChunk`.
    @discardableResult
    public func cutNewHeadChunk(mint: Int64, e: Encoding, chunkRange: Int64) -> MemChunk {
        // The new chunk's `prev` is the current head, so the list is newest-first. All but the first element
        // are m-mapped as soon as possible, so most of the time this is a single-element list.
        let chunk: any Chunk
        if e.isValid {
            do {
                chunk = try newEmptyChunk(e)
            } catch {
                preconditionFailure("cutNewHeadChunk: \(error)")  // Go: panic(err).
            }
        } else {
            chunk = XORChunk()
        }
        let mc = MemChunk(chunk: chunk, minTime: mint, maxTime: Int64.min, prev: headChunks)
        headChunks = mc
        headChunkCount += 1

        // Set the upper bound on when the next chunk must start; an earlier one may be chosen later.
        nextAt = rangeForTimestamp(mint, chunkRange)

        do {
            app = try mc.chunk.makeAppender()
        } catch {
            preconditionFailure("cutNewHeadChunk: \(error)")  // Go: panic(err).
        }
        return mc
    }

    /// Go: `mmapChunks` — write every head chunk EXCEPT the newest to the chunk files.
    ///
    /// The loop counts down from `len()-1` to 1, so chunks are written oldest first and `s.headChunks` itself
    /// is skipped. Afterwards the tail is unlinked and the count is exactly 1.
    ///
    /// Upstream hands `WriteChunk` a `chunkenc.Chunk`; the port's `ChunkDiskMapper` takes an encoding and
    /// bytes, because it does not model the chunk pool (§7d).
    @discardableResult
    public func mmapChunks(chunkDiskMapper: ChunkDiskMapper) -> Int {
        var count = 0
        guard let head = headChunks, head.prev != nil else {
            // There is none or only one head chunk, so nothing to m-map here.
            return count
        }

        var i = head.len() - 1
        while i > 0 {
            guard let chk = head.atOffset(i) else { break }
            let chunkRef = chunkDiskMapper.writeChunk(
                seriesRef: ref, mint: chk.minTime, maxt: chk.maxTime,
                encoding: chk.chunk.encoding, bytes: chk.chunk.bytes,
                isOOO: false, callback: handleChunkWriteError)
            mmappedChunks.append(
                MmappedChunk(
                    ref: chunkRef, numSamples: UInt16(chk.chunk.numSamples),
                    minTime: chk.minTime, maxTime: chk.maxTime))
            count += 1
            i -= 1
        }

        // Remove the tail of the list, leaving only the most recent head chunk.
        head.prev = nil
        headChunkCount = 1

        return count
    }
}
