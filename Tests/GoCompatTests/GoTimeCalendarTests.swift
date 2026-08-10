//===----------------------------------------------------------------------===//
// Differential tests for GoTime's calendar against Go's `time.Time`.
//
// The corpus is the whole `Int64` second range, because `promql`'s date functions
// reach it through an unguarded `int64(el.F)` — including the band where Go's own
// absolute-second count wraps. See oracle/suites_gotime_calendar.go.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

struct CalendarOut: Decodable, Equatable, Sendable {
    var year: Int64
    var month: Int
    var day: Int
    var weekday: Int
    var yearDay: Int
    var hour: Int
    var minute: Int
    var second: Int
    /// Go: `32 - time.Date(year, month, 32, …).Day()`, i.e. what `funcDaysInMonth`
    /// evaluates.
    var daysInMonth: Int
}

@Suite("GoTime's calendar matches Go over the whole Int64 range")
struct GoTimeCalendarTests {

    @Test("every committed second")
    func calendarMatchesGo() throws {
        try Fixtures.check("gocompat/time-calendar.jsonl", FixtureCase<String, CalendarOut>.self) {
            secString in
            let sec = Int64(secString)!
            let t = GoTime(unixSeconds: sec, nanosecond: 0)
            let (year, month, day) = t.utcDate
            let (hour, minute, second) = t.utcClock
            return CalendarOut(
                year: year, month: month, day: day,
                weekday: t.utcWeekday, yearDay: t.utcYearDay,
                hour: hour, minute: minute, second: second,
                daysInMonth: GoTime.daysInMonth(year: year, month: month))
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("GoTime calendar invariants")
struct GoTimeCalendarInvariantTests {

    @Test("the calendar goes through Go's absolute second count, wrap included")
    func absoluteSecondsWrap() {
        // Go's `Time.absSec()` is `absSeconds(sec + unixToAbsolute)` — an int64 add,
        // then a uint64 reinterpretation. For seconds below -9223372028741760000 the
        // sum is negative and the reinterpretation lands near 2**64, so the date is
        // nonsense — but *deterministically* nonsense, and reachable, so the port
        // reproduces it rather than computing the mathematically correct answer.
        //
        // The visible consequence: both infinities give the SAME year.
        let maxT = GoTime(unixSeconds: .max, nanosecond: 0)
        let minT = GoTime(unixSeconds: .min, nanosecond: 0)
        #expect(maxT.utcDate.year == 292_277_026_596)
        #expect(minT.utcDate.year == 292_277_026_596, "the wrap, not a sign error")
        #expect(minT.utcDate.month == 12)
        #expect(minT.utcDate.day == 4)

        // The boundary. One second above it is an ordinary very-negative date; at it
        // and below, the wrap has happened.
        let boundary: Int64 = -9_223_372_028_741_760_000
        #expect(GoTime(unixSeconds: boundary, nanosecond: 0).utcDate.year == -292_277_022_400)
        #expect(GoTime(unixSeconds: boundary - 1, nanosecond: 0).utcDate.year > 0,
                "one second lower and the year flips positive")
        #expect(GoTime(unixSeconds: boundary + 1, nanosecond: 0).utcDate.year == -292_277_022_400)
    }

    @Test("the int64 addition overflows for ordinary dates and nothing is lost")
    func positiveOverflowIsHarmless() {
        // `sec + unixToAbsolute` overflows Int64 for every second above 8113015807 —
        // i.e. from about the year 2227 onwards, which includes nothing anyone would
        // call extreme. The uint64 reinterpretation puts it back exactly, because the
        // true sum is below 2**64. Asserted as continuity across the boundary.
        let over: Int64 = 8_113_015_807
        let a = GoTime(unixSeconds: over, nanosecond: 0)
        let b = GoTime(unixSeconds: over + 1, nanosecond: 0)
        #expect(a.utcDate.year == 2227)
        #expect(b.utcDate.year == 2227)
        #expect(b.utcClock.second == a.utcClock.second + 1)
    }

    @Test("the epoch, and the day before it")
    func epoch() {
        let t = GoTime(unixSeconds: 0, nanosecond: 0)
        #expect(t.utcDate == (1970, 1, 1))
        #expect(t.utcWeekday == 4, "1970-01-01 was a Thursday, and Sunday is 0")
        #expect(t.utcYearDay == 1, "1-based")
        #expect(t.utcClock == (0, 0, 0))

        // A negative second count is where a floor-versus-truncate mistake shows up.
        // Going through the unsigned absolute count means there is no division of a
        // negative number to get wrong.
        let u = GoTime(unixSeconds: -1, nanosecond: 0)
        #expect(u.utcDate == (1969, 12, 31))
        #expect(u.utcClock == (23, 59, 59))
        #expect(u.utcYearDay == 365)
        #expect(u.utcWeekday == 3)
    }

    @Test("year 1 and year 0 both exist, in astronomical numbering")
    func astronomicalYears() {
        // Go uses astronomical year numbering, so year 0 is 1 BC and is a leap year.
        // A port that used ISO numbering would be off by one below year 1.
        let y1 = GoTime(unixSeconds: -62_135_596_800, nanosecond: 0)
        #expect(y1.utcDate == (1, 1, 1))
        #expect(y1.utcWeekday == 1, "0001-01-01 was a Monday")
        #expect(GoTime(unixSeconds: -62_135_596_801, nanosecond: 0).utcDate == (0, 12, 31))
    }

    @Test("the leap rule, including the century exceptions and negative years")
    func leapYears() {
        // February's length is the whole leap rule in one number — and note there is
        // no `isLeapYear` helper to test directly. An earlier version had one, and
        // deleting it was the *result* of a negative control: once `daysInMonth` went
        // through `dateToAbsDays` to match Go's `time.Date`, the helper had no caller,
        // and perturbing its 100- and 400-year exceptions changed nothing. Dead code
        // that no control can break is worse than no code.
        #expect(GoTime.daysInMonth(year: 2024, month: 2) == 29)
        #expect(GoTime.daysInMonth(year: 2023, month: 2) == 28)
        #expect(GoTime.daysInMonth(year: 1900, month: 2) == 28, "divisible by 100")
        #expect(GoTime.daysInMonth(year: 2000, month: 2) == 29, "divisible by 400")
        #expect(GoTime.daysInMonth(year: 2100, month: 2) == 28)
        // Astronomical numbering, where `%` is negative in Swift but every test is
        // against zero so the sign never matters.
        #expect(GoTime.daysInMonth(year: 0, month: 2) == 29)
        #expect(GoTime.daysInMonth(year: -1, month: 2) == 28)
        #expect(GoTime.daysInMonth(year: -4, month: 2) == 29)
        #expect(GoTime.daysInMonth(year: -100, month: 2) == 28)
        #expect(GoTime.daysInMonth(year: -400, month: 2) == 29)
        // And the fixed-length months, one of which is the 1-based indexing check.
        #expect(GoTime.daysInMonth(year: 2024, month: 1) == 31)
        #expect(GoTime.daysInMonth(year: 2024, month: 4) == 30)
        #expect(GoTime.daysInMonth(year: 2024, month: 12) == 31)
    }

    @Test("yearDay reaches 366 only in a leap year")
    func yearDayRange() {
        // 2024-12-31 and 2023-12-31, which is the cheapest check that the year-day
        // computation uses the right year's January 1.
        #expect(GoTime(unixSeconds: 1_735_689_599, nanosecond: 0).utcYearDay == 366)
        #expect(GoTime(unixSeconds: 1_704_067_199, nanosecond: 0).utcYearDay == 365)
        // 2024-02-29, the day that only exists in a leap year.
        let leapDay = GoTime(unixSeconds: 1_709_164_800, nanosecond: 0)
        #expect(leapDay.utcDate == (2024, 2, 29))
        #expect(leapDay.utcYearDay == 60)
    }

    @Test("daysFromCivil inverts civilFromDays")
    func civilRoundTrip() {
        // The two Hinnant halves have to agree or `utcYearDay` is silently wrong for
        // whole years at a time. Checked across the era boundaries rather than only
        // near the epoch.
        for days in [Int64](stride(from: -400_000, through: 400_000, by: 7_919)) {
            let (y, m, d) = GoTime.civilFromDays(days)
            #expect(GoTime.daysFromCivil(year: y, month: m, day: d) == days, "days \(days)")
        }
        for days in [Int64(-146_097), -719_468, 0, 146_097, 106_751_991_073_400] {
            let (y, m, d) = GoTime.civilFromDays(days)
            #expect(GoTime.daysFromCivil(year: y, month: m, day: d) == days, "days \(days)")
        }
    }
}

// MARK: - GoConv

@Suite("Go's saturating float-to-Int64 conversion")
struct GoConvTests {

    @Test("int64(Double) saturates and maps NaN to zero, as FCVTZS does")
    func saturates() {
        // Probed against Go on arm64, not inferred from the spec — which calls the
        // out-of-range case implementation-defined. Swift's `Int64(_:)` traps on all
        // three of these.
        #expect(GoConv.int64(.nan) == 0)
        #expect(GoConv.int64(Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)) == 0)
        #expect(GoConv.int64(.infinity) == Int64.max)
        #expect(GoConv.int64(-.infinity) == Int64.min)
        #expect(GoConv.int64(1e300) == Int64.max)
        #expect(GoConv.int64(-1e300) == Int64.min)
        // 2**63 exactly, which is the first value above the range. `>=` is required:
        // `Int64.max` is not representable as a Double, so a `>` test would hand 2**63
        // to a trapping conversion.
        #expect(GoConv.int64(9_223_372_036_854_775_808.0) == Int64.max)
        #expect(GoConv.int64(-9_223_372_036_854_775_808.0) == Int64.min)
        // In range, truncating toward zero.
        #expect(GoConv.int64(1.9) == 1)
        #expect(GoConv.int64(-1.9) == -1)
        #expect(GoConv.int64(0.5) == 0)
        #expect(GoConv.int64(-0.5) == 0)
        #expect(GoConv.int64(-0.0) == 0)
    }
}
