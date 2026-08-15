package main

// Differential coverage for `index.MemPostings` — the Head's in-memory inverted index.
//
// ## The shape
//
// A program of `add` / `delete` / `ensureOrder` operations against one `MemPostings`, then every reader is
// called and its answer committed. Everything here is exported upstream, so the oracle drives the real type
// directly — no Head needed, which is what makes this sliceable ahead of `head.go`.
//
// ## Two things the corpus deliberately does NOT assert, and why
//
// `LabelNames` and `Iter` range Go MAPS, so their order is arbitrary upstream — there is nothing to be
// byte-exact against (exception 11's situation, third instance). Both are **sorted before committing**, and
// the port sorts too. `LabelValues` is different and IS order-sensitive: it returns `lvs[name]`, an
// append-only insertion-ordered slice, and its `Limit` truncates before any sort — so it is committed
// verbatim, and that is the interesting half.
//
// The exception is `LabelValues` AFTER a `Delete`: the rebuild ranges `m[name]`'s keys, which is a map, so
// upstream's order becomes arbitrary at that point. Cases with a delete therefore sort it, and the flag says
// which is which rather than sorting everything and losing the insertion-order coverage.

import (
	"context"
	"fmt"
	"slices"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/index"
)

type mpOp struct {
	// add | delete | ensureOrder
	Op string `json:"op"`
	// For `add`.
	ID     uint64            `json:"id,omitempty"`
	Labels map[string]string `json:"labels,omitempty"`
	// For `delete`.
	Deleted  []uint64            `json:"deleted,omitempty"`
	Affected []map[string]string `json:"affected,omitempty"`
}

type mpIn struct {
	// Start from `NewUnorderedMemPostings` rather than `NewMemPostings`, so `addFor`'s insert-time repair is
	// skipped until an `ensureOrder` op runs.
	Unordered bool    `json:"unordered"`
	Ops       []mpOp  `json:"ops"`
	// Names to call `LabelValues` on, and the limit to pass. 0 means no limit.
	LabelValueQueries []mpLabelValueQuery `json:"labelValueQueries,omitempty"`
	// `Postings(name, values...)` queries.
	PostingsQueries []mpPostingsQuery `json:"postingsQueries,omitempty"`
	// `PostingsForAllLabelValues(name)`.
	AllValuesQueries []string `json:"allValuesQueries,omitempty"`
	// `PostingsForLabelMatching(name, match)` — the matcher is a fixed vocabulary, because a Go closure
	// cannot travel through JSON. See `mpMatcher`.
	MatchingQueries []mpMatchingQuery `json:"matchingQueries,omitempty"`
	// Whether `labelValues` is sorted before committing — true for every case with a `delete`, because the
	// rebuild ranges a map. See the file header.
	SortLabelValues bool `json:"sortLabelValues,omitempty"`
}

type mpLabelValueQuery struct {
	Name  string `json:"name"`
	Limit int    `json:"limit,omitempty"`
}

type mpPostingsQuery struct {
	Name   string   `json:"name"`
	Values []string `json:"values"`
}

type mpMatchingQuery struct {
	Name string `json:"name"`
	// all | none | hasPrefixA | isB | nonEmpty
	Matcher string `json:"matcher"`
}

// A closure cannot cross JSON, so the corpus names one of a fixed set. Chosen to cover the three outcomes
// `PostingsForLabelMatching` distinguishes: everything matches, nothing matches (which must be the
// `EmptyPostings()` SENTINEL, not an empty merge), and a proper subset.
func mpMatcher(kind string) func(string) bool {
	switch kind {
	case "all":
		return func(string) bool { return true }
	case "none":
		return func(string) bool { return false }
	case "hasPrefixA":
		return func(v string) bool { return len(v) > 0 && v[0] == 'a' }
	case "isB":
		return func(v string) bool { return v == "b" }
	case "nonEmpty":
		return func(v string) bool { return v != "" }
	default:
		panic("unknown mp matcher " + kind)
	}
}

type mpLabel struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type mpPostingsOut struct {
	Refs []uint64 `json:"refs"`
	Err  string   `json:"err"`
	// Whether the result IS the `EmptyPostings()` singleton, which `Intersect` compares by identity.
	IsEmptySentinel bool `json:"isEmptySentinel"`
}

type mpIterEntry struct {
	Label mpLabel  `json:"label"`
	Refs  []uint64 `json:"refs"`
}

type mpOut struct {
	Symbols    []string  `json:"symbols"`
	SortedKeys []mpLabel `json:"sortedKeys"`
	// SORTED before committing: upstream ranges a map. See the file header.
	LabelNames []string `json:"labelNames"`
	// Insertion-ordered, and committed verbatim unless `SortLabelValues`.
	LabelValues [][]string `json:"labelValues"`
	All         mpPostingsOut
	Postings    []mpPostingsOut `json:"postings"`
	AllValues   []mpPostingsOut `json:"allValues"`
	Matching    []mpPostingsOut `json:"matching"`
	// SORTED by label before committing: upstream ranges a map.
	Iter []mpIterEntry `json:"iter"`
}

func mpExpand(p index.Postings) mpPostingsOut {
	out := mpPostingsOut{Refs: []uint64{}, IsEmptySentinel: index.IsEmptyPostingsType(p)}
	refs, err := index.ExpandPostings(p)
	if err != nil {
		out.Err = err.Error()
	}
	for _, r := range refs {
		out.Refs = append(out.Refs, uint64(r))
	}
	return out
}

func genMemPostings(e *emitter) {
	n := 0
	emit := func(name string, in mpIn) {
		var p *index.MemPostings
		if in.Unordered {
			p = index.NewUnorderedMemPostings()
		} else {
			p = index.NewMemPostings()
		}

		for _, op := range in.Ops {
			switch op.Op {
			case "add":
				p.Add(storage.SeriesRef(op.ID), labels.FromMap(op.Labels))
			case "ensureOrder":
				p.EnsureOrder(1)
			case "delete":
				deleted := map[storage.SeriesRef]struct{}{}
				for _, d := range op.Deleted {
					deleted[storage.SeriesRef(d)] = struct{}{}
				}
				affected := map[labels.Label]struct{}{}
				for _, a := range op.Affected {
					for k, v := range a {
						affected[labels.Label{Name: k, Value: v}] = struct{}{}
					}
				}
				p.Delete(deleted, affected)
			default:
				panic("unknown mem postings op " + op.Op)
			}
		}

		out := mpOut{
			Symbols: []string{}, SortedKeys: []mpLabel{}, LabelNames: []string{},
			LabelValues: [][]string{}, Postings: []mpPostingsOut{},
			AllValues: []mpPostingsOut{}, Matching: []mpPostingsOut{}, Iter: []mpIterEntry{},
		}

		it := p.Symbols()
		for it.Next() {
			out.Symbols = append(out.Symbols, it.At())
		}
		for _, l := range p.SortedKeys() {
			out.SortedKeys = append(out.SortedKeys, mpLabel{Name: l.Name, Value: l.Value})
		}
		// Sorted: upstream ranges a map, so there is no order to pin.
		names := p.LabelNames()
		slices.Sort(names)
		out.LabelNames = append(out.LabelNames, names...)

		for _, q := range in.LabelValueQueries {
			var hints *storage.LabelHints
			if q.Limit > 0 {
				hints = &storage.LabelHints{Limit: q.Limit}
			}
			vs := p.LabelValues(context.Background(), q.Name, hints)
			if vs == nil {
				vs = []string{}
			}
			if in.SortLabelValues {
				slices.Sort(vs)
			}
			out.LabelValues = append(out.LabelValues, vs)
		}

		out.All = mpExpand(p.All())
		for _, q := range in.PostingsQueries {
			out.Postings = append(out.Postings, mpExpand(p.Postings(context.Background(), q.Name, q.Values...)))
		}
		for _, name := range in.AllValuesQueries {
			out.AllValues = append(
				out.AllValues, mpExpand(p.PostingsForAllLabelValues(context.Background(), name)))
		}
		for _, q := range in.MatchingQueries {
			out.Matching = append(out.Matching, mpExpand(
				p.PostingsForLabelMatching(context.Background(), q.Name, mpMatcher(q.Matcher))))
		}

		_ = p.Iter(func(l labels.Label, ps index.Postings) error {
			refs, _ := index.ExpandPostings(ps)
			entry := mpIterEntry{Label: mpLabel{Name: l.Name, Value: l.Value}, Refs: []uint64{}}
			for _, r := range refs {
				entry.Refs = append(entry.Refs, uint64(r))
			}
			out.Iter = append(out.Iter, entry)
			return nil
		})
		// Sorted: upstream ranges a map.
		slices.SortFunc(out.Iter, func(a, b mpIterEntry) int {
			if a.Label.Name != b.Label.Name {
				if a.Label.Name < b.Label.Name {
					return -1
				}
				return 1
			}
			if a.Label.Value == b.Label.Value {
				return 0
			}
			if a.Label.Value < b.Label.Value {
				return -1
			}
			return 1
		})

		e.emit(fmt.Sprintf("mp/%03d/%s", n, name), in, out)
		n++
	}

	genMemPostingsCases(emit)
}

func genMemPostingsCases(emit func(string, mpIn)) {
	add := func(id uint64, kv ...string) mpOp {
		m := map[string]string{}
		for i := 0; i+1 < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return mpOp{Op: "add", ID: id, Labels: m}
	}
	lv := func(qs ...mpLabelValueQuery) []mpLabelValueQuery { return qs }
	q := func(name string, limit int) mpLabelValueQuery {
		return mpLabelValueQuery{Name: name, Limit: limit}
	}

	// Empty: `LabelNames` returns nil (upstream sizes the result n-1, so the n == 0 return has to exist),
	// `All` is an empty merge, and `LabelValues` on an unknown name is empty.
	emit("empty", mpIn{
		LabelValueQueries: lv(q("__name__", 0)),
		AllValuesQueries:  []string{"__name__"},
		MatchingQueries:   []mpMatchingQuery{{Name: "__name__", Matcher: "all"}},
		PostingsQueries:   []mpPostingsQuery{{Name: "__name__", Values: []string{"x"}}},
	})

	// One series. Note `sortedKeys` includes the EMPTY pair and `labelNames` does not.
	emit("one-series", mpIn{
		Ops:               []mpOp{add(1, "__name__", "up", "job", "a")},
		LabelValueQueries: lv(q("__name__", 0), q("job", 0), q("", 0)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "__name__", Values: []string{"up"}},
			{Name: "__name__", Values: []string{"down"}},
			{Name: "__name__", Values: []string{"up", "down"}},
			{Name: "", Values: []string{""}},
		},
		AllValuesQueries: []string{"__name__", "job", "missing"},
	})

	// Several series sharing a label, so a merge actually merges.
	shared := []mpOp{
		add(1, "__name__", "up", "job", "a"),
		add(2, "__name__", "up", "job", "b"),
		add(3, "__name__", "down", "job", "a"),
	}
	emit("shared-labels", mpIn{
		Ops:               shared,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "__name__", Values: []string{"up"}},
			{Name: "job", Values: []string{"a"}},
			{Name: "job", Values: []string{"a", "b"}},
		},
		AllValuesQueries: []string{"__name__", "job"},
		MatchingQueries: []mpMatchingQuery{
			{Name: "job", Matcher: "all"},
			{Name: "job", Matcher: "none"},
			{Name: "job", Matcher: "hasPrefixA"},
			{Name: "job", Matcher: "isB"},
			{Name: "__name__", Matcher: "nonEmpty"},
			{Name: "missing", Matcher: "all"},
		},
	})

	// `LabelValues`' INSERTION order, and its limit truncating before any sort. `z` is added first, so an
	// implementation that sorted would answer `a` for limit 1 and upstream answers `z`.
	insertion := []mpOp{
		add(1, "k", "z"), add(2, "k", "m"), add(3, "k", "a"), add(4, "k", "b"),
	}
	emit("label-values-insertion-order", mpIn{
		Ops:               insertion,
		LabelValueQueries: lv(q("k", 0), q("k", 1), q("k", 2), q("k", 3), q("k", 4), q("k", 99)),
	})

	// IDs added OUT OF ORDER into an ordered MemPostings: `addFor`'s one-pass repair has to place each.
	emit("out-of-order-ids-ordered", mpIn{
		Ops: []mpOp{
			add(5, "k", "v"), add(3, "k", "v"), add(9, "k", "v"), add(1, "k", "v"), add(7, "k", "v"),
		},
		PostingsQueries: []mpPostingsQuery{{Name: "k", Values: []string{"v"}}},
	})
	// The same into an UNORDERED one, with no `ensureOrder`: the list stays in insertion order, and the
	// postings iterator therefore reports it unsorted. This is the state upstream calls unsafe to read, and
	// pinning it is what proves `ensureOrder` does something.
	emit("out-of-order-ids-unordered-no-ensure", mpIn{
		Unordered: true,
		Ops: []mpOp{
			add(5, "k", "v"), add(3, "k", "v"), add(9, "k", "v"), add(1, "k", "v"), add(7, "k", "v"),
		},
		PostingsQueries: []mpPostingsQuery{{Name: "k", Values: []string{"v"}}},
	})
	// And with `ensureOrder`, which sorts everything.
	emit("out-of-order-ids-unordered-ensured", mpIn{
		Unordered: true,
		Ops: []mpOp{
			add(5, "k", "v"), add(3, "k", "v"), add(9, "k", "v"), add(1, "k", "v"), add(7, "k", "v"),
			{Op: "ensureOrder"},
		},
		PostingsQueries: []mpPostingsQuery{{Name: "k", Values: []string{"v"}}},
	})
	// `ensureOrder` on an ALREADY ordered one is a no-op, and adding after it still repairs.
	emit("ensure-order-then-add", mpIn{
		Unordered: true,
		Ops: []mpOp{
			add(5, "k", "v"), add(3, "k", "v"), {Op: "ensureOrder"}, add(1, "k", "v"), add(9, "k", "v"),
		},
		PostingsQueries: []mpPostingsQuery{{Name: "k", Values: []string{"v"}}},
	})

	// Duplicate ids under one label, which the repair loop's `>=` must not reorder.
	emit("duplicate-ids", mpIn{
		Ops:             []mpOp{add(4, "k", "v"), add(4, "k", "v"), add(2, "k", "v"), add(4, "k", "v")},
		PostingsQueries: []mpPostingsQuery{{Name: "k", Values: []string{"v"}}},
	})

	// Deletion: one of several ids under a shared label.
	emit("delete-one-of-many", mpIn{
		Ops: append(append([]mpOp{}, shared...), mpOp{
			Op: "delete", Deleted: []uint64{2},
			Affected: []map[string]string{{"__name__": "up"}, {"job": "b"}},
		}),
		SortLabelValues:   true,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "__name__", Values: []string{"up"}},
			{Name: "job", Values: []string{"b"}},
		},
		AllValuesQueries: []string{"job"},
	})
	// Deleting the ONLY id under a value removes the value from `m` and rebuilds `lvs`.
	emit("delete-last-of-value", mpIn{
		Ops: append(append([]mpOp{}, shared...), mpOp{
			Op: "delete", Deleted: []uint64{3},
			Affected: []map[string]string{{"__name__": "down"}, {"job": "a"}},
		}),
		SortLabelValues:   true,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0)),
		PostingsQueries:   []mpPostingsQuery{{Name: "__name__", Values: []string{"down"}}},
		AllValuesQueries:  []string{"__name__"},
	})
	// Deleting EVERY id removes the label names entirely, `lvs` included — and `All` empties too, which is
	// what proves `Delete` processes `allPostingsKey` after the affected set.
	emit("delete-everything", mpIn{
		Ops: append(append([]mpOp{}, shared...), mpOp{
			Op: "delete", Deleted: []uint64{1, 2, 3},
			Affected: []map[string]string{
				{"__name__": "up"}, {"__name__": "down"}, {"job": "a"}, {"job": "b"},
			},
		}),
		SortLabelValues:   true,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0)),
		AllValuesQueries:  []string{"__name__", "job"},
		MatchingQueries:   []mpMatchingQuery{{Name: "job", Matcher: "all"}},
	})
	// A delete whose `affected` set does NOT mention a label the id is under: that label keeps a dangling
	// reference, which is upstream's documented contract — `affected` is a promise from the caller.
	emit("delete-with-incomplete-affected", mpIn{
		Ops: append(append([]mpOp{}, shared...), mpOp{
			Op: "delete", Deleted: []uint64{1},
			Affected: []map[string]string{{"__name__": "up"}},
		}),
		SortLabelValues:   true,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "__name__", Values: []string{"up"}},
			{Name: "job", Values: []string{"a"}},
		},
	})
	// A delete of an id that was never added, and of a label that does not exist.
	emit("delete-nonexistent", mpIn{
		Ops: append(append([]mpOp{}, shared...), mpOp{
			Op: "delete", Deleted: []uint64{99},
			Affected: []map[string]string{{"nope": "nope"}},
		}),
		SortLabelValues:   true,
		LabelValueQueries: lv(q("__name__", 0)),
		PostingsQueries:   []mpPostingsQuery{{Name: "__name__", Values: []string{"up"}}},
	})

	// An empty label VALUE is a real value, distinct from the empty label PAIR that `All` uses.
	emit("empty-label-value", mpIn{
		Ops:               []mpOp{add(1, "k", ""), add(2, "k", "v")},
		LabelValueQueries: lv(q("k", 0)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "k", Values: []string{""}},
			{Name: "", Values: []string{""}},
		},
		MatchingQueries: []mpMatchingQuery{
			{Name: "k", Matcher: "nonEmpty"},
			{Name: "k", Matcher: "all"},
		},
	})

	// Many series over several names, so `symbols` de-duplicates across names and values.
	var many []mpOp
	for i := 0; i < 30; i++ {
		many = append(many, add(uint64(i+1),
			"__name__", fmt.Sprintf("m%d", i%4),
			"job", fmt.Sprintf("j%d", i%3),
			"inst", fmt.Sprintf("i%d", i%5)))
	}
	emit("many-series", mpIn{
		Ops:               many,
		LabelValueQueries: lv(q("__name__", 0), q("job", 0), q("inst", 2)),
		PostingsQueries: []mpPostingsQuery{
			{Name: "__name__", Values: []string{"m0", "m2"}},
			{Name: "job", Values: []string{"j1"}},
		},
		AllValuesQueries: []string{"__name__", "inst"},
		MatchingQueries: []mpMatchingQuery{
			{Name: "inst", Matcher: "all"},
			{Name: "__name__", Matcher: "isB"},
		},
	})
	// A value shared by a name and a value, so `symbols` has to de-duplicate ACROSS the two.
	emit("name-equals-value", mpIn{
		Ops:               []mpOp{add(1, "a", "a", "b", "a")},
		LabelValueQueries: lv(q("a", 0), q("b", 0)),
	})
}
