//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/math/exp_arm64.s @ go1.26.5 — archExp.
//
// The sibling of ``GoMath/exp2(_:)``: `haveArchExp` is true for
// `amd64 || arm64 || loong64 || s390x` (math/exp_asm.go), so `math.Exp` is
// assembly on the architecture this project's fixtures are generated on and that
// CI runs. Both routines live in the same assembly file and share their
// polynomial, their `Ldexp` inlining and their constants; only the argument
// reduction and the thresholds differ.
//
// As with exp2, the polynomial is evaluated with **fused** multiply-adds, so it
// rounds once per term where the portable Go rounds twice — docs/PORTING.md
// quirk 0. Reaching for libm's `exp` would be a silent one-ULP divergence.
//
// Which of the fusions are *observable* was measured rather than assumed, by
// unfusing one expression at a time:
//
//   * `hi = x - k*Ln2Hi` — **never** observable. `Ln2Hi` carries only 32
//     significant bits and |k| <= 1075, so `k*Ln2Hi` is exact; that is precisely
//     what the hi/lo argument-reduction split is for.
//   * the argument reduction `Log2e*x ± 0.5` and the four polynomial terms — no
//     distinguishing input found, in 3,000,000 random inputs across the whole
//     domain or in a 1,700,000-candidate scan of the `int(...)` boundaries. The
//     polynomial terms are diluted below the final rounding; the reduction would
//     need the product to straddle an integer within one ULP.
//   * `c = r - rr*poly` — observable, and pinned by 3 committed cases.
//
// `math.Pow` calls `Exp`, which is why this is here: PromQL's `^` operator and
// every duration expression with a power in it go through it.
//===----------------------------------------------------------------------===//

extension GoMath {

    /// Go: `math.Exp` — e**x.
    ///
    /// Pinned by `Fixtures/gocompat/exp.jsonl`.
    public static func exp(_ x: Double) -> Double {
        // exp_arm64.s constants. Overflow/Underflow here are Exp's thresholds,
        // not Exp2's.
        let ln2Hi = 6.931_471_803_691_238_164_90e-01
        let ln2Lo = 1.908_214_929_270_587_700_02e-10
        let log2e = 1.442_695_040_888_963_387_00e+00
        let overflow = 7.097_827_128_933_839_730_96e+02
        let underflow = -7.451_332_191_019_411_084_20e+02
        // 2**-28, below which e**x rounds to exactly 1 + x.
        let nearZero = Double(bitPattern: 0x3e30_0000_0000_0000)

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
        if abs(x) < nearZero { return 1.0 + x }

        // Argument reduction: x = k*ln2 + r with |r| <= 0.5*ln2, computed as
        // r = hi - lo for extra precision.
        //
        // `FNMSUBD`/`FMADDD` make `log2e*x ± 0.5` a **single** rounding, which is
        // the difference from the portable `Exp`'s `Log2e*x + 0.5`. The
        // truncating convert (`FCVTZSD`) applied to x ± 0.5 is
        // round-half-away-from-zero spelled the long way.
        let kRounded =
            x < 0
            ? (-0.5).addingProduct(log2e, x)
            : (0.5).addingProduct(log2e, x)
        let k = Int(kRounded)
        let kAsDouble = Double(k)

        // FMSUBD: hi = x - kAsDouble*ln2Hi, one rounding.
        let hi = x.addingProduct(-kAsDouble, ln2Hi)
        let lo = kAsDouble * ln2Lo
        let r = hi - lo
        let rr = r * r

        // The fused polynomial, identical to exp2's.
        var poly = p4.addingProduct(rr, p5)
        poly = p3.addingProduct(rr, poly)
        poly = p2.addingProduct(rr, poly)
        poly = p1.addingProduct(rr, poly)
        // FMSUBD: c = r - rr*poly.
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
}
