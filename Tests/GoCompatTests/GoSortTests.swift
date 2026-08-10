//===----------------------------------------------------------------------===//
// Differential tests for `GoSort` — Go's pdqsort — and for `GoNatsort.compare`.
//
// Both corpora exist because `promql`'s four sorts have comparators that are not strict
// weak orderings, so the *algorithm's* permutation is the observable. See
// oracle/suites_gosort.go and oracle/suites_gonatsort.go.
//
// The sort fixture also carries the Less and Swap CALL COUNTS. They are not an output
// anyone can observe through PromQL, and they are pinned deliberately: a port that
// reached the right permutation by another route — a library sort for short ranges, say,
// or a `median` that stops early — matches the permutation and fails the counts.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

struct PdqIn: Decodable, Sendable {
    /// float64 bit patterns as decimal strings.
    var keys: [String]
    var cmp: String
    var reverse: Bool
}

struct PdqOut: Decodable, Equatable, Sendable {
    var perm: [Int]
    var lessCalls: Int
    var swapCalls: Int
}

struct NatsortIn: Decodable, Sendable {
    /// Hex, because a label value is an arbitrary byte string.
    var a: String
    var b: String
}

struct NatsortOut: Decodable, Equatable, Sendable {
    var ab: Bool
    var ba: Bool
}

@Suite("Go's pdqsort, which sort/sort_desc's output order is defined by")
struct GoSortTests {

    /// The five comparators the fixture names, over `(key, id)` pairs.
    static func comparator(_ name: String) -> (Double, Double) -> Bool {
        switch name {
        case "lt":
            return { a, b in a < b }
        case "nanLt":
            // promql's vectorByValueHeap.Less.
            return { a, b in
                if a.isNaN { return true }
                return a < b
            }
        case "nanGt":
            // promql's vectorByReverseValueHeap.Less.
            return { a, b in
                if a.isNaN { return true }
                return a > b
            }
        case "allEqual":
            return { _, _ in false }
        case "allLess":
            return { _, _ in true }
        default:
            fatalError("unknown comparator \(name)")
        }
    }

    @Test("every committed permutation, and both call counts")
    func pdqsortMatchesGo() throws {
        try Fixtures.check("gocompat/sort.jsonl", FixtureCase<PdqIn, PdqOut>.self) { input in
            var keys = input.keys.map { Double(bitPattern: UInt64($0)!) }
            var ids = Array(0..<keys.count)
            let cmp = Self.comparator(input.cmp)

            var lessCalls = 0
            var swapCalls = 0
            let less: (Int, Int) -> Bool = { i, j in
                lessCalls += 1
                return cmp(keys[i], keys[j])
            }
            let swap: (Int, Int) -> Void = { i, j in
                swapCalls += 1
                keys.swapAt(i, j)
                ids.swapAt(i, j)
            }

            if input.reverse {
                GoSort.sortReverse(count: keys.count, less: less, swap: swap)
            } else {
                GoSort.sort(count: keys.count, less: less, swap: swap)
            }
            return PdqOut(perm: ids, lessCalls: lessCalls, swapCalls: swapCalls)
        }
    }
}

@Suite("natsort.Compare, which is not an ordering")
struct GoNatsortTests {

    static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.utf8.count / 2)
        var it = Array(hex.utf8)
        for i in stride(from: 0, to: it.count, by: 2) {
            let hi = Self.nibble(it[i])
            let lo = Self.nibble(it[i + 1])
            out.append(hi << 4 | lo)
        }
        it = []
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: fatalError("not hex: \(c)")
        }
    }

    @Test("every committed pair, in both directions")
    func compareMatchesGo() throws {
        try Fixtures.check("gocompat/natsort.jsonl", FixtureCase<NatsortIn, NatsortOut>.self) {
            input in
            let a = Self.bytes(fromHex: input.a)
            let b = Self.bytes(fromHex: input.b)
            return NatsortOut(
                ab: GoNatsort.compare(a, b),
                ba: GoNatsort.compare(b, a))
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("sorting invariants")
struct GoSortInvariantTests {

    @Test("natsort.Compare is neither irreflexive nor asymmetric")
    func natsortIsNotAnOrdering() {
        // Both are why the pdqsort port exists. A comparator obeying either law would
        // let any correct sort produce the same answer.
        #expect(GoNatsort.compare("a", "a"))
        #expect(GoNatsort.compare("a1", "a01"))
        #expect(GoNatsort.compare("a01", "a1"))
        // The empty string chunks to nothing, so the loop never runs and the answer is
        // false — the one input for which Compare(x, x) is false.
        #expect(!GoNatsort.compare("", ""))
    }

    @Test("Atoi's range is load-bearing: the longer number can sort first")
    func atoiOverflowFallsBackToStrings() {
        // 9999999999999999999 fits in an int64; 10000000000000000000 does not, so Go's
        // Atoi fails for the second and BOTH chunks are compared as strings — where "1"
        // precedes "9".
        #expect(GoNatsort.compare("10000000000000000000", "9999999999999999999"))
        // One digit shorter on both sides, and the numeric comparison takes over.
        #expect(GoNatsort.compare("999999999999999999", "1000000000000000000"))
    }

    @Test("a NaN comparator makes sort.Sort's output algorithm-defined, not order-defined")
    func nanComparatorIsInconsistent() {
        let less = GoSortTests.comparator("nanLt")
        let nan = Double.nan
        // Both directions true, which no strict weak ordering permits.
        #expect(less(nan, nan))
        #expect(less(nan, 1))
        #expect(!less(1, nan))
    }

    @Test("bitsLen and nextPowerOfTwo match Go's, including at zero")
    func bitsLen() {
        #expect(GoSort.bitsLen(0) == 0)
        #expect(GoSort.bitsLen(1) == 1)
        #expect(GoSort.bitsLen(255) == 8)
        #expect(GoSort.bitsLen(256) == 9)
    }
}
