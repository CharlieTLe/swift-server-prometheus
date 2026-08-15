//===----------------------------------------------------------------------===//
// Ported from storage/interface.go @ v3.13.2 — the APPEND side.
//
// `Interface.swift`'s header deferred these "to Phases 6-7, with the Head", and the Head's appender is the
// first caller. Only what that appender implements is here; the sub-protocols Go composes into `Appender` are
// listed below with the slice that will need each, because an empty protocol would claim more than the port has.
//
// ## What is here
//
//   * `AppendOptions` — one flag, `DiscardOutOfOrder`, which `headAppender.Append` consults.
//   * `AppenderTransaction` — `Commit` and `Rollback`, and the rule they carry: an appender must be completed
//     with exactly one of them and must not be reused afterwards.
//   * `Appender` — the float `append` plus `setOptions`.
//   * `GetRef` — the optional extra interface downstream projects use to avoid a parallel reference table.
//
// ## What is NOT here, and who will need it
//
//   * `ExemplarAppender` — exemplars are their own slice (§7f defers them).
//   * `HistogramAppender` — the Head's histogram append path, deferred with the rest of it.
//   * `MetadataUpdater` — `UpdateMetadata`, which needs `memSeries.meta`.
//   * `StartTimestampAppender` — ported PARTIALLY: `appendSTZeroSample` is float-only and cheap, so it is here;
//     `AppendHistogramSTZeroSample` is a histogram method and is not. The protocol says so rather than
//     pretending to be complete.
//   * `AppendableV2`/`AppenderV2` — upstream's in-progress replacement (issue #17632). Nothing in the TSDB
//     implements it yet; `promqltest` uses it, which is why `PromQLTest` has its own narrower protocol.
//===----------------------------------------------------------------------===//

public import PromLabels

/// Go: `AppendOptions`.
///
/// Upstream's warning is worth keeping: this type is on its way out with the `AppenderV2` switch. Ported
/// because `headAppender.SetOptions` stores it and `Append` reads `DiscardOutOfOrder` on the out-of-order path.
public struct AppendOptions: Sendable, Equatable {
    /// Go: `DiscardOutOfOrder` — an out-of-order append MUST be rejected with `ErrOutOfOrderSample`, even when
    /// the TSDB has out-of-order ingestion enabled.
    public var discardOutOfOrder: Bool

    public init(discardOutOfOrder: Bool = false) {
        self.discardOutOfOrder = discardOutOfOrder
    }
}

/// Go: `AppenderTransaction`.
public protocol AppenderTransaction: AnyObject {
    /// Go: `Commit` — submits and clears the collected samples.
    func commit() throws
    /// Go: `Rollback` — rolls back the collected samples and drops them. Callers must call one of `commit()`
    /// or `rollback()`, and calling either twice is an error (`ErrAppenderClosed`).
    func rollback() throws
}

/// Go: `Appender` — batched appends against a storage.
///
/// `AnyObject` because every implementation is a pointer with mutable batch state, and because
/// `initAppender` swaps itself for a real one behind the same reference.
public protocol Appender: AppenderTransaction {
    /// Go: `Append`. The returned reference accelerates later appends of the same series and **may be
    /// rejected at any point**; 0 means "no reference, do not cache".
    @discardableResult
    func append(ref: SeriesRef, labels: Labels, t: Int64, v: Double) throws -> SeriesRef

    /// Go: `SetOptions`.
    func setOptions(_ opts: AppendOptions?)
}

/// Go: `StartTimestampAppender`, **minus its histogram method**.
///
/// Upstream's interface is `AppendSTZeroSample` plus `AppendHistogramSTZeroSample`; the second belongs to the
/// deferred histogram append path, so this protocol carries only the first. A partial port that says it is
/// partial, in the same spirit as `MemSeries` before §7f(d) filled it in.
public protocol StartTimestampAppender: Appender {
    /// Go: `AppendSTZeroSample` — a synthetic zero sample at the start timestamp, so a counter's first real
    /// sample has something to be a delta from.
    ///
    /// **Returns Go's pair rather than throwing**, because this is the one appender method whose error comes
    /// back with a NON-ZERO ref: an `st` that is out of order for the series answers
    /// `(s.ref, ErrOutOfOrderST)`, and a caller that has to re-append the real sample needs that ref. Same
    /// treatment, for the same reason, as `memSeries.appendable` (§7f(d)). `st >= t` is
    /// `(0, ErrSTNewerThanSample)`.
    func appendSTZeroSample(
        ref: SeriesRef, labels: Labels, t: Int64, st: Int64
    ) -> (ref: SeriesRef, error: (any Error)?)
}

/// Go: `GetRef` — an extra interface on appenders, used by downstream projects (Cortex, Mimir) so they do not
/// have to keep their own reference table.
public protocol GetRef {
    /// Returns 0 and the empty label set when the appender has no reference for the series. `hash` must be a
    /// hash of `lset`.
    func getRef(labels lset: Labels, hash: UInt64) -> (SeriesRef, Labels)
}
