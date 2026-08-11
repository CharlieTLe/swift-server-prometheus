//===----------------------------------------------------------------------===//
// Ported from promql/promqltest/test.go @ v3.13.2 — the `.test` file runner.
//
// **This is the exit gate, and it needs no differential corpus of its own.** Every other slice in
// this project is pinned by comparing against Go; this one is pinned by the 2,183 `eval`
// assertions upstream already wrote, which are committed verbatim in `Fixtures/promql/testdata/`
// and sha256-pinned in `MANIFEST.json`. A failure here is a real divergence in the *engine*, not
// in the runner's own byte-exactness — so the verification story is "run it and count", which is
// exactly what `PromQLTestTests` does.
//
// ## What it supports, and what it declines by name
//
// Supported: `load <step>`, `clear`, `eval instant [at <dur>] <expr>`, `eval range from <d> to <d>
// step <d> <expr>`, and the `_fail` / `_warn` / `_info` / `_ordered` modifiers, plus
// `expected_fail_message`, `expected_fail_regexp` and `expect no_info` / `expect no_warn`.
//
// Declined, each reported as a SKIP with its reason rather than a pass:
//
//   * `load_with_nhcb` — the native-histogram-custom-buckets loader variant, which needs the NHCB
//     conversion from `model/histogram`'s `convert.go` wired into the loader (33 assertions);
//   * `@st` lines — start timestamps, which ride on `EncXOR2` and so belong to Phases 6-7
//     (quirk 36, 18 assertions);
//   * `expect range vector` and `expect string` directives;
//   * any query the evaluator still refuses by name — `label_replace` (21) and `info` (42).
//
// The point of counting skips separately from failures is that a skip is a *known* gap with a
// number attached, and a failure is a bug. Reporting them together would let the second hide in
// the first.
//
// ## `testStartTime` is the Unix epoch, and every timestamp is an OFFSET from it
//
// `eval instant at 5m` means `t = 300_000`, not "five minutes from now". `load 1m` sets the *gap*
// between consecutive values in a series description, so `foo 0+1x5` is six samples a minute
// apart starting at 0.
//
// ## Comparison is `almost.Equal`, not `==`
//
// `defaultEpsilon` is **1e-6**, and the comparison is relative except near zero — Go's
// `util/almost`. Two details it gets right that `==` would not: a **stale NaN** compares equal
// only to another stale NaN (never to an ordinary NaN), and two ordinary NaNs *do* compare equal,
// which is the opposite of IEEE. Both matter: the `.test` files assert on both kinds.
//===----------------------------------------------------------------------===//

public import GoCompat
public import PromLabels
public import PromQL
public import PromQLParser
public import PromStorage

internal import PromHistogram
internal import PromModel
internal import PromTestStorage

/// Go: `defaultEpsilon` (test.go:61) — `0.000001`, "Relative error allowed for sample values".
///
/// **1e-6, not 1e-12.** The `.test` files write expectations to nine or ten significant figures
/// (`1.833333333` for `11/6`), so a tight epsilon rejects a *correct* answer. Twenty of
/// `extended_vectors.test`'s assertions failed on exactly that before this was read from the
/// source rather than guessed.
public let defaultEpsilon = 0.000001

/// Go: `almost.Equal` — the comparison every assertion uses.
///
/// A **stale** NaN is equal only to another stale NaN; two ordinary NaNs are equal to each other,
/// which IEEE says they are not. Below `minNormal` the comparison is absolute rather than
/// relative, because a relative one is meaningless there.
public func almostEqual(_ a: Double, _ b: Double, _ epsilon: Double = defaultEpsilon) -> Bool {
    if PromValue.isStaleNaN(a) || PromValue.isStaleNaN(b) {
        return PromValue.isStaleNaN(a) && PromValue.isStaleNaN(b)
    }
    if a.isNaN && b.isNaN {
        return true
    }
    if a == b {
        return true
    }
    let absSum = abs(a) + abs(b)
    let diff = abs(a - b)
    // Go: `minNormal = math.Float64frombits(0x0010000000000000)`, the smallest normal float64.
    let minNormal = Double(bitPattern: 0x0010_0000_0000_0000)
    if a == 0 || b == 0 || absSum < minNormal {
        return diff < epsilon * minNormal
    }
    return diff / Swift.min(absSum, Double.greatestFiniteMagnitude) < epsilon
}

/// One `eval` assertion's outcome.
public enum AssertionOutcome: Sendable {
    case passed
    /// A real divergence: the engine answered, and differently from the `.test` file.
    case failed(String)
    /// A known gap, with its reason. Counted separately so a bug cannot hide among them.
    case skipped(String)
}

/// The tally a run produces.
public struct RunReport: Sendable {
    public var passed = 0
    public var failed = 0
    public var skipped = 0
    /// The first `maxDetail` failures, for reporting. Corpora run to thousands of assertions, so
    /// the same batch-report discipline as `Fixtures.check` applies (CLAUDE.md).
    public var failures: [String] = []
    public var skipReasons: [String: Int] = [:]

    public init() {}

    public var total: Int { passed + failed + skipped }
}

/// Go: `test` — one `.test` file, parsed into commands and run.
public struct PromQLTestRunner {
    /// Go: `testStartTime = time.Unix(0, 0).UTC()`. Every timestamp in a `.test` file is an offset
    /// from the epoch, not from now.
    public static let startTime: Int64 = 0

    let engine: Engine
    let parser: Parser

    public init(engine: Engine, parser: Parser) {
        self.engine = engine
        self.parser = parser
    }

    /// Run one `.test` file's contents. Never throws: a malformed command is a *failure* the
    /// report carries, because a parse error in the runner is exactly as interesting as a wrong
    /// answer.
    public func run(_ input: String, name: String = "") -> RunReport {
        var report = RunReport()
        let lines = Self.scan(input)
        let store = MemStorage()

        var storeIncomplete: String? = nil
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty {
                i += 1
                continue
            }
            let head = line.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased()
                ?? ""
            switch head {
            case "clear":
                store.clear()
                storeIncomplete = nil
                i += 1
            case let h where h.hasPrefix("load"):
                let (next, outcome) = runLoad(lines, i, store)
                i = next
                // A load the runner declined leaves the store INCOMPLETE, so every assertion until
                // the next `clear` would fail for want of data rather than for a wrong answer.
                // Propagating the skip is what keeps `histograms.test`'s 149 assertions counted as
                // a known gap instead of 149 phantom bugs — the whole point of separating the two.
                if case .skipped(let reason) = outcome {
                    storeIncomplete = "depends on a declined load: \(reason)"
                }
                record(outcome, &report)
            case let h where h.hasPrefix("eval"):
                if let reason = storeIncomplete {
                    let (next, _) = runEval(lines, i, MemStorage(), name: name)
                    i = next
                    record(.skipped(reason), &report)
                    continue
                }
                let (next, outcomes) = runEval(lines, i, store, name: name)
                i = next
                for o in outcomes { record(o, &report) }
            default:
                record(.failed("\(name):\(i + 1): unknown command: \(line)"), &report)
                i += 1
            }
        }
        return report
    }

    private func record(_ o: AssertionOutcome?, _ report: inout RunReport) {
        guard let o else { return }
        switch o {
        case .passed:
            report.passed += 1
        case .failed(let msg):
            report.failed += 1
            if report.failures.count < 20 {
                report.failures.append(msg)
            }
        case .skipped(let reason):
            report.skipped += 1
            report.skipReasons[reason, default: 0] += 1
        }
    }

    /// Strip comments and trailing space, keeping blank lines — the parser uses a blank line as a
    /// block terminator, so they cannot be dropped.
    static func scan(_ input: String) -> [String] {
        input.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let s = String(raw)
            // Go: `strings.Split(l, "#")[0]` — the comment marker is taken at its FIRST occurrence
            // anywhere, so a `#` inside a label value would truncate the line. That is upstream's
            // behaviour and no committed `.test` file contains one, so it is reproduced rather than
            // improved: a runner that were cleverer here would accept files Go rejects.
            let body = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(body).trimmed()
        }
    }
}
