//===----------------------------------------------------------------------===//
// Differential tests: Builder/ScratchBuilder, Matcher, StableHash and
// FormatOpenMetricsFloat against Go.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromLabels
@testable import PromModel

struct BuilderOp: Decodable, Sendable {
    let op: String
    let args: [String]
    var decodedArgs: [String] { args.map { String(decoding: Hex.decode($0), as: UTF8.self) } }
}

struct BuilderIn: Decodable, Sendable {
    let base: LabelsIn
    let ops: [BuilderOp]
}

struct BuilderOut: Decodable, Equatable, Sendable {
    let labels: LabelsIn
    let rangeOrder: LabelsIn
    let gets: [String]
}

/// Mirrors the oracle's `corpusNames`, which `Get()` is probed against.
private let corpusNames = [
    "__name__", "job", "instance", "le", "cpu", "mode", "a", "aa", "b", "zzz",
    "with.dot", "quantile", "namespace", "pod",
]

/// Mirrors the oracle's `matcherProbes`.
private let matcherProbes = ["", "a", "b", "ab", "up", "node", "x|y", "A", "0"]

// LabelsIn is not Equatable upstream in this target, so compare via hex pairs.
private func hexPairs(_ l: Labels) -> [[String]] {
    l.map { [Hex.encode(Array($0.name.utf8)), Hex.encode(Array($0.value.utf8))] }
}

/// Reads the `bits` field of the oracle's float envelope; JSONDecoder ignores
/// the rest.
struct FloatBitsIn: Decodable, Sendable {
    let bits: String
    var value: Double { Double(bitPattern: UInt64(bits, radix: 16)!) }
}

struct MatcherIn: Decodable, Sendable {
    let type: Int
    let name: String
    let value: String
    var decodedName: String { String(decoding: Hex.decode(name), as: UTF8.self) }
    var decodedValue: String { String(decoding: Hex.decode(value), as: UTF8.self) }
}

struct MatcherOut: Decodable, Equatable, Sendable {
    let string: String
    let typeString: String
    let matches: [Bool]
    let setMatches: [String]
}

@Suite("LabelsBuilder matches Go labels.Builder")
struct LabelsBuilderTests {

    @Test("every committed fixture case: Labels(), Range() order and Get()")
    func fixtures() throws {
        try Fixtures.check("labels/builder.jsonl", FixtureCase<BuilderIn, BuilderOut>.self) {
            input in
            var b = LabelsBuilder(input.base.value)
            for op in input.ops {
                let args = op.decodedArgs
                switch op.op {
                case "del": b.del(args)
                case "keep": b.keep(args)
                case "set": b.set(args[0], args.count > 1 ? args[1] : "")
                default: fatalError("unknown builder op \(op.op)")
                }
            }

            var rangeOrder = [Label]()
            b.forEach { rangeOrder.append($0) }

            return BuilderOut(
                labels: LabelsIn(labels: hexPairs(b.labels())),
                rangeOrder: LabelsIn(labels: hexPairs(Labels(sortedUnchecked: rangeOrder))),
                gets: corpusNames.map { Hex.encode(Array(b.get($0).utf8)) })
        }
    }

    @Test("an empty value deletes, matching Go's Set semantics")
    func emptyValueDeletes() {
        var b = LabelsBuilder(Labels(strings: "a", "1", "b", "2"))
        b.set("a", "")
        #expect(b.labels() == Labels(strings: "b", "2"))
        #expect(b.get("a") == "")
    }

    @Test("Reset treats empty-valued base labels as deleted")
    func resetDropsEmpty() {
        // Go's Builder.Reset pushes base labels with "" values into `del`.
        let base = Labels(sortedUnchecked: [Label("a", ""), Label("b", "2")])
        var b = LabelsBuilder(base)
        b.set("c", "3")
        #expect(b.labels() == Labels(strings: "b", "2", "c", "3"))
    }

    @Test("unmodified builder returns the base unchanged")
    func passthrough() {
        let base = Labels(strings: "a", "1")
        let b = LabelsBuilder(base)
        #expect(b.labels() == base)
    }

    @Test("ScratchBuilder does not sort until asked")
    func scratchBuilder() {
        var sb = ScratchBuilder(capacity: 3)
        sb.add("z", "1")
        sb.add("a", "2")
        // Go's Labels() returns insertion order; Sort() is the caller's job.
        #expect(Array(sb.labels()).map(\.name) == ["z", "a"])
        sb.sort()
        #expect(Array(sb.labels()).map(\.name) == ["a", "z"])
        sb.reset()
        #expect(sb.labels().isEmpty)
    }
}

@Suite("Matcher matches Go labels.Matcher")
struct MatcherTests {

    @Test("String(), type rendering and matching for every fixture case")
    func fixtures() throws {
        try Fixtures.check("labels/matcher.jsonl", FixtureCase<MatcherIn, MatcherOut>.self) { input in
            let type = MatchType(rawValue: input.type)!
            let m = try Matcher(type, input.decodedName, input.decodedValue)
            return MatcherOut(
                string: m.description,
                typeString: type.description,
                matches: matcherProbes.map { m.matches($0) },
                setMatches: m.setMatches.map { Hex.encode(Array($0.utf8)) })
        }
    }

    @Test("names needing quotes are quoted, matching shouldQuoteName")
    func quoting() throws {
        #expect(try Matcher(.equal, "job", "x").description == #"job="x""#)
        #expect(try Matcher(.equal, "with.dot", "x").description == #""with.dot"="x""#)
        #expect(try Matcher(.equal, "", "x").description == #"""="x""#)
        #expect(try Matcher(.notEqual, "job", "x").description == #"job!="x""#)
        #expect(try Matcher(.regexp, "job", "a|b").description == #"job=~"a|b""#)
        #expect(try Matcher(.notRegexp, "job", "a|b").description == #"job!~"a|b""#)
    }

    @Test("inverse flips the match type")
    func inverse() throws {
        #expect(try Matcher(.equal, "a", "b").inverse().type == .notEqual)
        #expect(try Matcher(.regexp, "a", "b").inverse().type == .notRegexp)
    }

    @Test("real regexes now work, and matching is fully anchored")
    func realRegexes() throws {
        // Phase 2 replaced the literal-only stand-in with PromRegex, so these
        // compile instead of throwing.
        for pattern in ["a.*", "a+", "[abc]", "(a)", "a{2}", "^a$", "(?i)foo", "\\d+"] {
            #expect(throws: Never.self, "\(pattern)") { try Matcher(.regexp, "job", pattern) }
        }
        // Anchored: Go compiles ^(?s:...)$, so a substring must not match.
        let m = try Matcher(.regexp, "job", "foo")
        #expect(m.matches("foo"))
        #expect(!m.matches("foobar"))
        // Negation inverts.
        let n = try Matcher(.notRegexp, "job", "foo")
        #expect(!n.matches("foo"))
        #expect(n.matches("foobar"))
        // Malformed patterns still throw, with Go's message.
        #expect(throws: (any Error).self) { try Matcher(.regexp, "job", "a**") }
    }
}

@Suite("StableHash and OpenMetrics float formatting")
struct StableHashTests {

    @Test("StableHash matches Go for every fixture case")
    func stableHash() throws {
        try Fixtures.check("labels/stablehash.jsonl", FixtureCase<LabelsIn, String>.self) {
            String(format: "%016lx", $0.value.stableHash())
        }
    }

    @Test("StableHash is canonical where Hash is not")
    func stableVsUnstable() {
        // StableHash uses 0xFF framing in every Go label implementation; Hash()
        // depends on the build tag. They are therefore different functions.
        let l = Labels(strings: "__name__", "up", "job", "node")
        #expect(l.stableHash() != l.goHash())
    }

    @Test("FormatOpenMetricsFloat matches Go for every fixture case")
    func openMetricsFloat() throws {
        try Fixtures.check("labels/omfloat.jsonl", FixtureCase<FloatBitsIn, String>.self) {
            Labels.formatOpenMetricsFloat($0.value)
        }
    }

    @Test("integral values gain a .0 suffix")
    func omFloatSuffix() {
        #expect(Labels.formatOpenMetricsFloat(1) == "1.0")
        #expect(Labels.formatOpenMetricsFloat(0) == "0.0")
        #expect(Labels.formatOpenMetricsFloat(-1) == "-1.0")
        #expect(Labels.formatOpenMetricsFloat(2) == "2.0")
        #expect(Labels.formatOpenMetricsFloat(0.5) == "0.5")
        #expect(Labels.formatOpenMetricsFloat(1e21) == "1e+21")
        #expect(Labels.formatOpenMetricsFloat(.nan) == "NaN")
        #expect(Labels.formatOpenMetricsFloat(.infinity) == "+Inf")
        #expect(Labels.formatOpenMetricsFloat(-.infinity) == "-Inf")
    }
}

@Suite("Labels derived-set helpers")
struct LabelsHelpersTests {

    @Test("dropMetricName removes __name__ only")
    func dropMetricName() {
        let l = Labels(strings: "__name__", "up", "job", "node")
        #expect(l.dropMetricName() == Labels(strings: "job", "node"))
        // No-op when absent, and the same value is returned.
        let j = Labels(strings: "job", "node")
        #expect(j.dropMetricName() == j)
    }

    @Test("withoutEmpty drops empty values")
    func withoutEmpty() {
        let l = Labels(sortedUnchecked: [Label("a", ""), Label("b", "2"), Label("c", "")])
        #expect(l.withoutEmpty() == Labels(strings: "b", "2"))
    }

    @Test("matchLabels(on:) keeps or drops, and drops __name__ when off")
    func matchLabels() {
        let l = Labels(strings: "__name__", "up", "a", "1", "b", "2")
        #expect(l.matchLabels(on: true, ["a"]) == Labels(strings: "a", "1"))
        // on: false additionally drops __name__.
        #expect(l.matchLabels(on: false, ["a"]) == Labels(strings: "b", "2"))
    }

    @Test("isValid checks the metric name under the given scheme")
    func isValid() {
        #expect(Labels(strings: "__name__", "up", "job", "x").isValid(.legacy))
        #expect(!Labels(strings: "__name__", "up", "with.dot", "x").isValid(.legacy))
        #expect(Labels(strings: "__name__", "up", "with.dot", "x").isValid(.utf8))
        // Metric names may contain ':' even under legacy validation.
        #expect(Labels(strings: "__name__", "a:b").isValid(.legacy))
    }
}
