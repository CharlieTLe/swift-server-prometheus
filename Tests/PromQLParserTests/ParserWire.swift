//===----------------------------------------------------------------------===//
// Wire helpers shared by the PromQLParser fixture tests.
//
// `FloatHistJSON` duplicates the one in PromHistogramTests rather than being
// shared: GoOracleSupport is where cross-target test helpers live, and it
// deliberately does not depend on PromHistogram (promdiff links it too). Twenty
// lines of restatement is cheaper than that dependency.
//===----------------------------------------------------------------------===//

import GoCompat
import PromHistogram

/// A float64 as its 16 hex digits, which is how every float in Fixtures/ travels:
/// decimal text cannot express a bit-exact comparison, and NaN has no JSON form.
func hexBits(_ v: Double) -> String {
    let s = String(v.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

func doubleFromHex(_ s: String) -> Double {
    Double(bitPattern: UInt64(s, radix: 16)!)
}

/// Go: `strconv.FormatFloat(v, 'f', -1, 64)`, which is what `translate_ast.go`
/// uses for a number literal — never Swift's own formatting (ADR-4).
func formatFloatF(_ v: Double) -> String {
    GoFloat.format(v, .f, precision: -1)
}

struct SpanJSON: Codable, Equatable, Sendable {
    let o: Int32
    let l: UInt32

    init(_ s: Span) {
        o = s.offset
        l = s.length
    }

    var span: Span { Span(offset: o, length: l) }
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
}
