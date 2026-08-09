//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/context/context.go @ go1.25
//
// A subset of `context.Context`: cancellation, a deadline, and `Err()`. Every
// `storage` and `promql` entry point takes one, so it has to exist before the
// protocols can be written.
//
// See docs/DECISIONS.md ADR-13 for why this is a hand-rolled type rather than
// Swift structured concurrency's `Task` cancellation. In short: the PromQL
// evaluator is synchronous and non-`Sendable` by ADR-3, so it does not run
// inside a `Task` and cannot consult `Task.isCancelled`; but the cancel signal
// arrives from another thread (an HTTP handler), so the flag itself must be
// thread-safe.
//
// What is *not* here: `context.WithValue`. Prometheus uses it once, for
// `QueryOrigin` in the query logger, which arrives with Phase 9.
//===----------------------------------------------------------------------===//

internal import Synchronization

/// Go: the error values `context.Canceled` and `context.DeadlineExceeded`.
///
/// The `description` strings are Go's verbatim; they reach users through
/// `promql`'s `ErrQueryCanceled`/`ErrQueryTimeout` fallthrough case.
public enum GoContextError: Error, Hashable, Sendable, CustomStringConvertible {
    case canceled
    case deadlineExceeded

    public var description: String {
        switch self {
        case .canceled: return "context canceled"
        case .deadlineExceeded: return "context deadline exceeded"
        }
    }
}

/// Go: `context.Context`, minus values.
///
/// A class, because Go's contexts form a tree in which cancelling a parent
/// cancels its children, and because `cancel` mutates shared state.
public final class GoContext: Sendable {

    /// Absolute deadline, if this context or any ancestor has one.
    /// Go: `Context.Deadline`.
    public let deadline: GoTime?

    private let state: Mutex<State>

    private struct State {
        var cause: GoContextError?
        /// Children are held strongly, matching Go: a `cancelCtx` keeps its
        /// children until it is cancelled or its own parent is.
        var children: [GoContext]
    }

    private init(deadline: GoTime?) {
        self.deadline = deadline
        self.state = Mutex(State(cause: nil, children: []))
    }

    /// Go: `context.Background()`. Never cancelled, no deadline.
    public static func background() -> GoContext {
        GoContext(deadline: nil)
    }

    /// Go: `context.WithCancel(parent)`. The returned closure is Go's
    /// `CancelFunc`; calling it more than once is a no-op, as in Go.
    public static func withCancel(_ parent: GoContext) -> (
        context: GoContext, cancel: @Sendable () -> Void
    ) {
        let child = GoContext(deadline: parent.deadline)
        parent.adopt(child)
        return (child, { child.cancel(.canceled) })
    }

    /// Go: `context.WithTimeout(parent, timeout)`.
    ///
    /// The deadline is the earlier of `now + timeout` and the parent's, which is
    /// what `WithDeadline` does when it sees the parent expires first.
    ///
    /// Unlike Go there is no timer: nothing fires the cancellation on its own.
    /// `err()` compares the deadline against the clock when asked, which is
    /// sufficient because the evaluator polls (`contextDone` at every step) and
    /// avoids putting a thread or a `Task` behind every query.
    public static func withTimeout(
        _ parent: GoContext, _ timeout: GoDuration, now: GoTime = GoTime.now()
    ) -> (context: GoContext, cancel: @Sendable () -> Void) {
        var deadline = now.add(timeout)
        if let parentDeadline = parent.deadline, parentDeadline < deadline {
            deadline = parentDeadline
        }
        let child = GoContext(deadline: deadline)
        parent.adopt(child)
        return (child, { child.cancel(.canceled) })
    }

    /// Go: `Context.Err()` — nil until the context is done, then the reason.
    ///
    /// Takes the current time so the deadline check is testable and so a single
    /// evaluation step can be consistent about "now" rather than re-reading the
    /// clock per node.
    public func err(now: GoTime = GoTime.now()) -> GoContextError? {
        let existing = state.withLock { $0.cause }
        if let existing {
            return existing
        }
        if let deadline, !now.before(deadline) {
            cancel(.deadlineExceeded)
            return .deadlineExceeded
        }
        return nil
    }

    /// Go: whether `Context.Done()` has been closed. Equivalent to `err() != nil`.
    public func isDone(now: GoTime = GoTime.now()) -> Bool {
        err(now: now) != nil
    }

    private func adopt(_ child: GoContext) {
        // Go propagates an already-cancelled parent immediately rather than
        // registering the child (propagateCancel's `if parent.Err() != nil`).
        let parentCause = state.withLock { current -> GoContextError? in
            if current.cause == nil {
                current.children.append(child)
                return nil
            }
            return current.cause
        }
        if let parentCause {
            child.cancel(parentCause)
        }
    }

    /// Go: `cancelCtx.cancel`. First cause wins; children are cancelled with the
    /// same cause and then released.
    private func cancel(_ cause: GoContextError) {
        let children = state.withLock { current -> [GoContext] in
            if current.cause != nil {
                return []
            }
            current.cause = cause
            let toCancel = current.children
            current.children = []
            return toCancel
        }
        for child in children {
            child.cancel(cause)
        }
    }
}
