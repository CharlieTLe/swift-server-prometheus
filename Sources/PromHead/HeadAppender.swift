//===----------------------------------------------------------------------===//
// Ported from tsdb/head_append.go @ v3.13.2 — the FLOAT append path, end to end.
//
// This is the slice that makes the Head observable: `Appender()` is exported, and a committed sample shows up
// in three independent places — the accessors (`MinTime`/`MaxTime`/`NumSeries`), the **WAL bytes**, and the
// **chunk files**. Everything §7f(a)-(e) landed is wired together here.
//
// ## The two appenders, and why there are two
//
// `Head.Appender()` hands back an `InitAppender` while the head is UNINITIALISED, and a `HeadAppender`
// afterwards. The init appender exists for one reason: a fresh head has no time window, so the first sample's
// timestamp has to become that window before an appender can decide what is in bounds. `initTime` does that,
// and then the init appender **replaces itself** with a real appender and forwards every later call.
//
// `initTime` writes `maxTime` BEFORE `minTime`, and upstream's comment explains why in concurrency terms:
// `initialized()` keys off `minTime`, so setting `minTime` first would let another goroutine see an
// initialised head whose `maxTime` is still `MinInt64` — and `appendableMinValidTime` would then underflow and
// reject in-range samples. The port has no concurrency, but the ORDER is kept because it is the documented
// contract of the two fields.
//
// ## What `Append` decides, in order
//
//  1. **The fast-fail**: with out-of-order disabled, `t < minValidTime` is `ErrOutOfBounds` immediately, before
//     the series is even looked up. So a sample far in the past does not create a series.
//  2. **The series**: by ref if one was given, else `getOrCreate` — which is where empty labels are dropped and
//     an empty or duplicate-name label set is rejected with `ErrInvalidSample`.
//  3. **`appendable`**: the sample's verdict against the series' current state (§7f(d)).
//  4. **The batch**: `getCurrentBatch` appends the sample to a `RefSample` list, paired with its series.
//
// **Nothing is written to the series in step 4.** `Append` only collects; `Commit` is what appends to chunks,
// and `appendable` is therefore consulted TWICE for every sample — once optimistically in `Append` and again
// in `commitFloats`, where the answer can differ because another appender may have committed in between.
//
// ## Commit's order is load-bearing
//
// `log()` runs FIRST and a WAL failure rolls the whole append back — so a sample is never in the head unless
// it is in the WAL. Then, per batch, floats before histograms before metadata, because the staleness-marker
// conversion in `commitFloats` appends into the *same* batch's histogram list and depends on being read after.
//
// ## What is deliberately absent, and where each one goes
//
//   * **Histograms, exemplars and metadata.** `commitHistograms`, `commitFloatHistograms`, `commitMetadata`,
//     `AppendHistogram`, `AppendExemplar`, `UpdateMetadata`. The `sampleType` machinery that batches them IS
//     ported, because `getCurrentBatch`'s float behaviour is defined by it, and `Append`'s stale-NaN redirect
//     is a `guard` that names the deferral rather than a silent fall-through.
//   * **Out-of-order.** `commitFloats`' `oooSample` arm, `insert`, the WBL records, `collectOOORecords` and the
//     m-map markers. `OutOfOrderTimeWindow` defaults to 0, so `appendable` never answers `isOOO` — but the
//     *rejection* it produces when OOO is enabled is reachable and IS pinned (`ErrTooOldSample`).
//   * **The pools.** PORTING.md exception 4. `appendBatch.close` returns nine slices to nine pools; the port's
//     batches are just dropped.
//   * **`writeNotified`.** A `db.go` hook (§7j).
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromLabels
public import PromModel
public import PromRecord
public import PromStorage

/// Go: `sampleType` — the types a batch has to keep apart, "defined by everything that goes into a different
/// WAL record type or into a different chunk encoding".
///
/// The histogram cases are ported and unreachable in this slice: nothing writes them into `typesInBatch`
/// because the histogram append methods are deferred. They are here because `getCurrentBatch`'s decision table
/// is written in terms of them, and a table with the rows removed would be a different function.
public enum SampleType: UInt8, Sendable {
    /// Go: `stNone` — "the sample type does not matter".
    case none = 0
    /// Go: `stFloat` — all simple floats. Goes to `floats`.
    case float = 1
    case histogram = 2
    case customBucketHistogram = 3
    case floatHistogram = 4
    case customBucketFloatHistogram = 5
}

/// Go: `appendBatch` — a partition of the appended data in which every series holds only ONE sample type.
///
/// Only the float halves are populated in this slice; the others exist because `commitFloats`' staleness
/// conversion appends into `histograms`/`floatHistograms` of the same batch (deferred, see the file header).
public final class AppendBatch {
    /// Go: `floats` — the collected samples, in append order.
    public var floats: [RefSample] = []
    /// Go: `floatSeries` — the series for each sample, by index. The same series may appear more than once.
    public var floatSeries: [MemSeries] = []

    public init() {}
}

/// Go: `appenderCommitContext` — the counters and bounds `commitFloats` accumulates.
///
/// The float half only. The counters are not just metrics: `floatsAppended` is decremented for a duplicate
/// sample, which is how "silently dropped" is distinguished from "appended", and the two bounds become
/// `updateMinMaxTime`'s arguments.
struct AppenderCommitContext {
    var floatsAppended = 0
    var floatOOORejected = 0
    var floatTooOldRejected = 0
    var floatOOBRejected = 0
    var inOrderMint = Int64.max
    var inOrderMaxt = Int64.min
    var appendChunkOpts: ChunkOpts
}

/// Go: `handleAppendableError` — one decrement and one classification.
///
/// Note the `default`: an error that is none of the three still decrements `appended`, so an unexpected error
/// reduces the count without incrementing any rejection counter.
func handleAppendableError(
    _ error: any Error, appended: inout Int, oooRejected: inout Int, oobRejected: inout Int,
    tooOldRejected: inout Int
) {
    if let e = error as? StorageError {
        switch e {
        case .outOfOrderSample:
            appended -= 1
            oooRejected += 1
            return
        case .outOfBounds:
            appended -= 1
            oobRejected += 1
            return
        case .tooOldSample:
            appended -= 1
            tooOldRejected += 1
            return
        default:
            break
        }
    }
    appended -= 1
}

/// Go: `head.go`'s `getOrCreate` validation failures, which wrap `ErrInvalidSample`.
///
/// Two exact messages, and both are `%w`-wrapped upstream so `errors.Is(err, ErrInvalidSample)` holds — which
/// `scrape` relies on to classify a sample as unappendable rather than as a storage failure.
public enum AppenderError: Error, CustomStringConvertible, Equatable {
    /// Go: `fmt.Errorf("empty labelset: %w", ErrInvalidSample)`.
    case emptyLabelset
    /// Go: `fmt.Errorf("label name \"%s\" is not unique: %w", l, ErrInvalidSample)`.
    case duplicateLabelName(String)

    public var description: String {
        switch self {
        case .emptyLabelset:
            return "empty labelset: \(HeadError.invalidSample)"
        case .duplicateLabelName(let l):
            return "label name \"\(l)\" is not unique: \(HeadError.invalidSample)"
        }
    }
}

// MARK: - The Head's two entry points

extension Head {

    /// Go: `Head.Appender(context.Context)`.
    ///
    /// The context is accepted and ignored upstream too. The branch is on `initialized()`: an uninitialised
    /// head has no time window, so the first sample has to establish one.
    public func appender() -> any Appender {
        if !initialized() {
            return InitAppender(head: self)
        }
        return headAppender()
    }

    /// Go: `Head.appender()` — the real one.
    ///
    /// Every appender takes an `appendID` from the isolation state, and the `cleanupAppendIDsBelow` watermark
    /// that comes with it is applied to each series it touches at commit time. `headMaxt` and `oooTimeWindow`
    /// are read ONCE here rather than per sample, which is why a concurrent commit is invisible to an
    /// appender's own `appendable` checks.
    func headAppender() -> HeadAppender {
        let minValid = appendableMinValidTime()
        let (appendID, cleanupAppendIDsBelow) = iso.newAppendID(minTime: minValid)
        return HeadAppender(
            head: self, minValidTime: minValid, headMaxt: maxTime(),
            oooTimeWindow: opts.outOfOrderTimeWindow, appendID: appendID,
            cleanupAppendIDsBelow: cleanupAppendIDsBelow,
            storeST: opts.enableSTStorage, useXOR2: opts.useXOR2FloatEncoding())
    }

    /// Go: `initTime` — give a completely fresh head its first timestamp.
    ///
    /// **`maxTime` is written before `minTime`, and the order is the contract**: `initialized()` reads
    /// `minTime`, so the reverse order would publish an initialised head with `maxTime` still at `MinInt64`,
    /// and `appendableMinValidTime`'s `maxTime - chunkRange/2` would underflow. Upstream implements this with
    /// two compare-and-swaps plus an anti-deadlock spin for the loser of the race; single-threaded there is no
    /// race, and the CAS semantics reduce to "only if still the sentinel".
    func initTime(_ t: Int64) {
        guard maxTimeValue == Int64.min else { return }
        maxTimeValue = t
        if minTimeValue == Int64.max {
            minTimeValue = t
        }
    }

    /// Go: `h.numStaleSeries.Inc()` / `.Dec()`, reached from `commitFloats`' staleness transitions.
    func incNumStaleSeries() { numStaleSeries += 1 }
    func decNumStaleSeries() { numStaleSeries -= 1 }
}

// MARK: - InitAppender

/// Go: `initAppender` — the appender a fresh head hands out.
///
/// It holds no samples of its own: the first `append` establishes the head's time window and then builds the
/// real appender, which every later call forwards to. `Commit`/`Rollback` before any append are no-ops (they
/// only decrement the active-appender metric upstream), which is what makes an empty scrape harmless.
public final class InitAppender: StartTimestampAppender, GetRef {
    let head: Head
    var app: (any Appender)?

    init(head: Head) {
        self.head = head
    }

    public func setOptions(_ opts: AppendOptions?) {
        app?.setOptions(opts)
    }

    @discardableResult
    public func append(ref: SeriesRef, labels lset: Labels, t: Int64, v: Double) throws -> SeriesRef {
        if let app {
            return try app.append(ref: ref, labels: lset, t: t, v: v)
        }
        head.initTime(t)
        let a = head.headAppender()
        app = a
        return try a.append(ref: ref, labels: lset, t: t, v: v)
    }

    /// Go: `initAppender.AppendSTZeroSample` — note it initialises the head from `t`, the sample's own
    /// timestamp, not from `st`.
    public func appendSTZeroSample(
        ref: SeriesRef, labels lset: Labels, t: Int64, st: Int64
    ) -> (ref: SeriesRef, error: (any Error)?) {
        if let app = app as? any StartTimestampAppender {
            return app.appendSTZeroSample(ref: ref, labels: lset, t: t, st: st)
        }
        head.initTime(t)
        let a = head.headAppender()
        app = a
        return a.appendSTZeroSample(ref: ref, labels: lset, t: t, st: st)
    }

    /// Go: `GetRef` — note it asserts on `a.app` WITHOUT a nil check upstream, so a `GetRef` before the first
    /// append reaches a nil interface, the assertion fails, and it answers `(0, EmptyLabels())`. The port's
    /// optional chaining gives the same answer for the same reason.
    public func getRef(labels lset: Labels, hash: UInt64) -> (SeriesRef, Labels) {
        if let g = app as? any GetRef {
            return g.getRef(labels: lset, hash: hash)
        }
        return (SeriesRef(rawValue: 0), Labels())
    }

    public func commit() throws {
        guard let app else { return }
        try app.commit()
    }

    public func rollback() throws {
        guard let app else { return }
        try app.rollback()
    }
}

// MARK: - HeadAppender

/// Go: `headAppender` (with `headAppenderBase` folded in — the split exists upstream so `headAppenderV2` can
/// share the base, and `head_append_v2.go` is not ported).
public final class HeadAppender: StartTimestampAppender, GetRef {
    let head: Head
    /// Go: `minValidTime` — no samples below this are allowed.
    let minValidTime: Int64
    /// Go: `headMaxt` — tracked here "to not take the lock for every sample appended", so it is a SNAPSHOT.
    let headMaxt: Int64
    /// Go: `oooTimeWindow` — read once for the whole append.
    let oooTimeWindow: Int64

    /// Go: `seriesRefs`/`series` — the series this appender CREATED, which are what the WAL's series record
    /// carries and what `unmarkCreatedSeriesAsPendingCommit` walks.
    var seriesRefs: [RefSeries] = []
    var createdSeries: [MemSeries] = []
    /// Go: `batches`. "In regular cases, there should be only one of these."
    var batches: [AppendBatch] = []
    /// Go: `typesInBatch` — which single sample type each series holds in the most recent batch. Floats are
    /// implicit and deliberately NOT recorded, which is why a float-only append never cuts a second batch.
    var typesInBatch: [HeadSeriesRef: SampleType] = [:]

    let appendID: UInt64
    let cleanupAppendIDsBelow: UInt64
    var closed = false
    /// Go: `storeST`/`useXOR2` — snapshotted from the options so a config reload mid-append cannot split one
    /// batch across two encodings.
    let storeST: Bool
    let useXOR2: Bool

    /// Go: `hints`, set by `SetOptions`.
    var hints: AppendOptions?

    init(
        head: Head, minValidTime: Int64, headMaxt: Int64, oooTimeWindow: Int64, appendID: UInt64,
        cleanupAppendIDsBelow: UInt64, storeST: Bool, useXOR2: Bool
    ) {
        self.head = head
        self.minValidTime = minValidTime
        self.headMaxt = headMaxt
        self.oooTimeWindow = oooTimeWindow
        self.appendID = appendID
        self.cleanupAppendIDsBelow = cleanupAppendIDsBelow
        self.storeST = storeST
        self.useXOR2 = useXOR2
    }

    public func setOptions(_ opts: AppendOptions?) {
        hints = opts
    }

    /// Go: `headAppender.Append`.
    ///
    /// See the file header for the four decisions and for why nothing is written to the series here.
    @discardableResult
    public func append(ref: SeriesRef, labels lset: Labels, t: Int64, v: Double) throws -> SeriesRef {
        // Fail fast if OOO is disabled and the sample is out of bounds; a full check happens later.
        if oooTimeWindow == 0 && t < minValidTime {
            throw StorageError.outOfBounds
        }

        var series = head.series.getByID(HeadSeriesRef(rawValue: ref.rawValue))
        if series == nil {
            series = try getOrCreate(labels: lset).series
        }
        guard let s = series else { throw HeadError.invalidSample }

        if PromValue.isStaleNaN(v) {
            // Upstream turns a stale FLOAT into a stale histogram when this appender has already seen a
            // histogram for the series, to avoid cutting a new batch. Unreachable here: nothing writes a
            // histogram type into `typesInBatch` while the histogram append path is deferred, so this guard
            // names the deferral instead of silently doing the float thing.
            switch typesInBatch[s.ref] {
            case .histogram, .customBucketHistogram, .floatHistogram, .customBucketFloatHistogram:
                preconditionFailure(
                    "a stale float for a histogram series needs AppendHistogram, which §7f defers")
            default:
                break
            }
        }

        let (isOOO, _, err) = s.appendable(
            t: t, v: v, headMaxt: headMaxt, minValidTime: minValidTime, oooTimeWindow: oooTimeWindow)
        if err == nil {
            if isOOO, let hints, hints.discardOutOfOrder {
                throw StorageError.outOfOrderSample
            }
            s.pendingCommit = true
        }
        if let err {
            throw err
        }

        let b = getCurrentBatch(.float, s.ref)
        b.floats.append(RefSample(ref: s.ref, st: 0, t: t, v: v))
        b.floatSeries.append(s)
        return SeriesRef(rawValue: s.ref.rawValue)
    }

    /// Go: `headAppender.AppendSTZeroSample` — the synthetic zero sample a start timestamp implies.
    ///
    /// Float-only upstream too (the histogram flavour is a separate method), so it fits this slice. Three
    /// things worth noting: an `st` at or after the sample's own timestamp is rejected *before* any series
    /// lookup; the ST is checked with `appendable` as if it were a sample, because a shared ST between two
    /// scrapes would otherwise be an out-of-order write; and the OOO verdict returns the series' ref
    /// **alongside** the error, which is the only place in the appender that does.
    public func appendSTZeroSample(
        ref: SeriesRef, labels lset: Labels, t: Int64, st: Int64
    ) -> (ref: SeriesRef, error: (any Error)?) {
        if st >= t {
            return (SeriesRef(rawValue: 0), StorageError.stNewerThanSample)
        }

        var series = head.series.getByID(HeadSeriesRef(rawValue: ref.rawValue))
        if series == nil {
            do {
                series = try getOrCreate(labels: lset).series
            } catch {
                return (SeriesRef(rawValue: 0), error)
            }
        }
        guard let s = series else {
            return (SeriesRef(rawValue: 0), HeadError.invalidSample)
        }

        let (isOOO, _, err) = s.appendable(
            t: st, v: 0, headMaxt: headMaxt, minValidTime: minValidTime, oooTimeWindow: oooTimeWindow)
        if err == nil {
            s.pendingCommit = true
        }
        if let err {
            return (SeriesRef(rawValue: 0), err)
        }
        if isOOO {
            // The ONE place a non-zero ref travels with an error.
            return (SeriesRef(rawValue: s.ref.rawValue), StorageError.outOfOrderST)
        }

        let b = getCurrentBatch(.float, s.ref)
        b.floats.append(RefSample(ref: s.ref, st: 0, t: st, v: 0))
        b.floatSeries.append(s)
        return (SeriesRef(rawValue: s.ref.rawValue), nil)
    }

    /// Go: `headAppenderBase.getOrCreate` — the appender's wrapper around the Head's.
    ///
    /// Two validations that belong to the appender rather than to the Head, in this order: empty label VALUES
    /// are dropped first (`WithoutEmpty`), and only then is an empty label SET an error — so a sample labelled
    /// `{foo=""}` is rejected as an empty labelset, not accepted as a one-label series.
    @discardableResult
    func getOrCreate(labels lset: Labels) throws -> (series: MemSeries, created: Bool) {
        let lset = lset.withoutEmpty()
        if lset.isEmpty {
            throw AppenderError.emptyLabelset
        }
        if let duplicate = lset.hasDuplicateLabelNames() {
            throw AppenderError.duplicateLabelName(duplicate)
        }
        let (s, created) = try head.getOrCreate(
            hash: lset.goHash(), labels: lset, pendingCommit: true)
        if created {
            seriesRefs.append(RefSeries(ref: s.ref, labels: lset))
            createdSeries.append(s)
        }
        return (s, created)
    }

    /// Go: `getCurrentBatch` — the batch that can take this sample type for this series.
    ///
    /// The decision table is upstream's in full, including the rows only histograms can reach. What it means
    /// for a float-only append: `stFloat` is never recorded in `typesInBatch`, so `!ok && st == .float`
    /// matches every sample and the batch is never cut. A second batch appears only when a histogram type
    /// changes, or when a float lands on a series that already took a histogram in this batch.
    ///
    /// Note `newBatch()` CLEARS `typesInBatch` — the map describes the most recent batch only.
    @discardableResult
    func getCurrentBatch(_ st: SampleType, _ s: HeadSeriesRef) -> AppendBatch {
        func newBatch() -> AppendBatch {
            let b = AppendBatch()
            typesInBatch.removeAll(keepingCapacity: true)
            switch st {
            case .histogram, .floatHistogram, .customBucketHistogram, .customBucketFloatHistogram:
                // Only histogram types are recorded; floats are implicit.
                typesInBatch[s] = st
            default:
                break
            }
            batches.append(b)
            return b
        }

        // First batch ever. Create it.
        if batches.isEmpty {
            return newBatch()
        }

        let lastBatch = batches[batches.count - 1]
        if st == .none {
            // Type doesn't matter, last batch will always do.
            return lastBatch
        }
        let prevST = typesInBatch[s]
        switch true {
        case prevST == st:
            // An old series of some histogram type taking the same type again.
            return lastBatch
        case prevST == nil && st == .float:
            // A new float series, or an old float series taking floats.
            return lastBatch
        case st == .float:
            // A float appended to a histogram series: start a new batch.
            return newBatch()
        case prevST == nil:
            // A new series of some histogram type, or a histogram type on an old float series. Histograms
            // after floats are fine, so the batch continues.
            typesInBatch[s] = st
            return lastBatch
        default:
            // One histogram type changed to another.
            return newBatch()
        }
    }

    /// Go: `headAppenderBase.GetRef`. The labels it returns are the SERIES' own, so passing them back to
    /// `append` cannot cause another copy.
    public func getRef(labels lset: Labels, hash: UInt64) -> (SeriesRef, Labels) {
        guard let s = head.series.getByHash(hash: hash, labels: lset) else {
            return (SeriesRef(rawValue: 0), Labels())
        }
        return (SeriesRef(rawValue: s.ref.rawValue), s.labels())
    }

    /// Go: `headAppenderBase.log` — write everything this appender holds to the WAL.
    ///
    /// A nil WAL is a no-op, and the record ORDER is contractual: series first, so replay can resolve the refs
    /// the sample records use, then per batch metadata, then floats. Upstream's comment on the float/histogram
    /// order — *"It's important to do (float) Samples before histogram samples to end up with the correct
    /// order"* — is about replay reconstructing the same sequence.
    ///
    /// Each failure is wrapped with its own prefix (`log series: %w`, `log samples: %w`), and `Commit` turns
    /// the whole thing into `write to WAL: %w` after rolling back.
    func log() throws {
        guard let wal = head.wal else { return }

        let enc = RecordEncoder(enableSTStorage: storeST)

        if !seriesRefs.isEmpty {
            do {
                try wal.log(enc.series(seriesRefs))
            } catch {
                throw WALLogError.series(error)
            }
        }
        for b in batches {
            if !b.floats.isEmpty {
                do {
                    try wal.log(enc.samples(b.floats))
                } catch {
                    throw WALLogError.samples(error)
                }
            }
        }
    }

    /// Go: `Commit`.
    ///
    /// The order is the whole function: `log()` first, and a WAL failure ROLLS BACK and reports `write to WAL`
    /// — so a sample cannot be in the head without being in the WAL. Then the per-batch commit, then
    /// `unmarkCreatedSeriesAsPendingCommit`, then the two window updates, and `closeAppend` releases the
    /// isolation ID.
    public func commit() throws {
        if closed {
            throw HeadError.appenderClosed
        }

        do {
            try log()
        } catch {
            try? rollback()  // Most likely the same error will happen again.
            throw WALLogError.writeToWAL(error)
        }

        var acc = AppenderCommitContext(
            appendChunkOpts: ChunkOpts(
                chunkDiskMapper: head.chunkDiskMapper, chunkRange: head.chunkRange,
                samplesPerChunk: head.opts.samplesPerChunk, useXOR2: useXOR2, storeST: storeST))

        for b in batches {
            acc.floatsAppended += b.floats.count
        }

        for b in batches {
            // Do not change the order of these calls: the commit order of samples and the staleness-marker
            // handling both depend on it. (`commitHistograms`, `commitFloatHistograms` and `commitMetadata`
            // are the deferred half.)
            commitFloats(b, &acc)
        }
        unmarkCreatedSeriesAsPendingCommit()

        head.updateMinMaxTime(mint: acc.inOrderMint, maxt: acc.inOrderMaxt)

        head.iso.closeAppend(appendID)
        closed = true
    }

    /// Go: `commitFloats` — the in-order arm.
    ///
    /// Three things it does that `Append` did not: it consults `appendable` AGAIN (the answer can have changed,
    /// because `Append` only collected), it tracks the STALENESS transition per series so
    /// `numStaleSeries` counts series rather than samples, and it decrements `floatsAppended` for a sample
    /// `memSeries.append` silently dropped as an exact duplicate.
    func commitFloats(_ b: AppendBatch, _ acc: inout AppenderCommitContext) {
        for (i, s) in b.floats.enumerated() {
            let series = b.floatSeries[i]

            // Upstream's staleness-conversion block belongs to the histogram path: if the series' last value
            // was a histogram, the stale float becomes a stale histogram in this same batch. Unreachable while
            // the histogram append path is deferred — nothing can set `lastHistogramValue`.

            let (_, _, err) = series.appendable(
                t: s.t, v: s.v, headMaxt: headMaxt, minValidTime: minValidTime,
                oooTimeWindow: oooTimeWindow)
            if let err {
                handleAppendableError(
                    err, appended: &acc.floatsAppended, oooRejected: &acc.floatOOORejected,
                    oobRejected: &acc.floatOOBRejected, tooOldRejected: &acc.floatTooOldRejected)
            }

            let prevHeadChunkCount = series.headChunkCount
            var chunkCreated = false
            if err == nil {
                let newlyStale = !PromValue.isStaleNaN(series.lastValue) && PromValue.isStaleNaN(s.v)
                let staleToNonStale = PromValue.isStaleNaN(series.lastValue) && !PromValue.isStaleNaN(s.v)
                let (ok, created) = series.append(
                    st: s.st, t: s.t, v: s.v, appendID: appendID, o: acc.appendChunkOpts)
                chunkCreated = created
                if ok {
                    if s.t < acc.inOrderMint { acc.inOrderMint = s.t }
                    if s.t > acc.inOrderMaxt { acc.inOrderMaxt = s.t }
                    if newlyStale { head.incNumStaleSeries() }
                    if staleToNonStale { head.decNumStaleSeries() }
                } else {
                    // An exact duplicate, silently dropped.
                    acc.floatsAppended -= 1
                }
            }

            if chunkCreated {
                head.onChunkCreated(series: series, prevHeadChunkCount: prevHeadChunkCount)
            }

            series.cleanupAppendIDsBelow(cleanupAppendIDsBelow)
            series.pendingCommit = false
        }
    }

    /// Go: `unmarkCreatedSeriesAsPendingCommit` — run after ALL samples are committed, so a series created by
    /// this appender is not visible as commit-free while another of its samples is still pending.
    func unmarkCreatedSeriesAsPendingCommit() {
        for s in createdSeries {
            s.pendingCommit = false
        }
    }

    /// Go: `Rollback` — drop the samples, clear every touched series' pending flag, release the isolation ID,
    /// and **log the series records anyway**.
    ///
    /// That last part is the one to read twice, and the corpus caught the port getting it wrong: the function
    /// ends with `return a.log()` AFTER truncating `a.batches`, so the samples are gone but the series records
    /// are written. Upstream says why in two lines: *"Series are created in the head memory regardless of
    /// rollback. Thus we have to log them to the WAL in any case."* A rolled-back series stays in the index, so
    /// a replay that did not know about it would hand out its ref to a different label set.
    ///
    /// Everything in Go's `defer` — unmarking the created series, closing the append ID, marking the appender
    /// closed — therefore happens AFTER the log call, which is why it is a `defer` here too.
    public func rollback() throws {
        if closed {
            throw HeadError.appenderClosed
        }
        defer {
            unmarkCreatedSeriesAsPendingCommit()
            head.iso.closeAppend(appendID)
            closed = true
        }
        for b in batches {
            for i in b.floats.indices {
                let series = b.floatSeries[i]
                series.cleanupAppendIDsBelow(cleanupAppendIDsBelow)
                series.pendingCommit = false
            }
        }
        // Truncated BEFORE the log, so `log()` finds no samples to write — only the series.
        batches = []
        try log()
    }
}

/// Go: the `fmt.Errorf` wraps in `log()` and `Commit`.
public enum WALLogError: Error, CustomStringConvertible {
    case series(any Error)
    case samples(any Error)
    case writeToWAL(any Error)

    public var description: String {
        switch self {
        case .series(let e): return "log series: \(e)"
        case .samples(let e): return "log samples: \(e)"
        case .writeToWAL(let e): return "write to WAL: \(e)"
        }
    }
}
