//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/strconv/quote.go and $GOROOT/src/unicode/utf8/utf8.go
//
// `Labels.String()` calls `strconv.AppendQuote` on every label value (and on
// names that fail legacy validation), so this is on the byte-exactness path —
// see model/labels/labels_common.go stringImpl @ v3.13.2.
//===----------------------------------------------------------------------===//

public enum GoStrconv: Sendable {

    private static let lowerhex = Array("0123456789abcdef".utf8)

    // MARK: - IsPrint

    /// Go: `strconv.IsPrint`. Backed by `Generated/GoIsPrint.swift`.
    public static func isPrint(_ r: UInt32) -> Bool {
        // Fast path for ASCII, which is the overwhelming majority of label data.
        if r < 0x80 { return r >= 0x20 && r < 0x7F }
        var lo = 0
        var hi = printableRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = printableRanges[mid]
            if r < range.lo {
                hi = mid - 1
            } else if r > range.hi {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Quote

    /// Go: `strconv.Quote`.
    public static func quote(_ s: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count + 2)
        appendQuoted(&out, Array(s.utf8))
        return String(decoding: out, as: UTF8.self)
    }

    /// Go: `strconv.Quote` over raw bytes.
    ///
    /// This byte-level entry point is the primitive, not a convenience: a Go
    /// `string` may hold arbitrary bytes, and `Quote` has a defined behaviour for
    /// invalid UTF-8 (emit `\xNN` per offending byte) that a Swift `String`
    /// cannot represent. See docs/DECISIONS.md ADR-9.
    public static func quote(bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 2)
        appendQuoted(&out, bytes)
        return String(decoding: out, as: UTF8.self)
    }

    /// Go: `appendQuotedWith(buf, s, '"', ASCIIonly: false, graphicOnly: false)`.
    private static func appendQuoted(_ out: inout [UInt8], _ s: [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var i = 0
        while i < s.count {
            let (r, width) = decodeRune(s, i)
            if width == 1 && r == 0xFFFD {
                // Invalid UTF-8: Go emits the raw byte as \xNN.
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "x"))
                out.append(lowerhex[Int(s[i] >> 4)])
                out.append(lowerhex[Int(s[i] & 0xF)])
                i += 1
                continue
            }
            appendEscapedRune(&out, r)
            i += width
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Go: `appendEscapedRune`, not ASCII-only, not graphic-only.
    ///
    /// `quote` is the delimiter being escaped for: `Quote` passes `"` and
    /// `QuoteRune` passes `'`, and only that delimiter gets a backslash. So `'`
    /// is literal inside a quoted string and `"` is literal inside a quoted rune.
    static func appendEscapedRune(
        _ out: inout [UInt8], _ r: UInt32, quote: UInt8 = UInt8(ascii: "\"")
    ) {
        if r == UInt32(quote) || r == UInt32(UInt8(ascii: "\\")) {
            out.append(UInt8(ascii: "\\"))
            out.append(UInt8(r))
            return
        }
        if isPrint(r) {
            appendRune(&out, r)
            return
        }
        switch r {
        case 0x07: out.append(contentsOf: Array("\\a".utf8))
        case 0x08: out.append(contentsOf: Array("\\b".utf8))
        case 0x0C: out.append(contentsOf: Array("\\f".utf8))
        case 0x0A: out.append(contentsOf: Array("\\n".utf8))
        case 0x0D: out.append(contentsOf: Array("\\r".utf8))
        case 0x09: out.append(contentsOf: Array("\\t".utf8))
        case 0x0B: out.append(contentsOf: Array("\\v".utf8))
        default:
            var r = r
            if r < 0x20 || r == 0x7F {
                out.append(contentsOf: Array("\\x".utf8))
                out.append(lowerhex[Int((r >> 4) & 0xF)])
                out.append(lowerhex[Int(r & 0xF)])
            } else {
                if !isValidRune(r) { r = 0xFFFD }
                if r < 0x10000 {
                    out.append(contentsOf: Array("\\u".utf8))
                    for s in stride(from: 12, through: 0, by: -4) {
                        out.append(lowerhex[Int((r >> UInt32(s)) & 0xF)])
                    }
                } else {
                    out.append(contentsOf: Array("\\U".utf8))
                    for s in stride(from: 28, through: 0, by: -4) {
                        out.append(lowerhex[Int((r >> UInt32(s)) & 0xF)])
                    }
                }
            }
        }
    }

    // MARK: - UTF-8

    /// Go: `utf8.ValidRune`. Surrogates and out-of-range values are invalid.
    public static func isValidRune(_ r: UInt32) -> Bool {
        if r > 0x10FFFF { return false }
        if r >= 0xD800 && r <= 0xDFFF { return false }
        return true
    }

    /// Go: `utf8.AppendRune`.
    public static func appendRune(_ out: inout [UInt8], _ r: UInt32) {
        let r = isValidRune(r) ? r : 0xFFFD
        switch r {
        case 0..<0x80:
            out.append(UInt8(r))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (r >> 6)))
            out.append(UInt8(0x80 | (r & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (r >> 12)))
            out.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (r & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (r >> 18)))
            out.append(UInt8(0x80 | ((r >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (r & 0x3F)))
        }
    }

    /// Go: `utf8.DecodeRuneInString`. Returns `(0xFFFD, 1)` for any invalid
    /// sequence — including overlong encodings, surrogates and out-of-range
    /// values — which is what drives Quote's `\xNN` fallback.
    public static func decodeRune(_ s: [UInt8], _ i: Int) -> (UInt32, Int) {
        let n = s.count - i
        if n < 1 { return (0xFFFD, 0) }
        let b0 = s[i]

        if b0 < 0x80 { return (UInt32(b0), 1) }
        if b0 < 0xC2 { return (0xFFFD, 1) }  // continuation byte or overlong 2-byte

        func cont(_ k: Int, _ lo: UInt8, _ hi: UInt8) -> Bool {
            guard n > k else { return false }
            let b = s[i + k]
            return b >= lo && b <= hi
        }

        if b0 < 0xE0 {  // 2-byte
            guard cont(1, 0x80, 0xBF) else { return (0xFFFD, 1) }
            return ((UInt32(b0 & 0x1F) << 6) | UInt32(s[i + 1] & 0x3F), 2)
        }
        if b0 < 0xF0 {  // 3-byte
            // E0 excludes overlong; ED excludes surrogates.
            let lo: UInt8 = (b0 == 0xE0) ? 0xA0 : 0x80
            let hi: UInt8 = (b0 == 0xED) ? 0x9F : 0xBF
            guard cont(1, lo, hi), cont(2, 0x80, 0xBF) else { return (0xFFFD, 1) }
            var r = UInt32(b0 & 0x0F) << 12
            r |= UInt32(s[i + 1] & 0x3F) << 6
            r |= UInt32(s[i + 2] & 0x3F)
            return (r, 3)
        }
        if b0 < 0xF5 {  // 4-byte
            // F0 excludes overlong; F4 caps at U+10FFFF.
            let lo: UInt8 = (b0 == 0xF0) ? 0x90 : 0x80
            let hi: UInt8 = (b0 == 0xF4) ? 0x8F : 0xBF
            guard cont(1, lo, hi), cont(2, 0x80, 0xBF), cont(3, 0x80, 0xBF) else {
                return (0xFFFD, 1)
            }
            var r = UInt32(b0 & 0x07) << 18
            r |= UInt32(s[i + 1] & 0x3F) << 12
            r |= UInt32(s[i + 2] & 0x3F) << 6
            r |= UInt32(s[i + 3] & 0x3F)
            return (r, 4)
        }
        return (0xFFFD, 1)
    }
}
