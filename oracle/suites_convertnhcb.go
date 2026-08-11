package main

// Differential coverage for util/convertnhcb — classic histogram samples in, one NHCB out.
//
// Exported and pure, so the oracle drives it directly: build a `TempHistogram` from a script of
// setter calls and render whichever of the two results comes back. That makes this one of the
// cleanest surfaces in the project to pin, and it is worth ~195 of the exit gate's assertions
// (HANDOFF §5e), which is why it is ported before `info` or `label_replace`.
//
// ## What has to be reached
//
//   - the INTEGER/FLOAT decision, which is made after the `+Inf` bucket is synthesised — so a
//     fractional overall count forces the float path even when every bucket is integral, and one
//     fractional bucket forces it regardless of the count;
//   - the two different `Compact` arguments (2 for integer, 0 for float), which are observable on a
//     histogram with two adjacent empty buckets;
//   - the synthesised `+Inf` bucket, and the case where one was supplied;
//   - the count derived from the highest bucket when none was set;
//   - `setBucketCount`'s out-of-order insert, its duplicate-le tolerance, and the cumulativity
//     check against BOTH neighbours that only the out-of-order path does;
//   - every error, whose text reaches the user;
//   - the STICKY error: once set, later setters do nothing, so the FIRST failure is reported.

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/util/convertnhcb"
)

// One setter call.
type nhcbOp struct {
	// "bucket", "count" or "sum".
	Op string `json:"op"`
	// Hex bit patterns, so NaN and ±Inf travel exactly.
	A string `json:"a"`
	B string `json:"b"`
}

type nhcbIn struct {
	Ops []nhcbOp `json:"ops"`
}

type nhcbOut struct {
	// "integer", "float" or "" when an error came back.
	Kind string `json:"kind"`
	// The chosen histogram's String(), plus the fields String() omits — the same lesson the
	// promqltest gate learnt: spans and custom values are where an invisible difference hides.
	Str          string   `json:"str"`
	Schema       int32    `json:"schema"`
	Count        string   `json:"count"`
	Sum          string   `json:"sum"`
	PSpans       []string `json:"pspans"`
	PBuckets     []string `json:"pbuckets"`
	CustomValues []string `json:"cv"`
	Err          string   `json:"err"`
	// What each setter RETURNED, in order. Upstream's own callers write `_ = h.SetBucketCount(...)`,
	// so this is the least-observed half of the API — and recording only `Convert`'s error left a
	// negative control alive: turning the out-of-order duplicate-`le` tolerance into an error
	// changed a return value nothing looked at. `""` for an op that returned nil.
	OpErrs []string `json:"opErrs"`
	// `Err()` after the fact, which is sticky and may differ from the returned error.
	StickyErr string `json:"stickyErr"`
}

func runNHCBCase(in nhcbIn) nhcbOut {
	h := convertnhcb.NewTempHistogram()
	opErrs := []string{}
	for _, op := range in.Ops {
		var e error
		switch op.Op {
		case "bucket":
			e = h.SetBucketCount(unfbits(op.A), unfbits(op.B))
		case "count":
			e = h.SetCount(unfbits(op.A))
		case "sum":
			e = h.SetSum(unfbits(op.A))
		case "reset":
			h.Reset()
		}
		if e != nil {
			opErrs = append(opErrs, e.Error())
		} else {
			opErrs = append(opErrs, "")
		}
	}
	ih, fh, err := h.Convert()
	out := nhcbOut{
		PSpans: []string{}, PBuckets: []string{}, CustomValues: []string{}, OpErrs: opErrs,
	}
	if h.Err() != nil {
		out.StickyErr = h.Err().Error()
	}
	if err != nil {
		out.Err = err.Error()
		return out
	}
	switch {
	case ih != nil:
		out.Kind = "integer"
		out.Str = ih.String()
		out.Schema = ih.Schema
		out.Count = fmt.Sprintf("%d", ih.Count)
		out.Sum = fbits(ih.Sum)
		for _, s := range ih.PositiveSpans {
			out.PSpans = append(out.PSpans, fmt.Sprintf("(%d,%d)", s.Offset, s.Length))
		}
		for _, b := range ih.PositiveBuckets {
			out.PBuckets = append(out.PBuckets, fmt.Sprintf("%d", b))
		}
		for _, v := range ih.CustomValues {
			out.CustomValues = append(out.CustomValues, fbits(v))
		}
	case fh != nil:
		out.Kind = "float"
		out.Str = fh.String()
		out.Schema = fh.Schema
		out.Count = fbits(fh.Count)
		out.Sum = fbits(fh.Sum)
		for _, s := range fh.PositiveSpans {
			out.PSpans = append(out.PSpans, fmt.Sprintf("(%d,%d)", s.Offset, s.Length))
		}
		for _, b := range fh.PositiveBuckets {
			out.PBuckets = append(out.PBuckets, fbits(b))
		}
		for _, v := range fh.CustomValues {
			out.CustomValues = append(out.CustomValues, fbits(v))
		}
	}
	return out
}

func genConvertNHCB(e *emitter) {
	n := 0
	emit := func(ops ...nhcbOp) {
		in := nhcbIn{Ops: ops}
		e.emit(fmt.Sprintf("convertnhcb/%d", n), in, runNHCBCase(in))
		n++
	}
	b := func(le, count float64) nhcbOp {
		return nhcbOp{Op: "bucket", A: fbits(le), B: fbits(count)}
	}
	c := func(v float64) nhcbOp { return nhcbOp{Op: "count", A: fbits(v)} }
	sum := func(v float64) nhcbOp { return nhcbOp{Op: "sum", A: fbits(v)} }
	inf := math.Inf(1)

	// The plain integer case, with and without an explicit +Inf bucket and count.
	emit(b(1, 1), b(2, 3), b(inf, 4))
	emit(b(1, 1), b(2, 3), b(inf, 4), c(4), sum(10))
	emit(b(1, 1), b(2, 3))
	emit(b(1, 1), b(2, 3), c(5))
	emit(b(1, 1), b(2, 3), sum(7.5))
	// A single bucket, and a single +Inf bucket — the `len(buckets) > 1` guard on CustomValues.
	emit(b(inf, 3))
	emit(b(1, 3))
	emit(c(3))
	emit()
	emit(sum(1))
	// FRACTIONAL: one fractional bucket forces the float path; so does a fractional overall count
	// on its own, because the decision is made after +Inf is synthesised.
	emit(b(1, 1.5), b(2, 3), b(inf, 4))
	emit(b(1, 1), b(2, 3), b(inf, 4), c(4.5))
	emit(b(1, 1), b(2, 3), c(3.5))
	emit(b(1, 0.5), b(2, 0.5), b(inf, 0.5))
	// EMPTY buckets, where the two Compact arguments differ: 2 for the integer path, 0 for the
	// float one, so two adjacent empties merge in one and survive in the other.
	emit(b(1, 5), b(2, 5), b(3, 5), b(4, 5), b(5, 9), b(inf, 9))
	emit(b(1, 5), b(2, 5), b(3, 5), b(4, 5), b(5, 9.5), b(inf, 9.5))
	emit(b(1, 0), b(2, 0), b(3, 0), b(4, 1), b(inf, 1))
	emit(b(1, 0), b(2, 0), b(3, 0), b(4, 1.5), b(inf, 1.5))
	// OUT OF ORDER, which is the only path that checks cumulativity against both neighbours.
	emit(b(2, 3), b(1, 1), b(inf, 4))
	emit(b(3, 5), b(1, 1), b(2, 3), b(inf, 6))
	emit(b(2, 3), b(1, 4))
	emit(b(1, 1), b(3, 5), b(2, 6))
	// DUPLICATE le, ignored in both the in-order and out-of-order paths.
	emit(b(1, 1), b(1, 2), b(2, 3))
	emit(b(2, 3), b(1, 1), b(1, 9))
	// Every error.
	emit(b(math.NaN(), 1))
	emit(b(1, -1))
	emit(c(-1))
	emit(b(1, 5), b(2, 3))
	emit(b(1, 1), b(2, 3), b(inf, 4), c(9))
	emit(b(1, 1), b(2, 3), b(inf, 4.5), c(9.5))
	// The STICKY error: the first failure is reported and later setters do nothing.
	emit(b(1, -1), b(2, 3), c(10), sum(5))
	emit(b(math.NaN(), 1), b(1, 1))
	emit(c(-1), b(1, 1), b(inf, 1))
	// Reset clears it.
	emit(b(1, -1), nhcbOp{Op: "reset"}, b(1, 1), b(inf, 1))
	// Specials in the sum, which has NO validation at all.
	emit(b(1, 1), b(inf, 1), sum(math.NaN()))
	emit(b(1, 1), b(inf, 1), sum(inf))
	emit(b(1, 1), b(inf, 1), sum(-inf))
	// A NEGATIVE boundary, which is legal for a classic histogram.
	emit(b(-1, 1), b(0, 2), b(1, 3), b(inf, 4))
	// Large counts, where the integer conversion's int64 cast matters.
	emit(b(1, 1e15), b(inf, 1e15))
	emit(b(1, 1e18), b(inf, 1e18))
	emit(b(1, 1e19), b(inf, 1e19))

	// --- Cases added because a NEGATIVE CONTROL SURVIVED without them (Scripts/controls-convertnhcb.sh).
	//
	// TWO ADJACENT EMPTY BUCKETS, which is the only shape that distinguishes `Compact(2)` from
	// `Compact(0)` — and therefore the only shape that can catch the integer and float paths using
	// each other's argument. Every earlier case had at most one empty run, so swapping the two
	// arguments changed nothing and both controls survived. `Compact(2)` merges a gap of up to two
	// empty buckets into the surrounding span; `Compact(0)` splits the span instead.
	emit(b(1, 1), b(2, 1), b(3, 1), b(4, 2), b(inf, 3))
	// The same layout with a fractional count, so it takes the FLOAT path and pins the other side of
	// the asymmetry.
	emit(b(1, 1), b(2, 1), b(3, 1), b(4, 2), b(inf, 3.5))
	// A three-wide empty run, which `Compact(2)` also declines to merge — so the two paths agree
	// here, and the case is what proves the difference above is the gap width and not the path.
	emit(b(1, 1), b(2, 1), b(3, 1), b(4, 1), b(5, 2), b(inf, 3))

	// The out-of-order PREDECESSOR check. Every earlier out-of-order case tripped the successor
	// check first, so deleting the predecessor branch entirely left the corpus green. Here le=2 is
	// inserted with a count BELOW le=1's, which only the predecessor branch can see.
	emit(b(1, 5), b(3, 9), b(2, 3))
	// And one where the inserted count is fine against both, so the insert actually happens — the
	// control's counterpart, since a branch that always errors is not a check.
	emit(b(1, 2), b(3, 9), b(2, 5))

	// TWO DIFFERENT failing ops, which is what stickiness actually means: the FIRST error must be
	// the one reported. With one failing op, removing every sticky guard is unobservable, because a
	// succeeding setter never overwrites `err` and `Convert` reports it either way — so the whole
	// sticky-error control survived on a corpus that looked like it covered stickiness.
	emit(b(1, -1), c(-2))
	emit(c(-1), b(math.NaN(), 1))
	emit(b(math.NaN(), 1), b(2, -3), c(-4))
}
