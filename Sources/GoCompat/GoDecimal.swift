//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/internal/strconv/decimal.go
//
// Multiprecision decimal numbers, used for exact binary64 → decimal conversion
// when a fixed precision is requested. `strconv.FormatFloat`'s output is covered
// by Go's compatibility promise, so this is stable across Go versions even though
// Go 1.26 relocated the file from `strconv` to `internal/strconv`.
//===----------------------------------------------------------------------===//

/// A decimal number with enough digits to represent any binary64 exactly.
///
/// Value == `0.d[0]d[1]...d[nd-1] × 10^dp`.
struct GoDecimal {
    /// Go: `d [800]byte`. 800 digits is enough for the widest binary64 expansion
    /// (`5e-324` needs 751 significant places).
    static let capacity = 800
    /// Go: `maxShift = uintSize - 4`. Bounds a single shift step so the `UInt64`
    /// accumulators below cannot overflow.
    static let maxShift = 60

    /// Digits as ASCII `'0'...'9'`, most significant first.
    var d = [UInt8](repeating: 0, count: GoDecimal.capacity)
    /// Number of digits used.
    var nd = 0
    /// Decimal point position.
    var dp = 0
    /// Set when digits were discarded off the low end; `shouldRoundUp` needs it
    /// to break exact-half ties correctly.
    var trunc = false

    // MARK: - Construction

    /// Go: `(*decimal).Assign`.
    mutating func assign(_ v: UInt64) {
        var v = v
        var buf = [UInt8](repeating: 0, count: 24)

        // Write the decimal reversed into buf.
        var n = 0
        while v > 0 {
            let v1 = v / 10
            v -= 10 * v1
            buf[n] = UInt8(v) + UInt8(ascii: "0")
            n += 1
            v = v1
        }

        // Reverse again to produce a forward decimal in d.
        nd = 0
        n -= 1
        while n >= 0 {
            d[nd] = buf[n]
            nd += 1
            n -= 1
        }
        dp = nd
        trim()
    }

    // MARK: - Shifting

    /// Go: `(*decimal).Shift`. Multiplies by `2^k` (or divides, for negative `k`).
    mutating func shift(_ k: Int) {
        var k = k
        if nd == 0 { return }  // a == 0
        if k > 0 {
            while k > GoDecimal.maxShift {
                leftShift(GoDecimal.maxShift)
                k -= GoDecimal.maxShift
            }
            leftShift(k)
        } else if k < 0 {
            while k < -GoDecimal.maxShift {
                rightShift(GoDecimal.maxShift)
                k += GoDecimal.maxShift
            }
            rightShift(-k)
        }
    }

    /// Binary shift left (× 2) by `k` bits, `k <= maxShift`.
    ///
    /// Restructured from Go's `leftShift`, which consults the precomputed
    /// `leftcheats` table to learn the new digit count up front. We instead
    /// compute the product and derive `delta` from its length, which needs no
    /// table. Digits overflowing the buffer are dropped from the *least*
    /// significant end and set `trunc`, matching Go's `w >= len(a.d)` branch.
    private mutating func leftShift(_ k: Int) {
        guard nd > 0, k > 0 else { return }
        let shift = UInt64(k)

        // Multiply the digit string, viewed as an integer, by 2^k.
        // `out` accumulates least-significant-digit first.
        var out = [UInt8]()
        out.reserveCapacity(nd + k / 3 + 2)
        var carry: UInt64 = 0
        var i = nd - 1
        while i >= 0 {
            // Bounded by 9·2^60 + 2^60 = 10·2^60 < UInt64.max, hence maxShift == 60.
            let v = ((UInt64(d[i]) - 48) << shift) + carry
            out.append(UInt8(v % 10) + 48)
            carry = v / 10
            i -= 1
        }
        while carry > 0 {
            out.append(UInt8(carry % 10) + 48)
            carry /= 10
        }

        let newLen = out.count
        dp += newLen - nd

        // Drop least-significant digits that do not fit, then reverse into d.
        var dropped = 0
        if newLen > GoDecimal.capacity {
            dropped = newLen - GoDecimal.capacity
            for j in 0..<dropped where out[j] != UInt8(ascii: "0") {
                trunc = true
                break
            }
        }
        let kept = newLen - dropped
        for j in 0..<kept {
            d[kept - 1 - j] = out[dropped + j]
        }
        nd = kept
        trim()
    }

    /// Go: `rightShift`. Binary shift right (÷ 2) by `k` bits, `k <= maxShift`.
    private mutating func rightShift(_ k: Int) {
        var r = 0  // read index
        var w = 0  // write index
        let ku = UInt64(k)

        // Pick up enough leading digits to cover the first shift.
        var n: UInt64 = 0
        while n >> ku == 0 {
            if r >= nd {
                if n == 0 {
                    // a == 0; shouldn't get here, but handle anyway.
                    nd = 0
                    return
                }
                while n >> ku == 0 {
                    n *= 10
                    r += 1
                }
                break
            }
            n = n * 10 + UInt64(d[r]) - 48
            r += 1
        }
        dp -= r - 1

        let mask: UInt64 = (1 << ku) - 1

        // Pick up a digit, put down a digit.
        while r < nd {
            let c = UInt64(d[r])
            let dig = n >> ku
            n &= mask
            d[w] = UInt8(dig) + 48
            w += 1
            n = n * 10 + c - 48
            r += 1
        }

        // Put down extra digits.
        while n > 0 {
            let dig = n >> ku
            n &= mask
            if w < GoDecimal.capacity {
                d[w] = UInt8(dig) + 48
                w += 1
            } else if dig > 0 {
                trunc = true
            }
            n *= 10
        }

        nd = w
        trim()
    }

    // MARK: - Rounding

    /// Go: `trim`.
    mutating func trim() {
        while nd > 0 && d[nd - 1] == UInt8(ascii: "0") {
            nd -= 1
        }
        if nd == 0 {
            dp = 0
        }
    }

    /// Go: `shouldRoundUp`. Round-half-to-even at exact ties, unless digits were
    /// truncated (in which case the true value is above the halfway point).
    func shouldRoundUp(_ nd: Int) -> Bool {
        if nd < 0 || nd >= self.nd { return false }
        if d[nd] == UInt8(ascii: "5") && nd + 1 == self.nd {  // exactly halfway
            if trunc { return true }
            return nd > 0 && (d[nd - 1] - 48) % 2 != 0
        }
        return d[nd] >= UInt8(ascii: "5")
    }

    /// Go: `(*decimal).Round`.
    mutating func round(_ nd: Int) {
        if nd < 0 || nd >= self.nd { return }
        if shouldRoundUp(nd) {
            roundUp(nd)
        } else {
            roundDown(nd)
        }
    }

    /// Go: `(*decimal).RoundDown`.
    mutating func roundDown(_ nd: Int) {
        if nd < 0 || nd >= self.nd { return }
        self.nd = nd
        trim()
    }

    /// Go: `(*decimal).RoundUp`.
    mutating func roundUp(_ nd: Int) {
        if nd < 0 || nd >= self.nd { return }

        var i = nd - 1
        while i >= 0 {
            let c = d[i]
            if c < UInt8(ascii: "9") {  // can stop after this digit
                d[i] += 1
                self.nd = i + 1
                return
            }
            i -= 1
        }

        // Number is all 9s. Change to a single 1 with an adjusted decimal point.
        d[0] = UInt8(ascii: "1")
        self.nd = 1
        dp += 1
    }
}
