package main

// Differential coverage for storage/buffer.go and storage/memoized_iterator.go,
// plus the slice of storage/series.go the port took.
//
// These are the first STATEFUL surfaces in the corpus, so the fixture shape is the
// union of the two existing precedents: the op-script of labels/builder
// (suites_phase1b.go) and encoding/encbuf (suites_prom.go), plus the per-step
// full-state trace of promql/lex (suites_promql_lex.go).
//
// The oracle is a separate Go module, so it can only reach EXPORTED API.
// `sampleRing` is unexported and is therefore driven indirectly, through
// NewBufferIterator + Next/Seek/Buffer/PeekBack/ReduceDelta. That is a feature: it
// pins the observable surface rather than internals. The consequence is that
// nearly every case must end in a `bufferDrain`, because the drain is the only way
// the ring's index arithmetic becomes visible at all.
//
// Deliberately NOT in the corpus, because Go panics and would take the generator
// with it. Each is pinned as a Swift-side invariant test instead:
//   - PeekBack(0)                  divides by zero on an empty ring (buffer.go:787)
//   - an unknown ValueType         panics (buffer.go:100, :133)
//   - a negative ReduceDelta       never terminates (buffer.go:754)
//   - a foreign chunks.Sample      silently dropped on the first add (buffer.go:470)
//   - At() before the first Next() reads samples[-1] (series.go:122)

import (
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

// ---------------------------------------------------------------- wire types

type sampleJSON struct {
	// "f", "h" or "fh".
	Kind string `json:"kind"`
	ST   string `json:"st"`
	T    string `json:"t"`
	// Hex bit pattern; JSON cannot carry NaN and -0 would not survive a decimal
	// round trip.
	F string `json:"f"`
	// Index into histogramCatalogue. Ignored for kind "f".
	Hist int `json:"hist"`
}

type iterOp struct {
	Op string `json:"op"`
	// int64 as a decimal string, so 64-bit values survive JSON intact. "" when
	// the op takes no argument.
	Arg string `json:"arg"`
}

type iterIn struct {
	Samples  []sampleJSON `json:"samples"`
	Delta    string       `json:"delta"`
	WithCopy bool         `json:"withCopy"`
	Ops      []iterOp     `json:"ops"`
}

type iterStep struct {
	Op string `json:"op"`
	// chunkenc.ValueType raw value, or -1 where the op does not return one.
	Ret int    `json:"ret"`
	T   string `json:"t"`
	ST  string `json:"st"`
	F   string `json:"f"`
	// The histogram's String(), which Phase 3 already proved byte-identical.
	// nil when there is no histogram at this step.
	Hist *string `json:"hist"`
	// PeekBack / PeekPrev found something.
	OK *bool `json:"ok"`
	// ReduceDelta's return.
	Bool *bool `json:"bool"`
	// A bufferDrain's nested trace, one entry per SampleRingIterator.Next().
	Buf []iterStep `json:"buf"`
	Err string     `json:"err"`
}

type iterOut struct {
	Steps []iterStep `json:"steps"`
}

// ------------------------------------------------------- histogram catalogue

// histogramCatalogue is duplicated verbatim in
// Tests/PromStorageTests/IteratorWire.swift. Serialising the histograms would
// have meant duplicating the whole bucket-layout codec instead; an index is
// cheaper and cannot drift silently, because every output step carries the
// histogram's String() and a mismatched catalogue therefore shows up as a diff on
// the first case that touches it.
//
// Index 0 is deliberately "no histogram".
func integerHistogram(idx int) *histogram.Histogram {
	switch idx {
	case 1:
		return &histogram.Histogram{
			Schema: 0, Count: 12, Sum: 18.4, ZeroThreshold: 0.001, ZeroCount: 2,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []int64{3, 1},
			NegativeSpans:   []histogram.Span{{Offset: 1, Length: 2}},
			NegativeBuckets: []int64{2, -1},
		}
	case 2:
		return &histogram.Histogram{
			CounterResetHint: histogram.GaugeType,
			Schema:           2, Count: 5, Sum: -3.5,
			PositiveSpans:   []histogram.Span{{Offset: -1, Length: 3}},
			PositiveBuckets: []int64{1, 1, -1},
		}
	case 6:
		return &histogram.Histogram{
			Schema: histogram.CustomBucketsSchema, Count: 7, Sum: 9,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 3}},
			PositiveBuckets: []int64{2, 1, -1},
			CustomValues:    []float64{1, 5, 10},
		}
	}
	return nil
}

func floatHistogram(idx int) *histogram.FloatHistogram {
	switch idx {
	case 3:
		return &histogram.FloatHistogram{
			Schema: 0, Count: 11.5, Sum: 22.25, ZeroThreshold: 0.001, ZeroCount: 1.5,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{4, 6},
			NegativeSpans:   []histogram.Span{{Offset: 2, Length: 1}},
			NegativeBuckets: []float64{2},
		}
	case 4:
		return &histogram.FloatHistogram{
			Schema: 1, Count: 3, Sum: math.NaN(),
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{1, 2},
		}
	case 5:
		return &histogram.FloatHistogram{
			Schema: histogram.CustomBucketsSchema, Count: 6, Sum: 14,
			PositiveSpans:   []histogram.Span{{Offset: 0, Length: 2}},
			PositiveBuckets: []float64{2, 4},
			CustomValues:    []float64{2, 4},
		}
	}
	return nil
}

// -------------------------------------------------- a chunks.Sample for input

// oracleSample implements chunks.Sample so the corpus can build a sample list.
// Note this is a FOREIGN implementation as far as storage is concerned — but it
// never reaches sampleRing, because BufferedSeriesIterator re-wraps whatever the
// underlying iterator yields into storage's own fSample/hSample/fhSample before
// adding. That is exactly why the buffer.go:470 foreign-type bug is unreachable.
type oracleSample struct {
	st, t int64
	f     float64
	h     *histogram.Histogram
	fh    *histogram.FloatHistogram
}

func (s oracleSample) T() int64                { return s.t }
func (s oracleSample) ST() int64               { return s.st }
func (s oracleSample) H() *histogram.Histogram { return s.h }

// Deliberately does NOT panic for a histogram sample, where storage's own fSample
// and hSample do. This is the corpus's sample type, not a port of one, and the
// looser behaviour is what lets a case ask for `at()` on a histogram and see the
// zero it yields. Tests/PromStorageTests/IteratorWire.swift matches it exactly.
func (s oracleSample) F() float64 { return s.f }

// Converts, as storage.hSample.FH() does (buffer.go:227).
func (s oracleSample) FH() *histogram.FloatHistogram {
	if s.fh != nil {
		return s.fh
	}
	if s.h != nil {
		return s.h.ToFloat(nil)
	}
	return nil
}

func (s oracleSample) Type() chunkenc.ValueType {
	switch {
	case s.h != nil:
		return chunkenc.ValHistogram
	case s.fh != nil:
		return chunkenc.ValFloatHistogram
	}
	return chunkenc.ValFloat
}

func (s oracleSample) Copy() chunks.Sample {
	c := oracleSample{st: s.st, t: s.t, f: s.f}
	if s.h != nil {
		c.h = s.h.Copy()
	}
	if s.fh != nil {
		c.fh = s.fh.Copy()
	}
	return c
}

type oracleSamples []chunks.Sample

func (s oracleSamples) Get(i int) chunks.Sample { return s[i] }
func (s oracleSamples) Len() int                { return len(s) }

func buildSamples(in []sampleJSON) oracleSamples {
	out := make(oracleSamples, 0, len(in))
	for _, s := range in {
		os := oracleSample{st: parseI64(s.ST), t: parseI64(s.T)}
		switch s.Kind {
		case "f":
			os.f = unfbits(s.F)
		case "h":
			os.h = integerHistogram(s.Hist)
			if os.h == nil {
				panic(fmt.Sprintf("catalogue index %d is not an integer histogram", s.Hist))
			}
		case "fh":
			os.fh = floatHistogram(s.Hist)
			if os.fh == nil {
				panic(fmt.Sprintf("catalogue index %d is not a float histogram", s.Hist))
			}
		default:
			panic("unknown sample kind " + s.Kind)
		}
		out = append(out, os)
	}
	return out
}

func parseI64(s string) int64 {
	if s == "" {
		return 0
	}
	var v int64
	if _, err := fmt.Sscanf(s, "%d", &v); err != nil {
		panic(err)
	}
	return v
}

func i64(v int64) string { return fmt.Sprintf("%d", v) }

func histString(h *histogram.Histogram, fh *histogram.FloatHistogram) *string {
	switch {
	case h != nil:
		s := h.String()
		return &s
	case fh != nil:
		s := fh.String()
		return &s
	}
	return nil
}

func boolPtr(b bool) *bool { return &b }

// ------------------------------------------------------------ storage/buffer

func genStorageBuffer(e *emitter) {
	for _, c := range bufferCases() {
		e.emit(c.id, c.in, runBufferOps(c.in))
	}
}

func runBufferOps(in iterIn) iterOut {
	src := storage.NewListSeriesIterator(buildSamples(in.Samples))
	it := storage.NewBufferIterator(src, parseI64(in.Delta))

	out := iterOut{Steps: []iterStep{}}
	for _, op := range in.Ops {
		step := iterStep{Op: op.Op, Ret: -1}
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
		case "atFloatHistogram":
			t, fh := it.AtFloatHistogram(nil)
			step.T = i64(t)
			step.Hist = histString(nil, fh)
		case "peekBack":
			s, ok := it.PeekBack(int(parseI64(op.Arg)))
			step.OK = boolPtr(ok)
			if ok {
				step.T, step.ST = i64(s.T()), i64(s.ST())
				switch s.Type() {
				case chunkenc.ValFloat:
					step.F = fbits(s.F())
				case chunkenc.ValHistogram:
					step.Hist = histString(s.H(), nil)
				case chunkenc.ValFloatHistogram:
					step.Hist = histString(nil, s.FH())
				}
				step.Ret = int(s.Type())
			}
		case "reduceDelta":
			step.Bool = boolPtr(it.ReduceDelta(parseI64(op.Arg)))
		case "bufferDrain":
			step.Buf = drainBuffer(it)
		case "err":
			if err := it.Err(); err != nil {
				step.Err = err.Error()
			}
		default:
			panic("unknown buffer op " + op.Op)
		}
		out.Steps = append(out.Steps, step)
	}
	return out
}

// drainBuffer records the whole look-back window. This is the only view the
// oracle has of the ring's index arithmetic, so the ORDER here is the assertion
// that matters: it is what proves the doubling growth's two-segment copy and the
// specialized-to-interface migration's len-preserving trick.
func drainBuffer(it *storage.BufferedSeriesIterator) []iterStep {
	buf := it.Buffer()
	steps := []iterStep{}
	for {
		vt := buf.Next()
		if vt == chunkenc.ValNone {
			return steps
		}
		step := iterStep{Op: "bufNext", Ret: int(vt), T: i64(buf.AtT()), ST: i64(buf.AtST())}
		switch vt {
		case chunkenc.ValFloat:
			_, f := buf.At()
			step.F = fbits(f)
		case chunkenc.ValHistogram:
			_, h := buf.AtHistogram()
			step.Hist = histString(h, nil)
		case chunkenc.ValFloatHistogram:
			_, fh := buf.AtFloatHistogram(nil)
			step.Hist = histString(nil, fh)
		}
		steps = append(steps, step)
	}
}

// --------------------------------------------------------- storage/memoized

func genStorageMemoized(e *emitter) {
	for _, c := range memoizedCases() {
		e.emit(c.id, c.in, runMemoizedOps(c.in))
	}
}

func runMemoizedOps(in iterIn) iterOut {
	src := storage.NewListSeriesIterator(buildSamples(in.Samples))
	it := storage.NewMemoizedIterator(src, parseI64(in.Delta))

	out := iterOut{Steps: []iterStep{}}
	for _, op := range in.Ops {
		step := iterStep{Op: op.Op, Ret: -1}
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
		case "atFloatHistogram":
			t, fh := it.AtFloatHistogram()
			step.T = i64(t)
			step.Hist = histString(nil, fh)
		case "peekPrev":
			t, v, fh, ok := it.PeekPrev()
			step.OK = boolPtr(ok)
			step.T, step.F = i64(t), fbits(v)
			step.Hist = histString(nil, fh)
		case "err":
			if err := it.Err(); err != nil {
				step.Err = err.Error()
			}
		default:
			panic("unknown memoized op " + op.Op)
		}
		out.Steps = append(out.Steps, step)
	}
	return out
}

// -------------------------------------------------------- storage/listseries

func genStorageListSeries(e *emitter) {
	for _, c := range listSeriesCases() {
		e.emit(c.id, c.in, runListSeriesOps(c.in))
	}
}

func runListSeriesOps(in iterIn) iterOut {
	samples := storage.Samples(buildSamples(in.Samples))
	var it chunkenc.Iterator
	if in.WithCopy {
		it = storage.NewListSeriesIteratorWithCopy(samples)
	} else {
		it = storage.NewListSeriesIterator(samples)
	}

	out := iterOut{Steps: []iterStep{}}
	for _, op := range in.Ops {
		step := iterStep{Op: op.Op, Ret: -1}
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
		case "atHistogram":
			t, h := it.AtHistogram(nil)
			step.T = i64(t)
			step.Hist = histString(h, nil)
		case "atFloatHistogram":
			t, fh := it.AtFloatHistogram(nil)
			step.T = i64(t)
			step.Hist = histString(nil, fh)
		case "err":
			if err := it.Err(); err != nil {
				step.Err = err.Error()
			}
		default:
			panic("unknown listseries op " + op.Op)
		}
		out.Steps = append(out.Steps, step)
	}
	return out
}
