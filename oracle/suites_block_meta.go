package main

// Differential coverage for a block's `meta.json`.
//
// This is the only JSON in the TSDB and therefore the only place `encoding/json`'s own behaviour is a
// compatibility surface: field order, `omitempty`, the tab indent, and Go's HTML-escaping of `<`, `>` and
// `&` inside a string. The port emits the JSON by hand for exactly those reasons, so this suite is what says
// whether that was done right.
//
// What has to be reached:
//   - field order and the tab indent, on a minimal meta;
//   - `omitempty` per stats counter — one set, all set, none set;
//   - `compaction`, which has NO `omitempty` and so is always emitted even when empty;
//   - `sources`, `parents` and `hints`, which are slices with `omitempty` (so absent when empty);
//   - `deletable` and `failed`, which are bools with `omitempty` (so absent when false);
//   - a `hints` string containing the characters Go escapes and `strconv.Quote` does not;
//   - ULID rendering, including all-zero and all-ones bytes.

import (
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/oklog/ulid/v2"
	"github.com/prometheus/prometheus/tsdb"
)

type blockMetaIn struct {
	ULIDHex             string     `json:"ulidHex"`
	MinTime             int64      `json:"minTime"`
	MaxTime             int64      `json:"maxTime"`
	NumSamples          uint64     `json:"numSamples"`
	NumFloatSamples     uint64     `json:"numFloatSamples"`
	NumHistogramSamples uint64     `json:"numHistogramSamples"`
	NumSeries           uint64     `json:"numSeries"`
	NumChunks           uint64     `json:"numChunks"`
	NumTombstones       uint64     `json:"numTombstones"`
	Level               int        `json:"level"`
	SourceHexes         []string   `json:"sourceHexes"`
	Deletable           bool       `json:"deletable"`
	ParentHexes         []string   `json:"parentHexes"`
	ParentTimes         [][2]int64 `json:"parentTimes"`
	Failed              bool       `json:"failed"`
	// Hex-encoded, because a hint is where the escaping cases live and a JSON string field would repair
	// exactly what is under test — the same trap the submatch and chunkenc corpora hit.
	HintHexes []string `json:"hintHexes"`
}

type blockMetaOut struct {
	// The marshalled bytes, hex — so a trailing-newline or indent difference cannot hide.
	JSONHex string `json:"jsonHex"`
	// The ULID's string rendering, separately, so a ULID bug is distinguishable from a JSON bug.
	ULIDString string `json:"ulidString"`
}

func ulidFromHex(h string) ulid.ULID {
	b, _ := hex.DecodeString(h)
	var u ulid.ULID
	copy(u[:], b)
	return u
}

func genBlockMeta(e *emitter) {
	n := 0
	emit := func(in blockMetaIn) {
		hints := []string{}
		for _, h := range in.HintHexes {
			b, _ := hex.DecodeString(h)
			hints = append(hints, string(b))
		}
		if len(hints) == 0 {
			hints = nil
		}
		m := tsdb.BlockMeta{
			ULID:    ulidFromHex(in.ULIDHex),
			MinTime: in.MinTime,
			MaxTime: in.MaxTime,
			Stats: tsdb.BlockStats{
				NumSamples:          in.NumSamples,
				NumFloatSamples:     in.NumFloatSamples,
				NumHistogramSamples: in.NumHistogramSamples,
				NumSeries:           in.NumSeries,
				NumChunks:           in.NumChunks,
				NumTombstones:       in.NumTombstones,
			},
			Compaction: tsdb.BlockMetaCompaction{
				Level:     in.Level,
				Deletable: in.Deletable,
				Failed:    in.Failed,
				Hints:     hints,
			},
			Version: 1,
		}
		for _, h := range in.SourceHexes {
			m.Compaction.Sources = append(m.Compaction.Sources, ulidFromHex(h))
		}
		for i, h := range in.ParentHexes {
			d := tsdb.BlockDesc{ULID: ulidFromHex(h)}
			if i < len(in.ParentTimes) {
				d.MinTime = in.ParentTimes[i][0]
				d.MaxTime = in.ParentTimes[i][1]
			}
			m.Compaction.Parents = append(m.Compaction.Parents, d)
		}

		b, err := json.MarshalIndent(&m, "", "\t")
		out := blockMetaOut{ULIDString: m.ULID.String()}
		if err == nil {
			out.JSONHex = hex.EncodeToString(b)
		}
		e.emit(fmt.Sprintf("blockmeta/%d", n), in, out)
		n++
	}

	zero := "00000000000000000000000000000000"
	ones := "ffffffffffffffffffffffffffffffff"
	sample := "0189d5b1a2c34e5f8091a2b3c4d5e6f7"
	hx := func(s string) string { return hex.EncodeToString([]byte(s)) }

	// A minimal meta: field order, the tab indent, empty stats and empty compaction.
	emit(blockMetaIn{ULIDHex: sample, MinTime: 0, MaxTime: 0})
	emit(blockMetaIn{ULIDHex: sample, MinTime: 1, MaxTime: 2})
	emit(blockMetaIn{ULIDHex: zero, MinTime: -1, MaxTime: -1})
	emit(blockMetaIn{ULIDHex: ones, MinTime: 1 << 62, MaxTime: 1 << 62})

	// `omitempty` per stats counter.
	emit(blockMetaIn{ULIDHex: sample, NumSamples: 1})
	emit(blockMetaIn{ULIDHex: sample, NumTombstones: 1})
	emit(blockMetaIn{ULIDHex: sample, NumSeries: 5, NumChunks: 7})
	emit(blockMetaIn{
		ULIDHex: sample, NumSamples: 1, NumFloatSamples: 2, NumHistogramSamples: 3,
		NumSeries: 4, NumChunks: 5, NumTombstones: 6,
	})

	// Compaction's fields, each with `omitempty` except the struct itself.
	emit(blockMetaIn{ULIDHex: sample, Level: 1})
	emit(blockMetaIn{ULIDHex: sample, Deletable: true})
	emit(blockMetaIn{ULIDHex: sample, Failed: true})
	emit(blockMetaIn{ULIDHex: sample, SourceHexes: []string{zero}})
	emit(blockMetaIn{ULIDHex: sample, SourceHexes: []string{zero, ones, sample}})
	emit(blockMetaIn{
		ULIDHex: sample, ParentHexes: []string{zero}, ParentTimes: [][2]int64{{1, 2}},
	})
	emit(blockMetaIn{
		ULIDHex:     sample,
		ParentHexes: []string{zero, ones},
		ParentTimes: [][2]int64{{1, 2}, {-3, 4}},
	})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("from-out-of-order")}})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("a"), hx("b")}})
	// Everything at once.
	emit(blockMetaIn{
		ULIDHex: sample, MinTime: 100, MaxTime: 200, NumSamples: 9, NumSeries: 3,
		Level: 2, SourceHexes: []string{zero, ones}, Deletable: true,
		ParentHexes: []string{sample}, ParentTimes: [][2]int64{{5, 6}}, Failed: true,
		HintHexes: []string{hx("h1"), hx("h2")},
	})

	// The characters Go's JSON escapes and `strconv.Quote` does not: `<`, `>`, `&` are HTML-escaped by
	// default, and control bytes become `\uXXXX`.
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("a<b>c&d")}})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("quote\"back\\slash")}})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("tab\there\nnewline\rcr")}})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("")}})
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("unicode é 日本")}})
	// A control byte and DEL, which JSON must escape but `strconv.Quote` renders differently.
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{"01021f7f"}})
	// U+2028 and U+2029, which Go escapes even though they are valid in a JSON string.
	emit(blockMetaIn{ULIDHex: sample, HintHexes: []string{hx("a b c")}})
}
