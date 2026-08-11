package main

// Differential coverage for tsdb/chunkenc/xor2.go — and, through it, for varbit.go.
//
// Same seam as chunkenc/xor (§6a): the chunk's bytes are the encoding, so comparing them checks every
// bit the writers produced and iterating them back checks every bit the readers consume. XOR2 adds
// `AtST()`, which is the whole reason the encoding exists, and the ST deltas are what exercise
// `putVarbitIntFast`/`readVarbitInt` — HANDOFF §6c said varbit could only be pinned this way.
//
// What has to be reached, from the plan in §6b:
//   - all six joint control prefixes, including BOTH stale-NaN spellings (the `11111` whole-sample one
//     and the `111` value code) which differ by whether the timestamp moved;
//   - the 13/20/64-bit dod bins, both signs, both sides of each edge. These are ordinary two's
//     complement (-(1<<12) … (1<<12)-1), NOT XOR's asymmetric bitRange;
//   - no ST at all; ST from sample 0; ST first changing at sample k for k around the 0x7F boundary; ST
//     changing every sample. Sample 127 is a distinct branch, not an edge case;
//   - the three encoding paths in `default`, which means cases that stay in each and cases that cross
//     between them;
//   - the ST-delta varbit buckets, which is varbit's only route to a corpus;
//   - append-while-reading, as §6a's suite does, since XOR2's Appender restores more state.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

type xor2Sample struct {
	ST int64  `json:"st"`
	T  int64  `json:"t"`
	V  string `json:"v"`
}

type xor2In struct {
	Samples   []xor2Sample `json:"samples"`
	SplitAt   int          `json:"splitAt"`
	ReadFirst int          `json:"readFirst"`
}

type xor2ReadSample struct {
	ST int64  `json:"st"`
	T  int64  `json:"t"`
	V  string `json:"v"`
}

type xor2Out struct {
	Bytes      string           `json:"bytes"`
	NumSamples int              `json:"numSamples"`
	STHeader   uint8            `json:"stHeader"`
	Read       []xor2ReadSample `json:"read"`
	// The replay check: a fresh appender over the same bytes plus one more sample.
	ReplayBytes string `json:"replayBytes"`
	Err         string `json:"err"`
}

func genChunkEncXOR2(e *emitter) {
	n := 0

	build := func(in xor2In) xor2Out {
		out := xor2Out{Read: []xor2ReadSample{}}
		c := chunkenc.NewXOR2Chunk()
		app, err := c.Appender()
		if err != nil {
			out.Err = err.Error()
			return out
		}
		split := in.SplitAt
		if split == 0 {
			split = len(in.Samples)
		}
		for _, s := range in.Samples[:split] {
			app.Append(s.ST, s.T, unfbits(s.V))
		}
		it := c.Iterator(nil)
		for range in.ReadFirst {
			if it.Next() != chunkenc.ValFloat {
				break
			}
			t, v := it.At()
			out.Read = append(out.Read, xor2ReadSample{ST: it.AtST(), T: t, V: fbits(v)})
		}
		for _, s := range in.Samples[split:] {
			app.Append(s.ST, s.T, unfbits(s.V))
		}
		for it.Next() == chunkenc.ValFloat {
			t, v := it.At()
			out.Read = append(out.Read, xor2ReadSample{ST: it.AtST(), T: t, V: fbits(v)})
		}
		if it.Err() != nil {
			out.Err = it.Err().Error()
		}
		out.Bytes = hex.EncodeToString(c.Bytes())
		out.NumSamples = c.NumSamples()
		if len(c.Bytes()) > 2 {
			out.STHeader = c.Bytes()[2]
		}

		// Replay: rebuild from the bytes and append one more.
		if len(in.Samples) > 0 && in.SplitAt == 0 {
			c3 := chunkenc.NewXOR2Chunk()
			c3.Reset(c.Bytes())
			app3, err3 := c3.Appender()
			if err3 != nil {
				out.Err = err3.Error()
			} else {
				last := in.Samples[len(in.Samples)-1]
				st := last.ST
				if st != 0 {
					st += 500
				}
				app3.Append(st, last.T+1000, unfbits(last.V)+1)
				out.ReplayBytes = hex.EncodeToString(c3.Bytes())
			}
		}
		return out
	}

	emit := func(samples []xor2Sample) {
		in := xor2In{Samples: samples}
		e.emit(fmt.Sprintf("xor2/%d", n), in, build(in))
		n++
	}
	emitSplit := func(samples []xor2Sample, splitAt, readFirst int) {
		in := xor2In{Samples: samples, SplitAt: splitAt, ReadFirst: readFirst}
		e.emit(fmt.Sprintf("xor2/%d", n), in, build(in))
		n++
	}

	s := func(t int64, v float64) xor2Sample { return xor2Sample{ST: 0, T: t, V: fbits(v)} }
	sst := func(st, t int64, v float64) xor2Sample { return xor2Sample{ST: st, T: t, V: fbits(v)} }
	stale := math.Float64frombits(value.StaleNaN)

	// --- No ST at all: the header stays 0x00 and there are no ST bits.
	emit(nil)
	emit([]xor2Sample{s(0, 1)})
	emit([]xor2Sample{s(0, 1), s(1000, 1)})
	emit([]xor2Sample{s(0, 1), s(1000, 2)})
	emit([]xor2Sample{s(0, 1), s(1000, 2), s(2000, 3)})
	emit([]xor2Sample{s(0, 1), s(1000, 1), s(2000, 1), s(3000, 1)})

	// A steady run, so control code 0 (dod=0, value unchanged) dominates.
	steady := []xor2Sample{}
	for i := range 30 {
		steady = append(steady, s(int64(i)*15000, 42))
	}
	emit(steady)
	// Steady timestamps, moving values: control code 1 (dod=0, value changed).
	moving := []xor2Sample{}
	for i := range 30 {
		moving = append(moving, s(int64(i)*15000, float64(i)*1.25))
	}
	emit(moving)

	// --- The dod bins, both signs, both sides. These are two's complement, not bitRange.
	for _, dod := range []int64{
		1, -1,
		(1 << 12) - 1, 1 << 12, -(1 << 12), -(1 << 12) - 1, // the 13-bit edge
		(1 << 19) - 1, 1 << 19, -(1 << 19), -(1 << 19) - 1, // the 20-bit edge
		1 << 30, -(1 << 30), 1 << 40, -(1 << 40),
	} {
		emit([]xor2Sample{s(0, 1), s(10000, 2), s(20000, 3), s(30000 + dod, 4)})
		// The same dod with the value UNCHANGED, which takes the inlined fast path.
		emit([]xor2Sample{s(0, 1), s(10000, 1), s(20000, 1), s(30000 + dod, 1)})
	}

	// --- BOTH stale-NaN spellings.
	// dod=0 => the `11111` whole-sample prefix.
	emit([]xor2Sample{s(0, 1), s(1000, 1), s(2000, stale), s(3000, 1)})
	// dod!=0 => the `111` value code.
	emit([]xor2Sample{s(0, 1), s(1000, 1), s(2500, stale), s(4000, 1)})
	// Consecutive stales, and a stale as the very first sample.
	emit([]xor2Sample{s(0, 1), s(1000, 1), s(2000, stale), s(3000, stale), s(4000, 2)})
	emit([]xor2Sample{s(0, stale), s(1000, 1), s(2000, 1)})
	// The baseline must survive a stale: the value after it XORs against the last NON-stale one.
	emit([]xor2Sample{s(0, 7), s(1000, 7), s(2000, stale), s(3000, 7)})

	// --- Values that move the leading/trailing window.
	emit([]xor2Sample{s(0, 1e-300), s(1000, 1e300), s(2000, 1e-300)})
	emit([]xor2Sample{s(0, 0), s(1000, math.Float64frombits(1)), s(2000, math.Float64frombits(1<<63))})
	emit([]xor2Sample{s(0, 0), s(1000, math.Float64frombits(1<<63|1)), s(2000, 0)})
	emit([]xor2Sample{s(0, math.NaN()), s(1000, math.Inf(1)), s(2000, math.Inf(-1))})
	emit([]xor2Sample{s(0, 0), s(1000, math.Copysign(0, -1)), s(2000, 0)})

	// --- ST from sample 0, unchanged thereafter: firstSTKnown set, firstSTChangeOn zero.
	emit([]xor2Sample{sst(500, 1000, 1)})
	emit([]xor2Sample{sst(500, 1000, 1), sst(500, 2000, 2)})
	emit([]xor2Sample{sst(500, 1000, 1), sst(500, 2000, 2), sst(500, 3000, 3)})
	constST := []xor2Sample{}
	for i := range 20 {
		constST = append(constST, sst(500, int64(i)*15000+1000, 42))
	}
	emit(constST)

	// --- ST changing, which activates the per-sample delta path.
	emit([]xor2Sample{sst(500, 1000, 1), sst(600, 2000, 2)})
	emit([]xor2Sample{sst(0, 1000, 1), sst(600, 2000, 2)})
	emit([]xor2Sample{sst(500, 1000, 1), sst(500, 2000, 2), sst(700, 3000, 3)})
	changing := []xor2Sample{}
	for i := range 20 {
		changing = append(changing, sst(int64(i)*100+500, int64(i)*15000+1000, float64(i)))
	}
	emit(changing)
	// ST deltas that hit each inlined varbit bucket and then fall through to putVarbitIntFast.
	for _, step := range []int64{0, 1, -1, 4, -3, 5, 32, -31, 33, 256, -255, 257, 100000, -100000} {
		vs := []xor2Sample{sst(500, 1000, 1), sst(500, 2000, 1)}
		acc := int64(500)
		for i := range 6 {
			acc += step
			vs = append(vs, sst(acc, int64(i+3)*1000, 1))
		}
		emit(vs)
	}
	// The same, with the value ALSO changing, so the unfused ST width is used.
	for _, step := range []int64{1, 4, 32, 256, 100000} {
		vs := []xor2Sample{sst(500, 1000, 1), sst(500, 2000, 2)}
		acc := int64(500)
		for i := range 6 {
			acc += step
			vs = append(vs, sst(acc, int64(i+3)*1000+int64(i), float64(i)*3.5))
		}
		emit(vs)
	}

	// --- Sample 127, which forces the slow path REGARDLESS of the data, and the boundary either side.
	for _, changeAt := range []int{2, 126, 127, 128, 129} {
		vs := []xor2Sample{}
		for i := range 140 {
			st := int64(500)
			if i >= changeAt {
				st = 500 + int64(i)
			}
			vs = append(vs, sst(st, int64(i)*15000+1000, 42))
		}
		emit(vs)
	}
	// No ST change at all across the boundary: the forced slow path at 127 still runs.
	{
		vs := []xor2Sample{}
		for i := range 140 {
			vs = append(vs, sst(500, int64(i)*15000+1000, 42))
		}
		emit(vs)
	}
	// And with no ST whatsoever across the boundary.
	{
		vs := []xor2Sample{}
		for i := range 140 {
			vs = append(vs, s(int64(i)*15000, 42))
		}
		emit(vs)
	}

	// --- Cases added because a NEGATIVE CONTROL SURVIVED without them
	// (Scripts/controls-xor2.sh).
	//
	// The ACTIVE-ST FAST PATH needs `firstSTChangeOn > 0`, which means ST must change at sample **1**
	// specifically — a change at sample 2 or later goes through the slow path first and the earlier
	// cases all did that. So these start with an ST change at sample 1 and then run long enough to
	// exercise the fast path's own sub-cases: deltaStDiff of zero, and each inlined bucket, with the
	// value unchanged (so the T/V trailing bit is FUSED with the ST delta and the widths are one
	// greater) and with it changed (so they are not).
	for _, step := range []int64{0, 1, -1, 4, -3, 5, 32, -31, 33, 256, -255, 257, 100000} {
		// Value UNCHANGED throughout: the fused widths.
		vs := []xor2Sample{sst(500, 1000, 1), sst(600, 2000, 1)}
		acc := int64(600)
		for i := range 8 {
			acc += step
			vs = append(vs, sst(acc, int64(i+3)*1000, 1))
		}
		emit(vs)
		// Value CHANGING: the unfused widths, via encodeJoint.
		vs2 := []xor2Sample{sst(500, 1000, 1), sst(600, 2000, 2)}
		acc = 600
		for i := range 8 {
			acc += step
			vs2 = append(vs2, sst(acc, int64(i+3)*1000, float64(i)*2.5))
		}
		emit(vs2)
		// Value unchanged but the TIMESTAMP jittering, so the 13-bit-dod fast path pairs with the ST
		// delta rather than the dod=0 one.
		vs3 := []xor2Sample{sst(500, 1000, 1), sst(600, 2000, 1)}
		acc = 600
		for i := range 8 {
			acc += step
			vs3 = append(vs3, sst(acc, int64(i+3)*1000+int64(i%3), 1))
		}
		emit(vs3)
	}

	// **The fused ST buckets need `st` to TRACK `t`, not to step independently.** The cases above
	// stepped `st` by a constant while `t` stepped by 1000, so `newStDiff = prevT - st` moved by ~1000
	// every sample and `deltaStDiff` never landed in an inlined bucket — three controls survived on
	// exactly that. When `st = t - k` for a fixed lag, `newStDiff` is constant and `deltaStDiff` is
	// **zero**; drifting the lag by a little puts it in the small buckets.
	for _, drift := range []int64{0, 1, -1, 2, -3, 4, 5, -31, 32, 33, -255, 256, 257} {
		lag := int64(300)
		// Value unchanged, timestamps evenly spaced: the fused dod=0 sub-case.
		vs := []xor2Sample{}
		for i := range 12 {
			t := int64(1000 + i*1000)
			vs = append(vs, sst(t-lag-int64(i)*drift, t, 1))
		}
		emit(vs)
		// Value unchanged, timestamps jittering inside the 13-bit dod: the other fused sub-case.
		vs2 := []xor2Sample{}
		for i := range 12 {
			t := int64(1000+i*1000) + int64(i%3)
			vs2 = append(vs2, sst(t-lag-int64(i)*drift, t, 1))
		}
		emit(vs2)
		// Value changing: the unfused widths after encodeJoint.
		vs3 := []xor2Sample{}
		for i := range 12 {
			t := int64(1000 + i*1000)
			vs3 = append(vs3, sst(t-lag-int64(i)*drift, t, float64(i)*1.5))
		}
		emit(vs3)
	}

	// A REPLAY whose last sample is STALE, which is the only shape that distinguishes lifting
	// `baselineV` from lifting `val` when the appender is rebuilt.
	emit([]xor2Sample{s(0, 7), s(1000, 7), s(2000, stale)})
	emit([]xor2Sample{s(0, 7), s(1000, 8), s(2500, stale)})
	emit([]xor2Sample{sst(500, 1000, 7), sst(600, 2000, 8), sst(700, 3000, stale)})
	emit([]xor2Sample{s(0, 7), s(1000, stale), s(2000, stale)})

	// --- Append while reading, as §6a's suite does.
	{
		mid := []xor2Sample{}
		for i := range 12 {
			mid = append(mid, sst(int64(i)*10+500, int64(i)*15000+1000, float64(i)*1.5))
		}
		for _, split := range []int{1, 2, 3, 5, 8, 11} {
			for _, readFirst := range []int{0, 1, 2, 5} {
				if readFirst <= split {
					emitSplit(mid, split, readFirst)
				}
			}
		}
	}

	// --- A long mixed run: every path, many byte boundaries.
	{
		long := []xor2Sample{}
		for i := range 200 {
			v := math.Sin(float64(i)) * float64(i)
			if i%23 == 0 {
				v = stale
			}
			st := int64(0)
			if i >= 3 {
				st = int64(i)*7 + 500
			}
			long = append(long, xor2Sample{ST: st, T: int64(i)*15000 + int64(i%5), V: fbits(v)})
		}
		emit(long)
	}
}
