package main

// Differential coverage for tsdb/index's postings algebra — Intersect, Merge, Without and the leaf
// iterators, plus the loser tree Merge is built on.
//
// Everything here is EXPORTED, so unlike bstream/varbit this needs no chunk to reach it: the oracle
// calls `index.Intersect` and friends directly. That makes it the first Phase 6 slice that is pinnable
// on its own.
//
// A case is a small expression tree over ordered series-ref lists, driven by a SCRIPT of iterator
// operations rather than just expanded. Expanding only would miss most of the contract: `Seek` is
// idempotent, may not move, and is called repeatedly with unchanged targets by `Intersect`, so the
// interesting behaviour is in interleaved Next/Seek sequences.
//
// What has to be reached:
//   - `Seek` returning true WITHOUT advancing, on every implementation;
//   - `Seek` past the end, and `Seek` to a value below the current position;
//   - `Intersect`'s `Next`, which advances every input before seeking, versus its `Seek`;
//   - `Merge`'s de-duplication, and its `Seek` which advances the loser-tree WINNER directly;
//   - equal values across several merge inputs, which is where the loser tree's tie-breaking shows;
//   - `Without`'s `Seek`, which recurses through its own `Next`;
//   - the empty SENTINEL short-circuits in `Intersect` and `Without`;
//   - error propagation from a leaf through each operator.

import (
	"context"
	"errors"
	"fmt"

	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/index"
)

// A postings expression: a leaf list, or an operator over sub-expressions.
type postingsExpr struct {
	// "list", "empty", "err", "intersect", "merge", "without"
	Op   string          `json:"op"`
	List []uint64        `json:"list,omitempty"`
	Subs []*postingsExpr `json:"subs,omitempty"`
}

// One iterator operation.
type postingsOp struct {
	// "next" or "seek"
	Op string `json:"op"`
	V  uint64 `json:"v"`
}

type postingsIn struct {
	Expr *postingsExpr `json:"expr"`
	Ops  []postingsOp  `json:"ops"`
}

type postingsStep struct {
	OK bool   `json:"ok"`
	At uint64 `json:"at"`
}

type postingsOut struct {
	Steps []postingsStep `json:"steps"`
	Err   string         `json:"err"`
	// A second, independent run that just drains the iterator, so `ExpandPostings` is pinned too.
	Expanded []uint64 `json:"expanded"`
	ExpandOK bool     `json:"expandOK"`
	// Whether the built value IS the empty sentinel, which drives the short-circuits.
	IsEmptySentinel bool `json:"isEmptySentinel"`
}

var errTestPostings = errors.New("test postings failure")

func buildPostings(e *postingsExpr) index.Postings {
	switch e.Op {
	case "list":
		refs := make([]storage.SeriesRef, 0, len(e.List))
		for _, v := range e.List {
			refs = append(refs, storage.SeriesRef(v))
		}
		return index.NewListPostings(refs)
	case "empty":
		return index.EmptyPostings()
	case "err":
		return index.ErrPostings(errTestPostings)
	case "intersect":
		subs := make([]index.Postings, 0, len(e.Subs))
		for _, s := range e.Subs {
			subs = append(subs, buildPostings(s))
		}
		return index.Intersect(subs...)
	case "merge":
		subs := make([]index.Postings, 0, len(e.Subs))
		for _, s := range e.Subs {
			subs = append(subs, buildPostings(s))
		}
		return index.Merge(context.Background(), subs...)
	case "without":
		return index.Without(buildPostings(e.Subs[0]), buildPostings(e.Subs[1]))
	}
	panic("unknown op " + e.Op)
}

func genIndexPostings(e *emitter) {
	n := 0
	emit := func(expr *postingsExpr, ops []postingsOp) {
		in := postingsIn{Expr: expr, Ops: ops}
		out := postingsOut{Steps: []postingsStep{}, Expanded: []uint64{}}

		p := buildPostings(expr)
		out.IsEmptySentinel = index.IsEmptyPostingsType(p)
		for _, op := range ops {
			var ok bool
			if op.Op == "next" {
				ok = p.Next()
			} else {
				ok = p.Seek(storage.SeriesRef(op.V))
			}
			step := postingsStep{OK: ok}
			if ok {
				step.At = uint64(p.At())
			}
			out.Steps = append(out.Steps, step)
		}
		if err := p.Err(); err != nil {
			out.Err = err.Error()
		}

		// A fresh build, drained, so ExpandPostings is pinned independently of the script.
		p2 := buildPostings(expr)
		refs, err := index.ExpandPostings(p2)
		if err == nil {
			out.ExpandOK = true
			for _, r := range refs {
				out.Expanded = append(out.Expanded, uint64(r))
			}
		}

		e.emit(fmt.Sprintf("postings/%d", n), in, out)
		n++
	}

	list := func(vs ...uint64) *postingsExpr { return &postingsExpr{Op: "list", List: vs} }
	empty := func() *postingsExpr { return &postingsExpr{Op: "empty"} }
	errp := func() *postingsExpr { return &postingsExpr{Op: "err"} }
	isect := func(subs ...*postingsExpr) *postingsExpr {
		return &postingsExpr{Op: "intersect", Subs: subs}
	}
	mrg := func(subs ...*postingsExpr) *postingsExpr {
		return &postingsExpr{Op: "merge", Subs: subs}
	}
	wo := func(a, b *postingsExpr) *postingsExpr {
		return &postingsExpr{Op: "without", Subs: []*postingsExpr{a, b}}
	}

	next := func(k int) []postingsOp {
		ops := make([]postingsOp, k)
		for i := range ops {
			ops[i] = postingsOp{Op: "next"}
		}
		return ops
	}
	seek := func(v uint64) postingsOp { return postingsOp{Op: "seek", V: v} }

	// --- Leaves.
	emit(list(), next(2))
	emit(list(1), next(3))
	emit(list(1, 2, 3), next(5))
	emit(empty(), next(2))
	emit(errp(), next(2))
	// Seek semantics on a plain list: idempotent, backwards, past the end.
	emit(list(1, 3, 5, 7, 9), []postingsOp{seek(5), seek(5), seek(3), seek(6), seek(9), seek(10)})
	emit(list(1, 3, 5, 7, 9), []postingsOp{seek(0), {Op: "next"}, seek(1), seek(100)})
	emit(list(1, 3, 5, 7, 9), []postingsOp{{Op: "next"}, seek(1), seek(2), {Op: "next"}})
	emit(list(2, 4, 6), []postingsOp{seek(7), {Op: "next"}, seek(1)})
	// `listPostings.Next` resets `cur` to 0 on exhaustion, and that is observable only through a
	// BACKWARDS seek afterwards: with the reset, `cur >= x` is false and the exhausted iterator stays
	// exhausted; without it, `cur` still holds the last value and the seek reports it again. A control
	// survived until these existed.
	emit(list(1, 2), []postingsOp{{Op: "next"}, {Op: "next"}, {Op: "next"}, seek(1)})
	emit(list(1, 2), []postingsOp{{Op: "next"}, {Op: "next"}, {Op: "next"}, seek(2), seek(0)})
	emit(list(5), []postingsOp{{Op: "next"}, {Op: "next"}, seek(5), seek(1)})
	emit(list(1, 2, 3), append(next(4), seek(2), seek(3), seek(4)))

	// A long list, so the binary search in Seek is exercised rather than the next-item check.
	{
		var vs []uint64
		for i := range 200 {
			vs = append(vs, uint64(i*3+1))
		}
		emit(list(vs...), []postingsOp{seek(1), seek(300), seek(301), seek(302), seek(600), seek(1000)})
	}

	// --- Intersect.
	emit(isect(), next(2))
	emit(isect(list(1, 2, 3)), next(4))
	emit(isect(list(1, 2, 3), empty()), next(2))
	emit(isect(empty(), list(1, 2, 3)), next(2))
	emit(isect(list(1, 2, 3), list(2, 3, 4)), next(4))
	emit(isect(list(1, 2, 3), list(4, 5, 6)), next(2))
	emit(isect(list(1, 5, 9), list(1, 5, 9), list(1, 5, 9)), next(5))
	// Staggered, so Next's "advance all then seek" path runs rather than the all-equal one.
	emit(isect(list(1, 10, 20), list(5, 10, 15, 20)), next(4))
	emit(isect(list(1, 2, 3, 4, 5), list(5)), next(3))
	emit(isect(list(5), list(1, 2, 3, 4, 5)), next(3))
	// Three-way where the highest target comes from the LAST input, which is what Next's
	// keep-scanning-after-mismatch buys.
	emit(isect(list(1, 100), list(1, 50, 100), list(1, 100)), next(4))
	emit(isect(list(1, 2, 100), list(2, 100), list(100)), next(3))
	emit(isect(list(1, 3, 5), list(1, 3, 5)), []postingsOp{seek(3), seek(3), seek(4), seek(5), seek(6)})
	emit(isect(list(1, 3, 5), list(2, 3, 6)), []postingsOp{seek(1), seek(3), {Op: "next"}})
	emit(isect(list(1, 2), errp()), next(2))
	emit(isect(errp(), list(1, 2)), next(2))

	// --- Merge, and the loser tree under it.
	emit(mrg(), next(2))
	emit(mrg(list(1, 2, 3)), next(4))
	emit(mrg(list(1, 3), list(2, 4)), next(6))
	emit(mrg(list(1, 2, 3), list(1, 2, 3)), next(5))
	emit(mrg(list(1), list(1), list(1), list(1)), next(3))
	emit(mrg(list(), list(), list()), next(2))
	emit(mrg(list(), list(1, 2), list()), next(4))
	// Many inputs, so the tree has internal levels.
	emit(mrg(list(1, 9), list(2, 8), list(3, 7), list(4, 6), list(5)), next(11))
	// Duplicates spread across inputs, which is where de-duplication and tie-breaking meet.
	emit(mrg(list(1, 2, 3), list(2, 3, 4), list(3, 4, 5)), next(7))
	emit(mrg(list(5, 6), list(1, 2), list(3, 4)), next(7))
	// Merge's Seek advances the loser-tree WINNER directly, so it needs its own coverage.
	emit(mrg(list(1, 5, 9), list(2, 6, 10)), []postingsOp{seek(5), seek(5), seek(6), seek(11)})
	emit(mrg(list(1, 5, 9), list(2, 6, 10)), []postingsOp{seek(0), {Op: "next"}, seek(9), {Op: "next"}, {Op: "next"}})
	emit(mrg(list(1, 2), list(3, 4)), []postingsOp{seek(100), {Op: "next"}})
	emit(mrg(list(1, 2), empty()), next(4))
	emit(mrg(list(1, 2), errp()), next(4))
	emit(mrg(errp(), errp()), next(2))

	// LARGE series refs, which is what makes the loser tree's `maxVal` load-bearing. Every ref above is
	// under 1000, so a control that replaced `SeriesRef(MaxUint64)` with 1000 still dominated them all
	// and survived. An exhausted sequence is given `maxVal` so it always loses; a real ref at or above
	// it sorts as exhausted and vanishes from the merge.
	emit(mrg(list(1, 1<<20), list(2, 1<<40)), next(6))
	emit(mrg(list(1<<62, 1<<63), list(1<<61)), next(5))
	emit(mrg(list(0xFFFFFFFFFFFFFFFE), list(1)), next(4))
	emit(mrg(list(1000, 2000), list(1500)), next(5))
	emit(isect(list(1<<40, 1<<50), list(1<<40, 1<<50)), next(4))
	emit(wo(list(1<<40, 1<<50), list(1<<40)), next(3))

	// --- Without.
	emit(wo(list(1, 2, 3), list(2)), next(4))
	emit(wo(list(1, 2, 3), empty()), next(4))
	emit(wo(empty(), list(1, 2, 3)), next(2))
	emit(wo(list(1, 2, 3), list(1, 2, 3)), next(2))
	emit(wo(list(1, 2, 3), list(4, 5)), next(4))
	emit(wo(list(1, 2, 3, 4, 5), list(2, 4)), next(5))
	emit(wo(list(2, 4), list(1, 2, 3, 4, 5)), next(3))
	// Without's Seek recurses through its own Next, so a seek landing ON a removed value is the case.
	emit(wo(list(1, 2, 3, 4, 5), list(3)), []postingsOp{seek(3), seek(3), seek(1), seek(5), seek(6)})
	emit(wo(list(1, 2, 3, 4, 5), list(2, 3, 4)), []postingsOp{seek(2), {Op: "next"}, seek(4)})
	emit(wo(list(1, 2), errp()), next(3))
	emit(wo(errp(), list(1, 2)), next(3))

	// --- Nested, which is what a real query compiles to.
	emit(wo(mrg(list(1, 2, 3), list(4, 5)), list(2, 4)), next(6))
	emit(isect(mrg(list(1, 2), list(3, 4)), list(2, 3)), next(4))
	emit(mrg(isect(list(1, 2, 3), list(2, 3)), wo(list(4, 5), list(5))), next(5))
	emit(isect(wo(list(1, 2, 3), list(2)), mrg(list(1), list(3))), next(4))
	emit(isect(mrg(list(1, 2), empty()), wo(list(2, 3), empty())), next(3))
}
