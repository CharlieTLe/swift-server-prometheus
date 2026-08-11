//===----------------------------------------------------------------------===//
// Ported from storage/interface.go @ v3.13.2
//
// **Query side only.** Phase 5 is the PromQL engine, and the engine's whole
// storage surface is `Queryable`, `Querier`, `SeriesSet`, `Series`, `SelectHints`
// plus the two buffering iterators. Ported with it, because they are the same
// file and cost nothing: `LabelQuerier`, the chunk-query protocols, and the
// empty/error/test series sets.
//
// Deliberately deferred, each to the phase that first has a caller:
//   - `Appender`, `AppendableV2` and the exemplar/metadata/start-timestamp
//     appenders (storage/interface_append.go) -> Phases 6-7, with the Head.
//   - `Storage`, `ExemplarStorage`, `SampleAndChunkQueryable` -> Phase 6.
//   - `Searcher`, `SearchResultSet`, `SearchHints`, `Filter`, `Ordering` -> the
//     HTTP API, Phase 9. Nothing in the engine or TSDB reads them.
//
// Naming note: Go's `storage.Labels` interface ("a thing that has labels") would
// shadow `PromLabels.Labels`, the value type, since Swift has no per-module
// qualification at use sites. It is `LabelsProvider` here. Every other protocol
// keeps Go's name.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromAnnotations
public import PromChunkEnc
public import PromChunks
public import GoCompat

// MARK: - Errors

/// Go: the package-level error values in storage/interface.go.
///
/// Each `description` is Go's message byte-for-byte; several are compared by
/// identity across package boundaries (`errors.Is(err, storage.ErrOutOfOrderSample)`),
/// which an enum case gives for free.
public enum StorageError: Error, Hashable, Sendable, CustomStringConvertible {
    case notFound
    /// Out-of-order support is disabled and the sample is out of order.
    case outOfOrderSample
    /// Out-of-order support is disabled and the sample predates the append's
    /// minimum valid time.
    case outOfBounds
    /// Out-of-order support is enabled but the sample is outside the window.
    case tooOldSample
    case outOfOrderExemplar
    case duplicateExemplar
    case exemplarLabelLength
    case exemplarsDisabled
    case nativeHistogramsDisabled
    /// Go: `ErrOutOfOrderST`.
    case outOfOrderST
    /// Go: `ErrSTNewerThanSample`.
    case stNewerThanSample

    public var description: String {
        switch self {
        case .notFound: return "not found"
        case .outOfOrderSample: return "out of order sample"
        case .outOfBounds: return "out of bounds"
        case .tooOldSample: return "too old sample"
        case .outOfOrderExemplar: return "out of order exemplar"
        case .duplicateExemplar: return "duplicate exemplar"
        case .exemplarLabelLength:
            // interface.go:43 interpolates exemplar.ExemplarMaxLabelSetLength.
            return
                "label length for exemplar exceeds maximum of \(Exemplar.maxLabelSetLength) UTF-8 characters"
        case .exemplarsDisabled:
            return "exemplar storage is disabled or max exemplars is less than or equal to 0"
        case .nativeHistogramsDisabled: return "native histograms are disabled"
        case .outOfOrderST: return "start timestamp out of order, ignoring"
        case .stNewerThanSample: return "ST is newer or the same as sample's timestamp, ignoring"
        }
    }
}

/// Go: `exemplar.ExemplarMaxLabelSetLength`. The one constant
/// `ErrExemplarLabelLength` needs; `model/exemplar` proper arrives with Phase 8.
public enum Exemplar: Sendable {
    public static let maxLabelSetLength = 128
}

/// Go: `SeriesRef` — a `HeadSeriesRef` or `BlockSeriesRef`, or whatever an
/// out-of-tree implementation uses. 0 means "no reference; do not cache".
/// `Comparable` because Go's `SeriesRef` is a `uint64` and the postings algebra orders it directly —
/// `p.At() > target`, `nodes[left].value < nodes[right].value`. Ordering is part of the contract, not a
/// convenience: `Postings` is documented as "iterative access over an ORDERED list of SeriesRef".
public struct SeriesRef: RawRepresentable, Sendable, Hashable, Comparable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (a: SeriesRef, b: SeriesRef) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Queryables

/// Go: `Queryable`. The entry point PromQL uses.
public protocol Queryable {
    /// Go: `Querier(mint, maxt int64)`.
    func querier(mint: Int64, maxt: Int64) throws -> any Querier
}

/// Go: `LabelQuerier`.
public protocol LabelQuerier {
    /// Go: `LabelValues` — every potential value for `name`, sorted, narrowed by
    /// `matchers`.
    func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations)

    /// Go: `LabelNames` — every unique label name, sorted, narrowed by `matchers`.
    func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations)

    /// Go: `Close` — releases the querier's resources.
    func close() throws
}

/// Go: `Querier` — querying over a fixed time range, sample by sample.
///
/// `select` does not filter: results that do not match the matchers are
/// undefined behaviour, not an error. `sortSeries` is a request the caller should
/// avoid making when it can.
public protocol Querier: LabelQuerier {
    func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet
}

/// Go: `ChunkQueryable`.
public protocol ChunkQueryable {
    func chunkQuerier(mint: Int64, maxt: Int64) throws -> any ChunkQuerier
}

/// Go: `ChunkQuerier` — the same query, in encoded chunks.
public protocol ChunkQuerier: LabelQuerier {
    func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any ChunkSeriesSet
}

/// Go: `QueryableFunc` — adapts a closure to ``Queryable``, after
/// `http.HandlerFunc`.
public struct QueryableFunc: Queryable {
    private let body: (Int64, Int64) throws -> any Querier

    public init(_ body: @escaping (Int64, Int64) throws -> any Querier) {
        self.body = body
    }

    public func querier(mint: Int64, maxt: Int64) throws -> any Querier {
        try body(mint, maxt)
    }
}

/// Go: `MockQueryable` — "used for testing purposes so that a mock Querier can be
/// used". Ignores both bounds, exactly as Go's unnamed parameters say.
public struct MockQueryable: Queryable {
    public var mockQuerier: any Querier

    public init(mockQuerier: any Querier) { self.mockQuerier = mockQuerier }

    public func querier(mint: Int64, maxt: Int64) throws -> any Querier { mockQuerier }
}

/// Go: `MockQuerier` — `select` delegates to a closure; the three
/// `LabelQuerier` methods are stubs returning Go's zero values.
public struct MockQuerier: Querier {
    public var selectMockFunction:
        (_ sortSeries: Bool, _ hints: SelectHints?, _ matchers: [Matcher]) -> any SeriesSet

    public init(
        selectMockFunction: @escaping (Bool, SelectHints?, [Matcher]) -> any SeriesSet
    ) {
        self.selectMockFunction = selectMockFunction
    }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        selectMockFunction(sortSeries, hints, matchers)
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func close() throws {}
}

// MARK: - Hints

/// Go: `SelectHints`. Purely advisory — an implementation may ignore all of it.
public struct SelectHints: Sendable, Hashable {
    /// Start time in milliseconds for this select.
    public var start: Int64
    /// End time in milliseconds for this select.
    public var end: Int64

    /// Maximum number of results. 0 disables the limit.
    public var limit: Int

    /// Query step size in milliseconds.
    public var step: Int64
    /// The surrounding function or aggregation, as a string.
    public var func_: String

    /// Label names used in the aggregation.
    public var grouping: [String]
    /// True for `by`, false for `without`.
    public var by: Bool
    /// Range-vector selector range in milliseconds.
    public var range: Int64

    /// Total number of shards series should be split into at query time; only
    /// the `shardIndex` shard is returned. 0 disables sharding. Series shard by
    /// "labels stable hash" mod `shardCount`.
    public var shardCount: UInt64
    /// Shard index to query, in `0..<shardCount`.
    public var shardIndex: UInt64

    /// Skip trimming matched chunks to `start`/`end`. Results may then contain
    /// samples outside the range, in exchange for a faster select.
    public var disableTrimming: Bool

    /// Projection hints. Unused by this engine, as by Go's — they exist for
    /// other `Queryable` implementations, which is why they are carried rather
    /// than dropped.
    ///
    /// The minimum set of labels this select must fetch. An implementation that
    /// honours it must add a `__series_hash__` label holding the hash of the
    /// series' full label set, so the engine can still do horizontal joins.
    public var projectionLabels: [String]
    /// Whether `projectionLabels` is an include list or an exclude list.
    public var projectionInclude: Bool

    public init(
        start: Int64 = 0, end: Int64 = 0, limit: Int = 0, step: Int64 = 0, func_: String = "",
        grouping: [String] = [], by: Bool = false, range: Int64 = 0,
        shardCount: UInt64 = 0, shardIndex: UInt64 = 0, disableTrimming: Bool = false,
        projectionLabels: [String] = [], projectionInclude: Bool = false
    ) {
        self.start = start
        self.end = end
        self.limit = limit
        self.step = step
        self.func_ = func_
        self.grouping = grouping
        self.by = by
        self.range = range
        self.shardCount = shardCount
        self.shardIndex = shardIndex
        self.disableTrimming = disableTrimming
        self.projectionLabels = projectionLabels
        self.projectionInclude = projectionInclude
    }
}

/// Go: `LabelHints`. Results are returned in natural (alphabetical) order
/// regardless.
public struct LabelHints: Sendable, Hashable {
    /// Maximum number of results. 0 disables the limit.
    public var limit: Int

    public init(limit: Int = 0) { self.limit = limit }
}

// MARK: - Series

/// Go: the `storage.Labels` interface. Renamed; see the file header.
public protocol LabelsProvider {
    /// The complete label set. For a series, the labels that identify it.
    func labels() -> Labels
}

/// Go: `SampleIterable`.
public protocol SampleIterable {
    /// The argument is offered for reuse when non-nil; an implementation may
    /// return it or allocate a fresh iterator.
    func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator
}

/// Go: `ChunkIterable`. Iterates potentially overlapping chunks, sorted by min
/// time.
public protocol StorageChunkIterable {
    func iterator(_ reuse: (any ChunkMetaIterator)?) -> any ChunkMetaIterator
}

/// Go: `Series` — one time series, iterable by sample.
public protocol Series: LabelsProvider, SampleIterable {}

/// Go: `ChunkSeries` — one time series, iterable by chunk.
public protocol ChunkSeries: LabelsProvider, StorageChunkIterable {}

/// Go: `SeriesSet`.
///
/// A series returned by `at()` stays iterable after a further `next()`.
/// `warnings()` may be non-empty even when iteration did not fail.
public protocol SeriesSet: AnyObject {
    func next() -> Bool
    func at() -> (any Series)?
    /// The error iteration failed with. Once set, iteration cannot continue.
    func err() -> (any Error)?
    func warnings() -> Annotations
}

/// Go: `ChunkSeriesSet`.
public protocol ChunkSeriesSet: AnyObject {
    func next() -> Bool
    func at() -> (any ChunkSeries)?
    func err() -> (any Error)?
    func warnings() -> Annotations
}

// MARK: - Trivial series sets

/// Go: `errSeriesSet`, which doubles as `emptySeriesSet` when its error is nil.
public final class ErrSeriesSet: SeriesSet {
    private let error: (any Error)?

    public init(_ error: (any Error)?) { self.error = error }

    public func next() -> Bool { false }
    public func at() -> (any Series)? { nil }
    public func err() -> (any Error)? { error }
    public func warnings() -> Annotations { Annotations() }
}

/// Go: `EmptySeriesSet()`.
public func emptySeriesSet() -> any SeriesSet { ErrSeriesSet(nil) }

/// Go: `ErrSeriesSet(err)`.
public func errSeriesSet(_ err: any Error) -> any SeriesSet { ErrSeriesSet(err) }

/// Go: `errChunkSeriesSet`, likewise doubling as the empty set.
public final class ErrChunkSeriesSet: ChunkSeriesSet {
    private let error: (any Error)?

    public init(_ error: (any Error)?) { self.error = error }

    public func next() -> Bool { false }
    public func at() -> (any ChunkSeries)? { nil }
    public func err() -> (any Error)? { error }
    public func warnings() -> Annotations { Annotations() }
}

/// Go: `EmptyChunkSeriesSet()`.
public func emptyChunkSeriesSet() -> any ChunkSeriesSet { ErrChunkSeriesSet(nil) }

/// Go: `ErrChunkSeriesSet(err)`.
public func errChunkSeriesSet(_ err: any Error) -> any ChunkSeriesSet { ErrChunkSeriesSet(err) }

/// Go: `testSeriesSet` — `next()` is *always* true and `at()` always the same
/// series, so it never terminates. Kept because upstream's tests rely on the
/// non-termination.
public final class TestSeriesSet: SeriesSet {
    private let series: any Series

    public init(_ series: any Series) { self.series = series }

    public func next() -> Bool { true }
    public func at() -> (any Series)? { series }
    public func err() -> (any Error)? { nil }
    public func warnings() -> Annotations { Annotations() }
}
