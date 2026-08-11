//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the four sorts: `sort`, `sort_desc`,
// `sort_by_label` and `sort_by_label_desc`, plus `filterFloats`, the two
// `vectorBy*ValueHeap` comparators and `stringSliceFromArgs`.
//
// These are the last four `FunctionCalls` entries that can have a body, so with them the
// table is complete: 82 of 82, with seven of Go's 89 keys `nil` by construction.
//
// ## Why these needed a sorting algorithm ported first
//
// Neither comparator is a valid strict weak ordering, and Go's sorts are unstable, so the
// output for tied elements is a property of the ALGORITHM. See `GoCompat/GoSort.swift`
// for the port and `GoNatsort.swift` for the second offender. Swift's `sort(by:)` has
// undefined behaviour on such a predicate — it is not merely a different order.
//
// ## `sort` and `sort_desc` are each a double negative
//
// Neither uses the comparator you would expect:
//
//     sort       -> sort.Sort(sort.Reverse(vectorByReverseValueHeap(v)))
//     sort_desc  -> sort.Sort(sort.Reverse(vectorByValueHeap(v)))
//
// and both heaps answer `Less` with **true** for a NaN on the left, whichever direction
// they otherwise compare. Reversing that puts NaN last, which is upstream's stated goal
// ("NaN should sort to the bottom"). Collapsing the double negation into one comparator
// would change where NaNs land and, for equal values, the permutation.
//
// ## The two families disagree about histograms, and about `enh.Out`
//
// `sort`/`sort_desc` drop histogram samples through `filterFloats` — a **mixed** vector
// silently loses its histograms with no annotation. `sort_by_label`/`_desc` keep them and
// sort them by labels like anything else. And all four ignore `enh.Out` entirely: they
// return the input vector, sorted, rather than appending. Every other function in the
// table appends, so this is the exception that a shared helper would erase.
//
// `filterFloats` filters *in place* (`floats := v[:0]`), so it clobbers the caller's
// vector. That is safe only because `vectorVals[0]` is dead afterwards, and it is why the
// Swift version can return a fresh array without a visible difference.
//
// ## `sort_by_label`'s tie-break saves it from being nondeterministic
//
// After the named labels are exhausted the comparator falls back to
// `labels.Compare(a.Metric, b.Metric)`, which is a total order on distinct label sets —
// so the only remaining ties are genuine duplicate label sets, which PromQL calls
// undefined anyway. Note `_desc` negates that fallback with `-labels.Compare(...)`; only
// the SIGN is contractual in this port (see PORTING.md on Compare's magnitude), and
// `slices.SortFunc` only ever tests `< 0`.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromLabels
internal import PromQLParser
internal import PromRegex
internal import PromModel

/// Go: `filterFloats` — histogram samples removed.
///
/// Upstream reuses the input's storage (`v[:0]`), so the caller's vector is left
/// truncated; nothing reads it afterwards.
func filterFloats(_ v: Vector) -> Vector {
    var floats: [Sample] = []
    floats.reserveCapacity(v.samples.count)
    for s in v.samples where s.h == nil {
        floats.append(s)
    }
    return Vector(floats)
}

/// Go: `vectorByValueHeap.Less` — ascending, except that a NaN on the left always wins.
///
/// `Less(i, j)` and `Less(j, i)` are both true when both are NaN, which is what makes
/// the algorithm's tie-breaking observable.
private func vectorByValueLess(_ samples: [Sample], _ i: Int, _ j: Int) -> Bool {
    let vi = samples[i].f
    let vj = samples[j].f
    if vi.isNaN {
        return true
    }
    return vi < vj
}

/// Go: `vectorByReverseValueHeap.Less` — the same, descending.
private func vectorByReverseValueLess(_ samples: [Sample], _ i: Int, _ j: Int) -> Bool {
    let vi = samples[i].f
    let vj = samples[j].f
    if vi.isNaN {
        return true
    }
    return vi > vj
}

/// Go: `funcSort` — ascending by value, NaNs at the bottom.
func funcSort(_ v: [Vector], _: Matrix, _: [any Expr], _: EvalNodeHelper) -> (
    Vector, Annotations
) {
    var samples = filterFloats(v[0]).samples
    // `sort.Sort(sort.Reverse(vectorByReverseValueHeap(…)))`: a descending comparator,
    // reversed. Not an ascending one.
    GoSort.sortReverse(
        count: samples.count,
        less: { vectorByReverseValueLess(samples, $0, $1) },
        swap: { samples.swapAt($0, $1) })
    return (Vector(samples), Annotations())
}

/// Go: `funcSortDesc` — descending by value, NaNs at the bottom.
func funcSortDesc(_ v: [Vector], _: Matrix, _: [any Expr], _: EvalNodeHelper) -> (
    Vector, Annotations
) {
    var samples = filterFloats(v[0]).samples
    // `sort.Sort(sort.Reverse(vectorByValueHeap(…)))`: an ascending comparator, reversed.
    GoSort.sortReverse(
        count: samples.count,
        less: { vectorByValueLess(samples, $0, $1) },
        swap: { samples.swapAt($0, $1) })
    return (Vector(samples), Annotations())
}

/// Go: `stringFromArg` — the value of a `StringLiteral`, which the type checker has
/// already guaranteed.
func stringFromArg(_ e: any Expr) -> String {
    guard let literal = e as? StringLiteral else {
        preconditionFailure("stringFromArg: the argument is a string literal")
    }
    return String(decoding: literal.val, as: UTF8.self)
}

/// Go: `stringSliceFromArgs`.
func stringSliceFromArgs(_ args: [any Expr]) -> [String] {
    args.map(stringFromArg)
}

/// The body shared by `sort_by_label` and `sort_by_label_desc`; upstream duplicates it
/// with two signs flipped, and `sign` is those two.
private func sortByLabel(
    _ v: [Vector], _ args: [any Expr], sign: Int
) -> (Vector, Annotations) {
    let lbls = stringSliceFromArgs(Array(args.dropFirst()))
    var samples = v[0].samples
    GoSort.sortFunc(&samples) { a, b in
        for label in lbls {
            let lv1 = a.metric[label]
            let lv2 = b.metric[label]

            if lv1 == lv2 {
                continue
            }

            if GoNatsort.compare(lv1, lv2) {
                return -sign
            }

            return sign
        }

        // Every named label was equal: fall back to the whole label set, so the order is
        // at least consistent.
        return sign * Labels.compare(a.metric, b.metric)
    }
    return (Vector(samples), Annotations())
}

/// Go: `funcSortByLabel`.
func funcSortByLabel(_ v: [Vector], _: Matrix, _ args: [any Expr], _: EvalNodeHelper) -> (
    Vector, Annotations
) {
    sortByLabel(v, args, sign: 1)
}

/// Go: `funcSortByLabelDesc`.
func funcSortByLabelDesc(_ v: [Vector], _: Matrix, _ args: [any Expr], _: EvalNodeHelper)
    -> (Vector, Annotations)
{
    sortByLabel(v, args, sign: -1)
}

// MARK: - label_join

/// Go: `evalLabelJoin` (functions.go:2431) — concatenate several labels' values into one.
///
/// Not a `FunctionCalls` entry: it works on **series**, not samples, so the evaluator reaches it
/// directly (quirk 62's `nil` entries). It never looks at a timestamp or a value.
///
/// Three details, and the third is the one worth knowing:
///
///   * a source label the series does not have contributes the **empty string**, so the separator
///     still appears — `label_join(x, "d", "-", "a", "nosuch")` gives `"1-"`;
///   * every name is validated with **UTF8** rules, so `a.b` is a legal destination;
///   * writing to `__name__` resets `DropName` to **false**, where any other destination
///     *preserves* it. So `label_join(rate(x[5m]), "__name__", "", "job")` gives the result a name
///     back, and the delayed-name-removal cleanup will not strip it.
///
/// `mergeSeriesWithSameLabelset` runs afterwards, and this is the first caller that can actually
/// reach it: joining a *differing* label away is exactly the collision quirk 78 said needed
/// `label_replace` or an aggregation.
func evalLabelJoin(
    _ ev: Evaluator, _ ctx: GoContext, _ args: [any Expr], _ ws: inout Annotations
) throws -> any Value {
    let dst = stringFromArg(args[1])
    let sep = stringFromArg(args[2])
    var srcLabels = [String]()
    srcLabels.reserveCapacity(Swift.max(args.count - 3, 0))
    for i in 3..<args.count {
        let src = stringFromArg(args[i])
        if !ValidationScheme.utf8.isValidLabelName(src) {
            throw EvaluationError.invalidSourceLabelNameInLabelJoin(src)
        }
        srcLabels.append(src)
    }
    if !ValidationScheme.utf8.isValidLabelName(dst) {
        throw EvaluationError.invalidDestinationLabelNameInLabelJoin(dst)
    }

    let val = try ev.evalNode(ctx, args[0], &ws)
    guard var matrix = val as? Matrix else {
        throw EvaluatorNotPorted(nodeType: "Call", detail: "label_join input is not a matrix")
    }

    var lb = LabelsBuilder(Labels.empty)
    for i in matrix.series.indices {
        let el = matrix.series[i]
        // A missing source label joins as the empty string, so the separator survives.
        let strval = srcLabels.map { el.metric[$0] }.joined(separator: sep)
        lb.reset(el.metric)
        lb.set(dst, strval)
        matrix.series[i].metric = lb.labels()
        // Writing `__name__` RESETS DropName; any other destination preserves it.
        matrix.series[i].dropName = dst == LabelName.metricName ? false : el.dropName
    }

    return try ev.mergeSeriesWithSameLabelset(matrix)
}

/// Go: `evalLabelReplace` — the last of the three series-shaped functions.
///
/// Like `label_join` it rewrites the matrix in place and then merges label sets that collided, and like
/// `label_join` writing `__name__` **resets** `DropName` while any other destination preserves it.
///
/// What is specific to it, and what kept it unported until `PromRegex` grew capture tracking:
///
///   * the regex is compiled `"^(?s:" + regexStr + ")$"`, so it is fully anchored and `.` matches a
///     newline. A pattern that would match a substring does not match here;
///   * the replacement is `Regexp.ExpandString`, whose `$1`/`${name}` language is Go's own — `$1x` is
///     the name `1x`, a `$` before a non-name expands to nothing, and `$$` is the only escape;
///   * **a series whose source label does not match is left completely alone** — not cleared, not
///     given an empty destination. `if indexes != nil` guards the whole rewrite;
///   * the two argument validations happen BEFORE the argument is evaluated, so a bad regex or a bad
///     destination name is reported even when the inner expression would have failed too.
func evalLabelReplace(
    _ ev: Evaluator, _ ctx: GoContext, _ args: [any Expr], _ ws: inout Annotations
) throws -> any Value {
    let dst = stringFromArg(args[1])
    let repl = Array(stringLiteralBytes(args[2]))
    let src = stringFromArg(args[3])
    let regexStr = stringFromArg(args[4])

    guard let regex = try? CompiledRegex(anchoredForLabelReplace: regexStr) else {
        throw EvaluationError.invalidRegularExpressionInLabelReplace(regexStr)
    }
    // The `[UInt8]` overload, for ADR-9's reason: decoding first substitutes U+FFFD and the check can
    // then never fail. The same fix `count_values` needed.
    guard ValidationScheme.utf8.isValidLabelName(stringLiteralBytes(args[1])) else {
        throw EvaluationError.invalidDestinationLabelNameInLabelReplace(dst)
    }

    // **`evalNode`, not `eval`.** Go has two methods and the difference is exactly this: exported
    // `Eval` runs `cleanupMetricLabels` and internal `eval` does not, and `evalLabelReplace` calls the
    // internal one. Calling the outer one here applies the deferred `DropName` to the ARGUMENT, so two
    // name-dropping series collapse to one label set and the duplicate check fires before
    // `label_replace` ever gets to rename them — which is precisely what deferring the removal exists
    // to prevent. `label_join` above already had this right.
    let val = try ev.evalNode(ctx, args[0], &ws)
    guard var matrix = val as? Matrix else {
        throw EvaluationError.unknownValueType("label_replace: expected a matrix")
    }

    var lb = LabelsBuilder(Labels())
    for i in matrix.series.indices {
        let el = matrix.series[i]
        let srcVal = Array(el.metric[src].utf8)
        // Only replace when the regexp matches — otherwise the series passes through untouched.
        guard let indexes = regex.findSubmatchIndex(srcVal) else { continue }
        let res = regex.expand([], repl, srcVal, indexes)
        lb.reset(el.metric)
        lb.set(dst, String(decoding: res, as: UTF8.self))
        matrix.series[i].metric = lb.labels()
        matrix.series[i].dropName = dst == LabelName.metricName ? false : el.dropName
    }

    return try ev.mergeSeriesWithSameLabelset(matrix)
}

/// The raw bytes of a string-literal argument, for the surfaces where decoding first would be lossy.
func stringLiteralBytes(_ e: any Expr) -> [UInt8] {
    guard let literal = e as? StringLiteral else {
        preconditionFailure("stringLiteralBytes: the argument is a string literal")
    }
    return literal.val
}
