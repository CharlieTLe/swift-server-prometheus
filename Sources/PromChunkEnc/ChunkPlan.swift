//===----------------------------------------------------------------------===//
// Ported from the chunk-cutting and header-setting half of
// tsdb/chunkenc/float_histogram.go's `AppendFloatHistogram` @ v3.13.2
//
// **The decision, without the encoding.** `AppendFloatHistogram` does two separable things: it works
// out whether the sample belongs in the current chunk and what header a new chunk gets, and then it
// writes bits. This file is the first half. It exists because Phase 5's exit gate needs the *hints* a
// query reads back, and those depend only on the decision — where the chunk boundaries fall and what
// each chunk's header says. `xor.go` and the bstream can land later without touching any of this.
//
// ## Four ways a chunk boundary appears, and they set different headers
//
//   1. **The counter path cuts internally** because `appendable` said no. Header is `CounterReset` if
//      a reset was detected and is otherwise left **`unknown`** — upstream passes no `prev` on this
//      path, so it has nothing to compare against. A schema change therefore produces an `unknown`
//      chunk, not a `NotCounterReset` one.
//   2. **The gauge path cuts internally**, and the new chunk is always `GaugeType`.
//   3. **The Head cuts** for capacity or time and hands the old appender over as `prev`. This is the
//      ONLY producer of a `NotCounterReset` header: the new chunk's first sample is compared against
//      the old chunk's last one. So the same pair of samples gets a different header depending on
//      *why* the boundary is there, which is upstream's asymmetry rather than an accident.
//   4. **A recode**, which is not a boundary at all. It rewrites the current chunk with wider spans
//      and keeps every sample in it. It returns a new chunk object, so a reader that keys on
//      "did a new chunk come back" double-counts — the oracle's first driver did exactly that and
//      reported three read-back hints for a two-sample case.
//
// ## What this deliberately does NOT model
//
// The Head's capacity and time rules (`samplesPerChunk`, `nextAt`) are Phase 6-7's, so a boundary of
// kind 3 only happens when a caller asks for one. `MemStorage` never asks, which is exception 12's
// "one chunk per series" made precise: every `.test` file's longest series is ~101 samples at a
// 1-minute step, well inside a single chunk either way, so the model and the Head agree on every
// input the gate has. `chunkmeta`'s `cutBefore` cases pin kind 3 regardless, so the branch is
// verified before Phase 6 needs it.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import PromModel

/// Where one sample landed and what it reads back as.
public struct ChunkPlan: Sendable, Equatable {
    /// Per input sample, the index of the chunk holding it.
    public var chunkOf: [Int] = []
    /// Per chunk, its header.
    public var headers: [CounterResetHeader] = []
    /// Per input sample, the `CounterResetHint` a query READS BACK — which is not the hint the sample
    /// was written with. See `counterResetHint`.
    public var hints: [CounterResetHint] = []
}

/// The append-time half of the plan: one sample in, the hint it will read back with out.
///
/// **The hint is decidable at append time**, which is what makes this incremental. A chunk's header
/// is fixed when the chunk starts and never revised, and the position rule only needs to know how
/// many samples the chunk already holds — so nothing a later sample does can change an earlier one's
/// hint. `MemStorage` keeps one of these per series for exactly that reason, mirroring the Head's own
/// `s.app`; replanning a whole series on every append is O(n^2) and cost the exit gate four seconds.
public struct FloatHistogramChunkPlanner: Sendable {
    /// The current chunk's header.
    public private(set) var header: CounterResetHeader = .unknownCounterReset
    /// Index of the current chunk.
    public private(set) var chunkIndex = 0
    /// Headers of the chunks already closed, in order, plus the current one at the end.
    public private(set) var closedHeaders: [CounterResetHeader] = []

    private var count = 0
    private var state: FloatHistogramChunkState? = nil
    /// The state of the chunk a Head cut moved us off, which only that boundary consults.
    private var prev: FloatHistogramChunkState? = nil

    public init() {}

    private mutating func startChunk(_ h: CounterResetHeader) {
        closedHeaders.append(header)
        chunkIndex += 1
        header = h
        count = 0
        state = nil
    }

    /// Tell the planner the Head is cutting a chunk before the next sample — boundary kind 3.
    public mutating func cut() {
        guard state != nil else { return }
        prev = state
        startChunk(.unknownCounterReset)
    }

    /// Plan one sample and return the `CounterResetHint` a query will read back for it.
    public mutating func plan(_ h: FloatHistogram) -> CounterResetHint {
        if count == 0 {
            // An empty chunk takes anything; the only question is the header.
            //
            // Order matters: the gauge hint wins outright, then an explicit reset, and only then is
            // `prev` consulted — which is why a gauge sample after a Head cut gets a `GaugeType`
            // header and never a derived one.
            if h.counterResetHint == .gaugeType {
                header = .gaugeType
            } else if h.counterResetHint == .counterReset {
                header = .counterReset
            } else if let p = prev {
                let (_, reset) = floatHistogramAppendable(p, h)
                header = reset ? .counterReset : .notCounterReset
            }
            prev = nil
            count = 1
            state = FloatHistogramChunkState(header: header, numSamples: 1, last: h)
            return readBack(h, 1)
        }

        guard let s = state else { preconditionFailure("non-empty chunk without state") }

        if h.counterResetHint != .gaugeType {
            // The counter path.
            let (okToAppend, reset) = floatHistogramAppendable(s, h)
            if !okToAppend {
                // Kind 1: `CounterReset` when a reset was seen, and otherwise left `unknown`.
                startChunk(reset ? .counterReset : .unknownCounterReset)
                count = 1
                state = FloatHistogramChunkState(header: header, numSamples: 1, last: h)
                return readBack(h, 1)
            }
        } else if !floatHistogramAppendableGauge(s, h) {
            // Kind 2: always `GaugeType`.
            startChunk(.gaugeType)
            count = 1
            state = FloatHistogramChunkState(header: header, numSamples: 1, last: h)
            return readBack(h, 1)
        }

        // Appended to the current chunk — possibly through a recode, which is invisible here because
        // it changes the encoding and not the membership.
        count += 1
        // Upstream's appender keeps its own accumulated layout rather than adopting a stale sample's
        // empty one — and that difference is **provably unobservable here**, which is why the port
        // does not model it. A control that made the stale sample overwrite the layout survived, and
        // the reason is the staleness check two branches up: once `state.sum` is a stale NaN, the
        // next non-stale sample cuts a chunk unconditionally and never compares layouts, while the
        // next *stale* sample is exempt from the comparison too. So nothing can read the preserved
        // layout. Fifteen lines that looked like fidelity and were dead code.
        state = FloatHistogramChunkState(header: header, numSamples: count, last: h)
        return readBack(h, UInt16(truncatingIfNeeded: count))
    }

    /// **A STALE sample short-circuits the read entirely.** `AtFloatHistogram`
    /// (float_histogram.go:889) returns `&FloatHistogram{Sum: staleNaN}` and nothing else — no hint,
    /// no schema, no spans, no buckets. So a stale native histogram always reads back
    /// `UnknownCounterReset` however deep into a chunk it sits, and it loses its layout on the way
    /// out too. The corpus caught this: two cases wanted `unknown` where the position rule alone says
    /// `not_reset`.
    private func readBack(_ h: FloatHistogram, _ numRead: UInt16) -> CounterResetHint {
        if PromValue.isStaleNaN(h.sum) {
            return .unknownCounterReset
        }
        return counterResetHint(header, numRead)
    }
}

/// Lay a whole series out at once — the corpus's entry point, and a thin wrapper over the planner.
///
/// `cutBefore` names the sample indices at which the *Head* starts a new chunk — boundary kind 3 in
/// the file header. Everything else is decided by the planner.
public func planFloatHistogramChunks(
    _ samples: [FloatHistogram], cutBefore: Set<Int> = []
) -> ChunkPlan {
    var plan = ChunkPlan()
    var planner = FloatHistogramChunkPlanner()
    for (i, h) in samples.enumerated() {
        if cutBefore.contains(i) {
            planner.cut()
        }
        plan.hints.append(planner.plan(h))
        plan.chunkOf.append(planner.chunkIndex)
    }
    plan.headers = planner.closedHeaders + [planner.header]
    return plan
}
