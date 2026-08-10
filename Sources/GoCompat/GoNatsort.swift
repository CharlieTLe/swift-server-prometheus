//===----------------------------------------------------------------------===//
// Ported from github.com/facette/natsort @ v0.0.0-20181210072756-2cd4dd1e2dcb, which is
// what prometheus v3.13.2 pins. Only `Compare` and `chunkify` are here; the package's
// own `Sort` has no caller in Prometheus.
//
// ## `Compare` is a `Less`-shaped function that is not an ordering
//
// It returns true when `a` precedes `b` "in natural order", and:
//
//   * `Compare(x, x)` is **true** for any non-empty x — the equal-chunks path falls into
//     "we reached the last chunk of A, thus B is greater than A". So it is not
//     irreflexive.
//   * `Compare("a1", "a01")` and `Compare("a01", "a1")` are **both** true, because the
//     numeric chunks compare equal as integers and then the same last-chunk rule fires
//     for whichever side is asked first.
//
// `sort_by_label` guards the first problem by testing `lv1 == lv2` before calling, but
// not the second. That is precisely why the pdqsort port next door exists: with an
// inconsistent comparator the output is the algorithm's, not the ordering's.
//
// ## Chunking is a byte split, and that is exactly equivalent to the regexp
//
// Upstream uses `regexp.MustCompile("(\\d+|\\D+)").FindAllString`. Go's `\d` is `[0-9]`
// and `\D` is its complement over *runes*, so every rune falls in exactly one class and
// the matches are the maximal runs of each. Because the digits are ASCII, splitting the
// UTF-8 **bytes** into maximal digit / non-digit runs produces the identical list — and
// it also matches Go on invalid UTF-8, where the regexp engine treats each bad byte as
// U+FFFD, still a `\D`, and `FindAllString` hands back the original bytes. Label values
// are arbitrary byte strings, so that case is reachable and the corpus covers it.
//
// An empty string chunks to *nothing*, which is why `Compare("", "")` is false while
// `Compare("a", "a")` is true.
//
// ## `Atoi` failing is load-bearing
//
// A digit run longer than an `int` overflows, `strconv.Atoi` returns an error, and the
// comparison silently falls through to the **string** comparison for that chunk. So
// `"9999999999999999999"` versus `"10000000000000000000"` compares lexically — "1" < "9"
// — and orders the larger number first. Reproducing that needs Atoi's exact range, not a
// saturating parse.
//
// ## Both `i == nChunksB-1` exits are redundant, provably
//
// Upstream's numeric and string branches each end with
// `else if i == nChunksB-1 { return false }`. Deleting either changes nothing, ever: the
// alternative is `continue`, and the next iteration opens with `if i >= nChunksB { return
// false }` — which now holds, because `i` was `nChunksB-1`. Same value, one iteration
// later. Kept because it is upstream's shape, and recorded because the negative control
// for it cannot fail and that is not a gap in the corpus.
//
// Its mirror image, the `i == nChunksA-1` exit, returns **true** and is very much live —
// it is the reason `Compare(x, x)` is true.
//===----------------------------------------------------------------------===//

/// Go: `natsort` — natural-order string comparison.
public enum GoNatsort {

    /// Go: `chunkify` — maximal runs of digits and of non-digits, in order.
    ///
    /// Returned as byte slices of the input so the comparison below can be a byte-wise
    /// `<`, matching Go's string comparison.
    @usableFromInline
    static func chunkify(_ s: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = s.startIndex
        while i < s.endIndex {
            let digit = isDigit(s[i])
            var j = i + 1
            while j < s.endIndex && isDigit(s[j]) == digit {
                j += 1
            }
            out.append(s[i..<j])
            i = j
        }
        return out
    }

    private static func isDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    /// Go: `strconv.Atoi` restricted to what a chunk can hold — a non-empty run of
    /// ASCII digits, so only overflow can fail.
    ///
    /// Returns nil exactly when Go returns a non-nil error, which is the case that makes
    /// the caller fall back to comparing the chunks as strings.
    private static func atoi(_ chunk: ArraySlice<UInt8>) -> Int64? {
        guard let first = chunk.first, isDigit(first) else { return nil }
        var n: Int64 = 0
        for b in chunk {
            guard isDigit(b) else { return nil }
            let d = Int64(b - UInt8(ascii: "0"))
            let (m, mo) = n.multipliedReportingOverflow(by: 10)
            if mo { return nil }
            let (s, so) = m.addingReportingOverflow(d)
            if so { return nil }
            n = s
        }
        return n
    }

    /// Go: `bytes.Compare`-style ordering of two chunks, standing in for Go's `<` on
    /// strings — which compares bytes, not characters.
    private static func lexicographicallyBefore(
        _ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>
    ) -> Bool {
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex && j < b.endIndex {
            if a[i] != b[j] {
                return a[i] < b[j]
            }
            i += 1
            j += 1
        }
        return a.count < b.count
    }

    private static func chunksEqual(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
        a.count == b.count && !zip(a, b).contains { $0 != $1 }
    }

    /// Go: `natsort.Compare` — true when `a` precedes `b` in natural order.
    ///
    /// Transcribed with upstream's control flow intact, including the two `i ==
    /// nChunks-1` early exits that make it non-irreflexive. Do not "fix" them: the
    /// output order of `sort_by_label` depends on this exact shape.
    public static func compare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let chunksA = chunkify(a)
        let chunksB = chunkify(b)

        let nChunksA = chunksA.count
        let nChunksB = chunksB.count

        for i in 0..<nChunksA {
            if i >= nChunksB {
                return false
            }

            let aInt = atoi(chunksA[i])
            let bInt = atoi(chunksB[i])

            // Both numeric: compare as integers.
            if let aInt, let bInt {
                if aInt == bInt {
                    if i == nChunksA - 1 {
                        // The last chunk of A is reached, so B is the greater.
                        return true
                    } else if i == nChunksB - 1 {
                        // The last chunk of B is reached, so A is the greater.
                        return false
                    }
                    continue
                }
                return aInt < bInt
            }

            // Equal so far: on to the next chunk, with the same two early exits.
            if chunksEqual(chunksA[i], chunksB[i]) {
                if i == nChunksA - 1 {
                    return true
                } else if i == nChunksB - 1 {
                    return false
                }
                continue
            }

            return lexicographicallyBefore(chunksA[i], chunksB[i])
        }

        return false
    }

    /// Convenience for callers holding Swift strings; label values reach this as bytes.
    @inlinable
    public static func compare(_ a: String, _ b: String) -> Bool {
        compare(Array(a.utf8), Array(b.utf8))
    }
}
