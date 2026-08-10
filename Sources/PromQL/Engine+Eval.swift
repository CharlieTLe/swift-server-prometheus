//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — `query.Exec`, `Engine.exec`, `execEvalStmt`'s
// instant path, `contextDone`, `setOffsetForAtModifier`, and the `evaluator` core:
// `Eval`, `rangeEval`, and the `eval` arms that need no storage.
//
// ## What this slice can evaluate, and what it refuses
//
// Ported arms: `NumberLiteral`, `StringLiteral`, `ParenExpr`, `UnaryExpr`,
// `StepInvariantExpr`, `BinaryExpr` where both sides are **scalars**, and `Call` where no
// argument is a matrix selector or subquery. That is every expression that never touches
// the storage — `1 + 2`, `time()`, `vector(1)`, `-(3^2)`, `abs(-1) > bool 0`,
// `day_of_week(vector(0))`, `"a string"`.
//
// Everything else — selectors, aggregations, subqueries, matrix arguments, the four
// vector/scalar binop shapes — throws `EvaluatorNotPorted`. That is a **loud** stub with a
// named expression type, not a silent wrong answer, and the fixture corpus is restricted to
// what is implemented rather than the port pretending otherwise.
//
// Range queries (`start != end`) are also not ported: `execEvalStmt`'s second half needs the
// same arms plus the per-step series assembly, and lands with the selectors.
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
// ## How much of this file is actually PINNED, and how much is only transcribed
//
// Be clear about this, because the fixture's 339 green cases could be read as covering the
// file and they do not. A single-step, single-series corpus can only witness single-step,
// single-series behaviour. Of 16 negative controls, three break —`gatherVector`'s counting,
// the string result bypassing the matrix tails, and `scalarBinop`'s comparisons returning 1/0
// — and the rest survive because the shape that would separate them needs input this slice
// cannot produce:
//
//   * consuming the gathered point (`floats.removeFirst()`) only matters across **steps**;
//   * the instant shortcut's ORDER, the scalar tail's `mat[0]`, the vector tail's forced
//     timestamp and unary minus's `DropName`/metadata drop all need **more than one series**,
//     or a series with a name — which means a selector;
//   * `interval: 1` only matters where a range query divides by it;
//   * `setOffsetForAtModifier` has nothing to rewrite without a selector;
//   * the inverted-range shortcut cannot happen when `start == end`.
//
// One survivor is *provably* absorbed rather than merely unwitnessed: `gatherVector`'s
// `> maxSamples` versus `>=`. Reaching the limit exactly at the gather always means the
// result — which adds at least one more sample — trips `rangeEval`'s own `>` check
// immediately after, so both spellings reject the same queries.
//
// So: the arms are transcribed faithfully and the ones a storage-free query can reach are
// pinned. The rest become testable when the selectors land, and that is the honest state.
//
// ## `setOffsetForAtModifier` rewrites the AST before evaluation
//
// A selector with `@` gets `Offset = originalOffset + (evalTime - timestamp)`, so the rest
// of the evaluator can ignore `@` entirely and read `Offset`. It runs once per query, on
// the statement's *start* time, which is why an instant query and a range query over the
// same expression can produce different offsets. Observable through `Statement()` after
// `Exec`, which is how the fixture pins it.
//===----------------------------------------------------------------------===//

public import GoCompat
public import PromAnnotations
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
            let v = try evalNode(ctx, expr, &ws)
            // `cleanupMetricLabels` belongs to the delayed-name-removal path, which arrives
            // with the aggregations that need it.
            if enableDelayedNameRemoval {
                throw EvaluatorNotPorted(
                    nodeType: "enableDelayedNameRemoval",
                    detail: "cleanupMetricLabels lands with the aggregations")
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
            return try rangeEval(ctx, &ws, []) { _, enh in
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
                if !enableDelayedNameRemoval && mat.series.count > 1 {
                    // `mergeSeriesWithSameLabelset` only matters once two series can share a
                    // label set, which needs selectors.
                    throw EvaluatorNotPorted(
                        nodeType: "UnaryExpr",
                        detail: "mergeSeriesWithSameLabelset needs multi-series input")
                }
            }
            return mat

        case let e as BinaryExpr:
            let lt = e.lhs.type
            let rt = e.rhs.type
            guard lt == .scalar && rt == .scalar else {
                throw EvaluatorNotPorted(
                    nodeType: "BinaryExpr",
                    detail: "\(lt.documented) \(e.op.description) \(rt.documented)")
            }
            return try rangeEval(ctx, &ws, [e.lhs, e.rhs]) { v, enh in
                // `try` rather than `try?`: an unported operator must surface, not become NaN.
                let val = try scalarBinop(e.op, v[0].samples[0].f, v[1].samples[0].f)
                var out = enh.out
                out.append(Sample(f: val))
                return (out, Annotations())
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
            guard let mat = res as? Matrix else {
                // engine.go panics here with the *outer* expression's type, which is a
                // reachable-looking message for an unreachable state.
                throw EvaluatorNotPorted(
                    nodeType: "StepInvariantExpr",
                    detail: "unexpected result type \(res.type.documented)")
            }
            if startTimestamp == endTimestamp {
                return mat
            }
            throw EvaluatorNotPorted(
                nodeType: "StepInvariantExpr", detail: "step duplication needs range queries")

        case let e as Call:
            for a in e.args where a is MatrixSelector || a is SubqueryExpr {
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "\((e.function?.name ?? "")) over a range")
            }
            switch (e.function?.name ?? "") {
            case "label_replace", "label_join", "info":
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "\((e.function?.name ?? "")) works on series")
            default:
                break
            }
            guard let call = functionCalls[e.function?.name ?? ""] else {
                // Go panics: the seven nil entries are handled before this point.
                throw EvaluatorNotPorted(
                    nodeType: "Call", detail: "no implementation for \((e.function?.name ?? ""))")
            }
            // The sort-in-range-query warning needs `startTimestamp != endTimestamp`, so it
            // arrives with range queries.
            return try rangeEval(ctx, &ws, e.args) { v, enh in
                call(v, Matrix(), e.args, enh)
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
        _ ctx: GoContext, _ warnings: inout Annotations, _ exprs: [any Expr],
        _ funcCall: ([Vector], EvalNodeHelper) throws -> (Vector, Annotations)
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
                vectors.append(try gatherVector(ts, &matrixes[i]))
            }

            enh.ts = ts
            let (result, ws) = try funcCall(vectors, enh)
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

            ts += interval
        }

        throw EvaluatorNotPorted(
            nodeType: "rangeEval", detail: "the multi-step series assembly needs range queries")
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
    private func gatherVector(_ ts: Int64, _ input: inout Matrix?) throws -> Vector {
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
}

/// Go: `scalarBinop` — the arithmetic and comparison operators over two scalars.
///
/// The comparisons return `btos(...)`, i.e. 1 or 0 — a scalar comparison is arithmetic, not a
/// filter, which is why `1 > 2` is `0` and not "no data". `bool` is irrelevant here: the
/// parser rejects it on a scalar/scalar comparison.
///
/// `ATAN2` is the one operator missing: it needs `math.Atan2`, which — like the rest of Go's
/// trigonometry — is Go's own algorithm rather than libm's and so needs its own differential
/// fixture (PORTING.md quirks 41-43 for the same problem with the hyperbolics). Until then it
/// throws rather than quietly using Foundation's.
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
    case .atan2:
        throw EvaluatorNotPorted(
            nodeType: "scalarBinop", detail: "atan2 needs GoMath.atan2")
    default:
        // Go panics with `operator %q not allowed for Scalar operations`; the parser makes
        // this unreachable.
        throw EvaluatorNotPorted(
            nodeType: "scalarBinop", detail: "operator \(op.description) is not a scalar op")
    }
}

/// Go: `ev.errorf("vector cannot contain metrics with the same labelset")` and friends —
/// the evaluator's own messages, which reach the user verbatim.
public enum EvaluationError: Error, CustomStringConvertible, Equatable, Sendable {
    case duplicateLabelset

    public var description: String {
        switch self {
        case .duplicateLabelset:
            return "vector cannot contain metrics with the same labelset"
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

        // `populateSeries` walks the AST and attaches a SeriesSet to every selector. With no
        // selector arm ported there is nothing to populate, and reaching a selector is an
        // error anyway — so this is where that lands rather than in the middle of evaluation.

        // The `@` rewrite happens ONCE, on the start time, before evaluation.
        setOffsetForAtModifier(Timestamp.fromTime(s.start), s.expr)

        guard Timestamp.fromTime(s.start) == Timestamp.fromTime(s.end) && s.interval.nanoseconds == 0
        else {
            throw EvaluatorNotPorted(
                nodeType: "EvalStmt", detail: "range queries need the per-step series assembly")
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
}
