//===----------------------------------------------------------------------===//
// Ported from storage/lazy.go @ v3.13.2 — the whole file.
//
// Three tiny generic series sets, all of them about DEFERRING or SUPPRESSING
// work rather than producing it:
//
//   - `lazyGenericSeriesSet` runs its initialiser on the first `Next()`. That is
//     what makes `mergeGenericQuerier.Select` cheap: the merge heap is built —
//     and every wrapped querier's first `Next()` therefore run — only when the
//     caller actually iterates. `secondaryQuerier.Select` uses the same wrapper
//     for its all-or-nothing partial-failure logic.
//   - `warningsOnlySeriesSet` is an empty set that still carries warnings, which
//     is how a secondary querier's error survives being demoted to a warning.
//   - `errorOnlySeriesSet` is an empty set that carries an error, returned by
//     `newGenericMergeSeriesSet` when a set fails its pre-advance.
//
// The one behaviour worth stating, because it is easy to "clean up": every
// accessor on an UNINITIALISED lazy set answers as though the set were empty —
// `Err()` nil, `At()` nil, `Warnings()` empty — rather than initialising. So
// calling `Err()` before `Next()` never runs the query, and never reports a
// failure that a `Next()` would have found.
//===----------------------------------------------------------------------===//

public import PromAnnotations

/// Go: `lazyGenericSeriesSet`.
public final class LazyGenericSeriesSet<E: LabelsProvider>: GenericSeriesSet {
    /// Go: `init func() (genericSeriesSet, bool)`.
    private let initialise: () -> (set: any GenericSeriesSet<E>, ok: Bool)
    private var set: (any GenericSeriesSet<E>)?

    public init(initialise: @escaping () -> (set: any GenericSeriesSet<E>, ok: Bool)) {
        self.initialise = initialise
    }

    /// lazy.go:29 — the initialiser's own boolean is returned, NOT a further
    /// `Next()`. `newGenericMergeSeriesSet` supplies `s.Next()` as that boolean,
    /// so the merge is pre-advanced by exactly one series and the first `Next()`
    /// here is that advance rather than a second one.
    public func next() -> Bool {
        if let set { return set.next() }
        let (s, ok) = initialise()
        set = s
        return ok
    }

    public func err() -> (any Error)? { set?.err() }

    public func at() -> E? { set?.at() }

    public func warnings() -> Annotations { set?.warnings() ?? Annotations() }
}

/// Go: `warningsOnlySeriesSet` — `type warningsOnlySeriesSet annotations.Annotations`,
/// i.e. the annotations *are* the set.
public final class WarningsOnlySeriesSet<E: LabelsProvider>: GenericSeriesSet {
    private let annotations: Annotations

    public init(_ annotations: Annotations) { self.annotations = annotations }

    public func next() -> Bool { false }
    public func err() -> (any Error)? { nil }
    public func at() -> E? { nil }
    public func warnings() -> Annotations { annotations }
}

/// Go: `errorOnlySeriesSet`.
public final class ErrorOnlySeriesSet<E: LabelsProvider>: GenericSeriesSet {
    private let error: any Error

    public init(_ error: any Error) { self.error = error }

    public func next() -> Bool { false }
    public func at() -> E? { nil }
    public func err() -> (any Error)? { error }
    public func warnings() -> Annotations { Annotations() }
}
