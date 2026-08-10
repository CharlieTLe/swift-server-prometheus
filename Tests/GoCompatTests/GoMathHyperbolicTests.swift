//===----------------------------------------------------------------------===//
// Differential tests for GoMath's hyperbolic and inverse-hyperbolic routines,
// plus `Log1p`, which three of them are built on.
//
// Seven fixtures, one per function. None of these can be delegated to libm:
// measured against Go over 1,921,867 inputs each, Swift's libm differs on 24.6%
// of `Sinh`, 13.6% of `Cosh`, 5.4% of `Tanh`, 8.7% of `Asinh`, 69.5% of `Acosh`,
// 50.4% of `Atanh` and 18.0% of `Log1p`. `Cosh` fuses nothing and inherits every
// one of its differences from ``GoMath/exp(_:)``, which is the point: a routine
// with no arithmetic of its own still cannot use the platform's.
//
// The invariants below are the ones the fixtures pin but do not explain, and the
// ones that come from perturbing the port rather than from reading Go's source.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

@Suite("Go's hyperbolics, which libm does not reproduce")
struct GoMathHyperbolicTests {

    @Test("Sinh matches Go on every committed case")
    func sinh() throws {
        try Fixtures.check("gocompat/sinh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.sinh(doubleFromHexBits(hex)))
        }
    }

    @Test("Cosh matches Go on every committed case")
    func cosh() throws {
        try Fixtures.check("gocompat/cosh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.cosh(doubleFromHexBits(hex)))
        }
    }

    @Test("Tanh matches Go on every committed case")
    func tanh() throws {
        try Fixtures.check("gocompat/tanh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.tanh(doubleFromHexBits(hex)))
        }
    }

    @Test("Asinh matches Go on every committed case")
    func asinh() throws {
        try Fixtures.check("gocompat/asinh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.asinh(doubleFromHexBits(hex)))
        }
    }

    @Test("Acosh matches Go on every committed case")
    func acosh() throws {
        try Fixtures.check("gocompat/acosh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.acosh(doubleFromHexBits(hex)))
        }
    }

    @Test("Atanh matches Go on every committed case")
    func atanh() throws {
        try Fixtures.check("gocompat/atanh.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.atanh(doubleFromHexBits(hex)))
        }
    }

    @Test("Log1p matches Go on every committed case")
    func log1p() throws {
        try Fixtures.check("gocompat/log1p.jsonl", FixtureCase<String, String>.self) { hex in
            hexBits(GoMath.log1p(doubleFromHexBits(hex)))
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("Go hyperbolic invariants")
struct GoMathHyperbolicInvariantTests {

    @Test("NaN payloads split three ways, and none of them is Double.nan")
    func nanPayloads() {
        // `promqltest` renders results as text, so the payload is observable.
        //
        //   * Sinh, Tanh and Asinh let the ARGUMENT's payload through — Sinh and
        //     Tanh by falling into their rationals and propagating, Asinh by an
        //     explicit `return x`.
        //   * Cosh propagates too, but through `Abs(x)`, which clears the sign bit
        //     first — so a negative NaN comes back positive.
        //   * Acosh, Atanh and Log1p share their NaN branch with the out-of-domain
        //     case and return Go's `NaN()`, replacing whatever came in.
        let odd = Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)
        let negOdd = Double(bitPattern: 0xFFF8_0000_DEAD_BEEF)

        #expect(GoMath.sinh(odd).bitPattern == 0x7FF8_0000_DEAD_BEEF)
        #expect(GoMath.tanh(odd).bitPattern == 0x7FF8_0000_DEAD_BEEF)
        #expect(GoMath.asinh(odd).bitPattern == 0x7FF8_0000_DEAD_BEEF, "explicit return x")
        #expect(GoMath.cosh(negOdd).bitPattern == 0x7FF8_0000_DEAD_BEEF, "Abs clears the sign")

        #expect(GoMath.acosh(odd).bitPattern == 0x7FF8_0000_0000_0001, "Go's NaN()")
        #expect(GoMath.atanh(odd).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.log1p(odd).bitPattern == 0x7FF8_0000_0000_0001)

        // Out of domain, the same payload by the same branch. Reaching for
        // `Double.nan` here would be 0x7FF8000000000000 and wrong.
        #expect(GoMath.acosh(0.5).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.acosh(-.infinity).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.atanh(1.5).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.atanh(-1.5).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.log1p(-1.5).bitPattern == 0x7FF8_0000_0000_0001)
        #expect(GoMath.log1p(-.infinity).bitPattern == 0x7FF8_0000_0000_0001)
    }

    @Test("the sign of zero survives, and Cosh(±0) is 1")
    func signedZeros() {
        #expect(GoMath.sinh(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.tanh(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.asinh(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.atanh(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.log1p(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(GoMath.sinh(0.0).bitPattern == 0)
        #expect(GoMath.cosh(0.0) == 1)
        #expect(GoMath.cosh(-0.0) == 1)
        // Sinh's ±0 is not an explicit branch: it falls out of the rational, whose
        // numerator carries a factor of x. Worth stating, because "there is no
        // special case for zero" reads like a bug until you check.
        #expect(GoMath.sinh(0.0).isZero)
    }

    @Test("the infinities")
    func infinities() {
        #expect(GoMath.sinh(.infinity) == .infinity)
        #expect(GoMath.sinh(-.infinity) == -.infinity)
        #expect(GoMath.cosh(.infinity) == .infinity)
        #expect(GoMath.cosh(-.infinity) == .infinity)
        #expect(GoMath.tanh(.infinity) == 1)
        #expect(GoMath.tanh(-.infinity) == -1)
        #expect(GoMath.asinh(.infinity) == .infinity)
        #expect(GoMath.asinh(-.infinity) == -.infinity)
        #expect(GoMath.acosh(.infinity) == .infinity)
        #expect(GoMath.atanh(1) == .infinity)
        #expect(GoMath.atanh(-1) == -.infinity)
        #expect(GoMath.log1p(.infinity) == .infinity)
        #expect(GoMath.log1p(-1) == -.infinity)
    }

    @Test("upstream's own hex comments for two log1p constants are wrong")
    func log1pBoundaryConstants() {
        // log1p.go annotates `Sqrt2M1 = 4.142135623730950488017e-01` as
        // 0x3fda827999fcef34 and `Sqrt2HalfM1 = -2.928932188134524755992e-01` as
        // 0xbfd2bec333018866. Go compiles the DECIMALS, which round to the two
        // values below — two ULP and one ULP away from the comments. Transcribing
        // the hex would move log1p's branch boundary, so the port takes the
        // decimals, and this test is where that decision is recorded.
        #expect(Double("4.142135623730950488017e-01")!.bitPattern == 0x3FDA_8279_99FC_EF32)
        #expect(Double("-2.928932188134524755992e-01")!.bitPattern == 0xBFD2_BEC3_3301_8867)

        // Only the Sqrt2M1 error is observable, and both halves of that are worth
        // pinning. A one-ULP change to a boundary only changes behaviour for inputs
        // inside the ULP-wide gap it opens — here 0x3FDA827999FCEF32 and ...33,
        // which the wrong constant would route through the k = 0 shortcut instead of
        // the full reduction. Those two inputs give different answers by the two
        // routes, so `gocompat/log1p` catches the wrong constant; Sqrt2HalfM1's
        // single gap value does not, and the port is right there by transcription
        // rather than by test. Asserted as the branch really being taken:
        let m1 = Double(bitPattern: 0x3FDA_8279_99FC_EF32)
        #expect(GoMath.log1p(m1) != 0)
        // Non-strict: log1p's derivative here is ~0.707, so adjacent doubles can
        // map to the same output. Monotonicity across the split is the claim.
        #expect(GoMath.log1p(m1.nextDown) <= GoMath.log1p(m1), "monotone across the split")
        #expect(GoMath.log1p(m1) <= GoMath.log1p(m1.nextUp))
    }

    @Test("log1p beats log(1+x) only below 2**-53, which is narrower than it sounds")
    func log1pBeatsLog() {
        // The documented reason log1p exists is accuracy near zero, and it is worth
        // knowing exactly where that starts to matter, because it is *not* where the
        // branches are. At 2**-28 the sum `1+x` is exact, so `Log(1+x)` and
        // `Log1p(x)` give the same bits despite taking completely different paths.
        let x28 = Double(bitPattern: 0x3E30_0000_0000_0000)  // 2**-28
        #expect(GoMath.log1p(x28).bitPattern == GoMath.log(1 + x28).bitPattern)

        // The gap opens once `1+x` rounds to 1, i.e. |x| <= 2**-53. There Log gives
        // exactly zero and Log1p gives x.
        let x55 = Double(bitPattern: 0x3C80_0000_0000_0000)  // 2**-55
        #expect(GoMath.log(1 + x55) == 0, "log has lost it entirely")
        #expect(GoMath.log1p(x55) == x55, "log1p is the identity below Tiny")

        // Between Tiny (2**-54) and Small (2**-29) the answer is the two-term
        // series, which is a different number from x.
        let x30 = Double(bitPattern: 0x3E10_0000_0000_0000)  // 2**-30
        #expect(GoMath.log1p(x30) == x30 - x30 * x30 * 0.5)
        #expect(GoMath.log1p(x30) != x30)
    }

    @Test("two log1p branches are unreachable, not merely untested")
    func log1pDeadBranches() {
        // log1p.go:185's `return 0` and log1p.go:192's `return f - R` both need
        // `k == 0` on the `iu == 0` path. After the reduction, `iu == 0` implies
        // `u == 1.0`, which implies |x| <= 2**-53 — and |x| < 2**-29 has already
        // returned at log1p.go:141. So neither runs, which is why perturbing
        // log1p.go:192's fusion changes nothing in 34,000,052 inputs: the code is
        // dead, not the difference invisible.
        //
        // The two halves of that argument, asserted:
        let small = Double(bitPattern: 0x3E20_0000_0000_0000)  // 2**-29, log1p's Small
        let largestRoundingAway = Double(bitPattern: 0x3CA0_0000_0000_0000)  // 2**-53
        #expect(1.0 + largestRoundingAway == 1.0, "so u == 1.0 needs |x| <= 2**-53")
        #expect(1.0 + largestRoundingAway.nextUp != 1.0, "and nothing larger does")
        #expect(largestRoundingAway < small, "which Small has already caught")
        // Below Tiny the identity branch runs instead, so even 2**-54 never reaches
        // the reduction.
        let tiny = Double(bitPattern: 0x3C90_0000_0000_0000)  // 2**-54
        #expect(GoMath.log1p(tiny).bitPattern == tiny.bitPattern)
    }

    @Test("Sinh's P0 and Q0 are different decimals that round to one Double")
    func sinhP0EqualsQ0() {
        // Not a transcription slip. sinh.go writes
        // P0 = -0.6307673640497716991184787251e+6 and
        // Q0 = -0.6307673640497716991212077277e+6 — they differ in the 20th
        // significant digit, well below double precision, and Go's compiler loads
        // one constant for both. Both names are kept in the port so the source
        // still lines up; this test records why they are equal.
        #expect(GoMath.sinhP[0].bitPattern == GoMath.sinhQ[0].bitPattern)
        #expect(GoMath.sinhP[0].bitPattern == 0xC123_3FDE_BA64_BB4F)
        #expect(Double("-0.6307673640497716991184787251e+6")!
            == Double("-0.6307673640497716991212077277e+6")!)
    }

    @Test("the branch boundaries are exactly representable, so a PromQL literal hits them")
    func branchBoundaries() {
        // 0.5, 21, 0.625 and 2 are all exact, so `sinh(0.5)` from a query really
        // does land on the boundary rather than near it. Each pair below straddles
        // one; a wrong comparison direction shows up as one of them agreeing with
        // its neighbour across the branch.
        #expect(GoMath.sinh(0.5) != GoMath.sinh(0.5.nextUp), "0.5 is the series/Exp split")
        #expect(GoMath.sinh(21) != GoMath.sinh(21.0.nextUp), "21 is (ex-1/ex)/2 vs Exp/2")
        #expect(GoMath.tanh(0.625) != GoMath.tanh(0.625.nextDown))

        // Tanh's `z > 0.5*MAXLOG` branch returns a literal ±1 without evaluating
        // anything — but it is a shortcut, not the point where the value saturates.
        // Tanh already rounds to exactly 1 at 20, twenty-four short of the boundary,
        // so the branch is unobservable in the result and only ever saves work.
        let halfMaxLog = Double(bitPattern: 0x4046_01E6_78FC_457B)
        #expect(GoMath.tanh(19) != 1, "19 still has bits below 1")
        #expect(GoMath.tanh(20) == 1, "and 20 does not, well before the branch")
        #expect(GoMath.tanh(halfMaxLog) == 1, "exactly on the boundary it evaluates")
        #expect(GoMath.tanh(halfMaxLog.nextUp) == 1, "just above it does not")
        #expect(GoMath.tanh(-halfMaxLog.nextUp) == -1)
    }

    @Test("Acosh(1) is exactly 0, and the NearZero branches are the identity")
    func exactAnswers() {
        #expect(GoMath.acosh(1) == 0)
        #expect(GoMath.acosh(1).sign == .plus)

        // |x| < 2**-28 returns x untouched, so the answer is exact by construction.
        let x = Double(bitPattern: 0x3E20_0000_0000_0000)  // 2**-29
        #expect(GoMath.atanh(x) == x)
        #expect(GoMath.asinh(x) == x)

        // Above the boundary the series does run — but it does not change the
        // answer until much further up, because x**3/3 stays below half an ULP of x
        // until around 1e-5. So "the boundary is where the answer starts to move"
        // would be wrong, and 2**-27 is the counter-example.
        let justAbove = Double(bitPattern: 0x3E40_0000_0000_0000)  // 2**-27
        #expect(GoMath.atanh(justAbove) == justAbove, "still the identity by rounding")
        #expect(GoMath.asinh(justAbove) == justAbove)
        #expect(GoMath.atanh(1e-5) != 1e-5, "here it finally moves")
        #expect(GoMath.asinh(1e-5) != 1e-5)
    }
}
