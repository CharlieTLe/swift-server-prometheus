//===----------------------------------------------------------------------===//
// Ported from storage/secondary.go @ v3.13.2 — everything except the `Searcher`
// half (`SearchLabelNames`, `SearchLabelValues`, `warningsOnErrorSearchSet`),
// which belongs with generic.go Part B and the HTTP API in Phase 9.
//
// **Why this is in the merge slice rather than its own.** `NewMergeQuerier`
// cannot be ported without it: its second and fourth arms call
// `newSecondaryQuerierFrom`, and the whole primary/secondary distinction — the
// one thing that makes `merge.go`'s error handling interesting — lives here.
// Splitting them would have left `NewMergeQuerier` unable to take a secondary,
// which is most of what a corpus wants to exercise.
//
// ## What a secondary querier is
//
// "Best effort": every failure except `Close` becomes a WARNING and the result
// becomes empty. Prometheus treats every remote storage as secondary.
//
// The subtle part is the ALL-OR-NOTHING rule, and it is the reason the sets are
// lazy. A single secondary querier can be `Select`ed several times, producing
// several sets. On the FIRST `Next()` of ANY of them, `once` drives every set
// this querier has produced through one `Next()` each:
//
//   - if one of them errors, the set whose `Next()` we are inside becomes a
//     warnings-only set carrying that error, and EVERY OTHER set of the same
//     querier is replaced by a noop set. So a partial response never mixes
//     results from before and after a failure.
//   - a set that merely ran out becomes a warnings-only set carrying whatever
//     warnings it had.
//
// Two consequences that read as bugs and are not:
//
//   - the error is attributed to the set the caller happened to touch first
//     (`curr`), not to the set that failed. Upstream's comment says so: "ensure
//     current one returning errors as warnings, and rest of the sets return
//     nothing".
//   - `Select` after that first `Next()` PANICS ("Select invoked after first
//     Next of any returned SeriesSet was done"), because `asyncSets` has already
//     been finalised. The port throws instead — see ``SecondaryQuerierError``.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromAnnotations
public import GoCompat

/// Go: the `panic` in `secondaryQuerier.Select`.
///
/// A trap would match Go more literally, but `Select` cannot throw in this
/// port's protocol (nor in Go's), so the failure is reported through the set:
/// `Select` returns an ``ErrorOnlySeriesSet`` carrying this. The message is
/// Go's panic string verbatim, so a caller printing it sees the same text.
public enum SecondaryQuerierError: Error, CustomStringConvertible, Equatable {
    case selectAfterFirstNext

    public var description: String {
        "secondaryQuerier: Select invoked after first Next of any returned SeriesSet was done"
    }
}

/// Go: `secondaryQuerier`.
///
/// Not goroutine-safe, exactly as upstream says.
public final class SecondaryQuerier<E: LabelsProvider>: GenericQuerier {
    private let base: any GenericQuerier<E>

    /// Go: `once sync.Once` + `done bool`. The port is single-threaded by ADR-3,
    /// so `once` is a plain flag rather than a `sync.Once`.
    private var onceDone = false
    private var done = false
    private var asyncSets: [any GenericSeriesSet<E>] = []

    public init(_ base: any GenericQuerier<E>) { self.base = base }

    /// Go: `LabelValues` — the error becomes a warning and the values go empty.
    ///
    /// secondary.go:57 returns `nil, w.Add(err), nil`, so the WARNINGS THE CALL
    /// ALREADY PRODUCED are kept and the error is appended to them. A port that
    /// returned a fresh annotation set would silently drop them.
    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        do {
            return try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)
        } catch {
            var w = Annotations()
            return ([], w.add(error: error))
        }
    }

    /// Go: `LabelNames`.
    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        do {
            return try base.labelNames(ctx, hints: hints, matchers: matchers)
        } catch {
            var w = Annotations()
            return ([], w.add(error: error))
        }
    }

    /// Go: `Select`.
    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any GenericSeriesSet<E> {
        if done {
            return ErrorOnlySeriesSet<E>(SecondaryQuerierError.selectAfterFirstNext)
        }

        asyncSets.append(
            base.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))
        let curr = asyncSets.count - 1
        return LazyGenericSeriesSet<E> { [self] in
            if !onceDone {
                onceDone = true
                // secondary.go:97 — one `Next()` per set, in Select order.
                for i in asyncSets.indices {
                    let set = asyncSets[i]
                    if set.next() { continue }
                    let ws = set.warnings()
                    if let err = set.err() {
                        // All-or-nothing: the CURRENT set carries the error as a
                        // warning, every other set of this querier goes noop.
                        var withErr = ws
                        withErr.add(error: err)
                        asyncSets[curr] = WarningsOnlySeriesSet<E>(withErr)
                        for j in asyncSets.indices where j != curr {
                            asyncSets[j] = NoopGenericSeriesSet<E>()
                        }
                        break
                    }
                    // Exhausted set.
                    asyncSets[i] = WarningsOnlySeriesSet<E>(ws)
                }
                done = true
            }

            // secondary.go:123 — a set that was REPLACED reports "no data"
            // (false), one that survived reports "already positioned" (true).
            let set = asyncSets[curr]
            if set is WarningsOnlySeriesSet<E> || set is NoopGenericSeriesSet<E> {
                return (set, false)
            }
            return (set, true)
        }
    }

    /// Go: `Close` is inherited from the embedded `genericQuerier` and is the
    /// one method whose error is NOT demoted to a warning.
    public func close() throws { try base.close() }
}

/// Go: `newSecondaryQuerierFrom`.
public func newSecondaryQuerierFrom(_ q: any Querier) -> any GenericQuerier<AnySeries> {
    SecondaryQuerier(newGenericQuerierFrom(q))
}

/// Go: `newSecondaryQuerierFromChunk`.
public func newSecondaryQuerierFromChunk(
    _ cq: any ChunkQuerier
) -> any GenericQuerier<AnyChunkSeries> {
    SecondaryQuerier(newGenericQuerierFromChunk(cq))
}
