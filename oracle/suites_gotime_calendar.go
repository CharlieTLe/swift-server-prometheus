package main

// Differential coverage for the calendar half of Go's `time.Time`, which
// `promql/functions.go`'s eight date functions read.
//
// ## Why this needs its own suite rather than riding on gocompat/time-rfc3339
//
// RFC 3339 rendering only ever sees timestamps a human wrote. The date functions
// see **arbitrary sample values** through an unguarded `int64(el.F)`, so they reach
// the whole `Int64` second range — including the band where Go's own calendar
// wraps.
//
// That band is the point of this suite. Go does not compute the calendar from the
// Unix second count: `Time.absSec()` (time.go:784) is
// `absSeconds(sec + (unixToInternal + internalToAbsolute))` — an int64 addition,
// then a reinterpretation as uint64. For `sec < -9223372028741760000` the sum is
// negative and the reinterpretation lands near 2**64, giving a nonsense date
// deterministically. The band is 8,113,015,808 seconds wide, and it is reachable:
// `int64(-Inf)` saturates to `Int64.min`, so `year(vector(-Inf))` is **+292277026596**
// — the same answer as `year(vector(+Inf))`. Any finite sample below about
// -9.2233720287e18 lands there too.
//
// An earlier version of `GoTime` computed the calendar straight from `unixSeconds`
// and carried a comment saying the wrap "would hide a bug rather than match
// anything observable". It differed from Go on exactly the four extreme cases in
// this corpus, which is how that comment got retired. PORTING.md quirk 46.
//
// `daysInMonth` is emitted the way `funcDaysInMonth` computes it —
// `32 - time.Date(year, month, 32, …).Day()`, leaning on `time.Date`'s
// normalisation of an out-of-range day — so the port's direct month-length
// computation is checked against upstream's trick rather than against itself.

import (
	"fmt"
	"math"
	"math/rand"
	"time"
)

type calOut struct {
	Year    int64 `json:"year"`
	Month   int   `json:"month"`
	Day     int   `json:"day"`
	Weekday int   `json:"weekday"`
	YearDay int   `json:"yearDay"`
	Hour    int   `json:"hour"`
	Minute  int   `json:"minute"`
	Second  int   `json:"second"`
	// 32 - time.Date(Year, Month, 32, ...).Day(), i.e. exactly what
	// funcDaysInMonth evaluates.
	DaysInMonth int `json:"daysInMonth"`
}

func calendarCorpus() []int64 {
	// unixToAbsolute, spelled as Go derives it so the boundary below is checked
	// rather than copied.
	const (
		secondsPerDay      = 24 * 60 * 60
		marchThruDecember  = 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30 + 31
		absoluteYears      = 292277022400
		internalToAbsolute = int64((absoluteYears*365.2425 + marchThruDecember) * secondsPerDay)
		unixToInternal     = int64((1969*365 + 1969/4 - 1969/100 + 1969/400) * secondsPerDay)
		unixToAbsolute     = unixToInternal + internalToAbsolute
	)

	out := []int64{
		0, 1, -1, 59, 60, 61, 3599, 3600, 3601,
		86399, 86400, 86401, -86399, -86400, -86401,
		math.MaxInt64, math.MinInt64, math.MaxInt64 - 1, math.MinInt64 + 1,
		-62135596800, -62135596801, // year 1, and one second before it
		253402300799, 253402300800, // the 9999/10000 boundary
		// The two forms the date functions reach the calendar through: int64(el.F)
		// gives the raw extremes, while the no-argument form divides enh.Ts by 1000
		// first and so cannot.
		math.MaxInt64 / 1000, math.MinInt64 / 1000,
	}

	// The wrap boundary, straddled: the last second that does NOT wrap, the first
	// that does, and a spread through the band.
	out = append(out, -unixToAbsolute, -unixToAbsolute-1, -unixToAbsolute+1)
	for _, d := range []int64{2, 3, 100, 86400, 1 << 20, 1 << 30, 1 << 32, 8113015807} {
		out = append(out, -unixToAbsolute-d)
	}
	// And the boundary where the int64 addition overflows but the uint64
	// reinterpretation puts it back — nothing should be visible here, which is
	// itself worth pinning.
	over := int64(math.MaxInt64) - unixToAbsolute
	for _, d := range []int64{-2, -1, 0, 1, 2, 1 << 20} {
		out = append(out, over+d)
	}

	// Every month boundary of the leap-rule-interesting years, straddled.
	for _, y := range []int{
		1600, 1700, 1800, 1900, 2000, 2020, 2023, 2024, 2100, 2400,
		1, 0, -1, -4, -100, -400, -401,
	} {
		for m := time.January; m <= time.December; m++ {
			t := time.Date(y, m, 1, 0, 0, 0, 0, time.UTC)
			out = append(out, t.Unix(), t.Unix()-1, t.Unix()+1)
		}
		// December 31 of the year, to reach yday 365/366.
		t := time.Date(y, time.December, 31, 23, 59, 59, 0, time.UTC)
		out = append(out, t.Unix())
	}

	r := rand.New(rand.NewSource(20260810))
	for i := 0; i < 4000; i++ {
		switch i % 5 {
		case 0:
			out = append(out, r.Int63()-r.Int63())
		case 1:
			out = append(out, int64(r.Intn(4000000000))-2000000000)
		case 2:
			out = append(out, r.Int63())
		case 3:
			out = append(out, -r.Int63())
		case 4:
			// Inside the wrap band, which random Int64s essentially never reach:
			// the band is 8.1e9 wide against a 1.8e19 range.
			out = append(out, math.MinInt64+r.Int63n(8113015808))
		}
	}
	return out
}

func genGoTimeCalendar(e *emitter) {
	seen := map[int64]bool{}
	n := 0
	for _, sec := range calendarCorpus() {
		if seen[sec] {
			continue
		}
		seen[sec] = true
		t := time.Unix(sec, 0).UTC()
		e.emit(fmt.Sprintf("cal/%d", n), i64(sec), calOut{
			Year:        int64(t.Year()),
			Month:       int(t.Month()),
			Day:         t.Day(),
			Weekday:     int(t.Weekday()),
			YearDay:     t.YearDay(),
			Hour:        t.Hour(),
			Minute:      t.Minute(),
			Second:      t.Second(),
			DaysInMonth: 32 - time.Date(t.Year(), t.Month(), 32, 0, 0, 0, 0, time.UTC).Day(),
		})
		n++
	}
}

// ------------------------------------------------------ promql/functions-date
//
// The eight date functions through `FunctionCalls`, reusing the wire types of
// oracle/suites_promql_functions_elementwise.go. A separate fixture so a failure
// names the date slice rather than being buried among 300 arithmetic cases.

func genPromQLFunctionsDate(e *emitter) {
	names := []string{
		"days_in_month", "day_of_month", "day_of_week", "day_of_year",
		"hour", "minute", "month", "year",
	}

	// The sample values. `int64(el.F)` is unguarded, so every one of these is a
	// legal PromQL argument.
	values := []float64{
		0, math.Copysign(0, -1), 1, -1, 59, 60, 3600, 86399, 86400, -86400,
		// The saturating conversion: NaN is 0 seconds (1970), and BOTH infinities
		// come back as year 292277026596 — the negative one because Int64.min lands
		// in the band where Go's absolute-second count wraps.
		math.NaN(), math.Inf(1), math.Inf(-1),
		1e300, -1e300,
		// Just inside and just outside the Int64 range, from the float side.
		9.2233720368547758e18, -9.2233720368547758e18,
		// Either side of the wrap boundary (-9223372028741760000), reachable from a
		// finite sample: one ULP of a Double this large is 2048, so ordinary data can
		// land on both sides. The first is above it and gives an ordinary very
		// negative year; the second is below and wraps to +292277026596.
		-9.2233720287e18, -9.2233720288e18, -9.223372029e18,
		// Fractional values: the conversion truncates toward zero.
		1.9, -1.9, 0.5, -0.5, 86400.9, -86400.9,
		// Real timestamps, including a leap day and a year boundary.
		1709164800,   // 2024-02-29T00:00:00Z
		1709251199,   // 2024-02-29T23:59:59Z
		1704067200,   // 2024-01-01T00:00:00Z
		1735689599,   // 2024-12-31T23:59:59Z
		951782400,    // 2000-02-29
		-62135596800, // year 1
	}

	histN := int64(3)
	n := 0
	emit := func(in fnIn) {
		if in.Args == nil {
			in.Args = [][]fnSampleIn{}
		}
		for i := range in.Args {
			if in.Args[i] == nil {
				in.Args[i] = []fnSampleIn{}
			}
			for j := range in.Args[i] {
				if in.Args[i][j].Metric == nil {
					in.Args[i][j].Metric = []string{}
				}
			}
		}
		if in.Seed == nil {
			in.Seed = []fnSampleIn{}
		}
		e.emit(fmt.Sprintf("%s/%d", in.Fn, n), in, runFnCase(in))
		n++
	}

	for _, fn := range names {
		for _, delayed := range []bool{false, true} {
			samples := make([]fnSampleIn, 0, len(values))
			for i, v := range values {
				samples = append(samples, fnSampleIn{
					Metric: fnMetrics()[i%len(fnMetrics())],
					T:      i64(int64(i) * 1000),
					F:      fbits(v),
				})
			}
			emit(fnIn{Fn: fn, Delayed: delayed, Ts: "1500", Args: [][]fnSampleIn{samples}})
		}

		// The NO-ARGUMENT form, which reads enh.Ts/1000 and emits an unlabelled
		// sample with DropName FALSE — unlike the argument form. Note the division
		// happens first, so the Int64 extremes here are 1000x smaller and do not
		// reach the wrap band.
		for _, ts := range []int64{
			0, 1, -1, 999, 1000, 1500, -1500, -999,
			1709164800000, math.MaxInt64, math.MinInt64,
			math.MaxInt64 - 1, math.MinInt64 + 1,
		} {
			emit(fnIn{Fn: fn, Ts: i64(ts)})
		}

		// Histograms are skipped, the empty vector yields nothing, and a non-empty
		// enh.Out is appended to.
		emit(fnIn{
			Fn: fn, Ts: "1500",
			Args: [][]fnSampleIn{{
				{Metric: fnMetrics()[3], T: "1000", Hist: &histN},
				{Metric: fnMetrics()[2], T: "2000", F: fbits(1709164800)},
				{Metric: fnMetrics()[1], T: "3000", Hist: &histN},
			}},
		})
		emit(fnIn{Fn: fn, Ts: "1500", Args: [][]fnSampleIn{{}}})
		emit(fnIn{
			Fn: fn, Ts: "1500",
			Seed: []fnSampleIn{{Metric: fnMetrics()[6], T: "111", F: fbits(-99)}},
			Args: [][]fnSampleIn{{{Metric: fnMetrics()[2], T: "1000", F: fbits(1709164800)}}},
		})
		// And the no-argument form with a seeded Out, which is the one shape where
		// the two forms could plausibly have been written differently.
		emit(fnIn{
			Fn: fn, Ts: "1500",
			Seed: []fnSampleIn{{Metric: fnMetrics()[6], T: "111", F: fbits(-99)}},
		})
	}
}
