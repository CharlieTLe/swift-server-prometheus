//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/samples.go @ v3.13.2
//
// `Sample` is the interface `storage`'s look-back ring stores. It is a protocol
// rather than an enum because `sampleRing` keeps a `[any Sample]` for the mixed
// case — see Sources/PromStorage/SampleRing.swift.
//
// Note `st`: at this pin every sample carries a start timestamp (upstream commit
// 1e77d9ded), `chunkenc.Iterator` has `AtST()`, and "has a start timestamp" is
// spelled `st != 0` throughout. It is not optional and not an afterthought.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromHistogram

/// Go: `chunks.Sample`.
///
/// Only one of ``f``, ``h`` and ``fh`` is meaningful for a given sample; the
/// others trap, reproducing Go's panics. Those panics are upstream's way of
/// asserting the type discipline, not oversights — `Type()` tells a caller which
/// accessor is legal.
public protocol Sample {
    /// Go: `T()`.
    var t: Int64 { get }
    /// Go: `ST()` — the start timestamp, 0 when unset.
    var st: Int64 { get }
    /// Go: `F()`. Traps unless ``type`` is `.float`.
    var f: Double { get }
    /// Go: `H()`. Traps unless ``type`` is `.histogram`.
    ///
    /// Optional because the ring's not-yet-written slots hold nil, exactly as
    /// Go's `hSample.h` starts as a nil pointer in a freshly allocated buffer.
    var h: Histogram? { get }
    /// Go: `FH()`. Traps for a float sample; converts for an integer histogram.
    var fh: FloatHistogram? { get }
    /// Go: `Type()`.
    var type: ValueType { get }
    /// Go: `Copy()` — "Returns a deep copy".
    func copy() -> any Sample
}

/// Go: `chunks.Samples` — a random-access collection of samples.
public protocol Samples {
    func get(_ i: Int) -> any Sample
    var count: Int { get }
}

/// Go: `chunks.SampleSlice`.
public struct SampleSlice: Samples {
    public var samples: [any Sample]

    public init(_ samples: [any Sample]) { self.samples = samples }

    public func get(_ i: Int) -> any Sample { samples[i] }
    public var count: Int { samples.count }
}
