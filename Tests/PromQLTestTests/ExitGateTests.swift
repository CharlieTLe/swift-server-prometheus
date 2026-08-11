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
// `label_replace` (21 assertions) and `info` (42) are unported and the loader lacks NHCB (33) and
// `EncXOR2` (18) — and it turns any *new* breakage into a test failure immediately, which a
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
                enableTypeAndUnitLabels: true,
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
let promqlTestAllowedFailures = 0

/// A floor, so lowering the ratchet by converting passes into skips fails the test.
// 1,448 of 2,221 (65%). The 773 skips are itemised by the run itself, and every one of them names
// a known gap: 250 positive `expect` annotation assertions and 201 histogram-valued ones are the
// RUNNER's remaining work, 214 depend on `load_with_nhcb` or `@st` (Phases 6-7), and 58 are
// `info`/`label_replace`.
let promqlTestMinimumPasses = 1_448

extension String {
    fileprivate func padded(to n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}
