package headmemseries

// The driver over the lift: one JSON case is a PROGRAM of operations against a single `memSeries`, and the
// output records what each operation answered plus the whole visible state afterwards.
//
// A program rather than a call list because every interesting behaviour in `appendPreprocessor` is a function
// of history: the chunk-cut decisions depend on `nextAt` (set two cuts ago), on the byte length of the chunk
// so far, and on how many samples are in it. A per-call corpus cannot express "the 30th sample of a chunk
// that was cut at t=0".
//
// The state snapshot is deliberately wide — chunk BYTES included. The bytes are what makes this differential
// rather than structural: the port could get every count right and still encode the samples differently, and
// a snapshot of `minTime`/`maxTime`/`numSamples` alone would not notice.

import (
	"encoding/hex"
	"fmt"
	"math"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

// FBits is the corpus convention for a float: its 64-bit pattern in hex, so NaN, -0 and the stale NaN travel
// exactly. `appendable` compares `math.Float64bits`, so -0 and 0 are DIFFERENT to it — a corpus that shipped
// floats as JSON numbers would silently lose that case to `omitempty`.
func FBits(f float64) string { return fmt.Sprintf("%016x", math.Float64bits(f)) }

func fromFBits(s string) float64 {
	var u uint64
	if _, err := fmt.Sscanf(s, "%016x", &u); err != nil {
		panic("bad float bits " + s)
	}
	return math.Float64frombits(u)
}

type Op struct {
	// append | appendable | mmapChunks | truncateChunksBefore | cleanupAppendIDsBelow | atOffset |
	// overlapsHead | forceLastHistogram | forceLastFloatHistogram | snapshot
	Op string `json:"op"`

	// `append`: the sample, and the isolation append ID (0 disables isolation for this append).
	ST       int64  `json:"st,omitempty"`
	T        int64  `json:"t,omitempty"`
	V        string `json:"v,omitempty"`
	AppendID uint64 `json:"appendID,omitempty"`

	// `appendable`: the Head-level context it is asked about.
	HeadMaxt      int64 `json:"headMaxt,omitempty"`
	MinValidTime  int64 `json:"minValidTime,omitempty"`
	OOOTimeWindow int64 `json:"oooTimeWindow,omitempty"`

	// `truncateChunksBefore`, and the interval for `overlapsHead`.
	Mint int64 `json:"mint,omitempty"`
	Maxt int64 `json:"maxt,omitempty"`

	// `cleanupAppendIDsBelow`.
	Bound uint64 `json:"bound,omitempty"`

	// `atOffset` — negative and past-the-end offsets are the point of it.
	Offset int `json:"offset,omitempty"`

	// `setOpts` — a mid-program change of the two float-encoding options. NOT an affordance: `chunkOpts` is
	// rebuilt per appender from `HeadOptions`, so a config change between appends is exactly how upstream
	// reaches `appendPreprocessor`'s encoding-mismatch branch.
	UseXOR2 *bool `json:"useXOR2,omitempty"`
	StoreST *bool `json:"storeST,omitempty"`

	// `seedMmapped` — install mmapped-chunk descriptors directly, with no head chunk. That is not a hack
	// either: it is what `head_wal.go`'s `loadMmappedChunks` does on replay (`mSeries.mmappedChunks = mmc`),
	// and it is the ONLY way to reach the state `minTime`, `maxTime` and `appendPreprocessor` all branch on —
	// mmapped chunks present while `headChunks` is nil. Nothing in this slice's own API can produce it,
	// because `truncateChunksBefore` clears the mmapped array whenever it drops a head chunk.
	Mmapped []MmappedState `json:"mmapped,omitempty"`
}

type In struct {
	// `chunkOpts`.
	ChunkRange      int64 `json:"chunkRange"`
	SamplesPerChunk int   `json:"samplesPerChunk"`
	UseXOR2         bool  `json:"useXOR2,omitempty"`
	StoreST         bool  `json:"storeST,omitempty"`

	// `newMemSeries`.
	Ref               uint64 `json:"ref"`
	ShardHash         uint64 `json:"shardHash,omitempty"`
	IsolationDisabled bool   `json:"isolationDisabled,omitempty"`
	PendingCommit     bool   `json:"pendingCommit,omitempty"`

	Ops []Op `json:"ops"`
}

type ChunkState struct {
	MinTime    int64  `json:"minTime"`
	MaxTime    int64  `json:"maxTime"`
	Encoding   uint8  `json:"encoding"`
	NumSamples int    `json:"numSamples"`
	Bytes      string `json:"bytes"`
}

type MmappedState struct {
	Ref        uint64 `json:"ref"`
	NumSamples uint16 `json:"numSamples"`
	MinTime    int64  `json:"minTime"`
	MaxTime    int64  `json:"maxTime"`
}

type State struct {
	MinTime      int64  `json:"minTime"`
	MaxTime      int64  `json:"maxTime"`
	NextAt       int64  `json:"nextAt"`
	HeadCount    uint32 `json:"headCount"`
	FirstChunkID uint64 `json:"firstChunkID"`
	LastValue    string `json:"lastValue"`
	// `append` nils both on every float sample; `appendable`'s duplicate-histogram branch reads them.
	HasLastHistogram      bool `json:"hasLastHistogram,omitempty"`
	HasLastFloatHistogram bool `json:"hasLastFloatHistogram,omitempty"`
	// True once a head chunk exists, since `cutNewHeadChunk` is the only thing that sets the appender.
	HasApp bool `json:"hasApp"`
	// OLDEST first, through `collectHeadChunks` — the reverse of the `prev` chain, and the order the
	// linked list is not stored in.
	HeadChunks    []ChunkState   `json:"headChunks"`
	MmappedChunks []MmappedState `json:"mmappedChunks"`
	// The isolation ring's live contents, bounded by `txIDCount` because the iterator never terminates.
	TxIDs []uint64 `json:"txIDs"`
	// nil when isolation is disabled, which is a different thing from an empty ring.
	HasTxRing bool `json:"hasTxRing"`
}

type OpOut struct {
	// `append` / `appendPreprocessor`.
	SampleInOrder bool `json:"sampleInOrder,omitempty"`
	ChunkCreated  bool `json:"chunkCreated,omitempty"`
	// `appendable`.
	IsOOO    bool   `json:"isOOO,omitempty"`
	OOODelta int64  `json:"oooDelta,omitempty"`
	Err      string `json:"err,omitempty"`
	// `mmapChunks` / `truncateChunksBefore`.
	Count int `json:"count,omitempty"`
	// `atOffset`: nil when the offset walks off the list. `overlapsHead`: the boolean.
	Found    bool  `json:"found,omitempty"`
	MinTime  int64 `json:"minTime,omitempty"`
	Overlaps bool  `json:"overlaps,omitempty"`
}

// FileState is one chunk file the program produced. The bytes are RLE-hex, because a head chunk file carries
// a 128 KiB pre-allocated tail of zeros (quirk 182) and committing that verbatim would be absurd.
type FileState struct {
	Name  string `json:"name"`
	Size  int    `json:"size"`
	Bytes string `json:"bytes"`
}

type Out struct {
	// One entry per op that ANSWERS something. `snapshot` and `setOpts` produce none, so this is generally
	// shorter than `in.Ops` and the two are not index-aligned.
	Ops []OpOut `json:"ops"`
	// One entry per `snapshot` op, then the final state as the last entry — so a case that wants only the
	// end state does not have to ask for it.
	States []State `json:"states"`
	// The chunk files, after the mapper is closed. Filled in by the CALLER, which owns the directory. Without
	// them `mmapChunks`' `mint`/`maxt` arguments are unobservable: the `mmappedChunk` record carries its own
	// copies, so swapping the two in the `WriteChunk` call changes only the file.
	Files []FileState `json:"files"`
}

func snapshot(s *memSeries) State {
	st := State{
		MinTime:               s.minTime(),
		MaxTime:               s.maxTime(),
		NextAt:                s.nextAt,
		HeadCount:             s.headChunkCount.Load(),
		FirstChunkID:          uint64(s.firstChunkID),
		LastValue:             FBits(s.lastValue),
		HasLastHistogram:      s.lastHistogramValue != nil,
		HasLastFloatHistogram: s.lastFloatHistogramValue != nil,
		HasApp:                s.app != nil,
		HeadChunks:            []ChunkState{},
		MmappedChunks:         []MmappedState{},
		TxIDs:                 []uint64{},
		HasTxRing:             s.txs != nil,
	}
	for _, c := range collectHeadChunks(s.headChunks, nil) {
		st.HeadChunks = append(st.HeadChunks, ChunkState{
			MinTime:    c.minTime,
			MaxTime:    c.maxTime,
			Encoding:   uint8(c.chunk.Encoding()),
			NumSamples: c.chunk.NumSamples(),
			Bytes:      hex.EncodeToString(c.chunk.Bytes()),
		})
	}
	for _, c := range s.mmappedChunks {
		st.MmappedChunks = append(st.MmappedChunks, MmappedState{
			Ref:        uint64(c.ref),
			NumSamples: c.numSamples,
			MinTime:    c.minTime,
			MaxTime:    c.maxTime,
		})
	}
	if s.txs != nil {
		it := s.txs.iterator()
		for i := uint32(0); i < s.txs.txIDCount; i++ {
			st.TxIDs = append(st.TxIDs, it.At())
			it.Next()
		}
	}
	return st
}

// Drive runs one case. `cdm` may be nil when no `mmapChunks` op appears.
func Drive(in In, cdm *chunks.ChunkDiskMapper) Out {
	s := newMemSeries(chunks.HeadSeriesRef(in.Ref), in.ShardHash, in.IsolationDisabled, in.PendingCommit)
	o := chunkOpts{
		chunkDiskMapper: cdm,
		chunkRange:      in.ChunkRange,
		samplesPerChunk: in.SamplesPerChunk,
		useXOR2:         in.UseXOR2,
		storeST:         in.StoreST,
	}

	out := Out{Ops: []OpOut{}, States: []State{}, Files: []FileState{}}
	for _, op := range in.Ops {
		var r OpOut
		switch op.Op {
		case "append":
			r.SampleInOrder, r.ChunkCreated = s.append(op.ST, op.T, fromFBits(op.V), op.AppendID, o)
		case "appendable":
			isOOO, delta, err := s.appendable(op.T, fromFBits(op.V), op.HeadMaxt, op.MinValidTime, op.OOOTimeWindow)
			r.IsOOO, r.OOODelta = isOOO, delta
			if err != nil {
				r.Err = err.Error()
			}
		case "mmapChunks":
			r.Count = s.mmapChunks(cdm)
		case "truncateChunksBefore":
			r.Count = s.truncateChunksBefore(op.Mint)
		case "cleanupAppendIDsBelow":
			s.cleanupAppendIDsBelow(op.Bound)
		case "atOffset":
			if s.headChunks == nil {
				break
			}
			if c := s.headChunks.atOffset(op.Offset); c != nil {
				r.Found, r.MinTime = true, c.minTime
			}
		case "overlapsHead":
			if s.headChunks != nil {
				r.Overlaps = s.headChunks.OverlapsClosedInterval(op.Mint, op.Maxt)
			}
		case "forceLastHistogram":
			// A PROBE AFFORDANCE, not upstream behaviour: the only thing that sets this field is
			// `appendHistogram`, which §7f defers. Without it `appendable`'s
			// `NewDuplicateHistogramToFloatErr` arm is unreachable and would go unpinned.
			s.lastHistogramValue = &histogram.Histogram{}
		case "forceLastFloatHistogram":
			s.lastFloatHistogramValue = &histogram.FloatHistogram{}
		case "snapshot":
			out.States = append(out.States, snapshot(s))
			continue
		case "seedMmapped":
			for _, m := range op.Mmapped {
				s.mmappedChunks = append(s.mmappedChunks, &mmappedChunk{
					ref:        chunks.ChunkDiskMapperRef(m.Ref),
					numSamples: m.NumSamples,
					minTime:    m.MinTime,
					maxTime:    m.MaxTime,
				})
			}
			continue
		case "setOpts":
			if op.UseXOR2 != nil {
				o.useXOR2 = *op.UseXOR2
			}
			if op.StoreST != nil {
				o.storeST = *op.StoreST
			}
			continue
		default:
			panic("unknown memseries op " + op.Op)
		}
		out.Ops = append(out.Ops, r)
	}
	out.States = append(out.States, snapshot(s))
	return out
}
