//===----------------------------------------------------------------------===//
// Ported from tsdb/compact.go @ v3.13.2 — `BlockPopulator`, `DefaultBlockPopulator.PopulateBlock`,
// `IndexReaderPostingsFunc` and `AllSortedPostings`.
//
// The loop that turns readers into a block: symbols first, then every series with its chunks, accumulating
// the stats into the meta as it goes.
//
// ## The series ref written to the index is a COUNTER, not the source's
//
// `ref := storage.SeriesRef(0)`, and `ref++` runs at the very bottom of the loop — after the `continue`s. So
// the refs are dense positions in *output* order, a series skipped for having no chunks does not consume one,
// and a Head series ref never appears in a block's index. Quirk 197.
//
// That number is also less load-bearing than it looks: `index.Writer` derives the postings ordinals from each
// series record's byte POSITION divided by 16 (quirk 133), not from `ref`. `AddSeries` reads `ref` only for
// its monotonicity check. A port that passed the source's refs through would still produce a readable block —
// and a subtly different one, because `AddSeries` rejects a ref that goes backwards.
//
// ## The stats switch has no default arm
//
// `NumSamples` is incremented for every chunk; `NumFloatSamples` and `NumHistogramSamples` are a `switch` over
// four encodings with nothing else. So a chunk in an encoding outside that set contributes to the total and to
// neither breakdown, and `NumSamples != NumFloatSamples + NumHistogramSamples`. Quirk 198.
//
// ## Symbols are copied WHOLESALE, before any series is examined
//
// The symbol table is drained from the reader and written in full, then the series loop runs. Nothing checks
// whether a symbol is used: a block written from a Head whose series all fall outside `[mint, maxt]` still
// carries every label name and value the Head knew. Quirk 207 — and it is why an "empty" block still has a
// populated index right up until the `NumSamples == 0` check throws the directory away.
//
// ## The series set's `maxt` is `meta.MaxTime - 1`
//
// Upstream's comment: "Blocks meta is half open: [min, max), so subtract 1 to ensure we don't hold samples
// with exact meta.MaxTime timestamp." The other half of quirk 199.
//
// ## `disableTrimming` is FALSE
//
// So the synthetic `[MinInt64, mint-1]` and `[maxt+1, MaxInt64]` intervals of §6s ARE applied, and a chunk
// straddling the block boundary is re-encoded down to the samples inside it. That is the difference between a
// compaction and a copy, and it is why `populateWithDelChunkSeriesIterator` had to exist before this slice.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunks
public import PromIndex
public import PromStorage

internal import PromChunkEnc

/// Go: `IndexReaderPostingsFunc`.
public typealias IndexReaderPostingsFunc = (any BlockIndexReader) -> any Postings

/// Go: `AllSortedPostings(ctx, reader)`.
///
/// `index.AllPostingsKey()` is the empty label `("", "")`, and a failure becomes an `ErrPostings` rather than
/// a thrown error — so the failure surfaces at the set's `Err()`, one layer later, which is where
/// `PopulateBlock` reports `iterate compaction set`.
public func allSortedPostings(_ reader: any BlockIndexReader) -> any Postings {
    let key = allPostingsKey()
    do {
        let all = try reader.postings(name: key.name, values: [key.value])
        return reader.sortedPostings(all)
    } catch {
        return errPostings(error)
    }
}

/// Go: `BlockPopulator`.
public protocol BlockPopulator {
    /// Go: `PopulateBlock`. `meta` is `inout` because the stats are accumulated into it; see
    /// `LeveledCompactor.swift`'s header, quirk 201.
    func populateBlock(
        blocks: [any BlockReader], meta: inout BlockMeta, indexw: IndexWriter,
        chunkw: ChunkWriter, postingsFunc: IndexReaderPostingsFunc
    ) throws
}

/// Go: `DefaultBlockPopulator`.
public struct DefaultBlockPopulator: BlockPopulator {
    public init() {}

    public func populateBlock(
        blocks: [any BlockReader], meta: inout BlockMeta, indexw: IndexWriter,
        chunkw: ChunkWriter, postingsFunc: IndexReaderPostingsFunc
    ) throws {
        if blocks.isEmpty {
            throw CompactError.noReaders
        }
        // See `CompactError.verticalCompactionUnported`: merging needs `storage/merge.go`, and its only
        // caller is `Compact`, which is §7j's.
        if blocks.count > 1 {
            throw CompactError.verticalCompactionUnported(readers: blocks.count)
        }

        var closers: [() throws -> Void] = []
        defer { for c in closers { try? c() } }

        let block = blocks[0]
        let blockDescription = describe(block.meta())

        // The overlap detection (`globalMaxt`, `metrics.OverlappingBlocks`) is a metric and a log line over a
        // single reader, so it has nothing to observe here. It becomes real with `Compact`, §7j.

        let indexr: any BlockIndexReader
        do {
            indexr = try block.indexReader()
        } catch {
            throw CompactError.openIndexReader(block: blockDescription, underlying: error)
        }
        closers.append(indexr.close)

        let chunkr: any BlockChunkReader
        do {
            chunkr = try block.chunkReader()
        } catch {
            throw CompactError.openChunkReader(block: blockDescription, underlying: error)
        }
        closers.append(chunkr.close)

        let tombsr: any BlockTombstoneReader
        do {
            tombsr = try block.tombstoneReader()
        } catch {
            throw CompactError.openTombstoneReader(block: blockDescription, underlying: error)
        }
        closers.append(tombsr.close)

        let postings = postingsFunc(indexr)
        let set = BlockChunkSeriesSet(
            blockID: block.meta().ulid.description, index: indexr, chunks: chunkr,
            postings: postings, mint: meta.minTime, maxt: meta.maxTime - 1,
            disableTrimming: false, tombstonesFor: tombsr.get)

        // Symbols, in full and before any series. See the file header.
        for symbol in indexr.symbols() {
            do {
                try indexw.addSymbol(symbol)
            } catch {
                throw CompactError.addSymbol(error)
            }
        }

        var ref: UInt64 = 0
        while set.next() {
            guard let s = set.current else { break }

            var chks: [(meta: DecodedChunkMeta, bytes: [UInt8], encoding: Encoding)] = []
            let chksIter = s.iterator
            while chksIter.next() {
                guard let c = chksIter.current else { break }
                chks.append(c)
            }
            if let e = chksIter.err() {
                throw CompactError.chunkIter(e)
            }

            // Skip series with all deleted chunks.
            if chks.isEmpty {
                continue
            }

            let refs: [ChunkRef]
            do {
                // Go: `chunkw.WriteChunks(chks...)`, which sets `chks[i].Ref` in place. The port returns the
                // refs instead and the caller zips them back in, which is the same information.
                let payload: [(encoding: Encoding, bytes: [UInt8])] = chks.map {
                    (encoding: $0.encoding, bytes: $0.bytes)
                }
                refs = try chunkw.write(payload)
            } catch {
                throw CompactError.writeChunks(error)
            }

            // Spelled with an explicit type and a plain loop rather than one inferred `zip(…).map`:
            // HANDOFF §4 — the Swift 6.1 floor's type checker gives up on expressions the 6.4 one accepts,
            // and a tuple-of-three built inside a closure is exactly that shape.
            var indexChunks: [(minTime: Int64, maxTime: Int64, ref: UInt64)] = []
            indexChunks.reserveCapacity(chks.count)
            for (i, chk) in chks.enumerated() {
                indexChunks.append(
                    (minTime: chk.meta.minTime, maxTime: chk.meta.maxTime, ref: refs[i].rawValue))
            }

            do {
                try indexw.addSeries(ref: ref, labels: s.labels, chunks: indexChunks)
            } catch {
                throw CompactError.addSeries(error)
            }

            meta.stats.numChunks += UInt64(chks.count)
            meta.stats.numSeries += 1
            for chk in chks {
                let samples = UInt64(try numSamples(chk.encoding, chk.bytes))
                meta.stats.numSamples += samples
                // No default arm — see the file header, quirk 198.
                switch chk.encoding {
                case .histogram, .floatHistogram:
                    meta.stats.numHistogramSamples += samples
                case .xor, .xor2:
                    meta.stats.numFloatSamples += samples
                default:
                    break
                }
            }

            // `chunkPool.Put` for each chunk — exception 4, the port has no pool.
            ref += 1
        }
        if let e = set.err() {
            throw CompactError.iterateCompactionSet(e)
        }
    }

    /// Go: `chk.Chunk.NumSamples()`.
    ///
    /// Every encoding stores it as the leading big-endian `uint16`, but reading it off the bytes directly
    /// would be this file inventing a format. `newEmptyChunk` + `reset` is the same dispatch §7f(c) built,
    /// and it fails loudly on an encoding `PromChunkEnc` does not have rather than counting zero.
    private func numSamples(_ encoding: Encoding, _ bytes: [UInt8]) throws -> Int {
        let c = try newEmptyChunk(encoding)
        c.reset(bytes)
        return c.numSamples
    }

    /// Go: `%+v` over a `BlockMeta`, as the three `open … reader for block %+v` errors interpolate it.
    ///
    /// Reproducing Go's struct dump verbatim is not worth it and would be its own compatibility surface; the
    /// ULID and the range are what identify the block in the message, so the port names those. Recorded next
    /// to the errors rather than in PORTING.md because no consumer parses them.
    private func describe(_ m: BlockMeta) -> String {
        "{ULID:\(m.ulid) MinTime:\(m.minTime) MaxTime:\(m.maxTime)}"
    }
}
