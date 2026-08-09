//===----------------------------------------------------------------------===//
// Ported from promql/histogram_stats_iterator.go @ v3.13.2, plus
// `histogramStatsSeries` from promql/engine.go:4785-4801 — the only thing that
// constructs one.
//
// The wrapper `detectHistogramStatsDecoding` (already ported, in Preprocess.swift)
// arranges for: when a query only reads a histogram's Count and Sum, the buckets
// need not be decoded, so the selector is wrapped and this iterator strips
// everything but `count`, `sum`, `schema` and `counterResetHint`.
//
// Because the buckets are gone by the time the evaluator sees the sample, counter
// reset detection has to happen *here*, while the full histogram is still in hand.
// That is the whole reason this type is stateful, and the reason `last` holds a
// FULL copy of the previous sample rather than the stripped one it returned.
//
// Two Go shapes that Swift's value-typed `FloatHistogram` makes invisible, and are
// therefore commented rather than transcribed. Both were established by
// perturbation: unpicking each one leaves the whole differential suite green, which
// is the only honest reason to call something unobservable.
//
//   - `populateFH`'s `if fh == nil { fh = &FloatHistogram{}; *fh = h }` exists only
//     to stop `h` escaping to the heap (upstream says so at :104). With a struct
//     there is no escape and no allocation to avoid — and the whole reuse buffer is
//     unobservable, since the caller passes a copy and gets a value back. The
//     parameter and the `copy(to:)` call site are kept per PORTING.md §4, not
//     because anything can see them.
//   - `Reset` not clearing `current` (only `last` and `lastIsCurrent`) is an
//     allocation-reuse choice; `current` is always overwritten before it is read.
//     Replicated anyway, so the port reads like the original.
//
// What is NOT invisible, and cost a corpus rewrite to pin: `last` holds a copy of
// the FULL histogram, buckets included, not the stripped one that was returned.
// Storing the stripped form passes every case built from `tsdbutil`'s generators,
// because their counts move with the generator's parameter and `DetectReset`'s
// count comparison answers before it ever looks at a bucket. The fixture's
// `baseline/*` cases use a generator whose count and sum are FIXED for exactly this
// reason. Same lesson as PORTING.md's note on single-caller domains: a corpus that
// reaches a dependency through one shape pins only that shape.
//
// `AtHistogram` traps, as Go panics. Note the consequence for anything that wraps
// this: `Next`/`Seek` never report `.histogram`, so a caller that dispatches on the
// returned ValueType never reaches `atHistogram` — but one that dispatches on the
// *underlying* iterator's type can, and would take the process down.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromHistogram
public import PromLabels
public import PromStorage
internal import PromModel

/// Go: `promql.HistogramStatsIterator` — an iterator returning histograms that have
/// only their `count` and `sum` populated.
///
/// Counter reset detection is handled internally and the hint is set on each
/// returned histogram. `next()` and `seek(_:)` never return ``ValueType/histogram``,
/// always ``ValueType/floatHistogram``: the iterator enforces the conversion from
/// an integer `Histogram` to a `FloatHistogram`. ``atHistogram(_:)`` must not be
/// called and traps.
public final class HistogramStatsIterator: ChunkIterator {
    /// Go embeds `chunkenc.Iterator`; Swift has no embedding, so the promoted
    /// methods (`at`, `atT`, `atST`, `err`) are forwarded explicitly below.
    ///
    /// Public because `histogramStatsSeries.Iterator` reads it to pass as the reuse
    /// buffer of the series it wraps (engine.go:4795).
    public var iterator: any ChunkIterator

    /// The full histogram just read from the wrapped iterator; also the reuse
    /// buffer handed to it.
    private var current: FloatHistogram
    /// A full copy of the previously returned sample, with the hint this iterator
    /// computed for it. Nil until the first non-stale sample has been read, which
    /// is what makes the first sample's hint `unknownCounterReset`.
    private var last: FloatHistogram?
    /// True when `last` describes the position the iterator is currently on, so a
    /// repeated `atFloatHistogram(_:)` can answer from it.
    private var lastIsCurrent: Bool

    /// Go: `NewHistogramStatsIterator`.
    public init(_ it: any ChunkIterator) {
        self.iterator = it
        self.current = FloatHistogram()
        self.last = nil
        self.lastIsCurrent = false
    }

    /// Go: `Reset` — re-point at a new underlying iterator.
    ///
    /// Note it does **not** clear `current`, which stays as the reuse buffer. Only
    /// `last` and `lastIsCurrent` are dropped.
    public func reset(_ it: any ChunkIterator) {
        self.iterator = it
        self.last = nil
        self.lastIsCurrent = false
    }

    // MARK: - Advancing

    /// Go: `Next` — relays, but reports an integer histogram as a float one.
    public func next() -> ValueType {
        lastIsCurrent = false
        let vt = iterator.next()
        if vt == .histogram {
            return .floatHistogram
        }
        return vt
    }

    /// Go: `Seek` — relays, but reports an integer histogram as a float one.
    public func seek(_ t: Int64) -> ValueType {
        // If the seek is going to move the iterator, forget `last` and mark
        // `current` as no longer current.
        //
        // `atT()` here is the *wrapped* iterator's, which is why a seek before the
        // first advance is not safe over a `ListSeriesIterator`: that reads
        // `samples[-1]`, which panics in Go and traps here.
        if t > atT() {
            last = nil
            lastIsCurrent = false
        }
        let vt = iterator.seek(t)
        if vt == .histogram {
            return .floatHistogram
        }
        return vt
    }

    // MARK: - Reading

    /// Go: `AtHistogram` must never be called.
    public func atHistogram(_: Histogram?) -> (Int64, Histogram?) {
        preconditionFailure("HistogramStatsIterator.atHistogram must never be called")
    }

    /// Go: `AtFloatHistogram` — the current timestamp/float histogram pair, with
    /// counter reset detection performed on the fly.
    ///
    /// The result carries only `count`, `sum`, `counterResetHint` and `schema`;
    /// bucket data is intentionally omitted. The hint is explicit (not
    /// `unknownCounterReset`) only if the previous sample was accessed through this
    /// same iterator.
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        if lastIsCurrent {
            // Nothing changed since the last call. Return a copy of the stored
            // `last` rather than detecting again, which would yield a potentially
            // wrong "no counter reset".
            //
            // Note the timestamp comes from `atT()` here and from the underlying
            // read below — an asymmetry that is preserved, not tidied.
            let stored = last ?? FloatHistogram()
            return (atT(), populate(stored, detectReset: false, into: reuse))
        }

        let (t, produced) = iterator.atFloatHistogram(current)
        guard let produced else {
            // Go dereferences `hsi.current.Sum` on the next line, so a wrapped
            // iterator that yields no histogram panics there. Reported here
            // instead, where the cause is nameable.
            preconditionFailure(
                "HistogramStatsIterator: the wrapped iterator produced no float histogram")
        }
        current = produced

        if PromValue.isStaleNaN(current.sum) {
            // A stale marker passes its own hint through untouched, and — the part
            // that is easy to miss — does NOT become `last`. So the sample after a
            // stale one is compared against the sample *before* it.
            return (t, populate(current, detectReset: false, into: reuse))
        }
        let out = populate(current, detectReset: true, into: reuse)
        // Go reads `fh.CounterResetHint` here, i.e. the hint `populateFH` just
        // computed, not `current`'s.
        setLastFromCurrent(out.counterResetHint)
        return (t, out)
    }

    /// Go: `populateFH`, a closure over `fh` — the stripping step. Everything but
    /// these four fields is dropped.
    private func populate(
        _ src: FloatHistogram, detectReset: Bool, into reuse: FloatHistogram?
    ) -> FloatHistogram {
        var h = FloatHistogram(
            counterResetHint: src.counterResetHint,
            schema: src.schema,
            count: src.count,
            sum: src.sum)
        if detectReset {
            h.counterResetHint = resetHint(src.counterResetHint)
        }
        // Go's two branches — allocate, or CopyTo the caller's buffer — produce the
        // same value here, because a Swift `FloatHistogram` is a struct. Kept for
        // the call site (PORTING.md §4); nothing observes the difference.
        guard var destination = reuse else {
            return h
        }
        h.copy(to: &destination)
        return destination
    }

    /// Go: `setLastFromCurrent` — store a full copy of `current` as `last`, but with
    /// the hint this iterator computed rather than the one the sample carried.
    ///
    /// The copy is of the FULL histogram, buckets and all. That is what
    /// ``resetHint(_:)`` needs and it is the file's least visible invariant — see
    /// the header.
    ///
    /// `copy(to:)` into a default-initialised value is identical to `copy()`, so
    /// Go's nil branch collapses.
    private func setLastFromCurrent(_ hint: CounterResetHint) {
        var destination = last ?? FloatHistogram()
        current.copy(to: &destination)
        destination.counterResetHint = hint
        last = destination
        lastIsCurrent = true
    }

    /// Go: `getResetHint`.
    private func resetHint(_ hint: CounterResetHint) -> CounterResetHint {
        if hint != .unknownCounterReset {
            return hint
        }
        if last == nil {
            // We do not know whether there was a counter reset. This generally
            // triggers an explicit detection in the engine, which is itself less
            // reliable here because the engine will not see the buckets. Upstream's
            // argument for accepting that: wherever reset detection matters, an
            // iteration through the series has happened, so this branch is not
            // reached in the first place.
            return .unknownCounterReset
        }
        if current.detectReset(last!) {
            return .counterReset
        }
        return .notCounterReset
    }

    // MARK: - Forwarded, in Go by embedding

    public func at() -> (Int64, Double) { iterator.at() }

    public func atT() -> Int64 { iterator.atT() }

    public func atST() -> Int64 { iterator.atST() }

    public func err() -> (any Error)? { iterator.err() }
}

/// Go: `promql.histogramStatsSeries` (engine.go:4785) — the wrapper
/// `detectHistogramStatsDecoding` puts around a selector's series.
///
/// Lifted here rather than into the engine slice because it exists only to build a
/// ``HistogramStatsIterator``, and its reuse path is the only caller of
/// ``HistogramStatsIterator/reset(_:)``.
public struct HistogramStatsSeries: PromStorage.Series {
    public var series: any PromStorage.Series

    public init(_ series: any PromStorage.Series) {
        self.series = series
    }

    public func labels() -> Labels { series.labels() }

    public func iterator(_ it: (any ChunkIterator)?) -> any ChunkIterator {
        // Reuse the iterator where we can. Note what is passed inward: the stats
        // iterator's *wrapped* iterator, not the stats iterator itself, so the
        // series underneath gets its own kind back for reuse.
        if let statsIterator = it as? HistogramStatsIterator {
            statsIterator.reset(series.iterator(statsIterator.iterator))
            return statsIterator
        }
        return HistogramStatsIterator(series.iterator(it))
    }
}

/// Go: `newHistogramStatsSeries`.
public func newHistogramStatsSeries(_ series: any PromStorage.Series) -> HistogramStatsSeries {
    HistogramStatsSeries(series)
}
