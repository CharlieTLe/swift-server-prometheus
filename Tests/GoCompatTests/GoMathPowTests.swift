//===----------------------------------------------------------------------===//
// Differential tests: Go's math.Exp / Pow / Mod / Min / Max / Ldexp, and
// time.Duration.Seconds().
//
// None of these can be delegated. Two are arm64 **assembly** whose results libm
// does not reproduce (Exp, and Min/Max), one is an algorithm libm shares nothing
// with but the special-case table (Pow), and one is a two-line split that is not
// the obvious division (Duration.Seconds). Every `@Test` below that names libm or
// the Swift standard library exists to pin a divergence, so that "simplifying"
// GoMath back onto the platform fails loudly instead of silently.
//
// See docs/PORTING.md quirks 0 and 28.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

/// Input shape for the two-operand suites.
struct TwoFloatIn: Decodable, Sendable {
    let x: String
    let y: String
}

/// Output shape for `gocompat/minmax`.
struct MinMaxOut: Decodable, Equatable, Sendable {
    let min: String
    let max: String
}

/// Input shape for `gocompat/ldexp`.
struct LdexpIn: Decodable, Sendable {
    let frac: String
    let exp: Int
}

/// Input shape for `gocompat/duration-seconds`.
struct DurationSecondsIn: Decodable, Sendable {
    let nanos: String
}

func doubleFromHexBits(_ s: String) -> Double {
    Double(bitPattern: UInt64(s, radix: 16)!)
}

func hexBits(_ v: Double) -> String {
    String(format: "%016lx", v.bitPattern)
}

@Suite("Go math routines that are neither Swift's nor libm's")
struct GoMathPowTests {

    // MARK: - Exp

    @Test("Exp matches Go's arm64 assembly on every committed case")
    func expFixtures() throws {
        try Fixtures.check("gocompat/exp.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.exp(doubleFromHexBits(hex)))
        }
    }

    @Test("Exp's special cases and thresholds")
    func expSpecials() {
        #expect(GoMath.exp(0) == 1)
        #expect(GoMath.exp(1) == 2.718281828459045)
        #expect(GoMath.exp(.nan).isNaN)
        #expect(GoMath.exp(.infinity) == .infinity)
        #expect(GoMath.exp(-.infinity) == 0)
        // The Exp thresholds, distinct from Exp2's 1024 / -1074.
        #expect(GoMath.exp(709.7827128933841) == .infinity)
        #expect(GoMath.exp(-745.1332191019412) == 0)
        // Below 2**-28 the assembly short-circuits to 1 + x, which is exact.
        let tiny = 0x1p-40
        #expect(GoMath.exp(tiny) == 1 + tiny)
        // The subnormal result path, where the inlined Ldexp needs its 2**-52
        // scaling. Note -745 is *inside* the underflow threshold yet still
        // returns exactly 0 — e**-745 is below half the smallest subnormal — so
        // the subnormal window is narrower than the threshold suggests. Probed
        // against Go: Exp(-745) is 0 and Exp(-744) is 2 ULP above it.
        #expect(GoMath.exp(-745) == 0)
        #expect(GoMath.exp(-744).bitPattern == 0x0000_0000_0000_0002)
        #expect(GoMath.exp(-710) > 0)
        #expect(GoMath.exp(-710) < Double.leastNormalMagnitude)
    }

    // MARK: - Pow

    @Test("Pow matches Go on every committed case")
    func powFixtures() throws {
        try Fixtures.check("gocompat/pow.jsonl", FixtureCase<TwoFloatIn, String>.self) { input in
            hexBits(GoMath.pow(doubleFromHexBits(input.x), doubleFromHexBits(input.y)))
        }
    }

    @Test("Pow's special-case order is observable")
    func powSpecialOrder() {
        // `y == 0 || x == 1` is tested before `IsNaN`, so both of these are 1
        // rather than NaN. Reordering the switch would be an invisible change to
        // every `NaN ^ 0` in a PromQL query.
        #expect(GoMath.pow(.nan, 0) == 1)
        #expect(GoMath.pow(1, .nan) == 1)
        #expect(GoMath.pow(.nan, 1).isNaN)

        // Signed zero with an odd integer exponent keeps the sign; an even or
        // fractional one does not.
        #expect(GoMath.pow(-0.0, -3) == -.infinity)
        #expect(GoMath.pow(-0.0, -2) == .infinity)
        #expect(GoMath.pow(-0.0, 3).sign == .minus)
        #expect(GoMath.pow(-0.0, 2) == 0)
        #expect(GoMath.pow(-0.0, 2).sign == .plus)

        // Pow(-1, ±Inf) = 1, which is IEEE-754-2008 §9.2.1 and surprises people.
        #expect(GoMath.pow(-1, .infinity) == 1)
        #expect(GoMath.pow(-1, -.infinity) == 1)

        // A finite negative base with a non-integer exponent is NaN — but *which*
        // NaN depends on how the exponent is spelled, because `y == 0.5` and
        // `y == -0.5` are shortcut to Sqrt **before** the `yf != 0 && x < 0`
        // check. So Pow(-2, 0.5) is Sqrt(-2), the hardware NaN with payload 0,
        // while Pow(-2, 0.25) reaches the explicit branch and gets `math.NaN()`
        // with payload 1. I asserted payload 1 for both and the fixture said no;
        // Go confirms the split.
        #expect(GoMath.pow(-2, 0.5).bitPattern == 0x7ff8_0000_0000_0000)
        #expect(GoMath.pow(-2, -0.5).bitPattern == 0x7ff8_0000_0000_0000)
        #expect(GoMath.pow(-2, 0.25).bitPattern == GoFloat.goNaNBits)
    }

    @Test("isOddInt's 2**53 guard")
    func isOddIntGuard() {
        // Above 2**53 every float64 is an even integer, and Go returns false
        // without going near the int64 conversion — which on arm64 would give an
        // architecture-dependent answer (Go issue #57465).
        #expect(GoMath.isOddInt(3))
        #expect(!GoMath.isOddInt(4))
        #expect(!GoMath.isOddInt(3.5))
        #expect(!GoMath.isOddInt(9_007_199_254_740_992))
        #expect(!GoMath.isOddInt(1e300))
        #expect(!GoMath.isOddInt(-1e300))
        #expect(GoMath.isOddInt(-3))
    }

    // MARK: - Mod

    @Test("Mod matches Go on every committed case")
    func modFixtures() throws {
        try Fixtures.check("gocompat/mod.jsonl", FixtureCase<TwoFloatIn, String>.self) { input in
            hexBits(GoMath.mod(doubleFromHexBits(input.x), doubleFromHexBits(input.y)))
        }
    }

    @Test("Mod's special cases, and its NaN payload")
    func modSpecials() {
        // The result takes x's sign and |y| is used, so this is not the
        // mathematician's modulo.
        #expect(GoMath.mod(7, 3) == 1)
        #expect(GoMath.mod(-7, 3) == -1)
        #expect(GoMath.mod(7, -3) == 1)
        #expect(GoMath.mod(.infinity, 3).isNaN)
        #expect(GoMath.mod(3, .infinity) == 3)

        // The NaN cases return `math.NaN()`, whose payload is 1. libm's `fmod`
        // returns the hardware default instead, payload 0 — a difference that a
        // bit-pattern fixture sees and a `.isNaN` assertion does not.
        #expect(GoMath.mod(3, 0).bitPattern == GoFloat.goNaNBits)
        #expect(GoMath.mod(3, 0).bitPattern != Double.nan.bitPattern)
    }

    // MARK: - Min and Max

    @Test("Min and Max match Go's arm64 assembly on every committed case")
    func minMaxFixtures() throws {
        try Fixtures.check("gocompat/minmax.jsonl", FixtureCase<TwoFloatIn, MinMaxOut>.self) {
            input in
            let x = doubleFromHexBits(input.x)
            let y = doubleFromHexBits(input.y)
            return MinMaxOut(min: hexBits(GoMath.min(x, y)), max: hexBits(GoMath.max(x, y)))
        }
    }

    @Test("the ±Inf short-circuit runs before NaN handling")
    func infinityBeatsNaN() {
        // docs/PORTING.md quirk 28. dim_arm64.s compares each operand's raw bit
        // pattern against ±Inf and returns early, so the NaN never reaches FMAXD.
        // The portable `math.max` would return NaN for all four of these.
        #expect(GoMath.max(.infinity, .nan) == .infinity)
        #expect(GoMath.max(.nan, .infinity) == .infinity)
        #expect(GoMath.min(-.infinity, .nan) == -.infinity)
        #expect(GoMath.min(.nan, -.infinity) == -.infinity)

        // The short-circuit is one-sided per function: Max only checks +Inf.
        #expect(GoMath.max(-.infinity, .nan).isNaN)
        #expect(GoMath.min(.infinity, .nan).isNaN)
    }

    @Test("which NaN payload survives depends on the operand order")
    func nanPayloadOrder() {
        // `FMAXD F0, F1, F0` is FMAX(Fn=y, Fm=x), so **y is operand 1** and its
        // payload wins between two quiet NaNs. Swapping the arguments swaps the
        // answer, which is why GoMath.max cannot just forward to a symmetric
        // helper.
        let a = Double(bitPattern: 0x7ff8_0000_0000_0abc)
        let b = Double(bitPattern: 0x7ff8_0000_0000_0001)
        #expect(GoMath.max(b, a).bitPattern == 0x7ff8_0000_0000_0abc)
        #expect(GoMath.max(a, b).bitPattern == 0x7ff8_0000_0000_0001)
        #expect(GoMath.min(b, a).bitPattern == 0x7ff8_0000_0000_0abc)

        // A signalling NaN outranks a quiet one and comes back quietened.
        // Prometheus's stale marker is a signalling NaN, so this branch is live.
        let stale = Double(bitPattern: 0x7ff0_0000_0000_0002)
        #expect(GoMath.max(stale, 1).bitPattern == 0x7ff8_0000_0000_0002)
        #expect(GoMath.max(1, stale).bitPattern == 0x7ff8_0000_0000_0002)
    }

    @Test("signed zeros")
    func signedZeros() {
        #expect(GoMath.min(0, -0.0).sign == .minus)
        #expect(GoMath.min(-0.0, 0).sign == .minus)
        #expect(GoMath.max(0, -0.0).sign == .plus)
        #expect(GoMath.max(-0.0, 0).sign == .plus)
    }

    @Test("Swift's own min/max are NOT what Go computes")
    func swiftMinMaxDiffer() {
        // If this ever starts passing the other way, that is a signal to
        // re-examine GoMath.min/max — not a licence to delete them.
        #expect(Swift.max(1.0, Double.nan) == 1.0)
        #expect(GoMath.max(1.0, Double.nan).isNaN)
        #expect(Double.maximum(1.0, .nan) == 1.0)
        #expect(Double.minimum(1.0, .nan) == 1.0)
        #expect(GoMath.min(1.0, Double.nan).isNaN)
    }

    // MARK: - Ldexp

    @Test("Ldexp matches Go on every committed case")
    func ldexpFixtures() throws {
        try Fixtures.check("gocompat/ldexp.jsonl", FixtureCase<LdexpIn, String>.self) { input in
            hexBits(GoMath.ldexp(doubleFromHexBits(input.frac), input.exp))
        }
    }

    @Test("Ldexp's boundaries")
    func ldexpBoundaries() {
        #expect(GoMath.ldexp(1, 0) == 1)
        #expect(GoMath.ldexp(0.5, 1) == 1)
        // ±0 keeps its sign rather than becoming +0.
        #expect(GoMath.ldexp(-0.0, 100).sign == .minus)
        #expect(GoMath.ldexp(.infinity, -100) == .infinity)
        #expect(GoMath.ldexp(.nan, 5).isNaN)
        // Overflow to ±Inf, and underflow to a *signed* zero.
        #expect(GoMath.ldexp(1, 2000) == .infinity)
        #expect(GoMath.ldexp(-1, 2000) == -.infinity)
        #expect(GoMath.ldexp(1, -2000) == 0)
        #expect(GoMath.ldexp(-1, -2000).sign == .minus)
        // The denormal path, which needs the 2**-53 scaling.
        #expect(GoMath.ldexp(1, -1074) == Double.leastNonzeroMagnitude)
        #expect(GoMath.ldexp(1, -1075) == 0)
    }

    // MARK: - Duration.Seconds

    @Test("Duration.Seconds matches Go on every committed case")
    func durationSecondsFixtures() throws {
        try Fixtures.check(
            "gocompat/duration-seconds.jsonl", FixtureCase<DurationSecondsIn, String>.self
        ) { input in
            hexBits(GoDuration(nanoseconds: Int64(input.nanos)!).seconds)
        }
    }

    @Test("the whole/fractional split is NOT nanoseconds / 1e9")
    func secondsSplitIsRequired() {
        // Probed against Go: 4,994,284 of 20,000,000 random int64 nanosecond
        // counts disagree between the two forms. This is one of them.
        let nanos: Int64 = 5_577_006_791_947_779_410
        let split = GoDuration(nanoseconds: nanos).seconds
        let naive = Double(nanos) / 1e9
        #expect(split != naive)
        #expect(split == 5_577_006_791.947_779_655_5)
        #expect(naive == 5_577_006_791.947_778_701_8)
    }
}

@Suite("math.Log over its whole domain")
struct GoLogFullDomainTests {

    @Test("Log matches Go on every committed case")
    func logFixtures() throws {
        try Fixtures.check("gocompat/log.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.log(doubleFromHexBits(hex)))
        }
    }

    @Test("the reassembly has to be fused, and log2's corpus cannot prove it")
    func fusionIsRequired() {
        // The case the pow corpus found. Unfused — a literal transcription of
        // Go's source — this is one ULP high, and 2,350 gocompat/log2 cases still
        // pass, because Log2 only ever calls Log on a Frexp fraction in [0.5, 1).
        let x = Double(bitPattern: 0x4014_d342_232b_6aa7)
        #expect(GoMath.log(x).bitPattern == 0x3ffa_65de_e4f2_5515)

        // The unfused form, spelled exactly as log.go reads, for the record.
        let (f1raw, kiRaw) = GoMath.frexp(x)
        var f1 = f1raw
        var ki = kiRaw
        if f1 < Double(bitPattern: 0x3FE6_A09E_667F_3BCD) {
            f1 *= 2
            ki -= 1
        }
        let f = f1 - 1
        let k = Double(ki)
        let s = f / (2 + f)
        let s2 = s * s
        let s4 = s2 * s2
        let l1 = Double(bitPattern: 0x3FE5_5555_5555_5593)
        let l2 = Double(bitPattern: 0x3FD9_9999_9997_FA04)
        let l3 = Double(bitPattern: 0x3FD2_4924_9422_9359)
        let l4 = Double(bitPattern: 0x3FCC_71C5_1D8E_78AF)
        let l5 = Double(bitPattern: 0x3FC7_4664_96CB_03DE)
        let l6 = Double(bitPattern: 0x3FC3_9A09_D078_C69F)
        let l7 = Double(bitPattern: 0x3FC2_F112_DF3E_5244)
        let ln2Hi = Double(bitPattern: 0x3FE6_2E42_FEE0_0000)
        let ln2Lo = Double(bitPattern: 0x3DEA_39EF_3579_3C76)
        let t1 = s2 * (l1 + s4 * (l3 + s4 * (l5 + s4 * l7)))
        let t2 = s4 * (l2 + s4 * (l4 + s4 * l6))
        let r = t1 + t2
        let hfsq = 0.5 * f * f
        let unfused = k * ln2Hi - ((hfsq - (s * (hfsq + r) + k * ln2Lo)) - f)

        #expect(unfused.bitPattern == 0x3ffa_65de_e4f2_5516)
        #expect(unfused != GoMath.log(x))
    }

    @Test("Log(x < 0) is math.NaN(), payload 1")
    func negativeNaNPayload() {
        // Not `Double.nan`, whose payload is 0. log2's corpus takes Abs of every
        // input, so this branch was unpinned until gocompat/log existed.
        #expect(GoMath.log(-1).bitPattern == GoFloat.goNaNBits)
        #expect(GoMath.log(-1).bitPattern != Double.nan.bitPattern)
    }
}
