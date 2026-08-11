//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/histogram_meta.go and the `appendable` half of
// tsdb/chunkenc/float_histogram.go @ v3.13.2
//
// **The metadata half of `chunkenc`, ported before the encoding half.** §5d says Phase 6 starts with
// `xor.go`, and it still does for the *encoding*; this file is the part Phase 5's exit gate reached
// back for. It contains no bstream, no varint, no bit packing — every function here is pure logic
// over two `FloatHistogram`s and their spans, which is why it is portable and differentially
// testable today while `bstream.go` sits unmerged on a branch for want of an exported seam.
//
// ## What the gate wanted from here
//
// A native histogram's `CounterResetHint` does NOT survive a round trip through storage. Read back
// out of a chunk it is recomputed from two things — the chunk's header, and the sample's position
// within the chunk:
//
//     GaugeType chunk           -> every sample reads GaugeType
//     counter chunk, 2nd sample -> NotCounterReset
//     anything else             -> UnknownCounterReset
//
// The last line is the surprising one: even the first sample of a chunk whose header says
// `NotCounterReset` reads back as *unknown*, because the previous chunk may no longer exist in the
// TSDB (upstream's own TODO, prometheus/prometheus#15346). So a `.test` file's
// `counter_reset_hint:not_reset` is not a value the storage keeps — it is a value the storage
// *derives*, and where the chunk boundaries fall decides it.
//
// Which makes `appendable` the other half of the answer: it is what decides whether the next sample
// fits in the current chunk or starts a new one, and if it starts one, whether the header says
// `CounterReset` or `NotCounterReset`.
//
// ## `appendable` returns two booleans and they are not opposites
//
// `okToAppend` and `counterReset` are independent. A layout change the encoder cannot express gives
// `okToAppend == false, counterReset == false` — "cut a chunk, but this is not a reset". A count that
// went backwards gives `counterReset == true`. Both cut a chunk; only one sets the reset header. A
// port that collapses them into one flag gets the header wrong on a schema change, which is
// observable as a hint one query later.
//
// ## Order of checks is load-bearing
//
// The gauge short-circuit comes first, then the explicit `CounterReset` hint (which is "always
// honoured"), then the two staleness checks, and only then `Count`. So a **stale** sample never reads
// as a counter reset however small its count is, and an explicit reset hint wins over a count that
// did not actually go backwards. Reordering any of it changes the header on real input.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat
internal import PromModel

/// Go: `CounterResetHeader` — the two bits a histogram chunk carries about its first sample.
public enum CounterResetHeader: UInt8, Sendable, Equatable {
    /// Go: `CounterReset` (`0b10 << 6`).
    case counterReset = 0b1000_0000
    /// Go: `NotCounterReset` (`0b01 << 6`).
    case notCounterReset = 0b0100_0000
    /// Go: `GaugeType` (`0b11 << 6`) — "the chunk contains gauge histograms only".
    case gaugeType = 0b1100_0000
    /// Go: `UnknownCounterReset` (`0b00`).
    case unknownCounterReset = 0b0000_0000
}

/// Go: `counterResetHint(crh, numRead)` — the hint a sample READS BACK with, which is not the hint it
/// was written with.
///
/// `numRead` is the number of samples read from the chunk *including* the current one, so `> 1` means
/// "the second sample onwards". See the file header for why the default arm is `unknown` even when
/// the header is known.
public func counterResetHint(
    _ header: CounterResetHeader, _ numRead: UInt16
) -> CounterResetHint {
    switch true {
    case header == .gaugeType:
        // A gauge chunk contains gauge histograms only.
        return .gaugeType
    case numRead > 1:
        // In a counter chunk there cannot be a reset after the first sample.
        return .notCounterReset
    default:
        return .unknownCounterReset
    }
}

/// Go: `Insert` — a run of buckets to be inserted into one side's bucket slice so the two layouts
/// line up. The port keeps it because `appendable` computes it and the encoder will need it, even
/// though the hint derivation only reads the two booleans.
public struct Insert: Sendable, Equatable {
    /// Position in the *existing* bucket slice at which the run is inserted.
    public var pos: Int = 0
    public var num: Int = 0
    /// Optional in Go's comment: the global bucket index, used to adjust spans.
    public var bucketIdx: Int = 0
}

/// Go: `bucketIterator` — walks the global bucket indices a span list covers.
///
/// The `idx = -1` then `idx += spans[0].Offset` start, and the `idx--` on a zero-length span, are
/// both upstream's; a zero-length span is legal and contributes no bucket while still shifting the
/// offset of what follows.
struct BucketIterator {
    let spans: [Span]
    var span: Int = 0
    var bucket: Int = -1
    var idx: Int = -1

    init(_ spans: [Span]) {
        self.spans = spans
        if let first = spans.first {
            idx += Int(first.offset)
        }
    }

    mutating func next() -> (Int, Bool) {
        if span >= spans.count {
            return (0, false)
        }
        if bucket < Int(spans[span].length) - 1 {
            // Within the same span.
            bucket += 1
            idx += 1
            return (idx, true)
        }
        while span < spans.count - 1 {
            span += 1
            idx += Int(spans[span].offset) + 1
            bucket = 0
            if spans[span].length == 0 {
                idx -= 1
                continue
            }
            return (idx, true)
        }
        return (0, false)
    }
}

/// Go: `expandFloatSpansAndBuckets` — can layout `b` be written into a chunk whose current layout is
/// `a`, and is the transition a counter reset?
///
/// `ok == false` means "a bucket that was IN USE in `a` is missing from `b`", which upstream reads as
/// a reset. A bucket missing from `b` whose count in `a` was **zero** is fine: it is noted as an
/// insert and the walk continues. That is the whole subtlety — an empty bucket disappearing is not a
/// reset, a used one is.
func expandFloatSpansAndBuckets(
    _ a: [Span], _ b: [Span], _ aBuckets: [Double], _ bBuckets: [Double]
) -> (forward: [Insert], backward: [Insert], ok: Bool) {
    var ai = BucketIterator(a)
    var bi = BucketIterator(b)

    var aInserts: [Insert] = []
    var bInserts: [Insert] = []
    var aInter = Insert()
    var bInter = Insert()

    var (aIdx, aOK) = ai.next()
    var (bIdx, bOK) = bi.next()

    var aCount = 0.0
    var bCount = 0.0
    var aCountIdx = 0
    var bCountIdx = 0
    if aOK, aCountIdx < aBuckets.count { aCount = aBuckets[aCountIdx] }
    if bOK, bCountIdx < bBuckets.count { bCount = bBuckets[bCountIdx] }

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
        if aOK, aCountIdx < aBuckets.count { aCount = aBuckets[aCountIdx] }
    }

    func advanceB() {
        if bInter.num > 0 {
            bInserts.append(bInter)
            bInter.num = 0
        }
        (bIdx, bOK) = bi.next()
        bInter.pos += 1
        bCountIdx += 1
        if bOK, bCountIdx < bBuckets.count { bCount = bBuckets[bCountIdx] }
    }

    while true {
        if aOK && bOK {
            if aIdx == bIdx {
                // The same bucket in both: a smaller count in `b` is a reset.
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

/// The state `appendable` compares against: what the chunk's **last appended** float histogram was.
///
/// Go keeps this on `FloatHistogramAppender` as `schema`, `zThreshold`, `customValues`, `sum`, `cnt`,
/// `zCnt`, `pSpans`/`nSpans` and `pBuckets`/`nBuckets`. Naming it separately is what lets the logic
/// be ported without the encoder — the appender's other fields are all bstream bookkeeping.
public struct FloatHistogramChunkState: Sendable {
    public var header: CounterResetHeader
    public var numSamples: Int
    public var schema: Int32
    public var zeroThreshold: Double
    public var customValues: [Double]?
    public var sum: Double
    public var count: Double
    public var zeroCount: Double
    public var positiveSpans: [Span]
    public var negativeSpans: [Span]
    public var positiveBuckets: [Double]
    public var negativeBuckets: [Double]

    /// The state after `h` is the chunk's most recent sample.
    public init(header: CounterResetHeader, numSamples: Int, last h: FloatHistogram) {
        self.header = header
        self.numSamples = numSamples
        self.schema = h.schema
        self.zeroThreshold = h.zeroThreshold
        self.customValues = h.customValues
        self.sum = h.sum
        self.count = h.count
        self.zeroCount = h.zeroCount
        self.positiveSpans = h.positiveSpans
        self.negativeSpans = h.negativeSpans
        self.positiveBuckets = h.positiveBuckets
        self.negativeBuckets = h.negativeBuckets
    }
}

/// Go: `FloatHistogramAppender.appendable`.
///
/// Two independent booleans out — see the file header on why collapsing them is wrong. The check
/// order is upstream's and load-bearing: gauge, then the explicit reset hint, then staleness, then
/// the count.
public func floatHistogramAppendable(
    _ state: FloatHistogramChunkState, _ h: FloatHistogram
) -> (okToAppend: Bool, counterReset: Bool) {
    // A gauge chunk takes no counter histograms; the caller's gauge path handles it.
    if state.numSamples > 0 && state.header == .gaugeType {
        return (false, false)
    }
    if h.counterResetHint == .counterReset {
        // "Always honor the explicit counter reset hint."
        return (false, true)
    }
    if PromValue.isStaleNaN(h.sum) {
        // A stale sample's buckets and spans do not matter.
        return (true, false)
    }
    if PromValue.isStaleNaN(state.sum) {
        // After a stale sample the chunk accepts only stale samples.
        return (false, false)
    }
    if h.count < state.count {
        return (false, true)
    }
    if h.schema != state.schema || h.zeroThreshold != state.zeroThreshold {
        // A layout the encoder cannot express — cut a chunk, but NOT a reset.
        return (false, false)
    }
    if isCustomBucketsSchema(h.schema)
        && !customBucketBoundsMatch(h.customValues, state.customValues)
    {
        return (false, true)
    }
    if h.zeroCount < state.zeroCount {
        // The zero threshold did not change, so this is a reset.
        return (false, true)
    }
    let (_, _, pOK) = expandFloatSpansAndBuckets(
        state.positiveSpans, h.positiveSpans, state.positiveBuckets, h.positiveBuckets)
    if !pOK {
        return (false, true)
    }
    let (_, _, nOK) = expandFloatSpansAndBuckets(
        state.negativeSpans, h.negativeSpans, state.negativeBuckets, h.negativeBuckets)
    if !nOK {
        return (false, true)
    }
    return (true, false)
}

/// Go: `FloatHistogramAppender.appendableGauge`, reduced to its decision.
///
/// A gauge sample is appendable to a gauge chunk unless the schema, the zero threshold or the custom
/// bounds changed. There is **no counter-reset concept** here at all, which is the point of the gauge
/// header: `expandSpansBothWays` cannot fail, so the bucket layout never forces a cut.
public func floatHistogramAppendableGauge(
    _ state: FloatHistogramChunkState, _ h: FloatHistogram
) -> Bool {
    if state.numSamples > 0 && state.header != .gaugeType {
        return false
    }
    if PromValue.isStaleNaN(h.sum) {
        return true
    }
    if PromValue.isStaleNaN(state.sum) {
        return false
    }
    if h.schema != state.schema || h.zeroThreshold != state.zeroThreshold {
        return false
    }
    if isCustomBucketsSchema(h.schema)
        && !customBucketBoundsMatch(h.customValues, state.customValues)
    {
        return false
    }
    return true
}

/// Go: `histogram.CustomBucketBoundsMatch` — nil and empty are the same thing.
func customBucketBoundsMatch(_ a: [Double]?, _ b: [Double]?) -> Bool {
    let x = a ?? []
    let y = b ?? []
    return x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
}
