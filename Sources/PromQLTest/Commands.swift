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
internal import PromConvertNHCB
internal import PromModel
internal import PromRegex
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
        // `load_with_nhcb` appends the classic `_bucket`/`_sum`/`_count` series **and** their NHCB
        // conversions, which `appendCustomHistogram` below builds through `PromConvertNHCB`.

        // Go accumulates the block into `cmd.defs[hash]` and **REPLACES** on a repeated metric —
        // `aggregators.test` has two `data{test="-inf3",point="c"}` lines, and the second wins. An
        // appending loader errors on the duplicate instead, and because the block then aborts every
        // following series line is read as a command. That one difference cost 149 assertions in
        // `histograms.test` alone, so the accumulate-then-flush shape is not a detail.
        var defs: [UInt64: (metric: Labels, samples: [any PromChunks.Sample])] = [:]
        var order: [UInt64] = []
        var pendingST: (metric: Labels, values: [SequenceValue])? = nil

        while i + 1 < lines.count {
            i += 1
            let defLine = lines[i]
            if defLine.isEmpty {
                i -= 1
                break
            }
            // `@st` is a SUFFIX ON THE METRIC (`foo{…}@st  <values>`), not a line prefix — Go's
            // `isSTLine` looks at the token before the first space.
            //
            // An ST line does not stand alone: it describes the start timestamps of the sample line that
            // FOLLOWS it, so it is held pending and applied there. Two lines in a row is an error, as is
            // an ST line with nothing after it.
            if isSTLine(defLine) {
                if pendingST != nil {
                    return (i + 1, .failed("\(i + 1): @st line has no following sample line"))
                }
                do {
                    pendingST = try parseSTLine(defLine)
                } catch {
                    return (i + 1, .failed("\(i + 1): invalid @st line: \(error)"))
                }
                continue
            }
            if outcome != nil {
                continue
            }
            do {
                let (metric, values) = try parser.parseSeriesDesc(defLine)
                // The ST line's metric must match, and its value count must match exactly — a
                // per-position correspondence, so `_` placeholders have to line up.
                if let pending = pendingST {
                    if pending.metric != metric {
                        return (
                            i + 1,
                            .failed(
                                "\(i + 1): @st metric does not match the following sample line metric")
                        )
                    }
                    if pending.values.count != values.count {
                        return (
                            i + 1,
                            .failed(
                                "\(i + 1): @st line has \(pending.values.count) values but sample line"
                                    + " has \(values.count)")
                        )
                    }
                }
                var samples = [any PromChunks.Sample]()
                var t = Self.startTime
                for (j, v) in values.enumerated() {
                    defer { t += gap.milliseconds }
                    // An omitted value (`_`) is a HOLE: the timestamp advances and nothing is
                    // appended, which is how a `.test` file writes a gap.
                    if v.omitted {
                        continue
                    }
                    // Go: `s.ST = tsMs + int64(stVals[i].Value)` — the sequence holds OFFSETS in
                    // milliseconds relative to the sample's own timestamp, and they are typically
                    // negative (`-1m` means "this sample's series started a minute before it"). An
                    // omitted ST position leaves the sample's ST at 0, which means "unknown".
                    var st: Int64 = 0
                    if let pending = pendingST, j < pending.values.count, !pending.values[j].omitted {
                        st = t + Int64(pending.values[j].value)
                    }
                    if let h = v.histogram {
                        samples.append(FHSample(st: st, t: t, fh: h))
                    } else {
                        samples.append(FSample(st: st, t: t, f: v.value))
                    }
                }
                pendingST = nil
                let h = metric.goHash()
                if defs[h] == nil { order.append(h) }
                defs[h] = (metric, samples)
            } catch {
                return (i + 1, .failed("\(i + 1): \(defLine): \(String(describing: error))"))
            }
        }

        if pendingST != nil {
            return (i + 1, .failed("\(i + 1): @st line has no following sample line"))
        }

        for h in order {
            guard let d = defs[h] else { continue }
            do {
                try store.load(d.metric, d.samples)
            } catch {
                return (i + 1, .failed("\(i + 1): \(d.metric): \(String(describing: error))"))
            }
        }
        if withNHCB {
            do {
                try appendCustomHistograms(order.compactMap { defs[$0] }, store)
            } catch {
                return (i + 1, .failed("\(i + 1): NHCB conversion: \(String(describing: error))"))
            }
        }
        return (i + 1, outcome)
    }

    /// Go: `loadCmd.appendCustomHistogram` — collate the classic parts by base metric and
    /// timestamp, convert each timestamp's collation to one NHCB, and append those too.
    ///
    /// Three details from upstream that a straight reading would miss:
    ///
    ///   * a `_bucket` series whose `le` fails to parse, or is NaN, is **skipped silently** — not an
    ///     error, because a classic histogram can carry a malformed `le` and the rest is still
    ///     usable. `myHistogram2{le="Hello World"}` in `native_histograms.test` is exactly that;
    ///   * a *histogram-valued* sample inside a classic series is skipped (`if s.H != nil`), so a
    ///     series that is partly classic and partly native contributes only its floats;
    ///   * the result is emitted as a **FloatHistogram** either way: an integer conversion is
    ///     validated and then `ToFloat`ed, so the storage never sees the integer form.
    func appendCustomHistograms(
        _ defs: [(metric: Labels, samples: [any PromChunks.Sample])], _ store: MemStorage
    ) throws {
        // Base metric -> timestamp -> the collation so far. Insertion-ordered, because Go ranges a
        // map here and the append order is not contractual (PORTING.md exception 11's situation).
        var wrappers: [UInt64: (metric: Labels, byTs: [Int64: TempHistogram], order: [Int64])] = [:]
        var wrapperOrder: [UInt64] = []

        for d in defs {
            let mName = d.metric[LabelName.metricName]
            let (suffix, name) = getHistogramMetricBaseName(mName)
            if suffix == .none { continue }

            var setter: ((inout TempHistogram, Double) -> Void)
            switch suffix {
            case .bucket:
                // A malformed or NaN `le` skips the whole series, silently.
                guard let le = try? GoFloat.parse(d.metric["le"]), !le.isNaN else { continue }
                setter = { h, f in h.setBucketCount(le, f) }
            case .count:
                setter = { h, f in h.setCount(f) }
            case .sum:
                setter = { h, f in h.setSum(f) }
            case .none:
                continue
            }

            let base = getHistogramMetricBase(d.metric, name)
            let key = base.goHash()
            var w =
                wrappers[key] ?? {
                    wrapperOrder.append(key)
                    return (metric: base, byTs: [:], order: [])
                }()
            w.metric = base
            for s in d.samples {
                // A histogram-valued sample in a classic series contributes nothing.
                guard s.type == .float else { continue }
                var h = w.byTs[s.t] ?? TempHistogram()
                setter(&h, s.f)
                if w.byTs[s.t] == nil { w.order.append(s.t) }
                w.byTs[s.t] = h
            }
            wrappers[key] = w
        }

        for key in wrapperOrder {
            guard let w = wrappers[key] else { continue }
            var samples = [any PromChunks.Sample]()
            // Sorted by timestamp, as Go's `sort.Slice` does — the storage's append ordering
            // depends on it.
            for t in w.order.sorted() {
                guard let temp = w.byTs[t] else { continue }
                let (ih, fh, err) = temp.convert()
                if let err { throw err }
                var out = fh
                if out == nil, let ih {
                    // Validated, then converted: the storage only ever sees the float form.
                    try ih.validate()
                    out = ih.toFloat()
                }
                guard let out else { continue }
                try out.validate()
                samples.append(FHSample(st: 0, t: t, fh: out))
            }
            if !samples.isEmpty {
                try store.load(w.metric, samples)
            }
        }
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
        var expectedString: String? = nil
        var expectRangeVector = false
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
            // Go: `expectStringPrefix` — an instant query whose answer is a STRING. The literal is
            // Go-quoted, so it goes through `strconv.Unquote`: backticks are a raw string, and
            // `expect string` with nothing after it is an error rather than the empty string.
            if defLine.hasPrefix("expect string") {
                if defLine == "expect string" {
                    return (
                        i + 1,
                        [
                            .failed(
                                "\(loc): expected string literal not valid - a quoted string literal"
                                    + " is required")
                        ]
                    )
                }
                let lit = String(defLine.dropFirst("expect string ".count))
                guard let unquoted = try? GoStrconv.unquote(lit) else {
                    return (
                        i + 1,
                        [
                            .failed(
                                "\(loc): expected string literal not valid - check that the string is"
                                    + " correctly quoted")
                        ]
                    )
                }
                expectedString = unquoted
                continue
            }
            // Go: `rangeVectorPrefix` — an INSTANT query that is allowed to answer with a range
            // vector, over the grid this line names rather than the eval's own single timestamp.
            // Without the directive Go rejects multiple values in an instant evaluation outright.
            if defLine.hasPrefix("expect range vector") {
                guard let (from, to, step) = parseExpectRangeVector(defLine) else {
                    return (
                        i + 1,
                        [.failed("\(loc): invalid range vector definition \"\(defLine)\"")]
                    )
                }
                cmd.from = from
                cmd.to = to
                cmd.step = step
                expectRangeVector = true
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
                        // `expect fail regex:<pattern>` — the pattern, not a placeholder. The
                        // message and the regex are mutually exclusive in `patExpect`.
                        if e.isRegex { failRegexp = e.message }
                        continue
                    }
                    if e.kind == .ordered {
                        cmd.ordered = true
                        continue
                    }
                    // A `regex:` clause is no longer declined: `regexMatchesUnanchored` is the
                    // capture VM's unanchored search, and this is the caller that makes the VM's
                    // first-match cut load-bearing (quirk 115).
                    expects.append(e)
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
        // Go: "expecting multiple values in instant evaluation not allowed. consider using
        // 'expect range vector' directive". An instant eval may only answer with several values per
        // series when the directive says so.
        if cmd.isInstant, !expectRangeVector,
            expected.contains(where: { $0.values.count > 1 })
        {
            return (
                i + 1,
                [
                    .failed(
                        "\(loc): expecting multiple values in instant evaluation not allowed."
                            + " consider using 'expect range vector' directive to enable a range"
                            + " vector result for an instant query")
                ]
            )
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

        return (i + 1, [compare(res, cmd, expected, expectedScalar, loc, expectedString)])
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
        if let regexp {
            // Go: `cmd.expectedFailRegexp.MatchString(err.Error())` — an UNANCHORED search, which
            // `PromRegex`' capture VM provides. The boolean VM cannot: it only answers whole-subject
            // membership, which is why this was declined until `label_replace` landed.
            guard let matched = try? regexMatchesUnanchored(regexp, text) else {
                return .failed("\(loc): \(cmd.expr): unparsable fail regex \(regexp)")
            }
            if !matched {
                return .failed(
                    "\(loc): \(cmd.expr): expected failure matching \(regexp), got \(text)")
            }
        }
        return .passed
    }

    /// Go: `parseExpectRangeVector` — `expect range vector from <dur> to <dur> step <dur>`.
///
/// The three durations are offsets from `testStartTime`, which is the epoch, so they become absolute
/// millisecond timestamps directly.
func parseExpectRangeVector(_ line: String) -> (from: Int64, to: Int64, step: Int64)? {
    // Go uses `patExpectRange`, a regexp with three capture groups. Splitting on the keywords is the
    // same parse and keeps `PromRegex` out of the runner's parse path.
    // `expect range vector from <d> to <d> step <d>` is NINE tokens, not eight.
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 9, parts[0] == "expect", parts[1] == "range", parts[2] == "vector",
        parts[3] == "from", parts[5] == "to", parts[7] == "step"
    else {
        return nil
    }
    guard let from = try? PromDuration.parse(parts[4]), let to = try? PromDuration.parse(parts[6]),
        let step = try? PromDuration.parse(parts[8])
    else {
        return nil
    }
    return (from.milliseconds, to.milliseconds, step.milliseconds)
}

/// Go: `evalCmd.compareResult` — compare the answer against the expectation lines.
    private func compare(
        _ res: Result, _ cmd: EvalCommand,
        _ expected: [(labels: Labels, values: [SequenceValue])], _ expectedScalar: Double?,
        _ loc: String, _ expectedString: String? = nil
    ) -> AssertionOutcome {
        if let expectedString {
            guard let str = res.value as? StringValue else {
                return .failed(
                    "\(loc): \(cmd.expr): expected string result, but got"
                        + " \(res.value?.type.documented ?? "nil")")
            }
            return str.v == expectedString
                ? .passed
                : .failed(
                    "\(loc): \(cmd.expr): expected string \(expectedString), got \(str.v)")
        }
        if let expectedScalar {
            guard let s = try? res.scalar() else {
                return .failed("\(loc): \(cmd.expr): expected a scalar, got \(res.value?.type.documented ?? "nil")")
            }
            return almostEqual(expectedScalar, s.v)
                ? .passed
                : .failed("\(loc): \(cmd.expr): expected \(expectedScalar), got \(s.v)")
        }

        // An instant query yields a Vector; a range query a Matrix — **except** when the expression is
        // a range selector or subquery, which answers with a Matrix from an instant query too. That is
        // what `expect range vector` announces, and the comparison then falls through to the matrix
        // branch below, using the grid the directive named rather than the eval's single timestamp.
        if cmd.isInstant, !(res.value is Matrix) {
            guard let vec = try? res.vector() else {
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
        // Go: `assertMatrixSorted` (test.go:1454) — a range result is contractually sorted by
        // labels, so a correct-but-unsorted matrix is a failure rather than a pass.
        if mat.series.count > 1 {
            for j in 0..<(mat.series.count - 1)
            where Labels.compare(mat.series[j].metric, mat.series[j + 1].metric) > 0 {
                return .failed(
                    "\(loc): \(cmd.expr): matrix results should always be sorted by labels, but"
                        + " matrix is not sorted: series at index \(j + 1) with labels"
                        + " \(mat.series[j + 1].metric) sorts before series at index \(j) with"
                        + " labels \(mat.series[j].metric)")
            }
        }
        for e in expected {
            guard let s = mat.series.first(where: { $0.metric == e.labels }) else {
                return .failed("\(loc): \(cmd.expr): missing series \(e.labels)")
            }
            // **The expectation list is INDEXED BY STEP, and that is what makes a histogram-valued
            // range assertion comparable at all.** Go times value `i` at `start + i*step` and then
            // splits the list into a float list and a histogram list, each of which lines up
            // element-wise with the series' own two point slices. The runner previously declined
            // these 22 assertions because it compared the flat expectation list against `floats`
            // alone, which cannot work once the two kinds interleave — the timestamps are the
            // missing join key, not extra strictness.
            //
            // An OMITTED value is a hole and contributes to neither list; a histogram value is
            // never omitted.
            var wantFloats: [(t: Int64, f: Double)] = []
            var wantHists: [(t: Int64, h: FloatHistogram, hintSet: Bool)] = []
            for (j, v) in e.values.enumerated() {
                let t = cmd.from + Int64(j) * cmd.step
                if t > cmd.to {
                    return .failed(
                        "\(loc): \(cmd.expr): expected \(e.values.count) points for \(e.labels), but"
                            + " query time range cannot return this many points")
                }
                if let h = v.histogram {
                    wantHists.append((t, h, v.counterResetHintSet))
                } else if !v.omitted {
                    wantFloats.append((t, v.value))
                }
            }

            if wantFloats.count != s.floats.count || wantHists.count != s.histograms.count {
                return .failed(
                    "\(loc): \(cmd.expr): expected \(wantFloats.count) float points and"
                        + " \(wantHists.count) histogram points for \(e.labels), but got"
                        + " \(s.floats.count) and \(s.histograms.count)")
            }
            for (j, w) in wantFloats.enumerated() {
                let a = s.floats[j]
                if w.t != a.t {
                    return .failed(
                        "\(loc): \(cmd.expr): expected float value at index \(j) for \(e.labels) to"
                            + " have timestamp \(w.t), but it had timestamp \(a.t)")
                }
                if !almostEqual(a.f, w.f) {
                    return .failed(
                        "\(loc): \(cmd.expr): expected float value at index \(j) (t=\(a.t)) for"
                            + " \(e.labels) to be \(w.f), but got \(a.f)")
                }
            }
            for (j, w) in wantHists.enumerated() {
                let a = s.histograms[j]
                if w.t != a.t {
                    return .failed(
                        "\(loc): \(cmd.expr): expected histogram value at index \(j) for"
                            + " \(e.labels) to have timestamp \(w.t), but it had timestamp \(a.t)")
                }
                var wc = w.h
                var ac = a.h
                if !compareNativeHistogram(
                    wc.compact(maxEmptyBuckets: 0), ac.compact(maxEmptyBuckets: 0),
                    counterResetHintSet: w.hintSet)
                {
                    return .failed(
                        "\(loc): \(cmd.expr): expected histogram value at index \(j) (t=\(a.t)) for"
                            + " \(e.labels) to be \(hDetail(w.h)), but got \(hDetail(a.h))")
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
            // The hint is compared exactly when the expectation WROTE one — test.go:1362 passes
            // `exp0.CounterResetHintSet`, and `SequenceValue` carries the flag. This was hard-coded
            // to `false` until `MemStorage` learnt to DERIVE counter-reset hints (quirk 102): with
            // the flag on and the storage carrying stored hints unchanged, 8 assertions failed with
            // `want hint=notCounterReset, got hint=unknownCounterReset`. Now that the storage plans
            // chunks, an assertion that writes `counter_reset_hint:` actually checks the hint.
            var wantC = wantH
            var gotC = gotH
            return compareNativeHistogram(
                wantC.compact(maxEmptyBuckets: 0), gotC.compact(maxEmptyBuckets: 0),
                counterResetHintSet: want.counterResetHintSet)
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
/// Renders every field `compareNativeHistogram` compares — **count and sum included**.
///
/// They were missing, and that made three `start_timestamps.test` failures unreadable: the message showed
/// only the counter-reset hint differing while the real difference was the count, so the obvious reading
/// (a hint bug) was wrong. A failure message that omits the field it is failing on is worse than no
/// message.
func hDetail(_ h: FloatHistogram) -> String {
    var s = "count=\(GoFloat.format(h.count, .g)) sum=\(GoFloat.format(h.sum, .g))"
    s += " schema=\(h.schema) zt=\(h.zeroThreshold) zc=\(h.zeroCount) hint=\(h.counterResetHint)"
    s += " pSpans=\(h.positiveSpans.map { "(\($0.offset),\($0.length))" }.joined())"
    s += " nSpans=\(h.negativeSpans.map { "(\($0.offset),\($0.length))" }.joined())"
    s += " pB=\(h.positiveBuckets) nB=\(h.negativeBuckets) cv=\(h.customValues.map(String.init(describing:)) ?? "nil")"
    return s
}

// MARK: - `@st` lines

/// Go: `isSTLine` — a start-timestamp line is `metric{labels}@st <sequence>`, with **no space** before
/// `@st`. So the test is on the first whitespace-delimited token, not on the line.
func isSTLine(_ defLine: String) -> Bool {
    let t = defLine.trimmed()
    guard let spaceIdx = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
        return false
    }
    return t[t.startIndex..<spaceIdx].hasSuffix("@st")
}

/// Go: `parseSTLine` — the metric and the offset sequence.
///
/// The metric is parsed by handing `metricPart + " _"` to the ordinary series-description parser, which
/// is upstream's trick too: it avoids a second label parser at the cost of a dummy value.
func parseSTLine(_ defLine: String) throws -> (metric: Labels, values: [SequenceValue]) {
    let t = defLine.trimmed()
    guard let spaceIdx = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
        throw STParseError("invalid @st line: missing value sequence")
    }
    let metricPart = String(t[t.startIndex..<spaceIdx].dropLast(3))  // drop "@st"
    let valsPart = String(t[spaceIdx...]).trimmed()
    let (metric, _) = try Parser(options: Options()).parseSeriesDesc(metricPart + " _")
    return (metric, try parseSTSequence(valsPart))
}

/// Go: `parseDurationPrefix` — a signed Prometheus duration at the head of a string, in milliseconds,
/// plus whatever follows.
///
/// The unit scan stops at `x` explicitly, because `x` is the repeat-count separator and never part of a
/// duration unit — without that, `1mx3` would try to parse `mx` as a unit.
func parseDurationPrefix(_ s: String) throws -> (ms: Int64, rest: String) {
    if s.isEmpty { throw STParseError("empty duration") }
    let chars = Array(s)
    var negative = false
    var i = 0
    if chars[0] == "-" {
        negative = true
        i = 1
    } else if chars[0] == "+" {
        i = 1
    }
    let start = i
    while i < chars.count, chars[i].isNumber { i += 1 }
    if i == start {
        throw STParseError("expected digits in duration \"\(s)\"")
    }
    while i < chars.count, chars[i].isLetter, chars[i] != "x" { i += 1 }
    let text = String(chars[start..<i])
    guard let dur = try? PromDuration.parse(text) else {
        throw STParseError("invalid duration \"\(text)\"")
    }
    var ms = dur.milliseconds
    if negative { ms = -ms }
    return (ms, String(chars[i...]))
}

/// Go: `parseSTItem`. The grammar, from upstream's comment:
///
/// ```
/// _              one omitted position
/// _xN            N omitted positions
/// <dur>          one position
/// <dur>xN        N+1 positions, all the same
/// <dur>+<dur>xN  N+1 positions, offset increasing by the delta each step
/// <dur>-<dur>xN  N+1 positions, decreasing
/// ```
///
/// Note the asymmetry: `_xN` gives **N** positions while `<dur>xN` gives **N+1**. That is upstream's,
/// and it matches the series-description grammar, where `x` means "and N more".
func parseSTItem(_ item: String) throws -> [SequenceValue] {
    if item == "_" {
        return [SequenceValue(omitted: true)]
    }
    if item.hasPrefix("_x") {
        guard let n = UInt64(item.dropFirst(2)), n > 0 else {
            throw STParseError("invalid repeat count")
        }
        return (0..<Int(n)).map { _ in SequenceValue(omitted: true) }
    }

    let (base, rest) = try parseDurationPrefix(item)
    if rest.isEmpty {
        return [SequenceValue(value: Double(base))]
    }
    if rest.hasPrefix("x") {
        guard let n = UInt64(rest.dropFirst()) else {
            throw STParseError("invalid repeat count")
        }
        return (0...Int(n)).map { _ in SequenceValue(value: Double(base)) }
    }
    guard rest.hasPrefix("+") || rest.hasPrefix("-") else {
        throw STParseError("unexpected character \"\(rest.first!)\" after duration")
    }
    let negative = rest.hasPrefix("-")
    let (deltaMagnitude, rest2) = try parseDurationPrefix(String(rest.dropFirst()))
    let delta = negative ? -deltaMagnitude : deltaMagnitude
    guard rest2.hasPrefix("x") else {
        throw STParseError("expected 'x<count>' after step duration")
    }
    guard let n = UInt64(rest2.dropFirst()) else {
        throw STParseError("invalid repeat count")
    }
    var out: [SequenceValue] = []
    var offset = base
    for _ in 0...Int(n) {
        out.append(SequenceValue(value: Double(offset)))
        offset += delta
    }
    return out
}

/// Go: `parseSTSequence`.
func parseSTSequence(_ input: String) throws -> [SequenceValue] {
    var out: [SequenceValue] = []
    for item in input.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        out.append(contentsOf: try parseSTItem(String(item)))
    }
    return out
}

/// The runner's own errors for a malformed `@st` block. Not byte-exact against Go: these reach a test
/// report rather than a user, and `promqltest`'s own messages are `raise(line, ...)`-formatted with a
/// line number the port supplies separately.
struct STParseError: Error, CustomStringConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var description: String { text }
}
