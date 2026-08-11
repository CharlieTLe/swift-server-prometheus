//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `labelValuesWithMatchers` and `labelNamesWithMatchers`, plus the
// `blockIndexReader` dispatch that decides when they run at all.
//
// ## The dispatch is the first behaviour, and it is easy to miss
//
// `blockIndexReader.LabelValues` branches on `len(matchers) == 0`: with none it goes straight to the index
// reader, with any it calls `labelValuesWithMatchers`. Same for `LabelNames`. So the no-matcher path never
// touches this file, which makes it the control for everything in it rather than a case of it.
//
// `SortedLabelValues` adds a second layer: with no matchers it asks the reader for sorted values, with
// matchers it calls `LabelValues` and then **sorts the result itself**. So the two entry points return
// different ORDERS for the same query, and both are observable — `storage.Querier.LabelValues` is the sorted
// one.
//
// ## The queried name's own matchers prune BEFORE postings are fetched
//
// Upstream's comment: "If we have a matcher for the label name, we can filter out values that don't match
// before we fetch postings. This is especially useful for labels with many values. e.g. __name__ with a
// selector like {__name__="xyz"}". The filter reuses `allValues[:0]` in place — safe only because the read
// index stays ahead of the write index, and noted as such in a comment upstream.
//
// A matcher on the queried name does NOT set `hasMatchersForOtherLabels`, which is the whole point: if every
// matcher names the queried label, the filtered values ARE the answer and no postings are read.
//
// ## The limit is applied in two different branches, over two different ORDERS
//
//   - no other-label matchers → truncate the filtered values: `allValues[:hints.Limit]`, which is the
//     index's own (sorted) order;
//   - other-label matchers    → stop collecting once `len(values) >= hints.Limit`, walking
//     `FindIntersectingPostings`' returned order, which is a HEAP's order (quirk 158).
//
// The difference that matters is the ORDER, not the mechanism: stopping at k and taking the first k of the
// same sequence are the same thing, and a control asserting otherwise survives because it is a tautology.
// What is real is that the second branch's order is the heap's, so a limit there keeps a set the sorted
// order would not have chosen. Sorting `indexes` before collecting breaks 2 of the 7 corpus cases, which is
// what establishes it — the first version of this comment claimed the mechanism was the difference and was
// checked only afterwards.
//
// ## `len(allValues) == 0` returns nil EARLY
//
// Before `PostingsForMatchers`, so a matcher that prunes every value costs no postings work — and, more
// observably, cannot produce an error from the postings layer.
//
// ## `labelNamesWithMatchers` has no limit of its own
//
// It is `PostingsForMatchers` then `LabelNamesFor`. The limit lives in `blockBaseQuerier.LabelNames`, applied
// to the result afterwards — so unlike label values there is only one place it can act.
//===----------------------------------------------------------------------===//

public import PromIndex
public import PromLabels

internal import GoCompat

/// The index operations the label queries need, on top of ``PostingsIndex``.
///
/// Split from `PostingsIndex` rather than merged into it because `PostingsForMatchers` genuinely needs only
/// three methods, and a protocol that demanded these too would force every future caller (the Head included)
/// to implement more than it uses.
public protocol LabelQueryIndex: PostingsIndex {
    /// Go: `ix.LabelValues(ctx, name, nil)` — every value of the name, in the index's own order.
    func labelValues(name: String) throws -> [String]
    /// Go: `ix.LabelNamesFor(ctx, postings)` — the label names of the series in a postings list, sorted.
    func labelNamesFor(_ postings: any Postings) throws -> [String]
    /// Go: `ix.LabelNames(ctx)` — every label name in the index, sorted.
    func labelNames() throws -> [String]
}

/// Go: `fmt.Errorf("fetching values of label %s: %w", …)` and its siblings.
public enum LabelQueryError: Error, CustomStringConvertible {
    case fetchingValues(name: String, underlying: any Error)
    case fetchingPostingsForMatchers(underlying: any Error)
    case fetchingPostingsFor(name: String, value: String, underlying: any Error)
    case intersectingPostings(underlying: any Error)

    public var description: String {
        switch self {
        case .fetchingValues(let n, let e): return "fetching values of label \(n): \(e)"
        case .fetchingPostingsForMatchers(let e): return "fetching postings for matchers: \(e)"
        case .fetchingPostingsFor(let n, let v, let e):
            // Go: `%q` on the value, which is `strconv.Quote`.
            return "fetching postings for \(n)=\(GoStrconv.quote(v)): \(e)"
        case .intersectingPostings(let e): return "intersecting postings: \(e)"
        }
    }
}

/// Go: `labelValuesWithMatchers`.
///
/// `limit` of 0 means none, matching `storage.LabelHints`'s zero value — upstream tests `hints != nil &&
/// hints.Limit > 0`, so a nil hints and a zero limit are the same thing and the port collapses them.
public func labelValuesWithMatchers(
    _ ix: any LabelQueryIndex, name: String, limit: Int = 0, matchers: [Matcher]
) throws -> [String] {
    var allValues: [String]
    do {
        allValues = try ix.labelValues(name: name)
    } catch {
        throw LabelQueryError.fetchingValues(name: name, underlying: error)
    }

    // A matcher on the QUERIED name prunes before any postings are read. See the file header.
    var hasMatchersForOtherLabels = false
    for m in matchers {
        if m.name != name {
            hasMatchersForOtherLabels = true
            continue
        }
        // Go reuses `allValues[:0]`; the port rebuilds, because Swift's `Array` has no aliasing slice and
        // the in-place trick exists to avoid an allocation, not to be observable.
        allValues = allValues.filter { m.matches($0) }
    }

    if allValues.isEmpty {
        // EARLY, before `PostingsForMatchers`. See the file header.
        return []
    }

    if !hasMatchersForOtherLabels {
        // The filtered values ARE the answer, and the limit truncates.
        if limit > 0 && allValues.count > limit {
            return Array(allValues[0..<limit])
        }
        return allValues
    }

    let p: any Postings
    do {
        p = try postingsForMatchers(ix, matchers)
    } catch {
        throw LabelQueryError.fetchingPostingsForMatchers(underlying: error)
    }

    var valuesPostings: [any Postings] = []
    valuesPostings.reserveCapacity(allValues.count)
    for value in allValues {
        do {
            valuesPostings.append(try ix.postings(name: name, values: [value]))
        } catch {
            throw LabelQueryError.fetchingPostingsFor(
                name: name, value: value, underlying: error)
        }
    }

    let indexes: [Int]
    do {
        indexes = try findIntersectingPostings(p, valuesPostings)
    } catch {
        throw LabelQueryError.intersectingPostings(underlying: error)
    }

    // The limit acts WHILE collecting here, over the heap's order — not by truncating a sorted list. See
    // the file header; this is the half that makes the two limit sites inequivalent.
    var values: [String] = []
    values.reserveCapacity(indexes.count)
    for idx in indexes {
        values.append(allValues[idx])
        if limit > 0 && values.count >= limit {
            break
        }
    }
    return values
}

/// Go: `labelNamesWithMatchers` — `PostingsForMatchers` then `LabelNamesFor`. No limit of its own.
public func labelNamesWithMatchers(
    _ ix: any LabelQueryIndex, matchers: [Matcher]
) throws -> [String] {
    let p = try postingsForMatchers(ix, matchers)
    return try ix.labelNamesFor(p)
}

// MARK: - The dispatch

/// Go: `blockIndexReader.LabelValues` — the branch that decides whether the above runs.
public func blockLabelValues(
    _ ix: any LabelQueryIndex, name: String, limit: Int = 0, matchers: [Matcher] = []
) throws -> [String] {
    if matchers.isEmpty {
        var values = try ix.labelValues(name: name)
        // Go: `Reader.LabelValues` applies the limit itself, checked BEFORE appending (quirk 137's
        // neighbour), so the port's `indexLabelValues` already did it — but this seam takes the limit too,
        // and applying it twice is harmless while applying it never is not.
        if limit > 0 && values.count > limit {
            values = Array(values[0..<limit])
        }
        return values
    }
    return try labelValuesWithMatchers(ix, name: name, limit: limit, matchers: matchers)
}

/// Go: `blockIndexReader.SortedLabelValues`.
///
/// With matchers this SORTS what `LabelValues` returned; with none it asks for sorted values directly. So the
/// two entry points differ in order and both are reachable — `storage.Querier.LabelValues` is this one.
public func blockSortedLabelValues(
    _ ix: any LabelQueryIndex, name: String, limit: Int = 0, matchers: [Matcher] = []
) throws -> [String] {
    if matchers.isEmpty {
        // The index reader's own order is already sorted for v2, since the postings offset table is.
        return try blockLabelValues(ix, name: name, limit: limit)
    }
    // Go: `slices.Sort(st)` — byte order (ADR-10), not collation.
    var st = try blockLabelValues(ix, name: name, limit: limit, matchers: matchers)
    st.sort { goStringLessBytes($0, $1) }
    return st
}

/// Go: `blockIndexReader.LabelNames`, plus `blockBaseQuerier.LabelNames`'s limit.
///
/// The limit is applied AFTER the names come back, in the querier rather than in the index reader — which is
/// the opposite of label values, where the no-matcher path pushes it down.
public func blockLabelNames(
    _ ix: any LabelQueryIndex, limit: Int = 0, matchers: [Matcher] = []
) throws -> [String] {
    var res = matchers.isEmpty ? try ix.labelNames() : try labelNamesWithMatchers(ix, matchers: matchers)
    if limit > 0 && res.count > limit {
        res = Array(res[0..<limit])
    }
    return res
}
