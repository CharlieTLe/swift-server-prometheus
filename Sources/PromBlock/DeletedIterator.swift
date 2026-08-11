//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `DeletedIterator`.
//
// Wraps a chunk iterator and skips samples that fall inside a deletion interval. Exported upstream, so it is
// directly pinnable — and it needs to be, because its behaviour is stateful in a way nothing about the name
// suggests.
//
// ## It CONSUMES its own interval list as it advances, and that is observable
//
// `it.Intervals = it.Intervals[1:]` — both `Next` and `Seek` drop intervals off the FRONT once the current
// timestamp has passed them. The list is a cursor, not a filter. Three consequences:
//
//   1. **Iterating twice gives different answers.** After a full pass the list is empty, so a second pass
//      over the same iterator would delete nothing. Upstream relies on this never happening (each
//      `DeletedIterator` is reset before reuse, and `populateWithDelGenericSeriesIterator.next` reassigns
//      `bufIter.Intervals` from scratch every chunk).
//   2. **Seeking backwards is not supported.** Not merely inefficient — the intervals already dropped are
//      gone, so a sample the first pass deleted can come back.
//   3. It is only correct because the intervals are SORTED and non-overlapping, which is `Intervals`'
//      invariant maintained by `Add` (quirk 162). Handed an unsorted list it silently under-deletes.
//
// The port keeps the consuming behaviour rather than filtering against the full list, because a
// non-consuming version is *not* equivalent: the interval-drop is what makes the inner loop O(1) amortised,
// and — more importantly — a caller that reuses an iterator would then see different samples.
//
// ## `Next`'s inner loop has three exits and the order matters
//
//     for tr in intervals:
//         if tr.InBounds(ts) { continue Outer }   // deleted: fetch the next sample
//         if ts <= tr.Maxt   { return valueType } // before this interval: keep the sample
//         intervals = intervals[1:]               // past this interval: drop it and look at the next
//
// The second test is `ts <= tr.Maxt`, and it is reached only when `InBounds` was false — so `ts < tr.Mint`.
// Written as `ts < tr.Mint` it would read more obviously; as `ts <= tr.Maxt` it is the same predicate given
// the first test failed. A port that reorders these two drops intervals it should have kept.
//
// ## `Seek` re-enters through `Next`, and only for one case
//
// After seeking, if the landing timestamp is inside an interval it returns `it.Next()` — delegating the skip
// rather than looping itself. So a `Seek` into a deleted region behaves like a `Seek` followed by however
// many `Next`s the deletion needs. Its own loop has only two exits (`ts < Mint` keeps, `ts > Maxt` drops),
// because the third is `Next`'s job.
//
// `Seek` also checks `it.Iter.Err() != nil` FIRST and returns `ValNone` — `Next` does not. Reproduced;
// upstream is not symmetric here and a port that made it so would swallow a different set of errors.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromHistogram
public import PromTombstones

/// Go: `tsdb.DeletedIterator` — a chunk iterator with deletion intervals applied.
///
/// A class, not a struct, because `ChunkIterator` is `AnyObject` and because the interval consumption is
/// mutation the caller must see.
public final class DeletedIterator: ChunkIterator {
    /// Go: `Iter` — the wrapped iterator.
    public var iter: any ChunkIterator
    /// Go: `Intervals`. **Consumed as iteration proceeds.** See the file header.
    public var intervals: [DeletionInterval]

    public init(iter: any ChunkIterator, intervals: [DeletionInterval]) {
        self.iter = iter
        self.intervals = intervals
    }

    public func at() -> (Int64, Double) { iter.at() }

    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        iter.atHistogram(reuse)
    }

    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        iter.atFloatHistogram(reuse)
    }

    public func atT() -> Int64 { iter.atT() }

    public func atST() -> Int64 { iter.atST() }

    public func err() -> (any Error)? { iter.err() }

    /// Go: `Seek`.
    ///
    /// Checks the wrapped iterator's error FIRST, which `next()` does not — see the file header.
    public func seek(_ t: Int64) -> ValueType {
        if iter.err() != nil {
            return .none
        }
        let valueType = iter.seek(t)
        if valueType == .none {
            return .none
        }

        // Double-check whether the landing sample falls in a deleted interval.
        let ts = atT()
        for itv in intervals {
            if ts < itv.mint {
                return valueType
            }
            if ts > itv.maxt {
                // CONSUMED. See the file header.
                intervals.removeFirst()
                continue
            }
            // Inside an interval: delegate the skipping to `next()`.
            return next()
        }

        // Past every deleted interval.
        return valueType
    }

    /// Go: `Next`, with its labelled `continue Outer`.
    public func next() -> ValueType {
        outer: while true {
            let valueType = iter.next()
            if valueType == .none {
                return .none
            }
            let ts = atT()
            var deleted = false
            for tr in intervals {
                if tr.inBounds(ts) {
                    // Deleted: fetch the next sample.
                    deleted = true
                    break
                }
                if ts <= tr.maxt {
                    // Reached only when `inBounds` was false, i.e. `ts < tr.mint`: keep the sample.
                    return valueType
                }
                // Past this interval — drop it and look at the next. CONSUMED.
                intervals.removeFirst()
            }
            if deleted {
                continue outer
            }
            return valueType
        }
    }
}
