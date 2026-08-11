//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/varbit.go @ v3.13.2 — variable-bit-width integers over a `Bstream`.
//
// §6b scoped this as `EncXOR2`'s prerequisite, and it is the cheaper half: no chunk state, no
// timestamps, just four functions over the bit stream. It is also what `histogram.go` and
// `float_histogram.go` will need, so it pays twice.
//
// ## Four functions, and the two `Int` ones are the SAME encoding
//
// `putVarbitInt` and `putVarbitIntFast` produce identical bit strings. The fast one folds the prefix
// and the payload into a single `writeBitsFast` call per bucket instead of two `writeBits` calls, which
// is why XOR2 uses it on its hot path — upstream's own TODO says to merge them once XOR2 is stable.
// **Both are ported, and the corpus checks they agree**, because "obviously identical" is exactly the
// kind of claim that turns out to have a boundary case.
//
// ## The buckets are the same for signed and unsigned, and the RANGES are not
//
// Both `putVarbitInt` and `putVarbitUint` use prefixes `0`, `10`, `110`, … `11111111` with payload
// widths 3, 6, 9, 12, 18, 25, 56, 64. But the predicate differs:
//
//   * signed uses `bitRange(val, n)`, which is XOR's asymmetric `-((1<<(n-1))-1) … 1<<(n-1)` — so the
//     3-bit bucket holds `-3...4`, not `-4...3` (quirk 117);
//   * unsigned uses `bitRangeUint(val, n)`, which is `LeadingZeros64(x) >= 64-n` — a plain "fits in n
//     bits", so the 3-bit bucket holds `0...7`.
//
// A port that shares one predicate between them is wrong on every bucket edge.
//
// ## The readers are asymmetric between signed and unsigned, deliberately
//
// `readVarbitInt` sign-extends with `if bits > (1 << (sz-1)) { bits -= 1 << sz }` — strictly greater,
// which is what makes `1<<(sz-1)` stay positive and matches `bitRange`'s upper bound.
// `readVarbitUint` does **no** such adjustment. Same buckets, different arithmetic.
//
// ## An unknown prefix is an ERROR, not a zero
//
// Both readers reject `d` values outside the eight known prefixes with `invalid bit pattern %b`. The
// prefix loop runs at most 8 times and stops at the first `0` bit, so the only unreachable-in-practice
// value is `0b11111111` followed by... nothing: eight `1`s is the escape. The `default` arm is
// therefore dead for well-formed input and live for corrupt input, which is the case that matters.
//===----------------------------------------------------------------------===//

internal import GoCompat

/// Go: `putVarbitInt`.
public func putVarbitInt(_ b: inout Bstream, _ val: Int64) {
    if val == 0 {
        // Precisely 0, one bit.
        b.writeBit(false)
    } else if bitRange(val, 3) {
        b.writeBits(0b10, 2)
        b.writeBits(UInt64(bitPattern: val), 3)
    } else if bitRange(val, 6) {
        b.writeBits(0b110, 3)
        b.writeBits(UInt64(bitPattern: val), 6)
    } else if bitRange(val, 9) {
        b.writeBits(0b1110, 4)
        b.writeBits(UInt64(bitPattern: val), 9)
    } else if bitRange(val, 12) {
        b.writeBits(0b11110, 5)
        b.writeBits(UInt64(bitPattern: val), 12)
    } else if bitRange(val, 18) {
        b.writeBits(0b111110, 6)
        b.writeBits(UInt64(bitPattern: val), 18)
    } else if bitRange(val, 25) {
        b.writeBits(0b1111110, 7)
        b.writeBits(UInt64(bitPattern: val), 25)
    } else if bitRange(val, 56) {
        b.writeBits(0b11111110, 8)
        b.writeBits(UInt64(bitPattern: val), 56)
    } else {
        // Worst case, nine bytes.
        b.writeBits(0b11111111, 8)
        b.writeBits(UInt64(bitPattern: val), 64)
    }
}

/// Go: `putVarbitIntFast` — the same bit string as `putVarbitInt`, one `writeBitsFast` per bucket.
///
/// The masks matter: `(0b10 << 3) | (uval & 0x7)` keeps the payload from bleeding into the prefix when
/// `val` is negative and so has high bits set. Dropping a mask corrupts the prefix rather than the
/// value, which is the more confusing failure.
public func putVarbitIntFast(_ b: inout Bstream, _ val: Int64) {
    let uval = UInt64(bitPattern: val)
    if val == 0 {
        b.writeBit(false)
    } else if bitRange(val, 3) {
        b.writeBitsFast((0b10 << 3) | (uval & 0x7), 5)
    } else if bitRange(val, 6) {
        b.writeBitsFast((0b110 << 6) | (uval & 0x3F), 9)
    } else if bitRange(val, 9) {
        b.writeBitsFast((0b1110 << 9) | (uval & 0x1FF), 13)
    } else if bitRange(val, 12) {
        b.writeBitsFast((0b11110 << 12) | (uval & 0xFFF), 17)
    } else if bitRange(val, 18) {
        b.writeBitsFast((0b111110 << 18) | (uval & 0x3FFFF), 24)
    } else if bitRange(val, 25) {
        b.writeBitsFast((0b1111110 << 25) | (uval & 0x1FF_FFFF), 32)
    } else if bitRange(val, 56) {
        b.writeBitsFast((0b11111110 << 56) | (uval & 0xFF_FFFF_FFFF_FFFF), 64)
    } else {
        b.writeBitsFast(0b11111111, 8)
        b.writeBitsFast(uval, 64)
    }
}

/// Go: `errInvalidBitPattern` — `fmt.Errorf("invalid bit pattern %b", d)`.
///
/// `%b` on a Go `byte` is unpadded binary, so `0b101` renders as `101` and zero as `0`.
public struct InvalidBitPattern: Error, CustomStringConvertible, Equatable, Sendable {
    public let pattern: UInt8
    public init(_ pattern: UInt8) { self.pattern = pattern }
    public var description: String {
        "invalid bit pattern \(String(pattern, radix: 2))"
    }
}

/// Reads the unary prefix both varbit readers share: at most eight bits, stopping at the first `0`.
private func readVarbitPrefix(_ b: inout BstreamReader) throws -> UInt8 {
    var d: UInt8 = 0
    for _ in 0..<8 {
        d <<= 1
        var bit: Bool
        do {
            bit = try b.readBitFast()
        } catch {
            bit = try b.readBit()
        }
        if !bit { break }
        d |= 1
    }
    return d
}

/// The payload width for a prefix, or `nil` when the prefix is the 64-bit escape, or a throw when it is
/// not a prefix at all.
private func varbitSize(_ d: UInt8) throws -> UInt8? {
    switch d {
    case 0b0: return 0
    case 0b10: return 3
    case 0b110: return 6
    case 0b1110: return 9
    case 0b11110: return 12
    case 0b111110: return 18
    case 0b1111110: return 25
    case 0b11111110: return 56
    case 0b11111111: return nil  // the 64-bit escape
    default: throw InvalidBitPattern(d)
    }
}

/// Go: `readVarbitInt`.
public func readVarbitInt(_ b: inout BstreamReader) throws -> Int64 {
    let d = try readVarbitPrefix(&b)
    guard let sz = try varbitSize(d) else {
        // Not the fast path: upstream's comment says it is very unlikely to succeed for 64 bits.
        return Int64(bitPattern: try b.readBits(64))
    }
    if sz == 0 {
        return 0
    }
    var bits: UInt64
    do {
        bits = try b.readBitsFast(sz)
    } catch {
        bits = try b.readBits(sz)
    }
    // Sign extension, with `>` rather than `>=` so that `1 << (sz-1)` stays positive — the same
    // asymmetry `bitRange`'s upper bound has.
    if bits > (1 << (UInt64(sz) - 1)) {
        bits &-= 1 << UInt64(sz)
    }
    return Int64(bitPattern: bits)
}

/// Go: `bitRangeUint` — a plain "fits in `nbits`", unlike the signed `bitRange`.
func bitRangeUint(_ x: UInt64, _ nbits: Int) -> Bool {
    x.leadingZeroBitCount >= 64 - nbits
}

/// Go: `putVarbitUint` — the same buckets as `putVarbitInt`, but unsigned ranges.
public func putVarbitUint(_ b: inout Bstream, _ val: UInt64) {
    if val == 0 {
        b.writeBit(false)
    } else if bitRangeUint(val, 3) {
        b.writeBits(0b10, 2)
        b.writeBits(val, 3)
    } else if bitRangeUint(val, 6) {
        b.writeBits(0b110, 3)
        b.writeBits(val, 6)
    } else if bitRangeUint(val, 9) {
        b.writeBits(0b1110, 4)
        b.writeBits(val, 9)
    } else if bitRangeUint(val, 12) {
        b.writeBits(0b11110, 5)
        b.writeBits(val, 12)
    } else if bitRangeUint(val, 18) {
        b.writeBits(0b111110, 6)
        b.writeBits(val, 18)
    } else if bitRangeUint(val, 25) {
        b.writeBits(0b1111110, 7)
        b.writeBits(val, 25)
    } else if bitRangeUint(val, 56) {
        b.writeBits(0b11111110, 8)
        b.writeBits(val, 56)
    } else {
        b.writeBits(0b11111111, 8)
        b.writeBits(val, 64)
    }
}

/// Go: `readVarbitUint` — **no sign extension**, which is the only difference from `readVarbitInt`
/// beyond the return type.
public func readVarbitUint(_ b: inout BstreamReader) throws -> UInt64 {
    let d = try readVarbitPrefix(&b)
    guard let sz = try varbitSize(d) else {
        return try b.readBits(64)
    }
    if sz == 0 {
        return 0
    }
    do {
        return try b.readBitsFast(sz)
    } catch {
        return try b.readBits(sz)
    }
}
