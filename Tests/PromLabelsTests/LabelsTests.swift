//===----------------------------------------------------------------------===//
// Differential tests: Labels packed encoding, hashing, ordering and rendering
// against Go's DEFAULT (stringlabels) build. See docs/DECISIONS.md ADR-1.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromLabels

struct LabelsIn: Decodable, Equatable, Sendable {
    /// Names and values are hex-encoded — JSON strings cannot carry the bytes
    /// faithfully (Go's encoding/json rewrites invalid UTF-8 to U+FFFD). See ADR-9.
    let labels: [[String]]

    var value: Labels {
        // Fixture pairs arrive in Go's sorted order; go through the sorting
        // initialiser anyway so it is exercised too.
        Labels(
            labels.map {
                Label(
                    String(decoding: Hex.decode($0[0]), as: UTF8.self),
                    String(decoding: Hex.decode($0[1]), as: UTF8.self))
            })
    }
}

struct LabelsOut: Decodable, Equatable, Sendable {
    let hash: String
    let encoded: String
    let string: String
    let noSpace: String
    let impl: String
}

struct CompareIn: Decodable, Sendable {
    let a: LabelsIn
    let b: LabelsIn
}

struct HashNamesIn: Decodable, Sendable {
    let labels: LabelsIn
    let names: [String]
}

struct HashNamesOut: Decodable, Equatable, Sendable {
    let `for`: String
    let without: String
}

@Suite("Labels matches Go stringlabels")
struct LabelsTests {

    @Test("packed encoding, hash and rendering for every fixture case")
    func fixtures() throws {
        try Fixtures.check("labels/labels.jsonl", FixtureCase<LabelsIn, LabelsOut>.self) { input in
            let l = input.value
            return LabelsOut(
                hash: String(format: "%016lx", l.goHash()),
                encoded: Hex.encode(l.goEncodedBytes()),
                string: l.description,
                noSpace: l.descriptionNoSpace,
                impl: "stringlabels")
        }
    }

    @Test("fixtures were generated under the stringlabels build")
    func fixtureBuildTag() throws {
        // A fixture regenerated under -tags slicelabels would have a different
        // Hash() for the same labels; fail loudly rather than subtly.
        let cases = try Fixtures.load("labels/labels.jsonl", FixtureCase<LabelsIn, LabelsOut>.self)
        #expect(!cases.isEmpty)
        for c in cases {
            #expect(c.out.impl == "stringlabels", "\(c.id)")
        }
    }

    @Test("Compare sign matches Go for every fixture pair")
    func compare() throws {
        try Fixtures.check("labels/compare.jsonl", FixtureCase<CompareIn, Int>.self) { input in
            let c = Labels.compare(input.a.value, input.b.value)
            return c < 0 ? -1 : (c > 0 ? 1 : 0)
        }
    }

    @Test("HashForLabels / HashWithoutLabels match Go")
    func hashNames() throws {
        try Fixtures.check("labels/hashnames.jsonl", FixtureCase<HashNamesIn, HashNamesOut>.self) {
            input in
            let l = input.labels.value
            return HashNamesOut(
                for: String(format: "%016lx", l.goHash(forNames: input.names)),
                without: String(format: "%016lx", l.goHash(withoutNames: input.names)))
        }
    }

    @Test("the 0xFF length escape triggers at 255 bytes")
    func lengthEscape() {
        // encodeSize: one byte for 0...254, else 0xFF plus three bytes LE.
        let short = Labels([Label("a", String(repeating: "x", count: 254))])
        let long = Labels([Label("a", String(repeating: "x", count: 255))])
        // name: 1 + 1 ; value: 1 + 254  == 257
        #expect(short.goEncodedSize() == 257)
        // name: 1 + 1 ; value: 4 + 255  == 261
        #expect(long.goEncodedSize() == 261)
        #expect(long.goEncodedBytes()[2] == 0xFF)
    }

    @Test("packed encoding round-trips")
    func roundTrip() {
        let l = Labels(strings: "__name__", "up", "job", "node", "zzz", "")
        let decoded = Labels.fromGoEncodedBytes(l.goEncodedBytes())
        #expect(decoded == l)
    }

    @Test("ordering is by UTF-8 bytes, not Unicode collation")
    func byteOrdering() {
        // Go compares strings byte-wise. Swift's String '<' uses canonical
        // ordering, which differs — hence the UTF8ByteOrder wrapper.
        let a = Labels([Label("b", "1")])
        let aa = Labels([Label("aa", "1")])
        #expect(Labels.compare(aa, a) < 0)
    }

    @Test("names failing legacy validation get quoted in description")
    func quotedNames() {
        #expect(Labels([Label("with.dot", "v")]).description == #"{"with.dot"="v"}"#)
        #expect(Labels([Label("ok_name", "v")]).description == #"{ok_name="v"}"#)
    }

    @Test("Get returns empty string for absent labels, matching Go")
    func getSemantics() {
        let l = Labels(strings: "job", "node")
        #expect(l["job"] == "node")
        #expect(l["nope"] == "")
        #expect(l.value(for: "nope") == nil)
        #expect(!l.has("nope"))
    }
}
