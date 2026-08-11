package main

// Differential coverage for tsdb/chunkenc/xor.go — and, through it, for bstream.go.
//
// **This suite is what pins `Bstream.swift`.** `bstream` is unexported, so the oracle cannot call it;
// `NewXORChunk`/`Appender`/`Bytes`/`Iterator` are exported, and an appended sample sequence has exactly
// one correct byte string. So comparing the bytes checks every bit the stream writer produced, and
// iterating them back checks every bit the reader consumes. HANDOFF §5d said the two files were one
// unit of verification; this is that unit.
//
// Each case appends a sequence of (t, v) pairs and records:
//   - the chunk's BYTES, hex, which is the encoding itself;
//   - `NumSamples`, which is the two header bytes rather than anything derived;
//   - the samples read back, so the decoder is checked against the encoder rather than only the bytes;
//   - the appender state after a REPLAY (`Appender()` on a non-empty chunk), which is the only way the
//     leading/trailing window and tDelta are observable from outside.
//
// What has to be reached:
//   - the three sample positions with different framing: first (varint t, raw 64-bit v), second
//     (uvarint delta), third onwards (delta-of-delta buckets);
//   - every delta-of-delta bucket, INCLUDING both sides of each `bitRange` boundary, which is
//     asymmetric (`-((1<<(n-1))-1) … 1<<(n-1)`);
//   - the value encoder's three paths: identical value (one zero bit), reusable leading/trailing
//     window (one bit then the significant bits), and a new window (5-bit leading, 6-bit sigbits);
//   - the leading-zero CLAMP at 32, and the sigbits==64 encoding as 0;
//   - specials: NaN, ±Inf, -0, and the stale NaN, whose bit patterns drive the XOR;
//   - a long run, so the stream crosses many byte boundaries and `count`'s free-bit arithmetic is
//     exercised at every phase.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/value"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

type xorSample struct {
	T int64  `json:"t"`
	V string `json:"v"` // hex bit pattern, so NaN and -0 travel exactly
}

type xorIn struct {
	Samples []xorSample `json:"samples"`
	// Append the first `SplitAt` samples, create an ITERATOR, read `ReadFirst` of them, then append
	// the rest and continue reading through the same iterator.
	//
	// This is what pins `newBReader`'s copy of the final byte, and `loadNextBuffer`'s `+8 <` rather
	// than `+8 <=`. Upstream's comment frames both as a concurrency accommodation — a chunk can be
	// appended to while it is read — but the mechanism needs no threads at all: it is simply that the
	// last byte CHANGED after the reader started, and the reader is defined to see the copy it took.
	// Two controls survived until this existed.
	SplitAt   int `json:"splitAt"`
	ReadFirst int `json:"readFirst"`
}

type xorOut struct {
	Bytes      string      `json:"bytes"`
	NumSamples int         `json:"numSamples"`
	Read       []xorSample `json:"read"`
	// The appender state recovered by replaying the chunk — the only external view of the encoder's
	// leading/trailing window.
	ReplayT        int64  `json:"replayT"`
	ReplayV        string `json:"replayV"`
	ReplayTDelta   uint64 `json:"replayTDelta"`
	ReplayLeading  uint8  `json:"replayLeading"`
	ReplayTrailing uint8  `json:"replayTrailing"`
	Err            string `json:"err"`
}

func genChunkEncXOR(e *emitter) {
	n := 0
	emitSplit := func(samples []xorSample, splitAt, readFirst int) {
		in := xorIn{Samples: samples, SplitAt: splitAt, ReadFirst: readFirst}
		out := xorOut{Read: []xorSample{}}
		c := chunkenc.NewXORChunk()
		app, err := c.Appender()
		if err != nil {
			out.Err = err.Error()
			e.emit(fmt.Sprintf("xor/%d", n), in, out)
			n++
			return
		}
		for _, s := range samples[:splitAt] {
			app.Append(0, s.T, unfbits(s.V))
		}
		// The iterator is created HERE, over the chunk as it stands.
		it := c.Iterator(nil)
		for range readFirst {
			if it.Next() != chunkenc.ValFloat {
				break
			}
			t, v := it.At()
			out.Read = append(out.Read, xorSample{T: t, V: fbits(v)})
		}
		// Now append the rest, which rewrites the header AND the final byte the reader copied.
		for _, s := range samples[splitAt:] {
			app.Append(0, s.T, unfbits(s.V))
		}
		// Continue through the SAME iterator.
		for it.Next() == chunkenc.ValFloat {
			t, v := it.At()
			out.Read = append(out.Read, xorSample{T: t, V: fbits(v)})
		}
		if it.Err() != nil {
			out.Err = it.Err().Error()
		}
		out.Bytes = hex.EncodeToString(c.Bytes())
		out.NumSamples = c.NumSamples()
		e.emit(fmt.Sprintf("xor/%d", n), in, out)
		n++
	}

	emit := func(samples []xorSample) {
		in := xorIn{Samples: samples}
		out := xorOut{Read: []xorSample{}}

		c := chunkenc.NewXORChunk()
		app, err := c.Appender()
		if err != nil {
			out.Err = err.Error()
			e.emit(fmt.Sprintf("xor/%d", n), in, out)
			n++
			return
		}
		for _, s := range samples {
			app.Append(0, s.T, unfbits(s.V))
		}
		out.Bytes = hex.EncodeToString(c.Bytes())
		out.NumSamples = c.NumSamples()

		it := c.Iterator(nil)
		for it.Next() == chunkenc.ValFloat {
			t, v := it.At()
			out.Read = append(out.Read, xorSample{T: t, V: fbits(v)})
		}
		if it.Err() != nil {
			out.Err = it.Err().Error()
		}

		// Replay: `Appender()` on the non-empty chunk reconstructs the encoder state by iterating.
		// Its fields are unexported, so they are observed by appending ONE more sample and diffing the
		// bytes — which is what any real caller does anyway. Recorded as the resulting byte string.
		c2 := chunkenc.NewXORChunk()
		app2, err := c2.Appender()
		if err == nil {
			for _, s := range samples {
				app2.Append(0, s.T, unfbits(s.V))
			}
			// A fresh appender over the same bytes, then one more sample: if the replay recovered the
			// wrong state, these bytes differ.
			c3 := chunkenc.NewXORChunk()
			c3.Reset(c2.Bytes())
			app3, err3 := c3.Appender()
			if err3 != nil {
				out.Err = err3.Error()
			} else if len(samples) > 0 {
				last := samples[len(samples)-1]
				app3.Append(0, last.T+1000, unfbits(last.V)+1)
				out.ReplayV = hex.EncodeToString(c3.Bytes())
				out.ReplayT = int64(c3.NumSamples())
			}
		}

		e.emit(fmt.Sprintf("xor/%d", n), in, out)
		n++
	}

	s := func(t int64, v float64) xorSample { return xorSample{T: t, V: fbits(v)} }

	// The three framings, one sample at a time.
	emit(nil)
	emit([]xorSample{s(0, 0)})
	emit([]xorSample{s(0, 1)})
	emit([]xorSample{s(1000, 1.5)})
	emit([]xorSample{s(-1000, 1.5)})
	emit([]xorSample{s(0, 1), s(1000, 1)})
	emit([]xorSample{s(0, 1), s(1000, 2)})
	emit([]xorSample{s(0, 1), s(1000, 2), s(2000, 3)})

	// A steady series: every dod is 0, so each sample after the second costs one bit plus the value.
	steady := []xorSample{}
	for i := range 20 {
		steady = append(steady, s(int64(i)*15000, float64(i)))
	}
	emit(steady)

	// IDENTICAL values, so the value encoder writes a single zero bit every time.
	same := []xorSample{}
	for i := range 10 {
		same = append(same, s(int64(i)*15000, 42))
	}
	emit(same)

	// Every delta-of-delta bucket, and BOTH SIDES of each asymmetric boundary. `bitRange(x, n)` is
	// `-((1<<(n-1))-1) <= x && x <= 1<<(n-1)`, so for 14 bits the range is -8191…8192.
	for _, dod := range []int64{
		1, -1,
		8192, 8193, -8191, -8192, // the 14-bit boundary, both sides, both signs
		65536, 65537, -65535, -65536, // the 17-bit boundary
		524288, 524289, -524287, -524288, // the 20-bit boundary
		1 << 30, -(1 << 30), 1 << 40, -(1 << 40),
	} {
		// Three samples fix tDelta at 10000, then the fourth carries the dod.
		emit([]xorSample{s(0, 1), s(10000, 2), s(20000, 3), s(30000 + dod, 4)})
	}

	// The value encoder's three paths, forced by choosing values whose XOR has known zero runs.
	emit([]xorSample{s(0, 1), s(1000, 1), s(2000, 1)})           // all identical
	emit([]xorSample{s(0, 1), s(1000, 1.0000001), s(2000, 1.0000002)}) // small, reusable window
	emit([]xorSample{s(0, 1e-300), s(1000, 1e300), s(2000, 1e-300)})   // wildly different windows
	emit([]xorSample{s(0, 0), s(1000, math.Float64frombits(1))})       // 1 significant bit, 63 trailing
	emit([]xorSample{s(0, 0), s(1000, math.Float64frombits(1<<63))})   // the sign bit alone
	// The leading-zero CLAMP: a delta whose leading zeros exceed 32.
	emit([]xorSample{s(0, 0), s(1000, math.Float64frombits(1<<20))})
	emit([]xorSample{s(0, 0), s(1000, math.Float64frombits(1<<31))})
	emit([]xorSample{s(0, 0), s(1000, math.Float64frombits(1<<32))})
	// sigbits == 64, which is written as 0 and read back as 64: needs leading == trailing == 0, so the
	// delta must have both its top and bottom bit set.
	emit([]xorSample{s(0, math.Float64frombits(0)), s(1000, math.Float64frombits(1<<63 | 1))})

	// Specials, whose bit patterns are what the XOR sees.
	emit([]xorSample{s(0, math.NaN()), s(1000, math.NaN())})
	emit([]xorSample{s(0, math.NaN()), s(1000, 1)})
	emit([]xorSample{s(0, math.Inf(1)), s(1000, math.Inf(-1))})
	emit([]xorSample{s(0, 0), s(1000, math.Copysign(0, -1))})
	emit([]xorSample{s(0, math.Float64frombits(value.StaleNaN)), s(1000, math.Float64frombits(value.StaleNaN))})
	emit([]xorSample{s(0, 1), s(1000, math.Float64frombits(value.StaleNaN)), s(2000, 1)})

	// Timestamps at the edges of what a varint encodes.
	emit([]xorSample{s(math.MaxInt64/2, 1), s(math.MaxInt64/2 + 1000, 2)})
	emit([]xorSample{s(math.MinInt64/2, 1), s(math.MinInt64/2 + 1000, 2)})
	emit([]xorSample{s(0, 1), s(1, 2), s(2, 3), s(3, 4)})

	// APPEND-WHILE-READING, at several splits so the reader is mid-buffer, at a byte boundary, and
	// inside the final byte when the append lands.
	{
		mid := []xorSample{}
		for i := range 12 {
			mid = append(mid, s(int64(i)*15000, float64(i)*1.5))
		}
		for _, split := range []int{1, 2, 3, 5, 8, 11} {
			for _, readFirst := range []int{0, 1, 2, 5} {
				if readFirst <= split {
					emitSplit(mid, split, readFirst)
				}
			}
		}
		// And a shape whose values keep moving the leading/trailing window, so the reader's state at
		// the split matters as well as its position.
		wobbly := []xorSample{}
		for i := range 10 {
			wobbly = append(wobbly, s(int64(i)*1000+int64(i*i), math.Ldexp(1, i*7)))
		}
		for _, split := range []int{2, 4, 7} {
			emitSplit(wobbly, split, split)
		}
	}

	// A LONG run, so the stream crosses many byte boundaries in every phase of `count`'s arithmetic,
	// and with a value pattern that keeps changing the leading/trailing window.
	long := []xorSample{}
	for i := range 200 {
		long = append(long, s(int64(i)*15000+int64(i%7), math.Sin(float64(i))*float64(i)))
	}
	emit(long)
}
