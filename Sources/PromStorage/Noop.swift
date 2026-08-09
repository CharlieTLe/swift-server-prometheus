//===----------------------------------------------------------------------===//
// Ported from storage/noop.go @ v3.13.2
//
// `noopQuerier`'s `SearchLabelNames`/`SearchLabelValues` are omitted with the
// rest of the `Searcher` protocol (Phase 9). Worth noting what they do when they
// arrive: they return a **nil** `SearchResultSet`, not an empty one, so any
// caller that reaches them panics. Upstream asserts the conformance
// (`var _ Searcher = noopQuerier{}`) without exercising it.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromAnnotations
public import GoCompat

/// Go: `noopQuerier`.
public struct NoopQuerier: Querier {
    public init() {}

    public func select(
        _: GoContext, sortSeries _: Bool, hints _: SelectHints?, matchers _: [Matcher]
    ) -> any SeriesSet {
        noopSeriesSet()
    }

    public func labelValues(
        _: GoContext, name _: String, hints _: LabelHints?, matchers _: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func labelNames(
        _: GoContext, hints _: LabelHints?, matchers _: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func close() throws {}
}

/// Go: `NoopQuerier()`.
public func noopQuerier() -> any Querier { NoopQuerier() }

/// Go: `noopChunkQuerier`.
public struct NoopChunkQuerier: ChunkQuerier {
    public init() {}

    public func select(
        _: GoContext, sortSeries _: Bool, hints _: SelectHints?, matchers _: [Matcher]
    ) -> any ChunkSeriesSet {
        noopChunkedSeriesSet()
    }

    public func labelValues(
        _: GoContext, name _: String, hints _: LabelHints?, matchers _: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func labelNames(
        _: GoContext, hints _: LabelHints?, matchers _: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        ([], Annotations())
    }

    public func close() throws {}
}

/// Go: `NoopChunkedQuerier()`.
public func noopChunkedQuerier() -> any ChunkQuerier { NoopChunkQuerier() }

/// Go: `noopSeriesSet`. Behaviourally identical to `emptySeriesSet`; both exist
/// upstream, so both exist here.
public final class NoopSeriesSet: SeriesSet {
    public init() {}
    public func next() -> Bool { false }
    public func at() -> (any Series)? { nil }
    public func err() -> (any Error)? { nil }
    public func warnings() -> Annotations { Annotations() }
}

/// Go: `NoopSeriesSet()`.
public func noopSeriesSet() -> any SeriesSet { NoopSeriesSet() }

/// Go: `noopChunkedSeriesSet`.
public final class NoopChunkedSeriesSet: ChunkSeriesSet {
    public init() {}
    public func next() -> Bool { false }
    public func at() -> (any ChunkSeries)? { nil }
    public func err() -> (any Error)? { nil }
    public func warnings() -> Annotations { Annotations() }
}

/// Go: `NoopChunkedSeriesSet()`.
public func noopChunkedSeriesSet() -> any ChunkSeriesSet { NoopChunkedSeriesSet() }
