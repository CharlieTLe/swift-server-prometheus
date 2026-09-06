package main

// Differential coverage for §7i(a) — `tsdb/blockwriter.go` and `LeveledCompactor`'s WRITE path.
//
// **This is `oracle/blockfixture.go` in reverse.** That helper writes a block by hand so the READ path has an
// input; this one drives upstream's own writer end to end and commits what it produced, so the port's writer
// has an output to match. Nothing here assembles an index or a chunk segment: `BlockWriter` and
// `LeveledCompactor.Write` are both exported, so the corpus goes in through the same door a caller would.
//
// ## Four observables, and each one catches a different class of mistake
//
//  1. **The block's FILE BYTES** — `index`, every `chunks/NNNNNN`, and `meta.json`. This is the byte-identical
//     clause of the Phase 7 gate. A port that got the samples right and the chunk batching wrong fails here
//     and nowhere else.
//  2. **The DIRECTORY**: what exists under `dest` and what exists inside the block. That is what makes the
//     absent `tombstones` file (exception 26) a declared difference rather than a discovery, and what pins
//     the `.tmp-for-creation` directory being gone.
//  3. **`tsdb.OpenBlock` over the result** — labels, chunk metas, refs and samples, read back through real
//     upstream code. A block can be byte-identical and still be wrong about, say, `meta.json`'s stats; and a
//     block can decode correctly while its bytes differ. Neither observable subsumes the other.
//  4. **`Flush`'s return** — the ULID or nothing, and the error string.
//
// ## The ULID is SCRUBBED, and that is the whole trick
//
// `LeveledCompactor.Write` names its block `ulid.MustNew(ulid.Now(), rand.Reader)` — `crypto/rand`, reached
// directly, with no seam of any kind in v3.13.2 (quirk 196). Two consequences:
//
//   * a fixture that recorded the real ULID would differ on every regeneration, which §4 calls worse than no
//     fixture at all;
//   * the port therefore cannot be asked to reproduce it, only to *place* it correctly.
//
// So the generator substitutes the real 26-character ULID with `01ARZ3NDEKTSV4RRFFQ69G5FAV` everywhere it
// appears — the directory name, `meta.json`'s `ulid`, and `meta.json`'s `compaction.sources[0]` — and the port
// is handed the same constant through `LeveledCompactorOptions.newULID` (exception 27). The substitution is
// length-preserving, so every byte offset in `meta.json` survives it. It is a presentation transform on the
// oracle's output, in the same family as `scrubDir`; no upstream logic is reimplemented.
//
// **The index and the chunk segments contain no ULID at all**, so those two are compared with nothing
// scrubbed.
//
// ## Two modes, because `BlockWriter` cannot express a range
//
//   * `blockwriter` — `NewBlockWriter` / `Appender` / `Append` / `Commit` / `Flush` / `Close`. The whole head,
//     `[MinTime, MaxTime+1)`, and `w.head` is unexported so nothing else is reachable.
//   * `compactor` — `tsdb.NewHead` directly, then `NewLeveledCompactor(...).Write(dest, h, mint, maxt, base)`
//     with an explicit range. This is the only way to reach the arms that matter most: a range that CLIPS the
//     head, which makes §6s's synthetic deletion intervals fire and `populateWithDelChunkSeriesIterator`
//     re-encode a chunk; and a non-nil `base`, which is where `Parents` and the two compaction hints come
//     from.
//
// Both are real entry points. Neither reaches through an unexported symbol.

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/oklog/ulid/v2"
	"github.com/prometheus/common/promslog"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

// pinnedBlockULID is what every real ULID in this suite's output is replaced with. It is a valid ULID string
// (26 Crockford base32 characters, leading digit <= 7), so the port can parse it and produce the same
// directory name.
const pinnedBlockULID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

type bwSample struct {
	T int64  `json:"t"`
	V string `json:"v"`
}

type bwSeries struct {
	Labels map[string]string `json:"labels"`
	// `AppendSTZeroSample(0, lset, samples[0].T, *STZero)` before the samples, which is the only way to get a
	// start timestamp into a chunk. Needs `StoreST`, and only XOR2 stores it (quirk 36).
	STZero  *int64     `json:"stZero,omitempty"`
	Samples []bwSample `json:"samples"`
}

// A `Head.Delete` before the flush, so the tombstones reach `PopulateBlock` and the chunks get re-encoded.
type bwDelete struct {
	// "name=value" pairs, all equality matchers.
	Matchers []string `json:"matchers"`
	Mint     int64    `json:"mint"`
	Maxt     int64    `json:"maxt"`
}

// The `base *BlockMeta` argument of `LeveledCompactor.Write`, in the `compactor` mode only.
type bwBase struct {
	ULID    string   `json:"ulid"`
	MinTime int64    `json:"minTime"`
	MaxTime int64    `json:"maxTime"`
	Hints   []string `json:"hints,omitempty"`
}

type bwIn struct {
	// "blockwriter" | "compactor".
	Mode            string `json:"mode"`
	BlockSize       int64  `json:"blockSize"`
	SamplesPerChunk int    `json:"samplesPerChunk"`
	UseXOR2         bool   `json:"useXOR2,omitempty"`
	// `HeadOptions.EnableSTStorage`, which is what `promqltest` sets alongside `EncXOR2` (quirk 36).
	StoreST bool `json:"storeST,omitempty"`

	Series  []bwSeries `json:"series"`
	Deletes []bwDelete `json:"deletes,omitempty"`
	// `compactor` mode: use `head.MinTime()` / `head.MaxTime()+1`, which is exactly the range
	// `BlockWriter.Flush` computes. The mode exists so a case can DELETE before writing — `BlockWriter`
	// does not expose its head, so `Head.Delete` is unreachable through it.
	FullRange bool `json:"fullRange,omitempty"`
	// `compactor` mode, `fullRange` false: the explicit range handed to `Write`.
	Mint int64   `json:"mint,omitempty"`
	Maxt int64   `json:"maxt,omitempty"`
	Base *bwBase `json:"base,omitempty"`
	// `compactor` mode only: `Head.Truncate(mint)` before writing, which drops chunks and moves `MinTime`.
	TruncateBefore *int64 `json:"truncateBefore,omitempty"`
}

type bwFile struct {
	Name  string `json:"name"`
	Size  int    `json:"size"`
	Bytes string `json:"bytes"`
}

type bwChunkOut struct {
	Ref     uint64 `json:"ref"`
	MinTime int64  `json:"minTime"`
	MaxTime int64  `json:"maxTime"`
}

type bwSeriesOut struct {
	Labels  map[string]string `json:"labels"`
	Chunks  []bwChunkOut      `json:"chunks"`
	Samples []bwSample        `json:"samples"`
}

type bwOut struct {
	FlushErr string `json:"flushErr"`
	// The scrubbed ULID, or "" when no block was produced.
	ULID string `json:"ulid"`
	// Everything under `dest`, sorted. Scrubbed.
	DestEntries []string `json:"destEntries"`
	// Everything inside the block directory, sorted, `chunks/` prefixed.
	BlockFiles []string `json:"blockFiles"`

	MetaJSON   string   `json:"metaJSON"`
	IndexBytes string   `json:"indexBytes"`
	ChunkFiles []bwFile `json:"chunkFiles"`

	// Read back with `tsdb.OpenBlock`.
	OpenErr string        `json:"openErr"`
	Series  []bwSeriesOut `json:"series"`
}

func genBlockWrite(e *emitter) {
	n := 0
	emit := func(name string, in bwIn) {
		dir, err := os.MkdirTemp("", "promoracle-bw")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		dest := filepath.Join(dir, "dest")
		if err := os.MkdirAll(dest, 0o777); err != nil {
			panic(err)
		}

		out := bwOut{
			DestEntries: []string{}, BlockFiles: []string{}, ChunkFiles: []bwFile{},
			Series: []bwSeriesOut{},
		}

		var uid ulid.ULID
		switch in.Mode {
		case "blockwriter":
			uid = runBlockWriter(dir, dest, in, &out)
		case "compactor":
			uid = runCompactorWrite(dir, dest, in, &out)
		default:
			panic("unknown mode " + in.Mode)
		}

		scrub := func(s string) string {
			if uid == (ulid.ULID{}) {
				return s
			}
			return strings.ReplaceAll(s, uid.String(), pinnedBlockULID)
		}

		if uid != (ulid.ULID{}) {
			out.ULID = pinnedBlockULID
		}

		// (2) the directory.
		entries, err := os.ReadDir(dest)
		if err == nil {
			for _, ent := range entries {
				out.DestEntries = append(out.DestEntries, scrub(ent.Name()))
			}
			sort.Strings(out.DestEntries)
		}

		if uid != (ulid.ULID{}) {
			blockDir := filepath.Join(dest, uid.String())
			out.BlockFiles = listBlockFiles(blockDir)

			// (1) the file bytes.
			if b, rerr := os.ReadFile(filepath.Join(blockDir, "meta.json")); rerr == nil {
				out.MetaJSON = scrub(string(b))
			}
			if b, rerr := os.ReadFile(filepath.Join(blockDir, "index")); rerr == nil {
				out.IndexBytes = rleHex(b)
			}
			chunkEntries, cerr := os.ReadDir(filepath.Join(blockDir, "chunks"))
			if cerr == nil {
				names := []string{}
				for _, ce := range chunkEntries {
					names = append(names, ce.Name())
				}
				sort.Strings(names)
				for _, cn := range names {
					b, rerr := os.ReadFile(filepath.Join(blockDir, "chunks", cn))
					if rerr != nil {
						continue
					}
					out.ChunkFiles = append(
						out.ChunkFiles, bwFile{Name: cn, Size: len(b), Bytes: rleHex(b)})
				}
			}

			// (3) read it back with real upstream code.
			readBackBlock(blockDir, &out)
		}

		e.emit(fmt.Sprintf("bw/%03d/%s", n, name), in, out)
		n++
	}

	// --- helpers ------------------------------------------------------------------------------------

	const twoHours = int64(2 * 60 * 60 * 1000)

	base := func(mode string, series ...bwSeries) bwIn {
		return bwIn{Mode: mode, BlockSize: twoHours, SamplesPerChunk: 120, Series: series}
	}
	ser := func(name string, samples ...bwSample) bwSeries {
		return bwSeries{Labels: map[string]string{"__name__": name}, Samples: samples}
	}
	serL := func(lbls map[string]string, samples ...bwSample) bwSeries {
		return bwSeries{Labels: lbls, Samples: samples}
	}
	// A run of `count` samples starting at `start`, `step` apart, value `t/1000`.
	run := func(start, step int64, count int) []bwSample {
		out := []bwSample{}
		for i := 0; i < count; i++ {
			t := start + int64(i)*step
			out = append(out, bwSample{T: t, V: fbits(float64(t) / 1000)})
		}
		return out
	}

	// --- BlockWriter, end to end --------------------------------------------------------------------

	// Nothing appended at all. `MinTime()` is MaxInt64 and `MaxTime()+1` is MinInt64+1, so `Write` gets a
	// range whose start is past its end — and answers no block rather than an error. Quirk 203.
	emit("bw-empty-head", base("blockwriter"))

	// One series, one sample: the smallest block there is.
	emit("bw-one-sample", base("blockwriter", ser("a", bwSample{T: 1000, V: fbits(1)})))

	// One series, several samples in one chunk.
	emit("bw-one-series", base("blockwriter", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)}))

	// Three series: the symbol table has real content, the postings have three entries, and `AddSeries`
	// order is `labels.Compare` rather than append order — so appending c, a, b is the case that proves the
	// set sorts.
	emit("bw-three-series-out-of-order", base("blockwriter",
		bwSeries{Labels: map[string]string{"__name__": "c"}, Samples: run(1000, 1000, 3)},
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 3)},
		bwSeries{Labels: map[string]string{"__name__": "b"}, Samples: run(1000, 1000, 3)}))

	// Several labels per series, shared values: the symbol table de-duplicates and the postings have more
	// than one key.
	emit("bw-shared-symbols", base("blockwriter",
		serL(map[string]string{"__name__": "http", "job": "api", "code": "200"}, run(1000, 1000, 4)...),
		serL(map[string]string{"__name__": "http", "job": "api", "code": "500"}, run(1000, 1000, 4)...),
		serL(map[string]string{"__name__": "http", "job": "web", "code": "200"}, run(1000, 1000, 4)...)))

	// `SamplesPerChunk` forces a cut, so one series spans several chunks and the index's double-delta chunk
	// encoding has more than one entry to encode.
	//
	// **`compactor` + `fullRange`, not `blockwriter`.** `NewBlockWriter` builds its head from
	// `DefaultHeadOptions()` and overrides only `ChunkRange` and `ChunkDirRoot`, so `SamplesPerChunk` and
	// `FloatChunkEncoding` are unreachable through it — a case that set them in the `blockwriter` mode would
	// silently test the defaults. `cw-blockwriter-shape-control` is what establishes the two modes agree.
	multi := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 25)})
	multi.FullRange = true
	multi.SamplesPerChunk = 10
	emit("bw-multiple-chunks", multi)

	// The head's `ChunkRange` is the block size, so a small one cuts on the range rather than on the count.
	// `NewBlockWriter` DOES take the block size, so this one stays end to end.
	rangeCut := base("blockwriter", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(0, 1000, 12)})
	rangeCut.BlockSize = 4000
	emit("bw-chunkrange-cuts", rangeCut)

	// XOR2, which is what `promqltest` runs with (quirk 36) and what carries start timestamps.
	x2 := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 6)})
	x2.FullRange = true
	x2.UseXOR2 = true
	emit("bw-xor2", x2)

	x2multi := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 25)})
	x2multi.FullRange = true
	x2multi.UseXOR2 = true
	x2multi.SamplesPerChunk = 10
	emit("bw-xor2-multiple-chunks", x2multi)

	// Two series where one has far more samples than the other, so the chunk refs of the second series
	// start at a large offset — the `BlockChunkRef` arithmetic (quirk 142) with a non-trivial value.
	emit("bw-uneven-series", base("blockwriter",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 200)},
		bwSeries{Labels: map[string]string{"__name__": "b"}, Samples: run(1000, 1000, 2)}))

	// Negative and zero timestamps: `meta.MinTime` goes negative, and the index's signed varint for the
	// first chunk's mint has to carry it.
	emit("bw-negative-timestamps", base("blockwriter",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(-5000, 1000, 6)}))

	// A deletion that removes a series' samples entirely: `blockBaseSeriesSet` drops the chunk with
	// `IsSubrange` and the series never reaches `AddSeries`, so the block has one series where the head had
	// two — while the SYMBOL table still carries both names. Quirk 207.
	//
	// The delete cases run in the `compactor` mode with `fullRange`, which is `BlockWriter.Flush`'s own
	// configuration: `BlockWriter` does not expose its head, so `Head.Delete` cannot be reached through it.
	delAll := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)},
		bwSeries{Labels: map[string]string{"__name__": "b"}, Samples: run(1000, 1000, 5)})
	delAll.FullRange = true
	delAll.Deletes = []bwDelete{{Matchers: []string{"__name__=b"}, Mint: math.MinInt64, Maxt: math.MaxInt64}}
	emit("bw-delete-whole-series", delAll)

	// A deletion of the MIDDLE of a series: the chunk survives the subrange test, `currDelIter` is non-nil,
	// and the chunk is RE-ENCODED — different bytes and a different meta than the head's.
	delMid := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	delMid.FullRange = true
	delMid.Deletes = []bwDelete{{Matchers: []string{"__name__=a"}, Mint: 4000, Maxt: 6000}}
	emit("bw-delete-middle", delMid)

	// A deletion of the head of a series: the re-encoded chunk's `MinTime` moves.
	delHead := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	delHead.FullRange = true
	delHead.Deletes = []bwDelete{{Matchers: []string{"__name__=a"}, Mint: math.MinInt64, Maxt: 3000}}
	emit("bw-delete-front", delHead)

	// Every series deleted: no series reaches the index, `NumSamples` stays 0, and the whole temporary
	// directory is thrown away. Quirk 200 — `dest` must be EMPTY afterwards.
	delEverything := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)})
	delEverything.FullRange = true
	delEverything.Deletes = []bwDelete{
		{Matchers: []string{"__name__=a"}, Mint: math.MinInt64, Maxt: math.MaxInt64}}
	emit("bw-delete-everything", delEverything)

	// The control for the four above: the SAME head, the SAME range, no deletion. `compactor` + `fullRange`
	// must produce exactly the block `bw-one-series` produced through `BlockWriter`, which is what makes the
	// mode substitution above legitimate rather than a shortcut.
	fullShape := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	fullShape.FullRange = true
	emit("cw-blockwriter-shape-control", fullShape)

	// --- LeveledCompactor.Write with an explicit range ----------------------------------------------

	// The same data, written through the compactor with the range `BlockWriter` would have chosen. This is
	// the control for every clipped case below: it must produce the same block as `bw-one-series`.
	full := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	full.Mint, full.Maxt = 1000, 10001
	emit("cw-full-range", full)

	// A range that clips the TAIL. `trimBack` fires, the synthetic `[maxt+1, MaxInt64]` interval is added,
	// and the chunk is re-encoded down to the samples inside the block.
	clipBack := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	clipBack.Mint, clipBack.Maxt = 1000, 6000
	emit("cw-clip-back", clipBack)

	// A range that clips the FRONT.
	clipFront := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	clipFront.Mint, clipFront.Maxt = 5000, 10001
	emit("cw-clip-front", clipFront)

	// Both ends.
	clipBoth := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	clipBoth.Mint, clipBoth.Maxt = 4000, 8000
	emit("cw-clip-both", clipBoth)

	// **The boundary itself.** `maxt` is EXCLUSIVE, so the series set is built with `maxt-1`: a range
	// ending at 5001 keeps the sample at 5000 and a range ending at 5000 does not. Quirk 199, and the pair
	// is what makes the off-by-one visible.
	boundIn := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	boundIn.Mint, boundIn.Maxt = 1000, 5001
	emit("cw-boundary-inclusive", boundIn)

	boundOut := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	boundOut.Mint, boundOut.Maxt = 1000, 5000
	emit("cw-boundary-exclusive", boundOut)

	// A range that misses the data entirely: no samples, no block, `dest` untouched.
	miss := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	miss.Mint, miss.Maxt = 100000, 200000
	emit("cw-range-misses", miss)

	// A range clipping a series that has SEVERAL chunks, so the boundary falls between chunks for one and
	// inside a chunk for another.
	multiClip := base("compactor",
		bwSeries{Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 25)},
		bwSeries{Labels: map[string]string{"__name__": "b"}, Samples: run(1000, 1000, 25)})
	multiClip.SamplesPerChunk = 10
	multiClip.Mint, multiClip.Maxt = 6000, 18000
	emit("cw-clip-multiple-chunks", multiClip)

	// A `base` meta: `Parents` gets one entry and the two hints propagate. Nothing in the port produces an
	// out-of-order block, but `Write` reads the hint off `base`, so this is reachable.
	withBase := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)})
	withBase.Mint, withBase.Maxt = 1000, 5001
	withBase.Base = &bwBase{ULID: "01ARZ3NDEKTSV4RRFFQ69G5FAW", MinTime: 0, MaxTime: 999}
	emit("cw-base-parent", withBase)

	withOOO := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)})
	withOOO.Mint, withOOO.Maxt = 1000, 5001
	withOOO.Base = &bwBase{
		ULID: "01ARZ3NDEKTSV4RRFFQ69G5FAW", MinTime: 0, MaxTime: 999,
		Hints: []string{"from-out-of-order"}}
	emit("cw-base-out-of-order-hint", withOOO)

	withStale := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)})
	withStale.Mint, withStale.Maxt = 1000, 5001
	withStale.Base = &bwBase{
		ULID: "01ARZ3NDEKTSV4RRFFQ69G5FAW", MinTime: 0, MaxTime: 999,
		Hints: []string{"from-stale-series"}}
	emit("cw-base-stale-hint", withStale)

	// **Both hints.** `SetOutOfOrder`/`SetStaleSeries` re-SORT the hint list rather than appending in call
	// order, so the two come out alphabetically whichever way round they went in.
	withBoth := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 5)})
	withBoth.Mint, withBoth.Maxt = 1000, 5001
	withBoth.Base = &bwBase{
		ULID: "01ARZ3NDEKTSV4RRFFQ69G5FAW", MinTime: 0, MaxTime: 999,
		Hints: []string{"from-stale-series", "from-out-of-order"}}
	emit("cw-base-both-hints", withBoth)

	// A truncated head: `Truncate` drops chunks and moves `MinTime`, and `indexRange` then CLAMPS the
	// reader's mint up to it — so a compaction range reaching below the head's start writes only what is
	// left.
	truncated := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(0, 1000, 30)})
	truncated.SamplesPerChunk = 10
	tb := int64(15000)
	truncated.TruncateBefore = &tb
	truncated.Mint, truncated.Maxt = 0, 30001
	emit("cw-truncated-head", truncated)

	// A deletion plus a clip, so both a real tombstone and a synthetic trimming interval apply to the same
	// chunk — the interval list has two entries and `DeletedIterator` walks both.
	delAndClip := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1000, 1000, 10)})
	delAndClip.Deletes = []bwDelete{{Matchers: []string{"__name__=a"}, Mint: 3000, Maxt: 4000}}
	delAndClip.Mint, delAndClip.Maxt = 2000, 8000
	emit("cw-delete-and-clip", delAndClip)

	// **Dense samples across the clip boundary.** With samples a whole second apart, moving `mint` by one
	// millisecond changes nothing — the boundary lands in a gap. `blockBaseSeriesSet` compares
	// `chk.maxTime < mint` and `chk.minTime > maxt`, and the trimming intervals are `[MinInt64, mint-1]` and
	// `[maxt+1, MaxInt64]`, so a one-millisecond error is only visible when there is a sample at exactly the
	// millisecond in question. These two cases put one there.
	dense := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1, 1, 12)})
	dense.Mint, dense.Maxt = 5, 13
	emit("cw-clip-dense-front", dense)

	denseBack := base("compactor", bwSeries{
		Labels: map[string]string{"__name__": "a"}, Samples: run(1, 1, 12)})
	denseBack.Mint, denseBack.Maxt = 1, 8
	emit("cw-clip-dense-back", denseBack)

	// **Start timestamps.** `EnableSTStorage` plus `EncXOR2` is what `promqltest` runs with (quirk 36), and
	// this is the first thing in the port that can LOSE one: the head's open chunk is always re-encoded by a
	// compaction (quirk 208), and `populateCurrForSingleChunk` has to read `AtST()` per sample and pass it
	// on. With `EncXOR` the same case is silent, because the XOR appender discards the argument.
	stZero := int64(500)
	withST := bwIn{
		Mode: "compactor", BlockSize: twoHours, SamplesPerChunk: 120, UseXOR2: true, StoreST: true,
		FullRange: true,
		Series: []bwSeries{{
			Labels: map[string]string{"__name__": "a"}, STZero: &stZero,
			Samples: run(1000, 1000, 6)}}}
	emit("cw-xor2-start-timestamps", withST)

	// The same, with a deletion, so the re-encode runs over a chunk that has real tombstones too.
	stZero2 := int64(500)
	withSTDel := bwIn{
		Mode: "compactor", BlockSize: twoHours, SamplesPerChunk: 120, UseXOR2: true, StoreST: true,
		FullRange: true,
		Deletes:   []bwDelete{{Matchers: []string{"__name__=a"}, Mint: 3000, Maxt: 4000}},
		Series: []bwSeries{{
			Labels: map[string]string{"__name__": "a"}, STZero: &stZero2,
			Samples: run(1000, 1000, 8)}}}
	emit("cw-xor2-start-timestamps-deleted", withSTDel)

	// The XOR control for the pair above: the same start timestamps through `EncXOR`, which discards them.
	stZero3 := int64(500)
	withSTXor := bwIn{
		Mode: "compactor", BlockSize: twoHours, SamplesPerChunk: 120, StoreST: true,
		FullRange: true,
		Series: []bwSeries{{
			Labels: map[string]string{"__name__": "a"}, STZero: &stZero3,
			Samples: run(1000, 1000, 6)}}}
	emit("cw-xor-start-timestamps-discarded", withSTXor)

	// Many series, so the index's postings offset table has more than a handful of entries and the
	// symbol table crosses into multi-byte uvarint ordinals.
	many := bwIn{Mode: "blockwriter", BlockSize: twoHours, SamplesPerChunk: 120}
	for i := 0; i < 40; i++ {
		many.Series = append(many.Series, serL(
			map[string]string{
				"__name__": "metric", "instance": fmt.Sprintf("host-%02d", i),
				"job": fmt.Sprintf("job-%d", i%3),
			},
			run(1000, 1000, 3)...))
	}
	emit("bw-forty-series", many)
}

// runBlockWriter drives `NewBlockWriter` / `Appender` / `Flush` / `Close`, which is the whole of
// `blockwriter.go`.
func runBlockWriter(dir, dest string, in bwIn, out *bwOut) ulid.ULID {
	// `Flush` calls `w.logger.Info(...)` unconditionally, so a nil logger is a nil-pointer dereference.
	logger := promslog.NewNopLogger()

	// `NewBlockWriter` fixes `SamplesPerChunk` at the default and the chunk dir at a temp dir, so a case
	// that wants either changed has to go through the `compactor` mode. The one exception is the block
	// size, which is a parameter.
	w, err := tsdb.NewBlockWriter(logger, dest, in.BlockSize)
	if err != nil {
		out.FlushErr = err.Error()
		return ulid.ULID{}
	}

	app := w.Appender(context.Background())
	for _, s := range in.Series {
		for _, sm := range s.Samples {
			if _, aerr := app.Append(0, labels.FromMap(s.Labels), sm.T, fbitsToFloat(sm.V)); aerr != nil {
				out.FlushErr = aerr.Error()
				_ = w.Close()
				return ulid.ULID{}
			}
		}
	}
	if cerr := app.Commit(); cerr != nil {
		out.FlushErr = cerr.Error()
		_ = w.Close()
		return ulid.ULID{}
	}

	uid, ferr := w.Flush(context.Background())
	if ferr != nil {
		out.FlushErr = ferr.Error()
	}
	if cerr := w.Close(); cerr != nil && out.FlushErr == "" {
		out.FlushErr = cerr.Error()
	}
	return uid
}

// runCompactorWrite drives `tsdb.NewHead` plus `NewLeveledCompactor(...).Write`.
//
// With `FullRange` it reproduces `BlockWriter`'s configuration exactly — `ChunkRange = blockSize`,
// `Init(math.MinInt64)`, `[MinTime, MaxTime+1)`, a single-range compactor — on a head the caller can
// `Delete` from. Same code path; only the head handle differs.
func runCompactorWrite(dir, dest string, in bwIn, out *bwOut) ulid.ULID {
	h := newOracleHead(dir, in)
	defer h.Close()
	if !appendOracleSeries(h, in, out) {
		return ulid.ULID{}
	}
	if !applyDeletes(h, in, out) {
		return ulid.ULID{}
	}
	if in.TruncateBefore != nil {
		if terr := h.Truncate(*in.TruncateBefore); terr != nil {
			out.FlushErr = terr.Error()
			return ulid.ULID{}
		}
	}
	mint, maxt := in.Mint, in.Maxt
	if in.FullRange {
		mint, maxt = h.MinTime(), h.MaxTime()+1
	}
	return compactorWrite(dest, h, in, mint, maxt, out)
}

func newOracleHead(dir string, in bwIn) *tsdb.Head {
	chunkDir, err := os.MkdirTemp(dir, "head")
	if err != nil {
		panic(err)
	}
	opts := tsdb.DefaultHeadOptions()
	opts.ChunkDirRoot = chunkDir
	opts.ChunkRange = in.BlockSize
	opts.SamplesPerChunk = in.SamplesPerChunk
	if in.UseXOR2 {
		opts.FloatChunkEncoding.Store(uint32(chunkenc.EncXOR2))
	}
	opts.EnableSTStorage.Store(in.StoreST)
	h, err := tsdb.NewHead(nil, nil, nil, nil, opts, tsdb.NewHeadStats())
	if err != nil {
		panic(err)
	}
	// `BlockWriter.initHead` does exactly this: a backfill has to accept arbitrarily old samples.
	if err := h.Init(math.MinInt64); err != nil {
		panic(err)
	}
	return h
}

func appendOracleSeries(h *tsdb.Head, in bwIn, out *bwOut) bool {
	app := h.Appender(context.Background())
	for _, s := range in.Series {
		if s.STZero != nil && len(s.Samples) > 0 {
			if _, err := app.AppendSTZeroSample(
				0, labels.FromMap(s.Labels), s.Samples[0].T, *s.STZero); err != nil {
				out.FlushErr = err.Error()
				_ = app.Rollback()
				return false
			}
		}
		for _, sm := range s.Samples {
			if _, err := app.Append(0, labels.FromMap(s.Labels), sm.T, fbitsToFloat(sm.V)); err != nil {
				out.FlushErr = err.Error()
				_ = app.Rollback()
				return false
			}
		}
	}
	if err := app.Commit(); err != nil {
		out.FlushErr = err.Error()
		return false
	}
	return true
}

func applyDeletes(h *tsdb.Head, in bwIn, out *bwOut) bool {
	for _, d := range in.Deletes {
		ms := []*labels.Matcher{}
		for _, m := range d.Matchers {
			parts := strings.SplitN(m, "=", 2)
			ms = append(ms, labels.MustNewMatcher(labels.MatchEqual, parts[0], parts[1]))
		}
		if err := h.Delete(context.Background(), d.Mint, d.Maxt, ms...); err != nil {
			out.FlushErr = err.Error()
			return false
		}
	}
	return true
}

func compactorWrite(dest string, b tsdb.BlockReader, in bwIn, mint, maxt int64, out *bwOut) ulid.ULID {
	c, err := tsdb.NewLeveledCompactor(
		context.Background(), nil, promslog.NewNopLogger(), []int64{in.BlockSize},
		chunkenc.NewPool(), nil)
	if err != nil {
		out.FlushErr = err.Error()
		return ulid.ULID{}
	}

	var base *tsdb.BlockMeta
	if in.Base != nil {
		base = &tsdb.BlockMeta{
			ULID:    ulid.MustParse(in.Base.ULID),
			MinTime: in.Base.MinTime,
			MaxTime: in.Base.MaxTime,
		}
		base.Compaction.Hints = append([]string{}, in.Base.Hints...)
	}

	ids, err := c.Write(dest, b, mint, maxt, base)
	if err != nil {
		out.FlushErr = err.Error()
		return ulid.ULID{}
	}
	if len(ids) == 0 {
		return ulid.ULID{}
	}
	return ids[0]
}

// listBlockFiles names everything inside a block directory, `chunks/` prefixed, sorted.
func listBlockFiles(blockDir string) []string {
	names := []string{}
	entries, err := os.ReadDir(blockDir)
	if err != nil {
		return names
	}
	for _, ent := range entries {
		if !ent.IsDir() {
			names = append(names, ent.Name())
			continue
		}
		children, cerr := os.ReadDir(filepath.Join(blockDir, ent.Name()))
		if cerr != nil {
			continue
		}
		for _, c := range children {
			names = append(names, ent.Name()+"/"+c.Name())
		}
	}
	sort.Strings(names)
	return names
}

// readBackBlock is observable (3): `tsdb.OpenBlock` over what was just written, then every series read
// through the block querier's own machinery.
func readBackBlock(blockDir string, out *bwOut) {
	blk, err := tsdb.OpenBlock(nil, blockDir, chunkenc.NewPool(), tsdb.DefaultPostingsDecoderFactory)
	if err != nil {
		out.OpenErr = err.Error()
		return
	}
	defer blk.Close()

	q, err := tsdb.NewBlockChunkQuerier(blk, math.MinInt64, math.MaxInt64)
	if err != nil {
		out.OpenErr = err.Error()
		return
	}
	defer q.Close()

	ss := q.Select(context.Background(), true, nil,
		labels.MustNewMatcher(labels.MatchRegexp, "__name__", ".*"))
	for ss.Next() {
		s := ss.At()
		so := bwSeriesOut{
			Labels: s.Labels().Map(), Chunks: []bwChunkOut{}, Samples: []bwSample{}}
		it := s.Iterator(nil)
		for it.Next() {
			m := it.At()
			so.Chunks = append(
				so.Chunks, bwChunkOut{Ref: uint64(m.Ref), MinTime: m.MinTime, MaxTime: m.MaxTime})
			cit := m.Chunk.Iterator(nil)
			for cit.Next() == chunkenc.ValFloat {
				t, v := cit.At()
				so.Samples = append(so.Samples, bwSample{T: t, V: fbits(v)})
			}
		}
		if ierr := it.Err(); ierr != nil && out.OpenErr == "" {
			out.OpenErr = ierr.Error()
		}
		out.Series = append(out.Series, so)
	}
	if serr := ss.Err(); serr != nil && out.OpenErr == "" {
		out.OpenErr = serr.Error()
	}
}
