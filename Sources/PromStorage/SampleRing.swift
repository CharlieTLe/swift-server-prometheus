//===----------------------------------------------------------------------===//
// Ported from storage/buffer.go @ v3.13.2 — fSample/hSample/fhSample, sampleRing,
// bufType and SampleRingIterator. `BufferedSeriesIterator` is in Buffer.swift.
//
// The ring is the highest-risk code in Phase 5: a mistake in its index arithmetic
// does not crash, it silently returns the wrong look-back window, which is the
// failure mode docs/ROADMAP.md cites for doing PromQL before TSDB. Two invariants
// carry the whole thing and are pinned by Fixtures/storage/buffer.jsonl:
//
//   1. Retention is [newestT - delta, newestT], CLOSED at both ends. `tmin` is
//      `newest.T() - delta` and the eviction test is a strict `<`
//      (buffer.go:608), so a sample landing exactly on the lower bound is kept.
//   2. Growth doubles with a two-segment copy that preserves logical order even
//      when the ring is wrapped, and the specialized -> interface migration
//      copies the RAW backing array, dead slots included, so `len` is unchanged
//      and `i`/`f` stay valid without recomputation.
//
// **Four typed buffers, deliberately.** Go keeps `iBuf`/`fBuf`/`hBuf`/`fhBuf`
// purely to dodge interface boxing for the common homogeneous case, and a single
// array of a Swift enum would behave identically for every reachable usage. It is
// reproduced anyway: this port is reviewed by diffing against the Go file, and
// (2) above stops being self-evident once the representation is restructured.
//
// **The Copy/CopyTo call sites look redundant and are kept anyway.** Go reuses the
// histogram already in a ring slot (`s.h.CopyTo(buf[r.i].h)`) so `atH(i)` returns
// a value aliasing the ring, which is then silently mutated when the slot
// recycles. Swift's `Histogram`/`FloatHistogram` are structs, so that hazard
// cannot exist here — but docs/PORTING.md §4 exception 4 requires every explicit
// Copy/CopyTo call site to survive the loss of `sync.Pool`, so the branch shape
// stays.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromHistogram

// MARK: - Concrete samples

/// Go: `fSample`.
public struct FSample: Sample {
    public var st: Int64
    public var t: Int64
    public var fValue: Double

    public init(st: Int64, t: Int64, f: Double) {
        self.st = st
        self.t = t
        self.fValue = f
    }

    public var f: Double { fValue }
    /// buffer.go:190 — `panic("H() called for fSample")`.
    public var h: Histogram? { preconditionFailure("h called for FSample") }
    /// buffer.go:194 — `panic("FH() called for fSample")`.
    public var fh: FloatHistogram? { preconditionFailure("fh called for FSample") }
    public var type: ValueType { .float }
    public func copy() -> any Sample { self }
}

/// Go: `hSample`.
public struct HSample: Sample {
    public var st: Int64
    public var t: Int64
    /// Optional because a freshly allocated ring slot holds Go's nil pointer.
    public var hValue: Histogram?

    public init(st: Int64, t: Int64, h: Histogram?) {
        self.st = st
        self.t = t
        self.hValue = h
    }

    /// buffer.go:219 — `panic("F() called for hSample")`.
    public var f: Double { preconditionFailure("f called for HSample") }
    public var h: Histogram? { hValue }
    /// buffer.go:227 — `s.h.ToFloat(nil)`, so this allocates on every read. A
    /// hidden conversion behind what reads like a getter; kept as-is.
    public var fh: FloatHistogram? { hValue?.toFloat() }
    public var type: ValueType { .histogram }
    public func copy() -> any Sample {
        HSample(st: st, t: t, h: hValue?.copy())
    }
}

/// Go: `fhSample`.
public struct FHSample: Sample {
    public var st: Int64
    public var t: Int64
    public var fhValue: FloatHistogram?

    public init(st: Int64, t: Int64, fh: FloatHistogram?) {
        self.st = st
        self.t = t
        self.fhValue = fh
    }

    /// buffer.go:252 — `panic("F() called for fhSample")`.
    public var f: Double { preconditionFailure("f called for FHSample") }
    /// buffer.go:256 — `panic("H() called for fhSample")`.
    public var h: Histogram? { preconditionFailure("h called for FHSample") }
    public var fh: FloatHistogram? { fhValue }
    public var type: ValueType { .floatHistogram }
    public func copy() -> any Sample {
        FHSample(st: st, t: t, fh: fhValue?.copy())
    }
}

// MARK: - The ring

/// Go: `bufType`. Which of the four backing arrays is live.
enum BufType {
    /// Go: `noBuf` — nothing stored yet.
    case none
    case interfaceBuf
    case float
    case histogram
    case floatHistogram
}

/// Go: `sampleRing`.
final class SampleRing {
    /// Mutable: `ReduceDelta` shrinks it. `BufferedSeriesIterator` keeps the
    /// original separately and restores it on `reset(_:)`.
    var delta: Int64

    // Lookback buffers. `interfaceBuf` holds mixed samples; one of the other
    // three holds homogeneous ones. Only ONE may be populated at a time.
    var interfaceBuf: [any Sample] = []
    var floatBuf: [FSample] = []
    var histogramBuf: [HSample] = []
    var floatHistogramBuf: [FHSample] = []
    var bufInUse: BufType = .none

    /// Position of the most recent element.
    var i: Int = -1
    /// Position of the first (oldest) element.
    var f: Int = 0
    /// Number of live elements.
    var l: Int = 0

    /// Go embeds a single `SampleRingIterator` value and hands out a pointer to
    /// it, which is why `Buffer()` is documented as invalidating previously
    /// returned iterators. Reproduced with one owned instance; the iterator holds
    /// the ring `unowned`, since Go's is embedded and cannot outlive it.
    private lazy var sharedIterator = SampleRingIterator(self)

    /// Go: `newSampleRing`. `size <= 0` defers allocation to the first add, which
    /// then picks the type from the first sample. `BufferedSeriesIterator` always
    /// uses that form (buffer.go:49), so `size > 0` is test-only upstream.
    init(delta: Int64, size: Int, type: ValueType) {
        self.delta = delta
        reset()
        if size <= 0 {
            return
        }
        switch type {
        case .float:
            floatBuf = [FSample](repeating: FSample(st: 0, t: 0, f: 0), count: size)
        case .histogram:
            histogramBuf = [HSample](repeating: HSample(st: 0, t: 0, h: nil), count: size)
        case .floatHistogram:
            floatHistogramBuf = [FHSample](
                repeating: FHSample(st: 0, t: 0, fh: nil), count: size)
        default:
            // Nothing to do: the first sample lands in one of the other buffers.
            break
        }
    }

    /// Go: `reset`.
    func reset() {
        l = 0
        i = -1
        f = 0
        bufInUse = .none
        // The interface buffer must be emptied too: the first sample after a
        // reset always goes to a specialized buffer, and the later migration
        // appends into this one assuming it is length zero.
        interfaceBuf.removeAll(keepingCapacity: true)
    }

    /// Go: `iterator()`. Invalidates previously returned iterators.
    func iterator() -> SampleRingIterator {
        sharedIterator.reset()
        return sharedIterator
    }

    // MARK: Reads

    /// Go: `at(i)`. Wraps by the backing array's length; deliberately does *not*
    /// bounds-check `index` against `l`, so callers must respect the live count.
    func at(_ index: Int) -> any Sample {
        let j = (f + index) % interfaceBuf.count
        return interfaceBuf[j]
    }

    /// Go: `atF(i)`.
    func atF(_ index: Int) -> FSample {
        let j = (f + index) % floatBuf.count
        return floatBuf[j]
    }

    /// Go: `atH(i)`.
    func atH(_ index: Int) -> HSample {
        let j = (f + index) % histogramBuf.count
        return histogramBuf[j]
    }

    /// Go: `atFH(i)`.
    func atFH(_ index: Int) -> FHSample {
        let j = (f + index) % floatHistogramBuf.count
        return floatHistogramBuf[j]
    }

    /// Go: `nthLast(n)` — the nth most recent sample, 1-based.
    ///
    /// **Guarded, diverging from Go.** buffer.go:787 tests `n > r.l`, which lets
    /// `n == 0` through; it then reads index `l`, one slot *past* the newest, and
    /// reports success. On an empty ring `bufInUse` is `.none`, so it routes to
    /// `at(0)` and divides by zero. Only `PeekBack(1)` is reachable upstream
    /// (web/federate.go:126). See docs/PORTING.md.
    func nthLast(_ n: Int) -> (any Sample)? {
        precondition(n >= 1, "nthLast(\(n)): n must be at least 1; Go reads past the newest")
        if n > l {
            return nil
        }
        let index = l - n
        switch bufInUse {
        case .float: return atF(index)
        case .histogram: return atH(index)
        case .floatHistogram: return atFH(index)
        default: return at(index)
        }
    }

    /// Go: `samples()` — the live window, oldest first. Test-only upstream
    /// (its sole caller is buffer_test.go:71); kept because the fixture harness
    /// wants a whole-window read that does not go through the iterator.
    func samples() -> [any Sample] {
        var out = [any Sample]()
        out.reserveCapacity(l)
        for k in 0..<l {
            switch bufInUse {
            case .float: out.append(atF(k))
            case .histogram: out.append(atH(k))
            case .floatHistogram: out.append(atFH(k))
            default: out.append(at(k))
            }
        }
        return out
    }

    // MARK: Writes

    /// Go: `add(s)` — the general path, for any `Sample` implementation.
    func add(_ s: any Sample) {
        if bufInUse == .none {
            // First sample: pick the specialized buffer matching its type.
            //
            // **Guarded, diverging from Go.** buffer.go:470's type switch has no
            // `default` and then returns unconditionally, so a foreign Sample
            // implementation is silently dropped — on the *first* add only, since
            // later adds fall through to the migration path and are handled.
            switch s {
            case let s as FSample:
                bufInUse = .float
                addF(s, growing: &floatBuf)
            case let s as HSample:
                bufInUse = .histogram
                addH(s, growing: &histogramBuf)
            case let s as FHSample:
                bufInUse = .floatHistogram
                addFH(s, growing: &floatHistogramBuf)
            default:
                preconditionFailure(
                    "SampleRing.add: unsupported first sample type \(type(of: s)); "
                        + "Go drops it silently (buffer.go:470)")
            }
            return
        }

        if bufInUse != .interfaceBuf {
            // Still homogeneous. Stay specialized if the new sample fits.
            switch s {
            case let s as FSample where bufInUse == .float:
                addF(s, growing: &floatBuf)
                return
            case let s as HSample where bufInUse == .histogram:
                addH(s, growing: &histogramBuf)
                return
            case let s as FHSample where bufInUse == .floatHistogram:
                addFH(s, growing: &floatHistogramBuf)
                return
            default:
                break
            }

            // It does not fit. Migrate the specialized buffer into the interface
            // buffer, which is length zero at this point.
            //
            // buffer.go:508 copies the RAW backing array — every slot, dead ones
            // included — NOT the live window in logical order. That is required:
            // it keeps `len` identical so `i` and `f` remain valid. Copying only
            // the live samples would mean rebasing `f` to 0 and `i` to `l - 1`.
            switch bufInUse {
            case .float:
                for s in floatBuf { interfaceBuf.append(s) }
                floatBuf = []
            case .histogram:
                for s in histogramBuf { interfaceBuf.append(s) }
                histogramBuf = []
            case .floatHistogram:
                for s in floatHistogramBuf { interfaceBuf.append(s) }
                floatHistogramBuf = []
            default:
                break
            }
            bufInUse = .interfaceBuf
        }

        addSample(s, growing: &interfaceBuf)
    }

    /// Go: `addF` (the method) — specialized for `fSample`.
    func addF(_ s: FSample) {
        switch bufInUse {
        case .float:
            addF(s, growing: &floatBuf)
        case .none:
            addF(s, growing: &floatBuf)
            bufInUse = .float
        case .interfaceBuf:
            addSample(s, growing: &interfaceBuf)
        default:
            // Specialized, but not for floats — go through the checked path so
            // the migration happens.
            add(s)
        }
    }

    /// Go: `addH` (the method).
    func addH(_ s: HSample) {
        switch bufInUse {
        case .histogram:
            addH(s, growing: &histogramBuf)
        case .none:
            addH(s, growing: &histogramBuf)
            bufInUse = .histogram
        case .interfaceBuf:
            addSample(s, growing: &interfaceBuf)
        default:
            add(s)
        }
    }

    /// Go: `addFH` (the method).
    func addFH(_ s: FHSample) {
        switch bufInUse {
        case .floatHistogram:
            addFH(s, growing: &floatHistogramBuf)
        case .none:
            addFH(s, growing: &floatHistogramBuf)
            bufInUse = .floatHistogram
        case .interfaceBuf:
            addSample(s, growing: &interfaceBuf)
        default:
            add(s)
        }
    }

    // MARK: The four package-level add helpers

    /// Makes room for one more element and returns the slot index to write.
    ///
    /// Go writes this growth block out four times, once per buffer type
    /// (buffer.go:582, 621, 660, 705); the four copies are identical apart from
    /// the element type. Factored here because the arithmetic is the part that
    /// must be right, and four copies of it is four chances to be wrong.
    ///
    /// Written as stepwise statements rather than compound expressions: the Swift
    /// 6.1 floor job gives up on long chains of integer literals, which has
    /// already broken this repo's CI (HANDOFF §4).
    private func makeRoom<T>(in buf: inout [T], filler: T) -> Int {
        var length = buf.count
        // Grow the ring buffer if it fits no more elements.
        if length == 0 {
            buf = [T](repeating: filler, count: 16)
            length = 16
        }
        if length == l {
            var newBuf = [T](repeating: filler, count: 2 * length)
            // Two segments: the tail of the ring moves to the high half, the head
            // to the low half, so reading from the new `f` and wrapping at 2*len
            // yields the original logical order.
            for k in f..<length {
                newBuf[length + k] = buf[k]
            }
            for k in 0..<f {
                newBuf[k] = buf[k]
            }
            buf = newBuf
            i = f
            f += length
        } else {
            i += 1
            if i >= length {
                i -= length
            }
        }
        return i
    }

    /// The eviction loop shared by all four add helpers.
    ///
    /// Go duplicates it five times — once per add helper plus `genericReduceDelta`
    /// — with two anchors that are equivalent: the sample being added (`s.T()`)
    /// versus the newest in the ring (`buf[r.i].T()`). They agree because the
    /// sample being added *is* the newest.
    ///
    /// The test is a strict `<` against `newestT - delta`, so a sample sitting
    /// exactly on the lower bound survives: the window is closed at both ends.
    private func evict<T>(in buf: [T], newestT: Int64, timestamp: (T) -> Int64) {
        let tmin = newestT - delta
        while timestamp(buf[f]) < tmin {
            f += 1
            if f >= buf.count {
                f -= buf.count
            }
            l -= 1
        }
    }

    /// Go: package-level `addSample` — the interface case. Note it deep-copies
    /// (buffer.go:604), where `addF` stores by value.
    private func addSample(_ s: any Sample, growing buf: inout [any Sample]) {
        let slot = makeRoom(in: &buf, filler: FSample(st: 0, t: 0, f: 0))
        buf[slot] = s.copy()
        l += 1
        evict(in: buf, newestT: s.t) { $0.t }
    }

    /// Go: package-level `addF`.
    private func addF(_ s: FSample, growing buf: inout [FSample]) {
        let slot = makeRoom(in: &buf, filler: FSample(st: 0, t: 0, f: 0))
        buf[slot] = s
        l += 1
        evict(in: buf, newestT: s.t) { $0.t }
    }

    /// Go: package-level `addH`.
    private func addH(_ s: HSample, growing buf: inout [HSample]) {
        let slot = makeRoom(in: &buf, filler: HSample(st: 0, t: 0, h: nil))
        buf[slot].t = s.t
        buf[slot].st = s.st
        // buffer.go:684 — reuse the histogram already in the slot when there is
        // one. Redundant for a Swift value type; kept per PORTING.md §4.
        if buf[slot].hValue == nil {
            buf[slot].hValue = s.hValue?.copy()
        } else if var destination = buf[slot].hValue, let source = s.hValue {
            source.copy(to: &destination)
            buf[slot].hValue = destination
        } else {
            buf[slot].hValue = s.hValue
        }
        l += 1
        evict(in: buf, newestT: s.t) { $0.t }
    }

    /// Go: package-level `addFH`.
    private func addFH(_ s: FHSample, growing buf: inout [FHSample]) {
        let slot = makeRoom(in: &buf, filler: FHSample(st: 0, t: 0, fh: nil))
        buf[slot].t = s.t
        buf[slot].st = s.st
        // buffer.go:729 — as addH.
        if buf[slot].fhValue == nil {
            buf[slot].fhValue = s.fhValue?.copy()
        } else if var destination = buf[slot].fhValue, let source = s.fhValue {
            source.copy(to: &destination)
            buf[slot].fhValue = destination
        } else {
            buf[slot].fhValue = s.fhValue
        }
        l += 1
        evict(in: buf, newestT: s.t) { $0.t }
    }

    /// Go: `reduceDelta`. Can only shrink; returns false and does nothing when
    /// asked to grow.
    ///
    /// **Guarded, diverging from Go.** buffer.go:754 rejects `delta > r.delta` but
    /// not a negative delta, which makes `tmin > newestT` and breaks the eviction
    /// loop's termination proof — it walks past the newest into stale slots and can
    /// drive `l` negative. The engine only ever passes a step range
    /// (engine.go:2372). See docs/PORTING.md.
    func reduceDelta(_ newDelta: Int64) -> Bool {
        precondition(newDelta >= 0, "reduceDelta(\(newDelta)): a negative delta never terminates")
        if newDelta > delta {
            return false
        }
        delta = newDelta

        if l == 0 {
            return true
        }

        // Go anchors on the newest sample already in the ring here, rather than on
        // one being added.
        switch bufInUse {
        case .float:
            evict(in: floatBuf, newestT: floatBuf[i].t) { $0.t }
        case .histogram:
            evict(in: histogramBuf, newestT: histogramBuf[i].t) { $0.t }
        case .floatHistogram:
            evict(in: floatHistogramBuf, newestT: floatHistogramBuf[i].t) { $0.t }
        default:
            evict(in: interfaceBuf, newestT: interfaceBuf[i].t) { $0.t }
        }
        return true
    }
}

// MARK: - The buffer iterator

/// Go: `SampleRingIterator`, returned by `BufferedSeriesIterator.buffer()`.
///
/// Iterates the look-back window oldest to newest. Unlike
/// ``BufferedSeriesIterator``, this one is *not* pre-positioned: it starts at
/// index -1, so the first ``next()`` moves to the oldest element.
public final class SampleRingIterator {
    private unowned let r: SampleRing
    private var i: Int = -1
    private var stValue: Int64 = 0
    private var tValue: Int64 = 0
    private var fValue: Double = 0
    private var hValue: Histogram?
    private var fhValue: FloatHistogram?

    init(_ r: SampleRing) {
        self.r = r
    }

    /// Go: `reset(r)`. Note it clears `h`/`fh` but leaves `f` alone.
    func reset() {
        i = -1
        hValue = nil
        fhValue = nil
    }

    /// Go: `Next()`.
    public func next() -> ValueType {
        i += 1
        if i >= r.l {
            return .none
        }
        switch r.bufInUse {
        case .float:
            let s = r.atF(i)
            stValue = s.st
            tValue = s.t
            fValue = s.fValue
            return .float
        case .histogram:
            let s = r.atH(i)
            stValue = s.st
            tValue = s.t
            hValue = s.hValue
            return .histogram
        case .floatHistogram:
            let s = r.atFH(i)
            stValue = s.st
            tValue = s.t
            fhValue = s.fhValue
            return .floatHistogram
        default:
            break
        }

        // The mixed case. Note the asymmetry with the three branches above: here
        // the histogram branches cross-nil each other, but the float branch
        // (buffer.go:403) sets only `f` and leaves `h`/`fh` pointing at the
        // PREVIOUS histogram. So `atFloatHistogram()` after a float sample in a
        // mixed ring returns a stale histogram rather than nil. Callers must
        // switch on the returned ValueType; the engine does.
        let s = r.at(i)
        stValue = s.st
        tValue = s.t
        switch s.type {
        case .histogram:
            hValue = s.h
            fhValue = nil
            return .histogram
        case .floatHistogram:
            fhValue = s.fh
            hValue = nil
            return .floatHistogram
        default:
            fValue = s.f
            return .float
        }
    }

    /// Go: `At()`. Does **not** check the value type — for a histogram sample the
    /// float returned is whatever the last float sample left behind.
    public func at() -> (Int64, Double) { (tValue, fValue) }

    /// Go: `AtHistogram()`.
    public func atHistogram() -> (Int64, Histogram?) { (tValue, hValue) }

    /// Go: `AtFloatHistogram(fh)`. Converts an integer histogram, and always
    /// returns something the caller owns.
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        if fhValue == nil {
            // buffer.go:425 — `it.h.ToFloat(fh)`, which traps if `h` is nil too.
            // Reachable only by calling this on a float sample in a homogeneous
            // float ring, which the ValueType contract forbids.
            guard let h = hValue else {
                preconditionFailure(
                    "atFloatHistogram on a non-histogram sample; check the ValueType first")
            }
            if var destination = reuse {
                h.toFloat(into: &destination)
                return (tValue, destination)
            }
            return (tValue, h.toFloat())
        }
        if var destination = reuse, let source = fhValue {
            source.copy(to: &destination)
            return (tValue, destination)
        }
        return (tValue, fhValue?.copy())
    }

    /// Go: `AtT()`.
    public func atT() -> Int64 { tValue }

    /// Go: `AtST()`.
    public func atST() -> Int64 { stValue }
}
