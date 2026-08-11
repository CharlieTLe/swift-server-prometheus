//===----------------------------------------------------------------------===//
// Differential tests for `util/convertnhcb` — classic histogram samples in, one NHCB out.
//
// The corpus drives a script of setter calls and compares the chosen histogram field by field,
// **including the fields `String()` does not print**: the spans and the custom values. That is the
// lesson the `promqltest` gate taught the hard way — 30 of its failures rendered identically and
// differed in span structure — applied to a new surface from the start rather than after.
//
// See oracle/suites_convertnhcb.go for what the corpus has to reach.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromConvertNHCB
import PromHistogram
import Testing

struct NHCBOp: Decodable, Sendable {
    var op: String
    var a: String
    var b: String?
}

struct NHCBIn: Decodable, Sendable {
    /// Optional because the empty-script case emits `"ops": null` — Go marshals a nil slice as
    /// `null`, and one corpus case is deliberately the no-setters-at-all shape.
    var ops: [NHCBOp]?
}

struct NHCBOut: Decodable, Equatable, Sendable {
    var kind: String
    var str: String
    var schema: Int32
    var count: String
    var sum: String
    var pspans: [String]
    var pbuckets: [String]
    var cv: [String]
    var err: String
    var stickyErr: String
    /// What each setter RETURNED. Upstream's callers discard these, which is exactly why the corpus
    /// has to keep them: a control that changed only a return value survived without this.
    var opErrs: [String]
}

private func bits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hex(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }

@Suite("util/convertnhcb: classic buckets to one NHCB")
struct ConvertNHCBTests {

    @Test("every committed case matches Go, spans and custom values included")
    func matchesGo() throws {
        try Fixtures.check("histogram/convertnhcb.jsonl", FixtureCase<NHCBIn, NHCBOut>.self) {
            input in
            var h = TempHistogram()
            var opErrs: [String] = []
            for op in input.ops ?? [] {
                var e: (any Error)? = nil
                switch op.op {
                case "bucket": e = h.setBucketCount(bits(op.a), bits(op.b!))
                case "count": e = h.setCount(bits(op.a))
                case "sum": e = h.setSum(bits(op.a))
                case "reset": h.reset()
                default: break
                }
                opErrs.append(e.map { String(describing: $0) } ?? "")
            }
            let (ih, fh, err) = h.convert()
            var out = NHCBOut(
                kind: "", str: "", schema: 0, count: "", sum: "", pspans: [], pbuckets: [], cv: [],
                err: "", stickyErr: "", opErrs: opErrs)
            if let sticky = h.err {
                out.stickyErr = String(describing: sticky)
            }
            if let err {
                out.err = String(describing: err)
                return out
            }
            if let ih {
                out.kind = "integer"
                out.str = ih.description
                out.schema = ih.schema
                out.count = String(ih.count)
                out.sum = hex(ih.sum)
                out.pspans = ih.positiveSpans.map { "(\($0.offset),\($0.length))" }
                out.pbuckets = ih.positiveBuckets.map { String($0) }
                out.cv = (ih.customValues ?? []).map(hex)
            } else if let fh {
                out.kind = "float"
                out.str = fh.description
                out.schema = fh.schema
                out.count = hex(fh.count)
                out.sum = hex(fh.sum)
                out.pspans = fh.positiveSpans.map { "(\($0.offset),\($0.length))" }
                out.pbuckets = fh.positiveBuckets.map(hex)
                out.cv = (fh.customValues ?? []).map(hex)
            }
            return out
        }
    }
}

// MARK: - The name helpers, which have no float behaviour to pin

@Suite("convertnhcb: the metric-name helpers")
struct ConvertNHCBNameTests {

    @Test("the three suffixes are stripped in order, and _created is not")
    func suffixes() {
        // Tested in order, so `foo_bucket_sum` loses `_sum` rather than `_bucket`. `_created` is
        // deliberately left alone — upstream's comment says the caller owns it.
        #expect(getHistogramMetricBaseName("foo_bucket") == (.bucket, "foo"))
        #expect(getHistogramMetricBaseName("foo_sum") == (.sum, "foo"))
        #expect(getHistogramMetricBaseName("foo_count") == (.count, "foo"))
        #expect(getHistogramMetricBaseName("foo_bucket_sum") == (.sum, "foo_bucket"))
        #expect(getHistogramMetricBaseName("foo_created") == (.none, "foo_created"))
        #expect(getHistogramMetricBaseName("foo") == (.none, "foo"))
        #expect(getHistogramMetricBaseName("") == (.none, ""))
        // A name that IS a suffix.
        #expect(getHistogramMetricBaseName("_bucket") == (.bucket, ""))
    }
}
