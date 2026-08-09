//===----------------------------------------------------------------------===//
// Differential tests for the series-description language: ParseSeriesDesc,
// ParseMetric and ParseMetricSelector.
//
// This is where the histogram lexer states finally get covered. lexValueSequence,
// lexHistogram, lexHistogramDescriptor and lexBuckets are unreachable from Go's
// exported `Lex()`, which cannot set the unexported seriesDesc flag — so the
// promql/lex suite could not touch them, and ParseSeriesDesc is the only way in.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromHistogram
import PromLabels
import Testing

@testable import PromQLParser

struct SeriesValueJSON: Codable, Equatable, Sendable {
    let value: String
    let omitted: Bool
    let hist: FloatHistJSON?
    let hintSet: Bool
    let str: String
}

struct SeriesDescOut: Decodable, Equatable, Sendable {
    let errors: [ParseErrJSON]?
    let other: String
    let ok: Bool
    let labels: [String]?
    let values: [SeriesValueJSON]?
}

struct LineIn: Decodable, Sendable {
    let line: String
}

struct MetricIn: Decodable, Sendable {
    let input: String
}

struct MetricOut: Decodable, Equatable, Sendable {
    let errors: [ParseErrJSON]?
    let other: String
    let ok: Bool
    let labels: [String]?
}

struct SelectorOut: Decodable, Equatable, Sendable {
    let errors: [ParseErrJSON]?
    let other: String
    let ok: Bool
    let matchers: [String]?
}

/// Go: `flattenLabels` — name/value pairs, each hex-encoded, because a label can
/// carry bytes a String cannot (ADR-9).
func flattenLabels(_ l: Labels) -> [String] {
    var out = [String]()
    for label in l {
        out.append(Hex.encode(Array(label.name.utf8)))
        out.append(Hex.encode(Array(label.value.utf8)))
    }
    return out
}

func toParseErrJSON(_ e: ParseErrors) -> [ParseErrJSON] {
    e.errors.map {
        ParseErrJSON(
            start: $0.positionRange.start, end: $0.positionRange.end,
            msg: $0.message, rendered: $0.description)
    }
}

@Suite("PromQL series descriptions match Go")
struct SeriesDescTests {

    /// The oracle generates this suite under the all-features option set.
    static let parser = Parser(options: Options.named("all"))

    @Test("every committed series description")
    func seriesDescriptions() throws {
        try Fixtures.check("promql/seriesdesc.jsonl", FixtureCase<LineIn, SeriesDescOut>.self) {
            input in
            let line = String(decoding: Hex.decode(input.line), as: UTF8.self)
            do {
                let (labels, values) = try Self.parser.parseSeriesDesc(line)
                return SeriesDescOut(
                    errors: nil, other: "", ok: true,
                    labels: flattenLabels(labels),
                    values: values.map { v in
                        SeriesValueJSON(
                            value: hexBits(v.value),
                            omitted: v.omitted,
                            hist: v.histogram.map(FloatHistJSON.init),
                            hintSet: v.counterResetHintSet,
                            str: v.description)
                    })
            } catch let e as ParseErrors {
                return SeriesDescOut(
                    errors: toParseErrJSON(e), other: "", ok: false, labels: nil, values: nil)
            } catch {
                return SeriesDescOut(
                    errors: nil, other: String(describing: error), ok: false,
                    labels: nil, values: nil)
            }
        }
    }

    @Test("every committed metric")
    func metrics() throws {
        let parser = Parser()
        try Fixtures.check("promql/metric.jsonl", FixtureCase<MetricIn, MetricOut>.self) { input in
            let text = String(decoding: Hex.decode(input.input), as: UTF8.self)
            do {
                let labels = try parser.parseMetric(text)
                return MetricOut(
                    errors: nil, other: "", ok: true, labels: flattenLabels(labels))
            } catch let e as ParseErrors {
                return MetricOut(errors: toParseErrJSON(e), other: "", ok: false, labels: nil)
            } catch {
                return MetricOut(
                    errors: nil, other: String(describing: error), ok: false, labels: nil)
            }
        }
    }

    @Test("every committed metric selector")
    func metricSelectors() throws {
        let parser = Parser()
        try Fixtures.check(
            "promql/metricselector.jsonl", FixtureCase<MetricIn, SelectorOut>.self
        ) { input in
            let text = String(decoding: Hex.decode(input.input), as: UTF8.self)
            do {
                let matchers = try parser.parseMetricSelector(text)
                return SelectorOut(
                    errors: nil, other: "", ok: true,
                    matchers: matchers.compactMap { $0?.description })
            } catch let e as ParseErrors {
                return SelectorOut(
                    errors: toParseErrJSON(e), other: "", ok: false, matchers: nil)
            } catch {
                return SelectorOut(
                    errors: nil, other: String(describing: error), ok: false, matchers: nil)
            }
        }
    }
}
