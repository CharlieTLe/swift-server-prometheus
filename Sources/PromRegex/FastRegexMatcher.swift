//===----------------------------------------------------------------------===//
// Ported from model/labels/regexp.go @ v3.13.2 — the parts that are semantically
// required.
//
// What is here:
//   MatchString    parse -> String() -> re-parse anchored -> simplify -> compile
//                  -> NFA. This mirrors Go exactly, including the round-trip
//                  through String(), because Prometheus compiles
//                  `"^(?s:" + parsed.String() + ")$"` (regexp.go:76).
//   SetMatches     findSetMatches and optimizeAlternatingLiterals. NOT an
//                  optimisation: TSDB turns a regex matcher into direct index
//                  lookups with it, so it must be exact before Phase 6.
//
// What is deliberately NOT here: the ~600-line StringMatcher hierarchy
// (containsStringMatcher, literalPrefix*, zeroOrOneCharacter*, ...). Those exist
// purely to avoid running the regex engine. Go falls back to `m.re.MatchString`
// whenever they do not apply, so always running the engine yields exactly the
// semantics they are designed to preserve — just slower. Revisit under profiling,
// not before.
//===----------------------------------------------------------------------===//

/// Go: `labels.FastRegexMatcher`.
public struct FastRegexMatcher: Sendable {

    public let regexString: String
    private let machine: RegexMachine
    private let setMatchesValue: [String]
    private let optimized: Bool
    private let prefixValue: String

    /// Go: `maxSetMatches`.
    static let maxSetMatches = 256

    public init(_ pattern: String) throws {
        regexString = pattern

        // Go: optimizeAlternatingLiterals runs first and, when it succeeds,
        // short-circuits both the matcher and setMatches.
        let (literalSet, isLiteralAlternation) = Self.optimizeAlternatingLiterals(pattern)

        // Go: syntax.Parse(v, syntax.Perl|syntax.DotNL).
        let parsed = try parseRegex(pattern, [.perl, .dotNL])

        // Go: regexp.Compile("^(?s:" + parsed.String() + ")$"). The round-trip
        // through String() is reproduced rather than short-circuited so any
        // rendering quirk is shared with Go.
        let anchored = try parseRegex("^(?s:" + parsed.description + ")$", .perl)
        machine = RegexMachine(compileRegex(anchored.simplify()))

        if isLiteralAlternation {
            setMatchesValue = literalSet
            optimized = true
            prefixValue = Self.commonPrefix(literalSet)
        } else {
            // Go: clearCapture then findSetMatches on the parsed tree.
            let forSet = parsed.copy()
            Self.clearCapture(forSet)
            let (matches, caseSensitive) = Self.findSetMatches(forSet)
            if caseSensitive, matches.count < Self.maxSetMatches {
                setMatchesValue = matches
                optimized = !matches.isEmpty
            } else {
                setMatchesValue = []
                optimized = false
            }
            prefixValue = Self.commonPrefix(setMatchesValue)
        }
    }

    /// Go: `FastRegexMatcher.MatchString`.
    public func matchString(_ s: String) -> Bool {
        machine.matches(s)
    }

    /// Go: `FastRegexMatcher.SetMatches`.
    ///
    /// Order is not contractual — Go's map-backed matcher iterates a randomized
    /// Go map above ~16 alternates — so this is sorted. See docs/PORTING.md.
    public var setMatches: [String] { setMatchesValue.sorted() }

    /// Go: `FastRegexMatcher.IsOptimized`.
    public var isOptimized: Bool { optimized }

    /// Go: `FastRegexMatcher.prefix`.
    public var prefix: String { prefixValue }

    // MARK: - optimizeAlternatingLiterals

    /// Go: `optimizeAlternatingLiterals`.
    ///
    /// Returns the literal set and whether the pattern is entirely literals or a
    /// literal alternation. Note Go returns a matcher but **nil** setMatches for
    /// the empty pattern, so an empty regex is not optimised.
    static func optimizeAlternatingLiterals(_ s: String) -> ([String], Bool) {
        if s.isEmpty { return ([], false) }

        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        // Go uses regexp.QuoteMeta(x) == x to test "is a plain literal".
        for p in parts where !Self.isPlainLiteral(p) {
            return ([], false)
        }
        return (parts, true)
    }

    /// Go: `regexp.QuoteMeta(s) == s`.
    static func isPlainLiteral(_ s: String) -> Bool {
        let meta = Set(#"\.+*?()|[]{}^$"#.unicodeScalars.map(\.value))
        for u in s.unicodeScalars where meta.contains(u.value) { return false }
        return true
    }

    static func commonPrefix(_ strings: [String]) -> String {
        guard var common = strings.first else { return "" }
        for s in strings.dropFirst() {
            common = String(zip(common, s).prefix { $0.0 == $0.1 }.map(\.0))
            if common.isEmpty { break }
        }
        return common
    }

    // MARK: - findSetMatches

    /// Go: `clearCapture` — drops capture nodes so the set search can see through them.
    static func clearCapture(_ re: Regexp) {
        var i = 0
        while i < re.sub.count {
            let sub = re.sub[i]
            if sub.op == .capture && sub.sub.count == 1 {
                re.sub[i] = sub.sub[0]
                continue  // re-examine the replacement
            }
            clearCapture(sub)
            i += 1
        }
        if re.op == .capture && re.sub.count == 1 {
            let inner = re.sub[0]
            re.op = inner.op
            re.flags = inner.flags
            re.sub = inner.sub
            re.rune = inner.rune
            re.min = inner.min
            re.max = inner.max
            re.cap = 0
            re.name = ""
        }
    }

    /// Go: `clearBeginEndText` — strips a leading `^` / trailing `$` so the set
    /// search sees the bare alternation.
    static func clearBeginEndText(_ re: Regexp) {
        guard re.op == .concat, !re.sub.isEmpty else { return }
        if re.sub.first?.op == .beginText { re.sub.removeFirst() }
        if re.sub.last?.op == .endText { re.sub.removeLast() }
        if re.sub.count == 1 {
            let inner = re.sub[0]
            re.op = inner.op
            re.flags = inner.flags
            re.sub = inner.sub
            re.rune = inner.rune
        }
    }

    /// Go: `findSetMatches`.
    static func findSetMatches(_ re: Regexp) -> ([String], Bool) {
        clearBeginEndText(re)
        return findSetMatchesInternal(re, "")
    }

    /// Go: `findSetMatchesInternal`.
    static func findSetMatchesInternal(_ re: Regexp, _ base: String) -> ([String], Bool) {
        switch re.op {
        case .beginText, .endText:
            // Handling these inside a regex is subtle, so Go falls back to the engine.
            return ([], false)
        case .literal:
            return ([base + String(String.UnicodeScalarView(re.rune.compactMap(Unicode.Scalar.init)))],
                isCaseSensitive(re))
        case .emptyMatch:
            if !base.isEmpty { return ([base], isCaseSensitive(re)) }
            return ([], false)
        case .alternate:
            return findSetMatchesFromAlternate(re, base)
        case .capture:
            clearCapture(re)
            return findSetMatchesInternal(re, base)
        case .concat:
            return findSetMatchesFromConcat(re, base)
        case .charClass:
            if re.rune.count == 1 {
                // A one-rune "class" is a single character.
                guard let sc = Unicode.Scalar(re.rune[0]) else { return ([], false) }
                return ([base + String(sc)], isCaseSensitive(re))
            }
            var matches = [String]()
            var i = 0
            while i + 1 < re.rune.count {
                var lo = re.rune[i]
                let hi = re.rune[i + 1]
                if hi - lo > UInt32(maxSetMatches) { return ([], false) }
                while lo <= hi {
                    guard let sc = Unicode.Scalar(lo) else { return ([], false) }
                    matches.append(base + String(sc))
                    if matches.count > maxSetMatches { return ([], false) }
                    lo += 1
                }
                i += 2
            }
            return (matches, isCaseSensitive(re))
        default:
            return ([], false)
        }
    }

    /// Go: `findSetMatchesFromConcat`.
    static func findSetMatchesFromConcat(_ re: Regexp, _ base: String) -> ([String], Bool) {
        if re.sub.isEmpty { return ([], false) }
        for s in re.sub { clearCapture(s) }

        var matches = [base]
        var caseSensitive = true
        for sub in re.sub {
            var newMatches = [String]()
            for b in matches {
                let (m, cs) = findSetMatchesInternal(sub, b)
                if m.isEmpty { return ([], false) }
                if matches.count > maxSetMatches || newMatches.count + m.count > maxSetMatches {
                    return ([], false)
                }
                newMatches.append(contentsOf: m)
                caseSensitive = caseSensitive && cs
            }
            matches = newMatches
        }
        return (matches, caseSensitive)
    }

    /// Go: `findSetMatchesFromAlternate`.
    static func findSetMatchesFromAlternate(_ re: Regexp, _ base: String) -> ([String], Bool) {
        var setMatches = [String]()
        var caseSensitive = true
        for sub in re.sub {
            let (found, cs) = findSetMatchesInternal(sub, base)
            if found.isEmpty { return ([], false) }
            if setMatches.count + found.count > maxSetMatches { return ([], false) }
            setMatches.append(contentsOf: found)
            caseSensitive = caseSensitive && cs
        }
        return (setMatches, caseSensitive)
    }

    /// Go: `isCaseSensitive` — the inverse of the FoldCase flag.
    static func isCaseSensitive(_ re: Regexp) -> Bool {
        !re.flags.contains(.foldCase)
    }
}
