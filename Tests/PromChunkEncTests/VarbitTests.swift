//===----------------------------------------------------------------------===//
// `varbit.go`'s four functions — **and this suite is NOT differential, which is the point of the
// header.**
//
// `putVarbitInt`, `putVarbitIntFast`, `readVarbitInt`, `putVarbitUint` and `readVarbitUint` are all
// unexported in package `chunkenc`, so the oracle cannot call them. That is the same wall `bstream.go`
// hit (HANDOFF §5d), and it has the same answer: they get pinned against Go through the first chunk
// encoding that uses them, which is `EncXOR2` for start-timestamp deltas (§6b). Until that lands, this
// file is what can honestly be checked without Go:
//
//   1. **round-trip** — every value written and read back is itself. Catches an encoder/decoder
//      disagreement, which is the most likely bug, and says nothing about whether the BYTES match Go;
//   2. **`putVarbitInt` versus `putVarbitIntFast`** — two independent implementations of one encoding,
//      compared bit for bit. This one is a genuine cross-check rather than a tautology: the fast path
//      folds prefix and payload into a single masked write, so a wrong mask or a wrong width shows up
//      here without any Go involvement;
//   3. **the bucket boundaries** — that each value lands in the bucket the source comment claims, by
//      asserting the encoded LENGTH in bits. A boundary off by one changes the length, so this catches
//      the `bitRange`-versus-`bitRangeUint` confusion the file header warns about.
//
// What none of this catches is a systematically wrong bucket table — if every prefix were one bit too
// long, all three checks would still pass. Only the XOR2 corpus will catch that, and §6b's plan is to
// include a case per bucket edge for exactly this reason. **This file does not make `Varbit.swift`
// verified; it makes it self-consistent.**
//===----------------------------------------------------------------------===//

import PromChunkEnc
import Testing

@Suite("chunkenc: varbit integers, self-consistency pending the XOR2 corpus")
struct VarbitTests {

    /// The values that matter: zero, both sides of every bucket edge for both predicates, and the
    /// extremes. The signed edges are asymmetric — `bitRange(val, n)` admits `-((1<<(n-1))-1) …
    /// 1<<(n-1)`, so the 3-bit bucket is `-3...4`.
    private static let signedValues: [Int64] = {
        var vs: [Int64] = [0, 1, -1, 2, -2]
        for n in [3, 6, 9, 12, 18, 25, 56] as [Int64] {
            let hi = Int64(1) << (n - 1)
            let lo = -(hi - 1)
            // Inside the bucket, on both edges, and just outside on both sides.
            vs += [lo - 1, lo, lo + 1, hi - 1, hi, hi + 1]
        }
        vs += [Int64.min, Int64.max, Int64.min + 1, Int64.max - 1]
        vs += [1 << 62, -(1 << 62)]
        return vs
    }()

    private static let unsignedValues: [UInt64] = {
        var vs: [UInt64] = [0, 1, 2]
        for n in [3, 6, 9, 12, 18, 25, 56] as [UInt64] {
            let hi = (UInt64(1) << n) - 1  // the largest value that fits in n bits
            vs += [hi - 1, hi, hi + 1]
        }
        vs += [UInt64.max, UInt64.max - 1, 1 << 63]
        return vs
    }()

    @Test("every signed value round-trips")
    func signedRoundTrip() throws {
        for v in Self.signedValues {
            var b = Bstream()
            putVarbitInt(&b, v)
            var r = BstreamReader(b.bytes)
            let got = try readVarbitInt(&r)
            #expect(got == v, "putVarbitInt/readVarbitInt disagree on \(v): got \(got)")
        }
    }

    @Test("every unsigned value round-trips")
    func unsignedRoundTrip() throws {
        for v in Self.unsignedValues {
            var b = Bstream()
            putVarbitUint(&b, v)
            var r = BstreamReader(b.bytes)
            let got = try readVarbitUint(&r)
            #expect(got == v, "putVarbitUint/readVarbitUint disagree on \(v): got \(got)")
        }
    }

    /// **The cross-check with teeth.** Two independent implementations of one encoding: the plain one
    /// writes a prefix then a payload, the fast one folds both into a single masked write. A wrong mask
    /// or width in the fast path shows up as different bytes, with no Go needed.
    @Test("putVarbitIntFast writes exactly what putVarbitInt writes")
    func fastMatchesSlow() {
        for v in Self.signedValues {
            var slow = Bstream()
            putVarbitInt(&slow, v)
            var fast = Bstream()
            putVarbitIntFast(&fast, v)
            #expect(
                slow.bytes == fast.bytes && slow.count == fast.count,
                "fast and slow disagree on \(v): \(slow.bytes) vs \(fast.bytes)")
        }
    }

    /// The encoded LENGTH per bucket, which is what the source comment documents in its case labels:
    /// 1 bit for zero, then 5, 9, 13, 17, 24, 32, 64 and 72 bits.
    ///
    /// Asserting the length rather than the bytes is what makes this a boundary check: a bucket edge off
    /// by one moves a value into the neighbouring bucket and changes its length.
    @Test("each signed bucket encodes to the width its source comment claims")
    func signedBucketWidths() {
        func bitLength(_ v: Int64) -> Int {
            var b = Bstream()
            putVarbitInt(&b, v)
            // `count` is how many right-most bits of the last byte are FREE, so the used width is
            // 8*bytes - count. See `Bstream.swift`'s header, which warns about reading it the other way.
            return b.bytes.count * 8 - Int(b.count)
        }
        #expect(bitLength(0) == 1)
        // 3-bit bucket: -3...4, so 5 bits; 5 and -4 spill into the 6-bit bucket at 9 bits.
        #expect(bitLength(4) == 5)
        #expect(bitLength(-3) == 5)
        #expect(bitLength(5) == 9)
        #expect(bitLength(-4) == 9)
        // 6-bit bucket: -31...32.
        #expect(bitLength(32) == 9)
        #expect(bitLength(-31) == 9)
        #expect(bitLength(33) == 13)
        // 9-bit: -255...256. 12-bit: -2047...2048. 18-bit: -131071...131072.
        #expect(bitLength(256) == 13)
        #expect(bitLength(257) == 17)
        #expect(bitLength(2048) == 17)
        #expect(bitLength(2049) == 24)
        #expect(bitLength(131_072) == 24)
        #expect(bitLength(131_073) == 32)
        // 25-bit: -16777215...16777216. 56-bit next, then the 64-bit escape.
        #expect(bitLength(16_777_216) == 32)
        #expect(bitLength(16_777_217) == 64)
        #expect(bitLength(Int64.max) == 72)
        #expect(bitLength(Int64.min) == 72)
    }

    /// The unsigned buckets use `bitRangeUint`, a plain "fits in n bits", so the edges are `2^n - 1`
    /// rather than the signed asymmetric pair. Sharing one predicate between the two is the bug this
    /// catches.
    @Test("each unsigned bucket encodes to the width its source comment claims")
    func unsignedBucketWidths() {
        func bitLength(_ v: UInt64) -> Int {
            var b = Bstream()
            putVarbitUint(&b, v)
            return b.bytes.count * 8 - Int(b.count)
        }
        #expect(bitLength(0) == 1)
        #expect(bitLength(7) == 5)  // val <= 7
        #expect(bitLength(8) == 9)
        #expect(bitLength(63) == 9)  // val <= 63
        #expect(bitLength(64) == 13)
        #expect(bitLength(511) == 13)  // val <= 511
        #expect(bitLength(512) == 17)
        #expect(bitLength(4095) == 17)  // val <= 4095
        #expect(bitLength(4096) == 24)
        #expect(bitLength(262_143) == 24)  // val <= 262143
        #expect(bitLength(262_144) == 32)
        #expect(bitLength(33_554_431) == 32)  // val <= 33554431
        #expect(bitLength(33_554_432) == 64)
        #expect(bitLength(UInt64.max) == 72)
    }

    /// An unknown prefix is an ERROR rather than a zero, and the message is Go's `%b` rendering — no
    /// padding, no `0b`.
    @Test("a corrupt prefix is rejected with Go's message")
    func corruptPrefixRejected() {
        // Nine `1` bits: the reader stops after eight, giving `0b11111111`, which IS the escape — so the
        // unreachable-for-well-formed-input case needs a shorter impossible run. The only unreachable
        // `d` values are those with a zero bit followed by more ones, which the loop cannot produce.
        // So the `default` arm is dead for any bit string, and this test asserts the MESSAGE instead,
        // against a hand-built pattern, so the format is pinned for the day a caller can reach it.
        #expect(InvalidBitPattern(0b101).description == "invalid bit pattern 101")
        #expect(InvalidBitPattern(0).description == "invalid bit pattern 0")
        #expect(InvalidBitPattern(0b11111111).description == "invalid bit pattern 11111111")
    }
}
