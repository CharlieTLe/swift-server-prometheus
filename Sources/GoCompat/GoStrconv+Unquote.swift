//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/strconv/quote.go — Unquote and UnquoteChar.
//
// Needed by the PromQL lexer (Phase 4), which unquotes string literals, and by
// util/strutil. Paired with GoStrconv.quote so round-trips can be tested.
//===----------------------------------------------------------------------===//

extension GoStrconv {

    /// Go: `strconv.Unquote`. Accepts a single-quoted, double-quoted or
    /// backquoted Go string literal.
    ///
    /// Returns bytes rather than a String: `\xNN` escapes can produce invalid
    /// UTF-8, which Go represents happily and a Swift String cannot (ADR-9).
    public static func unquoteBytes(_ s: String) throws -> [UInt8] {
        let (out, rem) = try unquote(Array(s.utf8), unescape: true)
        if !rem.isEmpty { throw GoStrconvError.syntax }
        return out
    }

    /// Convenience for callers that know the result is valid UTF-8. Invalid
    /// sequences become U+FFFD, so prefer `unquoteBytes` on the byte path.
    public static func unquote(_ s: String) throws -> String {
        String(decoding: try unquoteBytes(s), as: UTF8.self)
    }

    /// Go: `unquote(in, unescape: true)`. Returns the decoded bytes and the
    /// unconsumed remainder.
    static func unquote(_ input: [UInt8], unescape: Bool) throws -> (out: [UInt8], rem: [UInt8]) {
        if input.count < 2 { throw GoStrconvError.syntax }
        let quote = input[0]

        // Optimistically locate the terminating quote; may be wrong when escapes
        // are present, which the slow path below handles.
        guard let endIdx = input[1...].firstIndex(of: quote) else { throw GoStrconvError.syntax }
        let end = endIdx + 1  // position after the terminating quote

        switch quote {
        case UInt8(ascii: "`"):
            // Raw string: carriage returns are discarded. Go deliberately does
            // not validate UTF-8 here.
            let body = input[1..<(end - 1)]
            return (body.filter { $0 != UInt8(ascii: "\r") }, Array(input[end...]))

        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            var out = [UInt8]()
            var i = 1  // skip the opening quote
            while i < input.count && input[i] != quote {
                // Unescaped newlines are invalid inside quoted strings.
                if input[i] == UInt8(ascii: "\n") { throw GoStrconvError.syntax }
                let (value, multibyte, next) = try unquoteChar(input, i, quote: quote)
                i = next
                if unescape {
                    if value < 0x80 || !multibyte {
                        out.append(UInt8(truncatingIfNeeded: value))
                    } else {
                        appendRune(&out, value)
                    }
                }
                // A single-quoted literal holds exactly one character.
                if quote == UInt8(ascii: "'") { break }
            }
            guard i < input.count, input[i] == quote else { throw GoStrconvError.syntax }
            i += 1  // skip the terminating quote
            return (out, Array(input[i...]))

        default:
            throw GoStrconvError.syntax
        }
    }

    /// Go: `strconv.UnquoteChar`. Returns the rune, whether it must be encoded as
    /// multi-byte UTF-8, and the index just past what was consumed.
    ///
    /// The `multibyte` flag is load-bearing: `\xNN` yields a single *byte* even
    /// when >= 0x80, whereas `\uNNNN` yields a rune to be UTF-8 encoded.
    static func unquoteChar(
        _ s: [UInt8], _ start: Int, quote: UInt8
    ) throws -> (value: UInt32, multibyte: Bool, next: Int) {
        guard start < s.count else { throw GoStrconvError.syntax }
        var i = start
        let c = s[i]

        if c == quote, quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") {
            throw GoStrconvError.syntax
        }
        if c >= 0x80 {
            let (r, size) = decodeRune(s, i)
            return (r, true, i + size)
        }
        if c != UInt8(ascii: "\\") {
            return (UInt32(c), false, i + 1)
        }

        // Escape sequence.
        guard i + 1 < s.count else { throw GoStrconvError.syntax }
        let e = s[i + 1]
        i += 2

        func hexRun(_ n: Int) throws -> UInt32 {
            guard i + n <= s.count else { throw GoStrconvError.syntax }
            var v: UInt32 = 0
            for j in 0..<n {
                guard let x = unhex(s[i + j]) else { throw GoStrconvError.syntax }
                v = (v << 4) | x
            }
            i += n
            return v
        }

        switch e {
        case UInt8(ascii: "a"): return (0x07, false, i)
        case UInt8(ascii: "b"): return (0x08, false, i)
        case UInt8(ascii: "f"): return (0x0C, false, i)
        case UInt8(ascii: "n"): return (0x0A, false, i)
        case UInt8(ascii: "r"): return (0x0D, false, i)
        case UInt8(ascii: "t"): return (0x09, false, i)
        case UInt8(ascii: "v"): return (0x0B, false, i)

        case UInt8(ascii: "x"):
            // Single byte, possibly not valid UTF-8 — hence multibyte == false.
            return (try hexRun(2), false, i)
        case UInt8(ascii: "u"):
            let v = try hexRun(4)
            guard isValidRune(v) else { throw GoStrconvError.syntax }
            return (v, true, i)
        case UInt8(ascii: "U"):
            let v = try hexRun(8)
            guard isValidRune(v) else { throw GoStrconvError.syntax }
            return (v, true, i)

        case UInt8(ascii: "0")...UInt8(ascii: "7"):
            // Three octal digits total; one already consumed.
            var v = UInt32(e - UInt8(ascii: "0"))
            guard i + 2 <= s.count else { throw GoStrconvError.syntax }
            for j in 0..<2 {
                let d = s[i + j]
                guard d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") else {
                    throw GoStrconvError.syntax
                }
                v = (v << 3) | UInt32(d - UInt8(ascii: "0"))
            }
            i += 2
            guard v <= 255 else { throw GoStrconvError.syntax }
            return (v, false, i)

        case UInt8(ascii: "\\"):
            return (UInt32(UInt8(ascii: "\\")), false, i)

        case UInt8(ascii: "'"), UInt8(ascii: "\""):
            // Only the delimiter in use may be escaped.
            guard e == quote else { throw GoStrconvError.syntax }
            return (UInt32(e), false, i)

        default:
            throw GoStrconvError.syntax
        }
    }

    /// Go: `unhex`.
    private static func unhex(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(c - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(c - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }
}
