package main

// Differential coverage for the Phase 5 protocol substrate:
//
//   storage/errors        the storage error strings, including the two
//                         duplicate-sample messages
//   chunkenc/enums        Encoding.String, IsValidEncoding, ValueType.String,
//                         ChunkEncoding, CompatibleValues
//   gocompat/time-rfc3339 time.Unix(...).UTC().Format(time.RFC3339), plus
//                         UnixMilli and the calendar fields under it
//   promql/timestamp      model/timestamp's three conversions

import (
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/prometheus/prometheus/model/timestamp"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

// ------------------------------------------------------------ storage/errors

func genStorageErrors(e *emitter) {
	// The package-level sentinels. Ported as an enum, so this suite is what
	// catches a reworded case.
	sentinels := []struct {
		name string
		err  error
	}{
		{"NotFound", storage.ErrNotFound},
		{"OutOfOrderSample", storage.ErrOutOfOrderSample},
		{"OutOfBounds", storage.ErrOutOfBounds},
		{"TooOldSample", storage.ErrTooOldSample},
		{"DuplicateSampleForTimestamp", storage.ErrDuplicateSampleForTimestamp},
		{"OutOfOrderExemplar", storage.ErrOutOfOrderExemplar},
		{"DuplicateExemplar", storage.ErrDuplicateExemplar},
		{"ExemplarLabelLength", storage.ErrExemplarLabelLength},
		{"ExemplarsDisabled", storage.ErrExemplarsDisabled},
		{"NativeHistogramsDisabled", storage.ErrNativeHistogramsDisabled},
		{"OutOfOrderST", storage.ErrOutOfOrderST},
		{"STNewerThanSample", storage.ErrSTNewerThanSample},
	}
	for _, s := range sentinels {
		e.emit("sentinel/"+s.name, s.name, s.err.Error())
	}
}

type dupIn struct {
	Kind      string `json:"kind"` // "float" or "histogramToFloat"
	Timestamp int64  `json:"timestamp"`
	// Hex bit patterns; JSON cannot carry NaN or the infinities, and -0 would not
	// survive a decimal round trip.
	Existing string `json:"existing"`
	NewValue string `json:"newValue"`
}

type dupOut struct {
	Message string `json:"message"`
	// errors.Is against the exported sentinel, which a custom Is makes true for
	// every instance regardless of payload.
	IsSentinel bool `json:"isSentinel"`
}

func genStorageDuplicateErrors(e *emitter) {
	timestamps := []int64{
		// 0 short-circuits to the bare message, so it is the interesting one.
		0, 1, -1, 1000, -1000, math.MaxInt64, math.MinInt64, 1136239445000,
	}
	values := []float64{
		0, 1, -1, 0.5, -0.5, 1e21, 1e-5, 1234.5, math.NaN(),
		math.Inf(1), math.Inf(-1), math.Copysign(0, -1),
	}

	for ti, ts := range timestamps {
		for vi, existing := range values {
			for ni, newValue := range values {
				in := dupIn{
					Kind: "float", Timestamp: ts,
					Existing: fbits(existing), NewValue: fbits(newValue),
				}
				err := storage.NewDuplicateFloatErr(ts, existing, newValue)
				e.emit(fmt.Sprintf("float/%d/%d/%d", ti, vi, ni), in, dupOut{
					Message:    err.Error(),
					IsSentinel: errors.Is(err, storage.ErrDuplicateSampleForTimestamp),
				})
			}
		}
	}

	for ti, ts := range timestamps {
		for ni, newValue := range values {
			in := dupIn{
				Kind: "histogramToFloat", Timestamp: ts, NewValue: fbits(newValue),
			}
			err := storage.NewDuplicateHistogramToFloatErr(ts, newValue)
			e.emit(fmt.Sprintf("histogramToFloat/%d/%d", ti, ni), in, dupOut{
				Message:    err.Error(),
				IsSentinel: errors.Is(err, storage.ErrDuplicateSampleForTimestamp),
			})
		}
	}
}

// ------------------------------------------------------------ chunkenc enums

type encOut struct {
	String  string `json:"string"`
	IsValid bool   `json:"isValid"`
}

type valueTypeOut struct {
	String          string `json:"string"`
	EncodingXOR2    string `json:"encodingXOR2"`
	EncodingNotXOR2 string `json:"encodingNotXOR2"`
}

func genChunkEncEncoding(e *emitter) {
	// Every declared encoding plus values past the end, which exercise the
	// "<unknown>" default a Swift enum would otherwise make unreachable. 255 is
	// included because Encoding is a uint8, so that is its top value.
	raws := []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 255}
	for _, raw := range raws {
		enc := chunkenc.Encoding(raw)
		e.emit(fmt.Sprintf("encoding/%d", raw), raw, encOut{
			String:  enc.String(),
			IsValid: chunkenc.IsValidEncoding(enc),
		})
	}
}

func genChunkEncValueType(e *emitter) {
	// Past the end too: ValueType.String's default is "unknown", where
	// Encoding.String's is "<unknown>", and nothing else pins that difference.
	for raw := 0; raw <= 6; raw++ {
		vt := chunkenc.ValueType(raw)
		e.emit(fmt.Sprintf("valuetype/%d", raw), raw, valueTypeOut{
			String:          vt.String(),
			EncodingXOR2:    vt.ChunkEncoding(true).String(),
			EncodingNotXOR2: vt.ChunkEncoding(false).String(),
		})
	}
}

type compatibleIn struct {
	A int `json:"a"`
	B int `json:"b"`
}

func genChunkEncCompatible(e *emitter) {
	// The full encoding cross product: only the XOR family is mutually
	// compatible, including same-histogram-type pairs being incompatible.
	for a := 0; a <= 5; a++ {
		for b := 0; b <= 5; b++ {
			e.emit(
				fmt.Sprintf("compatible/%d/%d", a, b),
				compatibleIn{A: a, B: b},
				chunkenc.CompatibleValues(chunkenc.Encoding(a), chunkenc.Encoding(b)),
			)
		}
	}
}

// --------------------------------------------------------------- time.RFC3339

type timeOut struct {
	RFC3339 string `json:"rfc3339"`
	Year    int    `json:"year"`
	Month   int    `json:"month"`
	Day     int    `json:"day"`
	Hour    int    `json:"hour"`
	Minute  int    `json:"minute"`
	Second  int    `json:"second"`
}

func genGoTimeRFC3339(e *emitter) {
	// Seconds chosen for the boundaries that break a hand-rolled civil-date
	// conversion: the epoch, negative seconds (floor vs. truncate), year 1 and
	// year 0 (Go uses astronomical numbering, so year 0 exists), the 4-digit year
	// boundary at 10000, leap years and century/400-year rules, and the extremes
	// reachable from an int64 millisecond timestamp divided by 1000.
	seconds := []int64{
		0, 1, -1, 59, 60, 61, -59, -60, -61,
		86399, 86400, 86401, -86399, -86400, -86401,
		1136239445,                 // 2006-01-02T22:04:05Z, Go's reference time
		951782400,                  // 2000-02-29, a 400-year leap year
		1078012800,                 // 2004-02-29, an ordinary leap year
		4107542400,                 // 2100-03-01, a century non-leap year
		253402300799, 253402300800, // 9999-12-31 / 10000-01-01, the 4-digit edge
		-62135596800, -62135596801, // 0001-01-01 / 0000-12-31, Go's zero Time
		-62167219200,                        // 0000-01-01
		-62167219201,                        // -0001-12-31, a negative year
		9223372036854775, -9223372036854775, // math.MaxInt64/1000 and its negation
		1, -2, 1000000000, -1000000000,
	}
	for i, sec := range seconds {
		t := time.Unix(sec, 0).UTC()
		y, m, d := t.Date()
		h, mi, s := t.Clock()
		e.emit(fmt.Sprintf("unix/%d", i), sec, timeOut{
			RFC3339: t.Format(time.RFC3339),
			Year:    y, Month: int(m), Day: d,
			Hour: h, Minute: mi, Second: s,
		})
	}
}

type unixMilliOut struct {
	// time.UnixMilli(ms) round-tripped back through UnixMilli.
	Milli int64 `json:"milli"`
	// The normalised second/nanosecond split, which is how GoTime stores it.
	Seconds int64  `json:"seconds"`
	Nanos   int    `json:"nanos"`
	RFC3339 string `json:"rfc3339"`
}

func genGoTimeUnixMilli(e *emitter) {
	// The negative cases are the point: time.UnixMilli does
	// Unix(ms/1e3, (ms%1e3)*1e6) with a negative remainder, which normalisation
	// has to carry back into the second.
	values := []int64{
		0, 1, 999, 1000, 1001, 1500,
		-1, -999, -1000, -1001, -1500, -2000,
		1136239445000, 1136239445123, -62135596800000,
		9223372036854775, -9223372036854775,
	}
	for i, ms := range values {
		t := time.UnixMilli(ms).UTC()
		e.emit(fmt.Sprintf("milli/%d", i), ms, unixMilliOut{
			Milli:   t.UnixMilli(),
			Seconds: t.Unix(),
			Nanos:   t.Nanosecond(),
			RFC3339: t.Format(time.RFC3339),
		})
	}
}

// ------------------------------------------------------------ model/timestamp

type timestampOut struct {
	// FromTime(Time(ms)) — the round trip.
	FromTime int64 `json:"fromTime"`
	// Time(ms) rendered, so a wrong second is visible rather than just a wrong int.
	RFC3339 string `json:"rfc3339"`
}

func genPromQLTimestamp(e *emitter) {
	values := []int64{
		0, 1, 999, 1000, 1001, -1, -999, -1000, -1001, -1500,
		1136239445000, 253402300800000, -62135596800000,
		9223372036854775, -9223372036854775,
	}
	for i, ms := range values {
		t := timestamp.Time(ms)
		e.emit(fmt.Sprintf("ms/%d", i), ms, timestampOut{
			FromTime: timestamp.FromTime(t),
			RFC3339:  t.Format(time.RFC3339),
		})
	}

}

// Separate suite, not more cases in promql/timestamp: a fixture file holds one
// in/out shape, and these take a float and return a bare int64.
func genPromQLTimestampFloatSeconds(e *emitter) {
	// math.Round is half-away-from-zero, and the ties are what separate it from
	// Swift's default rounding rule.
	floats := []float64{
		0, 1, -1, 0.5, -0.5, 0.0005, -0.0005, 0.0015, -0.0015,
		1.0005, 1.5, 2.5, -1.5, -2.5, 1e-4, 1e-3,
		1136239445.123, 1136239445.1235, -1136239445.123,
		0.1, 0.2, 0.3, 1.0000000000000002,
	}
	for i, f := range floats {
		e.emit(fmt.Sprintf("floatsec/%d", i), fbits(f), timestamp.FromFloatSeconds(f))
	}
}
