//===----------------------------------------------------------------------===//
// Ported from tsdb/head_read.go @ v3.13.2 — `headIndexReader`, the Head's INDEX side.
//
// §7f made the Head ingest. This makes it *findable*: the same index surface a block exposes, over the
// in-memory `MemPostings` and `stripeSeries` instead of over a file. `Head.Index()` is exported, so the corpus
// drives upstream's own reader.
//
// ## The time range is a FILTER on two levels, and only one of them is a real check
//
// `indexRange(mint, maxt)` clamps `mint` up to the head's own `MinTime` — so a reader asked for a window
// starting before the head's data silently gets the head's start instead. Then `LabelValues`/`LabelNames` bail
// out with an EMPTY result when the requested window and the head's do not overlap at all. But `Postings` and
// `Series` do **not** filter by time: postings come straight from `MemPostings`, and `Series` filters only the
// CHUNKS it reports. So a series whose samples all sit outside the window is still returned, with an empty
// chunk list — which is exactly what `blockBaseSeriesSet` expects (§6s).
//
// ## `Series` reports the open chunk's maxTime as `MaxInt64`
//
// The newest head chunk is still being appended to, so its real `maxTime` is a moving target. `appendSeriesChunks`
// therefore reports `math.MaxInt64` for it, and only for it — an mmapped chunk, or an older chunk on the head
// list, reports its true bound. A querier that trusted that number would never trim the last chunk; §6t's
// populate iterators are written to trim by sample instead, which is why this is safe.
//
// ## What is deliberately absent, and where each one goes
//
//   * **`ShardedPostings`.** A declared §6 deferral, and it needs `EnableSharding`; upstream itself returns a
//     failing postings list when sharding is off, so the port's absence is the same answer with a compile error
//     instead of a runtime one.
//   * **The stale index** (`headStaleIndexReader`, `staleSeriesRefs`, `staleSeriesRefsNoOOOData`,
//     `allStaleSeriesPostings`) — that is `StaleHead`'s reader, and `StaleHead` is a compaction input (§7i).
//   * **`ExemplarQuerier`**, with exemplars.
//   * **`Symbols`** returns `MemPostings.symbols()` upstream through an iterator; the port's `MemPostings`
//     already answers a sorted array (§7e), so the iterator wrapper has nothing to wrap.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunks
public import PromIndex
public import PromLabels
public import PromStorage

/// Go: `headChunksBufMaxCap` — the reusable `collectHeadChunks` buffer is dropped when it grows past this, so a
/// single huge series does not pin memory for the rest of the reader's life.
///
/// Pure allocation strategy with one observable consequence: none. Ported as a constant so the number is not
/// lost, and *not* acted on — the port has no buffer to reuse (PORTING.md exception 4).
public let headChunksBufMaxCap = 1024

/// Go: `headIndexReader` — "index reading for the head block. Not safe for concurrent use."
public final class HeadIndexReader: LabelQueryIndex {
    let head: Head
    /// Go: `mint`, already clamped by `indexRange`.
    public let mint: Int64
    public let maxt: Int64

    init(head: Head, mint: Int64, maxt: Int64) {
        self.head = head
        self.mint = mint
        self.maxt = maxt
    }

    /// Go: `Close` — nothing to release.
    public func close() throws {}

    /// Go: `Symbols`. Every name AND value in the head, sorted and de-duplicated.
    public func symbols() -> [String] {
        head.postings.symbols()
    }

    /// Go: `SortedLabelValues` — `LabelValues` and then a sort.
    ///
    /// Note that upstream sorts only when the call SUCCEEDED (`if err == nil`), so a failure returns whatever
    /// partial slice came back, unsorted. The port throws instead, which reaches the same place.
    public func sortedLabelValues(
        name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> [String] {
        var values = try labelValues(name: name, hints: hints, matchers: matchers)
        values.sort()
        return values
    }

    /// Go: `LabelValues`.
    ///
    /// The window check is the reader's, not the postings': it compares the READER's range against the HEAD's,
    /// and answers an empty list when they do not overlap — which is a different thing from "no such label".
    public func labelValues(
        name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> [String] {
        if maxt < head.minTime() || mint > head.maxTime() {
            return []
        }

        if matchers.isEmpty {
            return head.postings.labelValues(name: name, limit: hints?.limit ?? 0)
        }

        return try labelValuesWithMatchers(
            self, name: name, limit: hints?.limit ?? 0, matchers: matchers)
    }

    /// Go: `ix.LabelValues(ctx, name, nil)` — the unfiltered, unlimited form `labelValuesWithMatchers` calls
    /// back into. A separate method rather than a default argument, because a protocol witness cannot be
    /// satisfied by a method with defaults.
    public func labelValues(name: String) throws -> [String] {
        try labelValues(name: name, hints: nil, matchers: [])
    }

    /// Go: `LabelNames`. Same window check, and the no-matcher path SORTS — `MemPostings.labelNames` ranges a
    /// Go map, so upstream has no order of its own (exception 23).
    public func labelNames(matchers: [Matcher]) throws -> [String] {
        if maxt < head.minTime() || mint > head.maxTime() {
            return []
        }

        if matchers.isEmpty {
            var names = head.postings.labelNames()
            names.sort()
            return names
        }

        return try labelNamesWithMatchers(self, matchers: matchers)
    }

    /// Go: `ix.LabelNames(ctx)` — the unfiltered form, and the `LabelQueryIndex` witness.
    public func labelNames() throws -> [String] {
        try labelNames(matchers: [])
    }

    /// Go: `Postings` — straight from `MemPostings`, with **no time filtering**. See the file header.
    public func postings(name: String, values: [String]) throws -> any Postings {
        head.postings.postings(name: name, values: values)
    }

    /// Go: `PostingsForLabelMatching`.
    public func postingsForLabelMatching(
        name: String, match: @escaping (String) -> Bool
    ) throws -> any Postings {
        head.postings.postingsForLabelMatching(name: name, match: match)
    }

    /// Go: `PostingsForAllLabelValues`.
    public func postingsForAllLabelValues(name: String) throws -> any Postings {
        head.postings.postingsForAllLabelValues(name: name)
    }

    /// Go: `SortedPostings` — re-order a postings list by LABEL SET rather than by ref.
    ///
    /// Two details worth keeping: a ref with no series is **dropped** (upstream counts them and logs at debug
    /// level, because compaction can garbage-collect a series between a caller getting the refs and using
    /// them), and the sort is `labels.Compare`, so it is the same order a block's index has on disk. That is
    /// what lets a querier merge a head and a block without re-sorting.
    public func sortedPostings(_ p: any Postings) -> any Postings {
        var series: [MemSeries] = []
        series.reserveCapacity(128)

        var notFoundSeriesCount = 0
        // Fetch all the series only once.
        while p.next() {
            if let s = head.series.getByID(HeadSeriesRef(rawValue: p.at().rawValue)) {
                series.append(s)
            } else {
                notFoundSeriesCount += 1
            }
        }
        _ = notFoundSeriesCount  // Upstream logs this at debug level; the port has no logger.
        if let err = p.err() {
            return errPostings(SortedPostingsError.expandPostings(err))
        }

        series.sort { Labels.compare($0.labels(), $1.labels()) < 0 }

        return ListPostings(series.map { SeriesRef(rawValue: $0.ref.rawValue) })
    }

    /// Go: `Series` — the label set, and optionally the chunk metas in the reader's window.
    ///
    /// `chks == nil` upstream means "labels only", which is how `LabelNamesFor`-style callers avoid the chunk
    /// walk; the port models it with a separate `labels(for:)` rather than a nil out-parameter.
    public func series(_ ref: SeriesRef) throws -> (labels: Labels, chunks: [Meta]) {
        guard let s = head.series.getByID(HeadSeriesRef(rawValue: ref.rawValue)) else {
            throw StorageError.notFound
        }
        return (s.labels(), appendSeriesChunks(s, mint: mint, maxt: maxt, into: []))
    }

    /// Go: `Series` with a nil `chks`.
    public func labels(for ref: SeriesRef) throws -> Labels {
        guard let s = head.series.getByID(HeadSeriesRef(rawValue: ref.rawValue)) else {
            throw StorageError.notFound
        }
        return s.labels()
    }

    /// Go: `LabelNamesFor` — every label NAME used by the given series, sorted.
    ///
    /// A missing series is skipped rather than an error, and upstream says why: *"this happens during
    /// compaction, when series was garbage collected after the caller got the series IDs."* The
    /// `checkContextEveryNIterations` context check is dropped with the rest of `GoContext`'s cancellation.
    public func labelNamesFor(_ series: any Postings) throws -> [String] {
        var namesMap = Set<String>()
        while series.next() {
            guard let s = head.series.getByID(HeadSeriesRef(rawValue: series.at().rawValue)) else {
                continue
            }
            for l in s.labels() {
                namesMap.insert(l.name)
            }
        }
        if let err = series.err() {
            throw err
        }
        return namesMap.sorted()
    }
}

/// Go: `fmt.Errorf("expand postings: %w", err)` inside `SortedPostings`.
public enum SortedPostingsError: Error, CustomStringConvertible {
    case expandPostings(any Error)

    public var description: String {
        switch self {
        case .expandPostings(let e): return "expand postings: \(e)"
        }
    }
}

extension Head {

    /// Go: `Head.Index` — the whole time range.
    public func index() -> HeadIndexReader {
        indexRange(mint: Int64.min, maxt: Int64.max)
    }

    /// Go: `Head.indexRange` — and note the CLAMP: a `mint` below the head's own start is raised to it, so the
    /// reader can never be asked about a window the head does not cover on the low side. `maxt` is not clamped,
    /// because the head's `maxTime` moves as samples arrive.
    public func indexRange(mint: Int64, maxt: Int64) -> HeadIndexReader {
        var mint = mint
        let hmin = minTime()
        if hmin > mint {
            mint = hmin
        }
        return HeadIndexReader(head: self, mint: mint, maxt: maxt)
    }
}

extension MemSeries {

    /// Go: `memSeries.headChunkID(pos)` — the chunk ID for a position in the concatenation of
    /// `mmappedChunks` and the head chunk list.
    ///
    /// `pos + firstChunkID`, which is what makes IDs stable across truncation: `truncateChunksBefore` advances
    /// `firstChunkID` by exactly the number of chunks it dropped, so a ref handed out before a truncation still
    /// names the same chunk afterwards (or is out of range, which the reader detects).
    public func headChunkID(_ pos: Int) -> HeadChunkID {
        HeadChunkID(rawValue: UInt64(pos) &+ firstChunkID.rawValue)
    }
}

/// Go: `oooChunkIDMask` — bit 23 of a `HeadChunkID` marks an out-of-order chunk.
///
/// Ported with `unpackHeadChunkRef`, because the mask is how a reader tells the two apart and the *in-order*
/// path has to strip it. The OOO chunks themselves are Phase 10.
public let oooChunkIDMask: UInt64 = 1 << 23

/// Go: `unpackHeadChunkRef`.
public func unpackHeadChunkRef(_ ref: ChunkRef) -> (
    seriesID: HeadSeriesRef, chunkID: HeadChunkID, isOOO: Bool
) {
    let (sid, cid) = HeadChunkRef(rawValue: ref.rawValue).unpack()
    return (
        sid,
        HeadChunkID(rawValue: cid.rawValue & (oooChunkIDMask - 1)),
        (cid.rawValue & oooChunkIDMask) != 0
    )
}

/// Go: `chunks.ChunkRef(chunks.NewHeadChunkRef(ref, id))`.
///
/// The port's `HeadChunkRef` initialiser VALIDATES the 40/24-bit split and throws; upstream's `NewHeadChunkRef`
/// traps (`panic`) on the same condition. A Head that exceeded either bound would already have broken the
/// invariant `HeadChunkRef` exists to express, so this trap is upstream's behaviour rather than a new failure
/// mode.
func headChunkRef(_ ref: HeadSeriesRef, _ id: HeadChunkID) -> ChunkRef {
    do {
        return ChunkRef(rawValue: try HeadChunkRef(seriesRef: ref, chunkID: id).rawValue)
    } catch {
        preconditionFailure("head chunk ref out of range: \(error)")
    }
}

/// Go: `appendSeriesChunks` — the chunk metas of one series that overlap `[mint, maxt]`.
///
/// Three paths, and upstream keeps them apart for allocation reasons: the mmapped chunks, then a fast path for
/// the single head chunk (the common case), then the linked-list walk. The port keeps all three because the
/// **single-chunk path reports a different maxTime than the walk would**: `MaxInt64`, because that chunk is
/// open. In the walk, only the LAST element gets `MaxInt64` — the older ones are closed and report their real
/// bounds.
///
/// The `headChunksBuf` reuse is dropped (exception 4); `collectHeadChunks` allocates.
public func appendSeriesChunks(
    _ s: MemSeries, mint: Int64, maxt: Int64, into chks: [Meta]
) -> [Meta] {
    var chks = chks
    for (i, c) in s.mmappedChunks.enumerated() {
        // Do not expose chunks that are outside of the specified range.
        if !c.overlapsClosedInterval(mint, maxt) {
            continue
        }
        chks.append(
            Meta(
                ref: headChunkRef(s.ref, s.headChunkID(i)),
                minTime: c.minTime, maxTime: c.maxTime))
    }

    guard let head = s.headChunks else {
        return chks
    }

    // Fast path: a single head chunk, which is open and therefore reports MaxInt64.
    if head.prev == nil {
        if head.overlapsClosedInterval(mint, maxt) {
            chks.append(
                Meta(
                    ref: headChunkRef(s.ref, s.headChunkID(s.mmappedChunks.count)),
                    minTime: head.minTime, maxTime: Int64.max))
        }
        return chks
    }

    // Multiple head chunks: oldest first, and only the newest is open.
    let buf = collectHeadChunks(head)
    for (i, chk) in buf.enumerated() {
        var maxTime = chk.maxTime
        if i == buf.count - 1 {
            maxTime = Int64.max  // Open (newest) chunk.
        }
        if chk.overlapsClosedInterval(mint, maxt) {
            chks.append(
                Meta(
                    ref: headChunkRef(s.ref, s.headChunkID(s.mmappedChunks.count + i)),
                    minTime: chk.minTime, maxTime: maxTime))
        }
    }
    return chks
}

// MARK: - RangeHead

/// Go: `RangeHead` — the Head restricted to `[mint, maxt]`, and the only exported way to get a RANGED index or
/// chunk reader (`Head.indexRange`/`chunksRange` are unexported).
///
/// It is what compaction and the querier are handed: `db.go` wraps the Head in one per block interval, so the
/// range is the block boundary rather than a query window. Note there are **no restrictions on mint/maxt** —
/// upstream's own comment — so a `RangeHead` can name a window the head does not cover, and the readers'
/// clamping is what makes that harmless.
public final class RangeHead {
    let head: Head
    public let mint: Int64
    public let maxt: Int64
    /// Go: `isolationOff` — set only by `NewRangeHeadWithIsolationDisabled`, which compaction uses because it
    /// has already waited for the readers it cares about.
    let isolationOff: Bool

    /// Go: `NewRangeHead`.
    public init(head: Head, mint: Int64, maxt: Int64) {
        self.head = head
        self.mint = mint
        self.maxt = maxt
        self.isolationOff = false
    }

    /// Go: `NewRangeHeadWithIsolationDisabled`.
    public static func withIsolationDisabled(head: Head, mint: Int64, maxt: Int64) -> RangeHead {
        let rh = RangeHead(head: head, mint: mint, maxt: maxt)
        return RangeHead(head: rh.head, mint: rh.mint, maxt: rh.maxt, isolationOff: true)
    }

    private init(head: Head, mint: Int64, maxt: Int64, isolationOff: Bool) {
        self.head = head
        self.mint = mint
        self.maxt = maxt
        self.isolationOff = isolationOff
    }

    /// Go: `Index`.
    public func index() -> HeadIndexReader {
        head.indexRange(mint: mint, maxt: maxt)
    }

    /// Go: `Chunks` — with an isolation state unless it was disabled.
    public func chunks() throws -> HeadChunkReader {
        var isoState: IsolationState?
        if !isolationOff {
            isoState = head.iso.state(mint: mint, maxt: maxt)
        }
        return try head.chunksRange(mint: mint, maxt: maxt, isoState: isoState)
    }

    /// Go: `MinTime` — the RANGE's, not the head's.
    public func minTime() -> Int64 { mint }
    /// Go: `MaxTime`.
    public func maxTime() -> Int64 { maxt }

    /// Go: `BlockMaxTime` — `MaxTime() + 1`, because a block's interval is half-open `[mint, maxt)` while a
    /// head's is closed. Getting this wrong loses or duplicates the last millisecond of every compacted block.
    ///
    /// **The addition WRAPS**, and that is reachable: `NewRangeHead` puts no restriction on `maxt`, and a
    /// caller asking for "everything" passes `math.MaxInt64` — whereupon Go answers `math.MinInt64`. Swift's
    /// checked `+` trapped on exactly that input in the corpus, so the operator is `&+`. Quirk 192.
    public func blockMaxTime() -> Int64 { maxTime() &+ 1 }

    /// Go: `NumSeries` — the HEAD's count, not the range's. A series with no samples in the window still counts.
    public func numSeries() -> UInt64 { head.seriesCount() }

    /// Go: `Meta`, with its own ULID sentinel.
    public func meta() -> BlockMeta {
        var m = BlockMeta(ulid: rangeHeadULID, minTime: minTime(), maxTime: maxTime())
        m.stats.numSeries = numSeries()
        return m
    }

    /// Go: `String`.
    public var description: String { "range head (mint: \(minTime()), maxt: \(maxTime()))" }
}

/// Go: `rangeHeadULID` — `ulid.MustParse("0000000000XXXXXXXRANGEHEAD")`.
public let rangeHeadULID: ULID = {
    guard let u = ULID("0000000000XXXXXXXRANGEHEAD") else {
        preconditionFailure("rangeHeadULID is a compile-time constant upstream and must parse")
    }
    return u
}()
