//===----------------------------------------------------------------------===//
// `FindIntersectingPostings` — which candidate lists intersect the query.
//
// **The ORDER of the returned indexes is a heap's internal order, and that is the point of the corpus.** The
// set of intersecting candidates is easy to get right by any method; the order comes out of three separate
// decisions — `heap.Init` rather than repeated pushes, `Less`'s popped-to-the-bottom rule, and the loop's
// asymmetric match/overshoot branches — none of which is derivable from the inputs by inspection. A port that
// pushed in a loop, or sorted instead of heaping, agrees on every set and almost no order.
//
// So this test compares the returned slice as a SEQUENCE. If it ever needs to be relaxed to a set comparison,
// that is a decision to argue in PORTING.md, not a convenience.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromIndex
import PromStorage
import Testing

struct FindIntersectingIn: Codable, Sendable {
    var query: [UInt64]?
    var candidates: [[UInt64]]?
}

struct FindIntersectingOut: Decodable, Equatable, Sendable {
    var indexes: [Int]
    var err: String
}

@Suite("index: FindIntersectingPostings")
struct FindIntersectingTests {

    @Test("every committed case returns the same indexes in the same order")
    func matchesGo() throws {
        try Fixtures.check(
            "index/findintersecting.jsonl", FixtureCase<FindIntersectingIn, FindIntersectingOut>.self
        ) { input in
            let q = ListPostings((input.query ?? []).map { SeriesRef(rawValue: $0) })
            let cands: [any Postings] = (input.candidates ?? []).map { c in
                ListPostings(c.map { SeriesRef(rawValue: $0) })
            }
            do {
                return FindIntersectingOut(
                    indexes: try findIntersectingPostings(q, cands), err: "")
            } catch {
                return FindIntersectingOut(indexes: [], err: String(describing: error))
            }
        }
    }
}
