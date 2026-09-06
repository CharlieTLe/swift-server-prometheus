//===----------------------------------------------------------------------===//
// The two native-histogram chunk encodings, byte for byte — and with them the encoding half of
// `histogram_meta.go` (`HistogramLayout.swift`), which is unexported upstream and has no other route
// to a corpus.
//
// The fixture is a PROGRAM, not a list of expectations: a series of samples plus directives to cut a
// chunk (which is the only way `AppendHistogram`'s `prev` argument is reached) and to re-derive the
// appender from the chunk's own bytes (which is the only way the replay path is measured). This file
// replays that program through the port and compares everything the oracle recorded — the bytes, the
// counter-reset header, the caller's histogram after each append, four different read-back paths, a
// pass through a reused iterator, `Seek`, and one more append onto the finished bytes.
//
// See `oracle/suites_chunkenc_histogram.go` for the corpus design; the short version is quirk 59's
// rule, applied to `appendable`'s short-circuit order.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import PromHistogram
import Testing

// MARK: - the wire shapes

struct HGCSpan: Codable, Equatable, Sendable {
    var o: Int32
    var l: UInt32
}

struct HGCHist: Codable, Equatable, Sendable {
    var hint: Int
    var schema: Int32
    var zt: String
    var zcount: UInt64
    var count: UInt64
    var sum: String
    var pspans: [HGCSpan]?
    var nspans: [HGCSpan]?
    var pbuckets: [Int64]?
    var nbuckets: [Int64]?
    var custom: [String]?
}

struct HGCFHist: Codable, Equatable, Sendable {
    var hint: Int
    var schema: Int32
    var zt: String
    var zcount: String
    var count: String
    var sum: String
    var pspans: [HGCSpan]?
    var nspans: [HGCSpan]?
    var pbuckets: [String]?
    var nbuckets: [String]?
    var custom: [String]?
}

struct HGCSample: Codable, Equatable, Sendable {
    var t: Int64
    var h: HGCHist?
}

struct HGCFSample: Codable, Equatable, Sendable {
    var t: Int64
    var h: HGCFHist?
}

struct HGCIn: Codable, Sendable {
    var samples: [HGCSample]?
    var fsamples: [HGCFSample]?
    var appendOnly: Bool
    var cutBefore: [Int]?
    var reappendBefore: [Int]?
    var seeks: [Int64]?
}

struct HGCStep: Codable, Equatable, Sendable {
    var err: String
    var recoded: Bool
    var newChunk: Bool
    var bytes: String
    var num: Int
    var crh: Int
    var hAfter: HGCHist?
    var fhAfter: HGCFHist?
}

struct HGCChunkOut: Codable, Equatable, Sendable {
    var bytes: String
    var num: Int
    var crh: Int
    var samples: [HGCSample]
    var rsamples: [HGCSample]
    var fsamples: [HGCFSample]
    var rfsamples: [HGCFSample]
    var resetTs: [Int64]
    /// `atT()` BEFORE the first `next()`, on a fresh iterator and on a reset one. Upstream calls this
    /// unspecified, and it is the only place the two constructors' asymmetry is visible: the
    /// initialiser starts `t` at `Int64.min` and `reset` starts it at 0.
    var preT: Int64
    var resetPreT: Int64
    var err: String
    var replayBytes: String
    var replayNum: Int
    var replayNew: Bool
    var replayErr: String
}

struct HGCOut: Codable, Equatable, Sendable {
    var steps: [HGCStep]
    var chunks: [HGCChunkOut]
    var seekTypes: [Int]
    var seekTs: [Int64]
}

// MARK: - conversions

private func hgcBits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hgcHex(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }
private func hgcHex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

private func hgcUnhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func hgcSpansIn(_ ss: [HGCSpan]?) -> [Span] {
    (ss ?? []).map { Span(offset: $0.o, length: $0.l) }
}

/// Go marshals a nil slice as `null` and the port has no nil/empty distinction for spans — which
/// costs no fidelity, because every reader of `PositiveSpans` upstream asks `len(...)` or iterates.
private func hgcSpansOut(_ ss: [Span]) -> [HGCSpan]? {
    ss.isEmpty ? nil : ss.map { HGCSpan(o: $0.offset, l: $0.length) }
}

private func hgcFloatsIn(_ ss: [String]?) -> [Double]? {
    guard let ss, !ss.isEmpty else { return nil }
    return ss.map(hgcBits)
}

private func hgcFloatsOut(_ fs: [Double]?) -> [String]? {
    guard let fs, !fs.isEmpty else { return nil }
    return fs.map(hgcHex)
}

private func hgcHistIn(_ s: HGCHist?) -> Histogram? {
    guard let s else { return nil }
    return Histogram(
        counterResetHint: CounterResetHint(rawValue: UInt8(s.hint))!,
        schema: s.schema,
        zeroThreshold: hgcBits(s.zt),
        zeroCount: s.zcount,
        count: s.count,
        sum: hgcBits(s.sum),
        positiveSpans: hgcSpansIn(s.pspans),
        negativeSpans: hgcSpansIn(s.nspans),
        positiveBuckets: s.pbuckets ?? [],
        negativeBuckets: s.nbuckets ?? [],
        customValues: hgcFloatsIn(s.custom))
}

private func hgcHistOut(_ h: Histogram?) -> HGCHist? {
    guard let h else { return nil }
    return HGCHist(
        hint: Int(h.counterResetHint.rawValue), schema: h.schema, zt: hgcHex(h.zeroThreshold),
        zcount: h.zeroCount, count: h.count, sum: hgcHex(h.sum),
        pspans: hgcSpansOut(h.positiveSpans), nspans: hgcSpansOut(h.negativeSpans),
        pbuckets: h.positiveBuckets.isEmpty ? nil : h.positiveBuckets,
        nbuckets: h.negativeBuckets.isEmpty ? nil : h.negativeBuckets,
        custom: hgcFloatsOut(h.customValues))
}

private func hgcFHistIn(_ s: HGCFHist?) -> FloatHistogram? {
    guard let s else { return nil }
    return FloatHistogram(
        counterResetHint: CounterResetHint(rawValue: UInt8(s.hint))!,
        schema: s.schema,
        zeroThreshold: hgcBits(s.zt),
        zeroCount: hgcBits(s.zcount),
        count: hgcBits(s.count),
        sum: hgcBits(s.sum),
        positiveSpans: hgcSpansIn(s.pspans),
        negativeSpans: hgcSpansIn(s.nspans),
        positiveBuckets: hgcFloatsIn(s.pbuckets) ?? [],
        negativeBuckets: hgcFloatsIn(s.nbuckets) ?? [],
        customValues: hgcFloatsIn(s.custom))
}

private func hgcFHistOut(_ h: FloatHistogram?) -> HGCFHist? {
    guard let h else { return nil }
    return HGCFHist(
        hint: Int(h.counterResetHint.rawValue), schema: h.schema, zt: hgcHex(h.zeroThreshold),
        zcount: hgcHex(h.zeroCount), count: hgcHex(h.count), sum: hgcHex(h.sum),
        pspans: hgcSpansOut(h.positiveSpans), nspans: hgcSpansOut(h.negativeSpans),
        pbuckets: hgcFloatsOut(h.positiveBuckets), nbuckets: hgcFloatsOut(h.negativeBuckets),
        custom: hgcFloatsOut(h.customValues))
}

private func hgcErr(_ e: (any Error)?) -> String {
    guard let e else { return "" }
    return String(describing: e)
}

// MARK: - the integer driver

private func hgcReadInt(_ c: HistogramChunk) -> HGCChunkOut {
    var out = HGCChunkOut(
        bytes: hgcHex(c.bytes), num: c.numSamples, crh: Int(c.counterResetHeader.rawValue),
        samples: [], rsamples: [], fsamples: [], rfsamples: [], resetTs: [], preT: 0,
        resetPreT: 0, err: "", replayBytes: "", replayNum: 0, replayNew: false, replayErr: "")

    let it = c.iterator(nil)
    while it.next() == .histogram {
        let (t, h) = it.atHistogram(nil)
        out.samples.append(HGCSample(t: t, h: hgcHistOut(h)))
    }
    out.err = hgcErr(it.err())

    // The reuse buffer, carried across the whole loop the way a real caller does. Go returns the
    // buffer it was handed (mutated in place) on every non-stale sample and a fresh object on a stale
    // one; carrying the returned value either way is equivalent, because the non-stale path
    // overwrites every field.
    var reuse = Histogram()
    let it2 = c.iterator(nil)
    while it2.next() == .histogram {
        let (t, h) = it2.atHistogram(reuse)
        out.rsamples.append(HGCSample(t: t, h: hgcHistOut(h)))
        if let h { reuse = h }
    }

    let it3 = c.iterator(nil)
    while it3.next() == .histogram {
        let (t, fh) = it3.atFloatHistogram(nil)
        out.fsamples.append(HGCFSample(t: t, h: hgcFHistOut(fh)))
    }

    var freuse = FloatHistogram()
    let it4 = c.iterator(nil)
    while it4.next() == .histogram {
        let (t, fh) = it4.atFloatHistogram(freuse)
        out.rfsamples.append(HGCFSample(t: t, h: hgcFHistOut(fh)))
        if let fh { freuse = fh }
    }

    out.preT = c.iterator(nil).atT()

    // Hand the exhausted iterator back: the only route to `Reset`.
    let it5 = c.iterator(it4)
    out.resetPreT = it5.atT()
    while it5.next() == .histogram {
        out.resetTs.append(it5.atT())
    }
    return out
}

private func hgcReplayInt(_ bytes: [UInt8], _ last: Histogram, _ lastT: Int64) throws -> (
    String, Int, Bool, String
) {
    let c2 = try chunkFromData(.histogram, bytes)
    let app: any ChunkAppender
    do {
        app = try c2.makeAppender()
    } catch {
        return ("", 0, false, hgcErr(error))
    }
    var h = last.copy()
    do {
        let r = try app.appendHistogram(prev: nil, st: 0, t: lastT + 1000, h: &h, appendOnly: false)
        return (hgcHex(c2.bytes), c2.numSamples, r.chunk != nil, "")
    } catch {
        return (hgcHex(c2.bytes), c2.numSamples, false, hgcErr(error))
    }
}

private func hgcRunInt(_ input: HGCIn) throws -> HGCOut {
    var out = HGCOut(steps: [], chunks: [], seekTypes: [], seekTs: [])

    var c = HistogramChunk()
    var app: any ChunkAppender = try c.makeAppender()
    var prevApp: (any ChunkAppender)?
    var finished: [HistogramChunk] = []
    var lastH: Histogram?
    var lastT: Int64 = 0

    let cutBefore = Set(input.cutBefore ?? [])
    let reappendBefore = Set(input.reappendBefore ?? [])

    for (i, s) in (input.samples ?? []).enumerated() {
        if cutBefore.contains(i) {
            finished.append(c)
            prevApp = app
            c = HistogramChunk()
            app = try c.makeAppender()
        }
        if reappendBefore.contains(i) {
            app = try c.makeAppender()
        }

        var h = hgcHistIn(s.h)!
        var errText = ""
        var recoded = false
        var newChunkPresent = false
        do {
            let r = try app.appendHistogram(
                prev: prevApp, st: 0, t: s.t, h: &h, appendOnly: input.appendOnly)
            recoded = r.isRecoded
            newChunkPresent = r.chunk != nil
            app = r.appender
            if let nc = r.chunk as? HistogramChunk {
                if !recoded {
                    finished.append(c)
                }
                c = nc
            }
            lastH = h
            lastT = s.t
        } catch {
            errText = hgcErr(error)
        }
        prevApp = nil

        out.steps.append(
            HGCStep(
                err: errText, recoded: recoded, newChunk: newChunkPresent, bytes: hgcHex(c.bytes),
                num: c.numSamples, crh: Int(c.counterResetHeader.rawValue), hAfter: hgcHistOut(h),
                fhAfter: nil))
    }
    finished.append(c)

    for fc in finished {
        var co = hgcReadInt(fc)
        // `Compact` must not change the bytes; the assertion is that this line is here.
        fc.compact()
        co.bytes = hgcHex(fc.bytes)
        if let lastH, fc.numSamples > 0 {
            (co.replayBytes, co.replayNum, co.replayNew, co.replayErr) =
                try hgcReplayInt(fc.bytes, lastH, lastT)
        }
        out.chunks.append(co)
    }

    if let seeks = input.seeks, !seeks.isEmpty {
        let last = finished[finished.count - 1]
        for target in seeks {
            let it = last.iterator(nil)
            let vt = it.seek(target)
            out.seekTypes.append(Int(vt.rawValue))
            out.seekTs.append(vt == .none ? Int64.min : it.atT())
        }
    }
    return out
}

// MARK: - the float driver

private func hgcReadFloat(_ c: FloatHistogramChunk) -> HGCChunkOut {
    var out = HGCChunkOut(
        bytes: hgcHex(c.bytes), num: c.numSamples, crh: Int(c.counterResetHeader.rawValue),
        samples: [], rsamples: [], fsamples: [], rfsamples: [], resetTs: [], preT: 0,
        resetPreT: 0, err: "", replayBytes: "", replayNum: 0, replayNew: false, replayErr: "")

    let it = c.iterator(nil)
    while it.next() == .floatHistogram {
        let (t, fh) = it.atFloatHistogram(nil)
        out.fsamples.append(HGCFSample(t: t, h: hgcFHistOut(fh)))
    }
    out.err = hgcErr(it.err())

    var freuse = FloatHistogram()
    let it2 = c.iterator(nil)
    while it2.next() == .floatHistogram {
        let (t, fh) = it2.atFloatHistogram(freuse)
        out.rfsamples.append(HGCFSample(t: t, h: hgcFHistOut(fh)))
        if let fh { freuse = fh }
    }

    out.preT = c.iterator(nil).atT()

    let it3 = c.iterator(it2)
    out.resetPreT = it3.atT()
    while it3.next() == .floatHistogram {
        out.resetTs.append(it3.atT())
    }
    return out
}

private func hgcReplayFloat(_ bytes: [UInt8], _ last: FloatHistogram, _ lastT: Int64) throws -> (
    String, Int, Bool, String
) {
    let c2 = try chunkFromData(.floatHistogram, bytes)
    let app: any ChunkAppender
    do {
        app = try c2.makeAppender()
    } catch {
        return ("", 0, false, hgcErr(error))
    }
    var h = last.copy()
    do {
        let r = try app.appendFloatHistogram(
            prev: nil, st: 0, t: lastT + 1000, h: &h, appendOnly: false)
        return (hgcHex(c2.bytes), c2.numSamples, r.chunk != nil, "")
    } catch {
        return (hgcHex(c2.bytes), c2.numSamples, false, hgcErr(error))
    }
}

private func hgcRunFloat(_ input: HGCIn) throws -> HGCOut {
    var out = HGCOut(steps: [], chunks: [], seekTypes: [], seekTs: [])

    var c = FloatHistogramChunk()
    var app: any ChunkAppender = try c.makeAppender()
    var prevApp: (any ChunkAppender)?
    var finished: [FloatHistogramChunk] = []
    var lastH: FloatHistogram?
    var lastT: Int64 = 0

    let cutBefore = Set(input.cutBefore ?? [])
    let reappendBefore = Set(input.reappendBefore ?? [])

    for (i, s) in (input.fsamples ?? []).enumerated() {
        if cutBefore.contains(i) {
            finished.append(c)
            prevApp = app
            c = FloatHistogramChunk()
            app = try c.makeAppender()
        }
        if reappendBefore.contains(i) {
            app = try c.makeAppender()
        }

        var h = hgcFHistIn(s.h)!
        var errText = ""
        var recoded = false
        var newChunkPresent = false
        do {
            let r = try app.appendFloatHistogram(
                prev: prevApp, st: 0, t: s.t, h: &h, appendOnly: input.appendOnly)
            recoded = r.isRecoded
            newChunkPresent = r.chunk != nil
            app = r.appender
            if let nc = r.chunk as? FloatHistogramChunk {
                if !recoded {
                    finished.append(c)
                }
                c = nc
            }
            lastH = h
            lastT = s.t
        } catch {
            errText = hgcErr(error)
        }
        prevApp = nil

        out.steps.append(
            HGCStep(
                err: errText, recoded: recoded, newChunk: newChunkPresent, bytes: hgcHex(c.bytes),
                num: c.numSamples, crh: Int(c.counterResetHeader.rawValue), hAfter: nil,
                fhAfter: hgcFHistOut(h)))
    }
    finished.append(c)

    for fc in finished {
        var co = hgcReadFloat(fc)
        fc.compact()
        co.bytes = hgcHex(fc.bytes)
        if let lastH, fc.numSamples > 0 {
            (co.replayBytes, co.replayNum, co.replayNew, co.replayErr) =
                try hgcReplayFloat(fc.bytes, lastH, lastT)
        }
        out.chunks.append(co)
    }

    if let seeks = input.seeks, !seeks.isEmpty {
        let last = finished[finished.count - 1]
        for target in seeks {
            let it = last.iterator(nil)
            let vt = it.seek(target)
            out.seekTypes.append(Int(vt.rawValue))
            out.seekTs.append(vt == .none ? Int64.min : it.atT())
        }
    }
    return out
}

// MARK: - the suites

@Suite("chunkenc: the integer histogram chunk")
struct HistogramChunkTests {
    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("chunkenc/histogram.jsonl", FixtureCase<HGCIn, HGCOut>.self) { input in
            try hgcRunInt(input)
        }
    }
}

@Suite("chunkenc: the float histogram chunk")
struct FloatHistogramChunkTests {
    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("chunkenc/float-histogram.jsonl", FixtureCase<HGCIn, HGCOut>.self) {
            input in
            try hgcRunFloat(input)
        }
    }
}

// MARK: - what the corpus cannot reach

@Suite("chunkenc: histogram chunk edges the corpus cannot drive")
struct HistogramChunkEdgeTests {
    /// The six cross-type refusal strings. Go PANICS on all of them and every one is unreachable by
    /// contract — `appendPreprocessor` cuts a new chunk on an encoding change — so four raise with
    /// Go's exact text (exception 9's treatment) and the two `Append(st, t, v)` arms, which cannot
    /// throw, keep the message in a `preconditionFailure`. The four texts are asserted here because
    /// no corpus case can produce them: the oracle would have to panic to generate one.
    @Test("the cross-type appends carry Go's exact panic strings")
    func crossTypeMessages() throws {
        #expect(
            FloatChunkAppenderError.floatHistogramToHistogramChunk.description
                == "appended a float histogram sample to a histogram chunk")
        #expect(
            FloatChunkAppenderError.histogramToFloatHistogramChunk.description
                == "appended a histogram sample to a float histogram chunk")

        let hc = HistogramChunk()
        let ha = try hc.makeAppender()
        var fh = FloatHistogram()
        #expect(throws: FloatChunkAppenderError.floatHistogramToHistogramChunk) {
            _ = try ha.appendFloatHistogram(prev: nil, st: 0, t: 1, h: &fh, appendOnly: false)
        }

        let fc = FloatHistogramChunk()
        let fa = try fc.makeAppender()
        var h = Histogram()
        #expect(throws: FloatChunkAppenderError.histogramToFloatHistogramChunk) {
            _ = try fa.appendHistogram(prev: nil, st: 0, t: 1, h: &h, appendOnly: false)
        }
    }

    /// The `appendOnly` error texts, including the two `fmt.Errorf` ones whose insert counts are
    /// interpolated. The corpus drives four of the six; the two *backward* messages exist only on the
    /// gauge path and the float wording differs only by a prefix, so all eight spellings are checked
    /// here directly.
    @Test("the appendOnly refusals reproduce Go's messages")
    func appendOnlyMessages() {
        #expect(HistogramAppendError.counterReset.description == "histogram counter reset")
        #expect(HistogramAppendError.schemaChange.description == "histogram schema change")
        #expect(
            HistogramAppendError.gaugeSchemaChange.description == "gauge histogram schema change")
        #expect(
            HistogramAppendError.floatCounterReset.description == "float histogram counter reset")
        #expect(
            HistogramAppendError.floatSchemaChange.description == "float histogram schema change")
        #expect(
            HistogramAppendError.floatGaugeSchemaChange.description
                == "float gauge histogram schema change")
        #expect(
            HistogramAppendError.layoutChange(
                gauge: false, float: false, direction: .forward, positive: 1, negative: 0
            ).description
                == "histogram layout change with 1 positive and 0 negative forwards inserts")
        #expect(
            HistogramAppendError.layoutChange(
                gauge: true, float: false, direction: .backward, positive: 2, negative: 3
            ).description
                == "gauge histogram layout change with 2 positive and 3 negative backwards inserts")
        #expect(
            HistogramAppendError.layoutChange(
                gauge: false, float: true, direction: .forward, positive: 0, negative: 1
            ).description
                == "float histogram layout change with 0 positive and 1 negative forwards inserts")
        #expect(
            HistogramAppendError.layoutChange(
                gauge: true, float: true, direction: .backward, positive: 1, negative: 1
            ).description
                == "float gauge histogram layout change with 1 positive and 1 negative backwards inserts"
        )
    }

    /// A chunk whose layout says one schema and whose schema is not a known one. The reader rejects
    /// it with `histogram.UnknownSchemaError`, and the corpus cannot produce the bytes because the
    /// appender writes whatever schema it is given and the oracle would have to build a chunk by hand
    /// — which is what §6w's harness lesson forbids. So the bytes are built here from a chunk the
    /// port itself wrote, with the schema varbit rewritten.
    @Test("an unknown schema is rejected on the first read")
    func unknownSchemaIsRejected() throws {
        // Schema 53 is one past `ExponentialSchemaMaxReserved`.
        let c = HistogramChunk()
        let app = try c.appender()
        var h = Histogram(
            schema: 53, zeroThreshold: 0, count: 3, sum: 6,
            positiveSpans: [Span(offset: 0, length: 1)], positiveBuckets: [3])
        _ = try app.appendHistogram(prev: nil, st: 0, t: 1000, h: &h, appendOnly: false)

        let it = c.iterator(nil)
        #expect(it.next() == ValueType.none)
        #expect(hgcErr(it.err()).contains("unknown schema"))
    }

    /// `Compact` is a no-op in the port because Swift's `Array` has no observable capacity. The
    /// contract that matters is that it never changes what `Bytes()` returns, which is asserted here
    /// on both chunk types as well as in every corpus case.
    @Test("compact never changes the bytes")
    func compactIsTransparent() throws {
        let c = HistogramChunk()
        let app = try c.appender()
        var h = Histogram(
            count: 3, sum: 6, positiveSpans: [Span(offset: 0, length: 1)], positiveBuckets: [3])
        _ = try app.appendHistogram(prev: nil, st: 0, t: 1000, h: &h, appendOnly: false)
        let before = c.bytes
        c.compact()
        #expect(c.bytes == before)

        let fc = FloatHistogramChunk()
        let fapp = try fc.appender()
        var fh = FloatHistogram(
            count: 3, sum: 6, positiveSpans: [Span(offset: 0, length: 1)], positiveBuckets: [3])
        _ = try fapp.appendFloatHistogram(prev: nil, st: 0, t: 1000, h: &fh, appendOnly: false)
        let fbefore = fc.bytes
        fc.compact()
        #expect(fc.bytes == fbefore)
    }

    /// `CounterResetHintToHeader`, which has no other caller in the port yet — the Head's histogram
    /// append path is the one that will use it.
    @Test("the hint-to-header table")
    func hintToHeader() {
        #expect(counterResetHintToHeader(.counterReset) == .counterReset)
        #expect(counterResetHintToHeader(.notCounterReset) == .notCounterReset)
        #expect(counterResetHintToHeader(.gaugeType) == .gaugeType)
        #expect(counterResetHintToHeader(.unknownCounterReset) == .unknownCounterReset)
    }
}
