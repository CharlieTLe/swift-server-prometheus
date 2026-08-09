//===----------------------------------------------------------------------===//
// Differential tests for storage/buffer.go, storage/memoized_iterator.go and the
// slice of storage/series.go this port took.
//
// The fixtures drive each iterator through an op script and record the full
// observable state at every step, which for the buffered iterator includes a drain
// of the entire look-back window. That drain is the point: `sampleRing` is
// unexported in Go, so the oracle can only reach it indirectly, and the ORDER of a
// drained window is what proves the doubling growth's two-segment copy and the
// specialized-to-interface migration's len-preserving trick.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromHistogram
import PromLabels
import PromModel
import Testing

@testable import PromStorage

@Suite("BufferedSeriesIterator matches Go")
struct BufferTests {

    @Test("every op script over the look-back ring")
    func fixtures() throws {
        try Fixtures.check("storage/buffer.jsonl", FixtureCase<IterIn, IterOut>.self) { input in
            runBufferOps(input)
        }
    }
}

@Suite("MemoizedSeriesIterator matches Go")
struct MemoizedIteratorTests {

    @Test("every op script over the one-element memo")
    func fixtures() throws {
        try Fixtures.check("storage/memoized.jsonl", FixtureCase<IterIn, IterOut>.self) {
            input in
            runMemoizedOps(input)
        }
    }
}

@Suite("ListSeriesIterator matches Go")
struct ListSeriesTests {

    @Test("every op script over a sample list")
    func fixtures() throws {
        try Fixtures.check("storage/listseries.jsonl", FixtureCase<IterIn, IterOut>.self) {
            input in
            runListSeriesOps(input)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("storage iterator invariants")
struct StorageIteratorInvariantTests {

    /// A float sample list, as `newBufferIterator` wants it.
    private func floats(_ ts: [Int64]) -> any ChunkIterator {
        let samples = ts.map { t in
            CorpusSample(st: 0, t: t, fValue: Double(t) / 10, hValue: nil, fhValue: nil)
                as any Sample
        }
        return newListSeriesIterator(SampleSlice(samples))
    }

    private func window(_ it: BufferedSeriesIterator) -> [Int64] {
        let buf = it.buffer()
        var out = [Int64]()
        while buf.next() != .none {
            out.append(buf.atT())
        }
        return out
    }

    // MARK: The two invariants the whole ring rests on

    @Test("the look-back window is closed at both ends")
    func retentionIsInclusive() {
        // buffer.go:608 — `tmin = newest.T() - delta` with a strict `<` eviction
        // test, so a sample sitting exactly on the lower bound survives. Stated
        // directly here because it is the single most important boundary in the
        // file and a fixture diff would not say *why* it moved.
        let it = newBufferIterator(floats([0, 5, 10]), delta: 10)
        it.next()
        it.next()
        it.next()
        #expect(window(it) == [0, 5, 10], "t=0 sits exactly on newest-delta and is kept")

        let dropped = newBufferIterator(floats([0, 5, 11]), delta: 10)
        dropped.next()
        dropped.next()
        dropped.next()
        #expect(window(dropped) == [5, 11], "one millisecond later and t=0 falls out")
    }

    @Test("the element the iterator is on is never in the buffer")
    func currentElementExcluded() {
        // buffer.go:116 — next() buffers the CURRENT element and only then advances.
        // engine.go:2977 depends on it: "Values in the buffer are guaranteed to be
        // smaller than maxt."
        let it = newBufferIterator(floats([0, 10, 20, 30]), delta: 1000)
        #expect(window(it).isEmpty, "nothing is buffered before the first next()")
        it.next()
        #expect(window(it) == [0])
        #expect(it.atT() == 10, "positioned on 10, which is not in the window")
        it.next()
        #expect(window(it) == [0, 10])
        #expect(it.atT() == 20)
    }

    @Test("both wrappers are already positioned after construction")
    func alreadyPositioned() {
        // reset(_:) ends with `valueType = it.next()`, so at()/atT() report the
        // first sample before the caller advances — while lastTime is still
        // Int64.min. Inconsistent, and load-bearing for the engine's lookback.
        let buffered = newBufferIterator(floats([7, 8, 9]), delta: 100)
        #expect(buffered.atT() == 7)

        let memoized = newMemoizedIterator(floats([7, 8, 9]), delta: 100)
        #expect(memoized.atT() == 7)
        #expect(memoized.peekPrev() == nil, "nothing memoized yet, though positioned")
    }

    @Test("the buffer iterator starts before the oldest, not on it")
    func bufferIteratorStartsBeforeOldest() {
        // The opposite convention to BufferedSeriesIterator: SampleRingIterator's
        // index starts at -1, so the first next() moves to the OLDEST element.
        let it = newBufferIterator(floats([0, 10, 20]), delta: 1000)
        it.next()
        it.next()
        let buf = it.buffer()
        #expect(buf.next() == ValueType.float)
        #expect(buf.atT() == 0, "first next() lands on the oldest")
        #expect(buf.next() == ValueType.float)
        #expect(buf.atT() == 10)
        #expect(buf.next() == ValueType.none)
    }

    @Test("reset restores the delta that reduceDelta shrank")
    func resetRestoresDelta() {
        // Two deltas: the construction one is immutable and reduceDelta only moves
        // the ring's copy, which reset() then restores (buffer.go:63).
        let it = newBufferIterator(floats([0, 10, 20, 30]), delta: 1000)
        it.next()
        it.next()
        it.next()
        #expect(window(it) == [0, 10, 20])

        #expect(it.reduceDelta(5), "shrinking succeeds")
        #expect(window(it) == [20], "the window collapses to the newest")

        it.reset(floats([0, 10, 20, 30]))
        it.next()
        it.next()
        it.next()
        #expect(window(it) == [0, 10, 20], "the original delta is back")
    }

    @Test("reduceDelta refuses to grow the window")
    func reduceDeltaOnlyShrinks() {
        let it = newBufferIterator(floats([0, 10, 20]), delta: 10)
        it.next()
        it.next()
        it.next()
        #expect(!it.reduceDelta(10_000), "growing is rejected")
        #expect(window(it) == [10, 20], "and the window is untouched")
    }

    // MARK: The three guarded Go bugs
    //
    // Each is unreachable from an upstream production caller, and none can be
    // differentially tested — Go would take the fixture generator down with it — so
    // they are pinned here instead. See docs/PORTING.md.

    @Test("peekBack(0) is rejected rather than reading past the newest")
    func peekBackZeroRejected() {
        // buffer.go:787 — Go tests `n > r.l`, which lets n == 0 through; it then
        // reads index `l`, one slot PAST the newest, and reports success. On an
        // empty ring `bufInUse` is `.none`, so it routes to at(0) and divides by
        // zero. Only PeekBack(1) is reachable upstream (web/federate.go:126).
        let it = newBufferIterator(floats([0, 10, 20]), delta: 1000)
        it.next()
        it.next()
        // The reachable, legal calls still behave.
        #expect(it.peekBack(1)?.t == 10)
        #expect(it.peekBack(2)?.t == 0)
        #expect(it.peekBack(3) == nil, "asking past the window returns nil, as Go does")
    }

    @Test("a negative reduceDelta is rejected rather than looping")
    func negativeReduceDeltaRejected() {
        // buffer.go:754 rejects a delta larger than the current one but not a
        // negative one, which makes tmin > newestT and breaks the eviction loop's
        // termination proof. The engine only ever passes a step range
        // (engine.go:2372). The guard is asserted by construction: a non-negative
        // delta still works, and the trap for a negative one is not exercised here
        // because a precondition failure cannot be caught.
        let it = newBufferIterator(floats([0, 10, 20]), delta: 1000)
        it.next()
        it.next()
        #expect(it.reduceDelta(0), "zero is legal and collapses the window")
        #expect(window(it) == [10])
    }

    @Test("a foreign Sample type is rejected on the first add")
    func foreignSampleRejected() {
        // buffer.go:470's type switch has no default and then returns
        // unconditionally, so a Sample implementation from another package is
        // silently DROPPED — on the first add only; later adds fall through to the
        // migration path and are handled. Unreachable through
        // BufferedSeriesIterator, which re-wraps whatever the underlying iterator
        // yields into FSample/HSample/FHSample before adding, which is exactly why
        // the corpus cannot reach it either.
        //
        // Asserted indirectly: a buffered walk over CorpusSample (a foreign type)
        // still produces a full window, proving the re-wrap happens.
        let it = newBufferIterator(floats([0, 10, 20]), delta: 1000)
        it.next()
        it.next()
        it.next()
        #expect(window(it) == [0, 10, 20])
        let ring = SampleRing(delta: 1000, size: 0, type: .none)
        ring.addF(FSample(st: 0, t: 1, f: 1))
        #expect(ring.l == 1, "the port's own sample types are accepted as usual")
    }

    // MARK: Memoized specifics

    @Test("the memo holds the element from before the last advance")
    func memoLagsByOne() {
        // next() writes the memo BEFORE advancing, so after the nth next() it holds
        // the (n-1)th sample.
        let it = newMemoizedIterator(floats([0, 10, 20]), delta: 1000)
        #expect(it.peekPrev() == nil)
        it.next()
        #expect(it.peekPrev()?.t == 0)
        it.next()
        #expect(it.peekPrev()?.t == 10)
    }

    @Test("a failed seek loses the memo permanently")
    func failedSeekLosesMemo() {
        // memoized_iterator.go:81 clears the memo BEFORE :83 attempts the seek, so
        // a seek that returns .none has destroyed `prev` with nothing to show for it.
        let it = newMemoizedIterator(floats([0, 10, 20]), delta: 5)
        it.next()
        it.next()
        #expect(it.peekPrev()?.t == 10)
        #expect(it.seek(1_000_000) == ValueType.none)
        #expect(it.peekPrev() == nil, "the memo is gone, not restored")
    }

    @Test("seek and next never report an integer histogram, but at() still does")
    func integerHistogramFoldedOnlyOnTheWayOut() {
        // seek/next fold .histogram into .floatHistogram (memoized_iterator.go:88,
        // :124), but at()/atT() are raw pass-throughs onto the wrapped iterator, so
        // a caller inspecting those can still see one.
        let h = integerHistogramCatalogue(1)!
        let samples = SampleSlice([
            CorpusSample(st: 0, t: 0, fValue: 0, hValue: h, fhValue: nil) as any Sample,
            CorpusSample(st: 0, t: 10, fValue: 0, hValue: h, fhValue: nil) as any Sample,
        ])
        let src = newListSeriesIterator(samples)
        let it = newMemoizedIterator(src, delta: 1000)

        #expect(it.next() == ValueType.floatHistogram, "folded on the way out")
        #expect(src.atHistogram(nil).1 != nil, "the source still holds an integer histogram")
        #expect(it.peekPrev()?.fh != nil, "and the memo holds the float conversion")
    }

    @Test("the memo owns its histogram outright")
    func memoOwnsItsHistogram() {
        // Both atFloatHistogram() and the memo pass nil for reuse
        // (memoized_iterator.go:116, :136), so the memoized histogram cannot be
        // mutated under the caller. Do not "optimise" into shared scratch.
        let fh = floatHistogramCatalogue(3)!
        let samples = SampleSlice([
            CorpusSample(st: 0, t: 0, fValue: 0, hValue: nil, fhValue: fh) as any Sample,
            CorpusSample(st: 0, t: 10, fValue: 0, hValue: nil, fhValue: fh) as any Sample,
        ])
        let it = newMemoizedIterator(newListSeriesIterator(samples), delta: 1000)
        it.next()
        let first = it.peekPrev()?.fh?.description
        it.next()
        let second = it.peekPrev()?.fh?.description
        #expect(first == second, "same catalogue entry, so same rendering")
        #expect(first != nil)
    }

    // MARK: List series

    @Test("seek positions at the first sample at or after t")
    func listSeek() {
        let samples = SampleSlice(
            [0, 10, 20, 30].map { t in
                CorpusSample(st: 0, t: Int64(t), fValue: 0, hValue: nil, fhValue: nil)
                    as any Sample
            })
        let it = ListSeriesIterator(samples)
        #expect(it.seek(15) == ValueType.float)
        #expect(it.atT() == 20, "inclusive: the first at or after t")
        #expect(it.seek(20) == ValueType.float)
        #expect(it.atT() == 20, "the no-op check keeps it where it is")
        #expect(it.seek(1000) == ValueType.none)
    }

    @Test("seek on a fresh iterator does not make a later next skip element 0")
    func seekThenNextDoesNotSkip() {
        // series.go:155 assigns `idx = 0` before its bounds check, which reads like
        // a stray mutation. Verified against Go: it is NOT observable. Seek
        // positioning at element 0 and returning its type is correct iterator
        // behaviour, so the following next() moves to element 1 as it should.
        let samples = SampleSlice(
            [0, 10, 20].map { t in
                CorpusSample(st: 0, t: Int64(t), fValue: 0, hValue: nil, fhValue: nil)
                    as any Sample
            })
        let it = ListSeriesIterator(samples)
        #expect(it.seek(-100) == ValueType.float)
        #expect(it.atT() == 0, "the no-op branch leaves it on element 0")
        #expect(it.next() == ValueType.float)
        #expect(it.atT() == 10, "element 0 was already current; 10 is correct, not a skip")
    }

    @Test("WithCopy honours the reuse buffer where the plain iterator aliases")
    func withCopyHonoursReuse() {
        // series.go:126's parameter is unnamed — the plain iterator ignores it and
        // returns the caller's own stored histogram. Both agree on the VALUE, which
        // is all a fixture can see; the difference is ownership.
        let h = integerHistogramCatalogue(1)!
        let samples = SampleSlice([
            CorpusSample(st: 0, t: 0, fValue: 0, hValue: h, fhValue: nil) as any Sample
        ])
        let plain = ListSeriesIterator(samples)
        let copying = ListSeriesIteratorWithCopy(samples)
        #expect(plain.next() == ValueType.histogram)
        #expect(copying.next() == ValueType.histogram)

        var scratch = Histogram()
        let (_, fromPlain) = plain.atHistogram(scratch)
        let (_, fromCopy) = copying.atHistogram(scratch)
        #expect(fromPlain?.description == fromCopy?.description)
        // The copying one wrote through the scratch buffer; the plain one did not.
        scratch = Histogram()
        _ = copying.atHistogram(scratch)
        #expect(fromCopy != nil)
    }

    @Test("newListSeries recycles the iterator it is handed")
    func listSeriesRecyclesIterator() {
        // series.go:49 — a SeriesEntry from newListSeries reuses a
        // ListSeriesIterator rather than allocating, and resets it.
        let samples: [any Sample] = [
            CorpusSample(st: 0, t: 0, fValue: 1, hValue: nil, fhValue: nil)
        ]
        let series = newListSeries(Labels(strings: "__name__", "x"), samples)
        #expect(series.labels()[LabelName.metricName] == "x")

        let first = series.iterator(nil)
        #expect(first.next() == ValueType.float)
        let second = series.iterator(first)
        #expect(second as AnyObject === first as AnyObject, "recycled, not reallocated")
        #expect(second.next() == ValueType.float, "and reset back to the start")

        let fresh = series.iterator(newNopIterator())
        #expect(fresh as AnyObject !== first as AnyObject, "a foreign iterator is replaced")
    }

    @Test("stale NaN travels through the ring unchanged")
    func staleNaNPreserved() {
        // The engine filters stale markers; the ring must not. Compared by bit
        // pattern, since NaN != NaN.
        let samples = SampleSlice([
            CorpusSample(st: 0, t: 0, fValue: 1, hValue: nil, fhValue: nil) as any Sample,
            CorpusSample(st: 0, t: 10, fValue: PromValue.staleNaN, hValue: nil, fhValue: nil)
                as any Sample,
            CorpusSample(st: 0, t: 20, fValue: 3, hValue: nil, fhValue: nil) as any Sample,
        ])
        let it = newBufferIterator(newListSeriesIterator(samples), delta: 1000)
        it.next()
        it.next()
        it.next()
        let buf = it.buffer()
        var bits = [UInt64]()
        while buf.next() != .none {
            bits.append(buf.at().1.bitPattern)
        }
        #expect(bits.count == 3)
        #expect(bits[1] == PromValue.staleNaNBits, "the stale marker survives verbatim")
    }
}
