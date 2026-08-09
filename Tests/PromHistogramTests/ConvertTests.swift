//===----------------------------------------------------------------------===//
// Differential tests for model/histogram/convert.go — ConvertNHCBToClassic.
//
// The probe records every emitted series in order, rendered through
// Labels.description, so both the label sets and the cumulative bucket values are
// pinned. The integer and float branches walk spans differently — the integer one
// fills the gaps between spans while the float one skips them — so both are
// exercised over the same layouts.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromLabels
import PromModel
import Testing

@testable import PromHistogram

@Suite("ConvertNHCBToClassic matches Go")
struct ConvertTests {

    struct SeriesJSON: Codable, Equatable, Sendable {
        let labels: String
        let value: String
    }

    @Test("every committed conversion, series by series")
    func convert() throws {
        struct In: Decodable, Sendable {
            /// Exactly one of these is set, mirroring Go's `nhcb any` parameter.
            let int: HistJSON?
            let float: FloatHistJSON?
            let lset: String
        }
        struct Out: Decodable, Equatable, Sendable {
            let series: [SeriesJSON]
            let err: String
        }
        try Fixtures.check("histogram/nhcb-classic.jsonl", FixtureCase<In, Out>.self) { input in
            let nhcb: NativeHistogramWithCustomBuckets =
                if let h = input.int { .integer(h.histogram) } else { .float(input.float!.histogram) }

            var emitted = [SeriesJSON]()
            var builder = LabelsBuilder(Labels([Label("pre", "existing")]))
            let err = errString {
                try convertNHCBToClassic(
                    nhcb, lset: Self.parseLabels(input.lset), builder: &builder
                ) { labels, value in
                    emitted.append(SeriesJSON(labels: labels.description, value: hexBits(value)))
                }
            }
            return Out(series: emitted, err: err)
        }
    }

    /// Rebuilds the label set from the rendering the oracle recorded. Only the
    /// shapes this corpus uses need to parse.
    static func parseLabels(_ s: String) -> Labels {
        var pairs = [Label]()
        var body = s
        body.removeFirst()  // {
        body.removeLast()  // }
        if body.isEmpty { return Labels([]) }
        for part in body.components(separatedBy: ", ") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var name = String(part[part.startIndex..<eq])
            if name.hasPrefix("\"") { name = String(name.dropFirst().dropLast()) }
            let quoted = String(part[part.index(after: eq)...])
            let value = String(quoted.dropFirst().dropLast())
            pairs.append(Label(name, value))
        }
        return Labels(pairs)
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("ConvertNHCBToClassic invariants")
struct ConvertInvariantTests {

    static let nhcb = Histogram(
        schema: HistogramSchema.customBuckets,
        count: 6,
        sum: 19.4,
        positiveSpans: [Span(offset: 0, length: 3)],
        positiveBuckets: [1, 1, 1],
        customValues: [1, 2, 5])

    static func emit(
        _ nhcb: NativeHistogramWithCustomBuckets, _ lset: Labels
    ) throws -> [(Labels, Double)] {
        var out = [(Labels, Double)]()
        var builder = LabelsBuilder(Labels([]))
        try convertNHCBToClassic(nhcb, lset: lset, builder: &builder) { out.append(($0, $1)) }
        return out
    }

    @Test("buckets come out cumulative, with a final +Inf, then count and sum")
    func cumulativeSeries() throws {
        let series = try Self.emit(
            .integer(Self.nhcb), Labels([Label("__name__", "rq")]))
        // Three bounds plus the implicit +Inf, then _count and _sum.
        #expect(series.count == 6)
        // Deltas 1,1,1 accumulate to 1,2,3, then cumulative 1,3,6.
        #expect(series.map(\.1) == [1, 3, 6, 6, 6, 19.4])
        #expect(series[0].0[LabelName.bucket] == "1.0")
        #expect(series[2].0[LabelName.bucket] == "5.0")
        #expect(series[3].0[LabelName.bucket] == "+Inf")
        #expect(series[4].0[LabelName.metricName] == "rq_count")
        #expect(series[5].0[LabelName.metricName] == "rq_sum")
    }

    @Test("a missing metric name is rejected")
    func missingName() {
        #expect(
            errString { _ = try Self.emit(.integer(Self.nhcb), Labels([Label("job", "api")])) }
                == "metric name label '__name__' is missing")
    }

    @Test("an exponential histogram is rejected")
    func notAnNHCB() {
        let exponential = Histogram(
            schema: 0,
            count: 2,
            positiveSpans: [Span(offset: 0, length: 1)],
            positiveBuckets: [2])
        #expect(
            errString {
                _ = try Self.emit(.integer(exponential), Labels([Label("__name__", "rq")]))
            } == "unsupported histogram schema, not a NHCB")
        #expect(
            errString {
                _ = try Self.emit(
                    .float(exponential.toFloat()), Labels([Label("__name__", "rq")]))
            } == "unsupported histogram schema, not a NHCB")
    }

    @Test("the caller's builder is restored")
    func builderRestored() throws {
        // Upstream's queue manager relies on this: the builder is reused for each
        // emitted series, then put back the way it was found.
        let original = Labels([Label("pre", "existing")])
        var builder = LabelsBuilder(original)
        try convertNHCBToClassic(
            .integer(Self.nhcb), lset: Labels([Label("__name__", "rq")]), builder: &builder
        ) { _, _ in }
        #expect(builder.labels() == original)
    }

    @Test("an error from the emit callback stops the conversion")
    func emitErrorPropagates() {
        struct Stop: Error {}
        var builder = LabelsBuilder(Labels([]))
        var seen = 0
        #expect(throws: Stop.self) {
            try convertNHCBToClassic(
                .integer(Self.nhcb), lset: Labels([Label("__name__", "rq")]), builder: &builder
            ) { _, _ in
                seen += 1
                if seen == 2 { throw Stop() }
            }
        }
        #expect(seen == 2)
    }

    @Test("the integer branch fills span gaps, the float branch skips them")
    func spanGapHandling() throws {
        // Same layout, both representations: a leading offset and a gap. The
        // integer branch writes the running delta total into the gap buckets, the
        // float branch leaves them at zero — so the cumulative series differ.
        let integer = Histogram(
            schema: HistogramSchema.customBuckets,
            count: 5,
            sum: 10,
            positiveSpans: [Span(offset: 1, length: 2), Span(offset: 1, length: 1)],
            positiveBuckets: [2, 0, -1],
            customValues: [0.5, 1, 2.5, 10])
        let float = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 5,
            sum: 10,
            positiveSpans: [Span(offset: 1, length: 2), Span(offset: 1, length: 1)],
            positiveBuckets: [2, 2, 1],
            customValues: [0.5, 1, 2.5, 10])
        let lset = Labels([Label("__name__", "rq")])
        let intSeries = try Self.emit(.integer(integer), lset).map(\.1)
        let floatSeries = try Self.emit(.float(float), lset).map(\.1)
        #expect(intSeries != floatSeries)
        // The float branch's first bucket stays empty because the offset is skipped.
        #expect(floatSeries[0] == 0)
    }
}
