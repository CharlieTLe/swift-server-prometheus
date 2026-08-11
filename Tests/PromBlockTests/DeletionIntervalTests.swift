//===----------------------------------------------------------------------===//
// `tombstones.Intervals.Add` and `Interval.IsSubrange`.
//
// The tombstone FILE reader is deliberately unported (PORTING.md exception 16), but this arithmetic is on the
// hot path of every range query against a block whether tombstones exist or not: `blockBaseSeriesSet.Next`
// trims a series to the requested range by adding `[MinInt64, mint-1]` and `[maxt+1, MaxInt64]` as deletion
// intervals. So the overflow guards in `Add` are the COMMON path, and in Swift a missing one traps rather than
// wrapping.
//
// Each case applies a SEQUENCE of `Add`s and records the whole interval set after every step, because `Add`'s
// contract is an invariant — the set stays sorted, non-overlapping and merged — and a single call cannot show
// that the invariant survives.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import Testing

struct IntervalsIn: Codable, Sendable {
    var adds: [[Int64]]?
    var probes: [[Int64]]?
}

struct IntervalsOut: Decodable, Equatable, Sendable {
    var states: [[[Int64]]]
    var subrange: [Bool]
    var inBoundsFirst: [Bool]
}

@Suite("block: deletion-interval arithmetic")
struct DeletionIntervalTests {

    @Test("every committed Add sequence and IsSubrange probe matches Go")
    func matchesGo() throws {
        try Fixtures.check(
            "block/tsintervals.jsonl", FixtureCase<IntervalsIn, IntervalsOut>.self
        ) { input in
            var out = IntervalsOut(states: [], subrange: [], inBoundsFirst: [])
            var cur: [DeletionInterval] = []
            for a in input.adds ?? [] {
                cur = cur.addingInterval(DeletionInterval(mint: a[0], maxt: a[1]))
                out.states.append(cur.map { [$0.mint, $0.maxt] })
            }
            for p in input.probes ?? [] {
                let iv = DeletionInterval(mint: p[0], maxt: p[1])
                out.subrange.append(iv.isSubrange(cur))
                out.inBoundsFirst.append(cur.first?.inBounds(p[0]) ?? false)
            }
            return out
        }
    }
}
