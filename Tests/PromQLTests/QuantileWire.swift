//===----------------------------------------------------------------------===//
// Wire types for the quantile fixtures.
//
// Mirrors oracle/suites_promql_quantile.go and oracle/corpus_promql_quantile.go.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromHistogram
import Testing

@testable import PromQL

// Suffixed to avoid colliding with the identically-shaped helpers in
// ValueWire.swift, which is in the same test target.
func hexBitsQ(_ v: Double) -> String { String(format: "%016lx", v.bitPattern) }

func doubleFromHexQ(_ s: String) -> Double {
    guard let bits = UInt64(s, radix: 16) else { return 0 }
    return Double(bitPattern: bits)
}

/// Swift's libm `exp2`, named so the test that asserts it *differs* from Go's
/// cannot be mistaken for a call to the port.
func Foundation_exp2(_ x: Double) -> Double { Foundation.exp2(x) }

struct BucketJSON: Decodable, Sendable {
    let upperBound: String
    let count: String
}

struct BucketQuantileIn: Decodable, Sendable {
    let q: String
    let buckets: [BucketJSON]?

    var swiftBuckets: Buckets {
        (buckets ?? []).map {
            Bucket(upperBound: doubleFromHexQ($0.upperBound), count: doubleFromHexQ($0.count))
        }
    }
}

struct BucketQuantileOut: Decodable, Equatable, Sendable {
    let quantile: String
    let forcedMonotonic: Bool
    let fixedPrecision: Bool
    let minBucket: String
    let maxBucket: String
    let maxDiff: String
}

struct BucketFractionIn: Decodable, Sendable {
    let lower: String
    let upper: String
    let buckets: [BucketJSON]?

    var swiftBuckets: Buckets {
        (buckets ?? []).map {
            Bucket(upperBound: doubleFromHexQ($0.upperBound), count: doubleFromHexQ($0.count))
        }
    }
}

/// The oracle shares `spanJSON` with the histogram suites, whose keys are "o"/"l".
struct SpanJSONQ: Decodable, Sendable {
    let o: Int32
    let l: UInt32
}

struct HistSpecJSON: Decodable, Sendable {
    let schema: Int32
    let counterResetHint: UInt8
    let zeroThreshold: String
    let zeroCount: String
    let count: String
    let sum: String
    let positiveSpans: [SpanJSONQ]?
    let negativeSpans: [SpanJSONQ]?
    let positiveBuckets: [String]?
    let negativeBuckets: [String]?
    let customValues: [String]?

    var swiftHistogram: FloatHistogram {
        FloatHistogram(
            counterResetHint: CounterResetHint(rawValue: counterResetHint) ?? .unknownCounterReset,
            schema: schema,
            zeroThreshold: doubleFromHexQ(zeroThreshold),
            zeroCount: doubleFromHexQ(zeroCount),
            count: doubleFromHexQ(count),
            sum: doubleFromHexQ(sum),
            positiveSpans: (positiveSpans ?? []).map { Span(offset: $0.o, length: $0.l) },
            negativeSpans: (negativeSpans ?? []).map { Span(offset: $0.o, length: $0.l) },
            positiveBuckets: (positiveBuckets ?? []).map(doubleFromHexQ),
            negativeBuckets: (negativeBuckets ?? []).map(doubleFromHexQ),
            // nil and empty are NOT interchangeable here — PORTING.md quirk 4.
            customValues: customValues.map { $0.map(doubleFromHexQ) })
    }
}

struct HistQuantileIn: Decodable, Sendable {
    let q: String
    let h: HistSpecJSON
    let metricName: String
    let start: Int
    let end: Int
}

struct HistFractionIn: Decodable, Sendable {
    let lower: String
    let upper: String
    let h: HistSpecJSON
    let metricName: String
    let start: Int
    let end: Int
}

struct HistQuantileOut: Decodable, Equatable, Sendable {
    let value: String
    let warnings: [String]
    let infos: [String]
}
