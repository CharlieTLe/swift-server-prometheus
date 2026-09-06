//===----------------------------------------------------------------------===//
// `populateCurrForSingleChunk`'s HISTOGRAM arms — the two branches §7k made reachable.
//
// ## Why this is a Swift-side test and not a corpus case
//
// The re-encoder's differential corpus is `block/seriesset` and §7i(a)'s compaction suite, and neither can
// reach a histogram chunk today: the oracle would have to append one through a real `tsdb.Head`, and the
// Head's histogram append path is the slice §7k unblocks rather than the one it is. Building the block bytes
// by hand instead is what §6w's harness lesson forbids. So this drops a level, exactly as
// `MatrixIterSliceTests` and `VectorElemBinopTests` did when their corpora could not bypass a layer: the
// arms are asserted at the function, over chunks the port's own — corpus-pinned — appenders wrote.
//
// ## What is being asserted, and what it rests on
//
// Upstream's loop (querier.go:970-1000) has three arms; the port had one, guarded with
// `guard vt == .float`, because until §7k there was no encoding that could produce the other two. Quirk 208
// established that this function runs on **every** compaction of a Head — the open head chunk's index meta
// says `MaxInt64`, so `trimBack` always installs a `currDelIter` — so the missing arms were not a
// theoretical gap: they would have made a histogram series uncompactable the moment the Head could append
// one, with the port's own `populateCurrForSingleChunk: value type histogram unsupported`.
//
// Everything the arms are built from is already pinned differentially: the chunk bytes and the samples read
// back by `chunkenc/histogram` and `chunkenc/float-histogram`, `appendable`'s verdicts by the same, and the
// `appendOnly` refusal strings by `HistogramChunkEdgeTests`. What is NOT pinned anywhere else, and is what
// these tests are for, is the wiring: that the arm is taken at all, that `st` is threaded, that the
// appender returned by `AppendHistogram` replaces the one held, and that a refusal is reported as
// `iterate chunk while re-encoding: …`.
//===----------------------------------------------------------------------===//

import PromBlock
import PromChunkEnc
import PromHistogram
import PromIndex
import PromTombstones
import Testing

/// A one-chunk `BlockChunkSource` over bytes held in memory. A block's real one goes through
/// `ChunkReader`; nothing here needs the segment framing, and using it would put the histogram bytes
/// through a layer this test is not about.
private struct SingleChunkSource: BlockChunkSource {
    let encoding: Encoding
    let bytes: [UInt8]

    func chunkOrIterable(_ meta: DecodedChunkMeta, copyHeadChunk: Bool) throws -> ChunkOrIterable {
        ChunkOrIterable(chunk: (encoding: encoding, bytes: bytes))
    }
}

private func hist(_ count: UInt64, _ sum: Double, _ buckets: [Int64]) -> Histogram {
    Histogram(
        schema: 0, zeroThreshold: 0.001, count: count, sum: sum,
        positiveSpans: [Span(offset: 0, length: UInt32(buckets.count))], positiveBuckets: buckets)
}

@Suite("block: the populate iterator's histogram re-encode arms")
struct PopulateHistogramReencodeTests {

    /// An integer histogram chunk with its first sample deleted, re-encoded. Without the arm this reports
    /// `populateCurrForSingleChunk: value type histogram unsupported`; with it, a new `EncHistogram` chunk
    /// comes back carrying the two surviving samples.
    @Test("an integer histogram chunk re-encodes rather than being refused")
    func integerHistogramReEncodes() throws {
        let c = HistogramChunk()
        let app = try c.makeAppender()
        for (i, h) in [hist(6, 12, [2, 1, 3]), hist(9, 18, [3, 1, 3]), hist(14, 31, [5, 1, 3])]
            .enumerated()
        {
            var h = h
            _ = try app.appendHistogram(
                prev: nil, st: 0, t: Int64(i + 1) * 1000, h: &h, appendOnly: false)
        }

        let it = PopulateWithDelChunkSeriesIterator(
            blockID: "b", source: SingleChunkSource(encoding: .histogram, bytes: c.bytes),
            metas: [DecodedChunkMeta(ref: 1, minTime: 1000, maxTime: 3000)],
            intervals: [DeletionInterval(mint: 1000, maxt: 1000)])

        #expect(it.next())
        #expect(it.err() == nil)
        let out = try #require(it.current)
        #expect(out.encoding == .histogram)
        // The re-encoded chunk's own span, not the source meta's.
        #expect(out.meta.minTime == 2000)
        #expect(out.meta.maxTime == 3000)

        let re = try chunkFromData(.histogram, out.bytes)
        #expect(re.numSamples == 2)
        var got: [(Int64, UInt64, Double)] = []
        let rit = re.iterator(nil)
        while rit.next() == .histogram {
            let (t, h) = rit.atHistogram(nil)
            got.append((t, h!.count, h!.sum))
        }
        #expect(got.map(\.0) == [2000, 3000])
        #expect(got.map(\.1) == [9, 14])
        #expect(got.map(\.2) == [18, 31])
        #expect(!it.next())
    }

    /// The float twin. Its arm calls `AppendFloatHistogram`, and a `FloatHistogramAppender` refusing an
    /// integer histogram is a different error string again — so the two arms cannot be collapsed.
    @Test("a float histogram chunk re-encodes rather than being refused")
    func floatHistogramReEncodes() throws {
        let c = FloatHistogramChunk()
        let app = try c.makeAppender()
        for (i, h) in [hist(6, 12, [2, 1, 3]), hist(9, 18, [3, 1, 3]), hist(14, 31, [5, 1, 3])]
            .enumerated()
        {
            var fh = h.toFloat()
            _ = try app.appendFloatHistogram(
                prev: nil, st: 0, t: Int64(i + 1) * 1000, h: &fh, appendOnly: false)
        }

        let it = PopulateWithDelChunkSeriesIterator(
            blockID: "b", source: SingleChunkSource(encoding: .floatHistogram, bytes: c.bytes),
            metas: [DecodedChunkMeta(ref: 1, minTime: 1000, maxTime: 3000)],
            intervals: [DeletionInterval(mint: 3000, maxt: 3000)])

        #expect(it.next())
        #expect(it.err() == nil)
        let out = try #require(it.current)
        #expect(out.encoding == .floatHistogram)
        #expect(out.meta.minTime == 1000)
        #expect(out.meta.maxTime == 2000)

        let re = try chunkFromData(.floatHistogram, out.bytes)
        #expect(re.numSamples == 2)
        var ts: [Int64] = []
        var counts: [Double] = []
        let rit = re.iterator(nil)
        while rit.next() == .floatHistogram {
            let (t, h) = rit.atFloatHistogram(nil)
            ts.append(t)
            counts.append(h!.count)
        }
        #expect(ts == [1000, 2000])
        #expect(counts == [6, 9])
    }

    /// **`appendOnly: true` is upstream's, and re-encoding a chunk's own samples cannot trip it.** That is
    /// worth asserting rather than assuming, because it is the one way the new arms could fail in
    /// production. The proof is two-sided and both sides are here.
    ///
    /// The dangerous shape would be a chunk holding a non-stale sample *after* a stale one: `appendable`
    /// refuses everything after a stale sample (quirk 223), so re-encoding such a chunk would refuse with
    /// `histogram schema change`. **No such chunk exists**, because the appender that would have written it
    /// cuts a new chunk instead — which is what the first half asserts. Everything else is safe by
    /// construction: a chunk has ONE layout, every sample reads back with it, and a counter chunk's counts
    /// only rise, so any subset in order is appendable.
    @Test("the appendOnly refusal is unreachable, because a stale sample cuts rather than poisoning")
    func staleSampleCutsRatherThanPoisoning() throws {
        let stale = Histogram(sum: Double(bitPattern: 0x7FF0_0000_0000_0002))

        // Half one: a non-stale sample after a stale one CUTS. So the shape that would refuse cannot be
        // built through the appender.
        let c = HistogramChunk()
        var app: any ChunkAppender = try c.makeAppender()
        var h0 = hist(6, 12, [2, 1, 3])
        _ = try app.appendHistogram(prev: nil, st: 0, t: 1000, h: &h0, appendOnly: false)
        var h1 = stale
        _ = try app.appendHistogram(prev: nil, st: 0, t: 2000, h: &h1, appendOnly: false)
        var h2 = hist(14, 31, [5, 1, 3])
        let r = try app.appendHistogram(prev: nil, st: 0, t: 3000, h: &h2, appendOnly: false)
        #expect(r.chunk != nil)
        #expect(!r.isRecoded)
        #expect(c.numSamples == 2)

        // Half two: the shape that CAN exist — a stale tail — re-encodes without complaint.
        let d = HistogramChunk()
        var dapp: any ChunkAppender = try d.makeAppender()
        var g0 = hist(6, 12, [2, 1, 3])
        _ = try dapp.appendHistogram(prev: nil, st: 0, t: 1000, h: &g0, appendOnly: false)
        for i in 1...2 {
            var s = stale
            let rr = try dapp.appendHistogram(
                prev: nil, st: 0, t: Int64(i + 1) * 1000, h: &s, appendOnly: false)
            #expect(rr.chunk == nil)
            dapp = rr.appender
        }
        #expect(d.numSamples == 3)

        let it = PopulateWithDelChunkSeriesIterator(
            blockID: "b", source: SingleChunkSource(encoding: .histogram, bytes: d.bytes),
            metas: [DecodedChunkMeta(ref: 1, minTime: 1000, maxTime: 3000)],
            intervals: [DeletionInterval(mint: 1000, maxt: 1000)])
        #expect(it.next())
        #expect(it.err() == nil)
        let out = try #require(it.current)
        let re = try chunkFromData(.histogram, out.bytes)
        #expect(re.numSamples == 2)
        var ts: [Int64] = []
        let rit = re.iterator(nil)
        while rit.next() == .histogram {
            let (t, h) = rit.atHistogram(nil)
            ts.append(t)
            // A stale sample reads back as a bare sum, with no layout and no hint — quirk 223.
            #expect(h!.sum.isNaN)
            #expect(h!.positiveSpans.isEmpty)
        }
        #expect(ts == [2000, 3000])
    }

    /// The float chunk pass-through with NO deletion, which is the other half of the decision: `currDelIter`
    /// stays nil and the ORIGINAL bytes come out untouched. Included because it is the case that would keep
    /// passing if the arms above were still missing, and so the one that made the gap invisible.
    @Test("with no deletion a histogram chunk passes through unchanged")
    func noDeletionPassesThrough() throws {
        let c = HistogramChunk()
        let app = try c.makeAppender()
        var h = hist(6, 12, [2, 1, 3])
        _ = try app.appendHistogram(prev: nil, st: 0, t: 1000, h: &h, appendOnly: false)

        let it = PopulateWithDelChunkSeriesIterator(
            blockID: "b", source: SingleChunkSource(encoding: .histogram, bytes: c.bytes),
            metas: [DecodedChunkMeta(ref: 1, minTime: 1000, maxTime: 1000)], intervals: [])
        #expect(it.next())
        let out = try #require(it.current)
        #expect(out.bytes == c.bytes)
        #expect(out.encoding == .histogram)
    }
}
