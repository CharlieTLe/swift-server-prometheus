//===----------------------------------------------------------------------===//
// Ported from storage/generic.go @ v3.13.2 — PART A ONLY (lines 14-145).
//
// ## Two halves, one file, one stale header
//
// generic.go's own header says it "holds boilerplate adapters for generic
// MergeSeriesSet and MergeQuerier functions". That was true when it was written.
// Upstream commit `e1f4380b2` ("web/api: add search API endpoint") appended a
// whole label-search subsystem — top-K heaps, streaming two-way merges,
// relevance scoring, `Searcher`, `SearchResultSet` — to the same file without
// updating the header. Only the first ~145 lines are the merge boilerplate.
//
// **Part B is Phase 9's, with the HTTP API that is its only caller.** Nothing in
// `merge.go`, the TSDB or the engine reads it. The two references to it that DO
// appear in Part A and in `secondary.go` — `searcherFromGenericQuerier` and the
// `var _ Searcher = &querierAdapter{}` assertion — are omitted with it.
//
// ## Exception 30: a real Swift generic replaces Go's type erasure
//
// Go 1.15 had no generics, so `merge.go` was made to serve both `SeriesSet` and
// `ChunkSeriesSet` by erasing to an interface:
//
//     type genericSeriesSet interface { At() Labels; ... }
//     func (a *seriesSetAdapter) At() Series { return a.genericSeriesSet.At().(Series) }
//
// — an UNCHECKED type assertion at every boundary, whose safety rests on the
// invariant that a set built by `newGenericQuerierFrom` is only ever unwrapped
// by `querierAdapter`. Nothing in the type system says so; get the pairing wrong
// and it panics at run time.
//
// This port makes the element type a generic parameter instead, so the pairing
// is checked at compile time and every downcast disappears. `docs/PORTING.md`
// exception 30 records it. The behaviour is identical — the adapters are pure
// plumbing, and the corpus drives both instantiations through the same
// `NewMergeQuerier`/`NewMergeChunkQuerier` entry points Go's does.
//
// One consequence is visible in the shapes below. Swift existentials do not
// self-conform (`any Series` does not satisfy `Element: LabelsProvider`), so the
// generic is instantiated at two one-field wrappers, ``AnySeries`` and
// ``AnyChunkSeries``, rather than at `any Series` directly. They are the price
// of the exception and they are still strictly better than the assertions: an
// `AnySeries` cannot be mistaken for an `AnyChunkSeries`.
//
// The second is `genericQuerierAdapter`, which upstream gives two fields (`q`,
// `cq`) and a "One-of. If both are set, Querier will be used." comment. With the
// element type in the signature that one-of is expressible as two types, so
// ``GenericQuerierAdapter`` and ``GenericChunkQuerierAdapter`` are separate and
// the run-time branch is gone.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromAnnotations
public import GoCompat

// MARK: - The generic protocols

/// Go: `genericSeriesSet`.
///
/// `Element` replaces Go's `Labels` interface return. See the file header.
public protocol GenericSeriesSet<Element>: AnyObject {
    associatedtype Element: LabelsProvider

    func next() -> Bool
    func at() -> Element?
    func err() -> (any Error)?
    func warnings() -> Annotations
}

/// Go: `genericQuerier`.
public protocol GenericQuerier<Element>: LabelQuerier {
    associatedtype Element: LabelsProvider

    func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any GenericSeriesSet<Element>
}

/// Go: `genericSeriesMergeFunc`.
///
/// Optional result, because Go's returns a nil interface when handed no series
/// (`ChainedSeriesMerge`, `NewCompactingChunkSeriesMerger`) and the callers
/// already deal in optionals.
public typealias GenericSeriesMergeFunc<E: LabelsProvider> = ([E]) -> E?

// MARK: - The two element wrappers

/// Not in Go: `any Series` boxed so it can satisfy `Element: LabelsProvider`.
///
/// Swift existentials do not self-conform, which is the whole of the reason this
/// exists. See the file header and PORTING.md exception 30.
public struct AnySeries: LabelsProvider {
    public let base: any Series

    public init(_ base: any Series) { self.base = base }

    public func labels() -> Labels { base.labels() }
}

/// Not in Go: `any ChunkSeries` boxed. See ``AnySeries``.
public struct AnyChunkSeries: LabelsProvider {
    public let base: any ChunkSeries

    public init(_ base: any ChunkSeries) { self.base = base }

    public func labels() -> Labels { base.labels() }
}

// MARK: - Series-set adapters

/// Go: `genericSeriesSetAdapter`.
public final class GenericSeriesSetAdapter: GenericSeriesSet {
    public let base: any SeriesSet

    public init(_ base: any SeriesSet) { self.base = base }

    public func next() -> Bool { base.next() }
    public func at() -> AnySeries? { base.at().map(AnySeries.init) }
    public func err() -> (any Error)? { base.err() }
    public func warnings() -> Annotations { base.warnings() }
}

/// Go: `genericChunkSeriesSetAdapter`.
public final class GenericChunkSeriesSetAdapter: GenericSeriesSet {
    public let base: any ChunkSeriesSet

    public init(_ base: any ChunkSeriesSet) { self.base = base }

    public func next() -> Bool { base.next() }
    public func at() -> AnyChunkSeries? { base.at().map(AnyChunkSeries.init) }
    public func err() -> (any Error)? { base.err() }
    public func warnings() -> Annotations { base.warnings() }
}

/// Go: `seriesSetAdapter` — the unwrap direction. Where Go asserts
/// `.At().(Series)`, this reads a stored property of a known type.
public final class SeriesSetAdapter: SeriesSet {
    public let base: any GenericSeriesSet<AnySeries>

    public init(_ base: any GenericSeriesSet<AnySeries>) { self.base = base }

    public func next() -> Bool { base.next() }
    public func at() -> (any Series)? { base.at()?.base }
    public func err() -> (any Error)? { base.err() }
    public func warnings() -> Annotations { base.warnings() }
}

/// Go: `chunkSeriesSetAdapter`.
public final class ChunkSeriesSetAdapter: ChunkSeriesSet {
    public let base: any GenericSeriesSet<AnyChunkSeries>

    public init(_ base: any GenericSeriesSet<AnyChunkSeries>) { self.base = base }

    public func next() -> Bool { base.next() }
    public func at() -> (any ChunkSeries)? { base.at()?.base }
    public func err() -> (any Error)? { base.err() }
    public func warnings() -> Annotations { base.warnings() }
}

// MARK: - Querier adapters

/// Go: `genericQuerierAdapter` with its `q` field set. See the file header on
/// why the one-of became two types.
public final class GenericQuerierAdapter: GenericQuerier {
    public let base: any Querier

    public init(_ base: any Querier) { self.base = base }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any GenericSeriesSet<AnySeries> {
        GenericSeriesSetAdapter(
            base.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        try base.labelNames(ctx, hints: hints, matchers: matchers)
    }

    public func close() throws { try base.close() }
}

/// Go: `genericQuerierAdapter` with its `cq` field set.
public final class GenericChunkQuerierAdapter: GenericQuerier {
    public let base: any ChunkQuerier

    public init(_ base: any ChunkQuerier) { self.base = base }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any GenericSeriesSet<AnyChunkSeries> {
        GenericChunkSeriesSetAdapter(
            base.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        try base.labelNames(ctx, hints: hints, matchers: matchers)
    }

    public func close() throws { try base.close() }
}

/// Go: `newGenericQuerierFrom`.
public func newGenericQuerierFrom(_ q: any Querier) -> any GenericQuerier<AnySeries> {
    GenericQuerierAdapter(q)
}

/// Go: `newGenericQuerierFromChunk`.
public func newGenericQuerierFromChunk(_ cq: any ChunkQuerier) -> any GenericQuerier<AnyChunkSeries> {
    GenericChunkQuerierAdapter(cq)
}

/// Go: `querierAdapter` — a `genericQuerier` presented back as a `Querier`.
public final class QuerierAdapter: Querier {
    public let generic: any GenericQuerier<AnySeries>

    public init(_ generic: any GenericQuerier<AnySeries>) { self.generic = generic }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        SeriesSetAdapter(
            generic.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        try generic.labelValues(ctx, name: name, hints: hints, matchers: matchers)
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        try generic.labelNames(ctx, hints: hints, matchers: matchers)
    }

    public func close() throws { try generic.close() }
}

/// Go: `chunkQuerierAdapter`.
public final class ChunkQuerierAdapter: ChunkQuerier {
    public let generic: any GenericQuerier<AnyChunkSeries>

    public init(_ generic: any GenericQuerier<AnyChunkSeries>) { self.generic = generic }

    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any ChunkSeriesSet {
        ChunkSeriesSetAdapter(
            generic.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))
    }

    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        try generic.labelValues(ctx, name: name, hints: hints, matchers: matchers)
    }

    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        try generic.labelNames(ctx, hints: hints, matchers: matchers)
    }

    public func close() throws { try generic.close() }
}

// MARK: - Merge-function adapters

/// Go: `seriesMergerAdapter.Merge` — where the erasure cost a `[]Series` copy
/// and one unchecked assertion per element. Here it is a `map` over a stored
/// property.
func seriesMergerAdapter(
    _ f: @escaping VerticalSeriesMergeFunc
) -> GenericSeriesMergeFunc<AnySeries> {
    { elements in f(elements.map(\.base)).map(AnySeries.init) }
}

/// Go: `chunkSeriesMergerAdapter.Merge`.
func chunkSeriesMergerAdapter(
    _ f: @escaping VerticalChunkSeriesMergeFunc
) -> GenericSeriesMergeFunc<AnyChunkSeries> {
    { elements in f(elements.map(\.base)).map(AnyChunkSeries.init) }
}

// MARK: - The trivial generic set

/// Go: `noopGenericSeriesSet` (generic.go:814, in Part B's line range but part
/// of Part A's vocabulary — `secondary.go` substitutes it for every set of a
/// querier whose partner failed).
public final class NoopGenericSeriesSet<E: LabelsProvider>: GenericSeriesSet {
    public init() {}

    public func next() -> Bool { false }
    public func at() -> E? { nil }
    public func err() -> (any Error)? { nil }
    public func warnings() -> Annotations { Annotations() }
}
