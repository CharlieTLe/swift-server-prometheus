package main

// A shared helper: write a REAL block directory and open it with `tsdb.OpenBlock`.
//
// **This exists so the oracle never reimplements upstream logic**, and the temptation was real. The obvious
// shortcut for the querier suites is an adapter type satisfying `tsdb.BlockReader` by delegating to
// `index.Reader` and `chunks.Reader` — five methods, all trivial. But `Block.Index()` does not return the raw
// `*index.Reader`; it returns `blockIndexReader`, which is what routes `LabelValues` through
// `labelValuesWithMatchers` and prefixes errors with `block: <ulid>:`. An adapter returning the raw reader
// would bypass the very code under test, and an adapter reproducing `blockIndexReader` would be upstream
// logic living in the oracle — a fixture generator grading its own homework.
//
// So: write the three files a block is, and let `OpenBlock` do the rest. Everything the querier suites need
// then comes from real upstream code paths.
//
// The layout, and the order it has to be written in:
//
//	<dir>/meta.json      last, because its stats come from the other two
//	<dir>/index          needs the chunk refs, so after the chunks
//	<dir>/chunks/000001  first
//
// `OpenBlock` reads `meta.json` first and rejects any version but 1, so a malformed meta fails before the
// index is touched — which is also why the port reads it in that order (quirk 153).

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/oklog/ulid/v2"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
)

// blockSeries2 is one series as a suite wants to write it: labels, and the samples of each chunk.
type blockSeries2 struct {
	Labels labels.Labels
	// One entry per chunk. Splitting explicitly rather than by size, so a suite controls how many chunks a
	// series has — which is what makes the multi-chunk iterator paths reachable.
	Chunks [][]blockSample
}

type blockSample struct {
	T int64
	V float64
}

// hexOfBlockFile reads a file and hex-encodes it, so a suite can carry the bytes in its fixture's INPUT.
func hexOfBlockFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// writeOracleBlock writes a block directory and returns its path plus the file bytes, so a suite can put the
// bytes in its fixture's INPUT and the port can read the same block without a writer of its own.
func writeOracleBlock(dir string, series []blockSeries2) (indexHex, metaHex string, segHexes []string, err error) {
	if err = os.MkdirAll(filepath.Join(dir, "chunks"), 0o777); err != nil {
		return "", "", nil, err
	}

	// Sort by label set: `AddSeries` requires strictly increasing order.
	sorted := append([]blockSeries2{}, series...)
	sort.Slice(sorted, func(i, j int) bool {
		return labels.Compare(sorted[i].Labels, sorted[j].Labels) < 0
	})

	// 1. Chunks, in series order, so the refs ascend globally.
	cw, err := chunks.NewWriter(filepath.Join(dir, "chunks"))
	if err != nil {
		return "", "", nil, err
	}
	allMetas := make([][]chunks.Meta, len(sorted))
	var minT, maxT int64 = 0, 0
	first := true
	for i, s := range sorted {
		for _, samples := range s.Chunks {
			if len(samples) == 0 {
				continue
			}
			c := chunkenc.NewXORChunk()
			app, aerr := c.Appender()
			if aerr != nil {
				return "", "", nil, aerr
			}
			for _, sm := range samples {
				// `Append(st, t, v)` — `xorAppender.Append` IGNORES the start timestamp (`func (a
				// *xorAppender) Append(_, t int64, v float64)`), so 0 is not a magic value here, it is
				// unread. An XOR2 chunk would use it; these suites are float-only for now.
				app.Append(0, sm.T, sm.V)
			}
			m := chunks.Meta{
				MinTime: samples[0].T,
				MaxTime: samples[len(samples)-1].T,
				Chunk:   c,
			}
			allMetas[i] = append(allMetas[i], m)
			if first || samples[0].T < minT {
				minT = samples[0].T
			}
			if first || samples[len(samples)-1].T > maxT {
				maxT = samples[len(samples)-1].T
			}
			first = false
		}
		if len(allMetas[i]) > 0 {
			if werr := cw.WriteChunks(allMetas[i]...); werr != nil {
				return "", "", nil, werr
			}
		}
	}
	if err = cw.Close(); err != nil {
		return "", "", nil, err
	}

	// 2. Index. Symbols first, sorted and de-duplicated.
	iw, err := index.NewWriter(context.Background(), filepath.Join(dir, "index"))
	if err != nil {
		return "", "", nil, err
	}
	symSet := map[string]struct{}{}
	for _, s := range sorted {
		s.Labels.Range(func(l labels.Label) {
			symSet[l.Name] = struct{}{}
			symSet[l.Value] = struct{}{}
		})
	}
	syms := make([]string, 0, len(symSet))
	for s := range symSet {
		syms = append(syms, s)
	}
	sort.Strings(syms)
	for _, s := range syms {
		if err = iw.AddSymbol(s); err != nil {
			return "", "", nil, err
		}
	}
	numSamples := uint64(0)
	numChunks := uint64(0)
	for i, s := range sorted {
		if i > 0 && labels.Compare(sorted[i-1].Labels, s.Labels) == 0 {
			continue
		}
		if err = iw.AddSeries(storage.SeriesRef(i+1), s.Labels, allMetas[i]...); err != nil {
			return "", "", nil, err
		}
		for _, ch := range s.Chunks {
			numSamples += uint64(len(ch))
		}
		numChunks += uint64(len(allMetas[i]))
	}
	if err = iw.Close(); err != nil {
		return "", "", nil, err
	}

	// 3. `meta.json`, last. `maxTime` is EXCLUSIVE in a block, so the range is [minT, maxT+1).
	meta := tsdb.BlockMeta{
		ULID:    ulid.MustParse("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
		MinTime: minT,
		MaxTime: maxT + 1,
		Stats: tsdb.BlockStats{
			NumSamples:      numSamples,
			NumFloatSamples: numSamples,
			NumSeries:       uint64(len(sorted)),
			NumChunks:       numChunks,
		},
		Compaction: tsdb.BlockMetaCompaction{Level: 1},
		Version:    1,
	}
	meta.Compaction.Sources = []ulid.ULID{meta.ULID}
	mb, err := json.MarshalIndent(&meta, "", "\t")
	if err != nil {
		return "", "", nil, err
	}
	if err = os.WriteFile(filepath.Join(dir, "meta.json"), mb, 0o666); err != nil {
		return "", "", nil, err
	}

	indexHex, err = hexOfBlockFile(filepath.Join(dir, "index"))
	if err != nil {
		return "", "", nil, err
	}
	metaHex, err = hexOfBlockFile(filepath.Join(dir, "meta.json"))
	if err != nil {
		return "", "", nil, err
	}
	names, err := os.ReadDir(filepath.Join(dir, "chunks"))
	if err != nil {
		return "", "", nil, err
	}
	sort.Slice(names, func(i, j int) bool { return names[i].Name() < names[j].Name() })
	for _, e := range names {
		h, herr := hexOfBlockFile(filepath.Join(dir, "chunks", e.Name()))
		if herr != nil {
			return "", "", nil, herr
		}
		segHexes = append(segHexes, h)
	}
	return indexHex, metaHex, segHexes, nil
}

// openOracleBlock is `writeOracleBlock` plus `tsdb.OpenBlock`, which is the point: everything the querier
// suites drive is real upstream code from here on.
func openOracleBlock(dir string, series []blockSeries2) (
	*tsdb.Block, string, string, []string, error,
) {
	ih, mh, sh, err := writeOracleBlock(dir, series)
	if err != nil {
		return nil, "", "", nil, err
	}
	b, err := tsdb.OpenBlock(nil, dir, chunkenc.NewPool(), tsdb.DefaultPostingsDecoderFactory)
	if err != nil {
		return nil, "", "", nil, fmt.Errorf("open block: %w", err)
	}
	return b, ih, mh, sh, nil
}
