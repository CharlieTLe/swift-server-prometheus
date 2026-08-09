//===----------------------------------------------------------------------===//
// Ported from util/strutil/quote.go @ v3.13.2
//
// This is NOT `strconv.Unquote` (that one is `GoStrconv.unquote`). Upstream
// adapted Go's version and removed the single-quote special case, so in PromQL
// `'abc'` is an ordinary string rather than an invalid rune literal. The two
// differ in exactly that: `strconv.Unquote("'ab'")` is an error, this is "ab".
//
// The primitive returns bytes. A `\xNN` escape can produce invalid UTF-8, which a
// Go string holds happily and a Swift String cannot — ADR-9.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `util/strutil`.
public enum PromStrutil: Sendable {

    /// Go: `strutil.ErrSyntax`. A distinct type from `GoStrconvError` because the
    /// message differs in provenance even though the text matches.
    public struct ErrSyntax: Error, CustomStringConvertible, Sendable {
        public init() {}
        public var description: String { "invalid syntax" }
    }

    /// Go: `strutil.Unquote` — interprets `s` as a single-quoted, double-quoted or
    /// backquoted PromQL string literal.
    public static func unquoteBytes(_ s: [UInt8]) throws -> [UInt8] {
        let n = s.count
        if n < 2 { throw ErrSyntax() }
        let quote = s[0]
        if quote != s[n - 1] { throw ErrSyntax() }
        var body = Array(s[1..<(n - 1)])

        if quote == UInt8(ascii: "`") {
            // A raw string cannot contain a backquote, and unlike
            // strconv.Unquote's raw case, carriage returns are kept.
            if body.contains(UInt8(ascii: "`")) { throw ErrSyntax() }
            return body
        }
        if quote != UInt8(ascii: "\"") && quote != UInt8(ascii: "'") { throw ErrSyntax() }
        if body.contains(UInt8(ascii: "\n")) { throw ErrSyntax() }

        // The trivial case: nothing to decode.
        if !body.contains(UInt8(ascii: "\\")) && !body.contains(quote) { return body }

        var out = [UInt8]()
        out.reserveCapacity(3 * body.count / 2)
        var i = 0
        while i < body.count {
            let (value, multibyte, next) = try unquoteChar(body, i, quote)
            i = next
            if value < 0x80 || !multibyte {
                out.append(UInt8(truncatingIfNeeded: value))
            } else {
                GoStrconv.appendRune(&out, value)
            }
        }
        body = out
        return body
    }

    /// Convenience for callers on the String path. Invalid UTF-8 becomes U+FFFD,
    /// so prefer `unquoteBytes` wherever the bytes matter.
    public static func unquote(_ s: String) throws -> String {
        String(decoding: try unquoteBytes(Array(s.utf8)), as: UTF8.self)
    }

    public static func unquoteBytes(_ s: String) throws -> [UInt8] {
        try unquoteBytes(Array(s.utf8))
    }

    /// Go: `unquoteChar`. Returns the decoded value, whether it needs a multibyte
    /// UTF-8 encoding, and the index just past what was consumed.
    private static func unquoteChar(
        _ s: [UInt8], _ start: Int, _ quote: UInt8
    ) throws -> (value: UInt32, multibyte: Bool, next: Int) {
        let c = s[start]

        // Easy cases.
        if c == quote && (quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"")) {
            throw ErrSyntax()
        }
        if c >= 0x80 {
            let (r, size) = GoStrconv.decodeRune(s, start)
            return (r, true, start + size)
        }
        if c != UInt8(ascii: "\\") {
            return (UInt32(c), false, start + 1)
        }

        // Hard case: a backslash.
        if s.count - start <= 1 { throw ErrSyntax() }
        let esc = s[start + 1]
        var i = start + 2

        var value: UInt32 = 0
        var multibyte = false

        switch esc {
        case UInt8(ascii: "a"): value = 0x07
        case UInt8(ascii: "b"): value = 0x08
        case UInt8(ascii: "f"): value = 0x0C
        case UInt8(ascii: "n"): value = 0x0A
        case UInt8(ascii: "r"): value = 0x0D
        case UInt8(ascii: "t"): value = 0x09
        case UInt8(ascii: "v"): value = 0x0B

        case UInt8(ascii: "x"), UInt8(ascii: "u"), UInt8(ascii: "U"):
            let n: Int
            switch esc {
            case UInt8(ascii: "x"): n = 2
            case UInt8(ascii: "u"): n = 4
            default: n = 8
            }
            if s.count - i < n { throw ErrSyntax() }
            var v: UInt32 = 0
            for j in 0..<n {
                guard let x = unhex(s[i + j]) else { throw ErrSyntax() }
                v = v << 4 | UInt32(x)
            }
            i += n
            if esc == UInt8(ascii: "x") {
                // A single byte, which may well not be valid UTF-8.
                value = v
                break
            }
            // Go: utf8.MaxRune. Note surrogates are NOT rejected here, unlike in
            // strconv.Unquote — this is one of the places upstream's copy drifted.
            if v > 0x0010_FFFF { throw ErrSyntax() }
            value = v
            multibyte = true

        case UInt8(ascii: "0")...UInt8(ascii: "7"):
            var v = UInt32(esc - UInt8(ascii: "0"))
            // One digit is already in hand; two more are required.
            if s.count - i < 2 { throw ErrSyntax() }
            for j in 0..<2 {
                let d = s[i + j]
                guard d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") else {
                    throw ErrSyntax()
                }
                v = (v << 3) | UInt32(d - UInt8(ascii: "0"))
            }
            i += 2
            if v > 255 { throw ErrSyntax() }
            value = v

        case UInt8(ascii: "\\"):
            value = UInt32(UInt8(ascii: "\\"))

        case UInt8(ascii: "'"), UInt8(ascii: "\""):
            // Only the quote that opened the literal may be escaped.
            if esc != quote { throw ErrSyntax() }
            value = UInt32(esc)

        default:
            throw ErrSyntax()
        }

        return (value, multibyte, i)
    }

    /// Go: `unhex`.
    private static func unhex(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
