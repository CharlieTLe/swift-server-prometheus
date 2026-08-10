//===----------------------------------------------------------------------===//
// Ported from Go's time package (time.go, format_rfc3339.go) @ go1.26.5
//
// A deliberately small subset of `time.Time`: the instant, the arithmetic
// Prometheus does on it, the calendar accessors `promql/functions.go`'s eight date
// functions need, and RFC 3339 rendering in UTC.
//
// What is *not* here: locations, monotonic clock readings, and the general
// `Format`/`Parse` layout machinery. Prometheus treats query times as instants and
// converts them to integer milliseconds almost immediately (`model/timestamp`), so
// the full type would be a large compatibility surface bought for nothing. Grow
// this file when a port actually needs more, not pre-emptively.
//
// ## The calendar goes through Go's *absolute* second count, and it has to
//
// Go does not compute the calendar from the Unix second count. `Time.absSec()`
// (time.go:784) is `absSeconds(sec + (unixToInternal + internalToAbsolute))` —
// an `int64` addition, **then a reinterpretation as `uint64`**. Both halves of
// that matter:
//
//   * For `sec > 8113015807` the `int64` addition overflows, and the `uint64`
//     reinterpretation puts it back: the true sum is below 2**64, so the round
//     trip is exact and nothing is lost.
//   * For `sec < -9223372028741760000` the sum is genuinely negative, and the
//     `uint64` reinterpretation turns it into a value near 2**64 — a nonsense
//     date, deterministically. That band is **8,113,015,808 seconds wide** (about
//     257 years at the far negative end of `Int64`).
//
// An earlier version of this file computed the calendar directly from
// `unixSeconds` and said the wrap "would hide a bug rather than match anything
// observable". **That was wrong**, and `promql`'s date functions are how:
// `dateWrapper` does `time.Unix(int64(el.F), 0)` on arbitrary sample data with no
// guard, `int64(-Inf)` saturates to `Int64.min`, and so `year(vector(-Inf))` is
// legal PromQL whose answer in Go is **+292277026596** — the same as
// `year(vector(+Inf))`. Any finite sample below about -9.2233720287e18 lands in
// the band too, so this is not an infinities-only curiosity.
//
// The port therefore models `abs` exactly, with a wrapping `&+` and a
// `UInt64(bitPattern:)`, and derives everything from it. PORTING.md quirk 46.
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

/// Go: `time.Time`, reduced to the instant it denotes.
///
/// Stored as seconds since the Unix epoch plus a nanosecond remainder in
/// `0..<1_000_000_000`, mirroring how `time.Unix` normalises its arguments. A
/// single nanosecond count would overflow `Int64` at ±292 years, and
/// `time.Unix(math.MaxInt64/1000, 0)` — reachable from an `Int64` millisecond
/// timestamp — is 292 million years out.
public struct GoTime: Sendable, Hashable, Comparable {

    /// Whole seconds since 1970-01-01T00:00:00Z. May be negative.
    public let unixSeconds: Int64
    /// Nanoseconds within the second, always in `0..<1_000_000_000`.
    public let nanosecond: Int32

    private static let nanosPerSecond: Int64 = 1_000_000_000

    /// Seconds from 0001-01-01T00:00:00Z to 1970-01-01T00:00:00Z.
    /// time.go's `unixToInternal`, which fixes where Go's *zero* `Time` sits.
    ///
    /// Go writes this as `(1969*365 + 1969/4 - 1969/100 + 1969/400) * secondsPerDay`
    /// — 719,162 days × 86,400. Spelled as the value it denotes because the
    /// expression form blows the Swift 6.1 type checker's budget (HANDOFF §4); the
    /// derivation above is the check, and `gocompat/time-rfc3339` pins the result.
    static let unixToInternalSeconds: Int64 = 62_135_596_800

    /// Go: `time.Unix(sec, nsec)`. Normalises `nsec` outside `0..<1e9` into
    /// `sec`, exactly as Go does, so `Unix(0, -1)` is one nanosecond before the
    /// epoch rather than an invalid value.
    ///
    /// Traps on overflow of the *second* count while normalising an out-of-range
    /// nanosecond, which no caller in the port reaches — Prometheus always passes
    /// a nanosecond of 0.
    ///
    /// Note this is **not** the wrap that matters. Go's `time.Unix` leaves `sec`
    /// alone when `nsec` is already in range; the observable wrap is in the
    /// *calendar*, and the port reproduces it — see the file header and
    /// ``absoluteSeconds``.
    public static func unix(_ sec: Int64, _ nsec: Int64) -> GoTime {
        var seconds = sec
        var nanos = nsec
        if nanos < 0 || nanos >= nanosPerSecond {
            // time.go:1420 — Go floors here; Swift's `/` truncates, so the
            // negative case needs the adjustment spelled out.
            var n = nanos / nanosPerSecond
            if nanos % nanosPerSecond < 0 {
                n -= 1
            }
            seconds += n
            nanos -= n * nanosPerSecond
        }
        return GoTime(unixSeconds: seconds, nanosecond: Int32(nanos))
    }

    /// Requires `nanosecond` to already be normalised; use ``unix(_:_:)``
    /// otherwise.
    public init(unixSeconds: Int64, nanosecond: Int32) {
        precondition(
            nanosecond >= 0 && Int64(nanosecond) < GoTime.nanosPerSecond,
            "nanosecond out of range; use GoTime.unix(_:_:) to normalise")
        self.unixSeconds = unixSeconds
        self.nanosecond = nanosecond
    }

    /// Go: the zero `time.Time`, which is **January 1, year 1, 00:00:00 UTC** —
    /// not the Unix epoch. `IsZero` is defined against this.
    public static let zero = GoTime(
        unixSeconds: -GoTime.unixToInternalSeconds, nanosecond: 0)

    /// Go: `time.Now()`, to nanosecond resolution.
    ///
    /// `clock_gettime(CLOCK_REALTIME)` rather than Foundation's `Date`, whose
    /// `timeIntervalSince1970` is a `Double` and so cannot carry nanoseconds
    /// across the current epoch.
    public static func now() -> GoTime {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return GoTime.unix(Int64(ts.tv_sec), Int64(ts.tv_nsec))
    }

    /// Go: `Time.IsZero`.
    public var isZero: Bool { self == GoTime.zero }

    /// Go: `Time.UnixMilli` — `unixSec()*1e3 + nsec()/1e6`. Because `nanosecond`
    /// is non-negative this floors, which is what `timestamp.FromTime` relies on.
    public var unixMilliseconds: Int64 {
        let millisFromSeconds = unixSeconds * 1_000
        let millisFromNanos = Int64(nanosecond) / 1_000_000
        return millisFromSeconds + millisFromNanos
    }

    /// Go: `Time.UnixNano`. Overflows for instants more than ~292 years from the
    /// epoch, as Go's does; callers in Prometheus stay well inside that.
    public var unixNanoseconds: Int64 {
        unixSeconds * GoTime.nanosPerSecond + Int64(nanosecond)
    }

    /// Go: `Time.Add`.
    public func add(_ d: GoDuration) -> GoTime {
        let totalNanos = Int64(nanosecond) + d.nanoseconds % GoTime.nanosPerSecond
        let seconds = unixSeconds + d.nanoseconds / GoTime.nanosPerSecond
        return GoTime.unix(seconds, totalNanos)
    }

    /// Go: `Time.Sub`. Saturates at ±`maxDuration` the way Go's does.
    public func sub(_ other: GoTime) -> GoDuration {
        let secondsDelta = unixSeconds - other.unixSeconds
        let nanosDelta = Int64(nanosecond) - Int64(other.nanosecond)
        let (scaled, overflow) = secondsDelta.multipliedReportingOverflow(
            by: GoTime.nanosPerSecond)
        if overflow {
            return secondsDelta > 0 ? GoDuration.max : GoDuration.min
        }
        let (total, addOverflow) = scaled.addingReportingOverflow(nanosDelta)
        if addOverflow {
            return secondsDelta > 0 ? GoDuration.max : GoDuration.min
        }
        return GoDuration(nanoseconds: total)
    }

    /// Go: `Time.Before`.
    public func before(_ other: GoTime) -> Bool { self < other }
    /// Go: `Time.After`.
    public func after(_ other: GoTime) -> Bool { other < self }
    /// Go: `Time.Equal`. Identical to `==` here, since there is no location or
    /// monotonic reading to differ on.
    public func equal(_ other: GoTime) -> Bool { self == other }

    public static func < (lhs: GoTime, rhs: GoTime) -> Bool {
        if lhs.unixSeconds != rhs.unixSeconds {
            return lhs.unixSeconds < rhs.unixSeconds
        }
        return lhs.nanosecond < rhs.nanosecond
    }

    // MARK: - Calendar

    /// Go: `unixToAbsolute` (time.go:564) — seconds from the absolute zero instant
    /// to the Unix epoch.
    ///
    /// Go derives it as `unixToInternal + internalToAbsolute`, where
    /// `internalToAbsolute` is `(292277022400*365.2425 + 306) * 86400` folded at
    /// arbitrary constant precision. Spelled as the value it denotes, as
    /// ``unixToInternalSeconds`` is and for the same Swift 6.1 reason; the
    /// derivation is the check and `gocompat/time-calendar` pins the result.
    static let unixToAbsoluteSeconds: Int64 = 9_223_372_028_741_760_000

    /// ``unixToAbsoluteSeconds`` in days. Exact: the constant is a whole number of
    /// days, which is what lets the day and the second-of-day be split before the
    /// offset is applied.
    static let absoluteDaysToUnixEpoch: Int64 = 106_751_991_073_400

    /// Go: `Time.absSec()` (time.go:784) for the UTC location — the absolute second
    /// count as a `UInt64`.
    ///
    /// The wrapping `&+` and the `UInt64(bitPattern:)` are both Go's, and both are
    /// observable. See the file header for which inputs reach the wrap and why
    /// `year(vector(-Inf))` is +292277026596 rather than a large negative year.
    @usableFromInline
    var absoluteSeconds: UInt64 {
        UInt64(bitPattern: unixSeconds &+ GoTime.unixToAbsoluteSeconds)
    }

    /// The absolute day count, and the second within that day.
    ///
    /// Go: `absSeconds.days()` is `abs / secondsPerDay` and `absSeconds.clock()`
    /// takes `abs % secondsPerDay` — both **unsigned**, so there is no floor-versus-
    /// truncate question to get wrong. That is the other reason to go through `abs`:
    /// dividing a negative Unix second count needs a floor adjustment, and dividing
    /// the unsigned absolute count does not.
    @usableFromInline
    var absoluteDayAndSecond: (day: Int64, secondOfDay: Int64) {
        let abs = absoluteSeconds
        return (Int64(abs / 86_400), Int64(abs % 86_400))
    }

    /// Days from 1970-01-01 to this instant's day, floored — the input Hinnant's
    /// algorithm below wants.
    @usableFromInline
    var utcDaysSinceEpoch: Int64 {
        absoluteDayAndSecond.day - GoTime.absoluteDaysToUnixEpoch
    }

    /// Proleptic Gregorian year, month and day in UTC.
    ///
    /// Howard Hinnant's `civil_from_days`, which agrees with Go's Neri-Schneider
    /// `absDays.yearYday`/`split` over the whole `Int64` range — Go uses
    /// astronomical year numbering, so year 0 exists and is 1 BC. Verified against
    /// Go on 400,201 second values including the wrap band, not assumed.
    public var utcDate: (year: Int64, month: Int, day: Int) {
        GoTime.civilFromDays(utcDaysSinceEpoch)
    }

    /// Go: Hinnant's `civil_from_days`, split out because ``utcYearDay`` needs it
    /// for its own year as well.
    @usableFromInline
    static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
        // Shift the epoch to 0000-03-01 so leap days land at the end of the era.
        var z = days
        z += 719_468
        var era = z / 146_097
        if z % 146_097 < 0 {
            era -= 1
        }
        let dayOfEra = z - era * 146_097  // 0...146096

        // yearOfEra = (doe - doe/1460 + doe/36524 - doe/146096) / 365. The whole
        // numerator is divided by 365 — splitting the division across the terms
        // is a different (wrong) function. Spelled stepwise both to keep that
        // clear and because Swift 6.1's type checker budget dislikes long chains.
        var numerator = dayOfEra
        numerator -= dayOfEra / 1_460
        numerator += dayOfEra / 36_524
        numerator -= dayOfEra / 146_096
        let yearOfEra = numerator / 365  // 0...399

        var year = yearOfEra + era * 400

        // dayOfYear = doe - (365*yoe + yoe/4 - yoe/100)
        var daysBeforeYear = 365 * yearOfEra
        daysBeforeYear += yearOfEra / 4
        daysBeforeYear -= yearOfEra / 100
        let dayOfYear = dayOfEra - daysBeforeYear  // 0...365

        let mp = (5 * dayOfYear + 2) / 153  // 0...11
        var day = dayOfYear
        day -= (153 * mp + 2) / 5
        day += 1  // 1...31
        var month = mp + 3
        if mp >= 10 {
            month = mp - 9
        }
        if month <= 2 {
            year += 1
        }
        return (year, Int(month), Int(day))
    }

    /// Hinnant's `days_from_civil`, the inverse of ``civilFromDays(_:)``.
    ///
    /// Only ``utcYearDay`` needs it, and only for January 1, but it is written in
    /// full because a January-only version would hide the March-shifted year that
    /// makes the arithmetic work.
    @usableFromInline
    static func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
        var y = year
        if month <= 2 {
            y -= 1
        }
        var era = y / 400
        if y % 400 < 0 {
            era -= 1
        }
        let yearOfEra = y - era * 400  // 0...399
        let m = Int64(month)
        let mp = (m + 9) % 12  // 0...11, March = 0
        var dayOfYear = (153 * mp + 2) / 5
        dayOfYear += Int64(day) - 1  // 0...365
        var dayOfEra = yearOfEra * 365
        dayOfEra += yearOfEra / 4
        dayOfEra -= yearOfEra / 100
        dayOfEra += dayOfYear  // 0...146096
        var days = era * 146_097
        days += dayOfEra
        days -= 719_468
        return days
    }

    /// Clock time of day in UTC.
    ///
    /// Go: `absSeconds.clock()`, over the unsigned absolute count.
    public var utcClock: (hour: Int, minute: Int, second: Int) {
        let secondOfDay = absoluteDayAndSecond.secondOfDay
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return (Int(hour), Int(minute), Int(second))
    }

    /// Go: `Time.Weekday()` — Sunday is 0.
    ///
    /// `absDays.weekday()` is `(days + Wednesday) % 7`, because March 1 of the
    /// absolute year was a Wednesday. Unsigned throughout, so no sign correction.
    public var utcWeekday: Int {
        Int((UInt64(bitPattern: absoluteDayAndSecond.day) &+ 3) % 7)
    }

    /// Go: `Time.YearDay()` — 1-based, so January 1 is 1.
    ///
    /// Go reads it out of the Neri-Schneider split; the port takes the difference
    /// from January 1 of its own year, which is the same number and reuses
    /// ``daysFromCivil(year:month:day:)``.
    public var utcYearDay: Int {
        let days = utcDaysSinceEpoch
        let (year, _, _) = GoTime.civilFromDays(days)
        return Int(days - GoTime.daysFromCivil(year: year, month: 1, day: 1)) + 1
    }

    /// Go: `absoluteYears` (time.go:550) — the years subtracted from internal time
    /// to reach absolute time, defining the absolute zero instant as
    /// March 1, -292277022400.
    static let absoluteYears: UInt64 = 292_277_022_400

    /// Go: `dateToAbsDays` (time.go:599) — absolute days for a year/month/day, where
    /// the day may be **out of range**, which is the whole point of it.
    ///
    /// Transcribed including the two Neri-Schneider strength reductions
    /// (`(979*amonth - 2919) >> 5` for the March-based year-day, and the `/4` forms
    /// of `cday`/`centurydays`), because they are what the arithmetic below has to
    /// wrap the same way. Every operation is unsigned or explicitly wrapping, as
    /// Go's is: `uint64(year)` on a negative year is a reinterpretation, not a
    /// conversion.
    @usableFromInline
    static func dateToAbsDays(year: Int64, month: Int, day: Int) -> UInt64 {
        var amonth = UInt32(truncatingIfNeeded: month)
        var janFeb: UInt32 = 0
        if amonth < 3 {
            janFeb = 1
        }
        amonth &+= 12 &* janFeb
        var y = UInt64(bitPattern: year)
        y &-= UInt64(janFeb)
        y &+= absoluteYears

        // ayday := (153*amonth - 457) / 5, as Go's cheaper shift form.
        let ayday = (979 &* amonth &- 2919) >> 5

        let century = y / 100
        let cyear = UInt32(truncatingIfNeeded: y % 100)
        let cday = 1461 &* cyear / 4
        let centuryDays = 146_097 &* century / 4

        var offset = Int64(cday &+ ayday)
        offset &+= Int64(day)
        offset &-= 1
        return centuryDays &+ UInt64(bitPattern: offset)
    }

    /// Go: `funcDaysInMonth`'s `32 - time.Date(year, month, 32, 0, 0, 0, 0, UTC).Day()`.
    ///
    /// Upstream gets the month's length by asking `time.Date` to normalise an
    /// out-of-range day: day 32 of a 31-day month is day 1 of the next, so
    /// `32 - Day()` is the length of the original month.
    ///
    /// **The obvious shortcut — a month-length table plus a leap-year test — is
    /// wrong, and the fixture is what said so.** At the extreme years the date
    /// functions can reach, `time.Date`'s own arithmetic wraps: for year
    /// 292277026854 in January, Go returns **7**, not 31, because
    /// `int64(dateToAbsDays(…)) * secondsPerDay` (time.go's `Date`) overflows and the
    /// `Day()` read on the far side lands somewhere else entirely. A table agreed
    /// with Go on 4,659 of 4,664 corpus seconds and disagreed on the five extreme
    /// ones.
    ///
    /// So this reproduces the round trip: `dateToAbsDays`, the wrapping multiply and
    /// offset that `Date` applies, the ordinary calendar read on the far side, and
    /// finally the `32 -`. Both wraps are Go's and both are load-bearing.
    /// PORTING.md quirk 47.
    public static func daysInMonth(year: Int64, month: Int) -> Int {
        let absDays = dateToAbsDays(year: year, month: month, day: 32)
        // Go: `unix := int64(dateToAbsDays(...))*secondsPerDay + 0 + absoluteToUnix`,
        // where `absoluteToUnix` is `-unixToAbsolute`. Both operations wrap.
        var unix = Int64(bitPattern: absDays) &* 86_400
        unix &-= unixToAbsoluteSeconds
        return 32 - GoTime(unixSeconds: unix, nanosecond: 0).utcDate.day
    }

    // MARK: - Formatting

    /// Go: `t.UTC().Format(time.RFC3339)`.
    ///
    /// Only the UTC case, which renders the offset as a bare `Z`. The year goes
    /// through `appendInt(b, year, 4)`, so it is zero-padded to four digits but
    /// **not** truncated: year 10000 prints five digits and a negative year
    /// prints a leading `-` before the padded absolute value. Pinned by
    /// `Fixtures/gocompat/time-rfc3339.jsonl`.
    public var rfc3339UTC: String {
        let (year, month, day) = utcDate
        let (hour, minute, second) = utcClock

        var out = GoTime.appendInt(year, width: 4)
        out += "-"
        out += GoTime.appendInt(Int64(month), width: 2)
        out += "-"
        out += GoTime.appendInt(Int64(day), width: 2)
        out += "T"
        out += GoTime.appendInt(Int64(hour), width: 2)
        out += ":"
        out += GoTime.appendInt(Int64(minute), width: 2)
        out += ":"
        out += GoTime.appendInt(Int64(second), width: 2)
        out += "Z"
        return out
    }

    /// Go: `format.go`'s `appendInt` — sign, then the absolute value zero-padded
    /// to at least `width` digits.
    private static func appendInt(_ value: Int64, width: Int) -> String {
        var digits = ""
        var magnitude = value.magnitude
        if magnitude == 0 {
            digits = "0"
        } else {
            while magnitude > 0 {
                let d = magnitude % 10
                digits = String(UnicodeScalar(UInt8(ascii: "0") + UInt8(d))) + digits
                magnitude /= 10
            }
        }
        while digits.count < width {
            digits = "0" + digits
        }
        return value < 0 ? "-" + digits : digits
    }
}
