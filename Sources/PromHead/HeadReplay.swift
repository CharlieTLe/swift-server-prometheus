//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go and tsdb/head_wal.go @ v3.13.2 — `Head.Init`, `loadMmappedChunks`,
// `removeCorruptedMmappedChunks`, `loadWAL`, `resetSeriesWithMMappedChunks` and `appendChunkAndMmap`.
//
// **This is the slice that makes a restart possible.** §7f wrote the WAL and the chunk files; this reads them
// back, and the contract §7f's HANDOFF entry named is now testable: *a Head built by replaying a WAL must equal
// a Head built by appending the same samples.*
//
// ## `Init`'s two phases, and why the m-mapped one comes first
//
//  1. **The chunk files** (`loadMmappedChunks`). Every chunk `ChunkDiskMapper` holds is catalogued into a
//     `[HeadSeriesRef: [MmappedChunk]]` map — WITHOUT creating series, because the labels are in the WAL, not
//     in the chunk files. A chunk whose `maxTime` is below `minValidTime` is skipped, and so is one with an
//     encoding this build does not know.
//  2. **The WAL** (`loadWAL`, once per segment). Series records create the series and then take their mmapped
//     chunks from that map; sample records append. Which is why the order matters: a sample record must find a
//     series that already knows how far its on-disk chunks reach, or it would re-append samples that are
//     already in a chunk file.
//
// `mmMaxTime` is what carries that across: `resetSeriesWithMMappedChunks` sets it to the last mmapped chunk's
// `maxTime`, and `loadWAL` skips every sample at or below it. **That skip is the whole reason replay is not
// quadratic**, and it is also why a WAL replayed twice does not double-count.
//
// ## Duplicate series records, and `multiRef`
//
// A WAL can name the same label set under two refs — compaction and a truncated checkpoint both do it. The
// second record's `getOrCreateWithOptionalID` finds the existing series, so `created` is false, and the replay
// records `multiRef[walRef] = existingRef`. Every later record for the old ref is REMAPPED. Losing that map
// silently splits one series into two.
//
// ## What is deliberately absent, and where each one goes
//
//   * **The concurrency.** Upstream shards series by `ref % WALReplayConcurrency` across `walSubsetProcessor`
//     workers and streams decoded records through a channel. The port replays serially: `defaultWALReplayConcurrency`
//     is 1 (exception 24) and the sharding is an optimisation whose only observable effect would be the ORDER
//     samples reach a series — which upstream makes irrelevant by sharding on the ref, so every sample of a
//     series lands on one worker in record order. Serial replay is that same order.
//   * **The chunk snapshot** (`EnableMemorySnapshotOnShutdown`, `loadChunkSnapshot`, `LastChunkSnapshot`) — a
//     declared §7f omission, and it is what `snapIdx`/`snapOffset` exist for.
//   * **The chunk snapshot's** `snapIdx`/`snapOffset` interaction with the checkpoint backfill: upstream only
//     replays the checkpoint when `startFrom >= snapIdx`, because a snapshot newer than the checkpoint already
//     contains it. With no snapshot, `snapIdx` is -1 and the condition always holds.
//   * **The WBL** (`loadWBL`, `errLoadWbl`) and everything OOO — Phase 10.
//   * **Histograms, exemplars and metadata records.** `loadWAL` decodes them upstream; here the record types
//     are recognised and SKIPPED, exactly as upstream skips a type it does not know — but the skip is a
//     declared gap rather than a silent default, so the unknown-ref accounting still counts them.
//   * **`EnableFastStartup`** and the series-state file.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromChunks
public import PromFS
public import PromLabels
public import PromModel
public import PromRecord
public import PromStorage
public import PromTombstones
public import PromWAL

/// Go: `head_wal.go`'s replay errors, and `Init`'s wraps.
public enum HeadReplayError: Error, CustomStringConvertible {
    /// Go: `fmt.Errorf("iterate on-disk chunks: %w", err)`.
    case iterateOnDiskChunks(any Error)
    /// Go: `fmt.Errorf("out of sequence m-mapped chunk for series ref %d, last chunk: [%d, %d], new: [%d, %d]")`.
    case outOfSequenceMmappedChunk(
        seriesRef: UInt64, lastMinTime: Int64, lastMaxTime: Int64, mint: Int64, maxt: Int64)
    /// Go: `fmt.Errorf("finding WAL segments: %w", e)`.
    case findingWALSegments(any Error)
    /// Go: `fmt.Errorf("find last checkpoint: %w", err)`.
    case findLastCheckpoint(any Error)
    /// Go: `fmt.Errorf("open checkpoint: %w", err)`.
    case openCheckpoint(any Error)
    /// Go: `fmt.Errorf("backfill checkpoint: %w", err)`.
    case backfillCheckpoint(any Error)
    /// Go: `fmt.Errorf("open WAL segment: %d: %w", i, err)`.
    case openWALSegment(Int, any Error)
    /// Go: `&wlog.CorruptionErr{Err: fmt.Errorf("decode %s: %w", …)}` — the port carries the record kind and the
    /// segment/offset the reader was at, which is what makes a corrupt WAL diagnosable.
    case decode(kind: String, segment: Int, offset: Int64, underlying: any Error)

    public var description: String {
        switch self {
        case .iterateOnDiskChunks(let e): return "iterate on-disk chunks: \(e)"
        case .outOfSequenceMmappedChunk(let ref, let lmin, let lmax, let mint, let maxt):
            return
                "out of sequence m-mapped chunk for series ref \(ref), last chunk: [\(lmin), \(lmax)], new: [\(mint), \(maxt)]"
        case .findingWALSegments(let e): return "finding WAL segments: \(e)"
        case .findLastCheckpoint(let e): return "find last checkpoint: \(e)"
        case .openCheckpoint(let e): return "open checkpoint: \(e)"
        case .backfillCheckpoint(let e): return "backfill checkpoint: \(e)"
        case .openWALSegment(let i, let e): return "open WAL segment: \(i): \(e)"
        case .decode(let kind, let segment, let offset, let e):
            return "decode \(kind): \(e) (segment \(segment), offset \(offset))"
        }
    }
}

extension Head {

    /// Go: `Head.Init` — "loads data from the write ahead log and prepares the head for writes".
    ///
    /// The three deferred actions upstream run in reverse order, and all three matter:
    ///
    ///  1. the `minTime` clamp — *"Loading of m-mapped chunks and snapshot can make the mint of the Head to go
    ///     below minValidTime"*, so a replay that found older data than the caller allows is pulled back up;
    ///  2. `gc()` — *"After loading the wal remove the obsolete data from the head"*, which is what drops the
    ///     series whose every chunk turned out to be below `minValidTime`;
    ///  3. `postings.EnsureOrder` — the postings were built UNORDERED (§7e ported `newUnordered` for exactly
    ///     this), because replay adds refs in segment order rather than sorted.
    ///
    /// A Head with no WAL returns after the m-mapped phase — and upstream skips even that when there is neither
    /// a WAL nor a snapshot, because *"m-map chunks will be discarded anyway"*.
    public func initialize(minValidTime: Int64) throws {
        minValidTimeValue = minValidTime

        defer {
            // (3) then (2) then (1): Swift runs `defer`s in reverse, like Go.
            postings.ensureOrder()
        }
        defer {
            gc()
        }
        defer {
            if minTime() < minValidTimeValue {
                minTimeValue = minValidTimeValue
            }
        }

        var mmappedChunks: [HeadSeriesRef: [MmappedChunk]] = [:]

        if wal != nil {
            // Only load the m-mapped chunks when they will not be discarded anyway.
            do {
                (mmappedChunks, _) = try loadMmappedChunks(refSeries: [:])
            } catch {
                // If this fails, data will be recovered from the WAL, so no data is lost as long as the WAL is
                // intact.
                mmappedChunks = try removeCorruptedMmappedChunks(error)
            }
        }

        guard let wal else {
            return  // "WAL not found"
        }

        // The last CHECKPOINT is backfilled FIRST, because it holds the records the live segments no longer do
        // — `truncateWAL` deletes a segment only after a checkpoint covers it. A missing checkpoint is not an
        // error (`ErrNotFound`); anything else is.
        var checkpointDirName: String?
        // `LastCheckpoint` returns index 0 alongside `ErrNotFound`, and upstream uses that zero: `startFrom` is
        // the CHECKPOINT's index, never the WAL directory's first segment.
        var startFrom = 0
        do {
            let (cpdir, idx) = try lastCheckpoint(fsStorage, wal.dir)
            checkpointDirName = cpdir
            startFrom = idx
        } catch let e as RecordError where e == .notFound {
            checkpointDirName = nil
        } catch {
            throw HeadReplayError.findLastCheckpoint(error)
        }

        // Only `endAt` is taken from `Segments`; upstream discards the first index (`_, endAt, e :=`). The
        // difference is visible on a WAL whose oldest segment is ABOVE the checkpoint's: replay then tries to
        // open the segment that is missing and fails, rather than silently starting at whatever is there.
        let endAt: Int
        do {
            (_, endAt) = try walSegments(fsStorage, wal.dir)
        } catch {
            throw HeadReplayError.findingWALSegments(error)
        }

        stats.walReplayStatus.min = startFrom
        stats.walReplayStatus.max = endAt
        stats.walReplayStatus.current = startFrom

        var multiRef: [HeadSeriesRef: HeadSeriesRef] = [:]

        if let cpdir = checkpointDirName {
            let sr: SegmentBufReader
            do {
                sr = try newWALSegmentsReader(fsStorage, cpdir)
            } catch {
                throw HeadReplayError.openCheckpoint(error)
            }
            // "A corrupted checkpoint is a hard error for now and requires user intervention. There's likely
            // little data that can be recovered anyway."
            do {
                try loadWAL(WALReader(sr), multiRef: &multiRef, mmappedChunks: mmappedChunks)
            } catch {
                try? sr.close()
                throw HeadReplayError.backfillCheckpoint(error)
            }
            try? sr.close()
            // The segments the checkpoint covers are not replayed again.
            startFrom += 1
        }

        if startFrom > endAt {
            // Nothing left to read: an empty directory (`endAt` is -1), or a checkpoint that covers all of it.
            return
        }
        for i in startFrom...endAt {
            let segment: WALSegment
            do {
                segment = try openReadWALSegment(fsStorage, segmentName(wal.dir, i))
            } catch {
                throw HeadReplayError.openWALSegment(i, error)
            }
            let reader = WALReader(SegmentBufReader([segment]))
            try loadWAL(reader, multiRef: &multiRef, mmappedChunks: mmappedChunks)
            stats.walReplayStatus.current = i
        }
    }

    /// Go: `Head.loadMmappedChunks` — catalogue every chunk the chunk files hold.
    ///
    /// Returns the map and the LAST chunk ref seen. The `secondLastRef` in the error path is not a detail: when
    /// iteration fails, the ref it reports is the one BEFORE the failure, because *"the lastRef caused an
    /// error"* — a caller that used `lastRef` would treat the corrupt chunk as valid.
    ///
    /// `refSeries` is the snapshot's series map upstream; with the chunk snapshot unported it is always empty,
    /// so the `ok` branch that appends straight onto an existing series is unreachable here and the map is
    /// always the one built for `loadWAL`. Kept because it is the shape `resetSeriesWithMMappedChunks` consumes.
    func loadMmappedChunks(
        refSeries: [HeadSeriesRef: MemSeries]
    ) throws -> ([HeadSeriesRef: [MmappedChunk]], ChunkDiskMapperRef) {
        var mmappedChunks: [HeadSeriesRef: [MmappedChunk]] = [:]
        var lastRef = ChunkDiskMapperRef(rawValue: 0)
        var secondLastRef = ChunkDiskMapperRef(rawValue: 0)

        do {
            try chunkDiskMapper.iterateAllChunks {
                seriesRef, chunkRef, mint, maxt, numSamples, encoding, isOOO in
                secondLastRef = lastRef
                lastRef = chunkRef

                if !isOOO && maxt < minValidTimeValue {
                    return
                }
                // Any chunk without a valid encoding is ignored.
                if !encoding.isValid {
                    return
                }
                if isOOO {
                    return  // Phase 10.
                }

                var slice = mmappedChunks[seriesRef] ?? []
                if let last = slice.last, last.maxTime >= mint {
                    throw HeadReplayError.outOfSequenceMmappedChunk(
                        seriesRef: seriesRef.rawValue, lastMinTime: last.minTime,
                        lastMaxTime: last.maxTime, mint: mint, maxt: maxt)
                }
                slice.append(
                    MmappedChunk(ref: chunkRef, numSamples: numSamples, minTime: mint, maxTime: maxt))
                mmappedChunks[seriesRef] = slice
            }
        } catch {
            // `secondLastRef`, because `lastRef` caused the error.
            _ = secondLastRef
            throw HeadReplayError.iterateOnDiskChunks(error)
        }
        return (mmappedChunks, lastRef)
    }

    /// Go: `removeCorruptedMmappedChunks` — the three-step recovery, and each step is a fallback for the one
    /// before it.
    ///
    ///  1. reset the in-memory state, because *"we never want to preserve the in-memory series from snapshots
    ///     if we are repairing m-map chunks"*;
    ///  2. `DeleteCorrupted`, then re-load;
    ///  3. if either fails, `Truncate(MaxUint32)` — throw every chunk file away and rely on the WAL.
    ///
    /// **None of the three failures is fatal**: the function returns an empty map rather than an error, because
    /// the WAL still holds the samples. Only the `resetInMemoryState` failure propagates upstream, and the
    /// port's reset cannot fail.
    func removeCorruptedMmappedChunks(_ error: any Error) throws -> [HeadSeriesRef: [MmappedChunk]] {
        resetInMemoryState()

        do {
            try chunkDiskMapper.deleteCorrupted(error)
        } catch {
            // Deletion failed: discard the chunk files completely.
            try? chunkDiskMapper.truncate(fileNo: UInt32.max)
            return [:]
        }

        do {
            let (mmappedChunks, _) = try loadMmappedChunks(refSeries: [:])
            return mmappedChunks
        } catch {
            try? chunkDiskMapper.truncate(fileNo: UInt32.max)
            return [:]
        }
    }

    /// Go: `Head.loadWAL` — one segment's records into the head.
    ///
    /// Serial where upstream is sharded (see the file header). The record ORDER is the contract: *"The records
    /// are always replayed from the oldest to the newest."*
    func loadWAL(
        _ reader: WALReader, multiRef: inout [HeadSeriesRef: HeadSeriesRef],
        mmappedChunks: [HeadSeriesRef: [MmappedChunk]]
    ) throws {
        var dec = RecordDecoder()
        var unknownSampleRefs = 0
        var unknownTombstoneRefs = 0

        while reader.next() {
            let rec = reader.record
            switch recordType(rec) {
            case .series:
                let series: [RefSeries]
                do {
                    series = try dec.series(rec)
                } catch {
                    throw HeadReplayError.decode(
                        kind: "series", segment: reader.segment, offset: reader.offset,
                        underlying: error)
                }
                for walSeries in series {
                    let (mSeries, created) = try getOrCreateWithOptionalID(
                        id: walSeries.ref, hash: walSeries.labels.goHash(),
                        labels: walSeries.labels, pendingCommit: false)

                    if lastSeriesID < walSeries.ref.rawValue {
                        lastSeriesID = walSeries.ref.rawValue
                    }
                    if !created {
                        // A duplicate series record: every later record for the OLD ref is remapped.
                        multiRef[walSeries.ref] = mSeries.ref
                    }

                    resetSeriesWithMMappedChunks(
                        mSeries, mmc: mmappedChunks[walSeries.ref] ?? [],
                        walSeriesRef: walSeries.ref)
                }

            case .samples, .samplesV2:
                let samples: [RefSample]
                do {
                    samples = try dec.samples(rec)
                } catch {
                    throw HeadReplayError.decode(
                        kind: "samples", segment: reader.segment, offset: reader.offset,
                        underlying: error)
                }
                for var sam in samples {
                    if sam.t < minValidTimeValue {
                        continue  // Before minValidTime: discard.
                    }
                    if let r = multiRef[sam.ref] {
                        sam.ref = r
                    }
                    guard let ms = self.series.getByID(sam.ref) else {
                        unknownSampleRefs += 1
                        continue
                    }
                    if sam.t <= ms.mmMaxTime {
                        continue  // Already in an m-mapped chunk.
                    }

                    if !PromValue.isStaleNaN(ms.lastValue) && PromValue.isStaleNaN(sam.v) {
                        incNumStaleSeries()
                    }
                    if PromValue.isStaleNaN(ms.lastValue) && !PromValue.isStaleNaN(sam.v) {
                        decNumStaleSeries()
                    }

                    appendChunkAndMmap(ms) {
                        // The appendID is 0: replay is not isolated, because nothing can read the head yet.
                        let (_, chunkCreated) = ms.append(
                            st: sam.st, t: sam.t, v: sam.v, appendID: 0, o: replayChunkOpts())
                        return chunkCreated
                    }
                    updateMinMaxTime(mint: sam.t, maxt: sam.t)
                }

            case .tombstones:
                let stones: [Stone]
                do {
                    stones = try dec.tombstones(rec)
                } catch {
                    throw HeadReplayError.decode(
                        kind: "tombstones", segment: reader.segment, offset: reader.offset,
                        underlying: error)
                }
                for s in stones {
                    // A full-range tombstone means the series was DELETED, which is how a stale series is
                    // recorded so replay can drop it. `deleteSeriesByID` is §7h(c)'s, with the stale-series
                    // feature; until then the interval is added like any other.
                    for itv in s.intervals {
                        var ref = HeadSeriesRef(rawValue: s.ref.rawValue)
                        if let r = multiRef[ref] {
                            ref = r
                        }
                        if self.series.getByID(ref) == nil {
                            unknownTombstoneRefs += 1
                            continue
                        }
                        tombstones.addInterval(SeriesRef(rawValue: ref.rawValue), itv)
                    }
                }

            default:
                // Exemplars, metadata and the histogram record types: recognised and skipped, which is what
                // upstream does with a type it does not know. See the file header.
                continue
            }
        }
        if let err = reader.err {
            throw err
        }
        // Upstream logs the unknown-ref counts at WARN level ("Unknown series references"); the port has no
        // logger, and the counts are what a §7h(c) metric would read.
        _ = unknownSampleRefs
        _ = unknownTombstoneRefs
    }

    /// The `chunkOpts` replay appends with.
    ///
    /// `storeST` is passed *"so that appendPreprocessor cuts an in-progress XOR chunk immediately when replaying
    /// into a head with ST storage enabled"* — upstream's comment. Without it a replay could continue an XOR
    /// chunk with XOR2 appends and lose the start timestamps.
    func replayChunkOpts() -> ChunkOpts {
        ChunkOpts(
            chunkDiskMapper: chunkDiskMapper, chunkRange: chunkRange,
            samplesPerChunk: opts.samplesPerChunk, useXOR2: opts.useXOR2FloatEncoding(),
            storeST: opts.enableSTStorage)
    }

    /// Go: `Head.appendChunkAndMmap` — append, and m-map immediately if that cut a chunk.
    ///
    /// Replay m-maps as it goes rather than at the end, which is what keeps a long WAL from holding every chunk
    /// of every series in memory. The `prev >= 2` test mirrors `onChunkCreated`'s transition in reverse.
    @discardableResult
    func appendChunkAndMmap(_ ms: MemSeries, _ appendFn: () -> Bool) -> Bool {
        let prev = ms.headChunkCount
        let chunkCreated = appendFn()
        if chunkCreated {
            _ = ms.mmapChunks(chunkDiskMapper: chunkDiskMapper)
            if prev >= 2 {
                series.decMmapReady(ms.ref)
            }
        }
        return chunkCreated
    }

    /// Go: `Head.resetSeriesWithMMappedChunks` — give a series the chunks the chunk files hold for it.
    ///
    /// Two things it does beyond the assignment:
    ///
    ///   * it detects OVERLAP when the WAL ref differs from the series' own (a duplicate series record), which
    ///     upstream logs and counts — it does not reject, because the m-mapped chunks are authoritative;
    ///   * it sets **`mmMaxTime`**, the cache that lets `loadWAL` skip every sample already on disk, and widens
    ///     the head's window to the mmapped range. With no mmapped chunks it is `MinInt64`, so nothing is
    ///     skipped.
    @discardableResult
    func resetSeriesWithMMappedChunks(
        _ mSeries: MemSeries, mmc: [MmappedChunk], walSeriesRef: HeadSeriesRef
    ) -> Bool {
        var overlapped = false
        if mSeries.ref != walSeriesRef {
            // Do the new m-mapped chunks overlap the ones already there?
            if let firstOld = mSeries.mmappedChunks.first, let lastOld = mSeries.mmappedChunks.last,
                let firstNew = mmc.first, let lastNew = mmc.last
            {
                if PromHead.overlapsClosedInterval(
                    firstOld.minTime, lastOld.maxTime, firstNew.minTime, lastNew.maxTime)
                {
                    overlapped = true
                }
            }
        }

        mSeries.mmappedChunks = mmc
        // Cache the last m-mapped chunk time, so `loadWAL` can skip samples `append` would reject.
        if mmc.isEmpty {
            mSeries.mmMaxTime = Int64.min
        } else {
            mSeries.mmMaxTime = mmc[mmc.count - 1].maxTime
            updateMinMaxTime(mint: mmc[0].minTime, maxt: mSeries.mmMaxTime)
        }
        return overlapped
    }
}
