//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the two exported name sets.
//
// The rest of functions.go — ~100 function bodies and the `FunctionCalls` table
// they hang off — arrives with the evaluator. These two are here now because
// `PreprocessExpr` needs `AtModifierUnsafeFunctions`, and its neighbour is three
// lines away in the same file.
//===----------------------------------------------------------------------===//

/// Go: `AtModifierUnsafeFunctions` — functions whose result depends on the
/// evaluation timestamp, so wrapping a call to one in a `StepInvariantExpr` would
/// change the answer.
///
/// `timestamp` is in the set but is special-cased by ``preprocessExprHelper``:
/// `timestamp(metric @ 1)` *is* step-invariant, while `timestamp(abs(metric @ 1))`
/// is not, so membership here is necessary but not sufficient.
public let atModifierUnsafeFunctions: Set<String> = [
    // Step invariant functions.
    "days_in_month", "day_of_month", "day_of_week", "day_of_year",
    "end", "hour", "minute", "month", "year",
    "predict_linear", "range", "start", "step", "time",
    // Uses the timestamp of the argument for the result, hence unsafe with @.
    "timestamp",
]

/// Go: `AnchoredSafeFunctions` — the functions the `anchored` range modifier may
/// be used with, because it yields matrices carrying samples outside the window.
///
/// Read only by the evaluator (engine.go:2194), which is not ported yet. Here
/// rather than deferred because the error message it feeds needs these names
/// sorted, and the set is three lines from ``atModifierUnsafeFunctions`` upstream.
public let anchoredSafeFunctions: Set<String> = [
    "resets", "changes", "rate", "increase", "delta",
]
