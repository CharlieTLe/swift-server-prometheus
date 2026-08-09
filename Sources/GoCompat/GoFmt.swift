//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/strconv/quote.go (QuoteRune) and
// $GOROOT/src/fmt/format.go (fmtQc, fmtUnicode) @ go1.25
//
// The PromQL lexer builds error messages with `%q` on a rune and `%#U` on an
// escape character, and those strings are part of the parser's contract. Neither
// verb has a Swift equivalent:
//
//   %q  on a rune → strconv.QuoteRune, e.g. 'x', '\n', 'é'
//   %#U on a rune → U+0041 'A', or just U+0007 when unprintable
//
// `%q` on an integer never produces fmt's badVerb form, unlike `%q` on most other
// kinds of operand: `fmtQc` substitutes U+FFFD for anything that is not a valid
// rune. So the lexer's eof sentinel, -1, renders as `'�'` — see `foo{a!`.
//===----------------------------------------------------------------------===//

extension GoStrconv {

    /// Go: `strconv.QuoteRune`.
    public static func quoteRune(_ r: UInt32) -> String {
        var out = [UInt8]()
        out.append(UInt8(ascii: "'"))
        appendEscapedRune(&out, r, quote: UInt8(ascii: "'"))
        out.append(UInt8(ascii: "'"))
        return String(decoding: out, as: UTF8.self)
    }
}

/// Go: the `fmt` verbs the port needs that have no Swift counterpart.
public enum GoFmt: Sendable {

    /// Go's largest valid rune, `utf8.MaxRune`.
    public static let maxRune: UInt32 = 0x0010_FFFF

    /// Go: `%q` applied to a value of a rune-like integer type.
    ///
    /// `fmt.fmtQc` converts the operand to `uint64` and substitutes
    /// `utf8.RuneError` when the result is not a valid rune — it does **not** fall
    /// back to fmt's badVerb form, despite `%q` doing that for other kinds of
    /// operand. So the PromQL lexer's eof sentinel, -1, quotes as `'�'`.
    /// Confirmed against Go; `foo{a!` is a query that reaches it.
    public static func quoteVerb(_ value: Int64) -> String {
        // uint64(int32(-1)) is far above MaxRune, which is how a negative value
        // lands on the substitution.
        guard value >= 0, value <= Int64(maxRune) else {
            return GoStrconv.quoteRune(0xFFFD)
        }
        return GoStrconv.quoteRune(UInt32(value))
    }

    /// Go: `%#U`, as in `U+0041 'A'`.
    ///
    /// The quoted character is appended only when the rune is printable, matching
    /// `fmt.fmtUnicode`'s `f.sharp && u <= utf8.MaxRune && strconv.IsPrint(...)`.
    public static func sharpUnicode(_ value: Int64) -> String {
        var hex = ""
        if value >= 0 {
            hex = String(UInt64(value), radix: 16, uppercase: true)
        } else {
            // fmt converts to uint64 first, so a negative value formats as its
            // two's complement.
            hex = String(UInt64(bitPattern: value), radix: 16, uppercase: true)
        }
        // Precision defaults to 4, zero-padded.
        while hex.count < 4 { hex = "0" + hex }
        var out = "U+" + hex
        if value >= 0, value <= Int64(maxRune), GoStrconv.isPrint(UInt32(value)) {
            var scalarBytes = [UInt8]()
            GoStrconv.appendRune(&scalarBytes, UInt32(value))
            out += " '" + String(decoding: scalarBytes, as: UTF8.self) + "'"
        }
        return out
    }
}
