//===----------------------------------------------------------------------===//
// Differential tests for model/histogram/float_histogram.go, slices 2/4/5: the
// arithmetic.
//
// Everything compares by bit pattern. For the Kahan paths that is not a nicety:
// comparing values would let `NaN != NaN` and `-0.0 == 0.0` hide a real
// divergence in the compensation term, which is exactly the kind of error this
// suite exists to catch.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHistogram

@Suite("Float histogram arithmetic matches Go")
struct FloatArithmeticTests {

    @Test("Mul and Div at every factor")
    func scale() throws {
        struct In: Decodable, Sendable {
            let h: FloatHistJSON
            let factor: String
            let isDiv: Bool
        }
        try Fixtures.check("histogram/float-scale.jsonl", FixtureCase<In, FloatHistJSON>.self) {
            input in
            var h = input.h.histogram
            let factor = doubleFromHex(input.factor)
            if input.isDiv {
                h.div(factor)
            } else {
                h.mul(factor)
            }
            return FloatHistJSON(h)
        }
    }

    @Test("Add and Sub, with the flags and the compacted result")
    func addSub() throws {
        struct In: Decodable, Sendable {
            let a: FloatHistJSON
            let b: FloatHistJSON
            let isSub: Bool
        }
        struct Out: Decodable, Equatable, Sendable {
            let h: FloatHistJSON
            let crc: Bool
            let nbr: Bool
            let err: String
            let compacted: FloatHistJSON
        }
        try Fixtures.check("histogram/float-add.jsonl", FixtureCase<In, Out>.self) { input in
            var a = input.a.histogram
            let b = input.b.histogram
            var collision = false
            var reconciled = false
            let err = errString {
                let result = input.isSub ? try a.sub(b) : try a.add(b)
                collision = result.counterResetCollision
                reconciled = result.nhcbBoundsReconciled
            }
            var compacted = a.copy()
            compacted.compact(maxEmptyBuckets: 0)
            return Out(
                h: FloatHistJSON(a), crc: collision, nbr: reconciled, err: err,
                compacted: FloatHistJSON(compacted))
        }
    }

    @Test("KahanAdd, including the compensation histogram it returns")
    func kahanAdd() throws {
        struct In: Decodable, Sendable {
            let a: FloatHistJSON
            let b: FloatHistJSON
            let withC: Bool
        }
        struct Out: Decodable, Equatable, Sendable {
            let h: FloatHistJSON
            /// Null when the add failed, where Go returns a nil `updatedC`.
            let c: FloatHistJSON?
            let crc: Bool
            let nbr: Bool
            let err: String
        }
        try Fixtures.check("histogram/float-kahanadd.jsonl", FixtureCase<In, Out>.self) { input in
            var a = input.a.histogram
            let b = input.b.histogram

            var seed: FloatHistogram?
            if input.withC {
                // The same pre-seeded compensation histogram the oracle builds:
                // non-zero terms, so a port that ignores the incoming compensation
                // is caught rather than accidentally agreeing.
                var s = FloatHistogram(
                    counterResetHint: a.counterResetHint,
                    schema: a.schema,
                    zeroThreshold: a.zeroThreshold,
                    zeroCount: 1e-17,
                    count: 2e-17,
                    sum: 3e-17,
                    positiveSpans: a.positiveSpans,
                    negativeSpans: a.negativeSpans,
                    positiveBuckets: [Double](repeating: 0, count: a.positiveBuckets.count),
                    customValues: a.customValues)
                for j in s.positiveBuckets.indices {
                    s.positiveBuckets[j] = Double(j + 1) * 1e-17
                }
                if !a.usesCustomBuckets {
                    s.negativeBuckets = [Double](
                        repeating: 0, count: a.negativeBuckets.count)
                    for j in s.negativeBuckets.indices {
                        s.negativeBuckets[j] = Double(j + 1) * 1e-18
                    }
                }
                seed = s
            }

            // Go returns a nil updatedC when the add failed, so nothing to report.
            var c: FloatHistogram?
            var collision = false
            var reconciled = false
            let err = errString {
                let (updatedC, result) = try a.kahanAdd(b, seed)
                c = updatedC
                collision = result.counterResetCollision
                reconciled = result.nhcbBoundsReconciled
            }
            return Out(
                h: FloatHistJSON(a), c: c.map(FloatHistJSON.init), crc: collision,
                nbr: reconciled, err: err)
        }
    }

    @Test("ReduceResolution, including the histogram left behind on error")
    func reduceResolution() throws {
        struct In: Decodable, Sendable {
            let h: FloatHistJSON
            let targetSchema: Int32
        }
        struct Out: Decodable, Equatable, Sendable {
            let h: FloatHistJSON
            let err: String
        }
        try Fixtures.check("histogram/float-reduce.jsonl", FixtureCase<In, Out>.self) { input in
            var h = input.h.histogram
            let err = errString { try h.reduceResolution(targetSchema: input.targetSchema) }
            return Out(h: FloatHistJSON(h), err: err)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("Float histogram arithmetic invariants")
struct FloatArithmeticInvariantTests {

    static func sample() -> FloatHistogram {
        FloatHistogram(
            schema: 0,
            zeroThreshold: 0.001,
            zeroCount: 2,
            count: 8,
            sum: 9,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 3])
    }

    @Test("Mul and Div set the gauge hint for a negative operand")
    func negativeOperandBecomesGauge() {
        var h = Self.sample()
        h.mul(-1)
        #expect(h.counterResetHint == .gaugeType)

        var g = Self.sample()
        g.div(-1)
        #expect(g.counterResetHint == .gaugeType)

        // A positive operand leaves the hint alone.
        var p = Self.sample()
        p.mul(2)
        #expect(p.counterResetHint == .unknownCounterReset)
    }

    @Test("dividing by zero removes every bucket and sets the scalars to infinity")
    func divByZero() {
        var h = Self.sample()
        h.div(0)
        #expect(h.positiveBuckets.isEmpty)
        #expect(h.negativeBuckets.isEmpty)
        #expect(h.positiveSpans.isEmpty)
        #expect(h.negativeSpans.isEmpty)
        #expect(h.count == .infinity)
        #expect(h.zeroCount == .infinity)
        // Note the hint is NOT set to gauge here: Go returns before that check.
        #expect(h.counterResetHint == .unknownCounterReset)
    }

    @Test("mixing an exponential histogram with an NHCB is rejected")
    func incompatibleSchemas() {
        var exponential = Self.sample()
        let nhcb = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 3,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 2],
            customValues: [1, 2])

        #expect(
            errString { _ = try exponential.add(nhcb) }
                == "cannot apply this operation on histograms with a mix of exponential and custom bucket schemas"
        )
        // The receiver is untouched, because the check happens first.
        #expect(exponential.equals(Self.sample()))

        var custom = nhcb
        #expect(errString { _ = try custom.sub(Self.sample()) } != "")
        #expect(errString { _ = try custom.kahanAdd(Self.sample(), nil).1.counterResetCollision } != "")
    }

    @Test("a counter reset collision is reported and downgrades the hint")
    func counterResetCollision() throws {
        var a = Self.sample()
        a.counterResetHint = .counterReset
        var b = Self.sample()
        b.counterResetHint = .notCounterReset

        let result = try a.add(b)
        #expect(result.counterResetCollision)
        #expect(a.counterResetHint == .unknownCounterReset)

        // Anything involving a gauge is not a collision; the result is a gauge.
        var g = Self.sample()
        g.counterResetHint = .gaugeType
        var counter = Self.sample()
        counter.counterResetHint = .counterReset
        let gaugeResult = try counter.add(g)
        #expect(!gaugeResult.counterResetCollision)
        #expect(counter.counterResetHint == .gaugeType)
    }

    @Test("mismatched NHCB bounds are reconciled to their intersection")
    func nhcbBoundsReconciled() throws {
        var a = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 10,
            positiveSpans: [Span(offset: 0, length: 4)],
            positiveBuckets: [1, 2, 3, 4],
            customValues: [1, 2, 3])
        let b = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 26,
            positiveSpans: [Span(offset: 0, length: 4)],
            positiveBuckets: [5, 6, 7, 8],
            customValues: [1, 3, 5])

        let result = try a.add(b)
        #expect(result.nhcbBoundsReconciled)
        // Only the bounds present in both survive.
        #expect(a.customValues == [1, 3])

        // Matching bounds do not trigger reconciliation.
        var c = a
        c.customValues = [1, 3]
        var d = c
        #expect(try !d.add(c).nhcbBoundsReconciled)
    }

    @Test("no overlap in the bounds leaves no bounds at all")
    func nhcbNoOverlap() throws {
        var a = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 6,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [1, 2, 3],
            customValues: [1, 2])
        let b = FloatHistogram(
            schema: HistogramSchema.customBuckets,
            count: 15,
            positiveSpans: [Span(offset: 0, length: 3)],
            positiveBuckets: [4, 5, 6],
            customValues: [7, 8])

        #expect(try a.add(b).nhcbBoundsReconciled)
        // intersectCustomBucketBounds returns nil rather than an empty slice, so
        // everything lands in the single implicit +Inf bucket.
        #expect(a.customValues == nil)
        #expect(a.positiveBuckets == [21])
    }

    @Test("intersectCustomBucketBounds returns nil, not empty, for an empty input")
    func intersectEmpty() {
        // The distinction matters: customValues is Optional precisely because Go
        // tests it against nil.
        #expect(intersectCustomBucketBounds([], [1, 2]) == nil)
        #expect(intersectCustomBucketBounds([1, 2], []) == nil)
        #expect(intersectCustomBucketBounds([1, 2], [3, 4]) == nil)
        #expect(intersectCustomBucketBounds([1, 2, 3], [2, 3, 4])! == [2, 3])
    }

    @Test("KahanAdd creates a compensation histogram when given none")
    func kahanAddCreatesCompensation() throws {
        var a = Self.sample()
        let b = Self.sample()
        let (c, _) = try a.kahanAdd(b, nil)
        // The compensation histogram matches the result's layout.
        #expect(c.schema == a.schema)
        #expect(c.positiveSpans == a.positiveSpans)
        #expect(c.positiveBuckets.count == a.positiveBuckets.count)
        #expect(c.zeroThreshold == a.zeroThreshold)
    }

    @Test("KahanAdd beats naive addition on a pathological sequence")
    func kahanAddIsCompensated() throws {
        // A large bucket plus many tiny ones: naive summation loses every tiny
        // term, compensated summation does not.
        var kahan = FloatHistogram(
            schema: 0,
            positiveSpans: [Span(offset: 0, length: 1)],
            positiveBuckets: [1e16])
        var naive = kahan
        let tiny = FloatHistogram(
            schema: 0,
            positiveSpans: [Span(offset: 0, length: 1)],
            positiveBuckets: [1])

        var c: FloatHistogram?
        for _ in 0..<100 {
            let (updated, _) = try kahan.kahanAdd(tiny, c)
            c = updated
            try naive.add(tiny)
        }
        // Naive addition drops terms below the ULP of 1e16, which is 2.
        #expect(naive.positiveBuckets[0] == 1e16)
        // The compensated sum carries them in the compensation term.
        #expect(c!.positiveBuckets[0] != 0)
    }

    @Test("Add leaves empty buckets and adjacent spans for Compact to clean up")
    func addDoesNotCompact() throws {
        var a = FloatHistogram(
            schema: 0,
            positiveSpans: [Span(offset: 0, length: 1)],
            positiveBuckets: [1])
        let b = FloatHistogram(
            schema: 0,
            positiveSpans: [Span(offset: 2, length: 1)],
            positiveBuckets: [1])
        try a.add(b)
        // Two spans, because Add documents that normalising is the caller's job.
        #expect(a.positiveSpans.count == 2)
        a.compact(maxEmptyBuckets: 2)
        #expect(a.positiveSpans.count == 1)
    }

    @Test("reconcileZeroBuckets widens the receiver's zero bucket")
    func reconcileZeroBuckets() throws {
        // The other histogram has the larger threshold, so the receiver's zero
        // bucket grows and the buckets now inside it are folded in and trimmed.
        var a = FloatHistogram(
            schema: 0,
            zeroThreshold: 0.001,
            zeroCount: 1,
            count: 6,
            positiveSpans: [Span(offset: -3, length: 5)],
            positiveBuckets: [1, 1, 1, 1, 1])
        let b = FloatHistogram(
            schema: 0,
            zeroThreshold: 0.5,
            zeroCount: 2,
            count: 2,
            positiveSpans: [],
            positiveBuckets: [])

        try a.add(b)
        #expect(a.zeroThreshold == 0.5)
        // The buckets below 0.5 were folded into the zero count: 1 (original) +
        // the three buckets up to 0.5, plus the other histogram's 2.
        #expect(a.zeroCount == 6)
        #expect(a.positiveBuckets == [1, 1])
    }
}
