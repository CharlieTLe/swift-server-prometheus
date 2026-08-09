//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/time/time.go — Duration.String, fmtFrac, fmtInt.
//
// Reproduces Go's "72h3m0.5s" rendering. This is a formatting parity surface:
// durations appear in Prometheus error messages and API output.
//
// Note this is Go's `time.Duration`, NOT Prometheus's `model.Duration`, which has
// its own distinct format ("1d2h3m4s", no sub-second units) and lives in
// PromModel.
//===----------------------------------------------------------------------===//

/// Go: `time.Duration` — a count of nanoseconds.
public struct GoDuration: Sendable, Hashable, Comparable, CustomStringConvertible {

    public var nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public static let nanosecond = GoDuration(nanoseconds: 1)
    public static let microsecond = GoDuration(nanoseconds: 1_000)
    public static let millisecond = GoDuration(nanoseconds: 1_000_000)
    public static let second = GoDuration(nanoseconds: 1_000_000_000)
    public static let minute = GoDuration(nanoseconds: 60 * 1_000_000_000)
    public static let hour = GoDuration(nanoseconds: 60 * 60 * 1_000_000_000)

    /// Go: `minDuration` / `maxDuration` (time.go). `Time.Sub` saturates at these
    /// rather than wrapping.
    public static let min = GoDuration(nanoseconds: Int64.min)
    public static let max = GoDuration(nanoseconds: Int64.max)

    public static func < (a: GoDuration, b: GoDuration) -> Bool {
        a.nanoseconds < b.nanoseconds
    }

    /// Go: `Duration.String()`.
    ///
    /// Leading zero units are omitted. Durations below one second switch to a
    /// smaller unit so the leading digit is non-zero. Zero renders as "0s".
    /// Hours are the largest unit — Go stops there because days vary in length.
    public var description: String {
        // Go formats backwards into a 32-byte buffer; we mirror that so the digit
        // and unit ordering is identical by construction.
        var buf = [UInt8](repeating: 0, count: 32)
        var w = buf.count

        // Magnitude as unsigned so Int64.min does not overflow on negation.
        let neg = nanoseconds < 0
        var u = neg ? UInt64(bitPattern: Int64(0) &- nanoseconds) : UInt64(nanoseconds)

        if u < 1_000_000_000 {
            // Sub-second: pick the unit that gives a non-zero leading digit.
            var prec = 0
            w -= 1
            buf[w] = UInt8(ascii: "s")
            w -= 1
            if u == 0 {
                buf[w] = UInt8(ascii: "0")
                return String(decoding: buf[w...], as: UTF8.self)
            } else if u < 1_000 {
                prec = 0
                buf[w] = UInt8(ascii: "n")
            } else if u < 1_000_000 {
                prec = 3
                // U+00B5 MICRO SIGN is two bytes: 0xC2 0xB5.
                w -= 1
                buf[w] = 0xC2
                buf[w + 1] = 0xB5
            } else {
                prec = 6
                buf[w] = UInt8(ascii: "m")
            }
            (w, u) = Self.fmtFrac(&buf, w, u, prec)
            w = Self.fmtInt(&buf, w, u)
        } else {
            w -= 1
            buf[w] = UInt8(ascii: "s")

            (w, u) = Self.fmtFrac(&buf, w, u, 9)

            // u is now whole seconds.
            w = Self.fmtInt(&buf, w, u % 60)
            u /= 60

            // u is now whole minutes.
            if u > 0 {
                w -= 1
                buf[w] = UInt8(ascii: "m")
                w = Self.fmtInt(&buf, w, u % 60)
                u /= 60

                // u is now whole hours. Stop here: days differ in length.
                if u > 0 {
                    w -= 1
                    buf[w] = UInt8(ascii: "h")
                    w = Self.fmtInt(&buf, w, u)
                }
            }
        }

        if neg {
            w -= 1
            buf[w] = UInt8(ascii: "-")
        }
        return String(decoding: buf[w...], as: UTF8.self)
    }

    /// Go: `fmtFrac`. Writes the fraction, omitting trailing zeros and the
    /// decimal point itself when nothing was printed.
    private static func fmtFrac(
        _ buf: inout [UInt8], _ start: Int, _ v: UInt64, _ prec: Int
    ) -> (Int, UInt64) {
        var w = start
        var v = v
        var printed = false
        for _ in 0..<prec {
            let digit = v % 10
            printed = printed || digit != 0
            if printed {
                w -= 1
                buf[w] = UInt8(digit) + UInt8(ascii: "0")
            }
            v /= 10
        }
        if printed {
            w -= 1
            buf[w] = UInt8(ascii: ".")
        }
        return (w, v)
    }

    /// Go: `fmtInt`.
    private static func fmtInt(_ buf: inout [UInt8], _ start: Int, _ v: UInt64) -> Int {
        var w = start
        var v = v
        if v == 0 {
            w -= 1
            buf[w] = UInt8(ascii: "0")
        } else {
            while v > 0 {
                w -= 1
                buf[w] = UInt8(v % 10) + UInt8(ascii: "0")
                v /= 10
            }
        }
        return w
    }
}
