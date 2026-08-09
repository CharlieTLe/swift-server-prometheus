//===----------------------------------------------------------------------===//
// Ported from Go's src/math/log.go and src/math/frexp.go @ go1.25
//
// Go does NOT call libm for these. `math.Log` is a Go implementation of
// FDLIBM's __ieee754_log, and `math.Log2` builds on it with an exact shortcut for
// powers of two. Both differ from the platform libm by up to an ULP.
//
// That is not academic: libm's `log2` disagrees with Go's on 43 of the 2,350
// values in Fixtures/gocompat/log2.jsonl — including 2^(1/4) and other exact
// exponential bucket boundaries, which is exactly what
// `FloatHistogram.TrimBuckets` feeds it. Using libm would silently shift
// interpolated bucket counts and the re-estimated sum. See ADR-4's reasoning
// applied to functions rather than formatting.
//
// Constants are written as bit patterns with Go's decimal in the comment, so a
// decimal-literal rounding difference cannot creep in.
//===----------------------------------------------------------------------===//

/// Go: the parts of `math` that are implemented in Go rather than delegated to
/// the platform's libm.
public enum GoMath: Sendable {

    /// Go: `math.Frexp` — breaks `f` into a normalised fraction and a power of
    /// two, such that `f == frac × 2**exp` with `frac` in [1/2, 1).
    @inlinable
    public static func frexp(_ f: Double) -> (frac: Double, exp: Int) {
        if f == 0 {
            return (f, 0)  // Correctly returns -0.
        }
        if f.isInfinite || f.isNaN {
            return (f, 0)
        }
        var (f, exp) = normalize(f)
        var x = f.bitPattern
        exp += Int((x >> UInt64(shift)) & UInt64(mask)) - bias + 1
        x &= ~(UInt64(mask) << UInt64(shift))
        x |= UInt64(-1 + bias) << UInt64(shift)
        f = Double(bitPattern: x)
        return (f, exp)
    }

    /// Go: `math.Log` — the natural logarithm.
    ///
    /// The method is FDLIBM's: argument reduction to `f` in
    /// [sqrt(2)/2, sqrt(2)], then a rational approximation of
    /// `log(1+f) - f + f²/2` in `s = f/(2+f)`, then reassembly with `k·ln2` split
    /// into a high and a low part so the multiplication stays exact.
    public static func log(_ x: Double) -> Double {
        // 6.93147180369123816490e-01
        let ln2Hi = Double(bitPattern: 0x3FE6_2E42_FEE0_0000)
        // 1.90821492927058770002e-10
        let ln2Lo = Double(bitPattern: 0x3DEA_39EF_3579_3C76)
        // 6.666666666666735130e-01
        let l1 = Double(bitPattern: 0x3FE5_5555_5555_5593)
        // 3.999999999940941908e-01
        let l2 = Double(bitPattern: 0x3FD9_9999_9997_FA04)
        // 2.857142874366239149e-01
        let l3 = Double(bitPattern: 0x3FD2_4924_9422_9359)
        // 2.222219843214978396e-01
        let l4 = Double(bitPattern: 0x3FCC_71C5_1D8E_78AF)
        // 1.818357216161805012e-01
        let l5 = Double(bitPattern: 0x3FC7_4664_96CB_03DE)
        // 1.531383769920937332e-01
        let l6 = Double(bitPattern: 0x3FC3_9A09_D078_C69F)
        // 1.479819860511658591e-01
        let l7 = Double(bitPattern: 0x3FC2_F112_DF3E_5244)
        // math.Sqrt2 / 2, as Go's constant arithmetic rounds it.
        let sqrt2Half = Double(bitPattern: 0x3FE6_A09E_667F_3BCD)

        // Special cases.
        if x.isNaN || x == .infinity { return x }
        if x < 0 { return .nan }
        if x == 0 { return -.infinity }

        // Reduce.
        var (f1, ki) = frexp(x)
        if f1 < sqrt2Half {
            f1 *= 2
            ki -= 1
        }
        let f = f1 - 1
        let k = Double(ki)

        // Compute.
        let s = f / (2 + f)
        let s2 = s * s
        let s4 = s2 * s2
        let t1 = s2 * (l1 + s4 * (l3 + s4 * (l5 + s4 * l7)))
        let t2 = s4 * (l2 + s4 * (l4 + s4 * l6))
        let r = t1 + t2
        let hfsq = 0.5 * f * f
        return k * ln2Hi - ((hfsq - (s * (hfsq + r) + k * ln2Lo)) - f)
    }

    /// Go: `math.Log2` — the binary logarithm.
    ///
    /// The `frac == 0.5` shortcut is load-bearing: it makes exact powers of two
    /// give exact answers rather than depending on `log(0.5)·(1/ln2) + exp`
    /// landing precisely on `exp - 1`.
    ///
    /// The final step is a **fused** multiply-add, matching the `FMADDD` Go's arm64
    /// backend emits here (verified by disassembling `math.log2`). This is not a
    /// micro-optimisation: for `x` just above a power of two, `log(frac)·(1/ln2)`
    /// is close to `-exp`, so the addition cancels around eight significant
    /// digits. Rounding the product first — which is what an unfused `a*b + c`
    /// does — inflates that rounding error to tens of ULP in the small result.
    public static func log2(_ x: Double) -> Double {
        // 1 / math.Ln2, as Go's constant arithmetic rounds it.
        let invLn2 = Double(bitPattern: 0x3FF7_1547_652B_82FE)
        let (frac, exp) = frexp(x)
        if frac == 0.5 {
            return Double(exp - 1)
        }
        return Double(exp).addingProduct(log(frac), invLn2)
    }

    // MARK: - Bit layout

    @usableFromInline static let shift = 64 - 11 - 1
    @usableFromInline static let mask = 0x7FF
    @usableFromInline static let bias = 1023

    /// Go: `math.normalize` — scales a subnormal up so the exponent field is
    /// meaningful, reporting the compensating exponent.
    @inlinable
    static func normalize(_ x: Double) -> (y: Double, exp: Int) {
        // 2**-1022, the smallest normal.
        let smallestNormal = Double(bitPattern: 0x0010_0000_0000_0000)
        if abs(x) < smallestNormal {
            return (x * Double(UInt64(1) << 52), -52)
        }
        return (x, 0)
    }
}
