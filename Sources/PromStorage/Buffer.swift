//===----------------------------------------------------------------------===//
// Ported from storage/buffer.go @ v3.13.2 — BufferedSeriesIterator.
// The ring it wraps is in SampleRing.swift.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromHistogram

/// Go: `BufferedSeriesIterator` — an iterator with a look-back buffer holding the
/// last `delta` milliseconds of samples.
///
/// Two behaviours are surprising and load-bearing:
///
/// - **The current element is never in the buffer.** ``next()`` pushes the element
///   the iterator is *currently* on into the ring and only then advances
///   (buffer.go:116). `promql/engine.go:2977` relies on it: "Values in the buffer
///   are guaranteed to be smaller than maxt."
/// - **The iterator is already positioned after construction.** ``reset(_:)`` ends
///   with `valueType = it.next()`, so ``at()``/``atT()`` return the *first* sample
///   before the caller does anything, while ``lastTime`` is still `Int64.min`.
///   That state is internally inconsistent and the engine depends on it.
public final class BufferedSeriesIterator {
    /// Reusable decode scratch, passed into the wrapped iterator's
    /// `atHistogram`/`atFloatHistogram` (buffer.go:125, 129). The result is deep
    /// copied by the ring immediately, so the aliasing is contained.
    private var hReader = Histogram()
    private var fhReader = FloatHistogram()

    private var it: any ChunkIterator
    private let buf: SampleRing
    /// The construction-time delta. Immutable: ``reduceDelta(_:)`` shrinks the
    /// *ring's* copy, and ``reset(_:)`` restores the ring from this one.
    private let delta: Int64

    private var lastTime: Int64 = .min
    private var valueType: ValueType = .none

    /// Go: `NewBufferIterator`.
    public init(_ it: any ChunkIterator, delta: Int64) {
        self.buf = SampleRing(delta: delta, size: 0, type: .none)
        self.delta = delta
        self.it = it
        reset(it)
    }

    /// Go: `Reset` — re-use the buffer with a new iterator, restoring the delta.
    public func reset(_ it: any ChunkIterator) {
        self.it = it
        lastTime = .min
        buf.reset()
        buf.delta = delta
        valueType = it.next()
    }

    /// Go: `ReduceDelta` — lowers the buffered delta for this iterator only.
    /// Returns false and does nothing when asked to *raise* it.
    @discardableResult
    public func reduceDelta(_ newDelta: Int64) -> Bool {
        buf.reduceDelta(newDelta)
    }

    /// Go: `PeekBack(n)` — the nth previous element, 1-based. nil when the buffer
    /// holds fewer than n.
    public func peekBack(_ n: Int) -> (any Sample)? {
        buf.nthLast(n)
    }

    /// Go: `Buffer()` — an iterator over the buffered window. Invalidates any
    /// iterator previously returned from this method.
    public func buffer() -> SampleRingIterator {
        buf.iterator()
    }

    /// Go: `Seek(t)` — advance to the element at time `t` or greater.
    public func seek(_ t: Int64) -> ValueType {
        // The ring's delta, not the construction one: `ReduceDelta` moves this.
        let t0 = t - buf.delta

        // If the delta would seek backwards, preserve the buffer and advance
        // normally, filling it on the way. The test is strict, so at equality the
        // buffer survives.
        if valueType != .none && t0 > lastTime {
            // Note the ordering: the buffer is wiped *before* the seek is known to
            // succeed, so a failed seek loses the window and never restores it or
            // updates `lastTime`.
            buf.reset()

            valueType = it.seek(t0)
            switch valueType {
            case .none:
                return .none
            case .float, .histogram, .floatHistogram:
                lastTime = atT()
            default:
                // Go panics here. Reachable because `ValueType` is a
                // RawRepresentable struct in this port, not a closed enum.
                preconditionFailure("BufferedSeriesIterator: unknown value type \(valueType)")
            }
        }

        if lastTime >= t {
            return valueType
        }
        while true {
            valueType = next()
            if valueType == .none || lastTime >= t {
                return valueType
            }
        }
    }

    /// Go: `Next()` — buffer the current element, then advance.
    @discardableResult
    public func next() -> ValueType {
        // Add the current element to the buffer before advancing.
        switch valueType {
        case .none:
            return .none
        case .float:
            let (t, f) = it.at()
            let st = it.atST()
            buf.addF(FSample(st: st, t: t, f: f))
        case .histogram:
            let (t, h) = it.atHistogram(hReader)
            let st = it.atST()
            buf.addH(HSample(st: st, t: t, h: h))
        case .floatHistogram:
            let (t, fh) = it.atFloatHistogram(fhReader)
            let st = it.atST()
            buf.addFH(FHSample(st: st, t: t, fh: fh))
        default:
            preconditionFailure("BufferedSeriesIterator: unknown value type \(valueType)")
        }

        valueType = it.next()
        if valueType != .none {
            lastTime = atT()
        }
        return valueType
    }

    /// Go: `At()`. A raw pass-through, so it reports the first sample before any
    /// ``next()`` — see the type's note.
    public func at() -> (Int64, Double) { it.at() }

    /// Go: `AtHistogram(fh)`. Upstream misnames the parameter `fh` even though it
    /// is an integer histogram (buffer.go:149); the name is fixed here, the
    /// behaviour is not.
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        it.atHistogram(reuse)
    }

    /// Go: `AtFloatHistogram(fh)`.
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        it.atFloatHistogram(reuse)
    }

    /// Go: `AtT()`.
    public func atT() -> Int64 { it.atT() }

    /// Go: `AtST()`.
    public func atST() -> Int64 { it.atST() }

    /// Go: `Err()`.
    public func err() -> (any Error)? { it.err() }
}

/// Go: `NewBuffer(delta)` — allocate now, attach a real iterator later with
/// ``BufferedSeriesIterator/reset(_:)``. This is the form the PromQL engine uses:
/// one buffer per selector, reset per series.
public func newBuffer(delta: Int64) -> BufferedSeriesIterator {
    BufferedSeriesIterator(newNopIterator(), delta: delta)
}

/// Go: `NewBufferIterator(it, delta)`.
public func newBufferIterator(_ it: any ChunkIterator, delta: Int64) -> BufferedSeriesIterator {
    BufferedSeriesIterator(it, delta: delta)
}
