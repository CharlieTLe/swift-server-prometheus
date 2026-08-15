//===----------------------------------------------------------------------===//
// Ported from tsdb/tombstones/tombstones.go @ v3.13.2 — `MemTombstones`.
//
// PORTING.md exception 16 records that a block's tombstone FILE is not read, so a block's deletions are not
// applied. This is the other half of the type: the in-memory reader the Head keeps, which `Head.Delete` writes
// to and `Head.gc` prunes. It is needed now because the Head's exported `Tombstones()` returns it, and because
// `Delete` is how a caller marks samples deleted without rewriting a chunk.
//
// ## `TruncateBefore`'s backwards scan is the part to read twice
//
// It walks each series' intervals from the END, stopping at the first interval whose `Maxt` is at or after
// `beforeT`, and keeps everything AFTER that index. Which means: it relies on the intervals being sorted and
// non-overlapping — `Intervals.Add` guarantees both (§6q) — and an interval that merely *starts* before `beforeT`
// is kept whole rather than trimmed. Deleted data is not un-deleted by truncation; only fully-elapsed tombstones
// are dropped.
//
// Note `i+1` after the loop: when no interval satisfies the test, `i` is -1 and `ivs[0...]` is the whole list, so
// nothing is dropped. Off-by-one here silently drops a tombstone, which would resurrect deleted samples.
//
// ## What is absent
//
//   * The file codec (`WriteFile`, `Encode`, `Decode`, `ReadTombstones`) — exception 16, and §7i is the slice
//     that will need it to write a block.
//   * `NewTestMemTombstones`, a test helper.
//   * The `sync.RWMutex`, as everywhere else in the port.
//===----------------------------------------------------------------------===//

public import PromStorage

// Go's `tombstones.Intervals` is a named slice type; the port models it as `[DeletionInterval]` with the
// merging logic in an extension (§6q), so every signature below reads `[DeletionInterval]` where upstream reads
// `Intervals`.

/// Go: `tombstones.Reader` — the read surface a block or a Head exposes.
public protocol TombstoneReader {
    /// Go: `Get` — the deletion intervals for one series, or nil.
    func get(_ ref: SeriesRef) throws -> [DeletionInterval]
    /// Go: `Iter` — every series with tombstones. Stops on the first error the closure returns.
    func iter(_ f: (SeriesRef, [DeletionInterval]) throws -> Void) throws
    /// Go: `Total` — the number of INTERVALS, not of series.
    func total() -> UInt64
    func close() throws
}

/// Go: `MemTombstones` — "in memory Tombstone Reader that allows adding new intervals".
public final class MemTombstones: TombstoneReader {
    var intervalGroups: [SeriesRef: [DeletionInterval]] = [:]

    public init() {}

    /// Go: `Get` — and note it COPIES, because upstream's caller can hold the slice while another goroutine
    /// appends to it. The port's arrays are value types, so the copy is implicit; the comment stays because the
    /// aliasing question is the reason the method exists rather than a map read.
    public func get(_ ref: SeriesRef) throws -> [DeletionInterval] {
        intervalGroups[ref] ?? []
    }

    /// Go: `DeleteTombstones` — drop every tombstone of the given series, used by `Head.gc` for series it
    /// removed entirely.
    public func deleteTombstones(_ refs: Set<SeriesRef>) {
        for ref in refs {
            intervalGroups.removeValue(forKey: ref)
        }
    }

    /// Go: `TruncateBefore` — drop tombstones that are entirely before `beforeT`. See the file header for the
    /// backwards scan and the `i+1`.
    public func truncateBefore(_ beforeT: Int64) {
        for (ref, ivs) in intervalGroups {
            var i = ivs.count - 1
            while i >= 0 {
                if beforeT > ivs[i].maxt {
                    break
                }
                i -= 1
            }
            let remaining = Array(ivs.dropFirst(i + 1))
            if remaining.isEmpty {
                intervalGroups.removeValue(forKey: ref)
            } else {
                intervalGroups[ref] = remaining
            }
        }
    }

    /// Go: `Iter`. Ranges a Go map upstream, so the ORDER is arbitrary there — exception 11's situation again.
    /// Callers that commit output must sort; `Head.Tombstones` is read by the block writer (§7i), which sorts by
    /// ref because the tombstone file is ordered.
    public func iter(_ f: (SeriesRef, [DeletionInterval]) throws -> Void) throws {
        for (ref, ivs) in intervalGroups {
            try f(ref, ivs)
        }
    }

    /// Go: `Total` — the number of intervals across all series.
    public func total() -> UInt64 {
        intervalGroups.values.reduce(0) { $0 + UInt64($1.count) }
    }

    /// Go: `AddInterval` — merges through `Intervals.Add`, so overlapping and adjacent intervals coalesce
    /// (§6q). Adding the same interval twice is therefore idempotent.
    public func addInterval(_ ref: SeriesRef, _ itvs: DeletionInterval...) {
        addInterval(ref, itvs)
    }

    public func addInterval(_ ref: SeriesRef, _ itvs: [DeletionInterval]) {
        for itv in itvs {
            var group = intervalGroups[ref] ?? []
            group = group.addingInterval(itv)
            intervalGroups[ref] = group
        }
    }

    /// Go: `Close` — nothing to release.
    public func close() throws {}
}
