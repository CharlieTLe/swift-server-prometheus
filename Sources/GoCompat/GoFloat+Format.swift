//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/internal/strconv/ftoa.go
//
// Reproduces `strconv.FormatFloat(v, fmt, prec, 64)` byte-for-byte.
//
// ⚠️ ADR-4: Swift's `Double.description`, `"\(x)"` and `String(describing:)` do
// NOT match Go. Divergences are not cosmetic — Go renders 1234567.0 as
// "1.234567e+06" and 1.0 as "1", and these strings appear in PromQL output,
// labels.String(), HTTP JSON, and error messages. Ported code must always come
// through here.
//===----------------------------------------------------------------------===//

public enum GoFloat: Sendable {

    /// The `fmt` byte accepted by `strconv.FormatFloat`.
    public enum Kind: Sendable {
        /// `-ddd.dddd`
        case f
        /// `-d.dddde±dd`
        case e
        /// `-d.ddddE±dd`
        case E
        /// `%e` for large exponents, `%f` otherwise
        case g
        /// `%E` for large exponents, `%f` otherwise
        case G

        /// The exponent character `fmtE` should emit.
        fileprivate var exponentChar: UInt8 {
            switch self {
            case .f, .e, .g: return UInt8(ascii: "e")
            case .E, .G: return UInt8(ascii: "E")
            }
        }
    }

    /// A view over decimal digits. Go: `decimalSlice`.
    fileprivate struct Digits {
        var d: [UInt8]
        var nd: Int
        var dp: Int
    }

    // MARK: - Public API

    /// Equivalent to `strconv.FormatFloat(v, kind, precision, 64)`.
    ///
    /// `precision == -1` selects the shortest representation that round-trips —
    /// this is what Prometheus uses almost everywhere.
    public static func format(_ v: Double, _ kind: Kind = .g, precision: Int = -1) -> String {
        // ftoa.go: specials are checked before anything else, and carry an
        // explicit '+' on positive infinity.
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Inf" : "+Inf" }

        let neg = v.sign == .minus
        var prec = precision
        let digits: Digits

        if precision < 0 {
            // Shortest mode. Go runs Ryū (`roundShortest`); we take the digits
            // from Swift's own shortest-round-trip formatter, which solves the
            // identical problem (shortest, and closest among equal-length
            // candidates). The differential fixtures in Fixtures/gocompat are
            // what actually certify this equivalence.
            digits = shortestDigits(v)
            switch kind {
            case .e, .E: prec = digits.nd - 1
            case .f: prec = max(digits.nd - digits.dp, 0)
            case .g, .G: prec = digits.nd
            }
        } else {
            // Fixed precision: expand the value exactly, then round. ftoa.go
            // rounds to a different digit count per format.
            var dec = exactDecimal(v)
            switch kind {
            case .e, .E: dec.round(prec + 1)
            case .f: dec.round(dec.dp + prec)
            case .g, .G:
                if prec == 0 { prec = 1 }
                dec.round(prec)
            }
            digits = Digits(d: dec.d, nd: dec.nd, dp: dec.dp)
        }

        return formatDigits(shortest: precision < 0, neg: neg, digits, prec: prec, kind: kind)
    }

    /// Convenience matching the overwhelmingly common Prometheus call,
    /// `strconv.FormatFloat(v, 'f', -1, 64)`.
    @inlinable
    public static func formatF(_ v: Double) -> String { format(v, .f, precision: -1) }

    /// Convenience for `strconv.FormatFloat(v, 'g', -1, 64)`.
    @inlinable
    public static func formatG(_ v: Double) -> String { format(v, .g, precision: -1) }

    // MARK: - Digit generation

    /// Shortest round-tripping digits plus decimal-point position.
    ///
    /// Derived by parsing Swift's `description`, whose grammar is either
    /// `ddd.ddd` or `d.ddde±dd`, optionally signed.
    fileprivate static func shortestDigits(_ v: Double) -> Digits {
        if v == 0 { return Digits(d: [], nd: 0, dp: 0) }

        let s = Substring(String(v.magnitude))
        let mantissa: Substring
        var exponent = 0
        if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = s[s.startIndex..<eIdx]
            exponent = Int(s[s.index(after: eIdx)...]) ?? 0
        } else {
            mantissa = s
        }

        var digits = [UInt8]()
        digits.reserveCapacity(24)
        var pointPos = 0
        if let dot = mantissa.firstIndex(of: ".") {
            let intPart = mantissa[mantissa.startIndex..<dot]
            digits.append(contentsOf: intPart.utf8)
            digits.append(contentsOf: mantissa[mantissa.index(after: dot)...].utf8)
            pointPos = intPart.count
        } else {
            digits.append(contentsOf: mantissa.utf8)
            pointPos = mantissa.count
        }

        var dp = pointPos + exponent

        // Normalise: strip leading zeros (each one shifts the decimal point),
        // then trailing zeros. Go's `trim` forces dp == 0 for an all-zero value.
        var lead = 0
        while lead < digits.count && digits[lead] == UInt8(ascii: "0") {
            lead += 1
            dp -= 1
        }
        if lead > 0 { digits.removeFirst(lead) }
        while let last = digits.last, last == UInt8(ascii: "0") { digits.removeLast() }
        if digits.isEmpty { dp = 0 }

        return Digits(d: digits, nd: digits.count, dp: dp)
    }

    /// The exact decimal expansion of a binary64. Go: the `bigFtoa` prologue.
    fileprivate static func exactDecimal(_ v: Double) -> GoDecimal {
        let mantbits: UInt64 = 52
        let expbits: UInt64 = 11
        let bias = -1023

        let bits = v.magnitude.bitPattern
        var mant = bits & ((1 << mantbits) - 1)
        var exp = Int((bits >> mantbits) & ((1 << expbits) - 1))
        if exp == 0 {
            // Denormal: no implicit leading bit.
            exp += bias + 1
        } else {
            mant |= 1 << mantbits
            exp += bias
        }

        var dec = GoDecimal()
        dec.assign(mant)
        dec.shift(exp - Int(mantbits))
        return dec
    }

    // MARK: - Rendering

    /// Go: `formatDigits`.
    fileprivate static func formatDigits(
        shortest: Bool, neg: Bool, _ digs: Digits, prec: Int, kind: Kind
    ) -> String {
        switch kind {
        case .e, .E:
            return fmtE(neg: neg, digs, prec: prec, exponentChar: kind.exponentChar)
        case .f:
            return fmtF(neg: neg, digs, prec: prec)
        case .g, .G:
            var prec = prec
            // Trailing fractional zeros in 'e' form will be trimmed.
            var eprec = prec
            if eprec > digs.nd && digs.nd >= digs.dp {
                eprec = digs.nd
            }
            // %e is used if the exponent from the conversion is less than -4 or
            // greater than or equal to the precision. If precision was the
            // shortest possible, use precision 6 for this decision.
            if shortest {
                eprec = 6
            }
            let exp = digs.dp - 1
            if exp < -4 || exp >= eprec {
                if prec > digs.nd { prec = digs.nd }
                return fmtE(neg: neg, digs, prec: prec - 1, exponentChar: kind.exponentChar)
            }
            if prec > digs.dp { prec = digs.nd }
            return fmtF(neg: neg, digs, prec: max(prec - digs.dp, 0))
        }
    }

    /// Go: `fmtE`.
    private static func fmtE(
        neg: Bool, _ d: Digits, prec: Int, exponentChar: UInt8
    ) -> String {
        var out = [UInt8]()
        out.reserveCapacity(prec + 8)

        if neg { out.append(UInt8(ascii: "-")) }

        // First digit.
        out.append(d.nd != 0 ? d.d[0] : UInt8(ascii: "0"))

        // .moredigits
        if prec > 0 {
            out.append(UInt8(ascii: "."))
            var i = 1
            let m = min(d.nd, prec + 1)
            if i < m {
                out.append(contentsOf: d.d[i..<m])
                i = m
            }
            while i <= prec {
                out.append(UInt8(ascii: "0"))
                i += 1
            }
        }

        // e±
        out.append(exponentChar)
        var exp = d.dp - 1
        if d.nd == 0 { exp = 0 }  // special case: 0 has exponent 0
        if exp < 0 {
            out.append(UInt8(ascii: "-"))
            exp = -exp
        } else {
            out.append(UInt8(ascii: "+"))
        }

        // dd or ddd — always at least two digits.
        if exp < 10 {
            out.append(UInt8(ascii: "0"))
            out.append(UInt8(exp) + 48)
        } else if exp < 100 {
            out.append(UInt8(exp / 10) + 48)
            out.append(UInt8(exp % 10) + 48)
        } else {
            out.append(UInt8(exp / 100) + 48)
            out.append(UInt8((exp / 10) % 10) + 48)
            out.append(UInt8(exp % 10) + 48)
        }

        return String(decoding: out, as: UTF8.self)
    }

    /// Go: `fmtF`.
    private static func fmtF(neg: Bool, _ d: Digits, prec: Int) -> String {
        var out = [UInt8]()
        out.reserveCapacity(max(d.dp, 1) + prec + 2)

        if neg { out.append(UInt8(ascii: "-")) }

        // Integer part, padded with zeros as needed.
        if d.dp > 0 {
            var m = min(d.nd, d.dp)
            out.append(contentsOf: d.d[0..<m])
            while m < d.dp {
                out.append(UInt8(ascii: "0"))
                m += 1
            }
        } else {
            out.append(UInt8(ascii: "0"))
        }

        // Fraction.
        if prec > 0 {
            out.append(UInt8(ascii: "."))
            for i in 0..<prec {
                let j = d.dp + i
                out.append(j >= 0 && j < d.nd ? d.d[j] : UInt8(ascii: "0"))
            }
        }

        return String(decoding: out, as: UTF8.self)
    }
}
