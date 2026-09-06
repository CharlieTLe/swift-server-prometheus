package main

// Differential coverage for the tombstone FILE CODEC — `Encode`, `WriteFile`, `Decode` and
// `ReadTombstones` in `tsdb/tombstones/tombstones.go`. The arithmetic half is `block/tsintervals`;
// this is the on-disk format a block carries, and PORTING.md exception 16's other half.
//
// ## The corpus commits BYTES, because the format is the deliverable
//
// Every case records the hex of `Encode`'s output *and* of the file `WriteFile` left on disk, not just the
// intervals that came back. A port could get every interval right and still frame them differently: the
// magic, the version byte, the varint spelling and the CRC's input range are four independent decisions and
// a decoded-intervals-only assertion pins none of them.
//
// Both directions of the round trip are covered by that one equality. Go writes the bytes and reads them
// back here; the port writes the same input and must produce the same bytes, then read them back to the same
// intervals. Byte equality is what makes "upstream can read what the port wrote" follow — there is nothing
// left for a second, live round trip to establish.
//
// ## Why the Reader handed to `Encode` is not a bare `MemTombstones`
//
// `Encode` walks `tr.Iter`, and `MemTombstones.Iter` **ranges a Go map**. So a file over more than one series
// has a different byte order run to run, and committing one would make `verify-fixtures.sh` flaky — HANDOFF
// §4's "a fixture whose own output is nondeterministic is worse than no fixture", the third instance.
//
// Upstream has no order to be exact against, so the port picks one (ascending ref, PORTING.md exception 29)
// and this corpus hands Go a `Reader` that yields the same one. The `Reader` interface is the documented
// parameter of both `Encode` and `WriteFile`, so this is still the real entry point with a real
// implementation behind it — the intervals themselves come from a real `MemTombstones` built by real
// `AddInterval` calls, so the merge behaviour is on the path too.
//
// ## What the cases have to reach
//
//   - the EMPTY file, which is nine bytes and whose CRC is the checksum of nothing;
//   - `uvarint` refs of every width, 0 and `MaxUint64` included (10 bytes);
//   - `varint` (zigzag) timestamps at 0, ±1, `MinInt64` and `MaxInt64`;
//   - a series with SEVERAL intervals, so the repeated ref is visible;
//   - several series, so the entry order is;
//   - intervals that MERGE on the way in and again on the way back out, which is why the round trip is the
//     identity on the interval set and not on the entry list;
//   - `Iter` returning an ERROR, which is the only way `Encode` and `WriteFile` fail on a well-formed input —
//     it pins `encoding tombstones: %w` and the fact that `Encode` hands back the PARTIAL buffer;
//   - the directory listing after a write, because `tombstones.tmp` surviving would be a leak the intervals
//     cannot see.

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"sort"

	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/tombstones"
)

// One `AddInterval` call. Applied in order, so the merging is part of the input rather than assumed.
type tsAdd struct {
	Ref  uint64 `json:"ref"`
	Mint int64  `json:"mint"`
	Maxt int64  `json:"maxt"`
}

// One series' worth of intervals, flattened. Used for both directions.
type tsEntry struct {
	Ref       uint64     `json:"ref"`
	Intervals [][2]int64 `json:"intervals"`
}

type tsFileIn struct {
	Adds []tsAdd `json:"adds"`
	// `Get` probes against the reader `ReadTombstones` returned, including refs that were never added.
	Probes []uint64 `json:"probes"`
	// Make the Reader's `Iter` fail after this many entries. -1 never fails.
	IterFailsAfter int `json:"iterFailsAfter"`
}

type tsFileOut struct {
	// `Encode`'s output, hex. Present even when `EncodeErr` is set — Go returns the partial buffer.
	Encoded   string `json:"encoded"`
	EncodeErr string `json:"encodeErr"`

	// The bytes `WriteFile` left at `dir/tombstones`, hex. "" when the file does not exist.
	File     string   `json:"file"`
	Size     int64    `json:"size"`
	WriteErr string   `json:"writeErr"`
	Dirents  []string `json:"dirents"`

	// `ReadTombstones` of what `WriteFile` wrote.
	ReadEntries []tsEntry `json:"readEntries"`
	ReadTotal   uint64    `json:"readTotal"`
	ReadSize    int64     `json:"readSize"`
	ReadErr     string    `json:"readErr"`

	// `Decode` of `Encode`'s output, so the payload is pinned independently of the file's framing.
	DecodeEntries []tsEntry `json:"decodeEntries"`
	DecodeTotal   uint64    `json:"decodeTotal"`
	DecodeErr     string    `json:"decodeErr"`

	// One per probe: the intervals `Get` answered.
	Probed [][][2]int64 `json:"probed"`
}

// A `tombstones.Reader` whose `Iter` order is ASCENDING BY REF. See the header for why the corpus cannot use
// `MemTombstones` directly, and PORTING.md exception 29 for the port's matching choice.
type orderedTombstones struct {
	inner *tombstones.MemTombstones
	refs  []storage.SeriesRef
	// Fail after this many entries. -1 never fails.
	failAfter int
}

var errIterFailed = errors.New("iter failed")

func newOrderedTombstones(inner *tombstones.MemTombstones, failAfter int) *orderedTombstones {
	refs := []storage.SeriesRef{}
	_ = inner.Iter(func(ref storage.SeriesRef, _ tombstones.Intervals) error {
		refs = append(refs, ref)
		return nil
	})
	sort.Slice(refs, func(i, j int) bool { return refs[i] < refs[j] })
	return &orderedTombstones{inner: inner, refs: refs, failAfter: failAfter}
}

func (o *orderedTombstones) Get(ref storage.SeriesRef) (tombstones.Intervals, error) {
	return o.inner.Get(ref)
}

func (o *orderedTombstones) Iter(f func(storage.SeriesRef, tombstones.Intervals) error) error {
	for i, ref := range o.refs {
		if o.failAfter >= 0 && i >= o.failAfter {
			return errIterFailed
		}
		ivs, err := o.inner.Get(ref)
		if err != nil {
			return err
		}
		if err := f(ref, ivs); err != nil {
			return err
		}
	}
	return nil
}

func (o *orderedTombstones) Total() uint64 { return o.inner.Total() }
func (o *orderedTombstones) Close() error  { return nil }

func flattenTombstoneReader(tr tombstones.Reader) []tsEntry {
	out := []tsEntry{}
	_ = tr.Iter(func(ref storage.SeriesRef, ivs tombstones.Intervals) error {
		out = append(out, tsEntry{Ref: uint64(ref), Intervals: flattenIntervals(ivs)})
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Ref < out[j].Ref })
	return out
}

func genTombstoneFile(e *emitter) {
	n := 0
	emit := func(name string, in tsFileIn) {
		dir, err := os.MkdirTemp("", "promoracle-tsfile")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)

		mem := tombstones.NewMemTombstones()
		for _, a := range in.Adds {
			mem.AddInterval(storage.SeriesRef(a.Ref), tombstones.Interval{Mint: a.Mint, Maxt: a.Maxt})
		}
		tr := newOrderedTombstones(mem, in.IterFailsAfter)

		out := tsFileOut{
			Dirents: []string{}, ReadEntries: []tsEntry{}, DecodeEntries: []tsEntry{},
			Probed: [][][2]int64{},
		}

		encoded, encErr := tombstones.Encode(tr)
		out.Encoded = hex.EncodeToString(encoded)
		out.EncodeErr = errString(encErr)

		size, wErr := tombstones.WriteFile(slog.New(slog.DiscardHandler), dir, tr)
		out.Size = size
		out.WriteErr = errString(wErr)

		if b, err := os.ReadFile(filepath.Join(dir, tombstones.TombstonesFilename)); err == nil {
			out.File = hex.EncodeToString(b)
		}
		if ents, err := os.ReadDir(dir); err == nil {
			for _, ent := range ents {
				out.Dirents = append(out.Dirents, ent.Name())
			}
			sort.Strings(out.Dirents)
		}

		readBack, readSize, rErr := tombstones.ReadTombstones(dir)
		out.ReadSize = readSize
		out.ReadErr = errString(rErr)
		if rErr == nil {
			out.ReadEntries = flattenTombstoneReader(readBack)
			out.ReadTotal = readBack.Total()
			for _, p := range in.Probes {
				ivs, err := readBack.Get(storage.SeriesRef(p))
				if err != nil {
					panic(err)
				}
				out.Probed = append(out.Probed, flattenIntervals(ivs))
			}
		}

		decoded, dErr := tombstones.Decode(encoded)
		out.DecodeErr = errString(dErr)
		if dErr == nil {
			out.DecodeEntries = flattenTombstoneReader(decoded)
			out.DecodeTotal = decoded.Total()
		}

		e.emit(fmt.Sprintf("tsfile/%02d-%s", n, name), in, out)
		n++
	}

	add := func(ref uint64, mint, maxt int64) tsAdd { return tsAdd{Ref: ref, Mint: mint, Maxt: maxt} }
	plain := func(name string, adds ...tsAdd) {
		emit(name, tsFileIn{Adds: adds, Probes: []uint64{}, IterFailsAfter: -1})
	}

	// The empty file: nine bytes, and the CRC of nothing. This is what `compact.go:739` writes for every
	// block that has no deletions, so it is the single most-written tombstone file in Prometheus.
	plain("empty")

	// One series, one interval — the shape the file header's worked example uses.
	plain("one", add(7, 1, 5))
	plain("ref-zero", add(0, 1, 5))
	plain("ref-one", add(1, 0, 0))

	// `uvarint` widths. 127/128 is the one-to-two-byte boundary, 16383/16384 the two-to-three.
	plain("ref-127", add(127, 1, 2))
	plain("ref-128", add(128, 1, 2))
	plain("ref-16383", add(16383, 1, 2))
	plain("ref-16384", add(16384, 1, 2))
	plain("ref-maxint64", add(uint64(math.MaxInt64), 1, 2))
	plain("ref-maxuint64", add(math.MaxUint64, 1, 2))

	// `varint` (zigzag) widths and signs. -1 is one byte, 0 is one byte, 63/64 the boundary.
	plain("t-zero", add(3, 0, 0))
	plain("t-negative", add(3, -1, -1))
	plain("t-63", add(3, 63, 64))
	plain("t-neg-64", add(3, -65, -64))
	plain("t-minmax", add(3, math.MinInt64, math.MaxInt64))
	plain("t-min-only", add(3, math.MinInt64, -1))
	plain("t-max-only", add(3, 1, math.MaxInt64))

	// SEVERAL intervals on one series: the ref is repeated once per interval, which is the property that
	// makes a tombstone file's entry count differ from its series count.
	plain("multi-interval", add(4, 1, 2), add(4, 10, 12), add(4, 20, 22))
	// Added out of order — `Intervals.Add` sorts, so the file is still ascending by mint.
	plain("multi-interval-unsorted", add(4, 20, 22), add(4, 1, 2), add(4, 10, 12))
	// MERGING on the way in: three adds, one interval on disk.
	plain("merge-adjacent", add(4, 1, 5), add(4, 6, 9), add(4, 10, 14))
	plain("merge-overlap", add(4, 1, 10), add(4, 5, 15))
	plain("merge-idempotent", add(4, 1, 10), add(4, 1, 10), add(4, 1, 10))

	// Several series, so the entry ORDER is visible. Added in descending ref, written ascending.
	plain("many-series", add(9, 1, 2), add(5, 3, 4), add(1, 5, 6))
	plain(
		"many-series-multi",
		add(2, 1, 2), add(2, 10, 12), add(3, 5, 6), add(1, 100, 200), add(1, 300, 400),
	)

	// A wide one: 64 series with 1-3 intervals each, so the varint widths mix within one file.
	{
		adds := []tsAdd{}
		for i := range 64 {
			ref := uint64(i * 37)
			adds = append(adds, add(ref, int64(i)*1000, int64(i)*1000+10))
			if i%2 == 0 {
				adds = append(adds, add(ref, int64(i)*1000+100, int64(i)*1000+110))
			}
			if i%5 == 0 {
				adds = append(adds, add(ref, -int64(i)*1000, -int64(i)*1000+5))
			}
		}
		plain("wide", adds...)
	}

	// `Get` probes against the reader that came back, including refs that were never written. `Get` on an
	// absent ref answers nil rather than an error, which is what lets `blockBaseSeriesSet` call it blind.
	emit("probes", tsFileIn{
		Adds: []tsAdd{
			add(1, 10, 20), add(1, 30, 40), add(2, 5, 5), add(100, math.MinInt64, math.MaxInt64),
		},
		Probes:         []uint64{0, 1, 2, 3, 99, 100, 101, math.MaxUint64},
		IterFailsAfter: -1,
	})

	// The trimming intervals `blockBaseSeriesSet` adds, written to a file. The overflow guards are on the
	// path in `AddInterval` and the zigzag extremes are on the path in the codec, in one case.
	emit("trim-intervals", tsFileIn{
		Adds: []tsAdd{
			add(1, math.MinInt64, 99), add(1, 201, math.MaxInt64), add(1, 120, 130),
		},
		Probes:         []uint64{1},
		IterFailsAfter: -1,
	})

	// `Iter` FAILS. The only way a well-formed input makes `Encode` and `WriteFile` fail, and the only way
	// to see that `Encode` returns its PARTIAL buffer alongside the error.
	emit("iter-fails-immediately", tsFileIn{
		Adds:           []tsAdd{add(1, 1, 2), add(2, 3, 4)},
		Probes:         []uint64{},
		IterFailsAfter: 0,
	})
	emit("iter-fails-midway", tsFileIn{
		Adds:           []tsAdd{add(1, 1, 2), add(2, 3, 4), add(3, 5, 6)},
		Probes:         []uint64{},
		IterFailsAfter: 2,
	})
	// Fails after everything, so it does not fail at all — the inert twin of the two above, which is what
	// says the failure is the `Iter` error and not the `failAfter` plumbing.
	emit("iter-fails-never", tsFileIn{
		Adds:           []tsAdd{add(1, 1, 2), add(2, 3, 4), add(3, 5, 6)},
		Probes:         []uint64{},
		IterFailsAfter: 3,
	})
}
