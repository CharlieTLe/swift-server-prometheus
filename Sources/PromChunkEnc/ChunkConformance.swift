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
/// …and their four counterparts on the histogram appenders, which are four DIFFERENT strings:
///
///     panic("appended a float sample to a histogram chunk")            // both histogram appenders
///     panic("appended a float histogram sample to a histogram chunk")  // HistogramAppender
///     panic("appended a histogram sample to a float histogram chunk")  // FloatHistogramAppender
///
/// Note the third and fourth are not symmetric with the first two: a `HistogramAppender` refusing a
/// float histogram says "to a histogram chunk" while an `xorAppender` refusing one says "to a float
/// chunk", and the *float histogram* chunk's refusal of a float sample reuses the integer chunk's
/// wording ("a histogram chunk") rather than saying "float histogram chunk". All six are reproduced
/// verbatim.
///
/// Unreachable by contract — `appendPreprocessor` cuts a new chunk when the encoding changes, so a
/// sample never reaches the wrong chunk's appender — so this takes PORTING.md exception 9's
/// treatment: raise with Go's exact text rather than trap, and rather than the reachable-panic
/// treatment `extendFloats` gets. The two `Append(st, t, v)` arms cannot raise, because the protocol
/// method does not throw and Go's does not either; those keep the message in a `preconditionFailure`.
public enum FloatChunkAppenderError: Error, CustomStringConvertible, Equatable {
    case histogramToFloatChunk
    case floatHistogramToFloatChunk
    case floatHistogramToHistogramChunk
    case histogramToFloatHistogramChunk

    public var description: String {
        switch self {
        case .histogramToFloatChunk: return "appended a histogram sample to a float chunk"
        case .floatHistogramToFloatChunk:
            return "appended a float histogram sample to a float chunk"
        case .floatHistogramToHistogramChunk:
            return "appended a float histogram sample to a histogram chunk"
        case .histogramToFloatHistogramChunk:
            return "appended a histogram sample to a float histogram chunk"
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
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.histogramToFloatChunk
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.floatHistogramToFloatChunk
    }
}

extension XOR2Appender: ChunkAppender {
    public func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.histogramToFloatChunk
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.floatHistogramToFloatChunk
    }
}

extension HistogramAppender: ChunkAppender {
    /// Go: `panic("appended a float sample to a histogram chunk")`.
    public func append(_ st: Int64, _ t: Int64, _ v: Double) {
        preconditionFailure("appended a float sample to a histogram chunk")
    }

    /// Go: `AppendHistogram(prev Appender, _, t int64, ...)` — the start timestamp is discarded here
    /// too, exactly as in `xorAppender`. Start timestamps ride on XOR2 only.
    public func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        try appendHistogram(prev: prev, t: t, h: &h, appendOnly: appendOnly)
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.floatHistogramToHistogramChunk
    }
}

extension FloatHistogramAppender: ChunkAppender {
    /// Go: `panic("appended a float sample to a histogram chunk")` — the *same* text as the integer
    /// appender's, not "float histogram chunk".
    public func append(_ st: Int64, _ t: Int64, _ v: Double) {
        preconditionFailure("appended a float sample to a histogram chunk")
    }

    public func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        throw FloatChunkAppenderError.histogramToFloatHistogramChunk
    }

    public func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: inout FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender) {
        try appendFloatHistogram(prev: prev, t: t, h: &h, appendOnly: appendOnly)
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

extension HistogramChunk: Chunk {
    public func makeAppender() throws -> any ChunkAppender { try appender() }

    /// Go: `HistogramChunk.iterator(it)` — the reuse argument is honoured by `Reset`ing an existing
    /// `*histogramIterator` and ignored otherwise. Unlike the float chunks this needs no box: the
    /// iterator is already a class, because Go's is a pointer whose `Reset` IS the reuse mechanism.
    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        if let hi = reuse as? HistogramIterator {
            hi.reset(b.bytes)
            return hi
        }
        return iterator()
    }
}

extension FloatHistogramChunk: Chunk {
    public func makeAppender() throws -> any ChunkAppender { try appender() }

    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        if let hi = reuse as? FloatHistogramIterator {
            hi.reset(b.bytes)
            return hi
        }
        return iterator()
    }
}

// MARK: - NewEmptyChunk

/// Go: `chunkenc.NewEmptyChunk`.
///
/// **All four encodings answer.** The note that stood here through §7f(c) — that the histogram
/// encodings were absent from `PromChunkEnc` and so could only be reported by name — is discharged:
/// `HistogramChunk.swift` and `FloatHistogramChunk.swift` exist, so `EncHistogram` and
/// `EncFloatHistogram` build a real chunk. `EncNone` and any unknown byte are the only failures, and
/// they are Go's failure with Go's text.
///
/// Note what `cutNewHeadChunk` does with an INVALID encoding: it does not fail, it falls back to
/// `NewXORChunk()`. So the caller checks `Encoding.isValid` first and only reaches here for a valid one —
/// which is why an unsupported *valid* encoding is an error here rather than a silent XOR chunk.
public func newEmptyChunk(_ e: Encoding) throws -> any Chunk {
    switch e {
    case .xor: return XORChunk()
    case .histogram: return HistogramChunk()
    case .floatHistogram: return FloatHistogramChunk()
    case .xor2: return XOR2Chunk()
    default: throw NewEmptyChunkError.invalidEncoding(e)
    }
}

/// Go: `chunkenc.FromData` — a chunk over existing bytes, with `count: 0` so the last byte reads as
/// full. That is exactly `NewEmptyChunk` followed by `Reset`, since `Reset` zeroes `count` too.
///
/// Named apart from Go's `FromData` because a free function called `fromData` reads badly at a call
/// site; the two are the same function.
public func chunkFromData(_ e: Encoding, _ d: [UInt8]) throws -> any Chunk {
    let c = try newEmptyChunk(e)
    c.reset(d)
    return c
}

extension ValueType {
    /// Go: `ValueType.NewChunk`. `ValNone` maps to `EncNone`, which is not a valid encoding, so this
    /// raises for it — exactly as `NewEmptyChunk` does upstream.
    public func newChunk(useXOR2: Bool) throws -> any Chunk {
        try newEmptyChunk(chunkEncoding(useXOR2: useXOR2))
    }
}

public enum NewEmptyChunkError: Error, CustomStringConvertible, Equatable {
    case invalidEncoding(Encoding)

    /// Go: `fmt.Errorf("invalid chunk encoding %q", e)`. `%q` on a `Stringer` quotes the `String()`
    /// result, so `EncNone` renders as `"none"` and an unknown byte as `"<unknown>"` — not as a
    /// number, which is what a naive reading of `%q` on a `uint8` would give.
    public var description: String {
        switch self {
        case .invalidEncoding(let e):
            return "invalid chunk encoding \"\(e)\""
        }
    }
}
