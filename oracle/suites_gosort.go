package main

// Differential coverage for Go's `sort.Sort` — the pdqsort in
// src/sort/zsortinterface.go, which `promql/functions.go`'s `sort` and `sort_desc`
// depend on for their exact output.
//
// ## Why a sorting ALGORITHM is in the corpus at all
//
// `sort.Sort` is not stable, so the order of elements a comparator calls equal is
// whatever the algorithm leaves behind. That is normally none of a port's business. It
// becomes its business because `vectorByValueHeap.Less` answers **true** for a NaN on the
// left whichever way it otherwise compares, so `Less(i,j)` and `Less(j,i)` are both true
// for two NaNs — not a strict weak ordering. With an inconsistent comparator the result
// is not "some sorted permutation", it is *this algorithm's* permutation.
//
// ## What is pinned, and why it is more than the output
//
// Each case records three things:
//
//	perm       the ids in final order — the permutation, which is the observable
//	lessCalls  how many times Less was called
//	swapCalls  how many times Swap was called
//
// The call counts are a fingerprint of the control flow: insertion sort, heapsort,
// ninther versus median-of-three, `partialInsertionSort`'s early exit, `breakPatterns`.
// A port that produced the right permutation by a different route — say, by falling back
// to a library sort for small inputs — matches `perm` and fails the counts. Two of the
// negative controls for this suite are only caught by them.
//
// ## The comparators
//
// `lt` is the well-behaved case. `nanLt`/`nanGt` are PromQL's two heaps verbatim.
// `allEqual` returns false always, which makes EVERY element tied and so pins the
// algorithm's structure at maximum sensitivity — it is also what drains `limit` and
// reaches the heapsort fallback. `allLess` returns true always, which is inconsistent in
// the other direction.
//
// ## This fixture is pinned to a Go TOOLCHAIN, not to prometheus v3.13.2
//
// Every other corpus here is pinned to the upstream tag. This one is the standard
// library's, so a Go release that changed pdqsort would fail
// `Scripts/verify-fixtures.sh` rather than drift silently. Go has kept this algorithm
// since 1.19.

import (
	"fmt"
	"math"
	"sort"
	"strconv"
)

// parseU64 reads a decimal uint64.
func parseU64(s string) uint64 {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		panic(err)
	}
	return v
}

type pdqIn struct {
	// Keys as float64 BIT PATTERNS, decimal uint64 strings — so NaN payloads and
	// signed zeros survive the round trip.
	Keys []string `json:"keys"`
	// One of lt, nanLt, nanGt, allEqual, allLess.
	Cmp string `json:"cmp"`
	// Wrap the comparator in sort.Reverse, which is what `sort`/`sort_desc` do.
	Reverse bool `json:"reverse"`
}

type pdqOut struct {
	Perm      []int `json:"perm"`
	LessCalls int   `json:"lessCalls"`
	SwapCalls int   `json:"swapCalls"`
}

type pdqKeyed struct {
	key float64
	id  int
}

// pdqData is a sort.Interface whose Less is supplied by the case and which counts both
// operations.
type pdqData struct {
	s     []pdqKeyed
	less  func(a, b pdqKeyed) bool
	stats *pdqStats
}

type pdqStats struct {
	less int
	swap int
}

func (d pdqData) Len() int { return len(d.s) }

func (d pdqData) Less(i, j int) bool {
	d.stats.less++
	return d.less(d.s[i], d.s[j])
}

func (d pdqData) Swap(i, j int) {
	d.stats.swap++
	d.s[i], d.s[j] = d.s[j], d.s[i]
}

func pdqComparator(name string) func(a, b pdqKeyed) bool {
	switch name {
	case "lt":
		return func(a, b pdqKeyed) bool { return a.key < b.key }
	case "nanLt":
		// promql's vectorByValueHeap.Less, verbatim.
		return func(a, b pdqKeyed) bool {
			if math.IsNaN(a.key) {
				return true
			}
			return a.key < b.key
		}
	case "nanGt":
		// promql's vectorByReverseValueHeap.Less, verbatim.
		return func(a, b pdqKeyed) bool {
			if math.IsNaN(a.key) {
				return true
			}
			return a.key > b.key
		}
	case "allEqual":
		return func(pdqKeyed, pdqKeyed) bool { return false }
	case "allLess":
		return func(pdqKeyed, pdqKeyed) bool { return true }
	}
	panic("unknown comparator " + name)
}

func runPdqCase(in pdqIn) pdqOut {
	s := make([]pdqKeyed, len(in.Keys))
	for i, k := range in.Keys {
		s[i] = pdqKeyed{key: math.Float64frombits(parseU64(k)), id: i}
	}
	stats := &pdqStats{}
	data := pdqData{s: s, less: pdqComparator(in.Cmp), stats: stats}
	if in.Reverse {
		sort.Sort(sort.Reverse(data))
	} else {
		sort.Sort(data)
	}
	perm := make([]int, len(s))
	for i := range s {
		perm[i] = s[i].id
	}
	return pdqOut{Perm: perm, LessCalls: stats.less, SwapCalls: stats.swap}
}

// pdqLCG is a fixed linear congruential generator: the corpus must be identical on
// every machine, so `math/rand` is not an option even seeded.
type pdqLCG uint64

func (r *pdqLCG) next() uint64 {
	*r = pdqLCG(uint64(*r)*6364136223846793005 + 1442695040888963407)
	return uint64(*r) >> 11
}

func pdqKeys(vals []float64) []string {
	out := make([]string, len(vals))
	for i, v := range vals {
		out[i] = fmt.Sprintf("%d", math.Float64bits(v))
	}
	return out
}

// The shapes. Each returns `n` keys.
func pdqShape(shape string, n int) []float64 {
	vals := make([]float64, n)
	switch shape {
	case "ascending":
		for i := range vals {
			vals[i] = float64(i)
		}
	case "descending":
		for i := range vals {
			vals[i] = float64(n - i)
		}
	case "equal":
		for i := range vals {
			vals[i] = 7
		}
	case "twoValues":
		// Many duplicates, which is what partitionEqual exists for.
		for i := range vals {
			vals[i] = float64(i % 2)
		}
	case "fewValues":
		for i := range vals {
			vals[i] = float64(i % 5)
		}
	case "organPipe":
		// Up then down, the classic median-of-three killer.
		for i := range vals {
			if i < n/2 {
				vals[i] = float64(i)
			} else {
				vals[i] = float64(n - i)
			}
		}
	case "sawtooth":
		for i := range vals {
			vals[i] = float64(i % 16)
		}
	case "random":
		r := pdqLCG(uint64(n) * 2654435761)
		for i := range vals {
			vals[i] = float64(r.next() % 1000)
		}
	case "nearlySorted":
		// Ascending with every eighth pair swapped: the shape partialInsertionSort is
		// for, and the only way its five-step budget and its 50-element floor show.
		for i := range vals {
			vals[i] = float64(i)
		}
		for i := 0; i+1 < n; i += 8 {
			vals[i], vals[i+1] = vals[i+1], vals[i]
		}
	case "oneOutOfPlace":
		// Sorted but for a single displaced element, so partialInsertionSort returns
		// true after one shift.
		for i := range vals {
			vals[i] = float64(i)
		}
		if n > 2 {
			vals[n-1] = -1
		}
	case "allNaN":
		for i := range vals {
			vals[i] = math.NaN()
		}
	case "nanScattered":
		for i := range vals {
			if i%3 == 0 {
				vals[i] = math.NaN()
			} else {
				vals[i] = float64(i % 7)
			}
		}
	case "nanPayloads":
		// Distinct NaN payloads, so a port comparing bit patterns rather than using
		// IsNaN would disagree.
		for i := range vals {
			vals[i] = math.Float64frombits(0x7FF8000000000001 + uint64(i))
		}
	case "nanTail":
		// Ascending with NaNs in the last quarter only. The point is a sub-range that
		// starts at a > 0 and still holds an inconsistent element, which is the only way
		// partialInsertionSort's left shift can walk BELOW its own range — see the
		// `j >= 1` note in GoSort.swift.
		for i := range vals {
			if i >= n-n/4 {
				vals[i] = math.NaN()
			} else {
				vals[i] = float64(i)
			}
		}
	case "nanHead":
		for i := range vals {
			if i < n/4 {
				vals[i] = math.NaN()
			} else {
				vals[i] = float64(i)
			}
		}
	case "nearlySortedNaN":
		// nearlySorted, with a NaN every 16th element: an increasing hint AND an
		// inconsistent comparison in the same range.
		for i := range vals {
			vals[i] = float64(i)
		}
		for i := 0; i+1 < n; i += 8 {
			vals[i], vals[i+1] = vals[i+1], vals[i]
		}
		for i := 5; i < n; i += 16 {
			vals[i] = math.NaN()
		}
	case "extremes":
		pattern := []float64{
			math.Inf(1), math.Inf(-1), 0, math.Copysign(0, -1), math.NaN(),
			math.MaxFloat64, -math.MaxFloat64, math.SmallestNonzeroFloat64,
		}
		for i := range vals {
			vals[i] = pattern[i%len(pattern)]
		}
	default:
		panic("unknown shape " + shape)
	}
	return vals
}

func genGoPdqsort(e *emitter) {
	n := 0
	emit := func(in pdqIn) {
		if in.Keys == nil {
			in.Keys = []string{}
		}
		e.emit(fmt.Sprintf("%s/%d", in.Cmp, n), in, runPdqCase(in))
		n++
	}

	shapes := []string{
		"ascending", "descending", "equal", "twoValues", "fewValues", "organPipe",
		"sawtooth", "random", "nearlySorted", "oneOutOfPlace", "allNaN",
		"nanScattered", "nanPayloads", "nanTail", "nanHead", "nearlySortedNaN",
		"extremes",
	}
	// Sizes chosen around every threshold in the algorithm: 12 (insertion sort), 8
	// (choosePivot's static pivot), 50 (the ninther and partialInsertionSort's floor),
	// and enough length for the recursion to nest and for `limit` to run out.
	sizes := []int{
		0, 1, 2, 3, 4, 7, 8, 9, 11, 12, 13, 20, 30, 48, 49, 50, 51, 60, 100, 128,
		200, 257, 500, 1000,
	}

	for _, cmp := range []string{"lt", "nanLt", "nanGt", "allEqual", "allLess"} {
		for _, shape := range shapes {
			for _, size := range sizes {
				// The degenerate comparators do not read the keys, so one shape is
				// enough for them — otherwise 14 identical cases per size.
				if (cmp == "allEqual" || cmp == "allLess") && shape != "random" {
					continue
				}
				for _, reverse := range []bool{false, true} {
					emit(pdqIn{
						Keys:    pdqKeys(pdqShape(shape, size)),
						Cmp:     cmp,
						Reverse: reverse,
					})
				}
			}
		}
	}
}
