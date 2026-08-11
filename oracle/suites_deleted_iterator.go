package main

// Differential coverage for `tsdb.DeletedIterator`.
//
// Exported with public fields, so the corpus drives it directly over a real `chunkenc.XORChunk` iterator.
// It needs its own suite because its behaviour is **stateful in a way the name does not suggest**: it
// CONSUMES its interval list as it advances (`it.Intervals = it.Intervals[1:]`), so the list is a cursor
// rather than a filter.
//
// What has to be reached:
//
//   - the consumption itself, which makes a SECOND pass over the same iterator delete nothing. Each case
//     therefore records two passes, and the second is where a non-consuming port diverges.
//   - `Next`'s three exits in order: deleted (`InBounds` → fetch another), before-the-interval (`ts <=
//     tr.Maxt` → keep), past-it (drop and look at the next).
//   - `Seek`'s two exits plus its delegation to `Next` when the landing sample is inside an interval — so a
//     seek into a deleted region behaves like seek-then-skip.
//   - `Seek`'s error check, which `Next` does not have.
//   - intervals that are adjacent, overlapping the ends, covering everything, covering nothing, and
//     unsorted (where upstream silently under-deletes, because the consumption assumes sortedness).
//   - interleavings where a SEEK follows a NEXT, so the seek sees an already-trimmed list.
//
// The samples come from an XOR chunk so the wrapped iterator is the real one, not a stub: `AtT` goes through
// `xorIterator`, and a port whose own iterator disagrees shows up here rather than being masked.

import (
	"fmt"

	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

type deletedIterIn struct {
	// The samples to put in the chunk, as [t, v] pairs. `v` is an int for readability; the encoding is
	// exercised elsewhere.
	Samples [][2]int64 `json:"samples"`
	// Deletion intervals, as [mint, maxt]. Applied VERBATIM — deliberately not passed through `Add`, so
	// unsorted and overlapping lists reach the iterator the way a caller could hand them over.
	Intervals [][2]int64 `json:"intervals"`
	// An operation script. "n" = Next, "sN" = Seek(N). Run in order, on ONE iterator.
	Ops []string `json:"ops"`
}

type deletedIterOut struct {
	// Per op: the value type as a string, and the timestamp if any.
	Types []string `json:"types"`
	Times []int64  `json:"times"`
	// The interval list AFTER the script — the state that proves consumption happened.
	Remaining [][2]int64 `json:"remaining"`
	// A SECOND full pass with `Next` until exhaustion, on the SAME iterator. With consumption this yields
	// nothing (the iterator is spent) — but the timestamps are recorded rather than assumed.
	SecondPass []int64 `json:"secondPass"`
	// A fresh iterator over the same inputs, drained with `Next`: the "filter" answer, so the corpus
	// records what deletion actually does as well as the stateful part.
	FullDrain []int64 `json:"fullDrain"`
	Err       string  `json:"err"`
}

func valueTypeName(v chunkenc.ValueType) string {
	switch v {
	case chunkenc.ValNone:
		return "none"
	case chunkenc.ValFloat:
		return "float"
	case chunkenc.ValHistogram:
		return "histogram"
	case chunkenc.ValFloatHistogram:
		return "floathistogram"
	default:
		return fmt.Sprintf("unknown(%d)", int(v))
	}
}

func genDeletedIterator(e *emitter) {
	n := 0
	emit := func(in deletedIterIn) {
		out := deletedIterOut{
			Types: []string{}, Times: []int64{}, Remaining: [][2]int64{},
			SecondPass: []int64{}, FullDrain: []int64{},
		}

		build := func() *tsdb.DeletedIterator {
			c := chunkenc.NewXORChunk()
			app, err := c.Appender()
			if err != nil {
				return nil
			}
			for _, s := range in.Samples {
				app.Append(0, s[0], float64(s[1]))
			}
			var ivs tombstones.Intervals
			for _, iv := range in.Intervals {
				ivs = append(ivs, tombstones.Interval{Mint: iv[0], Maxt: iv[1]})
			}
			return &tsdb.DeletedIterator{Iter: c.Iterator(nil), Intervals: ivs}
		}

		it := build()
		if it == nil {
			out.Err = "appender"
			e.emit(fmt.Sprintf("deletediter/%d", n), in, out)
			n++
			return
		}

		for _, op := range in.Ops {
			var vt chunkenc.ValueType
			if op == "n" {
				vt = it.Next()
			} else {
				var target int64
				if _, serr := fmt.Sscanf(op, "s%d", &target); serr != nil {
					out.Err = "bad op " + op
					break
				}
				vt = it.Seek(target)
			}
			out.Types = append(out.Types, valueTypeName(vt))
			if vt == chunkenc.ValNone {
				// `AtT` after exhaustion is not meaningful; record a sentinel rather than reading it.
				out.Times = append(out.Times, -1<<62)
			} else {
				out.Times = append(out.Times, it.AtT())
			}
		}
		for _, r := range it.Intervals {
			out.Remaining = append(out.Remaining, [2]int64{r.Mint, r.Maxt})
		}
		// The second pass, on the SAME iterator — the state the consumption leaves behind.
		for it.Next() != chunkenc.ValNone {
			out.SecondPass = append(out.SecondPass, it.AtT())
		}
		if it.Err() != nil {
			out.Err = it.Err().Error()
		}

		// A fresh iterator, fully drained: what deletion means when nothing has consumed the list yet.
		fresh := build()
		for fresh.Next() != chunkenc.ValNone {
			out.FullDrain = append(out.FullDrain, fresh.AtT())
		}
		if out.Err == "" && fresh.Err() != nil {
			out.Err = fresh.Err().Error()
		}

		e.emit(fmt.Sprintf("deletediter/%d", n), in, out)
		n++
	}

	// A ten-sample chunk at t = 0, 10, 20, … 90.
	tenSamples := [][2]int64{}
	for i := range 10 {
		tenSamples = append(tenSamples, [2]int64{int64(i) * 10, int64(i)})
	}
	nexts := func(k int) []string {
		out := []string{}
		for range k {
			out = append(out, "n")
		}
		return out
	}
	iv := func(a, b int64) [2]int64 { return [2]int64{a, b} }

	// No intervals at all: the wrapped iterator, unchanged.
	emit(deletedIterIn{Samples: tenSamples, Ops: nexts(12)})
	// Deleting nothing, because the interval misses every sample.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(1000, 2000)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(-100, -1)}, Ops: nexts(12)})
	// Deleting everything.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(0, 90)}, Ops: nexts(3)})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(-1000, 1000)}, Ops: nexts(3),
	})

	// A single interval in the middle, at the front, at the back.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(0, 20)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(70, 90)}, Ops: nexts(12)})
	// Bounds exactly on a sample, and just inside/outside it.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 30)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(31, 39)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(29, 31)}, Ops: nexts(12)})

	// Several intervals, which is where the CONSUMPTION shows.
	emit(deletedIterIn{
		Samples:   tenSamples,
		Intervals: [][2]int64{iv(10, 10), iv(30, 30), iv(50, 50), iv(70, 70)},
		Ops:       nexts(12),
	})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(0, 10), iv(40, 50), iv(80, 90)},
		Ops: nexts(12),
	})
	// Adjacent intervals — the shape `Add` would have merged, reaching the iterator unmerged.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(20, 30), iv(31, 50)}, Ops: nexts(12),
	})
	// OVERLAPPING intervals, which `Add` would never produce.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(20, 50), iv(30, 40)}, Ops: nexts(12),
	})
	// UNSORTED, where the consumption's sortedness assumption is violated. Upstream silently
	// under-deletes; the corpus records exactly how.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(70, 80), iv(10, 20)}, Ops: nexts(12),
	})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(50, 60), iv(0, 10), iv(80, 90)},
		Ops: nexts(12),
	})

	// SEEK. Landing outside an interval, inside one (which delegates to Next), and past everything.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: []string{"s20"}})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: []string{"s30"}})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: []string{"s40"}})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: []string{"s60"}})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 50)}, Ops: []string{"s999"}})
	// A seek into a deleted region that runs to the END of the samples — `Next` exhausts.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(50, 90)}, Ops: []string{"s60"}})

	// INTERLEAVED: a seek after nexts, so the seek sees an already-trimmed list. This is the case a
	// non-consuming port gets right and a wrongly-consuming one does not.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(10, 10), iv(50, 50), iv(80, 80)},
		Ops: []string{"n", "n", "n", "s70", "n", "n"},
	})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(10, 10), iv(50, 50), iv(80, 80)},
		Ops: []string{"s40", "n", "s80", "n"},
	})
	// Seeking BACKWARDS after the list has been trimmed — unsupported, and the corpus says what happens.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(10, 10), iv(50, 50)},
		Ops: []string{"n", "n", "n", "n", "n", "s10", "n"},
	})
	// Seek to a timestamp BEFORE the first sample.
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(0, 0)}, Ops: []string{"s-100", "n"},
	})

	// A single sample, and an empty chunk.
	emit(deletedIterIn{Samples: [][2]int64{{5, 1}}, Ops: nexts(3)})
	emit(deletedIterIn{Samples: [][2]int64{{5, 1}}, Intervals: [][2]int64{iv(5, 5)}, Ops: nexts(3)})
	emit(deletedIterIn{Samples: [][2]int64{}, Intervals: [][2]int64{iv(0, 10)}, Ops: nexts(2)})
	emit(deletedIterIn{Samples: [][2]int64{}, Ops: []string{"s0", "n"}})

	// INVERTED intervals (mint > maxt), which upstream neither rejects nor documents. These exist because a
	// control changing `ts <= tr.Maxt` to `ts < tr.Maxt` SURVIVED without them: the test is reached only when
	// `InBounds` was false, so `ts < tr.Mint`, and for a well-formed interval that already implies `ts <
	// tr.Maxt`. The two spellings can only disagree when `Mint > Maxt`.
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(50, 30)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(30, 20)}, Ops: nexts(12)})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(90, 0)}, Ops: nexts(12)})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(20, 20), iv(60, 40)}, Ops: nexts(12),
	})
	emit(deletedIterIn{Samples: tenSamples, Intervals: [][2]int64{iv(50, 30)}, Ops: []string{"s40"}})
	// The case that finally distinguishes `ts <= tr.Maxt` from `ts < tr.Maxt`, and it took reasoning to find
	// rather than more inverted intervals: the two differ only when `ts == tr.Maxt` at the second test, which
	// requires `ts < tr.Mint` too — an INVERTED interval whose Maxt lands exactly on a sample. Even then both
	// spellings keep the sample, one by returning and one by falling out of the loop... UNLESS a LATER
	// interval would delete it. So the shape needed is: inverted interval with Maxt on a sample, followed by
	// an interval containing that sample.
	//
	//   t=30, intervals [{50,30}, {25,35}]
	//     `<=`: first interval's second test is 30<=30 → KEEP 30
	//     `<` : 30<30 fails → drop {50,30} → {25,35} contains 30 → DELETE 30
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(50, 30), iv(25, 35)}, Ops: nexts(12),
	})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(90, 50), iv(45, 55)}, Ops: nexts(12),
	})
	emit(deletedIterIn{
		Samples: tenSamples, Intervals: [][2]int64{iv(20, 0), iv(-5, 5)}, Ops: nexts(12),
	})

	// Negative and extreme timestamps.
	emit(deletedIterIn{
		Samples:   [][2]int64{{-30, 1}, {-20, 2}, {-10, 3}, {0, 4}, {10, 5}},
		Intervals: [][2]int64{iv(-20, -10)},
		Ops:       nexts(7),
	})
	emit(deletedIterIn{
		Samples:   [][2]int64{{1, 1}, {2, 2}, {3, 3}},
		Intervals: [][2]int64{iv(-1<<62, 1), iv(3, 1<<62)},
		Ops:       nexts(5),
	})
}
