//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `query.Exec`, `Engine.exec`, **both** halves of
// `execEvalStmt`, `contextDone`, `setOffsetForAtModifier`, and the `evaluator` core:
// `Eval`, `rangeEval`, `addToSeries`, and the `eval` arms that need no matrix selector.
//
// ## What this slice can evaluate, and what it refuses
//
// Ported arms: `NumberLiteral`, `StringLiteral`, `ParenExpr`, `UnaryExpr`, `VectorSelector`,
// `StepInvariantExpr`, `BinaryExpr` where both sides are **scalars**, and `Call` where no
// argument is a matrix selector or subquery — as **instant or range** queries.
//
// Everything else — aggregations, subqueries, matrix arguments, the four vector/scalar binop
// shapes — throws `EvaluatorNotPorted`. That is a **loud** stub with a named expression type,
// not a silent wrong answer, and the fixture corpus is restricted to what is implemented
// rather than the port pretending otherwise.
//
// ## An instant query is a range evaluation with one step, and `interval` is 1
//
// `execEvalStmt` builds the evaluator with `startTimestamp == endTimestamp` and
// **`interval: 1`** — not 0, which would divide by zero in `rangeEval`'s `numSteps`. The
// step loop then runs exactly once.
//
// `rangeEval`'s instant shortcut is the interesting part: when `endTimestamp ==
// startTimestamp` it builds the output matrix *directly from the result vector*, in the
// vector's own order, and returns before the map-based series assembly. Upstream's comment
// says "shortcut so as not to change sort order" — and that is load-bearing for `sort`,
// whose whole purpose is an order that a hash map would destroy.
//
// Note the guard `execEvalStmt` tests is `start == end && interval == 0` — **both**. So a
// *range* query whose start equals its end is a range evaluation with one step, and its
// result is a `Matrix` rather than a `Scalar`: the range path has no type tails at all.
//
// ## The sample limit is enforced in TWO places, and the peak is higher than it looks
//
// `rangeEval` resets `currentSamples` to `tempNumSamples` at the top of every step, adds the
// result's `TotalSamples()` and only then compares with `maxSamples` — so a step that
// exceeds the limit is *computed in full* before being rejected.
//
// But `gatherVector` also counts, one per input sample, and raises the same error itself. So
// the peak for `1 + 2` is **5**: one for each literal's own evaluation, two more as the
// operands are gathered, one for the result. A port that only counted results would accept a
// query Go rejects, which is what the corpus caught here — the boundary is pinned per shape
// rather than assumed.
//
// Two more accounting details belong to the range path and are invisible in an instant query:
// `tempNumSamples` **grows** by every step's result, so the peak rises with the number of
// steps; and the final `currentSamples = originalNumSamples + mat.totalSamples` *discards*
// the last step's gathered inputs. The second is only observable to an **enclosing**
// `rangeEval`, which reads `currentSamples` as its own `tempNumSamples` right after evaluating
// its arguments — so `(time() + 1) + 1` under a tight limit is what pins it, and nothing
// simpler can.
//
// ## How much of this file is actually PINNED, and how much is only transcribed
//
// Be clear about this, because green fixtures could be read as covering the file and they do
// not. Two corpora pin it: `promql/exec` (instant) and `promql/exec-range` (range). The range
// slice ran 15 negative controls of which **12 break**, and the three survivors each have an
// argument rather than a shrug:
//
//   * the multi-step assembly's duplicate check (`ss.ts == ts`) is **unreachable**: it needs
//     one step's result vector to hold two samples with the same label hash. A selector cannot
//     produce that — two series with one label set are one series to the storage — and no
//     ported function drops a *differing* label. `label_replace` and the aggregations make it
//     reachable; the check is transcribed now because a stub would be a silent wrong answer.
//   * the step duplication reading `floats[0]` versus `floats.last!` is **provably identical**:
//     every point the loop appends carries `floats[0].f`, so `last` always *is* `floats[0]`.
//   * the assembly's output ORDER is **provably unobservable in this slice**: the range tail
//     sorts, and no ported consumer reads the assembly's order — a nested `rangeEval` gathers
//     by timestamp, and a multi-series matrix comes from `evalSeries` rather than from here.
//     That is what licenses the insertion-order choice below rather than Go's map order.
//
// One survivor from the instant slice is *provably* absorbed the same way: `gatherVector`'s
// `> maxSamples` versus `>=`. Reaching the limit exactly at the gather always means the
// result — which adds at least one more sample — trips `rangeEval`'s own `>` check
// immediately after, so both spellings reject the same queries.
//
// A fourth behaviour is pinned Swift-side rather than differentially: which of a series' two
// point slices `addToSeries` grows. Putting a histogram in the float slice survives the whole
// differential corpus, because that corpus is float-only *on purpose* — a histogram appended
// to a real `tsdb.DB` returns through the chunk encoding, which re-derives
// `CounterResetHint`, so pinning it would pin Phases 6-7's subject. `sort_by_label` is the
// only ported function that passes a histogram sample *through* a `rangeEval` (`sort` and
// `sort_desc` drop them in `filterFloats`), which is why the test uses it.
//
// ## `setOffsetForAtModifier` rewrites the AST before evaluation
//
// A selector with `@` gets `Offset = originalOffset + (evalTime - timestamp)`, so the rest
// of the evaluator can ignore `@` entirely and read `Offset`. It runs once per query, on
// the statement's *start* time, which is why an instant query and a range query over the
// same expression can produce different offsets. Observable through `Statement()` after
// `Exec`, which is how the fixture pins it.
//
// It also explains why the step-duplication path is *visible*: for `http_requests @ 60` over
// three steps the rewritten offset is measured from the START time, so an evaluator that ran
// the selector per step would read a different sample each time. Upstream evaluates it once
// and copies the point, and the corpus's three equal values with three timestamps is the
// difference.
//===----------------------------------------------------------------------===//

public import GoCompat
public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromQLParser
public import PromStorage

internal import PromModel
internal import PromSchema

/// The expression kinds this slice does not evaluate yet. Thrown rather than trapped so a
/// caller sees which node stopped it.
public struct EvaluatorNotPorted: Error, CustomStringConvertible {
    public var nodeType: String
    public var detail: String

    public var description: String {
        "promql evaluator: \(nodeType) is not ported yet\(detail.isEmpty ? "" : " (\(detail))")"
    }
}

/// Go: `env` — the location string the query errors carry (engine.go:57).
let evaluationEnv = "query execution"

/// Go: `contextDone` — the query error for a cancelled or timed-out context, or nil.
func contextDone(_ ctx: GoContext, _ env: String) -> (any Error)? {
    guard let err = ctx.err() else {
        return nil
    }
    // `GoContext.err()` already distinguishes the two reasons, which is what `contextErr`
    // needs — Go reads them off `context.Canceled`/`DeadlineExceeded` with `errors.Is`.
    switch err {
    case .canceled:
        return contextErr(ContextCancellation.canceled, env)
    case .deadlineExceeded:
        return contextErr(ContextCancellation.deadlineExceeded, env)
    }
}

/// Go: `evaluator` — evaluates one expression over a fixed set of timestamps.
///
/// A class because Go passes `*evaluator` and mutates `currentSamples` through it.
final class Evaluator {
    var startTimestamp: Int64
    var endTimestamp: Int64
    /// Go: `interval` — **1** for an instant query, never 0.
    var interval: Int64
    var currentSamples: Int
    let maxSamples: Int
    let lookbackDelta: GoDuration
    let noStepSubqueryIntervalFn: (@Sendable (Int64) -> Int64)?
    let enableDelayedNameRemoval: Bool
    let enableTypeAndUnitLabels: Bool
    let useStartTimestamps: Bool

    init(
        startTimestamp: Int64, endTimestamp: Int64, interval: Int64, currentSamples: Int = 0,
        maxSamples: Int, lookbackDelta: GoDuration,
        noStepSubqueryIntervalFn: (@Sendable (Int64) -> Int64)?,
        enableDelayedNameRemoval: Bool, enableTypeAndUnitLabels: Bool, useStartTimestamps: Bool
    ) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.interval = interval
        self.currentSamples = currentSamples
        self.maxSamples = maxSamples
        self.lookbackDelta = lookbackDelta
        self.noStepSubqueryIntervalFn = noStepSubqueryIntervalFn
        self.enableDelayedNameRemoval = enableDelayedNameRemoval
        self.enableTypeAndUnitLabels = enableTypeAndUnitLabels
        self.useStartTimestamps = useStartTimestamps
    }

    /// Go: `Eval` — the top level, which recovers panics into an error.
    ///
    /// Go's `defer ev.recover(...)` catches the panics `ev.error` raises; Swift throws
    /// instead, so the classification lives in `classifyEvaluationError` and the
    /// `ErrWithWarnings` unwrapping happens here.
    func eval(_ ctx: GoContext, _ expr: any Expr) throws -> (any Value, Annotations) {
        var ws = Annotations()
        do {
            var v = try evalNode(ctx, expr, &ws)
            // With delayed name removal on, every body left `__name__` in place and recorded the
            // intent in `DropName`. This is where that intent is finally applied — ONCE, at the
            // top, after the whole expression has been evaluated. That is the point of deferring
            // it: an intermediate result keeps its name, so a nested expression can still match on
            // it, and only the answer loses it.
            if enableDelayedNameRemoval {
                v = try cleanupMetricLabels(v)
            }
            return (v, ws)
        } catch let e as ErrWithWarnings {
            _ = ws.merge(e.warnings)
            throw ErrWithWarnings(e.err, ws)
        }
    }

    /// Go: `eval` — the big switch, restricted to the storage-free arms.
    func evalNode(_ ctx: GoContext, _ expr: any Expr, _ ws: inout Annotations) throws -> any Value {
        if let err = contextDone(ctx, "expression evaluation") {
            throw err
        }
        // engine.go:2057 — an inverted range yields an empty matrix rather than an error.
        if endTimestamp < startTimestamp {
            return Matrix()
        }

        switch expr {
        case let e as NumberLiteral:
            return try rangeEval(ctx, nil, &ws, []) { _, _, enh in
                var out = enh.out
                out.append(Sample(f: e.val, metric: .empty))
                return (out, Annotations())
            }

        case let e as StringLiteral:
            // The only arm that does not go through rangeEval, and the only one that
            // returns something other than a Matrix.
            return StringValue(t: startTimestamp, v: String(decoding: e.val, as: UTF8.self))

        case let e as ParenExpr:
            return try evalNode(ctx, e.expr, &ws)

        case let e as UnaryExpr:
            let val = try evalNode(ctx, e.expr, &ws)
            guard var mat = val as? Matrix else {
                throw EvaluatorNotPorted(nodeType: "UnaryExpr", detail: "non-matrix operand")
            }
            if e.op == .sub {
                for i in 0..<mat.series.count {
                    if !enableDelayedNameRemoval {
                        mat.series[i].metric = mat.series[i].metric.dropReserved(isMetadataLabel)
                    }
                    mat.series[i].dropName = true
                    for j in 0..<mat.series[i].floats.count {
                        mat.series[i].floats[j].f = -mat.series[i].floats[j].f
                    }
                    for j in 0..<mat.series[i].histograms.count {
                        var h = mat.series[i].histograms[j].h.copy()
                        _ = h.mul(-1)
                        mat.series[i].histograms[j].h = h
                    }
                }
                if !enableDelayedNameRemoval {
                    mat = try mergeSeriesWithSameLabelset(mat)
                }
            }
            return mat

        case let e as BinaryExpr:
            let lt = e.lhs.type
            let rt = e.rhs.type
            switch (lt, rt) {
            case (.scalar, .scalar):
                return try rangeEval(ctx, nil, &ws, [e.lhs, e.rhs]) { v, _, enh in
                    // `try` rather than `try?`: an unported operator must surface, not become NaN.
                    let val = try scalarBinop(e.op, v[0].samples[0].f, v[1].samples[0].f)
                    var out = enh.out
                    out.append(Sample(f: val))
                    return (out, Annotations())
                }

            case (.vector, .vector):
                // The three set operators short-circuit to their own functions; everything else
                // goes through `VectorBinop`. All four pass the matching, which is what turns on
                // `rangeEval`'s signature machinery.
                guard let matching = e.vectorMatching else {
                    throw EvaluatorNotPorted(
                        nodeType: "BinaryExpr", detail: "vector/vector with no matching")
                }
                switch e.op {
                case .land:
                    return try rangeEval(ctx, matching, &ws, [e.lhs, e.rhs]) { v, sh, enh in
                        (try self.vectorAnd(v[0], v[1], matching, sh[0], sh[1], enh), Annotations())
                    }
                case .lor:
                    return try rangeEval(ctx, matching, &ws, [e.lhs, e.rhs]) { v, sh, enh in
                        (try self.vectorOr(v[0], v[1], matching, sh[0], sh[1], enh), Annotations())
                    }
                case .lunless:
                    return try rangeEval(ctx, matching, &ws, [e.lhs, e.rhs]) { v, sh, enh in
                        (
                            try self.vectorUnless(v[0], v[1], matching, sh[0], sh[1], enh),
                            Annotations()
                        )
                    }
                default:
                    return try rangeEval(ctx, matching, &ws, [e.lhs, e.rhs]) { v, sh, enh in
                        let (vec, err) = try self.vectorBinop(
                            e.op, v[0], v[1], matching, e.returnBool, sh[0], sh[1], enh,
                            e.positionRange)
                        return (vec, handleVectorBinopError(err, e))
                    }
                }

            case (.vector, .scalar):
                return try rangeEval(ctx, nil, &ws, [e.lhs, e.rhs]) { v, _, enh in
                    let (vec, err) = self.vectorScalarBinop(
                        e.op, v[0], Scalar(t: 0, v: v[1].samples[0].f), false, e.returnBool, enh,
                        e.positionRange)
                    return (vec, handleVectorBinopError(err, e))
                }

            case (.scalar, .vector):
                // Note the argument order: the VECTOR is still passed as `lhs`, with `swap` true.
                // That is what lets the metric always come from the vector.
                return try rangeEval(ctx, nil, &ws, [e.lhs, e.rhs]) { v, _, enh in
                    let (vec, err) = self.vectorScalarBinop(
                        e.op, v[1], Scalar(t: 0, v: v[0].samples[0].f), true, e.returnBool, enh,
                        e.positionRange)
                    return (vec, handleVectorBinopError(err, e))
                }

            default:
                // Go falls out of the switch and returns nil, which panics later. The parser
                // rejects every remaining combination, so this is unreachable.
                throw EvaluatorNotPorted(
                    nodeType: "BinaryExpr",
                    detail: "\(lt.documented) \(e.op.description) \(rt.documented)")
            }

        case let e as StepInvariantExpr:
            // A single evaluation, at the start timestamp, whose result is then repeated for
            // every step. With one step that repetition is the identity, which is why this
            // arm is portable before range queries are.
            let newEv = Evaluator(
                startTimestamp: startTimestamp, endTimestamp: startTimestamp,
                interval: interval, currentSamples: currentSamples, maxSamples: maxSamples,
                lookbackDelta: lookbackDelta,
                noStepSubqueryIntervalFn: noStepSubqueryIntervalFn,
                enableDelayedNameRemoval: enableDelayedNameRemoval,
                enableTypeAndUnitLabels: enableTypeAndUnitLabels,
                useStartTimestamps: useStartTimestamps)
            let res = try newEv.evalNode(ctx, e.expr, &ws)
            currentSamples = newEv.currentSamples
            if e.expr is MatrixSelector || e.expr is SubqueryExpr {
                // A range selector's timestamps are its own, so the result is not duplicated.
                return res
            }
            guard var mat = res as? Matrix else {
                // engine.go panics here with the *outer* expression's type, which is a
                // reachable-looking message for an unreachable state.
                throw EvaluatorNotPorted(
                    nodeType: "StepInvariantExpr",
                    detail: "unexpected result type \(res.type.documented)")
            }
            // The value does not change with the step, but its TIMESTAMP does, so the single
            // point is copied to every remaining step. Note the loop starts at
            // `startTimestamp + interval`: step 0's point is already there.
            for i in mat.series.indices {
                if mat.series[i].floats.count + mat.series[i].histograms.count != 1 {
                    // Go panics with "unexpected number of samples". A step-invariant
                    // subexpression is evaluated at exactly one timestamp, so this is a
                    // broken invariant rather than a user error.
                    throw EvaluatorNotPorted(
                        nodeType: "StepInvariantExpr", detail: "unexpected number of samples")
                }
                var t = startTimestamp + interval
                while t <= endTimestamp {
                    if !mat.series[i].floats.isEmpty {
                        mat.series[i].floats.append(
                            FPoint(t: t, f: mat.series[i].floats[0].f))
                        currentSamples += 1
                    } else {
                        let point = HPoint(t: t, h: mat.series[i].histograms[0].h)
                        mat.series[i].histograms.append(point)
                        currentSamples += point.size
                    }
                    if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    t += interval
                }
            }
            return mat

        case let e as VectorSelector:
            // `checkAndExpandSeriesSet` is where a storage error surfaces, wrapped so the
            // warnings collected before the failure still come back.
            let ws2: Annotations
            do {
                ws2 = try checkAndExpandSeriesSet(ctx, e)
            } catch {
                var carried = ws
                throw ErrWithWarnings(StorageExpansionError(underlying: error), carried.merge(ws))
            }
            _ = ws.merge(ws2)
            if e.smoothed {
                // A DIFFERENT function from `foo[5m] smoothed`: this interpolates the selector's
                // own samples onto the step grid, where the range form widens a window.
                let (mat, smoothAnnos) = try smoothSeries(e.series, e.offset, e.positionRange)
                _ = ws.merge(smoothAnnos)
                return mat
            }
            return try evalSeries(ctx, e.series, e.offset, false)

        case let e as AggregateExpr:
            // "Grouping labels must be sorted (expected both by generateGroupingKey() and
            // aggregation())" — and the sort is **IN PLACE on the AST node**, which is
            // observable: `Statement().String()` after `Exec` renders
            // `sum by (inst, job) (m)` for a query written `sum by (job, inst) (m)`.
            //
            // The port sorted a *copy* first, on the reasoning that nothing downstream reads the
            // unsorted order and mutating the node was gratuitous. Two of 677 fixture cases
            // disagreed. Same shape as `setOffsetForAtModifier`'s rewrite (quirk 76): the AST is
            // part of the observable surface once `Statement()` is exposed.
            e.grouping.sort()
            let sortedGrouping = e.grouping

            if e.op == .countValues {
                guard let valueLabel = e.param as? StringLiteral else {
                    throw EvaluatorNotPorted(
                        nodeType: "AggregateExpr", detail: "count_values parameter is not a string")
                }
                let name = String(decoding: valueLabel.val, as: UTF8.self)
                // Validated on the RAW BYTES, not on `name`: decoding substitutes U+FFFD, after
                // which every name is valid UTF-8 and `count_values("a\xc5z", …)` would be
                // accepted where Go rejects it. ADR-9, reached through the exit gate.
                if !ValidationScheme.utf8.isValidLabelName(valueLabel.val) {
                    // `%s` on the *expression*, so the message carries the quoted literal.
                    throw EvaluationError.invalidLabelName(valueLabel.description)
                }
                // The value label joins the grouping for `by (...)` and is left out for
                // `without (...)`, where "everything else" already includes it.
                var grouping = sortedGrouping
                if !e.without {
                    grouping.append(name)
                    grouping.sort()
                }
                guard let inner = e.expr else {
                    throw EvaluatorNotPorted(
                        nodeType: "AggregateExpr", detail: "no inner expression")
                }
                return try rangeEval(ctx, nil, &ws, [inner]) { v, _, enh in
                    self.aggregationCountValues(e, grouping, name, v[0], enh)
                }
            }

            var warnings = Annotations()
            let originalNumSamples = currentSamples
            // `e.Param` is `k` for topk/bottomk/limitk, `r` for limit_ratio, `q` for quantile —
            // and it may be a SERIES, so it is evaluated once, up front, before the input.
            let fp = try newFParams(ctx, e.param, &warnings)
            guard let inner = e.expr else {
                throw EvaluatorNotPorted(
                    nodeType: "AggregateExpr", detail: "no inner expression")
            }
            let val = try evalNode(ctx, inner, &warnings)
            guard let inputMatrix = val as? Matrix else {
                throw EvaluatorNotPorted(
                    nodeType: "AggregateExpr", detail: "input is not a matrix")
            }

            let (result, ws2) = try rangeEvalAgg(ctx, e, sortedGrouping, inputMatrix, fp)
            _ = warnings.merge(ws2)
            _ = ws.merge(warnings)
            currentSamples = originalNumSamples + result.totalSamples
            return result

        case let e as SubqueryExpr:
            // The subquery's own result, on its own step grid. `StepInvariantExpr` returns this
            // unduplicated, like a matrix selector, because the timestamps are the subquery's.
            return try runSubquery(ctx, e, &ws)

        case let e as MatrixSelector:
            // A range selector carries its own timestamps, so it is only ever evaluated once —
            // `StepInvariantExpr` returns its result unduplicated for exactly that reason, and
            // `rangeEval` never drives one.
            if startTimestamp != endTimestamp {
                throw EvaluationError.rangeEvaluationOfMatrixSelector
            }
            let (mat, ws2) = try matrixSelector(ctx, e)
            _ = ws.merge(ws2)
            return mat

        case let e as Call:
            if e.function?.name == "timestamp", let vs = e.args.first as? VectorSelector {
                guard let call = functionCalls["timestamp"] else {
                    throw EvaluatorNotPorted(nodeType: "Call", detail: "no timestamp entry")
                }
                return try rangeEvalTimestampFunctionOverVectorSelector(ctx, vs, call, e, &ws)
            }
            // Go scans the arguments for the first MatrixSelector **or** SubqueryExpr and
            // `break`s, so a second range argument is never looked at and the first one wins
            // whichever kind it is. No function in the table takes two, but the search order is
            // the contract, so it is reproduced rather than replaced by "the first matrix".
            let matrixArgIndex = e.args.firstIndex {
                $0 is MatrixSelector || $0 is SubqueryExpr
            }
            // A subquery argument is REPLACED IN THE AST by the equivalent range selector, so
            // the rest of the arm treats it as an ordinary one. The mutation is visible through
            // `Statement()` after `Exec`: the argument renders as a nameless range selector.
            var subqueryCleanup: (() -> Void)? = nil
            if let i = matrixArgIndex, let subq = e.args[i] as? SubqueryExpr {
                let (ms, totalSamples) = try evalSubquery(ctx, subq, &ws)
                e.args[i] = ms
                // Go's `defer`: the subquery's samples stay in memory until the call returns.
                subqueryCleanup = {
                    (ms.vectorSelector as? VectorSelector)?.series = []
                    self.currentSamples -= totalSamples
                }
            }
            defer { subqueryCleanup?() }
            switch (e.function?.name ?? "") {
            case "label_join":
                // Works on SERIES, so the evaluator reaches it directly rather than through
                // `functionCalls` (quirk 62).
                return try evalLabelJoin(self, ctx, e.args, &ws)
            case "label_replace":
                // Blocked on `PromRegex`: `FindStringSubmatchIndex` + `ExpandString` need capture
                // tracking, and the Pike VM is deliberately boolean-only
                // (`RegexCompiler.swift`'s header says so). That is a PromRegex slice, not an
                // evaluator one.
                throw EvaluatorNotPorted(
                    nodeType: "Call",
                    detail: "label_replace needs Pike VM capture tracking in PromRegex")
            case "info":
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "info works on series")
            default:
                break
            }
            guard let call = functionCalls[e.function?.name ?? ""] else {
                // Go panics: the seven nil entries are handled before this point.
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "no implementation for \((e.function?.name ?? ""))")
            }
            // The four sorts are meaningless over a range query — every step is sorted
            // independently and the result matrix is sorted by label set at the end — so
            // upstream warns rather than refusing. Note the warning is produced ONCE, before
            // the step loop, but merged into the result of EVERY step: `warnings.Merge(annos)`
            // returns the accumulator, so the closure hands back the running total.
            var warnings = Annotations()
            switch e.function?.name ?? "" {
            case "sort", "sort_desc", "sort_by_label", "sort_by_label_desc":
                if startTimestamp != endTimestamp {
                    _ = warnings.add(newSortInRangeQueryWarning(e.positionRange))
                }
            default:
                break
            }
            // The first matrix argument decides which half of the arm runs. Go breaks out of
            // the search on the first hit, so a second range argument is never looked at.
            if let matrixArgIndex {
                let mat = try evalCallWithMatrixArg(
                    ctx, e, call, matrixArgIndex, &warnings)
                _ = ws.merge(warnings)
                return mat
            }
            return try rangeEval(ctx, nil, &ws, e.args) { v, _, enh in
                let (vec, annos) = try call(v, Matrix(), e.args, enh)
                return (vec, warnings.merge(annos))
            }

        default:
            throw EvaluatorNotPorted(nodeType: expr.nodeTypeName, detail: "")
        }
    }

    /// Go: `rangeEval` — evaluate the arguments, then call `funcCall` once per step.
    ///
    /// `matching` is always nil here: the vector-matching path arrives with the vector
    /// binops. The instant shortcut is reproduced exactly, including its ordering guarantee.
    func rangeEval(
        _ ctx: GoContext, _ matching: VectorMatching?, _ warnings: inout Annotations,
        _ exprs: [any Expr],
        _ funcCall: ([Vector], [[EvalSeriesHelper]], EvalNodeHelper) throws -> (
            Vector, Annotations
        )
    ) throws -> Matrix {
        let originalNumSamples = currentSamples

        var matrixes = [Matrix?](repeating: nil, count: exprs.count)
        for (i, e) in exprs.enumerated() {
            // A string argument is read from the expression, not evaluated.
            if e.type != .string {
                let val = try evalNode(ctx, e, &warnings)
                guard let m = val as? Matrix else {
                    throw EvaluatorNotPorted(
                        nodeType: "rangeEval", detail: "argument is not a matrix")
                }
                matrixes[i] = m
            }
        }

        var biggestLen = 1
        for m in matrixes {
            if let m, m.series.count > biggestLen {
                biggestLen = m.series.count
            }
        }
        let enh = EvalNodeHelper()
        enh.enableDelayedNameRemoval = enableDelayedNameRemoval
        var tempNumSamples = currentSamples

        // The join signatures, computed ONCE across both sides before the step loop and turned
        // into small integers so the per-step lookups are array indexing. `useSignatures` is
        // just `matching != nil`, which the caller decides — the set operators and the
        // vector/vector arms pass one, the scalar arms pass nil.
        //
        // `sigf`'s two branches are not mirror images: `on` keeps the named labels, while
        // `ignoring` drops them **plus `__name__`**, which it arranges by prepending
        // `labels.MetricName` to the list before sorting. `bytesWithoutLabels` does not drop the
        // name of its own accord, so that prepend is load-bearing.
        var seriesHelpers: [[EvalSeriesHelper]] = []
        var bufHelpers: [[EvalSeriesHelper]] = []
        let useSignatures = matching != nil
        if let matching {
            var names = matching.matchingLabels
            let sigf: (Labels) -> [UInt8]
            if matching.on {
                names.sort()
                sigf = { $0.bytesWithLabels(names) }
            } else {
                names = [LabelName.metricName] + names
                names.sort()
                sigf = { $0.bytesWithoutLabels(names) }
            }

            seriesHelpers = matrixes.map {
                [EvalSeriesHelper](repeating: EvalSeriesHelper(), count: $0?.series.count ?? 0)
            }
            bufHelpers = seriesHelpers.map { _ in [] }

            var signatureToOrdinal: [[UInt8]: Int] = [:]
            for i in matrixes.indices {
                for (si, series) in (matrixes[i]?.series ?? []).enumerated() {
                    let strSig = sigf(series.metric)
                    if let ord = signatureToOrdinal[strSig] {
                        seriesHelpers[i][si] = EvalSeriesHelper(sigOrdinal: ord)
                        continue
                    }
                    signatureToOrdinal[strSig] = enh.numSigs
                    seriesHelpers[i][si] = EvalSeriesHelper(sigOrdinal: enh.numSigs)
                    enh.numSigs += 1
                }
            }
        }

        // Go: `seriess map[uint64]seriesAndTimestamp` — the output series, keyed by label
        // hash, with the last timestamp each was written at so a duplicate *within one step*
        // can be told from the same series across steps.
        //
        // Go ranges the map to assemble the result, so upstream's matrix order here is
        // randomised. `order` keeps insertion order instead: one of the orders Go can
        // produce, and the only deterministic choice (PORTING.md exception 7). The top-level
        // range path sorts the result, so this is not observable through a query — but an
        // *inner* expression's order becomes the next layer's input order, which is why it
        // is a recorded decision rather than an implementation detail.
        var seriess: [UInt64: (series: Series, ts: Int64)] = [:]
        var order: [UInt64] = []
        seriess.reserveCapacity(biggestLen)

        var ts = startTimestamp
        while ts <= endTimestamp {
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            // The count is reset at the top of every step: samples from earlier steps are no
            // longer in memory, apart from the results kept in `tempNumSamples`.
            currentSamples = tempNumSamples

            var vectors = [Vector]()
            vectors.reserveCapacity(exprs.count)
            for i in matrixes.indices {
                var bh: [EvalSeriesHelper] = []
                let sh = useSignatures ? seriesHelpers[i] : []
                vectors.append(try gatherVector(ts, &matrixes[i], &bh, sh))
                if useSignatures {
                    bufHelpers[i] = bh
                }
            }

            enh.ts = ts
            let (result, ws) = try funcCall(vectors, bufHelpers, enh)
            enh.out = Vector()
            _ = warnings.merge(ws)

            let vecNumSamples = result.totalSamples
            currentSamples += vecNumSamples
            tempNumSamples += vecNumSamples

            // Checked AFTER the call: an over-limit step is computed in full first.
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }

            if endTimestamp == startTimestamp {
                // The instant shortcut. The matrix is built in the RESULT VECTOR's order,
                // which is what `sort` depends on — the map-based assembly below would lose
                // it (engine.go:1537).
                if !enableDelayedNameRemoval && result.containsSameLabelset {
                    throw EvaluationError.duplicateLabelset
                }
                var mat = Matrix()
                mat.series.reserveCapacity(result.samples.count)
                for s in result.samples {
                    if s.h == nil {
                        mat.series.append(
                            Series(
                                metric: s.metric, floats: [FPoint(t: ts, f: s.f)],
                                dropName: s.dropName))
                    } else {
                        mat.series.append(
                            Series(
                                metric: s.metric, histograms: [HPoint(t: ts, h: s.h!)],
                                dropName: s.dropName))
                    }
                }
                currentSamples = originalNumSamples + mat.totalSamples
                return mat
            }

            // The multi-step path: fold this step's samples into the per-series accumulators.
            for sample in result.samples {
                let h = sample.metric.goHash()
                if var existing = seriess[h] {
                    // Seen at this same timestamp already: two output series with one label
                    // set, which is a genuine ambiguity rather than a mergeable pair.
                    if existing.ts == ts {
                        throw EvaluationError.duplicateLabelset
                    }
                    existing.ts = ts
                    addToSeries(&existing.series, enh.ts, sample.f, sample.h)
                    seriess[h] = existing
                } else {
                    var fresh = (
                        series: Series(metric: sample.metric, dropName: sample.dropName), ts: ts
                    )
                    addToSeries(&fresh.series, enh.ts, sample.f, sample.h)
                    seriess[h] = fresh
                    order.append(h)
                }
            }

            ts += interval
        }

        // Assemble the output matrix. By the time we get here the sample limit has already
        // been enforced per step, so no further check is needed — Go says as much.
        var mat = Matrix()
        mat.series.reserveCapacity(order.count)
        for h in order {
            mat.series.append(seriess[h]!.series)
        }
        currentSamples = originalNumSamples + mat.totalSamples
        return mat
    }

    /// Go: `gatherVector` — the samples at `ts` from each input series.
    ///
    /// Two things here are easy to miss and both are load-bearing:
    ///
    ///   * it **counts** every sample it gathers against `maxSamples`, and raises the error
    ///     itself. So the limit is enforced twice per step — once here on the inputs and
    ///     once in `rangeEval` on the result — and a query's peak is therefore higher than
    ///     the result alone suggests. `1 + 2` needs a limit of 5, not 3, and the corpus pins
    ///     exactly that boundary.
    ///   * it **consumes** the point it took (`input[i].Floats = series.Floats[1:]`), so the
    ///     next step does not rescan it. Go reslices; Swift removes from the front, which is
    ///     O(n) rather than O(1) but observably identical.
    ///
    /// The histogram size is deliberately NOT added: Go's comment says it only copies the
    /// pointer. Swift's value semantics make that a real copy, but the *accounting* stays
    /// Go's — the count is the contract, not the allocation.
    private func gatherVector(
        _ ts: Int64, _ input: inout Matrix?, _ bufHelpers: inout [EvalSeriesHelper],
        _ seriesHelpers: [EvalSeriesHelper]
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
            // The helper travels WITH the sample, so `bufHelpers` is parallel to the gathered
            // vector rather than to the input matrix — a series with no sample at this step
            // contributes neither.
            if !seriesHelpers.isEmpty {
                bufHelpers.append(seriesHelpers[i])
            }
            currentSamples += 1
            if currentSamples > maxSamples {
                throw QueryError.tooManySamples(evaluationEnv)
            }
        }
        return out
    }
}

/// Go: `addToSeries` — append one output point to a series, float or histogram.
///
/// Go's `numSteps` argument only sizes the pooled slice, so it is dropped (PORTING.md
/// exception 4). Which of the two slices grows is decided by `h == nil`, and nothing keeps
/// them in step: a series whose function returns a float at one timestamp and a histogram at
/// the next ends up with points in both, which is exactly what upstream produces.
func addToSeries(_ ss: inout Series, _ ts: Int64, _ f: Double, _ h: FloatHistogram?) {
    guard let h else {
        ss.floats.append(FPoint(t: ts, f: f))
        return
    }
    ss.histograms.append(HPoint(t: ts, h: h))
}

/// Go: `scalarBinop` — the arithmetic and comparison operators over two scalars.
///
/// The comparisons return `btos(...)`, i.e. 1 or 0 — a scalar comparison is arithmetic, not a
/// filter, which is why `1 > 2` is `0` and not "no data". `bool` is irrelevant here: the
/// parser rejects it on a scalar/scalar comparison.
///
/// `ATAN2` goes through `GoMath.atan2`, Go's own algorithm — nine ordered special cases and then
/// `Atan(y/x)` with a quadrant shift, which inherits `atan`'s divergence from libm (quirks
/// 39-40). Not Foundation's.
func scalarBinop(_ op: ItemType, _ lhs: Double, _ rhs: Double) throws -> Double {
    switch op {
    case .add: return lhs + rhs
    case .sub: return lhs - rhs
    case .mul: return lhs * rhs
    case .div: return lhs / rhs
    case .pow: return GoMath.pow(lhs, rhs)
    case .mod: return GoMath.mod(lhs, rhs)
    case .eqlc: return lhs == rhs ? 1 : 0
    case .neq: return lhs != rhs ? 1 : 0
    case .gtr: return lhs > rhs ? 1 : 0
    case .lss: return lhs < rhs ? 1 : 0
    case .gte: return lhs >= rhs ? 1 : 0
    case .lte: return lhs <= rhs ? 1 : 0
    case .atan2: return GoMath.atan2(lhs, rhs)
    default:
        // Go panics with `operator %q not allowed for Scalar operations`; the parser makes
        // this unreachable.
        throw EvaluatorNotPorted(
            nodeType: "scalarBinop", detail: "operator \(op.description) is not a scalar op")
    }
}

/// Go: `fmt.Errorf("expanding series: %w", err)` — the prefix a storage failure reaches the
/// user with.
public struct StorageExpansionError: Error, CustomStringConvertible {
    public var underlying: any Error
    public var description: String { "expanding series: \(String(describing: underlying))" }
}

/// Go: `ev.errorf("vector cannot contain metrics with the same labelset")` and friends —
/// the evaluator's own messages, which reach the user verbatim.
public enum EvaluationError: Error, CustomStringConvertible, Equatable, Sendable {
    case duplicateLabelset
    /// Go: `evalSeries`' `this should be an info metric, with float samples: %s`.
    case infoMetricWithHistogram(String)
    /// Go: `vectorSelectorSingle`'s `unknown value type %v` panic.
    case unknownValueType(String)
    /// Go: `funcDoubleExponentialSmoothing`'s two `panic(fmt.Errorf(...))`s. `%f`, so six
    /// decimal places, and `GoFloat` rather than interpolation because the text is byte-exact.
    case invalidSmoothingFactor(Double)
    case invalidTrendFactor(Double)
    /// Go: `matrixSelector`'s two `errorf`s for a range modifier over histogram data.
    case anchoredWithHistograms
    case smoothedWithHistograms
    /// Go: the `MatrixSelector` arm's `panic(errors.New(...))`, which asserts that a range
    /// selector is only ever evaluated at one timestamp. `rangeEval` never drives one, and the
    /// `Call` arm reads the matrix itself, so this is an internal invariant rather than a user
    /// error — but it is modelled as a thrown error because Swift cannot recover a trap.
    case rangeEvaluationOfMatrixSelector
    /// Go: the three panics of the vector-matching machinery. All are `panic(...)` or
    /// `ev.errorf`, so `recover` turns them into ordinary query errors.
    ///
    /// The first two are Go `panic("...")` with a bare string, which `recover`'s default arm
    /// formats with `%v` — so the message is the string itself.
    case setOperatorCardinality
    case manyToManyOnlyForSetOperators
    /// Go: `found duplicate series for the match group %s on the %s hand-side of the
    /// operation: [%s, %s];many-to-many matching not allowed: matching labels must be unique on
    /// one side`. Note the **missing space** after the semicolon — upstream concatenates two
    /// literals and the second starts with `;`.
    case duplicateSeriesForMatchGroup(
        matchedLabels: String, oneSide: String, a: String, b: String)
    case multipleMatchesNeedExplicitGrouping
    case groupingLabelsMustEnsureUniqueMatches
    /// Go: the `Call` arm's `anchored/smoothed modifier can only be used with: %s - not with %s`.
    /// The permitted names are `slices.Sorted(maps.Keys(...))` over a Go map, so the sort is
    /// upstream's own defence against a nondeterministic message.
    case modifierNotSafeForFunction(modifier: String, permitted: [String], function: String)
    /// Go: `rangeEvalAgg`'s three parameter rejections. `%v` on a `float64` is Go's `'g'`
    /// shortest form, not `%f`.
    case parameterValueIsNaN
    case ratioValueIsNaN
    case scalarUnderflowsInt64(Double)
    case scalarOverflowsInt64(Double)
    /// Go: `count_values`' `invalid label name %s`, where `%s` is the string LITERAL's rendering —
    /// so it arrives quoted and escaped, not bare.
    case invalidLabelName(String)
    /// Go: `evalLabelJoin`'s two panics. `%s` on a bare Go `string`, so unquoted.
    case invalidSourceLabelNameInLabelJoin(String)
    case invalidDestinationLabelNameInLabelJoin(String)

    public var description: String {
        switch self {
        case .duplicateLabelset:
            return "vector cannot contain metrics with the same labelset"
        case .infoMetricWithHistogram(let metric):
            return "this should be an info metric, with float samples: \(metric)"
        case .unknownValueType(let t):
            return "unknown value type \(t)"
        case .invalidSmoothingFactor(let sf):
            return
                "invalid smoothing factor. Expected: 0 < sf < 1, got: \(GoFloat.format(sf, .f, precision: 6))"
        case .invalidTrendFactor(let tf):
            return
                "invalid trend factor. Expected: 0 < tf < 1, got: \(GoFloat.format(tf, .f, precision: 6))"
        case .setOperatorCardinality:
            return "set operations must only use many-to-many matching"
        case .manyToManyOnlyForSetOperators:
            return "many-to-many only allowed for set operators"
        case .duplicateSeriesForMatchGroup(let matchedLabels, let oneSide, let a, let b):
            var s = "found duplicate series for the match group \(matchedLabels) on the "
            s += "\(oneSide) hand-side of the operation: [\(a), \(b)]"
            s += ";many-to-many matching not allowed: matching labels must be unique on one side"
            return s
        case .multipleMatchesNeedExplicitGrouping:
            return "multiple matches for labels: many-to-one matching must be explicit (group_left/group_right)"
        case .groupingLabelsMustEnsureUniqueMatches:
            return "multiple matches for labels: grouping labels must ensure unique matches"
        case .anchoredWithHistograms:
            return "anchored modifier is not supported with histograms"
        case .smoothedWithHistograms:
            return "smoothed modifier is not supported with histograms"
        case .rangeEvaluationOfMatrixSelector:
            return "cannot do range evaluation of matrix selector"
        case .parameterValueIsNaN:
            return "Parameter value is NaN"
        case .ratioValueIsNaN:
            return "Ratio value is NaN"
        case .scalarUnderflowsInt64(let v):
            return "Scalar value \(GoFloat.formatG(v)) underflows int64"
        case .scalarOverflowsInt64(let v):
            return "Scalar value \(GoFloat.formatG(v)) overflows int64"
        case .invalidLabelName(let s):
            return "invalid label name \(s)"
        case .invalidSourceLabelNameInLabelJoin(let s):
            return "invalid source label name in label_join(): \(s)"
        case .invalidDestinationLabelNameInLabelJoin(let s):
            return "invalid destination label name in label_join(): \(s)"
        case .modifierNotSafeForFunction(let modifier, let permitted, let function):
            var s = "\(modifier) modifier can only be used with: "
            s += permitted.joined(separator: ", ")
            s += " - not with \(function)"
            return s
        }
    }
}

// MARK: - The @ modifier's offset rewrite

/// Go: `setOffsetForAtModifier` — turn every `@` into an equivalent `Offset`, once, before
/// evaluation.
///
/// After this the evaluator never looks at `Timestamp` again: `Offset` carries both the
/// written offset and the distance from the evaluation time to the pinned one. Note the
/// subquery arm uses the *innermost* enclosing timestamp, so a nested `@` shadows an outer
/// one.
public func setOffsetForAtModifier(_ evalTime: Int64, _ expr: any Expr) {
    func getOffset(_ ts: Int64?, _ originalOffset: GoDuration, _ path: [any Node]) -> GoDuration {
        guard let ts else {
            return originalOffset
        }
        // The accumulated subquery offsets, plus the distance from the evaluation time to
        // the innermost subquery `@` when there is one — so a subquery timestamp shifts the
        // baseline the selector's own `@` is measured against.
        var (subqOffset, _, subqTs) = subqueryTimes(path)
        if let subqTs {
            subqOffset = GoDuration(
                nanoseconds: subqOffset.nanoseconds + (evalTime - subqTs) * 1_000_000)
        }
        let offsetForTs = GoDuration(nanoseconds: (evalTime - ts) * 1_000_000)
        let offsetDiff = offsetForTs.nanoseconds - subqOffset.nanoseconds
        return GoDuration(nanoseconds: originalOffset.nanoseconds + offsetDiff)
    }

    inspect(expr) { node, path in
        if let n = node as? VectorSelector {
            n.offset = getOffset(n.timestamp, n.originalOffset, path)
        } else if let n = node as? MatrixSelector {
            if let vs = n.vectorSelector as? VectorSelector {
                vs.offset = getOffset(vs.timestamp, vs.originalOffset, path)
            }
        } else if let n = node as? SubqueryExpr {
            n.offset = getOffset(n.timestamp, n.originalOffset, path)
        }
    }
}

// MARK: - Exec

extension Query {
    /// Go: `query.Exec` — run the query and wrap whatever comes back in a `Result`.
    ///
    /// `Result` carries the error rather than throwing it, which is Go's shape and the one
    /// the HTTP API depends on: a failed query still reports its warnings.
    public func exec(_ ctx: GoContext) -> Result {
        do {
            let (value, warnings) = try engine.exec(ctx, self)
            return Result(error: nil, value: value, warnings: warnings)
        } catch let e as ErrWithWarnings {
            return Result(error: e.err, value: nil, warnings: e.warnings)
        } catch {
            return Result(error: error, value: nil, warnings: Annotations())
        }
    }
}

extension Engine {
    /// Go: `Engine.exec` — the timeout, the query log, the active-query queue, and then the
    /// statement switch. Only the last of those is here; see Engine.swift's header for what
    /// is deliberately absent.
    func exec(_ ctx: GoContext, _ q: Query) throws -> (any Value, Annotations) {
        // Go wraps the context in `context.WithTimeout(ctx, ng.timeout)` first, so a query
        // that outlives the engine's timeout fails with ErrQueryTimeout rather than running
        // forever. `GoContext` carries a deadline, so the wrap is a derived context.
        let deadlined =
            timeout.nanoseconds > 0 ? GoContext.withTimeout(ctx, timeout).context : ctx
        // The base context may already be done — during shutdown, say.
        if let err = contextDone(deadlined, evaluationEnv) {
            throw err
        }
        guard let s = q.statement as? EvalStmt else {
            throw EvaluatorNotPorted(
                nodeType: "Statement", detail: "only EvalStmt is ported; TestStmt is promqltest's")
        }
        return try execEvalStmt(deadlined, q, s)
    }

    /// Go: `execEvalStmt`, instant path only.
    ///
    /// The querier is opened over `FindMinMaxTime`'s window even when nothing will read it,
    /// because opening it is what can fail — and that error is returned before any
    /// evaluation happens.
    func execEvalStmt(_ ctx: GoContext, _ q: Query, _ s: EvalStmt) throws -> (any Value, Annotations)
    {
        let (mint, maxt) = findMinMaxTime(s)
        let querier = try q.queryable.querier(mint: mint, maxt: maxt)
        // Go's `defer querier.Close()` discards the error; `try?` is the same discard, and
        // the comment is here because dropping an error deliberately should be visible.
        defer { try? querier.close() }

        // Attach a SeriesSet to every selector, with the hints the storage may use to plan.
        populateSeries(ctx, querier, s)

        // The `@` rewrite happens ONCE, on the start time, before evaluation.
        setOffsetForAtModifier(Timestamp.fromTime(s.start), s.expr)

        guard Timestamp.fromTime(s.start) == Timestamp.fromTime(s.end) && s.interval.nanoseconds == 0
        else {
            return try execRangeEvalStmt(ctx, s)
        }

        let start = Timestamp.fromTime(s.start)
        let ev = Evaluator(
            startTimestamp: start, endTimestamp: start,
            // 1, not 0: `rangeEval` divides by it.
            interval: 1,
            maxSamples: maxSamplesPerQuery, lookbackDelta: s.lookbackDelta,
            noStepSubqueryIntervalFn: noStepSubqueryIntervalFn,
            enableDelayedNameRemoval: enableDelayedNameRemoval,
            enableTypeAndUnitLabels: enableTypeAndUnitLabels,
            useStartTimestamps: useStartTimestamps)

        let (val, warnings) = try ev.eval(ctx, s.expr)

        // A String result is returned as-is; everything else must be a Matrix by now.
        if let str = val as? StringValue {
            return (str, warnings)
        }
        guard let mat = val as? Matrix else {
            throw EvaluatorNotPorted(
                nodeType: "EvalStmt", detail: "invalid expression type \(val.type.documented)")
        }

        switch s.expr.type {
        case .vector:
            // One value per series becomes a vector, and every point is forced to the
            // evaluation timestamp — the point's own may differ, and Go overwrites it.
            var vector = Vector()
            vector.samples.reserveCapacity(mat.series.count)
            for series in mat.series {
                if let h = series.histograms.first {
                    vector.samples.append(
                        Sample(t: start, h: h.h, metric: series.metric, dropName: series.dropName))
                } else {
                    vector.samples.append(
                        Sample(
                            t: start, f: series.floats[0].f, metric: series.metric,
                            dropName: series.dropName))
                }
            }
            return (vector, warnings)
        case .scalar:
            return (Scalar(t: start, v: mat.series[0].floats[0].f), warnings)
        case .matrix:
            var sorted = mat
            sorted.sort()
            return (sorted, warnings)
        default:
            throw EvaluatorNotPorted(
                nodeType: "EvalStmt", detail: "unexpected expression type \(s.expr.type.documented)")
        }
    }

    /// Go: `execEvalStmt`'s second half — the range evaluation.
    ///
    /// Split out because Go's is one function with an early `return` for the instant case;
    /// keeping them separate in Swift avoids a 150-line body. The querier, `populateSeries`
    /// and `setOffsetForAtModifier` all ran in the caller, in that order, which is upstream's.
    ///
    /// Three things differ from the instant path and all three are observable:
    ///
    ///   * the result is **always a `Matrix`**, whatever the expression's type. A range query
    ///     over `1` returns a one-series matrix with a point per step, not a `Scalar` — so
    ///     the three type tails of the instant path have no counterpart here.
    ///   * `interval` is the query's own step rather than 1, so it is what `rangeEval` and
    ///     `StepInvariantExpr` advance by.
    ///   * `contextDone` is checked once **after** evaluation and before the sort, so a
    ///     cancellation that arrives during the final assembly is still reported.
    func execRangeEvalStmt(_ ctx: GoContext, _ s: EvalStmt) throws -> (any Value, Annotations) {
        let ev = Evaluator(
            startTimestamp: Timestamp.fromTime(s.start),
            endTimestamp: Timestamp.fromTime(s.end),
            interval: durationMilliseconds(s.interval),
            maxSamples: maxSamplesPerQuery, lookbackDelta: s.lookbackDelta,
            noStepSubqueryIntervalFn: noStepSubqueryIntervalFn,
            enableDelayedNameRemoval: enableDelayedNameRemoval,
            enableTypeAndUnitLabels: enableTypeAndUnitLabels,
            useStartTimestamps: useStartTimestamps)

        let (val, warnings) = try ev.eval(ctx, s.expr)

        guard var mat = val as? Matrix else {
            // Go panics. `NewRangeQuery` rejects anything but scalar and instant vector, and
            // both of those evaluate to a Matrix, so this is unreachable through the front
            // door — but `Exec` can be handed a statement built by hand.
            throw EvaluatorNotPorted(
                nodeType: "EvalStmt", detail: "invalid expression type \(val.type.documented)")
        }

        if let err = contextDone(ctx, "expression evaluation") {
            throw ErrWithWarnings(err, warnings)
        }

        mat.sort()
        return (mat, warnings)
    }
}

// MARK: - Selectors

extension Engine {
    /// Go: `populateSeries` — attach an unexpanded `SeriesSet` to every selector, with the
    /// hints the storage may use to plan.
    ///
    /// The hints are advisory: `Select` is allowed to ignore every one of them and return a
    /// superset. What is *not* advisory is `Start`/`End`, which come from
    /// `getTimeRangesForSelector` — the same arithmetic `FindMinMaxTime` unions.
    func populateSeries(_ ctx: GoContext, _ querier: any Querier, _ s: EvalStmt) {
        // As in `findMinMaxTime`: set by a MatrixSelector, consumed and cleared by the
        // VectorSelector inside it.
        var evalRange = GoDuration(nanoseconds: 0)

        inspect(s.expr) { node, path in
            if let n = node as? VectorSelector {
                let (start, end) = getTimeRangesForSelector(s, n, path, evalRange)
                var interval = getLastSubqueryInterval(path)
                if interval.nanoseconds == 0 {
                    interval = s.interval
                }
                var hints = SelectHints(start: start, end: end)
                hints.step = durationMilliseconds(interval)
                hints.range = durationMilliseconds(evalRange)
                hints.func_ = extractFuncFromPath(path)
                evalRange = GoDuration(nanoseconds: 0)
                let (by, grouping) = extractGroupsFromPath(path)
                hints.by = by
                hints.grouping = grouping
                n.unexpandedSeriesSet = querier.select(
                    ctx, sortSeries: false, hints: hints,
                    matchers: n.labelMatchers.compactMap { $0 })
            } else if let n = node as? MatrixSelector {
                evalRange = n.range
            }
        }
    }

    /// Go: `getLastSubqueryInterval` — the innermost enclosing subquery's step, or zero.
    ///
    /// A subquery with no step written gets `noStepSubqueryIntervalFn(range)`, which is where
    /// the engine's default subquery interval finally lands.
    func getLastSubqueryInterval(_ path: [any Node]) -> GoDuration {
        var interval = GoDuration(nanoseconds: 0)
        for node in path {
            guard let n = node as? SubqueryExpr else { continue }
            if n.step.nanoseconds != 0 {
                interval = n.step
            } else {
                let ms = noStepSubqueryIntervalFn?(durationMilliseconds(n.range)) ?? 0
                interval = GoDuration(nanoseconds: ms * 1_000_000)
            }
        }
        return interval
    }
}

/// Go: `extractFuncFromPath` — the innermost enclosing function or aggregation's name, or ""
/// once a binary operator is reached.
///
/// The `BinaryExpr` case terminates deliberately: the hint is meant to describe a function
/// over a *single* metric, and past an operator it no longer does.
func extractFuncFromPath(_ p: [any Node]) -> String {
    if p.isEmpty {
        return ""
    }
    switch p[p.count - 1] {
    case let n as AggregateExpr:
        return n.op.description
    case let n as Call:
        return n.function?.name ?? ""
    case is BinaryExpr:
        return ""
    default:
        return extractFuncFromPath(Array(p.dropLast()))
    }
}

/// Go: `extractGroupsFromPath` — the immediately enclosing aggregation's grouping, if any.
///
/// Note it looks only at the LAST element, not up the whole path, and reports `!Without` so
/// `by` is true and `without` is false.
func extractGroupsFromPath(_ p: [any Node]) -> (Bool, [String]) {
    if p.isEmpty {
        return (false, [])
    }
    if let n = p[p.count - 1] as? AggregateExpr {
        return (!n.without, n.grouping)
    }
    return (false, [])
}

/// Go: `checkAndExpandSeriesSet` — drain the selector's `SeriesSet` into its `Series`, once.
///
/// Idempotent by design: a non-nil `Series` is a no-op, which is what makes it safe to call
/// from every arm that touches a selector.
func checkAndExpandSeriesSet(_ ctx: GoContext, _ expr: any Expr) throws -> Annotations {
    if let e = expr as? MatrixSelector {
        return try checkAndExpandSeriesSet(ctx, e.vectorSelector)
    }
    guard let e = expr as? VectorSelector else {
        return Annotations()
    }
    if !e.series.isEmpty {
        return Annotations()
    }
    guard let set = e.unexpandedSeriesSet else {
        return Annotations()
    }
    var (series, ws) = try expandSeriesSet(ctx, set)
    if e.skipHistogramBuckets {
        series = series.map { HistogramStatsSeries($0) }
    }
    e.series = series
    return ws
}

/// Go: `expandSeriesSet` — every series in the set, plus its warnings.
///
/// The context is checked *inside* the loop, so a cancellation during expansion is reported
/// rather than waited out.
// `PromStorage.Series` is qualified throughout: `PromQL.Series` is the value type and
// shadows it.
func expandSeriesSet(_ ctx: GoContext, _ it: any SeriesSet) throws -> ([any PromStorage.Series], Annotations) {
    var res: [any PromStorage.Series] = []
    while it.next() {
        if let err = ctx.err() {
            throw err
        }
            // `at()` is optional in the port where Go's is not; a `next()` that returned
            // true and then nil would be a broken SeriesSet, so this is a precondition
            // rather than a skip.
        guard let s = it.at() else {
            preconditionFailure("SeriesSet.next() returned true but at() was nil")
        }
        res.append(s)
    }
    if let err = it.err() {
        throw err
    }
    return (res, it.warnings())
}

extension Evaluator {
    /// Go: `evalSeries` — one series per input, sampled at every step through the lookback
    /// window.
    ///
    /// A series that yields no point at any step is **dropped entirely** rather than kept
    /// empty, which is why an instant query over a stale series returns nothing rather than a
    /// series with no samples.
    ///
    /// `recordOrigT` replaces the value with the sample's own timestamp — that is for `info`
    /// metrics, whose values are 1 by convention, so the space is reused. It raises for a
    /// histogram, since an info metric must be a float.
    func evalSeries(
        _ ctx: GoContext, _ series: [any PromStorage.Series], _ offset: GoDuration,
        _ recordOrigT: Bool
    ) throws -> Matrix {
        var mat = Matrix()
        mat.series.reserveCapacity(series.count)

        for s in series {
            if let err = contextDone(ctx, "expression evaluation") {
                throw err
            }
            let memo = MemoizedSeriesIterator(s.iterator(nil), delta: durationMilliseconds(lookbackDelta))
            var ss = Series(metric: s.labels())

            var ts = startTimestamp
            while ts <= endTimestamp {
                guard let (origT, f, h) = try vectorSelectorSingle(memo, offset, ts) else {
                    ts += interval
                    continue
                }
                if h == nil {
                    currentSamples += 1
                    if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    ss.floats.append(FPoint(t: ts, f: recordOrigT ? Double(origT) : f))
                } else {
                    if recordOrigT {
                        throw EvaluationError.infoMetricWithHistogram(ss.metric.description)
                    }
                    let point = HPoint(t: ts, h: h!)
                    // A histogram costs its own size, not 1 — the sample limit is in
                    // float-equivalents.
                    currentSamples += point.size
                    if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    ss.histograms.append(point)
                }
                ts += interval
            }

            if !ss.floats.isEmpty || !ss.histograms.isEmpty {
                mat.series.append(ss)
            }
        }
        return mat
    }

    /// Go: `cleanupMetricLabels` — apply every deferred `DropName` and then re-check for
    /// collisions.
    ///
    /// Only reached when `enableDelayedNameRemoval` is on, which is what `promqltest` runs with
    /// (test.go:111) and therefore what the exit gate exercises. The server defaults it off, so
    /// each function body strips the labels itself instead.
    ///
    /// The two arms are **not** symmetric, and the asymmetry is the interesting part:
    ///
    ///   * a `Matrix` goes through `mergeSeriesWithSameLabelset`, which *combines* colliding series
    ///     and errors only on two points at one timestamp;
    ///   * a `Vector` is checked with `ContainsSameLabelset` and **errors outright**.
    ///
    /// So dropping the name can merge a matrix and reject a vector, for the same collision. A
    /// vector has one point per series by construction, so there is nothing to merge — the merge
    /// would immediately hit its own duplicate-timestamp error anyway.
    func cleanupMetricLabels(_ v: any Value) throws -> any Value {
        if var mat = v as? Matrix {
            for i in mat.series.indices where mat.series[i].dropName {
                mat.series[i].metric = mat.series[i].metric.dropReserved(isMetadataLabel)
            }
            return try mergeSeriesWithSameLabelset(mat)
        }
        if var vec = v as? Vector {
            for i in vec.samples.indices where vec.samples[i].dropName {
                vec.samples[i].metric = vec.samples[i].metric.dropReserved(isMetadataLabel)
            }
            if vec.containsSameLabelset {
                throw EvaluationError.duplicateLabelset
            }
            return vec
        }
        // A String, which has no labels.
        return v
    }

    /// Go: `mergeSeriesWithSameLabelset` — combine series whose label sets became equal.
    ///
    /// Reachable because dropping `__name__` can make two series collide: `-foo` and `-bar`
    /// both render as `{}`. Two fast paths first — one series, or no duplicates at all, both
    /// returning the input untouched — and only then the grouping.
    ///
    /// Colliding series are merged by concatenating their points and sorting by timestamp; two
    /// points at the SAME timestamp are the error, because that is a genuine ambiguity rather
    /// than a mergeable pair.
    ///
    /// The grouping is a Go **map**, so the order of the output matrix is randomised per run
    /// once there is more than one group (PORTING.md exception 7).
    ///
    /// **Unreachable from the currently ported arms, and the corpus says so rather than
    /// implying otherwise.** A selector cannot produce two series with the same label set —
    /// that is one series to the storage — and two series differing in any label still differ
    /// after `__name__` is dropped. Reaching this needs a function that drops a *differing*
    /// label: `label_replace`, or an aggregation. Transcribed now because `UnaryExpr` calls it
    /// and a stub there would be a silent wrong answer; pinned when those land.
    func mergeSeriesWithSameLabelset(_ mat: Matrix) throws -> Matrix {
        if mat.series.count <= 1 {
            return mat
        }
        // The fast path Go takes pains over: no duplicates means no allocation.
        if !mat.containsSameLabelset {
            return mat
        }

        var seriesByHash: [UInt64: [Int]] = [:]
        var order: [UInt64] = []
        for i in mat.series.indices {
            let hash = mat.series[i].metric.goHash()
            if seriesByHash[hash] == nil {
                order.append(hash)
            }
            seriesByHash[hash, default: []].append(i)
        }

        var merged = Matrix()
        // Go ranges the map, so its order is arbitrary; insertion order here is one of the
        // orders Go can produce and the only deterministic choice available.
        for hash in order {
            let indices = seriesByHash[hash]!
            if indices.count == 1 {
                merged.series.append(mat.series[indices[0]])
                continue
            }
            var base = mat.series[indices[0]]
            for idx in indices.dropFirst() {
                base.floats.append(contentsOf: mat.series[idx].floats)
                base.histograms.append(contentsOf: mat.series[idx].histograms)
            }
            // `sort.Slice` is pdqsort over a `<` on timestamps. Ties are the error below, so
            // the instability cannot show.
            GoSort.sort(
                count: base.floats.count,
                less: { base.floats[$0].t < base.floats[$1].t },
                swap: { base.floats.swapAt($0, $1) })
            GoSort.sort(
                count: base.histograms.count,
                less: { base.histograms[$0].t < base.histograms[$1].t },
                swap: { base.histograms.swapAt($0, $1) })

            for i in 1..<Swift.max(base.floats.count, 1) where base.floats[i].t == base.floats[i - 1].t {
                throw EvaluationError.duplicateLabelset
            }
            for i in 1..<Swift.max(base.histograms.count, 1)
            where base.histograms[i].t == base.histograms[i - 1].t {
                throw EvaluationError.duplicateLabelset
            }
            merged.series.append(base)
        }
        return merged
    }

    /// Go: `rangeEvalTimestampFunctionOverVectorSelector` — `timestamp()` over a selector.
    ///
    /// It exists because a matrix evaluation reports the STEP's timestamp, and `timestamp()`
    /// has to report the SAMPLE's. So the selector is read directly, per step, and the sample
    /// values are discarded — only `T` is filled in.
    ///
    /// Two details that are easy to lose:
    ///
    ///   * the memoized iterator is built with `lookbackDelta - 1`, where `evalSeries` uses
    ///     the full `lookbackDelta`. One fewer millisecond of lookback, on this path only.
    ///   * with an `@` modifier the selector's `Offset` is **rewritten every step** to
    ///     `enh.Ts - timestamp`, so each step still gets a point — upstream issue 8433. That is
    ///     a mutation of the AST during evaluation, and it is deliberate.
    func rangeEvalTimestampFunctionOverVectorSelector(
        _ ctx: GoContext, _ vs: VectorSelector, _ call: FunctionCall, _ e: Call,
        _ ws: inout Annotations
    ) throws -> any Value {
        do {
            _ = ws.merge(try checkAndExpandSeriesSet(ctx, vs))
        } catch {
            var carried = ws
            throw ErrWithWarnings(StorageExpansionError(underlying: error), carried.merge(ws))
        }

        // `lookbackDelta - 1`, not `lookbackDelta`.
        let iterators = vs.series.map {
            MemoizedSeriesIterator($0.iterator(nil), delta: durationMilliseconds(lookbackDelta) - 1)
        }

        return try rangeEval(ctx, nil, &ws, []) { _, _, enh in
            if let t = vs.timestamp {
                // Issue 8433: without this an `@`-pinned selector yields one point in total
                // rather than one per step.
                vs.offset = GoDuration(nanoseconds: (enh.ts - t) * 1_000_000)
            }
            var vec = Vector()
            vec.samples.reserveCapacity(vs.series.count)
            for (i, s) in vs.series.enumerated() {
                guard let got = try self.vectorSelectorSingle(iterators[i], vs.offset, enh.ts)
                else {
                    continue
                }
                // The value is ignored: only the timestamp matters to the caller.
                vec.samples.append(Sample(t: got.origT, metric: s.labels()))
                self.currentSamples += 1
                if self.currentSamples > self.maxSamples {
                    throw QueryError.tooManySamples(evaluationEnv)
                }
            }
            return try call([vec], Matrix(), e.args, enh)
        }
    }

    /// Go: `vectorSelectorSingle` — the sample for one series at one step, or nil.
    ///
    /// The lookback rule in full: seek to `ts - offset`; if there is nothing there or the
    /// sample found is *after* it, fall back to the previous one — and accept that only if it
    /// is **strictly newer** than `refTime - lookbackDelta`. That `<=` is the half-open window
    /// `getTimeRangesForSelector` widens by `lookbackDelta - 1` to match.
    ///
    /// A stale marker is dropped as if there were no sample at all, and for a histogram the
    /// marker lives in `Sum`.
    func vectorSelectorSingle(
        _ it: MemoizedSeriesIterator, _ offset: GoDuration, _ ts: Int64
    ) throws -> (origT: Int64, f: Double, h: FloatHistogram?)? {
        let refTime = ts - durationMilliseconds(offset)
        var t: Int64 = 0
        var v = 0.0
        var h: FloatHistogram? = nil

        let valueType = it.seek(refTime)
        switch valueType {
        case .none:
            if let err = it.err() {
                throw err
            }
        case .float:
            (t, v) = it.at()
        case .floatHistogram:
            (t, h) = it.atFloatHistogram()
        default:
            throw EvaluationError.unknownValueType(String(describing: valueType))
        }
        if valueType == .none || t > refTime {
            guard let prev = it.peekPrev(),
                prev.t > refTime - durationMilliseconds(lookbackDelta)
            else {
                return nil
            }
            t = prev.t
            v = prev.value
            h = prev.fh
        }
        if PromValue.isStaleNaN(v) || (h != nil && PromValue.isStaleNaN(h!.sum)) {
            return nil
        }
        return (t, v, h)
    }
}
