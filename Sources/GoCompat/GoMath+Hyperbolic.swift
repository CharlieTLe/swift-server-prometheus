//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/math @ go1.26.5 — log1p.go, sinh.go (Sinh, Cosh),
// tanh.go, asinh.go, acosh.go and atanh.go.
//
// `log1p` is here rather than in a file of its own because nothing but `asinh`,
// `acosh` and `atanh` calls it; `promql/functions.go` has no `log1p` wrapper.
//
// **None of these can be delegated to libm.** Measured against Go over 1,921,867
// distinct inputs per function (every branch boundary of all seven, straddled;
// every power of two from 2**-1074 to 2**1023; subnormals; and a seeded random
// sample across the whole exponent range):
//
//   | function | Swift's libm differs | of which NaN payload only |
//   |---|---|---|
//   | `Sinh`  |   472,471 (24.6%) | 0 |
//   | `Cosh`  |   260,500 (13.6%) | 0 |
//   | `Tanh`  |   103,074 ( 5.4%) | 0 |
//   | `Asinh` |   166,942 ( 8.7%) | 82 |
//   | `Acosh` | 1,334,959 (69.5%) | 1,307,450 |
//   | `Atanh` |   968,192 (50.4%) | 903,582 |
//   | `Log1p` |   346,161 (18.0%) | 289,167 |
//
// Acosh's and Atanh's totals are dominated by the out-of-domain NaN payload —
// Go's `NaN()` is `0x7FF8000000000001` and Swift's `Double.nan` is
// `0x7FF8000000000000` — but strip that out and 27,509 and 64,610 genuine
// one-ULP disagreements remain. `Tanh` is the mildest of the seven and still
// differs on one input in nineteen, starting at `Tanh(0.49999999999999994)`.
// Other first witnesses: `Sinh(0.625)`, `Cosh(1.0000000000000002)`,
// `Atanh(0.5)`, `Log1p(0.625)`, `Asinh(0.5000000000000001)`.
//
// `haveArchSinh` and its six siblings are true only on **s390x** (math/stubs.go
// against math/arith_s390x.go), so on arm64 and amd64 the portable Go below is
// what runs — the same situation as the trig block, and the opposite of
// `Exp`/`Exp2`/`Min`/`Max`.
//
// ## Fusion
//
// From `go tool objdump` per function against a `go test -c math` binary, not
// guessed. **Thirty-six fused sites across the seven functions** — 21 in `log1p`,
// 6 in `sinh`, 5 in `tanh`, 2 each in `asinh` and `acosh`. `cosh` and `atanh`
// have none at all, because every product in them is immediately divided.
//
// Three of the thirty-six are the recompute-unrounded pattern that
// `quantile.go`'s `rank` (PORTING.md quirk 29) and `tan`/`xatan` (quirk 39) also
// show: **where a polynomial's leading term is `sq + const` and `sq` is itself a
// product, the compiler fuses the product into that add, recomputing it
// UNROUNDED** even though the rounded `sq` is sitting in a register. `sinh`'s
// `sq + Q2`, `tanh`'s `s + tanhQ[0]` and `log1p`'s `hfsq + R` are all of them.
//
// `log1p`'s is the one worth staring at, because **the same source expression is
// compiled two different ways two lines apart**. In
// `f - (hfsq - s*(hfsq+R))` (log1p.go:200) the inner `hfsq` is
// `fma(f, 0.5*f, R)` and the outer one is the rounded value from log1p.go:180.
// In `k*Ln2Hi - ((hfsq - (s*(hfsq+R) + …)) - f)` (log1p.go:202) **both** are
// unrounded — because `SCVTFD R1, F4` puts `float64(k)` in the register the
// rounded `hfsq` was living in, so the value no longer exists to be read. This is
// not a local reading of the source and no amount of care with the Go text would
// produce it. It is also the loudest site in the file: unfusing it moves 188,208
// of 20,000,000 results.
//
// A second non-local one, in `asinh`'s default branch: `Log1p(x + x*x/(1+Sqrt(1+x*x)))`
// contains `x*x` twice on one line, and the compiler fuses the one under the
// `Sqrt` into its `+ 1` while leaving the numerator's as a plain rounded `FMULD`.
//
// "It is fused" is a claim, and a claim needs a failing case to be a tested one.
// Every site was unfused on its own and diffed against Go over 34,000,052 inputs
// — 14,000,052 broad, then 20,000,000 aimed at the branches the broad pass
// reached least, which is what turned `log1p`'s `Lp2` term from silent into
// witnessed. **Nineteen of the thirty-six are observable**, and each of them has
// harvested witnesses committed in `oracle/suites_gomath_hyperbolic.go`; a
// negative-control run confirms all nineteen break the committed fixtures when
// undone. The seventeen that are not sort into three groups, recorded here
// because re-deriving them is expensive:
//
// | group | sites | why |
// |---|---|---|
// | **provably exact** | `log1p`'s `x - x*x*0.5`; its three `k*Ln2Hi` products (log1p.go:188, :194, :202) | the first because the multiplier is a power of two and `\|x\| < 2**-29` keeps `x*x` in [2**-108, 2**-58), far from subnormal; the other three because `Ln2Hi` carries only 32 significant bits and \|k\| ≤ 1075 — the same argument as `log`'s (quirk 30), and exactly what splitting ln2 hi/lo is *for* |
// | **unreachable** | log1p.go:192's `f - R` | needs `iu == 0 && k == 0`, and `iu == 0` after the reduction implies `u == 1.0`, hence `\|x\| ≤ 2**-53` — which log1p.go:141 has already returned for. Its sibling log1p.go:185 (`return 0`) is dead for the same reason. Zero differences here means the code never runs, not that the difference hides |
// | **diluted below the final rounding** | the *leading* term of every polynomial chain: `sinh`'s `P3*sq+P2` and `sq+Q2`, `tanh`'s `P0*s+P1`\* and `s+tanhQ[0]`, the first four adds of `log1p`'s `Lp` chain, and its three `k*Ln2Lo+c` sites, `1-(2/3)f` and `R-(…)` | observability falls off monotonically along each chain, which is the clearest single measurement here: `sinh`'s numerator goes 0 → 122 → 25,280 witnesses first term to last, its denominator 0 → 5 → 4,426; `tanh`'s 0 → 2 → 1,545 and 0 → 122 → 10,513; and the six adds of `log1p`'s seven-term `Lp` chain go 0, 0, 0, 0, 8, 315 |
//
// \* `tanh`'s first numerator term is *just* observable (2 witnesses in 34M) and
// so is witnessed; it is listed with the diluted group because it belongs to the
// same gradient.
//
// The consequence for the two unrounded recomputations in `sinh` and `tanh`:
// **they are invisible, and only because they are the first term of their chain.**
// `xatan`'s structurally identical site is the *only* term of its denominator's
// leading position and is loudly observable. So no witness found is a fact about
// the search, not a licence to simplify — the port spells all thirty-six the way
// the disassembly does.
//
// Constants are written as bit patterns with Go's decimal in the comment.
//
// **Two of upstream's own hex comments are wrong.** log1p.go annotates
// `Sqrt2M1` as `0x3fda827999fcef34` and `Sqrt2HalfM1` as `0xbfd2bec333018866`,
// but Go compiles the decimals to `0x3FDA827999FCEF32` and `0xBFD2BEC333018867`
// — two ULP and one ULP away. What runs is the decimal, and every constant in
// this file was round-tripped through Go rather than read off a comment.
//
// Only the `Sqrt2M1` error is observable, and the asymmetry is instructive. A
// one-ULP change to a branch boundary changes behaviour for exactly the inputs in
// the ULP-wide gap, which for `Sqrt2HalfM1` is a single value — and there the
// `k = 0` shortcut and the full reduction happen to agree to the last bit, so the
// wrong constant is undetectable. `Sqrt2M1`'s gap is likewise one value wide, but
// the two paths there do *not* agree, and the negative control breaks. The
// corpora carry both values regardless.
//
// Three other things that read as though they should matter and provably do not,
// each confirmed by a negative control staying green: `hfsq = 0.5*f*f` may be
// regrouped as `0.5*(f*f)` (`0.5*f` is exact and `f` is bounded away from
// subnormal), `Exp(2*z)` may be written `Exp(z+z)` or the reverse, and `sinh`'s
// `x > 21` boundary is a pure optimisation — by the time `Exp(x)` reaches 1.3e9,
// `1/Exp(x)` is far below half an ULP of it, so the two branches agree for every
// `x` at or above 21. The port keeps Go's spelling in all three cases anyway.
//
// One more that reads as a typo and is not: `sinh`'s `P0` and `Q0` are written as
// **different** decimals (…9911847872 51e+6 and …9912120772 77e+6) that round to
// the same `float64`, `0xC1233FDEBA64BB4F`. Go's compiler notices and loads one
// constant for both. Both names are kept below so the source still lines up.
//===----------------------------------------------------------------------===//

extension GoMath {

    // MARK: - Log1p

    /// Go: `math.Log1p` — the natural logarithm of `1 + x`, accurate for `x` near
    /// zero in a way `Log(1 + x)` is not.
    ///
    /// FDLIBM's `s_log1p.c`: reduce `1+x` to `2**k * (1+f)` with a correction term
    /// `c` for the rounding of `1+x`, approximate `log(1+f)` by a degree-14
    /// polynomial in `s = f/(2+f)`, then reassemble with `k·ln2` split hi/lo.
    ///
    /// Special cases: `Log1p(+Inf) = +Inf`, `Log1p(±0) = ±0`, `Log1p(-1) = -Inf`,
    /// `Log1p(x < -1) = NaN`, `Log1p(NaN) = NaN`. The out-of-domain case and the
    /// NaN case share one `return NaN()`, so a NaN argument's own payload is
    /// **replaced** by Go's — `Double.nan` would be wrong here in both directions.
    ///
    /// Twenty-one fused sites, four of which are not a local reading of the source.
    /// See the file header for the classification and for why `hfsq` is spelled
    /// three different ways.
    public static func log1p(_ x: Double) -> Double {
        // Sqrt(2)-1. Upstream's comment says 0x3fda827999fcef34; the decimal
        // 4.142135623730950488017e-01 that Go actually compiles is this.
        let sqrt2M1 = Double(bitPattern: 0x3FDA_8279_99FC_EF32)
        // Sqrt(2)/2-1. Upstream's comment says 0xbfd2bec333018866; the decimal
        // -2.928932188134524755992e-01 is this, one ULP more negative. Unlike
        // `Sqrt2M1` above, the difference is **unobservable**: it changes the
        // branch for exactly one input, and there the `k = 0` shortcut and the full
        // reduction agree to the last bit. Correct anyway, not by luck.
        let sqrt2HalfM1 = Double(bitPattern: 0xBFD2_BEC3_3301_8867)
        // Small = 2**-29, Tiny = 2**-54, Two53 = 2**53.
        let small = Double(bitPattern: 0x3E20_0000_0000_0000)
        let tiny = Double(bitPattern: 0x3C90_0000_0000_0000)
        let two53 = Double(bitPattern: 0x4340_0000_0000_0000)
        // 6.93147180369123816490e-01
        let ln2Hi = Double(bitPattern: 0x3FE6_2E42_FEE0_0000)
        // 1.90821492927058770002e-10
        let ln2Lo = Double(bitPattern: 0x3DEA_39EF_3579_3C76)
        // 6.666666666666735130e-01
        let lp1 = Double(bitPattern: 0x3FE5_5555_5555_5593)
        // 3.999999999940941908e-01
        let lp2 = Double(bitPattern: 0x3FD9_9999_9997_FA04)
        // 2.857142874366239149e-01
        let lp3 = Double(bitPattern: 0x3FD2_4924_9422_9359)
        // 2.222219843214978396e-01
        let lp4 = Double(bitPattern: 0x3FCC_71C5_1D8E_78AF)
        // 1.818357216161805012e-01
        let lp5 = Double(bitPattern: 0x3FC7_4664_96CB_03DE)
        // 1.531383769920937332e-01
        let lp6 = Double(bitPattern: 0x3FC3_9A09_D078_C69F)
        // 1.479819860511658591e-01
        let lp7 = Double(bitPattern: 0x3FC2_F112_DF3E_5244)
        // 0.66666666666666666 — identical to 2.0/3.0 either way, checked.
        let twoThirds = Double(bitPattern: 0x3FE5_5555_5555_5555)

        // Special cases. `x < -1 || IsNaN(x)` share one `return NaN()`, so a NaN
        // argument comes back with **Go's** payload, not its own.
        if x < -1 || x.isNaN { return goNaN }
        if x == -1 { return -.infinity }
        if x == .infinity { return .infinity }

        let absx = abs(x)

        var f = 0.0
        var iu: UInt64 = 0
        var k = 1
        if absx < sqrt2M1 {
            if absx < small {
                if absx < tiny { return x }
                // Fused (`FMSUBD`), but provably unobservable: `0.5` is a power of
                // two and `x*x` is nowhere near subnormal on this branch, so the
                // halving is exact whichever way round it happens.
                return x.addingProduct(-(x * x), 0.5)
            }
            if x > sqrt2HalfM1 {
                k = 0
                f = x
                iu = 1
            }
        }

        var c = 0.0
        if k != 0 {
            var u: Double
            if absx < two53 {
                u = 1.0 + x
                iu = u.bitPattern
                // Go: `int((iu >> 52) - 1023)`, where the subtraction wraps in
                // `uint64` for a small exponent and the `int` conversion
                // reinterprets it. Swift's `UInt64` subtraction traps instead, so
                // convert first — two's complement makes the two identical.
                //
                // `u` cannot be negative (`x > -1` is guaranteed above) nor
                // subnormal (the nearest double to -1 is -1+2**-53, so the closest
                // `u` gets to zero is 2**-53), so the shift really is the biased
                // exponent.
                k = Int(iu >> 52) - 1023
                // Correction term for the rounding of `1+x`.
                if k > 0 {
                    c = 1.0 - (u - x)
                } else {
                    c = x - (u - 1.0)
                }
                c /= u
            } else {
                u = x
                iu = u.bitPattern
                k = Int(iu >> 52) - 1023
                c = 0
            }
            iu &= 0x000F_FFFF_FFFF_FFFF
            if iu < 0x0006_A09E_667F_3BCD {  // mantissa of Sqrt(2)
                u = Double(bitPattern: iu | 0x3FF0_0000_0000_0000)  // normalize u
            } else {
                k += 1
                u = Double(bitPattern: iu | 0x3FE0_0000_0000_0000)  // normalize u/2
                iu = (0x0010_0000_0000_0000 - iu) >> 2
            }
            f = u - 1.0  // Sqrt(2)/2 < u < Sqrt(2)
        }

        // Go: `hfsq := 0.5 * f * f`, left-associated. Only `0.5*f` survives as a
        // rounded value in every reader; whether the second multiply is rounded
        // depends on which reader, so both forms are kept.
        //
        // The association is *not* load-bearing here, unusually: `0.5*f` is exact
        // and `f` is bounded away from subnormal, so `0.5*(f*f)` gives the same
        // bits. Go's spelling is kept anyway.
        let halfF = 0.5 * f
        let hfsq = halfF * f
        let kd = Double(k)

        if iu == 0 {  // |f| < 2**-20
            if f == 0 {
                if k == 0 { return 0 }
                c = c.addingProduct(kd, ln2Lo)
                return c.addingProduct(kd, ln2Hi)
            }
            // Go: `R = hfsq * (1.0 - 0.66666666666666666*f)`, and `R` is never
            // materialised — its multiply is fused into each of the two readers
            // below. The inner subtraction is fused too.
            let inner = (1.0).addingProduct(-f, twoThirds)
            if k == 0 {
                // f - hfsq*inner
                return f.addingProduct(-hfsq, inner)
            }
            // R - (k*Ln2Lo + c), then - f, then k*Ln2Hi - that.
            let kLn2LoPlusC = c.addingProduct(kd, ln2Lo)
            var d = (-kLn2LoPlusC).addingProduct(hfsq, inner)
            d -= f
            return (-d).addingProduct(kd, ln2Hi)
        }

        let s = f / (2.0 + f)
        let z = s * s
        var poly = lp6.addingProduct(z, lp7)
        poly = lp5.addingProduct(z, poly)
        poly = lp4.addingProduct(z, poly)
        poly = lp3.addingProduct(z, poly)
        poly = lp2.addingProduct(z, poly)
        poly = lp1.addingProduct(z, poly)
        let r = z * poly

        // `hfsq + R` with `hfsq` recomputed UNROUNDED — see the file header. Both
        // returns below spell it this way; they differ in the *outer* `hfsq`.
        let hfsqPlusR = r.addingProduct(halfF, f)

        if k == 0 {
            // The outer `hfsq` here is the rounded value: it is still live in F4.
            let d = hfsq.addingProduct(-s, hfsqPlusR)
            return f - d
        }
        // Here `float64(k)` has taken the rounded `hfsq`'s register, so the outer
        // `hfsq` is recomputed unrounded as well. Two lines apart in Go's source,
        // two different roundings.
        let kLn2LoPlusC = c.addingProduct(kd, ln2Lo)
        let inner = kLn2LoPlusC.addingProduct(s, hfsqPlusR)
        var d = (-inner).addingProduct(halfF, f)
        d -= f
        return (-d).addingProduct(kd, ln2Hi)
    }

    // MARK: - Sinh, Cosh

    /// Go: `sinh`'s P coefficients — Hart & Cheney #2029 (20.36D).
    @usableFromInline static let sinhP: [Double] = [
        Double(bitPattern: 0xC123_3FDE_BA64_BB4F),  // -0.6307673640497716991184787251e+6
        Double(bitPattern: 0xC0F5_F38B_8605_D22D),  // -0.8991272022039509355398013511e+5
        Double(bitPattern: 0xC0A6_9C6C_36DA_2DFB),  // -0.2894211355989563807284660366e+4
        Double(bitPattern: 0xC03A_4E3D_E854_0779),  // -0.2630563213397497062819489e+2
    ]

    /// Go: `sinh`'s Q coefficients. `Q0` is a different decimal from `P0` that
    /// rounds to the same `Double`; Go's compiler loads one constant for both.
    @usableFromInline static let sinhQ: [Double] = [
        Double(bitPattern: 0xC123_3FDE_BA64_BB4F),  // -0.6307673640497716991212077277e+6
        Double(bitPattern: 0x40CD_B796_3EAE_91E1),  // 0.1521517378790019070696485176e+5
        Double(bitPattern: 0xC065_B5B9_FCD0_03BB),  // -0.173678953558233699533450911e+3
    ]

    /// Go: `math.Sinh` — the hyperbolic sine.
    ///
    /// Special cases: `Sinh(±0) = ±0`, `Sinh(±Inf) = ±Inf`, `Sinh(NaN) = NaN`.
    /// None of them is an explicit branch: `±0` falls out of the rational (whose
    /// numerator carries a factor of `x`), and `±Inf` and `NaN` out of
    /// ``exp(_:)``'s and the rational's own propagation respectively. So a NaN
    /// argument keeps **its own** payload here.
    public static func sinh(_ x: Double) -> Double {
        let p = sinhP
        let q = sinhQ

        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }

        var temp: Double
        // `x > 21` is a pure optimisation, not a behavioural boundary: by the time
        // `Exp(x)` reaches 1.3e9, `1/Exp(x)` is far below half an ULP of it, so the
        // two branches agree for every x at or above 21. Verified by a negative
        // control, which stays green with the comparison changed to `>=`.
        if x > 21 {
            temp = exp(x) * 0.5
        } else if x > 0.5 {
            let ex = exp(x)
            temp = (ex - 1 / ex) * 0.5
        } else {
            let sq = x * x

            // (((P3*sq+P2)*sq+P1)*sq + P0) * x — three fused adds, then a plain
            // multiply by x rather than by sq.
            var num = p[2].addingProduct(p[3], sq)
            num = p[1].addingProduct(num, sq)
            num = p[0].addingProduct(num, sq)
            num = x * num

            // ((sq+Q2)*sq+Q1)*sq + Q0. The leading term is emitted as
            // `fma(x, x, Q2)` — the square recomputed UNROUNDED, even though `sq`
            // is in a register and the two later terms use it. Same compiler
            // behaviour as `tan`'s and `xatan`'s denominators.
            //
            // Undoing *this* one is invisible in 34,000,052 inputs, because it is
            // the leading term of the chain and |sq| <= 0.25 against |Q2| ~ 174
            // dilutes it below the final rounding — where `xatan`'s identical site
            // is loudly observable. Spelled as the disassembly has it regardless;
            // the two later terms are what the corpus witnesses.
            var den = q[2].addingProduct(x, x)
            den = q[1].addingProduct(den, sq)
            den = q[0].addingProduct(den, sq)

            temp = num / den
        }

        if sign {
            temp = -temp
        }
        return temp
    }

    /// Go: `math.Cosh` — the hyperbolic cosine.
    ///
    /// Special cases: `Cosh(±0) = 1`, `Cosh(±Inf) = +Inf`, `Cosh(NaN) = NaN`.
    ///
    /// Nothing is fused: both products in it are divisions or a multiply by `0.5`
    /// with no neighbouring add. It still cannot use libm's `cosh`, because
    /// ``exp(_:)`` is not libm's `exp` — 13.6% of inputs differ, which is entirely
    /// inherited.
    public static func cosh(_ x: Double) -> Double {
        // Go: `x = Abs(x)`, which clears the sign bit of a NaN too, so
        // `Cosh(-NaN)` is positive.
        let x = abs(x)
        if x > 21 {
            return exp(x) * 0.5
        }
        let ex = exp(x)
        return (ex + 1 / ex) * 0.5
    }

    // MARK: - Tanh

    /// Go: `tanhP` — Cephes `tanh.c`, the Cody & Waite `x + x**3 P(x)/Q(x)` form.
    @usableFromInline static let tanhP: [Double] = [
        Double(bitPattern: 0xBFEE_DC5B_AAFD_6F4B),  // -9.64399179425052238628e-1
        Double(bitPattern: 0xC058_D26A_0E26_682D),  // -9.92877231001918586564e1
        Double(bitPattern: 0xC099_3AC0_3058_0563),  // -1.61468768441708447952e3
    ]

    /// Go: `tanhQ`.
    @usableFromInline static let tanhQ: [Double] = [
        Double(bitPattern: 0x405C_33F2_8A58_1B86),  // 1.12811678491632931402e2
        Double(bitPattern: 0x40A1_76FA_0E55_35FA),  // 2.23548839060100448583e3
        Double(bitPattern: 0x40B2_EC10_2442_040C),  // 4.84406305325125486048e3
    ]

    /// Go: `math.Tanh` — the hyperbolic tangent.
    ///
    /// Special cases: `Tanh(±0) = ±0`, `Tanh(±Inf) = ±1`, `Tanh(NaN) = NaN`. The
    /// infinities go through the `z > MAXLOG/2` branch, which returns a literal
    /// `±1` rather than computing anything; NaN falls all the way to the rational
    /// and propagates its own payload.
    public static func tanh(_ x: Double) -> Double {
        let p = tanhP
        let q = tanhQ
        // 0.5*MAXLOG where MAXLOG = 8.8029691931113054295988e+01 = log(2**127).
        // Halving is exact, so the folded constant and the naive one agree.
        let halfMaxLog = Double(bitPattern: 0x4046_01E6_78FC_457B)

        var z = abs(x)
        if z > halfMaxLog {
            return x < 0 ? -1 : 1
        }
        if z >= 0.625 {
            // Go writes `Exp(2 * z)`; the compiler emits `FADDD z, z`, which is
            // the same value exactly — doubling is exact, so this is a spelling
            // choice and nothing more. Written as the disassembly has it.
            let s = exp(z + z)
            z = 1 - 2 / (s + 1)
            if x < 0 {
                z = -z
            }
            return z
        }
        if x == 0 {
            return x  // Preserves ±0.
        }

        let s = x * x
        // x + (x*s)*P(s)/Q(s), with the grouping the source's: `x*s*(…)` is
        // `(x*s)*(…)`, and the division binds tighter than the leading `x +`.
        var num = p[1].addingProduct(p[0], s)
        num = p[2].addingProduct(num, s)
        num = (x * s) * num

        // `s + tanhQ[0]` is emitted as `fma(x, x, tanhQ[0])` — the same unrounded
        // recomputation as `sinh`'s denominator.
        var den = q[0].addingProduct(x, x)
        den = q[1].addingProduct(den, s)
        den = q[2].addingProduct(den, s)

        // Plain `FADDD`: the divide result is not a product, so there is nothing to
        // fuse into the leading `x +`.
        return x + num / den
    }

    // MARK: - Asinh, Acosh, Atanh

    /// Go: `math.Ln2`, and `asinh`'s own locally spelled `Ln2` — a different
    /// decimal that rounds to the same `Double`, checked.
    /// 0.693147180559945309417232121458176568
    @usableFromInline static let ln2 = Double(bitPattern: 0x3FE6_2E42_FEFA_39EF)

    /// 2**-28 — `asinh`'s and `atanh`'s `NearZero`.
    @usableFromInline static let nearZero2Pow28 = Double(bitPattern: 0x3E30_0000_0000_0000)
    /// 2**28 — `asinh`'s and `acosh`'s `Large`.
    @usableFromInline static let large2Pow28 = Double(bitPattern: 0x41B0_0000_0000_0000)

    /// Go: `math.Asinh` — the inverse hyperbolic sine.
    ///
    /// Special cases: `Asinh(±0) = ±0`, `Asinh(±Inf) = ±Inf`, `Asinh(NaN) = NaN`,
    /// all three by the explicit `return x` at the top, so a NaN argument keeps its
    /// own payload.
    public static func asinh(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return x }

        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }

        var temp: Double
        if x > large2Pow28 {
            temp = log(x) + ln2
        } else if x > 2 {
            // Log(2*x + 1/(Sqrt(x*x+1)+x)). `x*x+1` is fused; `2*x` is `x+x`.
            let root = (1.0).addingProduct(x, x).squareRoot()
            temp = log((x + x) + 1 / (root + x))
        } else if x < nearZero2Pow28 {
            temp = x
        } else {
            // Log1p(x + x*x/(1+Sqrt(1+x*x))). Note the two `x*x` on this one line
            // compile differently: the one under the Sqrt is fused into its `+ 1`,
            // the numerator's is a plain rounded multiply.
            let root = (1.0).addingProduct(x, x).squareRoot()
            temp = log1p(x + (x * x) / (1 + root))
        }

        if sign {
            temp = -temp
        }
        return temp
    }

    /// Go: `math.Acosh` — the inverse hyperbolic cosine.
    ///
    /// Special cases: `Acosh(+Inf) = +Inf`, `Acosh(x) = NaN` for `x < 1`,
    /// `Acosh(NaN) = NaN`. The last two share one `return NaN()`, so **Go's**
    /// payload is what comes back either way — `Double.nan` would be wrong, and
    /// that alone is 1,307,450 of the 1,334,959 inputs where libm's `acosh`
    /// disagrees.
    public static func acosh(_ x: Double) -> Double {
        if x < 1 || x.isNaN { return goNaN }
        if x == 1 { return 0 }
        if x >= large2Pow28 { return log(x) + ln2 }
        if x > 2 {
            // Log(2*x - 1/(x+Sqrt(x*x-1))). `x*x-1` is fused (`FNMSUBD`).
            let root = (-1.0).addingProduct(x, x).squareRoot()
            return log((x + x) - 1 / (x + root))
        }
        let t = x - 1
        // Log1p(t + Sqrt(2*t+t*t)). `t*t` is fused into `2*t`, itself `t+t`.
        let root = (t + t).addingProduct(t, t).squareRoot()
        return log1p(t + root)
    }

    /// Go: `math.Atanh` — the inverse hyperbolic tangent.
    ///
    /// Special cases: `Atanh(1) = +Inf`, `Atanh(-1) = -Inf`, `Atanh(±0) = ±0`,
    /// `Atanh(x) = NaN` for `|x| > 1`, `Atanh(NaN) = NaN`. As in ``acosh(_:)``, the
    /// out-of-domain and NaN cases share one `return NaN()` and both carry Go's
    /// payload.
    ///
    /// Nothing is fused: each product is immediately divided.
    public static func atanh(_ x: Double) -> Double {
        if x < -1 || x > 1 || x.isNaN { return goNaN }
        if x == 1 { return .infinity }
        if x == -1 { return -.infinity }

        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }

        var temp: Double
        if x < nearZero2Pow28 {
            temp = x
        } else if x < 0.5 {
            temp = x + x
            temp = 0.5 * log1p(temp + temp * x / (1 - x))
        } else {
            temp = 0.5 * log1p((x + x) / (1 - x))
        }

        if sign {
            temp = -temp
        }
        return temp
    }
}
