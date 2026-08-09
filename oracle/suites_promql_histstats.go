package main

// Differential coverage for promql/histogram_stats_iterator.go.
//
// Op-script shaped, like the storage iterator suites, because the type is
// stateful: `last`, `lastIsCurrent` and the reuse buffer are only observable
// through a sequence of calls, and the interesting behaviours are all about what a
// *repeated* or *reordered* call returns.
//
// Two things this suite records that a histogram's String() cannot:
//
//   - the CounterResetHint. FloatHistogram.String() does not print it
//     (float_histogram.go:151), and the hint is the entire point of this iterator.
//   - count/sum as bit patterns, so the stale marker's NaN sum survives the wire
//     and so the stripping is asserted on the numbers rather than only on the
//     rendering.
//
// The underlying iterator is storage.NewListSeriesIterator, already ported and
// pinned by the storage/listseries suite, rather than a bespoke one — so a diff
// here cannot be the fixture generator's own fault.
//
// TRAP, and the reason no case seeks before its first `next`: Seek reads
// `hsi.AtT()`, which is the *embedded* iterator's, and listSeriesIterator.AtT()
// indexes samples[-1] before the first Next(). Go panics and takes the generator
// with it. Same family of trap as the look-back wrappers' raw pass-throughs.
//
// Not reachable from here, and pinned Swift-side instead: `histogramStatsSeries`
// (engine.go:4785) is unexported, so the oracle cannot construct one. Its reuse
// path is the only caller of Reset that upstream has, and Reset itself IS exported,
// so the `reset` op below covers the behaviour if not the call site.

import (
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/storage"
)

// ---------------------------------------------------------------- wire types

// statsSample describes one sample by NAMING A GENERATOR rather than spelling the
// histogram out. The generators are upstream's own (tsdb/tsdbutil/histogram.go),
// reproduced verbatim below and again in Tests/PromQLTests/HistogramStatsWire.swift.
//
// Chosen over the catalogue-of-literals shape the storage suites use because the
// behaviour under test is counter reset detection, which needs a FAMILY of
// histograms ordered by magnitude — `n` ascending means no reset, `n` descending
// means one. A catalogue would make that relationship invisible.
type statsSample struct {
	// "h" (integer histogram), "fh" (float histogram) or "f" (plain float).
	Kind string `json:"kind"`
	T    string `json:"t"`
	// "std" (exponential, schema 1), "custom" (custom buckets) or "stale".
	// Ignored for kind "f".
	Gen string `json:"gen"`
	// The generator's parameter. Counts and sum scale with it.
	N int64 `json:"n"`
	// histogram.CounterResetHint raw value.
	Hint int `json:"hint"`
	// Hex bit pattern, for kind "f".
	F string `json:"f"`
}

type statsIn struct {
	Samples []statsSample `json:"samples"`
	Ops     []iterOp      `json:"ops"`
}

type statsStep struct {
	Op string `json:"op"`
	// chunkenc.ValueType raw value, or -1 where the op does not return one.
	Ret int    `json:"ret"`
	T   string `json:"t"`
	ST  string `json:"st"`
	F   string `json:"f"`
	// The returned histogram's String(), which shows whether the buckets were
	// stripped. nil when the op returns no histogram.
	Hist *string `json:"hist"`
	// CounterResetHint, count, sum and schema of the returned histogram, which
	// String() either omits or renders lossily. -1 / "" when absent.
	Hint   int    `json:"hint"`
	Count  string `json:"count"`
	Sum    string `json:"sum"`
	Schema int    `json:"schema"`
	Err    string `json:"err"`
}

type statsOut struct {
	Steps []statsStep `json:"steps"`
}

// ------------------------------------------------------------------ generators

// Ported verbatim from tsdb/tsdbutil/histogram.go's GenerateTestHistogram.
// Duplicated in the Swift wire file; a divergence shows up on the first case,
// because every step carries the resulting count, sum and rendering.
func genTestHistogram(i int64) *histogram.Histogram {
	return &histogram.Histogram{
		Count:         12 + uint64(i*9),
		ZeroCount:     2 + uint64(i),
		ZeroThreshold: 0.001,
		Sum:           18.4 * float64(i+1),
		Schema:        1,
		PositiveSpans: []histogram.Span{
			{Offset: 0, Length: 2},
			{Offset: 1, Length: 2},
		},
		PositiveBuckets: []int64{i + 1, 1, -1, 0},
		NegativeSpans: []histogram.Span{
			{Offset: 0, Length: 2},
			{Offset: 1, Length: 2},
		},
		NegativeBuckets: []int64{i + 1, 1, -1, 0},
	}
}

// tsdbutil.GenerateTestCustomBucketsHistogram.
func genTestCustomBucketsHistogram(i int64) *histogram.Histogram {
	return &histogram.Histogram{
		Count:  5 + uint64(i*4),
		Sum:    18.4 * float64(i+1),
		Schema: histogram.CustomBucketsSchema,
		PositiveSpans: []histogram.Span{
			{Offset: 0, Length: 2},
			{Offset: 1, Length: 2},
		},
		PositiveBuckets: []int64{i + 1, 1, -1, 0},
		CustomValues:    []float64{0, 1, 2, 3, 4},
	}
}

// The stale marker exactly as promql/histogram_stats_iterator_test.go:70 spells it:
// a histogram with NOTHING but the stale sum. Count is therefore 0, which is what
// makes the "count is zero for a stale sample" assertion in upstream's test hold.
func genStaleHistogram() *histogram.Histogram {
	return &histogram.Histogram{Sum: math.Float64frombits(value.StaleNaN)}
}

// genFixedTotalHistogram keeps Count and Sum FIXED for every i and moves only the
// distribution of the observations across two buckets. So DetectReset's count
// comparison can see no difference and only its bucket-by-bucket comparison can.
//
// Not an upstream generator; added because it is the only shape that distinguishes
// storing the FULL previous histogram as `last` — what Go does — from storing the
// stripped one that was returned. Against a stripped baseline there are no buckets
// to compare, so every pair reads as "no counter reset", and the whole reason
// `last` is a full copy disappears silently. `tsdbutil`'s generators cannot reach
// this: their counts move with i, so the count check answers first and the port
// passes either way. (Established by perturbation, not by inspection.)
//
// Buckets are deltas: bucket0 = i, bucket1 = i + (10 - 2i) = 10 - i, total 10.
func genFixedTotalHistogram(i int64) *histogram.Histogram {
	return &histogram.Histogram{
		Count:           10,
		Sum:             20,
		Schema:          0,
		PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
		PositiveBuckets: []int64{i, 10 - 2*i},
	}
}

func statsHistogram(gen string, n int64, hint int) *histogram.Histogram {
	var h *histogram.Histogram
	switch gen {
	case "std":
		h = genTestHistogram(n)
	case "custom":
		h = genTestCustomBucketsHistogram(n)
	case "fixedTotal":
		h = genFixedTotalHistogram(n)
	case "stale":
		h = genStaleHistogram()
	default:
		panic("unknown histogram generator " + gen)
	}
	h.CounterResetHint = histogram.CounterResetHint(hint)
	return h
}

func buildStatsSamples(in []statsSample) oracleSamples {
	out := make(oracleSamples, 0, len(in))
	for _, s := range in {
		os := oracleSample{t: parseI64(s.T)}
		switch s.Kind {
		case "f":
			os.f = unfbits(s.F)
		case "h":
			os.h = statsHistogram(s.Gen, s.N, s.Hint)
		case "fh":
			os.fh = statsHistogram(s.Gen, s.N, s.Hint).ToFloat(nil)
		default:
			panic("unknown sample kind " + s.Kind)
		}
		out = append(out, os)
	}
	return out
}

// ---------------------------------------------------------------- the replay

func genPromQLHistogramStats(e *emitter) {
	for _, c := range histogramStatsCases() {
		e.emit(c.id, c.in, runHistogramStatsOps(c.in))
	}
}

// dirtyReuseBuffer is what the `atFHReuse` op hands to AtFloatHistogram: a FULL
// histogram, buckets and all, of the *other* schema family than the samples use.
// CopyTo has to wipe every one of those fields, and the customValues nil/non-nil
// branch is the one most likely to leak.
func dirtyReuseBuffer() *histogram.FloatHistogram {
	return genTestCustomBucketsHistogram(7).ToFloat(nil)
}

func runHistogramStatsOps(in statsIn) statsOut {
	samples := buildStatsSamples(in.Samples)
	it := promql.NewHistogramStatsIterator(storage.NewListSeriesIterator(samples))

	record := func(step *statsStep, t int64, fh *histogram.FloatHistogram) {
		step.T = i64(t)
		if fh == nil {
			step.Hint = -1
			step.Schema = -1
			return
		}
		step.Hist = histString(nil, fh)
		step.Hint = int(fh.CounterResetHint)
		step.Count = fbits(fh.Count)
		step.Sum = fbits(fh.Sum)
		step.Schema = int(fh.Schema)
	}

	out := statsOut{Steps: []statsStep{}}
	for _, op := range in.Ops {
		step := statsStep{Op: op.Op, Ret: -1, Hint: -1, Schema: -1}
		switch op.Op {
		case "next":
			step.Ret = int(it.Next())
		case "seek":
			step.Ret = int(it.Seek(parseI64(op.Arg)))
		case "at":
			t, f := it.At()
			step.T, step.F = i64(t), fbits(f)
		case "atT":
			step.T = i64(it.AtT())
		case "atST":
			step.ST = i64(it.AtST())
		case "atFH":
			t, fh := it.AtFloatHistogram(nil)
			record(&step, t, fh)
		case "atFHReuse":
			t, fh := it.AtFloatHistogram(dirtyReuseBuffer())
			record(&step, t, fh)
		case "reset":
			// A fresh iterator over the SAME samples, which is what upstream's own
			// test does (histogram_stats_iterator_test.go:147).
			it.Reset(storage.NewListSeriesIterator(buildStatsSamples(in.Samples)))
		case "err":
			if err := it.Err(); err != nil {
				step.Err = err.Error()
			}
		default:
			panic("unknown histogram-stats op " + op.Op)
		}
		out.Steps = append(out.Steps, step)
	}
	return out
}

// ----------------------------------------------------------------- the corpus

type statsCase struct {
	id string
	in statsIn
}

// Hint shorthands, so a case reads like upstream's table.
const (
	hUnknown = int(histogram.UnknownCounterReset)
	hReset   = int(histogram.CounterReset)
	hNot     = int(histogram.NotCounterReset)
	hGauge   = int(histogram.GaugeType)
)

func hSample(t, n int64, hint int) statsSample {
	return statsSample{Kind: "h", T: i64(t), Gen: "std", N: n, Hint: hint, F: fbits(0)}
}

func cbSample(t, n int64, hint int) statsSample {
	return statsSample{Kind: "h", T: i64(t), Gen: "custom", N: n, Hint: hint, F: fbits(0)}
}

func ftSample(t, n int64, hint int) statsSample {
	return statsSample{Kind: "h", T: i64(t), Gen: "fixedTotal", N: n, Hint: hint, F: fbits(0)}
}

func fhSample2(t, n int64, hint int) statsSample {
	return statsSample{Kind: "fh", T: i64(t), Gen: "std", N: n, Hint: hint, F: fbits(0)}
}

func staleSample(t int64, hint int) statsSample {
	return statsSample{Kind: "h", T: i64(t), Gen: "stale", N: 0, Hint: hint, F: fbits(0)}
}

func floatSample(t int64, v float64) statsSample {
	return statsSample{Kind: "f", T: i64(t), Gen: "std", N: 0, Hint: 0, F: fbits(v)}
}

// walk is the shape upstream's `check` closure uses: advance, then read TWICE to
// assert idempotency, for as many samples as there are, then one final advance to
// observe exhaustion.
func walk(n int) []iterOp {
	ops := []iterOp{}
	for i := 0; i < n; i++ {
		ops = append(ops, op("next"), op("atT"), op("atFH"), op("atFH"))
	}
	return append(ops, op("next"), op("err"))
}

func histogramStatsCases() []statsCase {
	var cases []statsCase
	add := func(id string, in statsIn) { cases = append(cases, statsCase{id: id, in: in}) }

	// --- Upstream's own six TestHistogramStatsDecoding tables, verbatim in shape.
	// Their expected hints are recorded in the fixture rather than asserted here,
	// which is the point: if the port disagrees the diff names the case.
	add("upstream/unknown-later-triggers-detection", statsIn{
		Samples: []statsSample{
			hSample(0, 0, hNot),
			hSample(10, 1, hUnknown),
			hSample(20, 2, hReset),
			hSample(30, 2, hUnknown),
		},
		Ops: walk(4),
	})
	add("upstream/unknown-first-no-detection", statsIn{
		Samples: []statsSample{
			hSample(0, 0, hUnknown),
			hSample(10, 1, hUnknown),
			hSample(20, 2, hReset),
			hSample(30, 2, hUnknown),
		},
		Ops: walk(4),
	})
	add("upstream/stale-before-unknown", statsIn{
		Samples: []statsSample{
			hSample(0, 0, hNot),
			hSample(10, 1, hUnknown),
			staleSample(20, hUnknown),
			hSample(30, 1, hUnknown),
		},
		Ops: walk(4),
	})
	add("upstream/unknown-at-beginning", statsIn{
		Samples: []statsSample{hSample(0, 1, hUnknown)},
		Ops:     walk(1),
	})
	add("upstream/detect-real-reset", statsIn{
		Samples: []statsSample{
			hSample(0, 2, hUnknown),
			hSample(10, 1, hUnknown),
		},
		Ops: walk(2),
	})
	add("upstream/detect-reset-after-stale", statsIn{
		Samples: []statsSample{
			hSample(0, 2, hUnknown),
			staleSample(10, hUnknown),
			hSample(20, 1, hUnknown),
		},
		Ops: walk(3),
	})

	// The same six, but through Reset onto a fresh underlying iterator: upstream
	// runs its whole `check` twice for exactly this reason. Reset drops `last` and
	// `lastIsCurrent` but deliberately keeps `current`, so a second walk must
	// reproduce the first hint-for-hint — including the first sample's `unknown`.
	add("reset/replays-identically", statsIn{
		Samples: []statsSample{
			hSample(0, 0, hUnknown),
			hSample(10, 1, hUnknown),
			hSample(20, 2, hReset),
			hSample(30, 2, hUnknown),
		},
		Ops: append(append(walk(4), op("reset")), walk(4)...),
	})
	// Reset PART WAY THROUGH, so `last` is non-nil when it is dropped. The first
	// sample of the second walk must be `unknown` again, not compared against the
	// sample that was current before the reset.
	add("reset/mid-walk-drops-last", statsIn{
		Samples: []statsSample{
			hSample(0, 5, hUnknown),
			hSample(10, 4, hUnknown),
			hSample(20, 3, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"), op("next"), op("atFH"),
			op("reset"),
			op("next"), op("atFH"), op("next"), op("atFH"), op("next"), op("err"),
		},
	})

	// --- The lastIsCurrent path, which is what stops a repeated read from
	// re-running detection and answering "no counter reset" for a sample that had
	// one. Read four times over a genuine reset.
	add("idempotent/repeated-read-over-a-reset", statsIn{
		Samples: []statsSample{
			hSample(0, 4, hUnknown),
			hSample(10, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			op("next"), op("atFH"), op("atFH"), op("atFH"), op("atFH"),
		},
	})
	// A `next` in between clears lastIsCurrent, so detection runs again — against
	// the NEW last, not the original one.
	add("idempotent/next-clears-it", statsIn{
		Samples: []statsSample{
			hSample(0, 3, hUnknown),
			hSample(10, 3, hUnknown),
			hSample(20, 3, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"), op("atFH"),
			op("next"), op("atFH"), op("atFH"),
			op("next"), op("atFH"), op("atFH"),
		},
	})
	// atT/at/atST between two reads must not disturb the memo: they are raw
	// pass-throughs and touch none of the three state fields.
	add("idempotent/reads-do-not-disturb", statsIn{
		Samples: []statsSample{
			hSample(0, 2, hUnknown),
			hSample(10, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			op("next"), op("atFH"), op("atT"), op("atST"), op("at"), op("atFH"),
		},
	})

	// --- The reuse buffer. `atFHReuse` hands in a full CUSTOM-BUCKETS histogram
	// while the samples are exponential, so every field CopyTo is responsible for
	// clearing is dirty on the way in — customValues most of all, which is the one
	// field CopyTo nils rather than resizes.
	add("reuse/wipes-a-dirty-buffer", statsIn{
		Samples: []statsSample{
			hSample(0, 1, hNot),
			hSample(10, 2, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFHReuse"), op("atFHReuse"),
			op("next"), op("atFHReuse"), op("atFH"),
		},
	})
	// The mirror image: custom-buckets samples into a buffer that is also custom
	// buckets, so customValues comes from the source rather than being nilled.
	add("reuse/custom-buckets-samples", statsIn{
		Samples: []statsSample{
			cbSample(0, 1, hNot),
			cbSample(10, 2, hUnknown),
			cbSample(20, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"), op("atFHReuse"),
			op("next"), op("atFH"),
			op("next"), op("atFH"), op("atFHReuse"),
		},
	})
	// Reuse on the stale path, which skips detection entirely — so the buffer is
	// wiped by a populate() that was told not to detect.
	add("reuse/on-a-stale-sample", statsIn{
		Samples: []statsSample{
			hSample(0, 2, hNot),
			staleSample(10, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFHReuse"), op("next"), op("atFHReuse"), op("atFHReuse"),
		},
	})

	// --- Seek. Every case advances first: see the file header on why a seek from
	// fresh panics in Go.
	add("seek/forward-drops-last", statsIn{
		// n descending, so a reset is detectable — and must NOT be reported,
		// because the seek dropped `last`.
		Samples: []statsSample{
			hSample(0, 5, hUnknown),
			hSample(10, 4, hUnknown),
			hSample(20, 3, hUnknown),
			hSample(30, 2, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"), op("next"), op("atFH"),
			opArg("seek", 30), op("atT"), op("atFH"), op("atFH"),
		},
	})
	add("seek/no-op-keeps-last", statsIn{
		// t <= AtT(), so the `t > hsi.AtT()` guard does not fire: `last` and
		// lastIsCurrent both survive, and the read answers from the memo.
		Samples: []statsSample{
			hSample(0, 4, hUnknown),
			hSample(10, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"), op("next"), op("atFH"),
			opArg("seek", 10), op("atT"), op("atFH"),
			opArg("seek", 0), op("atFH"),
		},
	})
	// A seek that lands exactly one sample on and therefore DOES fire the guard,
	// even though it advances by the minimum.
	add("seek/one-sample-forward", statsIn{
		Samples: []statsSample{
			hSample(0, 3, hUnknown),
			hSample(10, 3, hUnknown),
			hSample(20, 3, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			opArg("seek", 10), op("atFH"),
			opArg("seek", 11), op("atT"), op("atFH"),
		},
	})
	add("seek/past-end", statsIn{
		Samples: []statsSample{
			hSample(0, 1, hNot),
			hSample(10, 2, hNot),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			opArg("seek", 1000000), op("next"), op("err"),
		},
	})
	add("seek/integer-histogram-reported-as-float", statsIn{
		Samples: []statsSample{
			hSample(0, 1, hNot), hSample(10, 2, hNot), hSample(20, 3, hNot),
		},
		Ops: []iterOp{
			op("next"), opArg("seek", 15), op("atT"), op("atFH"),
		},
	})

	// --- Hints that are already explicit are passed through without detection,
	// which is the `hint != UnknownCounterReset` early return. A gauge series is
	// the case that matters: detection over gauges is meaningless and must not run.
	add("hints/gauge-passes-through", statsIn{
		Samples: []statsSample{
			hSample(0, 5, hGauge),
			hSample(10, 1, hGauge),
			hSample(20, 9, hGauge),
		},
		Ops: walk(3),
	})
	// An explicit NotCounterReset over a series that genuinely DID reset: the
	// sample's own hint wins and no detection happens.
	add("hints/explicit-not-reset-over-a-real-reset", statsIn{
		Samples: []statsSample{
			hSample(0, 9, hUnknown),
			hSample(10, 1, hNot),
		},
		Ops: walk(2),
	})
	// An explicit CounterReset over a series that did not reset.
	add("hints/explicit-reset-over-no-reset", statsIn{
		Samples: []statsSample{
			hSample(0, 1, hUnknown),
			hSample(10, 2, hReset),
			hSample(20, 3, hUnknown),
		},
		Ops: walk(3),
	})

	// --- Stale markers in the positions upstream's table does not reach.
	add("stale/first-sample", statsIn{
		Samples: []statsSample{
			staleSample(0, hUnknown),
			hSample(10, 1, hUnknown),
		},
		Ops: walk(2),
	})
	add("stale/only-sample", statsIn{
		Samples: []statsSample{staleSample(0, hUnknown)},
		Ops:     walk(1),
	})
	add("stale/consecutive", statsIn{
		Samples: []statsSample{
			hSample(0, 3, hUnknown),
			staleSample(10, hUnknown),
			staleSample(20, hUnknown),
			hSample(30, 1, hUnknown),
		},
		Ops: walk(4),
	})
	// A stale marker carrying an explicit hint: the stale branch passes the hint
	// through untouched, so an explicit CounterReset on a stale sample survives.
	add("stale/with-explicit-hint", statsIn{
		Samples: []statsSample{
			hSample(0, 3, hNot),
			staleSample(10, hReset),
			hSample(20, 4, hUnknown),
		},
		Ops: walk(3),
	})

	// --- Float-histogram samples, which arrive as ValFloatHistogram already, so
	// Next's fold does not fire.
	add("float-histogram/walk", statsIn{
		Samples: []statsSample{
			fhSample2(0, 0, hNot),
			fhSample2(10, 1, hUnknown),
			fhSample2(20, 0, hUnknown),
		},
		Ops: walk(3),
	})

	// --- Mixed streams. Next reports ValFloat for a float sample and the stats
	// iterator does nothing to it; at() is the promoted pass-through.
	add("mixed/floats-and-histograms", statsIn{
		Samples: []statsSample{
			hSample(0, 1, hNot),
			floatSample(10, 42.5),
			hSample(20, 2, hUnknown),
			floatSample(30, math.Inf(-1)),
			hSample(40, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			op("next"), op("at"),
			op("next"), op("atFH"),
			op("next"), op("at"),
			op("next"), op("atFH"),
			op("next"), op("err"),
		},
	})
	// A float sample between two histograms does NOT become `last` — nothing on
	// the float path touches the three state fields — so detection at t=40 above
	// compares against t=20. Restated as its own case with a reset in the gap.
	add("mixed/float-in-the-gap-does-not-clear-last", statsIn{
		Samples: []statsSample{
			hSample(0, 6, hUnknown),
			floatSample(10, 1),
			hSample(20, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			op("next"), op("at"),
			op("next"), op("atFH"), op("atFH"),
		},
	})

	// --- Schema changes across the boundary DetectReset treats specially: custom
	// buckets on one side and exponential on the other is an automatic reset
	// (float_histogram.go's DetectReset returns true on a schema family change).
	add("schema/custom-to-exponential", statsIn{
		Samples: []statsSample{
			cbSample(0, 1, hUnknown),
			hSample(10, 5, hUnknown),
			cbSample(20, 9, hUnknown),
		},
		Ops: walk(3),
	})
	// Custom buckets throughout, with the counts moving up and down, so the
	// decision comes from the bucket comparison inside one schema family rather
	// than from the family change above.
	add("schema/custom-buckets-only", statsIn{
		Samples: []statsSample{
			cbSample(0, 1, hUnknown),
			cbSample(10, 2, hUnknown),
			cbSample(20, 1, hUnknown),
			cbSample(30, 4, hUnknown),
		},
		Ops: walk(4),
	})

	// --- `last` holds the FULL previous histogram, not the stripped one that was
	// returned. Count and sum are identical across every sample here, so only the
	// buckets can decide — and a stripped baseline has none. See
	// genFixedTotalHistogram.
	add("baseline/full-histogram-not-the-stripped-one", statsIn{
		Samples: []statsSample{
			ftSample(0, 1, hUnknown),
			ftSample(10, 4, hUnknown),
			ftSample(20, 4, hUnknown),
			ftSample(30, 1, hUnknown),
		},
		Ops: walk(4),
	})
	// The same, with the memo read twice per sample already covered by walk(), plus
	// a seek in the middle so the baseline is dropped and the following sample must
	// fall back to `unknown` even though its buckets moved.
	add("baseline/seek-drops-the-full-baseline", statsIn{
		Samples: []statsSample{
			ftSample(0, 1, hUnknown),
			ftSample(10, 4, hUnknown),
			ftSample(20, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFH"),
			opArg("seek", 20), op("atT"), op("atFH"), op("atFH"),
		},
	})
	// And through a reuse buffer, which is the path where a stripped baseline would
	// be easiest to introduce by accident: populate() writes into the buffer and it
	// is `out`, not `current`, that setLastFromCurrent takes its hint from.
	add("baseline/through-a-reuse-buffer", statsIn{
		Samples: []statsSample{
			ftSample(0, 1, hUnknown),
			ftSample(10, 4, hUnknown),
			ftSample(20, 1, hUnknown),
		},
		Ops: []iterOp{
			op("next"), op("atFHReuse"),
			op("next"), op("atFHReuse"),
			op("next"), op("atFHReuse"),
		},
	})

	// --- Degenerate.
	add("empty", statsIn{
		Ops: []iterOp{op("next"), op("err")},
	})
	add("exhaustion/read-then-drain", statsIn{
		Samples: []statsSample{hSample(0, 1, hNot), hSample(10, 2, hNot)},
		Ops: []iterOp{
			op("next"), op("atFH"), op("next"), op("atFH"),
			op("next"), op("next"), op("err"),
		},
	})
	// A long ascending run: every sample after the first must be NotCounterReset,
	// which is the common shape in practice and the one a wrong `last` breaks
	// silently.
	add("long/ascending", statsIn{
		Samples: func() []statsSample {
			out := []statsSample{}
			for i := int64(0); i < 12; i++ {
				out = append(out, hSample(i*10, i, hUnknown))
			}
			return out
		}(),
		Ops: walk(12),
	})
	// A long descending run: every sample after the first must be CounterReset.
	add("long/descending", statsIn{
		Samples: func() []statsSample {
			out := []statsSample{}
			for i := int64(0); i < 12; i++ {
				out = append(out, hSample(i*10, 11-i, hUnknown))
			}
			return out
		}(),
		Ops: walk(12),
	})

	return cases
}
