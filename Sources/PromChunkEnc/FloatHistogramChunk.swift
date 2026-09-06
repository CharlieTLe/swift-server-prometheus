//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/float_histogram.go @ v3.13.2 — the FLOAT native-histogram chunk encoding.
//
// The layout, from upstream's own table:
//
//     field →    ts    count zeroCount sum []posbuckets []negbuckets
//     sample 1   raw   raw   raw       raw []raw        []raw
//     sample 2   delta xor   xor       xor []xor        []xor
//     sample >2  dod   xor   xor       xor []xor        []xor
//
// So the timestamp is varbit and **everything else is Gorilla XOR**, each field carrying its own
// leading/trailing window. `xorValue` is that triple, and there is one per count, per zero count, per
// sum, and per bucket — which is why the appender's bucket slices are `[XORValue]` here and `[Int64]`
// in the integer chunk.
//
// ## Read this next to `HistogramChunk.swift`; the differences are the whole file
//
// Seven of them, and every one is a place a shared implementation would be wrong:
//
//  1. **Buckets are ABSOLUTE, not deltas.** `expandFloatSpansAndBuckets` assigns the running count
//     where `expandIntSpansAndBuckets` accumulates it, and `insert` is called with `deltas: false`
//     rather than `true`.
//  2. **`appendable` returns a `counterReset` BOOL, not a `CounterResetHeader`.** So the schema /
//     zero-threshold arm, which the integer chunk reports as `UnknownCounterReset`, becomes plain
//     "no reset" — and `AppendHistogram`'s first-sample path then writes `NotCounterReset` where the
//     integer path writes `UnknownCounterReset`. The same two histograms in the two encodings give
//     chunks with different headers.
//  3. **The counter-reset header on a cut is written only when there WAS a reset.** The integer path
//     calls `setCounterResetHeader(counterResetHint)` unconditionally; this one guards it, so a
//     schema-change cut leaves the header at `UnknownCounterReset` (zero) instead of writing it.
//  4. **The layout is not re-derived from the appender's spans on the first sample of a recode**, but
//     the first sample's bucket values are seeded into `pBuckets` with `leading: 0xff` — so each
//     bucket's XOR window starts at the sentinel independently.
//  5. **The count and zero count are raw 64-bit floats on the first sample**, where the integer chunk
//     uses unsigned varbits.
//  6. **The iterator cannot answer `AtHistogram` at all** — Go panics. There is no float-to-integer
//     conversion, unlike the integer iterator's `AtFloatHistogram`, which converts happily.
//  7. **`Reset` clears `customValues` only on the recycling path**, where the integer iterator clears
//     it unconditionally. Unobservable here for the reason exception 31 gives, but noted so the two
//     files are not "the same" in someone's memory.
//
// Everything else — the three-byte header, `recode`, `recodeHistogram`, the `appendOnly` error
// strings (with a `float ` prefix), the gauge path — is the integer file with the types changed.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat
internal import PromModel

/// Go: `xorValue` — everything needed to XOR-encode and decode one float64 field.
public struct XORValue: Sendable, Equatable, FloatBucketCount {
    public var value: Double = 0
    public var leading: UInt8 = 0
    public var trailing: UInt8 = 0

    public init(value: Double = 0, leading: UInt8 = 0, trailing: UInt8 = 0) {
        self.value = value
        self.leading = leading
        self.trailing = trailing
    }

    /// Go reads `aBuckets[i].value` in `expandFloatSpansAndBuckets`.
    public var bucketCount: Double { value }
}

/// Go: `FloatHistogramChunk`.
public final class FloatHistogramChunk {
    var b: Bstream

    /// Go: `NewFloatHistogramChunk` — the same three header bytes as the integer chunk.
    public init() {
        self.b = Bstream(stream: [UInt8](repeating: 0, count: histogramHeaderSize), count: 0)
    }

    /// Go: `FloatHistogramChunk.Reset`.
    public func reset(_ stream: [UInt8]) {
        b.reset(stream)
    }

    /// Go: `Encoding`.
    public var encoding: Encoding { .floatHistogram }

    /// Go: `Bytes`.
    public var bytes: [UInt8] { b.bytes }

    /// Go: `NumSamples`.
    public var numSamples: Int {
        Int(GoBigEndian.uint16(bytes, 0))
    }

    /// Go: `GetCounterResetHeader`.
    public var counterResetHeader: CounterResetHeader {
        CounterResetHeader(rawValue: bytes[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
    }

    /// Go: `Compact` — a no-op, for the reason `XORChunk.compact()` is one.
    public func compact() {}

    /// Go: `FloatHistogramChunk.Appender`.
    ///
    /// The empty-chunk case seeds **three** `0xff` leading sentinels (sum, count, zero count) where
    /// the integer chunk seeds one, and the replay path rebuilds a `[XORValue]` per bucket from the
    /// iterator's three parallel slices.
    public func appender() throws -> FloatHistogramAppender {
        if b.stream.count == histogramHeaderSize {
            let a = FloatHistogramAppender(chunk: self, t: Int64.min)
            a.sum = XORValue(leading: 0xff)
            a.cnt = XORValue(leading: 0xff)
            a.zCnt = XORValue(leading: 0xff)
            return a
        }
        let it = iterator()
        while it.next() == .floatHistogram {}
        if let err = it.err() {
            throw err
        }

        var pBuckets: [XORValue] = []
        pBuckets.reserveCapacity(it.pBuckets.count)
        for i in 0..<it.pBuckets.count {
            pBuckets.append(
                XORValue(
                    value: it.pBuckets[i], leading: it.pBucketsLeading[i],
                    trailing: it.pBucketsTrailing[i]))
        }
        var nBuckets: [XORValue] = []
        nBuckets.reserveCapacity(it.nBuckets.count)
        for i in 0..<it.nBuckets.count {
            nBuckets.append(
                XORValue(
                    value: it.nBuckets[i], leading: it.nBucketsLeading[i],
                    trailing: it.nBucketsTrailing[i]))
        }

        let a = FloatHistogramAppender(chunk: self, t: it.t)
        a.schema = it.schema
        a.zThreshold = it.zThreshold
        a.pSpans = it.pSpans
        a.nSpans = it.nSpans
        a.customValues = it.customValues
        a.tDelta = it.tDelta
        a.cnt = it.cnt
        a.zCnt = it.zCnt
        a.pBuckets = pBuckets
        a.nBuckets = nBuckets
        a.sum = it.sum
        return a
    }

    /// Go: `FloatHistogramChunk.iterator`.
    public func iterator() -> FloatHistogramIterator {
        FloatHistogramIterator(bytes)
    }
}

// MARK: - The appender

/// Go: `floatHistogramAppendable` — the float counterpart of `HistogramAppendable`. Note the
/// asymmetry upstream's own comment points at: this one surfaces a bool where the integer version
/// surfaces the richer `CounterResetHeader`.
protocol FloatHistogramAppendable: AnyObject {
    func appendable(_ h: FloatHistogram) -> (
        positiveInserts: [Insert], negativeInserts: [Insert],
        backwardPositiveInserts: [Insert], backwardNegativeInserts: [Insert],
        okToAppend: Bool, counterReset: Bool
    )
}

/// Go: `FloatHistogramAppender`.
public final class FloatHistogramAppender {
    private let chunk: FloatHistogramChunk

    // Layout.
    var schema: Int32 = 0
    var zThreshold: Double = 0
    var pSpans: [Span] = []
    var nSpans: [Span] = []
    var customValues: [Double]?

    var t: Int64
    var tDelta: Int64 = 0
    var sum = XORValue()
    var cnt = XORValue()
    var zCnt = XORValue()
    var pBuckets: [XORValue] = []
    var nBuckets: [XORValue] = []

    init(chunk: FloatHistogramChunk, t: Int64) {
        self.chunk = chunk
        self.t = t
    }

    /// Go: `GetCounterResetHeader`.
    public var counterResetHeader: CounterResetHeader {
        CounterResetHeader(rawValue: chunk.b.bytes[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
    }

    /// Go: `setCounterResetHeader`.
    func setCounterResetHeader(_ cr: CounterResetHeader) {
        let old = chunk.b.bytes[histogramFlagPos]
        chunk.b.setByte(
            at: histogramFlagPos,
            (old & ~counterResetHeaderMask) | (cr.rawValue & counterResetHeaderMask))
    }

    /// Go: `NumSamples`.
    public var numSamples: Int {
        Int(GoBigEndian.uint16(chunk.b.bytes, 0))
    }

    /// Go: `setNumSamples`.
    func setNumSamples(_ num: Int) {
        chunk.b.putBigEndianUInt16(at: 0, UInt16(truncatingIfNeeded: num))
    }

    // MARK: appendable

    /// Go: `FloatHistogramAppender.appendable`.
    ///
    /// `HistogramMeta.swift` already carries this decision as the free function
    /// `floatHistogramAppendable(_:_:)`, ported in Phase 5 so the exit gate could derive counter-reset
    /// hints without a chunk. This is the same order of checks over the appender's own state, and it
    /// additionally produces the four insert lists that the free function throws away.
    func appendable(_ h: FloatHistogram) -> (
        positiveInserts: [Insert], negativeInserts: [Insert],
        backwardPositiveInserts: [Insert], backwardNegativeInserts: [Insert],
        okToAppend: Bool, counterReset: Bool
    ) {
        let none: [Insert] = []
        if numSamples > 0 && counterResetHeader == .gaugeType {
            return (none, none, none, none, false, false)
        }
        if h.counterResetHint == .counterReset {
            return (none, none, none, none, false, true)
        }
        if PromValue.isStaleNaN(h.sum) {
            return (none, none, none, none, true, false)
        }
        if PromValue.isStaleNaN(sum.value) {
            return (none, none, none, none, false, false)
        }
        if h.count < cnt.value {
            return (none, none, none, none, false, true)
        }
        if h.schema != schema || h.zeroThreshold != zThreshold {
            // Difference 2 from the integer chunk: there is no "unknown" to return here, so a layout
            // the encoder cannot express reads as "cut, but not a reset".
            return (none, none, none, none, false, false)
        }
        if isCustomBucketsSchema(h.schema)
            && !customBucketBoundsMatch(h.customValues, customValues)
        {
            return (none, none, none, none, false, true)
        }
        if h.zeroCount < zCnt.value {
            return (none, none, none, none, false, true)
        }

        let (pIns, pBack, pOK) = expandFloatSpansAndBuckets(
            pSpans, h.positiveSpans, pBuckets, h.positiveBuckets)
        if !pOK {
            return (pIns, none, pBack, none, false, true)
        }
        let (nIns, nBack, nOK) = expandFloatSpansAndBuckets(
            nSpans, h.negativeSpans, nBuckets, h.negativeBuckets)
        if !nOK {
            return (pIns, nIns, pBack, nBack, false, true)
        }
        return (pIns, nIns, pBack, nBack, true, false)
    }

    /// Go: `FloatHistogramAppender.appendableGauge`.
    func appendableGauge(_ h: FloatHistogram) -> (
        positiveInserts: [Insert], negativeInserts: [Insert],
        backwardPositiveInserts: [Insert], backwardNegativeInserts: [Insert],
        positiveSpans: [Span], negativeSpans: [Span], okToAppend: Bool
    ) {
        let none: [Insert] = []
        let noSpans: [Span] = []
        if numSamples > 0 && counterResetHeader != .gaugeType {
            return (none, none, none, none, noSpans, noSpans, false)
        }
        if PromValue.isStaleNaN(h.sum) {
            return (none, none, none, none, noSpans, noSpans, true)
        }
        if PromValue.isStaleNaN(sum.value) {
            return (none, none, none, none, noSpans, noSpans, false)
        }
        if h.schema != schema || h.zeroThreshold != zThreshold {
            return (none, none, none, none, noSpans, noSpans, false)
        }
        if isCustomBucketsSchema(h.schema)
            && !customBucketBoundsMatch(h.customValues, customValues)
        {
            return (none, none, none, none, noSpans, noSpans, false)
        }
        let (pIns, pBack, pMerged) = expandSpansBothWays(pSpans, h.positiveSpans)
        let (nIns, nBack, nMerged) = expandSpansBothWays(nSpans, h.negativeSpans)
        return (pIns, nIns, pBack, nBack, pMerged, nMerged, true)
    }

    // MARK: the encoder

    /// Go: `appendFloatHistogram(num, t, h) int`.
    @discardableResult
    func appendFloatHistogram(_ num: Int, _ t: Int64, _ hIn: FloatHistogram) -> Int {
        var tDelta: Int64 = 0

        var h = hIn
        if PromValue.isStaleNaN(h.sum) {
            h = FloatHistogram(sum: h.sum)
        }

        if num == 0 {
            writeHistogramChunkLayout(
                &chunk.b, h.schema, h.zeroThreshold, h.positiveSpans, h.negativeSpans, h.customValues)
            schema = h.schema
            zThreshold = h.zeroThreshold

            pSpans = h.positiveSpans.isEmpty ? [] : h.positiveSpans
            nSpans = h.negativeSpans.isEmpty ? [] : h.negativeSpans
            customValues = (h.customValues?.isEmpty ?? true) ? nil : h.customValues

            let numPBuckets = countSpans(h.positiveSpans)
            let numNBuckets = countSpans(h.negativeSpans)
            if numPBuckets > 0 {
                pBuckets = (0..<numPBuckets).map {
                    XORValue(value: h.positiveBuckets[$0], leading: 0xff)
                }
            } else {
                pBuckets = []
            }
            if numNBuckets > 0 {
                nBuckets = (0..<numNBuckets).map {
                    XORValue(value: h.negativeBuckets[$0], leading: 0xff)
                }
            } else {
                nBuckets = []
            }

            // Now the data: the timestamp is varbit and everything else is a raw 64-bit float.
            putVarbitInt(&chunk.b, t)
            chunk.b.writeBits(h.count.bitPattern, 64)
            chunk.b.writeBits(h.zeroCount.bitPattern, 64)
            chunk.b.writeBits(h.sum.bitPattern, 64)
            cnt.value = h.count
            zCnt.value = h.zeroCount
            sum.value = h.sum
            for b in h.positiveBuckets {
                chunk.b.writeBits(b.bitPattern, 64)
            }
            for b in h.negativeBuckets {
                chunk.b.writeBits(b.bitPattern, 64)
            }
        } else {
            tDelta = t &- self.t
            let tDod = tDelta &- self.tDelta
            putVarbitInt(&chunk.b, tDod)

            writeXorValue(&cnt, h.count)
            writeXorValue(&zCnt, h.zeroCount)
            writeXorValue(&sum, h.sum)

            for (i, b) in h.positiveBuckets.enumerated() {
                writeXorValue(&pBuckets[i], b)
            }
            for (i, b) in h.negativeBuckets.enumerated() {
                writeXorValue(&nBuckets[i], b)
            }
        }

        self.t = t
        self.tDelta = tDelta

        return num + 1
    }

    /// Go: `writeXorValue`. Note it updates `old.value` AFTER the write, so the XOR is against the
    /// previous value as it must be.
    private func writeXorValue(_ old: inout XORValue, _ v: Double) {
        xorWrite(&chunk.b, v, old.value, &old.leading, &old.trailing)
        old.value = v
    }

    /// Go: `FloatHistogramAppender.recode`.
    func recode(
        _ positiveInserts: [Insert], _ negativeInserts: [Insert],
        _ positiveSpans: [Span], _ negativeSpans: [Span]
    ) -> (FloatHistogramChunk, FloatHistogramAppender) {
        let byts = chunk.b.bytes
        let it = FloatHistogramIterator(byts)
        let hc = FloatHistogramChunk()
        guard let happ = try? hc.appender() else {
            preconditionFailure("this should never happen for an empty float histogram chunk")
        }
        let numPositiveBuckets = countSpans(positiveSpans)
        let numNegativeBuckets = countSpans(negativeSpans)

        var num = happ.numSamples
        while it.next() == .floatHistogram {
            let (tOld, hOldOpt) = it.atFloatHistogram(nil)
            guard var hOld = hOldOpt else { break }

            var positiveBuckets: [Double] = []
            var negativeBuckets: [Double] = []
            if numPositiveBuckets > 0 {
                positiveBuckets = [Double](repeating: 0, count: numPositiveBuckets)
            }
            if numNegativeBuckets > 0 {
                negativeBuckets = [Double](repeating: 0, count: numNegativeBuckets)
            }

            hOld.positiveSpans = positiveSpans
            hOld.negativeSpans = negativeSpans
            if !positiveInserts.isEmpty {
                // `deltas: false` — difference 1. The integer twin passes `true`.
                hOld.positiveBuckets = insert(
                    hOld.positiveBuckets, positiveBuckets, positiveInserts, false)
            }
            if !negativeInserts.isEmpty {
                hOld.negativeBuckets = insert(
                    hOld.negativeBuckets, negativeBuckets, negativeInserts, false)
            }
            num = happ.appendFloatHistogram(num, tOld, hOld)
        }
        happ.setNumSamples(num)
        happ.setCounterResetHeader(
            CounterResetHeader(rawValue: byts[histogramFlagPos] & counterResetHeaderMask)
                ?? .unknownCounterReset)
        return (hc, happ)
    }

    /// Go: `FloatHistogramAppender.recodeHistogram`.
    func recodeHistogram(
        _ fh: inout FloatHistogram, _ pBackwardInter: [Insert], _ nBackwardInter: [Insert]
    ) {
        if !pBackwardInter.isEmpty {
            let numPositiveBuckets = countSpans(fh.positiveSpans)
            fh.positiveBuckets = insert(
                fh.positiveBuckets, [Double](repeating: 0, count: numPositiveBuckets),
                pBackwardInter, false)
        }
        if !nBackwardInter.isEmpty {
            let numNegativeBuckets = countSpans(fh.negativeSpans)
            fh.negativeBuckets = insert(
                fh.negativeBuckets, [Double](repeating: 0, count: numNegativeBuckets),
                nBackwardInter, false)
        }
    }

    // MARK: AppendFloatHistogram

    /// Go: `FloatHistogramAppender.AppendFloatHistogram`.
    @discardableResult
    func appendFloatHistogram(
        prev: (any ChunkAppender)?, t: Int64, h: inout FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        let numSamplesNow = numSamples

        if numSamplesNow == Int(UInt16.max) {
            preconditionFailure("chunk capacity exceeded")
        }

        if numSamplesNow == 0 {
            setNumSamples(appendFloatHistogram(numSamplesNow, t, h))
            if h.counterResetHint == .gaugeType {
                setCounterResetHeader(.gaugeType)
                return (nil, false, self)
            }
            if h.counterResetHint == .counterReset {
                setCounterResetHeader(.counterReset)
            } else if let prev {
                if let p = prev as? any FloatHistogramAppendable {
                    let r = p.appendable(h)
                    // Difference 2 again: a bool, so the "no reset" answer is written out as
                    // `NotCounterReset` rather than left at unknown.
                    setCounterResetHeader(r.counterReset ? .counterReset : .notCounterReset)
                }
            }
            return (nil, false, self)
        }

        // Counter-like histogram.
        if h.counterResetHint != .gaugeType {
            let (pForward, nForward, pBackward, nBackward, okToAppend, counterReset) = appendable(h)
            if !okToAppend || counterReset {
                if appendOnly {
                    if counterReset {
                        throw HistogramAppendError.floatCounterReset
                    }
                    throw HistogramAppendError.floatSchemaChange
                }
                let newChunk = FloatHistogramChunk()
                guard let happ = try? newChunk.appender() else {
                    preconditionFailure("this should never happen for an empty float histogram chunk")
                }
                // Difference 3: guarded, so a non-reset cut leaves the header at zero.
                if counterReset {
                    happ.setCounterResetHeader(.counterReset)
                }
                happ.setNumSamples(happ.appendFloatHistogram(0, t, h))
                return (newChunk, false, happ)
            }
            if !pBackward.isEmpty || !nBackward.isEmpty {
                if pForward.isEmpty && nForward.isEmpty {
                    h.positiveSpans = pSpans
                    h.negativeSpans = nSpans
                } else {
                    h.positiveSpans = adjustForInserts(h.positiveSpans, pBackward)
                    h.negativeSpans = adjustForInserts(h.negativeSpans, nBackward)
                }
                recodeHistogram(&h, pBackward, nBackward)
            }
            if !pForward.isEmpty || !nForward.isEmpty {
                if appendOnly {
                    throw HistogramAppendError.layoutChange(
                        gauge: false, float: true, direction: .forward,
                        positive: pForward.count, negative: nForward.count)
                }
                let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)
                happ.setNumSamples(happ.appendFloatHistogram(happ.numSamples, t, h))
                return (chk, true, happ)
            }
            setNumSamples(appendFloatHistogram(numSamplesNow, t, h))
            return (nil, false, self)
        }

        // Gauge histogram.
        let (pForward, nForward, pBackward, nBackward, pMerged, nMerged, okToAppend) =
            appendableGauge(h)
        if !okToAppend {
            if appendOnly {
                throw HistogramAppendError.floatGaugeSchemaChange
            }
            let newChunk = FloatHistogramChunk()
            guard let happ = try? newChunk.appender() else {
                preconditionFailure("this should never happen for an empty float histogram chunk")
            }
            happ.setCounterResetHeader(.gaugeType)
            happ.setNumSamples(happ.appendFloatHistogram(0, t, h))
            return (newChunk, false, happ)
        }

        if pBackward.count + nBackward.count > 0 {
            if appendOnly {
                throw HistogramAppendError.layoutChange(
                    gauge: true, float: true, direction: .backward,
                    positive: pBackward.count, negative: nBackward.count)
            }
            h.positiveSpans = pMerged
            h.negativeSpans = nMerged
            recodeHistogram(&h, pBackward, nBackward)
        }

        if !pForward.isEmpty || !nForward.isEmpty {
            if appendOnly {
                throw HistogramAppendError.layoutChange(
                    gauge: true, float: true, direction: .forward,
                    positive: pForward.count, negative: nForward.count)
            }
            let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)
            happ.setNumSamples(happ.appendFloatHistogram(happ.numSamples, t, h))
            return (chk, true, happ)
        }

        setNumSamples(appendFloatHistogram(numSamplesNow, t, h))
        return (nil, false, self)
    }
}

extension FloatHistogramAppender: FloatHistogramAppendable {}

// MARK: - The iterator

/// Go: `floatHistogramIterator`.
///
/// A `final class`, for the reason `HistogramIterator` is one. The bucket leading/trailing windows are
/// three parallel slices rather than a `[XORValue]` — upstream's comment says why: `AtFloatHistogram`
/// hands `pBuckets` straight out, and a slice of structs would have to be converted on every call.
public final class FloatHistogramIterator: ChunkIterator {
    var br: BstreamReader
    var numTotal: UInt16
    public private(set) var numRead: UInt16 = 0

    var counterResetHeaderValue: CounterResetHeader

    // Layout.
    var schema: Int32 = 0
    var zThreshold: Double = 0
    var pSpans: [Span] = []
    var nSpans: [Span] = []
    var customValues: [Double]?

    var t: Int64
    var tDelta: Int64 = 0

    var sum = XORValue()
    var cnt = XORValue()
    var zCnt = XORValue()

    var pBuckets: [Double] = []
    var nBuckets: [Double] = []
    var pBucketsLeading: [UInt8] = []
    var nBucketsLeading: [UInt8] = []
    var pBucketsTrailing: [UInt8] = []
    var nBucketsTrailing: [UInt8] = []

    var error: (any Error)?

    /// Go: `newFloatHistogramIterator`. `t` starts at `math.MinInt64`; `reset` sets it to 0. Same
    /// asymmetry as the integer iterator's, and the same reason to keep it.
    public init(_ b: [UInt8]) {
        br = BstreamReader(Array(b[histogramHeaderSize...]))
        numTotal = GoBigEndian.uint16(b, 0)
        t = Int64.min
        counterResetHeaderValue =
            CounterResetHeader(rawValue: b[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
    }

    /// Go: `floatHistogramIterator.Reset`.
    public func reset(_ b: [UInt8]) {
        br = BstreamReader(Array(b[histogramHeaderSize...]))
        numTotal = GoBigEndian.uint16(b, 0)
        numRead = 0
        counterResetHeaderValue =
            CounterResetHeader(rawValue: b[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
        t = 0
        tDelta = 0
        cnt = XORValue()
        zCnt = XORValue()
        sum = XORValue()
        pBuckets = []
        nBuckets = []
        pBucketsLeading = []
        pBucketsTrailing = []
        nBucketsLeading = []
        nBucketsTrailing = []
        error = nil
        // Difference 7: upstream clears `customValues` only on the recycling branch. With that branch
        // gone (exception 31) it is cleared here, which is what the recycling branch would have done
        // for any iterator that had handed a histogram out — and for one that had not, the next
        // `Next()` overwrites it before anything can read it.
        customValues = nil
    }

    public func seek(_ target: Int64) -> ValueType {
        if error != nil {
            return .none
        }
        while target > t || numRead == 0 {
            if next() == .none {
                return .none
            }
        }
        return .floatHistogram
    }

    /// Go: `panic("cannot call floatHistogramIterator.At")`.
    public func at() -> (Int64, Double) {
        preconditionFailure("cannot call floatHistogramIterator.At")
    }

    /// Go: `panic("cannot call floatHistogramIterator.AtHistogram")`. Difference 6: there is no
    /// float-to-integer conversion, where the integer iterator converts to float happily.
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        preconditionFailure("cannot call floatHistogramIterator.AtHistogram")
    }

    public func atT() -> Int64 { t }

    /// Go: `floatHistogramIterator.AtST` returns 0.
    public func atST() -> Int64 { 0 }

    public func err() -> (any Error)? { error }

    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        if PromValue.isStaleNaN(sum.value) {
            return (t, FloatHistogram(sum: sum.value))
        }
        var fh = reuse ?? FloatHistogram()
        fh.counterResetHint = counterResetHint(counterResetHeaderValue, numRead)
        fh.schema = schema
        fh.zeroThreshold = zThreshold
        fh.zeroCount = zCnt.value
        fh.count = cnt.value
        fh.sum = sum.value
        fh.positiveSpans = pSpans
        fh.negativeSpans = nSpans
        fh.positiveBuckets = pBuckets
        fh.negativeBuckets = nBuckets
        fh.customValues = customValues
        reduceIfReserved(&fh)
        return (t, fh)
    }

    /// Go: `floatHistogramIterator.readXor`, which takes three pointers into one `xorValue`.
    ///
    /// Spelled as copy-mutate-write-back rather than three `&self.cnt.<field>` arguments: Swift's
    /// dynamic exclusivity enforcement for a class's stored property would see three overlapping
    /// accesses to `self.cnt`, which is a runtime trap rather than a compile error.
    private func xorReadInto(_ x: inout XORValue) throws {
        var v = x
        try xorRead(&br, &v.value, &v.leading, &v.trailing)
        x = v
    }

    public func next() -> ValueType {
        if error != nil || numRead == numTotal {
            return .none
        }
        if numRead == 0 {
            let layout: (
                schema: Int32, zeroThreshold: Double, positiveSpans: [Span], negativeSpans: [Span],
                customValues: [Double]?
            )
            do {
                layout = try readHistogramChunkLayout(&br)
            } catch {
                self.error = error
                return .none
            }

            if !isKnownSchema(layout.schema) {
                error = HistogramError.unknownSchema(layout.schema)
                return .none
            }

            schema = layout.schema
            zThreshold = layout.zeroThreshold
            pSpans = layout.positiveSpans
            nSpans = layout.negativeSpans
            customValues = layout.customValues
            let numPBuckets = countSpans(pSpans)
            let numNBuckets = countSpans(nSpans)
            if numPBuckets > 0 {
                pBuckets = [Double](repeating: 0, count: numPBuckets)
                pBucketsLeading = [UInt8](repeating: 0, count: numPBuckets)
                pBucketsTrailing = [UInt8](repeating: 0, count: numPBuckets)
            }
            if numNBuckets > 0 {
                nBuckets = [Double](repeating: 0, count: numNBuckets)
                nBucketsLeading = [UInt8](repeating: 0, count: numNBuckets)
                nBucketsTrailing = [UInt8](repeating: 0, count: numNBuckets)
            }

            do {
                t = try readVarbitInt(&br)
                cnt.value = Double(bitPattern: try br.readBits(64))
                zCnt.value = Double(bitPattern: try br.readBits(64))
                sum.value = Double(bitPattern: try br.readBits(64))
                for i in 0..<pBuckets.count {
                    pBuckets[i] = Double(bitPattern: try br.readBits(64))
                }
                for i in 0..<nBuckets.count {
                    nBuckets[i] = Double(bitPattern: try br.readBits(64))
                }
            } catch {
                self.error = error
                return .none
            }

            numRead += 1
            return .floatHistogram
        }

        do {
            let tDod = try readVarbitInt(&br)
            tDelta = tDelta &+ tDod
            t = t &+ tDelta

            try xorReadInto(&cnt)
            try xorReadInto(&zCnt)
            try xorReadInto(&sum)

            if PromValue.isStaleNaN(sum.value) {
                numRead += 1
                return .floatHistogram
            }

            for i in 0..<pBuckets.count {
                try xorRead(&br, &pBuckets[i], &pBucketsLeading[i], &pBucketsTrailing[i])
            }
            for i in 0..<nBuckets.count {
                try xorRead(&br, &nBuckets[i], &nBucketsLeading[i], &nBucketsTrailing[i])
            }
        } catch {
            self.error = error
            return .none
        }

        numRead += 1
        return .floatHistogram
    }
}
