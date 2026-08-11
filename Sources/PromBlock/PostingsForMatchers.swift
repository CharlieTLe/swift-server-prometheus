//===----------------------------------------------------------------------===//
// Ported from tsdb/querier.go @ v3.13.2 — `PostingsForMatchers` and its two helpers.
//
// This is the function that turns a query's label matchers into a postings list, and it is where the TSDB's
// query planning actually lives. It is also the densest piece of reasoning in the file, because a matcher
// that can match the EMPTY string means something completely different from one that cannot: the index only
// records series that HAVE a label, so `l!="foo"` must also select every series with no `l` at all.
//
// ## `labelMustBeSet` is the whole idea, and it is a per-NAME fact, not a per-matcher one
//
// A name is in `labelMustBeSet` when ANY matcher on it rejects the empty string. The optimisation upstream's
// comment names is `{l=~".", l!="1"}`: on its own `l!="1"` would have to be evaluated as "everything except
// l=1", including series without `l`, which means reading all postings. But `l=~"."` already guarantees `l`
// is present, so `l!="1"` becomes a cheap subtraction. **The two matchers are only combinable because they
// share a name**, which is why the map is keyed by name and consulted for every matcher on it.
//
// ## The matchers are SORTED, and the sort is about correctness, not speed
//
// `slices.SortStableFunc` puts intersecting matchers first. Upstream's comment gives two reasons and the
// second is the real one: "there is no chance that the set we subtract from contains postings of series that
// didn't exist when we constructed the set we subtract by." A concurrent appender can add series between two
// `ix.Postings` calls, so subtracting a NEWER set from an OLDER one can leave a series that should have been
// removed. Ordering the intersections first makes the subtrahend never older than the minuend.
//
// The comparator is worth reading twice: it returns `-1` when `i` intersects and `j` subtracts, and `+1`
// **otherwise** — including when both are the same kind. A comparator that never returns 0 is not a valid
// ordering, but `SortStableFunc` is stable, so equal elements keep their input order and the result is the
// intended partition anyway. The port reproduces the partition directly (a stable partition) rather than
// copying an invalid comparator into a Swift `sort(by:)`, which would trap or scramble — see quirk 156.
//
// ## `hasSubtractingMatchers && !hasIntersectingMatchers` reads ALL postings, deliberately
//
// With nothing to subtract from there is no base, so the base becomes every series. Upstream's comment says
// why it fetches `AllPostings` up front rather than letting the loop do it: "so that the base of subtraction
// doesn't include series that may be added to the index reader during this function call" — the same
// concurrency argument as the sort.
//
// ## Two `.*`/`.+` special cases each, and they are NOT symmetric
//
//     l=~".*"   do nothing at all       — matches every series, including those without `l`
//     l!~".*"   return EMPTY            — matches nothing
//     l=~".+"   all postings for `l`    — every series that HAS the label
//     l!~".+"   subtract all postings for `l`
//
// `l=~".*"` adding nothing to `its` is the case to be careful with: it is not "intersect with everything",
// it is "contribute no constraint", and those differ when it is the ONLY matcher — which is why the empty
// `its` case has to fall through to `intersect()`'s own behaviour rather than being special-cased here.
//
// ## The empty-postings short-circuits are checked on SOME branches and not others
//
// `IsEmptyPostingsType(it)` returns early on the `l=~".+"`, `isNot && !matchesEmpty` and `default`
// intersecting branches — because an empty intersection makes the whole result empty — but NOT on the
// subtracting ones, where an empty set to subtract is simply a no-op. Reproduced exactly; a port that
// checked uniformly would be *correct* and would still diverge on which error it reports first.
//===----------------------------------------------------------------------===//

public import PromIndex
public import PromLabels

/// Go: `tsdb.PostingsForMatchers`'s errors.
public enum PostingsForMatchersError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `errors.New("unexpected all postings")`. Unreachable from the top-level call, since the
    /// all-postings matcher is handled before the loop — but reachable if a caller passes it alongside
    /// others, so it is an error rather than an assertion.
    case unexpectedAllPostings

    public var description: String {
        switch self {
        case .unexpectedAllPostings: return "unexpected all postings"
        }
    }
}

/// The index operations `PostingsForMatchers` needs, as a protocol.
///
/// Go passes `tsdb.IndexReader`, a thirteen-method interface. Only these three are reached, so the port
/// narrows it — which is what lets `PostingsForMatchers` be tested against a block reader and, later, the
/// Head, without either having to implement methods it does not use.
public protocol PostingsIndex {
    /// Go: `ix.Postings(ctx, name, values...)`.
    func postings(name: String, values: [String]) throws -> any Postings
    /// Go: `ix.PostingsForLabelMatching(ctx, name, match)`. The closure is `@escaping` because an
    /// implementation may hand it to a traversal that outlives the call — which is exactly what the
    /// index reader's own `traversePostingOffsets` does.
    func postingsForLabelMatching(name: String, match: @escaping (String) -> Bool) throws
        -> any Postings
    /// Go: `ix.PostingsForAllLabelValues(ctx, name)`. A separate method rather than a nil predicate,
    /// because at this seam the nil-ness is the API rather than an implementation detail.
    func postingsForAllLabelValues(name: String) throws -> any Postings
}

/// Go: `PostingsForMatchers`.
public func postingsForMatchers(_ ix: any PostingsIndex, _ ms: [Matcher]) throws -> any Postings {
    // The all-postings matcher on its own, handled before anything else.
    if ms.count == 1 && ms[0].name.isEmpty && ms[0].value.isEmpty {
        let (k, v) = allPostingsKey()
        return try ix.postings(name: k, values: [v])
    }

    var its: [any Postings] = []
    var notIts: [any Postings] = []

    // Which label must be non-empty — a per-NAME fact. See the file header.
    var labelMustBeSet: [String: Bool] = [:]
    labelMustBeSet.reserveCapacity(ms.count)
    for m in ms where !m.matches("") {
        labelMustBeSet[m.name] = true
    }
    func isSubtractingMatcher(_ m: Matcher) -> Bool {
        if labelMustBeSet[m.name] != true {
            return true
        }
        return (m.type == .notEqual || m.type == .notRegexp) && m.matches("")
    }

    var hasSubtractingMatchers = false
    var hasIntersectingMatchers = false
    for m in ms {
        if isSubtractingMatcher(m) {
            hasSubtractingMatchers = true
        } else {
            hasIntersectingMatchers = true
        }
    }

    if hasSubtractingMatchers && !hasIntersectingMatchers {
        // Nothing to subtract from, so the base is everything — fetched up front for the reason
        // upstream's comment gives. See the file header.
        let (k, v) = allPostingsKey()
        its.append(try ix.postings(name: k, values: [v]))
    }

    // Intersecting matchers first. A STABLE PARTITION, not a comparator — quirk 156 and the file header.
    let sorted = ms.filter { !isSubtractingMatcher($0) } + ms.filter { isSubtractingMatcher($0) }

    for m in sorted {
        if m.name.isEmpty && m.value.isEmpty {
            // Handled at the top of the function; reaching it here means a caller mixed it with others.
            throw PostingsForMatchersError.unexpectedAllPostings
        }

        if m.type == .regexp && m.value == ".*" {
            // Matches any string, including the empty one: contributes NO constraint. Not the same as
            // intersecting with everything — see the file header.
            continue
        }
        if m.type == .notRegexp && m.value == ".*" {
            return emptyPostings()
        }
        if m.type == .regexp && m.value == ".+" {
            // Any non-empty string: every series that has the label.
            let it = try ix.postingsForAllLabelValues(name: m.name)
            if isEmptyPostingsType(it) {
                return emptyPostings()
            }
            its.append(it)
            continue
        }
        if m.type == .notRegexp && m.value == ".+" {
            notIts.append(try ix.postingsForAllLabelValues(name: m.name))
            continue
        }

        if labelMustBeSet[m.name] == true {
            // The label cannot be empty, so this can be smarter.
            let matchesEmpty = m.matches("")
            let isNot = m.type == .notEqual || m.type == .notRegexp
            if isNot && matchesEmpty {
                // `l!="foo"` — the inner matcher does not match empty, so subtract it at the end.
                let it = try postingsForMatcher(ix, m.inverse())
                notIts.append(it)
            } else if isNot && !matchesEmpty {
                // `l!=""` — the inner matcher CAN be empty, so the inverse has to be enumerated.
                let it = try inversePostingsForMatcher(ix, m.inverse())
                if isEmptyPostingsType(it) {
                    return emptyPostings()
                }
                its.append(it)
            } else {
                // `l="a"`, `l=~"a|b"`, `l=~"a.b"`, …
                let it = try postingsForMatcher(ix, m)
                if isEmptyPostingsType(it) {
                    return emptyPostings()
                }
                its.append(it)
            }
        } else {
            // `l=""` — selects the series that do NOT have the label set, so it is a subtraction of the
            // series that do. Upstream cites prometheus/prometheus#3575 here.
            notIts.append(try inversePostingsForMatcher(ix, m))
        }
    }

    var it = intersect(its)
    for n in notIts {
        it = without(it, n)
    }
    return it
}

/// Go: `postingsForMatcher` — the postings for series matching `m`, and **never for a missing label**.
///
/// The two fast paths are the reason a set-matching regex (`l=~"a|b"`) is as cheap as an equality: it
/// becomes a multi-value `Postings` lookup rather than a predicate walk. `setMatches` being empty is the
/// signal to fall back, which is why `FastRegexMatcher`'s set extraction is load-bearing rather than an
/// optimisation (PORTING.md exception 6 says the same from the other side).
func postingsForMatcher(_ ix: any PostingsIndex, _ m: Matcher) throws -> any Postings {
    if m.type == .equal {
        return try ix.postings(name: m.name, values: [m.value])
    }
    if m.type == .regexp {
        let setMatches = m.setMatches
        if !setMatches.isEmpty {
            return try ix.postings(name: m.name, values: setMatches)
        }
    }
    return try ix.postingsForLabelMatching(name: m.name, match: { m.matches($0) })
}

/// Go: `inversePostingsForMatcher` — series with the label name SET but not matching.
///
/// The two fast paths are double negations: the inverse of a `!~` is a `=~`, and of a `!=` an `=`. Note the
/// order — `MatchNotRegexp`'s set check comes first, and only then `MatchNotEqual`, so a `!~` whose pattern
/// happens to be a plain literal still goes through `setMatches`.
///
/// The `m.Value == ""` case matters more than it looks: inverting `=~""` or `=""` means "every value", so it
/// is `PostingsForAllLabelValues` rather than a predicate walk that would call the matcher once per value.
func inversePostingsForMatcher(_ ix: any PostingsIndex, _ m: Matcher) throws -> any Postings {
    if m.type == .notRegexp {
        let setMatches = m.setMatches
        if !setMatches.isEmpty {
            return try ix.postings(name: m.name, values: setMatches)
        }
    }
    if m.type == .notEqual {
        return try ix.postings(name: m.name, values: [m.value])
    }
    if m.value.isEmpty && (m.type == .regexp || m.type == .equal) {
        return try ix.postingsForAllLabelValues(name: m.name)
    }
    return try ix.postingsForLabelMatching(name: m.name, match: { !m.matches($0) })
}
