//===----------------------------------------------------------------------===//
// Ported from tsdb/tombstones/tombstones.go @ v3.13.2 — the INTERVAL ARITHMETIC only.
//
// **The file reader is deliberately not ported (exception 16); this type is, because the querier needs it
// even when there are no tombstones at all.** `blockBaseSeriesSet.Next` trims a series to the requested time
// range by *adding deletion intervals* — `[MinInt64, mint-1]` at the front and `[maxt+1, MaxInt64]` at the
// back — and then hands them to the same code a real tombstone would drive. So `Intervals.Add` is on the hot
// path of every range query against a block, tombstones or not.
//
// ## `Add` merges ADJACENT intervals, not just overlapping ones
//
// The comment says why: "Intervals are closed [t1, t2] and t is discrete, so if neighbour intervals are 1
// step difference to the new one, we can merge those together." Hence `Maxt >= n.Mint-1` rather than `>=
// n.Mint`, and `Mint > n.Maxt+1` rather than `> n.Maxt`. `[1,5]` and `[6,9]` become `[1,9]`.
//
// ## The two overflow guards are the reason the trimming case works at all
//
// `if n.Mint != math.MinInt64` and `if n.Maxt != math.MaxInt64` skip the binary search entirely, because
// `n.Mint-1` and `n.Maxt+1` would overflow — and those are EXACTLY the intervals the querier adds when
// trimming. So the guards are not defensive edge-case handling, they are the common path:
//
//     trimFront → Add(Interval{MinInt64, mint-1})   → `mini` stays 0, no search
//     trimBack  → Add(Interval{maxt+1, MaxInt64})   → `maxi` stays len(in), no search
//
// A port that "simplified" them by clamping instead of skipping would compute a different `mini`/`maxi` on
// every trimmed query. In Swift `n.Mint - 1` on `Int64.min` **traps** rather than wrapping, so the guard is
// load-bearing twice over.
//
// ## The two binary searches are not symmetric
//
// The first searches all of `in` and returns an index into it. The second searches `in[mini:]` — a
// *suffix* — and returns an index relative to that, which is why every later use is `maxi + mini`. Reading
// `maxi` as an absolute index is the mistake this shape invites, and the `maxi == 0` early return is what
// makes it look absolute (it means "the new interval sits entirely before `in[mini]`").
//
// ## `Add` mutates the receiver's storage in Go and returns a new slice
//
// `in[mini].Mint = n.Mint` writes through the slice, then `append(in[:mini+1], in[maxi+mini:]...)` compacts
// in place. Callers always use the return value, so the port takes `self` by value and returns — the
// aliasing is Go's allocation strategy, not a contract. See PORTING.md's `sync.Pool` exception for the same
// reasoning applied elsewhere.
//===----------------------------------------------------------------------===//

internal import GoCompat

/// Go: `tombstones.Interval` — one closed time range.
public struct DeletionInterval: Sendable, Equatable, Hashable {
    public var mint: Int64
    public var maxt: Int64

    public init(mint: Int64, maxt: Int64) {
        self.mint = mint
        self.maxt = maxt
    }

    /// Go: `InBounds` — closed at both ends.
    public func inBounds(_ t: Int64) -> Bool {
        t >= mint && t <= maxt
    }

    /// Go: `IsSubrange` — is this interval contained in ANY ONE of `dranges`?
    ///
    /// Not "covered by their union": a range spanning two adjacent intervals is **not** a subrange, because
    /// the loop tests each interval separately. That is only sound because `Intervals` is maintained merged
    /// by `Add`, which is what makes adjacency-merging load-bearing rather than cosmetic.
    public func isSubrange(_ dranges: [DeletionInterval]) -> Bool {
        for r in dranges where r.inBounds(mint) && r.inBounds(maxt) {
            return true
        }
        return false
    }
}

extension Array where Element == DeletionInterval {
    /// Go: `Intervals.Add` — insert a range, merging anything overlapping or ADJACENT.
    ///
    /// The receiver must already be sorted and non-overlapping, which is `Intervals`' documented invariant
    /// and which this maintains.
    public func addingInterval(_ n: DeletionInterval) -> [DeletionInterval] {
        var `in` = self
        if `in`.isEmpty {
            return [n]
        }

        // The lower bound. `Maxt >= n.Mint - 1`, so an interval ENDING one step before `n` merges.
        var mini = 0
        if n.mint != Int64.min {  // Avoid overflow — and in Swift, avoid a TRAP. See the file header.
            mini = goSearch(`in`.count) { `in`[$0].maxt >= n.mint - 1 }
            if mini == `in`.count {
                return `in` + [n]
            }
        }

        // The upper bound, searched over the SUFFIX `in[mini...]` — so it is relative, not absolute.
        var maxi = `in`.count
        if n.maxt != Int64.max {
            maxi = goSearch(`in`.count - mini) { `in`[mini + $0].mint > n.maxt + 1 }
            if maxi == 0 {
                // `n` sits entirely before `in[mini]`, adjacent to nothing.
                if mini == 0 {
                    return [n] + `in`
                }
                return Array(`in`[0..<mini]) + [n] + Array(`in`[mini...])
            }
        }

        if n.mint < `in`[mini].mint {
            `in`[mini].mint = n.mint
        }
        `in`[mini].maxt = Swift.max(n.maxt, `in`[maxi + mini - 1].maxt)
        return Array(`in`[0...mini]) + Array(`in`[(maxi + mini)...])
    }
}

/// Go: `sort.Search` — the smallest `i` in `[0, n)` for which `f(i)` is true, or `n`.
///
/// Ported rather than expressed as a `partitioningIndex`-style helper because the two binary searches above
/// depend on its exact boundary behaviour, and because `f` here is not monotone-by-construction — it is
/// monotone only given `Intervals`' sortedness invariant, so a different search could disagree on inputs that
/// violate it.
func goSearch(_ n: Int, _ f: (Int) -> Bool) -> Int {
    var i = 0
    var j = n
    while i < j {
        let h = Int(UInt(i + j) >> 1)
        if !f(h) {
            i = h + 1
        } else {
            j = h
        }
    }
    return i
}
