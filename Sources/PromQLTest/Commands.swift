//===----------------------------------------------------------------------===//
// Ported from promql/promqltest/test.go @ v3.13.2 — `parseLoad`/`loadCmd.append` and
// `parseEval`/`evalCmd.compareResult`.
//
// The two command blocks, split from `Runner.swift` so each stays readable. See that file's header
// for what the runner supports and what it declines by name.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromChunks
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromQL
internal import PromQLParser
internal import PromStorage
internal import PromTestStorage

extension PromQLTestRunner {

    // MARK: - load

    /// Go: `parseLoad` + `loadCmd.append`/`Load`.
    ///
    /// `load <step>` sets the **gap** between consecutive values in each series description, so
    /// `foo 0+1x5` is six samples `step` apart starting at `startTime`. `load_with_nhcb` is
    /// declined: it needs the NHCB conversion wired into the loader.
    func runLoad(_ lines: [String], _ start: Int, _ store: MemStorage) -> (Int, AssertionOutcome?) {
        var i = start
        let line = lines[i]
        var outcome: AssertionOutcome? = nil
        let withNHCB = line.hasPrefix("load_with_nhcb")

        // The step is the rest of the command line.
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let gap = try? PromDuration.parse(parts[1].trimmed()) else {
            return (i + 1, .failed("\(i + 1): invalid load step in: \(line)"))
        }
        if withNHCB {
            outcome = .skipped("load_with_nhcb needs the NHCB loader (Phases 6-7's convert.go)")
        }

        // Go accumulates the block into `cmd.defs[hash]` and **REPLACES** on a repeated metric —
        // `aggregators.test` has two `data{test="-inf3",point="c"}` lines, and the second wins. An
        // appending loader errors on the duplicate instead, and because the block then aborts every
        // following series line is read as a command. That one difference cost 149 assertions in
        // `histograms.test` alone, so the accumulate-then-flush shape is not a detail.
        var defs: [UInt64: (metric: Labels, samples: [any PromChunks.Sample])] = [:]
        var order: [UInt64] = []

        while i + 1 < lines.count {
            i += 1
            let defLine = lines[i]
            if defLine.isEmpty {
                i -= 1
                break
            }
            // `@st` is a SUFFIX ON THE METRIC (`foo{…}@st  <values>`), not a line prefix — Go's
            // `isSTLine` looks at the token before the first space. Start timestamps ride on
            // `EncXOR2`, so they belong to Phases 6-7 (quirk 36).
            let firstToken = defLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if firstToken.hasSuffix("@st") {
                outcome = .skipped("@st lines need EncXOR2 (Phases 6-7, quirk 36)")
                continue
            }
            if withNHCB || outcome != nil {
                continue
            }
            do {
                let (metric, values) = try parser.parseSeriesDesc(defLine)
                var samples = [any PromChunks.Sample]()
                var t = Self.startTime
                for v in values {
                    defer { t += gap.milliseconds }
                    // An omitted value (`_`) is a HOLE: the timestamp advances and nothing is
                    // appended, which is how a `.test` file writes a gap.
                    if v.omitted {
                        continue
                    }
                    if let h = v.histogram {
                        samples.append(FHSample(st: 0, t: t, fh: h))
                    } else {
                        samples.append(FSample(st: 0, t: t, f: v.value))
                    }
                }
                let h = metric.goHash()
                if defs[h] == nil { order.append(h) }
                defs[h] = (metric, samples)
            } catch {
                return (i + 1, .failed("\(i + 1): \(defLine): \(String(describing: error))"))
            }
        }

        for h in order {
            guard let d = defs[h] else { continue }
            do {
                try store.load(d.metric, d.samples)
            } catch {
                return (i + 1, .failed("\(i + 1): \(d.metric): \(String(describing: error))"))
            }
        }
        return (i + 1, outcome)
    }

    // MARK: - eval

    /// Go: `parseEval` + `evalCmd.compareResult`, collapsed — the parse and the run are one pass
    /// here because there is no need to keep the command around.
    ///
    /// Returns one outcome per assertion, which for an `eval` line is exactly one.
    func runEval(
        _ lines: [String], _ start: Int, _ store: MemStorage, name: String
    ) -> (Int, [AssertionOutcome]) {
        var i = start
        let line = lines[i]
        let loc = "\(name):\(i + 1)"

        // `eval[_fail|_warn|_ordered|_info] instant [at <dur>] <expr>` or
        // `eval[_fail|_warn|_info] range from <d> to <d> step <d> <expr>`.
        guard var cmd = EvalCommand(line: line) else {
            return (i + 1, [.failed("\(loc): unparsable eval: \(line)")])
        }

        // The expectation lines, until a blank line.
        var expected: [(labels: Labels, values: [SequenceValue])] = []
        var expectedScalar: Double? = nil
        var failMessage: String? = nil
        var failRegexp: String? = nil
        var unsupportedDirective: String? = nil
        var expects: [ExpectClause] = []
        while i + 1 < lines.count {
            i += 1
            let defLine = lines[i]
            if defLine.isEmpty {
                i -= 1
                break
            }
            if cmd.fail, defLine.hasPrefix("expected_fail_message") {
                failMessage = String(defLine.dropFirst("expected_fail_message".count)).trimmed()
                break
            }
            if cmd.fail, defLine.hasPrefix("expected_fail_regexp") {
                failRegexp = String(defLine.dropFirst("expected_fail_regexp".count)).trimmed()
                break
            }
            if defLine.hasPrefix("expect range vector") || defLine.hasPrefix("expect string") {
                unsupportedDirective = "the `\(defLine)` directive"
                continue
            }
            // `expect <type>[ msg:<text>| regex:<pat>]`. Go: `patExpect`.
            if defLine.split(separator: " ").first.map(String.init) == "expect" {
                switch ExpectClause(line: defLine) {
                case .some(let e):
                    // `expect fail [msg:<text>]` is the modern spelling of `eval_fail` plus
                    // `expected_fail_message`, and most of the corpus uses it. Missing this made
                    // every deliberate-error assertion read as an unexpected failure — 20 of the
                    // first 21 failures the gate reported.
                    if e.kind == .fail {
                        cmd.fail = true
                        if let m = e.message { failMessage = m }
                        if e.isRegex { failRegexp = "" }
                        continue
                    }
                    if e.kind == .ordered {
                        cmd.ordered = true
                        continue
                    }
                    if e.isRegex {
                        // A regex expectation needs an unanchored matcher, which is
                        // `FastRegexMatcher`'s job — deferred with `label_replace`.
                        unsupportedDirective = "`expect … regex:` needs an unanchored matcher"
                    } else {
                        expects.append(e)
                    }
                case nil:
                    return (i + 1, [.failed("\(loc): unparsable expect: \(defLine)")])
                }
                continue
            }
            // A bare number is a scalar expectation.
            if !defLine.contains("{"), let f = try? GoFloat.parse(defLine.trimmed()) {
                expectedScalar = f
                break
            }
            do {
                let (metric, values) = try parser.parseSeriesDesc(defLine)
                expected.append((metric, values))
            } catch {
                return (i + 1, [.failed("\(loc): bad expectation \(defLine): \(error)")])
            }
        }

        if let unsupportedDirective {
            return (i + 1, [.skipped(unsupportedDirective)])
        }

        // Run it.
        let query: Query
        do {
            if cmd.isInstant {
                query = try engine.newInstantQuery(
                    store, nil, cmd.expr, Timestamp.time(cmd.at))
            } else {
                query = try engine.newRangeQuery(
                    store, nil, cmd.expr, Timestamp.time(cmd.from), Timestamp.time(cmd.to),
                    GoDuration(nanoseconds: cmd.step * 1_000_000))
            }
        } catch {
            // A build failure is a legitimate `eval_fail` outcome.
            return (i + 1, [checkFailure(cmd, error, failMessage, failRegexp, loc)])
        }
        let res = query.exec(GoContext.background())

        if let err = res.error {
            if err is EvaluatorNotPorted {
                return (i + 1, [.skipped(String(describing: err))])
            }
            return (i + 1, [checkFailure(cmd, err, failMessage, failRegexp, loc)])
        }
        if cmd.fail {
            return (
                i + 1, [.failed("\(loc): expected \(cmd.expr) to fail, got \(res.value?.description ?? "nil")")]
            )
        }

        // The annotation assertions. `asStrings` with an EMPTY query renders the bare message,
        // which is what `err.Error()` gives Go and therefore what an `expect … msg:` line carries —
        // passing the query would append a `(line:col)` suffix the expectation does not have.
        let (warnings, infos) = res.warnings.asStrings(query: "", maxWarnings: 0, maxInfos: 0)
        if cmd.warn && warnings.isEmpty {
            return (i + 1, [.failed("\(loc): expected a warning from \(cmd.expr), got none")])
        }
        if cmd.info && infos.isEmpty {
            return (i + 1, [.failed("\(loc): expected an info from \(cmd.expr), got none")])
        }
        if let bad = checkAnnotations(expects, warnings, infos, cmd, loc) {
            return (i + 1, [bad])
        }

        return (i + 1, [compare(res, cmd, expected, expectedScalar, loc)])
    }

    /// An `eval_fail` line: the query had to fail, and optionally with a given message.
    private func checkFailure(
        _ cmd: EvalCommand, _ err: any Error, _ message: String?, _ regexp: String?, _ loc: String
    ) -> AssertionOutcome {
        if err is EvaluatorNotPorted {
            return .skipped(String(describing: err))
        }
        guard cmd.fail else {
            return .failed("\(loc): \(cmd.expr) failed unexpectedly: \(String(describing: err))")
        }
        let text = String(describing: err)
        if let message, text != message {
            return .failed("\(loc): \(cmd.expr): expected failure \(message), got \(text)")
        }
        if regexp != nil {
            // A regexp assertion needs an unanchored matcher, which is `FastRegexMatcher`'s job
            // rather than `Matcher`'s — deferred with `label_replace`.
            return .skipped("a `fail regex:` expectation needs an unanchored matcher")
        }
        return .passed
    }

    /// Go: `evalCmd.compareResult` — compare the answer against the expectation lines.
    private func compare(
        _ res: Result, _ cmd: EvalCommand,
        _ expected: [(labels: Labels, values: [SequenceValue])], _ expectedScalar: Double?,
        _ loc: String
    ) -> AssertionOutcome {
        if let expectedScalar {
            guard let s = try? res.scalar() else {
                return .failed("\(loc): \(cmd.expr): expected a scalar, got \(res.value?.type.documented ?? "nil")")
            }
            return almostEqual(expectedScalar, s.v)
                ? .passed
                : .failed("\(loc): \(cmd.expr): expected \(expectedScalar), got \(s.v)")
        }

        // An instant query yields a Vector; a range query a Matrix.
        if cmd.isInstant {
            guard let vec = try? res.vector() else {
                if res.value is Matrix {
                    return .skipped("an instant query returning a range vector")
                }
                return .failed("\(loc): \(cmd.expr): expected a vector, got \(res.value?.type.documented ?? "nil")")
            }
            if vec.samples.count != expected.count {
                return .failed(
                    "\(loc): \(cmd.expr): expected \(expected.count) series, got \(vec.samples.count)")
            }
            // `eval_ordered` compares position by position; otherwise the answer is matched by
            // label set, because a vector's order is not contractual unless asked for.
            if cmd.ordered {
                for (j, s) in vec.samples.enumerated() {
                    if s.metric != expected[j].labels {
                        return .failed(
                            "\(loc): \(cmd.expr): at position \(j) expected \(expected[j].labels), got \(s.metric)")
                    }
                    if let bad = mismatch(expected[j].values, s, loc, cmd) { return bad }
                }
                return .passed
            }
            for e in expected {
                guard let s = vec.samples.first(where: { $0.metric == e.labels }) else {
                    return .failed("\(loc): \(cmd.expr): missing series \(e.labels)")
                }
                if let bad = mismatch(e.values, s, loc, cmd) { return bad }
            }
            return .passed
        }

        guard let mat = res.value as? Matrix else {
            return .failed("\(loc): \(cmd.expr): expected a matrix, got \(res.value?.type.documented ?? "nil")")
        }
        if mat.series.count != expected.count {
            return .failed(
                "\(loc): \(cmd.expr): expected \(expected.count) series, got \(mat.series.count)")
        }
        for e in expected {
            guard let s = mat.series.first(where: { $0.metric == e.labels }) else {
                return .failed("\(loc): \(cmd.expr): missing series \(e.labels)")
            }
            // A series carrying histograms cannot be index-compared against a float expectation
            // list, because the two point slices are separate and interleave by timestamp — the
            // same limitation the instant path declines by name.
            if !s.histograms.isEmpty || e.values.contains(where: { $0.histogram != nil }) {
                return .skipped("histogram-valued assertions")
            }
            // An omitted value in a range expectation is a HOLE, so the points are compared
            // against the non-omitted ones in order.
            let wanted = e.values.filter { !$0.omitted }
            let got = s.floats.map(\.f)
            if wanted.count != got.count {
                return .failed(
                    "\(loc): \(cmd.expr): \(e.labels): expected \(wanted.count) points, got \(got.count)")
            }
            for (j, w) in wanted.enumerated() where w.histogram == nil {
                if !almostEqual(w.value, got[j]) {
                    return .failed(
                        "\(loc): \(cmd.expr): \(e.labels): point \(j) expected \(w.value), got \(got[j])")
                }
            }
        }
        return .passed
    }

    /// One sample against one expectation.
    private func mismatch(
        _ values: [SequenceValue], _ s: PromQL.Sample, _ loc: String, _ cmd: EvalCommand
    ) -> AssertionOutcome? {
        guard let want = values.first else { return nil }
        if let wantH = want.histogram {
            guard let gotH = s.h else {
                return .failed("\(loc): \(cmd.expr): \(s.metric): expected a histogram, got a float")
            }
            // **BOTH SIDES ARE COMPACTED FIRST** — test.go:1323 is
            // `compareNativeHistogram(expected.H.Compact(0), actual.H.Compact(0), …)`. Without it
            // `histogram_mul_div * 0` fails: the file writes `buckets:[0 0 0]` and the engine's
            // answer is already compacted to nothing, so the spans differ while the two
            // `String()` renderings are identical. That accounted for ~30 of the gate's 39
            // failures, and it was the COMPARISON rather than `compact` or `mul` — the corpus
            // addition proved Go's `Compact(0)` and the port's already agree.
            //
            // `counterResetHintSet` is false: a `.test` expectation that does not write a hint
            // means "don't care", and the series-description parser has no way to say which it
            // was — a documented narrowing, since upstream compares it only when the file set one.
            var wantC = wantH
            var gotC = gotH
            return compareNativeHistogram(
                wantC.compact(maxEmptyBuckets: 0), gotC.compact(maxEmptyBuckets: 0),
                counterResetHintSet: false)
                ? nil
                : .failed(
                    "\(loc): \(cmd.expr): \(s.metric): histogram mismatch:\n"
                        + "      want \(hDetail(wantH))\n      got  \(hDetail(gotH))")
        }
        if let gotH = s.h {
            return .failed("\(loc): \(cmd.expr): \(s.metric): expected a float, got histogram \(gotH)")
        }
        return almostEqual(want.value, s.f)
            ? nil
            : .failed("\(loc): \(cmd.expr): \(s.metric): expected \(want.value), got \(s.f)")
    }
}

/// One parsed `eval` line.
struct EvalCommand {
    var expr: String
    var isInstant: Bool
    var at: Int64 = 0
    var from: Int64 = 0
    var to: Int64 = 0
    var step: Int64 = 0
    var fail = false
    var warn = false
    var info = false
    var ordered = false

    /// Go: `patEvalInstant` / `patEvalRange`, hand-parsed — the two regexes are simple enough that
    /// a split is clearer, and `PromRegex` has no submatch support (that is `label_replace`'s
    /// blocker).
    init?(line: String) {
        var rest = line
        guard rest.hasPrefix("eval") else { return nil }
        rest = String(rest.dropFirst(4))
        if rest.hasPrefix("_") {
            let mod = rest.dropFirst().prefix(while: { $0 != " " })
            switch mod {
            case "fail": fail = true
            case "warn": warn = true
            case "info": info = true
            case "ordered": ordered = true
            default: return nil
            }
            rest = String(rest.dropFirst(1 + mod.count))
        }
        rest = rest.trimmed()

        if rest.hasPrefix("instant") {
            isInstant = true
            rest = String(rest.dropFirst("instant".count)).trimmed()
            if rest.hasPrefix("at ") {
                rest = String(rest.dropFirst(3)).trimmed()
                let offset = rest.prefix(while: { $0 != " " })
                guard let d = try? PromDuration.parse(String(offset)) else { return nil }
                at = PromQLTestRunner.startTime + d.milliseconds
                rest = String(rest.dropFirst(offset.count)).trimmed()
            }
            expr = rest
            return
        }
        guard rest.hasPrefix("range from ") else { return nil }
        isInstant = false
        rest = String(rest.dropFirst("range from ".count))
        // `<from> to <to> step <step> <expr>`
        // Split on the two keywords by hand: `range(of:)` is Foundation's, and the package does
        // not import it.
        let words = rest.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 5, words[1] == "to", words[3] == "step" else { return nil }
        let fromStr = words[0]
        let toStr = words[2]
        let stepStrRaw = words[4]
        var tail = words.dropFirst(5).joined(separator: " ").trimmed()
        _ = stepStrRaw
        let stepStr = stepStrRaw
        guard let f = try? PromDuration.parse(fromStr), let t = try? PromDuration.parse(toStr),
            let st = try? PromDuration.parse(stepStr)
        else { return nil }
        from = PromQLTestRunner.startTime + f.milliseconds
        to = PromQLTestRunner.startTime + t.milliseconds
        step = st.milliseconds
        expr = tail
    }
}

extension String {
    /// A manual trim: the package does not import Foundation, and `trimmingCharacters` is
    /// Foundation's. Only the three characters a `.test` file can carry are stripped.
    func trimmed() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\r" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
        return String(s)
    }
}


/// Go: `expectCmd` plus its type tag — one `expect` line.
struct ExpectClause {
    enum Kind: String { case fail, ordered, warn, noWarn = "no_warn", info, noInfo = "no_info" }
    var kind: Kind
    /// An `expect warn msg: <text>` expectation. Nil means "any annotation of this kind".
    var message: String?
    var isRegex = false

    /// Go: `patExpect` — `^expect\s+(ordered|fail|warn|no_warn|info|no_info)(?:\s+(regex|msg):(.+))?$`.
    init?(line: String) {
        var rest = line.trimmed()
        guard rest.hasPrefix("expect") else { return nil }
        rest = String(rest.dropFirst("expect".count)).trimmed()
        let word = String(rest.prefix(while: { $0 != " " && $0 != ":" }))
        guard let k = Kind(rawValue: word) else { return nil }
        kind = k
        rest = String(rest.dropFirst(word.count)).trimmed()
        if rest.isEmpty {
            return
        }
        if rest.hasPrefix("msg:") {
            message = String(rest.dropFirst(4)).trimmed()
        } else if rest.hasPrefix("regex:") {
            isRegex = true
        } else {
            return nil
        }
    }
}

extension PromQLTestRunner {
    /// Go: `checkAnnotations` + `validateExpectedAnnotationsOfType`.
    ///
    /// A positive expectation must be satisfied by **some** actual annotation of that kind; a
    /// negative one requires none at all. `no_warn` and `warn` cannot both appear (upstream
    /// validates that at parse time), so the two are checked independently here.
    func checkAnnotations(
        _ expects: [ExpectClause], _ warnings: [String], _ infos: [String],
        _ cmd: EvalCommand, _ loc: String
    ) -> AssertionOutcome? {
        for e in expects {
            switch e.kind {
            case .warn, .info:
                let actual = e.kind == .warn ? warnings : infos
                guard let want = e.message else {
                    if actual.isEmpty {
                        return .failed("\(loc): \(cmd.expr): expected a \(e.kind.rawValue), got none")
                    }
                    continue
                }
                if !actual.contains(want) {
                    return .failed(
                        "\(loc): \(cmd.expr):\n      want \(want)\n      got  \(actual)")
                }
            case .noWarn:
                if !warnings.isEmpty {
                    return .failed("\(loc): \(cmd.expr): expected no warnings, got \(warnings)")
                }
            case .noInfo:
                if !infos.isEmpty {
                    return .failed("\(loc): \(cmd.expr): expected no infos, got \(infos)")
                }
            case .fail, .ordered:
                // Handled by the command modifiers.
                continue
            }
        }
        return nil
    }
}


/// The fields `FloatHistogram.String()` does not print, which is exactly where a mismatch with two
/// identical renderings has to live.
func hDetail(_ h: FloatHistogram) -> String {
    var s = "schema=\(h.schema) zt=\(h.zeroThreshold) zc=\(h.zeroCount) hint=\(h.counterResetHint)"
    s += " pSpans=\(h.positiveSpans.map { "(\($0.offset),\($0.length))" }.joined())"
    s += " nSpans=\(h.negativeSpans.map { "(\($0.offset),\($0.length))" }.joined())"
    s += " pB=\(h.positiveBuckets) nB=\(h.negativeBuckets) cv=\(h.customValues.map(String.init(describing:)) ?? "nil")"
    return s
}
