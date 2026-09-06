//===----------------------------------------------------------------------===//
// Ported from storage/merge.go @ v3.13.2 — the whole file.
//
// The vertical merge: several queriers over the SAME time range, whose series
// have to be interleaved by label set and then, where two of them carry the same
// series, by timestamp. `db.go` merges the Head with the persisted blocks
// through this (§7j); `fanout.go` merges local storage with remote read.
//
// ## The three levels, and where each one's tie-break lives
//
//   1. `mergeGenericQuerier.Select` fans out and wraps the result in a LAZY set,
//      so nothing runs until the caller iterates.
//   2. `genericMergeSeriesSet` heap-merges the per-querier sets BY LABEL SET,
//      popping every set whose current series has the label set at the top.
//   3. the popped sets' series are handed to a `VerticalSeriesMergeFunc` —
//      `ChainedSeriesMerge` for samples, `NewCompactingChunkSeriesMerger` or
//      `NewConcatenatingChunkSeriesMerger` for chunks.
//
// **The heap's tie-break at level 2 is observable at level 3.** Two sets whose
// current series have EQUAL labels compare equal, so which one is popped first
// is decided by the heap's internal layout — and `chainSampleIterator` keeps the
// FIRST sample it sees at a given timestamp and drops the rest. So a duplicate
// timestamp with two different values resolves to whichever querier the heap
// happened to order first. That is why `GoHeap` is Go's algorithm rather than
// any heap (see its header), and why the corpus's overlap cases pin values and
// not just timestamps.
//
// ## Exception 30 — the generics
//
// `generic.go`'s header has the reasoning. Everything below that Go writes
// against `genericSeriesSet`/`Labels` is written here against a generic element
// type, so the unchecked downcasts are gone.
//
// ## Exception 33 — `concurrentSelect` is not concurrent here
//
// Upstream runs the per-querier `Select`s in goroutines whenever there is at
// least one secondary querier, collecting the resulting sets off an UNBUFFERED
// channel — so `seriesSets` ends up in *completion* order, which is scheduler
// dependent. Since that order feeds the level-2 heap and the level-2 heap
// decides the level-3 tie-break, upstream's own output is not deterministic for
// a query that has a secondary querier AND a duplicate timestamp carrying
// different values.
//
// This port always selects in querier order (primaries then secondaries), which
// is exactly the non-concurrent branch. The reasons, in order of weight:
//
//   - there is no contract to be byte-exact against in the concurrent branch, so
//     reproducing the goroutines would buy nondeterminism, not fidelity;
//   - ADR-3 says the query path is synchronous and non-`Sendable`, and a
//     `Querier` is not `Sendable`;
//   - the TODO on the field says "Remove once remote queries are asynchronous".
//
// The corpus keeps this honest rather than hiding it: cases that pin a duplicate
// timestamp with differing values use PRIMARIES ONLY, where upstream is
// sequential and deterministic. See PORTING.md exception 33 and quirk 215.
//===----------------------------------------------------------------------===//

public import PromLabels
public import PromAnnotations
public import PromChunkEnc
public import PromChunks
public import PromHistogram
public import GoCompat

// MARK: - The merging queriers

/// Go: `mergeGenericQuerier`.
public final class MergeGenericQuerier<E: LabelsProvider>: GenericQuerier {
    let queriers: [any GenericQuerier<E>]
    /// Go: `mergeFn` — used when two queriers' `Select`s return the same labels.
    let mergeFn: GenericSeriesMergeFunc<E>

    init(queriers: [any GenericQuerier<E>], mergeFn: @escaping GenericSeriesMergeFunc<E>) {
        self.queriers = queriers
        self.mergeFn = mergeFn
    }

    /// Go: `Select`.
    ///
    /// `sortSeries` is IGNORED and `true` passed down instead — upstream's
    /// comment is "We need to sort for merge to work". A caller that asked for
    /// unsorted output still gets sorted output from a merge querier.
    public func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any GenericSeriesSet<E> {
        var seriesSets: [any GenericSeriesSet<E>] = []
        seriesSets.reserveCapacity(queriers.count)
        let limit = hints?.limit ?? 0
        for querier in queriers {
            // merge.go:141 — sorted, always.
            seriesSets.append(
                querier.select(ctx, sortSeries: true, hints: hints, matchers: matchers))
        }
        // merge.go:155's `matchersCopy` guards against a querier that mutates
        // the slice it is handed. Swift arrays are values, so every querier
        // already got its own copy.
        let mergeFn = self.mergeFn
        return LazyGenericSeriesSet<E> {
            let s = newGenericMergeSeriesSet(seriesSets, limit, mergeFn)
            return (s, s.next())
        }
    }

    /// Go: `LabelValues`.
    ///
    /// **The warnings are DROPPED on error.** merge.go:199 returns
    /// `nil, nil, fmt.Errorf(...)`, discarding the `ws` that `mergeResults`
    /// accumulated on the way to the failure — including warnings from queriers
    /// that succeeded. Reproduced, not fixed.
    public func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) {
        do {
            return try mergeResults(queriers, hints) { q in
                try q.labelValues(ctx, name: name, hints: hints, matchers: matchers)
            }
        } catch let e as MergeResultsFailure {
            throw MergeQuerierError.labelValues(name: name, underlying: e.underlying)
        }
    }

    /// Go: `LabelNames`.
    public func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) {
        do {
            let r = try mergeResults(queriers, hints) { q in
                let n = try q.labelNames(ctx, hints: hints, matchers: matchers)
                return (values: n.names, warnings: n.warnings)
            }
            return (names: r.values, warnings: r.warnings)
        } catch let e as MergeResultsFailure {
            throw MergeQuerierError.labelNames(underlying: e.underlying)
        }
    }

    /// Go: `Close` — every querier is closed even after one fails, and the
    /// errors are JOINED.
    public func close() throws {
        var errs: [(any Error)?] = []
        for querier in queriers {
            do { try querier.close() } catch { errs.append(error) }
        }
        if let joined = goErrorsJoin(errs) { throw joined }
    }
}

/// Go: the two `fmt.Errorf` wrappers in `LabelValues`/`LabelNames`.
public enum MergeQuerierError: Error, CustomStringConvertible {
    case labelValues(name: String, underlying: any Error)
    case labelNames(underlying: any Error)

    public var description: String {
        switch self {
        case .labelValues(let name, let e):
            return "LabelValues() from merge generic querier for label \(name): \(e)"
        case .labelNames(let e):
            return "LabelNames() from merge generic querier: \(e)"
        }
    }
}

/// Not in Go: the carrier that lets `mergeResults` report a failure through
/// `throws` while `LabelValues`/`LabelNames` still recognise it as theirs to
/// wrap. Go returns a triple, so it needs no such thing.
struct MergeResultsFailure: Error {
    let underlying: any Error
}

/// Go: `NewMergeQuerier`.
///
/// The switch is the interesting part and is pinned by the corpus's
/// `querierKind` field. `filterQueriers` drops nils and `noopQuerier`s FIRST, so
/// `NewMergeQuerier([noop, q], nil, f)` returns `q` itself, unwrapped — not a
/// merge querier over one input.
public func newMergeQuerier(
    primaries: [(any Querier)?], secondaries: [(any Querier)?],
    mergeFn: @escaping VerticalSeriesMergeFunc
) -> any Querier {
    let primaries = filterQueriers(primaries)
    let secondaries = filterQueriers(secondaries)

    switch (primaries.count, secondaries.count) {
    case (0, 0):
        return NoopQuerier()
    case (1, 0):
        return primaries[0]
    case (0, 1):
        return QuerierAdapter(newSecondaryQuerierFrom(secondaries[0]))
    default:
        break
    }

    var queriers: [any GenericQuerier<AnySeries>] = []
    queriers.reserveCapacity(primaries.count + secondaries.count)
    for q in primaries { queriers.append(newGenericQuerierFrom(q)) }
    for q in secondaries { queriers.append(newSecondaryQuerierFrom(q)) }

    return QuerierAdapter(
        MergeGenericQuerier(queriers: queriers, mergeFn: seriesMergerAdapter(mergeFn)))
}

/// Go: `filterQueriers`.
func filterQueriers(_ qs: [(any Querier)?]) -> [any Querier] {
    var ret: [any Querier] = []
    ret.reserveCapacity(qs.count)
    for q in qs {
        guard let q else { continue }
        if q is NoopQuerier { continue }
        ret.append(q)
    }
    return ret
}

/// Go: `NewMergeChunkQuerier`.
public func newMergeChunkQuerier(
    primaries: [(any ChunkQuerier)?], secondaries: [(any ChunkQuerier)?],
    mergeFn: @escaping VerticalChunkSeriesMergeFunc
) -> any ChunkQuerier {
    let primaries = filterChunkQueriers(primaries)
    let secondaries = filterChunkQueriers(secondaries)

    switch (primaries.count, secondaries.count) {
    case (0, 0):
        return NoopChunkQuerier()
    case (1, 0):
        return primaries[0]
    case (0, 1):
        return ChunkQuerierAdapter(newSecondaryQuerierFromChunk(secondaries[0]))
    default:
        break
    }

    var queriers: [any GenericQuerier<AnyChunkSeries>] = []
    queriers.reserveCapacity(primaries.count + secondaries.count)
    for q in primaries { queriers.append(newGenericQuerierFromChunk(q)) }
    for q in secondaries { queriers.append(newSecondaryQuerierFromChunk(q)) }

    return ChunkQuerierAdapter(
        MergeGenericQuerier(queriers: queriers, mergeFn: chunkSeriesMergerAdapter(mergeFn)))
}

/// Go: `filterChunkQueriers`.
func filterChunkQueriers(_ qs: [(any ChunkQuerier)?]) -> [any ChunkQuerier] {
    var ret: [any ChunkQuerier] = []
    ret.reserveCapacity(qs.count)
    for q in qs {
        guard let q else { continue }
        if q is NoopChunkQuerier { continue }
        ret.append(q)
    }
    return ret
}

// MARK: - Label merging

/// Go: `mergeResults` — a recursive binary merge sort over the queriers.
///
/// Three things to keep:
///
///   - the recursion SPLITS BY HALF (`labelGenericQueriers.SplitByHalf`) rather
///     than folding left, so the limit is applied at every level of the tree and
///     not just at the end. That is what makes `truncateToLimit` appear three
///     times per call.
///   - the warnings accumulate ACROSS the error return: `ws.Merge(w)` runs
///     before the `if err != nil`, and the error path returns `nil, ws, err`. It
///     is the caller that then throws them away.
///   - a single querier is called DIRECTLY and its result is not truncated here
///     at all. The limit is the querier's own to apply at the leaf.
func mergeResults<E: LabelsProvider>(
    _ lq: [any GenericQuerier<E>], _ hints: LabelHints?,
    _ resultsFn: (any GenericQuerier<E>) throws -> (values: [String], warnings: Annotations)
) throws -> (values: [String], warnings: Annotations) {
    if lq.isEmpty {
        return ([], Annotations())
    }
    if lq.count == 1 {
        return try resultsFn(lq[0])
    }
    let i = lq.count / 2
    let a = Array(lq[0..<i])
    let b = Array(lq[i...])

    var ws = Annotations()
    var s1: [String]
    do {
        let r = try mergeResults(a, hints, resultsFn)
        ws.merge(r.warnings)
        s1 = r.values
    } catch let e as MergeResultsFailure {
        throw e
    } catch {
        throw MergeResultsFailure(underlying: error)
    }
    var s2: [String]
    do {
        let r = try mergeResults(b, hints, resultsFn)
        ws.merge(r.warnings)
        s2 = r.values
    } catch let e as MergeResultsFailure {
        throw e
    } catch {
        throw MergeResultsFailure(underlying: error)
    }

    s1 = truncateToLimit(s1, hints)
    s2 = truncateToLimit(s2, hints)

    var merged = mergeStrings(s1, s2)
    merged = truncateToLimit(merged, hints)

    return (merged, ws)
}

/// Go: `mergeStrings` — a sorted merge that DEDUPLICATES equal heads.
func mergeStrings(_ a: [String], _ b: [String]) -> [String] {
    var res: [String] = []
    res.reserveCapacity(max(a.count, b.count) * 10 / 9)

    var i = 0
    var j = 0
    while i < a.count && j < b.count {
        if a[i] == b[j] {
            res.append(a[i])
            i += 1
            j += 1
        } else if goStringLess(a[i], b[j]) {
            res.append(a[i])
            i += 1
        } else {
            res.append(b[j])
            j += 1
        }
    }

    res.append(contentsOf: a[i...])
    res.append(contentsOf: b[j...])
    return res
}

/// ADR-10: Go's `<` on strings is a BYTE comparison; Swift's is Unicode
/// collation. `mergeStrings` merges two lists the queriers sorted Go's way, so
/// comparing them Swift's way would interleave them wrongly for any label value
/// where the two orders disagree.
///
/// `PromIndex` exports the same predicate as `goStringLessBytes`, but `PromIndex`
/// depends on `PromStorage` and not the other way round, so it cannot be reached
/// from here.
func goStringLess(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}

/// Go: `truncateToLimit`.
func truncateToLimit(_ s: [String], _ hints: LabelHints?) -> [String] {
    if let hints, hints.limit > 0, s.count > hints.limit {
        return Array(s[0..<hints.limit])
    }
    return s
}

// MARK: - The merged series sets

/// Go: `VerticalSeriesMergeFunc`.
public typealias VerticalSeriesMergeFunc = ([any Series]) -> (any Series)?

/// Go: `VerticalChunkSeriesMergeFunc`.
public typealias VerticalChunkSeriesMergeFunc = ([any ChunkSeries]) -> (any ChunkSeries)?

/// Go: `NewMergeSeriesSet`. A `limit` of 0 disables the limit.
public func newMergeSeriesSet(
    _ sets: [any SeriesSet], _ limit: Int, _ mergeFunc: @escaping VerticalSeriesMergeFunc
) -> any SeriesSet {
    let genericSets: [any GenericSeriesSet<AnySeries>] = sets.map { GenericSeriesSetAdapter($0) }
    return SeriesSetAdapter(
        newGenericMergeSeriesSet(genericSets, limit, seriesMergerAdapter(mergeFunc)))
}

/// Go: `NewMergeChunkSeriesSet`.
public func newMergeChunkSeriesSet(
    _ sets: [any ChunkSeriesSet], _ limit: Int,
    _ mergeFunc: @escaping VerticalChunkSeriesMergeFunc
) -> any ChunkSeriesSet {
    let genericSets: [any GenericSeriesSet<AnyChunkSeries>] = sets.map {
        GenericChunkSeriesSetAdapter($0)
    }
    return ChunkSeriesSetAdapter(
        newGenericMergeSeriesSet(genericSets, limit, chunkSeriesMergerAdapter(mergeFunc)))
}

/// Go: `newGenericMergeSeriesSet`.
///
/// Two behaviours worth stating:
///
///   - a SINGLE set is returned unwrapped, so the limit and the merge function
///     do not apply to it at all. `NewMergeSeriesSet([s], 1, f)` is `s`.
///   - the sets are PRE-ADVANCED here, before anything is returned, and a set
///     that reports an error during that advance collapses the whole merge into
///     an `errorOnlySeriesSet`. The advance happens even for sets pushed after
///     the failing one, because the `Err()` check is inside the loop and returns
///     immediately — so sets EARLIER in the list have been advanced and later
///     ones have not.
public func newGenericMergeSeriesSet<E: LabelsProvider>(
    _ sets: [any GenericSeriesSet<E>], _ seriesLimit: Int,
    _ mergeFunc: @escaping GenericSeriesMergeFunc<E>
) -> any GenericSeriesSet<E> {
    if sets.count == 1 {
        return sets[0]
    }

    // Pre-advance, so the label under each set's cursor can be introspected.
    var h = GenericSeriesSetHeap<E>()
    for set in sets {
        if set.next() {
            h.push(set)
        }
        if let err = set.err() {
            return ErrorOnlySeriesSet<E>(err)
        }
    }
    return GenericMergeSeriesSet(
        mergeFunc: mergeFunc, sets: sets, heap: h, seriesLimit: seriesLimit)
}

/// Go: `genericMergeSeriesSet`.
public final class GenericMergeSeriesSet<E: LabelsProvider>: GenericSeriesSet {
    private var currentLabels = Labels.empty
    private let mergeFunc: GenericSeriesMergeFunc<E>

    private var heap: GenericSeriesSetHeap<E>
    private let sets: [any GenericSeriesSet<E>]
    private var currentSets: [any GenericSeriesSet<E>] = []
    private let seriesLimit: Int
    /// Go: `mergedSeries` — the total number of series merged AND RETURNED.
    private var mergedSeries = 0

    init(
        mergeFunc: @escaping GenericSeriesMergeFunc<E>, sets: [any GenericSeriesSet<E>],
        heap: GenericSeriesSetHeap<E>, seriesLimit: Int
    ) {
        self.mergeFunc = mergeFunc
        self.sets = sets
        self.heap = heap
        self.seriesLimit = seriesLimit
    }

    /// Go: `Next`.
    ///
    /// The outer loop exists for a reason upstream spells out: "If, for the
    /// current label set, all the next series sets come from failed remote
    /// storage sources, we want to keep trying with the next label set." A
    /// failed secondary contributes a set that reports `false` forever, so the
    /// pops can produce an empty `currentSets` and the loop has to go round.
    public func next() -> Bool {
        if seriesLimit > 0 && mergedSeries >= seriesLimit {
            return false
        }

        while true {
            // Re-advance the sets consumed by the previous `Next`.
            for set in currentSets {
                if set.next() {
                    heap.push(set)
                }
            }

            if heap.isEmpty {
                return false
            }

            currentSets.removeAll(keepingCapacity: true)
            currentLabels = heap.peek().at()?.labels() ?? Labels.empty
            while !heap.isEmpty,
                Labels.compare(currentLabels, heap.peek().at()?.labels() ?? Labels.empty) == 0
            {
                currentSets.append(heap.pop())
            }

            if !currentSets.isEmpty {
                break
            }
        }
        mergedSeries += 1
        return true
    }

    /// Go: `At`.
    ///
    /// The single-set case bypasses the merge function entirely, so a merge over
    /// non-overlapping queriers never pays for `ChainedSeriesMerge` and never
    /// wraps the series in a `SeriesEntry`.
    public func at() -> E? {
        if currentSets.count == 1 {
            return currentSets[0].at()
        }
        var series: [E] = []
        series.reserveCapacity(currentSets.count)
        for set in currentSets {
            guard let s = set.at() else { continue }
            series.append(s)
        }
        return mergeFunc(series)
    }

    /// Go: `Err` — the FIRST set with an error, in the sets' original order.
    public func err() -> (any Error)? {
        for set in sets {
            if let err = set.err() { return err }
        }
        return nil
    }

    /// Go: `Warnings` — every set's, merged.
    public func warnings() -> Annotations {
        var ws = Annotations()
        for set in sets {
            ws.merge(set.warnings())
        }
        return ws
    }
}

/// Go: `genericSeriesSetHeap`, on `container/heap`.
///
/// `Less` compares LABEL SETS only, so two sets positioned on the same series
/// compare equal and the heap's own tie-break decides which comes out first.
/// See the file header: that decision is visible in the merged samples, which is
/// why this runs on ``GoHeap`` — Go's own sift order — rather than on any heap.
struct GenericSeriesSetHeap<E: LabelsProvider> {
    var items: [any GenericSeriesSet<E>] = []

    var isEmpty: Bool { items.isEmpty }

    func peek() -> any GenericSeriesSet<E> { items[0] }

    /// Go: `Less`. A set positioned past its end has no `At()`; Go would panic
    /// there, and nothing pushes such a set, so the empty label set is a
    /// placeholder that keeps the comparator total.
    private func less(_ i: Int, _ j: Int) -> Bool {
        let a = items[i].at()?.labels() ?? Labels.empty
        let b = items[j].at()?.labels() ?? Labels.empty
        return Labels.compare(a, b) < 0
    }

    /// Go: `heap.Push`.
    mutating func push(_ set: any GenericSeriesSet<E>) {
        items.append(set)
        GoHeap.pushed(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
    }

    /// Go: `heap.Pop`.
    mutating func pop() -> any GenericSeriesSet<E> {
        GoHeap.popped(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
        return items.removeLast()
    }
}

/// Go: `samplesIteratorHeap` — ordered by the iterators' CURRENT timestamps.
struct SamplesIteratorHeap {
    var items: [any ChunkIterator] = []

    var isEmpty: Bool { items.isEmpty }

    /// Go: `Less`.
    private func less(_ i: Int, _ j: Int) -> Bool { items[i].atT() < items[j].atT() }

    mutating func push(_ it: any ChunkIterator) {
        items.append(it)
        GoHeap.pushed(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
    }

    mutating func pop() -> any ChunkIterator {
        GoHeap.popped(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
        return items.removeLast()
    }
}

/// Go: `chunkIteratorHeap` — by min time, then by max time.
struct ChunkIteratorHeap {
    var items: [any ChunkMetaIterator] = []

    var isEmpty: Bool { items.isEmpty }

    /// Go: `Less`.
    private func less(_ i: Int, _ j: Int) -> Bool {
        let at = items[i].at()
        let bt = items[j].at()
        if at.minTime == bt.minTime {
            return at.maxTime < bt.maxTime
        }
        return at.minTime < bt.minTime
    }

    mutating func push(_ it: any ChunkMetaIterator) {
        items.append(it)
        GoHeap.pushed(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
    }

    mutating func pop() -> any ChunkMetaIterator {
        GoHeap.popped(
            count: items.count, less: { self.less($0, $1) }, swap: { items.swapAt($0, $1) })
        return items.removeLast()
    }
}

// MARK: - ChainedSeriesMerge

/// Go: `ChainedSeriesMerge` — chain the samples of several same-labelled series
/// in timestamp order, keeping ONE sample per timestamp.
///
/// The labels come from `series[0]`, not from a merge of all of them: the
/// contract is that they are already equal.
public func chainedSeriesMerge(_ series: [any Series]) -> (any Series)? {
    if series.isEmpty {
        return nil
    }
    return SeriesEntry(lset: series[0].labels()) { it in
        chainSampleIteratorFromSeries(it, series)
    }
}

/// Go: `chainSampleIterator`.
public final class ChainSampleIterator: ChunkIterator {
    var iterators: [any ChunkIterator] = []
    /// Go: `h samplesIteratorHeap`. **Nil and empty are different states**: a nil
    /// heap means "not initialised", which is what `Next` branches on, and
    /// `Seek` assigns an EMPTY heap precisely so a following `Next` does not
    /// re-initialise.
    var h: SamplesIteratorHeap?

    var curr: (any ChunkIterator)?
    var lastT: Int64 = Int64.min

    /// Whether the previous and current samples are neighbours within the same
    /// base iterator. Only read by the two histogram accessors.
    var consecutive = false

    /// The iterators the previous use left behind, offered back for reuse.
    var reuseSlots: [any ChunkIterator] = []

    init() {}

    /// Go: `getChainSampleIterator` — reuse the memory of `it` when it already
    /// is a chain iterator.
    ///
    /// Go's reuse is capacity-driven: `cap(csi.iterators) < length` reallocates
    /// (so NO iterator is offered back), otherwise it reslices (so the first
    /// `length` are). Modelled on the count, which for a slice built with
    /// `make(_, length)` is the capacity.
    static func get(_ it: (any ChunkIterator)?, _ length: Int) -> ChainSampleIterator {
        let csi = (it as? ChainSampleIterator) ?? ChainSampleIterator()
        if csi.iterators.count < length {
            csi.reuseSlots = []
        } else {
            csi.reuseSlots = Array(csi.iterators[0..<length])
        }
        csi.iterators = []
        csi.h = nil
        csi.lastT = Int64.min
        return csi
    }

    /// Go: `Seek`.
    ///
    /// The no-op check is `c.lastT >= t`, and its `return c.curr.Seek(c.lastT)`
    /// is not a typo: seeking the CURRENT iterator to the timestamp it is
    /// already at re-reports the value type without moving. Any iterator that
    /// errors during the fan-out aborts the whole seek, leaving `curr` at
    /// whatever it was.
    public func seek(_ t: Int64) -> ValueType {
        if let curr, lastT >= t {
            return curr.seek(lastT)
        }
        // "Callers of Seek usually aren't interested anyway."
        consecutive = false
        h = SamplesIteratorHeap()
        for iter in iterators {
            if iter.seek(t) == .none {
                if iter.err() != nil {
                    // Any iterator reporting an error aborts the whole seek.
                    return .none
                }
                continue
            }
            h!.push(iter)
        }
        if !h!.isEmpty {
            let popped = h!.pop()
            curr = popped
            lastT = popped.atT()
            return popped.seek(lastT)
        }
        curr = nil
        return .none
    }

    public func at() -> (Int64, Double) {
        guard let curr else {
            preconditionFailure(
                "chainSampleIterator.At called before first .Next or after .Next returned false.")
        }
        return curr.at()
    }

    /// Go: `AtHistogram`.
    ///
    /// The counter-reset hint is DOWNGRADED when the sample is not a direct
    /// neighbour of the previous one in the same base iterator, because a reset
    /// cannot be inferred across a switch of source. A gauge histogram is exempt
    /// — it has no counter to reset.
    public func atHistogram(_ reuse: Histogram?) -> (Int64, Histogram?) {
        guard let curr else {
            preconditionFailure(
                "chainSampleIterator.AtHistogram called before first .Next or after .Next returned false."
            )
        }
        var (t, h) = curr.atHistogram(reuse)
        if !consecutive, var hh = h, hh.counterResetHint != .gaugeType {
            hh.counterResetHint = .unknownCounterReset
            h = hh
        }
        return (t, h)
    }

    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        guard let curr else {
            preconditionFailure(
                "chainSampleIterator.AtFloatHistogram called before first .Next or after .Next returned false."
            )
        }
        var (t, fh) = curr.atFloatHistogram(reuse)
        if !consecutive, var ff = fh, ff.counterResetHint != .gaugeType {
            ff.counterResetHint = .unknownCounterReset
            fh = ff
        }
        return (t, fh)
    }

    public func atT() -> Int64 {
        guard let curr else {
            preconditionFailure(
                "chainSampleIterator.AtT called before first .Next or after .Next returned false.")
        }
        return curr.atT()
    }

    public func atST() -> Int64 {
        guard let curr else {
            preconditionFailure(
                "chainSampleIterator.AtST called before first .Next or after .Next returned false.")
        }
        return curr.atST()
    }

    /// Go: `Next`.
    ///
    /// The first call installs `iterators[0]` as `curr` WITHOUT advancing it,
    /// because the loop below calls `curr.Next()` as its first act; every other
    /// iterator is advanced once and pushed. An error from any of them aborts —
    /// except from `iterators[0]`, whose error is caught by the loop.
    public func next() -> ValueType {
        var currT: Int64 = 0
        var currValueType = ValueType.none
        var iteratorChanged = false

        if h == nil {
            iteratorChanged = true
            h = SamplesIteratorHeap()
            // merge.go:620 — `c.iterators[0]`, which indexes out of range for an
            // empty chain. Go panics; nothing constructs one.
            curr = iterators.first
            for iter in iterators.dropFirst() {
                if iter.next() == .none {
                    if iter.err() != nil {
                        // Abort. `iterators[0]`'s own error is caught below.
                        return .none
                    }
                } else {
                    h!.push(iter)
                }
            }
        }

        guard curr != nil else { return .none }

        while true {
            currValueType = curr!.next()

            if currValueType == .none {
                if curr!.err() != nil {
                    return .none
                }
                if h!.isEmpty {
                    curr = nil
                    return .none
                }
            } else {
                currT = curr!.atT()
                if currT == lastT {
                    // Same timestamp as the last emitted sample: dropped.
                    continue
                }
                if h!.isEmpty {
                    // The only iterator left; no need to consult the heap.
                    break
                }
                let nextT = h!.items[0].atT()
                if currT < nextT {
                    break
                }
                // `curr` does not hold the smallest timestamp; put it back.
                h!.push(curr!)
            }

            let popped = h!.pop()
            curr = popped
            iteratorChanged = true
            currT = popped.atT()
            // merge.go:677 — a `Seek` to the timestamp it is already at, which
            // re-reports the value type. Not dead code: the underlying iterator
            // is what decides what that type is.
            currValueType = popped.seek(currT)
            if currT != lastT {
                break
            }
        }

        consecutive = !iteratorChanged
        lastT = currT
        return currValueType
    }

    /// Go: `Err` — every iterator's error, joined. Note it does NOT stop at the
    /// first, and it includes nils, which `errors.Join` then drops.
    public func err() -> (any Error)? {
        goErrorsJoin(iterators.map { $0.err() })
    }
}

/// Go: `ChainSampleIteratorFromSeries`.
public func chainSampleIteratorFromSeries(
    _ it: (any ChunkIterator)?, _ series: [any Series]
) -> any ChunkIterator {
    let csi = ChainSampleIterator.get(it, series.count)
    var built: [any ChunkIterator] = []
    built.reserveCapacity(series.count)
    for (i, s) in series.enumerated() {
        built.append(s.iterator(i < csi.reuseSlots.count ? csi.reuseSlots[i] : nil))
    }
    csi.iterators = built
    return csi
}

/// Go: `ChainSampleIteratorFromIterables`.
public func chainSampleIteratorFromIterables(
    _ it: (any ChunkIterator)?, _ iterables: [any ChunkIterable]
) -> any ChunkIterator {
    let csi = ChainSampleIterator.get(it, iterables.count)
    var built: [any ChunkIterator] = []
    built.reserveCapacity(iterables.count)
    for (i, c) in iterables.enumerated() {
        built.append(c.iterator(i < csi.reuseSlots.count ? csi.reuseSlots[i] : nil))
    }
    csi.iterators = built
    return csi
}

/// Go: `ChainSampleIteratorFromIterators`.
public func chainSampleIteratorFromIterators(
    _ it: (any ChunkIterator)?, _ iterators: [any ChunkIterator]
) -> any ChunkIterator {
    let csi = ChainSampleIterator.get(it, 0)
    csi.iterators = iterators
    return csi
}

// MARK: - The chunk mergers

/// Go: `NewCompactingChunkSeriesMerger`.
///
/// Merges same-labelled chunk series into one, COMPACTING overlaps: a run of
/// time-overlapping chunks is decoded, merged by the sample merge function, and
/// re-encoded into as many 120-sample chunks as it takes.
public func newCompactingChunkSeriesMerger(
    _ mergeFunc: @escaping VerticalSeriesMergeFunc
) -> VerticalChunkSeriesMergeFunc {
    { series in
        if series.isEmpty {
            return nil
        }
        return ChunkSeriesEntry(lset: series[0].labels()) { _ in
            var iterators: [any ChunkMetaIterator] = []
            iterators.reserveCapacity(series.count)
            for s in series {
                iterators.append(s.iterator(nil))
            }
            return CompactChunkIterator(mergeFunc: mergeFunc, iterators: iterators)
        }
    }
}

/// Go: `compactChunkIterator`.
public final class CompactChunkIterator: ChunkMetaIterator {
    private let mergeFunc: VerticalSeriesMergeFunc
    private let iterators: [any ChunkMetaIterator]

    /// Nil until the first `next()`, as in Go.
    private var h: ChunkIteratorHeap?

    private var error: (any Error)?
    private var curr = Meta(minTime: 0, maxTime: 0)

    init(mergeFunc: @escaping VerticalSeriesMergeFunc, iterators: [any ChunkMetaIterator]) {
        self.mergeFunc = mergeFunc
        self.iterators = iterators
    }

    public func at() -> Meta { curr }

    /// Go: `Next`.
    ///
    /// The de-duplication is EXACT-MATCH-ONLY: a chunk with the same bounds and
    /// the same bytes as the previous one is dropped without decoding. Anything
    /// else that overlaps is decoded and merged, however small the difference.
    ///
    /// `oMaxTime` grows as overlapping chunks are absorbed, so the run extends
    /// transitively — chunk C overlapping B which overlaps A joins the same
    /// merge even if C does not touch A.
    ///
    /// One shape worth noticing: the comparison is against `prev`, the last
    /// chunk ADDED to the overlap, not against `c.curr`. So a run of three
    /// identical chunks collapses, but A, B, A does not — the second A differs
    /// from B and is merged in.
    public func next() -> Bool {
        if h == nil {
            h = ChunkIteratorHeap()
            for iter in iterators {
                if iter.next() {
                    h!.push(iter)
                }
            }
        }
        if h!.isEmpty {
            return false
        }

        let iter = h!.pop()
        curr = iter.at()
        if iter.next() {
            h!.push(iter)
        }

        var overlapping: [any Series] = []
        var oMaxTime = curr.maxTime
        var prev = curr

        while !h!.isEmpty {
            let next = h!.items[0].at()
            if next.minTime > oMaxTime {
                break
            }

            // Only a PERFECT duplicate is skipped.
            if next.minTime != prev.minTime || next.maxTime != prev.maxTime
                || (next.chunk?.bytes ?? []) != (prev.chunk?.bytes ?? [])
            {
                overlapping.append(newChunkToSeriesDecoder(Labels.empty, next))
                if next.maxTime > oMaxTime {
                    oMaxTime = next.maxTime
                }
                prev = next
            }

            let popped = h!.pop()
            if popped.next() {
                h!.push(popped)
            }
        }
        if overlapping.isEmpty {
            return true
        }

        // The current chunk is added LAST, after the ones that overlapped it.
        overlapping.append(newChunkToSeriesDecoder(Labels.empty, curr))
        guard let merged = mergeFunc(overlapping) else {
            error = CompactChunkIteratorError.mergeReturnedNothing
            return false
        }
        let encoded = newSeriesToChunkEncoder(merged).iterator(nil)
        if !encoded.next() {
            if let e = encoded.err() {
                error = e
                return false
            }
            preconditionFailure("unexpected seriesToChunkEncoder lack of iterations")
        }
        curr = encoded.at()
        if encoded.next() {
            h!.push(encoded)
        }
        return true
    }

    /// Go: `Err` — the iterators' errors joined, with the iterator's own error
    /// appended LAST.
    public func err() -> (any Error)? {
        var errs: [(any Error)?] = iterators.map { $0.err() }
        errs.append(error)
        return goErrorsJoin(errs)
    }
}

/// Not in Go: Go's merge function returns a nil interface here and the code
/// dereferences it, panicking. The port reports it.
public enum CompactChunkIteratorError: Error, CustomStringConvertible, Equatable {
    case mergeReturnedNothing

    public var description: String {
        "compactChunkIterator: merge function returned no series"
    }
}

/// Go: `NewConcatenatingChunkSeriesMerger` — no compaction at all. "The
/// resultant stream of chunks for a series might be overlapping and unsorted."
public func newConcatenatingChunkSeriesMerger() -> VerticalChunkSeriesMergeFunc {
    { series in
        if series.isEmpty {
            return nil
        }
        return ChunkSeriesEntry(lset: series[0].labels()) { _ in
            var iterators: [any ChunkMetaIterator] = []
            iterators.reserveCapacity(series.count)
            for s in series {
                iterators.append(s.iterator(nil))
            }
            return ConcatenatingChunkIterator(iterators: iterators)
        }
    }
}

/// Go: `concatenatingChunkIterator`.
public final class ConcatenatingChunkIterator: ChunkMetaIterator {
    private let iterators: [any ChunkMetaIterator]
    private var idx = 0
    private var curr = Meta(minTime: 0, maxTime: 0)

    init(iterators: [any ChunkMetaIterator]) { self.iterators = iterators }

    public func at() -> Meta { curr }

    /// Go: `Next` — recursive, and it STOPS on an erroring iterator rather than
    /// skipping to the next one.
    public func next() -> Bool {
        if idx >= iterators.count {
            return false
        }
        if iterators[idx].next() {
            curr = iterators[idx].at()
            return true
        }
        if iterators[idx].err() != nil {
            return false
        }
        idx += 1
        return next()
    }

    public func err() -> (any Error)? {
        goErrorsJoin(iterators.map { $0.err() })
    }
}
