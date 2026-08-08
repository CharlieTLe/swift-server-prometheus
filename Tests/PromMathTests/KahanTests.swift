//===----------------------------------------------------------------------===//
// Differential tests: Kahan–Neumaier summation against Go's util/kahansum.
//
// Bit-exactness requirement: PromQL's sum/avg/sum_over_time accumulate here and
// the conformance suite pins their output.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromMath
@testable import PromModel

struct KahanIn: Decodable, Sendable {
    let values: [String]
    var doubles: [Double] { values.map { Double(bitPattern: UInt64($0, radix: 16)!) } }
}

struct KahanOut: Decodable, Equatable, Sendable {
    let sum: String
    let c: String
}

@Suite("Kahan summation is bit-exact with Go")
struct KahanTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("math/kahan.jsonl", FixtureCase<KahanIn, KahanOut>.self) { input in
            var sum = 0.0
            var c = 0.0
            for v in input.doubles {
                (sum, c) = Kahan.inc(v, sum, c)
            }
            // Compare bit patterns, not values: NaN != NaN and -0.0 == 0.0 would
            // both let a real divergence through.
            return KahanOut(
                sum: String(format: "%016lx", sum.bitPattern),
                c: String(format: "%016lx", c.bitPattern))
        }
    }

    @Test("compensation recovers the term naive summation loses")
    func compensationWorks() {
        // The classic case: 1 + 1e100 + 1 - 1e100. Naive gives 0.
        var sum = 0.0
        var c = 0.0
        for v in [1.0, 1e100, 1.0, -1e100] {
            (sum, c) = Kahan.inc(v, sum, c)
        }
        #expect(sum + c == 2.0)

        var naive = 0.0
        for v in [1.0, 1e100, 1.0, -1e100] { naive += v }
        #expect(naive == 0.0)
    }

    @Test("infinity resets the compensation term")
    func infinityResets() {
        var sum = 0.0
        var c = 0.0
        (sum, c) = Kahan.inc(.greatestFiniteMagnitude, sum, c)
        (sum, c) = Kahan.inc(.greatestFiniteMagnitude, sum, c)
        #expect(sum.isInfinite)
        #expect(c == 0.0)
    }
}

@Suite("StaleNaN and almost.Equal")
struct AlmostTests {

    @Test("StaleNaN is a distinct bit pattern, not just any NaN")
    func staleNaNIsExact() {
        #expect(PromValue.isStaleNaN(PromValue.staleNaN))
        #expect(!PromValue.isStaleNaN(PromValue.normalNaN))
        #expect(!PromValue.isStaleNaN(.nan))
        #expect(PromValue.staleNaNBits == 0x7ff0_0000_0000_0002)
    }

    @Test("StaleNaN never compares equal to an ordinary NaN")
    func staleNaNNotEqualToNaN() {
        #expect(Almost.equal(PromValue.staleNaN, PromValue.staleNaN, 1e-9))
        #expect(!Almost.equal(PromValue.staleNaN, .nan, 1e-9))
        #expect(!Almost.equal(.nan, PromValue.staleNaN, 1e-9))
        // Ordinary NaNs do compare equal, for test purposes.
        #expect(Almost.equal(.nan, .nan, 1e-9))
    }

    @Test("near-zero comparisons use the minNormal scale")
    func nearZero() {
        #expect(Almost.equal(0, 0, 1e-9))
        #expect(!Almost.equal(0, 1, 1e-9))
        #expect(Almost.equal(1.0, 1.0 + 1e-15, 1e-9))
        #expect(!Almost.equal(1.0, 1.1, 1e-9))
    }
}
