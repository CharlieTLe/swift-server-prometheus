package main

// Differential coverage for tsdb/wlog's SEGMENT FORMAT — the envelope §7a's records travel in.
//
// One suite, `wal/segments`, and it is a round trip in the same sense `record/encode` is: the committed
// output is the **segment bytes** plus what `wlog.Reader` reads back out of them, so the writer and the
// reader cannot be wrong in a way the other hides.
//
// ## Why the bytes are RLE-encoded rather than plain hex
//
// A page is 32 KB and most of a realistic page is zero padding, so plain hex would make this file tens of
// megabytes and the interesting bytes unfindable. `rleHex` is a **reversible** encoding — hex pairs for
// non-zero bytes, `z<n>` for a run of n zeros — so it is still byte-exact, and a padding run of the wrong
// length is still a diff. It is not a digest: nothing is lost.
//
// ## What has to be reached, and why each case exists
//
//   - **a zero-length record.** `for i := 0; i == 0 || len(enc) > 0; i++` runs at least once, so an empty
//     record is a real `recFull` fragment with length 0 and the CRC of nothing. Written as a `while` loop it
//     would vanish, and the reader would see one fewer record with no error;
//   - **the batch boundary.** `Log(a, b)` flushes once and `Log(a); Log(b)` twice, so the two produce
//     different FILES for the same record stream. Both are in, with the same records;
//   - **`Log()` with no records at all**, which writes nothing and must not flush;
//   - **a record that exactly fills the page** (`pageSize - recordHeaderSize`), and one byte either side of
//     it, because that is where `full()`'s `< recordHeaderSize` boundary and the split into first/last both
//     turn over;
//   - **a page with 1..6 bytes left**, which `full()` calls full and which therefore gets zero-padded with
//     no room for a terminator header — the reader has to accept a page whose terminator is at the very end;
//   - **a record spanning three pages**, so a `recMiddle` fragment exists at all;
//   - **a record that does not fit in the rest of the SEGMENT**, which rotates. With `segmentSize` at one
//     page this needs only a two-page record; the corpus also runs a 4-page segment so `donePages` and the
//     `(pageSize - recordHeaderSize) * (pagesPerSegment - donePages - 1)` term are both non-trivial;
//   - **`NextSegment` on an empty page**, which must NOT write a page of zeros into the abandoned segment;
//   - **`Truncate`**, including an index in the middle and one past the end;
//   - **a range read** with each bound open and closed, because `first` continues and `last` breaks;
//   - **reading a WAL with no records**, where the single segment is zero bytes long.
//
// Multi-page records are built as zeros with distinctive markers at the head, the middle and the tail. That
// is not laziness about the RLE: it means a fragment boundary that lands in the wrong place moves a marker,
// which shows up as a diff in the *record* as well as in the segment.

import (
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/prometheus/prometheus/tsdb/wlog"
	"github.com/prometheus/prometheus/util/compression"
)

const walPageSize = 32 * 1024
const walRecordHeaderSize = 7

// rleHex encodes bytes as hex pairs with runs of zeros collapsed to `z<n>.`. Reversible; see the file
// header. The trailing `.` is not decoration: hex pairs are themselves digits, so `z16372` followed by the
// byte 0x11 would read as a run of 1637211 without a terminator. That ambiguity panicked the first run.
func rleHex(b []byte) string {
	var sb strings.Builder
	i := 0
	for i < len(b) {
		if b[i] == 0 {
			j := i
			for j < len(b) && b[j] == 0 {
				j++
			}
			sb.WriteByte('z')
			sb.WriteString(strconv.Itoa(j - i))
			sb.WriteByte('.')
			i = j
			continue
		}
		sb.WriteString(hex.EncodeToString(b[i : i+1]))
		i++
	}
	return sb.String()
}

type walOp struct {
	// log | nextSegment | nextSegmentSync | truncate | sync
	Op string `json:"op"`
	// For `log`: the records, each rle-hex. A present-but-empty list is `Log()` with no arguments.
	Records []string `json:"records,omitempty"`
	// For `truncate`.
	Index int `json:"index,omitempty"`
}

type walSegmentOut struct {
	Name  string `json:"name"`
	Size  int    `json:"size"`
	Bytes string `json:"bytes"`
}

// A file planted in the directory BEFORE `NewSize` runs, so the construction path sees a non-empty WAL.
//
// Three of the sweep's survivors need this and nothing else: every other case starts from an empty directory,
// so `NewSize` never resumes and `listSegments` never sees a set that is unsorted or gappy. Note the names are
// deliberately NOT `%08d` in two of the cases — `listSegments` accepts any integer filename, and "9" against
// "10" is what tells a numeric sort apart from a lexicographic one.
type walSeedFile struct {
	Name  string `json:"name"`
	Bytes string `json:"bytes"`
}

type walIn struct {
	// In pages, so the fixture reads as "a 1-page segment" rather than "32768".
	SegmentPages int     `json:"segmentPages"`
	Ops          []walOp `json:"ops"`
	// The range handed to `NewSegmentsRangeReader`; -1 is open.
	ReadFirst int `json:"readFirst"`
	ReadLast  int `json:"readLast"`
	// Planted before `NewSize`. Omitted from every case that does not use it, so adding this field left the
	// existing fixture bytes untouched.
	PreSeed []walSeedFile `json:"preSeed,omitempty"`
}

type walOut struct {
	// The directory after `Close`, which IS the format.
	Segments []walSegmentOut `json:"segments"`
	// `Segments(dir)`, which is `(-1, -1)` for an empty directory.
	SegFirst int   `json:"segFirst"`
	SegLast  int   `json:"segLast"`
	Size     int64 `json:"size"`
	// `LastSegmentAndOffset`, read BEFORE Close because the offset is the in-memory page's `alloc`.
	LastSegment int    `json:"lastSegment"`
	LastOffset  int    `json:"lastOffset"`
	OpErr       string `json:"opErr"`

	// The read-back, through `NewSegmentsRangeReader` + `NewReader`.
	Read    []string `json:"read"`
	ReadErr string   `json:"readErr"`
	// `Reader.Segment()` and `Reader.Offset()`, NOT queried when the range selected no segments — see
	// `ReaderHasNoSegments`.
	ReadSegment int   `json:"readSegment"`
	ReadOffset  int64 `json:"readOffset"`
	// **`Reader.Segment()` PANICS on a reader with no segments**, and this corpus found it by reaching it:
	// `NewSegmentBufReader` deliberately returns `&segmentBufReader{}` with a nil `segs` so that `Read` can
	// answer `io.EOF`, and then `Segment()` does `b.segs[b.cur].Index()` with no guard —
	// `index out of range [0] with length 0`. Two families of case get there: a range whose `First` is past
	// the last segment, and a `Truncate` that removed every segment.
	//
	// So the accessors are skipped when this is set, because querying them would take the fixture generator
	// down (the trap PORTING.md §4 describes for the look-back wrappers, in a new place). The port's own
	// answers for this state are asserted Swift-side instead, since Go has none to compare against.
	ReaderHasNoSegments bool `json:"readerHasNoSegments"`
}

func genWALSegments(e *emitter) {
	n := 0
	emit := func(in walIn) {
		dir, err := os.MkdirTemp("", "promoracle-wal")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		out := walOut{Segments: []walSegmentOut{}, Read: []string{}}

		// Planted before construction, because `NewSize` reads the directory to pick its segment index.
		for _, sf := range in.PreSeed {
			if err := os.WriteFile(filepath.Join(dir, sf.Name), unrleHex(sf.Bytes), 0o666); err != nil {
				panic(err)
			}
		}

		w, err := wlog.NewSize(
			slog.New(slog.DiscardHandler), nil, dir, in.SegmentPages*walPageSize, compression.None)
		if err != nil {
			// A GAP in the planted indices makes this fail rather than panic — `NewSize` calls `Segments`,
			// which calls `listSegments`, which rejects a non-sequential set. That is a case, not a crash.
			out.OpErr = strings.ReplaceAll(err.Error(), dir, "<dir>")
			walReadBack(dir, in, &out)
			out.OpErr = strings.ReplaceAll(out.OpErr, dir, "<dir>")
			e.emit(fmt.Sprintf("wal/%03d/pages%d", n, in.SegmentPages), in, out)
			n++
			return
		}

		for _, op := range in.Ops {
			switch op.Op {
			case "log":
				recs := make([][]byte, 0, len(op.Records))
				for _, r := range op.Records {
					recs = append(recs, unrleHex(r))
				}
				err = w.Log(recs...)
			case "nextSegment":
				_, err = w.NextSegment()
			case "nextSegmentSync":
				_, err = w.NextSegmentSync()
			case "truncate":
				err = w.Truncate(op.Index)
			case "sync":
				err = w.Sync()
			default:
				panic("unknown wal op " + op.Op)
			}
			if err != nil {
				out.OpErr = err.Error()
				break
			}
		}

		// Before Close: the offset is the in-memory page's `alloc`, so closing first would lose it.
		if out.OpErr == "" {
			seg, off, err := w.LastSegmentAndOffset()
			if err != nil {
				out.OpErr = err.Error()
			}
			out.LastSegment, out.LastOffset = seg, off
		}

		if sz, err := w.Size(); err == nil {
			out.Size = sz
		}
		if err := w.Close(); err != nil && out.OpErr == "" {
			out.OpErr = err.Error()
		}

		walReadBack(dir, in, &out)
		out.OpErr = strings.ReplaceAll(out.OpErr, dir, "<dir>")

		e.emit(fmt.Sprintf("wal/%03d/pages%d", n, in.SegmentPages), in, out)
		n++
	}

	genWALSegmentCases(emit)
}

// The read-back half — the directory listing, `Segments`, and the `Reader` — shared by the `WL`-driven cases
// and the raw-bytes ones.
func walReadBack(dir string, in walIn, out *walOut) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		panic(err)
	}
	names := []string{}
	for _, en := range entries {
		names = append(names, en.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			panic(err)
		}
		out.Segments = append(out.Segments, walSegmentOut{Name: name, Size: len(b), Bytes: rleHex(b)})
	}

	first, last, err := wlog.Segments(dir)
	if err != nil {
		out.OpErr = err.Error()
	}
	out.SegFirst, out.SegLast = first, last

	sr, err := wlog.NewSegmentsRangeReader(
		wlog.SegmentRange{Dir: dir, First: in.ReadFirst, Last: in.ReadLast})
	if err != nil {
		out.ReadErr = strings.ReplaceAll(err.Error(), dir, "<dir>")
		return
	}
	r := wlog.NewReader(sr)
	for r.Next() {
		out.Read = append(out.Read, rleHex(r.Record()))
	}
	if e := r.Err(); e != nil {
		out.ReadErr = e.Error()
	}
	// The temp directory differs every run and `CorruptionErr` embeds it, so it has to be scrubbed or the
	// fixture is not reproducible (PORTING.md on corpus reproducibility).
	out.ReadErr = strings.ReplaceAll(out.ReadErr, dir, "<dir>")
	// See `ReaderHasNoSegments`: `Segment()` panics rather than answering when there are none.
	out.ReaderHasNoSegments = walRangeSelectsNothing(dir, in.ReadFirst, in.ReadLast)
	if !out.ReaderHasNoSegments {
		out.ReadSegment = r.Segment()
		out.ReadOffset = r.Offset()
	}
	sr.Close()
}

// Whether the range `NewSegmentsRangeReader` was given selects no segments at all, which is the state
// `Reader.Segment()` panics in. Computed the same way `NewSegmentsRangeReader` does rather than by asking the
// reader, because asking is the thing that crashes.
func walRangeSelectsNothing(dir string, first, last int) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return true
	}
	for _, en := range entries {
		k, err := strconv.Atoi(en.Name())
		if err != nil {
			continue
		}
		if first >= 0 && k < first {
			continue
		}
		if last >= 0 && k > last {
			continue
		}
		return false
	}
	return true
}

func unrleHex(s string) []byte {
	var out []byte
	i := 0
	for i < len(s) {
		if s[i] == 'z' {
			j := i + 1
			for j < len(s) && s[j] != '.' {
				j++
			}
			cnt, err := strconv.Atoi(s[i+1 : j])
			if err != nil {
				panic("bad rle run: " + s[i:j])
			}
			out = append(out, make([]byte, cnt)...)
			i = j + 1
			continue
		}
		b, err := hex.DecodeString(s[i : i+2])
		if err != nil {
			panic("bad rle hex: " + s[i:i+2])
		}
		out = append(out, b[0])
		i += 2
	}
	return out
}

// A record of `size` bytes: zeros with 8-byte markers at the head, the middle and the tail. RLE-friendly,
// and a fragment boundary in the wrong place moves a marker rather than being absorbed by the padding.
func markedRecord(size int, tag byte) string {
	b := make([]byte, size)
	put := func(at int) {
		for k := 0; k < 8 && at+k < size; k++ {
			b[at+k] = tag + byte(k)
		}
	}
	if size > 0 {
		put(0)
	}
	if size > 16 {
		put(size / 2)
	}
	if size > 8 {
		put(size - 8)
	}
	return rleHex(b)
}

func smallRecord(bytes ...byte) string { return rleHex(bytes) }

func genWALSegmentCases(emit func(walIn)) {
	logOp := func(recs ...string) walOp { return walOp{Op: "log", Records: recs} }
	all := func(pages int, ops ...walOp) walIn {
		return walIn{SegmentPages: pages, Ops: ops, ReadFirst: -1, ReadLast: -1}
	}

	maxFrag := walPageSize - walRecordHeaderSize

	// Nothing logged at all: one segment, zero bytes, and `Segments` reports 0/0 because the file exists.
	emit(all(1))
	// `Log()` with no records — the loop body never runs, so nothing is written and nothing is flushed.
	emit(all(1, walOp{Op: "log", Records: []string{}}))
	// A ZERO-LENGTH record. Point 3 of the format header.
	emit(all(1, logOp(smallRecord())))
	emit(all(1, logOp(smallRecord(), smallRecord())))
	// One small record, then two in one batch, then two in two batches — the batch boundary decides how
	// many flushes happen and therefore how much of the page reaches the file.
	emit(all(1, logOp(smallRecord(1, 2, 3))))
	emit(all(1, logOp(smallRecord(1, 2, 3), smallRecord(4, 5, 6))))
	emit(all(1, logOp(smallRecord(1, 2, 3)), logOp(smallRecord(4, 5, 6))))

	// The page-fill boundary, from below and above. `maxFrag` exactly fills the page and leaves 0 bytes,
	// so `full()` is true and the page is cleared; `maxFrag+1` must split.
	emit(all(2, logOp(markedRecord(maxFrag-1, 0x11))))
	emit(all(2, logOp(markedRecord(maxFrag, 0x22))))
	emit(all(2, logOp(markedRecord(maxFrag+1, 0x33))))

	// Leave 1..6 bytes of the page free, which `full()` counts as full: the tail is zero-padded and there
	// is no room for a terminator header, so the reader's `k == pageSize` arm is what handles it.
	for _, spare := range []int{1, 3, 6, 7, 8} {
		emit(all(2, logOp(markedRecord(maxFrag-spare, 0x44))))
	}

	// Three pages, so a `recMiddle` fragment exists.
	emit(all(4, logOp(markedRecord(2*maxFrag+100, 0x55))))
	// Exactly two fragments' worth, so the last fragment is full and the page after it is untouched.
	emit(all(4, logOp(markedRecord(2*maxFrag, 0x66))))

	// A record that does not fit in the remaining SEGMENT, so a rotation happens mid-log.
	emit(all(1, logOp(markedRecord(maxFrag+50, 0x77))))
	emit(all(2, logOp(smallRecord(9)), logOp(markedRecord(2*maxFrag-10, 0x88))))
	// Fill a 4-page segment gradually, so `donePages` is 1, 2, 3 in turn before the rotation.
	emit(all(4,
		logOp(markedRecord(maxFrag, 0x91)),
		logOp(markedRecord(maxFrag, 0x92)),
		logOp(markedRecord(maxFrag, 0x93)),
		logOp(markedRecord(maxFrag, 0x94)),
	))

	// NextSegment with an empty page must not write a page of zeros into the segment it abandons.
	emit(all(2, walOp{Op: "nextSegment"}))
	emit(all(2, logOp(smallRecord(1)), walOp{Op: "nextSegment"}, logOp(smallRecord(2))))
	emit(all(2, logOp(smallRecord(1)), walOp{Op: "nextSegmentSync"}, logOp(smallRecord(2))))
	// NextSegment straight after a record that already filled and cleared the page.
	emit(all(2, logOp(markedRecord(maxFrag, 0xa1)), walOp{Op: "nextSegment"}))

	// Sync is a no-op for the bytes and is here to prove it.
	emit(all(1, logOp(smallRecord(7)), walOp{Op: "sync"}, logOp(smallRecord(8))))

	// Truncate: below the first index, in the middle, at the last, and past the end.
	rotate := []walOp{
		logOp(smallRecord(1)), walOp{Op: "nextSegment"},
		logOp(smallRecord(2)), walOp{Op: "nextSegment"},
		logOp(smallRecord(3)),
	}
	for _, idx := range []int{0, 1, 2, 3, 5} {
		ops := append([]walOp{}, rotate...)
		ops = append(ops, walOp{Op: "truncate", Index: idx})
		emit(all(2, ops...))
	}

	// Range reads over a three-segment WAL: each bound open, each closed, and an empty range.
	for _, rng := range [][2]int{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}, {2, 1}, {5, -1}} {
		in := all(2, rotate...)
		in.ReadFirst, in.ReadLast = rng[0], rng[1]
		emit(in)
	}

	// A batch whose records straddle a page boundary in the middle of the batch, so the final flush sees a
	// partially-filled page that already has a cleared page behind it.
	emit(all(4,
		logOp(markedRecord(maxFrag-20, 0xb1), smallRecord(1, 2), markedRecord(100, 0xb2)),
	))
	// Many small records in one batch, crossing two page boundaries.
	var many []string
	for i := 0; i < 400; i++ {
		many = append(many, markedRecord(90+i%7, byte(0xc0+i%16)))
	}
	emit(all(4, logOp(many...)))

	// ---- A pre-seeded directory, which is the only way to reach `NewSize`'s resume arithmetic and
	// `listSegments`' two invariants. See `walSeedFile`. ----
	seeded := func(seed []walSeedFile, ops ...walOp) walIn {
		in := all(2, ops...)
		in.PreSeed = seed
		return in
	}
	// One existing segment: the new one must be `last + 1`, never `last`. Reusing the index would truncate
	// a segment a reader may still need.
	emit(seeded([]walSeedFile{{Name: "00000005", Bytes: ""}}, logOp(smallRecord(1))))
	// A non-empty existing segment, so the resumed index is picked over a file with real bytes in it.
	emit(seeded(
		[]walSeedFile{{Name: "00000000", Bytes: smallRecord(1, 2, 3)}}, logOp(smallRecord(4))))
	// "9" against "10": sorted NUMERICALLY these are sequential and the next index is 11; sorted
	// lexicographically they are 10 then 9, which the sequentiality check then rejects. So this one case
	// separates the two sorts.
	emit(seeded(
		[]walSeedFile{{Name: "9", Bytes: ""}, {Name: "10", Bytes: ""}}, logOp(smallRecord(1))))
	// A GAP, which is an error out of `NewSize` itself rather than a WAL that opens.
	emit(seeded([]walSeedFile{{Name: "0", Bytes: ""}, {Name: "2", Bytes: ""}}))
	// A non-integer filename is SKIPPED rather than rejected, which is how a `checkpoint.NNNNNN` directory
	// lives alongside the segments.
	emit(seeded(
		[]walSeedFile{{Name: "00000000", Bytes: ""}, {Name: "checkpoint.000123", Bytes: ""}},
		logOp(smallRecord(1))))
}
