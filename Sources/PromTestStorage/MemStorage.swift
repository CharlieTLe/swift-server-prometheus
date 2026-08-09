//===----------------------------------------------------------------------===//
// NOT a port. This target fills the role `util/teststorage` fills upstream — it
// is the storage `promqltest` runs the `.test` files against — but it is not a
// port of that file, because that file is a thin wrapper over a real `tsdb.DB`:
//
//     func NewWithError(o ...Option) (*TestStorage, error) {
//         ...
//         db, err := tsdb.Open(dir, nil, nil, opts, tsdb.NewDBStats())
//
// Phase 5 has no TSDB (Phases 6-7), so the stand-in is our own code. See
// docs/ROADMAP.md §2: "the storage seam is narrow", and docs/HANDOFF.md §5 step 1.
//
// **The behaviour it stands in for is still upstream's**, and is therefore still
// differentially tested: `Fixtures/storage/mem-select.jsonl` drives a real
// `tsdb.DB` through `util/teststorage` in the oracle and diffs the series and
// samples a `Select` returns. What is *ours* is the shape of the load API below;
// what is upstream's is everything `select` does, and that half is pinned.
//
// Deliberately not modelled, because the port has no chunks yet and nothing in
// the engine observes them:
//   - **Chunk granularity.** `SelectHints.DisableTrimming` means "return whole
//     chunks" upstream; here it means "do not trim at all", which is the same
//     thing only for a store whose every series is one chunk. Nothing in
//     `promql` sets it (`engine.go:1059` builds hints without it) — it exists for
//     remote read, Phase 10.
//   - **Tombstones.** No delete API, so `blockBaseSeriesSet`'s interval
//     subtraction has nothing to subtract.
//   - **Time-range filtering of the label APIs.** `labelValues`/`labelNames` go
//     through the block *index*, which upstream is not time-filtered per series;
//     ours are not either. Phase 9 owns that surface and can pin it when the
//     HTTP API gives it a caller.
//===----------------------------------------------------------------------===//

public import PromChunks
public import PromLabels
public import PromStorage

// Only reached from the append path's type discipline, not from any public
// signature here.
internal import PromChunkEnc
internal import PromHistogram

/// An in-memory ``Queryable`` — the Phase 5 stand-in for `tsdb.DB`.
///
/// Series are kept in **insertion order**, and that is deliberate rather than
/// incidental. Upstream's order here is genuinely nondeterministic: with every
/// sample in the Head and no persisted block, `tsdb.DB.Querier` returns a single
/// querier, so `storage.NewMergeQuerier`'s "we need to sort for merge to work"
/// (`merge.go:302`) never fires and `Select(ctx, false, ...)` yields postings in
/// series-ref order — which is append order — and `promqltest`'s loader appends
/// by ranging a **Go map**:
///
///     func (cmd *loadCmd) append(a storage.AppenderV2) error {
///         for h, smpls := range cmd.defs {          // test.go:918, map order
///
/// So there is no upstream order to be byte-exact against, and any `.test`
/// assertion that depended on one would already be flaky in upstream's own CI.
/// Insertion order is chosen because it is reproducible and because
/// ``select(_:sortSeries:hints:matchers:)`` can still deliver label order on
/// request, exactly as a block querier does. Recorded as exception 11 in
/// docs/PORTING.md.
public final class MemStorage: Queryable {
    /// One series: its label set and its samples, ordered by timestamp.
    struct Entry {
        var lset: Labels
        var samples: [any Sample]
    }

    /// Insertion-ordered. See the type's note.
    private var entries: [Entry] = []
    /// `Labels` -> index into ``entries``. Upstream's postings index, minus the
    /// inverted part: this store filters by scanning, because a `.test` file's
    /// largest `load` is a few hundred series.
    private var byLabels: [Labels: Int] = [:]

    public init() {}

    // MARK: - Loading

    /// Append one sample, enforcing the ordering rules `memSeries.appendable`
    /// enforces (`tsdb/head_append.go:652`) for `oooTimeWindow == 0`, which is
    /// what `util/teststorage` configures.
    ///
    /// Not `storage.Appender`: that protocol is deferred to Phases 6-7, where the
    /// Head is the subject and `AppenderV2`'s commit/rollback and reference
    /// caching actually mean something. Committing to its shape here would be
    /// guessing.
    public func append(_ lset: Labels, _ sample: any Sample) throws {
        guard let idx = byLabels[lset] else {
            byLabels[lset] = entries.count
            entries.append(Entry(lset: lset, samples: [sample]))
            return
        }

        // head_append.go:656 — "The series has no sample and was freshly
        // created." Unreachable through this API, which never creates an empty
        // series, but the branch is where Go's `t > msMaxt` check gets its
        // precondition.
        guard let last = entries[idx].samples.last else {
            entries[idx].samples.append(sample)
            return
        }

        if sample.t > last.t {
            entries[idx].samples.append(sample)
            return
        }

        if sample.t == last.t {
            // head_append.go:665 — an *exact* duplicate is accepted and dropped,
            // "as we can encounter them in valid cases like federation and
            // erroring out at that time would be extremely noisy". Anything else
            // at the same timestamp is an error.
            try Self.requireExactDuplicate(existing: last, incoming: sample)
            return
        }

        // oooTimeWindow == 0 and there is no minValidTime here, so Go's last two
        // branches collapse to this one.
        throw StorageError.outOfOrderSample
    }

    /// head_append.go:665-676 and its two histogram twins, which differ only in
    /// how they compare values. Returns normally for an exact duplicate; throws
    /// the error Go returns otherwise.
    private static func requireExactDuplicate(existing: any Sample, incoming: any Sample) throws {
        switch incoming.type {
        case .float:
            // head_append.go:668 — a float arriving on top of a histogram is its
            // own error, and note `existing` stays 0 in it and is not printed.
            if existing.type != .float {
                throw DuplicateSampleForTimestampError.duplicateHistogramToFloat(
                    t: incoming.t, newValue: incoming.f)
            }
            // head_append.go:671 — compared as **bits**, not with `==`, so a
            // repeated NaN is an accepted duplicate and `-0` and `+0` are not
            // each other's.
            if existing.f.bitPattern != incoming.f.bitPattern {
                throw DuplicateSampleForTimestampError.duplicateFloat(
                    t: incoming.t, existing: existing.f, newValue: incoming.f)
            }

        case .histogram:
            // head_append.go:710 — `!h.Equals(s.lastHistogramValue)`. Go compares
            // against `lastHistogramValue`, which is nil when the previous sample
            // was a float, and `(*Histogram)(nil).Equals(h)` is false; so a
            // histogram landing on a float is a plain duplicate error with no
            // value in its message.
            guard existing.type == .histogram, let a = existing.h, let b = incoming.h,
                a.equals(b)
            else {
                throw DuplicateSampleForTimestampError.sentinel
            }

        case .floatHistogram:
            guard existing.type == .floatHistogram, let a = existing.fh, let b = incoming.fh,
                a.equals(b)
            else {
                throw DuplicateSampleForTimestampError.sentinel
            }

        case .none:
            preconditionFailure("MemStorage.append: sample with ValueType .none")

        // `ValueType` is a `RawRepresentable` struct, not an enum, so the switch
        // needs a default even though the four constants above are all of them.
        default:
            preconditionFailure("MemStorage.append: unknown ValueType \(incoming.type.rawValue)")
        }
    }

    /// Append a whole series at once — what a `.test` file's `load` command does.
    public func load(_ lset: Labels, _ samples: [any Sample]) throws {
        for s in samples {
            try append(lset, s)
        }
    }

    /// The `clear` command in a `.test` file.
    public func clear() {
        entries.removeAll()
        byLabels.removeAll()
    }

    /// Number of series held, ignoring time ranges.
    public var seriesCount: Int { entries.count }

    // MARK: - Queryable

    public func querier(mint: Int64, maxt: Int64) throws -> any Querier {
        MemQuerier(storage: self, mint: mint, maxt: maxt)
    }

    /// The snapshot a querier reads. Taken by value, so a querier is unaffected
    /// by later appends — upstream gets the same isolation from the Head's
    /// `RLock` plus its append-only chunks.
    func snapshot() -> [Entry] { entries }
}
