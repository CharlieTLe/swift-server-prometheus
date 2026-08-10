//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — the four query error types, `errWithWarnings`,
// `contextErr`, and the panic-to-error conversion in `evaluator.recover`.
//
// This is the error vocabulary of query *evaluation*, which the evaluator raises and
// `Exec` returns. It is ported ahead of the evaluator because every one of these strings is
// user-visible through the HTTP API and none of them needs an evaluator to be pinned.
//
// ## The three timing errors carry a location, not a duration
//
// `ErrQueryTimeout("query execution")` renders as "query timed out in query execution".
// The string is *where* the query was when it stopped — `execEvalStmt`, `expression
// evaluation`, `result sorting` — so the message reads as a place rather than an interval.
// Passing an empty one yields the trailing "in " with nothing after it, which the corpus
// pins because it is reachable from a caller that has no context to name.
//
// ## `evaluator.recover` classifies panics into four shapes, in order
//
//   1. a Go **runtime** error (nil dereference, index out of range) becomes
//      `unexpected error: <it>` — wrapped, so `errors.Is` still finds the original;
//   2. an `errWithWarnings` is unwrapped into its error *and its annotations are merged*,
//      which is the only way a failed evaluation still returns warnings;
//   3. any other `error` passes through unchanged;
//   4. anything else at all is formatted with `%v`.
//
// The order matters: `runtime.Error` also satisfies `error`, so the first case has to come
// first or a runtime panic would lose its "unexpected error" prefix. Swift has no
// equivalent of recovering an arbitrary panic — a trap is not catchable — so the
// classification is exposed as a function over an already-caught error, and the port's own
// invariants use `precondition` where Go panics. See PORTING.md exception 9.
//
// ## 12 negative controls, all 12 break — but four only with the right filter
//
// Four of these behaviours (`unexpected error:`'s prefix, `classifyEvaluationError`'s case
// order, `contextErr`'s passthrough, and the runtime-error arm) are pinned by the
// hand-written invariant suite rather than by the fixture, because Go's `recover` and
// `contextErr` are unexported and only their *outputs* cross the wire. A control sweep
// filtered to the fixture suites alone reports them green. That is the same trap as the
// `--filter "promql/functions"` mistake in HANDOFF §4, in a new disguise: the filter has to
// cover every suite that pins the file, not just the differential one.
//
// ## `ErrStorage` is transparent
//
// It exists to be recognised by `errors.As`, not to decorate: its `Error()` returns the
// wrapped error's text verbatim, with no prefix. A port that added "storage: " would look
// tidier and break every consumer that matches on the message.
//===----------------------------------------------------------------------===//

public import PromAnnotations

internal import GoCompat

/// Go: `ErrQueryTimeout`, `ErrQueryCanceled`, `ErrTooManySamples` and `ErrStorage`.
///
/// Go declares these as four distinct types — three `string`s and a struct — so that
/// `errors.As` can tell them apart. One enum with four cases is the same discrimination.
public enum QueryError: Error, CustomStringConvertible {
    /// Go: `ErrQueryTimeout`. The payload is the *location*, not a duration.
    case queryTimeout(String)
    /// Go: `ErrQueryCanceled`.
    case queryCanceled(String)
    /// Go: `ErrTooManySamples`.
    case tooManySamples(String)
    /// Go: `ErrStorage` — a transparent wrapper whose message is the wrapped error's.
    case storage(any Error)
    /// Go: `fmt.Errorf("unexpected error: %w", err)` from `recover`'s `runtime.Error` arm.
    case unexpected(any Error)
    /// Go: `recover`'s default arm, `fmt.Errorf("%v", err)` over a non-error panic value.
    case panicValue(String)

    public var description: String {
        switch self {
        case .queryTimeout(let env):
            return "query timed out in \(env)"
        case .queryCanceled(let env):
            return "query was canceled in \(env)"
        case .tooManySamples(let env):
            return "query processing would load too many samples into memory in \(env)"
        case .storage(let err):
            // No prefix: `ErrStorage.Error()` is `e.Err.Error()`.
            return String(describing: err)
        case .unexpected(let err):
            return "unexpected error: \(String(describing: err))"
        case .panicValue(let text):
            return text
        }
    }
}

/// Go: the `runtime.Error` values `recover` wraps as `unexpected error: %w`.
///
/// Only the shapes the port can actually reach are modelled. A Swift index-out-of-range
/// **traps**, and a trap is not catchable (PORTING.md exception 9), so where upstream's own
/// panic is *reachable from a query* the port has to raise it deliberately and with Go's exact
/// text — otherwise a query that Go answers with an error would crash the process.
///
/// The message shapes are Go's runtime's, and they differ by sign: a negative index has no
/// length suffix, a too-large one does.
///
///     index out of range [-1]
///     index out of range [0] with length 0
public enum GoRuntimeError: Error, CustomStringConvertible, Equatable, Sendable {
    case indexOutOfRange(Int, length: Int)

    public var description: String {
        switch self {
        case .indexOutOfRange(let i, let length):
            if i < 0 {
                return "runtime error: index out of range [\(i)]"
            }
            return "runtime error: index out of range [\(i)] with length \(length)"
        }
    }
}

/// Go: `errWithWarnings` — an error carrying annotations that survive it.
///
/// The only way a failed evaluation still returns warnings: `recover` unwraps this and
/// merges the annotations into the ones being returned.
///
/// `@unchecked Sendable` because `Error` refines `Sendable` in Swift 6 while `Annotations`
/// is not: `AnnotationError` is an `AnyObject` protocol (ADR-6), so an `Annotations` holds
/// references. They are immutable once constructed and never mutated through this value, so
/// the checked conformance is what is missing, not the safety. Swift 6.1 rejects the
/// unannotated form where 6.2 does not, which is what the floor build in CI is for.
public struct ErrWithWarnings: Error, CustomStringConvertible, @unchecked Sendable {
    public var err: any Error
    public var warnings: Annotations

    public init(_ err: any Error, _ warnings: Annotations) {
        self.err = err
        self.warnings = warnings
    }

    /// Go: `Error()` — the inner error's text, with no mention of the warnings.
    public var description: String { String(describing: err) }
}

/// Go: the two `context` sentinels `contextErr` recognises.
///
/// Swift has no `context.Context`, and `GoContext` models cancellation without importing
/// Go's error values, so the two reasons are an enum here.
public enum ContextCancellation: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `context.Canceled`.
    case canceled
    /// Go: `context.DeadlineExceeded`.
    case deadlineExceeded

    public var description: String {
        switch self {
        case .canceled: return "context canceled"
        case .deadlineExceeded: return "context deadline exceeded"
        }
    }
}

/// Go: `contextErr` — turn a context failure into the query error that names where it
/// happened, and leave anything else alone.
///
/// Note the mapping is *not* symmetric with the names: `context.Canceled` becomes
/// `ErrQueryCanceled` and `DeadlineExceeded` becomes `ErrQueryTimeout`, so "deadline
/// exceeded" is reported to the user as a *timeout*.
public func contextErr(_ err: any Error, _ env: String) -> any Error {
    if let c = err as? ContextCancellation {
        switch c {
        case .canceled:
            return QueryError.queryCanceled(env)
        case .deadlineExceeded:
            return QueryError.queryTimeout(env)
        }
    }
    return err
}

/// Go: the body of `evaluator.recover` — classify a caught error and merge any warnings.
///
/// Returns the error to report; `warnings` is merged into in place, as Go's `ws.Merge`
/// does. `isRuntimeError` stands in for Go's `case runtime.Error`, which has no Swift
/// analogue: a Swift runtime failure traps rather than throwing, so the caller decides.
///
/// The `ErrWithWarnings` case must be tested before the plain-error case, exactly as Go's
/// type switch orders them — otherwise the warnings would be dropped.
public func classifyEvaluationError(
    _ err: any Error, warnings: inout Annotations, isRuntimeError: Bool = false
) -> any Error {
    if isRuntimeError {
        return QueryError.unexpected(err)
    }
    if let e = err as? ErrWithWarnings {
        _ = warnings.merge(e.warnings)
        return e.err
    }
    return err
}
