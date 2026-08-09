//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/chunk.go @ v3.13.2 — nopIterator, mockSeriesIterator
//===----------------------------------------------------------------------===//

public import PromHistogram

/// Go: `nopIterator` — holds no data and is immediately exhausted.
///
/// Used widely as the "no samples" answer, including by `storage`'s empty series.
/// Note the timestamps: `at`, `atHistogram`, `atFloatHistogram` and `atT` all
/// report `math.MinInt64`, but `atST` reports 0.
public final class NopChunkIterator: ChunkIterator {
    public init() {}

    public func next() -> ValueType { .none }
    public func seek(_: Int64) -> ValueType { .none }
    public func at() -> (Int64, Double) { (Int64.min, 0) }
    public func atHistogram(_: Histogram?) -> (Int64, Histogram?) { (Int64.min, nil) }
    public func atFloatHistogram(_: FloatHistogram?) -> (Int64, FloatHistogram?) {
        (Int64.min, nil)
    }
    public func atT() -> Int64 { Int64.min }
    public func atST() -> Int64 { 0 }
    public func err() -> (any Error)? { nil }
}

/// Go: `NewNopIterator`.
public func newNopIterator() -> any ChunkIterator { NopChunkIterator() }

/// Go: `mockSeriesIterator` — floats only, and `seek` deliberately does nothing.
///
/// Kept because `storage.MockSeries` is built on it and upstream's own storage
/// tests (the source of this port's differential cases) depend on its exact
/// non-behaviour: `seek` always reports exhaustion even when samples remain.
public final class MockSeriesChunkIterator: ChunkIterator {
    private let timestamps: [Int64]
    private let startTimestamps: [Int64]
    private let values: [Double]
    private var currIndex: Int

    /// `startTimestamps` may be empty to mean "no start timestamps".
    public init(startTimestamps: [Int64], timestamps: [Int64], values: [Double]) {
        self.startTimestamps = startTimestamps
        self.timestamps = timestamps
        self.values = values
        self.currIndex = -1
    }

    public func next() -> ValueType {
        if currIndex < timestamps.count - 1 {
            currIndex += 1
            return .float
        }
        return .none
    }

    /// chunk.go:263 — always `ValNone`, regardless of `t`.
    public func seek(_: Int64) -> ValueType { .none }

    public func at() -> (Int64, Double) { (timestamps[currIndex], values[currIndex]) }
    public func atHistogram(_: Histogram?) -> (Int64, Histogram?) { (Int64.min, nil) }
    public func atFloatHistogram(_: FloatHistogram?) -> (Int64, FloatHistogram?) {
        (Int64.min, nil)
    }
    public func atT() -> Int64 { timestamps[currIndex] }

    public func atST() -> Int64 {
        if startTimestamps.isEmpty {
            return 0
        }
        return startTimestamps[currIndex]
    }

    public func err() -> (any Error)? { nil }
}

/// Go: `MockSeriesIterator`.
public func mockSeriesIterator(
    startTimestamps: [Int64], timestamps: [Int64], values: [Double]
) -> any ChunkIterator {
    MockSeriesChunkIterator(
        startTimestamps: startTimestamps, timestamps: timestamps, values: values)
}
