//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/internal/strconv/atoi.go — `ParseUint` and `ParseInt`,
// plus `*NumError.Error()` from src/strconv/number.go.
//
// The PromQL parser needs all three:
//
//   - `parser.number()` tries `ParseInt(val, 0, 64)` first and only falls back to
//     ParseFloat, which is why `0755` is 493 and `0x1f` is 31 rather than being
//     read as decimal.
//   - the `uint` grammar rule uses `ParseUint(val, 10, 64)`, and its error
//     reaches the user as `invalid repetition in series values: %s`.
//   - `%s` on a strconv error renders the whole `NumError`, not just "invalid
//     syntax" — `strconv.ParseFloat: parsing "1e309": value out of range`. Both
//     the function name and the quoted input are part of the message.
//===----------------------------------------------------------------------===//

/// Go: `*strconv.NumError` — the error strconv's parse functions actually return.
///
/// `description` is Go's `Error()`: `"strconv." + Func + ": parsing " +
/// Quote(Num) + ": " + Err`.
public struct GoNumError: Error, Equatable, CustomStringConvertible {
    /// The name of the failing function, without the package: `ParseInt`.
    public var fn: String
    /// The input, reproduced verbatim. Bytes, not a String: `%q` escapes invalid
    /// UTF-8 byte by byte, and decoding through U+FFFD first would change the
    /// message (ADR-9).
    public var num: [UInt8]
    public var err: GoStrconvError

    public init(fn: String, num: [UInt8], err: GoStrconvError) {
        self.fn = fn
        self.num = num
        self.err = err
    }

    public init(fn: String, num: String, err: GoStrconvError) {
        self.init(fn: fn, num: Array(num.utf8), err: err)
    }

    public var description: String {
        "strconv.\(fn): parsing \(GoStrconv.quote(bytes: num)): \(err)"
    }
}

extension GoStrconv {

    /// Go: `strconv.ParseUint(s, base, bitSize)`.
    ///
    /// Only base 0 and 10 are reachable from the port, but the full base range is
    /// implemented because narrowing it would be a silent divergence if a later
    /// phase needs base 16.
    ///
    /// On `.range` Go still returns a value — the maximum for the bit size — and
    /// callers do read it, so the pair is returned rather than thrown.
    public static func parseUint(
        _ s: String, base: Int, bitSize: Int
    ) -> (value: UInt64, error: GoNumError?) {
        parseUint(Array(s.utf8), base: base, bitSize: bitSize)
    }

    public static func parseUint(
        _ input: [UInt8], base: Int, bitSize: Int
    ) -> (value: UInt64, error: GoNumError?) {
        let (v, err) = parseUintBytes(input, base: base, bitSize: bitSize)
        if let err { return (v, GoNumError(fn: "ParseUint", num: input, err: err)) }
        return (v, nil)
    }

    /// Go: `strconv.ParseInt(s, base, bitSize)`.
    public static func parseInt(
        _ s: String, base: Int, bitSize: Int
    ) -> (value: Int64, error: GoNumError?) {
        parseInt(Array(s.utf8), base: base, bitSize: bitSize)
    }

    public static func parseInt(
        _ input: [UInt8], base: Int, bitSize: Int
    ) -> (value: Int64, error: GoNumError?) {
        let numError = { (e: GoStrconvError) in
            GoNumError(fn: "ParseInt", num: input, err: e)
        }

        var bytes = input
        if bytes.isEmpty { return (0, numError(.syntax)) }

        // Pick off a leading sign.
        var neg = false
        if bytes[0] == UInt8(ascii: "+") {
            bytes.removeFirst()
        } else if bytes[0] == UInt8(ascii: "-") {
            bytes.removeFirst()
            neg = true
        }

        let (un, err) = parseUintBytes(bytes, base: base, bitSize: bitSize)
        // A range error is carried forward, because ParseInt's own range check
        // below still has to run on the clamped value. Any other error is final.
        if let err, err != .range { return (0, numError(err)) }

        let effectiveBitSize = bitSize == 0 ? 64 : bitSize
        let cutoff = UInt64(1) << UInt(effectiveBitSize - 1)
        if !neg && un >= cutoff {
            return (Int64(cutoff - 1), numError(.range))
        }
        if neg && un > cutoff {
            // -cutoff, computed without overflowing on Int64.min.
            return (Int64(bitPattern: ~cutoff &+ 1), numError(.range))
        }
        // Go: `n := int64(un)`, a wrapping conversion. `un` can be exactly 2^63
        // here (a negative at the very edge of the range), which `Int64(_:)` would
        // trap on and Go turns into Int64.min.
        var n = Int64(bitPattern: un)
        if neg { n = 0 &- n }
        return (n, nil)
    }

    /// The body of Go's `ParseUint`, over bytes and returning the bare error so
    /// `parseInt` can inspect it before wrapping.
    private static func parseUintBytes(
        _ input: [UInt8], base baseIn: Int, bitSize bitSizeIn: Int
    ) -> (UInt64, GoStrconvError?) {
        if input.isEmpty { return (0, .syntax) }

        let base0 = baseIn == 0
        let s0 = input
        var s = input
        var base = baseIn

        if base >= 2 && base <= 36 {
            // A valid explicit base; nothing to do.
        } else if base == 0 {
            // Go infers the base from the prefix. Note the `default` arm: a bare
            // leading zero means octal, which is what makes `0755` 493.
            base = 10
            if s[0] == UInt8(ascii: "0") {
                if s.count >= 3 && lowerASCII(s[1]) == UInt8(ascii: "b") {
                    base = 2
                    s.removeFirst(2)
                } else if s.count >= 3 && lowerASCII(s[1]) == UInt8(ascii: "o") {
                    base = 8
                    s.removeFirst(2)
                } else if s.count >= 3 && lowerASCII(s[1]) == UInt8(ascii: "x") {
                    base = 16
                    s.removeFirst(2)
                } else {
                    base = 8
                    s.removeFirst(1)
                }
            }
        } else {
            // Go: ErrBase. Unreachable from this port, and there is no PromQL
            // message for it, so it is reported as a syntax error.
            return (0, .syntax)
        }

        let bitSize = bitSizeIn == 0 ? 64 : bitSizeIn
        if bitSizeIn < 0 || bitSizeIn > 64 { return (0, .syntax) }

        // The smallest n for which n*base overflows UInt64.
        let cutoff = UInt64.max / UInt64(base) + 1
        let maxVal: UInt64 = bitSize == 64 ? UInt64.max : (UInt64(1) << UInt(bitSize)) - 1

        var underscores = false
        var n: UInt64 = 0
        for c in s {
            var d: UInt8
            if c == UInt8(ascii: "_") && base0 {
                underscores = true
                continue
            } else if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                d = c - UInt8(ascii: "0")
            } else if lowerASCII(c) >= UInt8(ascii: "a") && lowerASCII(c) <= UInt8(ascii: "z") {
                d = lowerASCII(c) - UInt8(ascii: "a") + 10
            } else {
                return (0, .syntax)
            }

            if d >= UInt8(base) { return (0, .syntax) }

            if n >= cutoff { return (maxVal, .range) }
            n = n &* UInt64(base)

            let n1 = n &+ UInt64(d)
            if n1 < n || n1 > maxVal { return (maxVal, .range) }
            n = n1
        }

        // Placement is validated only after the digits parse, and against the
        // string as it was *before* the base prefix was stripped.
        if underscores && !GoFloat.underscoreOK(s0) { return (0, .syntax) }

        return (n, nil)
    }

    /// Go: `lower` — ASCII-only case folding by setting bit 5. Note this maps
    /// some non-letters too, which is deliberate: Go relies on the subsequent
    /// range check to reject them.
    private static func lowerASCII(_ c: UInt8) -> UInt8 { c | (UInt8(ascii: "a") - UInt8(ascii: "A")) }
}
