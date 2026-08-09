//===----------------------------------------------------------------------===//
// Tests for GoContext — the context.Context subset.
//
// No fixture: `context` has no byte-exact surface beyond the two error strings,
// and its behaviour is cancellation propagation, which is a property rather than
// a value. These are the properties the engine's `contextDone` polling relies on.
// See docs/DECISIONS.md ADR-13.
//===----------------------------------------------------------------------===//

import Testing

@testable import GoCompat

@Suite("GoContext behaves like context.Context")
struct GoContextTests {

    @Test("the error strings are Go's")
    func errorStrings() {
        // These reach users through promql's ErrQueryCanceled/ErrQueryTimeout
        // fallthrough, so they are a contract surface even though nothing else here
        // is.
        #expect(GoContextError.canceled.description == "context canceled")
        #expect(GoContextError.deadlineExceeded.description == "context deadline exceeded")
    }

    @Test("background is never done")
    func background() {
        let ctx = GoContext.background()
        #expect(ctx.err(now: GoTime.unix(0, 0)) == nil)
        #expect(!ctx.isDone(now: GoTime.unix(Int64.max / 2, 0)))
        #expect(ctx.deadline == nil)
    }

    @Test("cancel is sticky and idempotent")
    func cancel() {
        let (ctx, cancel) = GoContext.withCancel(GoContext.background())
        #expect(ctx.err(now: GoTime.unix(0, 0)) == nil)
        cancel()
        #expect(ctx.err(now: GoTime.unix(0, 0)) == .canceled)
        // A second call is a no-op, as Go's CancelFunc is.
        cancel()
        #expect(ctx.err(now: GoTime.unix(0, 0)) == .canceled)
    }

    @Test("cancelling a parent cancels its children")
    func propagation() {
        let (parent, cancelParent) = GoContext.withCancel(GoContext.background())
        let (child, _) = GoContext.withCancel(parent)
        let (grandchild, _) = GoContext.withCancel(child)

        cancelParent()
        #expect(child.err(now: GoTime.unix(0, 0)) == .canceled)
        #expect(grandchild.err(now: GoTime.unix(0, 0)) == .canceled)
    }

    @Test("a child of an already-cancelled parent starts cancelled")
    func alreadyCancelledParent() {
        // Go's propagateCancel checks parent.Err() first and cancels immediately
        // rather than registering the child.
        let (parent, cancelParent) = GoContext.withCancel(GoContext.background())
        cancelParent()
        let (child, _) = GoContext.withCancel(parent)
        #expect(child.err(now: GoTime.unix(0, 0)) == .canceled)
    }

    @Test("the deadline is checked against the clock, not a timer")
    func deadline() {
        let start = GoTime.unix(1_000, 0)
        let (ctx, _) = GoContext.withTimeout(
            GoContext.background(), GoDuration(nanoseconds: 5_000_000_000), now: start)
        #expect(ctx.deadline == GoTime.unix(1_005, 0))

        #expect(ctx.err(now: GoTime.unix(1_004, 999_999_999)) == nil)
        // The deadline itself counts as expired: Go's timer fires *at* it.
        #expect(ctx.err(now: GoTime.unix(1_005, 0)) == .deadlineExceeded)
        // And it is sticky once tripped, even if asked about an earlier instant.
        #expect(ctx.err(now: GoTime.unix(1_000, 0)) == .deadlineExceeded)
    }

    @Test("a timeout takes the parent's earlier deadline")
    func earlierParentDeadline() {
        // Go's WithDeadline keeps the parent's when the parent expires first.
        let start = GoTime.unix(1_000, 0)
        let (parent, _) = GoContext.withTimeout(
            GoContext.background(), GoDuration(nanoseconds: 2_000_000_000), now: start)
        let (child, _) = GoContext.withTimeout(
            parent, GoDuration(nanoseconds: 10_000_000_000), now: start)
        #expect(child.deadline == GoTime.unix(1_002, 0))
    }

    @Test("cancellation wins over a later deadline")
    func cancelBeatsDeadline() {
        let start = GoTime.unix(1_000, 0)
        let (ctx, cancel) = GoContext.withTimeout(
            GoContext.background(), GoDuration(nanoseconds: 5_000_000_000), now: start)
        cancel()
        // First cause wins, so this stays .canceled rather than becoming
        // .deadlineExceeded once the clock passes the deadline.
        #expect(ctx.err(now: GoTime.unix(9_999, 0)) == .canceled)
    }
}
