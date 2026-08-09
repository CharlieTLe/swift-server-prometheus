//===----------------------------------------------------------------------===//
// Differential tests for promql/value.go.
//
// Every String() here reaches the Phase 5 exit gate: promqltest renders results
// through them and compares the text. They use strconv.FormatFloat(v, 'f', -1, 64)
// — the 'f' format, which has no exponent, so 1e21 is 22 digits and MaxFloat64 is
// 309 of them. That is a different ADR-4 surface from the 'g' used almost
// everywhere else in this port.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromHistogram
import PromLabels
import PromModel
import PromQLParser
import Testing

@testable import PromQL

@Suite("promql value types match Go")
struct ValueTests {

    @Test("String, Scalar, points, Sample, Series, Vector and Matrix render like Go's")
    func rendering() throws {
        try Fixtures.check("promql/value.jsonl", FixtureCase<ValueIn, ValueOut>.self) { input in
            runValueCase(input)
        }
    }

    @Test("Matrix sorts by labels.Compare, which is byte order")
    func sorting() throws {
        try Fixtures.check("promql/value-sort.jsonl", FixtureCase<SortIn, SortOut>.self) {
            input in
            runSortCase(input)
        }
    }
}

@Suite("StorageSeries matches Go")
struct StorageSeriesTests {

    @Test("every op script over the merged float and histogram streams")
    func fixtures() throws {
        try Fixtures.check(
            "promql/storageseries.jsonl", FixtureCase<StorageSeriesIn, ValueIterOut>.self
        ) { input in
            runStorageSeriesOps(input)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("promql value invariants")
struct ValueInvariantTests {

    @Test("the 'f' format is used, not 'g'")
    func formatIsF() {
        // The single easiest way to break every rendering in this file at once, and
        // it would look right for ordinary values: 'g' only diverges at the
        // exponent boundaries.
        #expect(Scalar(t: 0, v: 1e21).description == "scalar: 1000000000000000000000 @[0]")
        #expect(FPoint(t: 0, f: 1e-7).description == "0.0000001 @[0]")
        #expect(FPoint(t: 0, f: -0.0).description == "-0 @[0]", "signed zero survives")
    }

    @Test("an empty Series still renders the trailing newline")
    func emptySeriesKeepsNewline() {
        // value.go:89 joins an empty slice, so the format's "\n" is still emitted
        // and the result ends in a blank line. A `guard vals.isEmpty` shortcut here
        // would look tidier and be wrong.
        let s = Series(metric: Labels(strings: "__name__", "x"))
        #expect(s.description == "{__name__=\"x\"} =>\n")
    }

    @Test("a mixed Series renders floats first, not merged by timestamp")
    func mixedSeriesDoesNotMerge() {
        // value.go:78-81 carries upstream's own TODO wondering whether primary
        // sorting by timestamp would be better. It is not what it does.
        let s = Series(
            metric: .empty,
            floats: [FPoint(t: 100, f: 1)],
            histograms: [HPoint(t: 0, h: valueFloatHistogramCatalogue(3)!)])
        let lines = s.description.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("1 @[100]"), "the float comes first despite t=100 > t=0")
    }

    @Test("Vector and Matrix weigh histograms differently")
    func totalSamplesDisagree() {
        // value.go:282 uses H.Size()/16 for a Vector, while HPoint.size — which
        // Matrix.TotalSamples goes through — uses (H.Size() + 8)/16. The
        // inconsistency is upstream's, and both feed sample-count limits, so
        // neither can be "corrected" to the other.
        let h = valueFloatHistogramCatalogue(3)!
        let vec = Vector([Sample(t: 0, h: h)])
        let mat = Matrix([Series(histograms: [HPoint(t: 0, h: h)])])
        #expect(vec.totalSamples == 1 + h.size / 16)
        #expect(mat.totalSamples == (h.size + 8) / 16)
        #expect(vec.totalSamples != mat.totalSamples)
    }

    @Test("duplicate detection compares hashes, so it can false-positive")
    func sameLabelsetUsesHashes() {
        // value.go:296 compares Metric.Hash(), not the labels. A hash collision
        // would report a duplicate that is not one — Go's behaviour, and the hash
        // is the stringlabels one per ADR-1. Pinned so a "fix" to comparing labels
        // is a deliberate divergence rather than a tidy-up.
        let a = Sample(metric: Labels(strings: "__name__", "a"))
        let b = Sample(metric: Labels(strings: "__name__", "b"))
        #expect(!Vector([]).containsSameLabelset)
        #expect(!Vector([a]).containsSameLabelset)
        #expect(!Vector([a, b]).containsSameLabelset)
        #expect(Vector([a, a]).containsSameLabelset, "the len == 2 branch")
        #expect(Vector([a, b, a]).containsSameLabelset, "the map branch")
        #expect(!Vector([a, b, Sample(metric: Labels(strings: "__name__", "c"))])
            .containsSameLabelset)
    }

    @Test("countSamplesAfter counts strictly after the cutoff")
    func countSamplesAfterIsStrict() {
        // Unexported in Go, so unreachable from the oracle — see the suite's note.
        // Pinned here against the HPoint size formula the fixtures DO pin.
        let h = valueFloatHistogramCatalogue(3)!
        let floats = [FPoint(t: 0, f: 1), FPoint(t: 10, f: 2), FPoint(t: 20, f: 3)]
        let hists = [HPoint(t: 5, h: h), HPoint(t: 25, h: h)]

        #expect(countSamplesAfter(floats: floats, histograms: [], cutoff: 10) == 1)
        #expect(countSamplesAfter(floats: floats, histograms: [], cutoff: 9) == 2)
        #expect(
            countSamplesAfter(floats: floats, histograms: [], cutoff: 20) == 0,
            "strictly after, so the point at the cutoff does not count")
        #expect(countSamplesAfter(floats: [], histograms: hists, cutoff: 10) == Int64(hists[1].size))
        #expect(
            countSamplesAfter(floats: floats, histograms: hists, cutoff: -1)
                == 3 + Int64(hists[0].size + hists[1].size))
    }

    @Test("Result reports the error's text, then the value, then empty")
    func resultRendering() {
        #expect(Result().description == "")
        #expect(Result(value: Scalar(t: 0, v: 1)).description == "scalar: 1 @[0]")
        #expect(
            Result(error: Result.WrongTypeError.notVector).description
                == "query result is not a Vector")
        // The error wins even when a value is present.
        #expect(
            Result(error: Result.WrongTypeError.notScalar, value: Scalar(t: 0, v: 1))
                .description == "query result is not a Scalar")
    }

    @Test("asking Result for the wrong type reports Go's exact wording")
    func resultAccessorErrors() throws {
        // Note the asymmetry: a Matrix mismatch says "range Vector", the
        // documentation's name, where the other two use the internal one.
        #expect(Result.WrongTypeError.notVector.description == "query result is not a Vector")
        #expect(
            Result.WrongTypeError.notRangeVector.description
                == "query result is not a range Vector")
        #expect(Result.WrongTypeError.notScalar.description == "query result is not a Scalar")

        let r = Result(value: Vector([]))
        #expect(throws: Never.self) { try r.vector() }
        #expect(throws: (any Error).self) { try r.matrix() }
        #expect(throws: (any Error).self) { try r.scalar() }

        // A carried error takes precedence over the type check.
        let failed = Result(error: Result.WrongTypeError.notScalar, value: Vector([]))
        #expect(throws: (any Error).self) { try failed.vector() }
    }

    @Test("Vector and Matrix behave like the slices they are in Go")
    func collectionConformance() {
        // They are structs rather than typealiases only because Swift permits one
        // conformance per type, so `[Sample]` and `[Series]` could not both make
        // Array a Value. The call sites should not be able to tell.
        var vec = Vector()
        #expect(vec.isEmpty)
        vec.append(Sample(t: 1, f: 1))
        vec.append(Sample(t: 2, f: 2))
        #expect(vec.count == 2)
        #expect(vec[0].t == 1)
        #expect(vec.map(\.t) == [1, 2])
        vec[0].f = 9
        #expect(vec[0].f == 9)

        var mat: Matrix = Matrix([Series(metric: Labels(strings: "__name__", "b"))])
        mat.append(Series(metric: Labels(strings: "__name__", "a")))
        #expect(mat.count == 2)
        mat.sort()
        #expect(mat[0].metric[LabelName.metricName] == "a")
    }

    @Test("StorageSeries hands back its own labels and recycles its iterator")
    func storageSeriesBridge() {
        let series = Series(
            metric: Labels(strings: "__name__", "x"),
            floats: [FPoint(t: 0, f: 1), FPoint(t: 10, f: 2)])
        let ss = StorageSeries(series)
        #expect(ss.labels() == series.metric)

        let first = ss.iterator(nil)
        #expect(first.next() == PromChunkEnc.ValueType.float)
        #expect(first.atT() == 0)
        let second = ss.iterator(first)
        #expect(second as AnyObject === first as AnyObject, "recycled, not reallocated")
        // Reset puts currT back to Int64.min, so atT() is only meaningful again
        // after the next advance — the iterator is NOT pre-positioned, unlike the
        // look-back wrappers in PromStorage.
        #expect(second.atT() == Int64.min, "reset, and not yet positioned")
        #expect(second.next() == PromChunkEnc.ValueType.float)
        #expect(second.atT() == 0, "back at the start")

        let fresh = ss.iterator(newNopIterator())
        #expect(fresh as AnyObject !== first as AnyObject, "a foreign iterator is replaced")
    }

    @Test("the merged walk yields the float first at an equal timestamp")
    func floatWinsTies() {
        // value.go:557-560 — the default arm picks the float, so at an identical
        // timestamp the float is seen before the histogram. A `<=` there instead of
        // `<` on the histogram comparison would silently reverse it.
        let h = valueFloatHistogramCatalogue(3)!
        let it = StorageSeriesIterator(
            Series(floats: [FPoint(t: 100, f: 7)], histograms: [HPoint(t: 100, h: h)]))
        #expect(it.next() == PromChunkEnc.ValueType.float)
        #expect(it.at() == (100, 7))
        #expect(it.next() == PromChunkEnc.ValueType.floatHistogram)
        #expect(it.atT() == 100)
        #expect(it.next() == PromChunkEnc.ValueType.none)
    }

    @Test("atST is always zero, which is a TODO upstream")
    func atSTIsZero() {
        // value.go:528. Worth pinning: when upstream implements it this will start
        // failing, which is the signal to follow.
        let it = StorageSeriesIterator(Series(floats: [FPoint(t: 5, f: 1)]))
        #expect(it.next() == PromChunkEnc.ValueType.float)
        #expect(it.atST() == 0)
    }

    @Test("seek(Int64.min) reports a float it never read")
    func seekAtTheSentinelDoesNotAdvance() {
        // `currT` starts at math.MinInt64 and the loop is `while currT < t`, so
        // seeking to exactly Int64.min never runs it — and the tail then returns
        // ValFloat because `currH` is nil. The result claims a float sample while
        // the iterator sits on the sentinel with a zero value, having read nothing.
        //
        // I wrote this test asserting the opposite ("always advances at least
        // once") and the fixture said no; verified against Go, which does the same.
        // Replicated, and pinned by promql/storageseries's seek/negative case.
        let it = StorageSeriesIterator(Series(floats: [FPoint(t: 0, f: 1)]))
        #expect(it.seek(Int64.min) == PromChunkEnc.ValueType.float)
        #expect(it.atT() == Int64.min, "not positioned on any real sample")
        #expect(it.at() == (Int64.min, 0))

        // One millisecond higher and it behaves as expected.
        let ok = StorageSeriesIterator(Series(floats: [FPoint(t: 0, f: 1)]))
        #expect(ok.seek(Int64.min + 1) == PromChunkEnc.ValueType.float)
        #expect(ok.atT() == 0)
    }
}
