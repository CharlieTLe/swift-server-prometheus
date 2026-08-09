//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/math @ go1.26.5 — pow.go, mod.go, ldexp.go, modf.go,
// dim_arm64.s (archMin/archMax) and floor_arm64.s (archTrunc).
//
// None of these can be delegated to Swift's standard library or to libm:
//
//   * `math.Pow` is **not** libm's `pow`. It is Go's own algorithm — successive
//     squaring for the integer part of the exponent, `Exp(yf * Log(x))` for the
//     fraction, reassembled with `Ldexp` — so it inherits the exact rounding of
//     Go's `Exp` and `Log` rather than the platform's.
//   * `math.Min`/`math.Max` are arm64 **assembly** whose ±Inf short-circuit runs
//     before NaN handling, which makes `Max(+Inf, NaN)` = `+Inf` where the
//     portable Go returns NaN. See ``max(_:_:)``.
//   * `math.Mod` is Go's repeated-`Ldexp` subtraction loop, not `fmod`.
//
// PromQL reaches all of them: `^` and `%` are `Pow` and `Mod`, `min_of`/`max_of`
// duration expressions are `Min`/`Max`, and `promql/functions.go` uses the lot.
//===----------------------------------------------------------------------===//

extension GoMath {

    // MARK: - Min and Max

    /// Go: `math.Max` — the larger of `x` and `y`.
    ///
    /// **Ported from `dim_arm64.s`, not from the portable `math.max`**, and the
    /// two genuinely disagree. `haveArchMax` is true for
    /// `amd64 || arm64 || loong64 || riscv64 || s390x` (math/dim_asm.go), so the
    /// assembly is what runs here.
    ///
    /// The assembly compares each operand's **raw 64-bit pattern** against
    /// `+Inf` and returns `+Inf` on a hit, *before* reaching the `FMAXD` that
    /// would otherwise handle NaN. So `Max(+Inf, NaN)` is `+Inf`, where the
    /// portable implementation's `IsNaN` case would give NaN. Probed against Go
    /// rather than reasoned about: docs/PORTING.md quirk 28.
    ///
    /// `FMAXD` is ARM's `FMAX`, which **propagates** a NaN operand, not `FMAXNM`
    /// and not libm's `fmax`, both of which return the non-NaN operand instead.
    public static func max(_ x: Double, _ y: Double) -> Double {
        if x.bitPattern == positiveInfinityBits || y.bitPattern == positiveInfinityBits {
            return .infinity
        }
        // `FMAXD F0, F1, F0` is `Fd = FMAX(Fn, Fm)` with Fn = F1 = y and
        // Fm = F0 = x, so **y is operand 1**. That ordering is observable: with
        // two different quiet NaNs the result is y's payload, not x's.
        let op1 = y
        let op2 = x
        if let nan = processNaNs(op1, op2) { return nan }
        if op1 == 0 && op2 == 0 {
            // Both are zero, possibly differing in sign. FPMax yields +0 when
            // either operand is +0.
            return op1.sign == .minus ? op2 : op1
        }
        return op1 > op2 ? op1 : op2
    }

    /// Go: `math.Min` — the smaller of `x` and `y`.
    ///
    /// The mirror of ``max(_:_:)``, including the short-circuit: the raw-bits
    /// pre-check is for `-Inf`, so `Min(-Inf, NaN)` is `-Inf` while
    /// `Min(+Inf, NaN)` is NaN.
    public static func min(_ x: Double, _ y: Double) -> Double {
        if x.bitPattern == negativeInfinityBits || y.bitPattern == negativeInfinityBits {
            return -.infinity
        }
        let op1 = y
        let op2 = x
        if let nan = processNaNs(op1, op2) { return nan }
        if op1 == 0 && op2 == 0 {
            // FPMin yields -0 when either operand is -0.
            return op1.sign == .minus ? op1 : op2
        }
        return op1 < op2 ? op1 : op2
    }

    private static let positiveInfinityBits: UInt64 = 0x7ff0_0000_0000_0000
    private static let negativeInfinityBits: UInt64 = 0xfff0_0000_0000_0000
    /// The bit ARM sets to quieten a signalling NaN: the significand's MSB.
    private static let quietBit: UInt64 = 0x0008_0000_0000_0000

    /// ARM's `FPProcessNaNs(op1, op2)`, which `FMIN`/`FMAX` defer to. Nil when
    /// neither operand is a NaN.
    ///
    /// A signalling NaN wins over a quiet one and is quietened; between two quiet
    /// NaNs, operand 1 wins. Prometheus's own stale marker
    /// (`0x7ff0000000000002`) has a clear quiet bit, so the signalling branch is
    /// reachable in practice, not just in theory.
    private static func processNaNs(_ op1: Double, _ op2: Double) -> Double? {
        if isSignallingNaN(op1) { return Double(bitPattern: op1.bitPattern | quietBit) }
        if isSignallingNaN(op2) { return Double(bitPattern: op2.bitPattern | quietBit) }
        if op1.isNaN { return op1 }
        if op2.isNaN { return op2 }
        return nil
    }

    private static func isSignallingNaN(_ x: Double) -> Bool {
        x.isNaN && (x.bitPattern & quietBit) == 0
    }

    // MARK: - Trunc, Modf, Ldexp

    /// Go: `math.Trunc`. On arm64 this is `archTrunc`, a bare `FRINTZD`
    /// (floor_arm64.s), which is exactly IEEE round-toward-zero — so unlike the
    /// rest of this file, the obvious Swift spelling is the faithful one.
    public static func trunc(_ x: Double) -> Double {
        x.rounded(.towardZero)
    }

    /// Go: `math.Modf` — the integer and fractional parts, both carrying `f`'s
    /// sign.
    ///
    /// `Modf(±Inf)` is `(±Inf, NaN)`: the subtraction is `Inf - Inf`. That NaN
    /// comes from the hardware rather than from `math.NaN()`, so its payload is
    /// `0x7ff8000000000000` and matches Go's on the same machine.
    public static func modf(_ f: Double) -> (integer: Double, fractional: Double) {
        let integer = trunc(f)
        // Go: `Copysign(f-integer, f)`.
        let fractional = Double(signOf: f, magnitudeOf: f - integer)
        return (integer, fractional)
    }

    /// Go: `math.Ldexp` — `frac × 2**exp`, the inverse of ``frexp(_:)``.
    ///
    /// `haveArchLdexp` is false everywhere but s390x (math/stubs.go), so this is
    /// the portable implementation.
    public static func ldexp(_ frac: Double, _ exp: Int) -> Double {
        // Special cases. The zero case returns `frac` rather than 0 so that -0
        // keeps its sign.
        if frac == 0 { return frac }
        if frac.isInfinite || frac.isNaN { return frac }

        let (normalized, extraExp) = normalize(frac)
        var exp = exp + extraExp
        var bits = normalized.bitPattern
        exp += Int(bits >> UInt64(shift)) & mask - bias

        if exp < -1075 {
            // Underflow. Go: `Copysign(0, frac)`.
            return Double(signOf: frac, magnitudeOf: 0)
        }
        if exp > 1023 {
            return frac < 0 ? -.infinity : .infinity
        }

        var m = 1.0
        if exp < -1022 {
            // Denormal: shift the exponent into range and scale back by 2**-53.
            exp += 53
            m = 0x1p-53
        }
        bits &= ~(UInt64(mask) << UInt64(shift))
        bits |= UInt64(exp + bias) << UInt64(shift)
        return m * Double(bitPattern: bits)
    }

    // MARK: - Mod

    /// Go: `math.Mod` — the floating-point remainder of `x/y`, with `x`'s sign.
    ///
    /// `haveArchMod` is false outside s390x, so this is Go's portable loop:
    /// repeatedly subtract `y` scaled to `r`'s binade. It is **not** `fmod`;
    /// the results agree on ordinary inputs but this is the one that is pinned.
    public static func mod(_ x: Double, _ y: Double) -> Double {
        if y == 0 || x.isInfinite || x.isNaN || y.isNaN {
            return Double(bitPattern: GoFloat.goNaNBits)
        }
        let y = abs(y)

        let (yfr, yexp) = frexp(y)
        var r = x
        if x < 0 { r = -x }

        while r >= y {
            let (rfr, rexpRaw) = frexp(r)
            var rexp = rexpRaw
            if rfr < yfr { rexp -= 1 }
            r -= ldexp(y, rexp - yexp)
        }
        if x < 0 { r = -r }
        return r
    }

    // MARK: - Pow

    /// Go: `math.isOddInt`.
    ///
    /// The `2**53` guard is not an optimisation: without it, `int64(xi)` on a
    /// value that overflows `Int64` gives an architecture-dependent answer, and
    /// it does so on arm64 (Go issue #57465). Anything that large is an even
    /// integer anyway.
    static func isOddInt(_ x: Double) -> Bool {
        if abs(x) >= 9_007_199_254_740_992.0 {  // 1<<53
            return false
        }
        let (xi, xf) = modf(x)
        return xf == 0 && Int64(xi) & 1 == 1
    }

    /// Go: `math.Pow` — `x**y`.
    ///
    /// `haveArchPow` is false outside s390x, so this is Go's portable algorithm,
    /// and it is **not** libm's `pow`. The integer part of the exponent is
    /// applied by successive squaring in a `(fraction, exponent)` representation,
    /// the fractional part by `Exp(yf * Log(x))`; both of those inherit Go's own
    /// rounding, which the platform's `pow` has no reason to reproduce.
    ///
    /// Pinned by `Fixtures/gocompat/pow.jsonl`.
    public static func pow(_ x: Double, _ y: Double) -> Double {
        // The special cases are FreeBSD's e_pow.c list, in Go's order. Order
        // matters: `Pow(1, NaN)` is 1 because `x == 1` is tested before `IsNaN`,
        // and `Pow(NaN, 0)` is 1 for the same reason.
        if y == 0 || x == 1 { return 1 }
        if y == 1 { return x }
        if x.isNaN || y.isNaN { return Double(bitPattern: GoFloat.goNaNBits) }
        if x == 0 {
            if y < 0 {
                if x.sign == .minus && isOddInt(y) { return -.infinity }
                return .infinity
            }
            // y > 0; y == 0 and y == NaN were handled above.
            if x.sign == .minus && isOddInt(y) { return x }
            return 0
        }
        if y.isInfinite {
            if x == -1 { return 1 }
            if (abs(x) < 1) == (y == .infinity) { return 0 }
            return .infinity
        }
        if x.isInfinite {
            if x == -.infinity {
                // Go: `Pow(1/x, -y)`, i.e. Pow(-0, -y).
                return pow(1 / x, -y)
            }
            if y < 0 { return 0 }
            return .infinity
        }
        if y == 0.5 { return x.squareRoot() }
        if y == -0.5 { return 1 / x.squareRoot() }

        var (yi, yf) = modf(abs(y))
        if yf != 0 && x < 0 { return Double(bitPattern: GoFloat.goNaNBits) }
        if yi >= 9_223_372_036_854_775_808.0 {  // 1<<63
            // yi is a large even integer, so x**yi overflows or underflows for
            // every x except -1 (x == 1 was handled above).
            if x == -1 { return 1 }
            if (abs(x) < 1) == (y > 0) { return 0 }
            return .infinity
        }

        // The answer is a1 * 2**ae.
        var a1 = 1.0
        var ae = 0

        // a1 *= x**yf
        if yf != 0 {
            if yf > 0.5 {
                yf -= 1
                yi += 1
            }
            a1 = GoMath.exp(yf * GoMath.log(x))
        }

        // a1 *= x**yi, by successive squaring, accumulating the powers of two
        // into ae rather than letting them overflow the mantissa.
        var (x1, xe) = frexp(x)
        var i = Int64(yi)
        while i != 0 {
            // Catch xe before it overflows the shift below. Since i is
            // non-zero, ae will take on at least one more xe, and that lower
            // bound already exceeds a float64's exponent range — so the
            // Ldexp at the end will underflow to 0 or overflow to Inf.
            //
            // Go writes the bound as `-1<<12` / `1<<12`; spelled as the value it
            // denotes, because an untyped shift literal in a comparison is an
            // overload-resolution problem the Swift 6.1 type checker charges for
            // (HANDOFF §4).
            if xe < -4096 || 4096 < xe {
                ae += xe
                break
            }
            if i & 1 == 1 {
                a1 *= x1
                ae += xe
            }
            x1 *= x1
            xe <<= 1
            if x1 < 0.5 {
                x1 += x1
                xe -= 1
            }
            i >>= 1
        }

        // if y < 0 the answer is 1/ans — applied to the parts, in this order.
        if y < 0 {
            a1 = 1 / a1
            ae = -ae
        }
        return ldexp(a1, ae)
    }
}
