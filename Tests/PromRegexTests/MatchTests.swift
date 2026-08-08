//===----------------------------------------------------------------------===//
// The other half of the Phase 2 gate: does the engine MATCH like Go, and does
// SetMatches agree?
//
// These pin FastRegexMatcher, which is the exact surface Matcher.Matches uses —
// not a lower-level approximation of it.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromRegex

struct MatchIn: Decodable, Sendable {
    let pattern: String
    let subject: String
    var patternText: String { String(decoding: Hex.decode(pattern), as: UTF8.self) }
    var subjectText: String { String(decoding: Hex.decode(subject), as: UTF8.self) }
}

struct SetOut: Decodable, Equatable, Sendable {
    let set: [String]
    let optimized: Bool
}

@Suite("FastRegexMatcher matches Go")
struct MatchTests {

    @Test("MatchString for every committed fixture case")
    func fixtures() throws {
        // Rebuilding the matcher per case would recompile the same pattern dozens
        // of times, so cache by pattern.
        var cache = [String: FastRegexMatcher]()
        try Fixtures.check("regex/match.jsonl", FixtureCase<MatchIn, Bool>.self) { input in
            let p = input.patternText
            let m: FastRegexMatcher
            if let cached = cache[p] {
                m = cached
            } else {
                m = try FastRegexMatcher(p)
                cache[p] = m
            }
            return m.matchString(input.subjectText)
        }
    }

    @Test("SetMatches for every committed fixture case")
    func setMatches() throws {
        // Asserts the SET only. `optimized` is recorded in the fixture but not
        // compared: Go's IsOptimized() is true whenever ANY optimisation applied,
        // including the StringMatcher hierarchy this port deliberately omits as
        // performance-only. It is consumed nowhere in the Prometheus server — only
        // by upstream's own matcher_test.go. See docs/PORTING.md exception 7.
        let cases = try Fixtures.load(
            "regex/setmatches.jsonl", FixtureCase<PatternIn, SetOut>.self)
        var failures = [String]()
        for c in cases {
            let m = try FastRegexMatcher(c.in.pattern)
            let got = m.setMatches.map { Hex.encode(Array($0.utf8)) }
            if got != c.out.set {
                failures.append("\(c.id) \(c.in.pattern.debugDescription)")
            }
        }
        #expect(cases.count > 600)
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: ", "))")
    }

    @Test("isOptimized is narrower than Go's, by design")
    func optimizedIsNarrower() throws {
        // We report only the set-match optimisation. Go additionally reports
        // stringMatcher/prefix/suffix/contains, so Go says true for these while we
        // say false. Semantics are unaffected: without those shortcuts the engine
        // runs, which is what they exist to avoid, not to change.
        #expect(try FastRegexMatcher("a|b").isOptimized)  // set match: we agree
        #expect(try !FastRegexMatcher("ab*c").isOptimized)  // Go: true (prefix/suffix)
        #expect(try !FastRegexMatcher(".*").isOptimized)  // Go: true (stringMatcher)
    }

    @Test("anchoring is full-match, not search")
    func fullMatch() throws {
        let m = try FastRegexMatcher("foo")
        #expect(m.matchString("foo"))
        // Prometheus anchors with ^(?s:...)$, so a substring must not match.
        #expect(!m.matchString("foobar"))
        #expect(!m.matchString("xfoo"))

        let dotStar = try FastRegexMatcher(".*foo.*")
        #expect(dotStar.matchString("xfooy"))
        #expect(!dotStar.matchString("bar"))
    }

    @Test("(?s) means dot matches newline, which Prometheus relies on")
    func dotMatchesNewline() throws {
        // The compiled form is ^(?s:...)$, so `.` spans newlines.
        #expect(try FastRegexMatcher(".*").matchString("a\nb"))
        #expect(try FastRegexMatcher("a.b").matchString("a\nb"))
    }

    @Test("case-insensitive matching folds Unicode, not just ASCII")
    func unicodeFolding() throws {
        let m = try FastRegexMatcher("(?i)s")
        #expect(m.matchString("s"))
        #expect(m.matchString("S"))
        // ſ (U+017F) folds with s/S — the case Prometheus's own tests exercise.
        #expect(m.matchString("ſ"))

        let k = try FastRegexMatcher("(?i)k")
        #expect(k.matchString("K"))
        #expect(k.matchString("\u{212A}"))  // Kelvin sign
    }

    @Test("no catastrophic backtracking: an NFA simulation stays linear")
    func noCatastrophicBacktracking() throws {
        // This is the ADR-6 property. A backtracking engine takes exponential time
        // on this shape; an NFA simulation does not. The assertion is simply that
        // it completes — under ICU this pattern is a denial-of-service vector, and
        // these patterns arrive verbatim from user queries.
        let m = try FastRegexMatcher("(a+)+b")
        let subject = String(repeating: "a", count: 60)
        #expect(!m.matchString(subject))

        let m2 = try FastRegexMatcher("(x+x+)+y")
        #expect(!m2.matchString(String(repeating: "x", count: 60)))
    }

    @Test("SetMatches feeds TSDB index lookups, so it must be exact")
    func setMatchesSemantics() throws {
        // A literal alternation reduces to a finite set.
        #expect(try FastRegexMatcher("a|b|c").setMatches == ["a", "b", "c"])
        #expect(try FastRegexMatcher("foo").setMatches == ["foo"])
        // Duplicates are preserved, as Go's slice-backed matcher does.
        #expect(try FastRegexMatcher("a|a").setMatches == ["a", "a"])
        // The empty pattern yields no set: Go returns nil there even though the
        // set would be [""].
        #expect(try FastRegexMatcher("").setMatches.isEmpty)
        #expect(try !FastRegexMatcher("").isOptimized)
        // Anything requiring the engine yields no set.
        #expect(try FastRegexMatcher(".*").setMatches.isEmpty)
        #expect(try FastRegexMatcher("a+").setMatches.isEmpty)
    }
}
