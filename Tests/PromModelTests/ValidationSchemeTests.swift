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
