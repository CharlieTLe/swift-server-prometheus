//===----------------------------------------------------------------------===//
// The query side of the Phase 5 in-memory storage. See MemStorage.swift for what
// this target is and is not.
//
// Everything here is upstream behaviour, taken from `tsdb/querier.go`'s
// `selectSeriesSet` (:180) and `blockBaseSeriesSet.Next` (:440) and from
// `tsdb/head_read.go`'s label readers, and pinned against a real `tsdb.DB` by
// `Fixtures/storage/mem-select.jsonl` and `Fixtures/storage/mem-labels.jsonl`.
//
// Four of the five behaviours below were written the other way round first and
// the fixtures corrected them. They are not guessable:
//
//  1. `select` is a TWO-STAGE filter with two DIFFERENT ranges. See `select`.
//  2. A series whose samples are all trimmed away is still RETURNED, empty.
//  3. `labelValues`/`labelNames` are gated on the store's OVERALL range but are
//     not filtered per series.
//  4. `labelValues` applies its limit BEFORE sorting; `labelNames` after.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromLabels
public import PromStorage

// Internal: reached only through the sample list, never in a public signature.
internal import PromChunkEnc
internal import PromChunks

// `public import`, not internal: `GoContext` appears in `select`/`labelValues`/
// `labelNames`, which are public. See docs/HANDOFF.md §4.
public import GoCompat

/// A ``Querier`` over a ``MemStorage`` snapshot for a fixed time range.
public final class MemQuerier: Querier {
    private let entries: [MemStorage.Entry]
    private let mint: Int64
    private let maxt: Int64

    init(storage: MemStorage, mint: Int64, maxt: Int64) {
        self.entries = storage.snapshot()
        self.mint = mint
        self.maxt = maxt
    }

    // MARK: - Querier

    /// Two stages, with two different ranges. Getting this wrong is silent, so
    /// the reasoning is spelled out.
    ///
    /// **Stage 1, visibility, uses the QUERIER's range.** Upstream, `Select`
    /// reads chunk metadata through an index reader that was opened with the
    /// querier's `mint`/`maxt` (`headIndexReader`), so a chunk outside that range
    /// is not merely trimmed — it is never seen. A series with no visible chunk
    /// is skipped entirely (`querier.go:503`, `if len(chks) == 0 { continue }`).
    ///
    /// **Stage 2, trimming, uses the HINTS' range**, which *overrides* the
    /// querier's rather than narrowing it (`querier.go:205-207`). Hints wider than
    /// the querier therefore widen the samples returned from an already-visible
    /// series, but cannot make an invisible series appear. The
    /// `hints/two-stage` and `hints/disjoint` fixtures pin exactly that.
    ///
    /// Both ranges are **closed** at both ends (`querier.go:479`).
    ///
    /// **A series can be returned with no samples at all**, when stage 1 admits it
    /// and stage 2 removes everything — `nohints/instant-miss` queries the instant
    /// t=250 between samples and gets three empty series, not an empty set. This
    /// is the one place where the port is a superset of upstream rather than an
    /// equal: see ``spanOverlaps`` for the chunk-granularity caveat.
    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        var trimMint = mint
        var trimMaxt = maxt
        var disableTrimming = false
        if let hints {
            trimMint = hints.start
            trimMaxt = hints.end
            disableTrimming = hints.disableTrimming
        }

        var matched = [any Series]()
        for entry in entries {
            if let err = ctx.err() {
                return errSeriesSet(err)
            }
            guard Self.matches(entry.lset, matchers) else { continue }
            // Stage 1: the querier's range, never the hints'.
            guard Self.spanOverlaps(entry, mint: mint, maxt: maxt) else { continue }

            // Stage 2. `disableTrimming` means "return whole chunks" upstream,
            // which for a one-chunk-per-series store is "return everything".
            let samples =
                disableTrimming
                ? entry.samples
                : entry.samples.filter { $0.t >= trimMint && $0.t <= trimMaxt }

            // Deliberately NOT `if samples.isEmpty { continue }`. See the doc
            // comment: upstream skips at chunk granularity, which has already
            // happened in stage 1.
            matched.append(newListSeries(entry.lset, samples))
        }

        // querier.go:199 — `p = index.SortedPostings(p)`, which sorts by labels.
        // Unsorted is insertion order; see MemStorage's note on why that is a
        // choice rather than a match.
        if sortSeries {
            matched.sort { Labels.compare($0.labels(), $1.labels()) < 0 }
        }

        return MemSeriesSet(matched)
    }

    /// Whether a series is visible at all, modelling each series as **one chunk**
    /// spanning its first to its last sample.
    ///
    /// That model is exact for a series upstream would hold in a single chunk, and
    /// the *samples* it returns are exact whenever the hints' range is contained in
    /// the querier's — which it always is for this engine, since `execEvalStmt`
    /// derives the querier's bounds from `FindMinMaxTime` over the same selectors
    /// the hints come from (`engine.go:788`).
    ///
    /// Where it is a superset: upstream's chunks tile a series' span with gaps
    /// between them, so a range falling entirely inside a gap matches no chunk and
    /// drops the series, whereas one big chunk still overlaps. The difference is
    /// only ever a series returned with an **empty** sample list, which the
    /// evaluator cannot observe — it builds output from points, and a series with
    /// no points contributes none. Recorded as exception 12 in docs/PORTING.md.
    static func spanOverlaps(_ entry: MemStorage.Entry, mint: Int64, maxt: Int64) -> Bool {
        guard let first = entry.samples.first, let last = entry.samples.last else {
            return false
        }
        // chunks.Meta.OverlapsClosedInterval.
        return first.t <= maxt && mint <= last.t
    }

    /// The semantic content of `PostingsForMatchers`, without the inverted index:
    /// every matcher must match, and a **missing** label is matched as the empty
    /// string.
    ///
    /// That last part is the whole reason this cannot check `lset.has(m.name)`
    /// first: `{job=""}` and `{job!="api"}` are both required to match series that
    /// carry no `job` at all, which is exactly what `Labels.subscript` returning
    /// `""` for an absent name gives for free. The `match/eq-empty-value` and
    /// `match/neq` fixtures pin it.
    static func matches(_ lset: Labels, _ matchers: [Matcher]) -> Bool {
        for m in matchers where !m.matches(lset[m.name]) {
            return false
        }
        return true
    }

    // MARK: - LabelQuerier

    /// Go: `headIndexReader.LabelValues` (head_read.go:154) below
    /// `blockBaseQuerier.LabelValues`, which calls `SortedLabelValues`.
    ///
    /// Two things here are the opposite of what the `LabelQuerier` doc comment
    /// ("Results are returned in natural (alphabetical) order") suggests, and both
    /// are pinned:
    ///
    ///   - the range gate is over the store's **overall** span, not per series, so
    ///     a value carried only by a series with no sample in range is still
    ///     returned (`values/narrow-range`);
    ///   - the limit truncates the **append-ordered** value list and only what
    ///     survives is sorted, because `MemPostings.LabelValues` slices
    ///     `p.lvs[name]` — an append-only slice — before `SortedLabelValues` sorts.
    ///     So `instance` first seen as "1" then "0", with limit 1, yields **["1"]**
    ///     and not ["0"] (`values/limit-unsorted`).
    ///
    /// The consequence worth knowing for Phase 9: *which* values a limit keeps
    /// depends on ingest order, so it is not a stable API result.
    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        if let err = ctx.err() { throw err }
        guard overlapsStoreRange else { return ([], Annotations()) }

        // First-seen order, deduplicated.
        var values = [String]()
        var seen = Set<String>()
        for entry in entries where Self.matches(entry.lset, matchers) {
            let v = entry.lset[name]
            if !v.isEmpty, seen.insert(v).inserted { values.append(v) }
        }
        if let limit = hints?.limit, limit > 0, values.count > limit {
            values = Array(values.prefix(limit))
        }
        values.sort { $0.utf8Lexicographic < $1.utf8Lexicographic }
        return (values, Annotations())
    }

    /// Go: `headIndexReader.LabelNames` (head_read.go:172) below
    /// `blockBaseQuerier.LabelNames`.
    ///
    /// Note the asymmetry with ``labelValues(_:name:hints:matchers:)``: here the
    /// index sorts first and `blockBaseQuerier.LabelNames` truncates the sorted
    /// result, so the limit does keep the alphabetically first names.
    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        if let err = ctx.err() { throw err }
        guard overlapsStoreRange else { return ([], Annotations()) }

        var seen = Set<String>()
        for entry in entries where Self.matches(entry.lset, matchers) {
            for l in entry.lset { seen.insert(l.name) }
        }
        var names = seen.sorted { $0.utf8Lexicographic < $1.utf8Lexicographic }
        if let limit = hints?.limit, limit > 0, names.count > limit {
            names = Array(names.prefix(limit))
        }
        return (names, Annotations())
    }

    /// head_read.go:155 — `if h.maxt < h.head.MinTime() || h.mint > h.head.MaxTime()`.
    ///
    /// An empty store leaves the sentinels as they start, so the gate closes:
    /// upstream's empty head reports `MinTime() == math.MaxInt64` and
    /// `MaxTime() == math.MinInt64` for the same reason.
    private var overlapsStoreRange: Bool {
        var storeMinT = Int64.max
        var storeMaxT = Int64.min
        for entry in entries {
            if let first = entry.samples.first { storeMinT = Swift.min(storeMinT, first.t) }
            if let last = entry.samples.last { storeMaxT = Swift.max(storeMaxT, last.t) }
        }
        return !(maxt < storeMinT || mint > storeMaxT)
    }

    /// Nothing to release: the snapshot is a value.
    public func close() throws {}
}

/// A ``SeriesSet`` over a fixed list of series.
///
/// Positioned before the first element, like every Go series set: `at()` is only
/// legal after a `next()` that returned true.
public final class MemSeriesSet: SeriesSet {
    private let series: [any Series]
    private var idx = -1

    public init(_ series: [any Series]) { self.series = series }

    public func next() -> Bool {
        idx += 1
        return idx < series.count
    }

    public func at() -> (any Series)? {
        guard idx >= 0, idx < series.count else { return nil }
        return series[idx]
    }

    public func err() -> (any Error)? { nil }
    public func warnings() -> Annotations { Annotations() }
}
