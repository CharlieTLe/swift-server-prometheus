package main

// Differential coverage for `tombstones.Intervals.Add` and `Interval.IsSubrange`.
//
// Exported, so the corpus drives them directly. They are here even though the tombstone FILE reader is
// deliberately unported (PORTING.md exception 16), because **the querier needs this arithmetic when there are
// no tombstones at all**: `blockBaseSeriesSet.Next` trims a series to the requested range by adding
// `[MinInt64, mint-1]` and `[maxt+1, MaxInt64]` as deletion intervals. So `Add` is on the hot path of every
// range query against a block.
//
// What has to be reached:
//
//   - ADJACENCY merging, not just overlap: `[1,5]` + `[6,9]` is `[1,9]`, because the bounds are `Maxt >=
//     n.Mint-1` and `Mint > n.Maxt+1`. Off-by-one either way changes the shape of the result.
//   - the two OVERFLOW GUARDS, which skip the binary search when `n.Mint == MinInt64` or `n.Maxt == MaxInt64`
//     — and those are exactly the intervals trimming adds, so the guards are the common path, not an edge
//     case. In Swift `MinInt64 - 1` traps rather than wrapping, so a missing guard is a crash.
//   - the ASYMMETRIC searches: the first is over all of `in`, the second over the suffix `in[mini:]`, so
//     `maxi` is relative and every use is `maxi + mini`. Cases where `mini > 0` are what distinguish a port
//     that treats it as absolute.
//   - `maxi == 0`'s two sub-cases (`mini == 0` and not), which insert rather than merge.
//   - `IsSubrange`'s per-interval test: a range spanning two ADJACENT intervals is NOT a subrange, which is
//     only sound because `Add` keeps the set merged.
//
// Sequences rather than single calls: `Add` mutates and returns, and its invariant is that the result stays
// sorted and non-overlapping. A single call cannot show that the invariant survives, so each case applies a
// whole sequence and records the state after every step.

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/tsdb/tombstones"
)

type intervalsIn struct {
	// Applied in order; the output records the state after each.
	Adds [][2]int64 `json:"adds"`
	// `IsSubrange` probes, run against the FINAL state.
	Probes [][2]int64 `json:"probes"`
}

type intervalsOut struct {
	// The full interval set after each `Add`, flattened as [mint, maxt] pairs.
	States [][][2]int64 `json:"states"`
	// One per probe.
	Subrange []bool `json:"subrange"`
	// `InBounds` of each probe's mint against the final set's first interval, so the primitive underneath
	// `IsSubrange` is pinned separately from the loop over it.
	InBoundsFirst []bool `json:"inBoundsFirst"`
}

func flattenIntervals(in tombstones.Intervals) [][2]int64 {
	out := [][2]int64{}
	for _, r := range in {
		out = append(out, [2]int64{r.Mint, r.Maxt})
	}
	return out
}

func genTombstoneIntervals(e *emitter) {
	n := 0
	emit := func(in intervalsIn) {
		out := intervalsOut{States: [][][2]int64{}, Subrange: []bool{}, InBoundsFirst: []bool{}}
		var cur tombstones.Intervals
		for _, a := range in.Adds {
			cur = cur.Add(tombstones.Interval{Mint: a[0], Maxt: a[1]})
			out.States = append(out.States, flattenIntervals(cur))
		}
		for _, p := range in.Probes {
			iv := tombstones.Interval{Mint: p[0], Maxt: p[1]}
			out.Subrange = append(out.Subrange, iv.IsSubrange(cur))
			if len(cur) > 0 {
				out.InBoundsFirst = append(out.InBoundsFirst, cur[0].InBounds(p[0]))
			} else {
				out.InBoundsFirst = append(out.InBoundsFirst, false)
			}
		}
		e.emit(fmt.Sprintf("tsintervals/%d", n), in, out)
		n++
	}

	iv := func(a, b int64) [2]int64 { return [2]int64{a, b} }
	minI := int64(math.MinInt64)
	maxI := int64(math.MaxInt64)

	// The empty receiver, and a single interval.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 5)}, Probes: [][2]int64{
		iv(1, 5), iv(2, 4), iv(1, 1), iv(5, 5), iv(0, 5), iv(1, 6), iv(6, 7),
	}})

	// Disjoint, in order and out of order — the second exercises insertion before an existing interval.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(10, 12), iv(20, 22)}})
	emit(intervalsIn{Adds: [][2]int64{iv(20, 22), iv(10, 12), iv(1, 2)}})
	emit(intervalsIn{Adds: [][2]int64{iv(10, 12), iv(1, 2), iv(20, 22), iv(15, 16)}})

	// ADJACENCY. Each of these merges even though the ranges do not overlap.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 5), iv(6, 9)}})
	emit(intervalsIn{Adds: [][2]int64{iv(6, 9), iv(1, 5)}})
	// One step further apart: must NOT merge.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 5), iv(7, 9)}})
	emit(intervalsIn{Adds: [][2]int64{iv(7, 9), iv(1, 5)}})
	// Filling a one-element gap merges all three.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 5), iv(7, 9), iv(6, 6)}})
	// Bridging a wider gap.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(10, 12), iv(3, 9)}})
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(10, 12), iv(4, 8)}})

	// Overlaps of every shape.
	emit(intervalsIn{Adds: [][2]int64{iv(5, 10), iv(1, 7)}})
	emit(intervalsIn{Adds: [][2]int64{iv(5, 10), iv(7, 15)}})
	emit(intervalsIn{Adds: [][2]int64{iv(5, 10), iv(1, 15)}})
	emit(intervalsIn{Adds: [][2]int64{iv(5, 10), iv(6, 7)}})
	emit(intervalsIn{Adds: [][2]int64{iv(5, 10), iv(5, 10)}})
	// Swallowing SEVERAL at once, which is where `maxi + mini` matters.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(5, 6), iv(9, 10), iv(13, 14), iv(0, 20)}})
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(5, 6), iv(9, 10), iv(13, 14), iv(5, 10)}})
	// `mini > 0` AND several swallowed: the case a port reading `maxi` as absolute gets wrong.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(5, 6), iv(9, 10), iv(13, 14), iv(6, 13)}})
	emit(intervalsIn{Adds: [][2]int64{
		iv(1, 2), iv(5, 6), iv(9, 10), iv(13, 14), iv(17, 18), iv(6, 14),
	}})

	// THE OVERFLOW GUARDS — and these are the querier's trimming intervals, not exotica.
	emit(intervalsIn{Adds: [][2]int64{iv(minI, 99)}})
	emit(intervalsIn{Adds: [][2]int64{iv(101, maxI)}})
	emit(intervalsIn{Adds: [][2]int64{iv(minI, 99), iv(101, maxI)}})
	// Exactly the pair `blockBaseSeriesSet` adds when trimming to [100, 200].
	emit(intervalsIn{Adds: [][2]int64{iv(minI, 99), iv(201, maxI)}, Probes: [][2]int64{
		iv(0, 50), iv(50, 150), iv(150, 250), iv(250, 300), iv(100, 200),
	}})
	// Trimming on top of an existing deletion, in both orders.
	emit(intervalsIn{Adds: [][2]int64{iv(120, 130), iv(minI, 99), iv(201, maxI)}})
	emit(intervalsIn{Adds: [][2]int64{iv(minI, 99), iv(120, 130), iv(201, maxI)}})
	// A trim interval ADJACENT to an existing one, so it merges across the guard's skipped search.
	emit(intervalsIn{Adds: [][2]int64{iv(100, 130), iv(minI, 99)}})
	emit(intervalsIn{Adds: [][2]int64{iv(100, 130), iv(131, maxI)}})
	emit(intervalsIn{Adds: [][2]int64{iv(minI, maxI)}})
	emit(intervalsIn{Adds: [][2]int64{iv(1, 2), iv(minI, maxI)}})
	emit(intervalsIn{Adds: [][2]int64{iv(minI, maxI), iv(1, 2)}})

	// Negative and zero bounds, which the querier reaches for pre-epoch timestamps.
	emit(intervalsIn{Adds: [][2]int64{iv(-10, -5), iv(-4, 0), iv(1, 5)}})
	emit(intervalsIn{Adds: [][2]int64{iv(0, 0)}, Probes: [][2]int64{iv(0, 0), iv(-1, 0), iv(0, 1)}})
	emit(intervalsIn{Adds: [][2]int64{iv(-1, -1), iv(1, 1)}, Probes: [][2]int64{iv(0, 0), iv(-1, 1)}})

	// `IsSubrange` spanning two ADJACENT-but-separate intervals: NOT a subrange, because the test is per
	// interval. Only reachable if `Add` left them separate, which is why this pairs with the no-merge cases.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 5), iv(7, 9)}, Probes: [][2]int64{
		iv(1, 9), iv(4, 8), iv(1, 5), iv(7, 9), iv(6, 6), iv(2, 3), iv(8, 8),
	}})
	// An empty set: every probe is false.
	emit(intervalsIn{Probes: [][2]int64{iv(1, 2), iv(0, 0)}})
	// A probe whose mint > maxt — inverted, which upstream neither rejects nor documents.
	emit(intervalsIn{Adds: [][2]int64{iv(1, 10)}, Probes: [][2]int64{iv(5, 3), iv(10, 1)}})

	// Many intervals, so the binary searches do real work.
	{
		adds := [][2]int64{}
		for i := range 40 {
			adds = append(adds, iv(int64(i)*10, int64(i)*10+3))
		}
		// Then merge across the middle of them.
		adds = append(adds, iv(95, 205))
		emit(intervalsIn{Adds: adds, Probes: [][2]int64{
			iv(0, 3), iv(100, 200), iv(95, 205), iv(4, 9), iv(390, 393),
		}})
	}
}
