package main

// Differential coverage for github.com/facette/natsort's `Compare`, which
// `promql/functions.go`'s `sort_by_label` and `sort_by_label_desc` call for every pair of
// label values.
//
// ## Compare is a Less that is not an ordering, and that is the point
//
//	Compare("a", "a")     == true    // not irreflexive
//	Compare("a1", "a01")  == true
//	Compare("a01", "a1")  == true    // ... and not asymmetric either
//
// `sort_by_label` guards the first with an `lv1 == lv2` test before calling; nothing
// guards the second. So the fixture has to pin `Compare` in BOTH directions for every
// pair, which is what `ab`/`ba` below are, and the sort's output then depends on the
// pdqsort in gocompat/sort.jsonl.
//
// ## What has to be reached
//
//   - the chunking, including its treatment of an empty string (NO chunks, so Compare is
//     false) and of a string that is all digits or all non-digits;
//   - numeric chunks that compare EQUAL as integers but differ as strings, i.e. leading
//     zeros — the case that makes Compare asymmetric;
//   - both "we reached the last chunk" early exits, which need one operand to be a
//     prefix-in-chunks of the other;
//   - digit runs long enough to OVERFLOW strconv.Atoi, where the comparison silently
//     falls back to comparing the chunks as strings and so orders the larger number
//     first;
//   - multi-byte UTF-8 and INVALID UTF-8, since Go compares strings byte-wise and the
//     regexp's `\D` matches a malformed byte as readily as a letter. Reachable in Go
//     because label values are arbitrary bytes; the operands travel as hex for that
//     reason.

import (
	"encoding/hex"
	"fmt"

	"github.com/facette/natsort"
)

type natsortIn struct {
	// Hex-encoded, because a label value is an arbitrary byte string and some cases
	// are deliberately not valid UTF-8.
	AHex string `json:"a"`
	BHex string `json:"b"`
}

type natsortOut struct {
	// Both directions: the asymmetry is the behaviour being pinned.
	AB bool `json:"ab"`
	BA bool `json:"ba"`
}

func runNatsortCase(in natsortIn) natsortOut {
	a, err := hex.DecodeString(in.AHex)
	if err != nil {
		panic(err)
	}
	b, err := hex.DecodeString(in.BHex)
	if err != nil {
		panic(err)
	}
	return natsortOut{
		AB: natsort.Compare(string(a), string(b)),
		BA: natsort.Compare(string(b), string(a)),
	}
}

func genGoNatsort(e *emitter) {
	n := 0
	emit := func(a, b string) {
		in := natsortIn{
			AHex: hex.EncodeToString([]byte(a)),
			BHex: hex.EncodeToString([]byte(b)),
		}
		e.emit(fmt.Sprintf("natsort/%d", n), in, runNatsortCase(in))
		n++
	}

	words := []string{
		// The empty string, which chunks to nothing.
		"",
		// Pure chunks of one kind.
		"a", "b", "ab", "z", "A", "Z",
		"0", "1", "2", "9", "10", "11", "100", "007", "0", "00",
		// Digits and letters interleaved, both ways round.
		"a1", "a2", "a10", "a01", "a001", "a1b", "a1b2", "1a", "10a", "01a",
		"x1y1", "x1y2", "x01y1",
		// The classic natural-sort motivation.
		"file1", "file2", "file10", "file20", "file100",
		"v1.2.3", "v1.2.10", "v1.10.2", "v1.2", "v1.2.3.4",
		// Chunk-prefix pairs, which drive both last-chunk exits.
		"a1x", "a1xx", "aa", "aaa",
		// Separators, which are ordinary non-digit chunks.
		"-", "-1", "1-", "+1", " 1", "1 ",
		// Overflowing digit runs. 19 digits is where Atoi's fast path ends and 20 is
		// past int64, so the pair below is compared as STRINGS and the larger number
		// sorts first.
		"9223372036854775807", "9223372036854775808",
		"9999999999999999999", "10000000000000000000",
		"99999999999999999999999999", "100000000000000000000000000",
		// Long equal-value runs with different lengths.
		"0000000000000000000000001", "1",
		// Multi-byte UTF-8: Go compares the bytes.
		"é", "e", "日", "z9", "é1", "é2",
		// Invalid UTF-8. The regexp engine sees U+FFFD, still a \D, and FindAllString
		// hands back the original bytes.
		"\xff", "\xff1", "\xfe1", "a\xffb", "\xc3", "\xc3\x28",
	}

	for i := range words {
		for j := range words {
			// Compare is asymmetric, so both (i,j) and (j,i) are emitted by the pair
			// itself; iterating i <= j would still cover it, but the full grid also pins
			// the reflexive Compare(x, x) == true for every shape.
			if j < i {
				continue
			}
			emit(words[i], words[j])
		}
	}
}
