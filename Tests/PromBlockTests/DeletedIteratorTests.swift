//===----------------------------------------------------------------------===//
// `DeletedIterator` — a chunk iterator with deletion intervals applied.
//
// **The behaviour under test is statefulness, so the corpus is a SCRIPT, not a query.** `DeletedIterator`
// consumes its interval list as it advances (`it.Intervals = it.Intervals[1:]`), so the list is a cursor
// rather than a filter. Each case therefore runs a sequence of `next()`/`seek(_:)` calls on ONE iterator and
// records, per step, the value type and timestamp — then the interval list that survived, then a SECOND pass,
// then a fresh iterator drained fully.
//
// The second pass is what a non-consuming port fails: after a full pass the list is empty, so a filter-style
// implementation would still delete, and this one no longer can. The fresh drain is the complement — what
// deletion actually *means* — so a failure says which of the two properties broke.
//
// The wrapped iterator is a real `XORChunk` iterator on both sides, not a stub, so a disagreement in the
// port's own chunk decoding surfaces here rather than being masked by a hand-rolled sample source.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromBlock
import PromChunkEnc
import PromHistogram
import Testing

struct DeletedIterIn: Codable, Sendable {
    var samples: [[Int64]]?
    var intervals: [[Int64]]?
    var ops: [String]?
}

struct DeletedIterOut: Decodable, Equatable, Sendable {
    var types: [String]
    var times: [Int64]
    var remaining: [[Int64]]
    var secondPass: [Int64]
    var fullDrain: [Int64]
    var err: String
}

/// `ValueType.description` is the pinned port of Go's `ValueType.String()`, so the names come from there
/// rather than from a second switch that could drift from it.
private func valueTypeName(_ v: ValueType) -> String { v.description }

@Suite("block: DeletedIterator")
struct DeletedIteratorTests {

    @Test("every committed script matches Go, including the interval list it leaves behind")
    func matchesGo() throws {
        try Fixtures.check(
            "block/deletediter.jsonl", FixtureCase<DeletedIterIn, DeletedIterOut>.self
        ) { input in
            var out = DeletedIterOut(
                types: [], times: [], remaining: [], secondPass: [], fullDrain: [], err: "")

            func build() throws -> DeletedIterator {
                let c = XORChunk()
                let app = try c.appender()
                for s in input.samples ?? [] {
                    app.append(s[0], Double(s[1]))
                }
                let ivs = (input.intervals ?? []).map {
                    DeletionInterval(mint: $0[0], maxt: $0[1])
                }
                // `XORIterator` is a struct in the port; `AnyChunkIterator` boxes it so the protocol's
                // `AnyObject` requirement holds. That box is a port detail, not a divergence — Go's
                // `chunkenc.Iterator` is already an interface over a pointer.
                return DeletedIterator(iter: BoxedXORIterator(c.iterator()), intervals: ivs)
            }

            let it = try build()
            for op in input.ops ?? [] {
                let vt: ValueType
                if op == "n" {
                    vt = it.next()
                } else {
                    let target = Int64(op.dropFirst()) ?? 0
                    vt = it.seek(target)
                }
                out.types.append(valueTypeName(vt))
                // Go records a sentinel rather than reading `AtT` after exhaustion.
                out.times.append(vt == .none ? -(1 << 62) : it.atT())
            }
            out.remaining = it.intervals.map { [$0.mint, $0.maxt] }
            while it.next() != .none {
                out.secondPass.append(it.atT())
            }
            if let e = it.err() { out.err = String(describing: e) }

            let fresh = try build()
            while fresh.next() != .none {
                out.fullDrain.append(fresh.atT())
            }
            if out.err.isEmpty, let e = fresh.err() { out.err = String(describing: e) }
            return out
        }
    }
}

/// A reference box around the port's `XORIterator`, which is a `struct`.
///
/// `ChunkIterator` is `AnyObject` because Go's `chunkenc.Iterator` is an interface over a pointer and
/// `SampleIterable.iterator(_:)` hands one back for reuse. The XOR iterator predates that protocol and is a
/// value type, so this adapts it. Nothing here decides anything — every method forwards.
private final class BoxedXORIterator: ChunkIterator {
    private var it: XORIterator

    init(_ it: XORIterator) { self.it = it }

    func next() -> ValueType { it.next() }
    func seek(_ t: Int64) -> ValueType { it.seek(t) }
    func at() -> (Int64, Double) { it.at }
    func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) { (Int64.min, nil) }
    func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) { (Int64.min, nil) }
    func atT() -> Int64 { it.at.0 }
    /// `XORIterator` has no start timestamp — Go's `xorIterator.AtST` returns 0, which the protocol
    /// documents as "unimplemented/unset". XOR2 is where an ST actually lives.
    func atST() -> Int64 { 0 }
    func err() -> (any Error)? { it.err }
}
