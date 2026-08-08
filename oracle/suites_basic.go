package main

import (
	"encoding/hex"
	"fmt"
	"math"
	"math/rand"
	"strconv"

	"github.com/cespare/xxhash/v2"
	"github.com/prometheus/prometheus/util/kahansum"
)

// Floats travel as hex bit patterns so JSON never rounds them.
func fbits(f float64) string { return fmt.Sprintf("%016x", math.Float64bits(f)) }

// ---------------------------------------------------------------- floatformat

type floatFormatIn struct {
	Bits string `json:"bits"`
	Fmt  string `json:"fmt"`
	Prec int    `json:"prec"`
}

// floatCorpus is shared by several suites: a deterministic sweep that hits every
// binary exponent, all subnormals-by-construction, ties, and "human" magnitudes.
func floatCorpus() []float64 {
	r := rand.New(rand.NewSource(20260808))
	var vs []float64
	add := func(f float64) {
		if !math.IsNaN(f) && !math.IsInf(f, 0) {
			vs = append(vs, f)
		}
	}
	// Structural: every binary exponent, plus +/- 1 ULP on a sample of them.
	// Committed fixtures stay reviewable; the exhaustive sweep (millions of
	// cases, including every ULP neighbour) is the nightly job's work —
	// see Scripts/fuzz-diff.sh.
	for e := -1074; e <= 1023; e++ {
		v := math.Ldexp(1, e)
		add(v)
		if e%16 == 0 {
			add(math.Nextafter(v, math.Inf(1)))
			add(math.Nextafter(v, math.Inf(-1)))
		}
	}
	// Every decimal exponent, plus +/- 1 ULP on a sample.
	for e := -323; e <= 308; e++ {
		v, _ := strconv.ParseFloat("1e"+strconv.Itoa(e), 64)
		add(v)
		if e%8 == 0 {
			add(math.Nextafter(v, math.Inf(1)))
			add(math.Nextafter(v, math.Inf(-1)))
		}
	}
	// Uniform random bit patterns: every exponent, including subnormals.
	for i := 0; i < 1200; i++ {
		add(math.Float64frombits(r.Uint64()))
	}
	// "Human" magnitudes, where shortest-digit ties cluster.
	for i := 0; i < 1200; i++ {
		add(r.NormFloat64() * math.Pow(10, float64(r.Intn(40)-20)))
	}
	// Simple ratios and small integers — the most tie-prone region.
	for i := 0; i < 800; i++ {
		add(float64(r.Intn(2000000)) / float64(1+r.Intn(1000)))
	}
	// Exact special values.
	add(0)
	add(math.Copysign(0, -1))
	return vs
}

func genFloatFormat(e *emitter) {
	// Shortest mode for every format Prometheus uses, plus ('f', 3) which is the
	// one fixed-precision call site (promql/parser/printer.go @ v3.13.2).
	type spec struct {
		f    byte
		prec int
	}
	specs := []spec{{'g', -1}, {'f', -1}, {'e', -1}, {'E', -1}, {'G', -1}, {'f', 3}}
	for i, v := range floatCorpus() {
		for _, s := range specs {
			e.emit(
				fmt.Sprintf("%d/%c/%d", i, s.f, s.prec),
				floatFormatIn{Bits: fbits(v), Fmt: string(s.f), Prec: s.prec},
				strconv.FormatFloat(v, s.f, s.prec, 64),
			)
		}
	}
	// Specials: Go prints "+Inf" with an explicit sign.
	for i, v := range []float64{math.Inf(1), math.Inf(-1), math.NaN()} {
		for _, s := range specs {
			e.emit(
				fmt.Sprintf("special%d/%c/%d", i, s.f, s.prec),
				floatFormatIn{Bits: fbits(v), Fmt: string(s.f), Prec: s.prec},
				strconv.FormatFloat(v, s.f, s.prec, 64),
			)
		}
	}
}

// --------------------------------------------------------------------- quote

type bytesIn struct {
	Bytes string `json:"bytes"`
}

// byteStringCorpus covers ASCII, control characters, valid multi-byte UTF-8,
// and deliberately INVALID UTF-8 — Go's Quote has defined \xNN behaviour there
// and a Go string can hold it, unlike a Swift String. See ADR-9.
func byteStringCorpus() [][]byte {
	r := rand.New(rand.NewSource(6809))
	var out [][]byte
	fixed := []string{
		"", "a", "up", "hello world", `with"quote`, `back\slash`,
		"tab\there", "nl\nhere", "cr\rhere", "bell\ahere", "vt\vhere", "ff\fhere",
		"nul\x00here", "del\x7fhere", "esc\x1bhere",
		"h\u00e9llo", "\u65e5\u672c\u8a9e", "emoji\U0001F600here", "combining e\u0301",
		"\u00a0nbsp", "\u2028lineSep", "\ufeffbom", "\U0010FFFF max",
		"very" + string(make([]byte, 260)) + "long",
	}
	for _, s := range fixed {
		out = append(out, []byte(s))
	}
	// Invalid UTF-8: lone continuations, truncated sequences, overlongs,
	// surrogates, out-of-range.
	invalid := [][]byte{
		{0x80}, {0xBF}, {0xC0, 0x80}, {0xC1, 0xBF}, {0xE0, 0x80, 0x80},
		{0xED, 0xA0, 0x80}, {0xF0, 0x80, 0x80, 0x80}, {0xF4, 0x90, 0x80, 0x80},
		{0xF5, 0x80, 0x80, 0x80}, {0xFF}, {0xFE, 0xFE},
		{'a', 0x80, 'b'}, {0xC2}, {0xE2, 0x82}, {0xF0, 0x9F, 0x98},
	}
	out = append(out, invalid...)
	// Random byte soup: the highest-yield source of invalid-UTF-8 edge cases.
	for i := 0; i < 1200; i++ {
		b := make([]byte, r.Intn(24))
		for j := range b {
			b[j] = byte(r.Intn(256))
		}
		out = append(out, b)
	}
	// Random valid runes.
	for i := 0; i < 600; i++ {
		s := ""
		for j := 0; j < r.Intn(8); j++ {
			s += string(rune(r.Intn(0x10FFFF)))
		}
		out = append(out, []byte(s))
	}
	return out
}

func genQuote(e *emitter) {
	for i, b := range byteStringCorpus() {
		e.emit(fmt.Sprintf("q/%d", i), bytesIn{Bytes: hex.EncodeToString(b)},
			strconv.Quote(string(b)))
	}
}

// -------------------------------------------------------------------- varint

type varintIn struct {
	// Decimal strings so JSON does not lose 64-bit precision.
	U      string `json:"u"`
	Signed bool   `json:"signed"`
}

func genVarint(e *emitter) {
	r := rand.New(rand.NewSource(1234))
	var us []uint64
	us = append(us, 0, 1, 127, 128, 255, 256, 16383, 16384,
		math.MaxUint32, math.MaxUint64, math.MaxUint64-1, 1<<63)
	for i := 0; i < 1500; i++ {
		// Bias toward small values, which is what TSDB actually stores.
		switch r.Intn(3) {
		case 0:
			us = append(us, uint64(r.Intn(1<<8)))
		case 1:
			us = append(us, uint64(r.Int63n(1<<32)))
		default:
			us = append(us, r.Uint64())
		}
	}
	for i, u := range us {
		buf := make([]byte, 0, 10)
		e.emit(fmt.Sprintf("u/%d", i), varintIn{U: strconv.FormatUint(u, 10), Signed: false},
			hex.EncodeToString(appendUvarint(buf, u)))

		s := int64(u)
		e.emit(fmt.Sprintf("s/%d", i), varintIn{U: strconv.FormatInt(s, 10), Signed: true},
			hex.EncodeToString(appendVarint(buf[:0], s)))
	}
}

// ---------------------------------------------------------------------- hash

func genXXHash64(e *emitter) {
	for i, b := range byteStringCorpus() {
		e.emit(fmt.Sprintf("x/%d", i), bytesIn{Bytes: hex.EncodeToString(b)},
			fmt.Sprintf("%016x", xxhash.Sum64(b)))
	}
	// Length sweep: xxhash branches on >=32, then 8/4/1-byte tails.
	r := rand.New(rand.NewSource(99))
	for n := 0; n <= 200; n++ {
		b := make([]byte, n)
		for j := range b {
			b[j] = byte(r.Intn(256))
		}
		e.emit(fmt.Sprintf("xlen/%d", n), bytesIn{Bytes: hex.EncodeToString(b)},
			fmt.Sprintf("%016x", xxhash.Sum64(b)))
	}
}

func genCRC32C(e *emitter) {
	for i, b := range byteStringCorpus() {
		e.emit(fmt.Sprintf("c/%d", i), bytesIn{Bytes: hex.EncodeToString(b)},
			fmt.Sprintf("%08x", castagnoli(b)))
	}
	// Length sweep across the slicing-by-8 boundary.
	r := rand.New(rand.NewSource(1001))
	for n := 0; n <= 200; n++ {
		b := make([]byte, n)
		for j := range b {
			b[j] = byte(r.Intn(256))
		}
		e.emit(fmt.Sprintf("clen/%d", n), bytesIn{Bytes: hex.EncodeToString(b)},
			fmt.Sprintf("%08x", castagnoli(b)))
	}
}

// ---------------------------------------------------------------------- kahan

type kahanIn struct {
	Values []string `json:"values"`
}

type kahanOut struct {
	Sum string `json:"sum"`
	C   string `json:"c"`
}

func genKahan(e *emitter) {
	r := rand.New(rand.NewSource(4242))
	// Sequences chosen to exercise catastrophic cancellation, the Neumaier swap
	// branch, and the infinity reset.
	seqs := [][]float64{
		{1, 1e100, 1, -1e100},
		{1e16, 1, 1, 1, 1, 1, 1, 1},
		{0.1, 0.2, 0.3, 0.4, 0.5},
		{math.MaxFloat64, math.MaxFloat64},
		{math.MaxFloat64, -math.MaxFloat64, 1},
		{1e308, 1e308, -1e308},
		{math.SmallestNonzeroFloat64, 1, -1},
		{},
		{0},
	}
	for i := 0; i < 1500; i++ {
		n := 1 + r.Intn(24)
		s := make([]float64, n)
		for j := range s {
			switch r.Intn(4) {
			case 0:
				s[j] = r.NormFloat64()
			case 1:
				s[j] = r.NormFloat64() * math.Pow(10, float64(r.Intn(60)-30))
			case 2:
				s[j] = float64(r.Intn(1000))
			default:
				s[j] = math.Float64frombits(r.Uint64())
			}
		}
		seqs = append(seqs, s)
	}
	for i, seq := range seqs {
		var sum, c float64
		in := kahanIn{Values: make([]string, 0, len(seq))}
		bad := false
		for _, v := range seq {
			if math.IsNaN(v) {
				bad = true
				break
			}
			in.Values = append(in.Values, fbits(v))
			sum, c = kahansum.Inc(v, sum, c)
		}
		if bad {
			continue
		}
		e.emit(fmt.Sprintf("k/%d", i), in, kahanOut{Sum: fbits(sum), C: fbits(c)})
	}
}
