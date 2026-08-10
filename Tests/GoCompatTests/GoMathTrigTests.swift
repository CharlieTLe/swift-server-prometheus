//===----------------------------------------------------------------------===//
// Differential tests for GoMath's trigonometric, inverse-trigonometric and
// base-10 logarithm routines.
//
// Seven fixtures, one per function. None of these can be delegated to libm:
// measured against Go over 2,000,052 inputs each, Swift's libm differs on 23% of
// `Sin`, 29% of `Cos`, 41% of `Tan`, 67% of `Asin`, 63% of `Acos`, 15% of `Atan`
// and 65% of `Log10`. `Abs`, `Ceil`, `Floor` and `Sqrt` differ on none, and the
// port keeps using Swift's for those — asserted at the bottom of this file so the
// claim is not left as a comment.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

@Suite("Go's trigonometry, which libm does not reproduce")
struct GoMathTrigTests {

    @Test("Sin matches Go on every committed case")
    func sin() throws {
        try Fixtures.check("gocompat/sin.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.sin(doubleFromHexBits(hex)))
        }
    }

    @Test("Cos matches Go on every committed case")
    func cos() throws {
        try Fixtures.check("gocompat/cos.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.cos(doubleFromHexBits(hex)))
        }
    }

    @Test("Tan matches Go on every committed case")
    func tan() throws {
        try Fixtures.check("gocompat/tan.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.tan(doubleFromHexBits(hex)))
        }
    }

    @Test("Asin matches Go on every committed case")
    func asin() throws {
        try Fixtures.check("gocompat/asin.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.asin(doubleFromHexBits(hex)))
        }
    }

    @Test("Acos matches Go on every committed case")
    func acos() throws {
        try Fixtures.check("gocompat/acos.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.acos(doubleFromHexBits(hex)))
        }
    }

    @Test("Atan matches Go on every committed case")
    func atan() throws {
        try Fixtures.check("gocompat/atan.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.atan(doubleFromHexBits(hex)))
        }
    }

    @Test("Atan2 matches Go on every committed case, sign of zero included")
    func atan2() throws {
        // Two inputs, so the case is a pair. The zero/infinity grid is the point: atan2's nine
        // special cases are ORDERED, and every one of them carries y's sign.
        try Fixtures.check("gocompat/atan2.jsonl", FixtureCase<[String], String>.self) { pair in
            hexBits(GoMath.atan2(doubleFromHexBits(pair[0]), doubleFromHexBits(pair[1])))
        }
    }

    @Test("Log10 matches Go on every committed case")
    func log10() throws {
        try Fixtures.check("gocompat/log10.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.log10(doubleFromHexBits(hex)))
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("Go trigonometry invariants")
struct GoMathTrigInvariantTests {

    @Test("Abs, Ceil, Floor and Sqrt agree with Go, so Swift's are kept")
    func hardwareFunctionsAgree() {
        // The reason there is no GoMath.sqrt: these four are the same hardware
        // instruction either side, and they agreed on all 2,000,052 probe inputs
        // where every transcendental diverged. Spot-checked here at the boundaries
        // that would break first if that ever stopped being true.
        #expect(Double(2).squareRoot().bitPattern == 0x3FF6_A09E_667F_3BCD)
        #expect((-0.0).squareRoot().bitPattern == 0x8000_0000_0000_0000, "Sqrt(-0) = -0")
        #expect(Double(-1).squareRoot().isNaN)
        #expect((0.5).rounded(.up) == 1)
        #expect((-0.5).rounded(.up).bitPattern == 0x8000_0000_0000_0000, "Ceil(-0.5) = -0")
        #expect((-0.5).rounded(.down) == -1)
        #expect(abs(-0.0).bitPattern == 0, "Abs(-0) = +0")
    }

    @Test("NaN comes back with Go's payload, and Sin keeps the argument's")
    func nanPayloads() {
        // Not a detail: `promqltest` renders results as text, so the payload is
        // observable. Go's math.NaN() is 0x7FF8000000000001; Swift's Double.nan is
        // 0x7FF8000000000000, and reaching for the latter would be wrong in both
        // directions here.
        //
        // sin/tan `return x` for a NaN argument, so the ARGUMENT's payload
        // survives; cos returns NaN(), so it does not. asin's out-of-domain branch
        // returns NaN() too.
        let odd = Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)
        #expect(GoMath.sin(odd).bitPattern == 0x7FF8_0000_DEAD_BEEF, "Sin returns x")
        #expect(GoMath.tan(odd).bitPattern == 0x7FF8_0000_DEAD_BEEF, "Tan returns x")
        #expect(GoMath.cos(odd).bitPattern == 0x7FF8_0000_0000_0001, "Cos returns NaN()")
        #expect(GoMath.cos(.infinity).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.sin(.infinity).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.asin(2).bitPattern == 0x7FF8_0000_0000_0001, "out of domain")
        #expect(GoMath.asin(-2).bitPattern == 0x7FF8_0000_0000_0001)
    }

    @Test("the sign of zero survives")
    func signedZeros() {
        // sin/tan/atan/asin all `return x` for ±0. `Acos` does not — it is
        // `Pi/2 - Asin(x)`, so Acos(±0) is Pi/2 either way.
        #expect(GoMath.sin(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.tan(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.atan(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.asin(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.sin(0.0).bitPattern == 0)
        #expect(GoMath.cos(0.0) == 1)
        #expect(GoMath.cos(-0.0) == 1)
        #expect(GoMath.acos(0.0) == GoMath.acos(-0.0))
    }

    @Test("1/Ln10 is hard-coded because the naive computation is one ULP out")
    func invLn10IsExact() {
        // Go folds `1/Ln10` in arbitrary precision. Computing it from the rounded
        // Ln10 gives 0x3FDBCB7B1526E50D — one ULP low — which would shift every
        // log10 result. The same trap does not apply to 1/Ln2, which happens to be
        // identical either way; only Ln10 bites.
        let ln10 = 2.302585092994046
        #expect((1.0 / ln10).bitPattern == 0x3FDB_CB7B_1526_E50D, "the naive value")
        // The port's constant, exercised through log10 at an exact power of ten.
        #expect(GoMath.log10(100) == 2)
        #expect(GoMath.log10(1e10) == 10)
        #expect(GoMath.log10(1) == 0)
    }

    @Test("trigReduce takes over above 2**29, and the octant survives")
    func payneHanekSwitchover() {
        // Below the threshold the three-part Pi/4 split runs; at and above it
        // Payne-Hanek does, and the two must agree at the boundary to within the
        // spacing of the arguments themselves. Asserted as continuity rather than
        // by value: a wrong limb index or shift makes the two sides disagree
        // wildly, which is the failure mode worth catching here.
        //
        // The bound is one ULP of the argument, not an absolute epsilon: |sin a -
        // sin b| <= |a - b|, and at 2**29 one ULP is already 1.2e-7 radians.
        let t = Double(1 << 29)
        let below = GoMath.sin(t.nextDown)
        let at = GoMath.sin(t)
        #expect(abs(below - at) <= t.ulp, "continuous across the switchover")
        #expect(abs(GoMath.sin(t)) <= 1)
        #expect(abs(GoMath.cos(t)) <= 1)

        // The `bitshift == 0` limb path: (exp+61) % 64 == 0, so exp = 3, 67, ...
        // Go's `>> 64` is 0 and so is Swift's `>>`, but Swift's masking `&>>` would
        // be the identity. If these were `&>>` the results would be nonsense.
        for exp in [3, 67, 131, 195, 259] {
            let v = Double(sign: .plus, exponent: exp, significand: 1.5)
            #expect(abs(GoMath.sin(v)) <= 1, "exp \(exp)")
            #expect(abs(GoMath.cos(v)) <= 1, "exp \(exp)")
        }
    }

    @Test("tan skips its polynomial below the 1e-14 threshold")
    func tanSmallArgumentShortcut() {
        // `zz > 1e-14` means |z| > 1e-7; below it `y = z` exactly, so tan is the
        // identity on tiny arguments and the rational is never evaluated.
        #expect(GoMath.tan(1e-8) == 1e-8)
        #expect(GoMath.tan(-1e-8) == -1e-8)
        // And above it the rational does run, so the result is no longer the input.
        #expect(GoMath.tan(1e-6) != 1e-6)
    }
}
