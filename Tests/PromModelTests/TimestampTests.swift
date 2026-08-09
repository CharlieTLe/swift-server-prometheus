//===----------------------------------------------------------------------===//
// Differential tests for model/timestamp/timestamp.go.
//
// Three one-line conversions, and every one of them has a trap: the millisecond
// remainder is negative below the epoch, and FromFloatSeconds rounds
// half-away-from-zero, which is not Swift's default rounding rule.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import Testing

@testable import PromModel

@Suite("model/timestamp matches Go")
struct TimestampTests {

    struct Out: Decodable, Equatable, Sendable {
        let fromTime: Int64
        let rfc3339: String
    }

    @Test("Time and FromTime round-trip a millisecond timestamp")
    func roundTrip() throws {
        try Fixtures.check("promql/timestamp.jsonl", FixtureCase<Int64, Out>.self) { ms in
            let t = Timestamp.time(ms)
            return Out(fromTime: Timestamp.fromTime(t), rfc3339: t.rfc3339UTC)
        }
    }

    @Test("FromFloatSeconds rounds the way math.Round does")
    func fromFloatSeconds() throws {
        // The input travels as a hex bit pattern, so a tie is exactly the tie Go
        // saw rather than whatever a decimal round trip produced.
        try Fixtures.check(
            "promql/timestamp-floatsec.jsonl", FixtureCase<String, Int64>.self
        ) { hex in
            let f = Double(bitPattern: UInt64(hex, radix: 16)!)
            return Timestamp.fromFloatSeconds(f)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("model/timestamp invariants")
struct TimestampInvariantTests {

    @Test("half-way values round away from zero, not to even")
    func roundingRule() {
        // Swift's bare `rounded()` is .toNearestOrAwayFromZero too, but `Int64(x)`
        // truncates and `x.rounded(.toNearestOrEven)` would differ — 2.5 -> 2. Pin
        // the rule so a future "simplification" cannot silently change it.
        #expect(Timestamp.fromFloatSeconds(0.0005) == 1)
        #expect(Timestamp.fromFloatSeconds(-0.0005) == -1)
        #expect(Timestamp.fromFloatSeconds(0.0015) == 2)
        #expect(Timestamp.fromFloatSeconds(-0.0015) == -2)
    }

    @Test("a negative millisecond timestamp lands on the right second")
    func negativeMillis() {
        // time.UnixMilli(-1) is 999ms before the epoch, so the second is -1 and the
        // nanosecond remainder is 999_000_000.
        let t = Timestamp.time(-1)
        #expect(t.unixSeconds == -1)
        #expect(t.nanosecond == 999_000_000)
        #expect(Timestamp.fromTime(t) == -1)
    }
}
