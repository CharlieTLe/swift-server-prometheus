package main

// Differential coverage for strconv.ParseInt / ParseUint and the NumError text.
//
// Pinned because the PromQL parser depends on all three behaviours being exact:
// `0755` must be 493 (base-0 octal), `1_000` must be 1000 (underscores are legal
// only for base 0), and the error text that reaches the user is the whole
// NumError — `strconv.ParseFloat: parsing "1e309": value out of range` — not just
// its ErrRange tail.

import (
	"fmt"
	"strconv"
)

func intParseCorpus() []string {
	var out []string
	add := func(ss ...string) { out = append(out, ss...) }

	// Plain decimal, signs, and the int64 boundaries.
	add("0", "1", "-1", "+1", "9", "10", "0000", "-0", "+0",
		"9223372036854775807", "9223372036854775808", "-9223372036854775808",
		"-9223372036854775809", "18446744073709551615", "18446744073709551616",
		"99999999999999999999999999999999")

	// Base prefixes, which base 0 infers and base 10 rejects.
	add("0x1f", "0X1F", "0xff", "0x", "0x0", "0b101", "0B101", "0b", "0b2",
		"0o17", "0O17", "0o", "0o8", "0755", "0777", "08", "09", "07", "00",
		"-0x1f", "+0x1f", "-0755")

	// Underscores: legal between digits and after a prefix, for base 0 only.
	add("1_000", "1_000_000", "0x_1f", "0b_1010", "0o_17", "0_755",
		"_1", "1_", "1__0", "0x1_", "0_x1", "-1_000")

	// Syntax errors and non-ASCII.
	add("", " ", "1 ", " 1", "+", "-", "++1", "--1", "1.0", "1e3", "abc",
		"0xg", "z", "١٢٣", "1\x00", "\xff", "1-1", "٢")

	return out
}

func genGoParseInt(e *emitter) {
	type numOut struct {
		Val string `json:"val"`
		Err string `json:"err"`
	}

	// The two (base, bitSize) pairs the parser actually uses, plus base 16 so the
	// implementation is pinned beyond the reachable set.
	cases := []struct {
		fn      string
		base    int
		bitSize int
	}{
		{"ParseInt", 0, 64},
		{"ParseInt", 10, 64},
		{"ParseUint", 10, 64},
		{"ParseUint", 0, 64},
		{"ParseUint", 16, 64},
		{"ParseInt", 0, 32},
	}

	for i, s := range intParseCorpus() {
		for _, c := range cases {
			var out numOut
			if c.fn == "ParseInt" {
				v, err := strconv.ParseInt(s, c.base, c.bitSize)
				out.Val = strconv.FormatInt(v, 10)
				if err != nil {
					out.Err = err.Error()
				}
			} else {
				v, err := strconv.ParseUint(s, c.base, c.bitSize)
				out.Val = strconv.FormatUint(v, 10)
				if err != nil {
					out.Err = err.Error()
				}
			}
			e.emit(fmt.Sprintf("%s/%d/%d/%d", c.fn, c.base, c.bitSize, i),
				map[string]any{
					"in":      fmt.Sprintf("%x", s),
					"fn":      c.fn,
					"base":    c.base,
					"bitSize": c.bitSize,
				}, out)
		}
	}
}
