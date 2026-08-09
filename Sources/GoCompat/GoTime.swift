//===----------------------------------------------------------------------===//
// Ported from Go's time package (time.go, format_rfc3339.go) @ go1.25
//
// A deliberately small subset of `time.Time`: the instant, the arithmetic
// Prometheus does on it, and RFC 3339 rendering in UTC.
//
// What is *not* here: locations, monotonic clock readings, the general
// `Format`/`Parse` layout machinery, and the calendar accessors nothing in the
// port calls yet. Prometheus treats query times as instants and converts them to
// integer milliseconds almost immediately (`model/timestamp`), so the full type
// would be a large compatibility surface bought for nothing. Grow this file when
// a port actually needs more, not pre-emptively.
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
    /// Traps on overflow of the second count, which Go cannot express either —
    /// its own `Unix` silently wraps, and reproducing a wrap would hide a bug
    /// rather than match anything observable.
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

    /// Proleptic Gregorian year, month and day in UTC.
    ///
    /// Howard Hinnant's `civil_from_days`, which agrees with Go's `absDate` over
    /// the whole `Int64` range including year 0 — Go uses astronomical year
    /// numbering, so year 0 exists and is 1 BC.
    public var utcDate: (year: Int64, month: Int, day: Int) {
        // Floor-divide the second count into days; Swift's `/` truncates.
        let secondsPerDay: Int64 = 86_400
        var days = unixSeconds / secondsPerDay
        if unixSeconds % secondsPerDay < 0 {
            days -= 1
        }

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

    /// Clock time of day in UTC.
    public var utcClock: (hour: Int, minute: Int, second: Int) {
        let secondsPerDay: Int64 = 86_400
        var secondOfDay = unixSeconds % secondsPerDay
        if secondOfDay < 0 {
            secondOfDay += secondsPerDay
        }
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return (Int(hour), Int(minute), Int(second))
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
