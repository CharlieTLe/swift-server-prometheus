//===----------------------------------------------------------------------===//
// The wire format shared by the histogram/integer* fixtures.
//
// Floats travel as hex bit patterns, so NaN and -0 survive the round trip and
// every comparison is bit-exact rather than mathematical (ADR-4, and see
// docs/HANDOFF.md on why `NaN != NaN` would let a real divergence through).
//===----------------------------------------------------------------------===//

import Foundation
import PromHistogram

func hexBits(_ v: Double) -> String { String(format: "%016lx", v.bitPattern) }
func doubleFromHex(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

struct SpanJSON: Codable, Equatable, Sendable {
    let o: Int32
    let l: UInt32

    init(_ span: Span) {
        o = span.offset
        l = span.length
    }

    var span: Span { Span(offset: o, length: l) }
}

/// A `Histogram` on the wire.
///
/// `cv` is Optional and the rest are not, deliberately: Go cannot tell a nil
/// span or bucket slice from an empty one, but histogram.go:456 tests
/// `CustomValues != nil`, so there `null` and `[]` mean different things.
struct HistJSON: Codable, Equatable, Sendable {
    let crh: UInt8
    let schema: Int32
    let zt: String
    let zc: UInt64
    let count: UInt64
    let sum: String
    let psp: [SpanJSON]
    let nsp: [SpanJSON]
    let pb: [Int64]
    let nb: [Int64]
    let cv: [String]?

    init(_ h: Histogram) {
        crh = h.counterResetHint.rawValue
        schema = h.schema
        zt = hexBits(h.zeroThreshold)
        zc = h.zeroCount
        count = h.count
        sum = hexBits(h.sum)
        psp = h.positiveSpans.map(SpanJSON.init)
        nsp = h.negativeSpans.map(SpanJSON.init)
        pb = h.positiveBuckets
        nb = h.negativeBuckets
        cv = h.customValues.map { $0.map(hexBits) }
    }

    var histogram: Histogram {
        Histogram(
            counterResetHint: CounterResetHint(rawValue: crh)!,
            schema: schema,
            zeroThreshold: doubleFromHex(zt),
            zeroCount: zc,
            count: count,
            sum: doubleFromHex(sum),
            positiveSpans: psp.map(\.span),
            negativeSpans: nsp.map(\.span),
            positiveBuckets: pb,
            negativeBuckets: nb,
            customValues: cv.map { $0.map(doubleFromHex) })
    }
}

struct FloatHistJSON: Codable, Equatable, Sendable {
    let crh: UInt8
    let schema: Int32
    let zt: String
    let zc: String
    let count: String
    let sum: String
    let psp: [SpanJSON]
    let nsp: [SpanJSON]
    let pb: [String]
    let nb: [String]
    let cv: [String]?

    init(_ fh: FloatHistogram) {
        crh = fh.counterResetHint.rawValue
        schema = fh.schema
        zt = hexBits(fh.zeroThreshold)
        zc = hexBits(fh.zeroCount)
        count = hexBits(fh.count)
        sum = hexBits(fh.sum)
        psp = fh.positiveSpans.map(SpanJSON.init)
        nsp = fh.negativeSpans.map(SpanJSON.init)
        pb = fh.positiveBuckets.map(hexBits)
        nb = fh.negativeBuckets.map(hexBits)
        cv = fh.customValues.map { $0.map(hexBits) }
    }

    var histogram: FloatHistogram {
        FloatHistogram(
            counterResetHint: CounterResetHint(rawValue: crh)!,
            schema: schema,
            zeroThreshold: doubleFromHex(zt),
            zeroCount: doubleFromHex(zc),
            count: doubleFromHex(count),
            sum: doubleFromHex(sum),
            positiveSpans: psp.map(\.span),
            negativeSpans: nsp.map(\.span),
            positiveBuckets: pb.map(doubleFromHex),
            negativeBuckets: nb.map(doubleFromHex),
            customValues: cv.map { $0.map(doubleFromHex) })
    }
}

/// Every bucket an iterator yields, rendered the way Go's `Bucket.String()` does
/// — which folds in the bounds, the inclusivity flags and the decoded count.
func drain<I: BucketIterator>(_ iterator: I) -> [String] {
    var it = iterator
    var out = [String]()
    while it.next() { out.append(it.at().description) }
    return out
}

/// The error text Go would produce, or "" for success.
func errString(_ body: () throws -> Void) -> String {
    do {
        try body()
        return ""
    } catch let e as HistogramError {
        return e.description
    } catch let e as HistogramOperationError {
        return e.description
    } catch {
        return "unexpected error type: \(error)"
    }
}
