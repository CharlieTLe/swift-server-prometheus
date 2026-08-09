//===----------------------------------------------------------------------===//
// Differential tests for GoTime — the subset of Go's time package the PromQL
// engine needs.
//
// RFC 3339 rendering is the reason this exists: one annotation message formats a
// timestamp through it, and a hand-rolled civil-date conversion is easy to get
// subtly wrong. It was wrong on the first attempt, over the whole range, and this
// fixture is what said so.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

@Suite("GoTime matches Go's time package")
struct GoTimeTests {

    struct DateOut: Decodable, Equatable, Sendable {
        let rfc3339: String
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    @Test("time.Unix(sec, 0).UTC() renders and decomposes like Go's")
    func rfc3339() throws {
        try Fixtures.check("gocompat/time-rfc3339.jsonl", FixtureCase<Int64, DateOut>.self) { sec in
            let t = GoTime.unix(sec, 0)
            let (year, month, day) = t.utcDate
            let (hour, minute, second) = t.utcClock
            return DateOut(
                rfc3339: t.rfc3339UTC,
                year: Int(year), month: month, day: day,
                hour: hour, minute: minute, second: second)
        }
    }

    struct MilliOut: Decodable, Equatable, Sendable {
        let milli: Int64
        let seconds: Int64
        let nanos: Int
        let rfc3339: String
    }

    @Test("time.UnixMilli normalises a negative remainder the way Go does")
    func unixMilli() throws {
        try Fixtures.check("gocompat/time-unixmilli.jsonl", FixtureCase<Int64, MilliOut>.self) {
            ms in
            // Go: Unix(ms/1e3, (ms%1e3)*1e6), where the remainder is negative for
            // negative ms and normalisation carries it back into the second.
            let t = GoTime.unix(ms / 1_000, (ms % 1_000) * 1_000_000)
            return MilliOut(
                milli: t.unixMilliseconds,
                seconds: t.unixSeconds,
                nanos: Int(t.nanosecond),
                rfc3339: t.rfc3339UTC)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("GoTime invariants")
struct GoTimeInvariantTests {

    @Test("the zero value is year 1, not the Unix epoch")
    func zeroIsYearOne() {
        // Go's zero time.Time is 0001-01-01T00:00:00Z, and IsZero is defined
        // against it. A Swift struct whose memberwise default was 0 would silently
        // put the zero value at 1970 instead.
        #expect(GoTime.zero.rfc3339UTC == "0001-01-01T00:00:00Z")
        #expect(GoTime.zero.isZero)
        #expect(!GoTime.unix(0, 0).isZero)
    }

    @Test("unix normalises nanoseconds outside 0..<1e9")
    func normalisation() {
        // time.Unix(0, -1) is one nanosecond before the epoch, not an invalid value.
        let before = GoTime.unix(0, -1)
        #expect(before.unixSeconds == -1)
        #expect(before.nanosecond == 999_999_999)

        let after = GoTime.unix(0, 1_000_000_001)
        #expect(after.unixSeconds == 1)
        #expect(after.nanosecond == 1)

        // Whole negative seconds stay whole.
        let exact = GoTime.unix(0, -1_000_000_000)
        #expect(exact.unixSeconds == -1)
        #expect(exact.nanosecond == 0)
    }

    @Test("unixMilliseconds floors, which is what timestamp.FromTime relies on")
    func milliFloors() {
        // nanosecond is non-negative by construction, so the division cannot round
        // toward zero across the epoch the way a signed nanosecond count would.
        #expect(GoTime.unix(-1, 999_000_000).unixMilliseconds == -1)
        #expect(GoTime.unix(-1, 0).unixMilliseconds == -1_000)
        #expect(GoTime.unix(0, 999_999).unixMilliseconds == 0)
    }

    @Test("add and sub round-trip")
    func arithmetic() {
        let base = GoTime.unix(1_136_239_445, 123_456_789)
        let shifted = base.add(GoDuration(nanoseconds: 5_000_000_000))
        #expect(shifted.unixSeconds == 1_136_239_450)
        #expect(shifted.nanosecond == 123_456_789)
        #expect(shifted.sub(base) == GoDuration(nanoseconds: 5_000_000_000))
        #expect(base.before(shifted))
        #expect(shifted.after(base))

        // A sub-second negative shift has to borrow from the second.
        let back = base.add(GoDuration(nanoseconds: -200_000_000))
        #expect(back.unixSeconds == 1_136_239_444)
        #expect(back.nanosecond == 923_456_789)
    }

    @Test("sub saturates instead of wrapping")
    func subSaturates() {
        // Go's Time.Sub clamps to ±maxDuration rather than overflowing.
        let far = GoTime.unix(Int64.max / 2, 0)
        let near = GoTime.unix(Int64.min / 2, 0)
        #expect(far.sub(near) == GoDuration.max)
        #expect(near.sub(far) == GoDuration.min)
    }

    @Test("the four-digit year is padded but not truncated")
    func yearWidth() {
        // Go's appendInt(b, year, 4) pads to four digits and prints more when it
        // has them; a negative year gets a leading sign before the padding.
        #expect(GoTime.unix(253_402_300_800, 0).rfc3339UTC.hasPrefix("10000-"))
        #expect(GoTime.unix(-62_135_596_801, 0).rfc3339UTC.hasPrefix("0000-"))
        #expect(GoTime.unix(-62_167_219_201, 0).rfc3339UTC.hasPrefix("-0001-"))
    }
}
