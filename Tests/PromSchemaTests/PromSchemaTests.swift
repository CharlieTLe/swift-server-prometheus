//===----------------------------------------------------------------------===//
// Differential tests for PromSchema against schema/labels.go.
//
// Mirrors oracle/suites_schema.go. Two fixtures because the in/out shapes differ.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromLabels
import PromModel
import Testing

@testable import PromSchema

// MARK: - Wire

struct SchemaMetadataIn: Decodable, Sendable {
    /// "literal" or "fromLabels".
    let mode: String
    let name: String
    let type: String
    let unit: String
    /// Flattened name/value pairs for "fromLabels".
    let from: [String]?
    /// Flattened name/value pairs seeding `setToLabels`' builder.
    let base: [String]?
    /// The names `isEmpty(for:)` is probed with.
    let probe: [String]
}

struct SchemaMetadataOut: Decodable, Equatable, Sendable {
    let name: String
    let type: String
    let unit: String
    let typeEmpty: Bool
    let emptyFor: [Bool]
    /// `addToLabels` into a fresh builder, rendered WITHOUT sorting.
    let add: String
    let set: String
}

/// Go: `labels.FromStrings`, over the flattened pairs the fixture carries.
private func labelsFromFlat(_ flat: [String]?) -> Labels {
    guard let flat, !flat.isEmpty else { return .empty }
    return Labels(strings: flat)
}

private func runSchemaMetadata(_ input: SchemaMetadataIn) -> SchemaMetadataOut {
    let m: Metadata
    switch input.mode {
    case "literal":
        m = Metadata(name: input.name, type: input.type, unit: input.unit)
    case "fromLabels":
        m = Metadata(labels: labelsFromFlat(input.from))
    default:
        preconditionFailure("unknown mode \(input.mode)")
    }

    var sb = ScratchBuilder()
    m.addToLabels(&sb)

    var b = LabelsBuilder(labelsFromFlat(input.base))
    m.setToLabels(&b)

    return SchemaMetadataOut(
        name: m.name,
        type: m.type,
        unit: m.unit,
        typeEmpty: m.isTypeEmpty,
        emptyFor: input.probe.map { m.isEmpty(for: $0) },
        add: sb.labels().description,
        set: b.labels().description
    )
}

// MARK: - Tests

@Suite("prometheus/schema")
struct PromSchemaTests {

    @Test("IsMetadataLabel matches Go on every committed case")
    func isMetadataLabelMatches() throws {
        try Fixtures.check("schema/metadatalabel.jsonl", FixtureCase<String, Bool>.self) { name in
            isMetadataLabel(name)
        }
    }

    @Test("Metadata matches Go on every committed case")
    func metadataMatches() throws {
        try Fixtures.check(
            "schema/metadata.jsonl",
            FixtureCase<SchemaMetadataIn, SchemaMetadataOut>.self
        ) { input in
            runSchemaMetadata(input)
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("prometheus/schema invariants")
struct PromSchemaInvariantTests {

    @Test("the three metadata labels are exactly __name__, __type__ and __unit__")
    func exactlyThree() {
        #expect(isMetadataLabel("__name__"))
        #expect(isMetadataLabel("__type__"))
        #expect(isMetadataLabel("__unit__"))
        // Reserved-looking neighbours that are NOT metadata labels. The engine
        // passes this predicate to `dropReserved`, whose loop stops at the first
        // name above '_' — so conflating "reserved" with "metadata" would drop
        // service-discovery labels from every function result.
        #expect(!isMetadataLabel("__address__"))
        #expect(!isMetadataLabel("__scrape_interval__"))
        #expect(!isMetadataLabel("__name"))
        #expect(!isMetadataLabel("__NAME__"))
        #expect(!isMetadataLabel(""))
        #expect(!isMetadataLabel("le"))
    }

    @Test("it is a superset of dropMetricName, which is why the engine passes it")
    func widerThanDropMetricName() {
        // `dropMetricName` drops only `__name__`. A PromQL function's result keeps
        // no type and no unit either, so `functions.go` passes `IsMetadataLabel`
        // instead — three labels, not one.
        let ls = Labels([
            Label("__name__", "foo"),
            Label("__type__", "counter"),
            Label("__unit__", "seconds"),
            Label("job", "j"),
        ])
        #expect(ls.dropMetricName().description == #"{__type__="counter", __unit__="seconds", job="j"}"#)
        #expect(ls.dropReserved(isMetadataLabel).description == #"{job="j"}"#)
    }

    @Test("empty and \"unknown\" types are indistinguishable to every reader")
    func emptyTypeEqualsUnknown() {
        // The whole reason `SetToLabels`' `if Type == MetricTypeUnknown` branch can
        // be collapsed in the port: both arms set the label to "". Asserted across
        // all four readers rather than just the one.
        let empty = Metadata(name: "foo", type: "", unit: "s")
        let unknown = Metadata(name: "foo", type: "unknown", unit: "s")

        #expect(empty.isTypeEmpty)
        #expect(unknown.isTypeEmpty)
        #expect(empty.isEmpty(for: "__type__") == unknown.isEmpty(for: "__type__"))

        var a = ScratchBuilder()
        var b = ScratchBuilder()
        empty.addToLabels(&a)
        unknown.addToLabels(&b)
        #expect(a.labels().description == b.labels().description)

        let base = Labels([Label("__type__", "summary")])
        var c = LabelsBuilder(base)
        var d = LabelsBuilder(base)
        empty.setToLabels(&c)
        unknown.setToLabels(&d)
        #expect(c.labels().description == d.labels().description)
        #expect(c.labels()["__type__"].isEmpty, "an empty field REMOVES the label")
    }

    @Test("a literal Metadata and one read back from labels differ in Type")
    func literalVersusFromLabels() {
        // Not a slip in either direction: `NewMetadataFromLabels` substitutes the
        // string "unknown" for a missing `__type__`, while `Metadata{}` leaves "".
        // Different values, identical behaviour — which is what the fixture pins.
        #expect(Metadata().type == "")
        #expect(Metadata(labels: .empty).type == "unknown")
        #expect(Metadata().isTypeEmpty)
        #expect(Metadata(labels: .empty).isTypeEmpty)
    }

    @Test("Type carries arbitrary strings, so it is not the MetricType enum")
    func typeIsNotAnEnum() {
        // Reachable: a scraped series can carry any `__type__` value, and
        // `NewMetadataFromLabels` copies it verbatim. An enum-typed field would
        // drop it, so `Metadata.type` is a String — the same forcing PORTING.md
        // exception 8 records for `HistogramOperation`.
        let m = Metadata(labels: Labels([Label("__type__", "nonsense")]))
        #expect(m.type == "nonsense")
        #expect(!m.isTypeEmpty, "an unrecognised type is not empty")
        #expect(MetricType(rawValue: m.type) == nil, "and the enum genuinely cannot hold it")
        var sb = ScratchBuilder()
        m.addToLabels(&sb)
        #expect(sb.labels()["__type__"] == "nonsense", "it is written back out")
    }

    @Test("addToLabels skips empty fields, setToLabels removes them")
    func addVersusSet() {
        // The one behavioural difference between the two writers, and it is easy to
        // get backwards.
        let m = Metadata(name: "", type: "counter", unit: "")
        var sb = ScratchBuilder()
        m.addToLabels(&sb)
        #expect(sb.labels().description == #"{__type__="counter"}"#, "name and unit skipped")

        let base = Labels([
            Label("__name__", "old"),
            Label("__unit__", "bytes"),
        ])
        var b = LabelsBuilder(base)
        m.setToLabels(&b)
        #expect(b.labels().description == #"{__type__="counter"}"#, "name and unit removed")
    }

    @Test("addToLabels appends name, then type, then unit")
    func addOrder() {
        // The fixture renders the builder unsorted for this reason: a caller
        // building a series from scratch relies on the order, and sorting before
        // comparing would have thrown the only evidence away.
        let m = Metadata(name: "foo", type: "counter", unit: "seconds")
        var sb = ScratchBuilder()
        m.addToLabels(&sb)
        #expect(Array(sb.labels()).map(\.name) == ["__name__", "__type__", "__unit__"])
    }
}
