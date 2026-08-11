//===----------------------------------------------------------------------===//
// `regexp.QuoteMeta`, pinned against `github.com/grafana/regexp` — the package Prometheus actually
// imports. `promql/info.go` builds its info-series selector by joining quoted label values with `|`,
// so an escape the port gets wrong silently widens a selector rather than failing.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromRegex
import Testing

struct QuoteMetaIn: Codable, Sendable { var s: String }
struct QuoteMetaOut: Decodable, Equatable, Sendable { var out: String }

@Suite("regexp.QuoteMeta")
struct QuoteMetaTests {
    @Test("every committed case matches Go")
    func matchesGo() throws {
        try Fixtures.check("regex/quotemeta.jsonl", FixtureCase<QuoteMetaIn, QuoteMetaOut>.self) {
            input in
            QuoteMetaOut(out: goQuoteMeta(input.s))
        }
    }
}
