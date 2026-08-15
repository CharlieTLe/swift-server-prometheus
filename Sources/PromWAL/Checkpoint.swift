//===----------------------------------------------------------------------===//
// Ported from tsdb/wlog/checkpoint.go @ v3.13.2.
//
// A checkpoint is a COMPACTED COPY of a range of WAL segments, written in the same segmented format so it can be
// read back through the same reader and concatenated with the segments that follow it. `Head.truncateWAL` makes
// one and then deletes the segments it covered; `Head.Init` reads it first, before the live segments.
//
// ## What "compacted" means, and the three filters
//
//   * **series** — kept only when `keep(ref)` says so. The Head's predicate keeps a series that still exists, or
//     one whose WAL-expiry says its samples are still in the WAL (`keepSeriesInWALCheckpointFn`). Dropping a
//     series record whose samples survive would leave a replay with samples it cannot name.
//   * **samples, tombstones, exemplars** — kept only at or after `mint`.
//   * **metadata** — only the LATEST per series, which is why upstream accumulates a map and flushes it at the
//     end rather than filtering in place.
//
// ## The temporary directory, and the one divergence
//
// Upstream writes into `checkpoint.NNNNNNNN.tmp`, syncs it, and then `fileutil.Replace`s it onto the final name
// — an atomic rename, so a crash never leaves a half-written checkpoint under a name `LastCheckpoint` trusts.
// `PromFS` has no rename, so the port COPIES the temporary directory's files to the final name and removes the
// temporary one. See PORTING.md exception 25: the sequence of visible states differs (a crash mid-copy can leave
// a partial checkpoint), the end state does not.
//
// ## What is absent
//
//   * **Histograms, exemplars and metadata records.** The port's `Head` cannot produce them yet (§7f defers the
//     histogram append path, exemplars and `UpdateMetadata`), so a checkpoint that filtered them would be
//     untestable. The record types are recognised and **copied through unchanged**, which is what keeps a
//     checkpoint lossless for records this build does not filter — and is a deliberate difference from
//     upstream's mint filter, recorded in `CheckpointStats` as `PassedThrough`. See PORTING.md quirk 193.
//
//     Note what is NOT passed through: an **unknown** type, and `MmapMarkers`. Upstream's `switch` has no case
//     for either, so both fall to `default: continue` and are DROPPED, and the port drops them too. Copying an
//     unknown record through would be a divergence rather than a deferral — the whole point of upstream's
//     `continue` is that a record a future Prometheus wrote cannot be reasoned about.
//   * `DeleteTempCheckpoints`' `tsdbutil.RemoveTmpDirs` — the port removes them inline.
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromFS
public import PromRecord
public import PromStorage
public import PromTombstones

/// Go: `checkpointPrefix`.
public let checkpointPrefix = "checkpoint."
/// Go: `CheckpointTempFileSuffix`.
public let checkpointTempFileSuffix = ".tmp"

/// Go: `CheckpointStats` — "stats about a created checkpoint".
public struct CheckpointStats: Sendable, Equatable {
    public var droppedSeries = 0
    public var droppedSamples = 0
    public var droppedTombstones = 0
    public var totalSeries = 0
    public var totalSamples = 0
    public var totalTombstones = 0
    /// NOT upstream's: the records this build copies through without filtering (histograms, exemplars,
    /// metadata). Counted rather than silently dropped, so a checkpoint's losslessness is visible.
    public var passedThrough = 0

    public init() {}
}

/// Go: `CheckpointDir` — `checkpoint.` plus the segment index, zero-padded to eight.
public func checkpointDir(_ dir: String, _ i: Int) -> String {
    "\(dir)/\(checkpointPrefix)\(String(format: "%08d", i))"
}

/// Go: `checkpointRef`.
public struct CheckpointRef: Sendable, Equatable {
    public var name: String
    public var index: Int
}

/// Go: `listCheckpoints` — sorted by index.
///
/// Two rejections that are not the same: a name starting with the prefix that is **not a directory** is an
/// ERROR (`checkpoint %s is not a directory`), while a name whose suffix does not parse as an integer is simply
/// SKIPPED — which is what makes `checkpoint.00000005.tmp` invisible here rather than fatal.
public func listCheckpoints(_ fs: any PromFS, _ dir: String) throws -> [CheckpointRef] {
    var refs: [CheckpointRef] = []
    for name in try fs.list(dir) {
        guard name.hasPrefix(checkpointPrefix) else { continue }
        // The order matters and is upstream's: the directory test comes BEFORE the suffix parse, so a FILE
        // called `checkpoint.00000001.tmp` is an error while a directory of that name is skipped.
        // `PromFS` has no `isDir`, so the test is "can it be listed" — the name came from `list(dir)`, so it
        // exists, and `list` on a file throws.
        if (try? fs.list("\(dir)/\(name)")) == nil {
            throw CheckpointError.notADirectory(name)
        }
        let suffix = String(name.dropFirst(checkpointPrefix.count))
        guard let idx = Int(suffix) else { continue }
        refs.append(CheckpointRef(name: name, index: idx))
    }
    refs.sort { $0.index < $1.index }
    return refs
}

/// Go: `LastCheckpoint` — the most recent checkpoint's directory and index, or `ErrNotFound`.
public func lastCheckpoint(_ fs: any PromFS, _ dir: String) throws -> (dir: String, index: Int) {
    let checkpoints = try listCheckpoints(fs, dir)
    guard let last = checkpoints.last else {
        throw RecordError.notFound
    }
    return ("\(dir)/\(last.name)", last.index)
}

/// Go: `DeleteCheckpoints` — every checkpoint BELOW `maxIndex`.
///
/// Note the `break`: the list is sorted, so the first index at or above `maxIndex` ends the walk. And note that
/// upstream JOINS the removal errors rather than stopping, so a checkpoint that cannot be removed does not
/// prevent the others from going.
public func deleteCheckpoints(_ fs: any PromFS, _ dir: String, maxIndex: Int) throws {
    let checkpoints = try listCheckpoints(fs, dir)
    var first: (any Error)?
    for checkpoint in checkpoints {
        if checkpoint.index >= maxIndex {
            break
        }
        do { try removeDirectoryRecursively(fs, "\(dir)/\(checkpoint.name)") } catch {
            first = first ?? error
        }
    }
    if let first { throw first }
}

/// Go: `isTempDir`, and `DeleteTempCheckpoints` around it.
public func deleteTempCheckpoints(_ fs: any PromFS, _ dir: String) throws {
    for name in (try? fs.list(dir)) ?? [] {
        if name.hasPrefix(checkpointPrefix) && name.hasSuffix(checkpointTempFileSuffix) {
            try? removeDirectoryRecursively(fs, "\(dir)/\(name)")
        }
    }
}

/// `os.RemoveAll` for a directory of files, which is all a checkpoint is.
func removeDirectoryRecursively(_ fs: any PromFS, _ path: String) throws {
    for name in (try? fs.list(path)) ?? [] {
        try? removeDirectoryRecursively(fs, "\(path)/\(name)")
        try? fs.remove("\(path)/\(name)")
    }
    try fs.remove(path)
}

/// Go: `wlog.Checkpoint` — "creates a compacted checkpoint of segments in range [from, to] in the given WAL".
///
/// The range handling is the part to read twice. When a previous checkpoint exists, `from` is **replaced** by
/// that checkpoint's index + 1, and the checkpoint's own directory is prepended to the read range — so a new
/// checkpoint includes the old one rather than superseding it. A `from` above that boundary is an error
/// (`unexpected gap to last checkpoint`), because the segments in between would be lost.
@discardableResult
public func checkpoint(
    fs: any PromFS, wal: WL, from: Int, to: Int, keep: (HeadSeriesRef) -> Bool, mint: Int64,
    enableSTStorage: Bool
) throws -> CheckpointStats {
    var stats = CheckpointStats()
    var from = from

    var ranges: [WALSegmentRange] = []
    var lastCP: (dir: String, index: Int)?
    do {
        lastCP = try lastCheckpoint(fs, wal.dir)
    } catch let e as RecordError where e == .notFound {
        lastCP = nil
    } catch {
        throw CheckpointError.findLastCheckpoint(error)
    }
    if let lastCP {
        let last = lastCP.index + 1
        if from > last {
            throw CheckpointError.unexpectedGap(expected: last, requested: from)
        }
        // Ignore WAL files below the checkpoint; they should not exist to begin with.
        from = last
        ranges.append(WALSegmentRange(dir: lastCP.dir, first: -1, last: Int(Int32.max)))
    }
    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: to))

    let sgmReader: SegmentBufReader
    do {
        sgmReader = try newWALSegmentsRangeReader(fs, ranges)
    } catch {
        throw CheckpointError.createSegmentReader(error)
    }

    try deleteTempCheckpoints(fs, wal.dir)

    let cpdir = checkpointDir(wal.dir, to)
    let cpdirtmp = cpdir + checkpointTempFileSuffix

    try fs.createDirectory(cpdirtmp)
    let cp: WL
    do {
        cp = try WL(fs: fs, dir: cpdirtmp)
    } catch {
        throw CheckpointError.openCheckpoint(error)
    }
    // Upstream's unconditional `defer`: *"Ensures that an early return caused by an error doesn't leave any tmp
    // files."* It runs on success too, where both calls are no-ops — the `WL` is already closed and the
    // temporary directory has already been consumed by the copy below.
    defer {
        try? cp.close()
        try? removeDirectoryRecursively(fs, cpdirtmp)
    }

    let r = WALReader(sgmReader)
    var dec = RecordDecoder()
    let enc = RecordEncoder(enableSTStorage: enableSTStorage)
    var recs: [[UInt8]] = []

    while r.next() {
        let rec = r.record
        switch recordType(rec) {
        case .series:
            let series: [RefSeries]
            do { series = try dec.series(rec) } catch {
                throw CheckpointError.decode("series", error)
            }
            let repl = series.filter { keep($0.ref) }
            if !repl.isEmpty {
                recs.append(enc.series(repl))
            }
            stats.totalSeries += series.count
            stats.droppedSeries += series.count - repl.count

        case .samples, .samplesV2:
            let samples: [RefSample]
            do { samples = try dec.samples(rec) } catch {
                throw CheckpointError.decode("samples", error)
            }
            let repl = samples.filter { $0.t >= mint }
            if !repl.isEmpty {
                recs.append(enc.samples(repl))
            }
            stats.totalSamples += samples.count
            stats.droppedSamples += samples.count - repl.count

        case .tombstones:
            let tstones: [Stone]
            do { tstones = try dec.tombstones(rec) } catch {
                throw CheckpointError.decode("deletes", error)
            }
            // A tombstone is kept when ANY of its intervals reaches `mint` — upstream's loop breaks out of the
            // interval scan on the first one that qualifies, so a stone is all-or-nothing rather than trimmed.
            let repl = tstones.filter { stone in stone.intervals.contains { $0.maxt >= mint } }
            if !repl.isEmpty {
                recs.append(enc.tombstones(repl))
            }
            stats.totalTombstones += tstones.count
            stats.droppedTombstones += tstones.count - repl.count

        case .unknown, .mmapMarkers:
            // Upstream's `default: continue` — *"Unknown record type, probably from a future Prometheus
            // version."* `MmapMarkers` lands here too: the switch has no case for it, so a checkpoint drops it.
            continue

        default:
            // Histograms, exemplars and metadata: copied through unfiltered. See the file header.
            recs.append(rec)
            stats.passedThrough += 1
        }

        // Upstream batches until the buffer passes 1 MiB; the port flushes per record, which changes only how
        // many `Log` calls happen — a WAL record's bytes do not depend on what was written before it.
        if !recs.isEmpty {
            do { try cp.log(records: recs) } catch {
                throw CheckpointError.flushRecords(error)
            }
            recs.removeAll(keepingCapacity: true)
        }
    }
    // "If we hit any corruption during checkpointing, repairing is not an option. The head won't know which
    // series records are lost."
    if let err = r.err {
        throw CheckpointError.readSegments(err)
    }

    do { try cp.close() } catch {
        throw CheckpointError.closeCheckpoint(error)
    }
    try sgmReader.close()

    // Upstream syncs the temporary directory and then renames it atomically. `PromFS` has no rename, so the
    // files are copied and the temporary directory removed by the `defer` above — exception 25.
    try fs.createDirectory(cpdir)
    for name in try fs.list(cpdirtmp) {
        let src = try fs.openForReading("\(cpdirtmp)/\(name)")
        let bytes = try src.read(offset: 0, length: src.size)
        try src.close()
        let dst = try fs.createFile("\(cpdir)/\(name)")
        try dst.append(bytes)
        try dst.close()
    }

    return stats
}

/// Go: `checkpoint.go`'s wrapped errors.
public enum CheckpointError: Error, CustomStringConvertible {
    case unexpectedGap(expected: Int, requested: Int)
    case notADirectory(String)
    case findLastCheckpoint(any Error)
    case createSegmentReader(any Error)
    case openCheckpoint(any Error)
    case decode(String, any Error)
    case flushRecords(any Error)
    case readSegments(any Error)
    case closeCheckpoint(any Error)

    public var description: String {
        switch self {
        case .unexpectedGap(let expected, let requested):
            return "unexpected gap to last checkpoint. expected:\(expected), requested:\(requested)"
        case .notADirectory(let name): return "checkpoint \(name) is not a directory"
        case .findLastCheckpoint(let e): return "find last checkpoint: \(e)"
        case .createSegmentReader(let e): return "create segment reader: \(e)"
        case .openCheckpoint(let e): return "open checkpoint: \(e)"
        case .decode(let kind, let e): return "decode \(kind): \(e)"
        case .flushRecords(let e): return "flush records: \(e)"
        case .readSegments(let e): return "read segments: \(e)"
        case .closeCheckpoint(let e): return "close checkpoint: \(e)"
        }
    }
}
