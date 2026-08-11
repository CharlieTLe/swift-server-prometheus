//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `blockBaseSeriesSet.Next` and `seriesData`.
//
// The step between a postings list and a series a caller can read: resolve each ref, drop what the time range
// and the tombstones exclude, and record what survived.
//
// **Scope of this slice.** `Next`'s SELECTION and SKIP rules are here and pinned. The chunk *trimming* it sets
// up — the two synthetic deletion intervals — is computed here but only becomes observable through the
// `populateWithDel*` iterators, which are the next slice. So `intervals` is recorded on `SeriesData` and
// checked by the corpus as far as `Next` decides it; what the trimming does to samples is pinned there.
//
// ## Three different reasons to SKIP a series, and only one of them is an error
//
//   1. `errors.Is(err, storage.ErrNotFound)` from `index.Series` → `continue`. Upstream's comment: "Postings
//      may be stale. Skip if no underlying series exists." Any OTHER error stops the whole set.
//   2. `len(b.bufChks) == 0` → `continue`. A series with no chunks at all is not a series.
//   3. `len(chks) == 0` after prefiltering → `continue`. Everything was out of range or deleted.
//
// So a postings list of N refs can yield anywhere from 0 to N series, and a ref that resolves to nothing is
// silently absent rather than an error. That is the behaviour a corpus has to reach, because it is the one a
// hand-written test would assume away.
//
// ## The three time ranges are half-open, closed and closed — and they are all different
//
// Upstream spells this out in a NOTE because it is the source of off-by-ones:
//
//     block time range      [meta.MinTime, meta.MaxTime)   half-open
//     chunk time range      [chk.MinTime, chk.MaxTime]     closed
//     requested time range  [req.Start, req.End]           closed
//
// So the prefilter is `chk.MaxTime < b.mint` and `chk.MinTime > b.maxt` — strict, because both ends are
// inclusive. A chunk touching the boundary is KEPT.
//
// ## `nChks` is counted in a separate pass and DELIBERATELY ignores tombstones
//
// The first loop counts chunks in range to size the allocation; the second applies the full filter including
// `IsSubrange`. Upstream's comment says "roughly - ignoring tombstones", so the count can over-estimate and
// that is intended. Reproduced as a `reserveCapacity`, which is what it is.
//
// ## `trimFront`/`trimBack` are computed over the KEPT chunks, and only when trimming is enabled
//
// They are set inside the second loop, after `chks = append(chks, chk)` — so a chunk excluded by the range or
// fully deleted does not cause trimming. And `disableTrimming` skips them entirely, which is how a compactor
// reads a block without clipping the chunks it is about to rewrite.
//
// The intervals added are `[MinInt64, mint-1]` and `[maxt+1, MaxInt64]` — quirk 162's overflow-guard path,
// and the reason the interval arithmetic had to be ported before this.
//===----------------------------------------------------------------------===//

public import PromIndex
public import PromStorage

/// Go: `seriesData` — what `blockBaseSeriesSet` produces for one series.
public struct SeriesData: Sendable {
    public var labels: [(name: String, value: String)]
    /// The chunks that survived prefiltering, in index order.
    public var chunks: [DecodedChunkMeta]
    /// The deletion intervals to apply, INCLUDING the synthetic trimming ones.
    public var intervals: [DeletionInterval]
}

/// The index operations `blockBaseSeriesSet` needs.
///
/// Narrow on purpose, like ``PostingsIndex``: this is `index.Series` and nothing else.
public protocol SeriesIndex {
    /// Go: `index.Series(ref, builder, chks)`. Returns nil for Go's `storage.ErrNotFound`, which is a SKIP
    /// rather than an error — see the file header. Any other failure throws.
    func series(_ ref: SeriesRef) throws -> (
        labels: [(name: String, value: String)], chunks: [DecodedChunkMeta]
    )?
}

/// Go: `fmt.Errorf("get series %d: %w", …)` and `"get tombstones: %w"`.
public enum SeriesSetError: Error, CustomStringConvertible {
    case getSeries(ref: UInt64, underlying: any Error)
    case getTombstones(underlying: any Error)

    public var description: String {
        switch self {
        case .getSeries(let r, let e): return "get series \(r): \(e)"
        case .getTombstones(let e): return "get tombstones: \(e)"
        }
    }
}

/// Go: `blockBaseSeriesSet` — iterate a block's series, trimmed to a range and to tombstones.
///
/// A class because `Next()`/`At()` are cursor operations, matching Go's pointer receiver and
/// `storage.SeriesSet`'s shape.
public final class BlockBaseSeriesSet {
    private let index: any SeriesIndex
    private let postings: any Postings
    private let mint: Int64
    private let maxt: Int64
    private let disableTrimming: Bool
    /// Go: `b.tombstones.Get(ref)`. Always empty here — the tombstone reader is exception 16 — but kept as a
    /// closure so the Head and a future `Delete()` can supply one without changing this type.
    private let tombstonesFor: (SeriesRef) throws -> [DeletionInterval]

    /// Go: `curr`. Valid after a `next()` that returned true.
    public private(set) var current: SeriesData?
    public private(set) var error: (any Error)?

    public init(
        index: any SeriesIndex, postings: any Postings, mint: Int64, maxt: Int64,
        disableTrimming: Bool = false,
        tombstonesFor: @escaping (SeriesRef) throws -> [DeletionInterval] = { _ in [] }
    ) {
        self.index = index
        self.postings = postings
        self.mint = mint
        self.maxt = maxt
        self.disableTrimming = disableTrimming
        self.tombstonesFor = tombstonesFor
    }

    /// Go: `Next`.
    public func next() -> Bool {
        while postings.next() {
            let ref = postings.at()

            let resolved: (labels: [(name: String, value: String)], chunks: [DecodedChunkMeta])?
            do {
                resolved = try index.series(ref)
            } catch let e {
                // `error` shadows the property inside a `catch`, hence the explicit binding.
                self.error = SeriesSetError.getSeries(ref: ref.rawValue, underlying: e)
                return false
            }
            guard let resolved else {
                // Go: `errors.Is(err, storage.ErrNotFound)` — "postings may be stale". A SKIP.
                continue
            }
            let bufChks = resolved.chunks
            if bufChks.isEmpty {
                continue
            }

            var intervals: [DeletionInterval]
            do {
                intervals = try tombstonesFor(ref)
            } catch let e {
                self.error = SeriesSetError.getTombstones(underlying: e)
                return false
            }

            var trimFront = false
            var trimBack = false

            // Go counts chunks in range first, to size the allocation — "roughly - ignoring tombstones",
            // so the count may over-estimate. See the file header.
            var nChks = 0
            for chk in bufChks where chk.maxTime >= mint && chk.minTime <= maxt {
                nChks += 1
            }
            var chks: [DecodedChunkMeta] = []
            chks.reserveCapacity(nChks)

            for chk in bufChks {
                // STRICT comparisons: the chunk and the request are both closed ranges, so a chunk
                // touching a boundary is kept.
                if chk.maxTime < mint { continue }
                if chk.minTime > maxt { continue }
                if DeletionInterval(mint: chk.minTime, maxt: chk.maxTime).isSubrange(intervals) {
                    continue
                }
                chks.append(chk)

                // Only for chunks that were KEPT, and only when trimming is enabled.
                if !disableTrimming {
                    if chk.minTime < mint { trimFront = true }
                    if chk.maxTime > maxt { trimBack = true }
                }
            }

            if chks.isEmpty {
                continue
            }

            if trimFront {
                intervals = intervals.addingInterval(
                    DeletionInterval(mint: Int64.min, maxt: mint - 1))
            }
            if trimBack {
                intervals = intervals.addingInterval(
                    DeletionInterval(mint: maxt + 1, maxt: Int64.max))
            }

            current = SeriesData(labels: resolved.labels, chunks: chks, intervals: intervals)
            return true
        }
        return false
    }

    /// Go: `Err` — the set's own error, else the postings'.
    public func err() -> (any Error)? {
        if let error { return error }
        return postings.err()
    }
}
