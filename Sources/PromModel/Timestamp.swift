//===----------------------------------------------------------------------===//
// Ported from model/timestamp/timestamp.go @ v3.13.2
//===----------------------------------------------------------------------===//

public import GoCompat

/// Go: `package timestamp` — conversions between `time.Time` and the integer
/// milliseconds Prometheus uses internally.
public enum Timestamp: Sendable {

    /// Go: `FromTime`, which is `t.UnixMilli()`.
    public static func fromTime(_ t: GoTime) -> Int64 {
        t.unixMilliseconds
    }

    /// Go: `Time` — `time.UnixMilli(ts).UTC()`.
    ///
    /// `time.UnixMilli` is `Unix(ms/1e3, (ms%1e3)*1e6)`, whose remainder is
    /// negative for negative `ms`; `GoTime.unix` normalises that back, so a
    /// negative millisecond timestamp lands on the right second.
    public static func time(_ ts: Int64) -> GoTime {
        GoTime.unix(ts / 1_000, (ts % 1_000) * 1_000_000)
    }

    /// Go: `FromFloatSeconds` — `int64(math.Round(ts * 1000))`.
    ///
    /// `math.Round` is half-away-from-zero, which is Swift's
    /// `rounded(.toNearestOrAwayFromZero)` and *not* `rounded()`'s default
    /// banker-free tie handling on `.toNearestOrEven`. The `Int64` conversion
    /// truncates whatever is left; a value outside `Int64`'s range is undefined
    /// in Go and traps here rather than producing a silently wrong timestamp.
    public static func fromFloatSeconds(_ ts: Double) -> Int64 {
        Int64((ts * 1_000).rounded(.toNearestOrAwayFromZero))
    }
}
