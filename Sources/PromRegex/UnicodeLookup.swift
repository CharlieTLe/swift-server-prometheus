//===----------------------------------------------------------------------===//
// Unicode lookups backing the regex engine.
//
// The data lives in Generated/SimpleFold.swift and Generated/UnicodeGroups.swift,
// emitted from Go's own tables by oracle/tables.go — see Scripts/regen-tables.sh.
// Hand-transcribing 2,878 fold orbits and 6,701 group ranges would be neither
// reviewable nor trustworthy.
//===----------------------------------------------------------------------===//

extension UnicodeTables {

    /// Go: `parse.go` `minFold` / `maxFold` — the bounds of every rune involved
    /// in case folding, so callers can skip the lookup entirely outside them.
    public static let minFold: UInt32 = 0x0041
    public static let maxFold: UInt32 = 0x1E943

    /// Go: `unicode.SimpleFold(r)`.
    ///
    /// Returns the next rune in `r`'s case-folding orbit, wrapping around to the
    /// orbit's smallest member; a rune with no orbit folds to itself. Go bakes
    /// this into character classes at **parse** time, so the port must agree
    /// rune-for-rune or the resulting AST differs.
    public static func simpleFold(_ r: UInt32) -> UInt32 {
        if r < minFold || r > maxFold { return r }
        var lo = 0
        var hi = simpleFoldPairs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let p = simpleFoldPairs[mid]
            if r < p.from {
                hi = mid - 1
            } else if r > p.from {
                lo = mid + 1
            } else {
                return p.to
            }
        }
        return r
    }

    /// Go: `minFoldRune` — the smallest rune fold-equivalent to `r`.
    public static func minFoldRune(_ r: UInt32) -> UInt32 {
        if r < minFold || r > maxFold { return r }
        var min = r
        var f = simpleFold(r)
        while f != r {
            min = Swift.min(min, f)
            f = simpleFold(f)
        }
        return min
    }

    /// Resolve a `\p{Name}` group. Go: `unicodeTable` consults
    /// `unicode.Categories` then `unicode.Scripts` — and deliberately not
    /// `unicode.Properties`, so `\p{White_Space}` is an error in Go.
    public static func group(named name: String) -> [(lo: UInt32, hi: UInt32, stride: UInt32)]? {
        categories[name] ?? scripts[name]
    }

    /// Expand a Go `RangeTable`-style entry list into class range pairs.
    ///
    /// Go stores some ranges with a stride > 1, meaning "every Nth rune in
    /// [lo, hi]" — those must be expanded into individual runes, not treated as
    /// a contiguous span.
    public static func classPairs(
        for ranges: [(lo: UInt32, hi: UInt32, stride: UInt32)]
    ) -> [UInt32] {
        var out = [UInt32]()
        out.reserveCapacity(ranges.count * 2)
        for r in ranges {
            if r.stride == 1 {
                out.append(r.lo)
                out.append(r.hi)
            } else {
                var c = r.lo
                while c <= r.hi {
                    out.append(c)
                    out.append(c)
                    c += r.stride
                }
            }
        }
        return out
    }
}
