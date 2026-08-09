package main

// The corpus for the storage iterator suites.
//
// Hand-built rather than seeded-random: every case exists to reach one specific
// branch, and a random walk would not reliably hit growth-while-wrapped or the
// specialized-to-interface migration at all.
//
// Timestamps are dense and small so the delta arithmetic is easy to check by eye;
// the interesting values are the deltas, not the timestamps.

import "fmt"

type iterCase struct {
	id string
	in iterIn
}

// ------------------------------------------------------------------- builders

func fSampleJSON(t int64, v float64) sampleJSON {
	return sampleJSON{Kind: "f", T: i64(t), ST: i64(0), F: fbits(v)}
}

func fSampleWithST(st, t int64, v float64) sampleJSON {
	return sampleJSON{Kind: "f", T: i64(t), ST: i64(st), F: fbits(v)}
}

func hSampleJSON(t int64, catalogue int) sampleJSON {
	return sampleJSON{Kind: "h", T: i64(t), ST: i64(0), F: fbits(0), Hist: catalogue}
}

func fhSampleJSON(t int64, catalogue int) sampleJSON {
	return sampleJSON{Kind: "fh", T: i64(t), ST: i64(0), F: fbits(0), Hist: catalogue}
}

func op(name string) iterOp             { return iterOp{Op: name} }
func opArg(name string, a int64) iterOp { return iterOp{Op: name, Arg: i64(a)} }

// IMPORTANT, and the source of three corpus bugs while this was written: `at`,
// `atT`, `atST`, `atHistogram` and `atFloatHistogram` are raw pass-throughs onto
// the wrapped iterator on BOTH BufferedSeriesIterator and MemoizedSeriesIterator.
// They are therefore only legal while that iterator is still positioned — once it
// is exhausted they index past the end of the sample list and Go panics, taking the
// generator with it. So a walk must read the current sample BEFORE advancing, and
// must never read after the `next` that exhausts.

// nextsThenDrain advances n times and then records the whole window. The drain is
// the only view the oracle has of the ring, so almost every case ends in one.
func nextsThenDrain(n int) []iterOp {
	ops := make([]iterOp, 0, n+1)
	for i := 0; i < n; i++ {
		ops = append(ops, op("next"))
	}
	return append(ops, op("bufferDrain"))
}

// floatRun returns count float samples at t = start, start+step, ...
func floatRun(start, step int64, count int) []sampleJSON {
	out := make([]sampleJSON, 0, count)
	for i := 0; i < count; i++ {
		t := start + int64(i)*step
		out = append(out, fSampleJSON(t, float64(i)+0.5))
	}
	return out
}

// ------------------------------------------------------------- buffer corpus

func bufferCases() []iterCase {
	var cases []iterCase
	add := func(id string, in iterIn) { cases = append(cases, iterCase{id: id, in: in}) }

	bigDelta := int64(1_000_000)

	// --- Degenerate shapes. Note `at`/`atT` are absent from the empty case: the
	// iterator is "already positioned", which for an empty list means positioned
	// past the end, and Go's listSeriesIterator.At() then indexes samples[-1]...
	// actually samples[0] of an empty slice, and panics.
	add("empty", iterIn{
		Delta: i64(100),
		Ops:   []iterOp{op("next"), op("bufferDrain"), op("next"), op("err")},
	})
	add("single", iterIn{
		Samples: floatRun(0, 1, 1),
		Delta:   i64(100),
		// at/atT/atST before any next() exercise the already-positioned state.
		Ops: []iterOp{
			op("at"), op("atT"), op("atST"), op("bufferDrain"),
			op("next"), op("bufferDrain"), op("next"), op("bufferDrain"), op("err"),
		},
	})

	// --- Growth. 16 is the lazy first allocation, so 17 forces one doubling and
	// 33 forces two. The drain asserts ORDER, which is what proves the
	// two-segment copy.
	add("grow/exactly16", iterIn{
		Samples: floatRun(0, 1, 16), Delta: i64(bigDelta), Ops: nextsThenDrain(16),
	})
	add("grow/one-doubling", iterIn{
		Samples: floatRun(0, 1, 17), Delta: i64(bigDelta), Ops: nextsThenDrain(17),
	})
	add("grow/two-doublings", iterIn{
		Samples: floatRun(0, 1, 33), Delta: i64(bigDelta), Ops: nextsThenDrain(33),
	})
	add("grow/many", iterIn{
		Samples: floatRun(0, 1, 70), Delta: i64(bigDelta), Ops: nextsThenDrain(70),
	})

	// --- Growth while WRAPPED: the case a restructured two-segment copy breaks.
	//
	// The timestamp jump evicts the first ten samples, which advances `f` to 10.
	// The dense run that follows then fills the ring back to 16 with f != 0, so
	// the doubling happens on a wrapped ring.
	wrapped := append(floatRun(0, 1, 10), floatRun(1000, 1, 31)...)
	add("grow/wrapped", iterIn{
		Samples: wrapped, Delta: i64(100), Ops: nextsThenDrain(41),
	})
	// The same shape, drained at every step through the growth so the exact
	// transition is visible rather than just its end state.
	stepwise := []iterOp{}
	for i := 0; i < 41; i++ {
		stepwise = append(stepwise, op("next"), op("bufferDrain"))
	}
	add("grow/wrapped-stepwise", iterIn{
		Samples: wrapped, Delta: i64(100), Ops: stepwise,
	})

	// --- The eviction boundary. Retention is [newest-delta, newest] CLOSED, so a
	// sample sitting exactly on the lower bound survives.
	add("evict/boundary-kept", iterIn{
		// After buffering t=10 with delta 10, tmin is 0 and t=0 is retained.
		Samples: []sampleJSON{fSampleJSON(0, 1), fSampleJSON(5, 2), fSampleJSON(10, 3)},
		Delta:   i64(10),
		Ops:     nextsThenDrain(3),
	})
	add("evict/boundary-dropped", iterIn{
		// One millisecond later and t=0 falls out.
		Samples: []sampleJSON{fSampleJSON(0, 1), fSampleJSON(5, 2), fSampleJSON(11, 3)},
		Delta:   i64(10),
		Ops:     nextsThenDrain(3),
	})
	add("evict/delta-zero", iterIn{
		Samples: floatRun(0, 1, 5), Delta: i64(0), Ops: nextsThenDrain(5),
	})
	add("evict/delta-one", iterIn{
		Samples: floatRun(0, 1, 5), Delta: i64(1), Ops: nextsThenDrain(5),
	})
	add("evict/sparse", iterIn{
		Samples: floatRun(0, 1000, 8), Delta: i64(2500), Ops: nextsThenDrain(8),
	})
	add("evict/all-but-newest", iterIn{
		Samples: append(floatRun(0, 1, 20), fSampleJSON(999_999, 7)),
		Delta:   i64(50),
		Ops:     nextsThenDrain(21),
	})

	// --- ReduceDelta: shrink, no-op at equality, and refuse to grow.
	add("reduceDelta/shrink", iterIn{
		Samples: floatRun(0, 1, 12), Delta: i64(100),
		Ops: append(nextsThenDrain(12),
			opArg("reduceDelta", 5), op("bufferDrain"),
			opArg("reduceDelta", 2), op("bufferDrain")),
	})
	add("reduceDelta/equal", iterIn{
		Samples: floatRun(0, 1, 6), Delta: i64(100),
		Ops: append(nextsThenDrain(6), opArg("reduceDelta", 100), op("bufferDrain")),
	})
	add("reduceDelta/refuses-to-grow", iterIn{
		Samples: floatRun(0, 1, 6), Delta: i64(10),
		Ops: append(nextsThenDrain(6),
			opArg("reduceDelta", 1000), op("bufferDrain"),
			opArg("reduceDelta", 0), op("bufferDrain")),
	})
	add("reduceDelta/empty-ring", iterIn{
		Samples: floatRun(0, 1, 3), Delta: i64(100),
		Ops: []iterOp{opArg("reduceDelta", 5), op("bufferDrain")},
	})

	// --- Homogeneous histogram rings, which use the specialized buffers.
	add("hist/integer", iterIn{
		Samples: []sampleJSON{
			hSampleJSON(0, 1), hSampleJSON(1, 2), hSampleJSON(2, 1), hSampleJSON(3, 6),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(4),
	})
	add("hist/integer-grow", iterIn{
		Samples: func() []sampleJSON {
			out := []sampleJSON{}
			for i := 0; i < 18; i++ {
				out = append(out, hSampleJSON(int64(i), 1+i%2))
			}
			return out
		}(),
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(18),
	})
	add("hist/float", iterIn{
		Samples: []sampleJSON{
			fhSampleJSON(0, 3), fhSampleJSON(1, 4), fhSampleJSON(2, 5), fhSampleJSON(3, 3),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(4),
	})
	add("hist/float-grow", iterIn{
		Samples: func() []sampleJSON {
			out := []sampleJSON{}
			for i := 0; i < 18; i++ {
				out = append(out, fhSampleJSON(int64(i), 3+i%3))
			}
			return out
		}(),
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(18),
	})

	// --- Mixed streams, which force the specialized -> interface migration.
	add("mixed/float-then-integer", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), fSampleJSON(1, 2), hSampleJSON(2, 1), fSampleJSON(3, 4),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(4),
	})
	add("mixed/float-then-float-histogram", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), fSampleJSON(1, 2), fhSampleJSON(2, 3), fSampleJSON(3, 4),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(4),
	})
	add("mixed/integer-then-float-histogram", iterIn{
		Samples: []sampleJSON{
			hSampleJSON(0, 1), hSampleJSON(1, 2), fhSampleJSON(2, 3), hSampleJSON(3, 6),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(4),
	})
	// Migration AFTER a doubling, so the specialized buffer holds dead slots when
	// it is copied wholesale into the interface buffer.
	add("mixed/migration-after-growth", iterIn{
		Samples: append(floatRun(0, 1, 20), hSampleJSON(20, 1), fSampleJSON(21, 9)),
		Delta:   i64(bigDelta),
		Ops:     nextsThenDrain(22),
	})
	// Migration on a ring that is both grown AND wrapped.
	add("mixed/migration-after-wrapped-growth", iterIn{
		Samples: append(wrapped, hSampleJSON(1031, 1), fSampleJSON(1032, 9)),
		Delta:   i64(100),
		Ops:     nextsThenDrain(43),
	})
	add("mixed/interleaved", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), hSampleJSON(1, 1), fhSampleJSON(2, 3), fSampleJSON(3, 4),
			hSampleJSON(4, 2), fhSampleJSON(5, 5), fSampleJSON(6, 7),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(7),
	})
	// Mixed ring, drained then read again: the drain's float branch leaves the
	// stale histogram in place (buffer.go:403), so a second drain over the same
	// window is the only way to see that the iterator resets `h`/`fh`.
	add("mixed/drain-twice", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), hSampleJSON(1, 1), fSampleJSON(2, 3),
		},
		Delta: i64(bigDelta),
		Ops:   []iterOp{op("next"), op("next"), op("next"), op("bufferDrain"), op("bufferDrain")},
	})

	// --- Seek.
	add("seek/forward", iterIn{
		Samples: floatRun(0, 10, 12), Delta: i64(25),
		Ops: []iterOp{opArg("seek", 50), op("at"), op("atT"), op("bufferDrain"), op("err")},
	})
	add("seek/exact-lasttime", iterIn{
		Samples: floatRun(0, 10, 12), Delta: i64(25),
		Ops: []iterOp{
			op("next"), op("next"), opArg("seek", 10), op("atT"), op("bufferDrain"),
		},
	})
	add("seek/backwards-preserves-buffer", iterIn{
		Samples: floatRun(0, 10, 12), Delta: i64(1000),
		Ops: []iterOp{
			op("next"), op("next"), op("next"), op("next"), op("bufferDrain"),
			opArg("seek", 5), op("atT"), op("bufferDrain"),
		},
	})
	add("seek/past-end-wipes-buffer", iterIn{
		Samples: floatRun(0, 10, 12), Delta: i64(25),
		Ops: []iterOp{
			op("next"), op("next"), op("next"), op("bufferDrain"),
			opArg("seek", 100_000), op("bufferDrain"), op("err"),
		},
	})
	add("seek/on-exhausted", iterIn{
		Samples: floatRun(0, 10, 3), Delta: i64(25),
		Ops: []iterOp{
			op("next"), op("next"), op("next"), op("next"),
			opArg("seek", 0), opArg("seek", 100), op("bufferDrain"),
		},
	})
	add("seek/negative-target", iterIn{
		Samples: floatRun(0, 10, 5), Delta: i64(25),
		Ops: []iterOp{opArg("seek", -1000), op("atT"), op("bufferDrain")},
	})
	add("seek/histogram", iterIn{
		Samples: []sampleJSON{
			hSampleJSON(0, 1), fhSampleJSON(10, 3), hSampleJSON(20, 2), fhSampleJSON(30, 4),
		},
		Delta: i64(15),
		Ops: []iterOp{
			opArg("seek", 20), op("atT"), op("atFloatHistogram"), op("bufferDrain"),
		},
	})

	// --- PeekBack, over both a wrapped and a freshly grown ring.
	peeks := []iterOp{}
	for n := int64(1); n <= 6; n++ {
		peeks = append(peeks, opArg("peekBack", n))
	}
	add("peekBack/small", iterIn{
		Samples: floatRun(0, 1, 5), Delta: i64(bigDelta),
		Ops: append(nextsThenDrain(5), peeks...),
	})
	add("peekBack/wrapped", iterIn{
		Samples: wrapped, Delta: i64(100),
		Ops: append(nextsThenDrain(41), peeks...),
	})
	add("peekBack/histogram", iterIn{
		Samples: []sampleJSON{hSampleJSON(0, 1), hSampleJSON(1, 2), hSampleJSON(2, 6)},
		Delta:   i64(bigDelta),
		Ops:     append(nextsThenDrain(3), peeks...),
	})
	add("peekBack/mixed", iterIn{
		Samples: []sampleJSON{fSampleJSON(0, 1), hSampleJSON(1, 1), fhSampleJSON(2, 3)},
		Delta:   i64(bigDelta),
		Ops:     append(nextsThenDrain(3), peeks...),
	})
	add("peekBack/empty-buffer", iterIn{
		Samples: floatRun(0, 1, 3), Delta: i64(bigDelta),
		Ops: []iterOp{opArg("peekBack", 1), opArg("peekBack", 2)},
	})

	// --- Start timestamps, which every sample carries at this pin.
	//
	// `atST` is interleaved rather than appended after the last `next`: the
	// BufferedSeriesIterator's at* are raw pass-throughs onto the wrapped
	// iterator, so once it is exhausted they index past the end and Go panics.
	add("st/set", iterIn{
		Samples: []sampleJSON{
			fSampleWithST(0, 10, 1), fSampleWithST(5, 20, 2), fSampleWithST(0, 30, 3),
		},
		Delta: i64(bigDelta),
		Ops: []iterOp{
			op("atST"), op("next"), op("atST"), op("next"), op("atST"),
			op("next"), op("bufferDrain"),
		},
	})

	// --- Stale NaN, which the engine filters but the ring must carry verbatim.
	add("stale", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1),
			{Kind: "f", T: i64(1), ST: i64(0), F: staleNaNBits()},
			fSampleJSON(2, 3),
		},
		Delta: i64(bigDelta),
		Ops:   nextsThenDrain(3),
	})

	return cases
}

// staleNaNBits is the bit pattern of Prometheus's stale marker
// (model/value.StaleNaN), spelled as bits because it is a NaN.
func staleNaNBits() string { return fmt.Sprintf("%016x", uint64(0x7ff0000000000002)) }

// ----------------------------------------------------------- memoized corpus

func memoizedCases() []iterCase {
	var cases []iterCase
	add := func(id string, in iterIn) { cases = append(cases, iterCase{id: id, in: in}) }

	// The engine's two deltas, which are inconsistent upstream and must stay so:
	// lookbackDelta at engine.go:1850, but lookbackDelta-1 at engine.go:2666.
	lookback := int64(300_000)

	add("empty", iterIn{
		Delta: i64(lookback),
		Ops:   []iterOp{op("peekPrev"), op("next"), op("peekPrev"), op("err")},
	})
	add("single", iterIn{
		Samples: floatRun(100, 1, 1), Delta: i64(lookback),
		Ops: []iterOp{
			op("at"), op("atT"), op("peekPrev"),
			op("next"), op("peekPrev"), op("next"), op("peekPrev"),
		},
	})

	// next/peekPrev interleaved: the memo is written BEFORE advancing, so after
	// the nth next() it holds the (n-1)th sample.
	// Read the current sample, then advance — see the note above.
	interleaved := []iterOp{}
	for i := 0; i < 8; i++ {
		interleaved = append(interleaved, op("at"), op("atT"), op("peekPrev"), op("next"))
	}
	add("walk/interleaved", iterIn{
		Samples: floatRun(0, 10, 8), Delta: i64(lookback), Ops: interleaved,
	})

	// Seek within the delta walks forward and keeps the memo; seek beyond it
	// hard-seeks and discards the memo first.
	add("seek/within-delta", iterIn{
		Samples: floatRun(0, 10, 20), Delta: i64(50),
		Ops: []iterOp{
			op("next"), op("next"), op("peekPrev"),
			opArg("seek", 30), op("atT"), op("peekPrev"),
		},
	})
	add("seek/beyond-delta", iterIn{
		Samples: floatRun(0, 10, 20), Delta: i64(5),
		Ops: []iterOp{
			op("next"), op("next"), op("peekPrev"),
			opArg("seek", 150), op("atT"), op("peekPrev"),
		},
	})
	// A seek that fails: the memo is cleared before the seek is attempted, so it
	// is gone for good even though the iterator had one.
	add("seek/failed-loses-memo", iterIn{
		Samples: floatRun(0, 10, 5), Delta: i64(5),
		Ops: []iterOp{
			op("next"), op("next"), op("peekPrev"),
			opArg("seek", 1_000_000), op("peekPrev"), op("err"),
		},
	})
	add("seek/exact", iterIn{
		Samples: floatRun(0, 10, 10), Delta: i64(lookback),
		Ops: []iterOp{opArg("seek", 50), op("atT"), op("peekPrev")},
	})
	add("seek/repeated", iterIn{
		Samples: floatRun(0, 10, 10), Delta: i64(20),
		Ops: []iterOp{
			opArg("seek", 20), op("atT"), opArg("seek", 20), op("atT"),
			opArg("seek", 40), op("atT"), op("peekPrev"),
		},
	})
	add("seek/backwards", iterIn{
		Samples: floatRun(0, 10, 10), Delta: i64(lookback),
		Ops: []iterOp{
			op("next"), op("next"), op("next"),
			opArg("seek", 0), op("atT"), op("peekPrev"),
		},
	})

	// Integer histograms: seek/next must never report `.histogram`, but at() is a
	// raw pass-through and still reveals one.
	add("hist/integer-becomes-float", iterIn{
		Samples: []sampleJSON{
			hSampleJSON(0, 1), hSampleJSON(10, 2), hSampleJSON(20, 6),
		},
		Delta: i64(lookback),
		Ops: []iterOp{
			op("next"), op("peekPrev"), op("atFloatHistogram"),
			opArg("seek", 20), op("atFloatHistogram"), op("peekPrev"),
		},
	})
	add("hist/float", iterIn{
		Samples: []sampleJSON{
			fhSampleJSON(0, 3), fhSampleJSON(10, 4), fhSampleJSON(20, 5),
		},
		Delta: i64(lookback),
		Ops: []iterOp{
			op("next"), op("peekPrev"), op("atFloatHistogram"),
			op("next"), op("peekPrev"),
		},
	})
	add("hist/mixed-with-floats", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), hSampleJSON(10, 1), fSampleJSON(20, 3), fhSampleJSON(30, 3),
		},
		Delta: i64(lookback),
		Ops: []iterOp{
			op("next"), op("peekPrev"), op("next"), op("peekPrev"),
			op("next"), op("peekPrev"), op("next"), op("peekPrev"),
		},
	})

	// The engine's exact deltas, to pin the off-by-one it passes at :2666.
	for _, d := range []int64{lookback, lookback - 1, 0, 1} {
		add(fmt.Sprintf("delta/%d", d), iterIn{
			Samples: floatRun(0, 100, 6), Delta: i64(d),
			Ops: []iterOp{
				opArg("seek", 250), op("atT"), op("peekPrev"),
				opArg("seek", 500), op("atT"), op("peekPrev"),
			},
		})
	}

	add("stale", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1),
			{Kind: "f", T: i64(10), ST: i64(0), F: staleNaNBits()},
			fSampleJSON(20, 3),
		},
		Delta: i64(lookback),
		Ops: []iterOp{
			op("next"), op("at"), op("peekPrev"), op("next"), op("at"), op("peekPrev"),
		},
	})

	return cases
}

// --------------------------------------------------------- listseries corpus

func listSeriesCases() []iterCase {
	var cases []iterCase
	add := func(id string, in iterIn) { cases = append(cases, iterCase{id: id, in: in}) }

	// `at` before the first `next` is excluded: Go indexes samples[-1] and panics.
	// `next` first (the list iterator starts BEFORE the first element, unlike the
	// buffered and memoized ones), then read, exactly as many times as there are
	// samples, then one final `next` to observe exhaustion.
	walkN := func(count int) []iterOp {
		ops := []iterOp{}
		for i := 0; i < count; i++ {
			ops = append(ops, op("next"), op("atT"), op("atST"), op("at"))
		}
		return append(ops, op("next"))
	}

	add("float/walk", iterIn{Samples: floatRun(0, 10, 4), Ops: walkN(4)})
	add("float/empty", iterIn{Ops: []iterOp{op("next"), op("next"), op("err")}})
	add("float/seek-fresh", iterIn{
		Samples: floatRun(0, 10, 5),
		Ops:     []iterOp{opArg("seek", 25), op("atT"), op("next"), op("atT")},
	})
	// Seek on a fresh iterator whose first sample already satisfies the target
	// takes the no-op branch, and the following next() must move to element 1.
	add("float/seek-noop-then-next", iterIn{
		Samples: floatRun(0, 10, 5),
		Ops: []iterOp{
			opArg("seek", -100), op("atT"), op("next"), op("atT"), op("next"), op("atT"),
		},
	})
	add("float/seek-past-end", iterIn{
		Samples: floatRun(0, 10, 5),
		// No at* here: the seek leaves the iterator past the end.
		Ops: []iterOp{opArg("seek", 100_000), op("next"), op("err")},
	})
	add("float/seek-empty", iterIn{
		Ops: []iterOp{opArg("seek", 0), op("next")},
	})
	add("float/seek-exact", iterIn{
		Samples: floatRun(0, 10, 5),
		Ops: []iterOp{
			opArg("seek", 20), op("atT"), opArg("seek", 20), op("atT"),
			opArg("seek", 40), op("atT"),
		},
	})
	add("float/seek-backwards", iterIn{
		Samples: floatRun(0, 10, 5),
		Ops: []iterOp{
			opArg("seek", 30), op("atT"), opArg("seek", 0), op("atT"),
		},
	})

	histWalk := []iterOp{}
	for i := 0; i < 3; i++ {
		histWalk = append(histWalk, op("next"), op("atT"), op("atHistogram"),
			op("atFloatHistogram"))
	}
	histWalk = append(histWalk, op("next"))
	add("integer/walk", iterIn{
		Samples: []sampleJSON{hSampleJSON(0, 1), hSampleJSON(10, 2), hSampleJSON(20, 6)},
		Ops:     histWalk,
	})
	// WithCopy honours the reuse buffer where the plain one hands back an alias.
	// Both are asked for the same thing so the fixture shows they agree on value.
	add("integer/walk-withcopy", iterIn{
		Samples:  []sampleJSON{hSampleJSON(0, 1), hSampleJSON(10, 2), hSampleJSON(20, 6)},
		WithCopy: true,
		Ops:      histWalk,
	})

	fhWalk := []iterOp{}
	for i := 0; i < 3; i++ {
		fhWalk = append(fhWalk, op("next"), op("atT"), op("atFloatHistogram"))
	}
	fhWalk = append(fhWalk, op("next"))
	add("float-histogram/walk", iterIn{
		Samples: []sampleJSON{fhSampleJSON(0, 3), fhSampleJSON(10, 4), fhSampleJSON(20, 5)},
		Ops:     fhWalk,
	})
	add("float-histogram/walk-withcopy", iterIn{
		Samples:  []sampleJSON{fhSampleJSON(0, 3), fhSampleJSON(10, 4), fhSampleJSON(20, 5)},
		WithCopy: true,
		Ops:      fhWalk,
	})

	add("mixed/walk", iterIn{
		Samples: []sampleJSON{
			fSampleJSON(0, 1), hSampleJSON(10, 1), fhSampleJSON(20, 3), fSampleJSON(30, 4),
		},
		Ops: []iterOp{
			op("next"), op("atT"), op("next"), op("atT"), op("atHistogram"),
			op("next"), op("atT"), op("atFloatHistogram"), op("next"), op("atT"), op("at"),
			op("next"),
		},
	})

	add("st/set", iterIn{
		Samples: []sampleJSON{
			fSampleWithST(1, 10, 1), fSampleWithST(0, 20, 2), fSampleWithST(15, 30, 3),
		},
		Ops: []iterOp{
			op("next"), op("atST"), op("next"), op("atST"), op("next"), op("atST"),
		},
	})

	return cases
}
