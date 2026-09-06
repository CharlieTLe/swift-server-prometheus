//===----------------------------------------------------------------------===//
// What the merge corpus cannot reach, asserted by hand.
//
// Three kinds of thing end up here, and the rule for each is the same: the corpus is the contract
// wherever Go can be made to produce an answer, so this file holds only the cases where it cannot.
//
//   1. **A behaviour upstream reaches by PANICKING.** `secondaryQuerier.Select` after the first
//      `Next()` panics in Go, so the oracle cannot emit a case for it — a panic takes the fixture
//      generator with it. The port throws instead, and the message is Go's panic string verbatim,
//      so what is asserted here is the string.
//   2. **A rendering whose Go original is a Go MAP.** `errors.Join`'s member ORDER is deterministic
//      (it is a slice), but `Annotations`' is not, so the corpus sorts. The joined message's exact
//      shape is therefore pinned here rather than there.
//   3. **A constructor arm no realistic input reaches.** `ChainedSeriesMerge()` with no series, and
//      the two chunk mergers with none: upstream returns a nil interface that its own caller would
//      dereference, so the corpus can only ever call them with at least one series.
//===----------------------------------------------------------------------===//

import GoCompat
import PromAnnotations
import PromChunkEnc
import PromChunks
import PromLabels
import PromStorage
import Testing

/// A leaf querier that returns a set with one series and nothing else, so a secondary can be driven
/// past its first `Next()`.
private final class OneSeriesQuerier: Querier {
    func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        OneSeriesSet()
    }
    func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) { ([], Annotations()) }
    func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) { ([], Annotations()) }
    func close() throws {}
}

private final class OneSeriesSet: SeriesSet {
    private var done = false
    func next() -> Bool {
        if done { return false }
        done = true
        return true
    }
    func at() -> (any Series)? {
        newListSeries(Labels([Label("__name__", "x")]), [])
    }
    func err() -> (any Error)? { nil }
    func warnings() -> Annotations { Annotations() }
}

private struct NamedError: Error, CustomStringConvertible {
    let description: String
}

@Suite("storage: merge, the paths a Go-driven corpus cannot reach")
struct StorageMergeUnitTests {

    @Test("a secondary querier refuses a Select after the first Next, with Go's panic message")
    func secondarySelectAfterNext() throws {
        let sq = SecondaryQuerier(newGenericQuerierFrom(OneSeriesQuerier()))
        let ctx = GoContext.background()

        let first = sq.select(ctx, sortSeries: true, hints: nil, matchers: [])
        // The all-or-nothing pass runs here, which is what sets `done`.
        #expect(first.next())

        let second = sq.select(ctx, sortSeries: true, hints: nil, matchers: [])
        #expect(!second.next())
        #expect(
            String(describing: second.err() ?? NamedError(description: "<none>"))
                == "secondaryQuerier: Select invoked after first Next of any returned SeriesSet was done"
        )
    }

    @Test("errors.Join renders its members newline-separated and drops nils")
    func joinRendering() {
        #expect(goErrorsJoin([]) == nil)
        #expect(goErrorsJoin([nil, nil]) == nil)

        let one = goErrorsJoin([nil, NamedError(description: "a"), nil])
        #expect(String(describing: one!) == "a")

        let two = goErrorsJoin([NamedError(description: "a"), nil, NamedError(description: "b")])
        #expect(String(describing: two!) == "a\nb")

        let three = goErrorsJoin(
            [NamedError(description: "a"), NamedError(description: "b"),
             NamedError(description: "c")])
        #expect(String(describing: three!) == "a\nb\nc")
    }

    @Test("the three merge functions return nothing for no series")
    func emptyMerges() {
        #expect(chainedSeriesMerge([]) == nil)
        #expect(newCompactingChunkSeriesMerger(chainedSeriesMerge)([]) == nil)
        #expect(newConcatenatingChunkSeriesMerger()([]) == nil)
    }

    @Test("a plain error added to Annotations is a WARNING, and the last one wins")
    func plainAnnotation() {
        var ws = Annotations()
        ws.add(error: NamedError(description: "boom"))
        #expect(ws.countWarningsAndInfo() == (countWarnings: 1, countInfo: 0))
        #expect(ws.asErrors().map { String(describing: $0) } == ["boom"])

        // Deduplication is on the message, exactly as Go's `map[string]error` key is.
        ws.add(error: NamedError(description: "boom"))
        #expect(ws.count == 1)
    }

    @Test("NewMergeSeriesSet with one set returns that set unwrapped, limit and all")
    func singleSetShortcut() {
        // `newGenericMergeSeriesSet` short-circuits before the limit is stored, so a limit of 1
        // over a single two-series set still yields both. Upstream's shape, asserted here because
        // the corpus always goes through `NewMergeQuerier`, which never builds a one-set merge.
        let set = newMergeSeriesSet([TwoSeriesSet()], 1, chainedSeriesMerge)
        var n = 0
        while set.next() { n += 1 }
        #expect(n == 2)
    }
}

private final class TwoSeriesSet: SeriesSet {
    private var i = 0
    func next() -> Bool {
        i += 1
        return i <= 2
    }
    func at() -> (any Series)? {
        newListSeries(Labels([Label("__name__", "s\(i)")]), [])
    }
    func err() -> (any Error)? { nil }
    func warnings() -> Annotations { Annotations() }
}

// MARK: - secondaryQuerier's MULTI-SET behaviour

//===----------------------------------------------------------------------===//
// `secondaryQuerier`'s all-or-nothing rule is UNREACHABLE from `NewMergeQuerier`, and that is
// structural rather than a gap in the corpus.
//
// The rule only does anything when one secondary querier has produced SEVERAL sets, which means
// several `Select` calls on the same querier before the first `Next()`. `NewMergeQuerier` selects
// each querier exactly once, and so does `NewMergeChunkQuerier`; nothing in the tree selects twice.
// So no case the oracle can build through the exported entry points reaches `asyncSets[1]`, and six
// negative controls survived the first sweep for that single reason.
//
// Upstream reaches it only from `merge_test.go`, which calls the unexported `newSecondaryQuerierFrom`
// directly — and `secondary.go` cannot be lifted into `oracle/probe/` because `genericQuerier` and
// `genericSeriesSet` are unexported too, so the lift would not compile. Hand-written assertions are
// therefore the honest instrument here, and they are written against the SOURCE's stated contract
// ("consistent partial response strategy, where you have either full results or none") rather than
// against the port's behaviour.
//===----------------------------------------------------------------------===//

/// A querier whose successive `Select`s hand out successive prepared sets.
private final class ScriptedQuerier: Querier {
    private var sets: [any SeriesSet]
    private var i = 0

    init(_ sets: [any SeriesSet]) { self.sets = sets }

    func select(
        _ ctx: GoContext, sortSeries: Bool, hints: SelectHints?, matchers: [Matcher]
    ) -> any SeriesSet {
        defer { i += 1 }
        return sets[i]
    }
    func labelValues(
        _ ctx: GoContext, name: String, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (values: [String], warnings: Annotations) { ([], Annotations()) }
    func labelNames(
        _ ctx: GoContext, hints: LabelHints?, matchers: [Matcher]
    ) throws -> (names: [String], warnings: Annotations) { ([], Annotations()) }
    func close() throws {}
}

/// A set that yields `n` series named `<prefix>N`, optionally with warnings and a terminal error.
private final class ScriptedSet: SeriesSet {
    private let prefix: String
    private let n: Int
    private let warning: String?
    private let error: (any Error)?
    private var i = 0

    init(prefix: String, n: Int, warning: String? = nil, error: (any Error)? = nil) {
        self.prefix = prefix
        self.n = n
        self.warning = warning
        self.error = error
    }

    func next() -> Bool {
        if i >= n { return false }
        i += 1
        return true
    }
    func at() -> (any Series)? {
        newListSeries(Labels([Label("__name__", "\(prefix)\(i)")]), [])
    }
    func err() -> (any Error)? { error }
    func warnings() -> Annotations {
        var ws = Annotations()
        if let warning { ws.add(error: NamedError(description: warning)) }
        return ws
    }
}

private func warningTexts(_ ws: Annotations) -> [String] {
    ws.asErrors().map { String(describing: $0) }.sorted()
}

@Suite("storage: secondaryQuerier's all-or-nothing rule")
struct SecondaryQuerierMultiSetTests {

    @Test("one set failing empties every other set of the same querier")
    func allOrNothing() {
        let q = SecondaryQuerier(
            newGenericQuerierFrom(
                ScriptedQuerier([
                    ScriptedSet(prefix: "a", n: 2),
                    ScriptedSet(
                        prefix: "b", n: 0, warning: "b-warn",
                        error: NamedError(description: "b-err")),
                ])))
        let ctx = GoContext.background()
        let first = q.select(ctx, sortSeries: true, hints: nil, matchers: [])
        let second = q.select(ctx, sortSeries: true, hints: nil, matchers: [])

        // The FIRST set is the one the caller touched, so it carries the failure — even though it
        // is the SECOND set that failed. secondary.go:105's comment says so in as many words.
        #expect(!first.next())
        #expect(warningTexts(first.warnings()) == ["b-err", "b-warn"])
        #expect(first.err() == nil)

        // Every other set of the same querier is emptied, warnings and all.
        #expect(!second.next())
        #expect(warningTexts(second.warnings()) == [])
    }

    @Test("an exhausted set becomes a warnings-only set carrying its own warnings")
    func exhaustedSetsKeepTheirWarnings() {
        let q = SecondaryQuerier(
            newGenericQuerierFrom(
                ScriptedQuerier([
                    ScriptedSet(prefix: "a", n: 0, warning: "a-warn"),
                    ScriptedSet(prefix: "b", n: 0, warning: "b-warn"),
                ])))
        let ctx = GoContext.background()
        let first = q.select(ctx, sortSeries: true, hints: nil, matchers: [])
        let second = q.select(ctx, sortSeries: true, hints: nil, matchers: [])

        #expect(!first.next())
        #expect(warningTexts(first.warnings()) == ["a-warn"])
        #expect(!second.next())
        #expect(warningTexts(second.warnings()) == ["b-warn"])
    }

    @Test("the all-or-nothing pass runs exactly ONCE, however many sets are iterated")
    func onlyOnce() {
        let q = SecondaryQuerier(
            newGenericQuerierFrom(
                ScriptedQuerier([
                    ScriptedSet(prefix: "a", n: 3),
                    ScriptedSet(prefix: "b", n: 3),
                ])))
        let ctx = GoContext.background()
        let first = q.select(ctx, sortSeries: true, hints: nil, matchers: [])
        let second = q.select(ctx, sortSeries: true, hints: nil, matchers: [])

        // `first.Next()` runs the pass, which advances BOTH sets by one. The lazy wrapper then
        // reports "already positioned", so neither is advanced again.
        #expect(first.next())
        #expect(second.next())
        #expect(first.at()?.base.labels().description == "{__name__=\"a1\"}")
        #expect(second.at()?.base.labels().description == "{__name__=\"b1\"}")
    }

    @Test("the noop generic set is empty")
    func noopGenericSet() {
        let s = NoopGenericSeriesSet<AnySeries>()
        #expect(!s.next())
        #expect(s.at() == nil)
        #expect(s.err() == nil)
        #expect(s.warnings().isEmpty)
    }
}
