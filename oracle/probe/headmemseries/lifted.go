// Package headmemseries is a LIFT of `memSeries`' in-order chunk state out of `package tsdb`, so the oracle
// can drive it. Everything here is unexported upstream and nothing on `Head`'s exported surface reaches it
// until `head_read.go` makes a Head queryable, so there is no entry point to generate fixtures from — the
// same situation `isolation.go` and `seriesHashmap` were in (HANDOFF §7f(a), §7f(b)).
//
// Those two were probed with throwaway packages. This one is COMMITTED, and that is the improvement worth
// carrying: `Scripts/verify-fixtures.sh` regenerates from it, so the probe is re-run on every upstream-pin
// bump instead of existing only in a session's scratch directory. A throwaway probe verifies the port once;
// a committed one keeps verifying it.
//
// # What makes the lift honest
//
// `memSeries`' chunk state depends on `chunkenc`, `chunks` and `storage` — all *exported* packages, imported
// here for real rather than stubbed. So the only thing the lift replaces is the `package tsdb` line. The
// bodies below are byte-for-byte upstream, from:
//
//	tsdb/head.go        — memSeries, memChunk, mmappedChunk, newMemSeries, minTime, maxTime,
//	                      truncateChunksBefore, cleanupAppendIDsBelow, collectHeadChunks, overlapsClosedInterval
//	tsdb/head_append.go — chunkOpts, appendable, append, appendPreprocessor, computeChunkEndTime,
//	                      cutNewHeadChunk, mmapChunks, handleChunkWriteError
//	tsdb/isolation.go   — txRing, newTxRing (memSeries.append calls txs.add)
//	tsdb/db.go          — rangeForTimestamp (appendPreprocessor and cutNewHeadChunk both call it)
//
// # The five deltas, each one a thing the port also does not have
//
//  1. `package tsdb` -> `package headmemseries`.
//  2. **Out-of-order is removed**: the `ooo *memSeriesOOOFields` field, `memSeriesOOOFields`, `oooHeadChunk`,
//     `insert`, `cutNewOOOHeadChunk` and `mmapCurrentOOOHeadChunk`, plus `truncateChunksBefore`'s OOO block
//     and its `minOOOMmapRef` parameter. `OutOfOrderTimeWindow` defaults to 0 (disabled) and the OOO head is
//     Phase 10; the port defers it identically, so a lift that kept it would pin code with no counterpart.
//     `appendable`'s `oooTimeWindow` parameter STAYS — it is what makes the OOO *decision* observable, and
//     the port has it too.
//  3. **The histogram append path is removed**: `appendHistogram`, `appendFloatHistogram` and
//     `histogramsAppendPreprocessor`. §7f defers histograms in the appender. The two `last*HistogramValue`
//     FIELDS stay, because `append` nils them and `appendable` branches on them — see `ForceLastHistogram`
//     in drive.go for how the driver reaches that branch without the deferred setter.
//  4. **`sync.Mutex` and the `meta *metadata.Metadata` field are dropped.** The mutex has no counterpart
//     (the port has no concurrency yet, see Isolation.swift) and `meta` is written only by
//     `headAppender.UpdateMetadata`, which is not in this slice.
//  5. `s.shardHash` stays a field but nothing reads it here; sharding is `EnableSharding`, a declared §7f
//     omission. It is kept because `newMemSeries` takes it and the port's initialiser mirrors that.
//
// Anything else that differs from upstream is a BUG in this file, not a decision.
package headmemseries

import (
	"errors"
	"math"
	"slices"
	stdatomic "sync/atomic"

	"github.com/prometheus/prometheus/model/histogram"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
	"github.com/prometheus/prometheus/tsdb/chunks"
)

// ---------------------------------------------------------------------------
// tsdb/db.go
// ---------------------------------------------------------------------------

// rangeForTimestamp returns the first timestamp of the window AFTER the one t falls in — an exclusive upper
// bound, which is why `nextAt` compares with `>=`.
func rangeForTimestamp(t, width int64) (maxt int64) {
	return (t/width)*width + width
}

// ---------------------------------------------------------------------------
// tsdb/isolation.go — txRing, because memSeries.append calls txs.add
// ---------------------------------------------------------------------------

type txRing struct {
	txIDs     []uint64
	txIDFirst uint32 // Position of the first id in the ring.
	txIDCount uint32 // How many ids in the ring.
}

func newTxRing(capacity int) *txRing {
	return &txRing{
		txIDs: make([]uint64, capacity),
	}
}

func (txr *txRing) add(appendID uint64) {
	if int(txr.txIDCount) == len(txr.txIDs) {
		// Ring buffer is full, expand by doubling.
		newLen := txr.txIDCount * 2
		if newLen == 0 {
			newLen = 4
		}
		newRing := make([]uint64, newLen)
		idx := copy(newRing, txr.txIDs[txr.txIDFirst:])
		copy(newRing[idx:], txr.txIDs[:txr.txIDFirst])
		txr.txIDs = newRing
		txr.txIDFirst = 0
	}

	txr.txIDs[int(txr.txIDFirst+txr.txIDCount)%len(txr.txIDs)] = appendID
	txr.txIDCount++
}

func (txr *txRing) cleanupAppendIDsBelow(bound uint64) {
	if len(txr.txIDs) == 0 {
		return
	}
	pos := int(txr.txIDFirst)

	for txr.txIDCount > 0 {
		if txr.txIDs[pos] >= bound {
			break
		}
		txr.txIDFirst++
		txr.txIDCount--

		pos++
		if pos == len(txr.txIDs) {
			pos = 0
		}
	}

	txr.txIDFirst %= uint32(len(txr.txIDs))
}

func (txr *txRing) iterator() *txRingIterator {
	return &txRingIterator{
		pos: txr.txIDFirst,
		ids: txr.txIDs,
	}
}

// txRingIterator lets you iterate over the ring. It doesn't terminate,
// it DOESN'T terminate.
type txRingIterator struct {
	ids []uint64

	pos uint32
}

func (it *txRingIterator) At() uint64 {
	return it.ids[it.pos]
}

func (it *txRingIterator) Next() {
	it.pos++
	if int(it.pos) == len(it.ids) {
		it.pos = 0
	}
}

// ---------------------------------------------------------------------------
// tsdb/head.go — memSeries and the two chunk descriptors
// ---------------------------------------------------------------------------

// memSeries is the in-memory representation of a series. None of its methods
// are goroutine safe and it is the caller's responsibility to lock it.
type memSeries struct {
	ref chunks.HeadSeriesRef

	// Series labels hash to use for sharding purposes. The value is always 0 when sharding has not
	// been explicitly enabled in TSDB.
	shardHash uint64

	// Immutable chunks on disk that have not yet gone into a block, in order of ascending time stamps.
	// When compaction runs, chunks get moved into a block and all pointers are shifted like so:
	//
	//                                    /------- let's say these 2 chunks get stored into a block
	//                                    |  |
	// before compaction: mmappedChunks=[p5,p6,p7,p8,p9] firstChunkID=5
	//  after compaction: mmappedChunks=[p7,p8,p9]       firstChunkID=7
	//
	// pN is the pointer to the mmappedChunk referred to by HeadChunkID=N
	mmappedChunks []*mmappedChunk
	// Most recent chunks in memory that are still being built or waiting to be mmapped.
	// This is a linked list, headChunks points to the most recent chunk, headChunks.prev points
	// to older chunk and so on.
	// Please note the headChunkCount field tracking the number of headChunks.
	headChunks   *memChunk
	firstChunkID chunks.HeadChunkID // HeadChunkID for mmappedChunks[0]

	mmMaxTime int64 // Max time of any mmapped chunk, only used during WAL replay.

	nextAt                           int64 // Timestamp at which to cut the next chunk.
	histogramChunkHasComputedEndTime bool  // True if nextAt has been predicted for the current histograms chunk; false otherwise.
	pendingCommit                    bool  // Whether there are samples waiting to be committed to this series.
	// headChunkCount tracks the number of head chunks.
	headChunkCount stdatomic.Uint32

	// We keep the last value here (in addition to appending it to the chunk) so we can check for duplicates.
	lastValue float64

	// We keep the last histogram value here (in addition to appending it to the chunk) so we can check for duplicates.
	lastHistogramValue      *histogram.Histogram
	lastFloatHistogramValue *histogram.FloatHistogram

	// Current appender for the head chunk. Set when a new head chunk is cut.
	app chunkenc.Appender

	// txs is nil if isolation is disabled.
	txs *txRing
}

func newMemSeries(id chunks.HeadSeriesRef, shardHash uint64, isolationDisabled, pendingCommit bool) *memSeries {
	s := &memSeries{
		ref:           id,
		nextAt:        math.MinInt64,
		shardHash:     shardHash,
		pendingCommit: pendingCommit,
	}
	if !isolationDisabled {
		s.txs = newTxRing(0)
	}
	return s
}

func (s *memSeries) minTime() int64 {
	if len(s.mmappedChunks) > 0 {
		return s.mmappedChunks[0].minTime
	}
	if s.headChunks != nil {
		return s.headChunks.oldest().minTime
	}
	return math.MinInt64
}

func (s *memSeries) maxTime() int64 {
	// The highest timestamps will always be in the regular (non-OOO) chunks, even if OOO is enabled.
	if s.headChunks != nil {
		return s.headChunks.maxTime
	}
	if len(s.mmappedChunks) > 0 {
		return s.mmappedChunks[len(s.mmappedChunks)-1].maxTime
	}
	return math.MinInt64
}

// truncateChunksBefore removes all chunks from the series that
// have no timestamp at or after mint.
// Chunk IDs remain unchanged.
func (s *memSeries) truncateChunksBefore(mint int64) int {
	var removedInOrder int
	if s.headChunks != nil {
		var i uint32
		var nextChk *memChunk
		chk := s.headChunks
		for chk != nil {
			if chk.maxTime < mint {
				// If any head chunk is truncated, we can truncate all mmapped chunks.
				removedInOrder = chk.len() + len(s.mmappedChunks)
				s.firstChunkID += chunks.HeadChunkID(removedInOrder)
				if i == 0 {
					// This is the first chunk on the list so we need to remove the entire list.
					s.headChunks = nil
					s.headChunkCount.Store(0)
				} else {
					// This is NOT the first chunk, unlink it from parent.
					nextChk.prev = nil
					s.headChunkCount.Store(i)
				}
				s.mmappedChunks = nil
				break
			}
			nextChk = chk
			chk = chk.prev
			i++
		}
	}
	if len(s.mmappedChunks) > 0 {
		for i, c := range s.mmappedChunks {
			if c.maxTime >= mint {
				break
			}
			removedInOrder = i + 1
		}
		s.mmappedChunks = append(s.mmappedChunks[:0], s.mmappedChunks[removedInOrder:]...)
		s.firstChunkID += chunks.HeadChunkID(removedInOrder)
	}

	return removedInOrder
}

// cleanupAppendIDsBelow cleans up older appendIDs. Has to be called after
// acquiring lock.
func (s *memSeries) cleanupAppendIDsBelow(bound uint64) {
	if s.txs != nil {
		s.txs.cleanupAppendIDsBelow(bound)
	}
}

type memChunk struct {
	chunk            chunkenc.Chunk
	minTime, maxTime int64
	prev             *memChunk // Link to the previous element on the list.
}

// len returns the length of memChunk list, including the element it was called on.
func (mc *memChunk) len() (count int) {
	if mc.prev == nil {
		return 1
	}

	elem := mc
	for elem != nil {
		count++
		elem = elem.prev
	}
	return count
}

func collectHeadChunks(head *memChunk, buf []*memChunk) []*memChunk {
	if head == nil {
		return buf
	}
	// Single walk: append newest-to-oldest (following prev pointers), then
	// reverse to oldest-to-newest. Pointer-chasing the linked list is the
	// expensive part; slices.Reverse on a contiguous array is essentially
	// free by comparison.
	hc := buf
	for elem := head; elem != nil; elem = elem.prev {
		hc = append(hc, elem)
	}
	slices.Reverse(hc)
	return hc
}

// oldest returns the oldest element on the list.
// For single element list this will be the same memChunk oldest() was called on.
func (mc *memChunk) oldest() (elem *memChunk) {
	if mc.prev == nil {
		return mc
	}
	elem = mc
	for elem.prev != nil {
		elem = elem.prev
	}
	return elem
}

// atOffset returns a memChunk that's Nth element on the linked list.
func (mc *memChunk) atOffset(offset int) (elem *memChunk) {
	if offset == 0 {
		return mc
	}
	if offset == 1 {
		return mc.prev
	}
	if offset < 0 {
		return nil
	}

	var i int
	elem = mc
	for i < offset {
		i++
		elem = elem.prev
		if elem == nil {
			break
		}
	}
	return elem
}

// OverlapsClosedInterval returns true if the chunk overlaps [mint, maxt].
func (mc *memChunk) OverlapsClosedInterval(mint, maxt int64) bool {
	return overlapsClosedInterval(mc.minTime, mc.maxTime, mint, maxt)
}

func overlapsClosedInterval(mint1, maxt1, mint2, maxt2 int64) bool {
	return mint1 <= maxt2 && mint2 <= maxt1
}

// mmappedChunk describes a head chunk on disk that has been mmapped.
type mmappedChunk struct {
	ref              chunks.ChunkDiskMapperRef
	numSamples       uint16
	minTime, maxTime int64
}

// Returns true if the chunk overlaps [mint, maxt].
func (mc *mmappedChunk) OverlapsClosedInterval(mint, maxt int64) bool {
	return overlapsClosedInterval(mc.minTime, mc.maxTime, mint, maxt)
}

// ---------------------------------------------------------------------------
// tsdb/head_append.go — the append path
// ---------------------------------------------------------------------------

// appendable checks whether the given sample is valid for appending to the series.
// If the sample is valid and in-order, it returns false with no error.
// If the sample belongs to the out-of-order chunk, it returns true with no error.
// If the sample cannot be handled, it returns an error.
func (s *memSeries) appendable(t int64, v float64, headMaxt, minValidTime, oooTimeWindow int64) (isOOO bool, oooDelta int64, err error) {
	// Check if we can append in the in-order chunk.
	if t >= minValidTime {
		if s.headChunks == nil {
			// The series has no sample and was freshly created.
			return false, 0, nil
		}
		msMaxt := s.maxTime()
		if t > msMaxt {
			return false, 0, nil
		}
		if t == msMaxt {
			// We are allowing exact duplicates as we can encounter them in valid cases
			// like federation and erroring out at that time would be extremely noisy.
			// This only checks against the latest in-order sample.
			// The OOO headchunk has its own method to detect these duplicates.
			if s.lastHistogramValue != nil || s.lastFloatHistogramValue != nil {
				return false, 0, storage.NewDuplicateHistogramToFloatErr(t, v)
			}
			if math.Float64bits(s.lastValue) != math.Float64bits(v) {
				return false, 0, storage.NewDuplicateFloatErr(t, s.lastValue, v)
			}
			// Sample is identical (ts + value) with most current (highest ts) sample in sampleBuf.
			return false, 0, nil
		}
	}

	// The sample cannot go in the in-order chunk. Check if it can go in the out-of-order chunk.
	if oooTimeWindow > 0 && t >= headMaxt-oooTimeWindow {
		return true, headMaxt - t, nil
	}

	// The sample cannot go in both in-order and out-of-order chunk.
	if oooTimeWindow > 0 {
		return true, headMaxt - t, storage.ErrTooOldSample
	}
	if t < minValidTime {
		return false, headMaxt - t, storage.ErrOutOfBounds
	}
	return false, headMaxt - t, storage.ErrOutOfOrderSample
}

// chunkOpts are chunk-level options that are passed when appending to a memSeries.
type chunkOpts struct {
	chunkDiskMapper *chunks.ChunkDiskMapper
	chunkRange      int64
	samplesPerChunk int
	useXOR2         bool // Selects XOR2 encoding for float chunks.
	storeST         bool // Whether start-timestamp storage is enabled.
}

// append adds the sample (t, v) to the series. The caller also has to provide
// the appendID for isolation. (The appendID can be zero, which results in no
// isolation for this append.)
// Series lock must be held when calling.
func (s *memSeries) append(st, t int64, v float64, appendID uint64, o chunkOpts) (sampleInOrder, chunkCreated bool) {
	c, sampleInOrder, chunkCreated := s.appendPreprocessor(t, chunkenc.ValFloat.ChunkEncoding(o.useXOR2), o)
	if !sampleInOrder {
		return sampleInOrder, chunkCreated
	}
	s.app.Append(st, t, v)

	c.maxTime = t

	s.lastValue = v
	s.lastHistogramValue = nil
	s.lastFloatHistogramValue = nil

	if appendID > 0 {
		s.txs.add(appendID)
	}

	return true, chunkCreated
}

// appendPreprocessor takes care of cutting new XOR chunks and m-mapping old ones. XOR chunks are cut based on
// the number of samples they contain.
func (s *memSeries) appendPreprocessor(t int64, e chunkenc.Encoding, o chunkOpts) (c *memChunk, sampleInOrder, chunkCreated bool) {
	c = s.headChunks

	if c == nil {
		if len(s.mmappedChunks) > 0 && s.mmappedChunks[len(s.mmappedChunks)-1].maxTime >= t {
			// Out of order sample. Sample timestamp is already in the mmapped chunks, so ignore it.
			return c, false, false
		}
		// There is no head chunk in this series yet, create the first chunk for the sample.
		c = s.cutNewHeadChunk(t, e, o.chunkRange)
		chunkCreated = true
	}

	// Out of order sample.
	if c.maxTime >= t {
		return c, false, chunkCreated
	}

	// Check the chunk size, unless we just created it and if the chunk is too large, cut a new one.
	if !chunkCreated && len(c.chunk.Bytes()) > chunkenc.MaxBytesPerXORChunkBeforeAppend {
		c = s.cutNewHeadChunk(t, e, o.chunkRange)
		chunkCreated = true
	}

	// XOR and XOR2 are compatible float encodings when ST storage is disabled:
	// switching between them does not require cutting the current chunk. When ST
	// storage is enabled the two encodings differ in their start-timestamp support
	// and must not be mixed within a single chunk; the o.storeST override forces
	// an immediate cut that CompatibleValues would otherwise allow to skip.
	if c.chunk.Encoding() != e && (!chunkenc.CompatibleValues(c.chunk.Encoding(), e) || o.storeST) {
		c = s.cutNewHeadChunk(t, e, o.chunkRange)
		chunkCreated = true
	}

	numSamples := c.chunk.NumSamples()
	if numSamples == 0 {
		// It could be the new chunk created after reading the chunk snapshot,
		// hence we fix the minTime of the chunk here.
		c.minTime = t
		s.nextAt = rangeForTimestamp(c.minTime, o.chunkRange)
	}

	// If we reach 25% of a chunk's desired sample count, predict an end time
	// for this chunk that will try to make samples equally distributed within
	// the remaining chunks in the current chunk range.
	// At latest it must happen at the timestamp set when the chunk was cut.
	if numSamples == o.samplesPerChunk/4 {
		s.nextAt = computeChunkEndTime(c.minTime, c.maxTime, s.nextAt, 4)
	}
	// If numSamples > samplesPerChunk*2 then our previous prediction was invalid,
	// most likely because samples rate has changed and now they are arriving more frequently.
	// Since we assume that the rate is higher, we're being conservative and cutting at 2*samplesPerChunk
	// as we expect more chunks to come.
	// Note that next chunk will have its nextAt recalculated for the new rate.
	if t >= s.nextAt || numSamples >= o.samplesPerChunk*2 {
		c = s.cutNewHeadChunk(t, e, o.chunkRange)
		chunkCreated = true
	}

	return c, true, chunkCreated
}

// computeChunkEndTime estimates the end timestamp based the beginning of a
// chunk, its current timestamp and the upper bound up to which we insert data.
// It assumes that the time range is 1/ratioToFull full.
// Assuming that the samples will keep arriving at the same rate, it will make the
// remaining n chunks within this chunk range (before max) equally sized.
func computeChunkEndTime(start, cur, maxT int64, ratioToFull float64) int64 {
	n := float64(maxT-start) / (float64(cur-start+1) * ratioToFull)
	if n <= 1 {
		return maxT
	}
	return int64(float64(start) + float64(maxT-start)/math.Floor(n))
}

func (s *memSeries) cutNewHeadChunk(mint int64, e chunkenc.Encoding, chunkRange int64) *memChunk {
	// When cutting a new head chunk we create a new memChunk instance with .prev
	// pointing at the current .headChunks, so it forms a linked list.
	// All but first headChunks list elements will be m-mapped as soon as possible
	// so this is a single element list most of the time.
	s.headChunks = &memChunk{
		minTime: mint,
		maxTime: math.MinInt64,
		prev:    s.headChunks,
	}
	s.headChunkCount.Add(1)

	if chunkenc.IsValidEncoding(e) {
		var err error
		s.headChunks.chunk, err = chunkenc.NewEmptyChunk(e)
		if err != nil {
			panic(err) // This should never happen.
		}
	} else {
		s.headChunks.chunk = chunkenc.NewXORChunk()
	}

	// Set upper bound on when the next chunk must be started. An earlier timestamp
	// may be chosen dynamically at a later point.
	s.nextAt = rangeForTimestamp(mint, chunkRange)

	app, err := s.headChunks.chunk.Appender()
	if err != nil {
		panic(err)
	}
	s.app = app
	return s.headChunks
}

// mmapChunks will m-map all but first chunk on s.headChunks list and update headChunkCount.
func (s *memSeries) mmapChunks(chunkDiskMapper *chunks.ChunkDiskMapper) (count int) {
	if s.headChunks == nil || s.headChunks.prev == nil {
		// There is none or only one head chunk, so nothing to m-map here.
		return count
	}

	// Write chunks starting from the oldest one and stop before we get to current s.headChunks.
	// If we have this chain: s.headChunks{t4} -> t3 -> t2 -> t1 -> t0
	// then we need to write chunks t0 to t3, but skip s.headChunks.
	for i := s.headChunks.len() - 1; i > 0; i-- {
		chk := s.headChunks.atOffset(i)
		chunkRef := chunkDiskMapper.WriteChunk(s.ref, chk.minTime, chk.maxTime, chk.chunk, false, handleChunkWriteError)
		s.mmappedChunks = append(s.mmappedChunks, &mmappedChunk{
			ref:        chunkRef,
			numSamples: uint16(chk.chunk.NumSamples()),
			minTime:    chk.minTime,
			maxTime:    chk.maxTime,
		})
		count++
	}

	// Remove the tail of the list, leaving only the most recent head chunk.
	s.headChunks.prev = nil
	s.headChunkCount.Store(1)

	return count
}

func handleChunkWriteError(err error) {
	if err != nil && !errors.Is(err, chunks.ErrChunkDiskMapperClosed) {
		panic(err)
	}
}
