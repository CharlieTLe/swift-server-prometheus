package main

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"math/rand"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/tsdb/encoding"
)

// ------------------------------------------------------------------- helpers

func appendUvarint(buf []byte, x uint64) []byte {
	var tmp [binary.MaxVarintLen64]byte
	n := binary.PutUvarint(tmp[:], x)
	return append(buf, tmp[:n]...)
}

func appendVarint(buf []byte, x int64) []byte {
	var tmp [binary.MaxVarintLen64]byte
	n := binary.PutVarint(tmp[:], x)
	return append(buf, tmp[:n]...)
}

var castagnoliTable = crc32.MakeTable(crc32.Castagnoli)

func castagnoli(b []byte) uint32 { return crc32.Checksum(b, castagnoliTable) }

// -------------------------------------------------------------------- labels

// labelsIn carries names/values as HEX.
//
// They cannot travel as JSON strings: Go's encoding/json replaces invalid UTF-8
// with U+FFFD, which silently corrupts the fixture INPUT and makes every derived
// hash disagree. Hex keeps the bytes exact regardless.
type labelsIn struct {
	Labels [][2]string `json:"labels"`
}

type labelsOut struct {
	// labels.Hash() under the DEFAULT (stringlabels) build. See ADR-1.
	Hash string `json:"hash"`
	// The stringlabels packed encoding, which is what Hash() digests.
	Encoded string `json:"encoded"`
	String  string `json:"string"`
	NoSpace string `json:"noSpace"`
	// Implementation name, so a fixture regenerated under the wrong build tag
	// is loudly wrong instead of subtly wrong.
	Impl string `json:"impl"`
}

// corpusNames is shared by labelSetCorpus and the HashFor/HashWithout suites.
var corpusNames = []string{"__name__", "job", "instance", "le", "cpu", "mode", "a", "aa", "b", "zzz",
	"with.dot", "quantile", "namespace", "pod"}

// labelSetCorpus covers realistic Prometheus label sets plus adversarial ones:
// names needing quoting, values with control characters and invalid UTF-8, and
// values longer than 254 bytes to exercise the 0xFF/3-byte-LE length escape.
func labelSetCorpus() [][]labels.Label {
	r := rand.New(rand.NewSource(31337))
	var out [][]labels.Label

	out = append(out,
		nil,
		[]labels.Label{{Name: "__name__", Value: "up"}},
		[]labels.Label{{Name: "__name__", Value: "up"}, {Name: "job", Value: "node"}},
		[]labels.Label{
			{Name: "__name__", Value: "node_cpu_seconds_total"},
			{Name: "cpu", Value: "10"},
			{Name: "instance", Value: "10.253.57.87:9100"},
			{Name: "job", Value: "node-exporter"},
			{Name: "mode", Value: "idle"},
		},
		// Names that fail legacy validation -> Go quotes them in String().
		[]labels.Label{{Name: "with.dot", Value: "v"}},
		[]labels.Label{{Name: "with space", Value: "v"}},
		[]labels.Label{{Name: "üñïçø∂é", Value: "v"}},
		[]labels.Label{{Name: "0leading", Value: "v"}},
		[]labels.Label{{Name: "", Value: "empty name"}},
		// Values needing escapes.
		[]labels.Label{{Name: "a", Value: `has "quotes"`}},
		[]labels.Label{{Name: "a", Value: "has\ttab\nnewline"}},
		[]labels.Label{{Name: "a", Value: "has\x00nul\x7fdel"}},
		[]labels.Label{{Name: "a", Value: ""}},
		// The 0xFF length escape: 254/255/256 and beyond, for name and value.
		[]labels.Label{{Name: "a", Value: strings.Repeat("x", 254)}},
		[]labels.Label{{Name: "a", Value: strings.Repeat("x", 255)}},
		[]labels.Label{{Name: "a", Value: strings.Repeat("x", 256)}},
		[]labels.Label{{Name: "a", Value: strings.Repeat("x", 1000)}},
		[]labels.Label{{Name: strings.Repeat("n", 255), Value: "v"}},
		[]labels.Label{{Name: strings.Repeat("n", 300), Value: strings.Repeat("v", 300)}},
		// Ordering edge cases: prefix names, where a naive packed-byte compare
		// would disagree with name-then-value ordering.
		[]labels.Label{{Name: "a", Value: "1"}, {Name: "aa", Value: "2"}},
		[]labels.Label{{Name: "b", Value: "1"}},
		[]labels.Label{{Name: "aa", Value: "1"}},
	)

	// Random label sets.
	for i := 0; i < 1500; i++ {
		n := r.Intn(8)
		seen := map[string]bool{}
		var ls []labels.Label
		for j := 0; j < n; j++ {
			nm := corpusNames[r.Intn(len(corpusNames))]
			if seen[nm] {
				continue
			}
			seen[nm] = true
			var v string
			switch r.Intn(4) {
			case 0:
				v = fmt.Sprintf("%d", r.Intn(1000))
			case 1:
				v = strings.Repeat("v", r.Intn(64))
			case 2:
				// Control characters and quotes: exercises Quote's escapes while
				// staying valid UTF-8.
				pool := []string{"\x00", "\t", "\n", "\r", "\x7f", "\x1b", `"`, `\\`, " ", "="}
				for k := 0; k < r.Intn(6); k++ {
					v += pool[r.Intn(len(pool))]
				}
			default:
				v = randValidRune(r)
			}
			ls = append(ls, labels.Label{Name: nm, Value: v})
		}
		out = append(out, ls)
	}
	return out
}

// randValidRune returns a single valid UTF-8 rune, skipping the surrogate range
// (U+D800-U+DFFF), which is not encodable.
func randValidRune(r *rand.Rand) string {
	for {
		c := rune(r.Intn(0x10FFFF + 1))
		if c >= 0xD800 && c <= 0xDFFF {
			continue
		}
		return string(c)
	}
}

func genLabels(e *emitter) {
	for i, ls := range labelSetCorpus() {
		l := labels.New(ls...)
		e.emit(fmt.Sprintf("l/%d", i), toLabelsIn(l), labelsOut{
			Hash:    fmt.Sprintf("%016x", l.Hash()),
			Encoded: hex.EncodeToString(l.Bytes(nil)),
			String:  l.String(),
			NoSpace: l.StringNoSpace(),
			Impl:    labels.ImplementationName,
		})
	}
}

func toLabelsIn(l labels.Labels) labelsIn {
	in := labelsIn{Labels: make([][2]string, 0, l.Len())}
	l.Range(func(lb labels.Label) {
		// Guard the ADR-9 boundary: a Swift String cannot hold invalid UTF-8, so
		// the label corpus is restricted to valid UTF-8 and we assert it here
		// rather than discovering it as a mysterious hash mismatch.
		if !utf8.ValidString(lb.Name) || !utf8.ValidString(lb.Value) {
			panic("label corpus must be valid UTF-8; see docs/DECISIONS.md ADR-9")
		}
		in.Labels = append(in.Labels, [2]string{
			hex.EncodeToString([]byte(lb.Name)),
			hex.EncodeToString([]byte(lb.Value)),
		})
	})
	return in
}

type cmpIn struct {
	A labelsIn `json:"a"`
	B labelsIn `json:"b"`
}

// genLabelsCompare records only the SIGN of labels.Compare: Go's three label
// implementations return different magnitudes for the prefix case (stringlabels a
// byte-length delta, slicelabels a label-count delta), and every caller is a sort
// comparator. See docs/PORTING.md.
func genLabelsCompare(e *emitter) {
	corpus := labelSetCorpus()
	r := rand.New(rand.NewSource(555))
	for i := 0; i < 3000; i++ {
		a := labels.New(corpus[r.Intn(len(corpus))]...)
		b := labels.New(corpus[r.Intn(len(corpus))]...)
		c := labels.Compare(a, b)
		sign := 0
		if c < 0 {
			sign = -1
		} else if c > 0 {
			sign = 1
		}
		e.emit(fmt.Sprintf("cmp/%d", i), cmpIn{A: toLabelsIn(a), B: toLabelsIn(b)}, sign)
	}
}

type hashNamesIn struct {
	Labels labelsIn `json:"labels"`
	Names  []string `json:"names"`
}

type hashNamesOut struct {
	For     string `json:"for"`
	Without string `json:"without"`
}

// HashForLabels / HashWithoutLabels use 0xFF framing and ARE canonical across all
// three Go label implementations, unlike Hash(). `names` must be sorted ascending.
func genLabelsHashNames(e *emitter) {
	corpus := labelSetCorpus()
	r := rand.New(rand.NewSource(556))
	for i := 0; i < 2000; i++ {
		l := labels.New(corpus[r.Intn(len(corpus))]...)
		nameSet := map[string]bool{}
		for j := 0; j < r.Intn(4); j++ {
			nameSet[corpusNames[r.Intn(len(corpusNames))]] = true
		}
		sel := make([]string, 0, len(nameSet))
		for n := range nameSet {
			sel = append(sel, n)
		}
		sort.Strings(sel)
		hf, _ := l.HashForLabels(nil, sel...)
		hw, _ := l.HashWithoutLabels(nil, sel...)
		e.emit(fmt.Sprintf("hn/%d", i),
			hashNamesIn{Labels: toLabelsIn(l), Names: sel},
			hashNamesOut{
				For:     fmt.Sprintf("%016x", hf),
				Without: fmt.Sprintf("%016x", hw),
			})
	}
}

// -------------------------------------------------------------------- encbuf

// An op-script drives Encbuf so the fixture describes a byte-exact sequence of
// writes rather than a single value.
type encOp struct {
	Op string `json:"op"`
	// Arguments travel as strings so 64-bit values survive JSON intact.
	Arg string `json:"arg"`
}

type encbufIn struct {
	Ops []encOp `json:"ops"`
}

func genEncbuf(e *emitter) {
	r := rand.New(rand.NewSource(777))
	ops := []string{
		"byte", "be32", "be64", "be32int", "be64int64", "befloat64",
		"uvarint", "uvarint64", "varint64", "uvarintstr", "string", "hash",
	}
	for i := 0; i < 2000; i++ {
		n := 1 + r.Intn(10)
		var script []encOp
		var buf encoding.Encbuf
		for j := 0; j < n; j++ {
			op := ops[r.Intn(len(ops))]
			var arg string
			switch op {
			case "byte":
				v := byte(r.Intn(256))
				arg = fmt.Sprintf("%d", v)
				buf.PutByte(v)
			case "be32":
				v := uint32(r.Uint32())
				arg = fmt.Sprintf("%d", v)
				buf.PutBE32(v)
			case "be64":
				v := r.Uint64()
				arg = fmt.Sprintf("%d", v)
				buf.PutBE64(v)
			case "be32int":
				v := r.Intn(1 << 31)
				arg = fmt.Sprintf("%d", v)
				buf.PutBE32int(v)
			case "be64int64":
				v := r.Int63() - (1 << 62)
				arg = fmt.Sprintf("%d", v)
				buf.PutBE64int64(v)
			case "befloat64":
				v := r.NormFloat64()
				arg = fbits(v)
				buf.PutBEFloat64(v)
			case "uvarint":
				v := r.Intn(1 << 30)
				arg = fmt.Sprintf("%d", v)
				buf.PutUvarint(v)
			case "uvarint64":
				v := r.Uint64()
				arg = fmt.Sprintf("%d", v)
				buf.PutUvarint64(v)
			case "varint64":
				v := r.Int63() - (1 << 62)
				arg = fmt.Sprintf("%d", v)
				buf.PutVarint64(v)
			case "uvarintstr", "string":
				b := make([]byte, r.Intn(48))
				for k := range b {
					b[k] = byte(r.Intn(256))
				}
				arg = hex.EncodeToString(b)
				if op == "uvarintstr" {
					buf.PutUvarintStr(string(b))
				} else {
					buf.PutString(string(b))
				}
			case "hash":
				arg = ""
				buf.PutHash(crc32.New(castagnoliTable))
			}
			script = append(script, encOp{Op: op, Arg: arg})
		}
		e.emit(fmt.Sprintf("eb/%d", i), encbufIn{Ops: script},
			hex.EncodeToString(buf.Get()))
	}
}
