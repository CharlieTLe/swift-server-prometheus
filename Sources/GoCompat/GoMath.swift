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
    ///
    /// `haveArchLog` is true only for `amd64 || s390x` (math/log_asm.go), so on
    /// arm64 this pure-Go `log` is what runs — the mirror image of `Exp`/`Exp2`.
    ///
    /// **Seven expressions are fused**, and which ones is not guessable: it comes
    /// from `go tool objdump -s 'math\.log$'`. Two are structural rather than
    /// local, and both are easy to miss:
    ///
    ///   * `t1 = s2 * (...)` never exists as a rounded value. `R := t1 + t2`
    ///     compiles to a single `FMADDD` of `t2 + s2*(...)`.
    ///   * `hfsq = 0.5 * f * f` never exists either. Only `0.5*f` is rounded, and
    ///     the second multiplication is fused into each of the two places `hfsq`
    ///     is read.
    ///
    /// Not all seven are *observable*, and the difference is worth recording so
    /// nobody has to re-derive it. Measured by unfusing one expression at a time
    /// and comparing against Go over 30,000,000 random inputs:
    ///
    /// | expression | observable |
    /// |---|---|
    /// | `k*Ln2Hi` in the final `FNMSUBD` | **never** — provably: `Ln2Hi` carries only 32 significant bits and \|k\| ≤ 1075, so the product is exact. That is what the hi/lo split is *for*. |
    /// | the two polynomial chains | not in 30M random inputs, nor in the corpus |
    /// | `hfsq + R` | not in 30M random inputs, nor in the corpus |
    /// | `R = t1 + t2` | ~3 per million |
    /// | `inner = s*(hfsq+R) + k*Ln2Lo` | ~12 per million |
    /// | `d = hfsq - inner` | not by random search, but the corpus's near-1 cases catch it |
    ///
    /// `Fixtures/gocompat/log.jsonl` commits harvested witnesses for the three
    /// observable ones, so unfusing any of them fails 10–16 cases rather than
    /// silently passing. The unobservable ones are matched by construction from
    /// the disassembly, which is stated here rather than implied.
    ///
    /// This matters: unfused, `log(5.2063069815873524)` is one ULP high, which
    /// carries straight into `Pow` (which computes `Exp(yf * Log(x))`) and from
    /// there into every PromQL `^`. The `gocompat/log2` corpus cannot catch any of
    /// it — `Log2` only ever calls `Log` on a fraction in [0.5, 1), where `k` is 0
    /// or -1 — so `gocompat/log` pins the full domain. A `pow` case is what
    /// exposed the gap.
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

        // Special cases. The negative case is Go's `NaN()`, whose payload is 1 —
        // `Double.nan`'s is 0, and a bit-pattern fixture sees the difference.
        if x.isNaN || x == .infinity { return x }
        if x < 0 { return Double(bitPattern: GoFloat.goNaNBits) }
        if x == 0 { return -.infinity }

        // Reduce.
        var (f1, ki) = frexp(x)
        if f1 < sqrt2Half {
            f1 *= 2
            ki -= 1
        }
        let f = f1 - 1
        let k = Double(ki)

        // Compute. Every `addingProduct` below is an `FMADDD`/`FNMSUBD` in Go's
        // arm64 output; see the doc comment for why that is load-bearing.
        let s = f / (2 + f)
        let s2 = s * s
        let s4 = s2 * s2

        var t1Poly = l5.addingProduct(s4, l7)
        t1Poly = l3.addingProduct(s4, t1Poly)
        t1Poly = l1.addingProduct(s4, t1Poly)

        var t2Poly = l4.addingProduct(s4, l6)
        t2Poly = l2.addingProduct(s4, t2Poly)
        let t2 = s4 * t2Poly

        // R = t1 + t2, with `t1 = s2 * t1Poly` fused into the addition.
        let r = t2.addingProduct(s2, t1Poly)

        // `hfsq` is only ever half-formed: 0.5*f is rounded, the `* f` is fused
        // into each of its two readers.
        let halfF = 0.5 * f
        let hfsqPlusR = r.addingProduct(halfF, f)
        let kLn2Lo = k * ln2Lo
        let inner = kLn2Lo.addingProduct(s, hfsqPlusR)
        // FNMSUBD: hfsq - inner.
        var d = (-inner).addingProduct(halfF, f)
        d -= f
        // FNMSUBD: k*Ln2Hi - d.
        return (-d).addingProduct(k, ln2Hi)
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


    // MARK: - Exp2

    /// Go: `math.Exp2` — 2**x.
    ///
    /// **Ported from the arm64 assembly (`math/exp_arm64.s`, `archExp2`), not from
    /// the pure-Go `exp2`.** `haveArchExp2` is true for `arm64 || loong64`
    /// (`math/exp2_asm.go`), so on the architecture this project's fixtures are
    /// generated on, and that CI runs, Go takes the assembly path. That is the
    /// mirror image of `math.Log`, which is assembly on amd64 and pure Go on arm64
    /// — see docs/PORTING.md's note on architecture-dependent answers.
    ///
    /// The algorithm is the same as the portable `exp2`/`expmulti` pair, with one
    /// difference that is entirely observable: the polynomial is evaluated with
    /// **fused** multiply-adds (`FMADDD`/`FMSUBD`/`FNMULD`), so it rounds once per
    /// term instead of twice. This is docs/PORTING.md quirk 0, and it is not
    /// theoretical here — Swift's own `exp2` from libm disagrees with Go's on 19 of
    /// 93 probe values, always by one ULP, including 2**0.5 where libm is the *more*
    /// accurate of the two. Matching Go is the requirement.
    ///
    /// Pinned by `Fixtures/gocompat/exp2.jsonl`.
    public static func exp2(_ x: Double) -> Double {
        // exp_arm64.s constants. Note Overflow2/Underflow2, which are the exp2
        // thresholds, not Exp's.
        let ln2Hi = 6.931_471_803_691_238_164_90e-01
        let ln2Lo = 1.908_214_929_270_587_700_02e-10
        let overflow = 1.023_999_999_999_999_9e+03
        let underflow = -1.0740e+03

        let p1 = 1.666_666_666_666_666_574_15e-01
        let p2 = -2.777_777_777_701_559_338_42e-03
        let p3 = 6.613_756_321_437_934_361_17e-05
        let p4 = -1.653_390_220_546_525_153_90e-06
        let p5 = 4.138_136_797_057_238_460_39e-08

        // Special cases, in the assembly's order. `x > overflow` catches +Inf and
        // `x < underflow` catches -Inf, so neither needs its own test.
        if x.isNaN { return x }
        if x > overflow { return .infinity }
        if x < underflow { return 0 }

        // Argument reduction: x = r*lg(e) + k with |r| <= ln(2)/2, computed as
        // r = hi - lo for extra precision. The rounding is truncation
        // (`FCVTZSD`), applied to x ± 0.5 — so this is round-half-away-from-zero
        // expressed the long way.
        let kRounded = x < 0 ? x - 0.5 : x + 0.5
        let k = Int(kRounded)
        let kAsDouble = Double(k)

        let t = x - kAsDouble
        let hi = t * ln2Hi
        let lo = -t * ln2Lo
        let r = hi - lo
        let rr = r * r

        // The fused polynomial. Each step is `a + b*c` and must round once, so
        // every one goes through addingProduct.
        var poly = p4.addingProduct(rr, p5)
        poly = p3.addingProduct(rr, poly)
        poly = p2.addingProduct(rr, poly)
        poly = p1.addingProduct(rr, poly)
        // FMSUBD: c = r - rr*poly, also a single rounding.
        let c = r.addingProduct(-rr, poly)

        let denominator = 2.0 - c
        let quotient = (r * c) / denominator
        var y = lo - quotient
        y -= hi
        y = 1.0 - y

        // The assembly inlines Ldexp(y, k) and skips its Inf/NaN/zero checks,
        // which is safe because y is always a normal near 1.
        var bits = y.bitPattern
        let fraction = bits & 0x000f_ffff_ffff_ffff
        var exponent = Int(bits >> 52)
        exponent += k

        var m = 1.0
        if exponent < 1 {
            // Denormal: shift the exponent up and scale back down by 2**-52.
            exponent += 52
            m = Double(bitPattern: 0x3cb0_0000_0000_0000)
        }
        bits = (UInt64(exponent) << 52) | fraction
        return m * Double(bitPattern: bits)
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
