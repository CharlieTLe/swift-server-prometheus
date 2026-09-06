//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/histogram.go @ v3.13.2 — the INTEGER native-histogram chunk encoding.
//
// The layout, copied from upstream's own table so it is not re-derived (raw = the number itself,
// delta = against the previous sample, dod = delta of that delta, xor = Gorilla's float XOR):
//
//     field →    ts    count zeroCount sum []posbuckets []negbuckets
//     sample 1   raw   raw   raw       raw []raw        []raw
//     sample 2   delta delta delta     xor []delta      []delta
//     sample >2  dod   dod   dod       xor []dod        []dod
//
// So everything but the sum is varbit integers, and only the sum rides the XOR machinery `xor.go`
// already provides. `float_histogram.go` is the same file with every count XOR-encoded instead — the
// two are worth reading side by side, and the asymmetries between them are listed at the top of
// `FloatHistogramChunk.swift`.
//
// ## Three bytes of header, and the third one is a decision the READER re-derives
//
// `[0:2]` is the big-endian sample count, `[2]`'s top two bits are the `CounterResetHeader`. The
// header is written by `AppendHistogram` — on the first sample from the *previous* chunk's appender,
// and on a cut from `appendable`'s verdict — and read back per sample by `counterResetHint(header,
// numRead)`, which is `HistogramMeta.swift`'s and already pinned. Note the third header byte is NOT
// part of what `newBReader` sees: every iterator opens the stream at `histogramHeaderSize`.
//
// ## `appendable` returns SIX things and the sixth is not a boolean
//
// This is the one substantive difference from the float chunk. `HistogramAppender.appendable` yields a
// `CounterResetHeader`, not a `counterReset bool`, so it can say *unknown* — which it does for a
// schema or zero-threshold change, deliberately, because upstream will not pay for a full counter
// reset detection while prometheus/prometheus#15346 is open. The float appender collapses the same
// decision to a bool and therefore writes `NotCounterReset` where the integer one writes
// `UnknownCounterReset`. Two encodings of the same histogram do not produce the same header.
//
// The four forward/backward insert lists are the other half of the answer:
//
//   * **forward** inserts widen the CHUNK to hold buckets the new sample has and the chunk does not.
//     Acting on them means `recode` — decode every sample and re-encode it under the new layout,
//     returning a whole new chunk with `isRecoded = true`.
//   * **backward** inserts widen the SAMPLE to hold buckets the chunk has (with a zero count) and the
//     sample does not. Acting on them means `recodeHistogram`, which rewrites the caller's histogram
//     in place.
//
// Both can be non-empty at once, and then both happen, backward first.
//
// ## `h` is MUTATED, and that is not an accident of the port
//
// `AppendHistogram` takes `h *histogram.Histogram` and writes through it: `h.PositiveSpans` is
// replaced on the backward-insert path and `recodeHistogram` rewrites `h.PositiveBuckets`. The
// mutation escapes — `memSeries.appendHistogram` stores the same pointer as `s.lastHistogramValue`
// right afterwards. So the port takes `h` as `inout` rather than by value; a Swift value copy would be
// a silent divergence that only shows up two slices later, in the Head.
//
// ## The stale sample is a different histogram
//
// `appendHistogram` replaces a stale-NaN sample with `&histogram.Histogram{Sum: h.Sum}` — no spans, no
// buckets, count and zeroCount zero — and the count dods are then forced to 0 while the appender's
// `cntDelta` keeps the value it just computed against a zero count. The decoder skips the buckets
// entirely on a stale sum, so the two sides' *state* legitimately disagrees after a stale sample even
// though every sample reads back correctly. That disagreement is observable: `Appender()` recovers the
// DECODER's state, so appending to a chunk that has been round-tripped through `Reset` is not always
// byte-identical to appending to the original. See the corpus's `stale/*` cases.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat
internal import PromModel

/// Go: `HistogramChunk`.
///
/// A `final class` for the reason `XORChunk` is one: upstream passes `*HistogramChunk` and the
/// appender holds a `*bstream` pointing into it, so an append must be visible through the chunk.
public final class HistogramChunk {
    var b: Bstream

    /// Go: `NewHistogramChunk` — three header bytes.
    public init() {
        self.b = Bstream(stream: [UInt8](repeating: 0, count: histogramHeaderSize), count: 0)
    }

    /// Go: `HistogramChunk.Reset`.
    public func reset(_ stream: [UInt8]) {
        b.reset(stream)
    }

    /// Go: `Encoding`.
    public var encoding: Encoding { .histogram }

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

    /// Go: `Compact` — a no-op here for the reason `XORChunk.compact()` is one: Swift's `Array` has no
    /// observable capacity, and `Bytes()` returns the used prefix in both languages. Kept for the call
    /// site, per PORTING.md §4.
    public func compact() {}

    /// Go: `HistogramChunk.Appender`.
    ///
    /// On a non-empty chunk this REPLAYS the whole thing through an iterator and lifts the decoder's
    /// final state. That is not merely a shortcut: the decoder's state is what the *next* sample is
    /// encoded against, so a replayed appender is the definition of correct here — and it differs from
    /// the original appender in two places worth knowing about. `leading` comes back as 0 rather than
    /// the `0xff` sentinel a fresh appender starts with (so the second sample after a replay takes the
    /// reuse-window path instead of the new-window path), and after a stale sample the counts and their
    /// deltas differ, because the encoder and decoder disagree there by construction.
    public func appender() throws -> HistogramAppender {
        if b.stream.count == histogramHeaderSize {
            // Avoid allocating an iterator when the chunk is empty.
            return HistogramAppender(chunk: self, t: Int64.min, leading: 0xff)
        }
        let it = iterator()
        while it.next() == .histogram {}
        if let err = it.err() {
            throw err
        }
        let a = HistogramAppender(chunk: self, t: it.t, leading: it.leading)
        a.schema = it.schema
        a.zThreshold = it.zThreshold
        a.pSpans = it.pSpans
        a.nSpans = it.nSpans
        a.customValues = it.customValues
        a.cnt = it.cnt
        a.zCnt = it.zCnt
        a.tDelta = it.tDelta
        a.cntDelta = it.cntDelta
        a.zCntDelta = it.zCntDelta
        a.pBuckets = it.pBuckets
        a.nBuckets = it.nBuckets
        a.pBucketsDelta = it.pBucketsDelta
        a.nBucketsDelta = it.nBucketsDelta
        a.sum = it.sum
        a.trailing = it.trailing
        return a
    }

    /// Go: `HistogramChunk.iterator`.
    public func iterator() -> HistogramIterator {
        HistogramIterator(bytes)
    }
}

// MARK: - The appender

/// The subset of `HistogramAppender` that `AppendHistogram` needs from the *previous* chunk's
/// appender — Go's `histogramAppendable`, an unexported interface whose only purpose is to let the
/// exported `Appender` interface stay one type.
///
/// Upstream's comment names `*HistogramSTAppender` as a second conformer; no such type exists at
/// v3.13.2, so the protocol has exactly one. It is kept anyway, because the alternative — a direct
/// `as? HistogramAppender` — would silently stop matching the moment upstream adds the ST variant.
protocol HistogramAppendable: AnyObject {
    func appendable(_ h: Histogram) -> (
        positiveInserts: [Insert], negativeInserts: [Insert],
        backwardPositiveInserts: [Insert], backwardNegativeInserts: [Insert],
        okToAppend: Bool, counterResetHint: CounterResetHeader
    )
}

/// Go: `HistogramAppender`.
public final class HistogramAppender {
    /// Go holds `b *bstream`; the port holds the chunk and writes through it, which is the same
    /// aliasing with a name on it. `var` rather than `let` because `recode` hands the appender a
    /// different chunk.
    private let chunk: HistogramChunk

    // Layout.
    var schema: Int32 = 0
    var zThreshold: Double = 0
    var pSpans: [Span] = []
    var nSpans: [Span] = []
    /// Read only after the first sample is appended.
    var customValues: [Double]?

    /// Every delta is SIGNED, `tDelta` included. Upstream's comment: gauge histograms mean negative
    /// deltas have to work even though a new chunk is started on a counter reset.
    var t: Int64
    var cnt: UInt64 = 0
    var zCnt: UInt64 = 0
    var tDelta: Int64 = 0
    var cntDelta: Int64 = 0
    var zCntDelta: Int64 = 0
    var pBuckets: [Int64] = []
    var nBuckets: [Int64] = []
    var pBucketsDelta: [Int64] = []
    var nBucketsDelta: [Int64] = []

    /// The sum is the only field that is Gorilla XOR encoded.
    var sum: Double = 0
    var leading: UInt8 = 0
    var trailing: UInt8 = 0

    init(chunk: HistogramChunk, t: Int64, leading: UInt8 = 0) {
        self.chunk = chunk
        self.t = t
        self.leading = leading
    }

    /// Go: `GetCounterResetHeader`.
    public var counterResetHeader: CounterResetHeader {
        CounterResetHeader(rawValue: chunk.b.bytes[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
    }

    /// Go: `setCounterResetHeader` — a read-modify-write of the top two bits only.
    func setCounterResetHeader(_ cr: CounterResetHeader) {
        let old = chunk.b.bytes[histogramFlagPos]
        chunk.b.setByte(
            at: histogramFlagPos, (old & ~counterResetHeaderMask) | (cr.rawValue & counterResetHeaderMask))
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

    /// Go: `HistogramAppender.appendable`.
    ///
    /// The order of the checks is upstream's and load-bearing — see `HistogramMeta.swift`'s header,
    /// which says the same thing about the float twin. What differs here is the SIXTH return: a
    /// `CounterResetHeader` rather than a bool, so the schema/zero-threshold arm can answer *unknown*
    /// instead of having to pick a side. `counterResetHint` starts as `NotCounterReset` and every
    /// early return that is not a reset leaves it there — including the gauge short-circuit, which
    /// returns `okToAppend == false` with a `NotCounterReset` hint.
    func appendable(_ h: Histogram) -> (
        positiveInserts: [Insert], negativeInserts: [Insert],
        backwardPositiveInserts: [Insert], backwardNegativeInserts: [Insert],
        okToAppend: Bool, counterResetHint: CounterResetHeader
    ) {
        let none: [Insert] = []
        if numSamples > 0 && counterResetHeader == .gaugeType {
            return (none, none, none, none, false, .notCounterReset)
        }
        if h.counterResetHint == .counterReset {
            // "Always honor the explicit counter reset hint."
            return (none, none, none, none, false, .counterReset)
        }
        if PromValue.isStaleNaN(h.sum) {
            // A stale sample whose buckets and spans do not matter.
            return (none, none, none, none, true, .notCounterReset)
        }
        if PromValue.isStaleNaN(sum) {
            // After a stale sample the chunk accepts only stale samples.
            return (none, none, none, none, false, .unknownCounterReset)
        }
        if h.count < cnt {
            return (none, none, none, none, false, .counterReset)
        }
        if h.schema != schema || h.zeroThreshold != zThreshold {
            // histogram.go:293-299 — deliberately NOT a reset verdict. Upstream will not pay for a
            // full counter reset detection while prometheus/prometheus#15346 is open, so it says
            // "unknown" rather than guessing. The float chunk cannot express this and says "no reset".
            return (none, none, none, none, false, .unknownCounterReset)
        }
        if isCustomBucketsSchema(h.schema)
            && !customBucketBoundsMatch(h.customValues, customValues)
        {
            return (none, none, none, none, false, .counterReset)
        }
        if h.zeroCount < zCnt {
            // The zero threshold did not change, so this is a reset.
            return (none, none, none, none, false, .counterReset)
        }

        let (pIns, pBack, pOK) = expandIntSpansAndBuckets(
            pSpans, h.positiveSpans, pBuckets, h.positiveBuckets)
        if !pOK {
            return (pIns, none, pBack, none, false, .counterReset)
        }
        let (nIns, nBack, nOK) = expandIntSpansAndBuckets(
            nSpans, h.negativeSpans, nBuckets, h.negativeBuckets)
        if !nOK {
            return (pIns, nIns, pBack, nBack, false, .counterReset)
        }
        return (pIns, nIns, pBack, nBack, true, .notCounterReset)
    }

    /// Go: `HistogramAppender.appendableGauge`.
    ///
    /// No counter-reset concept at all — `expandSpansBothWays` cannot fail, so the bucket layout never
    /// forces a cut and the merged spans come back instead of a verdict.
    func appendableGauge(_ h: Histogram) -> (
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
        if PromValue.isStaleNaN(sum) {
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

    /// Go: `appendHistogram(num, t, h) int` — writes one sample and returns `num + 1`. It does NOT
    /// touch the header; the caller persists the count with `setNumSamples`.
    @discardableResult
    func appendHistogram(_ num: Int, _ t: Int64, _ hIn: Histogram) -> Int {
        var tDelta: Int64 = 0
        var cntDelta: Int64 = 0
        var zCntDelta: Int64 = 0

        var h = hIn
        if PromValue.isStaleNaN(h.sum) {
            // Everything but the sum is emptied, so no buckets are written and — for a first sample —
            // the layout written into the chunk is empty too.
            h = Histogram(sum: h.sum)
        }

        if num == 0 {
            // The first append dictates the layout and is responsible for encoding it.
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
                pBuckets = [Int64](repeating: 0, count: numPBuckets)
                pBucketsDelta = [Int64](repeating: 0, count: numPBuckets)
            } else {
                pBuckets = []
                pBucketsDelta = []
            }
            if numNBuckets > 0 {
                nBuckets = [Int64](repeating: 0, count: numNBuckets)
                nBucketsDelta = [Int64](repeating: 0, count: numNBuckets)
            } else {
                nBuckets = []
                nBucketsDelta = []
            }

            // Now the data.
            putVarbitInt(&chunk.b, t)
            putVarbitUint(&chunk.b, h.count)
            putVarbitUint(&chunk.b, h.zeroCount)
            chunk.b.writeBits(h.sum.bitPattern, 64)
            for b in h.positiveBuckets {
                putVarbitInt(&chunk.b, b)
            }
            for b in h.negativeBuckets {
                putVarbitInt(&chunk.b, b)
            }
        } else {
            // The second sample's single deltas fall out of the double-delta code, so there is no
            // separate branch for it.
            tDelta = t &- self.t
            cntDelta = Int64(bitPattern: h.count) &- Int64(bitPattern: cnt)
            zCntDelta = Int64(bitPattern: h.zeroCount) &- Int64(bitPattern: zCnt)

            let tDod = tDelta &- self.tDelta
            var cntDod = cntDelta &- self.cntDelta
            var zCntDod = zCntDelta &- self.zCntDelta

            if PromValue.isStaleNaN(h.sum) {
                // The dods are zeroed but `cntDelta`/`zCntDelta` below are NOT — see the file header.
                cntDod = 0
                zCntDod = 0
            }

            putVarbitInt(&chunk.b, tDod)
            putVarbitInt(&chunk.b, cntDod)
            putVarbitInt(&chunk.b, zCntDod)

            writeSumDelta(h.sum)

            for (i, b) in h.positiveBuckets.enumerated() {
                let delta = b &- pBuckets[i]
                let dod = delta &- pBucketsDelta[i]
                putVarbitInt(&chunk.b, dod)
                pBucketsDelta[i] = delta
            }
            for (i, b) in h.negativeBuckets.enumerated() {
                let delta = b &- nBuckets[i]
                let dod = delta &- nBucketsDelta[i]
                putVarbitInt(&chunk.b, dod)
                nBucketsDelta[i] = delta
            }
        }

        self.t = t
        cnt = h.count
        zCnt = h.zeroCount
        self.tDelta = tDelta
        self.cntDelta = cntDelta
        self.zCntDelta = zCntDelta

        // Go: `copy(a.pBuckets, h.PositiveBuckets)` — a partial copy of min(len, len). A stale sample
        // has no buckets, so this leaves the appender's bucket values alone.
        for i in 0..<min(pBuckets.count, h.positiveBuckets.count) {
            pBuckets[i] = h.positiveBuckets[i]
        }
        for i in 0..<min(nBuckets.count, h.negativeBuckets.count) {
            nBuckets[i] = h.negativeBuckets[i]
        }
        // The bucket deltas were already updated above.
        sum = h.sum

        return num + 1
    }

    private func writeSumDelta(_ v: Double) {
        xorWrite(&chunk.b, v, sum, &leading, &trailing)
    }

    /// Go: `HistogramAppender.recode` — decode everything, re-encode it under the wider span layout.
    ///
    /// Upstream's TODO says this could be done in place; it is not, and the port does not try either,
    /// because "decode and re-encode" is exactly what makes the output byte-defined.
    ///
    /// Note the counter-reset header is carried over from the OLD chunk's bytes, read directly rather
    /// than through the appender — `happ`'s chunk is the new one and its header is still zero.
    func recode(
        _ positiveInserts: [Insert], _ negativeInserts: [Insert],
        _ positiveSpans: [Span], _ negativeSpans: [Span]
    ) -> (HistogramChunk, HistogramAppender) {
        let byts = chunk.b.bytes
        let it = HistogramIterator(byts)
        let hc = HistogramChunk()
        // Go panics if this errors, with "this should never happen for an empty histogram chunk".
        guard let happ = try? hc.appender() else {
            preconditionFailure("this should never happen for an empty histogram chunk")
        }
        let numPositiveBuckets = countSpans(positiveSpans)
        let numNegativeBuckets = countSpans(negativeSpans)

        var num = happ.numSamples
        while it.next() == .histogram {
            let (tOld, hOldOpt) = it.atHistogram(nil)
            guard var hOld = hOldOpt else { break }

            var positiveBuckets: [Int64] = []
            var negativeBuckets: [Int64] = []
            if numPositiveBuckets > 0 {
                positiveBuckets = [Int64](repeating: 0, count: numPositiveBuckets)
            }
            if numNegativeBuckets > 0 {
                negativeBuckets = [Int64](repeating: 0, count: numNegativeBuckets)
            }

            hOld.positiveSpans = positiveSpans
            hOld.negativeSpans = negativeSpans
            if !positiveInserts.isEmpty {
                hOld.positiveBuckets = insert(
                    hOld.positiveBuckets, positiveBuckets, positiveInserts, true)
            }
            if !negativeInserts.isEmpty {
                hOld.negativeBuckets = insert(
                    hOld.negativeBuckets, negativeBuckets, negativeInserts, true)
            }
            num = happ.appendHistogram(num, tOld, hOld)
        }
        happ.setNumSamples(num)
        happ.setCounterResetHeader(
            CounterResetHeader(rawValue: byts[histogramFlagPos] & counterResetHeaderMask)
                ?? .unknownCounterReset)
        return (hc, happ)
    }

    /// Go: `recodeHistogram` — widen the SAMPLE in place so it carries the chunk's extra (empty)
    /// buckets. `inout` because Go writes through the caller's pointer; see the file header.
    func recodeHistogram(
        _ h: inout Histogram, _ pBackwardInserts: [Insert], _ nBackwardInserts: [Insert]
    ) {
        if !pBackwardInserts.isEmpty {
            let numPositiveBuckets = countSpans(h.positiveSpans)
            h.positiveBuckets = insert(
                h.positiveBuckets, [Int64](repeating: 0, count: numPositiveBuckets),
                pBackwardInserts, true)
        }
        if !nBackwardInserts.isEmpty {
            let numNegativeBuckets = countSpans(h.negativeSpans)
            h.negativeBuckets = insert(
                h.negativeBuckets, [Int64](repeating: 0, count: numNegativeBuckets),
                nBackwardInserts, true)
        }
    }

    // MARK: AppendHistogram

    /// Go: `HistogramAppender.AppendHistogram`.
    ///
    /// The four outcomes, all of which the caller has to handle:
    ///
    ///  * appended to this chunk — `chunk == nil`, `isRecoded == false`, the same appender back;
    ///  * this chunk recoded — the NEW chunk and `isRecoded == true`, and the caller must swap it in
    ///    place of the old one rather than treat it as a fresh chunk;
    ///  * a new chunk cut — the new chunk with `isRecoded == false`;
    ///  * `appendOnly` and the sample does not fit — a throw, and the caller keeps the appender it
    ///    already has (Go returns `a` alongside the error, which is the same appender).
    @discardableResult
    func appendHistogram(
        prev: (any ChunkAppender)?, t: Int64, h: inout Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        let numSamplesNow = numSamples

        if numSamplesNow == Int(UInt16.max) {
            preconditionFailure("chunk capacity exceeded")
        }

        if numSamplesNow == 0 {
            setNumSamples(appendHistogram(numSamplesNow, t, h))
            if h.counterResetHint == .gaugeType {
                setCounterResetHeader(.gaugeType)
                return (nil, false, self)
            }
            if h.counterResetHint == .counterReset {
                // "Always honor the explicit counter reset hint."
                setCounterResetHeader(.counterReset)
            } else if let prev {
                // A new chunk continued from a previous one: the previous appender's `appendable`
                // decides the header. The type test is here rather than at the interface boundary so
                // a caller can hand over whichever appender it happens to hold — and `prev` is
                // silently ignored when it is not an integer-histogram appender, which is what makes
                // a float-chunk-to-histogram-chunk transition give `UnknownCounterReset`.
                if let p = prev as? any HistogramAppendable {
                    let r = p.appendable(h)
                    setCounterResetHeader(r.counterResetHint)
                }
            }
            return (nil, false, self)
        }

        // Counter-like histogram.
        if h.counterResetHint != .gaugeType {
            let (pForward, nForward, pBackward, nBackward, okToAppend, crHint) = appendable(h)
            if !okToAppend || crHint != .notCounterReset {
                if appendOnly {
                    if crHint == .counterReset {
                        throw HistogramAppendError.counterReset
                    }
                    throw HistogramAppendError.schemaChange
                }
                let newChunk = HistogramChunk()
                guard let happ = try? newChunk.appender() else {
                    preconditionFailure("this should never happen for an empty histogram chunk")
                }
                happ.setCounterResetHeader(crHint)
                happ.setNumSamples(happ.appendHistogram(0, t, h))
                return (newChunk, false, happ)
            }
            if !pBackward.isEmpty || !nBackward.isEmpty {
                // The sample has to grow the chunk's extra empty buckets.
                if pForward.isEmpty && nForward.isEmpty {
                    // No new buckets from the sample, so the appender's spans already accommodate it.
                    // Upstream copies rather than aliases, "in case the input is sharing spans from an
                    // iterator" — with copy-on-write arrays the copy is implicit, and the assignment
                    // is what matters.
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
                        gauge: false, float: false, direction: .forward,
                        positive: pForward.count, negative: nForward.count)
                }
                let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)
                happ.setNumSamples(happ.appendHistogram(happ.numSamples, t, h))
                return (chk, true, happ)
            }
            setNumSamples(appendHistogram(numSamplesNow, t, h))
            return (nil, false, self)
        }

        // Gauge histogram.
        let (pForward, nForward, pBackward, nBackward, pMerged, nMerged, okToAppend) =
            appendableGauge(h)
        if !okToAppend {
            if appendOnly {
                throw HistogramAppendError.gaugeSchemaChange
            }
            let newChunk = HistogramChunk()
            guard let happ = try? newChunk.appender() else {
                preconditionFailure("this should never happen for an empty histogram chunk")
            }
            happ.setCounterResetHeader(.gaugeType)
            happ.setNumSamples(happ.appendHistogram(0, t, h))
            return (newChunk, false, happ)
        }

        if pBackward.count + nBackward.count > 0 {
            if appendOnly {
                throw HistogramAppendError.layoutChange(
                    gauge: true, float: false, direction: .backward,
                    positive: pBackward.count, negative: nBackward.count)
            }
            h.positiveSpans = pMerged
            h.negativeSpans = nMerged
            recodeHistogram(&h, pBackward, nBackward)
        }

        if !pForward.isEmpty || !nForward.isEmpty {
            if appendOnly {
                throw HistogramAppendError.layoutChange(
                    gauge: true, float: false, direction: .forward,
                    positive: pForward.count, negative: nForward.count)
            }
            let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)
            happ.setNumSamples(happ.appendHistogram(happ.numSamples, t, h))
            return (chk, true, happ)
        }

        setNumSamples(appendHistogram(numSamplesNow, t, h))
        return (nil, false, self)
    }
}

extension HistogramAppender: HistogramAppendable {}

/// Go: the `errors.New`/`fmt.Errorf` messages `AppendHistogram` and `AppendFloatHistogram` produce
/// when `appendOnly` is set. Reproduced byte for byte, including the float chunk's `float ` prefix and
/// the fact that the *backward* message only exists on the gauge path.
public enum HistogramAppendError: Error, CustomStringConvertible, Equatable {
    public enum Direction: String, Sendable, Equatable {
        case forward = "forwards"
        case backward = "backwards"
    }

    case counterReset
    case schemaChange
    case gaugeSchemaChange
    case floatCounterReset
    case floatSchemaChange
    case floatGaugeSchemaChange
    case layoutChange(gauge: Bool, float: Bool, direction: Direction, positive: Int, negative: Int)

    public var description: String {
        switch self {
        case .counterReset: return "histogram counter reset"
        case .schemaChange: return "histogram schema change"
        case .gaugeSchemaChange: return "gauge histogram schema change"
        case .floatCounterReset: return "float histogram counter reset"
        case .floatSchemaChange: return "float histogram schema change"
        case .floatGaugeSchemaChange: return "float gauge histogram schema change"
        case .layoutChange(let gauge, let float, let direction, let positive, let negative):
            var s = float ? "float " : ""
            s += gauge ? "gauge histogram" : "histogram"
            s += " layout change with \(positive) positive and \(negative) negative "
            s += direction.rawValue
            s += " inserts"
            return s
        }
    }
}

// MARK: - expandIntSpansAndBuckets

/// Go: `expandIntSpansAndBuckets`.
///
/// **The one line that is not shared with the float twin is `aCount += aBuckets[aCountIdx]`.** Integer
/// histogram buckets are DELTAS, so the running count has to accumulate; float histogram buckets are
/// absolute, so its twin assigns. A port that shares the loop between them detects the wrong resets
/// on every histogram with more than one bucket, and the two functions otherwise read identically —
/// which is exactly why upstream keeps them as two copies rather than one generic.
///
/// `ok == false` means a bucket that was IN USE in `a` is missing from `b`, which upstream reads as a
/// counter reset. A bucket missing from `b` whose count in `a` was zero is fine: it is noted as a
/// *backward* insert and the walk continues.
func expandIntSpansAndBuckets(
    _ a: [Span], _ b: [Span], _ aBuckets: [Int64], _ bBuckets: [Int64]
) -> (forward: [Insert], backward: [Insert], ok: Bool) {
    var ai = BucketIterator(a)
    var bi = BucketIterator(b)

    var aInserts: [Insert] = []
    var bInserts: [Insert] = []
    var aInter = Insert()
    var bInter = Insert()

    var (aIdx, aOK) = ai.next()
    var (bIdx, bOK) = bi.next()

    var aCount: Int64 = 0
    var bCount: Int64 = 0
    var aCountIdx = 0
    var bCountIdx = 0
    // The first bucket is an absolute count; every later one is a delta, hence `=` here and `+=` in
    // the two advance helpers.
    if aOK { aCount = aBuckets[aCountIdx] }
    if bOK { bCount = bBuckets[bCountIdx] }

    func addInsert(_ inserts: inout [Insert], _ insert: inout Insert, _ otherIdx: Int) {
        if insert.num == 0 {
            insert.bucketIdx = otherIdx
        } else if insert.bucketIdx + insert.num != otherIdx {
            // Not continuous with the previous insert, so flush it.
            inserts.append(insert)
            insert.num = 0
            insert.bucketIdx = otherIdx
        }
        insert.num += 1
    }

    func advanceA() {
        if aInter.num > 0 {
            aInserts.append(aInter)
            aInter.num = 0
        }
        (aIdx, aOK) = ai.next()
        aInter.pos += 1
        aCountIdx += 1
        if aOK { aCount = aCount &+ aBuckets[aCountIdx] }
    }

    func advanceB() {
        if bInter.num > 0 {
            bInserts.append(bInter)
            bInter.num = 0
        }
        (bIdx, bOK) = bi.next()
        bInter.pos += 1
        bCountIdx += 1
        if bOK { bCount = bCount &+ bBuckets[bCountIdx] }
    }

    while true {
        if aOK && bOK {
            if aIdx == bIdx {
                if aCount > bCount {
                    return ([], [], false)
                }
                advanceA()
                advanceB()
                continue
            } else if aIdx < bIdx {
                // `b` is missing a bucket `a` has. Fine only if `a`'s was empty.
                if aCount == 0 {
                    addInsert(&bInserts, &bInter, aIdx)
                    advanceA()
                    continue
                }
                return ([], [], false)
            } else {
                // `a` is missing a bucket `b` has, which is ordinary growth.
                addInsert(&aInserts, &aInter, bIdx)
                advanceB()
            }
        } else if aOK && !bOK {
            if aCount == 0 {
                addInsert(&bInserts, &bInter, aIdx)
                advanceA()
                continue
            }
            return ([], [], false)
        } else if !aOK && bOK {
            addInsert(&aInserts, &aInter, bIdx)
            advanceB()
        } else {
            if aInter.num > 0 { aInserts.append(aInter) }
            if bInter.num > 0 { bInserts.append(bInter) }
            break
        }
    }

    return (aInserts, bInserts, true)
}

// MARK: - The iterator

/// Go: `histogramIterator`.
///
/// **A `final class`, unlike `XORIterator`.** Go's is a pointer and `Chunk.Iterator(reuse)` hands one
/// back after `Reset`, so reference semantics are the contract rather than an implementation detail.
/// The float chunks were made value types and boxed (§7f(c)) because their iterators are two words and
/// `PromQL`'s reuse sites depend on the copy semantics; these carry six slices and are only ever
/// reached through `any ChunkIterator`, so boxing would buy nothing and cost a layer.
///
/// **What is deliberately NOT ported is the slice recycling.** Upstream tracks `atHistogramCalled` /
/// `atFloatHistogramCalled` and, on the next `Next`, copies any slice it has already handed out before
/// mutating it — because Go slices alias. Swift arrays are copy-on-write, so the caller's histogram is
/// already isolated from any later mutation and every branch of that bookkeeping is unobservable. See
/// PORTING.md exception 31.
public final class HistogramIterator: ChunkIterator {
    var br: BstreamReader
    /// `var` rather than `let`: `Reset` re-reads it from the new stream.
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
    var cnt: UInt64 = 0
    var zCnt: UInt64 = 0
    var tDelta: Int64 = 0
    var cntDelta: Int64 = 0
    var zCntDelta: Int64 = 0
    /// Deltas, matching `Histogram.positiveBuckets`.
    var pBuckets: [Int64] = []
    var nBuckets: [Int64] = []
    /// Absolute counts, matching `FloatHistogram.positiveBuckets`. Kept alongside so
    /// `atFloatHistogram(nil)` can hand them out without a conversion pass.
    var pFloatBuckets: [Double] = []
    var nFloatBuckets: [Double] = []
    var pBucketsDelta: [Int64] = []
    var nBucketsDelta: [Int64] = []

    var sum: Double = 0
    var leading: UInt8 = 0
    var trailing: UInt8 = 0

    var error: (any Error)?

    /// Go: `newHistogramIterator`. Note `t` starts at `math.MinInt64` here and at **0** in `reset` —
    /// an upstream asymmetry, reproduced. It is observable through `Seek`, whose loop condition is
    /// `t > it.t`.
    public init(_ b: [UInt8]) {
        br = BstreamReader(Array(b[histogramHeaderSize...]))
        numTotal = GoBigEndian.uint16(b, 0)
        t = Int64.min
        counterResetHeaderValue =
            CounterResetHeader(rawValue: b[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
    }

    /// Go: `histogramIterator.Reset`.
    public func reset(_ b: [UInt8]) {
        br = BstreamReader(Array(b[histogramHeaderSize...]))
        numTotal = GoBigEndian.uint16(b, 0)
        numRead = 0
        counterResetHeaderValue =
            CounterResetHeader(rawValue: b[histogramFlagPos] & counterResetHeaderMask)
            ?? .unknownCounterReset
        t = 0
        cnt = 0
        zCnt = 0
        tDelta = 0
        cntDelta = 0
        zCntDelta = 0
        pBuckets = []
        nBuckets = []
        pFloatBuckets = []
        nFloatBuckets = []
        pBucketsDelta = []
        nBucketsDelta = []
        sum = 0
        leading = 0
        trailing = 0
        error = nil
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
        return .histogram
    }

    /// Go: `panic("cannot call histogramIterator.At")`. Unreachable by contract — a histogram chunk's
    /// samples are never floats — so PORTING.md exception 9's treatment, with Go's exact text.
    public func at() -> (Int64, Double) {
        preconditionFailure("cannot call histogramIterator.At")
    }

    public func atT() -> Int64 { t }

    /// Go: `histogramIterator.AtST` returns 0 — integer histogram chunks carry no start timestamp.
    public func atST() -> Int64 { 0 }

    public func err() -> (any Error)? { error }

    /// Go: `AtHistogram`.
    ///
    /// The `reuse` argument is Go's optional buffer. Whether it is nil changes nothing observable in
    /// Swift beyond the fields the reuse path leaves alone — and it leaves NONE alone, because every
    /// field is overwritten. It is kept because PORTING.md §4 asks for the call sites.
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        if PromValue.isStaleNaN(sum) {
            // A stale sample carries nothing but its sum, and NOT the counter reset hint.
            return (t, Histogram(sum: sum))
        }
        var h = reuse ?? Histogram()
        h.counterResetHint = counterResetHint(counterResetHeaderValue, numRead)
        h.schema = schema
        h.zeroThreshold = zThreshold
        h.zeroCount = zCnt
        h.count = cnt
        h.sum = sum
        h.positiveSpans = pSpans
        h.negativeSpans = nSpans
        h.positiveBuckets = pBuckets
        h.negativeBuckets = nBuckets
        h.customValues = customValues
        reduceIfReserved(&h)
        return (t, h)
    }

    /// Go: `AtFloatHistogram` — also valid over an integer chunk, which it converts. Note it uses
    /// `pFloatBuckets`, the ABSOLUTE counts, where `atHistogram` uses the deltas.
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        if PromValue.isStaleNaN(sum) {
            return (t, FloatHistogram(sum: sum))
        }
        var fh = reuse ?? FloatHistogram()
        fh.counterResetHint = counterResetHint(counterResetHeaderValue, numRead)
        fh.schema = schema
        fh.zeroThreshold = zThreshold
        fh.zeroCount = Double(zCnt)
        fh.count = Double(cnt)
        fh.sum = sum
        fh.positiveSpans = pSpans
        fh.negativeSpans = nSpans
        if reuse == nil {
            fh.positiveBuckets = pFloatBuckets
            fh.negativeBuckets = nFloatBuckets
        } else {
            // The reuse path recomputes the cumulative sums from the deltas rather than reading
            // `pFloatBuckets`. Same numbers by construction, and reproduced so a divergence between
            // the two would show.
            var currentPositive = 0.0
            fh.positiveBuckets = pBuckets.map { b in
                currentPositive += Double(b)
                return currentPositive
            }
            var currentNegative = 0.0
            fh.negativeBuckets = nBuckets.map { b in
                currentNegative += Double(b)
                return currentNegative
            }
        }
        fh.customValues = customValues
        reduceIfReserved(&fh)
        return (t, fh)
    }

    public func next() -> ValueType {
        if error != nil || numRead == numTotal {
            return .none
        }

        if numRead == 0 {
            // The first read owns the chunk layout and everything that depends on it. The chunk-level
            // counter reset info is discarded here; it is re-derived per sample by `counterResetHint`.
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
                pBuckets = [Int64](repeating: 0, count: numPBuckets)
                pBucketsDelta = [Int64](repeating: 0, count: numPBuckets)
                pFloatBuckets = [Double](repeating: 0, count: numPBuckets)
            }
            if numNBuckets > 0 {
                nBuckets = [Int64](repeating: 0, count: numNBuckets)
                nBucketsDelta = [Int64](repeating: 0, count: numNBuckets)
                nFloatBuckets = [Double](repeating: 0, count: numNBuckets)
            }

            do {
                t = try readVarbitInt(&br)
                cnt = try readVarbitUint(&br)
                zCnt = try readVarbitUint(&br)
                sum = Double(bitPattern: try br.readBits(64))

                var current: Int64 = 0
                for i in 0..<pBuckets.count {
                    let v = try readVarbitInt(&br)
                    pBuckets[i] = v
                    current = current &+ pBuckets[i]
                    pFloatBuckets[i] = Double(current)
                }
                current = 0
                for i in 0..<nBuckets.count {
                    let v = try readVarbitInt(&br)
                    nBuckets[i] = v
                    current = current &+ nBuckets[i]
                    nFloatBuckets[i] = Double(current)
                }
            } catch {
                self.error = error
                return .none
            }

            numRead += 1
            return .histogram
        }

        do {
            let tDod = try readVarbitInt(&br)
            tDelta = tDelta &+ tDod
            t = t &+ tDelta

            let cntDod = try readVarbitInt(&br)
            cntDelta = cntDelta &+ cntDod
            cnt = UInt64(bitPattern: Int64(bitPattern: cnt) &+ cntDelta)

            let zCntDod = try readVarbitInt(&br)
            zCntDelta = zCntDelta &+ zCntDod
            zCnt = UInt64(bitPattern: Int64(bitPattern: zCnt) &+ zCntDelta)

            try xorRead(&br, &sum, &leading, &trailing)

            if PromValue.isStaleNaN(sum) {
                // The encoder wrote no bucket dods for a stale sample, so none are read.
                numRead += 1
                return .histogram
            }

            var current: Int64 = 0
            for i in 0..<pBuckets.count {
                let dod = try readVarbitInt(&br)
                pBucketsDelta[i] = pBucketsDelta[i] &+ dod
                pBuckets[i] = pBuckets[i] &+ pBucketsDelta[i]
                current = current &+ pBuckets[i]
                pFloatBuckets[i] = Double(current)
            }
            current = 0
            for i in 0..<nBuckets.count {
                let dod = try readVarbitInt(&br)
                nBucketsDelta[i] = nBucketsDelta[i] &+ dod
                nBuckets[i] = nBuckets[i] &+ nBucketsDelta[i]
                current = current &+ nBuckets[i]
                nFloatBuckets[i] = Double(current)
            }
        } catch {
            self.error = error
            return .none
        }

        numRead += 1
        return .histogram
    }
}

/// Go: the `Schema > ExponentialSchemaMax && Schema <= ExponentialSchemaMaxReserved` arm both `At*`
/// methods carry.
///
/// A chunk written by a newer Prometheus can hold a resolution this build does not support (schemas 9
/// through 52); rather than reject it, the reader reduces it to schema 8 on the way out. Upstream calls
/// this "a very slow path" and panics if the reduction fails, on the grounds that only invalid chunk
/// data could get here — exception 9's treatment again, since the port cannot throw from `At*`.
func reduceIfReserved(_ h: inout Histogram) {
    guard h.schema > HistogramSchema.exponentialMax
        && h.schema <= HistogramSchema.exponentialMaxReserved
    else { return }
    do {
        try h.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
    } catch {
        preconditionFailure(String(describing: error))
    }
}

func reduceIfReserved(_ fh: inout FloatHistogram) {
    guard fh.schema > HistogramSchema.exponentialMax
        && fh.schema <= HistogramSchema.exponentialMaxReserved
    else { return }
    do {
        try fh.reduceResolution(targetSchema: HistogramSchema.exponentialMax)
    } catch {
        preconditionFailure(String(describing: error))
    }
}
