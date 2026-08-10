package main

// Differential coverage for promql/engine.go's query-planning arithmetic —
// `FindMinMaxTime`, and through it `getTimeRangesForSelector` and `subqueryTimes` — plus
// the `HashRatioSampler` that `limit_ratio` uses.
//
// Both are exported and take no storage, which is what makes them portable before the
// evaluator exists. `FindMinMaxTime` takes a `*parser.EvalStmt`, so a case is a query
// string plus the four statement fields, and both sides parse the same bytes.
//
// ## What has to be reached
//
//   - NO selector at all, which returns (0, 0) rather than (MaxInt64, MinInt64);
//   - an instant selector, where the start moves back by `lookbackDelta - 1` — the
//     half-open window, and the `- 1` is the whole point;
//   - a RANGE selector, where it moves back by `range - 1` instead and the lookback delta
//     does not appear;
//   - `anchored` and `smoothed`, which add the lookback delta to the range — and
//     `smoothed`, uniquely, extends the END forward. Both the instant and the range form,
//     because the two are different code paths with different arithmetic;
//   - `offset`, applied last and unconditionally;
//   - `@`, which replaces start and end and skips the offset arithmetic — and `@` WITH an
//     offset, where the offset still applies to the pinned timestamp;
//   - subqueries: one, nested, with offsets that accumulate, and with an `@` on the inner
//     or the outer one — where the accumulation RESETS rather than adds;
//   - several selectors, so the min and the max come from different ones;
//   - a range query (start != end, interval set) as well as an instant one.
//
// ## The ratio sampler
//
// `SampleOffset` is `Hash(labels) / float64(math.MaxUint64)`, so the cases are label sets
// — and the divisor is worth a case of its own: `float64(math.MaxUint64)` rounds to 2^64,
// so a hash at the top of the range gives an offset of exactly 1.0 rather than just under
// it. `AddRatioSampleWithOffset` is then pinned across the sign boundary, at the limits,
// and with NaN and infinite limits, where both halves of its condition are false.

import (
	"fmt"
	"math"
	"time"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
)

type planIn struct {
	Expr string `json:"expr"`
	// Milliseconds since the epoch, decimal strings.
	Start string `json:"start"`
	End   string `json:"end"`
	// Nanoseconds, decimal strings.
	Interval      string `json:"interval"`
	LookbackDelta string `json:"lookback"`
}

type planOut struct {
	Min string `json:"min"`
	Max string `json:"max"`
}

func runMinMaxCase(in planIn) planOut {
	p := parser.NewParser(parser.Options{
		EnableExperimentalFunctions:  true,
		EnableExtendedRangeSelectors: true,
	})
	expr, err := p.ParseExpr(in.Expr)
	if err != nil {
		panic(fmt.Sprintf("fixture expr %q: %v", in.Expr, err))
	}
	s := &parser.EvalStmt{
		Expr:          expr,
		Start:         time.UnixMilli(parseI64(in.Start)).UTC(),
		End:           time.UnixMilli(parseI64(in.End)).UTC(),
		Interval:      time.Duration(parseI64(in.Interval)),
		LookbackDelta: time.Duration(parseI64(in.LookbackDelta)),
	}
	minT, maxT := promql.FindMinMaxTime(s)
	return planOut{Min: i64(minT), Max: i64(maxT)}
}

func genPromQLMinMaxTime(e *emitter) {
	n := 0
	emit := func(in planIn) {
		e.emit(fmt.Sprintf("minmax/%d", n), in, runMinMaxCase(in))
		n++
	}

	exprs := []string{
		// No selector: the (0, 0) reset.
		`1`,
		`1 + 2`,
		`time()`,
		`vector(1)`,
		`"a string"`,
		// One instant selector, with and without matchers.
		`foo`,
		`foo{job="a"}`,
		`{__name__="foo"}`,
		// Instant selectors with the modifiers. These DO parse — `foo smoothed` is legal
		// even though the modifiers are usually written on a range — and they are the only
		// way to reach the `evalRange == 0` branch's `if n.Smoothed`, where `anchored` does
		// nothing at all and `smoothed` extends the end. Without them that branch looked
		// like dead code and a negative control for it could not fail.
		`foo smoothed`,
		`foo anchored`,
		`foo smoothed offset 5m`,
		`foo smoothed @ 100`,
		`foo anchored offset 5m`,
		`sum(foo smoothed)`,
		`foo offset 5m`,
		`foo offset -5m`,
		`foo @ 100`,
		`foo @ 100 offset 5m`,
		`foo @ start()`,
		`foo @ end()`,
		// Range selectors: the `evalRange != 0` branch.
		`rate(foo[5m])`,
		`rate(foo[5m] offset 10m)`,
		`rate(foo[5m] @ 100)`,
		`rate(foo[5m] @ 100 offset 10m)`,
		`count_over_time(foo[1s])`,
		`count_over_time(foo[1ms])`,
		// The extended range selectors, both forms.
		`rate(foo[5m] anchored)`,
		`rate(foo[5m] smoothed)`,
		`rate(foo[5m] anchored offset 10m)`,
		`rate(foo[5m] smoothed offset 10m)`,
		`rate(foo[5m] smoothed @ 100)`,
		// Several selectors, so min and max come from different ones.
		`foo + bar offset 1h`,
		`rate(foo[10m]) + bar`,
		// A range selector followed by an instant one with a LARGE offset. This is what
		// makes `evalRange = 0` after each VectorSelector observable: without the reset the
		// trailing `bar` inherits the 10m range, and because its offset makes it the global
		// minimum, the answer changes. In `rate(foo[10m]) + bar` the two starts coincide and
		// the leak is invisible — which is exactly what the negative control found.
		`rate(foo[10m]) + bar offset 1h`,
		`bar offset 1h + rate(foo[10m])`,
		`rate(foo[10m] smoothed) + rate(bar[1m] anchored offset 30m)`,
		`foo @ 100 + bar @ 200`,
		// Subqueries.
		`max_over_time(foo[5m:1m])`,
		`max_over_time(foo[5m:1m] offset 10m)`,
		`max_over_time(rate(foo[1m])[5m:1m])`,
		`max_over_time(max_over_time(foo[5m:1m])[1h:10m])`,
		`max_over_time(foo[5m:1m] @ 100)`,
		// An `@` on the OUTER subquery with an offset inside, and the other way round:
		// the reset in subqueryTimes is what these separate.
		`max_over_time(max_over_time(foo[5m:1m] offset 3m)[1h:10m] @ 100)`,
		`max_over_time(max_over_time(foo[5m:1m] @ 100)[1h:10m] offset 3m)`,
		`max_over_time(max_over_time(foo[5m:1m] @ 100)[1h:10m] @ 200)`,
		// A subquery whose inner selector carries its own `@`, which overrides the
		// subquery's.
		`max_over_time(foo @ 50[5m:1m] @ 100)`,
		// A subquery over a range selector with the extended modifiers.
		`max_over_time(rate(foo[1m] smoothed)[5m:1m])`,
	}

	// Instant queries at a few evaluation times, including one that makes the window
	// straddle zero, plus a range query.
	type window struct {
		start, end, interval, lookback int64
	}
	windows := []window{
		// Instant at t=0, so the lookback start goes negative.
		{0, 0, 0, int64(5 * time.Minute)},
		// Instant at a round time.
		{1_600_000_000_000, 1_600_000_000_000, 0, int64(5 * time.Minute)},
		// A one-millisecond lookback delta, which is where the `- 1` cancels exactly.
		{1_600_000_000_000, 1_600_000_000_000, 0, int64(time.Millisecond)},
		// A zero lookback delta, so the `- 1` moves the start FORWARD by 1ms.
		{1_600_000_000_000, 1_600_000_000_000, 0, 0},
		// Range query.
		{1_600_000_000_000, 1_600_000_060_000, int64(15 * time.Second), int64(5 * time.Minute)},
		// A range query whose interval exceeds its span.
		{1_600_000_000_000, 1_600_000_010_000, int64(time.Hour), int64(time.Minute)},
	}

	for _, expr := range exprs {
		for _, w := range windows {
			emit(planIn{
				Expr:          expr,
				Start:         i64(w.start),
				End:           i64(w.end),
				Interval:      i64(w.interval),
				LookbackDelta: i64(w.lookback),
			})
		}
	}
}

// ------------------------------------------------------------- ratio sampler

type ratioIn struct {
	// Alternating name/value pairs, or nil for the empty label set. Present when the
	// case is testing SampleOffset.
	Metric []string `json:"metric"`
	// Bit patterns as decimal uint64 strings; both are read only by the WithOffset case.
	RatioLimit   string `json:"ratioLimit"`
	SampleOffset string `json:"sampleOffset"`
	// Which of the three methods this case exercises.
	Kind string `json:"kind"`
}

type ratioOut struct {
	// SampleOffset's result as a bit pattern, "" when the case is not testing it.
	Offset string `json:"offset"`
	Added  bool   `json:"added"`
}

func runRatioCase(in ratioIn) ratioOut {
	s := promql.NewHashRatioSampler()
	switch in.Kind {
	case "offset":
		m := labels.FromStrings(in.Metric...)
		return ratioOut{Offset: fbits(s.SampleOffset(&m))}
	case "sample":
		m := labels.FromStrings(in.Metric...)
		sample := promql.Sample{Metric: m, F: 1}
		limit := unfbits(in.RatioLimit)
		return ratioOut{
			Offset: fbits(s.SampleOffset(&m)),
			Added:  s.AddRatioSample(limit, &sample),
		}
	case "withOffset":
		limit := unfbits(in.RatioLimit)
		offset := unfbits(in.SampleOffset)
		return ratioOut{Added: s.AddRatioSampleWithOffset(limit, offset)}
	}
	panic("unknown ratio case kind " + in.Kind)
}

func genPromQLRatioSampler(e *emitter) {
	n := 0
	emit := func(in ratioIn) {
		if in.Metric == nil {
			in.Metric = []string{}
		}
		if in.RatioLimit == "" {
			in.RatioLimit = fbits(0)
		}
		if in.SampleOffset == "" {
			in.SampleOffset = fbits(0)
		}
		e.emit(fmt.Sprintf("%s/%d", in.Kind, n), in, runRatioCase(in))
		n++
	}

	metrics := [][]string{
		nil,
		{"__name__", "foo"},
		{"__name__", "foo", "job", "a"},
		{"__name__", "foo", "job", "b"},
		{"__name__", "foo", "instance", "i1", "job", "a"},
		{"a", ""},
		{"__name__", "foo", "le", "+Inf"},
		// A long label set, and one with bytes that are not letters.
		{"__name__", "a_very_long_metric_name_for_hashing", "l1", "v1", "l2", "v2",
			"l3", "v3", "l4", "v4"},
		{"__name__", "foo", "tag", "ünïcödé"},
	}
	for _, m := range metrics {
		emit(ratioIn{Kind: "offset", Metric: m})
	}

	limits := []float64{
		0, 1, -1, 0.5, -0.5, 0.9, -0.1, 0.001, -0.001,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		// Out of range, which the sampler does not police.
		2, -2,
		math.NaN(), math.Inf(1), math.Inf(-1),
		math.Copysign(0, -1),
	}
	for _, m := range metrics {
		for _, l := range limits {
			emit(ratioIn{Kind: "sample", Metric: m, RatioLimit: fbits(l)})
		}
	}

	// AddRatioSampleWithOffset over the whole grid, including the exact boundaries where
	// `<` and `>=` differ.
	offsets := []float64{
		0, math.Copysign(0, -1), 0.001, 0.5, 0.9, 0.999, 1,
		// Exactly `1 + ratioLimit` for the negative limits above.
		0.5, 0.9, 0.999,
		math.SmallestNonzeroFloat64, math.NaN(), math.Inf(1), math.Inf(-1),
		// Just below and just above 0.5, which is where a strict versus non-strict
		// comparison shows.
		math.Nextafter(0.5, 0), math.Nextafter(0.5, 1),
	}
	for _, l := range limits {
		for _, o := range offsets {
			emit(ratioIn{Kind: "withOffset", RatioLimit: fbits(l), SampleOffset: fbits(o)})
		}
	}
}
