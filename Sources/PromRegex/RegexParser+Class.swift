//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/parse.go — character classes, escapes,
// and the alternation `factor` rewriter.
//===----------------------------------------------------------------------===//

private import GoCompat

// MARK: - Class range primitives (free functions, as in Go)

/// Go: `cleanClass` — sort by lo ascending / hi descending, then merge.
func cleanClass(_ rp: inout [UInt32]) -> [UInt32] {
    guard rp.count >= 2 else { return rp }

    // Sort pairs.
    var pairs = [(UInt32, UInt32)]()
    pairs.reserveCapacity(rp.count / 2)
    var i = 0
    while i + 1 < rp.count {
        pairs.append((rp[i], rp[i + 1]))
        i += 2
    }
    pairs.sort { a, b in a.0 < b.0 || (a.0 == b.0 && a.1 > b.1) }

    var r = [UInt32]()
    r.reserveCapacity(rp.count)
    for p in pairs {
        r.append(p.0)
        r.append(p.1)
    }

    // Merge abutting and overlapping ranges.
    var w = 2
    var j = 2
    while j + 1 < r.count {
        let lo = r[j]
        let hi = r[j + 1]
        // `r[w-1] + 1` can overflow only when r[w-1] == UInt32.max, which cannot
        // happen for a valid class (max rune is 0x10FFFF).
        if lo <= r[w - 1] + 1 {
            if hi > r[w - 1] { r[w - 1] = hi }
            j += 2
            continue
        }
        r[w] = lo
        r[w + 1] = hi
        w += 2
        j += 2
    }
    rp = Array(r[0..<w])
    return rp
}

/// Go: `appendRange`.
///
/// Checks the last *two* ranges, not just the last: when appending case-folded
/// alphabets one range may be growing A-Z while the other grows a-z.
func appendRange(_ r: [UInt32], _ lo: UInt32, _ hi: UInt32) -> [UInt32] {
    var r = r
    let n = r.count
    var i = 2
    while i <= 4 {
        if n >= i {
            let rlo = r[n - i]
            let rhi = r[n - i + 1]
            if lo <= rhi + 1 && rlo <= hi + 1 {
                if lo < rlo { r[n - i] = lo }
                if hi > rhi { r[n - i + 1] = hi }
                return r
            }
        }
        i += 2
    }
    r.append(lo)
    r.append(hi)
    return r
}

/// Go: `appendFoldedRange` — the range plus every fold-equivalent rune.
func appendFoldedRange(_ r: [UInt32], _ lo: UInt32, _ hi: UInt32) -> [UInt32] {
    var r = r
    var lo = lo
    var hi = hi
    let minFold = UnicodeTables.minFold
    let maxFold = UnicodeTables.maxFold

    if lo <= minFold && hi >= maxFold {
        return appendRange(r, lo, hi)  // full range: folding adds nothing
    }
    if hi < minFold || lo > maxFold {
        return appendRange(r, lo, hi)  // outside folding entirely
    }
    if lo < minFold {
        r = appendRange(r, lo, minFold - 1)
        lo = minFold
    }
    if hi > maxFold {
        r = appendRange(r, maxFold + 1, hi)
        hi = maxFold
    }

    // Brute force, relying on appendRange to coalesce as it goes.
    var c = lo
    while c <= hi {
        r = appendRange(r, c, c)
        var f = UnicodeTables.simpleFold(c)
        while f != c {
            r = appendRange(r, f, f)
            f = UnicodeTables.simpleFold(f)
        }
        c += 1
    }
    return r
}

/// Go: `appendClass`. Assumes `x` is clean.
func appendClass(_ r: [UInt32], _ x: [UInt32]) -> [UInt32] {
    var r = r
    var i = 0
    while i + 1 < x.count {
        r = appendRange(r, x[i], x[i + 1])
        i += 2
    }
    return r
}

/// Go: `appendFoldedClass`.
func appendFoldedClass(_ r: [UInt32], _ x: [UInt32]) -> [UInt32] {
    var r = r
    var i = 0
    while i + 1 < x.count {
        r = appendFoldedRange(r, x[i], x[i + 1])
        i += 2
    }
    return r
}

/// Go: `appendNegatedClass`. Assumes `x` is clean.
func appendNegatedClass(_ r: [UInt32], _ x: [UInt32]) -> [UInt32] {
    var r = r
    var nextLo: UInt32 = 0
    var i = 0
    while i + 1 < x.count {
        let lo = x[i]
        let hi = x[i + 1]
        if lo > 0, nextLo <= lo - 1 {
            r = appendRange(r, nextLo, lo - 1)
        }
        nextLo = hi + 1
        i += 2
    }
    if nextLo <= 0x10FFFF {
        r = appendRange(r, nextLo, 0x10FFFF)
    }
    return r
}

/// Go: `appendLiteral`.
func appendLiteral(_ r: [UInt32], _ x: UInt32, _ flags: RegexFlags) -> [UInt32] {
    flags.contains(.foldCase) ? appendFoldedRange(r, x, x) : appendRange(r, x, x)
}

/// Go: `appendTable` — expands stride > 1 entries rune by rune.
func appendTable(_ r: [UInt32], _ ranges: [(lo: UInt32, hi: UInt32, stride: UInt32)]) -> [UInt32] {
    var r = r
    for xr in ranges {
        if xr.stride == 1 {
            r = appendRange(r, xr.lo, xr.hi)
            continue
        }
        var c = xr.lo
        while c <= xr.hi {
            r = appendRange(r, c, c)
            c += xr.stride
        }
    }
    return r
}

/// Go: `appendNegatedTable`.
func appendNegatedTable(
    _ r: [UInt32], _ ranges: [(lo: UInt32, hi: UInt32, stride: UInt32)]
) -> [UInt32] {
    var r = r
    var nextLo: UInt32 = 0
    for xr in ranges {
        if xr.stride == 1 {
            if xr.lo > 0, nextLo <= xr.lo - 1 {
                r = appendRange(r, nextLo, xr.lo - 1)
            }
            nextLo = xr.hi + 1
            continue
        }
        var c = xr.lo
        while c <= xr.hi {
            if c > 0, nextLo <= c - 1 {
                r = appendRange(r, nextLo, c - 1)
            }
            nextLo = c + 1
            c += xr.stride
        }
    }
    if nextLo <= 0x10FFFF {
        r = appendRange(r, nextLo, 0x10FFFF)
    }
    return r
}

/// Go: `negateClass`. Assumes `r` is clean.
func negateClass(_ input: [UInt32]) -> [UInt32] {
    var r = input
    var nextLo: UInt32 = 0
    var w = 0
    var i = 0
    while i + 1 < r.count {
        let lo = r[i]
        let hi = r[i + 1]
        if lo > 0, nextLo <= lo - 1 {
            r[w] = nextLo
            r[w + 1] = lo - 1
            w += 2
        }
        nextLo = hi + 1
        i += 2
    }
    r = Array(r[0..<w])
    if nextLo <= 0x10FFFF {
        // The negation can have one more range than the original.
        r.append(nextLo)
        r.append(0x10FFFF)
    }
    return r
}

// MARK: - Parser: escapes and classes

extension RegexParser {

    /// Go: `parseEscape`.
    mutating func parseEscape(_ start: Int) throws -> (UInt32, Int) {
        var t = start + 1
        if t >= inputBytes.count {
            throw RegexError(.trailingBackslash, "")
        }
        var (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
        t = next

        switch c {
        // Octal escapes.
        case 0x31...0x37:  // '1'...'7'
            // A single non-zero digit is a backreference, which is unsupported.
            if t >= inputBytes.count || inputBytes[t] < UInt8(ascii: "0")
                || inputBytes[t] > UInt8(ascii: "7")
            {
                break
            }
            fallthrough
        case 0x30:  // '0'
            // Up to three octal digits; one already consumed.
            var r = c - 0x30
            var i = 1
            while i < 3 {
                if t >= inputBytes.count || inputBytes[t] < UInt8(ascii: "0")
                    || inputBytes[t] > UInt8(ascii: "7")
                {
                    break
                }
                r = r * 8 + UInt32(inputBytes[t] - UInt8(ascii: "0"))
                t += 1
                i += 1
            }
            return (r, t)

        // Hexadecimal escapes.
        case UInt32(UInt8(ascii: "x")):
            if t >= inputBytes.count { break }
            (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
            t = next
            if c == UInt32(UInt8(ascii: "{")) {
                // Any number of hex digits in braces; at least one required.
                var nhex = 0
                var r: UInt32 = 0
                while true {
                    if t >= inputBytes.count {
                        throw RegexError(.invalidEscape, text(start, t))
                    }
                    (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
                    t = next
                    if c == UInt32(UInt8(ascii: "}")) { break }
                    let v = Self.unhexValue(c)
                    if v < 0 { throw RegexError(.invalidEscape, text(start, t)) }
                    r = r * 16 + UInt32(v)
                    if r > 0x10FFFF { throw RegexError(.invalidEscape, text(start, t)) }
                    nhex += 1
                }
                if nhex == 0 { throw RegexError(.invalidEscape, text(start, t)) }
                return (r, t)
            }
            // Two hex digits.
            let x = Self.unhexValue(c)
            if t >= inputBytes.count { throw RegexError(.invalidEscape, text(start, t)) }
            (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
            t = next
            let y = Self.unhexValue(c)
            if x < 0 || y < 0 { break }
            return (UInt32(x * 16 + y), t)

        // C escapes. There is deliberately no `\b` case: in Perl `\b` is a word
        // boundary, and `[\b]` as backspace is not supported.
        case UInt32(UInt8(ascii: "a")): return (0x07, t)
        case UInt32(UInt8(ascii: "f")): return (0x0C, t)
        case UInt32(UInt8(ascii: "n")): return (0x0A, t)
        case UInt32(UInt8(ascii: "r")): return (0x0D, t)
        case UInt32(UInt8(ascii: "t")): return (0x09, t)
        case UInt32(UInt8(ascii: "v")): return (0x0B, t)

        default:
            if c < 0x80 && !Self.isAlnum(c) {
                // An escaped non-word character is always itself. Go is stricter
                // than PCRE here (it rejects `\q`) but does allow `\_`.
                return (c, t)
            }
        }
        throw RegexError(.invalidEscape, text(start, t))
    }

    /// Go: `parseClassChar`.
    mutating func parseClassChar(_ start: Int, _ wholeClassStart: Int) throws -> (UInt32, Int) {
        if start >= inputBytes.count {
            throw RegexError(.missingBracket, text(from: wholeClassStart))
        }
        // Regular escapes are allowed here even where they need not be escaped.
        if inputBytes[start] == UInt8(ascii: "\\") {
            return try parseEscape(start)
        }
        return try Self.nextRune(inputBytes, start, wholePattern)
    }

    /// Go: `parsePerlClassEscape` — `\d`, `\s`, `\w` and negations.
    mutating func parsePerlClassEscape(_ start: Int, _ r: [UInt32]) -> ([UInt32], Int)? {
        guard parseFlags.contains(.perlX), start + 1 < inputBytes.count,
            inputBytes[start] == UInt8(ascii: "\\")
        else { return nil }
        let key = text(start, start + 2)
        guard let g = UnicodeTables.perlGroups[key] else { return nil }
        return (appendGroup(r, g), start + 2)
    }

    /// Go: `parseNamedClass` — `[:alnum:]` and friends.
    mutating func parseNamedClass(_ start: Int, _ r: [UInt32]) throws -> ([UInt32], Int)? {
        guard start + 1 < inputBytes.count, inputBytes[start] == UInt8(ascii: "["),
            inputBytes[start + 1] == UInt8(ascii: ":")
        else { return nil }
        guard
            let i = Self.findSeq(
                inputBytes, from: start + 2, sequence: [UInt8(ascii: ":"), UInt8(ascii: "]")])
        else { return nil }
        let name = text(start, i + 2)
        guard let g = UnicodeTables.posixGroups[name] else {
            throw RegexError(.invalidCharRange, name)
        }
        return (appendGroup(r, g), i + 2)
    }

    /// Go: `appendGroup`.
    mutating func appendGroup(_ r: [UInt32], _ g: UnicodeTables.CharGroup) -> [UInt32] {
        if !parseFlags.contains(.foldCase) {
            return g.sign < 0 ? appendNegatedClass(r, g.cls) : appendClass(r, g.cls)
        }
        var tmp = appendFoldedClass([], g.cls)
        let cleaned = cleanClass(&tmp)
        return g.sign < 0 ? appendNegatedClass(r, cleaned) : appendClass(r, cleaned)
    }

    /// Go: `parseUnicodeClass` — `\p{Han}` / `\pL` / `\P{...}`.
    mutating func parseUnicodeClass(_ start: Int, _ r: [UInt32]) throws -> ([UInt32], Int)? {
        guard parseFlags.contains(.unicodeGroups), start + 1 < inputBytes.count,
            inputBytes[start] == UInt8(ascii: "\\"),
            inputBytes[start + 1] == UInt8(ascii: "p") || inputBytes[start + 1] == UInt8(ascii: "P")
        else { return nil }

        // Committed: from here on we either parse or throw.
        var sign = inputBytes[start + 1] == UInt8(ascii: "P") ? -1 : 1
        var t = start + 2
        guard t < inputBytes.count else {
            throw RegexError(.invalidCharRange, text(from: start))
        }
        let (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
        t = next

        var seq: String
        var name: String
        if c != UInt32(UInt8(ascii: "{")) {
            // Single-letter name, e.g. \pL.
            seq = text(start, t)
            name = String(seq.dropFirst(2))
        } else {
            guard let end = Self.findSeq(inputBytes, from: start, sequence: [UInt8(ascii: "}")]) else {
                try Self.checkUTF8(inputBytes, start, text(from: start))
                throw RegexError(.invalidCharRange, text(from: start))
            }
            seq = text(start, end + 1)
            name = text(start + 3, end)
            t = end + 1
            try Self.checkUTF8(Array(name.utf8), 0, name)
        }

        // A leading ^ negates: \p{^Han} == \P{Han}.
        if name.hasPrefix("^") {
            sign = -sign
            name = String(name.dropFirst())
        }

        let (tab, fold, tsign) = UnicodeTables.unicodeTable(name)
        guard let tab else { throw RegexError(.invalidCharRange, seq) }
        if tsign < 0 { sign = -sign }

        var out = r
        if !parseFlags.contains(.foldCase) || fold == nil {
            out = sign > 0 ? appendTable(out, tab) : appendNegatedTable(out, tab)
        } else {
            // Merge table and fold companion in scratch space; required for the
            // negative case and tidier for the positive one.
            var tmp = appendTable([], tab)
            tmp = appendTable(tmp, fold!)
            let cleaned = cleanClass(&tmp)
            out = sign > 0 ? appendClass(out, cleaned) : appendNegatedClass(out, cleaned)
        }
        return (out, t)
    }

    /// Go: `parseClass`.
    mutating func parseClass(_ start: Int) throws -> Int {
        var t = start + 1  // chop '['
        let re = makeRegexp(.charClass)
        re.flags = parseFlags

        var sign = 1
        if t < inputBytes.count, inputBytes[t] == UInt8(ascii: "^") {
            sign = -1
            t += 1
            // If the class must not match \n, add it now so the later negation
            // does the right thing.
            if !parseFlags.contains(.classNL) {
                re.rune.append(0x0A)
                re.rune.append(0x0A)
            }
        }

        var cls = re.rune
        var first = true  // ']' and '-' are literal as the first character
        while t >= inputBytes.count || inputBytes[t] != UInt8(ascii: "]") || first {
            if t >= inputBytes.count {
                throw RegexError(.missingBracket, text(from: start))
            }
            // POSIX allows '-' unescaped only first or last; Perl allows it anywhere.
            if inputBytes[t] == UInt8(ascii: "-"), !parseFlags.contains(.perlX), !first,
                t + 1 >= inputBytes.count || inputBytes[t + 1] != UInt8(ascii: "]")
            {
                let (_, size) = GoStrconv.decodeRune(inputBytes, t + 1)
                throw RegexError(.invalidCharRange, text(t, t + 1 + size))
            }
            first = false

            // [:alnum:] and friends.
            if t + 2 < inputBytes.count, inputBytes[t] == UInt8(ascii: "["),
                inputBytes[t + 1] == UInt8(ascii: ":")
            {
                if let (ncls, nt) = try parseNamedClass(t, cls) {
                    cls = ncls
                    t = nt
                    continue
                }
            }

            // \p{Han} and friends.
            if let (ncls, nt) = try parseUnicodeClass(t, cls) {
                cls = ncls
                t = nt
                continue
            }

            // \d, \s, \w.
            if let (ncls, nt) = parsePerlClassEscape(t, cls) {
                cls = ncls
                t = nt
                continue
            }

            // Single character or a simple range.
            let rngStart = t
            var lo: UInt32
            var hi: UInt32
            (lo, t) = try parseClassChar(t, start)
            hi = lo
            // `[a-]` means (a|-), so require a following character that is not ']'.
            if t + 1 < inputBytes.count, inputBytes[t] == UInt8(ascii: "-"),
                inputBytes[t + 1] != UInt8(ascii: "]")
            {
                t += 1
                (hi, t) = try parseClassChar(t, start)
                if hi < lo {
                    throw RegexError(.invalidCharRange, text(rngStart, t))
                }
            }
            cls =
                parseFlags.contains(.foldCase)
                ? appendFoldedRange(cls, lo, hi) : appendRange(cls, lo, hi)
        }
        t += 1  // chop ']'

        re.rune = cls
        var cleaned = cleanClass(&re.rune)
        if sign < 0 { cleaned = negateClass(cleaned) }
        re.rune = cleaned
        try pushNode(re)
        return t
    }
}
