package main

// Differential coverage for `tsdb.PostingsForMatchers` — the function that turns a query's label matchers
// into a postings list.
//
// **The seam is exact and needs no adapter**: `*index.Reader` satisfies `tsdb.IndexReader` in full, so this
// calls upstream's exported `PostingsForMatchers` against a real index file written by upstream's own
// `index.Writer`. Nothing here is a mock, which matters because the function's hardest behaviours are about
// what the *index* does and does not contain — a series with no `l` label has no posting under any value of
// `l`, and that absence is the whole reason `labelMustBeSet` exists.
//
// What has to be reached, in the order the port's file header argues it:
//
//   - `labelMustBeSet` as a per-NAME fact: `{l=~".", l!="1"}`, the case upstream's comment names. Also the
//     shape where two matchers on the same name disagree about emptiness.
//   - the SORT, which is about correctness under concurrency and therefore invisible here — but its effect
//     on the *result set* must still be identity, so cases present the same matchers in several orders.
//   - `hasSubtractingMatchers && !hasIntersectingMatchers`, which reads all postings as the base.
//   - the four `.*`/`.+` special cases, which are NOT symmetric, each alone and each combined.
//   - `l=""`, which selects series WITHOUT the label — prometheus/prometheus#3575.
//   - the empty short-circuits, which fire on some branches and not others.
//   - a set-matching regex (`l=~"a|b"`), which takes the multi-value fast path rather than a predicate walk.
//
// The series deliberately include ones missing a label entirely, ones carrying an EMPTY value for it, and
// ones where only some names overlap — because those three are what separate a correct `labelMustBeSet` from
// a plausible one.

import (
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/index"
)

type pfmIn struct {
	// One entry per series: a flat list of name/value pairs. Sorted and de-duplicated by the generator,
	// because `AddSeries` requires strictly increasing label sets.
	Series [][]string `json:"series"`
	// One entry per query: a list of matchers, each `[type, name, value]` with the type spelled as the
	// operator (`=`, `!=`, `=~`, `!~`).
	Queries [][][3]string `json:"queries"`
	// **The index file's bytes, hex.** INPUT, for the reason `suites_index_reader.go` records: the port
	// has its own writer now, but comparing the port's reader against the port's writer would be comparing
	// against itself. Go writes the file.
	FileHex string `json:"fileHex"`
}

type pfmOut struct {
	// Per query: the matching series refs, and each one's labels, so a wrong answer says WHICH series.
	Refs      [][]uint64 `json:"refs"`
	LabelSets [][]string `json:"labelSets"`
	Errs      []string   `json:"errs"`
	// The refs the writer assigned, so the port's own file (if it ever writes one) is not needed to
	// interpret the results.
	WriteErr string `json:"writeErr"`
}

func parsePFMMatcher(m [3]string) (*labels.Matcher, error) {
	var t labels.MatchType
	switch m[0] {
	case "=":
		t = labels.MatchEqual
	case "!=":
		t = labels.MatchNotEqual
	case "=~":
		t = labels.MatchRegexp
	case "!~":
		t = labels.MatchNotRegexp
	default:
		return nil, fmt.Errorf("unknown matcher type %q", m[0])
	}
	return labels.NewMatcher(t, m[1], m[2])
}

func genPostingsForMatchers(e *emitter) {
	n := 0
	emit := func(in pfmIn) {
		out := pfmOut{Refs: [][]uint64{}, LabelSets: [][]string{}, Errs: []string{}}

		dir, err := os.MkdirTemp("", "pfm")
		if err != nil {
			out.WriteErr = err.Error()
			e.emit(fmt.Sprintf("pfm/%d", n), in, out)
			n++
			return
		}
		defer os.RemoveAll(dir)
		fn := filepath.Join(dir, "index")

		w, err := index.NewWriter(context.Background(), fn)
		if err != nil {
			out.WriteErr = err.Error()
			e.emit(fmt.Sprintf("pfm/%d", n), in, out)
			n++
			return
		}

		// Build the label sets, then the symbol set they need. `AddSymbol` requires sorted order and
		// rejects repeats; `AddSeries` requires strictly increasing label sets.
		lsets := []labels.Labels{}
		symSet := map[string]struct{}{}
		for _, flat := range in.Series {
			ls := labels.FromStrings(flat...)
			lsets = append(lsets, ls)
			ls.Range(func(l labels.Label) {
				symSet[l.Name] = struct{}{}
				symSet[l.Value] = struct{}{}
			})
		}
		sort.Slice(lsets, func(i, j int) bool { return labels.Compare(lsets[i], lsets[j]) < 0 })
		syms := make([]string, 0, len(symSet))
		for s := range symSet {
			syms = append(syms, s)
		}
		sort.Strings(syms)
		for _, s := range syms {
			if err := w.AddSymbol(s); err != nil {
				out.WriteErr = err.Error()
				break
			}
		}
		if out.WriteErr == "" {
			for i, ls := range lsets {
				if i > 0 && labels.Compare(lsets[i-1], ls) == 0 {
					// A duplicate label set is unwritable; skipping it is a generation fix, not a finding.
					continue
				}
				if err := w.AddSeries(storage.SeriesRef(i+1), ls); err != nil {
					out.WriteErr = err.Error()
					break
				}
			}
		}
		if out.WriteErr == "" {
			if err := w.Close(); err != nil {
				out.WriteErr = err.Error()
			}
		} else {
			_ = w.Close()
		}
		if out.WriteErr != "" {
			e.emit(fmt.Sprintf("pfm/%d", n), in, out)
			n++
			return
		}

		raw, err := os.ReadFile(fn)
		if err != nil {
			out.WriteErr = err.Error()
			e.emit(fmt.Sprintf("pfm/%d", n), in, out)
			n++
			return
		}
		in.FileHex = hex.EncodeToString(raw)

		r, err := index.NewReader(oracleByteSlice(raw), index.DecodePostingsRaw)
		if err != nil {
			out.WriteErr = err.Error()
			e.emit(fmt.Sprintf("pfm/%d", n), in, out)
			n++
			return
		}
		defer r.Close()

		for _, q := range in.Queries {
			// A FRESH slice per query: `PostingsForMatchers` sorts `ms` IN PLACE, so a shared slice would
			// hand the next query a reordered copy — which the sort makes harmless for the result but not
			// for the fixture's own `queries` field, which is echoed back as input.
			ms := make([]*labels.Matcher, 0, len(q))
			bad := ""
			for _, spec := range q {
				m, merr := parsePFMMatcher(spec)
				if merr != nil {
					bad = merr.Error()
					break
				}
				ms = append(ms, m)
			}
			if bad != "" {
				out.Refs = append(out.Refs, []uint64{})
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, bad)
				continue
			}

			p, perr := tsdb.PostingsForMatchers(context.Background(), r, ms...)
			if perr != nil {
				out.Refs = append(out.Refs, []uint64{})
				out.LabelSets = append(out.LabelSets, []string{})
				out.Errs = append(out.Errs, perr.Error())
				continue
			}
			ids, eerr := index.ExpandPostings(p)
			refs := []uint64{}
			sets := []string{}
			for _, id := range ids {
				refs = append(refs, uint64(id))
				var b labels.ScratchBuilder
				if serr := r.Series(id, &b, nil); serr == nil {
					sets = append(sets, b.Labels().String())
				} else {
					sets = append(sets, "ERR:"+serr.Error())
				}
			}
			out.Refs = append(out.Refs, refs)
			out.LabelSets = append(out.LabelSets, sets)
			if eerr != nil {
				out.Errs = append(out.Errs, eerr.Error())
			} else {
				out.Errs = append(out.Errs, "")
			}
		}

		e.emit(fmt.Sprintf("pfm/%d", n), in, out)
		n++
	}

	// The base population, chosen so the three cases that separate a correct `labelMustBeSet` from a
	// plausible one are all present: a series MISSING `l`, a series with an EMPTY `l`, and series whose
	// names only partly overlap.
	base := [][]string{
		{"__name__", "up", "job", "api", "l", "a"},
		{"__name__", "up", "job", "api", "l", "b"},
		{"__name__", "up", "job", "web", "l", "ab"},
		{"__name__", "up", "job", "web"},            // no `l` at all
		{"__name__", "down", "job", "web", "l", ""}, // `l` present but EMPTY
		{"__name__", "down", "job", "db", "l", "1"},
		{"__name__", "down", "l", "2"}, // no `job`
	}

	q := func(ms ...[3]string) [][3]string { return ms }
	M := func(t, n, v string) [3]string { return [3]string{t, n, v} }

	// Single matchers of every type, on a name that is sometimes absent and sometimes empty.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=", "l", "a")),
		q(M("=", "l", "")), // selects series WITHOUT `l` too — issue #3575
		q(M("!=", "l", "a")),
		q(M("!=", "l", "")), // "has a non-empty `l`"
		q(M("=~", "l", "a|b")),
		q(M("=~", "l", "a.*")),
		q(M("!~", "l", "a|b")),
		q(M("!~", "l", "")),
		q(M("=", "job", "api")),
		q(M("=", "job", "")),
		q(M("!=", "job", "web")),
		q(M("=", "nosuch", "x")),
		q(M("=", "nosuch", "")),
		q(M("!=", "nosuch", "x")),
	}})

	// The four `.*`/`.+` cases, alone and combined — they are not symmetric.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=~", "l", ".*")),
		q(M("!~", "l", ".*")),
		q(M("=~", "l", ".+")),
		q(M("!~", "l", ".+")),
		q(M("=~", "nosuch", ".*")),
		q(M("=~", "nosuch", ".+")),
		q(M("!~", "nosuch", ".+")),
		// `.*` contributes no constraint, so these two must differ only by the other matcher.
		q(M("=~", "l", ".*"), M("=", "job", "api")),
		q(M("=", "job", "api")),
		// `.*` as the ONLY matcher alongside an all-postings-shaped one.
		q(M("=~", "l", ".*"), M("=~", "job", ".*")),
		q(M("=~", "l", ".+"), M("=~", "job", ".+")),
		q(M("!~", "l", ".+"), M("=", "__name__", "up")),
		// `.*` combined with another matcher ON THE SAME NAME. These exist because removing the `.*`
		// special case entirely still passes every other shape: the fall-through lands in a branch that
		// produces an empty subtraction or an intersection with a superset, so the equivalence has to be
		// checked rather than reasoned about. Each of the four quadrants of `labelMustBeSet` x isNot:
		q(M("=~", "l", ".*"), M("=", "l", "a")),
		q(M("=~", "l", ".*"), M("!=", "l", "a")),
		q(M("=~", "l", ".*"), M("=", "l", "")),
		q(M("=~", "l", ".*"), M("!=", "l", "")),
		q(M("=~", "l", ".*"), M("=~", "l", ".")),
		q(M("=~", "l", ".*"), M("!~", "l", "a|b")),
		q(M("=~", "l", ".*"), M("=~", "l", ".*")),
		q(M("!~", "l", ".*"), M("=", "l", "a")),
		q(M("=~", "l", ".+"), M("=", "l", "")),
		q(M("=~", "l", ".+"), M("!=", "l", "")),
	}})

	// `labelMustBeSet` as a per-NAME fact — upstream's own example, and its neighbours.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=~", "l", "."), M("!=", "l", "1")),
		q(M("!=", "l", "1")), // the same subtraction WITHOUT the presence guarantee
		q(M("=~", "l", "."), M("!~", "l", "a|b")),
		q(M("!=", "l", ""), M("!=", "l", "a")),
		q(M("=", "l", ""), M("=", "job", "web")),
		// Two matchers on the same name that disagree about emptiness.
		q(M("=", "l", ""), M("!=", "l", "a")),
		q(M("!=", "l", ""), M("=", "l", "")),
	}})

	// Only-subtracting queries, which read all postings as the base.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("!=", "l", "a")),
		q(M("!=", "l", "a"), M("!=", "job", "web")),
		q(M("!~", "l", "a|b"), M("!~", "job", "api")),
		q(M("=", "nosuch", "")),
		q(M("=", "nosuch", ""), M("=", "alsonone", "")),
	}})

	// ORDER INDEPENDENCE. The sort exists for concurrency, so on a static file the same matchers in any
	// order must give the same set — and if the port's stable partition is wrong, these disagree.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=", "job", "api"), M("!=", "l", "a")),
		q(M("!=", "l", "a"), M("=", "job", "api")),
		q(M("=~", "l", ".+"), M("!=", "job", "web"), M("=", "__name__", "up")),
		q(M("=", "__name__", "up"), M("=~", "l", ".+"), M("!=", "job", "web")),
		q(M("!=", "job", "web"), M("=", "__name__", "up"), M("=~", "l", ".+")),
	}})

	// The empty short-circuits: an intersecting matcher that matches nothing must make the whole result
	// empty, and a subtracting one that matches nothing must be a no-op.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=", "l", "zzz")),
		q(M("=", "l", "zzz"), M("=", "job", "api")),
		q(M("=", "job", "api"), M("=", "l", "zzz")),
		q(M("!=", "l", "zzz")),
		q(M("=", "job", "api"), M("!=", "l", "zzz")),
		q(M("=~", "l", "zzz|yyy")),
		q(M("!~", "l", "zzz|yyy")),
	}})

	// The all-postings matcher: alone it is handled before the loop, mixed it is an ERROR.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=", "", "")),
		q(M("=", "", ""), M("=", "job", "api")),
		q(M("=", "job", "api"), M("=", "", "")),
	}})

	// A set-matching regex, which takes the multi-value fast path, and one that cannot.
	emit(pfmIn{Series: base, Queries: [][][3]string{
		q(M("=~", "l", "a|b|ab")),
		q(M("=~", "l", "a|zzz")),
		q(M("=~", "l", "zzz|yyy")),
		q(M("!~", "l", "a|b")),
		q(M("!~", "l", "a|zzz")),
		q(M("=~", "l", "[ab]")), // no set matches: a predicate walk
		q(M("=~", "l", "a.*b")), // ditto
		q(M("!~", "l", "[ab]")),
	}})

	// Many values of one label, so the predicate walk crosses sparse entries (the same reason the reader
	// suite's match queries do).
	{
		many := [][]string{}
		for i := range 40 {
			many = append(many, []string{"__name__", "m", "l", fmt.Sprintf("v%02d", i)})
		}
		many = append(many, []string{"__name__", "m"})
		emit(pfmIn{Series: many, Queries: [][][3]string{
			q(M("=~", "l", "v0.")),
			q(M("!~", "l", "v0.")),
			q(M("=~", "l", ".+")),
			q(M("=", "l", "")),
			q(M("!=", "l", ""), M("!~", "l", "v1.")),
			q(M("=~", "l", strings.Join([]string{"v00", "v15", "v39"}, "|"))),
		}})
	}

	// A single series, and no series at all — the degenerate files.
	emit(pfmIn{Series: [][]string{{"__name__", "only"}}, Queries: [][][3]string{
		q(M("=", "__name__", "only")),
		q(M("=", "l", "")),
		q(M("!=", "l", "x")),
		q(M("=~", "l", ".*")),
		q(M("=~", "l", ".+")),
	}})
}
