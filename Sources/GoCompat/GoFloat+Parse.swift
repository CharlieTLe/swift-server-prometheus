//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/internal/strconv/atof.go and atoi.go (underscoreOK)
//
// Reproduces `strconv.ParseFloat(s, 64)`: which strings are accepted, which
// error is returned, and the exact bits produced.
//
// Strategy: Go's *syntax* rules are reimplemented here (they are idiosyncratic —
// see the notes below), while the decimal→binary conversion is delegated to
// Swift's `Double(String)`. Both are correctly rounded to nearest-even, and the
// forms Go accepts were verified to produce identical bit patterns in Swift,
// including "1.", ".5", "1.e5", hex floats and overflow/underflow. Underscores
// are the sole exception (Swift rejects them), so they are stripped after their
// placement has been validated.
//===----------------------------------------------------------------------===//

/// Go: `strconv.ErrSyntax` / `strconv.ErrRange`.
public enum GoStrconvError: Error, Equatable, CustomStringConvertible {
    case syntax
    case range

    public var description: String {
        switch self {
        case .syntax: return "invalid syntax"
        case .range: return "value out of range"
        }
    }
}

extension GoFloat {

    /// Go's `nan()` returns this exact payload — not an arbitrary NaN.
    /// It coincides with Prometheus's `value.NormalNaN`. Note Swift's
    /// `Double.nan` is `0x7FF8000000000000`, one bit different.
    public static let goNaNBits: UInt64 = 0x7FF8_0000_0000_0001

    /// Equivalent to `strconv.ParseFloat(s, 64)`.
    ///
    /// Throws `.syntax` for malformed input and `.range` when a well-formed
    /// value overflows, in which case Go still yields ±Inf — use
    /// `parseAllowingRange` if you want Go's value-plus-error pair.
    public static func parse(_ s: String) throws -> Double {
        let (v, err) = parseAllowingRange(s)
        if let err { throw err }
        return v
    }

    /// Go's `(f, err)` pair. On `.range`, `value` is ±Inf exactly as Go returns.
    ///
    /// Note underflow is **not** a range error in Go: "1e-400" yields 0 and no
    /// error, while "1e400" yields +Inf and ErrRange.
    public static func parseAllowingRange(_ s: String) -> (value: Double, error: GoStrconvError?) {
        let u = Array(s.utf8)

        // Specials first. Go's `special()` has a quirk worth preserving: the sign
        // case falls through to the 'i' case only, so "+Inf"/"-Infinity" parse but
        // "+nan"/"-nan" are syntax errors.
        if let f = special(u) { return (f, nil) }

        guard let form = validate(u) else { return (0, .syntax) }

        // Normalise before delegating:
        //  - underscores are validated above but Swift's parser rejects them;
        //  - Swift rejects an uppercase hex prefix/exponent ("0X1P-2"), which Go
        //    accepts, so lowercase everything. Safe here because specials
        //    ("Inf"/"NaN") were already handled and digits/signs are unaffected.
        let needsNormalising = form.hasUnderscores || u.contains { $0 >= 0x41 && $0 <= 0x5A }
        let cleaned =
            needsNormalising
            ? String(
                decoding: u.filter { $0 != UInt8(ascii: "_") }.map {
                    ($0 >= 0x41 && $0 <= 0x5A) ? $0 | 0x20 : $0
                }, as: UTF8.self)
            : s

        guard let v = Double(cleaned) else { return (0, .syntax) }
        if v.isInfinite { return (v, .range) }  // well-formed but overflowed
        return (v, nil)
    }

    // MARK: - Specials

    /// Go: `special()`.
    private static func special(_ s: [UInt8]) -> Double? {
        if s.isEmpty { return nil }
        var i = 0
        var sign = 1.0
        var sawSign = false
        if s[0] == UInt8(ascii: "+") || s[0] == UInt8(ascii: "-") {
            if s[0] == UInt8(ascii: "-") { sign = -1 }
            sawSign = true
            i = 1
        }

        let rest = Array(s[i...])
        let lead = rest.first.map { $0 | 0x20 }  // ASCII lowercase

        if lead == UInt8(ascii: "i") {
            let n = commonPrefixLenIgnoringCase(rest, "infinity")
            // Anything longer than "inf" is fine, but without full "infinity"
            // only "inf" is consumed — and it must then be the whole string.
            if n == 3 || n == 8, rest.count == n {
                return sign * Double.infinity
            }
            return nil
        }
        // Reached only without a sign: Go's switch falls through the sign case
        // into 'i', never into 'n'.
        if !sawSign, lead == UInt8(ascii: "n") {
            if commonPrefixLenIgnoringCase(rest, "nan") == 3, rest.count == 3 {
                return Double(bitPattern: goNaNBits)
            }
        }
        return nil
    }

    private static func commonPrefixLenIgnoringCase(_ s: [UInt8], _ prefix: String) -> Int {
        let p = Array(prefix.utf8)
        var n = 0
        while n < s.count && n < p.count && (s[n] | 0x20) == p[n] { n += 1 }
        return n
    }

    // MARK: - Syntax

    private struct Form { var hasUnderscores: Bool }

    /// Validates the whole string as a Go floating-point literal.
    /// Go: `readFloat` plus the `n != len(s)` check in `ParseFloat`.
    private static func validate(_ s: [UInt8]) -> Form? {
        var i = 0
        var underscores = false

        if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }

        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        func isHexDigit(_ c: UInt8) -> Bool {
            isDigit(c) || ((c | 0x20) >= UInt8(ascii: "a") && (c | 0x20) <= UInt8(ascii: "f"))
        }

        // Hexadecimal form: 0x/0X, mantissa, then a REQUIRED p exponent.
        let isHex =
            i + 1 < s.count && s[i] == UInt8(ascii: "0") && (s[i + 1] | 0x20) == UInt8(ascii: "x")
        if isHex { i += 2 }

        var mantissaDigits = 0
        var sawDot = false
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "_") {
                underscores = true
                i += 1
                continue
            }
            if isHex ? isHexDigit(c) : isDigit(c) {
                mantissaDigits += 1
                i += 1
                continue
            }
            if c == UInt8(ascii: ".") && !sawDot {
                sawDot = true
                i += 1
                continue
            }
            break
        }
        if mantissaDigits == 0 { return nil }

        // Exponent: 'p' required for hex, 'e' optional for decimal.
        let expMarker: UInt8 = isHex ? UInt8(ascii: "p") : UInt8(ascii: "e")
        var sawExp = false
        if i < s.count, (s[i] | 0x20) == expMarker {
            i += 1
            sawExp = true
            if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
            var expDigits = 0
            while i < s.count {
                let c = s[i]
                if c == UInt8(ascii: "_") {
                    underscores = true
                    i += 1
                    continue
                }
                if isDigit(c) {
                    expDigits += 1
                    i += 1
                    continue
                }
                break
            }
            if expDigits == 0 { return nil }
        }
        if isHex && !sawExp { return nil }  // "0x1" is a syntax error in Go

        // Trailing junk is a syntax error (Go checks `n != len(s)`).
        if i != s.count { return nil }

        if underscores && !underscoreOK(s) { return nil }
        return Form(hasUnderscores: underscores)
    }

    /// Go: `underscoreOK`. Underscores may appear only between digits, or
    /// between a base prefix and a digit.
    ///
    /// Internal rather than private: `GoStrconv.parseUint` needs the same
    /// function, and Go shares one copy of it between atof and atoi too.
    static func underscoreOK(_ input: [UInt8]) -> Bool {
        // saw: "^" start, "0" digit or base prefix, "_" underscore, "!" other.
        var saw: UInt8 = UInt8(ascii: "^")
        var i = 0
        var s = input

        if s.count >= 1, s[0] == UInt8(ascii: "-") || s[0] == UInt8(ascii: "+") {
            s = Array(s[1...])
        }

        var hex = false
        if s.count >= 2, s[0] == UInt8(ascii: "0") {
            let c = s[1] | 0x20
            if c == UInt8(ascii: "b") || c == UInt8(ascii: "o") || c == UInt8(ascii: "x") {
                i = 2
                saw = UInt8(ascii: "0")  // a base prefix counts as a digit here
                hex = c == UInt8(ascii: "x")
            }
        }

        while i < s.count {
            let c = s[i]
            let lower = c | 0x20
            let isDigit = c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
            let isHexLetter = hex && lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "f")
            if isDigit || isHexLetter {
                saw = UInt8(ascii: "0")
                i += 1
                continue
            }
            if c == UInt8(ascii: "_") {
                if saw != UInt8(ascii: "0") { return false }  // must follow a digit
                saw = UInt8(ascii: "_")
                i += 1
                continue
            }
            if saw == UInt8(ascii: "_") { return false }  // must be followed by a digit
            saw = UInt8(ascii: "!")
            i += 1
        }
        return saw != UInt8(ascii: "_")
    }
}
