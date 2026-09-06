package main

// Differential coverage for tsdb/chunkenc/histogram.go and float_histogram.go — the two native
// histogram chunk encodings — and, through them, for the encoding half of histogram_meta.go
// (`writeHistogramChunkLayout`, `putZeroThreshold`, `putCustomBound`, `expandSpansBothWays`,
// `insert`, `adjustForInserts`), which is unexported and has no other route.
//
// **Driven through the real entry points.** `NewHistogramChunk`, `Appender`, `AppendHistogram`,
// `Bytes`, `NumSamples`, `GetCounterResetHeader`, `Iterator`, `FromData` and `Reset` are all
// exported, so the corpus never assembles a chunk by hand — HANDOFF's §6w harness lesson. Each case
// is a small PROGRAM: a list of samples, plus directives to cut a chunk (so `AppendHistogram`'s
// `prev` argument is exercised, which is the only way `prev.appendable` decides a header) and to
// re-derive the appender from the chunk's own bytes (so the replay path is measured).
//
// What every case records:
//
//   - per append: the error text, `isRecoded`, whether a new chunk came back, and the CALLER'S
//     histogram AFTER the call — because `AppendHistogram` writes through its `*histogram.Histogram`
//     argument on the backward-insert path and the mutation escapes into `memSeries`;
//   - per chunk: the BYTES, `NumSamples`, the counter-reset header;
//   - the samples read back four ways for the integer chunk (`AtHistogram` with and without a reuse
//     buffer, `AtFloatHistogram` with and without) and two ways for the float chunk, because the
//     reuse and non-reuse paths are genuinely different code and the integer chunk's
//     `AtFloatHistogram` is a conversion;
//   - a pass through a REUSED iterator, which is the only route to `Reset`;
//   - `Seek` over a list of targets, which is the only route to the `numRead == 0` clause;
//   - a REPLAY append: `FromData` over the finished bytes, `Appender()`, one more sample. If the
//     replay recovered the wrong encoder state — the leading/trailing window, the bucket deltas, the
//     count deltas — these bytes differ.
//
// ## Corpus design, which is the part that decides what this measures
//
// HANDOFF quirk 59: a corpus from one generator family pins one axis, and the blindness follows the
// dependency's short-circuit order. `appendable` short-circuits in this order — gauge, explicit
// hint, stale, stale, count, schema/threshold, custom bounds, zero count, positive layout, negative
// layout — so a corpus whose count always moves with the shape answers at `h.Count < a.cnt` and never
// looks at a bucket. Every shape below is therefore built so that at least two cases differ in
// exactly ONE field:
//
//   - schema changes (including the RESERVED range 9..52, which the reader reduces to 8, and the
//     negative reserved range -9..-5, which it does not);
//   - custom bucket bounds, TWO DIFFERENT sets rather than one set twice — the bounds comparison is
//     invisible otherwise;
//   - counter resets detected by count, by zero count, and by a bucket going backwards, plus resets
//     only HINTED (`CounterResetHint: CounterReset`) with the numbers unchanged;
//   - gauge histograms, including a gauge sample arriving at a counter chunk and vice versa;
//   - span layouts that force a forward recode, ones that force a backward recode, ones that force
//     BOTH at once, and ones that force neither;
//   - zero-bucket-only changes with the layout fixed;
//   - NaN, ±Inf and stale-NaN sums, and a stale sample in the middle of a run;
//   - the zero threshold at both ends of the one-byte range (2^-243 and 2^10) and one step outside
//     each, plus a non-power-of-two;
//   - custom bounds on both sides of `putCustomBound`'s escape (0, 0.001, 33554.430, 33554.431, a
//     negative, and one that is not a whole multiple of 0.001);
//   - `appendOnly`, which turns every one of the cut decisions into a distinct error string;
//   - a long run, so the varbit dods cross bucket edges and the stream crosses many byte boundaries.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

// MARK: - the wire shapes

type hgcSpan struct {
	Offset int32  `json:"o"`
	Length uint32 `json:"l"`
}

// hgcHist is an INTEGER histogram on the wire. Floats travel as 16-hex-digit bit patterns so NaN,
// the stale NaN and -0 survive (see HANDOFF §4).
type hgcHist struct {
	Hint     int      `json:"hint"`
	Schema   int32    `json:"schema"`
	ZT       string   `json:"zt"`
	ZCount   uint64   `json:"zcount"`
	Count    uint64   `json:"count"`
	Sum      string   `json:"sum"`
	PSpans   []hgcSpan `json:"pspans"`
	NSpans   []hgcSpan `json:"nspans"`
	PBuckets []int64  `json:"pbuckets"`
	NBuckets []int64  `json:"nbuckets"`
	Custom   []string `json:"custom"`
}

// hgcFHist is a FLOAT histogram on the wire.
type hgcFHist struct {
	Hint     int      `json:"hint"`
	Schema   int32    `json:"schema"`
	ZT       string   `json:"zt"`
	ZCount   string   `json:"zcount"`
	Count    string   `json:"count"`
	Sum      string   `json:"sum"`
	PSpans   []hgcSpan `json:"pspans"`
	NSpans   []hgcSpan `json:"nspans"`
	PBuckets []string `json:"pbuckets"`
	NBuckets []string `json:"nbuckets"`
	Custom   []string `json:"custom"`
}

type hgcSample struct {
	T int64   `json:"t"`
	H *hgcHist `json:"h,omitempty"`
}

type hgcFSample struct {
	T int64    `json:"t"`
	H *hgcFHist `json:"h,omitempty"`
}

type hgcIn struct {
	Samples  []hgcSample  `json:"samples,omitempty"`
	FSamples []hgcFSample `json:"fsamples,omitempty"`
	// `appendOnly` refuses rather than cutting or recoding, and each refusal has its own text.
	AppendOnly bool `json:"appendOnly"`
	// Sample indices at which the DRIVER cuts a new chunk itself and hands the old appender over as
	// `prev`. That is what `cutNewHeadChunk` does in the Head, and it is the only route to
	// `AppendHistogram`'s `prev.appendable(...)` branch.
	CutBefore []int `json:"cutBefore,omitempty"`
	// Sample indices at which the appender is re-derived with `chunk.Appender()`, so the encoder
	// state comes from the DECODER rather than from the appender that wrote the samples.
	ReappendBefore []int `json:"reappendBefore,omitempty"`
	// Targets for `Seek`, run over the final chunk.
	Seeks []int64 `json:"seeks,omitempty"`
}

type hgcStep struct {
	Err      string   `json:"err"`
	Recoded  bool     `json:"recoded"`
	NewChunk bool     `json:"newChunk"`
	Bytes    string   `json:"bytes"`
	Num      int      `json:"num"`
	CRH      int      `json:"crh"`
	// The caller's histogram AFTER the call: `AppendHistogram` writes through the pointer.
	HAfter  *hgcHist  `json:"hAfter,omitempty"`
	FHAfter *hgcFHist `json:"fhAfter,omitempty"`
}

type hgcChunkOut struct {
	Bytes string `json:"bytes"`
	Num   int    `json:"num"`
	CRH   int    `json:"crh"`
	// `AtHistogram(nil)` / `AtFloatHistogram(nil)` for the float chunk.
	Samples []hgcSample `json:"samples"`
	// `AtHistogram(reuse)`.
	RSamples []hgcSample `json:"rsamples"`
	// `AtFloatHistogram(nil)`, which for the integer chunk is a conversion.
	FSamples []hgcFSample `json:"fsamples"`
	// `AtFloatHistogram(reuse)`.
	RFSamples []hgcFSample `json:"rfsamples"`
	// Read through an iterator handed back for reuse, i.e. through `Reset`.
	ResetTS []int64 `json:"resetTs"`
	// `AtT()` BEFORE the first `Next`, on a fresh iterator and on a reset one. Upstream calls this
	// "unspecified", and it is the only place the two constructors' asymmetry shows: `newHistogramIterator`
	// starts `t` at `math.MinInt64` and `Reset` starts it at 0.
	PreT      int64 `json:"preT"`
	ResetPreT int64 `json:"resetPreT"`
	Err     string  `json:"err"`
	// The REPLAY: `FromData` over these bytes, `Appender()`, then one more sample.
	ReplayBytes string `json:"replayBytes"`
	ReplayNum   int    `json:"replayNum"`
	ReplayNew   bool   `json:"replayNew"`
	ReplayErr   string `json:"replayErr"`
}

type hgcOut struct {
	Steps  []hgcStep     `json:"steps"`
	Chunks []hgcChunkOut `json:"chunks"`
	// `Seek(target)` over the final chunk: the value type as an int, then the timestamp.
	SeekTypes []int   `json:"seekTypes"`
	SeekTS    []int64 `json:"seekTs"`
}

// MARK: - spec <-> value

func hgcSpansOut(ss []histogram.Span) []hgcSpan {
	if len(ss) == 0 {
		return nil
	}
	out := make([]hgcSpan, len(ss))
	for i, s := range ss {
		out[i] = hgcSpan{Offset: s.Offset, Length: s.Length}
	}
	return out
}

func hgcSpansIn(ss []hgcSpan) []histogram.Span {
	if len(ss) == 0 {
		return nil
	}
	out := make([]histogram.Span, len(ss))
	for i, s := range ss {
		out[i] = histogram.Span{Offset: s.Offset, Length: s.Length}
	}
	return out
}

func hgcFloatsOut(fs []float64) []string {
	if len(fs) == 0 {
		return nil
	}
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = fbits(f)
	}
	return out
}

func hgcFloatsIn(ss []string) []float64 {
	if len(ss) == 0 {
		return nil
	}
	out := make([]float64, len(ss))
	for i, s := range ss {
		out[i] = unfbits(s)
	}
	return out
}

// hgcHistOut SNAPSHOTS the histogram, bucket slices included.
//
// The copy is not defensive tidiness, it is required: `AtHistogram(reuse)` hands back the buffer it
// was given, so two samples read through one reuse buffer are the SAME `*histogram.Histogram` with
// the SAME backing arrays. Recording the slice header would make every earlier sample in the corpus
// show the LAST sample's buckets, and the first run of this suite did exactly that — 83 of 130 cases
// "mismatched" against a port whose only sin was having value semantics. §6w's harness lesson, in a
// new costume: the corpus was measuring Go's aliasing rather than Go's encoding.
func hgcHistOut(h *histogram.Histogram) *hgcHist {
	if h == nil {
		return nil
	}
	return &hgcHist{
		Hint:     int(h.CounterResetHint),
		Schema:   h.Schema,
		ZT:       fbits(h.ZeroThreshold),
		ZCount:   h.ZeroCount,
		Count:    h.Count,
		Sum:      fbits(h.Sum),
		PSpans:   hgcSpansOut(h.PositiveSpans),
		NSpans:   hgcSpansOut(h.NegativeSpans),
		PBuckets: append([]int64(nil), h.PositiveBuckets...),
		NBuckets: append([]int64(nil), h.NegativeBuckets...),
		Custom:   hgcFloatsOut(h.CustomValues),
	}
}

func hgcHistIn(s *hgcHist) *histogram.Histogram {
	if s == nil {
		return nil
	}
	return &histogram.Histogram{
		CounterResetHint: histogram.CounterResetHint(s.Hint),
		Schema:           s.Schema,
		ZeroThreshold:    unfbits(s.ZT),
		ZeroCount:        s.ZCount,
		Count:            s.Count,
		Sum:              unfbits(s.Sum),
		PositiveSpans:    hgcSpansIn(s.PSpans),
		NegativeSpans:    hgcSpansIn(s.NSpans),
		PositiveBuckets:  append([]int64(nil), s.PBuckets...),
		NegativeBuckets:  append([]int64(nil), s.NBuckets...),
		CustomValues:     hgcFloatsIn(s.Custom),
	}
}

func hgcFHistOut(h *histogram.FloatHistogram) *hgcFHist {
	if h == nil {
		return nil
	}
	return &hgcFHist{
		Hint:     int(h.CounterResetHint),
		Schema:   h.Schema,
		ZT:       fbits(h.ZeroThreshold),
		ZCount:   fbits(h.ZeroCount),
		Count:    fbits(h.Count),
		Sum:      fbits(h.Sum),
		PSpans:   hgcSpansOut(h.PositiveSpans),
		NSpans:   hgcSpansOut(h.NegativeSpans),
		PBuckets: hgcFloatsOut(h.PositiveBuckets),
		NBuckets: hgcFloatsOut(h.NegativeBuckets),
		Custom:   hgcFloatsOut(h.CustomValues),
	}
}

func hgcFHistIn(s *hgcFHist) *histogram.FloatHistogram {
	if s == nil {
		return nil
	}
	return &histogram.FloatHistogram{
		CounterResetHint: histogram.CounterResetHint(s.Hint),
		Schema:           s.Schema,
		ZeroThreshold:    unfbits(s.ZT),
		ZeroCount:        unfbits(s.ZCount),
		Count:            unfbits(s.Count),
		Sum:              unfbits(s.Sum),
		PositiveSpans:    hgcSpansIn(s.PSpans),
		NegativeSpans:    hgcSpansIn(s.NSpans),
		PositiveBuckets:  hgcFloatsIn(s.PBuckets),
		NegativeBuckets:  hgcFloatsIn(s.NBuckets),
		CustomValues:     hgcFloatsIn(s.Custom),
	}
}

func hgcContains(xs []int, v int) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func hgcErr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// MARK: - the integer driver

func hgcReadInt(c chunkenc.Chunk) hgcChunkOut {
	out := hgcChunkOut{
		Bytes:     hex.EncodeToString(c.Bytes()),
		Num:       c.NumSamples(),
		Samples:   []hgcSample{},
		RSamples:  []hgcSample{},
		FSamples:  []hgcFSample{},
		RFSamples: []hgcFSample{},
		ResetTS:   []int64{},
	}
	out.CRH = int(c.(*chunkenc.HistogramChunk).GetCounterResetHeader())

	it := c.Iterator(nil)
	for it.Next() == chunkenc.ValHistogram {
		t, h := it.AtHistogram(nil)
		out.Samples = append(out.Samples, hgcSample{T: t, H: hgcHistOut(h)})
	}
	out.Err = hgcErr(it.Err())

	// The reuse buffer, carried across the whole loop the way a real caller does.
	reuse := &histogram.Histogram{}
	it2 := c.Iterator(nil)
	for it2.Next() == chunkenc.ValHistogram {
		t, h := it2.AtHistogram(reuse)
		out.RSamples = append(out.RSamples, hgcSample{T: t, H: hgcHistOut(h)})
	}

	it3 := c.Iterator(nil)
	for it3.Next() == chunkenc.ValHistogram {
		t, fh := it3.AtFloatHistogram(nil)
		out.FSamples = append(out.FSamples, hgcFSample{T: t, H: hgcFHistOut(fh)})
	}

	freuse := &histogram.FloatHistogram{}
	it4 := c.Iterator(nil)
	for it4.Next() == chunkenc.ValHistogram {
		t, fh := it4.AtFloatHistogram(freuse)
		out.RFSamples = append(out.RFSamples, hgcFSample{T: t, H: hgcFHistOut(fh)})
	}

	out.PreT = c.Iterator(nil).AtT()

	// Hand the exhausted iterator back for reuse: that is the only route to `Reset`.
	it5 := c.Iterator(it4)
	out.ResetPreT = it5.AtT()
	for it5.Next() == chunkenc.ValHistogram {
		out.ResetTS = append(out.ResetTS, it5.AtT())
	}
	return out
}

func hgcReplayInt(bytes []byte, last *histogram.Histogram, lastT int64) (string, int, bool, string) {
	c2, err := chunkenc.FromData(chunkenc.EncHistogram, append([]byte(nil), bytes...))
	if err != nil {
		return "", 0, false, hgcErr(err)
	}
	app, err := c2.Appender()
	if err != nil {
		return "", 0, false, hgcErr(err)
	}
	h := last.Copy()
	newChunk, _, _, err := app.AppendHistogram(nil, 0, lastT+1000, h, false)
	return hex.EncodeToString(c2.Bytes()), c2.NumSamples(), newChunk != nil, hgcErr(err)
}

func hgcRunInt(in hgcIn) hgcOut {
	out := hgcOut{Steps: []hgcStep{}, Chunks: []hgcChunkOut{}, SeekTypes: []int{}, SeekTS: []int64{}}

	c := chunkenc.NewHistogramChunk()
	app, err := c.Appender()
	if err != nil {
		out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
		return out
	}
	var prevApp chunkenc.Appender
	var finished []chunkenc.Chunk
	var lastH *histogram.Histogram
	var lastT int64

	for i, s := range in.Samples {
		if hgcContains(in.CutBefore, i) {
			// What `cutNewHeadChunk` does: the CALLER makes the chunk and hands the old appender over.
			finished = append(finished, c)
			prevApp = app
			c = chunkenc.NewHistogramChunk()
			app, err = c.Appender()
			if err != nil {
				out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
				return out
			}
		}
		if hgcContains(in.ReappendBefore, i) {
			app, err = c.Appender()
			if err != nil {
				out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
				return out
			}
		}

		h := hgcHistIn(s.H)
		newChunk, recoded, napp, aerr := app.AppendHistogram(prevApp, 0, s.T, h, in.AppendOnly)
		prevApp = nil
		app = napp
		if newChunk != nil {
			if recoded {
				c = newChunk.(*chunkenc.HistogramChunk)
			} else {
				finished = append(finished, c)
				c = newChunk.(*chunkenc.HistogramChunk)
			}
		}
		if aerr == nil {
			lastH = h
			lastT = s.T
		}
		out.Steps = append(out.Steps, hgcStep{
			Err:      hgcErr(aerr),
			Recoded:  recoded,
			NewChunk: newChunk != nil,
			Bytes:    hex.EncodeToString(c.Bytes()),
			Num:      c.NumSamples(),
			CRH:      int(c.GetCounterResetHeader()),
			HAfter:   hgcHistOut(h),
		})
	}
	finished = append(finished, c)

	for _, fc := range finished {
		co := hgcReadInt(fc)
		// `Compact` is documented as optional and is a no-op for these chunks; calling it must not
		// change the bytes, which the assertion below is.
		fc.Compact()
		co.Bytes = hex.EncodeToString(fc.Bytes())
		if lastH != nil && fc.NumSamples() > 0 {
			co.ReplayBytes, co.ReplayNum, co.ReplayNew, co.ReplayErr =
				hgcReplayInt(fc.Bytes(), lastH, lastT)
		}
		out.Chunks = append(out.Chunks, co)
	}

	if len(in.Seeks) > 0 {
		last := finished[len(finished)-1]
		for _, target := range in.Seeks {
			it := last.Iterator(nil)
			vt := it.Seek(target)
			out.SeekTypes = append(out.SeekTypes, int(vt))
			if vt == chunkenc.ValNone {
				out.SeekTS = append(out.SeekTS, math.MinInt64)
			} else {
				out.SeekTS = append(out.SeekTS, it.AtT())
			}
		}
	}
	return out
}

// MARK: - the float driver

func hgcReadFloat(c *chunkenc.FloatHistogramChunk) hgcChunkOut {
	out := hgcChunkOut{
		Bytes:     hex.EncodeToString(c.Bytes()),
		Num:       c.NumSamples(),
		CRH:       int(c.GetCounterResetHeader()),
		Samples:   []hgcSample{},
		RSamples:  []hgcSample{},
		FSamples:  []hgcFSample{},
		RFSamples: []hgcFSample{},
		ResetTS:   []int64{},
	}

	it := c.Iterator(nil)
	for it.Next() == chunkenc.ValFloatHistogram {
		t, fh := it.AtFloatHistogram(nil)
		out.FSamples = append(out.FSamples, hgcFSample{T: t, H: hgcFHistOut(fh)})
	}
	out.Err = hgcErr(it.Err())

	freuse := &histogram.FloatHistogram{}
	it2 := c.Iterator(nil)
	for it2.Next() == chunkenc.ValFloatHistogram {
		t, fh := it2.AtFloatHistogram(freuse)
		out.RFSamples = append(out.RFSamples, hgcFSample{T: t, H: hgcFHistOut(fh)})
	}

	out.PreT = c.Iterator(nil).AtT()

	it3 := c.Iterator(it2)
	out.ResetPreT = it3.AtT()
	for it3.Next() == chunkenc.ValFloatHistogram {
		out.ResetTS = append(out.ResetTS, it3.AtT())
	}
	return out
}

func hgcReplayFloat(bytes []byte, last *histogram.FloatHistogram, lastT int64) (string, int, bool, string) {
	c2, err := chunkenc.FromData(chunkenc.EncFloatHistogram, append([]byte(nil), bytes...))
	if err != nil {
		return "", 0, false, hgcErr(err)
	}
	app, err := c2.Appender()
	if err != nil {
		return "", 0, false, hgcErr(err)
	}
	h := last.Copy()
	newChunk, _, _, err := app.AppendFloatHistogram(nil, 0, lastT+1000, h, false)
	return hex.EncodeToString(c2.Bytes()), c2.NumSamples(), newChunk != nil, hgcErr(err)
}

func hgcRunFloat(in hgcIn) hgcOut {
	out := hgcOut{Steps: []hgcStep{}, Chunks: []hgcChunkOut{}, SeekTypes: []int{}, SeekTS: []int64{}}

	c := chunkenc.NewFloatHistogramChunk()
	app, err := c.Appender()
	if err != nil {
		out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
		return out
	}
	var prevApp chunkenc.Appender
	var finished []*chunkenc.FloatHistogramChunk
	var lastH *histogram.FloatHistogram
	var lastT int64

	for i, s := range in.FSamples {
		if hgcContains(in.CutBefore, i) {
			finished = append(finished, c)
			prevApp = app
			c = chunkenc.NewFloatHistogramChunk()
			app, err = c.Appender()
			if err != nil {
				out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
				return out
			}
		}
		if hgcContains(in.ReappendBefore, i) {
			app, err = c.Appender()
			if err != nil {
				out.Steps = append(out.Steps, hgcStep{Err: hgcErr(err)})
				return out
			}
		}

		h := hgcFHistIn(s.H)
		newChunk, recoded, napp, aerr := app.AppendFloatHistogram(prevApp, 0, s.T, h, in.AppendOnly)
		prevApp = nil
		app = napp
		if newChunk != nil {
			if recoded {
				c = newChunk.(*chunkenc.FloatHistogramChunk)
			} else {
				finished = append(finished, c)
				c = newChunk.(*chunkenc.FloatHistogramChunk)
			}
		}
		if aerr == nil {
			lastH = h
			lastT = s.T
		}
		out.Steps = append(out.Steps, hgcStep{
			Err:      hgcErr(aerr),
			Recoded:  recoded,
			NewChunk: newChunk != nil,
			Bytes:    hex.EncodeToString(c.Bytes()),
			Num:      c.NumSamples(),
			CRH:      int(c.GetCounterResetHeader()),
			FHAfter:  hgcFHistOut(h),
		})
	}
	finished = append(finished, c)

	for _, fc := range finished {
		co := hgcReadFloat(fc)
		fc.Compact()
		co.Bytes = hex.EncodeToString(fc.Bytes())
		if lastH != nil && fc.NumSamples() > 0 {
			co.ReplayBytes, co.ReplayNum, co.ReplayNew, co.ReplayErr =
				hgcReplayFloat(fc.Bytes(), lastH, lastT)
		}
		out.Chunks = append(out.Chunks, co)
	}

	if len(in.Seeks) > 0 {
		last := finished[len(finished)-1]
		for _, target := range in.Seeks {
			it := last.Iterator(nil)
			vt := it.Seek(target)
			out.SeekTypes = append(out.SeekTypes, int(vt))
			if vt == chunkenc.ValNone {
				out.SeekTS = append(out.SeekTS, math.MinInt64)
			} else {
				out.SeekTS = append(out.SeekTS, it.AtT())
			}
		}
	}
	return out
}

// MARK: - the shapes

// hgcShape is one named sample program in INTEGER form. The float suite derives its corpus from the
// same list plus the float-only shapes below, which is what makes the two encodings comparable
// case by case — and what makes the differences between them (the counter-reset header on a schema
// change, chiefly) show up as a diff rather than as two unrelated corpora.
type hgcShape struct {
	Name string
	In   hgcIn
}

func hgcH(hint histogram.CounterResetHint, schema int32, zt float64, zc, cnt uint64, sum float64,
	pspans []hgcSpan, pbuckets []int64, nspans []hgcSpan, nbuckets []int64, custom []float64,
) *hgcHist {
	return &hgcHist{
		Hint: int(hint), Schema: schema, ZT: fbits(zt), ZCount: zc, Count: cnt, Sum: fbits(sum),
		PSpans: pspans, PBuckets: pbuckets, NSpans: nspans, NBuckets: nbuckets,
		Custom: hgcFloatsOut(custom),
	}
}

// A plain counter histogram: schema 0, one positive span of three buckets.
func hgcBasic(cnt uint64, sum float64, buckets []int64) *hgcHist {
	return hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, cnt, sum,
		[]hgcSpan{{Offset: 0, Length: 3}}, buckets, nil, nil, nil)
}

func hgcShapes() []hgcShape {
	sp := func(o int32, l uint32) hgcSpan { return hgcSpan{Offset: o, Length: l} }
	var out []hgcShape
	add := func(name string, in hgcIn) { out = append(out, hgcShape{Name: name, In: in}) }

	// ---- The three sample positions, one at a time.
	add("empty", hgcIn{})
	add("one", hgcIn{Samples: []hgcSample{{T: 1000, H: hgcBasic(6, 12.5, []int64{2, 1, 3})}}})
	add("two", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12.5, []int64{2, 1, 3})},
		{T: 2000, H: hgcBasic(9, 20.0, []int64{3, 1, 3})},
	}})
	add("three", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12.5, []int64{2, 1, 3})},
		{T: 2000, H: hgcBasic(9, 20.0, []int64{3, 1, 3})},
		{T: 3000, H: hgcBasic(14, 31.0, []int64{5, 1, 3})},
	}})

	// ---- Everything constant except ONE field, so the short-circuit order is measured rather than
	// assumed. The baseline count is FIXED so `h.Count < a.cnt` cannot answer first (quirk 59).
	baseline := hgcBasic(30, 60, []int64{10, 0, 0})
	only := func(name string, second *hgcHist) {
		add("only/"+name, hgcIn{Samples: []hgcSample{
			{T: 1000, H: baseline}, {T: 2000, H: second},
		}})
	}
	only("nothing", hgcBasic(30, 60, []int64{10, 0, 0}))
	only("bucket-up", hgcBasic(30, 60, []int64{11, -1, 0}))
	only("bucket-down", hgcBasic(30, 60, []int64{9, 1, 0}))
	only("sum", hgcBasic(30, 61, []int64{10, 0, 0}))
	only("count-up", hgcBasic(31, 60, []int64{10, 0, 0}))
	only("count-down", hgcBasic(29, 60, []int64{10, 0, 0}))
	only("zerocount-up",
		hgcH(histogram.UnknownCounterReset, 0, 0.001, 5, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("schema-up",
		hgcH(histogram.UnknownCounterReset, 1, 0.001, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("schema-down",
		hgcH(histogram.UnknownCounterReset, -1, 0.001, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("threshold",
		hgcH(histogram.UnknownCounterReset, 0, 0.002, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("hint-reset",
		hgcH(histogram.CounterReset, 0, 0.001, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("hint-notreset",
		hgcH(histogram.NotCounterReset, 0, 0.001, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	only("hint-gauge",
		hgcH(histogram.GaugeType, 0, 0.001, 0, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil))
	// A zero-count DECREASE with the threshold unchanged is a reset; with the threshold changed it is
	// "unknown" instead. Two cases that differ only in the threshold.
	add("only/zerocount-down", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 5, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 1, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil)},
	}})
	add("only/zerocount-down-and-threshold", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 5, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.004, 1, 30, 60, []hgcSpan{sp(0, 3)}, []int64{10, 0, 0}, nil, nil, nil)},
	}})

	// ---- Span layouts. Forward only, backward only, both, and neither.
	//
	// A FORWARD insert means the sample has a bucket the chunk does not, so the CHUNK is recoded. A
	// BACKWARD insert means the chunk has an EMPTY bucket the sample does not, so the SAMPLE is
	// widened. Isolating one from the other needs the empty-bucket rule, and the trap is that integer
	// buckets are DELTAS: `[3, 0, 0]` is three buckets of 3, not one of 3 and two empties. To make a
	// bucket vanishable its RUNNING count has to be zero, which is `[3, -3, 0]`. The first version of
	// these two cases used `[3, 0, 0]` and produced a counter reset instead of a backward insert —
	// the corpus said so, which is the whole point of committing the header alongside the bytes.
	add("layout/forward", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 0, 3}, nil, nil, nil)},
	}})
	add("layout/backward", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 3, 6, []hgcSpan{sp(0, 3)}, []int64{3, -3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 4, 8, []hgcSpan{sp(0, 1)}, []int64{4}, nil, nil, nil)},
	}})
	add("layout/both", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 3, 6, []hgcSpan{sp(0, 2)}, []int64{3, -3}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 6, 12, []hgcSpan{sp(0, 1), sp(1, 1)}, []int64{4, -2}, nil, nil, nil)},
	}})
	add("layout/backward-run", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 5, 10, []hgcSpan{sp(0, 5)}, []int64{5, -5, 0, 0, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 6, 12, []hgcSpan{sp(0, 1)}, []int64{6}, nil, nil, nil)},
	}})
	add("layout/backward-split", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 8, 16, []hgcSpan{sp(0, 5)}, []int64{5, -5, 3, -3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 9, 18, []hgcSpan{sp(0, 1), sp(1, 1)}, []int64{6, -3}, nil, nil, nil)},
	}})

	// ---- Two Insert entries at the SAME `pos`, which is the only thing `insert`'s `firstInsert`
	// flag and `addInsert`'s continuity test can be told apart by. `addInsert` merges consecutive
	// inserted indices into one entry and starts a NEW entry — with the same `pos` — when they are
	// not contiguous, so a sample that adds two buckets at non-adjacent indices before the same old
	// bucket produces exactly that. Three controls survived until these two cases existed.
	//
	// `mid`: the chunk covers {0, 6} and the sample covers {0, 2, 4, 6}, so the inserts at indices 2
	// and 4 are both at `pos` 1 and the running value there is NOT zero — which is what makes
	// `-v`-versus-0 observable.
	add("layout/two-inserts-one-pos", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 6, 12, []hgcSpan{sp(0, 1), sp(5, 1)}, []int64{3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 16, 32, []hgcSpan{sp(0, 1), sp(1, 1), sp(1, 1), sp(1, 1)}, []int64{4, 0, 0, 0}, nil, nil, nil)},
	}})
	// `trailing`: the chunk covers {0} and the sample covers {0, 2, 4}, so both inserts are PAST the
	// end of the input and land in `insert`'s trailing loop — where `v = 0` between entries is the
	// line under test.
	add("layout/two-trailing-inserts", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 3, 6, []hgcSpan{sp(0, 1)}, []int64{3}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 12, 24, []hgcSpan{sp(0, 1), sp(1, 1), sp(1, 1)}, []int64{4, 0, 0}, nil, nil, nil)},
	}})
	// A bucket that is IN USE in the chunk and missing from the sample: a counter reset, and the only
	// case that separates the `aCount == 0` test in the `aIdx < bIdx` arm from an unconditional
	// backward insert.
	add("layout/used-bucket-vanishes", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 7, 14, []hgcSpan{sp(0, 2)}, []int64{3, 1}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 1), sp(1, 1)}, []int64{5, 0}, nil, nil, nil)},
	}})
	// A backward insert RUN (num > 1) alongside a forward insert, so `adjustForInserts` is reached
	// with a multi-bucket insert — the branch where `insertIdx` has to advance within the run.
	add("layout/backward-run-with-forward", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 5, 10, []hgcSpan{sp(0, 3), sp(2, 1)}, []int64{3, -3, 0, 2}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 11, 22, []hgcSpan{sp(0, 1), sp(4, 1), sp(1, 1)}, []int64{4, -1, 1}, nil, nil, nil)},
	}})
	// Backward inserts at NON-CONTIGUOUS indices, plus a forward insert so `adjustForInserts` runs.
	// `addInsert`'s continuity test is what splits them into two `Insert` entries, and only
	// `adjustForInserts` can see the difference: `insert` reads `pos` and `num` and never `bucketIdx`,
	// so two entries of one and one entry of two produce the same buckets. The control for that test
	// survived the whole first sweep for exactly that reason. Here the chunk covers {0, 1, 5, 8} with
	// 1 and 5 empty and the sample covers {0, 8, 10}, so the backward inserts are at 1 and 5 — merging
	// them would put the second at 2.
	add("layout/discontinuous-backward", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 5, 10, []hgcSpan{sp(0, 2), sp(3, 1), sp(2, 1)}, []int64{3, -3, 0, 2}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 11, 22, []hgcSpan{sp(0, 1), sp(7, 1), sp(1, 1)}, []int64{4, -1, 1}, nil, nil, nil)},
	}})
	add("layout/prepend", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 3, 6, []hgcSpan{sp(2, 2)}, []int64{3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 9, 18, []hgcSpan{sp(0, 4)}, []int64{2, 0, 1, 0}, nil, nil, nil)},
	}})
	add("layout/split-span", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 4, 8, []hgcSpan{sp(0, 1), sp(3, 1)}, []int64{2, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 12, 24, []hgcSpan{sp(0, 5)}, []int64{2, 1, 1, 1, -1}, nil, nil, nil)},
	}})
	add("layout/zero-length-span", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 3, 6, []hgcSpan{sp(0, 1), sp(2, 0), sp(1, 1)}, []int64{2, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 5, 10, []hgcSpan{sp(0, 1), sp(2, 0), sp(1, 1)}, []int64{3, 0}, nil, nil, nil)},
	}})
	add("layout/negative-buckets", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 1, 8, 4, []hgcSpan{sp(0, 2)}, []int64{2, 0}, []hgcSpan{sp(0, 2)}, []int64{2, 1}, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 1, 13, 8, []hgcSpan{sp(0, 3)}, []int64{2, 0, 2}, []hgcSpan{sp(0, 2)}, []int64{3, 1}, nil)},
	}})
	add("layout/negative-only", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 5, -5, nil, nil, []hgcSpan{sp(-2, 2)}, []int64{3, -1}, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 8, -9, nil, nil, []hgcSpan{sp(-2, 3)}, []int64{3, -1, 3}, nil)},
	}})
	add("layout/no-buckets-at-all", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 4, 4, 1, nil, nil, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 7, 7, 2, nil, nil, nil, nil, nil)},
	}})

	// ---- Custom bucket bounds. TWO DIFFERENT sets, not one set twice, which is what makes
	// `CustomBucketBoundsMatch` observable at all (quirk 59's second instance).
	cb := func(bounds []float64, cnt uint64, buckets []int64) *hgcHist {
		return hgcH(histogram.UnknownCounterReset, -53, 0, 0, cnt, float64(cnt),
			[]hgcSpan{sp(0, uint32(len(buckets)))}, buckets, nil, nil, bounds)
	}
	add("custom/same", hgcIn{Samples: []hgcSample{
		{T: 1000, H: cb([]float64{1, 2, 5}, 6, []int64{2, 1, 1})},
		{T: 2000, H: cb([]float64{1, 2, 5}, 9, []int64{3, 1, 1})},
	}})
	add("custom/different-bounds", hgcIn{Samples: []hgcSample{
		{T: 1000, H: cb([]float64{1, 2, 5}, 6, []int64{2, 1, 1})},
		{T: 2000, H: cb([]float64{1, 2, 10}, 9, []int64{3, 1, 1})},
	}})
	add("custom/more-bounds", hgcIn{Samples: []hgcSample{
		{T: 1000, H: cb([]float64{1, 2, 5}, 6, []int64{2, 1, 1})},
		{T: 2000, H: cb([]float64{1, 2, 5, 10}, 10, []int64{3, 1, 1, 1})},
	}})
	add("custom/no-bounds", hgcIn{Samples: []hgcSample{
		{T: 1000, H: cb(nil, 0, nil)},
	}})
	// `putCustomBound`'s escape, both sides of every edge it has.
	for i, bounds := range [][]float64{
		{0},
		{0.001},
		{0.0005},    // not a whole multiple of 0.001 -> the 8-byte escape
		{33554.430}, // the last varbit-representable value
		{33554.431}, // one step past it -> the escape
		{-1},        // negative -> the escape
		{math.Inf(1)},
		{1, 2, 4, 8, 16, 32, 64, 128},
		// 1.001 is a WITNESS, harvested for `isWholeWhenMultiplied`'s rounding. `1.001 * 1000` is
		// `1000.9999999999999` in float64, so `math.Round` gives 1001 and the bound encodes in a
		// varbit, while a floor would give 1000, decide the bound is not a whole multiple of 0.001,
		// and spend nine bytes on it. Every other bound in this corpus multiplies exactly, so the
		// control for that rounding survived until this line existed.
		{1.001},
		{0.001, 1.001, 2.003, 5.007},
	} {
		bk := make([]int64, len(bounds))
		for j := range bk {
			bk[j] = 1
		}
		add(fmt.Sprintf("custom/bound-%d", i), hgcIn{Samples: []hgcSample{
			{T: 1000, H: cb(bounds, uint64(len(bounds)), bk)},
			{T: 2000, H: cb(bounds, uint64(len(bounds))*2, bk)},
		}})
	}

	// ---- The zero threshold's one-byte range, both ends and both sides of both ends.
	for i, zt := range []float64{
		0,                    // the single zero byte
		math.Ldexp(1, -243),  // the low end of the one-byte range
		math.Ldexp(1, -244),  // one step below -> 9 bytes
		math.Ldexp(1, 10),    // the high end
		math.Ldexp(1, 11),    // one step above -> 9 bytes
		math.Ldexp(1, -128),  // the DEFAULT zero threshold, byte 116
		0.003,                // not a power of two -> 9 bytes
		math.Inf(1),
	} {
		add(fmt.Sprintf("threshold/%d", i), hgcIn{Samples: []hgcSample{
			{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, zt, 1, 4, 8, []hgcSpan{sp(0, 2)}, []int64{2, 0}, nil, nil, nil)},
			{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, zt, 2, 6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0}, nil, nil, nil)},
		}})
	}

	// ---- Schemas, including both reserved ranges. 9..52 is reduced to 8 by the READER, so a chunk
	// written at schema 9 reads back at schema 8 with merged buckets; -9..-5 is known and is NOT
	// reduced. Both need cases or the reduce arm is invisible.
	for _, schema := range []int32{-4, -1, 0, 3, 8, 9, 20, 52, -5, -9, -53} {
		var custom []float64
		spans := []hgcSpan{sp(0, 4)}
		if schema == -53 {
			custom = []float64{1, 2, 4, 8}
		}
		add(fmt.Sprintf("schema/%d", schema), hgcIn{Samples: []hgcSample{
			{T: 1000, H: hgcH(histogram.UnknownCounterReset, schema, 0.001, 0, 10, 20, spans, []int64{4, -1, 2, 0}, nil, nil, custom)},
			{T: 2000, H: hgcH(histogram.UnknownCounterReset, schema, 0.001, 0, 16, 32, spans, []int64{6, -1, 2, 0}, nil, nil, custom)},
		}})
	}

	// ---- Gauge histograms. `expandSpansBothWays` never fails, so a gauge chunk absorbs layouts a
	// counter chunk would reject — including one with NO overlap at all.
	g := func(cnt uint64, sum float64, spans []hgcSpan, buckets []int64) *hgcHist {
		return hgcH(histogram.GaugeType, 0, 0.001, 0, cnt, sum, spans, buckets, nil, nil, nil)
	}
	add("gauge/steady", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 3)}, []int64{2, 1, 0})},
		{T: 2000, H: g(4, 8, []hgcSpan{sp(0, 3)}, []int64{2, -1, 1})},
		{T: 3000, H: g(9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 1})},
	}})
	add("gauge/shrink", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 1})},
		{T: 2000, H: g(1, 2, []hgcSpan{sp(0, 3)}, []int64{1, 0, 0})},
	}})
	add("gauge/disjoint-layout", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0})},
		{T: 2000, H: g(5, 10, []hgcSpan{sp(5, 2)}, []int64{2, 1})},
	}})
	add("gauge/grow-and-shrink", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0})},
		{T: 2000, H: g(9, 18, []hgcSpan{sp(0, 4)}, []int64{3, 0, 2, 1})},
		{T: 3000, H: g(4, 8, []hgcSpan{sp(1, 1)}, []int64{4})},
	}})
	add("gauge/schema-change", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0})},
		{T: 2000, H: hgcH(histogram.GaugeType, 2, 0.001, 0, 6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0}, nil, nil, nil)},
	}})
	// A gauge sample arriving at a counter chunk, and a counter sample arriving at a gauge chunk.
	add("gauge/into-counter-chunk", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: g(9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 3})},
	}})
	add("gauge/counter-into-gauge-chunk", hgcIn{Samples: []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 3)}, []int64{2, 1, 3})},
		{T: 2000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
	}})

	// ---- Stale NaN. The appender replaces the sample with `{Sum: staleNaN}` and forces the count
	// dods to zero while KEEPING the computed deltas, so encoder and decoder state disagree from
	// here on — which the replay output shows.
	stale := hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 0, math.Float64frombits(value.StaleNaN), nil, nil, nil, nil, nil)
	add("stale/first", hgcIn{Samples: []hgcSample{{T: 1000, H: stale}}})
	add("stale/second", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: stale},
	}})
	add("stale/middle", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: stale},
		{T: 3000, H: hgcBasic(12, 24, []int64{4, 1, 3})},
	}})
	add("stale/run", hgcIn{Samples: []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: stale},
		{T: 3000, H: stale},
		{T: 4000, H: stale},
	}})
	add("stale/after-reappend", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
			{T: 2000, H: stale},
			{T: 3000, H: hgcBasic(12, 24, []int64{4, 1, 3})},
		},
		ReappendBefore: []int{2},
	})

	// ---- Special sums, whose bit patterns drive the XOR.
	for i, sum := range []float64{
		math.NaN(), math.Inf(1), math.Inf(-1), math.Copysign(0, -1), 0,
		math.Float64frombits(1), math.Float64frombits(1<<63 | 1),
	} {
		add(fmt.Sprintf("sum/%d", i), hgcIn{Samples: []hgcSample{
			{T: 1000, H: hgcBasic(6, sum, []int64{2, 1, 3})},
			{T: 2000, H: hgcBasic(9, sum, []int64{3, 1, 3})},
			{T: 3000, H: hgcBasic(12, -sum, []int64{4, 1, 3})},
		}})
	}

	// ---- Timestamp dods across the varbit bucket edges, both signs and both sides. `bitRange` is
	// asymmetric, so `-((1<<(n-1))-1) … 1<<(n-1)`.
	for _, dod := range []int64{
		0, 1, -1, 4, 5, -3, -4, 32, 33, -31, -32,
		256, 257, -255, -256, 2048, 2049, -2047, -2048,
		131072, 131073, 16777216, -16777216,
		1 << 40, -(1 << 40),
	} {
		add(fmt.Sprintf("tdod/%d", dod), hgcIn{Samples: []hgcSample{
			{T: 0, H: hgcBasic(3, 6, []int64{1, 1, 1})},
			{T: 10000, H: hgcBasic(6, 12, []int64{2, 1, 1})},
			{T: 20000, H: hgcBasic(9, 18, []int64{3, 1, 1})},
			{T: 30000 + dod, H: hgcBasic(12, 24, []int64{4, 1, 1})},
		}})
	}

	// ---- Count dods across the same edges, which travel through `putVarbitInt` too.
	for _, d := range []int64{1, 4, 5, 32, 33, 2048, 2049, 1 << 30} {
		add(fmt.Sprintf("cntdod/%d", d), hgcIn{Samples: []hgcSample{
			{T: 1000, H: hgcBasic(100, 200, []int64{50, 0, 0})},
			{T: 2000, H: hgcBasic(200, 400, []int64{100, 0, 0})},
			{T: 3000, H: hgcBasic(uint64(300+d), 600, []int64{150, 0, 0})},
		}})
	}

	// ---- `prev`: a chunk the CALLER cut, with the previous appender handed over. That is the only
	// route to `AppendHistogram`'s `prev.appendable(h)` branch, and its answer is the new chunk's
	// header. Four cases so the four possible headers all appear.
	add("prev/continues", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
			{T: 2000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
		},
		CutBefore: []int{1},
	})
	add("prev/reset-by-count", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(60, 120, []int64{20, 1, 3})},
			{T: 2000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
		},
		CutBefore: []int{1},
	})
	add("prev/schema-change", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
			{T: 2000, H: hgcH(histogram.UnknownCounterReset, 2, 0.001, 0, 9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 3}, nil, nil, nil)},
		},
		CutBefore: []int{1},
	})
	add("prev/gauge", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 3)}, []int64{2, 1, 3})},
			{T: 2000, H: g(9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 3})},
		},
		CutBefore: []int{1},
	})
	add("prev/stale-then-fresh", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
			{T: 2000, H: stale},
			{T: 3000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
		},
		CutBefore: []int{2},
	})

	// ---- The replay path on its own: re-derive the appender at every position, including at
	// exactly ONE sample, where the recovered `leading` is 0 rather than the fresh appender's 0xff.
	for _, k := range []int{1, 2, 3} {
		add(fmt.Sprintf("reappend/%d", k), hgcIn{
			Samples: []hgcSample{
				{T: 1000, H: hgcBasic(6, 12.25, []int64{2, 1, 3})},
				{T: 2000, H: hgcBasic(9, 20.5, []int64{3, 1, 3})},
				{T: 3000, H: hgcBasic(14, 31.75, []int64{5, 1, 3})},
				{T: 4000, H: hgcBasic(20, 44.125, []int64{7, 1, 4})},
			},
			ReappendBefore: []int{k},
		})
	}

	// ---- `appendOnly`, which turns each cut decision into its own error string.
	appendOnly := func(name string, samples []hgcSample) {
		add("appendonly/"+name, hgcIn{Samples: samples, AppendOnly: true})
	}
	appendOnly("counter-reset", []hgcSample{
		{T: 1000, H: hgcBasic(60, 120, []int64{20, 1, 3})},
		{T: 2000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
	})
	appendOnly("schema-change", []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 2, 0.001, 0, 9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 1, 3}, nil, nil, nil)},
	})
	appendOnly("forward-inserts", []hgcSample{
		{T: 1000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0}, nil, nil, nil)},
		{T: 2000, H: hgcH(histogram.UnknownCounterReset, 0, 0.001, 0, 9, 18, []hgcSpan{sp(0, 3)}, []int64{3, 0, 3}, nil, nil, nil)},
	})
	appendOnly("gauge-schema-change", []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0})},
		{T: 2000, H: hgcH(histogram.GaugeType, 2, 0.001, 0, 6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0}, nil, nil, nil)},
	})
	appendOnly("gauge-backward-inserts", []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 3)}, []int64{3, 0, 0})},
		{T: 2000, H: g(4, 8, []hgcSpan{sp(0, 1)}, []int64{4})},
	})
	appendOnly("gauge-forward-inserts", []hgcSample{
		{T: 1000, H: g(6, 12, []hgcSpan{sp(0, 2)}, []int64{3, 0})},
		{T: 2000, H: g(9, 18, []hgcSpan{sp(0, 4)}, []int64{3, 0, 2, 1})},
	})
	appendOnly("fits", []hgcSample{
		{T: 1000, H: hgcBasic(6, 12, []int64{2, 1, 3})},
		{T: 2000, H: hgcBasic(9, 18, []int64{3, 1, 3})},
	})

	// ---- Seek, whose loop condition is `t > it.t || it.numRead == 0` — so seeking to a timestamp
	// at or below the first sample still advances once, and that clause needs a case.
	add("seek", hgcIn{
		Samples: []hgcSample{
			{T: 1000, H: hgcBasic(3, 6, []int64{1, 1, 1})},
			{T: 2000, H: hgcBasic(6, 12, []int64{2, 1, 1})},
			{T: 3000, H: hgcBasic(9, 18, []int64{3, 1, 1})},
		},
		Seeks: []int64{math.MinInt64, 0, 999, 1000, 1001, 2000, 3000, 3001, math.MaxInt64},
	})

	// ---- A long run, so the stream crosses many byte boundaries in every phase of `count`'s
	// arithmetic and the varbit dods keep moving between buckets.
	longRun := []hgcSample{}
	cnt := uint64(0)
	for i := range 60 {
		cnt += uint64(i%7) + 1
		longRun = append(longRun, hgcSample{
			T: int64(i)*15000 + int64(i%5),
			H: hgcH(histogram.UnknownCounterReset, 1, math.Ldexp(1, -128), uint64(i/3), cnt,
				math.Sin(float64(i))*float64(i),
				[]hgcSpan{sp(0, 3), sp(2, 2)},
				[]int64{int64(i % 5), 1, -1, int64(i % 3), 0},
				[]hgcSpan{sp(-1, 2)},
				[]int64{int64(i % 4), -1}, nil),
		})
	}
	add("long", hgcIn{Samples: longRun})

	return out
}

func genChunkEncHistogram(e *emitter) {
	for _, s := range hgcShapes() {
		e.emit("histogram/"+s.Name, s.In, hgcRunInt(s.In))
	}
}

// The float suite reuses every integer shape by converting it sample by sample, then adds the shapes
// only a float histogram can have. Sharing the list is deliberate: the two encodings then differ in
// the fixture exactly where they differ in Go, which is what makes the counter-reset-header
// asymmetry (integer says "unknown" on a schema change, float says "not a reset") a visible diff
// rather than a fact buried in two unrelated corpora.
func hgcFloatShapes() []hgcShape {
	var out []hgcShape
	for _, s := range hgcShapes() {
		fs := make([]hgcFSample, 0, len(s.In.Samples))
		for _, smp := range s.In.Samples {
			h := hgcHistIn(smp.H)
			var fh *histogram.FloatHistogram
			if h != nil {
				fh = h.ToFloat(nil)
			}
			fs = append(fs, hgcFSample{T: smp.T, H: hgcFHistOut(fh)})
		}
		in := s.In
		in.Samples = nil
		in.FSamples = fs
		out = append(out, hgcShape{Name: s.Name, In: in})
	}

	sp := func(o int32, l uint32) hgcSpan { return hgcSpan{Offset: o, Length: l} }
	fh := func(hint histogram.CounterResetHint, schema int32, zt, zc, cnt, sum float64,
		pspans []hgcSpan, pbuckets []float64, custom []float64,
	) *hgcFHist {
		return &hgcFHist{
			Hint: int(hint), Schema: schema, ZT: fbits(zt), ZCount: fbits(zc), Count: fbits(cnt),
			Sum: fbits(sum), PSpans: pspans, PBuckets: hgcFloatsOut(pbuckets),
			Custom: hgcFloatsOut(custom),
		}
	}
	add := func(name string, in hgcIn) { out = append(out, hgcShape{Name: name, In: in}) }

	// ---- FRACTIONAL counts, which is the whole point of the float encoding and which no converted
	// integer shape can produce. Every count and bucket is XOR encoded here, so the leading/trailing
	// windows move per FIELD rather than only on the sum.
	add("float/fractional", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0.5, 6.25, 12.5, []hgcSpan{sp(0, 3)}, []float64{2.5, 2.25, 1}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0.5, 9.75, 20.25, []hgcSpan{sp(0, 3)}, []float64{4, 3.75, 1.5}, nil)},
		{T: 3000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 1.25, 14.5, 31, []hgcSpan{sp(0, 3)}, []float64{6, 5.25, 2}, nil)},
	}})
	// A fractional count that goes DOWN by a hair — the reset test is `<`, so this is a reset while
	// an equal count is not.
	add("float/tiny-decrease", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, math.Nextafter(10, 0), 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
	}})
	add("float/equal-counts", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
	}})
	// A single BUCKET going backwards while the total count rises: only the per-bucket walk can see
	// this, so it is the case that separates `expandFloatSpansAndBuckets` from the count test above.
	add("float/bucket-backwards", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 12, 24, []hgcSpan{sp(0, 2)}, []float64{9, 3}, nil)},
	}})
	// NaN and ±Inf in a COUNT and in a BUCKET, not only in the sum — the integer encoding cannot do
	// this at all, and every comparison in `appendable` is a float comparison here.
	for i, v := range []float64{math.NaN(), math.Inf(1), math.Inf(-1), math.Copysign(0, -1)} {
		add(fmt.Sprintf("float/special-count-%d", i), hgcIn{FSamples: []hgcFSample{
			{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
			{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, v, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
		}})
		add(fmt.Sprintf("float/special-bucket-%d", i), hgcIn{FSamples: []hgcFSample{
			{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 5}, nil)},
			{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 12, 24, []hgcSpan{sp(0, 2)}, []float64{v, 5}, nil)},
		}})
	}
	// A zero bucket that is fractional, so the zero-count comparison is a float one.
	add("float/fractional-zero", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0.5, 10, 20, []hgcSpan{sp(0, 2)}, []float64{5, 4.5}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0.25, 12, 24, []hgcSpan{sp(0, 2)}, []float64{6, 5.75}, nil)},
	}})
	// Values whose XOR deltas force every window path: identical, a reusable window, a brand new one.
	add("float/xor-windows", hgcIn{FSamples: []hgcFSample{
		{T: 1000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 1, 1, []hgcSpan{sp(0, 2)}, []float64{1, 0}, nil)},
		{T: 2000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 1, 1, []hgcSpan{sp(0, 2)}, []float64{1, 0}, nil)},
		{T: 3000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 1.0000001, 1.0000002, []hgcSpan{sp(0, 2)}, []float64{1.0000001, 0}, nil)},
		{T: 4000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 1e300, 1e300, []hgcSpan{sp(0, 2)}, []float64{1e300, 0}, nil)},
		{T: 5000, H: fh(histogram.UnknownCounterReset, 0, 0.001, 0, 1e300, 1e300, []hgcSpan{sp(0, 2)}, []float64{1e300, 1}, nil)},
	}})
	return out
}

func genChunkEncFloatHistogram(e *emitter) {
	for _, s := range hgcFloatShapes() {
		e.emit("float-histogram/"+s.Name, s.In, hgcRunFloat(s.In))
	}
}
