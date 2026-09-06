//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/histogram_meta.go @ v3.13.2 — the ENCODING half.
//
// `HistogramMeta.swift` took the *decision* half of this file in Phase 5 (`counterResetHint`,
// `bucketIterator`, `expandFloatSpansAndBuckets`, `appendable`), because the exit gate needed to know
// where a chunk gets cut without needing a chunk. What was left behind is everything that touches a
// `Bstream`: the layout header, the two bespoke float codecs under it, and the three span/bucket
// rewriters the recode path uses. That is this file, and it is the shared floor of both histogram
// chunk encodings.
//
// ## The layout header is written ONCE, by the first sample, and never revisited
//
// `writeHistogramChunkLayout` runs from `appendHistogram`'s `num == 0` arm. Everything after it is
// encoded *relative* to that layout, which is why a schema, zero-threshold, span or custom-bounds
// change cannot be appended and has to cut a new chunk — the two `appendable` functions exist to
// decide exactly that.
//
// ## Two hand-rolled float codecs, and both are about the COMMON case being one byte
//
// `putZeroThreshold` spends one byte on a power of two in `2^-243 … 2^10` (the default zero threshold,
// `2^-128`, encodes as the single byte 116) and nine on anything else. `putCustomBound` spends an
// unsigned varbit on a non-negative multiple of 0.001 up to 33554.430 and 1 bit + 8 bytes on anything
// else — and the `+1` before the varbit is load-bearing, because it is what makes 0 free as the
// "escaped" marker.
//
// The subtlety in `putCustomBound` is the SHORT-CIRCUIT: `tf < 0 || tf > 33554430 ||
// !isWholeWhenMultiplied(f)`. Go evaluates left to right, so `isWholeWhenMultiplied` never sees a
// negative or huge input — which is what makes its unchecked `uint(math.Round(...))` conversion safe
// upstream, and what lets the port spell that conversion out without guessing at arm64's saturation
// for the cases it cannot reach.
//
// ## `insert` is where the delta encoding gets paid for
//
// Integer histogram buckets are stored as DELTAS and float histogram buckets as ABSOLUTE values, so
// `insert` takes a `deltas` flag and the two arms are genuinely different arithmetic, not a
// micro-optimisation: inserting an empty bucket into a delta run has to emit `-v` (to bring the
// running value to 0) and then re-add `v` to the following delta, while inserting into an absolute
// run just writes 0. Passing the wrong flag produces a chunk that decodes without error and with the
// wrong numbers, which is the worst kind of bug this file can have.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat

/// Go: the histogram chunk header constants.
///
/// Three bytes: `[0:2]` is the big-endian sample count and `[2]` carries the counter-reset header in
/// its top two bits. XOR's header is two bytes, XOR2's is three with a different third byte — so the
/// three encodings agree on the sample count's position and on nothing else.
let histogramFlagPos = 2
let histogramHeaderSize = 3

/// Go: `CounterResetHeaderMask`.
let counterResetHeaderMask: UInt8 = 0b1100_0000

/// Go: `countSpans`.
func countSpans(_ spans: [Span]) -> Int {
    var cnt = 0
    for s in spans {
        cnt += Int(s.length)
    }
    return cnt
}

// MARK: - The chunk layout header

/// Go: `writeHistogramChunkLayout`.
func writeHistogramChunkLayout(
    _ b: inout Bstream, _ schema: Int32, _ zeroThreshold: Double,
    _ positiveSpans: [Span], _ negativeSpans: [Span], _ customValues: [Double]?
) {
    putZeroThreshold(&b, zeroThreshold)
    putVarbitInt(&b, Int64(schema))
    putHistogramChunkLayoutSpans(&b, positiveSpans)
    putHistogramChunkLayoutSpans(&b, negativeSpans)
    if isCustomBucketsSchema(schema) {
        putHistogramChunkLayoutCustomBounds(&b, customValues ?? [])
    }
}

/// Go: `readHistogramChunkLayout`.
///
/// The custom bounds are read **only** for a custom-buckets schema, so the schema read above decides
/// how many more bits the header has. A chunk whose schema byte is corrupted therefore mis-frames
/// everything after it rather than failing here.
func readHistogramChunkLayout(_ b: inout BstreamReader) throws -> (
    schema: Int32, zeroThreshold: Double,
    positiveSpans: [Span], negativeSpans: [Span], customValues: [Double]?
) {
    let zeroThreshold = try readZeroThreshold(&b)
    let v = try readVarbitInt(&b)
    let schema = Int32(truncatingIfNeeded: v)
    let positiveSpans = try readHistogramChunkLayoutSpans(&b)
    let negativeSpans = try readHistogramChunkLayoutSpans(&b)
    var customValues: [Double]?
    if isCustomBucketsSchema(schema) {
        customValues = try readHistogramChunkLayoutCustomBounds(&b)
    }
    return (schema, zeroThreshold, positiveSpans, negativeSpans, customValues)
}

/// Go: `putHistogramChunkLayoutSpans` — note the order is LENGTH then OFFSET, the reverse of how a
/// `Span` reads in source.
func putHistogramChunkLayoutSpans(_ b: inout Bstream, _ spans: [Span]) {
    putVarbitUint(&b, UInt64(spans.count))
    for s in spans {
        putVarbitUint(&b, UInt64(s.length))
        putVarbitInt(&b, Int64(s.offset))
    }
}

/// Go: `readHistogramChunkLayoutSpans`.
func readHistogramChunkLayoutSpans(_ b: inout BstreamReader) throws -> [Span] {
    var spans: [Span] = []
    let num = try readVarbitUint(&b)
    var i: UInt64 = 0
    while i < num {
        let length = try readVarbitUint(&b)
        let offset = try readVarbitInt(&b)
        spans.append(
            Span(
                offset: Int32(truncatingIfNeeded: offset),
                length: UInt32(truncatingIfNeeded: length)))
        i += 1
    }
    return spans
}

/// Go: `putHistogramChunkLayoutCustomBounds`.
func putHistogramChunkLayoutCustomBounds(_ b: inout Bstream, _ customValues: [Double]) {
    putVarbitUint(&b, UInt64(customValues.count))
    for bound in customValues {
        putCustomBound(&b, bound)
    }
}

/// Go: `readHistogramChunkLayoutCustomBounds` — `nil` rather than `[]` for an empty list, because Go's
/// `var customValues []float64` is nil when the loop never runs and `CustomValues` is compared for
/// nil-ness elsewhere (`CustomBucketBoundsMatch` treats nil and empty alike, but `Histogram.Copy`
/// does not).
func readHistogramChunkLayoutCustomBounds(_ b: inout BstreamReader) throws -> [Double]? {
    var customValues: [Double] = []
    let num = try readVarbitUint(&b)
    var i: UInt64 = 0
    while i < num {
        customValues.append(try readCustomBound(&b))
        i += 1
    }
    return customValues.isEmpty ? nil : customValues
}

// MARK: - The zero threshold

/// Go: `putZeroThreshold` — one byte for a power of two in `[2^-243, 2^10]`, nine for anything else.
///
/// The exponent stored is Go's `Frexp` exponent, which is one MORE than the IEEE 754 exponent because
/// `Frexp` normalises the fraction to `[0.5, 1)`: `2^-243` is `0.5 * 2^-242`. Adding 243 maps
/// `-242…11` onto `1…254`, leaving 0 for "threshold is zero" and 255 for the escape.
func putZeroThreshold(_ b: inout Bstream, _ threshold: Double) {
    if threshold == 0 {
        b.writeByte(0)
        return
    }
    let (frac, exp) = GoMath.frexp(threshold)
    if frac != 0.5 || exp < -242 || exp > 11 {
        b.writeByte(255)
        b.writeBits(threshold.bitPattern, 64)
        return
    }
    b.writeByte(UInt8(truncatingIfNeeded: exp + 243))
}

/// Go: `readZeroThreshold`.
func readZeroThreshold(_ br: inout BstreamReader) throws -> Double {
    let b = try br.readByte()
    switch b {
    case 0:
        return 0
    case 255:
        return Double(bitPattern: try br.readBits(64))
    default:
        return GoMath.ldexp(0.5, Int(b) - 243)
    }
}

// MARK: - Custom bucket bounds

/// Go: `isWholeWhenMultiplied`.
///
/// Go's `uint(math.Round(in * 1000))` is an unchecked float-to-unsigned conversion, which Swift traps
/// on for a negative, NaN or out-of-range input where Go's arm64 `FCVTZU` saturates. **The only caller
/// short-circuits on `tf < 0` and `tf > 33554430` first**, so the reachable domain here is
/// `[0, 33554430]` and the saturation never happens — but spelling it out is cheaper than a trap that
/// only a future caller would find.
func isWholeWhenMultiplied(_ inValue: Double) -> Bool {
    let r = (inValue * 1000).rounded()
    let i: UInt
    if r.isNaN || r <= 0 {
        i = 0
    } else if r >= Double(UInt.max) {
        i = UInt.max
    } else {
        i = UInt(r)
    }
    let out = Double(i) / 1000
    return inValue == out
}

/// Go: `putCustomBound`.
///
/// The `+1` is what makes the escape work: every representable bound encodes as a *positive* varbit,
/// so the leading bit is always 1 and a leading 0 unambiguously means "eight bytes of float64 follow".
/// 33554430 is `2^25 - 2`, one below what a four-byte varbit holds — beyond that the float64 is no
/// more expensive, so upstream does not widen the varbit.
func putCustomBound(_ b: inout Bstream, _ f: Double) {
    let tf = f * 1000
    if tf < 0 || tf > 33_554_430 || !isWholeWhenMultiplied(f) {
        b.writeBit(false)
        b.writeBits(f.bitPattern, 64)
        return
    }
    putVarbitUint(&b, UInt64(tf.rounded()) + 1)
}

/// Go: `readCustomBound`.
func readCustomBound(_ br: inout BstreamReader) throws -> Double {
    let b = try readVarbitUint(&br)
    switch b {
    case 0:
        return Double(bitPattern: try br.readBits(64))
    default:
        return Double(b - 1) / 1000
    }
}

// MARK: - Span rewriting

/// Go: `expandSpansBothWays` — the GAUGE counterpart of `expand{Int,Float}SpansAndBuckets`.
///
/// Three differences from its counter siblings, and they are all consequences of one thing: a gauge
/// histogram has no counter to reset, so nothing here can fail. It returns no `ok`; it produces the
/// MERGED span layout as well as the two insert lists; and it will happily merge two layouts that
/// share no bucket at all, where the counter versions would call that a reset.
func expandSpansBothWays(_ a: [Span], _ b: [Span]) -> (
    forward: [Insert], backward: [Insert], mergedSpans: [Span]
) {
    var ai = BucketIterator(a)
    var bi = BucketIterator(b)

    var fInserts: [Insert] = []
    var bInserts: [Insert] = []
    var mergedSpans: [Span] = []
    var lastBucket = 0

    func addBucket(_ bucket: Int) {
        var offset = bucket - lastBucket - 1
        if offset == 0 && !mergedSpans.isEmpty {
            mergedSpans[mergedSpans.count - 1].length += 1
        } else {
            if mergedSpans.isEmpty {
                offset += 1
            }
            mergedSpans.append(
                Span(offset: Int32(truncatingIfNeeded: offset), length: 1))
        }
        lastBucket = bucket
    }

    var fInter = Insert()
    var bInter = Insert()

    var (av, aOK) = ai.next()
    var (bv, bOK) = bi.next()

    while true {
        if aOK && bOK {
            if av == bv {
                // The same bucket in both: flush whatever run each side had accumulated.
                if fInter.num > 0 {
                    fInserts.append(fInter)
                    fInter.num = 0
                }
                if bInter.num > 0 {
                    bInserts.append(bInter)
                    bInter.num = 0
                }
                addBucket(av)
                (av, aOK) = ai.next()
                (bv, bOK) = bi.next()
                fInter.pos += 1
                bInter.pos += 1
            } else if av < bv {
                // `b` misses a bucket `a` has.
                bInter.num += 1
                if fInter.num > 0 {
                    fInserts.append(fInter)
                    fInter.num = 0
                }
                addBucket(av)
                fInter.pos += 1
                (av, aOK) = ai.next()
            } else {
                // `a` misses a bucket `b` has.
                fInter.num += 1
                if bInter.num > 0 {
                    bInserts.append(bInter)
                    bInter.num = 0
                }
                addBucket(bv)
                bInter.pos += 1
                (bv, bOK) = bi.next()
            }
        } else if aOK && !bOK {
            bInter.num += 1
            addBucket(av)
            (av, aOK) = ai.next()
        } else if !aOK && bOK {
            fInter.num += 1
            addBucket(bv)
            (bv, bOK) = bi.next()
        } else {
            if fInter.num > 0 { fInserts.append(fInter) }
            if bInter.num > 0 { bInserts.append(bInter) }
            break
        }
    }

    return (fInserts, bInserts, mergedSpans)
}

/// Go: `adjustForInserts` — the span layout that results from applying `inserts` to `spans`.
///
/// Note the early return: with no inserts it hands back the input UNCHANGED, which for Go means the
/// caller keeps aliasing the same slice. Swift's arrays are copy-on-write, so the aliasing is not
/// observable; the return value is.
func adjustForInserts(_ spans: [Span], _ inserts: [Insert]) -> [Span] {
    if inserts.isEmpty {
        return spans
    }

    var it = BucketIterator(spans)

    var mergedSpans: [Span] = []
    var lastBucket = 0
    var i = 0
    var insertIdx = inserts[i].bucketIdx
    var insertNum = inserts[i].num

    func addBucket(_ bucket: Int) {
        var offset = bucket - lastBucket - 1
        if offset == 0 && !mergedSpans.isEmpty {
            mergedSpans[mergedSpans.count - 1].length += 1
        } else {
            if mergedSpans.isEmpty {
                offset += 1
            }
            mergedSpans.append(
                Span(offset: Int32(truncatingIfNeeded: offset), length: 1))
        }
        lastBucket = bucket
    }

    func consumeInsert() {
        insertNum -= 1
        if insertNum == 0 {
            i += 1
            if i < inserts.count {
                insertIdx = inserts[i].bucketIdx
                insertNum = inserts[i].num
            }
        } else {
            // A run of `num` inserts occupies CONSECUTIVE bucket indices from `bucketIdx`.
            insertIdx += 1
        }
    }

    var (bucket, ok) = it.next()
    while ok {
        if i < inserts.count && insertIdx < bucket {
            addBucket(insertIdx)
            consumeInsert()
        } else {
            addBucket(bucket)
            (bucket, ok) = it.next()
        }
    }
    while i < inserts.count {
        addBucket(insertIdx)
        consumeInsert()
    }
    return mergedSpans
}

// MARK: - insert

/// The arithmetic `insert` needs, spelled as a protocol so the one function serves both bucket
/// representations — Go gets this from a `int64 | float64` type constraint.
///
/// **Wrapping addition, deliberately.** Go's `int64` arithmetic wraps and Swift's traps, and `insert`
/// runs over caller-supplied bucket deltas with no range check upstream. `&+` keeps a pathological
/// input producing Go's answer rather than killing the process.
protocol BucketValueArithmetic: Equatable {
    static var zeroValue: Self { get }
    func wrappingAdding(_ other: Self) -> Self
    var wrappingNegated: Self { get }
}

extension Int64: BucketValueArithmetic {
    static var zeroValue: Int64 { 0 }
    func wrappingAdding(_ other: Int64) -> Int64 { self &+ other }
    var wrappingNegated: Int64 { 0 &- self }
}

extension Double: BucketValueArithmetic {
    static var zeroValue: Double { 0 }
    func wrappingAdding(_ other: Double) -> Double { self + other }
    /// `-v` in Go, so `-0.0` for a zero `v`. Kept as unary minus rather than `0 - v`, which would
    /// give `+0.0`.
    var wrappingNegated: Double { -self }
}

/// Go: `insert[BV bucketValue]`.
///
/// `out` must already be the right length; upstream says so and indexes it unchecked. See the file
/// header on why `deltas` is not a flag one can get away with guessing.
func insert<BV: BucketValueArithmetic>(
    _ input: [BV], _ outIn: [BV], _ inserts: [Insert], _ deltas: Bool
) -> [BV] {
    var out = outIn
    var oi = 0  // Position in `out`.
    var v = BV.zeroValue  // The last value seen.
    var ii = 0  // The next insert to process.

    for (i, d) in input.enumerated() {
        if ii >= inserts.count || i != inserts[ii].pos {
            // No insert here, so the original delta is still valid.
            out[oi] = d
            oi += 1
            v = v.wrappingAdding(d)
            continue
        }
        var firstInsert = true
        while ii < inserts.count && i == inserts[ii].pos {
            // `insert.num` new buckets whose VALUES are 0. In a delta run that means the first one
            // carries `-v` to bring the running value back to zero and the rest carry 0; in an
            // absolute run every one is simply 0.
            if deltas && firstInsert {
                out[oi] = v.wrappingNegated
                firstInsert = false
            } else {
                out[oi] = BV.zeroValue
            }
            oi += 1
            var x = 1
            while x < inserts[ii].num {
                out[oi] = BV.zeroValue
                oi += 1
                x += 1
            }
            ii += 1
        }
        // The original value, re-based: in a delta run the inserts drove the running value to 0, so
        // the old delta has to re-add what was there before.
        if deltas {
            out[oi] = d.wrappingAdding(v)
        } else {
            out[oi] = d
        }
        oi += 1
        v = v.wrappingAdding(d)
    }

    // Trailing inserts, past the end of the input.
    while ii < inserts.count {
        precondition(
            inserts[ii].pos >= input.count, "leftover inserts must be after the current buckets")
        if deltas {
            out[oi] = v.wrappingNegated
        } else {
            out[oi] = BV.zeroValue
        }
        oi += 1
        var x = 1
        while x < inserts[ii].num {
            out[oi] = BV.zeroValue
            oi += 1
            x += 1
        }
        ii += 1
        // `v = 0` rather than tracking: every trailing insert run starts from a zeroed value.
        v = BV.zeroValue
    }
    return out
}

// MARK: - The hint/header conversion

/// Go: `CounterResetHintToHeader`.
public func counterResetHintToHeader(_ hint: CounterResetHint) -> CounterResetHeader {
    switch hint {
    case .counterReset: return .counterReset
    case .notCounterReset: return .notCounterReset
    case .gaugeType: return .gaugeType
    default: return .unknownCounterReset
    }
}
