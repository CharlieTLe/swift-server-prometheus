//===----------------------------------------------------------------------===//
// Ported from tsdb/blockwriter.go @ v3.13.2 — `BlockWriter`, the smallest thing that writes a block.
//
// A `Head` with no WAL, plus a `LeveledCompactor`, plus one method. 132 lines upstream, and it is the entry
// point everything downstream of the TSDB uses to make a block out of samples: `promtool tsdb create-blocks-from`,
// the backfill path, and every downstream project that imports `tsdb` without wanting `db.go`.
//
// ## `blockSize` is used TWICE and clips NOTHING
//
//   * `opts.ChunkRange = w.blockSize` — the head's chunk range, so it decides where `appendPreprocessor` cuts;
//   * `[]int64{w.blockSize}` — the compactor's only range, which only `plan`/`selectDirs` read, and neither
//     runs here.
//
// `Flush` then writes `[head.MinTime(), head.MaxTime()+1)` — the head's WHOLE span. So a `BlockWriter` built
// with the default two-hour block size and fed five hours of samples produces ONE five-hour block, not three.
// Quirk 202. Splitting by range is `db.go`'s job.
//
// ## `Init(math.MinInt64)`, not `Init(0)`
//
// `minValidTime` of `MinInt64` means the head accepts a sample at any timestamp, which is what a backfill
// needs: the data being imported is arbitrarily old. A head initialised with 0 would reject every historical
// sample with `out of bounds`.
//
// ## An empty head flushes to nothing, and it does not error
//
// `MinTime()` on an uninitialised head is `math.MaxInt64` and `MaxTime()` is `math.MinInt64`, so `Flush`
// asks the compactor to write `[MaxInt64, MinInt64+1)` — a range whose start is greater than its end.
// `PopulateBlock` finds no series, `NumSamples` stays 0, and `Write` answers no ULID. `Flush` turns that into
// the ZERO ULID and upstream's comment says the caller has to notice: "No block was produced. Caller is
// responsible to check empty ulid.ULID based on its use case." Note also that `ErrNoSeriesAppended` is
// DECLARED in this file and never returned by it — `db.go`'s importer is what raises it. Quirk 203.
//
// ## The temporary chunk directory
//
// `initHead` calls `os.MkdirTemp(os.TempDir(), "head")` and `Close` removes it. `PromFS` (ADR-15) has no
// temp-directory notion, so the path is a parameter with a default; see exception 28. The lifecycle is
// otherwise upstream's, `Close`'s remove included.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromFS
public import PromHead
public import PromStorage

/// Go: `var ErrNoSeriesAppended = errors.New("no series appended, aborting")`.
///
/// Declared in `blockwriter.go` and never returned by it; `db.go`'s block importer is the only raiser. Ported
/// where upstream declares it, because that is where a reader will look for it. Quirk 203.
public enum BlockWriterError: Error, CustomStringConvertible, Equatable {
    case noSeriesAppended

    public var description: String {
        switch self {
        case .noSeriesAppended: return "no series appended, aborting"
        }
    }
}

/// Go: `BlockWriter`.
public final class BlockWriter {
    let fs: any PromFS
    let destinationDir: String
    let blockSize: Int64
    let chunkDir: String
    /// Go: `head`. Created by `initHead` and owned for the writer's whole life.
    public let head: Head
    /// The generator the compactor names its block with — see exception 27.
    let newULID: @Sendable () -> ULID
    let tombstoneWriter: (any TombstoneFileWriter)?

    /// Go: `NewBlockWriter(logger, dir, blockSize)`.
    ///
    /// Upstream's note is worth keeping verbatim, because it is the contract: *"the writer will not check if
    /// the target directory exists or contains anything at all. It is the caller's responsibility to ensure
    /// that the resulting blocks do not overlap etc."*
    ///
    /// `chunkDir` stands in for `os.MkdirTemp(os.TempDir(), "head")`; see the file header and exception 28.
    public init(
        fs: any PromFS, dir: String, blockSize: Int64, chunkDir: String = "head",
        newULID: (@Sendable () -> ULID)? = nil,
        tombstoneWriter: (any TombstoneFileWriter)? = nil
    ) throws {
        self.fs = fs
        self.destinationDir = dir
        self.blockSize = blockSize
        self.chunkDir = chunkDir
        self.newULID = newULID ?? { ULID.newRandom() }
        self.tombstoneWriter = tombstoneWriter

        // Go: `initHead`.
        let opts = HeadOptions.default()
        opts.chunkRange = blockSize
        opts.chunkDirRoot = chunkDir
        // `NewHead(nil, w.logger, nil, nil, opts, NewHeadStats())` — no registerer, and NO WAL. A
        // `BlockWriter` is a one-shot: nothing replays it, so nothing has to be logged.
        self.head = try Head(fs: fs, wal: nil, opts: opts, stats: HeadStats())
        try head.initialize(minValidTime: Int64.min)
    }

    /// Go: `Appender(ctx)`.
    public func appender() -> any Appender { head.appender() }

    /// Go: `Flush(ctx)` — "This is where actual block writing happens. After flush completes, no writes can
    /// be done."
    ///
    /// Returns nil where upstream returns the zero ULID: Swift has an optional and Go does not, and the
    /// caller's obligation ("check empty ulid.ULID based on its use case") is easier to discharge against
    /// one. The distinction upstream draws — no block written versus a block written — is preserved exactly.
    @discardableResult
    public func flush() throws -> ULID? {
        let mint = head.minTime()
        // Add +1 millisecond to block maxt because block intervals are half-open: [b.MinTime, b.MaxTime).
        // **`&+`, not `+`.** An uninitialised head's `MaxTime()` is `Int64.min`, which is fine, but a head
        // that has seen a sample at `Int64.max` wraps here exactly as `RangeHead.BlockMaxTime` does
        // (quirk 192) — and Swift's checked `+` would trap where Go wraps.
        let maxt = head.maxTime() &+ 1

        var options = LeveledCompactorOptions()
        options.newULID = newULID
        options.tombstoneWriter = tombstoneWriter
        // `NewLeveledCompactor(ctx, nil, w.logger, []int64{w.blockSize}, chunkenc.NewPool(), nil)`.
        let compactor = try LeveledCompactor(fs: fs, ranges: [blockSize], options: options)

        let ids = try compactor.write(
            dest: destinationDir, block: HeadBlockReader(head), mint: mint, maxt: maxt, base: nil)
        return ids.first
    }

    /// Go: `Close` — closes the head, and removes the temporary chunk directory in a `defer` so it goes even
    /// when the close fails.
    public func close() throws {
        defer {
            if fs.exists(chunkDir) {
                try? fs.remove(chunkDir)
            }
        }
        try head.close()
    }
}
