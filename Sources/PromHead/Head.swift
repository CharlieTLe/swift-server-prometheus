//===----------------------------------------------------------------------===//
// Ported from tsdb/head.go @ v3.13.2 — `HeadOptions`, `NewHead`, the Head's state and its accessors.
//
// This is the first slice with an EXPORTED entry point: `NewHead` and everything on `Head` that a caller can
// see. §7f(a)-(d) all had to be pinned through lifted probe packages because their types are unexported; this
// one the oracle drives directly, which is what §7f's scoping correction was about (HANDOFF §7f).
//
// ## What a fresh Head answers, and why the sentinels matter
//
// `resetInMemoryState` sets `minTime` to `MaxInt64` and `maxTime` to `MinInt64`, and **`MinTime()` being
// `MaxInt64` is how the Head reports "uninitialised"** — `initialized()` is literally that comparison. Which
// means `Meta()` on a fresh Head reports an INVERTED range (`MinTime > MaxTime`), and `compactable()` returns
// false through the `initialized` guard rather than through the arithmetic. Both are load-bearing: `db.go`
// asks `compactable()` on every tick.
//
// ## What is deliberately absent, and where each one goes
//
//   * **`Init`.** Its body IS the WAL replay — `loadMmappedChunks`, the chunk snapshot, the record loop — and
//     its deferred `gc()` needs `stripeSeries.gc`. That is §7h, and porting a hollow `Init` here would claim
//     the replay works. What `Init` does that is NOT replay is one line, `h.minValidTime.Store(...)`, and that
//     is `setMinValidTime`, which is here. Upstream's own doc says `Init` exists "so that it limits the
//     ingested samples to the head min valid time"; an appender against a Head with `minValidTime` already
//     set is the same thing minus the replay.
//   * **The metrics.** `headMetrics` is 200 lines of `prometheus.Registerer` plumbing and the registry is
//     Phase 9. Every counter increment upstream is a comment here, and `onChunkCreated`'s *observable* half —
//     the `incMmapReady` bookkeeping — is ported, because `mmapHeadChunks` reads it.
//   * **Exemplars.** `resetInMemoryState` builds a `CircularExemplarStorage`; `EnableExemplarStorage` defaults
//     false and §7f defers the whole feature, so `maxExemplars` is carried (because `NewHead` zeroes it) and
//     the storage is not.
//   * **Tombstones.** `MemTombstones` was unported when this file was written; §7h(a) added it, so
//     `Head.tombstones` and `Head.Tombstones()` are in `HeadGC.swift` with the rest of the deletion path.
//   * **Out-of-order** (`wbl`, `oooIso`, `minOOOTime`/`maxOOOTime`'s writers), **sharding**,
//     **`EnableFastStartup`**'s series-state goroutine, the WAL-expiry map, the cardinality cache, and the
//     pools. Each is named in §7f's "what to leave out" list.
//   * **The locks.** Same reasoning as `Isolation.swift` and `StripeSeries.swift`: the port has no
//     concurrency, and every `atomic` here is a plain field. `updateMinMaxTime`'s compare-and-swap loops
//     collapse to two comparisons, which is what they compute single-threaded.
//===----------------------------------------------------------------------===//

public import PromBlock
public import PromChunkEnc
public import PromChunks
public import PromFS
public import PromIndex
public import PromLabels
public import PromStorage
public import PromTombstones
public import PromWAL

/// Go: `DefaultOutOfOrderCapMax` — the default maximum size of an in-memory out-of-order chunk.
public let defaultOutOfOrderCapMax: Int64 = 32
/// Go: `DefaultSamplesPerChunk`.
public let defaultSamplesPerChunk = 120
/// Go: `DefaultBlockDuration` (db.go) — two hours in milliseconds, and the default `ChunkRange`.
public let defaultBlockDuration: Int64 = 2 * 60 * 60 * 1000
/// Go: `defaultIsolationDisabled` — **false**, so isolation is ON unless a caller turns it off.
public let defaultIsolationDisabled = false

/// Go: `head.go`'s error vocabulary, and `NewHead`'s two validation failures.
///
/// `ErrInvalidSample`, `ErrInvalidExemplar` and `ErrAppenderClosed` are declared here with the rest because
/// they are `head.go`'s package-level vars; their throwers arrive with `headAppender`.
public enum HeadError: Error, CustomStringConvertible, Equatable {
    /// Go: `ErrInvalidSample`.
    case invalidSample
    /// Go: `ErrInvalidExemplar`.
    case invalidExemplar
    /// Go: `ErrAppenderClosed`.
    case appenderClosed
    /// Go: `fmt.Errorf("OOOCapMax of %d is invalid. must be > 0 and <= 255", capMax)`.
    case invalidOOOCapMax(Int64)
    /// Go: `fmt.Errorf("invalid chunk range %d", opts.ChunkRange)`.
    case invalidChunkRange(Int64)

    public var description: String {
        switch self {
        case .invalidSample: return "invalid sample"
        case .invalidExemplar: return "invalid exemplar"
        case .appenderClosed: return "appender closed"
        case .invalidOOOCapMax(let c):
            return "OOOCapMax of \(c) is invalid. must be > 0 and <= 255"
        case .invalidChunkRange(let r): return "invalid chunk range \(r)"
        }
    }
}

/// Go: `HeadOptions`.
///
/// A CLASS, not a struct, because `NewHead` MUTATES the options it is given — it clamps a negative
/// `OutOfOrderTimeWindow` to 0, zeroes `MaxExemplars` when exemplar storage is off, fills in a nil
/// `SeriesCallback` and a nil `ChunkPool`, and replaces a non-positive `WALReplayConcurrency`. `db.go` keeps a
/// pointer to the same object and reads those fields later (`ApplyConfig`), so the writes are visible to the
/// caller and a value type would lose them.
///
/// The `atomic` fields upstream are the runtime-reloadable ones; they are plain here for the reason in the file
/// header, but which ones they are is worth keeping visible, so each says so.
public final class HeadOptions {
    /// Go: `MaxExemplars` (atomic, runtime reloadable).
    public var maxExemplars: Int64 = 0
    /// Go: `OutOfOrderTimeWindow` (atomic, runtime reloadable). 0 disables out-of-order ingestion.
    public var outOfOrderTimeWindow: Int64 = 0
    /// Go: `OutOfOrderCapMax` (atomic, runtime reloadable).
    public var outOfOrderCapMax: Int64 = defaultOutOfOrderCapMax
    /// Go: `EnableSTStorage` (atomic) — the `st-storage` feature flag, which decides whether a start timestamp
    /// is stored per sample and therefore whether XOR and XOR2 chunks may be mixed.
    public var enableSTStorage = false
    /// Go: `FloatChunkEncoding` (atomic) — the encoding applied to NEW float chunks. Upstream's comment is
    /// explicit that the zero value (`EncNone`) is not a valid sentinel and that `DefaultHeadOptions` must be
    /// used; the port initialises it to `.xor` for the same reason.
    public var floatChunkEncoding: Encoding = .xor

    public var chunkRange: Int64 = defaultBlockDuration
    /// Go: `ChunkDirRoot` — the PARENT of the chunks directory. `mmappedChunksDir` appends `chunks_head`.
    public var chunkDirRoot: String = ""
    public var chunkWriteBufferSize: Int = defaultWriteBufferSize
    public var chunkWriteQueueSize: Int = 0
    public var samplesPerChunk: Int = defaultSamplesPerChunk
    /// Go: `StripeSize` — upstream's comment requires a power of two and nothing validates it; `StripeSeries`
    /// has the `precondition` (§7f(b)).
    public var stripeSize: Int = defaultStripeSize
    public var seriesCallback: (any SeriesLifecycleCallback)? = NoopSeriesLifecycleCallback()
    public var enableExemplarStorage = false
    public var enableMemorySnapshotOnShutdown = false
    public var isolationDisabled = defaultIsolationDisabled
    /// Go: `WALReplayConcurrency` — `GOMAXPROCS(0)` by default, and `NewHead` replaces a value <= 0. The port
    /// replays serially, so this only decides what `EnsureOrder` is told; see `Init`'s deferral.
    public var walReplayConcurrency: Int = 0
    public var enableSharding = false
    public var enableSTAsZeroSample = false
    public var enableMetadataWALRecords = false
    public var enableFastStartup = false

    /// The `ChunkPool` is deliberately absent: PORTING.md exception 4 drops `sync.Pool`, and `NewHead`'s
    /// "fill in a nil pool" branch has nothing to fill.
    public init() {}

    /// Go: `DefaultHeadOptions`.
    ///
    /// The two `Store` calls at the end of upstream's constructor are why this exists as a factory rather than
    /// as the struct's zero value: `OutOfOrderCapMax` and `FloatChunkEncoding` are atomics that cannot be set
    /// in a literal. The port's defaults are on the properties, so this is the same object.
    public static func `default`() -> HeadOptions { HeadOptions() }

    /// Go: `UseXOR2FloatEncoding` — whether new float chunks use XOR2. This is the switch quirk 36 was waiting
    /// for: `promqltest` sets `EncXOR2` because start timestamps ride on it.
    public func useXOR2FloatEncoding() -> Bool { floatChunkEncoding == .xor2 }
}

/// Go: `mmappedChunksDir`.
public func mmappedChunksDir(_ dir: String) -> String {
    dir.isEmpty ? "chunks_head" : "\(dir)/chunks_head"
}

/// Go: `HeadStats`.
public final class HeadStats {
    public var walReplayStatus = WALReplayStatus()
    public init() {}
}

/// Go: `WALReplayStatus`. Written by `startWALReplayStatus`/`updateWALReplayStatusRead` during replay (§7h)
/// and read by the `/status/tsdb` endpoint (Phase 9).
public final class WALReplayStatus {
    public var min = 0
    public var max = 0
    public var current = 0
    public init() {}

    /// Go: `GetWALReplayStatus` — a locked COPY upstream, so callers cannot see a torn triple.
    public func get() -> (min: Int, max: Int, current: Int) { (min, max, current) }
}

/// Go: `headULID` — `ulid.MustParse("0000000000XXXXXXXXXXXXHEAD")`.
///
/// Not a timestamp: it is a hand-written sentinel that reads as "HEAD" in Crockford base32, so a `BlockMeta`
/// coming from the Head is recognisable in logs and in a compaction's `sources`. `RangeHead` and `StaleHead`
/// have their own (§7g).
public let headULID: ULID = {
    guard let u = ULID("0000000000XXXXXXXXXXXXHEAD") else {
        preconditionFailure("headULID is a compile-time constant upstream and must parse")
    }
    return u
}()

/// Go: `Head` — reads and writes of time series data within a time window.
///
/// See the file header for the fields that are deliberately absent. The `atomic` types upstream are plain
/// properties here.
public final class Head {
    /// Go: `chunkRange` — a copy of `opts.ChunkRange`, atomic because `ApplyConfig` can change it.
    public private(set) var chunkRange: Int64 = 0
    /// Go: `numSeries`.
    var numSeries: UInt64 = 0
    /// Go: `numStaleSeries`.
    var numStaleSeries: UInt64 = 0
    /// Go: `minTime`/`maxTime`. **`minTime == MaxInt64` means uninitialised**, so the two are stored in that
    /// order and upstream's comment warns that `maxTime` must be updated first.
    var minTimeValue: Int64 = Int64.max
    var maxTimeValue: Int64 = Int64.min
    /// Go: `minOOOTime`/`maxOOOTime`. Present because `Meta` and the OOO accessors read them; nothing in this
    /// slice writes them, since out-of-order ingestion is Phase 10.
    var minOOOTimeValue: Int64 = Int64.max
    var maxOOOTimeValue: Int64 = Int64.min
    /// Go: `minValidTime` — the lowest timestamp the head will accept. Set by `Init` and `SetMinValidTime`,
    /// and it must not be below the maxt of the last persisted block.
    var minValidTimeValue: Int64 = 0
    /// Go: `lastWALTruncationTime` / `lastMemoryTruncationTime`.
    var lastWALTruncationTime: Int64 = Int64.min
    var lastMemoryTruncationTime: Int64 = Int64.min
    /// Go: `lastSeriesID` — the source of `HeadSeriesRef`s, and it is PRE-incremented, so the first series is
    /// 1 and a ref of 0 means "allocate one" in `getOrCreateWithOptionalID`.
    var lastSeriesID: UInt64 = 0

    public let opts: HeadOptions
    /// Go: `wal` — may be nil, and `NewHead` accepts that: a Head with no WAL simply does not log.
    public let wal: WL?
    /// The filesystem the Head was built with. Upstream reaches the WAL's directory through `os` directly;
    /// `PromFS` is an object, so the Head keeps the one it was handed — `Init` opens WAL segments itself
    /// (§7h(b)) and `WL` keeps its own copy private.
    public let fsStorage: any PromFS

    /// Go: `series` — all series addressable by ID or by label hash.
    public private(set) var series: StripeSeries
    /// Go: `postings` — built UNORDERED, because replay adds refs out of order and `Init` calls
    /// `EnsureOrder` afterwards (§7e ported `newUnordered` for exactly this).
    public private(set) var postings: MemPostings
    /// Go: `tombstones` — the Head's in-memory deletion intervals. `MemTombstones` landed with §7h(a); before
    /// that the field could not exist, which is what the file header's tombstone bullet recorded.
    public private(set) var tombstones: MemTombstones
    /// Go: `iso`.
    public private(set) var iso: Isolation
    /// Go: `chunkDiskMapper`.
    public let chunkDiskMapper: ChunkDiskMapper
    /// Go: `stats`.
    public let stats: HeadStats

    /// Go: `closed`, guarded by `closedMtx`. **Nothing reads it yet in the port**: upstream's only reader is
    /// `head_read.go:452`, where a `headChunkReader` refuses to serve a closed Head. Carried rather than
    /// dropped because §7g is the slice that adds that reader, and a control that removes this assignment
    /// therefore survives today — argued in `Scripts/controls-head.sh`.
    var closed = false

    /// Go: `NewHead`.
    ///
    /// The validation order is upstream's and the two error strings are byte-exact. Note what it does to the
    /// options object it is handed — the mutations are visible to the caller, which is why `HeadOptions` is a
    /// class here (see its doc comment):
    ///
    ///   * a negative `OutOfOrderTimeWindow` is clamped to 0;
    ///   * `MaxExemplars` is zeroed when exemplar storage is off;
    ///   * a nil `SeriesCallback` becomes the noop;
    ///   * a `WALReplayConcurrency <= 0` becomes `GOMAXPROCS(0)`.
    ///
    /// `OutOfOrderCapMax` is validated **before** `ChunkRange` and the check is `<= 0 || > 255`, so a Head
    /// with both invalid reports the OOO one.
    ///
    /// Two of Go's parameters are absent: `prometheus.Registerer` (the metrics are Phase 9, see the file
    /// header) and `*slog.Logger` (nothing here logs; upstream substitutes a nop logger for nil, which is
    /// what a missing parameter is). `wbl` is absent with the rest of out-of-order.
    public init(fs: any PromFS, wal: WL? = nil, opts: HeadOptions, stats: HeadStats? = nil) throws {
        if opts.outOfOrderTimeWindow < 0 {
            opts.outOfOrderTimeWindow = 0
        }

        // The time window is runtime-settable, so the cap must be valid even when OOO is off.
        let capMax = opts.outOfOrderCapMax
        if capMax <= 0 || capMax > 255 {
            throw HeadError.invalidOOOCapMax(capMax)
        }

        if opts.chunkRange < 1 {
            throw HeadError.invalidChunkRange(opts.chunkRange)
        }
        if opts.seriesCallback == nil {
            opts.seriesCallback = NoopSeriesLifecycleCallback()
        }

        if !opts.enableExemplarStorage {
            opts.maxExemplars = 0
        }

        self.opts = opts
        self.wal = wal
        self.fsStorage = fs
        self.stats = stats ?? HeadStats()

        // resetInMemoryState, inlined because Swift cannot call a method before the stored properties are
        // initialised. `resetInMemoryState()` below is the same code and is what `Init`'s snapshot-failure
        // path calls a second time.
        self.series = StripeSeries(
            stripeSize: opts.stripeSize,
            seriesCallback: opts.seriesCallback ?? NoopSeriesLifecycleCallback())
        self.postings = MemPostings.newUnordered()
        self.tombstones = MemTombstones()
        self.iso = Isolation(disabled: opts.isolationDisabled)
        self.chunkRange = opts.chunkRange

        if opts.walReplayConcurrency <= 0 {
            opts.walReplayConcurrency = Head.defaultWALReplayConcurrency
        }

        self.chunkDiskMapper = try ChunkDiskMapper(
            fs: fs, dir: mmappedChunksDir(opts.chunkDirRoot),
            writeBufferSize: opts.chunkWriteBufferSize,
            writeQueueSize: opts.chunkWriteQueueSize)
    }

    /// Go: `defaultWALReplayConcurrency = runtime.GOMAXPROCS(0)`.
    ///
    /// **Not read from the machine.** It reaches only `EnsureOrder`'s worker count, which the port replays
    /// serially, and a value that varies with the host would make `HeadOptions` unpinnable. Fixed at 1 and
    /// recorded rather than being a silent difference.
    public static let defaultWALReplayConcurrency = 1

    /// Go: `resetInMemoryState`.
    ///
    /// Upstream flushes the existing series through `iterForDeletion` first, purely to fire the lifecycle
    /// callbacks and the `seriesRemoved` metric; that walk waits for `stripeSeries.gc` (§7g).
    public func resetInMemoryState() {
        series = StripeSeries(
            stripeSize: opts.stripeSize,
            seriesCallback: opts.seriesCallback ?? NoopSeriesLifecycleCallback())
        iso = Isolation(disabled: opts.isolationDisabled)
        numSeries = 0
        postings = MemPostings.newUnordered()
        tombstones = MemTombstones()
        chunkRange = opts.chunkRange
        minTimeValue = Int64.max
        maxTimeValue = Int64.min
        minOOOTimeValue = Int64.max
        maxOOOTimeValue = Int64.min
        lastWALTruncationTime = Int64.min
        lastMemoryTruncationTime = Int64.min
    }

    // MARK: - The time window

    /// Go: `MinTime` — the lowest visible timestamp. `MaxInt64` means the head is UNINITIALISED.
    public func minTime() -> Int64 { minTimeValue }
    /// Go: `MaxTime`.
    public func maxTime() -> Int64 { maxTimeValue }
    /// Go: `MinOOOTime`.
    public func minOOOTime() -> Int64 { minOOOTimeValue }
    /// Go: `MaxOOOTime`.
    public func maxOOOTime() -> Int64 { maxOOOTimeValue }

    /// Go: `updateMinMaxTime` — two compare-and-swap loops, which single-threaded are two comparisons.
    ///
    /// Only ever widens the window, and the two halves are independent: a commit whose samples are all older
    /// than `maxTime` moves `minTime` alone.
    public func updateMinMaxTime(mint: Int64, maxt: Int64) {
        if mint < minTimeValue {
            minTimeValue = mint
        }
        if maxt > maxTimeValue {
            maxTimeValue = maxt
        }
    }

    /// Go: `updateMinOOOMaxOOOTime`. Its callers are the OOO append path (Phase 10); it is here because the
    /// OOO accessors are, and leaving it out would make the pair asymmetric.
    public func updateMinOOOMaxOOOTime(mint: Int64, maxt: Int64) {
        if mint < minOOOTimeValue {
            minOOOTimeValue = mint
        }
        if maxt > maxOOOTimeValue {
            maxOOOTimeValue = maxt
        }
    }

    /// Go: `SetMinValidTime`.
    public func setMinValidTime(_ minValidTime: Int64) { minValidTimeValue = minValidTime }

    /// Go: `h.minValidTime.Load()`, exposed because `headAppender` needs it and `Init` is deferred.
    public func minValidTime() -> Int64 { minValidTimeValue }

    /// Go: `appendableMinValidTime` (head_append.go) — the oldest timestamp an appender will take.
    ///
    /// The `max` of two boundaries with different jobs, and upstream's comments name both: `maxTime -
    /// chunkRange/2` keeps samples out of the compaction window so appending and compacting can race safely,
    /// and `minValidTime` stops one block's timeframe overlapping the next. Note the first is derived from
    /// `maxTime`, so it MOVES as samples arrive.
    public func appendableMinValidTime() -> Int64 {
        let cwEnd = maxTime() - chunkRange / 2
        return max(cwEnd, minValidTimeValue)
    }

    /// Go: `AppendableMinValidTime` — and the `false` means "the head is not initialised, so the minimum is
    /// not known yet", which is a different answer from a minimum of 0.
    public func appendableMinValidTimeIfInitialized() -> (Int64, Bool) {
        if !initialized() {
            return (0, false)
        }
        return (appendableMinValidTime(), true)
    }

    /// Go: `initialized` — "the head has a MinTime set". Unexported upstream; `db.go` reaches the same fact
    /// through `Meta()`, and `Truncate` branches on it.
    public func initialized() -> Bool { minTime() != Int64.max }

    /// Go: `compactable` — the head's range is 1.5 chunk ranges wide, the half acting as a buffer for the
    /// appendable window. Note the integer arithmetic: `chunkRange/2*3`, which divides FIRST, so an odd chunk
    /// range loses a millisecond.
    public func compactable() -> Bool {
        if !initialized() {
            return false
        }
        return maxTime() - minTime() > chunkRange / 2 * 3
    }

    /// Go: `OverlapsClosedInterval`.
    public func overlapsClosedInterval(mint: Int64, maxt: Int64) -> Bool {
        minTime() <= maxt && mint <= maxTime()
    }

    // MARK: - Identity and size

    /// Go: `NumSeries`.
    public func seriesCount() -> UInt64 { numSeries }
    /// Go: `NumStaleSeries`.
    public func staleSeriesCount() -> UInt64 { numStaleSeries }

    /// Go: `Meta` — "The head is dynamic so will return dynamic results."
    ///
    /// On a fresh head this reports `MinTime == MaxInt64` and `MaxTime == MinInt64`, an inverted range. That is
    /// upstream's answer and callers are expected to check `initialized()`.
    public func meta() -> BlockMeta {
        var m = BlockMeta(ulid: headULID, minTime: minTime(), maxTime: maxTime())
        m.stats.numSeries = numSeries
        return m
    }

    /// Go: `String()`, which exists so a stringified Head in an error is not a struct dump.
    public var description: String { "head" }

    /// Go: `Size` — the WAL plus the WBL plus the chunk files. Every error is DISCARDED upstream (`walSize, _
    /// = h.wal.Size()`), so a failing stat reads as a zero-sized WAL rather than as an error.
    public func size() -> Int64 {
        var walSize: Int64 = 0
        if let wal {
            walSize = (try? wal.size()) ?? 0
        }
        let cdmSize = (try? chunkDiskMapper.size()) ?? 0
        return walSize + cdmSize
    }

    // MARK: - Series creation

    /// Go: `getOrCreate` — the hash lookup first, then allocation.
    public func getOrCreate(
        hash: UInt64, labels lset: Labels, pendingCommit: Bool
    ) throws -> (series: MemSeries, created: Bool) {
        if let s = series.getByHash(hash: hash, labels: lset) {
            return (s, false)
        }
        return try getOrCreateWithOptionalID(
            id: HeadSeriesRef(rawValue: 0), hash: hash, labels: lset, pendingCommit: pendingCommit)
    }

    /// Go: `getOrCreateWithOptionalID` — "If id is zero, one will be allocated."
    ///
    /// Three things in order, and each is observable: the lifecycle callback can REFUSE the series (and then
    /// no ID is consumed, because the allocation happens after), the ID is pre-incremented so the first series
    /// is 1, and **an ID is consumed even when the series turns out to exist** — upstream's comment says so:
    /// *"Note this id is wasted in the case where a concurrent operation creates the same series first."*
    ///
    /// `shardHash` is `labels.StableHash` only when `EnableSharding` is on, and 0 otherwise, which is why
    /// `MemSeries.shardHash` is normally 0.
    public func getOrCreateWithOptionalID(
        id: HeadSeriesRef, hash: UInt64, labels lset: Labels, pendingCommit: Bool
    ) throws -> (series: MemSeries, created: Bool) {
        if let callback = opts.seriesCallback {
            try callback.preCreation(lset)
        }
        var id = id
        if id.rawValue == 0 {
            lastSeriesID += 1
            id = HeadSeriesRef(rawValue: lastSeriesID)
        }

        var shardHash: UInt64 = 0
        if opts.enableSharding {
            shardHash = lset.stableHash()
        }
        let optimisticallyCreatedSeries = MemSeries(
            labels: lset, ref: id, shardHash: shardHash,
            isolationDisabled: opts.isolationDisabled, pendingCommit: pendingCommit)

        let (s, created) = series.setUnlessAlreadySet(
            hash: hash, labels: lset, optimisticallyCreatedSeries)
        if !created {
            return (s, false)
        }

        numSeries += 1

        postings.add(id: SeriesRef(rawValue: id.rawValue), labels: lset)

        // Adding the series to the postings is what marks it as created: any later call to this or to a read
        // method would find it.
        series.postCreation(labels: lset)

        return (s, true)
    }

    /// Go: `onChunkCreated` — the metrics half is absent (Phase 9); the `mmapReady` half is not.
    ///
    /// The condition is a TRANSITION, not a threshold: `prevHeadChunkCount < 2 && headChunkCount == 2`, so a
    /// stripe's counter is bumped exactly once per series no matter how long the chunk list grows.
    public func onChunkCreated(series s: MemSeries, prevHeadChunkCount: UInt32) {
        if prevHeadChunkCount < 2 && s.headChunkCount == 2 {
            series.incMmapReady(s.ref)
        }
    }

    /// Go: `mmapHeadChunks` — m-map every series with more than one head chunk.
    ///
    /// The `mmapReady` counter is a per-stripe SHORTCUT, not the condition: a stripe whose counter is zero is
    /// skipped wholesale, and within a stripe each series is checked again (`headChunkCount < 2`). Both tests
    /// are needed — the counter can be stale high, because `truncateChunksBefore` reduces a series' chunk
    /// count without touching it.
    @discardableResult
    public func mmapHeadChunks() -> Int {
        var count = 0
        for i in 0..<series.size {
            if series.mmapReady[i] == 0 {
                continue  // No series in this stripe needs m-mapping.
            }
            for (_, s) in series.series[i] {
                if s.headChunkCount < 2 {  // 0 or 1 head chunks: nothing to m-map.
                    continue
                }
                let n = s.mmapChunks(chunkDiskMapper: chunkDiskMapper)
                if n > 0 {
                    count += n
                    series.decMmapReady(s.ref)
                }
            }
        }
        return count
    }

    // MARK: - Shutdown

    /// Go: `Close` — m-map all but the last chunk, then close the mapper and the WAL, JOINING the errors.
    ///
    /// Upstream m-maps *before* closing "in case we're performing snapshot since that only takes samples from
    /// most recent head chunk", and it does not stop on the first failure: `errors.Join` means a WAL close is
    /// attempted even after the mapper's failed. The port throws the first error but only after doing every
    /// step, which is the observable part of that.
    public func close() throws {
        closed = true

        mmapHeadChunks()

        var first: (any Error)?
        do { try chunkDiskMapper.close() } catch { first = first ?? error }
        if let wal {
            do { try wal.close() } catch { first = first ?? error }
        }
        if let first { throw first }
    }
}
