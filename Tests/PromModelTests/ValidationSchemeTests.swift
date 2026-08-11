//===----------------------------------------------------------------------===//
// Differential tests for prometheus/common/model validation semantics.
//===----------------------------------------------------------------------===//

import Testing

@testable import PromModel

@Suite("ValidationScheme matches prometheus/common")
struct ValidationSchemeTests {

    @Test("legacy label names exclude ':' but metric names include it")
    func colonAsymmetry() {
        // model/metric.go: IsValidLabelName inlines its own character class,
        // while IsValidMetricName goes through isValidLegacyRune, which permits ':'.
        #expect(!ValidationScheme.legacy.isValidLabelName("with:colon"))
        #expect(ValidationScheme.legacy.isValidMetricName("with:colon"))
    }

    @Test("legacy rejects a leading digit but allows digits later")
    func leadingDigit() {
        #expect(!ValidationScheme.legacy.isValidLabelName("0abc"))
        #expect(ValidationScheme.legacy.isValidLabelName("a0bc"))
        #expect(ValidationScheme.legacy.isValidLabelName("_abc"))
        #expect(ValidationScheme.legacy.isValidLabelName("__name__"))
    }

    @Test("empty is invalid under both schemes")
    func empty() {
        #expect(!ValidationScheme.legacy.isValidLabelName(""))
        #expect(!ValidationScheme.utf8.isValidLabelName(""))
        #expect(!ValidationScheme.legacy.isValidMetricName(""))
        #expect(!ValidationScheme.utf8.isValidMetricName(""))
    }

    @Test("utf8 accepts what legacy rejects")
    func utf8Permissive() {
        for n in ["with.dot", "with space", "üñïçø∂é", "0leading", "with:colon"] {
            #expect(ValidationScheme.utf8.isValidLabelName(n), "\(n)")
            #expect(!ValidationScheme.legacy.isValidLabelName(n), "\(n)")
        }
    }
}

// MARK: - The byte overload, and why it exists

@Suite("isValidLabelName over raw bytes")
struct ValidationSchemeBytesTests {

    @Test("invalid UTF-8 is rejected on the bytes and accepted after decoding")
    func invalidUTF8() {
        // `a\xC5z` — 0xC5 is a two-byte lead followed by `z`, which is not a continuation. Go's
        // `utf8.ValidString` rejects it, so `count_values("a\xc5z", …)` is an error upstream.
        let bad: [UInt8] = [0x61, 0xC5, 0x7A]
        #expect(!ValidationScheme.utf8.isValidLabelName(bad))
        // And the reason the byte overload has to exist: decoding substitutes U+FFFD, after which
        // the name is valid UTF-8 by construction and the check can no longer fail. That is
        // ADR-9's lossiness, and it cost one exit-gate assertion until the bytes were checked.
        #expect(ValidationScheme.utf8.isValidLabelName(String(decoding: bad, as: UTF8.self)))
    }

    @Test("the UTF-8 validator rejects what Go's rejects")
    func utf8Validator() {
        // Valid: ASCII, two-, three- and four-byte sequences.
        #expect(ValidationScheme.utf8.isValidLabelName(Array("abc".utf8)))
        #expect(ValidationScheme.utf8.isValidLabelName(Array("é".utf8)))
        #expect(ValidationScheme.utf8.isValidLabelName(Array("€".utf8)))
        #expect(ValidationScheme.utf8.isValidLabelName(Array("𝄞".utf8)))
        // Empty is invalid whatever the scheme.
        #expect(!ValidationScheme.utf8.isValidLabelName([UInt8]()))
        // A truncated sequence.
        #expect(!ValidationScheme.utf8.isValidLabelName([0xE2, 0x82]))
        // OVERLONG: `0xC0 0x80` encodes U+0000 in two bytes, which Go rejects — the whole reason
        // `0xC0`/`0xC1` are never legal leads.
        #expect(!ValidationScheme.utf8.isValidLabelName([0xC0, 0x80]))
        #expect(!ValidationScheme.utf8.isValidLabelName([0xE0, 0x80, 0x80]))
        // A SURROGATE, U+D800 spelled as `0xED 0xA0 0x80`. Legal in UTF-16, never in UTF-8.
        #expect(!ValidationScheme.utf8.isValidLabelName([0xED, 0xA0, 0x80]))
        // ABOVE U+10FFFF.
        #expect(!ValidationScheme.utf8.isValidLabelName([0xF4, 0x90, 0x80, 0x80]))
        #expect(!ValidationScheme.utf8.isValidLabelName([0xF5, 0x80, 0x80, 0x80]))
        // A bare continuation byte.
        #expect(!ValidationScheme.utf8.isValidLabelName([0x80]))
        // The legacy scheme is byte-wise and unchanged by any of this.
        #expect(ValidationScheme.legacy.isValidLabelName(Array("a_1".utf8)))
        #expect(!ValidationScheme.legacy.isValidLabelName(Array("1a".utf8)))
        #expect(!ValidationScheme.legacy.isValidLabelName(Array("é".utf8)))
    }
}
