//===----------------------------------------------------------------------===//
// Tests for Sources/PromTestStorage — the Phase 5 in-memory Queryable.
//
// Two kinds, and the split is deliberate:
//
//   - **Differential**, against `Fixtures/storage/mem-{select,labels}.jsonl`,
//     which the oracle produced from a real `tsdb.DB`. This is where the
//     behaviour that the port must reproduce is asserted.
//   - **Invariant**, Swift-side, for the two things that have no upstream answer:
//     the unsorted select order (nondeterministic upstream, so a choice here) and
//     the load path's ordering errors (our API, not `storage.Appender`).
//===----------------------------------------------------------------------===//

import Foundation
import GoCompat
import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromHistogram
import PromLabels
import PromStorage
import Testing

@testable import PromTestStorage

// MARK: - Differential

@Suite("PromTestStorage differential")
struct MemStorageFixtureTests {

    /// Every case selects with `sortSeries: true`, matching the oracle. Unsorted
    /// order is not a contract upstream — see ``MemStorageInvariantTests``.
    @Test("storage/mem-select")
    func memSelect() throws {
        try Fixtures.check("storage/mem-select.jsonl", FixtureCase<MemSelectIn, MemSelectOut>.self)
        { input in
            let store = try MemWire.load(input.series)
            let querier = try store.querier(
                mint: MemWire.i64(input.mint), maxt: MemWire.i64(input.maxt))

            var hints: SelectHints?
            if let h = input.hints {
                hints = SelectHints(
                    start: MemWire.i64(h.start), end: MemWire.i64(h.end),
                    disableTrimming: h.disableTrimming)
            }

            let set = querier.select(
                GoContext.background(), sortSeries: true, hints: hints,
                matchers: try MemWire.matchers(input.matchers))

            var out = [MemSeriesOutJSON]()
            while set.next() {
                guard let s = set.at() else { break }
                out.append(MemWire.drain(s))
            }
            return MemSelectOut(
                series: out, err: set.err().map { String(describing: $0) } ?? "",
                warnings: [])
        }
    }

    @Test("storage/mem-labels")
    func memLabels() throws {
        try Fixtures.check("storage/mem-labels.jsonl", FixtureCase<MemLabelsIn, MemLabelsOut>.self)
        { input in
            let store = try MemWire.load(input.series)
            let querier = try store.querier(
                mint: MemWire.i64(input.mint), maxt: MemWire.i64(input.maxt))

            let hints = input.limit > 0 ? LabelHints(limit: input.limit) : nil
            let matchers = try MemWire.matchers(input.matchers ?? [])

            let result: [String]
            if input.kind == "names" {
                result = try querier.labelNames(
                    GoContext.background(), hints: hints, matchers: matchers).names
            } else {
                result = try querier.labelValues(
                    GoContext.background(), name: input.name, hints: hints,
                    matchers: matchers
                ).values
            }
            return MemLabelsOut(result: result, err: "", warnings: [])
        }
    }
}

// MARK: - Invariants

@Suite("PromTestStorage invariants")
struct MemStorageInvariantTests {

    /// Append order is deliberately not label order, so the two select orders are
    /// distinguishable.
    private func dataset() throws -> (store: MemStorage, appended: [Labels]) {
        let lsets = [
            Labels(strings: ["__name__", "m", "i", "2"]),
            Labels(strings: ["__name__", "m", "i", "0"]),
            Labels(strings: ["__name__", "m", "i", "1"]),
        ]
        let store = MemStorage()
        for (n, lset) in lsets.enumerated() {
            try store.load(
                lset,
                [
                    FSample(st: 0, t: 0, f: Double(n)),
                    FSample(st: 0, t: 100, f: Double(n) + 0.5),
                ])
        }
        return (store, lsets)
    }

    private func selectLabels(_ store: MemStorage, sorted: Bool) throws -> [Labels] {
        let q = try store.querier(mint: 0, maxt: 1000)
        let set = q.select(
            GoContext.background(), sortSeries: sorted, hints: nil,
            matchers: [try Matcher(.equal, "__name__", "m")])
        var out = [Labels]()
        while set.next() {
            guard let s = set.at() else { break }
            out.append(s.labels())
        }
        return out
    }

    /// `sortSeries: false` yields **insertion order**. There is nothing upstream
    /// to compare this against: with everything in the Head, upstream's order is
    /// series-ref order, and `promqltest` appends by ranging a Go map. This asserts
    /// the port's choice so it cannot drift silently. docs/PORTING.md exception 11.
    @Test("unsorted select is insertion order")
    func unsortedIsInsertionOrder() throws {
        let (store, appended) = try dataset()
        #expect(try selectLabels(store, sorted: false) == appended)
    }

    /// Sorting changes the order but not the membership, which is the part that
    /// *is* upstream's contract.
    @Test("sorted select is label order over the same set")
    func sortedIsLabelOrder() throws {
        let (store, appended) = try dataset()
        let sorted = try selectLabels(store, sorted: true)
        #expect(sorted == appended.sorted { Labels.compare($0, $1) < 0 })
        #expect(Set(sorted) == Set(try selectLabels(store, sorted: false)))
    }

    /// The chunk-granularity caveat on ``MemQuerier/spanOverlaps(_:mint:maxt:)``,
    /// asserted rather than left as prose: an instant between two samples returns
    /// the series **empty**, not absent.
    @Test("a fully trimmed series is returned empty, not dropped")
    func trimmedSeriesIsReturnedEmpty() throws {
        let (store, _) = try dataset()
        let q = try store.querier(mint: 50, maxt: 50)
        let set = q.select(
            GoContext.background(), sortSeries: true, hints: nil,
            matchers: [try Matcher(.equal, "__name__", "m")])

        var count = 0
        while set.next() {
            guard let s = set.at() else { break }
            count += 1
            let it = s.iterator(nil)
            #expect(it.next() == .none)
        }
        #expect(count == 3)
    }

    /// Past the last sample of every series, stage 1 drops them all.
    @Test("a series outside the querier range is absent")
    func seriesOutsideRangeIsAbsent() throws {
        let (store, _) = try dataset()
        #expect(try selectLabels(store, sorted: true).count == 3)

        let q = try store.querier(mint: 101, maxt: 200)
        let set = q.select(
            GoContext.background(), sortSeries: true, hints: nil,
            matchers: [try Matcher(.equal, "__name__", "m")])
        #expect(set.next() == false)
    }

    // MARK: Load path

    private func store(_ samples: [any Sample]) throws -> MemStorage {
        let s = MemStorage()
        try s.load(Labels(strings: ["__name__", "m"]), samples)
        return s
    }

    @Test("an out-of-order append is rejected")
    func outOfOrderRejected() throws {
        #expect(throws: StorageError.outOfOrderSample) {
            try store([FSample(st: 0, t: 100, f: 1), FSample(st: 0, t: 50, f: 2)])
        }
    }

    /// head_append.go:665 — an exact duplicate is accepted and dropped.
    @Test("an exact duplicate append is accepted and dropped")
    func exactDuplicateAccepted() throws {
        let s = try store([FSample(st: 0, t: 100, f: 1), FSample(st: 0, t: 100, f: 1)])
        let q = try s.querier(mint: 0, maxt: 1000)
        let set = q.select(
            GoContext.background(), sortSeries: false, hints: nil, matchers: [])
        #expect(set.next())
        let series = try #require(set.at())
        #expect(MemWire.drain(series).samples.count == 1)
    }

    /// Compared as **bits**, so a repeated NaN is an accepted duplicate where
    /// `==` would have called it a conflict.
    @Test("a repeated NaN is an exact duplicate")
    func repeatedNaNIsDuplicate() throws {
        let s = try store([
            FSample(st: 0, t: 100, f: Double.nan), FSample(st: 0, t: 100, f: Double.nan),
        ])
        let q = try s.querier(mint: 0, maxt: 1000)
        let set = q.select(
            GoContext.background(), sortSeries: false, hints: nil, matchers: [])
        #expect(set.next())
        let series = try #require(set.at())
        #expect(MemWire.drain(series).samples.count == 1)
    }

    /// ...and by the same bit comparison, `+0` landing on `-0` is a conflict.
    @Test("negative zero over positive zero is a duplicate conflict")
    func signedZeroIsConflict() throws {
        #expect(throws: DuplicateSampleForTimestampError.self) {
            try store([
                FSample(st: 0, t: 100, f: -0.0), FSample(st: 0, t: 100, f: 0.0),
            ])
        }
    }

    @Test("a differing value at the same timestamp carries Go's message")
    func duplicateMessage() throws {
        do {
            _ = try store([FSample(st: 0, t: 100, f: 1), FSample(st: 0, t: 100, f: 2)])
            Issue.record("expected a duplicate-sample error")
        } catch let error as DuplicateSampleForTimestampError {
            #expect(
                String(describing: error)
                    == "duplicate sample for timestamp 100; overrides not allowed: existing 1, new value 2"
            )
        }
    }

    /// A float arriving on top of a histogram is its own error, and `existing` is
    /// deliberately not printed.
    @Test("a float over a histogram is a histogram-to-float duplicate")
    func floatOverHistogram() throws {
        let h = FloatHistogram(
            schema: 0, count: 3, sum: 6,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 2])
        do {
            _ = try store([FHSample(st: 0, t: 100, fh: h), FSample(st: 0, t: 100, f: 5)])
            Issue.record("expected a duplicate-sample error")
        } catch let error as DuplicateSampleForTimestampError {
            #expect(
                String(describing: error)
                    == "duplicate sample for timestamp 100; overrides not allowed: existing is a histogram, new value 5"
            )
        }
    }

    /// Histogram carriage, which the differential suite deliberately leaves out
    /// because a real `tsdb.DB` returns histograms through the chunk encoding
    /// rather than as they were appended. This store hands back what it was given.
    @Test("histogram samples round-trip through the store")
    func histogramsRoundTrip() throws {
        let fh = FloatHistogram(
            schema: 0, count: 3, sum: 6,
            positiveSpans: [Span(offset: 0, length: 2)],
            positiveBuckets: [1, 2])
        let s = try store([FHSample(st: 0, t: 100, fh: fh)])

        let q = try s.querier(mint: 0, maxt: 1000)
        let set = q.select(
            GoContext.background(), sortSeries: false, hints: nil, matchers: [])
        #expect(set.next())
        let series = try #require(set.at())

        let it = series.iterator(nil)
        #expect(it.next() == .floatHistogram)
        let (t, got) = it.atFloatHistogram(nil)
        #expect(t == 100)
        #expect(try #require(got).equals(fh))
    }

    /// `clear`, which a `.test` file's own `clear` command needs.
    @Test("clear empties the store")
    func clearEmpties() throws {
        let (store, _) = try dataset()
        #expect(store.seriesCount == 3)
        store.clear()
        #expect(store.seriesCount == 0)
        #expect(try selectLabels(store, sorted: true).isEmpty)
    }

    /// A querier holds a snapshot: appends after it was opened are invisible to
    /// it, as they are to a Head querier holding its read lock.
    @Test("a querier is isolated from later appends")
    func querierIsSnapshot() throws {
        let (store, appended) = try dataset()
        let q = try store.querier(mint: 0, maxt: 1000)

        try store.load(
            Labels(strings: ["__name__", "m", "i", "9"]), [FSample(st: 0, t: 200, f: 9)])

        let set = q.select(
            GoContext.background(), sortSeries: false, hints: nil,
            matchers: [try Matcher(.equal, "__name__", "m")])
        var count = 0
        while set.next() { count += 1 }
        #expect(count == appended.count)
    }
}
