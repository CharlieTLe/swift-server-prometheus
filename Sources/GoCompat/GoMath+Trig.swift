//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/math @ go1.26.5 — sin.go (Sin, Cos), tan.go,
// trig_reduce.go, asin.go (Asin, Acos), atan.go (xatan, satan, Atan) and
// log10.go.
//
// **None of these can be delegated to libm, and the divergence is not rare.**
// Measured against Go over 2,000,052 inputs per function (structured boundaries
// plus random values across the whole exponent range):
//
//   | function | inputs where Swift's libm differs from Go |
//   |---|---|
//   | `Sin`   | 466,199 (23%) |
//   | `Cos`   | 573,768 (29%) |
//   | `Tan`   | 817,377 (41%) |
//   | `Asin`  | 1,338,076 (67%) |
//   | `Acos`  | 1,258,393 (63%) |
//   | `Atan`  | 296,632 (15%) |
//   | `Log10` | 1,294,745 (65%) |
//
// For comparison, `Abs`, `Ceil`, `Floor` and `Sqrt` agree on all 2,000,052 —
// they are hardware instructions on both sides, and the port keeps using Swift's.
//
// Part of the divergence is the NaN payload: Go's `math.NaN()` is
// `0x7FF8000000000001` and Swift's `Double.nan` is `0x7FF8000000000000`, so every
// out-of-domain input differs on its own. But most of it is genuine one-ULP
// disagreement on ordinary finite inputs — `Asin(0.5)`, `Atan(0.5)`, `Sin(2)`,
// `Cos(Pi/2)`, `Tan(Pi)` all differ.
//
// `haveArchSin` and its siblings are true only on **s390x** (math/arith_s390x.go
// against math/stubs.go), so on arm64 and amd64 the portable Go below is what
// runs. That is the opposite of `Exp`/`Exp2`/`Min`/`Max`, and it is why this file
// transcribes Go source rather than assembly.
//
// ## Fusion
//
// Derived from `go tool objdump` per function, not guessed. Every `a*b + c` and
// `c - a*b` in these routines is fused — the argument reduction, both Cephes
// polynomials, the rational numerators and denominators, and every final
// accumulation.
//
// "It is fused" is a claim, and a claim needs a failing case to be a tested one.
// Each site was unfused on its own and 12,000,000 inputs searched for a changed
// result; the observable ones have **harvested witnesses** committed in the
// corpora (`oracle/suites_gomath_trig.go`), so undoing any of them fails loudly.
// The classification, because re-deriving it is expensive:
//
// | site | observable |
// |---|---|
// | `y*PI4A`, `y*PI4B` | **never** — provably. `y` is an integer below 2**30 and the constants carry 22 and 21 significant bits, so both products fit in 53 bits exactly. That is what splitting Pi/4 into three parts is *for*. |
// | `y*PI4C` | yes — 3 witnesses. Full-precision constant, so the product is not exact. |
// | `_sin[0..2]`, `_cos[0..2]` polynomial terms | not in 12,000,000 inputs — diluted below the final rounding, as in `log`'s chains |
// | `1.0 - 0.5*zz` | not in 12,000,000 inputs |
// | `_sin[3..4]`, `_cos[3..4]`, both final accumulations | yes — witnessed |
// | `tan`'s numerator, `_tanQ[2..4]`, final accumulation | yes — witnessed |
// | `tan`'s `zz + _tanQ[1]` | not in 12,000,000 inputs, *either* fused-unrounded or plain. Spelled as the disassembly has it anyway; see below. |
// | all eleven of `xatan`'s sites | yes — witnessed. The most fusion-sensitive routine here. |
// | `asin`'s `1 - x*x` | yes — witnessed |
// | `satan`'s `Pi/2 - xatan(1/x) + Morebits` | Go does **not** fuse it, and fusing it changes nothing in 12,000,000 inputs. Left unfused to match. |
//
// One site is not a local reading of the source, and it is the same phenomenon as
// `quantile.go`'s `rank` (PORTING.md quirk 29): **where a polynomial's leading
// term is `z + const` and `z` is itself a product, the compiler fuses the product
// into that add, recomputing it UNROUNDED.** Two places:
//
//   * `xatan`: `z + Q0` is `fma(x, x, Q0)`. **Observable** — `0xbfe1383384b20da8`
//     distinguishes it both from reusing the rounded `z` and from an unfused
//     `x*x + Q0`.
//   * `tan`: `zz + _tanQ[1]` is `fma(z, z, _tanQ[1])`, even though the rounded
//     `zz` sits in a register and every *other* term of the same denominator uses
//     it. Not observable by search — but it is the same compiler behaviour, so the
//     port spells it the same way rather than relying on the search's silence.
//
// Spelling either as `zz + _tanQ[1]` compiles and looks like the Go source.
//
// Constants are written as bit patterns with Go's decimal in the comment. `4/Pi`,
// `Pi/2`, `Pi/4` and `0.5*Morebits` were each checked against Go's
// arbitrary-precision fold: all four happen to be identical to the naive two-step
// Swift computation, unlike `1/Ln10`, which is one ULP out and is hard-coded.
//===----------------------------------------------------------------------===//

extension GoMath {

    // MARK: - Shared constants

    /// Go: `math.Pi`, as `4/Pi` folded at arbitrary precision then rounded.
    /// Checked: identical to `4.0 / Double.pi`.
    /// 1.2732395447351628
    @usableFromInline static let fourOverPi = Double(bitPattern: 0x3FF4_5F30_6DC9_C883)

    /// Go: `Pi/4` split into three parts, so that `y*PI4A` and `y*PI4B` are exact
    /// for the `y` this reduction produces. Only `y*PI4C` carries a rounding — and
    /// it is fused, which is what makes the fusion observable at all.
    /// 7.85398125648498535156e-1
    @usableFromInline static let pi4A = Double(bitPattern: 0x3FE9_21FB_4000_0000)
    /// 3.77489470793079817668e-8
    @usableFromInline static let pi4B = Double(bitPattern: 0x3E64_442D_0000_0000)
    /// 2.69515142907905952645e-15
    @usableFromInline static let pi4C = Double(bitPattern: 0x3CE8_4698_98CC_5170)

    /// Go: `math.Pi/2`, folded at arbitrary precision. Exact halving, so identical
    /// to `Double.pi / 2`.
    @usableFromInline static let piOver2 = Double(bitPattern: 0x3FF9_21FB_5444_2D18)
    /// Go: `math.Pi/4`.
    @usableFromInline static let piOver4 = Double(bitPattern: 0x3FE9_21FB_5444_2D18)

    /// Go: `math.NaN()` — `0x7FF8000000000001`, **not** Swift's `Double.nan`.
    ///
    /// The payload is observable: it is what every out-of-domain result carries,
    /// and `promqltest` renders results as text. Same value as
    /// `PromValue.normalNaNBits`, which is Prometheus's name for Go's NaN.
    @usableFromInline static let goNaN = Double(bitPattern: 0x7FF8_0000_0000_0001)

    /// Go: `reduceThreshold` (trig_reduce.go) — above this, the Pi/4 split is not
    /// accurate enough and Payne–Hanek reduction takes over.
    @usableFromInline static let reduceThreshold = Double(1 << 29)

    /// Go: `_sin` — the Cephes sine coefficients, most significant last.
    @usableFromInline static let sinCoefficients: [Double] = [
        Double(bitPattern: 0x3DE5_D8FD_1FD1_9CCD),  // 1.58962301576546568060e-10
        Double(bitPattern: 0xBE5A_E5E5_A929_1F5D),  // -2.50507477628578072866e-8
        Double(bitPattern: 0x3EC7_1DE3_567D_48A1),  // 2.75573136213857245213e-6
        Double(bitPattern: 0xBF2A_01A0_19BF_DF03),  // -1.98412698295895385996e-4
        Double(bitPattern: 0x3F81_1111_1110_F7D0),  // 8.33333333332211858878e-3
        Double(bitPattern: 0xBFC5_5555_5555_5548),  // -1.66666666666666307295e-1
    ]

    /// Go: `_cos` — the Cephes cosine coefficients.
    @usableFromInline static let cosCoefficients: [Double] = [
        Double(bitPattern: 0xBDA8_FA49_A086_1A9B),  // -1.13585365213876817300e-11
        Double(bitPattern: 0x3E21_EE9D_7B4E_3F05),  // 2.08757008419747316778e-9
        Double(bitPattern: 0xBE92_7E4F_7EAC_4BC6),  // -2.75573141792967388112e-7
        Double(bitPattern: 0x3EFA_01A0_19C8_44F5),  // 2.48015872888517045348e-5
        Double(bitPattern: 0xBF56_C16C_16C1_4F91),  // -1.38888888888730564116e-3
        Double(bitPattern: 0x3FA5_5555_5555_554B),  // 4.16666666666665929218e-2
    ]

    // MARK: - Sin, Cos

    /// Go: `math.Sin` — the sine of the radian argument.
    ///
    /// Special cases: `Sin(±0) = ±0`, `Sin(±Inf) = NaN`, `Sin(NaN) = NaN`. Note
    /// the first and last are `return x`, so a NaN argument comes back with **its
    /// own** payload rather than Go's — unlike `Cos`, which returns `NaN()`.
    public static func sin(_ x: Double) -> Double {
        // sin.go:198 — `x == 0 || IsNaN(x)` returns x, which preserves both the
        // sign of zero and the argument's NaN payload.
        if x == 0 || x.isNaN {
            return x
        }
        if x.isInfinite {
            return goNaN
        }

        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }

        var j: UInt64
        var y = 0.0
        var z = 0.0
        if x >= reduceThreshold {
            (j, z) = trigReduce(x)
        } else {
            // The conversion cannot saturate: x is finite, non-negative and below
            // 2**29 here, so the product is under 7e8. Go's FCVTZUD would saturate;
            // Swift's `UInt64(_:)` would trap, and neither happens.
            j = UInt64(x * fourOverPi)
            y = Double(j)
            // Map zeros to origin.
            if j & 1 == 1 {
                j += 1
                y += 1
            }
            j &= 7
            z = extendedReduce(x, y)
        }

        // Reflect in the x axis.
        if j > 3 {
            sign = !sign
            j -= 4
        }

        let zz = z * z
        if j == 1 || j == 2 {
            y = cosPolynomial(zz)
        } else {
            y = sinPolynomial(z, zz)
        }
        if sign {
            y = -y
        }
        return y
    }

    /// Go: `math.Cos` — the cosine of the radian argument.
    ///
    /// Special cases: `Cos(±Inf) = NaN`, `Cos(NaN) = NaN`. Both return Go's
    /// `NaN()`, so a NaN argument's payload is **replaced** here where `Sin` keeps
    /// it. Not a symmetry worth tidying: `Cos(NaN)` is `0x7FF8000000000001` in Go
    /// whatever came in.
    public static func cos(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite {
            return goNaN
        }

        var sign = false
        // sin.go:135 — `x = Abs(x)`, with the sign discarded rather than saved,
        // because cosine is even.
        let x = abs(x)

        var j: UInt64
        var y = 0.0
        var z = 0.0
        if x >= reduceThreshold {
            (j, z) = trigReduce(x)
        } else {
            j = UInt64(x * fourOverPi)
            y = Double(j)
            if j & 1 == 1 {
                j += 1
                y += 1
            }
            j &= 7
            z = extendedReduce(x, y)
        }

        if j > 3 {
            j -= 4
            sign = !sign
        }
        if j > 1 {
            sign = !sign
        }

        let zz = z * z
        // The branches are the opposite way round from `sin`'s, which is the whole
        // difference between the two functions once the octant is known.
        if j == 1 || j == 2 {
            y = sinPolynomial(z, zz)
        } else {
            y = cosPolynomial(zz)
        }
        if sign {
            y = -y
        }
        return y
    }

    /// Go: `z = ((x - y*PI4A) - y*PI4B) - y*PI4C`, the extended-precision modular
    /// arithmetic shared by `sin`, `cos` and `tan`.
    ///
    /// All three subtractions are **fused** (`FMSUBD` ×3 at sin.go:227,
    /// sin.go:155, tan.go:124). `y*PI4A` and `y*PI4B` are exact — both constants
    /// carry only 32 significant bits — so those two fusions cannot be observed;
    /// `y*PI4C` is not, so that one can.
    @inlinable
    static func extendedReduce(_ x: Double, _ y: Double) -> Double {
        var z = x.addingProduct(-y, pi4A)
        z = z.addingProduct(-y, pi4B)
        z = z.addingProduct(-y, pi4C)
        return z
    }

    /// Go: `z + z*zz*(<_sin polynomial>)`.
    ///
    /// Five fused multiply-adds for the polynomial and one more for the final
    /// accumulation; only `z*zz` is a plain multiply. Written as statements rather
    /// than one expression because a chain this long blows the Swift 6.1 type
    /// checker's budget — see docs/HANDOFF.md §4.
    @inlinable
    static func sinPolynomial(_ z: Double, _ zz: Double) -> Double {
        let c = sinCoefficients
        var p = c[1].addingProduct(c[0], zz)
        p = c[2].addingProduct(p, zz)
        p = c[3].addingProduct(p, zz)
        p = c[4].addingProduct(p, zz)
        p = c[5].addingProduct(p, zz)
        let zzz = z * zz
        return z.addingProduct(zzz, p)
    }

    /// Go: `1.0 - 0.5*zz + zz*zz*(<_cos polynomial>)`.
    ///
    /// `1.0 - 0.5*zz` is fused, `zz*zz` is a plain multiply, the polynomial is five
    /// fused multiply-adds, and the final add is fused.
    @inlinable
    static func cosPolynomial(_ zz: Double) -> Double {
        let c = cosCoefficients
        var p = c[1].addingProduct(c[0], zz)
        p = c[2].addingProduct(p, zz)
        p = c[3].addingProduct(p, zz)
        p = c[4].addingProduct(p, zz)
        p = c[5].addingProduct(p, zz)
        let head = (1.0).addingProduct(-0.5, zz)
        return head.addingProduct(zz * zz, p)
    }

    // MARK: - Payne–Hanek reduction

    /// Go: `mPi4` — the binary digits of 4/Pi, as 64-bit limbs.
    @usableFromInline static let mPi4: [UInt64] = [
        0x0000_0000_0000_0001,
        0x45f3_06dc_9c88_2a53,
        0xf84e_afa3_ea69_bb81,
        0xb6c5_2b32_7887_2083,
        0xfca2_c757_bd77_8ac3,
        0x6e48_dc74_849b_a5c0,
        0x0c92_5dd4_13a3_2439,
        0xfc3b_d639_6253_4e7d,
        0xd104_6bea_5d76_8909,
        0xd338_e04d_68be_fc82,
        0x7323_ac73_06a6_73e9,
        0x3908_bf17_7bf2_5076,
        0x3ff1_2fff_bc0b_301f,
        0xde5e_2316_b414_da3e,
        0xda6c_fd9e_4f96_136e,
        0x9e8c_7ecd_3cbf_d45a,
        0xea4f_758f_d7cb_e2f6,
        0x7a0e_73ef_14a5_25d4,
        0xd7f6_bf62_3f1a_ba10,
        0xac06_608d_f8f6_d757,
    ]

    /// Go: `trigReduce` — Payne–Hanek argument reduction for `|x| >= 2**29`, where
    /// the three-part Pi/4 split runs out of precision.
    ///
    /// Returns the octant `j` and the reduced argument `z`. Integer arithmetic
    /// throughout, so there is nothing to fuse: the disassembly's only float
    /// operations are the `z--` at trig_reduce.go:71 and the `z * PI4` at :74.
    ///
    /// One Swift/Go agreement worth stating, because it is load-bearing and
    /// silent: `bitshift` is `(exp+61) % 64` and **can be 0**, which makes the
    /// three `>> (64 - bitshift)` shifts a shift by 64. Go defines an
    /// over-wide shift as 0, and Swift's `>>` is a "smart shift" that also yields
    /// 0 — but `&>>`, the masking shift, would give the *unshifted* value instead.
    /// Do not "optimise" these into `&>>`.
    @usableFromInline
    static func trigReduce(_ x: Double) -> (j: UInt64, z: Double) {
        let pi4 = piOver4
        if x < pi4 {
            return (0, x)
        }
        // x = ix * 2**exp.
        var ix = x.bitPattern
        let exp = Int((ix >> UInt64(shift)) & UInt64(mask)) - bias - shift
        ix &= ~(UInt64(mask) << UInt64(shift))
        ix |= 1 << UInt64(shift)

        // Three limbs of 4/Pi such that the product's leading digit has exponent
        // -61. `exp >= -53` because x >= Pi/4, and `exp < 971` for any finite
        // Double, so `digit + 3` stays inside mPi4's twenty entries.
        let digit = UInt(exp + 61) / 64
        let bitshift = UInt64(UInt(exp + 61) % 64)
        let d = Int(digit)
        let z0 = (mPi4[d] << bitshift) | (mPi4[d + 1] >> (64 - bitshift))
        let z1 = (mPi4[d + 1] << bitshift) | (mPi4[d + 2] >> (64 - bitshift))
        let z2 = (mPi4[d + 2] << bitshift) | (mPi4[d + 3] >> (64 - bitshift))

        // Go: bits.Mul64 / bits.Add64.
        let (z2hi, _) = z2.multipliedFullWidth(by: ix)
        let (z1hi, z1lo) = z1.multipliedFullWidth(by: ix)
        let z0lo = z0 &* ix
        let (lo, carry) = z1lo.addingReportingOverflow(z2hi)
        var hi = z0lo &+ UInt64(z1hi) &+ (carry ? 1 : 0)

        // The top three bits are the octant.
        var j = hi >> 61
        hi = (hi << 3) | (lo >> 61)
        let lz = UInt64(hi.leadingZeroBitCount)
        let e = UInt64(bias) - (lz + 1)
        // Clear the implicit mantissa bit and shift into place.
        hi = (hi << (lz + 1)) | (lo >> (64 - (lz + 1)))
        hi >>= UInt64(64 - shift)
        hi |= e << UInt64(shift)
        var z = Double(bitPattern: hi)

        // Map zeros to origin.
        if j & 1 == 1 {
            j += 1
            j &= 7
            z -= 1
        }
        return (j, z * pi4)
    }

    // MARK: - Tan

    /// Go: `_tanP`.
    @usableFromInline static let tanP: [Double] = [
        Double(bitPattern: 0xC0C9_92D8_D24F_3F38),  // -1.30936939181383777646e4
        Double(bitPattern: 0x4131_99EC_A5FC_9DDD),  // 1.15351664838587416140e6
        Double(bitPattern: 0xC171_1FEA_D329_9176),  // -1.79565251976484877988e7
    ]

    /// Go: `_tanQ`. Index 0 is 1.0 and is never read — the source writes the
    /// leading term as a bare `zz`, which is where the unrounded recomputation
    /// below comes from.
    @usableFromInline static let tanQ: [Double] = [
        1.0,
        Double(bitPattern: 0x40CA_B8A5_EEB3_6572),  // 1.36812963470692954678e4
        Double(bitPattern: 0xC134_27BC_582A_BC96),  // -1.32089234440210967447e6
        Double(bitPattern: 0x4177_D98F_C2EA_D8EF),  // 2.50083801823357915839e7
        Double(bitPattern: 0xC189_AFE0_3CBE_5A31),  // -5.38695755929454629881e7
    ]

    /// Go: `math.Tan` — the tangent of the radian argument.
    ///
    /// Special cases: `Tan(±0) = ±0`, `Tan(±Inf) = NaN`, `Tan(NaN) = NaN`, with the
    /// argument's own NaN payload preserved as in `Sin`.
    public static func tan(_ x: Double) -> Double {
        if x == 0 || x.isNaN {
            return x
        }
        if x.isInfinite {
            return goNaN
        }

        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }

        var j: UInt64
        var y = 0.0
        var z = 0.0
        if x >= reduceThreshold {
            (j, z) = trigReduce(x)
        } else {
            j = UInt64(x * fourOverPi)
            y = Double(j)
            // Map zeros and singularities to origin. Note `j` is NOT masked to 7
            // here as it is in sin/cos. Adding `j &= 7` changes nothing — `tan`
            // only ever tests `j & 2`, which the mask preserves — and it was
            // checked, not assumed. Left off to match the source.
            if j & 1 == 1 {
                j += 1
                y += 1
            }
            z = extendedReduce(x, y)
        }

        let zz = z * z
        if zz > 1e-14 {
            var p = tanP[1].addingProduct(tanP[0], zz)
            p = tanP[2].addingProduct(p, zz)
            let numerator = zz * p

            // THE ONE THAT IS NOT A LOCAL READING OF THE SOURCE. Go writes
            // `(zz + _tanQ[1])`, and the compiler emits `FMADDD` of
            // `_tanQ[1] + z*z` — recomputing the square unrounded, even though the
            // rounded `zz` is in a register and every later term of this same
            // denominator uses it.
            //
            // Not observable: neither this spelling, the rounded `zz + _tanQ[1]`,
            // nor an unfused `z*z + _tanQ[1]` differs on any of 12,000,000 searched
            // inputs, so there is no witness in the corpus. Kept as the
            // disassembly has it because `xatan`'s structurally identical site IS
            // observable, so the silence here is the search's, not the compiler's.
            var q = tanQ[1].addingProduct(z, z)
            q = tanQ[2].addingProduct(q, zz)
            q = tanQ[3].addingProduct(q, zz)
            q = tanQ[4].addingProduct(q, zz)

            y = z.addingProduct(z, numerator / q)
        } else {
            y = z
        }

        if j & 2 == 2 {
            y = -1 / y
        }
        if sign {
            y = -y
        }
        return y
    }

    // MARK: - Asin, Acos, Atan

    /// Go: `xatan`'s P coefficients.
    @usableFromInline static let atanP: [Double] = [
        Double(bitPattern: 0xBFEC_007F_A1F7_2594),  // -8.750608600031904122785e-01
        Double(bitPattern: 0xC030_2854_5B6B_807A),  // -1.615753718733365076637e+01
        Double(bitPattern: 0xC052_C08C_3688_0273),  // -7.500855792314704667340e+01
        Double(bitPattern: 0xC05E_B8BF_2D05_BA25),  // -1.228866684490136173410e+02
        Double(bitPattern: 0xC050_3669_FD28_EC8E),  // -6.485021904942025371773e+01
    ]

    /// Go: `xatan`'s Q coefficients.
    @usableFromInline static let atanQ: [Double] = [
        Double(bitPattern: 0x4038_DBC4_5B14_603C),  // +2.485846490142306297962e+01
        Double(bitPattern: 0x4064_A0DD_43B8_FA25),  // +1.650270098316988542046e+02
        Double(bitPattern: 0x407B_0E18_D2E2_BE3B),  // +4.328810604912902668951e+02
        Double(bitPattern: 0x407E_563F_13B0_49EA),  // +4.853903996359136964868e+02
        Double(bitPattern: 0x4068_519E_FBBD_62EC),  // +1.945506571482613964425e+02
    ]

    /// Go: `xatan` — arctangent of an argument in the range [0, 0.66].
    ///
    /// Every add in both chains is fused, and `z + Q0` is the same unrounded
    /// recomputation as `tan`'s denominator: the compiler emits `fma(x, x, Q0)`
    /// rather than reusing the rounded `z = x*x`.
    @inlinable
    static func xatan(_ x: Double) -> Double {
        let p = atanP
        let q = atanQ
        let z = x * x

        var num = p[1].addingProduct(p[0], z)
        num = p[2].addingProduct(num, z)
        num = p[3].addingProduct(num, z)
        num = p[4].addingProduct(num, z)
        num = z * num

        // `z + Q0`, recomputed unrounded — see the doc comment.
        var den = q[0].addingProduct(x, x)
        den = q[1].addingProduct(den, z)
        den = q[2].addingProduct(den, z)
        den = q[3].addingProduct(den, z)
        den = q[4].addingProduct(den, z)

        let r = num / den
        return x.addingProduct(x, r)
    }

    /// Go: `satan` — arctangent for a non-negative argument, reducing to `xatan`'s
    /// range.
    ///
    /// Note the two reassembly lines are **not** fused and must not be: they are
    /// plain adds and subtracts in the disassembly (atan.go:85, :87), and the
    /// `+ Morebits` term is what makes the reduction accurate.
    @inlinable
    static func satan(_ x: Double) -> Double {
        // pi/2 = PIO2 + Morebits
        let moreBits = Double(bitPattern: 0x3C91_A626_3314_5C07)
        // 0.5*Morebits, folded by Go at arbitrary precision; exact halving, so
        // identical either way.
        let halfMoreBits = Double(bitPattern: 0x3C81_A626_3314_5C07)
        // tan(3*pi/8)
        let tan3pio8 = Double(bitPattern: 0x4003_504F_333F_9DE6)

        if x <= 0.66 {
            return xatan(x)
        }
        if x > tan3pio8 {
            return piOver2 - xatan(1 / x) + moreBits
        }
        return piOver4 + xatan((x - 1) / (x + 1)) + halfMoreBits
    }

    /// Go: `math.Atan` — the arctangent, in radians.
    ///
    /// Special cases: `Atan(±0) = ±0`, `Atan(±Inf) = ±Pi/2`. A NaN argument falls
    /// through `x > 0` to `-satan(-x)` and comes back NaN by propagation, which is
    /// what Go does too.
    public static func atan(_ x: Double) -> Double {
        if x == 0 {
            return x
        }
        if x > 0 {
            return satan(x)
        }
        return -satan(-x)
    }

    /// Go: `math.Asin` — the arcsine, in radians.
    ///
    /// Special cases: `Asin(±0) = ±0`, `Asin(x) = NaN` for `|x| > 1`.
    ///
    /// The one fused site is `1 - x*x` (asin.go:40, `FMSUBD`); the two divisions
    /// and the `Pi/2 -` are plain.
    public static func asin(_ x: Double) -> Double {
        if x == 0 {
            return x  // Preserves ±0.
        }
        var x = x
        var sign = false
        if x < 0 {
            x = -x
            sign = true
        }
        if x > 1 {
            return goNaN
        }

        // Fused: `Sqrt(1 - x*x)`.
        var temp = (1.0).addingProduct(-x, x).squareRoot()
        if x > 0.7 {
            temp = piOver2 - satan(temp / x)
        } else {
            temp = satan(x / temp)
        }

        if sign {
            temp = -temp
        }
        return temp
    }

    /// Go: `math.Acos` — the arccosine, in radians. Literally `Pi/2 - Asin(x)`.
    public static func acos(_ x: Double) -> Double {
        piOver2 - asin(x)
    }

    // MARK: - Log10

    /// Go: `math.Log10` — `Log(x) * (1/Ln10)`.
    ///
    /// `1/Ln10` is a Go untyped constant folded in arbitrary precision. The naive
    /// Swift `1.0 / 2.302585092994046` is `0x3FDBCB7B1526E50D`, **one ULP low**, so
    /// the value is hard-coded. (`1/Ln2`, used by ``log2(_:)``, happens to be
    /// identical either way; only `Ln10` bites.)
    ///
    /// Not fused — the multiply stands alone in the disassembly.
    public static func log10(_ x: Double) -> Double {
        // 0.4342944819032518
        let invLn10 = Double(bitPattern: 0x3FDB_CB7B_1526_E50E)
        return log(x) * invLn10
    }

    /// Go: `math.Atan2` — the angle to `(x, y)`, with the quadrant resolved.
    ///
    /// Nine special cases before any arithmetic, and the order matters: `y == 0` is tested
    /// *before* `x == 0`, so `atan2(0, 0)` is `+0` rather than `π/2`. Every result carries
    /// `y`'s sign through `Copysign`, which is what makes `atan2(-0, -1)` `-π` and
    /// `atan2(+0, -1)` `+π`.
    ///
    /// `Double(signOf:magnitudeOf:)` is `math.Copysign` exactly, NaN payloads included.
    ///
    /// The `y == 0` case's guard is `x >= 0 && !Signbit(x)`, which is belt and braces: `x >= 0`
    /// is already false for `-0`… except that in Go `-0 >= 0` is **true**, so the `Signbit`
    /// test is the one doing the work. Reproduced as written rather than simplified.
    ///
    /// Once the special cases are out of the way it is `Atan(y/x)` plus a quadrant shift, so it
    /// inherits `atan`'s divergence from libm (PORTING.md quirks 39-40): the division rounds
    /// first, then Go's own `satan` runs on the result.
    @inlinable
    public static func atan2(_ y: Double, _ x: Double) -> Double {
        // Special cases, in Go's order.
        if y.isNaN || x.isNaN {
            // `goNaN`, not `Double.nan`: Go's payload is 1 and Swift's is 0, and the payload is
            // observable — 34 corpus cases disagreed on exactly this.
            return goNaN
        }
        if y == 0 {
            if x >= 0 && !(x.sign == .minus) {
                return Double(signOf: y, magnitudeOf: 0)
            }
            return Double(signOf: y, magnitudeOf: Double.pi)
        }
        if x == 0 {
            return Double(signOf: y, magnitudeOf: Double.pi / 2)
        }
        if x.isInfinite {
            if x > 0 {
                if y.isInfinite {
                    return Double(signOf: y, magnitudeOf: Double.pi / 4)
                }
                return Double(signOf: y, magnitudeOf: 0)
            }
            if y.isInfinite {
                return Double(signOf: y, magnitudeOf: 3 * Double.pi / 4)
            }
            return Double(signOf: y, magnitudeOf: Double.pi)
        }
        if y.isInfinite {
            return Double(signOf: y, magnitudeOf: Double.pi / 2)
        }

        // Call atan and determine the quadrant.
        let q = atan(y / x)
        if x < 0 {
            if q <= 0 {
                return q + Double.pi
            }
            return q - Double.pi
        }
        return q
    }

}
