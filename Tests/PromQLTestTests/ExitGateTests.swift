//===----------------------------------------------------------------------===//
// THE EXIT GATE. Runs every committed `.test` file through the ported engine and reports the
// tally.
//
// This suite is deliberately unlike every other one in the project. There is no fixture to
// compare against, because the `.test` files *are* the comparison — 2,183 `eval` assertions
// upstream wrote, copied verbatim and sha256-pinned. So the assertion here is not "matches Go" but
// "answers correctly", and the number it prints is the project's headline metric.
//
// It does **not** yet require zero failures, and says so in one place rather than pretending: the
// threshold is a recorded number that only moves down. That is the honest shape while
// `label_replace` (21 assertions) and `info` (42) are unported and `EncXOR2` (23) is a Phase 6-7
// dependency — and it turns any *new* breakage into a test failure immediately, which a
// "known failures" list of names would not.
//
// `EnableDelayedNameRemoval` is TRUE, because that is what upstream's own runner sets
// (test.go:111) and therefore what the gate means.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromQL
import PromQLParser
import PromQLTest
import Testing

@Suite("promqltest: the Phase 5 exit gate")
struct PromQLTestTests {

    /// Upstream's `TestParserOpts` plus the two flags the extended syntax needs.
    private func makeRunner() -> PromQLTestRunner {
        let options = Options(
            enableExperimentalFunctions: true,
            experimentalDurationExpr: true,
            enableExtendedRangeSelectors: true,
            enableBinopFillModifiers: true)
        let engine = Engine(
            EngineOpts(
                maxSamples: 50_000_000,
                timeout: GoDuration(nanoseconds: 100 * 1_000_000_000),
                lookbackDelta: GoDuration(nanoseconds: 5 * 60 * 1_000_000_000),
                noStepSubqueryIntervalFn: { _ in 60_000 },
                enableAtModifier: true,
                enableNegativeOffset: true,
                // What upstream's runner sets, so it is what the gate means.
                enableDelayedNameRemoval: true,
                // NOT set by upstream's runner (test.go:104-111), and setting it changes which
                // possible-non-counter info `rate` emits — one assertion asserts `expect no_info`
                // and got one. The gate has to run the engine upstream's runner builds, not a
                // more-featureful one.
                parserOptions: options))
        return PromQLTestRunner(engine: engine, parser: Parser(options: options))
    }

    @Test("every committed .test file runs, and the tally only improves")
    func exitGate() throws {
        let files = try Fixtures.list("promql/testdata").filter { $0.hasSuffix(".test") }.sorted()
        #expect(!files.isEmpty, "no .test files found — the fixture path is wrong")

        var total = RunReport()
        var perFile: [(String, RunReport)] = []
        let runner = makeRunner()
        for f in files {
            let input = try Fixtures.text("promql/testdata/\(f)")
            let r = runner.run(input, name: f)
            perFile.append((f, r))
            total.passed += r.passed
            total.failed += r.failed
            total.skipped += r.skipped
            for (k, v) in r.skipReasons { total.skipReasons[k, default: 0] += v }
            if total.failures.count < 20 {
                total.failures.append(contentsOf: r.failures.prefix(20 - total.failures.count))
            }
        }

        print("=== promqltest exit gate ===")
        for (f, r) in perFile {
            print(
                "  \(f.padded(to: 28)) pass \(String(r.passed).padded(to: 5))"
                    + " fail \(String(r.failed).padded(to: 5)) skip \(r.skipped)")
        }
        print(
            "  TOTAL                        pass \(total.passed)  fail \(total.failed)"
                + "  skip \(total.skipped)  of \(total.total)")
        if !total.skipReasons.isEmpty {
            print("  --- skips by reason ---")
            for (k, v) in total.skipReasons.sorted(by: { $0.value > $1.value }).prefix(12) {
                print("  \(String(v).padded(to: 6)) \(k)")
            }
        }
        if !total.failures.isEmpty {
            print("  --- first failures ---")
            for f in total.failures { print("  \(f)") }
        }

        // A RATCHET, not a target: this number is what the port currently achieves, and it is only
        // ever edited downwards. A new failure trips the test immediately, which is what a list of
        // known-failing names would not do.
        let allowedFailures = promqlTestAllowedFailures
        #expect(
            total.failed <= allowedFailures,
            "the exit gate regressed: \(total.failed) failures, ratchet \(allowedFailures)")
        // And a floor on progress, so the ratchet cannot be satisfied by turning passes into skips.
        #expect(total.passed >= promqlTestMinimumPasses)
    }
}

/// The exit-gate ratchet. Edited **downwards only**, in the commit that earns it.
///
/// Where the remaining failures live is recorded in `docs/HANDOFF.md` §5e; the ones that are known
/// *gaps* rather than bugs are counted as skips instead, so this number is bugs plus
/// runner-incompleteness and nothing else.
// **Zero failures.** Every `.test` file the port can load now answers correctly, so the ratchet is
// 0 and any new divergence trips this test immediately rather than hiding under a threshold.
//
// The last two to go were the `conflicting counter resets during histogram aggregation` warnings on
// `sum_over_time`/`avg_over_time` over a mixed-hint matrix, and they were never an evaluator bug:
// `MemStorage` returned stored counter-reset hints unchanged where a chunk read-back DERIVES them
// from the chunk header and the sample's position (quirk 102). Five hypotheses, four refuted, and the
// cause was four layers from the symptom — HANDOFF §5e records the whole chase because the lesson
// (test each layer, do not reason from the one that failed) outlives the bug.
//
// Also closed with it: `counterResetHintSet` is now passed the way upstream passes it, and the
// histogram-valued RANGE assertions are compared by splitting the expectation list by timestamp.
// Those two were held back deliberately until the storage could derive hints, because turning them
// on first would have turned 2 failures into 8 without finding anything new.
let promqlTestAllowedFailures = 0

// Measured when `util/convertnhcb` landed, and worth keeping as a record of how the gate hides
// things: with `counterResetHintSet` passed as upstream passes it, the gate reported **8** failures
// rather than 2 — six more instances of the same storage gap that the comparison simply was not
// looking for. A threshold that only counts what it checks is not a measurement of correctness, and
// the six were real.

/// A floor, so lowering the ratchet by converting passes into skips fails the test.
// 2,092 of 2,188 (96%), with ZERO failures — and BOTH are a Phase 6-7 dependency rather than an
// so the engine has no known divergence left that the gate can see. The 96 skips are itemised by the
// run itself and every one names a known gap: 63 are `info`/`label_replace`, 23 are `@st` lines
// (`EncXOR2`, Phases 6-7), and the rest are the `expect range vector`/`expect string` directives.
//
// `load_with_nhcb` is no longer among them: porting `util/convertnhcb` and wiring it into the loader
// moved 170 assertions from skip to pass in one commit, which is what measuring the gap before
// choosing the work was for (HANDOFF §5e). `native_histograms.test`, the largest file at 522
// assertions, now passes all 522 with no skips at all.
let promqlTestMinimumPasses = 2_092

extension String {
    fileprivate func padded(to n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}

//===----------------------------------------------------------------------===//
// Two `load_with_nhcb` behaviours the committed `.test` corpus does not reach.
//
// `Scripts/controls-convertnhcb.sh` perturbed both and the whole gate stayed green, which is a
// corpus gap rather than dead code: upstream's loader really does have these two branches, and
// `histograms.test` and `operators.test` — the only two files with a `load_with_nhcb` block — happen
// to have neither a malformed `le` nor a series mixing classic and native samples. So the coverage
// has to be written rather than found.
//===----------------------------------------------------------------------===//

@Suite("load_with_nhcb: the two branches the .test corpus misses")
struct NHCBLoaderEdgeTests {

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

    /// A `_bucket` series whose `le` does not parse is skipped **silently** — the rest of the
    /// histogram still converts. Treating the bad `le` as `0` instead would add a phantom bucket, and
    /// erroring would lose the whole series; upstream does neither.
    @Test("a malformed le skips its series and leaves the rest converting")
    func malformedLe() {
        let r = run(
            """
            load_with_nhcb 1m
              h_bucket{le="1"}          1
              h_bucket{le="Hello"}      7
              h_bucket{le="2"}          3
              h_bucket{le="+Inf"}       4

            eval instant at 0m h
              {__name__="h"} {{schema:-53 count:4 custom_values:[1 2] buckets:[1 2 1]}}

            eval instant at 0m histogram_count(h)
              {} 4
            """)
        #expect(r.failed == 0, "\(r.failures)")
        #expect(r.passed == 2)
    }

    /// A histogram-valued sample inside a classic series contributes **nothing** to the collation,
    /// so a series that is half classic and half native yields an NHCB from its floats alone.
    @Test("a native sample in a classic series is not collated")
    func mixedClassicAndNative() {
        let r = run(
            """
            load_with_nhcb 1m
              h_bucket{le="1"}     1 1
              h_bucket{le="2"}     3 {{schema:0 count:5 sum:5 buckets:[5]}}
              h_bucket{le="+Inf"}  4 4

            eval instant at 1m h
              {__name__="h"} {{schema:-53 count:4 custom_values:[1] buckets:[1 3]}}
            """)
        #expect(r.failed == 0, "\(r.failures)")
        #expect(r.passed == 1)
    }
}
