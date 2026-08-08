//===----------------------------------------------------------------------===//
// Differential tests: Go's strconv.FormatFloat vs GoFloat.
//
// ADR-4 — this is the highest-leverage parity surface in the port. Swift's
// Double.description does not match Go, and float strings surface in PromQL
// output, labels.String(), HTTP JSON, and error messages.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

struct FloatFormatIn: Decodable, Sendable {
    let bits: String
    let fmt: String
    let prec: Int

    var value: Double { Double(bitPattern: UInt64(bits, radix: 16)!) }

    var kind: GoFloat.Kind {
        switch fmt {
        case "f": return .f
        case "e": return .e
        case "E": return .E
        case "g": return .g
        case "G": return .G
        default: fatalError("unknown format \(fmt)")
        }
    }
}

@Suite("GoFloat formatting matches Go strconv")
struct GoFloatFormatTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("gocompat/floatformat.jsonl", FixtureCase<FloatFormatIn, String>.self) {
            GoFloat.format($0.value, $0.kind, precision: $0.prec)
        }
    }

    @Test("the divergences that motivate ADR-4")
    func swiftDescriptionDiverges() {
        // If any of these ever start matching Double.description, ADR-4 can be
        // revisited. Until then they document why the module exists.
        #expect(GoFloat.format(1.0, .g) == "1")
        #expect(1.0.description == "1.0")

        #expect(GoFloat.format(1_234_567.0, .g) == "1.234567e+06")
        #expect(1_234_567.0.description == "1234567.0")

        #expect(GoFloat.format(.infinity, .g) == "+Inf")
        #expect(Double.infinity.description == "inf")

        #expect(GoFloat.format(.nan, .g) == "NaN")
        #expect(Double.nan.description == "nan")
    }

    @Test("subnormal 'f' expansion is fully written out")
    func subnormalExpansion() {
        // Go writes 5e-324 in 'f' form as "0." + 323 zeros + "5".
        let s = GoFloat.format(Double(bitPattern: 1), .f, precision: -1)
        #expect(s.count == 326)
        #expect(s.hasPrefix("0.0"))
        #expect(s.hasSuffix("5"))
    }
}
