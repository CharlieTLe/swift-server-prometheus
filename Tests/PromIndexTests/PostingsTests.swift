//===----------------------------------------------------------------------===//
// The postings algebra, driven by SCRIPTS of iterator operations rather than by expanding.
//
// Expanding only would miss most of the contract: `Seek` is idempotent, may not advance, and is called
// repeatedly with unchanged targets by `Intersect` — so the interesting behaviour lives in interleaved
// `next`/`seek` sequences, and that is what the corpus records.
//
// Unlike `bstream`/`varbit`, everything here is exported upstream, so this pins directly.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromIndex
import PromStorage
import Testing

/// A postings expression: a leaf, or an operator over sub-expressions.
final class PostingsExpr: Codable, Sendable {
    let op: String
    let list: [UInt64]?
    let subs: [PostingsExpr]?
}

struct PostingsOp: Codable, Sendable {
    var op: String
    var v: UInt64
}

struct PostingsIn: Codable, Sendable {
    var expr: PostingsExpr
    var ops: [PostingsOp]
}

struct PostingsStep: Codable, Equatable, Sendable {
    var ok: Bool
    var at: UInt64
}

struct PostingsOut: Decodable, Equatable, Sendable {
    var steps: [PostingsStep]
    var err: String
    var expanded: [UInt64]
    var expandOK: Bool
    var isEmptySentinel: Bool
}

private struct TestPostingsFailure: Error, CustomStringConvertible {
    var description: String { "test postings failure" }
}

private func build(_ e: PostingsExpr) -> any Postings {
    switch e.op {
    case "list":
        return ListPostings((e.list ?? []).map { SeriesRef(rawValue: $0) })
    case "empty":
        return emptyPostings()
    case "err":
        return errPostings(TestPostingsFailure())
    case "intersect":
        return intersect((e.subs ?? []).map(build))
    case "merge":
        return merge((e.subs ?? []).map(build))
    case "without":
        let subs = e.subs ?? []
        return without(build(subs[0]), build(subs[1]))
    default:
        preconditionFailure("unknown op \(e.op)")
    }
}

@Suite("index: the postings algebra")
struct PostingsTests {

    @Test("every committed case matches Go")
    func matchesGo() throws {
        try Fixtures.check("index/postings.jsonl", FixtureCase<PostingsIn, PostingsOut>.self) {
            input in
            let p = build(input.expr)
            var out = PostingsOut(
                steps: [], err: "", expanded: [], expandOK: false,
                isEmptySentinel: isEmptyPostingsType(p))
            for op in input.ops {
                let ok = op.op == "next" ? p.next() : p.seek(SeriesRef(rawValue: op.v))
                out.steps.append(PostingsStep(ok: ok, at: ok ? p.at().rawValue : 0))
            }
            if let e = p.err() {
                out.err = String(describing: e)
            }
            // A fresh build, drained, so `expandPostings` is pinned independently of the script.
            let p2 = build(input.expr)
            if let refs = try? expandPostings(p2) {
                out.expandOK = true
                out.expanded = refs.map(\.rawValue)
            }
            return out
        }
    }
}
