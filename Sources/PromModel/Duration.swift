//===----------------------------------------------------------------------===//
// Ported from github.com/prometheus/common@v0.69.0 model/time.go — the version
// pinned by prometheus v3.13.2's go.mod.
//
// This is `model.Duration`, NOT Go's `time.Duration` (that one is GoCompat's
// `GoDuration`). The two differ in both directions:
//
//   - Parsing: `model.ParseDuration` takes PromQL's `1h30m` grammar with a
//     fixed 365d year and 7d week, requires units in descending order, and
//     rejects negatives. `time.ParseDuration` accepts none of that.
//   - Formatting: `model.Duration.String()` works in whole milliseconds and
//     emits y/w/d/h/m/s/ms; `time.Duration.String()` emits ns/µs/ms/s/m/h with
//     fractions.
//
// Both directions are user-facing here: `String()` renders every `offset` and
// range in `printer.go`, and the parse errors reach `ParseErr` verbatim.
//
// The name avoids `Duration`, which would collide with the Swift standard
// library's own `Duration` at every use site.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `model.Duration` — a `time.Duration` with PromQL's parsing and
/// formatting rules. The stored value is nanoseconds, as in Go.
public struct PromDuration: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public static func < (a: PromDuration, b: PromDuration) -> Bool {
        a.nanoseconds < b.nanoseconds
    }

    // MARK: - Parsing

    /// Go: `model.ParseDuration`'s error set. The `description` of each case
    /// reproduces Go's message byte-for-byte — these strings reach users through
    /// `ParseErr`, so they are contract, not diagnostics.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        /// Go: `not a valid duration string: %q`.
        case notValid(String)
        /// Go: `unknown unit %q in duration %q`.
        case unknownUnit(unit: String, duration: String)
        case outOfRange

        public var description: String {
            switch self {
            case .empty:
                return "empty duration string"
            case .notValid(let orig):
                return "not a valid duration string: \(GoStrconv.quote(orig))"
            case .unknownUnit(let unit, let duration):
                return "unknown unit \(GoStrconv.quote(unit)) in duration \(GoStrconv.quote(duration))"
            case .outOfRange:
                return "duration out of range"
            }
        }
    }

    /// Go: `unitMap`. `pos` orders the units so they can be required to appear
    /// biggest-first — which is what stops `1m1d` being read as a month plus a
    /// day. `mult` is nanoseconds per unit.
    private static let unitMap: [String: (pos: Int, mult: UInt64)] = [
        "ms": (7, 1_000_000),
        "s": (6, 1_000_000_000),
        "m": (5, 60 * 1_000_000_000),
        "h": (4, 60 * 60 * 1_000_000_000),
        "d": (3, 24 * 60 * 60 * 1_000_000_000),
        "w": (2, 7 * 24 * 60 * 60 * 1_000_000_000),
        "y": (1, 365 * 24 * 60 * 60 * 1_000_000_000),
    ]

    /// Go: `model.ParseDuration`. A year is always 365d and a week always 7d.
    /// Negative durations are not accepted.
    public static func parse(_ s: String) throws -> PromDuration {
        try parse(Array(s.utf8), orig: s)
    }

    /// The byte-level primitive. A duration string is ASCII by construction —
    /// anything else fails — but the caller may hold arbitrary bytes, and `orig`
    /// has to be the *original* text because it appears in the error messages.
    public static func parse(_ bytes: [UInt8], orig: String) throws -> PromDuration {
        // Go special-cases these two before the loop: a bare "0" is legal
        // without a unit, and "" gets its own message rather than the generic one.
        if bytes == [UInt8(ascii: "0")] { return PromDuration(nanoseconds: 0) }
        if bytes.isEmpty { throw ParseError.empty }

        var i = 0
        var dur: UInt64 = 0
        var lastUnitPos = 0

        while i < bytes.count {
            guard isDigit(bytes[i]) else { throw ParseError.notValid(orig) }

            // Consume [0-9]*.
            let numStart = i
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            guard let v = parseUInt64(bytes[numStart..<i]) else {
                // Go: strconv.ParseUint failing (only possible on overflow here)
                // is folded into the generic message, not reported as a range error.
                throw ParseError.notValid(orig)
            }

            // Consume the unit: everything up to the next digit.
            let unitStart = i
            while i < bytes.count, !isDigit(bytes[i]) { i += 1 }
            if i == unitStart { throw ParseError.notValid(orig) }
            let u = String(decoding: bytes[unitStart..<i], as: UTF8.self)

            guard let unit = unitMap[u] else {
                throw ParseError.unknownUnit(unit: u, duration: orig)
            }
            // Units must go from biggest to smallest, and none may repeat.
            if unit.pos <= lastUnitPos { throw ParseError.notValid(orig) }
            lastUnitPos = unit.pos

            // Go: `v > 1<<63/unit.mult`, an unsigned division — this is the
            // "> ~290 years" overflow guard on time.Duration.
            if v > (UInt64(1) << 63) / unit.mult { throw ParseError.outOfRange }
            dur = dur &+ v &* unit.mult
            if dur > (UInt64(1) << 63) - 1 { throw ParseError.outOfRange }
        }

        return PromDuration(nanoseconds: Int64(bitPattern: dur))
    }

    /// Go: `isdigit` — ASCII only, deliberately.
    private static func isDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    /// Go: `strconv.ParseUint(s, 10, 0)` over a known-all-digits slice. Returns
    /// nil on overflow, which is the only way it can fail here.
    private static func parseUInt64(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        var acc: UInt64 = 0
        for b in bytes {
            let (m, mo) = acc.multipliedReportingOverflow(by: 10)
            if mo { return nil }
            let (a, ao) = m.addingReportingOverflow(UInt64(b - UInt8(ascii: "0")))
            if ao { return nil }
            acc = a
        }
        return acc
    }

    // MARK: - Formatting

    /// Go: `model.Duration.String()`.
    ///
    /// Note it works in whole **milliseconds**: anything finer is truncated away,
    /// so a sub-millisecond duration renders as `0s`. Years and weeks are only
    /// emitted when they divide the remainder exactly, because `90d` reads more
    /// easily than `12w6d`.
    public var description: String {
        var ms = nanoseconds / 1_000_000
        if ms == 0 { return "0s" }

        var sign = ""
        if ms < 0 {
            sign = "-"
            ms = -ms
        }

        var r = ""
        // `exact` marks the units that are skipped unless they divide evenly.
        func f(_ unit: String, _ mult: Int64, _ exact: Bool) {
            if exact && ms % mult != 0 { return }
            let v = ms / mult
            if v > 0 {
                r += "\(v)\(unit)"
                ms -= v * mult
            }
        }

        f("y", 1000 * 60 * 60 * 24 * 365, true)
        f("w", 1000 * 60 * 60 * 24 * 7, true)
        f("d", 1000 * 60 * 60 * 24, false)
        f("h", 1000 * 60 * 60, false)
        f("m", 1000 * 60, false)
        f("s", 1000, false)
        f("ms", 1, false)

        return sign + r
    }

    /// `time.Duration.Seconds()` — used where the grammar turns a DURATION item
    /// into a `NumberLiteral`.
    public var seconds: Double { Double(nanoseconds) / 1e9 }

    /// `time.Duration.Milliseconds()` — truncating, as in Go.
    public var milliseconds: Int64 { nanoseconds / 1_000_000 }
}
