//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/errors/join.go @ go1.25
//
// `storage/merge.go` joins errors in four places — `mergeGenericQuerier.Close`,
// `chainSampleIterator.Err`, `compactChunkIterator.Err` and
// `concatenatingChunkIterator.Err` — and the joined *message* is observable: it
// is what a querier's caller prints. `errors.Join` renders as the members'
// messages separated by a single `\n`, so a port that returned only the first
// error would differ in text as soon as two iterators fail at once.
//
// Two details that are easy to get wrong and are pinned by the merge corpus:
//
//   - `Join` DISCARDS nil members, and returns nil when every member is nil. So
//     `errors.Join(nil, nil)` is nil, not an empty joined error.
//   - `Join` of exactly ONE non-nil error still returns a `*joinError`, whose
//     message is that error's message unchanged. So the wrapper is invisible in
//     text but present in type — which is why this always wraps rather than
//     unwrapping the single case.
//===----------------------------------------------------------------------===//

/// Go: `errors.joinError`.
public struct GoJoinedError: Error, CustomStringConvertible {
    public let errors: [any Error]

    public init(_ errors: [any Error]) { self.errors = errors }

    /// join.go:48 — `\n` between members, no trailing newline.
    public var description: String {
        var out = ""
        for (i, e) in errors.enumerated() {
            if i > 0 { out += "\n" }
            out += String(describing: e)
        }
        return out
    }
}

/// Go: `errors.Join`. Nil members are dropped; all-nil yields nil.
public func goErrorsJoin(_ errs: [(any Error)?]) -> (any Error)? {
    var kept: [any Error] = []
    for e in errs {
        if let e { kept.append(e) }
    }
    if kept.isEmpty { return nil }
    return GoJoinedError(kept)
}
