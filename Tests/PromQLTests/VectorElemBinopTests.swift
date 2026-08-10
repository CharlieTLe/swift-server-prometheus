//===----------------------------------------------------------------------===//
// Tests for `vectorElemBinop`'s HISTOGRAM quadrants, which the differential corpus cannot reach.
//
// `promql/exec` is float-only on purpose: a histogram appended to a real `tsdb.DB` returns
// through the chunk encoding, which re-derives `CounterResetHint`, so pinning it would pin
// Phases 6-7's subject (HANDOFF §5). That leaves three of the four quadrants of
// `vectorElemBinop` — float⊕histogram, histogram⊕float and histogram⊕histogram — with no
// query-level case at all, and three negative controls survived on exactly that.
//
// `vectorElemBinop` is a free function taking plain values, so it can be driven directly. The
// arithmetic it delegates to (`FloatHistogram.add`/`sub`/`mul`/`div`/`trimBuckets`) is already
// pinned bit-for-bit by `Fixtures/histogram/*`; what these assert is the **dispatch**: which
// operator each quadrant allows, what it returns, and which rejections are infos rather than
// errors.
//===----------------------------------------------------------------------===//

import GoCompat
import PromAnnotations
import PromHistogram
import PromLabels
import PromPosRange
import PromQLParser
import Testing

@testable import PromQL

@Suite("vectorElemBinop: the histogram quadrants")
struct VectorElemBinopTests {

    private var pos: PositionRange { PositionRange(start: 0, end: 1) }

    private func h(_ count: Double, _ sum: Double, _ buckets: [Double] = [1, 2]) -> FloatHistogram
    {
        FloatHistogram(
            schema: 0, count: count, sum: sum,
            positiveSpans: [Span(offset: 0, length: UInt32(buckets.count))],
            positiveBuckets: buckets)
    }

    private func run(_ op: ItemType, _ l: Double, _ r: Double, _ hl: FloatHistogram?, _ hr: FloatHistogram?)
        -> (Double, FloatHistogram?, Bool, (any Error)?, (any Error)?)
    {
        vectorElemBinop(op, l, r, hl, hr, pos)
    }

    @Test("float * histogram scales, and every other operator is an info")
    func floatTimesHistogram() {
        // Only `*`, and only because scaling is commutative — there is no `histogram + float`
        // meaning, so `+` is rejected in both directions.
        let (f, hv, keep, info, err) = run(.mul, 3, 0, nil, h(10, 20))
        #expect(f == 0)
        #expect(keep)
        #expect(info == nil && err == nil)
        #expect(hv?.count == 30)
        #expect(hv?.sum == 60)

        for op in [ItemType.add, .sub, .div, .pow, .mod, .eqlc, .neq, .gtr, .lss, .gte, .lte, .atan2, .trimLower, .trimUpper] {
            let (_, hv, keep, _, err) = run(op, 3, 0, nil, h(10, 20))
            #expect(!keep, "\(op) should be rejected")
            #expect(hv == nil)
            // An INFO, not an error: the query succeeds with an annotation and the element
            // vanishes. `handleVectorBinopError` is what turns it into one.
            let anno = try? #require(err as? any AnnotationError)
            #expect(anno?.kind == .info, "\(op) should be rejected with an info")
        }
    }

    @Test("histogram ⊕ float allows scaling, division and the two trims")
    func histogramWithFloat() {
        let (_, mulH, mulKeep, _, mulErr) = run(.mul, 0, 3, h(10, 20), nil)
        #expect(mulKeep && mulErr == nil)
        #expect(mulH?.count == 30)

        let (_, divH, divKeep, _, divErr) = run(.div, 0, 2, h(10, 20), nil)
        #expect(divKeep && divErr == nil)
        #expect(divH?.count == 5)
        #expect(divH?.sum == 10)

        // The two trims exist only in this quadrant, and only this way round.
        let (_, trimUpH, trimUpKeep, _, _) = run(.trimUpper, 0, 1, h(10, 20), nil)
        #expect(trimUpKeep)
        #expect(trimUpH != nil)
        let (_, trimLoH, trimLoKeep, _, _) = run(.trimLower, 0, 1, h(10, 20), nil)
        #expect(trimLoKeep)
        #expect(trimLoH != nil)

        // No `+`/`-`: adding a scalar to a histogram has no meaning.
        for op in [ItemType.add, .sub, .pow, .mod, .eqlc, .neq, .gtr, .lss, .gte, .lte, .atan2] {
            let (_, _, keep, _, err) = run(op, 0, 3, h(10, 20), nil)
            #expect(!keep, "\(op) should be rejected")
            #expect((err as? any AnnotationError)?.kind == .info)
        }
    }

    @Test("histogram ⊕ histogram allows add, sub and the two equalities only")
    func histogramWithHistogram() {
        let (_, addH, addKeep, _, addErr) = run(.add, 0, 0, h(10, 20), h(5, 6))
        #expect(addKeep && addErr == nil)
        #expect(addH?.count == 15)
        #expect(addH?.sum == 26)

        // A difference is a GAUGE whatever the operands were — upstream forces the hint.
        let (_, subH, subKeep, _, subErr) = run(.sub, 0, 0, h(10, 20), h(5, 6))
        #expect(subKeep && subErr == nil)
        #expect(subH?.count == 5)
        #expect(subH?.counterResetHint == .gaugeType)

        // `==`/`!=` return the LEFT histogram as the value and use `keep` to filter, exactly as
        // the float comparisons do. Upstream's comment: "This operation expects that both
        // histograms are compacted."
        let same = h(10, 20)
        let (_, eqH, eqKeep, _, _) = run(.eqlc, 0, 0, same, same)
        #expect(eqKeep)
        #expect(eqH?.count == 10)
        let (_, _, neqKeep, _, _) = run(.neq, 0, 0, same, same)
        #expect(!neqKeep)
        let (_, _, eqDiffKeep, _, _) = run(.eqlc, 0, 0, h(10, 20), h(11, 20))
        #expect(!eqDiffKeep)

        for op in [ItemType.mul, .div, .pow, .mod, .gtr, .lss, .gte, .lte, .atan2, .trimLower, .trimUpper] {
            let (_, _, keep, _, err) = run(op, 0, 0, h(10, 20), h(5, 6))
            #expect(!keep, "\(op) should be rejected")
            #expect((err as? any AnnotationError)?.kind == .info)
        }
    }

    @Test("float ⊕ float rejects only the two trims")
    func floatWithFloat() {
        for op in [ItemType.trimLower, .trimUpper] {
            let (_, _, keep, _, err) = run(op, 1, 2, nil, nil)
            #expect(!keep)
            #expect((err as? any AnnotationError)?.kind == .info)
        }
        // Everything else computes or filters. The comparisons return the LEFT value.
        let (gtF, _, gtKeep, _, _) = run(.gtr, 5, 3, nil, nil)
        #expect(gtF == 5 && gtKeep)
        let (ltF, _, ltKeep, _, _) = run(.lss, 5, 3, nil, nil)
        #expect(ltF == 5 && !ltKeep)
    }
}

// MARK: - returnBool over a histogram result

@Suite("VectorBinop: returnBool and histograms")
struct VectorBinopBoolTests {

    private func evaluator() -> Evaluator {
        Evaluator(
            startTimestamp: 0, endTimestamp: 0, interval: 1, maxSamples: 1_000_000,
            lookbackDelta: GoDuration(nanoseconds: 300_000_000_000),
            noStepSubqueryIntervalFn: nil, enableDelayedNameRemoval: false,
            enableTypeAndUnitLabels: false, useStartTimestamps: false)
    }

    @Test("returnBool clears the histogram result, so a bool comparison is always a float")
    func returnBoolClearsHistogram() throws {
        // `histogramValue = nil` under `returnBool`. Without it, `h == bool h` would return the
        // left histogram *and* a float of 1 — a sample that is both, which nothing downstream
        // expects. Unreachable from the float-only corpus.
        let ev = evaluator()
        let enh = EvalNodeHelper()
        enh.numSigs = 1
        let hist = FloatHistogram(
            schema: 0, count: 10, sum: 20,
            positiveSpans: [Span(offset: 0, length: 2)], positiveBuckets: [4, 6])

        let lhs = Vector([Sample(t: 0, h: hist, metric: Labels(strings: ["a", "1"]))])
        let rhs = Vector([Sample(t: 0, h: hist, metric: Labels(strings: ["a", "1"]))])
        let helpers = [EvalSeriesHelper(sigOrdinal: 0)]

        let (out, err) = try ev.vectorBinop(
            .eqlc, lhs, rhs, VectorMatching(card: .oneToOne), true, helpers, helpers, enh,
            PositionRange(start: 0, end: 1))
        #expect(err == nil)
        #expect(out.samples.count == 1)
        #expect(out.samples[0].h == nil, "returnBool must clear the histogram")
        #expect(out.samples[0].f == 1)
        #expect(out.samples[0].dropName)
    }
}
