//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — the query-preparation pass.
//
// `PreprocessExpr` and everything it reaches: `unwrapParenExpr`,
// `foldQueryContextFunctions`, `preprocessExprHelper`, `newStepInvariantExpr` and
// `detectHistogramStatsDecoding`. That is a self-contained slice of engine.go —
// it rewrites the AST before evaluation and touches no evaluator state — so it
// lands ahead of the evaluator rather than with it.
//
// Every rewrite here is an **in-place field assignment on an AST node**, which is
// the whole reason ADR-11 chose final classes over an indirect enum. Read that ADR
// before "modernising" any of this into a tree rebuild.
//
// Not ported here, deliberately:
//   - `setOffsetForAtModifier` and `subqueryTimes` — same file, and they are
//     tree rewrites too, but they run at *evaluation* time (per step, from
//     `execEvalStmt`) rather than at preparation time, and they are unexported
//     with no exported entry point, so they are not differentially reachable on
//     their own. They go with the evaluator.
//   - `makeInt64Pointer` — Go needs it because `Timestamp` is a `*int64`;
//     `Int64?` needs no helper.
//===----------------------------------------------------------------------===//

// `public`, not `internal`: `preprocessExpr` takes `GoTime`/`GoDuration` in a
// public signature, which `InternalImportsByDefault` rejects otherwise.
public import GoCompat
internal import PromModel
public import PromQLParser

/// Go: `PreprocessExpr` — resolve everything that is fixed for a given query
/// before evaluation begins.
///
/// Four passes, in this order, and the order is observable:
///
///  1. ``detectHistogramStatsDecoding(_:)`` marks the selectors that need only a
///     histogram's sum and count. It runs **first**, on the tree as parsed, so it
///     sees `histogram_count(...)` before step 2 can fold anything.
///  2. ``foldQueryContextFunctions(_:start:end:step:)`` rewrites `start()`,
///     `end()`, `range()` and `step()` into number literals, which is what lets
///     step 4 recognise their parents as step-invariant.
///  3. The duration visitor folds duration *expressions* into concrete durations.
///     This is the only pass that can fail.
///  4. ``preprocessExprHelper(_:start:end:)`` wraps the step-invariant subtrees in
///     `StepInvariantExpr`, and resolves `@ start()` / `@ end()` to timestamps.
///
/// The expression is mutated in place *and* returned, because step 4 may need to
/// wrap the root — which a caller holding the old reference could not observe.
public func preprocessExpr(
    _ expr: any Expr, start: GoTime, end: GoTime, step: GoDuration
) throws -> any Expr {
    detectHistogramStatsDecoding(expr)

    var expr = foldQueryContextFunctions(expr, start: start, end: end, step: step)

    let visitor = DurationVisitor(step: step, queryRange: end.sub(start))
    try walk(visitor, expr, [])

    let (_, shouldWrap) = preprocessExprHelper(expr, start: start, end: end)
    if shouldWrap {
        expr = newStepInvariantExpr(expr)
    }
    return expr
}

/// Go: `unwrapParenExpr` — the AST equivalent of deleting redundant parentheses.
///
/// Loops rather than recursing once, because `((foo))` nests.
func unwrapParenExpr(_ e: inout any Expr) {
    while let p = e as? ParenExpr {
        e = p.expr
    }
}

/// The optional overload, for `AggregateExpr.param` and `AggregateExpr.expr`. Go
/// gets this for free: the type assertion on a nil interface simply fails and the
/// loop stops.
func unwrapParenExpr(_ e: inout (any Expr)?) {
    while let p = e as? ParenExpr {
        e = p.expr
    }
}

/// Go: `foldQueryContextFunctions` — rewrite `start()`, `end()`, `range()` and
/// `step()` into `NumberLiteral`s, since each is constant for a given execution.
///
/// The point is not the constant folding itself but what it unlocks:
/// `preprocessExprHelper` can only recognise a parent as step-invariant if its
/// children are literals, and these four are `AtModifierUnsafeFunctions` members
/// that would otherwise block that.
func foldQueryContextFunctions(
    _ expr: any Expr, start: GoTime, end: GoTime, step: GoDuration
) -> any Expr {
    // Go tests for a Call *before* the switch, so a matching call is replaced
    // outright and its arguments are never visited. Any other call falls through
    // to the switch's Call case below and has its arguments folded.
    if let call = expr as? Call, let name = call.function?.name {
        switch name {
        case "start":
            return NumberLiteral(
                val: Double(Timestamp.fromTime(start)) / 1000, posRange: call.posRange)
        case "end":
            return NumberLiteral(
                val: Double(Timestamp.fromTime(end)) / 1000, posRange: call.posRange)
        case "range":
            return NumberLiteral(val: end.sub(start).seconds, posRange: call.posRange)
        case "step":
            // An instant query has start == end, and its step is meaningless
            // rather than zero — Go reports 0 for it either way, but through this
            // branch rather than by reading `step`.
            var val = 0.0
            if !start.equal(end) {
                val = step.seconds
            }
            return NumberLiteral(val: val, posRange: call.posRange)
        default:
            break
        }
    }

    switch expr {
    case let n as BinaryExpr:
        n.lhs = foldQueryContextFunctions(n.lhs, start: start, end: end, step: step)
        n.rhs = foldQueryContextFunctions(n.rhs, start: start, end: end, step: step)
    case let n as Call:
        for i in n.args.indices {
            n.args[i] = foldQueryContextFunctions(n.args[i], start: start, end: end, step: step)
        }
    case let n as AggregateExpr:
        if let e = n.expr {
            n.expr = foldQueryContextFunctions(e, start: start, end: end, step: step)
        }
        if let p = n.param {
            n.param = foldQueryContextFunctions(p, start: start, end: end, step: step)
        }
    case let n as UnaryExpr:
        n.expr = foldQueryContextFunctions(n.expr, start: start, end: end, step: step)
    case let n as ParenExpr:
        n.expr = foldQueryContextFunctions(n.expr, start: start, end: end, step: step)
    case let n as SubqueryExpr:
        n.expr = foldQueryContextFunctions(n.expr, start: start, end: end, step: step)
    case is MatrixSelector, is VectorSelector, is NumberLiteral, is StringLiteral:
        // Leaves, or nodes with no foldable sub-expression. A `MatrixSelector`'s
        // vector selector is deliberately not visited: Go lists it here as a leaf.
        break
    default:
        // Go panics with `foldQueryContextFunctions: unhandled node type %T`.
        // Unreachable from a parsed tree: a `DurationExpr` only ever hangs off a
        // selector's `RangeExpr`/`OriginalOffsetExpr`/`StepExpr`, none of which
        // this walk descends into, and `StepInvariantExpr` does not exist until
        // step 4 of `preprocessExpr`.
        preconditionFailure(
            "foldQueryContextFunctions: unhandled node type *parser.\(expr.nodeTypeName)")
    }
    return expr
}

/// Go: `newStepInvariantExpr`.
func newStepInvariantExpr(_ expr: any Expr) -> any Expr {
    StepInvariantExpr(expr: expr)
}

/// Go: `preprocessExprHelper` — wrap each step-invariant subtree in a
/// `StepInvariantExpr` at the **highest** level where that is true, resolve
/// `@ start()` / `@ end()`, and drop redundant parentheses around function and
/// aggregation parameters.
///
/// Returns `(isStepInvariant, shouldWrap)`. The two are not the same question:
/// a `MatrixSelector` can be step-invariant and still must not be wrapped,
/// because functions over range vectors evaluate them directly; a `StringLiteral`
/// likewise. So `shouldWrap` is false for the nodes that never need it, and the
/// caller wraps only when told to.
func preprocessExprHelper(
    _ expr: (any Expr)?, start: GoTime, end: GoTime
) -> (isStepInvariant: Bool, shouldWrap: Bool) {
    switch expr {
    case let n as VectorSelector:
        switch n.startOrEnd {
        case .start: n.timestamp = Timestamp.fromTime(start)
        case .end: n.timestamp = Timestamp.fromTime(end)
        default: break
        }
        // An `@` timestamp is exactly what makes a selector step-invariant, so
        // both answers are the same test.
        return (n.timestamp != nil, n.timestamp != nil)

    case let n as AggregateExpr:
        unwrapParenExpr(&n.expr)
        unwrapParenExpr(&n.param)
        return preprocessExprHelper(n.expr, start: start, end: end)

    case let n as BinaryExpr:
        let (isInvariantLHS, shouldWrapLHS) = preprocessExprHelper(n.lhs, start: start, end: end)
        let (isInvariantRHS, shouldWrapRHS) = preprocessExprHelper(n.rhs, start: start, end: end)
        if isInvariantLHS && isInvariantRHS {
            // Both sides invariant: report up so the *parent* wraps the whole
            // binary expression, rather than wrapping each side separately.
            return (true, true)
        }
        if shouldWrapLHS {
            n.lhs = newStepInvariantExpr(n.lhs)
        }
        if shouldWrapRHS {
            n.rhs = newStepInvariantExpr(n.rhs)
        }
        return (false, false)

    case let n as Call:
        guard let function = n.function else {
            // Go reads `n.Func.Name` and nil-derefs. Only reachable from a tree
            // the parser already reported an error for.
            preconditionFailure("preprocessExprHelper: Call with an unresolved function")
        }
        var isStepInvariant = !atModifierUnsafeFunctions.contains(function.name)
        // `timestamp` is @-unsafe in general but safe when every argument is a
        // plain vector selector: `timestamp(metric @ 1)` is step-invariant,
        // `timestamp(abs(metric @ 1))` is not.
        var isTimestampWithAllArgsStepInvariantSafe = function.name == "timestamp"
        var shouldWrap = [Bool](repeating: false, count: n.args.count)

        for i in n.args.indices {
            unwrapParenExpr(&n.args[i])
            let (argIsStepInvariant, wrapArg) = preprocessExprHelper(
                n.args[i], start: start, end: end)
            shouldWrap[i] = wrapArg
            isStepInvariant = isStepInvariant && argIsStepInvariant

            let argIsVectorSelector = n.args[i] is VectorSelector
            if !argIsStepInvariant || !argIsVectorSelector {
                isTimestampWithAllArgsStepInvariantSafe = false
            }
        }

        if isStepInvariant || isTimestampWithAllArgsStepInvariantSafe {
            return (true, true)
        }
        for (i, wrap) in shouldWrap.enumerated() where wrap {
            n.args[i] = newStepInvariantExpr(n.args[i])
        }
        return (false, false)

    case let n as MatrixSelector:
        // Never wrapped: a function over a range vector evaluates it directly.
        let (isStepInvariant, _) = preprocessExprHelper(
            n.vectorSelector, start: start, end: end)
        return (isStepInvariant, false)

    case let n as SubqueryExpr:
        // The inside of a subquery is wrapped whenever it is invariant, whether or
        // not the subquery itself carries an `@` — because the offset is adjusted
        // per subquery step, and wrapping pins the inside to the subquery's own
        // start time instead.
        let (isInvariant, _) = preprocessExprHelper(n.expr, start: start, end: end)
        if isInvariant {
            n.expr = newStepInvariantExpr(n.expr)
        }
        switch n.startOrEnd {
        case .start: n.timestamp = Timestamp.fromTime(start)
        case .end: n.timestamp = Timestamp.fromTime(end)
        default: break
        }
        return (n.timestamp != nil, n.timestamp != nil)

    case let n as ParenExpr:
        return preprocessExprHelper(n.expr, start: start, end: end)

    case let n as UnaryExpr:
        return preprocessExprHelper(n.expr, start: start, end: end)

    case is StringLiteral, is NumberLiteral:
        // Invariant, but never wrapped.
        return (true, false)

    default:
        // Go: `panic(fmt.Sprintf("found unexpected node %#v", expr))`. A nil
        // expression lands here too, since a nil Go interface matches no case.
        preconditionFailure(
            "found unexpected node \(expr.map { "*parser.\($0.nodeTypeName)" } ?? "<nil>")")
    }
}

/// Go: `detectHistogramStatsDecoding` — set `SkipHistogramBuckets` on the vector
/// selectors whose consumers need only a native histogram's sum and count.
///
/// Upstream calls it an optimisation that is "not required for correctness", which
/// is true of the decoding but **not** of this flag's effect on counter-reset
/// detection — which is why the subquery case below clears it.
///
/// The walk is over the path *upwards* from each selector, and it is not a simple
/// "any histogram function above me" test:
///
///   - `histogram_count`/`histogram_sum`/`histogram_avg` set the flag but keep
///     walking, because something further up may veto it.
///   - `histogram_quantile`/`histogram_quantiles`/`histogram_fraction` need whole
///     buckets, so they clear it and stop.
///   - a `SubqueryExpr` clears it and stops: correct counter-reset detection needs
///     the buckets.
///   - `</` and `>/` (trim) depend on buckets, so they clear it and stop.
///
/// Nothing resets the flag to false when the path matches nothing, so a selector
/// simply keeps the `false` it was parsed with.
func detectHistogramStatsDecoding(_ expr: any Expr) {
    inspect(expr) { node, path in
        guard let n = node as? VectorSelector else { return }

        // Walk backwards up the path. Go labels this `pathLoop` so the inner
        // switch can break out of the loop rather than the switch.
        pathLoop: for p in path.reversed() {
            switch p {
            case is SubqueryExpr:
                n.skipHistogramBuckets = false
                break pathLoop

            case let call as Call:
                switch call.function?.name {
                case "histogram_count", "histogram_sum", "histogram_avg":
                    // Allowed preliminarily; keep walking in case a subquery or a
                    // whole-histogram function sits further up. (The latter would
                    // make no sense, but detecting it costs nothing.)
                    n.skipHistogramBuckets = true
                case "histogram_quantile", "histogram_quantiles", "histogram_fraction":
                    n.skipHistogramBuckets = false
                    break pathLoop
                default:
                    break
                }

            case let binary as BinaryExpr:
                if binary.op == .trimUpper || binary.op == .trimLower {
                    n.skipHistogramBuckets = false
                    break pathLoop
                }

            default:
                break
            }
        }
    }
}
