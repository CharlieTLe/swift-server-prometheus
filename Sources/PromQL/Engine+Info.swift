//===----------------------------------------------------------------------===//
// Ported from promql/info.go @ v3.13.2
//
// `info(v, {…})` enriches a vector with data labels from *info metrics* — series like `target_info`
// whose whole job is to carry metadata keyed by an identifying label set. It works on **series, not
// samples**, so like `label_join` it is dispatched straight from the `Call` arm and never appears in
// `functionCalls` (quirk 62).
//
// ## The whole function is a join on a synthesised signature
//
// A base series and an info series belong together when they agree on the *identifying labels*, which
// upstream hard-codes to `instance` and `job` — `identifyingLabels`, with a comment saying the list is
// fixed so the engine needs no knowledge of individual info metrics. The signature is
// `__name__=<info metric name>` plus whichever identifying labels the series carries, sorted; two
// series with the same signature join.
//
// Note what that means for a base series with **neither** `instance` nor `job`: its signature is just
// the info metric's name, so it joins any info series that also has neither. That is upstream's
// behaviour and `info.test` asserts it.
//
// ## `__name__` matchers are not data label matchers, and the difference is load-bearing
//
// The second argument is parsed as a `VectorSelector`, but it is a *label selector*: its matchers say
// which data labels to copy. A `__name__` matcher inside it means something else entirely — it selects
// which info *metrics* to consider — so it is pulled out into `infoNameMatchers` and then **removed**
// from `dataLabelMatchers`. `removeNameFromDataLabelMatchers` is called on both exits, including the
// early one, and upstream's comment explains why: leaving it in makes `combineWithInfoVector` treat
// `__name__` as "the only data label asked for" and exclude every series.
//
// ## `effectiveInfoNameMatchers` has three cases and only the middle one is surprising
//
//   * any positive matcher (`=` or `=~`) present -> use the matchers as given;
//   * **only negative** matchers -> prepend a synthetic `__name__=~".+_info"`, because a set of
//     exclusions alone would otherwise select every series in the store;
//   * none at all -> `__name__="target_info"`.
//
// ## Info sample timestamps ride in the float VALUE
//
// `fetchInfoSeries` calls `evalSeries(…, recordOrigT: true)`, which puts each sample's *original*
// timestamp in `F` instead of its value. `combineWithInfoVector` then reads `int64(s.F)` back out and
// uses it to break ties between two info series with the same signature: the newer one wins, and an
// exact tie is a **query error**, not a warning. An info metric's actual value is never used.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromQLParser
internal import PromRegex
internal import PromStorage

/// Go: `targetInfo`.
private let targetInfoName = "target_info"

/// Go: `identifyingLabels` — "currently hard coded, so we don't need knowledge of individual info
/// metrics".
private let identifyingLabels = ["instance", "job"]

extension Evaluator {

    /// Go: `evalInfo`.
    func evalInfo(
        _ ctx: GoContext, _ args: [any Expr], _ ws: inout Annotations
    ) throws -> any Value {
        // `evalNode`, not `eval` — Go's internal `eval`, which does NOT run
        // `cleanupMetricLabels`. The outer one would apply the deferred `DropName` to the argument,
        // and `info` reads `__name__` (through `ignoreSeries` and the signature), so a name removed
        // early changes the answer. `label_replace` had the same trap and `label_join` did not.
        let val = try evalNode(ctx, args[0], &ws)
        // Go: an unchecked `val.(Matrix)` type assertion — the parser's type checking guarantees it,
        // so a failure here is an internal invariant rather than a user error.
        guard let mat = val as? Matrix else {
            throw EvaluationError.unknownValueType("info: expected a matrix")
        }

        // Data label name -> its matchers. A `__name__` matcher goes in BOTH here and
        // `infoNameMatchers`, and is removed from here later — see the file header.
        var dataLabelMatchers: [String: [Matcher]] = [:]
        var dataLabelOrder: [String] = []
        var infoNameMatchers: [Matcher] = []
        if args.count > 1 {
            // Go: "TODO: Introduce a dedicated LabelSelector type." The second argument really is a
            // `VectorSelector`, and it is used as a bag of matchers rather than as a selector.
            guard let labelSelector = args[1] as? VectorSelector else {
                throw EvaluationError.unknownValueType("info: expected a vector selector")
            }
            // `labelMatchers` is `[Matcher?]` because Go's is `[]*labels.Matcher` and a nil element is
            // representable; the parser never produces one.
            for m in labelSelector.labelMatchers.compactMap({ $0 }) {
                if dataLabelMatchers[m.name] == nil { dataLabelOrder.append(m.name) }
                dataLabelMatchers[m.name, default: []].append(m)
                if m.name == LabelName.metricName {
                    infoNameMatchers.append(m)
                }
            }
        } else {
            infoNameMatchers = [try Matcher(.equal, LabelName.metricName, targetInfoName)]
        }

        // "Don't try to enrich info series." A series whose name matches EVERY effective name matcher
        // is itself an info series, so it passes through untouched.
        let effectiveNameMatchers = try effectiveInfoNameMatchers(infoNameMatchers)
        var ignoreSeries = Set<UInt64>()
        for s in mat.series {
            let name = s.metric[LabelName.metricName]
            if effectiveNameMatchers.allSatisfy({ $0.matches(name) }) {
                ignoreSeries.insert(s.metric.goHash())
            }
        }

        let selectHints = infoSelectHints(args[0])
        let (infoMat, fetchWs) = try fetchInfoSeries(
            ctx, mat, ignoreSeries, &dataLabelMatchers, &dataLabelOrder, selectHints)
        ws.merge(fetchWs)

        let (res, combineWs) = try combineWithInfoSeries(
            ctx, mat, infoMat, ignoreSeries, dataLabelMatchers)
        ws.merge(combineWs)
        return res
    }

    /// Go: `effectiveInfoNameMatchers` — see the file header for the three cases.
    private func effectiveInfoNameMatchers(_ matchers: [Matcher]) throws -> [Matcher] {
        for m in matchers where m.type == .equal || m.type == .regexp {
            // At least one positive matcher: use them as given.
            return matchers
        }
        if !matchers.isEmpty {
            // Only negatives. Without the synthetic matcher the selection would be "everything except
            // these", which is every series in the store.
            return try [Matcher(.regexp, LabelName.metricName, ".+_info")] + matchers
        }
        return [try Matcher(.equal, LabelName.metricName, targetInfoName)]
    }

    /// Go: `infoSelectHints` — the hints for selecting the INFO series, derived from the first
    /// argument's own selector.
    ///
    /// Two subtleties. `Inspect` stops at the **first** `VectorSelector` (it returns an error to end
    /// the traversal), so a nested expression contributes only its leftmost selector's `@` and
    /// `offset`. And the start is reduced by `lookbackDelta - 1` rather than `lookbackDelta`, with
    /// upstream's comment: "we want to exclude samples that are precisely the lookback delta before
    /// the eval time".
    private func infoSelectHints(_ expr: any Expr) -> SelectHints {
        var nodeTimestamp: Int64? = nil
        var offset: Int64 = 0
        inspect(expr) { node, _ in
            guard let n = node as? VectorSelector else { return }
            if let ts = n.timestamp {
                nodeTimestamp = ts
            }
            offset = durationMilliseconds(n.originalOffset)
            // Go: `errors.New("end traversal")` — throwing is how `Inspect` is stopped, and the
            // port's `inspect` swallows it exactly as Go's `//nolint:errcheck` does.
            throw EndTraversal()
        }

        var start = startTimestamp
        var end = endTimestamp
        if let ts = nodeTimestamp {
            // "The timestamp on the selector overrides everything."
            start = ts
            end = ts
        }
        start -= durationMilliseconds(lookbackDelta) - 1
        start -= offset
        end -= offset

        return SelectHints(start: start, end: end, step: interval, func_: "info")
    }

    /// Go: `fetchInfoSeries` — select the info series whose identifying labels appear in `mat`.
    ///
    /// The selector is built by collecting every value each identifying label takes across the base
    /// matrix and joining them into one alternation per label, `QuoteMeta`d. **Go ranges a map to
    /// build that alternation**, so the order of the branches is nondeterministic upstream — and
    /// unobservable, because alternation is order-insensitive for matching and the regexp never
    /// reaches the user. The port joins in first-seen order; recorded as exception 16.
    private func fetchInfoSeries(
        _ ctx: GoContext, _ mat: Matrix, _ ignoreSeries: Set<UInt64>,
        _ dataLabelMatchers: inout [String: [Matcher]], _ dataLabelOrder: inout [String],
        _ selectHints: SelectHints
    ) throws -> (Matrix, Annotations) {
        // Go: a closure, called on BOTH exits — see the file header on why the early one matters.
        func removeNameFromDataLabelMatchers() {
            for name in dataLabelOrder {
                guard var ms = dataLabelMatchers[name] else { continue }
                ms.removeAll { $0.name == LabelName.metricName }
                if ms.isEmpty {
                    dataLabelMatchers.removeValue(forKey: name)
                } else {
                    dataLabelMatchers[name] = ms
                }
            }
            dataLabelOrder = dataLabelOrder.filter { dataLabelMatchers[$0] != nil }
        }

        // Values per identifying label, in first-seen order.
        var idLblValues: [String: [String]] = [:]
        var idLblSeen: [String: Set<String>] = [:]
        var idLblOrder: [String] = []
        for s in mat.series {
            if ignoreSeries.contains(s.metric.goHash()) { continue }
            for l in identifyingLabels {
                let val = s.metric[l]
                if val.isEmpty { continue }
                if idLblValues[l] == nil {
                    idLblValues[l] = []
                    idLblSeen[l] = []
                    idLblOrder.append(l)
                }
                if idLblSeen[l]!.insert(val).inserted {
                    idLblValues[l]!.append(val)
                }
            }
        }
        if idLblValues.isEmpty {
            removeNameFromDataLabelMatchers()
            return (Matrix(), Annotations())
        }

        var infoLabelMatchers: [Matcher] = []
        for name in idLblOrder {
            let re = idLblValues[name]!.map(goQuoteMeta).joined(separator: "|")
            infoLabelMatchers.append(try Matcher(.regexp, name, re))
        }
        // A `__name__` matcher in the label selector picks info METRICS; everything else is a data
        // label constraint on the info series.
        var nameMatchers: [Matcher] = []
        for name in dataLabelOrder {
            for m in dataLabelMatchers[name] ?? [] {
                if m.name == LabelName.metricName {
                    nameMatchers.append(m)
                } else {
                    infoLabelMatchers.append(m)
                }
            }
        }
        removeNameFromDataLabelMatchers()
        infoLabelMatchers += try effectiveInfoNameMatchers(nameMatchers)

        // `info` is the only function that selects during evaluation — every other selector was
        // populated by `populateSeries` before the evaluator ran. A missing querier means the
        // evaluator was built without storage, which only tests do.
        guard let querier else {
            return (Matrix(), Annotations())
        }
        let infoIt = querier.select(
            ctx, sortSeries: false, hints: selectHints, matchers: infoLabelMatchers)
        let (infoSeries, ws) = try expandSeriesSet(ctx, infoIt)
        // `recordOrigT: true` — the sample's ORIGINAL timestamp rides in the float value, which is
        // how the newest-wins tie-break below works.
        let infoMat = try evalSeries(ctx, infoSeries, GoDuration(nanoseconds: 0), true)
        return (infoMat, ws)
    }

    /// Go: `combineWithInfoSeries` — step over the range, joining base and info vectors per timestamp.
    ///
    /// The same shape as `rangeEval`: gather both vectors at `ts`, combine, accumulate into output
    /// series. The sample accounting is Go's, including the `tempNumSamples` dance that keeps the
    /// running result's samples counted while resetting the per-step figure.
    private func combineWithInfoSeries(
        _ ctx: GoContext, _ mat: Matrix, _ infoMat: Matrix, _ ignoreSeries: Set<UInt64>,
        _ dataLabelMatchers: [String: [Matcher]]
    ) throws -> (Matrix, Annotations) {
        // Go: `sigFunction(name)` — `__name__=name` plus the identifying labels this series carries,
        // sorted, then `Bytes()`.
        //
        // Upstream hashes to a byte string; the port keys on `Labels` itself, which is `Hashable` and
        // injective where `Bytes()` is merely documented not to be a compatibility surface
        // (exception 1). The signature never leaves the query, so the only requirement is that equal
        // signatures mean equal joins.
        func signature(_ name: String, _ lset: Labels) -> Labels {
            var b = ScratchBuilder()
            b.add(LabelName.metricName, name)
            for l in lset.matchLabels(on: true, identifyingLabels) {
                b.add(l.name, l.value)
            }
            b.sort()
            return b.labels()
        }

        var infoMetrics: [String] = []
        var infoMetricsSeen = Set<String>()
        for s in infoMat.series {
            let name = s.metric[LabelName.metricName]
            if infoMetricsSeen.insert(name).inserted {
                infoMetrics.append(name)
            }
        }

        let numSteps = Int((endTimestamp - startTimestamp) / interval) + 1
        _ = numSteps  // Go passes it to `addToSeries` to size a pooled slice; exception 4 drops it.
        let originalNumSamples = currentSamples

        // Signatures, computed once per series rather than once per step.
        var baseSigs: [UInt64: [String: Labels]] = [:]
        for s in mat.series {
            var sigs: [String: Labels] = [:]
            for infoName in infoMetrics {
                sigs[infoName] = signature(infoName, s.metric)
            }
            baseSigs[s.metric.goHash()] = sigs
        }
        var infoSigs: [UInt64: Labels] = [:]
        for s in infoMat.series {
            let name = s.metric[LabelName.metricName]
            infoSigs[s.metric.goHash()] = signature(name, s.metric)
        }

        var base: Matrix? = mat
        var info: Matrix? = infoMat
        var noHelpers: [EvalSeriesHelper] = []
        var seriess: [UInt64: (series: Series, ts: Int64)] = [:]
        var seriesOrder: [UInt64] = []
        var tempNumSamples = currentSamples
        var warnings = Annotations()

        var ts = startTimestamp
        while ts <= endTimestamp {
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            currentSamples = tempNumSamples
            let baseVector = try gatherVectorForInfo(ts, &base, &noHelpers)
            let infoVector = try gatherVectorForInfo(ts, &info, &noHelpers)

            let result = try combineWithInfoVector(
                baseVector, infoVector, ignoreSeries, baseSigs, infoSigs, dataLabelMatchers,
                &warnings)

            let vecNumSamples = result.totalSamples
            currentSamples += vecNumSamples
            // Go's comment: the next iteration resets `currentSamples` to `tempNumSamples`, so the
            // result's own samples have to be folded into it or they stop being accounted for.
            tempNumSamples += vecNumSamples
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }

            for sample in result.samples {
                let h = sample.metric.goHash()
                if var ss = seriess[h] {
                    if ss.ts == ts {
                        // Go: `ev.errorf` — a hard query error, not a warning.
                        throw EvaluationError.duplicateLabelset
                    }
                    ss.ts = ts
                    addToSeries(&ss.series, ts, sample.f, sample.h)
                    seriess[h] = ss
                } else {
                    var ss = (series: Series(metric: sample.metric), ts: ts)
                    addToSeries(&ss.series, ts, sample.f, sample.h)
                    seriess[h] = ss
                    seriesOrder.append(h)
                }
            }
            ts += interval
        }

        // Go assembles by ranging `seriess`, a map — the fourth instance of exception 7's situation,
        // and the same answer as exception 14: first-insertion order.
        var numSamples = 0
        var output = Matrix()
        for h in seriesOrder {
            guard let ss = seriess[h] else { continue }
            numSamples += ss.series.floats.count + totalHPointSize(ss.series.histograms)
            output.series.append(ss.series)
        }
        currentSamples = originalNumSamples + numSamples
        return (output, warnings)
    }

    /// `gatherVector` is private to `Engine+Eval.swift` and takes the helper arrays this path has no
    /// use for; this is the two-argument call site spelled out rather than widening that signature.
    private func gatherVectorForInfo(
        _ ts: Int64, _ input: inout Matrix?, _ bufHelpers: inout [EvalSeriesHelper]
    ) throws -> Vector {
        guard input != nil else { return Vector() }
        var out = Vector()
        out.samples.reserveCapacity(input!.series.count)
        for i in 0..<input!.series.count {
            let series = input!.series[i]
            if let f = series.floats.first, f.t == ts {
                out.samples.append(
                    Sample(t: ts, f: f.f, metric: series.metric, dropName: series.dropName))
                input!.series[i].floats.removeFirst()
            } else if let h = series.histograms.first, h.t == ts {
                out.samples.append(
                    Sample(t: ts, h: h.h, metric: series.metric, dropName: series.dropName))
                input!.series[i].histograms.removeFirst()
            } else {
                continue
            }
            currentSamples += 1
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }
        }
        return out
    }

    /// Go: `combineWithInfoVector` — one timestamp's join.
    private func combineWithInfoVector(
        _ base: Vector, _ info: Vector, _ ignoreSeries: Set<UInt64>,
        _ baseSigs: [UInt64: [String: Labels]], _ infoSigs: [UInt64: Labels],
        _ dataLabelMatchers: [String: [Matcher]], _ warnings: inout Annotations
    ) throws -> Vector {
        if base.samples.isEmpty {
            // "Short-circuit: nothing is going to match."
            return Vector()
        }

        // Info samples by signature, newest wins. The "timestamp" is the ORIGINAL sample timestamp,
        // which rides in the float value — see the file header.
        var rightStrSigs: [Labels: Sample] = [:]
        for s in info.samples {
            if s.h != nil {
                throw EvaluationError.infoSampleShouldBeFloat
            }
            let origT = Int64(s.f)
            guard let sig = infoSigs[s.metric.goHash()] else { continue }
            if let existing = rightStrSigs[sig] {
                let existingOrigT = Int64(existing.f)
                if existingOrigT > origT {
                    // Keep the other one; it is newer.
                } else if existingOrigT < origT {
                    rightStrSigs[sig] = s
                } else {
                    // An exact tie is unresolvable, so it is an ERROR rather than a choice.
                    throw EvaluationError.duplicateSeriesForInfoMetric(
                        existing: "\(existing.metric)", existingT: existingOrigT,
                        new: "\(s.metric)", newT: origT)
                }
            } else {
                rightStrSigs[sig] = s
            }
        }

        var out = Vector()
        for bs in base.samples {
            let hash = bs.metric.goHash()

            if ignoreSeries.contains(hash) {
                // An info series itself: passed through with no enrichment.
                out.samples.append(Sample(t: bs.t, f: bs.f, h: bs.h, metric: bs.metric))
                continue
            }

            let baseLabels = bs.metric.map()
            var lb = LabelsBuilder(Labels())

            // For each info metric name, find an info series with the matching signature.
            var seenInfoMetrics = Set<String>()
            for (infoName, sig) in (baseSigs[hash] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let isample = rightStrSigs[sig] else { continue }
                if seenInfoMetrics.contains(infoName) { continue }

                // Go: `is.Metric.Validate(func(l) error)` — a closure returning an error aborts the
                // whole query. Only a genuine conflict does: `__name__` is skipped, a label not among
                // the requested data labels is skipped, and a label already on the base metric is
                // skipped.
                for l in isample.metric {
                    if l.name == LabelName.metricName { continue }
                    if !dataLabelMatchers.isEmpty && dataLabelMatchers[l.name] == nil {
                        // Not among the specified data label matchers.
                        continue
                    }
                    let v = lb.get(l.name)
                    if !v.isEmpty && v != l.value {
                        throw EvaluationError.conflictingLabel(l.name)
                    }
                    if baseLabels[l.name] != nil {
                        // Already on the base metric, so the base wins.
                        continue
                    }
                    lb.set(l.name, l.value)
                }
                seenInfoMetrics.insert(infoName)
            }

            let infoLbls = lb.labels()
            if seenInfoMetrics.isEmpty {
                // No info series matched. If any data label matcher does NOT match the empty string,
                // this base series has to be DROPPED — the matcher asked for a label that cannot be
                // supplied.
                var allMatchersMatchEmpty = true
                outer: for (_, ms) in dataLabelMatchers {
                    for m in ms where !m.matches("") {
                        allMatchersMatchEmpty = false
                        break outer
                    }
                }
                if !allMatchersMatchEmpty {
                    continue
                }
            }

            var ob = LabelsBuilder(bs.metric)
            for l in infoLbls {
                ob.set(l.name, l.value)
            }
            out.samples.append(Sample(t: bs.t, f: bs.f, h: bs.h, metric: ob.labels()))
        }
        return out
    }
}

/// Go: `errors.New("end traversal")` — `Inspect`'s stop signal, which is an error by convention
/// rather than because anything went wrong.
private struct EndTraversal: Error {}
