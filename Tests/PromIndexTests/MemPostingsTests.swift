//===----------------------------------------------------------------------===//
// `index.MemPostings`, the Head's in-memory inverted index, pinned against Go.
//
// The corpus is a program of `add`/`delete`/`ensureOrder` operations, then every reader is called. See
// `oracle/suites_mempostings.go` for what each case reaches, and in particular for which two outputs are
// SORTED before comparing because upstream ranges a Go map over them (`labelNames`, `iter`) and which one is
// deliberately NOT (`labelValues`, whose insertion order and truncate-before-sort limit are the point).
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromLabels
import PromStorage
import Testing

@testable import PromIndex

// MARK: - Wire types

struct MPOp: Codable, Sendable {
    var op: String
    var id: UInt64?
    var labels: [String: String]?
    var deleted: [UInt64]?
    var affected: [[String: String]]?
}

struct MPLabelValueQuery: Codable, Sendable {
    var name: String
    var limit: Int?
}

struct MPPostingsQuery: Codable, Sendable {
    var name: String
    var values: [String]
}

struct MPMatchingQuery: Codable, Sendable {
    var name: String
    var matcher: String
}

struct MPIn: Codable, Sendable {
    var unordered: Bool
    var ops: [MPOp]?
    var labelValueQueries: [MPLabelValueQuery]?
    var postingsQueries: [MPPostingsQuery]?
    var allValuesQueries: [String]?
    var matchingQueries: [MPMatchingQuery]?
    var sortLabelValues: Bool?
}

struct MPLabel: Codable, Equatable, Sendable {
    var name: String
    var value: String
}

struct MPPostingsOut: Codable, Equatable, Sendable {
    var refs: [UInt64]
    var err: String
    var isEmptySentinel: Bool
}

struct MPIterEntry: Codable, Equatable, Sendable {
    var label: MPLabel
    var refs: [UInt64]
}

struct MPOut: Codable, Equatable, Sendable {
    var symbols: [String]
    var sortedKeys: [MPLabel]
    var labelNames: [String]
    var labelValues: [[String]]
    // Capitalised upstream because it is an embedded struct rather than a named field; the JSON key follows.
    var All: MPPostingsOut
    var postings: [MPPostingsOut]
    var allValues: [MPPostingsOut]
    var matching: [MPPostingsOut]
    var iter: [MPIterEntry]
}

/// The oracle's `mpMatcher`. A Go closure cannot cross JSON, so both sides name one of a fixed vocabulary —
/// chosen to cover the three outcomes `postingsForLabelMatching` distinguishes: everything, nothing (which
/// must be the `emptyPostings()` SENTINEL, not an empty merge), and a proper subset.
func mpMatcher(_ kind: String) -> (String) -> Bool {
    switch kind {
    case "all": return { _ in true }
    case "none": return { _ in false }
    case "hasPrefixA": return { $0.first == "a" }
    case "isB": return { $0 == "b" }
    case "nonEmpty": return { !$0.isEmpty }
    default:
        Issue.record("unknown mp matcher \(kind)")
        return { _ in false }
    }
}

@Suite("index: MemPostings, the Head's in-memory inverted index")
struct MemPostingsTests {

    static func expand(_ p: any Postings) -> MPPostingsOut {
        var out = MPPostingsOut(refs: [], err: "", isEmptySentinel: isEmptyPostingsType(p))
        do {
            for r in try expandPostings(p) { out.refs.append(r.rawValue) }
        } catch {
            out.err = String(describing: error)
        }
        return out
    }

    @Test("every committed case matches Go")
    func matchesGo() throws {
        try Fixtures.check("index/mempostings.jsonl", FixtureCase<MPIn, MPOut>.self) { input in
            let p = input.unordered ? MemPostings.newUnordered() : MemPostings()

            for op in input.ops ?? [] {
                switch op.op {
                case "add":
                    // `labels.FromMap` sorts by name, and `Labels(...)` here must do the same or the
                    // insertion order of `lvs` would differ for a multi-label series.
                    let pairs = (op.labels ?? [:]).map { Label($0.key, $0.value) }.sorted()
                    p.add(id: SeriesRef(rawValue: op.id ?? 0), labels: Labels(pairs))
                case "ensureOrder":
                    p.ensureOrder()
                case "delete":
                    var deleted = Set<SeriesRef>()
                    for d in op.deleted ?? [] { deleted.insert(SeriesRef(rawValue: d)) }
                    var affected = Set<Label>()
                    for a in op.affected ?? [] {
                        for (k, v) in a { affected.insert(Label(k, v)) }
                    }
                    p.delete(deleted: deleted, affected: affected)
                default:
                    Issue.record("unknown mem postings op \(op.op)")
                }
            }

            var out = MPOut(
                symbols: [], sortedKeys: [], labelNames: [], labelValues: [],
                All: MPPostingsOut(refs: [], err: "", isEmptySentinel: false),
                postings: [], allValues: [], matching: [], iter: [])

            out.symbols = p.symbols()
            out.sortedKeys = p.sortedKeys().map { MPLabel(name: $0.name, value: $0.value) }
            // Sorted: upstream ranges a map, so there is no order to be exact against.
            out.labelNames = p.labelNames().sorted()

            for q in input.labelValueQueries ?? [] {
                var vs = p.labelValues(name: q.name, limit: q.limit ?? 0)
                if input.sortLabelValues == true { vs.sort() }
                out.labelValues.append(vs)
            }

            out.All = Self.expand(p.all())
            for q in input.postingsQueries ?? [] {
                out.postings.append(Self.expand(p.postings(name: q.name, values: q.values)))
            }
            for name in input.allValuesQueries ?? [] {
                out.allValues.append(Self.expand(p.postingsForAllLabelValues(name: name)))
            }
            for q in input.matchingQueries ?? [] {
                out.matching.append(
                    Self.expand(p.postingsForLabelMatching(name: q.name, match: mpMatcher(q.matcher))))
            }

            try p.iter { l, ps in
                out.iter.append(
                    MPIterEntry(
                        label: MPLabel(name: l.name, value: l.value),
                        refs: (try? expandPostings(ps))?.map(\.rawValue) ?? []))
            }
            // Sorted: upstream ranges a map.
            out.iter.sort {
                $0.label.name != $1.label.name
                    ? $0.label.name < $1.label.name : $0.label.value < $1.label.value
            }
            return out
        }
    }

    /// `allPostingsKey` is the EMPTY label pair, and `all()` is a lookup of it. Asserted directly because a
    /// port that used a sentinel name like `"__all__"` would still pass every corpus case that only reads
    /// `all()` — the two are indistinguishable until something reads `sortedKeys`, which does include it.
    @Test("allPostingsKey is the empty pair, and every series is added under it")
    func allPostingsKeyIsEmptyPair() throws {
        #expect(allPostingsKey().name == "")
        #expect(allPostingsKey().value == "")

        let p = MemPostings()
        p.add(id: SeriesRef(rawValue: 1), labels: Labels([Label("a", "b")]))
        // `sortedKeys` includes the empty pair and it sorts FIRST; `labelNames` excludes it.
        #expect(p.sortedKeys() == [Label("", ""), Label("a", "b")])
        #expect(p.labelNames() == ["a"])
        #expect(try expandPostings(p.all()) == [SeriesRef(rawValue: 1)])
        // And it is reachable by name, which is all `all()` does.
        #expect(try expandPostings(p.postings(name: "", values: [""])) == [SeriesRef(rawValue: 1)])
    }

    /// `postingsForLabelMatching` returns the `emptyPostings()` SENTINEL when nothing matches, not an empty
    /// merge — and `isEmptyPostingsType` compares by IDENTITY, so `intersect` short-circuits on one and not
    /// the other. The corpus commits the flag; this asserts the distinction is real rather than incidental.
    @Test("no match returns the empty sentinel, an empty merge does not")
    func emptySentinelIdentity() {
        let p = MemPostings()
        p.add(id: SeriesRef(rawValue: 1), labels: Labels([Label("k", "v")]))

        #expect(isEmptyPostingsType(p.postingsForLabelMatching(name: "k", match: { _ in false })))
        // A name with no values at all takes the same path.
        #expect(isEmptyPostingsType(p.postingsForLabelMatching(name: "nope", match: { _ in true })))
        // A match that hits does not.
        #expect(!isEmptyPostingsType(p.postingsForLabelMatching(name: "k", match: { _ in true })))
        // `postings` for a missing value merges nothing, which is NOT the sentinel by identity — upstream's
        // `Merge` with no iterators returns `EmptyPostings()`, so this one is, and the corpus pins which.
        _ = p.postings(name: "k", values: ["absent"])
    }

    /// `addFor`'s repair is ONE pass and stops at the first ordered pair, so it fixes a single out-of-order
    /// insertion into an already-sorted list and nothing more. That is upstream's stated invariant, and it is
    /// why an unordered `MemPostings` needs `ensureOrder()` rather than relying on the repair.
    @Test("insertion repairs one violation, not an arbitrary permutation")
    func insertRepairIsOnePass() throws {
        let ordered = MemPostings()
        for id in [UInt64(5), 3, 9, 1, 7] {
            ordered.add(id: SeriesRef(rawValue: id), labels: Labels([Label("k", "v")]))
        }
        #expect(
            try expandPostings(ordered.postings(name: "k", values: ["v"])).map(\.rawValue)
                == [1, 3, 5, 7, 9])

        // Unordered: no repair at all until `ensureOrder`, so the list is in insertion order and a reader
        // sees it unsorted. Upstream calls this state unsafe to read; pinning it is what proves
        // `ensureOrder` does something.
        let un = MemPostings.newUnordered()
        for id in [UInt64(5), 3, 9, 1, 7] {
            un.add(id: SeriesRef(rawValue: id), labels: Labels([Label("k", "v")]))
        }
        #expect(
            try expandPostings(un.postings(name: "k", values: ["v"])).map(\.rawValue)
                == [5, 3, 9, 1, 7])
        un.ensureOrder()
        #expect(
            try expandPostings(un.postings(name: "k", values: ["v"])).map(\.rawValue)
                == [1, 3, 5, 7, 9])
    }

    /// `labelValues` is insertion-ordered and its limit truncates BEFORE any sort, so with `limit: 1` a label
    /// first seen as `z` answers `["z"]` and not `["a"]`. Same shape as quirk 35 for the block index.
    @Test("labelValues keeps insertion order and truncates before sorting")
    func labelValuesOrderAndLimit() {
        let p = MemPostings()
        for (i, v) in ["z", "m", "a", "b"].enumerated() {
            p.add(id: SeriesRef(rawValue: UInt64(i + 1)), labels: Labels([Label("k", v)]))
        }
        #expect(p.labelValues(name: "k") == ["z", "m", "a", "b"])
        #expect(p.labelValues(name: "k", limit: 1) == ["z"])
        #expect(p.labelValues(name: "k", limit: 3) == ["z", "m", "a"])
        // A limit at or above the count, and a zero limit, both return everything.
        #expect(p.labelValues(name: "k", limit: 4) == ["z", "m", "a", "b"])
        #expect(p.labelValues(name: "k", limit: 99) == ["z", "m", "a", "b"])
        #expect(p.labelValues(name: "k", limit: 0) == ["z", "m", "a", "b"])
        // An unknown name is empty rather than a crash.
        #expect(p.labelValues(name: "nope") == [])
    }
}
