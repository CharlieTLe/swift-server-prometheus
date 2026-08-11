package main

// Differential coverage for `index.FindIntersectingPostings`.
//
// Exported, so the corpus reaches it directly: postings lists in, candidate indexes out. What makes it worth
// a suite of its own rather than a few cases inside another is that **the ORDER of the returned indexes is a
// heap's internal order**, and heap order is not derivable from the inputs by inspection. Three separate
// things decide it:
//
//   - `heap.Init` versus repeated pushes — `Init` sifts DOWN from the last internal node backwards, pushes
//     sift UP from the end, and the two give differently ordered valid heaps.
//   - `Less`'s popped-to-the-bottom rule, which is how the "pop" that never removes anything works.
//   - the loop's asymmetric branches: a match pops, an overshoot advances the root only.
//
// So the cases are built to make order observable: candidates that share values, candidates that tie on
// their first value, candidates whose first values are already in heap order and candidates whose are exactly
// reversed. A port that used `Push` in a loop, or sorted instead of heaping, agrees on the SET every time and
// on the ORDER almost never.
//
// Also covered: candidates that are empty (dropped before `Init`, so they never get an index), the
// all-candidates-empty case that returns nil before heaping, and a query list shorter than every candidate.

import (
	"fmt"

	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/index"
)

type findIntersectingIn struct {
	// The query postings — `p` in upstream's signature.
	Query []uint64 `json:"query"`
	// One entry per candidate list.
	Candidates [][]uint64 `json:"candidates"`
}

type findIntersectingOut struct {
	// The candidate indexes, **in the order returned** — which is the heap's order, not sorted.
	Indexes []int  `json:"indexes"`
	Err     string `json:"err"`
}

func refsOf(vs []uint64) []storage.SeriesRef {
	out := make([]storage.SeriesRef, 0, len(vs))
	for _, v := range vs {
		out = append(out, storage.SeriesRef(v))
	}
	return out
}

func genFindIntersecting(e *emitter) {
	n := 0
	emit := func(in findIntersectingIn) {
		out := findIntersectingOut{Indexes: []int{}}

		cands := make([]index.Postings, 0, len(in.Candidates))
		for _, c := range in.Candidates {
			cands = append(cands, index.NewListPostings(refsOf(c)))
		}
		idxs, err := index.FindIntersectingPostings(
			index.NewListPostings(refsOf(in.Query)), cands)
		if err != nil {
			out.Err = err.Error()
		}
		if idxs != nil {
			out.Indexes = idxs
		}
		e.emit(fmt.Sprintf("findintersecting/%d", n), in, out)
		n++
	}

	// The basics: one candidate, hitting and missing.
	emit(findIntersectingIn{Query: []uint64{1, 2, 3}, Candidates: [][]uint64{{2}}})
	emit(findIntersectingIn{Query: []uint64{1, 2, 3}, Candidates: [][]uint64{{9}}})
	emit(findIntersectingIn{Query: []uint64{}, Candidates: [][]uint64{{1}}})
	emit(findIntersectingIn{Query: []uint64{1}, Candidates: [][]uint64{}})
	// Every candidate empty: returns before `heap.Init` runs at all.
	emit(findIntersectingIn{Query: []uint64{1, 2}, Candidates: [][]uint64{{}, {}}})
	// Some empty, some not — the empty ones are dropped before `Init`, so they never get an index and the
	// indexes that DO come back are not a contiguous range.
	emit(findIntersectingIn{Query: []uint64{1, 2, 3}, Candidates: [][]uint64{{}, {2}, {}, {3}}})

	// ORDER. The first values are already ascending, so `Init` has little to do.
	emit(findIntersectingIn{
		Query:      []uint64{1, 2, 3, 4, 5, 6, 7, 8},
		Candidates: [][]uint64{{1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}},
	})
	// The first values are exactly REVERSED, which is the case `Init` and repeated-push disagree on most.
	emit(findIntersectingIn{
		Query:      []uint64{1, 2, 3, 4, 5, 6, 7, 8},
		Candidates: [][]uint64{{8}, {7}, {6}, {5}, {4}, {3}, {2}, {1}},
	})
	// TIES on the first value: `Less` falls through to `At()`, which is equal, so the tie-break is the
	// heap's swap order and nothing else.
	emit(findIntersectingIn{
		Query:      []uint64{5},
		Candidates: [][]uint64{{5}, {5}, {5}, {5}, {5}},
	})
	emit(findIntersectingIn{
		Query:      []uint64{5, 6},
		Candidates: [][]uint64{{5, 6}, {5}, {6}, {5, 6}, {6, 5}},
	})
	// Shared values across candidates, so several pop at the same query position.
	emit(findIntersectingIn{
		Query:      []uint64{2, 4, 6, 8},
		Candidates: [][]uint64{{2, 4}, {4, 6}, {6, 8}, {1, 3}, {2, 8}},
	})
	// A candidate whose values are all BELOW the query's first: `seekHead` advances it repeatedly and only
	// then pops it, which is the branch that does not pop immediately.
	emit(findIntersectingIn{
		Query:      []uint64{100},
		Candidates: [][]uint64{{1, 2, 3, 4, 5}, {100}, {1, 100}},
	})
	// A candidate whose values are all ABOVE: the query exhausts first, taking the early return that keeps
	// the partial result.
	emit(findIntersectingIn{
		Query:      []uint64{1, 2},
		Candidates: [][]uint64{{1}, {500}, {600}},
	})
	// The query overshoots repeatedly, so both branches alternate.
	emit(findIntersectingIn{
		Query:      []uint64{10, 20, 30, 40},
		Candidates: [][]uint64{{5, 10}, {15, 20}, {25, 30}, {35, 40}, {45, 50}},
	})

	// Sizes around the heap's shape changes: 1, 2, 3 are the degenerate trees, 7 and 8 the first full and
	// first-overflowing ones, 15 and 16 the next.
	for _, count := range []int{1, 2, 3, 7, 8, 15, 16, 33} {
		cands := make([][]uint64, 0, count)
		for i := range count {
			// Descending first values, so `Init` does real work at every size.
			cands = append(cands, []uint64{uint64(count - i)})
		}
		q := make([]uint64, 0, count)
		for i := range count {
			q = append(q, uint64(i+1))
		}
		emit(findIntersectingIn{Query: q, Candidates: cands})
		// The same candidates against a query that hits only half of them.
		half := make([]uint64, 0, count/2+1)
		for i := 0; i <= count/2; i++ {
			half = append(half, uint64(i*2+1))
		}
		emit(findIntersectingIn{Query: half, Candidates: cands})
	}

	// **The cases that actually distinguish `heap.Init` from repeated `Push`.**
	//
	// These were not written by inspection — a first version of this suite pinned the set and the order in
	// 32 cases and a control that replaced `Init` with a push loop SURVIVED all of them. The three below
	// came out of a brute-force search over small random inputs, and each returns a DIFFERENT ORDER under
	// the two constructions:
	//
	//     query [1 4 5 8], candidates [[1 3 5 7] [6 7] [0] [0 4] [1 2 5 6] [4]]  init [0 4 3 5]  push [4 0 3 5]
	//     query [1 3 6 7], candidates [[3] [2 5 8] [0 1 2 8] [3 4]]              init [2 3 0]    push [2 0 3]
	//     query [4 5 6],   candidates [[7] [3 7 8] [1 4 6] [1 2 5 8] [1] [2 4 6 7]] init [5 2 3] push [2 5 3]
	//
	// The shape they share: several candidates TIE on their first value, so the initial layout decides which
	// of them the heap sees first, and the query then pops them in that order. Ties in `At()` make `Less`
	// return false both ways, so no swap resolves them — the layout is the only tie-break there is.
	emit(findIntersectingIn{
		Query:      []uint64{1, 4, 5, 8},
		Candidates: [][]uint64{{1, 3, 5, 7}, {6, 7}, {0}, {0, 4}, {1, 2, 5, 6}, {4}},
	})
	emit(findIntersectingIn{
		Query:      []uint64{1, 3, 6, 7},
		Candidates: [][]uint64{{3}, {2, 5, 8}, {0, 1, 2, 8}, {3, 4}},
	})
	emit(findIntersectingIn{
		Query:      []uint64{4, 5, 6},
		Candidates: [][]uint64{{7}, {3, 7, 8}, {1, 4, 6}, {1, 2, 5, 8}, {1}, {2, 4, 6, 7}},
	})
	// The same shape, deliberately: pairs of candidates tying on their first value at several heap sizes.
	for _, count := range []int{4, 5, 6, 7, 9, 12} {
		cands := make([][]uint64, 0, count)
		for i := range count {
			// Tie every adjacent pair on the first value, then differ afterwards.
			cands = append(cands, []uint64{uint64(i/2 + 1), uint64(20 + i)})
		}
		q := []uint64{}
		for i := 1; i <= count/2+1; i++ {
			q = append(q, uint64(i))
		}
		for i := range count {
			q = append(q, uint64(20+i))
		}
		emit(findIntersectingIn{Query: q, Candidates: cands})
	}

	// Large refs, so nothing depends on small integers.
	emit(findIntersectingIn{
		Query: []uint64{1 << 40, 1 << 41, 1 << 62},
		Candidates: [][]uint64{
			{1 << 41}, {1 << 62}, {1 << 40, 1 << 62}, {(1 << 62) + 1},
		},
	})
	// Zero as a ref, which is also `ListPostings`'s reset value — so a port that treats 0 as "unset"
	// diverges here.
	emit(findIntersectingIn{Query: []uint64{0, 1}, Candidates: [][]uint64{{0}, {1}, {0, 1}}})
}
