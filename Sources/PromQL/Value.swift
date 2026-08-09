//===----------------------------------------------------------------------===//
// Ported from promql/value.go @ v3.13.2
//
// The result types of a query: `StringValue`, `Scalar`, `Series`, `FPoint`,
// `HPoint`, `Sample`, `Vector`, `Matrix`, `Result`, `StartTimestamps`, and the
// `StorageSeries` bridge that lets a `promql.Series` be read as a
// `storage.Series`.
//
// Every `String()` here is a compatibility surface: `promqltest` renders results
// through them and compares the text. They go through `GoFloat.formatF` — note
// `'f'`, **not** `'g'`: `strconv.FormatFloat(v, 'f', -1, 64)` throughout this file
// (value.go:58, :99, :113). ADR-4.
//
// Three names could not be kept:
//
//   - Go's `promql.String` becomes `StringValue`. Swift prefers a same-module
//     declaration in name lookup, so a type literally called `String` would shadow
//     `Swift.String` for the whole module.
//   - Go's `Vector` and `Matrix` are named slice types with methods. Swift allows a
//     type only ONE conformance to a protocol, so `[Sample]` and `[Series]` cannot
//     both conditionally conform `Array` to `Value`. They are structs wrapping the
//     array, with `RandomAccessCollection` + `RangeReplaceableCollection` so call
//     sites still read like arrays. Same forcing as ADR-11's `Expressions`.
//
// `ValueType` is ambiguous in this module and must always be qualified: there is
// the expression type (`PromQLParser.ValueType` — vector, scalar, matrix, string)
// and the chunk-iterator type (`PromChunkEnc.ValueType` — float, histogram,
// floatHistogram). Go has exactly the same collision between `parser.ValueType`
// and `chunkenc.ValueType`, and resolves it the same way.
//
// `Series` and `Sample` DO keep Go's names even though `PromStorage.Series` and
// `PromChunks.Sample` exist: Swift resolves them to this module's declarations
// inside `PromQL`, exactly as Go resolves `Series` to `promql.Series` inside
// package `promql`. The storage ones are written module-qualified where needed.
//
// Deliberately deferred:
//   - `MarshalJSON` on every type here -> Phase 9, with the HTTP API. It needs
//     more than `strconv`: Go's `encoding/json` has its own float encoder (a
//     'f'/'e' switch at 1e-6 and 1e21 plus exponent cleanup), HTML-escapes `<`,
//     `>` and `&` by default, and sorts map keys — three separate byte-exact
//     surfaces. Upstream's own comments say the `FPoint`/`HPoint` ones are unused
//     inside Prometheus (value.go:104-111), so nothing here needs them yet.
//   - `fParams` / `newFParams` (value.go:585) -> the engine PR; they take an
//     `*evaluator` and call `ev.eval`.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromChunkEnc
public import PromHistogram
public import PromLabels
public import PromQLParser
public import PromStorage
internal import GoCompat

// MARK: - Scalars and strings

/// Go: `promql.String` — a string value. Renamed; see the file header.
public struct StringValue: Value, Sendable, Hashable {
    public var t: Int64
    public var v: String

    public init(t: Int64, v: String) {
        self.t = t
        self.v = v
    }

    public var type: PromQLParser.ValueType { .string }
    /// value.go:43 — the bare value, with no timestamp.
    public var description: String { v }
}

/// Go: `Scalar` — a data point explicitly not associated with a metric.
public struct Scalar: Value, Sendable, Hashable {
    public var t: Int64
    public var v: Double

    public init(t: Int64, v: Double) {
        self.t = t
        self.v = v
    }

    public var type: PromQLParser.ValueType { .scalar }

    /// value.go:57 — `"scalar: %v @[%v]"` with the value pre-formatted by
    /// `strconv.FormatFloat(v, 'f', -1, 64)`.
    public var description: String {
        "scalar: \(GoFloat.formatF(v)) @[\(t)]"
    }
}

// MARK: - Points

/// Go: `FPoint` — a single float data point.
public struct FPoint: Sendable, Hashable, CustomStringConvertible {
    public var t: Int64
    public var f: Double

    public init(t: Int64, f: Double) {
        self.t = t
        self.f = f
    }

    /// value.go:98.
    public var description: String { "\(GoFloat.formatF(f)) @[\(t)]" }
}

/// Go: `HPoint` — a single histogram data point.
///
/// Go's field is a pointer and its doc says "H must never be nil", so it is
/// non-optional here.
public struct HPoint: Sendable, CustomStringConvertible {
    public var t: Int64
    public var h: FloatHistogram

    public init(t: Int64, h: FloatHistogram) {
        self.t = t
        self.h = h
    }

    /// value.go:124.
    public var description: String { "\(h) @[\(t)]" }

    /// Go: `size()` — the point's cost measured in float samples. The histogram's
    /// own size plus 8 bytes for the timestamp, over the 16 bytes an `FPoint`
    /// occupies.
    ///
    /// Note this is **not** the formula ``Vector/totalSamples`` uses, which omits
    /// the `+ 8` (value.go:282). The inconsistency is upstream's; both are pinned.
    public var size: Int { (h.size + 8) / 16 }
}

/// Go: `totalHPointSize`.
public func totalHPointSize(_ histograms: [HPoint]) -> Int {
    var total = 0
    for h in histograms {
        total += h.size
    }
    return total
}

/// Go: `countSamplesAfter` — sample equivalents with a timestamp **strictly**
/// after `cutoff`. Floats count 1, histograms count via ``HPoint/size``.
///
/// Scans backwards because the call site uses `cutoff = maxt - interval`, so only
/// the last point or two usually qualify.
public func countSamplesAfter(
    floats: [FPoint], histograms: [HPoint], cutoff: Int64
) -> Int64 {
    var n: Int64 = 0
    var i = floats.count - 1
    while i >= 0 && floats[i].t > cutoff {
        n += 1
        i -= 1
    }
    var j = histograms.count - 1
    while j >= 0 && histograms[j].t > cutoff {
        n += Int64(histograms[j].size)
        j -= 1
    }
    return n
}

// MARK: - Sample and Series

/// Go: `promql.Sample` — one sample of a metric, float or histogram.
///
/// `h == nil` means a float sample; otherwise it is a histogram sample.
public struct Sample: Sendable, CustomStringConvertible {
    public var t: Int64
    public var f: Double
    public var h: FloatHistogram?

    public var metric: Labels
    /// Whether `__name__` should be dropped as part of the evaluation.
    public var dropName: Bool

    public init(
        t: Int64 = 0, f: Double = 0, h: FloatHistogram? = nil,
        metric: Labels = .empty, dropName: Bool = false
    ) {
        self.t = t
        self.f = f
        self.h = h
        self.metric = metric
        self.dropName = dropName
    }

    /// value.go:226 — delegates to `FPoint`/`HPoint` for the point half.
    public var description: String {
        let point: String
        if let h {
            point = HPoint(t: t, h: h).description
        } else {
            point = FPoint(t: t, f: f).description
        }
        return "\(metric) => \(point)"
    }
}

/// Go: `promql.Series` — a stream of data points belonging to a metric.
public struct Series: Sendable, CustomStringConvertible {
    public var metric: Labels
    public var floats: [FPoint]
    public var histograms: [HPoint]
    /// Whether `__name__` should be dropped as part of the evaluation.
    public var dropName: Bool

    public init(
        metric: Labels = .empty, floats: [FPoint] = [], histograms: [HPoint] = [],
        dropName: Bool = false
    ) {
        self.metric = metric
        self.floats = floats
        self.histograms = histograms
        self.dropName = dropName
    }

    /// value.go:77. Floats first, then histograms, each already sorted by
    /// timestamp — upstream's own TODO wonders whether a mixed series should sort
    /// by timestamp across both instead. It does not, so neither does this.
    ///
    /// With no points at all the result still ends in the newline: `"metric =>\n"`.
    public var description: String {
        var vals = [String]()
        vals.reserveCapacity(floats.count + histograms.count)
        for f in floats {
            vals.append(f.description)
        }
        for h in histograms {
            vals.append(h.description)
        }
        return "\(metric) =>\n\(vals.joined(separator: "\n"))"
    }
}

// MARK: - Vector

/// Go: `Vector` — `[]Sample` where every sample shares a timestamp.
///
/// A struct rather than a typealias; see the file header.
public struct Vector: Value, Sendable {
    public var samples: [Sample]

    public init(_ samples: [Sample] = []) {
        self.samples = samples
    }

    public var type: PromQLParser.ValueType { .vector }

    /// value.go:265 — one sample per line.
    public var description: String {
        samples.map(\.description).joined(separator: "\n")
    }

    /// Go: `TotalSamples`. A float weighs 1; a histogram weighs more, by its size
    /// relative to a float sample.
    ///
    /// value.go:282 uses `H.Size() / 16` — **without** the `+ 8` that
    /// ``HPoint/size`` applies. Replicated rather than unified: the two really do
    /// disagree upstream, and both feed sample-count limits.
    public var totalSamples: Int {
        var numSamples = 0
        for sample in samples {
            numSamples += 1
            if let h = sample.h {
                numSamples += h.size / 16
            }
        }
        return numSamples
    }

    /// Go: `ContainsSameLabelset`. Two samples with the same label set is
    /// semantically undefined (upstream issue 4562).
    ///
    /// Compares label-set **hashes**, not the labels, so a hash collision reports a
    /// duplicate that is not one. Go's behaviour; and `Labels.Hash` is the
    /// stringlabels one per ADR-1.
    public var containsSameLabelset: Bool {
        switch samples.count {
        case 0, 1:
            return false
        case 2:
            return samples[0].metric.goHash() == samples[1].metric.goHash()
        default:
            var seen = Set<UInt64>(minimumCapacity: samples.count)
            for s in samples {
                let hash = s.metric.goHash()
                if seen.contains(hash) {
                    return true
                }
                seen.insert(hash)
            }
            return false
        }
    }
}

// MARK: - Matrix

/// Go: `Matrix` — `[]Series`, sortable and printable.
public struct Matrix: Value, Sendable {
    public var series: [Series]

    public init(_ series: [Series] = []) {
        self.series = series
    }

    public var type: PromQLParser.ValueType { .matrix }

    /// value.go:314 — one series per line, each itself multi-line.
    public var description: String {
        series.map(\.description).joined(separator: "\n")
    }

    /// Go: `TotalSamples`. Unlike ``Vector/totalSamples`` this one *does* go
    /// through ``HPoint/size``.
    public var totalSamples: Int {
        var numSamples = 0
        for s in series {
            numSamples += s.floats.count + totalHPointSize(s.histograms)
        }
        return numSamples
    }

    /// Go: `Less(i, j)` — `labels.Compare(...) < 0`.
    ///
    /// ADR-10: only the *sign* of `Labels.compare` is contractual, and it compares
    /// UTF-8 bytes rather than by Unicode collation. `assertMatrixSorted` in the
    /// conformance runner checks this ordering, so it is observable.
    public static func less(_ a: Series, _ b: Series) -> Bool {
        Labels.compare(a.metric, b.metric) < 0
    }

    /// Go: `sort.Sort(Matrix)`.
    ///
    /// Neither Go's `sort.Sort` nor Swift's `sort()` is stable, and the comparator
    /// is a total order except across duplicate label sets — which
    /// ``containsSameLabelset`` exists to reject and upstream calls semantically
    /// undefined. So the instability is not observable for well-formed input.
    public mutating func sort() {
        series.sort(by: Matrix.less)
    }

    /// Go: `ContainsSameLabelset`. As ``Vector/containsSameLabelset``, hashes and
    /// all.
    public var containsSameLabelset: Bool {
        switch series.count {
        case 0, 1:
            return false
        case 2:
            return series[0].metric.goHash() == series[1].metric.goHash()
        default:
            var seen = Set<UInt64>(minimumCapacity: series.count)
            for s in series {
                let hash = s.metric.goHash()
                if seen.contains(hash) {
                    return true
                }
                seen.insert(hash)
            }
            return false
        }
    }
}

// MARK: - Collection conformances
//
// So `Vector` and `Matrix` read like the slices they are in Go: indexing,
// iteration, `append`, `count`, and array literals.

extension Vector: RandomAccessCollection, RangeReplaceableCollection {
    public typealias Element = Sample
    public typealias Index = Int

    public init() { self.samples = [] }

    public var startIndex: Int { samples.startIndex }
    public var endIndex: Int { samples.endIndex }

    public subscript(position: Int) -> Sample {
        get { samples[position] }
        set { samples[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection<Sample>>(
        _ subrange: Range<Int>, with newElements: C
    ) {
        samples.replaceSubrange(subrange, with: newElements)
    }
}

extension Matrix: RandomAccessCollection, RangeReplaceableCollection {
    public typealias Element = Series
    public typealias Index = Int

    public init() { self.series = [] }

    public var startIndex: Int { series.startIndex }
    public var endIndex: Int { series.endIndex }

    public subscript(position: Int) -> Series {
        get { series[position] }
        set { series[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection<Series>>(
        _ subrange: Range<Int>, with newElements: C
    ) {
        series.replaceSubrange(subrange, with: newElements)
    }
}

// MARK: - Result

/// Go: `Result` — the outcome of an execution, or the error that stopped it.
public struct Result {
    public var error: (any Error)?
    public var value: (any Value)?
    public var warnings: Annotations

    public init(
        error: (any Error)? = nil, value: (any Value)? = nil,
        warnings: Annotations = Annotations()
    ) {
        self.error = error
        self.value = value
        self.warnings = warnings
    }

    /// Go: the error strings from `Result.Vector`/`Matrix`/`Scalar`.
    ///
    /// Note the middle one: asking for a `Matrix` and getting something else
    /// reports "not a range Vector", the documentation's name for it, where the
    /// other two use the internal name.
    public enum WrongTypeError: Error, Hashable, Sendable, CustomStringConvertible {
        case notVector
        case notRangeVector
        case notScalar

        public var description: String {
            switch self {
            case .notVector: return "query result is not a Vector"
            case .notRangeVector: return "query result is not a range Vector"
            case .notScalar: return "query result is not a Scalar"
            }
        }
    }

    /// Go: `Vector()`.
    public func vector() throws -> Vector {
        if let error { throw error }
        guard let v = value as? Vector else { throw WrongTypeError.notVector }
        return v
    }

    /// Go: `Matrix()`.
    public func matrix() throws -> Matrix {
        if let error { throw error }
        guard let v = value as? Matrix else { throw WrongTypeError.notRangeVector }
        return v
    }

    /// Go: `Scalar()`.
    public func scalar() throws -> Scalar {
        if let error { throw error }
        guard let v = value as? Scalar else { throw WrongTypeError.notScalar }
        return v
    }
}

extension Result: CustomStringConvertible {
    /// value.go:410 — the error's text wins, then an absent value renders empty.
    public var description: String {
        if let error {
            return "\(error)"
        }
        guard let value else {
            return ""
        }
        return value.description
    }
}

// MARK: - StartTimestamps

/// Go: `StartTimestamps` — start timestamps aligned with a series' points.
public struct StartTimestamps: Sendable, Hashable {
    public var floats: [Int64]
    public var histograms: [Int64]

    public init(floats: [Int64] = [], histograms: [Int64] = []) {
        self.floats = floats
        self.histograms = histograms
    }

    /// Go: `Reset` — clears while keeping capacity. Go's nil checks are a no-op
    /// distinction here, since an empty Swift array is already the nil case.
    public mutating func reset() {
        floats.removeAll(keepingCapacity: true)
        histograms.removeAll(keepingCapacity: true)
    }
}

// MARK: - The storage bridge

/// Go: `StorageSeries` — "simulates promql.Series as storage.Series".
///
/// This is what lets query results be fed back through a `Querier`, and it is the
/// substrate an in-memory `Queryable` is built on.
public final class StorageSeries: PromStorage.Series {
    private let series: Series

    /// Go: `NewStorageSeries`.
    public init(_ series: Series) {
        self.series = series
    }

    public func labels() -> Labels { series.metric }

    /// Recycles the iterator it is handed when it is already a
    /// ``StorageSeriesIterator``, as series.go's list iterator does.
    public func iterator(_ reuse: (any ChunkIterator)?) -> any ChunkIterator {
        if let existing = reuse as? StorageSeriesIterator {
            existing.reset(series)
            return existing
        }
        return StorageSeriesIterator(series)
    }
}

/// Go: `storageSeriesIterator`.
///
/// Merges the float and histogram streams of one `Series` into a single ordered
/// walk. **Floats win ties**: at an equal timestamp the float is yielded first
/// (value.go:557-560).
public final class StorageSeriesIterator: ChunkIterator {
    private var floats: [FPoint]
    private var histograms: [HPoint]
    /// Indices of the *candidate* in each stream. Note the asymmetry, which is
    /// Go's: `iFloats` starts at -1 and `iHistograms` at 0, because the first
    /// `next()` sees `currH == nil` and so advances the float side only.
    private var iFloats: Int
    private var iHistograms: Int
    private var currT: Int64
    private var currF: Double
    private var currH: FloatHistogram?

    public init(_ series: Series) {
        self.floats = series.floats
        self.histograms = series.histograms
        self.iFloats = -1
        self.iHistograms = 0
        self.currT = .min
        self.currF = 0
        self.currH = nil
    }

    /// Go: `reset`.
    public func reset(_ series: Series) {
        floats = series.floats
        histograms = series.histograms
        iFloats = -1
        iHistograms = 0
        currT = .min
        currF = 0
        currH = nil
    }

    /// Go: `Seek`.
    ///
    /// The exhaustion guard tests `iFloats >= floats.count`, and `iFloats` starts
    /// at -1 — so on a fresh iterator over empty streams it does *not* short
    /// circuit; it falls into the loop and gets `.none` from ``next()`` instead.
    /// Same answer, different path, and worth not "simplifying".
    public func seek(_ t: Int64) -> PromChunkEnc.ValueType {
        if iFloats >= floats.count && iHistograms >= histograms.count {
            return .none
        }
        while currT < t {
            if next() == .none {
                return .none
            }
        }
        if currH != nil {
            return .floatHistogram
        }
        return .float
    }

    public func at() -> (Int64, Double) { (currT, currF) }

    /// Go: `AtHistogram` **panics** — this iterator only ever yields float
    /// histograms, so an integer-histogram read is a caller error rather than a
    /// missing feature (value.go:512).
    public func atHistogram(_: Histogram?) -> (Int64, Histogram?) {
        preconditionFailure("StorageSeriesIterator: atHistogram not supported")
    }

    /// Go: `AtFloatHistogram`. Traps on a float sample, where Go dereferences a nil
    /// `currH`; the reuse buffer is honoured when supplied.
    public func atFloatHistogram(_ reuse: FloatHistogram?) -> (Int64, FloatHistogram?) {
        guard let currH else {
            preconditionFailure(
                "StorageSeriesIterator: atFloatHistogram on a float sample; "
                    + "check the ValueType first")
        }
        guard var destination = reuse else {
            return (currT, currH.copy())
        }
        currH.copy(to: &destination)
        return (currT, destination)
    }

    public func atT() -> Int64 { currT }

    /// Go: `AtST` — a TODO upstream (value.go:528), so always 0.
    public func atST() -> Int64 { 0 }

    /// Go: `Next`. Advances whichever stream produced the current value, then picks
    /// the earlier of the two candidates, floats winning ties.
    public func next() -> PromChunkEnc.ValueType {
        if currH != nil {
            iHistograms += 1
        } else {
            iFloats += 1
        }

        var pickH = false
        var pickF = false
        let floatsExhausted = iFloats >= floats.count
        let histogramsExhausted = iHistograms >= histograms.count

        if floatsExhausted {
            if histogramsExhausted {
                return .none
            }
            pickH = true
        } else if histogramsExhausted {
            pickF = true
        } else if histograms[iHistograms].t < floats[iFloats].t {
            // The next histogram comes strictly before the next float.
            pickH = true
        } else {
            // Everything else picks the float, which is what makes floats win a tie.
            pickF = true
        }

        if pickF {
            let p = floats[iFloats]
            currT = p.t
            currF = p.f
            currH = nil
            return .float
        }
        if pickH {
            let p = histograms[iHistograms]
            currT = p.t
            currF = 0
            currH = p.h
            return .floatHistogram
        }
        preconditionFailure("StorageSeriesIterator.next failed to pick a value type")
    }

    public func err() -> (any Error)? { nil }
}
