//===----------------------------------------------------------------------===//
// Ported from storage/series.go @ v3.13.2 — a minimal slice.
//
// Only what is needed to iterate a known list of samples, which is what the
// differential fixtures for BufferedSeriesIterator and MemoizedSeriesIterator have
// to drive, plus its two natural companions.
//
// Deferred, each to the phase that first has a caller:
//   - `ChunkSeriesEntry`, `NewListChunkSeriesFromSamples`, `listChunkSeriesIterator`,
//     `seriesToChunkEncoder`, `errChunksIterator` -> Phase 6, with the chunk
//     encodings they need.
//   - `chunkSetToSeriesSet` / `seriesSetToChunkSet` (`NewSeriesSetFromChunkSeriesSet`,
//     `NewSeriesSetToChunkSet`) -> Phase 6 / the remote-read path in Phase 10.
//   - `ExpandSamples`, `ExpandSamplesWithoutReplacingNaNs`, `ExpandChunks` -> test
//     utilities with no production caller. Worth knowing when they arrive:
//     `ExpandSamples` substitutes -42 for NaN (series.go:484) purely so upstream's
//     tests can use `==`, which makes a genuine -42 indistinguishable from NaN.
//
// Nothing here has a production consumer upstream — `NewListSeries` has 45 call
// sites and every one is a `_test.go`. It is ported for the same reason
// `chunkenc.MockSeriesIterator` was: this port's fixtures need it.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromHistogram
public import PromLabels

/// Go: `SeriesEntry` — a `Series` whose iterator comes from a closure.
public final class SeriesEntry: Series {
    public var lset: Labels
    public var sampleIteratorFn: ((any ChunkIterator)?) -> any ChunkIterator

    public init(
        lset: Labels,
        sampleIteratorFn: @escaping ((any ChunkIterator)?) -> any ChunkIterator
    ) {
        self.lset = lset
        self.sampleIteratorFn = sampleIteratorFn
    }

    public func labels() -> Labels { lset }

    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        sampleIteratorFn(reuse)
    }
}

/// Go: `NewListSeries` — a series that iterates the supplied samples.
///
/// Recycles the iterator it is handed when it is already a ``ListSeriesIterator``,
/// mirroring series.go:49.
public func newListSeries(_ lset: Labels, _ s: [any Sample]) -> SeriesEntry {
    let samples = SampleSlice(s)
    return SeriesEntry(lset: lset) { reuse in
        if let existing = reuse as? ListSeriesIterator {
            existing.reset(samples)
            return existing
        }
        return newListSeriesIterator(samples)
    }
}

/// Go: `listSeriesIterator`.
///
/// One guard, and it is not a divergence: `At`/`AtT`/`AtST`/`AtHistogram` index
/// `samples[-1]` if called before the first `Next()` (series.go:122), which panics
/// in Go and would trap in Swift anyway. The precondition just says why.
///
/// What this deliberately does **not** "fix": `Seek` on a fresh iterator assigns
/// `idx = 0` before its bounds check (series.go:155), which reads like a stray
/// mutation. It is not observable — `Seek` positioning at element 0 and returning
/// its type is correct iterator behaviour, and a following `Next()` therefore moves
/// to element 1 as it should; for an empty list both paths return `.none`. Verified
/// against Go rather than assumed, so this port matches it exactly.
public class ListSeriesIterator: ChunkIterator {
    fileprivate var samples: any Samples
    fileprivate var idx: Int

    public init(_ samples: any Samples) {
        self.samples = samples
        self.idx = -1
    }

    /// Go: `Reset`.
    public func reset(_ samples: any Samples) {
        self.samples = samples
        self.idx = -1
    }

    /// Go reads `samples[-1]` here and panics; this reports the same failure with
    /// a message that names the cause.
    fileprivate func current() -> any Sample {
        precondition(
            idx >= 0, "ListSeriesIterator: at* called before next(); Go reads samples[-1]")
        return samples.get(idx)
    }

    public func at() -> (Int64, Double) {
        let s = current()
        return (s.t, s.f)
    }

    /// Go ignores the reuse argument entirely (series.go:126, an unnamed
    /// parameter) and returns the caller's own stored histogram, so the result
    /// **aliases** the sample list. ``ListSeriesIteratorWithCopy`` exists purely to
    /// fix that; both are ported because upstream uses both.
    public func atHistogram(_: Histogram?) -> (Int64, Histogram?) {
        let s = current()
        return (s.t, s.h)
    }

    public func atFloatHistogram(_: FloatHistogram?) -> (Int64, FloatHistogram?) {
        let s = current()
        return (s.t, s.fh)
    }

    public func atT() -> Int64 { current().t }

    public func atST() -> Int64 { current().st }

    public func next() -> ValueType {
        idx += 1
        if idx >= samples.count {
            return .none
        }
        return samples.get(idx).type
    }

    public func seek(_ t: Int64) -> ValueType {
        // Matches series.go:155 exactly, side effect included: `idx` is committed
        // to 0 even on the path that returns `.none` just below. See the type's
        // note for why that turns out not to be observable.
        if idx == -1 {
            idx = 0
        }
        if idx >= samples.count {
            return .none
        }
        // No-op check: inclusive, "at or after t".
        let s = samples.get(idx)
        if s.t >= t {
            return s.type
        }
        // Binary search between the current position and the end. Go writes this
        // as `it.idx += sort.Search(...)` with the closure reading `it.idx`, which
        // works only because Go evaluates the right-hand side first; spelled out
        // here so the ordering is explicit rather than incidental.
        let base = idx
        let searchCount = samples.count - base
        idx = base + ListSeriesIterator.search(searchCount) { i in
            samples.get(i + base).t >= t
        }

        if idx >= samples.count {
            return .none
        }
        return samples.get(idx).type
    }

    /// Go: `sort.Search` — the smallest index in `0..<n` for which `predicate` is
    /// true, or `n` if there is none.
    static func search(_ n: Int, _ predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = n
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(mid) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    public func err() -> (any Error)? { nil }
}

/// Go: `NewListSeriesIterator`.
public func newListSeriesIterator(_ samples: any Samples) -> any ChunkIterator {
    ListSeriesIterator(samples)
}

/// Go: `listSeriesIteratorWithCopy` — as ``ListSeriesIterator``, but honours the
/// caller's reuse buffer instead of handing back an alias.
public final class ListSeriesIteratorWithCopy: ListSeriesIterator {
    public override func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        let (t, ih) = super.atHistogram(nil)
        guard var destination = reuse, let source = ih else {
            return (t, ih)
        }
        source.copy(to: &destination)
        return (t, destination)
    }

    public override func atFloatHistogram(_ reuse: FloatHistogram?) -> (
        Int64, FloatHistogram?
    ) {
        let (t, ih) = super.atFloatHistogram(nil)
        guard var destination = reuse, let source = ih else {
            return (t, ih)
        }
        source.copy(to: &destination)
        return (t, destination)
    }
}

/// Go: `NewListSeriesIteratorWithCopy`.
public func newListSeriesIteratorWithCopy(_ samples: any Samples) -> any ChunkIterator {
    ListSeriesIteratorWithCopy(samples)
}
