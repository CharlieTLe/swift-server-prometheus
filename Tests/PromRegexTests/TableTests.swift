//===----------------------------------------------------------------------===//
// Differential tests for the regex table layer.
//
// The parser/compiler are not written yet, so these cover what is testable
// without them: fold orbits and \p{...} name resolution. The parse-output half of
// the unicodetable fixture (`class`) activates once the parser lands.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromRegex

struct RuneIn: Decodable, Sendable {
    let r: String
    var value: UInt32 { UInt32(r, radix: 16)! }
}

struct NameIn: Decodable, Sendable {
    let name: String
}

struct UnicodeTableOut: Decodable, Equatable, Sendable {
    let resolves: Bool
    let `class`: String
    let err: String
}

@Suite("SimpleFold matches unicode.SimpleFold")
struct SimpleFoldTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("regex/simplefold.jsonl", FixtureCase<RuneIn, String>.self) {
            String(format: "%04X", UnicodeTables.simpleFold($0.value))
        }
    }

    @Test("multi-member orbits cycle, and that is why (?i) needs them")
    func orbits() {
        // ſ (U+017F) / S / s is a three-member orbit. Prometheus's own regex tests
        // exercise it, so an incomplete orbit is not a theoretical concern.
        var seen = [UInt32]()
        var c: UInt32 = 0x0053  // 'S'
        repeat {
            seen.append(c)
            c = UnicodeTables.simpleFold(c)
        } while c != 0x0053
        #expect(seen.sorted() == [0x0053, 0x0073, 0x017F])

        // Kelvin sign folds with K/k.
        #expect(Set([0x004B, 0x006B, 0x212A].map { UnicodeTables.simpleFold(UInt32($0)) })
            == Set([0x006B, 0x212A, 0x004B]))
    }

    @Test("runes outside the fold bounds are identity")
    func outsideBounds() {
        #expect(UnicodeTables.simpleFold(0x0040) == 0x0040)  // '@', below minFold
        #expect(UnicodeTables.simpleFold(0x10FFFF) == 0x10FFFF)  // above maxFold
        #expect(UnicodeTables.minFold == 0x0041)
        #expect(UnicodeTables.maxFold == 0x1E943)
    }

    @Test("minFoldRune returns the smallest orbit member")
    func minFoldRune() {
        for r in [0x0053, 0x0073, 0x017F] {
            #expect(UnicodeTables.minFoldRune(UInt32(r)) == 0x0053, "\(r)")
        }
        #expect(UnicodeTables.minFoldRune(0x0041) == 0x0041)
    }
}

@Suite(#"\p{...} name resolution matches Go"#)
struct UnicodeTableTests {

    /// Extract the group name from the simple `\p{NAME}` / `\P{NAME}` forms.
    /// The other shapes in the fixture need the parser.
    private func simpleGroupName(_ pattern: String) -> String? {
        guard pattern.count > 4, pattern.hasSuffix("}") else { return nil }
        let prefix = String(pattern.prefix(3))
        guard prefix == #"\p{"# || prefix == #"\P{"# else { return nil }
        return String(pattern.dropFirst(3).dropLast())
    }

    @Test("resolution agrees with Go for every simple fixture case")
    func resolution() throws {
        let cases = try Fixtures.load(
            "regex/unicodetable.jsonl", FixtureCase<NameIn, UnicodeTableOut>.self)
        var checked = 0
        var failures = [String]()
        for c in cases {
            guard let name = simpleGroupName(c.in.name) else { continue }
            // A leading ^ is a parser-level negation, not part of the name.
            if name.hasPrefix("^") { continue }
            checked += 1
            let got = UnicodeTables.unicodeTable(name).tab != nil
            if got != c.out.resolves {
                failures.append("\(c.id) \(c.in.name): resolves got \(got) want \(c.out.resolves)")
            }
        }
        #expect(checked > 30, "fixture should exercise a meaningful number of names")
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: "\n"))")
    }

    @Test("Properties do NOT resolve, unlike Categories and Scripts")
    func propertiesAreNotGroups() {
        // Go's unicodeTable consults unicode.Categories then unicode.Scripts and
        // never unicode.Properties. Merging all three — as a first cut of this port
        // did — would wrongly accept these.
        for name in ["White_Space", "Hyphen", "Dash", "Quotation_Mark"] {
            #expect(UnicodeTables.properties[name] != nil, "\(name) should exist as a property")
            #expect(
                UnicodeTables.unicodeTable(name).tab == nil,
                "\(name) must not resolve as a \\p{...} group")
        }
        // Categories and scripts do resolve.
        for name in ["L", "Lu", "Nd", "Greek", "Han", "Latin"] {
            #expect(UnicodeTables.unicodeTable(name).tab != nil, "\(name)")
        }
    }

    @Test("special names Go handles before the map lookups")
    func specialNames() {
        #expect(UnicodeTables.unicodeTable("Any").sign == +1)
        #expect(UnicodeTables.unicodeTable("Any").tab != nil)
        // Assigned is Cn inverted.
        #expect(UnicodeTables.unicodeTable("Assigned").sign == -1)
        #expect(UnicodeTables.unicodeTable("ASCII").tab != nil)
        // LC is the only non-canonical Categories key.
        #expect(UnicodeTables.unicodeTable("Lc").tab != nil)
    }

    @Test("canonicalName strips separators and fixes case")
    func canonicalName() {
        #expect(UnicodeTables.canonicalName("Uppercase_Letter") == "Uppercaseletter")
        #expect(UnicodeTables.canonicalName("uppercase letter") == "Uppercaseletter")
        #expect(UnicodeTables.canonicalName("Uppercase-Letter") == "Uppercaseletter")
        #expect(UnicodeTables.canonicalName("greek") == "Greek")
        #expect(UnicodeTables.canonicalName("GREEK") == "Greek")
        #expect(UnicodeTables.canonicalName("") == "")
    }

    @Test("aliases resolve through the canonicalised map")
    func aliases() {
        for name in ["Letter", "Uppercase_Letter", "uppercase letter", "Decimal_Number"] {
            #expect(UnicodeTables.unicodeTable(name).tab != nil, "\(name)")
        }
    }

    @Test("fold companions exist for case-sensitive groups")
    func foldCompanions() {
        // \p{Greek} under (?i) must match more than the base table; a missing fold
        // companion makes case-insensitive Unicode classes silently too small.
        #expect(UnicodeTables.unicodeTable("Greek").fold != nil)
        #expect(UnicodeTables.unicodeTable("L").fold != nil)
    }
}

@Suite("Perl and POSIX class data")
struct PerlGroupTests {

    @Test(#"\d \s \w carry Go's exact ranges"#)
    func perlGroups() {
        #expect(UnicodeTables.perlGroups[#"\d"#]! == (1, [0x30, 0x39]))
        #expect(UnicodeTables.perlGroups[#"\D"#]!.sign == -1)
        #expect(UnicodeTables.perlGroups[#"\s"#]!.cls == [0x9, 0xA, 0xC, 0xD, 0x20, 0x20])
        #expect(
            UnicodeTables.perlGroups[#"\w"#]!.cls
                == [0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A])
        // \s notably excludes \v (0x0B): the range is 0x9-0xA then 0xC-0xD.
        #expect(!UnicodeTables.perlGroups[#"\s"#]!.cls.contains(0x0B))
    }

    @Test("all 14 POSIX classes are present in both signs")
    func posixGroups() {
        let names = [
            "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph",
            "lower", "print", "punct", "space", "upper", "word", "xdigit",
        ]
        #expect(names.count == 14)
        for n in names {
            #expect(UnicodeTables.posixGroups["[:\(n):]"]?.sign == 1, "\(n)")
            #expect(UnicodeTables.posixGroups["[:^\(n):]"]?.sign == -1, "\(n)")
        }
        #expect(UnicodeTables.posixGroups.count == 28)
        // [:space:] is 0x9-0xD plus space, unlike \s.
        #expect(UnicodeTables.posixGroups["[:space:]"]!.cls == [0x9, 0xD, 0x20, 0x20])
    }
}

@Suite("Regexp AST and printer")
struct RegexpPrinterTests {

    // Hand-built ASTs: the parser-driven differential coverage of String() arrives
    // with the parser. These pin the cases the Go source specifies directly.

    @Test("literals and metacharacter escaping")
    func literals() {
        #expect(Regexp(op: .literal, rune: Array("abc".unicodeScalars.map(\.value))).description == "abc")
        // meta = \.+*?()|[]{}^$
        #expect(Regexp(op: .literal, rune: [UInt32(UInt8(ascii: "."))]).description == #"\."#)
        #expect(Regexp(op: .literal, rune: [UInt32(UInt8(ascii: "$"))]).description == #"\$"#)
        // Non-printable runes use \x / \n forms.
        #expect(Regexp(op: .literal, rune: [0x0A]).description == #"\n"#)
        #expect(Regexp(op: .literal, rune: [0x00]).description == #"\x00"#)
        // U+1234 is printable, so Go emits it literally; U+E000 (private use) is
        // not, and takes the \x{...} form with lowercase hex.
        #expect(Regexp(op: .literal, rune: [0x1234]).description == "\u{1234}")
        #expect(Regexp(op: .literal, rune: [0xE000]).description == #"\x{e000}"#)
    }

    @Test("anchors, any-char and empty match")
    func simpleOps() {
        #expect(Regexp(op: .emptyMatch).description == "(?:)")
        #expect(Regexp(op: .beginText).description == #"\A"#)
        #expect(Regexp(op: .endText).description == #"\z"#)
        // The parser records whether the anchor came from `$`. At top level that
        // makes calcFlags emit (?-m:...), because `$` means end-of-TEXT only when
        // multiline is off — verified against Go: parse("$").String() == "(?-m:$)".
        #expect(Regexp(op: .endText, flags: .wasDollar).description == "(?-m:$)")
        #expect(Regexp(op: .wordBoundary).description == #"\b"#)
        #expect(Regexp(op: .noWordBoundary).description == #"\B"#)
        #expect(Regexp(op: .noMatch).description == #"[^\x00-\x{10FFFF}]"#)
    }

    @Test("character classes, including the negated-class gap form")
    func charClasses() {
        #expect(Regexp(op: .charClass, rune: [0x61, 0x7A]).description == "[a-z]")
        // Spanning 0...MaxRune prints as a negated class showing the gaps.
        #expect(Regexp(op: .charClass, rune: [0, 0x60, 0x7B, 0x10FFFF]).description == "[^a-z]")
        #expect(Regexp(op: .charClass, rune: []).description == #"[^\x00-\x{10FFFF}]"#)
        // An odd rune count is malformed and Go says so rather than crashing.
        #expect(Regexp(op: .charClass, rune: [0x61]).description == "[invalid char class]")
    }

    @Test("repeat operands are parenthesised only when needed")
    func repeats() {
        let a = { Regexp(op: .literal, rune: [UInt32(UInt8(ascii: "a"))]) }
        #expect(Regexp(op: .star, sub: [a()]).description == "a*")
        #expect(Regexp(op: .plus, sub: [a()]).description == "a+")
        #expect(Regexp(op: .quest, sub: [a()]).description == "a?")
        #expect(Regexp(op: .repeat, sub: [a()], min: 2, max: 5).description == "a{2,5}")
        #expect(Regexp(op: .repeat, sub: [a()], min: 3, max: 3).description == "a{3}")
        #expect(Regexp(op: .repeat, sub: [a()], min: 2, max: -1).description == "a{2,}")
        #expect(Regexp(op: .star, flags: .nonGreedy, sub: [a()]).description == "a*?")
        // A multi-rune literal needs grouping so `ab*` does not become `(ab)*`.
        let ab = Regexp(op: .literal, rune: Array("ab".unicodeScalars.map(\.value)))
        #expect(Regexp(op: .star, sub: [ab]).description == "(?:ab)*")
    }

    @Test("concat, alternate and capture")
    func composites() {
        let a = Regexp(op: .literal, rune: [UInt32(UInt8(ascii: "a"))])
        let b = Regexp(op: .literal, rune: [UInt32(UInt8(ascii: "b"))])
        #expect(Regexp(op: .concat, sub: [a, b]).description == "ab")
        #expect(Regexp(op: .alternate, sub: [a, b]).description == "a|b")
        #expect(Regexp(op: .capture, sub: [a], cap: 1).description == "(a)")
        #expect(Regexp(op: .capture, sub: [a], cap: 1, name: "x").description == "(?P<x>a)")
        // An alternation inside a concat needs grouping.
        let alt = Regexp(op: .alternate, sub: [a, b])
        #expect(Regexp(op: .concat, sub: [alt, a]).description == "(?:a|b)a")
    }

    @Test("dot rendering depends on whether newline is included")
    func anyChar() {
        // Both print as "." but calcFlags wraps them differently at the top level:
        // (?s) for anyChar, (?-s) for anyCharNotNL.
        #expect(Regexp(op: .anyChar).description == "(?s:.)")
        #expect(Regexp(op: .anyCharNotNL).description == "(?-s:.)")
    }

    @Test("structural equality ignores identity")
    func equality() {
        let x = Regexp(op: .literal, rune: [0x61])
        let y = Regexp(op: .literal, rune: [0x61])
        #expect(x.isEqual(to: y))
        #expect(!x.isEqual(to: Regexp(op: .literal, rune: [0x62])))
        // FoldCase is part of literal identity.
        #expect(!x.isEqual(to: Regexp(op: .literal, flags: .foldCase, rune: [0x61])))
        // $ versus \z are distinguished by WasDollar.
        #expect(!Regexp(op: .endText).isEqual(to: Regexp(op: .endText, flags: .wasDollar)))
    }
}
