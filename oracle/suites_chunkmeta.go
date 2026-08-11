package main

// Differential coverage for the metadata half of tsdb/chunkenc: which samples share a chunk, what
// header each chunk gets, and therefore what CounterResetHint a query READS BACK.
//
// ## The seam, and why it is this one
//
// `appendable`, `appendableGauge` and `expandFloatSpansAndBuckets` are all unexported, so the oracle
// cannot call them — the same wall `bstream.go` hit (HANDOFF §5d). But their whole observable effect
// is reachable through three exported calls: `AppendFloatHistogram` says whether a new chunk started,
// `GetCounterResetHeader` says what header it got, and the iterator's `AtFloatHistogram` says what
// hint each sample reads back with. Pinning the *composition* is better than pinning the private
// helper anyway, because the composition is what the storage and the engine actually see.
//
// So each case is a sequence of float histograms appended in order, and the output is, per sample:
// which chunk it landed in, that chunk's header, and its read-back hint.
//
// ## What has to be reached
//
//   - a plain counting-up series: one chunk, first sample `unknown`, the rest `not_reset`;
//   - a COUNT GOING BACKWARDS: new chunk, `CounterReset` header — and note the sample that starts it
//     still reads back `unknown`, not `reset`;
//   - a SCHEMA change: new chunk, but `NotCounterReset` — `okToAppend` and `counterReset` are
//     independent booleans and this is the case that separates them;
//   - an explicit `CounterReset` hint on a sample whose count did NOT go backwards, which is
//     honoured anyway;
//   - a GAUGE series, where every sample reads `gauge` including the first;
//   - a gauge sample arriving in a counter chunk and vice versa;
//   - STALE samples, which are accepted whatever their buckets say, and which then accept only
//     stale samples after them;
//   - a bucket that DISAPPEARS: a reset if it was in use, ordinary if it was empty. That is
//     `expandFloatSpansAndBuckets`' one subtlety and it is invisible from the counts alone;
//   - a zero-count going backwards, and a zero-THRESHOLD change, which are a reset and a
//     not-a-reset respectively;
//   - custom-bucket boundaries changing, which is a reset.

import (
	"fmt"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

// One float histogram on the wire. Only the fields the decision reads.
type chHist struct {
	Schema        int32    `json:"schema"`
	Count         string   `json:"count"`
	Sum           string   `json:"sum"`
	ZeroThreshold string   `json:"zt"`
	ZeroCount     string   `json:"zc"`
	PSpans        []string `json:"pspans"`
	PBuckets      []string `json:"pbuckets"`
	NSpans        []string `json:"nspans"`
	NBuckets      []string `json:"nbuckets"`
	CustomValues  []string `json:"cv"`
	// "", "reset", "not_reset" or "gauge" — the hint the sample is WRITTEN with.
	Hint string `json:"hint"`
}

type chunkMetaIn struct {
	Samples []chHist `json:"samples"`
	// Sample indices at which the driver forces a NEW chunk before appending, passing the old
	// appender as `prev`. This models the HEAD's own chunk cut (capacity or time based), which is the
	// only way a `NotCounterReset` header is ever set: `AppendFloatHistogram`'s internal cut passes no
	// `prev` and so leaves the header `unknown` unless it detected a reset. Without this the whole
	// `prev != nil` branch of upstream's code is unreachable from the exported API.
	CutBefore []int `json:"cutBefore"`
}

type chunkMetaOut struct {
	// Per input sample, the index of the chunk it landed in.
	ChunkOf []int `json:"chunkOf"`
	// Per chunk, its counter reset header.
	Headers []string `json:"headers"`
	// Per input sample, the hint it READS BACK with — the whole point of the suite.
	Hints []string `json:"hints"`
	Err   string   `json:"err"`
}

func hintName(h histogram.CounterResetHint) string {
	switch h {
	case histogram.UnknownCounterReset:
		return "unknown"
	case histogram.CounterReset:
		return "reset"
	case histogram.NotCounterReset:
		return "not_reset"
	case histogram.GaugeType:
		return "gauge"
	}
	return "?"
}

func headerName(h chunkenc.CounterResetHeader) string {
	switch h {
	case chunkenc.CounterReset:
		return "reset"
	case chunkenc.NotCounterReset:
		return "not_reset"
	case chunkenc.GaugeType:
		return "gauge"
	case chunkenc.UnknownCounterReset:
		return "unknown"
	}
	return "?"
}

func toFH(w chHist) *histogram.FloatHistogram {
	h := &histogram.FloatHistogram{
		Schema:        w.Schema,
		Count:         unfbits(w.Count),
		Sum:           unfbits(w.Sum),
		ZeroThreshold: unfbits(w.ZeroThreshold),
		ZeroCount:     unfbits(w.ZeroCount),
	}
	for _, s := range w.PSpans {
		var o int32
		var l uint32
		fmt.Sscanf(s, "(%d,%d)", &o, &l)
		h.PositiveSpans = append(h.PositiveSpans, histogram.Span{Offset: o, Length: l})
	}
	for _, s := range w.NSpans {
		var o int32
		var l uint32
		fmt.Sscanf(s, "(%d,%d)", &o, &l)
		h.NegativeSpans = append(h.NegativeSpans, histogram.Span{Offset: o, Length: l})
	}
	for _, b := range w.PBuckets {
		h.PositiveBuckets = append(h.PositiveBuckets, unfbits(b))
	}
	for _, b := range w.NBuckets {
		h.NegativeBuckets = append(h.NegativeBuckets, unfbits(b))
	}
	for _, v := range w.CustomValues {
		h.CustomValues = append(h.CustomValues, unfbits(v))
	}
	switch w.Hint {
	case "reset":
		h.CounterResetHint = histogram.CounterReset
	case "not_reset":
		h.CounterResetHint = histogram.NotCounterReset
	case "gauge":
		h.CounterResetHint = histogram.GaugeType
	}
	return h
}

func runChunkMetaCase(in chunkMetaIn) chunkMetaOut {
	out := chunkMetaOut{ChunkOf: []int{}, Headers: []string{}, Hints: []string{}}

	// Every chunk in order, and each one's appender, so `prev` can be passed on a cut — which is
	// what lets the NEW chunk's header be computed from the OLD chunk's last sample.
	chunks := []chunkenc.Chunk{chunkenc.NewFloatHistogramChunk()}
	app, err := chunks[0].Appender()
	if err != nil {
		out.Err = err.Error()
		return out
	}
	cut := map[int]bool{}
	for _, i := range in.CutBefore {
		cut[i] = true
	}

	for i, w := range in.Samples {
		h := toFH(w)
		t := int64(i) * 60_000

		// The Head's own cut: a fresh chunk, and the OLD appender handed over as `prev` so the new
		// chunk's header can be derived from the last sample of the old one.
		var prev chunkenc.Appender
		if cut[i] {
			prev = app
			c := chunkenc.NewFloatHistogramChunk()
			a2, err := c.Appender()
			if err != nil {
				out.Err = err.Error()
				return out
			}
			chunks = append(chunks, c)
			app = a2
		}

		newChunk, recoded, newApp, err := app.AppendFloatHistogram(prev, 0, t, h, false)
		if err != nil {
			out.Err = fmt.Sprintf("sample %d: %s", i, err.Error())
			return out
		}
		if newChunk != nil {
			if recoded {
				// **NOT a cut.** A recode rewrites the CURRENT chunk with wider spans and keeps every
				// sample in it; the appender's own `recoded` flag is the only way to tell the two
				// apart, and treating a recode as a cut double-counts the samples already written.
				// The first version of this driver did exactly that and reported three read-back
				// hints for a two-sample case.
				chunks[len(chunks)-1] = newChunk
			} else {
				chunks = append(chunks, newChunk)
			}
		}
		app = newApp
		out.ChunkOf = append(out.ChunkOf, len(chunks)-1)
	}

	for _, c := range chunks {
		out.Headers = append(out.Headers, headerName(c.(*chunkenc.FloatHistogramChunk).GetCounterResetHeader()))
		it := c.Iterator(nil)
		for it.Next() == chunkenc.ValFloatHistogram {
			_, fh := it.AtFloatHistogram(nil)
			out.Hints = append(out.Hints, hintName(fh.CounterResetHint))
		}
		if it.Err() != nil {
			out.Err = it.Err().Error()
			return out
		}
	}
	return out
}

func genChunkMeta(e *emitter) {
	n := 0
	emit := func(samples ...chHist) {
		in := chunkMetaIn{Samples: samples, CutBefore: []int{}}
		e.emit(fmt.Sprintf("chunkmeta/%d", n), in, runChunkMetaCase(in))
		n++
	}
	// The same, with the Head cutting a chunk before the given sample indices.
	emitCut := func(cutBefore []int, samples ...chHist) {
		in := chunkMetaIn{Samples: samples, CutBefore: cutBefore}
		e.emit(fmt.Sprintf("chunkmeta/%d", n), in, runChunkMetaCase(in))
		n++
	}

	// A plain counter histogram with one positive span. `count` doubles as the knob that drives a
	// reset, so it is a parameter and the buckets follow it.
	h := func(count float64, buckets ...float64) chHist {
		w := chHist{
			Schema: 0, Count: fbits(count), Sum: fbits(count),
			ZeroThreshold: fbits(0), ZeroCount: fbits(0),
			PSpans:   []string{fmt.Sprintf("(0,%d)", len(buckets))},
			PBuckets: []string{}, NSpans: []string{}, NBuckets: []string{}, CustomValues: []string{},
		}
		for _, b := range buckets {
			w.PBuckets = append(w.PBuckets, fbits(b))
		}
		return w
	}
	hint := func(w chHist, s string) chHist { w.Hint = s; return w }
	schema := func(w chHist, s int32) chHist { w.Schema = s; return w }

	// Counting up: ONE chunk, and the first sample reads back `unknown` while the rest read
	// `not_reset`. This is the shape every `.test` file's `metric ...x10` load has, and it is why
	// `sum(metric)` at 5m expects `not_reset`.
	emit(h(3, 1, 1, 1), h(6, 2, 2, 2), h(9, 3, 3, 3))
	emit(h(3, 1, 1, 1))
	emit(h(3, 1, 1, 1), h(3, 1, 1, 1))

	// The COUNT GOES BACKWARDS: a new chunk with a `reset` header. Note the sample that starts it
	// reads back `unknown`, not `reset` — the header is not the hint.
	emit(h(3, 1, 1, 1), h(6, 2, 2, 2), h(2, 1, 1, 0), h(4, 2, 1, 1))

	// A SCHEMA CHANGE cuts a chunk with a `not_reset` header: `okToAppend` is false and
	// `counterReset` is false, which is the case that proves they are independent.
	emit(h(3, 1, 1, 1), schema(h(6, 2, 2, 2), 2))
	// A ZERO-THRESHOLD change, the other not-a-reset cut.
	emit(h(3, 1, 1, 1), func() chHist { w := h(6, 2, 2, 2); w.ZeroThreshold = fbits(0.5); return w }())

	// An explicit `reset` hint on a sample whose count did NOT go backwards — honoured anyway,
	// because that check comes before the count.
	emit(h(3, 1, 1, 1), hint(h(6, 2, 2, 2), "reset"))
	// An explicit `not_reset` hint on a sample whose count DID go backwards — NOT honoured, since
	// only `CounterReset` is special-cased.
	emit(h(6, 2, 2, 2), hint(h(3, 1, 1, 1), "not_reset"))

	// GAUGE: every sample reads `gauge`, first one included, and the count may move either way.
	emit(hint(h(3, 1, 1, 1), "gauge"), hint(h(1, 1, 0, 0), "gauge"), hint(h(9, 3, 3, 3), "gauge"))
	// A gauge sample arriving in a counter chunk, and a counter sample in a gauge chunk.
	emit(h(3, 1, 1, 1), hint(h(6, 2, 2, 2), "gauge"))
	emit(hint(h(3, 1, 1, 1), "gauge"), h(6, 2, 2, 2))

	// STALE. A stale sample is appendable whatever its buckets say...
	stale := func() chHist {
		w := h(0)
		w.Sum = fmt.Sprintf("%016x", value.StaleNaN)
		w.PSpans = []string{}
		return w
	}
	emit(h(3, 1, 1, 1), stale(), h(6, 2, 2, 2))
	// ...and after one, only stale samples are.
	emit(stale(), h(3, 1, 1, 1))
	emit(stale(), stale())

	// A BUCKET DISAPPEARS. `expandFloatSpansAndBuckets`' one subtlety: dropping a bucket that was
	// EMPTY is fine, dropping one that was IN USE is a reset — and the two are indistinguishable
	// from the total count, which rises in both cases here.
	twoSpans := func(count float64, b0, b1 float64) chHist {
		w := h(count)
		w.PSpans = []string{"(0,1)", "(1,1)"}
		w.PBuckets = []string{fbits(b0), fbits(b1)}
		return w
	}
	oneSpan := func(count float64, b0 float64) chHist {
		w := h(count)
		w.PSpans = []string{"(0,1)"}
		w.PBuckets = []string{fbits(b0)}
		return w
	}
	// The second bucket was EMPTY and vanishes: not a reset.
	emit(twoSpans(1, 1, 0), oneSpan(2, 2))
	// The second bucket was IN USE and vanishes: a reset, even though the count went UP.
	emit(twoSpans(3, 1, 2), oneSpan(4, 4))
	// A bucket APPEARS, which is ordinary growth in the other direction.
	emit(oneSpan(1, 1), twoSpans(3, 2, 1))
	// A bucket's own count drops while the total rises — the `aCount > bCount` arm.
	emit(twoSpans(3, 2, 1), twoSpans(4, 1, 3))

	// The ZERO COUNT going backwards with the threshold unchanged is a reset.
	zc := func(count, zeroCount float64) chHist {
		w := h(count, 1, 1)
		w.ZeroThreshold = fbits(0.001)
		w.ZeroCount = fbits(zeroCount)
		return w
	}
	emit(zc(4, 2), zc(6, 3))
	emit(zc(4, 2), zc(6, 1))

	// CUSTOM BUCKETS: the same boundaries append, different ones are a reset.
	cb := func(count float64, cv ...float64) chHist {
		w := h(count, 1, 1)
		w.Schema = -53
		w.CustomValues = []string{}
		for _, v := range cv {
			w.CustomValues = append(w.CustomValues, fbits(v))
		}
		return w
	}
	emit(cb(2, 1, 2), cb(4, 1, 2))
	emit(cb(2, 1, 2), cb(4, 1, 3))
	emit(cb(2, 1, 2), cb(4, 1))

	// NEGATIVE buckets, which go through the same expansion independently of the positive ones.
	neg := func(count float64, b0, b1 float64) chHist {
		w := h(count)
		w.NSpans = []string{"(0,1)", "(1,1)"}
		w.NBuckets = []string{fbits(b0), fbits(b1)}
		return w
	}
	emit(neg(3, 1, 2), neg(6, 2, 4))
	emit(neg(3, 1, 2), neg(6, 4, 1))

	// --- The HEAD's cut, which is the ONLY producer of a `NotCounterReset` header.
	//
	// A chunk cut for capacity or time hands the old appender over as `prev`, and the new chunk's
	// header is then `NotCounterReset` or `CounterReset` depending on whether the old chunk's last
	// sample and the new one look like a reset. The internal cut cannot do this — it has no `prev` —
	// so a series that resets mid-chunk and a series cut on a chunk boundary get DIFFERENT headers
	// for the same pair of samples. That asymmetry is upstream's and this is where it is pinned.
	emitCut([]int{2}, h(3, 1, 1, 1), h(6, 2, 2, 2), h(9, 3, 3, 3))
	// Cut, and the sample across the boundary IS a reset.
	emitCut([]int{2}, h(3, 1, 1, 1), h(6, 2, 2, 2), h(2, 1, 1, 0))
	// Cut on a gauge series: the header follows the hint, not the counts.
	emitCut([]int{2}, hint(h(3, 1, 1, 1), "gauge"), hint(h(6, 2, 2, 2), "gauge"), hint(h(1, 1, 0, 0), "gauge"))
	// Cut where the crossing pair changes SCHEMA — `appendable` says not-a-reset, so the header is
	// `not_reset` even though the samples could not have shared a chunk.
	emitCut([]int{2}, h(3, 1, 1, 1), h(6, 2, 2, 2), schema(h(9, 3, 3, 3), 2))
	// Two cuts, so the third chunk's header is derived from the second chunk's single sample.
	emitCut([]int{1, 2}, h(3, 1, 1, 1), h(6, 2, 2, 2), h(9, 3, 3, 3))
	// A cut whose crossing pair drops an IN-USE bucket: a reset the counts alone do not show.
	emitCut([]int{1}, twoSpans(3, 1, 2), oneSpan(4, 4))
	// And one whose crossing pair drops an EMPTY bucket: not a reset.
	emitCut([]int{1}, twoSpans(1, 1, 0), oneSpan(2, 2))

	// --- Cases added because a NEGATIVE CONTROL SURVIVED without them
	// (Scripts/controls-chunkmeta.sh).
	//
	// The MID-LIST vanished bucket. Every earlier case that dropped a bucket dropped the LAST one, so
	// it went through `expandFloatSpansAndBuckets`' `aOK && !bOK` tail branch and the `aIdx < bIdx`
	// branch — the one that has more of `b` still to come — was never reached. Here `a` covers indices
	// 0,1,2 and `b` covers 0 and 2, so index 1 vanishes with `b` continuing past it.
	threeWide := func(count float64, b0, b1, b2 float64) chHist {
		w := h(count)
		w.PSpans = []string{"(0,3)"}
		w.PBuckets = []string{fbits(b0), fbits(b1), fbits(b2)}
		return w
	}
	gapped := func(count float64, b0, b2 float64) chHist {
		w := h(count)
		w.PSpans = []string{"(0,1)", "(1,1)"}
		w.PBuckets = []string{fbits(b0), fbits(b2)}
		return w
	}
	// The vanished middle bucket was IN USE: a reset.
	emit(threeWide(6, 1, 2, 3), gapped(8, 3, 5))
	// The vanished middle bucket was EMPTY: not a reset, just an insert.
	emit(threeWide(4, 1, 0, 3), gapped(8, 3, 5))

	// ZERO-LENGTH SPANS, which are legal and contribute no bucket while still shifting what follows.
	// `bucketIterator` has a dedicated `idx--; continue` for them and nothing reached it.
	zeroLen := func(count float64, b0, b1 float64) chHist {
		w := h(count)
		w.PSpans = []string{"(0,1)", "(2,0)", "(1,1)"}
		w.PBuckets = []string{fbits(b0), fbits(b1)}
		return w
	}
	emit(zeroLen(3, 1, 2), zeroLen(6, 2, 4))
	emit(zeroLen(3, 1, 2), zeroLen(6, 4, 2))
	emit(zeroLen(3, 1, 2), gapped(6, 2, 4))

	// A NON-ZERO FIRST OFFSET. Every case so far started at `(0,n)`, so the iterator's
	// `idx += spans[0].Offset` start was unobservable — dropping it shifted both sides equally.
	offset := func(count float64, off int32, b0, b1 float64) chHist {
		w := h(count)
		w.PSpans = []string{fmt.Sprintf("(%d,2)", off)}
		w.PBuckets = []string{fbits(b0), fbits(b1)}
		return w
	}
	emit(offset(3, 2, 1, 2), offset(6, 2, 2, 4))
	// The two sides start at DIFFERENT offsets, which is what actually needs the offset to be read.
	emit(offset(3, 2, 1, 2), offset(6, 1, 2, 4))
	emit(offset(3, 1, 1, 2), offset(6, 2, 2, 4))
	emit(offset(3, -2, 1, 2), offset(6, 0, 2, 4))

	// The three cases above still left `bucketIterator`'s zero-length-span branch alive: with the same
	// span layout on both sides the phantom buckets line up and cancel. So ENUMERATE instead of
	// hand-picking — every ordered pair of these layouts, with counts that rise, which is the only
	// way to be sure one of them puts a zero-length span on one side of a comparison and not the
	// other. Hand-chosen shapes kept missing it; the cross product cannot.
	layouts := [][]string{
		{"(0,2)"},
		{"(0,1)", "(1,1)"},
		{"(0,1)", "(2,0)", "(1,1)"},
		{"(2,0)", "(0,2)"},
		{"(1,2)"},
		{"(-1,2)"},
		{"(0,1)", "(0,0)", "(0,1)"},
	}
	withLayout := func(count float64, spans []string, bs ...float64) chHist {
		w := h(count)
		w.PSpans = spans
		w.PBuckets = []string{}
		for _, b := range bs {
			w.PBuckets = append(w.PBuckets, fbits(b))
		}
		return w
	}
	for _, la := range layouts {
		for _, lb := range layouts {
			emit(withLayout(3, la, 1, 2), withLayout(9, lb, 3, 6))
			// And with the second sample's per-bucket counts inverted, so the pair straddles the
			// `aCount > bCount` decision as well as the layout one.
			emit(withLayout(3, la, 1, 2), withLayout(9, lb, 6, 3))
		}
	}

	// A long run, to reach whatever capacity rule the chunk has — the position-in-chunk rule is
	// what `counterResetHint` keys on, so where a full chunk cuts is observable.
	long := []chHist{}
	for i := 1; i <= 150; i++ {
		long = append(long, h(float64(i)*3, float64(i), float64(i), float64(i)))
	}
	emit(long...)
}
