package main

// Differential coverage for promql/engine.go's error vocabulary — the four query error
// types, `errWithWarnings`, `contextErr` — and for `sort.Sort(Matrix)`, which is exported
// through Matrix's sort.Interface methods and so can be pinned directly.
//
// ## Why the errors are worth a fixture
//
// Every one of these strings reaches the user through the HTTP API, and three of them
// embed a location — `ErrQueryTimeout("expression evaluation")` reads "query timed out in
// expression evaluation". The location is a place, not a duration, and an empty one leaves
// a trailing "in " that a caller with no context to name can actually produce.
//
// `ErrStorage` is transparent: its message is the wrapped error's, with no prefix. A port
// that added one would look tidier and break consumers matching on the text.
//
// `contextErr`'s mapping is not symmetric with its names: `context.Canceled` becomes
// ErrQueryCanceled and `DeadlineExceeded` becomes ErrQuery**Timeout**, so a deadline is
// reported as a timeout.
//
// ## Why Matrix's sort is worth one
//
// `Matrix.Less` is `labels.Compare(...) < 0`, a total order on *distinct* label sets — so
// for well-formed input any correct sort agrees and there is nothing to pin. It is not
// total across DUPLICATE label sets, which `ContainsSameLabelset` exists to detect and
// upstream calls semantically undefined; there, `sort.Sort`'s permutation is the answer.
// The corpus therefore leans on duplicates, and on sizes either side of the algorithm's
// thresholds.

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
)

type queryErrIn struct {
	// One of timeout, canceled, tooManySamples, storage, withWarnings, contextErr.
	Kind string `json:"kind"`
	// The location string the three timing errors carry.
	Env string `json:"env"`
	// The wrapped error's text, for storage/withWarnings.
	Inner string `json:"inner"`
	// For contextErr: canceled, deadline, or other.
	Cause string `json:"cause"`
}

type queryErrOut struct {
	Text string `json:"text"`
	// contextErr only: whether the result is the canceled or the timeout error, or neither.
	Mapped string `json:"mapped"`
}

func runQueryErrCase(in queryErrIn) queryErrOut {
	switch in.Kind {
	case "timeout":
		return queryErrOut{Text: promql.ErrQueryTimeout(in.Env).Error()}
	case "canceled":
		return queryErrOut{Text: promql.ErrQueryCanceled(in.Env).Error()}
	case "tooManySamples":
		return queryErrOut{Text: promql.ErrTooManySamples(in.Env).Error()}
	case "storage":
		return queryErrOut{Text: promql.ErrStorage{Err: errors.New(in.Inner)}.Error()}
	case "withWarnings":
		// errWithWarnings is unexported, but its Error() is its inner error's — which is
		// the whole observable, and is reproducible here.
		return queryErrOut{Text: errors.New(in.Inner).Error()}
	case "contextErr":
		var cause error
		switch in.Cause {
		case "canceled":
			cause = context.Canceled
		case "deadline":
			cause = context.DeadlineExceeded
		case "wrappedCanceled":
			// contextErr uses errors.Is, so a wrapped sentinel still maps.
			cause = fmt.Errorf("reading from storage: %w", context.Canceled)
		default:
			cause = errors.New(in.Inner)
		}
		// contextErr is unexported; its behaviour is observable through the errors it
		// returns, which are these three cases.
		var got error
		switch {
		case errors.Is(cause, context.Canceled):
			got = promql.ErrQueryCanceled(in.Env)
		case errors.Is(cause, context.DeadlineExceeded):
			got = promql.ErrQueryTimeout(in.Env)
		default:
			got = cause
		}
		mapped := "passthrough"
		var qc promql.ErrQueryCanceled
		var qt promql.ErrQueryTimeout
		if errors.As(got, &qc) {
			mapped = "canceled"
		} else if errors.As(got, &qt) {
			mapped = "timeout"
		}
		return queryErrOut{Text: got.Error(), Mapped: mapped}
	}
	panic("unknown kind " + in.Kind)
}

func genPromQLQueryErrors(e *emitter) {
	n := 0
	emit := func(in queryErrIn) {
		e.emit(fmt.Sprintf("%s/%d", in.Kind, n), in, runQueryErrCase(in))
		n++
	}

	envs := []string{
		// The locations engine.go actually passes.
		"query execution", "expression evaluation", "result sorting",
		// And the shapes that stress the formatting: empty, spaces, unicode, a quote.
		"", " ", "ünïcödé", `a "quoted" place`, "a\nnewline",
	}
	for _, kind := range []string{"timeout", "canceled", "tooManySamples"} {
		for _, env := range envs {
			emit(queryErrIn{Kind: kind, Env: env})
		}
	}

	inners := []string{
		"some storage error", "", "expanding series: block not found",
		`error with "quotes"`, "ünïcödé",
	}
	for _, inner := range inners {
		emit(queryErrIn{Kind: "storage", Inner: inner})
		emit(queryErrIn{Kind: "withWarnings", Inner: inner})
	}

	for _, cause := range []string{"canceled", "deadline", "wrappedCanceled", "other"} {
		for _, env := range []string{"query execution", ""} {
			emit(queryErrIn{
				Kind: "contextErr", Cause: cause, Env: env, Inner: "an unrelated error",
			})
		}
	}
}

// ------------------------------------------------------------- Matrix's sort

type matrixSortIn struct {
	// One label set per series, each a flat name/value list.
	Series [][]string `json:"series"`
}

type matrixSortOut struct {
	// The input indices in sorted order: the permutation, which is what an unstable sort
	// decides for tied elements.
	Perm []int `json:"perm"`
}

func runMatrixSortCase(in matrixSortIn) matrixSortOut {
	mat := make(promql.Matrix, 0, len(in.Series))
	for i, ls := range in.Series {
		// The index rides along in the Floats so the permutation is recoverable; Less
		// reads only the Metric.
		mat = append(mat, promql.Series{
			Metric: labels.FromStrings(ls...),
			Floats: []promql.FPoint{{T: 0, F: float64(i)}},
		})
	}
	// `sort.Sort(mat)` — Matrix implements sort.Interface, so this is the exported route
	// to the same pdqsort the four PromQL sorts use.
	sort.Sort(mat)
	perm := make([]int, 0, len(mat))
	for _, s := range mat {
		perm = append(perm, int(s.Floats[0].F))
	}
	return matrixSortOut{Perm: perm}
}

func genPromQLMatrixSort(e *emitter) {
	n := 0
	emit := func(in matrixSortIn) {
		if in.Series == nil {
			in.Series = [][]string{}
		}
		e.emit(fmt.Sprintf("matrixsort/%d", n), in, runMatrixSortCase(in))
		n++
	}

	// Distinct label sets, in and out of order.
	emit(matrixSortIn{})
	emit(matrixSortIn{Series: [][]string{{"__name__", "a"}}})
	emit(matrixSortIn{Series: [][]string{{"__name__", "b"}, {"__name__", "a"}}})
	emit(matrixSortIn{Series: [][]string{
		{"__name__", "c"}, {"__name__", "a"}, {"__name__", "b"},
	}})
	// Label sets that differ only in a later label, and in the number of labels — where
	// Compare's magnitude differs between Go's label implementations but its sign does not.
	emit(matrixSortIn{Series: [][]string{
		{"__name__", "a", "job", "z"}, {"__name__", "a", "job", "a"},
		{"__name__", "a"},
	}})
	emit(matrixSortIn{Series: [][]string{
		{"__name__", "a", "job", "a"}, {"__name__", "a", "instance", "z"},
	}})

	// DUPLICATE label sets, which is where Less is not a total order and the algorithm's
	// permutation is the observable. Sizes across insertion sort's 12 and the ninther's 50.
	for _, size := range []int{2, 3, 12, 13, 30, 49, 50, 51, 100} {
		all := make([][]string, 0, size)
		for i := 0; i < size; i++ {
			all = append(all, []string{"__name__", "dup"})
		}
		emit(matrixSortIn{Series: all})

		// Half duplicates, half distinct: ties inside a real ordering.
		mixed := make([][]string, 0, size)
		for i := 0; i < size; i++ {
			if i%2 == 0 {
				mixed = append(mixed, []string{"__name__", "dup"})
			} else {
				mixed = append(mixed, []string{"__name__", fmt.Sprintf("s%03d", size-i)})
			}
		}
		emit(matrixSortIn{Series: mixed})

		// A few distinct values with many repeats each, which is partitionEqual's shape.
		few := make([][]string, 0, size)
		for i := 0; i < size; i++ {
			few = append(few, []string{"__name__", fmt.Sprintf("g%d", i%3)})
		}
		emit(matrixSortIn{Series: few})

		// Already sorted, and reversed.
		asc := make([][]string, 0, size)
		desc := make([][]string, 0, size)
		for i := 0; i < size; i++ {
			asc = append(asc, []string{"__name__", fmt.Sprintf("s%03d", i)})
			desc = append(desc, []string{"__name__", fmt.Sprintf("s%03d", size-i)})
		}
		emit(matrixSortIn{Series: asc})
		emit(matrixSortIn{Series: desc})
	}

	// Empty label sets alongside non-empty ones: Compare puts the empty set first.
	emit(matrixSortIn{Series: [][]string{{}, {"__name__", "a"}, {}}})

}
