//===----------------------------------------------------------------------------------------------===//
// The `chunkenc` protocol conformances added by §7f(c).
//
// Three protocols had drifted from their concrete types — `Chunk` had no conforming type at all — and the Head
// is the first caller that needs `any Chunk`. These assert the parts of the reconciliation that are
// BEHAVIOUR rather than shape: what `XORAppender` does with a start timestamp, what the histogram arms answer,
// and which encodings `newEmptyChunk` can build.
//
// The two float ENCODINGS themselves are already pinned differentially by `chunkenc/xor` and `chunkenc/xor2`;
// nothing here re-tests them.
//===----------------------------------------------------------------------------------------------===//

import PromHistogram
import Testing

@testable import PromChunkEnc

@Suite("chunkenc: the Chunk/ChunkAppender/ChunkIterable conformances")
struct ChunkConformanceTests {

    /// **`XORAppender` discards the start timestamp, and that is faithful.** Upstream's
    /// `xorAppender.Append(_, t int64, v float64)` names the parameter `_`, because ST rides on XOR2 and not
    /// XOR (quirk 36). So appending through the three-argument protocol method with a wild `st` must produce
    /// byte-identical output to the two-argument concrete one.
    @Test("the XOR appender ignores st, byte for byte")
    func xorDiscardsStartTimestamp() throws {
        let viaProtocol = XORChunk()
        let a1: any ChunkAppender = try viaProtocol.makeAppender()
        a1.append(999_999, 100, 1.5)
        a1.append(-42, 200, 2.5)

        let viaConcrete = XORChunk()
        let a2 = try viaConcrete.appender()
        a2.append(100, 1.5)
        a2.append(200, 2.5)

        #expect(viaProtocol.bytes == viaConcrete.bytes)
        #expect(viaProtocol.numSamples == 2)
    }

    /// XOR2 by contrast **uses** `st`, so two appends differing only in it must produce different bytes. That
    /// is the other half of quirk 36 and the reason the protocol carries three arguments at all.
    @Test("the XOR2 appender uses st, unlike XOR")
    func xor2UsesStartTimestamp() throws {
        let a = XOR2Chunk()
        let aa: any ChunkAppender = try a.makeAppender()
        aa.append(50, 100, 1.5)

        let b = XOR2Chunk()
        let ba: any ChunkAppender = try b.makeAppender()
        ba.append(60, 100, 1.5)

        #expect(a.bytes != b.bytes)

        // And the same st really is the same bytes, so the difference above is st and not noise.
        let c = XOR2Chunk()
        let ca: any ChunkAppender = try c.makeAppender()
        ca.append(50, 100, 1.5)
        #expect(a.bytes == c.bytes)
    }

    /// Go's float appenders **panic** on a histogram: `"appended a histogram sample to a float chunk"` and
    /// `"appended a float histogram sample to a float chunk"`. Unreachable by contract, because
    /// `appendPreprocessor` cuts a new chunk when the encoding changes — so the port raises with Go's exact
    /// text (exception 9's treatment) rather than trapping.
    @Test("appending a histogram to a float chunk is refused with Go's message")
    func histogramToFloatChunkIsRefused() throws {
        for chunk in [XORChunk() as any Chunk, XOR2Chunk() as any Chunk] {
            let app = try chunk.makeAppender()
            #expect(throws: FloatChunkAppenderError.histogramToFloatChunk) {
                _ = try app.appendHistogram(
                    prev: nil, st: 0, t: 1, h: Histogram(), appendOnly: false)
            }
            #expect(throws: FloatChunkAppenderError.floatHistogramToFloatChunk) {
                _ = try app.appendFloatHistogram(
                    prev: nil, st: 0, t: 1, h: FloatHistogram(), appendOnly: false)
            }
        }
        #expect(
            FloatChunkAppenderError.histogramToFloatChunk.description
                == "appended a histogram sample to a float chunk")
        #expect(
            FloatChunkAppenderError.floatHistogramToFloatChunk.description
                == "appended a float histogram sample to a float chunk")
    }

    /// `newEmptyChunk` answers for the two float encodings and reports the rest **by name** rather than
    /// silently substituting XOR. The histogram chunk encodings are genuinely not ported yet.
    @Test("newEmptyChunk builds the float encodings and names the rest")
    func newEmptyChunkCoverage() throws {
        #expect(try newEmptyChunk(.xor).encoding == .xor)
        #expect(try newEmptyChunk(.xor2).encoding == .xor2)
        #expect(try newEmptyChunk(.xor).numSamples == 0)

        for missing in [Encoding.histogram, .floatHistogram] {
            #expect(throws: NewEmptyChunkError.unsupportedEncoding(missing)) {
                _ = try newEmptyChunk(missing)
            }
        }
        // `.none` is not a valid encoding at all — `Encoding.isValid` says so, and `cutNewHeadChunk` checks
        // that first and falls back to an XOR chunk rather than calling this.
        #expect(!Encoding.none.isValid)
        #expect(Encoding.xor.isValid && Encoding.xor2.isValid)
        #expect(throws: NewEmptyChunkError.unsupportedEncoding(Encoding.none)) {
            _ = try newEmptyChunk(.none)
        }
    }

    /// The boxed iterator forwards, and its histogram accessors answer `(Int64.min, nil)` — the pairing Go's
    /// `nopIterator` uses for "not a histogram", and what the two hand-written boxes it replaced already did.
    @Test("the boxed float iterator forwards and reports no histogram")
    func boxedIteratorForwards() throws {
        let c = XORChunk()
        let app = try c.appender()
        app.append(100, 1.5)
        app.append(200, 2.5)

        let it = c.iterator(nil)
        #expect(it.next() == .float)
        #expect(it.at() == (100, 1.5))
        #expect(it.atT() == 100)
        // XOR carries no start timestamp, so `atST` is 0 — the protocol's "unset".
        #expect(it.atST() == 0)
        #expect(it.next() == .float)
        #expect(it.at() == (200, 2.5))
        #expect(it.next() == ValueType.none)
        #expect(it.err() == nil)

        let fresh = c.iterator(nil)
        #expect(fresh.atHistogram(nil).0 == Int64.min)
        #expect(fresh.atHistogram(nil).1 == nil)
        #expect(fresh.atFloatHistogram(nil).0 == Int64.min)
        #expect(fresh.atFloatHistogram(nil).1 == nil)
    }

    /// A chunk reached through `any Chunk` round-trips its bytes, which is what `memSeries` will do: cut a
    /// chunk polymorphically, append, then hand the bytes to the disk mapper.
    @Test("a chunk behind the existential round-trips through reset")
    func existentialRoundTrip() throws {
        for enc in [Encoding.xor, .xor2] {
            let src: any Chunk = try newEmptyChunk(enc)
            let app = try src.makeAppender()
            app.append(0, 10, 1.0)
            app.append(0, 20, 2.0)
            let bytes = src.bytes

            let dst: any Chunk = try newEmptyChunk(enc)
            dst.reset(bytes)
            #expect(dst.numSamples == 2)
            #expect(dst.bytes == bytes)

            var got: [(Int64, Double)] = []
            let it = dst.iterator(nil)
            while it.next() == .float { got.append(it.at()) }
            #expect(got.map(\.0) == [10, 20])
            #expect(got.map(\.1) == [1.0, 2.0])
        }
    }
}
