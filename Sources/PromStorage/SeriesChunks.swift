//===----------------------------------------------------------------------===//
// Ported from storage/series.go @ v3.13.2 — the CHUNK half, deferred by
// Series.swift's header to "Phase 6, with the chunk encodings they need".
//
// It arrives now because `NewCompactingChunkSeriesMerger` is built out of it:
// compacting an overlap means DECODING each overlapping chunk into a `Series`
// (`newChunkToSeriesDecoder`), running the vertical sample merge over them, and
// RE-ENCODING the result (`NewSeriesToChunkEncoder`). Nothing else in merge.go
// needs it and nothing here needs merge.go, so it is its own file.
//
// ## What is here
//
//   `ChunkSeriesEntry`            a ChunkSeries whose iterator comes from a closure
//   `listChunkSeriesIterator`     iterate a known list of metas
//   `errChunksIterator`           the empty iterator that reports one error
//   `newChunkToSeriesDecoder`     one chunk, presented as a Series
//   `seriesToChunkEncoder`        a Series, re-encoded into 120-sample chunks
//
// ## What is NOT, and why
//
//   - `NewListChunkSeriesFromSamples` needs `chunks.ChunkFromSamples`, which is
//     a test helper with no production caller.
//   - `chunkSetToSeriesSet` / `seriesSetToChunkSet` are the remote-read path's
//     (Phase 10). `chunkSetToSeriesSet.At()` calls `ChainedSeriesMerge`, so it
//     is *cheap* now — but adding a public type with no caller is how a port
//     accumulates untested surface.
//   - The HISTOGRAM arms of `seriesToChunkEncoder.Iterator` throw. `PromChunkEnc`
//     has no `HistogramChunk`/`FloatHistogramChunk` yet (see `newEmptyChunk`), so
//     `ValueType.histogram.newChunk(...)` cannot produce one. This is the
//     existing §7f gap surfacing, not a new one: the arms are written out in
//     full so that porting the encodings is the only thing left to do.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
internal import PromHistogram
public import PromLabels

/// Go: `ChunkSeriesEntry`.
public final class ChunkSeriesEntry: ChunkSeries {
    public var lset: Labels
    public var chunkIteratorFn: ((any ChunkMetaIterator)?) -> any ChunkMetaIterator

    public init(
        lset: Labels,
        chunkIteratorFn: @escaping ((any ChunkMetaIterator)?) -> any ChunkMetaIterator
    ) {
        self.lset = lset
        self.chunkIteratorFn = chunkIteratorFn
    }

    public func labels() -> Labels { lset }

    public func iterator(_ reuse: (any ChunkMetaIterator)?) -> any ChunkMetaIterator {
        chunkIteratorFn(reuse)
    }
}

/// Go: `listChunkSeriesIterator`.
public final class ListChunkSeriesIterator: ChunkMetaIterator {
    private var chks: [Meta]
    private var idx: Int

    public init(_ chks: [Meta]) {
        self.chks = chks
        self.idx = -1
    }

    /// Go: `Reset`.
    public func reset(_ chks: [Meta]) {
        self.chks = chks
        self.idx = -1
    }

    /// Go reads `chks[-1]` before the first `Next`, which panics; the
    /// precondition reports the same failure by name.
    public func at() -> Meta {
        precondition(
            idx >= 0 && idx < chks.count,
            "ListChunkSeriesIterator: at() outside the list; Go indexes chks[-1]")
        return chks[idx]
    }

    public func next() -> Bool {
        idx += 1
        return idx < chks.count
    }

    public func err() -> (any Error)? { nil }
}

/// Go: `NewListChunkSeriesIterator`.
public func newListChunkSeriesIterator(_ chks: [Meta]) -> any ChunkMetaIterator {
    ListChunkSeriesIterator(chks)
}

/// Go: `errChunksIterator` — no chunks, one error.
///
/// `At()` returns the ZERO `chunks.Meta`, which has a nil chunk. Reproduced with
/// a meta whose bounds are 0/0 and whose chunk is nil, because a caller that
/// reads `At()` without checking `Next()` gets Go's zero value rather than a
/// trap.
public final class ErrChunksIterator: ChunkMetaIterator {
    private let error: any Error

    public init(_ error: any Error) { self.error = error }

    public func at() -> Meta { Meta(minTime: 0, maxTime: 0) }
    public func next() -> Bool { false }
    public func err() -> (any Error)? { error }
}

/// Go: `newChunkToSeriesDecoder` — one chunk, seen as a `Series`.
///
/// The labels are the caller's; `compactChunkIterator` passes
/// `labels.EmptyLabels()` because it is already working within one series.
public func newChunkToSeriesDecoder(_ lset: Labels, _ chk: Meta) -> any Series {
    SeriesEntry(lset: lset) { it in
        guard let chunk = chk.chunk else {
            // Go dereferences `chk.Chunk.Iterator(it)` and panics on a nil chunk.
            // Every caller in this package fills it in first.
            preconditionFailure("newChunkToSeriesDecoder: meta has no chunk; Go dereferences nil")
        }
        return chunk.iterator(it)
    }
}

/// Go: `seriesToChunkEncoderSplit`.
public let seriesToChunkEncoderSplit = 120

/// Go: `fmt.Errorf("unknown sample type %s", typ.String())` plus the two
/// encoding failures the port can hit where Go cannot.
public enum SeriesToChunkEncoderError: Error, CustomStringConvertible {
    case unknownSampleType(ValueType)
    case newChunk(any Error)
    case appender(any Error)
    case appendHistogram(any Error)

    public var description: String {
        switch self {
        case .unknownSampleType(let t): return "unknown sample type \(t)"
        case .newChunk(let e): return String(describing: e)
        case .appender(let e): return String(describing: e)
        case .appendHistogram(let e): return String(describing: e)
        }
    }
}

/// Go: `seriesToChunkEncoder` / `NewSeriesToChunkEncoder`.
///
/// Re-encodes a series' samples into chunks of at most 120 samples, cutting also
/// whenever the sample TYPE changes or whenever the presence of a start
/// timestamp changes.
public final class SeriesToChunkEncoder: ChunkSeries {
    private let series: any Series

    public init(_ series: any Series) { self.series = series }

    public func labels() -> Labels { series.labels() }

    /// Go: `Iterator`.
    ///
    /// Two details that a rewrite loses:
    ///
    ///   - `maxt` is deliberately NOT reset when a chunk is cut. Upstream says so
    ///     in a comment repeated three times: "maxt is immediately overwritten
    ///     below which is why setting it here won't make a difference." `mint`
    ///     IS reset, to `MaxInt64`, and that sentinel is how the first sample of
    ///     a chunk is recognised.
    ///   - a histogram append that returns a new chunk WITHOUT recoding cuts the
    ///     current chunk; one that recodes replaces it in place and does not.
    public func iterator(_ reuse: (any ChunkMetaIterator)?) -> any ChunkMetaIterator {
        var chk: (any Chunk)?
        var app: (any ChunkAppender)?
        var mint = Int64.max
        var maxt = Int64.min

        var chks: [Meta] = []
        let existing = reuse as? ListChunkSeriesIterator

        var i = 0
        let seriesIter = series.iterator(nil)
        var lastType = ValueType.none
        var lastHadST = false

        var typ = seriesIter.next()
        while typ != .none {
            let st = seriesIter.atST()
            let hasST = st != 0
            if typ != lastType || lastHadST != hasST || i >= seriesToChunkEncoderSplit {
                chks = appendChunk(chks, mint, maxt, chk)
                do {
                    chk = try newEmptyChunk(typ.chunkEncoding(useXOR2: hasST))
                } catch {
                    return ErrChunksIterator(SeriesToChunkEncoderError.newChunk(error))
                }
                do {
                    app = try chk?.makeAppender()
                } catch {
                    return ErrChunksIterator(SeriesToChunkEncoderError.appender(error))
                }
                mint = Int64.max
                // maxt is NOT reset — see the doc comment.
                i = 0
            }
            lastType = typ
            lastHadST = hasST

            var t: Int64 = 0
            switch typ {
            case .float:
                let (ts, v) = seriesIter.at()
                t = ts
                app?.append(st, ts, v)
            case .histogram:
                let (ts, h) = seriesIter.atHistogram(nil)
                t = ts
                guard let h else {
                    return ErrChunksIterator(SeriesToChunkEncoderError.unknownSampleType(typ))
                }
                do {
                    let (newChk, recoded, newApp) = try app!.appendHistogram(
                        prev: nil, st: st, t: ts, h: h, appendOnly: false)
                    app = newApp
                    if let newChk {
                        if !recoded {
                            chks = appendChunk(chks, mint, maxt, chk)
                            mint = Int64.max
                            i = 0
                        }
                        chk = newChk
                    }
                } catch {
                    return ErrChunksIterator(SeriesToChunkEncoderError.appendHistogram(error))
                }
            case .floatHistogram:
                let (ts, fh) = seriesIter.atFloatHistogram(nil)
                t = ts
                guard let fh else {
                    return ErrChunksIterator(SeriesToChunkEncoderError.unknownSampleType(typ))
                }
                do {
                    let (newChk, recoded, newApp) = try app!.appendFloatHistogram(
                        prev: nil, st: st, t: ts, h: fh, appendOnly: false)
                    app = newApp
                    if let newChk {
                        if !recoded {
                            chks = appendChunk(chks, mint, maxt, chk)
                            mint = Int64.max
                            i = 0
                        }
                        chk = newChk
                    }
                } catch {
                    return ErrChunksIterator(SeriesToChunkEncoderError.appendHistogram(error))
                }
            default:
                return ErrChunksIterator(SeriesToChunkEncoderError.unknownSampleType(typ))
            }

            maxt = t
            if mint == Int64.max {
                mint = t
            }
            i += 1
            typ = seriesIter.next()
        }
        if let e = seriesIter.err() {
            return ErrChunksIterator(e)
        }

        chks = appendChunk(chks, mint, maxt, chk)

        if let existing {
            existing.reset(chks)
            return existing
        }
        return newListChunkSeriesIterator(chks)
    }
}

/// Go: `NewSeriesToChunkEncoder`.
public func newSeriesToChunkEncoder(_ series: any Series) -> any ChunkSeries {
    SeriesToChunkEncoder(series)
}

/// Go: `appendChunk` — a nil chunk appends nothing, which is what makes the
/// unconditional call at the top of the cut branch safe on the first iteration.
func appendChunk(_ chks: [Meta], _ mint: Int64, _ maxt: Int64, _ chk: (any Chunk)?) -> [Meta] {
    guard let chk else { return chks }
    var chks = chks
    chks.append(Meta(chunk: chk, minTime: mint, maxTime: maxt))
    return chks
}
