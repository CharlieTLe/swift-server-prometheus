//===----------------------------------------------------------------------===//
// Ported from storage/memoized_iterator.go @ v3.13.2
//
// Upstream's own doc comment is worth keeping in mind: this "deliberately does not
// implement chunkenc.Iterator", and it "regards integer histograms as float
// histograms", so `seek`/`next` never return `.histogram`.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromHistogram

/// Go: `MemoizedSeriesIterator` — wraps an iterator and remembers exactly one
/// previous element.
///
/// Like ``BufferedSeriesIterator`` it is **already positioned** after
/// construction: ``reset(_:)`` ends with `valueType = it.next()`, so ``at()`` and
/// ``atT()`` report the first sample before the caller advances, while `lastTime`
/// is still `Int64.min`. The consequence is that the *first* ``seek(_:)`` almost
/// always takes the hard-seek branch, discarding the fact that the iterator was
/// already positioned. Asymmetric, and load-bearing for the engine's lookback.
public final class MemoizedSeriesIterator {
    private var it: any ChunkIterator
    /// Immutable, unlike ``BufferedSeriesIterator``'s pair of deltas.
    private let delta: Int64

    private var lastTime: Int64 = .min
    private var valueType: ValueType = .none

    /// The previously returned value. `nil` means nothing is memoized.
    ///
    /// Go signals "nothing memoized" with `prevTime == math.MinInt64`
    /// (memoized_iterator.go:68), which would make a genuine sample at
    /// `Int64.min` invisible. An Optional says the same thing without the blind
    /// spot; see docs/PORTING.md.
    private var prev: (t: Int64, value: Double, fh: FloatHistogram?)?

    /// Go: `NewMemoizedIterator`.
    public init(_ it: any ChunkIterator, delta: Int64) {
        self.it = it
        self.delta = delta
        reset(it)
    }

    /// Go: `Reset` — reuse the wrapper with a new iterator.
    ///
    /// Note it does *not* resync `lastTime` with the iterator, which is now
    /// positioned on sample 0.
    public func reset(_ it: any ChunkIterator) {
        self.it = it
        lastTime = .min
        prev = nil
        valueType = it.next()
    }

    /// Go: `PeekPrev()` — the previous element, or nil if none is buffered.
    public func peekPrev() -> (t: Int64, value: Double, fh: FloatHistogram?)? {
        prev
    }

    /// Go: `Seek(t)` — advance to the element at time `t` or greater.
    ///
    /// Structurally the same as ``BufferedSeriesIterator/seek(_:)``, and the three
    /// differences are the point: this clears the memo rather than the ring, uses
    /// the single immutable delta, and folds `.histogram` into `.floatHistogram`
    /// where the buffered iterator traps on an unknown type.
    public func seek(_ t: Int64) -> ValueType {
        let t0 = t - delta

        if valueType != .none && t0 > lastTime {
            // Reset the memo because the seek advanced more than the delta.
            //
            // Ordering, as in the buffered iterator: the memo is discarded before
            // the seek is known to succeed, so a seek that returns `.none` loses
            // `prev` permanently.
            prev = nil

            valueType = it.seek(t0)
            switch valueType {
            case .none:
                return .none
            case .histogram:
                valueType = .floatHistogram
            default:
                break
            }
            lastTime = it.atT()
        }
        if lastTime >= t {
            return valueType
        }
        while next() != .none {
            if lastTime >= t {
                return valueType
            }
        }
        return .none
    }

    /// Go: `Next()` — memoize the current element, then advance.
    ///
    /// Upstream's comment matters: this "does not check whether the element being
    /// buffered is within the time range of the current element and the duration of
    /// delta before". `delta` is used *only* to compute the hard-seek target in
    /// ``seek(_:)``. The staleness check lives in the engine
    /// (`promql/engine.go:2729`), which is what makes the lookback window
    /// half-open — `(refTime - lookbackDelta, refTime]`. Do not move it here.
    @discardableResult
    public func next() -> ValueType {
        // Keep track of the previous element.
        switch valueType {
        case .none:
            return .none
        case .float:
            let (t, v) = it.at()
            prev = (t: t, value: v, fh: nil)
        case .histogram, .floatHistogram:
            // Both pass nil for reuse, so the memoized histogram is owned outright
            // and cannot be mutated under us. Do not "optimise" into shared
            // scratch.
            let (t, fh) = it.atFloatHistogram(nil)
            prev = (t: t, value: 0, fh: fh)
        default:
            break
        }

        valueType = it.next()
        if valueType != .none {
            lastTime = it.atT()
        }
        if valueType == .histogram {
            valueType = .floatHistogram
        }
        return valueType
    }

    /// Go: `At()`. A raw pass-through — so, unlike ``seek(_:)``/``next()``, a
    /// caller inspecting this can still observe an integer histogram.
    public func at() -> (Int64, Double) { it.at() }

    /// Go: `AtFloatHistogram()`. Always allocates; see the note in ``next()``.
    public func atFloatHistogram() -> (Int64, FloatHistogram?) {
        it.atFloatHistogram(nil)
    }

    /// Go: `AtT()`.
    public func atT() -> Int64 { it.atT() }

    /// Go: `Err()`.
    public func err() -> (any Error)? { it.err() }
}

/// Go: `NewMemoizedEmptyIterator(delta)`.
public func newMemoizedEmptyIterator(delta: Int64) -> MemoizedSeriesIterator {
    MemoizedSeriesIterator(newNopIterator(), delta: delta)
}

/// Go: `NewMemoizedIterator(it, delta)`.
public func newMemoizedIterator(_ it: any ChunkIterator, delta: Int64)
    -> MemoizedSeriesIterator
{
    MemoizedSeriesIterator(it, delta: delta)
}
