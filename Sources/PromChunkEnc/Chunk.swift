//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/chunk.go @ v3.13.2
//
// **Protocol surface only.** The concrete encodings — XOR, XOR2, histogram,
// float histogram, and the bstream/varbit machinery under them — are Phases 6–7.
// They are the reason `storage` can be ported now: `storage.Series.Iterator`
// returns a `chunkenc.Iterator`, so the protocol has to exist first.
//
// Omitted along with them: `NewEmptyChunk`, `FromData`, the chunk `Pool`, and
// `ValueType.NewChunk` (which calls `NewEmptyChunk`). `ValueType.ChunkEncoding`
// is here because it is pure table lookup.
//===----------------------------------------------------------------------===//

public import PromHistogram

/// Go: `chunkenc.Encoding`.
public struct Encoding: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let none = Encoding(rawValue: 0)
    public static let xor = Encoding(rawValue: 1)
    public static let histogram = Encoding(rawValue: 2)
    public static let floatHistogram = Encoding(rawValue: 3)
    public static let xor2 = Encoding(rawValue: 4)

    /// Go: `Encoding.String()`.
    public var description: String {
        switch self {
        case .none: return "none"
        case .xor: return "XOR"
        case .histogram: return "histogram"
        case .floatHistogram: return "floathistogram"
        case .xor2: return "XOR2"
        default: return "<unknown>"
        }
    }

    /// Go: `IsValidEncoding`. Note `EncNone` is not valid.
    public var isValid: Bool {
        self == .xor || self == .histogram || self == .floatHistogram || self == .xor2
    }
}

/// Go: `chunkenc`'s size constants.
public enum ChunkLimits: Sendable {
    /// Go: `MaxBytesPerXORChunk`.
    public static let maxBytesPerXORChunk = 1024
    /// Go: `MaxBytesPerXORChunkBeforeAppend` — leaves room for one maximally
    /// sized (19-byte) sample.
    public static let maxBytesPerXORChunkBeforeAppend = 1024 - 19
    /// Go: `TargetBytesPerHistogramChunk`.
    public static let targetBytesPerHistogramChunk = 1024
    /// Go: `MinSamplesPerHistogramChunk`.
    public static let minSamplesPerHistogramChunk = 10
}

/// Go: `chunkenc.ValueType`.
public struct ValueType: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// No value at the current position.
    public static let none = ValueType(rawValue: 0)
    /// A simple float, retrieved with `at()`.
    public static let float = ValueType(rawValue: 1)
    /// An integer-count histogram; `atFloatHistogram` works too.
    public static let histogram = ValueType(rawValue: 2)
    /// A float-count histogram.
    public static let floatHistogram = ValueType(rawValue: 3)

    /// Go: `ValueType.String()`. Note the default is "unknown", where
    /// `Encoding.String()` uses "<unknown>".
    public var description: String {
        switch self {
        case .none: return "none"
        case .float: return "float"
        case .histogram: return "histogram"
        case .floatHistogram: return "floathistogram"
        default: return "unknown"
        }
    }

    /// Go: `ValueType.ChunkEncoding`.
    public func chunkEncoding(useXOR2: Bool) -> Encoding {
        switch self {
        case .float: return useXOR2 ? .xor2 : .xor
        case .histogram: return .histogram
        case .floatHistogram: return .floatHistogram
        default: return .none
        }
    }
}

/// Go: `CompatibleValues` — whether a chunk opened with encoding `a` can keep
/// taking appends when the desired encoding becomes `b`. Only the XOR family is
/// mutually compatible.
public func compatibleValues(_ a: Encoding, _ b: Encoding) -> Bool {
    isFloatXOREncoding(a) && isFloatXOREncoding(b)
}

/// Go: `isFloatXOREncoding`.
func isFloatXOREncoding(_ e: Encoding) -> Bool {
    e == .xor || e == .xor2
}

/// Go: `chunkenc.Iterator`.
///
/// Iterates a series' samples in timestamp-increasing order. `next()`/`seek(_:)`
/// return the type at the new position, or ``ValueType/none`` once exhausted.
///
/// `AnyObject`: every implementation is a pointer type with mutable cursor state,
/// and `SampleIterable.iterator(_:)` hands an existing one back for reuse.
public protocol ChunkIterator: AnyObject {
    /// Go: `Next`.
    func next() -> ValueType

    /// Go: `Seek` — advance to the first sample at or after `t`. If the current
    /// sample already satisfies that, this has no effect.
    func seek(_ t: Int64) -> ValueType

    /// Go: `At`. Only meaningful for ``ValueType/float``. Behaviour before the
    /// first advance is unspecified.
    func at() -> (Int64, Double)

    /// Go: `AtHistogram`. The argument is Go's reuse buffer; pass nil to
    /// allocate. Preserved rather than dropped with `sync.Pool`, because callers
    /// depend on copy-vs-alias semantics — PORTING.md §4.
    ///
    /// The result is optional because Go returns a nil `*Histogram` when the
    /// current value is not one (`nopIterator`, `mockSeriesIterator`), paired
    /// with a timestamp of `math.MinInt64`.
    func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?)

    /// Go: `AtFloatHistogram`. Also valid over an integer-count histogram, which
    /// it converts.
    func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?)

    /// Go: `AtT` — the current timestamp.
    func atT() -> Int64

    /// Go: `AtST` — the current start timestamp, or 0 when unimplemented/unset.
    func atST() -> Int64

    /// Go: `Err`. Only meaningful once the iterator is exhausted.
    func err() -> (any Error)?
}

/// Go: `chunkenc.Iterable`.
public protocol ChunkIterable {
    /// The argument is offered for reuse; an implementation may return it or a
    /// fresh iterator.
    func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator
}

/// Go: `chunkenc.Chunk`.
///
/// **The member shapes follow the CONCRETE types, not Go's interface.** Go declares `Bytes()`, `Encoding()`
/// and `NumSamples()` as methods because a Go interface has no other option; `XORChunk` and `XOR2Chunk` were
/// written with properties, which is idiomatic Swift for a derived value and is what every existing call site
/// uses. Matching the protocol to them costs no fidelity — the Go origin is an interface *shape*, not an
/// observable — and it avoids rewriting the concrete types and their callers to satisfy a spelling.
///
/// `makeAppender()` is the one deliberate rename. Go's is `Appender()`, and so is the concrete method on each
/// chunk — but the concrete one returns its *own* appender type, and Swift does not allow return-type
/// covariance for a protocol witness. Rather than force thirteen call sites onto an existential, the protocol
/// asks for a differently-named factory and each chunk implements it by wrapping its concrete appender.
public protocol Chunk: ChunkIterable {
    /// Go: `Bytes`.
    var bytes: [UInt8] { get }
    /// Go: `Encoding`.
    var encoding: Encoding { get }
    /// Go: `NumSamples`.
    var numSamples: Int { get }
    /// Go: `Appender` — see the note above on the name.
    func makeAppender() throws -> any ChunkAppender
    /// Go: `Compact` — optional; a hint that no more samples are coming.
    func compact()
    /// Go: `Reset`.
    func reset(_ stream: [UInt8])
}

/// Go: `chunkenc.Appender`. Named `ChunkAppender` here because `storage` has an
/// `Appender` of its own and Swift has no per-module name shadowing.
public protocol ChunkAppender: AnyObject {
    /// Go: `Append`. May trap when the chunk is full; deciding when to cut a new
    /// chunk is the caller's job.
    ///
    /// Unlabelled to match the concrete appenders. **`st` is the start timestamp and the XOR appender
    /// discards it** — upstream's `xorAppender.Append(_, t int64, v float64)` names the parameter `_`, because
    /// start timestamps ride on XOR2 and not XOR (quirk 36). So a three-argument signature here is not a
    /// claim that every encoding stores it.
    func append(_ st: Int64, _ t: Int64, _ v: Double)

    /// Go: `AppendHistogram`.
    func appendHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: Histogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender)

    /// Go: `AppendFloatHistogram`.
    func appendFloatHistogram(
        prev: (any ChunkAppender)?, st: Int64, t: Int64, h: FloatHistogram, appendOnly: Bool
    ) throws -> (chunk: (any Chunk)?, isRecoded: Bool, appender: any ChunkAppender)
}
