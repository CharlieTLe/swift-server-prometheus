//===----------------------------------------------------------------------===//
// Differential tests: Go's math.Log2 / math.Log / math.Frexp vs GoMath.
//
// Go does not call libm for these — math.Log is a Go implementation of FDLIBM's
// __ieee754_log, and math.Log2 layers an exact power-of-two shortcut on top.
// Calling the platform libm instead mismatches Go on 43 of the 2,350 committed
// cases, including exact exponential bucket boundaries like 2^(1/4). That matters
// because FloatHistogram.TrimBuckets interpolates through Log2: with libm, 895 of
// the 9,048 committed trim cases come out wrong.
//
// One detail is load-bearing. Go's final step, `log(frac)*(1/Ln2) + float64(exp)`,
// compiles to a fused FMADDD on arm64, and GoMath uses `addingProduct` to match.
// It is not a micro-optimisation: for x just above a power of two the product is
// close to -exp, so the addition cancels around eight significant digits, and
// rounding the product first inflates the error to tens of ULP. Unfused, 33 of
// these cases are wrong — including every one that matters for schema-0 bucket
// interpolation.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

@Suite("Go math functions that are not libm")
struct GoMathTests {

    @Test("Log2 matches Go bit-for-bit on every committed case")
    func log2Fixtures() throws {
        try Fixtures.check("gocompat/log2.jsonl", FixtureCase<String, String>.self) { input in
            let x = Double(bitPattern: UInt64(input, radix: 16)!)
            return String(format: "%016lx", GoMath.log2(x).bitPattern)
        }
    }

    @Test("the final multiply-add has to be fused")
    func fusionIsRequired() {
        // Corpus case l/171, the worst of the ones fusion fixes. x is just above 1,
        // so log(frac)*(1/ln2) lands just under -exp and the addition cancels about
        // eight digits.
        let x = Double(bitPattern: 0x3FF0_0B1A_FA5A_BCBF)
        let goAnswer = Double(bitPattern: 0x3F70_0000_0000_0043)

        #expect(GoMath.log2(x).bitPattern == goAnswer.bitPattern)

        // The unfused form is 61 ULP out. Pinned so nobody rewrites
        // `addingProduct` back into `a * b + c`.
        let (frac, exp) = GoMath.frexp(x)
        let invLn2 = Double(bitPattern: 0x3FF7_1547_652B_82FE)
        let unfused = GoMath.log(frac) * invLn2 + Double(exp)
        #expect(unfused.bitPattern == 0x3F70_0000_0000_0080)
        #expect(unfused != goAnswer)
    }

    @Test("exact powers of two give exact answers")
    func exactPowersOfTwo() {
        // This is what the frac == 0.5 shortcut buys, and it holds regardless of
        // fusion: without it the result would depend on log(0.5) * (1/ln2) + exp
        // landing precisely on exp - 1. Exponential bucket bounds for schema ≤ 0
        // are all powers of two, so this is the case that matters most.
        for exp in -1074...1023 {
            let v = Double(sign: .plus, exponent: exp, significand: 1)
            #expect(GoMath.log2(v) == Double(exp), "2^\(exp)")
        }
    }

    @Test("Frexp splits into a fraction in [1/2, 1) and an exponent")
    func frexp() {
        var (frac, exp) = GoMath.frexp(8)
        #expect(frac == 0.5)
        #expect(exp == 4)

        (frac, exp) = GoMath.frexp(1)
        #expect(frac == 0.5)
        #expect(exp == 1)

        // Subnormals are normalised first, with a compensating exponent.
        (frac, exp) = GoMath.frexp(5e-324)
        #expect(frac == 0.5)
        #expect(exp == -1073)

        // Zero keeps its sign, and neither zero nor a non-finite value gets an
        // exponent.
        (frac, exp) = GoMath.frexp(-0.0)
        #expect(frac.sign == .minus)
        #expect(exp == 0)
        (frac, exp) = GoMath.frexp(.infinity)
        #expect(frac == .infinity)
        #expect(exp == 0)
        #expect(GoMath.frexp(.nan).frac.isNaN)
    }

    @Test("Log handles the special cases Go's does")
    func logSpecialCases() {
        #expect(GoMath.log(0) == -.infinity)
        #expect(GoMath.log(-1).isNaN)
        #expect(GoMath.log(.nan).isNaN)
        #expect(GoMath.log(.infinity) == .infinity)
        #expect(GoMath.log(1) == 0)
    }
}
