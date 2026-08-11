//===----------------------------------------------------------------------===//
// `info(...)` behaviours that `info.test`'s 42 assertions do not reach.
//
// `Scripts/controls-info.sh` perturbed each of these and the exit gate stayed green. That is a corpus
// gap rather than dead code in every case here: `MemQuerier` honours the select hints
// (`MemQuerier.swift`'s two-stage filter), and upstream's own test file simply has no sample sitting
// on a window boundary, no metacharacter in an `instance` value, and no metric named exactly `_info`.
//
// Written as `.test` text through the runner rather than as engine calls, so the comparison, the
// loader and the annotation handling are the same ones the gate uses.
//===----------------------------------------------------------------------===//

import GoCompat
import PromQL
import PromQLParser
import PromQLTest
import Testing

@Suite("info: the edges info.test does not reach")
struct InfoEdgeTests {

    private func run(_ input: String) -> RunReport {
        let options = Options(enableExperimentalFunctions: true)
        let engine = Engine(
            EngineOpts(
                maxSamples: 50_000_000,
                timeout: GoDuration(nanoseconds: 100 * 1_000_000_000),
                lookbackDelta: GoDuration(nanoseconds: 5 * 60 * 1_000_000_000),
                noStepSubqueryIntervalFn: { _ in 60_000 },
                enableAtModifier: true, enableNegativeOffset: true,
                enableDelayedNameRemoval: true, parserOptions: options))
        return PromQLTestRunner(engine: engine, parser: Parser(options: options))
            .run(input, name: "synthetic")
    }

    private func expectClean(_ r: RunReport, _ passed: Int) {
        #expect(r.failed == 0, "\(r.failures)")
        #expect(r.skipped == 0, "\(r.skipReasons)")
        #expect(r.passed == passed)
    }

    /// **The info select hints only bite when the querier's own window is WIDER than theirs**, and
    /// missing that is why the first three versions of these tests proved nothing. `MemQuerier` is a
    /// two-stage filter: stage 1 clips to the range the querier was opened over, stage 2 to the hints.
    /// The querier's range comes from `getTimeRangesForSelector`, which applies the *same*
    /// `lookbackDelta - 1` reduction — so for a plain `info(metric)` the two windows coincide exactly
    /// and any perturbation of the hints is clipped away by stage 1 before it can matter.
    ///
    /// A range-vector argument breaks the tie: `sum_over_time(metric[10m])` opens the querier 10
    /// minutes back while the info select still asks for one lookback, so the hints are the only thing
    /// excluding the older sample.
    ///
    /// This one pins the off-by-one itself. Upstream reduces the start by `lookbackDelta - 1`, not
    /// `lookbackDelta`, with the comment "we want to exclude samples that are precisely the lookback
    /// delta before the eval time" — so an info sample exactly 5m before the eval time is invisible.
    @Test("an info sample exactly one lookback before the eval time is excluded")
    func lookbackBoundary() {
        expectClean(
            run(
                """
                load 5m
                  metric{instance="a", job="1"}                1 2
                  target_info{instance="a", job="1", data="d"} 1 _

                eval instant at 5m info(sum_over_time(metric[10m]))
                  {instance="a", job="1"} 3
                """), 1)

        // One millisecond later the same sample IS inside the window, which is what makes the line
        // above a boundary rather than an exclusion.
        expectClean(
            run(
                """
                load 1ms
                  target_info{instance="a", job="1", data="d"} _ 1

                load 5m
                  metric{instance="a", job="1"} 1 2

                eval instant at 5m info(sum_over_time(metric[10m]))
                  {instance="a", job="1", data="d"} 3
                """), 1)
    }

    /// An `@` on the argument's selector overrides the hint window entirely — `start = end = ts`.
    ///
    /// Observing that needs two things at once, and the first two attempts had neither. The querier's
    /// own window must be WIDER than the hints' (stage 1 clips first, and `getTimeRangesForSelector`
    /// applies the same `@` arithmetic, so a single-selector argument makes the two coincide exactly) —
    /// hence the second selector, which widens the union. And the *effect* has to be visible in the
    /// labels rather than the window, since the info matrix is still evaluated at the evaluator's own
    /// timestamps with its own lookback — hence two info series with the same signature and different
    /// data labels, where the newest-origT tie-break decides which data label lands. With the `@`
    /// override the later info sample is trimmed away and `old` wins; without it, `new` does.
    @Test("an @ on the argument pins the info select window too")
    func atModifierPinsTheWindow() {
        expectClean(
            run(
                """
                load 1m
                  metric{instance="a", job="1"}                  1 1 1 1 1 1
                  other{instance="a", job="1"}                   1 1 1 1 1 1
                  target_info{instance="a", job="1", data="old"} _ 1 _ _ _ _
                  target_info{instance="a", job="1", data="new"} _ _ 1 _ _ _

                eval instant at 5m info((metric @ 60) + (other * 0))
                  {instance="a", job="1", data="old"} 1
                """), 1)
    }

    /// The argument's `offset` shifts the hint window back by the same amount, and the same two
    /// requirements as above apply. `end` moves from 10m to 9m, which trims the info sample at 10m and
    /// leaves the one at 8m as the newest — so `old` wins where an unshifted window would pick `new`.
    @Test("the argument's offset shifts the info select window")
    func offsetShiftsTheWindow() {
        expectClean(
            run(
                """
                load 1m
                  metric{instance="a", job="1"}                  1 1 1 1 1 1 1 1 1 1 1
                  other{instance="a", job="1"}                   1 1 1 1 1 1 1 1 1 1 1
                  target_info{instance="a", job="1", data="old"} _ _ _ _ _ _ _ _ 1 _ _
                  target_info{instance="a", job="1", data="new"} _ _ _ _ _ _ _ _ _ _ 1

                eval instant at 10m info((metric offset 1m) + (other * 0))
                  {instance="a", job="1", data="old"} 1
                """), 1)
    }

    /// Identifying label values are `QuoteMeta`d before being joined into the selector's alternation.
    ///
    /// **A wider selector alone cannot be wrong**, which is the subtlety: the alternation is only a
    /// prefilter and the join itself compares signatures exactly, so an unescaped `.` can pull in
    /// extra info series but they all fail the signature match. What an unescaped value CAN do is make
    /// the regexp fail to compile — `a(b` is not a valid pattern — and that is a query error rather
    /// than a wider result. So the value here contains an unbalanced paren.
    @Test("a metacharacter in an identifying label value is escaped")
    func quotedIdentifyingValues() {
        expectClean(
            run(
                """
                load 1m
                  metric{instance="a(b", job="1"}                 1
                  target_info{instance="a(b", job="1", data="d"}  1

                eval instant at 0m info(metric)
                  {__name__="metric", instance="a(b", job="1", data="d"} 1
                """), 1)
    }

    /// With only NEGATIVE `__name__` matchers, `effectiveInfoNameMatchers` prepends a synthetic
    /// `__name__=~".+_info"`. `.+` requires at least one character before `_info`, so a metric named
    /// exactly `_info` is NOT selected — the difference between `.+_info` and `.*_info`, which no
    /// assertion upstream distinguishes.
    @Test("the synthetic matcher is .+_info, so a metric named exactly _info is not selected")
    func syntheticMatcherRequiresAPrefix() {
        expectClean(
            run(
                """
                load 1m
                  metric{instance="a", job="1"}              1
                  _info{instance="a", job="1", data="bare"}   1
                  x_info{instance="a", job="1", data="x"}     1

                eval instant at 0m info(metric, {__name__!="y_info"})
                  {__name__="metric", instance="a", job="1", data="x"} 1
                """), 1)
    }

    /// An identifying label whose value is the empty string is skipped when collecting values, so the
    /// alternation stays `a` rather than becoming `a|`.
    ///
    /// **Making that observable takes a specific shape**, which is why the control survived: an empty
    /// label value is indistinguishable from a missing one in Prometheus, so a series "with
    /// `instance=\"\"`" is just a series without `instance`, and `instance=~"a"` does not match it
    /// while `instance=~"a|"` does. So the test needs a base series with no `instance`, an info series
    /// with no `instance`, and a second base series that supplies the `a`. With the skip the info
    /// series is never selected and neither base series is enriched; without it, the no-`instance`
    /// pair joins.
    @Test("an empty identifying label value does not widen the selector")
    func emptyIdentifyingValue() {
        expectClean(
            run(
                """
                load 1m
                  metric{instance="a", job="1"}       1
                  metric{job="1"}                     1
                  target_info{job="1", data="noinst"} 1

                eval instant at 0m info(metric)
                  {__name__="metric", instance="a", job="1"} 1
                  {__name__="metric", job="1"} 1
                """), 1)
    }
}
