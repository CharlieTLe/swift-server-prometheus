//===----------------------------------------------------------------------===//
// Differential tests for model/histogram/float_histogram.go, slice 1: the
// read-only surface and the bucket iterators.
//
// The merge path of `floatBucketIterator` (targetSchema < schema) and its
// `absoluteStartValue` skipping are NOT exercised here. Both are unexported in
// Go and only reachable across the package boundary through `DetectReset`, so
// they are pinned in the DetectReset suite instead.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHistogram

struct FloatOut: Codable, Equatable, Sendable {
    let str: String
    let testExpr: String
    let pos: [String]
    let neg: [String]
    let posRev: [String]
    let negRev: [String]
    let all: [String]
    let allRev: [String]
    /// Null for custom buckets, where `zeroBucket()` traps.
    let zero: String?
    let copy: FloatHistJSON
    let copyTo: FloatHistJSON
    let compact0: FloatHistJSON
    let validate: String
    let size: Int
    let hasOverflow: Bool
}

@Suite("Float histogram matches Go")
struct FloatHistogramTests {

    /// The dirty CopyTo destination the oracle uses, of a different schema, so a
    /// field `copy(to:)` fails to overwrite shows up as a mismatch.
    static func dirtyDestination() -> FloatHistogram {
        FloatHistogram(
            counterResetHint: .gaugeType,
            schema: 3,
            zeroThreshold: 7.5,
            zeroCount: 99,
            count: 123,
            sum: -0.5,
            positiveSpans: [Span(offset: 5, length: 3)],
            negativeSpans: [Span(offset: 2, length: 2)],
            positiveBuckets: [9, 9, 9],
            negativeBuckets: [4, 4],
            customValues: [11, 22])
    }

    @Test("String, TestExpression, every iterator, Copy, CopyTo, Compact, Size")
    func values() throws {
        try Fixtures.check("histogram/float.jsonl", FixtureCase<FloatHistJSON, FloatOut>.self) {
            input in
            let h = input.histogram
            var destination = Self.dirtyDestination()
            h.copy(to: &destination)
            var compacted = h.copy()
            compacted.compact(maxEmptyBuckets: 0)
            return FloatOut(
                str: h.description,
                testExpr: h.testExpression(),
                pos: drain(h.positiveBucketIterator()),
                neg: drain(h.negativeBucketIterator()),
                posRev: drain(h.positiveReverseBucketIterator()),
                negRev: drain(h.negativeReverseBucketIterator()),
                all: drain(h.allBucketIterator()),
                allRev: drain(h.allReverseBucketIterator()),
                zero: h.usesCustomBuckets ? nil : h.zeroBucket().description,
                copy: FloatHistJSON(h.copy()),
                copyTo: FloatHistJSON(destination),
                compact0: FloatHistJSON(compacted),
                validate: errString(h.validate),
                size: h.size,
                hasOverflow: h.hasOverflow)
        }
    }

    @Test("CopyToSchema at every reachable target schema")
    func copyToSchema() throws {
        struct In: Decodable, Sendable {
            let h: FloatHistJSON
            let targetSchema: Int32
        }
        try Fixtures.check(
            "histogram/float-copytoschema.jsonl", FixtureCase<In, FloatHistJSON>.self
        ) { input in
            FloatHistJSON(input.h.histogram.copyToSchema(input.targetSchema))
        }
    }

    @Test("Equals over every pair of the bit-pattern corpus")
    func equals() throws {
        struct In: Decodable, Sendable {
            let a: FloatHistJSON
            let b: FloatHistJSON
        }
        try Fixtures.check("histogram/float-equals.jsonl", FixtureCase<In, Bool>.self) { input in
            input.a.histogram.equals(input.b.histogram)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("Float histogram invariants")
struct FloatHistogramInvariantTests {

    static let sample = FloatHistogram(
        schema: 0,
        zeroThreshold: 0.001,
        zeroCount: 4,
        count: 21,
        sum: 1234.5,
        positiveSpans: [Span(offset: 0, length: 3), Span(offset: 1, length: 1)],
        negativeSpans: [Span(offset: 0, length: 4), Span(offset: 1, length: 1)],
        positiveBuckets: [1, 2, 1, 1],
        negativeBuckets: [1, 3, 1, 2, 1])

    @Test("Equals compares counts by bit pattern but the zero threshold by value")
    func equalsComparisonModes() {
        var a = Self.sample
        var b = Self.sample
        // Count, Sum, ZeroCount and buckets: bit patterns, so NaN equals itself...
        a.count = .nan
        b.count = .nan
        #expect(a.equals(b))
        // ...and -0 does not equal +0.
        a.count = 0
        b.count = -0.0
        #expect(!a.equals(b))

        a = Self.sample
        b = Self.sample
        // ZeroThreshold, by contrast, is compared with != — float_histogram.go:623.
        // So a NaN threshold never equals itself...
        a.zeroThreshold = .nan
        b.zeroThreshold = .nan
        #expect(!a.equals(b))
        // ...and -0 does equal +0.
        a.zeroThreshold = 0
        b.zeroThreshold = -0.0
        #expect(a.equals(b))
    }

    @Test("CopyToSchema keeps the counter reset hint only on the fast path")
    func copyToSchemaDropsHint() {
        // float_histogram.go:161 builds the result with a struct literal that omits
        // CounterResetHint, so a real reduction resets the hint and drops
        // customValues. Only targetSchema == schema goes through Copy.
        var h = Self.sample
        h.counterResetHint = .gaugeType
        #expect(h.copyToSchema(0).counterResetHint == .gaugeType)
        #expect(h.copyToSchema(-1).counterResetHint == .unknownCounterReset)
    }

    @Test("TestExpression emits the PromQL testing DSL")
    func testExpression() {
        // This has to round-trip with the PromQL parser in Phase 4, because the
        // conformance .test files are written in it.
        let h = FloatHistogram(
            schema: 0,
            count: 4,
            sum: 5,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 1])
        #expect(h.testExpression() == "{{count:4 sum:5 buckets:[1 2 1]}}")

        // Schema, zero bucket, offsets, the negative side and the hint all appear.
        let full = FloatHistogram(
            counterResetHint: .gaugeType,
            schema: 1,
            zeroThreshold: 0.001,
            zeroCount: 2,
            count: 8,
            sum: 3.5,
            positiveSpans: [Span(offset: 1, length: 2)],
            negativeSpans: [Span(offset: 2, length: 1)],
            positiveBuckets: [1, 2],
            negativeBuckets: [3])
        #expect(
            full.testExpression()
                == "{{schema:1 count:8 sum:3.5 z_bucket:2 z_bucket_w:0.001 counter_reset_hint:gauge offset:1 buckets:[1 2] n_offset:2 n_buckets:[3]}}"
        )

        // Custom values print as Go's %g over the whole slice: bracketed, space
        // separated.
        let nhcb = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 3,
            sum: 1.5,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 2],
            customValues: [0.5, 1, 2.5])
        #expect(
            nhcb.testExpression()
                == "{{schema:-53 count:3 sum:1.5 custom_values:[0.5 1 2.5] buckets:[1 2]}}")
    }

    @Test("TestExpression compacts first, so multi-span input is fine")
    func testExpressionCompacts() {
        // Two spans with a gap become one span with explicit empty buckets, since
        // Go compacts with maxEmptyBuckets == MaxInt before rendering.
        let h = FloatHistogram(
            schema: 0,
            count: 3,
            sum: 3,
            positiveSpans: [Span(offset: 0, length: 2), Span(offset: 2, length: 1)],
            positiveBuckets: [1, 1, 1])
        #expect(h.testExpression() == "{{count:3 sum:3 buckets:[1 1 0 0 1]}}")
    }

    @Test("Validate does not compare count against the buckets")
    func validateIgnoresCount() {
        // Unlike Histogram.validate(), floating-point error would make a strict
        // check produce false positives, so Go omits it entirely.
        var h = FloatHistogram(
            schema: 0,
            count: 1000,
            positiveSpans: [Span(offset: 0, length: 1)],
            positiveBuckets: [1])
        #expect(throws: Never.self) { try h.validate() }
        // A negative count is still rejected — note the double space, which is
        // upstream's typo.
        h.count = -1
        #expect(
            errString(h.validate)
                == "observation count is  -1: histogram's observation count is negative")
        // As is a negative zero count, which the integer histogram cannot express.
        h.count = 1
        h.zeroCount = -2.5
        #expect(
            errString(h.validate)
                == "zero bucket has observation count of -2.5: histogram has a bucket whose observation count is negative"
        )
    }

    @Test("the AllBucketIterator clamps boundaries that overlap the zero bucket")
    func allBucketIteratorClamps() {
        // Both outer buckets lie entirely inside the zero threshold, so clamping
        // their inner boundary to it pushes that boundary PAST the outer one and
        // Go reports an inverted interval: "(0.5,0.25]" rather than "(0.125,0.25]".
        // Verified against Go directly — the clamp is unconditional, with no check
        // that the bucket still makes sense afterwards.
        let h = FloatHistogram(
            schema: 0,
            zeroThreshold: 0.5,
            zeroCount: 2,
            count: 4,
            positiveSpans: [Span(offset: -2, length: 1)],
            negativeSpans: [Span(offset: -2, length: 1)],
            positiveBuckets: [1],
            negativeBuckets: [1])
        let all = drain(h.allBucketIterator())
        #expect(all == ["[-0.25,-0.5):1", "[-0.5,0.5]:2", "(0.5,0.25]:1"])
        // Reverse yields the same buckets in the opposite order.
        #expect(drain(h.allReverseBucketIterator()) == all.reversed())
    }

    @Test("the reverse iterators walk the same buckets backwards")
    func reverseIterators() {
        let forward = drain(Self.sample.positiveBucketIterator())
        let reverse = drain(Self.sample.positiveReverseBucketIterator())
        #expect(reverse == forward.reversed())

        let negForward = drain(Self.sample.negativeBucketIterator())
        let negReverse = drain(Self.sample.negativeReverseBucketIterator())
        #expect(negReverse == negForward.reversed())
    }

    @Test("Size reports Go's 64-bit layout, not Swift's")
    func size() {
        // Callers use this as a stable memory-accounting number, so it is Go's
        // struct layout by design: 168 bytes plus 8 per span, bucket and bound.
        #expect(FloatHistogram().size == 168)
        #expect(Self.sample.size == 168 + 2 * 8 + 2 * 8 + 4 * 8 + 5 * 8)
        var h = FloatHistogram(schema: HistogramSchema.customBuckets)
        h.customValues = [1, 2, 3]
        #expect(h.size == 168 + 3 * 8)
    }

    @Test("HasOverflow finds an infinity in any field")
    func hasOverflow() {
        #expect(!Self.sample.hasOverflow)
        for mutate in [
            { (h: inout FloatHistogram) in h.count = .infinity },
            { h in h.sum = -.infinity },
            { h in h.zeroCount = .infinity },
            { h in h.positiveBuckets[0] = .infinity },
            { h in h.negativeBuckets[0] = -.infinity },
        ] {
            var h = Self.sample
            mutate(&h)
            #expect(h.hasOverflow)
        }
        // Custom values count too, even though this histogram's schema ignores them.
        var nhcb = FloatHistogram(schema: HistogramSchema.customBuckets)
        nhcb.customValues = [1, .infinity]
        #expect(nhcb.hasOverflow)
        // A NaN is not an overflow.
        var nan = Self.sample
        nan.sum = .nan
        #expect(!nan.hasOverflow)
    }
}
