//===----------------------------------------------------------------------===//
// `tsdb/wlog/checkpoint.go`, asserted by hand.
//
// The differential corpus for the checkpoint is `Fixtures/head/replay.jsonl` — it drives `tsdb.Head.Truncate`
// and commits the checkpoint directory's NAME, its segment BYTES and its records decoded, so the compaction is
// pinned against Go rather than against expectations written here. That is the contract, and this file does not
// repeat it.
//
// What is here is what a corpus driven through the Head cannot reach:
//
//   * the ERROR paths — `unexpected gap to last checkpoint`, and `checkpoint %s is not a directory`;
//   * the directory PREDICATES — `listCheckpoints`' two different rejections, `LastCheckpoint`'s `ErrNotFound`,
//     `DeleteCheckpoints`' bound and `DeleteTempCheckpoints`;
//   * the record types the Head cannot yet PRODUCE, which is what `CheckpointStats.passedThrough` counts and
//     PORTING.md quirk 193 records;
//   * the temporary directory's lifecycle, which is exception 25's other half: it must be gone whether the
//     checkpoint succeeded or failed.
//
// `Head.truncateWAL`'s own arms (`walExpiries`, `keepSeriesInWALCheckpointFn`, the two-thirds rule) are in
// `Tests/PromHeadTests/HeadReplayTests.swift`, next to the corpus that drives them.
//===----------------------------------------------------------------------===//

import PromChunks
import PromFS
import PromLabels
import PromRecord
import PromStorage
import PromTombstones
import PromWAL
import Testing

@Suite("wal: the checkpoint — its directory, its filters and its temporary name")
struct CheckpointTests {

    /// A WAL holding one series and four samples, with the segment left CLOSED so every byte is on disk.
    private static func seedWAL(_ fs: InMemoryFS, dir: String = "wal") throws {
        let w = try WL(fs: fs, dir: dir)
        let enc = RecordEncoder()
        let lset = Labels([Label("__name__", "m")])
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: lset)]))
        try w.log(
            enc.samples([
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 1000, v: 1),
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 2000, v: 2),
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 3000, v: 3),
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 4000, v: 4),
            ]))
        try w.close()
    }

    /// Every record a checkpoint directory holds, in order, as `(type, payload)`.
    private static func readRecords(_ fs: InMemoryFS, _ dir: String) throws -> [(RecordType, [UInt8])] {
        let sr = try newWALSegmentsReader(fs, dir)
        let r = WALReader(sr)
        var out: [(RecordType, [UInt8])] = []
        while r.next() {
            out.append((recordType(r.record), r.record))
        }
        if let e = r.err { throw e }
        try sr.close()
        return out
    }

    // MARK: - The directory, and the two rejections that are not the same

    /// `CheckpointDir` zero-pads to eight, which is what makes the names sort as their indices do.
    @Test("CheckpointDir zero-pads the index to eight")
    func checkpointDirPads() {
        #expect(checkpointDir("wal", 0) == "wal/checkpoint.00000000")
        #expect(checkpointDir("wal", 7) == "wal/checkpoint.00000007")
        #expect(checkpointDir("wal", 12_345_678) == "wal/checkpoint.12345678")
        // Past eight digits `%08d` stops padding rather than truncating.
        #expect(checkpointDir("wal", 123_456_789) == "wal/checkpoint.123456789")
    }

    /// `LastCheckpoint` on a directory with no checkpoints is `record.ErrNotFound` — *not* an empty result. Every
    /// caller tests for exactly that error to tell "no checkpoint yet" from a real failure, so the identity of
    /// the error is the contract, not just its text.
    @Test("LastCheckpoint reports ErrNotFound on a directory with no checkpoints")
    func lastCheckpointNotFound() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)
        #expect(throws: RecordError.notFound) { try lastCheckpoint(fs, "wal") }
        #expect(try listCheckpoints(fs, "wal").isEmpty)
    }

    /// The `.tmp` suffix is what makes a half-written checkpoint invisible: `checkpoint.00000005.tmp` does not
    /// parse as an integer, so `listCheckpoints` SKIPS it — while a name that does parse is taken.
    ///
    /// The distinction matters because the two rejections have different consequences. A skipped name is
    /// ignored; a non-directory is a hard error (below).
    ///
    /// The nine-digit index is deliberate and is what makes the SORT load-bearing. `%08d` pads to eight but does
    /// not truncate, so past 99,999,999 the names stop sorting lexically the way their indices sort — and every
    /// name here arrives from `fs.list`, which is already sorted. Without a case that separates the two orders,
    /// removing `refs.sort` changes nothing and the negative control reads as a proof it is not.
    @Test("listCheckpoints skips a .tmp suffix and sorts the rest by index, not by name")
    func listCheckpointsSkipsTemp() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("wal")
        for name in [
            "checkpoint.00000009", "checkpoint.00000002", "checkpoint.00000005.tmp",
            "checkpoint.00000004", "checkpoint.notanumber", "notacheckpoint.00000001",
            // Lexically BELOW `checkpoint.99999999`, numerically above it.
            "checkpoint.99999999", "checkpoint.100000000",
        ] {
            try fs.createDirectory("wal/\(name)")
        }

        let refs = try listCheckpoints(fs, "wal")
        #expect(refs.map(\.index) == [2, 4, 9, 99_999_999, 100_000_000])
        #expect(
            refs.map(\.name) == [
                "checkpoint.00000002", "checkpoint.00000004", "checkpoint.00000009",
                "checkpoint.99999999", "checkpoint.100000000",
            ])

        let (dir, idx) = try lastCheckpoint(fs, "wal")
        #expect(dir == "wal/checkpoint.100000000")
        #expect(idx == 100_000_000)
    }

    /// A FILE whose name starts with the prefix is `checkpoint %s is not a directory`, byte for byte. Upstream
    /// tests `fi.IsDir()` before parsing the suffix, so this fires even for a name that would have been skipped.
    @Test("a file named like a checkpoint is an error rather than a skip")
    func listCheckpointsRejectsAFile() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("wal")
        let h = try fs.createFile("wal/checkpoint.00000003")
        try h.append([1, 2, 3])
        try h.close()

        do {
            _ = try listCheckpoints(fs, "wal")
            Issue.record("expected an error")
        } catch let e as CheckpointError {
            #expect(e.description == "checkpoint checkpoint.00000003 is not a directory")
        }

        // And the suffix parse never runs, so even an unparseable one is fatal.
        let h2 = try fs.createFile("wal/checkpoint.00000004.tmp")
        try h2.close()
        try fs.remove("wal/checkpoint.00000003")
        do {
            _ = try listCheckpoints(fs, "wal")
            Issue.record("expected an error")
        } catch let e as CheckpointError {
            #expect(e.description == "checkpoint checkpoint.00000004.tmp is not a directory")
        }
    }

    /// `DeleteCheckpoints` removes everything strictly BELOW `maxIndex` and stops at the first index at or above
    /// it. The boundary is the assertion: `maxIndex` itself survives.
    @Test("DeleteCheckpoints removes everything below maxIndex and keeps maxIndex itself")
    func deleteCheckpointsBound() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("wal")
        for i in [1, 3, 5, 7] {
            try fs.createDirectory("wal/\(String(format: "checkpoint.%08d", i))")
            // A file inside, so the removal has to recurse rather than just unlink a name.
            let h = try fs.createFile("wal/\(String(format: "checkpoint.%08d", i))/00000000")
            try h.append([0xAB])
            try h.close()
        }

        try deleteCheckpoints(fs, "wal", maxIndex: 5)
        #expect(try listCheckpoints(fs, "wal").map(\.index) == [5, 7])
        // The subtree went with the directory.
        #expect(fs.exists("wal/checkpoint.00000003/00000000") == false)

        // maxIndex below everything removes nothing; maxIndex above everything removes all.
        try deleteCheckpoints(fs, "wal", maxIndex: 0)
        #expect(try listCheckpoints(fs, "wal").map(\.index) == [5, 7])
        try deleteCheckpoints(fs, "wal", maxIndex: 99)
        #expect(try listCheckpoints(fs, "wal").isEmpty)
    }

    /// `DeleteTempCheckpoints` takes the `.tmp` directories and nothing else — it is what `Checkpoint` calls
    /// before it starts, so a crash during a previous checkpoint cannot leave bytes that confuse the new one.
    @Test("DeleteTempCheckpoints removes only the .tmp directories")
    func deleteTempCheckpointsOnlyTemp() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("wal")
        for name in [
            "checkpoint.00000002", "checkpoint.00000003.tmp", "checkpoint.00000004.tmp",
            "00000000.tmp",
        ] {
            try fs.createDirectory("wal/\(name)")
        }

        try deleteTempCheckpoints(fs, "wal")
        #expect(((try? fs.list("wal")) ?? []).sorted() == ["00000000.tmp", "checkpoint.00000002"])
    }

    // MARK: - The range, and the gap that is not allowed

    /// A `from` above the previous checkpoint's index + 1 would skip segments, and the segments in between are
    /// exactly the ones nothing else holds — so it is refused with a message the port reproduces byte for byte.
    @Test("Checkpoint refuses a gap to the last checkpoint")
    func unexpectedGap() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)
        try fs.createDirectory("wal/checkpoint.00000002")
        let wal = try WL(fs: fs, dir: "wal")

        do {
            _ = try checkpoint(
                fs: fs, wal: wal, from: 4, to: 6, keep: { _ in true }, mint: 0,
                enableSTStorage: false)
            Issue.record("expected an error")
        } catch let e as CheckpointError {
            #expect(e.description == "unexpected gap to last checkpoint. expected:3, requested:4")
        }

        // `from == last` is the boundary and is allowed, as is anything below it — a `from` under the previous
        // checkpoint is silently RAISED to it rather than rejected, because *"WAL files below the checkpoint
        // should not exist to begin with"*.
        for from in [0, 1, 2, 3] {
            #expect(throws: Never.self) {
                _ = try checkpoint(
                    fs: fs, wal: wal, from: from, to: 6, keep: { _ in true }, mint: 0,
                    enableSTStorage: false)
            }
            // `InMemoryFS.remove` takes the subtree, like `os.RemoveAll`.
            try fs.remove("wal/checkpoint.00000006")
        }
        try wal.close()
    }

    // MARK: - The three filters, as stats

    /// The filters, counted. `keep` drops the series, `mint` drops the samples, and the tombstone is
    /// all-or-nothing on whether ANY of its intervals reaches `mint`.
    @Test("the filters drop what they should, and CheckpointStats counts both halves")
    func filtersAndStats() throws {
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "wal")
        let enc = RecordEncoder()
        try w.log(
            enc.series([
                RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: Labels([Label("n", "a")])),
                RefSeries(ref: HeadSeriesRef(rawValue: 2), labels: Labels([Label("n", "b")])),
            ]))
        try w.log(
            enc.samples([
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 1000, v: 1),
                RefSample(ref: HeadSeriesRef(rawValue: 1), t: 5000, v: 2),
                RefSample(ref: HeadSeriesRef(rawValue: 2), t: 9000, v: 3),
            ]))
        try w.log(
            enc.tombstones([
                // The encoder FLATTENS: one entry per (ref, interval) pair, so these two stones become three
                // entries on the wire and three stones when decoded. See the assertion below.
                Stone(
                    ref: SeriesRef(rawValue: 1),
                    intervals: [DeletionInterval(mint: 0, maxt: 100)]),
                Stone(
                    ref: SeriesRef(rawValue: 2),
                    intervals: [
                        DeletionInterval(mint: 0, maxt: 100),
                        DeletionInterval(mint: 4000, maxt: 6000),
                    ]),
            ]))
        try w.close()

        let wal = try WL(fs: fs, dir: "wal")
        let stats = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0,
            keep: { $0.rawValue == 1 }, mint: 5000, enableSTStorage: false)
        try wal.close()

        #expect(stats.totalSeries == 2)
        #expect(stats.droppedSeries == 1)
        #expect(stats.totalSamples == 3)
        #expect(stats.droppedSamples == 1)  // Only t=1000 is below mint.
        // THREE, not two: the record codec flattens a `Stone`'s intervals, so the filter sees one interval per
        // stone no matter what was encoded. Only `2:[4000,6000]` reaches `mint`.
        #expect(stats.totalTombstones == 3)
        #expect(stats.droppedTombstones == 2)
        #expect(stats.passedThrough == 0)

        // And the surviving records, read back through the same reader `Init` uses.
        var dec = RecordDecoder()
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000000")
        #expect(recs.map(\.0) == [.series, .samples, .tombstones])
        #expect(try dec.series(recs[0].1).map(\.ref.rawValue) == [1])
        #expect(try dec.samples(recs[1].1).map(\.t) == [5000, 9000])
        // One stone survives, and note the `keep` predicate does NOT apply to tombstones: ref 2's series record
        // was dropped, its stone was not. Only `mint` filters a tombstone.
        #expect(
            try dec.tombstones(recs[2].1) == [
                Stone(
                    ref: SeriesRef(rawValue: 2),
                    intervals: [DeletionInterval(mint: 4000, maxt: 6000)])
            ])
        // Upstream's filter breaks out of the interval scan on the first interval that qualifies. That `break`
        // is DEAD on a decoded record, because there is never more than one interval to scan — the codec split
        // them. Recorded so the negative control that removes it is read as a proof, not a gap.
        #expect(try dec.tombstones(recs[2].1).allSatisfy { $0.intervals.count == 1 })
    }

    /// A record whose only surviving content is nothing at all is not written: upstream's `if len(buf[start:])
    /// == 0 { continue }`. So a checkpoint over a WAL where every series is dropped and every sample is below
    /// `mint` holds NO records, rather than empty ones.
    @Test("a record whose whole content is discarded is not written")
    func fullyDiscardedRecordsAreNotWritten() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)
        let wal = try WL(fs: fs, dir: "wal")
        let stats = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in false }, mint: 1_000_000,
            enableSTStorage: false)
        try wal.close()

        #expect(stats.droppedSeries == 1)
        #expect(stats.droppedSamples == 4)
        #expect(try Self.readRecords(fs, "wal/checkpoint.00000000").isEmpty)
    }

    // MARK: - The record types this build cannot produce

    /// Histograms, exemplars and metadata are COPIED THROUGH unfiltered, and `passedThrough` counts them — a
    /// deliberate difference from upstream's `mint` filter, recorded as PORTING.md quirk 193, because the port's
    /// Head cannot produce any of these yet and a filter for them would be untestable.
    ///
    /// What is NOT copied through: `MmapMarkers` and an UNKNOWN type. Upstream's switch has no case for either,
    /// so both fall to `default: continue` and are dropped — copying an unknown record through would be a
    /// divergence rather than a deferral. The Head cannot write these either, so they are planted by hand.
    @Test("histograms, exemplars and metadata pass through; mmap markers and unknown types are dropped")
    func passThroughAndDrop() throws {
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "wal")
        // The pass-through arm never DECODES, so the payloads can be arbitrary — which is the point: a record
        // this build cannot parse still survives a checkpoint byte for byte.
        let passed: [[UInt8]] = [
            [RecordType.metadata.rawValue, 0xAA, 0xBB],
            [RecordType.exemplars.rawValue, 0xCC],
            [RecordType.histogramSamples.rawValue, 0xDD],
            [RecordType.floatHistogramSamples.rawValue, 0xDE],
            [RecordType.customBucketsHistogramSamples.rawValue, 0xDF],
            [RecordType.customBucketsFloatHistogramSamples.rawValue, 0xE0],
            [RecordType.histogramSamplesV2.rawValue, 0xE1],
            [RecordType.floatHistogramSamplesV2.rawValue, 0xE2],
        ]
        let dropped: [[UInt8]] = [
            [RecordType.mmapMarkers.rawValue, 0xEE],
            [200, 0xFF],  // No such type: `recordType` answers `.unknown`.
        ]
        for rec in passed + dropped {
            try w.log(rec)
        }
        try w.close()

        let wal = try WL(fs: fs, dir: "wal")
        let stats = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0, enableSTStorage: false)
        try wal.close()

        #expect(stats.passedThrough == passed.count)
        #expect(stats.totalSeries == 0)
        #expect(stats.totalSamples == 0)
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000000")
        #expect(recs.map(\.1) == passed)
    }

    // MARK: - The temporary directory, which is exception 25

    /// Exception 25: `PromFS` has no rename, so the temporary directory is COPIED to the final name rather than
    /// moved. The END STATE has to be indistinguishable, and that is what is asserted — the `.tmp` name is gone
    /// and the final one holds the same bytes.
    @Test("the temporary directory is gone after a successful checkpoint, and its bytes arrived")
    func temporaryDirectoryIsConsumed() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)
        let wal = try WL(fs: fs, dir: "wal")
        _ = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0, enableSTStorage: false)
        try wal.close()

        #expect(fs.exists("wal/checkpoint.00000000.tmp") == false)
        #expect(((try? fs.list("wal")) ?? []).contains("checkpoint.00000000"))
        // A real segment, not an empty directory.
        let files = ((try? fs.list("wal/checkpoint.00000000")) ?? []).sorted()
        #expect(files == ["00000000"])
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000000")
        #expect(recs.map(\.0) == [.series, .samples])
    }

    /// And gone after a FAILED one, which is what upstream's unconditional `defer` is for: *"Ensures that an
    /// early return caused by an error doesn't leave any tmp files."* Without it the next checkpoint would find
    /// a half-written directory — `DeleteTempCheckpoints` would clear it, but only on the next attempt.
    ///
    /// The failure is a series record whose payload is truncated, which is the one thing that reaches
    /// `decode series` without needing a corrupt segment.
    @Test("a failed checkpoint leaves no temporary directory behind")
    func temporaryDirectoryIsRemovedOnFailure() throws {
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "wal")
        // A `series` type byte with a payload the decoder cannot finish.
        try w.log([RecordType.series.rawValue, 0x01, 0x02])
        try w.close()

        let wal = try WL(fs: fs, dir: "wal")
        do {
            _ = try checkpoint(
                fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0,
                enableSTStorage: false)
            Issue.record("expected a decode failure")
        } catch let e as CheckpointError {
            #expect(e.description.hasPrefix("decode series: "))
        }
        try wal.close()

        #expect(fs.exists("wal/checkpoint.00000000.tmp") == false)
    }

    /// A new checkpoint INCLUDES the old one rather than superseding it: `from` is replaced by the previous
    /// index + 1 and the previous directory is prepended to the read range. The corpus pins this through two
    /// truncations; here it is the mechanism on its own, so the records that came *through* the old checkpoint
    /// are identifiable.
    @Test("a new checkpoint reads the previous one first")
    func newCheckpointIncludesTheOld() throws {
        let fs = InMemoryFS()
        let enc = RecordEncoder()
        let lset = Labels([Label("__name__", "m")])

        // Segment 0 holds the series record and one sample; segment 1 holds another sample.
        let w = try WL(fs: fs, dir: "wal")
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: lset)]))
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 1000, v: 1)]))
        _ = try w.nextSegment()
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 2000, v: 2)]))
        _ = try w.nextSegment()
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 3000, v: 3)]))
        try w.close()

        let wal = try WL(fs: fs, dir: "wal")
        _ = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0, enableSTStorage: false)
        // The second checkpoint asks for 1..1, and gets checkpoint.00000000's contents as well.
        let stats = try checkpoint(
            fs: fs, wal: wal, from: 1, to: 1, keep: { _ in true }, mint: 0, enableSTStorage: false)
        try wal.close()

        // Two records from the old checkpoint plus one from segment 1.
        #expect(stats.totalSeries == 1)
        #expect(stats.totalSamples == 2)

        var dec = RecordDecoder()
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000001")
        #expect(recs.map(\.0) == [.series, .samples, .samples])
        #expect(try dec.samples(recs[1].1).map(\.t) == [1000])
        #expect(try dec.samples(recs[2].1).map(\.t) == [2000])
        // Segment 2 was not asked for, so t=3000 is not in the checkpoint — it is still in the live WAL.
        #expect(recs.count == 3)
    }

    /// A `from` BELOW the previous checkpoint's boundary is silently raised to it rather than honoured —
    /// *"Ignore WAL files below the checkpoint. They shouldn't exist to begin with."* Without the raise those
    /// segments are read twice, once through the previous checkpoint and once directly, and the new checkpoint
    /// gets duplicate records.
    ///
    /// `Head.truncateWAL` never asks for such a range (its `first` comes from `Segments`, which after a
    /// truncation is already above the checkpoint), so this is only reachable by calling `Checkpoint` directly.
    @Test("a from below the previous checkpoint is raised, so its segments are not read twice")
    func fromBelowThePreviousCheckpointIsRaised() throws {
        let fs = InMemoryFS()
        let enc = RecordEncoder()
        let lset = Labels([Label("__name__", "m")])

        let w = try WL(fs: fs, dir: "wal")
        try w.log(enc.series([RefSeries(ref: HeadSeriesRef(rawValue: 1), labels: lset)]))
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 1000, v: 1)]))
        _ = try w.nextSegment()
        try w.log(enc.samples([RefSample(ref: HeadSeriesRef(rawValue: 1), t: 2000, v: 2)]))
        try w.close()

        let wal = try WL(fs: fs, dir: "wal")
        _ = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0, enableSTStorage: false)
        // `from: 0` is below `lastCheckpoint.index + 1 == 1`, so segment 0 must NOT be read again — its records
        // are already inside checkpoint.00000000.
        let stats = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 1, keep: { _ in true }, mint: 0, enableSTStorage: false)
        try wal.close()

        #expect(stats.totalSeries == 1)  // Two if segment 0 were read a second time.
        #expect(stats.totalSamples == 2)
        var dec = RecordDecoder()
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000001")
        #expect(recs.map(\.0) == [.series, .samples, .samples])
        #expect(try dec.samples(recs[1].1).map(\.t) == [1000])
        #expect(try dec.samples(recs[2].1).map(\.t) == [2000])
    }

    /// `Checkpoint` calls `DeleteTempCheckpoints` before it opens its own temporary directory, and that is not
    /// hygiene — a leftover `.tmp` from a crashed run holds SEGMENTS, so the new `WL` would continue writing
    /// after them and the leftover records would be copied to the final name as if they belonged.
    @Test("a leftover temporary checkpoint is cleared before the new one is written")
    func leftoverTemporaryCheckpointIsCleared() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)

        // A crashed previous run: `checkpoint.00000000.tmp` with a record in it, under a DIFFERENT ref so it is
        // identifiable if it survives.
        let stale = try WL(fs: fs, dir: "wal/checkpoint.00000000.tmp")
        try stale.log(
            RecordEncoder().series([
                RefSeries(ref: HeadSeriesRef(rawValue: 77), labels: Labels([Label("stale", "y")]))
            ]))
        try stale.close()

        let wal = try WL(fs: fs, dir: "wal")
        _ = try checkpoint(
            fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0, enableSTStorage: false)
        try wal.close()

        var dec = RecordDecoder()
        let recs = try Self.readRecords(fs, "wal/checkpoint.00000000")
        #expect(recs.map(\.0) == [.series, .samples])
        #expect(try dec.series(recs[0].1).map(\.ref.rawValue) == [1])
        // One segment, not two: the stale directory's `00000000` did not push the new one to `00000001`.
        #expect(((try? fs.list("wal/checkpoint.00000000")) ?? []).sorted() == ["00000000"])
    }

    /// A corruption met while checkpointing is fatal: *"If we hit any corruption during checkpointing, repairing
    /// is not an option. The head won't know which series records are lost."* Wrapped as `read segments`.
    ///
    /// The corruption is a flipped payload byte, so the record's CRC no longer matches — which is the failure
    /// `Reader` reports through `Err()` rather than through a decode error.
    @Test("a corrupt source segment fails the checkpoint rather than being skipped")
    func corruptSourceSegmentFailsTheCheckpoint() throws {
        let fs = InMemoryFS()
        try Self.seedWAL(fs)

        // Flip a byte inside the first record's payload. The fragment header is seven bytes
        // ([type|flags][BE16 length][BE32 CRC]), so anything past that is payload.
        let h = try fs.openForReading("wal/00000000")
        var bytes = try h.read(offset: 0, length: h.size)
        try h.close()
        bytes[9] ^= 0xFF
        let wh = try fs.createFile("wal/00000000")
        try wh.append(bytes)
        try wh.close()

        let wal = try WL(fs: fs, dir: "wal")
        do {
            _ = try checkpoint(
                fs: fs, wal: wal, from: 0, to: 0, keep: { _ in true }, mint: 0,
                enableSTStorage: false)
            Issue.record("expected a read failure")
        } catch let e as CheckpointError {
            #expect(e.description.hasPrefix("read segments: "))
        }
        try wal.close()
        // And the temporary directory went with it.
        #expect(fs.exists("wal/checkpoint.00000000.tmp") == false)
    }
}
