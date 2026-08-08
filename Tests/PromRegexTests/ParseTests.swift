//===----------------------------------------------------------------------===//
// The Phase 2 gate: does the ported parser build the same tree as Go, and refuse
// the same patterns with the same message?
//
// The corpus is Go's own regexp testdata (basic.dat, repetition.dat,
// nullsubexpr.dat, re2-search.txt), Prometheus's real matcher shapes, hand-picked
// syntax corners, and 4,000 random mutations — mutations being where the
// accept/reject boundary actually gets probed.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromRegex

struct PatternIn: Decodable, Sendable {
    let s: String
    var pattern: String { String(decoding: Hex.decode(s), as: UTF8.self) }
    var patternBytes: [UInt8] { Hex.decode(s) }
}

struct ParseOutRegex: Decodable, Equatable, Sendable {
    let tree: String
    let err: String
}

@Suite("Regex parser matches Go syntax.Parse")
struct RegexParseTests {

    @Test("tree and error text for every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("regex/parse.jsonl", FixtureCase<PatternIn, ParseOutRegex>.self) { input in
            do {
                // Prometheus's flags: syntax.Perl | syntax.DotNL.
                // Bytes, not String: three fixture patterns are invalid UTF-8, and
                // decoding them into a String would silently replace the bad bytes
                // with U+FFFD and hide Go's ErrInvalidUTF8 (ADR-9).
                let re = try parseRegex(bytes: input.patternBytes, [.perl, .dotNL])
                return ParseOutRegex(tree: re.description, err: "")
            } catch let e as RegexError {
                return ParseOutRegex(tree: "", err: e.description)
            }
        }
    }

    @Test("error messages reproduce Go's text exactly")
    func errorText() {
        // These strings reach users through PromQL, so they are contractual.
        func err(_ p: String) -> String? {
            do {
                _ = try parseRegex(p, [.perl, .dotNL])
                return nil
            } catch let e as RegexError {
                return e.description
            } catch {
                return "unexpected \(error)"
            }
        }
        #expect(err("a**") == "error parsing regexp: invalid nested repetition operator: `**`")
        #expect(err("(") == "error parsing regexp: missing closing ): `(`")
        #expect(err(")") == "error parsing regexp: unexpected ): `)`")
        #expect(err("[a") == "error parsing regexp: missing closing ]: `[a`")
        #expect(err("*a") == "error parsing regexp: missing argument to repetition operator: `*`")
        #expect(err("\\") == "error parsing regexp: trailing backslash at end of expression: ``")
        #expect(err("a{1001}") == "error parsing regexp: invalid repeat count: `{1001}`")
        #expect(err("[z-a]") == "error parsing regexp: invalid character class range: `z-a`")
        #expect(err("\\p{Nope}") == "error parsing regexp: invalid character class range: `\\p{Nope}`")
    }

    @Test("alternation factoring reshapes the tree, and that is observable")
    func factoring() throws {
        // Go factors common prefixes out of alternations. findSetMatches walks the
        // factored tree, so the shape matters beyond cosmetics.
        #expect(try parseRegex("abc|abd", [.perl, .dotNL]).description == "ab[cd]")
        #expect(try parseRegex("a|b", [.perl, .dotNL]).description == "[ab]")
        #expect(try parseRegex("ABC|ABD|AEF|BCX|BCY", [.perl, .dotNL]).description
            == "A(?:B[CD]|EF)|BC[XY]")
    }

    @Test("case folding is baked into the tree at parse time")
    func folding() throws {
        // (?i) is compiled away into class ranges / folded literals, which is why
        // the port needs Go's exact fold orbits.
        // Verified against Go: folded literals store the orbit MINIMUM, so "abc"
        // becomes ABC, and the printer wraps it as (?i:...).
        let re = try parseRegex("(?i)abc", [.perl, .dotNL])
        #expect(re.description == "(?i:ABC)")
        #expect(re.rune == [0x41, 0x42, 0x43])
        // ſ folds with s/S, so a folded literal normalises to the orbit minimum.
        let s = try parseRegex("(?i)ſ", [.perl, .dotNL])
        #expect(s.op == .literal)
        #expect(s.flags.contains(.foldCase))
        #expect(s.rune == [0x53])  // minFoldRune(ſ) == 'S'
    }

    @Test("Prometheus's own matcher shapes parse")
    func prometheusShapes() throws {
        for p in [
            ".*", ".+", ".?", ".*foo.*", ".*foo.*|.*bar.*", "(?i:(foo|bar))",
            ".*(?i:abc).*", "(?i).*(?-i:abc)def", ".*(?msU:abc).*",
            "(?i:(xyz-016a-ixb-dp.*|xyz-016a-ixb-op.*))", "😀", "❤️",
        ] {
            #expect(throws: Never.self, "\(p)") { try parseRegex(p, [.perl, .dotNL]) }
        }
    }

    @Test("deeply nested patterns hit the nesting limit rather than crashing")
    func nestingLimit() {
        let deep = String(repeating: "(", count: 1200) + "a" + String(repeating: ")", count: 1200)
        do {
            _ = try parseRegex(deep, [.perl, .dotNL])
            Issue.record("expected a nesting-depth error")
        } catch let e as RegexError {
            #expect(e.code == .nestingDepth)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
