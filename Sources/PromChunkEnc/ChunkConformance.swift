//===----------------------------------------------------------------------===//
// The conformances that make `chunkenc`'s protocols usable, plus `NewEmptyChunk`.
//
// **Why this file exists at all is worth reading once**, because it is the third instance of one mistake.
// `Chunk`, `ChunkAppender` and `ChunkIterable` were each declared early "so another module can refer to
// them", and the concrete types — `XORChunk`, `XOR2Chunk` and their appenders and iterators — were written
// later and independently. Nothing forces a protocol and its would-be conformers together until some caller
// needs the polymorphism, so all three drifted: `Chunk` had **no conforming type at all**, the appenders had
// a different arity and no histogram methods, and the iterators are `struct`s against an `AnyObject`-bound
// protocol. The Head is the first caller that needs `any Chunk`, which is what surfaced it.
//
// The rule that follows, recorded in HANDOFF §7f(c): **whichever slice adds the first concrete type should be
// the slice that conforms it**, even if no existential is needed yet.
//
// ## Three reconciliations, each a decision
//
//  1. **Member shapes follow the concrete types.** `bytes`, `encoding` and `numSamples` are properties here
//     and methods in Go, because a Go interface has no other option. No fidelity is lost; see `Chunk`'s note.
//  2. **`st` is discarded by XOR and used by XOR2**, exactly as upstream. `xorAppender.Append(_, t, v)` names
//     the parameter `_`; `xor2Appender.Append(st, t, v)` computes an `stDiff` from it. That asymmetry is
//     quirk 36's mechanism, so `XORAppender` gets a three-argument overload that throws `st` away rather than
//     the protocol getting two signatures.
//  3. **Iterators are BOXED, not converted to classes.** `ChunkIterator` is `AnyObject`-bound and the two
//     iterators are value types. Making them classes would change the copy-vs-alias semantics of
//     `iterator(reuse:)`, which PORTING.md §4 records as load-bearing — and `PromQL`'s three reuse call sites
//     depend on it. Phase 6 had already reached this conclusion and written `BoxedXOR` twice (once in
//     `PromBlock`, once in the tests); this file is that adapter promoted, generalised over both iterators,
//     and made public so the duplicates can go.
//===----------------------------------------------------------------------===//

public import PromHistogram

// MARK: - The float iterators, behind one protocol so a single box serves both

/// The shape `XORIterator` and `XOR2Iterator` already share. It exists so `BoxedFloatChunkIterator` can be
/// generic rather than duplicated; it is public only because the box's generic bound needs it to be.
public protocol FloatChunkIteratorValue {
    mutating func next() -> ValueType
    mutating func seek(_ target: Int64) -> ValueType
    var at: (Int64, Double) { get }
    /// Go: `AtST`. **`xorIterator.AtST` returns 0**, which the `ChunkIterator` protocol documents as
    /// "unimplemented/unset" — XOR chunks carry no start timestamp.
    var atST: Int64 { get }
    var err: (any Error)? { get }
}

extension XORIterator: FloatChunkIteratorValue {
    /// Go: `xorIterator` has no `AtST` of its own and the interface's contract is 0.
    public var atST: Int64 { 0 }
}

extension XOR2Iterator: FloatChunkIteratorValue {}

/// A reference box around a value-type float iterator.
///
/// Replaces the two hand-written `BoxedXOR` copies (`PromBlock/PopulateIterators.swift` and
/// `Tests/PromBlockTests/DeletedIteratorTests.swift`) — a second copy of an adapter is how the two drift, the
/// same argument that moved `rleHex` into `GoOracleSupport`.
///
/// The histogram accessors answer `(Int64.min, nil)`, which is the pairing Go's `nopIterator` uses for "not a
/// histogram" and what the previous box already did.
public final class BoxedFloatChunkIterator<I: FloatChunkIteratorValue>: ChunkIterator {
    private var it: I

    public init(_ it: I) { self.it = it }

    public func next() -> ValueType { it.next() }
    public func seek(_ t: Int64) -> ValueType { it.seek(t) }
    public func at() -> (Int64, Double) { it.at }
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) { (Int64.min, nil) }
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) { (Int64.min, nil) }
    public func atT() -> Int64 { it.at.0 }
    public func atST() -> Int64 { it.atST }
    public func err() -> (any Error)? { it.err }
}

// MARK: - The appenders

/// Go: the two histogram arms of `xorAppender`, which **panic**:
///
///     panic("appended a histogram sample to a float chunk")
///     panic("appended a float histogram sample to a float chunk")
///
/// Unreachable by contract — `appendPreprocessor` cuts a new chunk when the encoding changes, so a histogram
/// never reaches a float chunk's appender — so this takes PORTING.md exception 9's treatment: raise with Go's
/// exact text rather than trap, and rather than the reachable-panic treatment `extendFloats` gets.
public enum FloatChunkAppenderError: Error, CustomStringConvertible, Equatable {
    case histogramToFloatChunk
    case floatHistogramToFloatChunk

    public var description: String {
        switch self {
        case .histogramToFloatChunk: return "appended a histogram sample to a float chunk"
        case .floatHistogramToFloatChunk: return "appended a float histogram sample to a float chunk"
        }
    }
}

extension XORAppender: ChunkAppender {
    /// Go: `xorAppender.Append(_, t int64, v float64)` — the start timestamp is **discarded**, and upstream
    /// says so by naming the parameter `_`. XOR carries no ST; that is XOR2's job (quirk 36).
    public func append(_ st: Int64, _ t: Int64, _ v: Double) {
        append(t, v)
    }

    public func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.histogramToFloatChunk
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.floatHistogramToFloatChunk
    }
}

extension XOR2Appender: ChunkAppender {
    public func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.histogramToFloatChunk
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.floatHistogramToFloatChunk
    }
}

// MARK: - The chunks

extension XORChunk: Chunk {
    /// Go: `Chunk.Appender`. Named apart from the concrete `appender()` because Swift has no return-type
    /// covariance for a witness — see `Chunk`'s note.
    public func makeAppender() throws -> any ChunkAppender { try appender() }

    /// Go: `Chunk.Iterator(reuse)`. The reuse argument is honoured only when it is a box of the right kind;
    /// otherwise a fresh one is made, which is what upstream's own implementations do when the type assertion
    /// fails.
    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        BoxedFloatChunkIterator(iterator())
    }
}

extension XOR2Chunk: Chunk {
    public func makeAppender() throws -> any ChunkAppender { try appender() }

    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        BoxedFloatChunkIterator(iterator())
    }
}

// MARK: - NewEmptyChunk

/// Go: `chunkenc.NewEmptyChunk`.
///
/// **The histogram encodings are not ported yet** (`PromChunkEnc` has `XORChunk`, `XOR2Chunk`, `Bstream`,
/// `Varbit` and `HistogramMeta`, but no `HistogramChunk`/`FloatHistogramChunk`), so this answers for the two
/// float encodings and reports the rest by name. That is consistent rather than a new gap: §7f defers
/// histogram appends, and `chunkOpts.useXOR2` selects between exactly these two.
///
/// Note what `cutNewHeadChunk` does with an INVALID encoding: it does not fail, it falls back to
/// `NewXORChunk()`. So the caller checks `Encoding.isValid` first and only reaches here for a valid one —
/// which is why an unsupported *valid* encoding is an error here rather than a silent XOR chunk.
public func newEmptyChunk(_ e: Encoding) throws -> any Chunk {
    switch e {
    case .xor: return XORChunk()
    case .xor2: return XOR2Chunk()
    default: throw NewEmptyChunkError.unsupportedEncoding(e)
    }
}

public enum NewEmptyChunkError: Error, CustomStringConvertible, Equatable {
    case unsupportedEncoding(Encoding)

    public var description: String {
        switch self {
        case .unsupportedEncoding(let e):
            return "chunk encoding \(e) is not implemented in this port yet"
        }
    }
}
