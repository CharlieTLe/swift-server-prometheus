//===----------------------------------------------------------------------===//
// Ported from promql/functions.go @ v3.13.2 — the histogram family — plus the
// bucket caches it needs from `EvalNodeHelper` (engine.go:1240-1372).
//
// `simpleHistogramFunc` and the five direct readers (`histogram_count`, `_sum`,
// `_avg`, `_stddev`, `_stdvar`), then `histogram_fraction`, `histogram_quantile`
// and `histogram_quantiles`, which sit on the already-ported `quantile.go`.
//
// ## Classic and native histograms are separated first, and it is not symmetric
//
// `resetHistograms` splits the input vector once per step: anything with `H != nil`
// goes to `nativeHistogramSamples`, and everything else is treated as a **classic**
// bucket series, keyed by its label set with `le` removed. Then a second pass looks
// for a native histogram whose *full* label set matches a classic signature, and
// when it finds one it drops **both** — the classic entry from the map and the
// native sample's `H` — leaving a `Sample` with no histogram that every caller then
// skips with `if sample.H == nil { continue }`. So a conflict removes two series and
// raises one warning, and the `H = nil` marker is how the second loop tells the
// first loop's victims apart.
//
// ## Go iterates a map here, so the output order is upstream's own coin flip
//
// `for _, mb := range enh.signatureToMetricWithBuckets` ranges a
// `map[string]*metricWithBuckets`. The order of classic-histogram results is
// therefore randomised per run in Go, exactly as PORTING.md exception 7 records for
// `Annotations`. The port keeps **first-insertion order** so its own output is
// reproducible, and `Fixtures/promql/functions-histogram.jsonl` sorts the samples
// before comparing. Exception 13.
//
// What *is* deterministic and is pinned: native-histogram results always come
// before classic ones, and within the natives the order is the input vector's.
//
// ## Fusion
//
// One site, from the evaluator's fusion map: `histogramVariance`'s
// `bucket.Count*delta*delta` is handed to a Kahan step, and `util/kahansum` casts
// its arguments through `float64(...)` expressly to forbid fusing across the
// boundary — so the product must be **rounded with a plain `*` first**, and it is
// left-associative. See docs/HANDOFF.md §5 on Kahan summation.
//===----------------------------------------------------------------------===//

public import PromAnnotations
public import PromHistogram
public import PromLabels
public import PromQLParser

internal import GoCompat
internal import PromMath
internal import PromModel
internal import PromSchema

// MARK: - The bucket caches

/// Go: `metricWithBuckets` — a classic histogram's label set (with `le` and the
/// metadata labels removed) and the buckets found for it at this step.
///
/// A `final class` because Go holds `*metricWithBuckets` in the map and mutates
/// `buckets` through the pointer while appending, and because `funcHistogramQuantile`
/// writes `mb.metric` back after dropping labels.
final class MetricWithBuckets {
    var metric: Labels
    var buckets: Buckets

    init(metric: Labels, buckets: Buckets = []) {
        self.metric = metric
        self.buckets = buckets
    }
}

extension EvalNodeHelper {

    /// Go: `resetHistograms` — split `inVec` into classic bucket groups and native
    /// histograms, and resolve conflicts between them.
    ///
    /// Returns the annotations the split itself raises: a `BadBucketLabelWarning`
    /// per sample whose `le` will not parse, and a
    /// `MixedClassicNativeHistogramsWarning` per conflicting pair.
    ///
    /// Two details that are easy to get backwards:
    ///
    ///   * the classic signature excludes **only `le`** (`BytesWithoutLabels`), while
    ///     the metric stored alongside it has `le`, `__name__`, `__type__` and
    ///     `__unit__` removed (`excludedLabels`). Two different label sets, computed
    ///     from the same sample.
    ///   * the conflict pass keys on the native sample's **full** label set
    ///     including `__name__`, and compares it against the classic signature that
    ///     had `le` stripped. So `foo_bucket{le="1"}` and a native `foo_bucket`
    ///     conflict, but a native `foo` does not.
    ///
    /// `enableDelayedNameRemoval` changes only whether the warnings carry a metric
    /// name, not what is dropped.
    func resetHistograms(_ inVec: Vector, _ arg: any Expr) -> Annotations {
        var annos = Annotations()

        // Go reuses the map and truncates each entry's buckets rather than
        // reallocating. The port clears instead: the reuse is allocation
        // optimisation (PORTING.md exception 4) and nothing observes it, because
        // every entry is rebuilt from this vector.
        signatureToMetricWithBuckets.removeAll(keepingCapacity: true)
        signatureOrder.removeAll(keepingCapacity: true)
        nativeHistogramSamples.removeAll(keepingCapacity: true)

        for sample in inVec {
            // Only classic buckets are wanted here; remember the histograms for the
            // second pass.
            if sample.h != nil {
                nativeHistogramSamples.append(sample)
                continue
            }

            let leValue = sample.metric[LabelName.bucket]
            guard let upperBound = try? GoFloat.parse(leValue) else {
                if enableDelayedNameRemoval {
                    annos.add(
                        newBadBucketLabelWarning(
                            sample.metric[LabelName.metricName], leValue, arg.positionRange))
                } else {
                    annos.add(newBadBucketLabelWarning("", leValue, arg.positionRange))
                }
                continue
            }

            let signature = labelSignature(sample.metric, without: [LabelName.bucket])
            let mb: MetricWithBuckets
            if let existing = signatureToMetricWithBuckets[signature] {
                mb = existing
            } else {
                var b = LabelsBuilder(sample.metric)
                b.del(excludedLabels)
                mb = MetricWithBuckets(metric: b.labels())
                signatureToMetricWithBuckets[signature] = mb
                signatureOrder.append(signature)
            }
            mb.buckets.append(Bucket(upperBound: upperBound, count: sample.f))
        }

        for idx in nativeHistogramSamples.indices {
            let sample = nativeHistogramSamples[idx]
            // The same signature a classic histogram would have, ignoring any `le`.
            let signature = labelSignature(sample.metric)
            guard let mb = signatureToMetricWithBuckets[signature], !mb.buckets.isEmpty else {
                continue
            }
            // Classic buckets and a native histogram with the same name and labels at
            // this point. Evaluate neither.
            if enableDelayedNameRemoval {
                annos.add(
                    newMixedClassicNativeHistogramsWarning(
                        sample.metric[LabelName.metricName], arg.positionRange))
            } else {
                annos.add(newMixedClassicNativeHistogramsWarning("", arg.positionRange))
            }
            signatureToMetricWithBuckets.removeValue(forKey: signature)
            signatureOrder.removeAll { $0 == signature }
            nativeHistogramSamples[idx].h = nil
        }
        return annos
    }

    /// Go: `getOrCreateLblsWithQuantile` — the label set for one
    /// `histogram_quantiles` output, cached across steps.
    ///
    /// The quantile's rendering is `labels.FormatOpenMetricsFloat`, and **NaN is
    /// special-cased before the lookup** because a NaN map key cannot be found
    /// again — so `histogram_quantiles(v, "q", NaN)` labels its output `q="NaN"`
    /// without consulting the cache.
    func getOrCreateLblsWithQuantile(
        _ lbls: Labels, _ quantileLabel: String, _ q: Double
    ) -> Labels {
        let key = labelSignature(lbls)
        var cached = signatureToLabelsWithQuantile[key] ?? [:]
        if let hit = cached[q] {
            return hit
        }
        var quantileStr = "NaN"
        if !q.isNaN {
            // Cannot do a map lookup by NaN key.
            quantileStr = quantileStrs[q] ?? ""
        }
        var b = LabelsBuilder(lbls)
        b.set(quantileLabel, quantileStr)
        let out = b.labels()
        cached[q] = out
        signatureToLabelsWithQuantile[key] = cached
        return out
    }
}

/// The map key Go builds with `Labels.Bytes`/`BytesWithoutLabels`.
///
/// **Not Go's encoding, deliberately.** PORTING.md exception 1 records that
/// `labels.Bytes()` is explicitly not a compatibility surface — Go's own doc says
/// "Encoding may change over time or between runs of Prometheus" — so any injective
/// encoding will do. What *is* required is that the two callers agree: the classic
/// signature drops `le`, the native one drops nothing, and a conflict is exactly
/// when the two coincide.
private func labelSignature(_ ls: Labels, without names: [String] = []) -> [UInt8] {
    if names.isEmpty {
        return ls.goEncodedBytes()
    }
    var b = LabelsBuilder(ls)
    b.del(names)
    return b.labels().goEncodedBytes()
}

/// Go: `getMetricName` — `metric.Get(model.MetricNameLabel)`.
func getMetricName(_ metric: Labels) -> String {
    metric[LabelName.metricName]
}

// MARK: - simpleHistogramFunc and the direct readers

/// Go: `simpleHistogramFunc` — the mirror of ``simpleFloatFunc(_:_:_:)``, applying
/// `f` to every **histogram** sample and skipping the floats.
///
/// **It does not drop the same labels as `simpleFloatFunc`, and that is upstream's
/// asymmetry rather than a transcription slip.** `simpleFloatFunc` passes
/// `schema.IsMetadataLabel`, so `abs(x)` loses `__name__`, `__type__` and
/// `__unit__`. `simpleHistogramFunc` passes an inline
/// `func(n string) bool { return n == labels.MetricName }` (functions.go:1946), so
/// `histogram_count(x)` loses **only `__name__`** and keeps the type and unit.
///
/// Found by the fixture, not by reading: the port originally used
/// `isMetadataLabel` here by symmetry with its neighbour and failed 5 of 599 cases.
/// The other histogram functions in this file — `histogram_quantile` and friends —
/// go back to `isMetadataLabel`, so all three spellings are live in one file.
func simpleHistogramFunc(
    _ vectorVals: [Vector], _ enh: EvalNodeHelper, _ f: (FloatHistogram) -> Double
) -> Vector {
    for el in vectorVals[0] {
        guard let h = el.h else { continue }
        var metric = el.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved { $0 == LabelName.metricName }
        }
        enh.out.append(Sample(f: f(h), metric: metric, dropName: true))
    }
    return enh.out
}

/// Go: `funcHistogramCount`.
func funcHistogramCount(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleHistogramFunc(v, enh) { $0.count }, Annotations())
}

/// Go: `funcHistogramSum`.
func funcHistogramSum(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleHistogramFunc(v, enh) { $0.sum }, Annotations())
}

/// Go: `funcHistogramAvg` — `Sum / Count`, with no guard, so an empty histogram
/// gives NaN and a zero-count one with a non-zero sum gives ±Inf.
func funcHistogramAvg(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    (simpleHistogramFunc(v, enh) { $0.sum / $0.count }, Annotations())
}

/// Go: `histogramVariance` — the shared body of `histogram_stddev` and
/// `histogram_stdvar`.
///
/// Three per-bucket cases decide the representative value, and the order of the
/// tests matters: custom buckets take the arithmetic mean, the zero bucket of an
/// exponential histogram takes 0, and everything else takes the **geometric** mean
/// with the sign of the bucket restored.
///
/// The accumulation is Kahan, and `bucket.Count*delta*delta` must be rounded by a
/// plain left-associative `*` before it reaches the Kahan step — `util/kahansum`
/// casts its arguments through `float64(...)` specifically to forbid fusing there.
func histogramVariance(
    _ vectorVals: [Vector], _ enh: EvalNodeHelper, _ varianceToResult: ((Double) -> Double)?
) -> (Vector, Annotations) {
    let out = simpleHistogramFunc(vectorVals, enh) { h in
        let mean = h.sum / h.count
        var variance = 0.0
        var cVariance = 0.0
        var it = h.allBucketIterator()
        while it.next() {
            let bucket = it.at()
            if bucket.count == 0 {
                continue
            }
            var val: Double
            if h.usesCustomBuckets {
                // Arithmetic mean for custom buckets.
                val = (bucket.upper + bucket.lower) / 2.0
            } else if bucket.lower <= 0 && bucket.upper >= 0 {
                // Zero — effectively the arithmetic mean — in the zero bucket.
                val = 0
            } else {
                // Geometric mean for standard exponential buckets.
                val = (bucket.upper * bucket.lower).squareRoot()
                if bucket.upper < 0 {
                    val = -val
                }
            }
            let delta = val - mean
            // Rounded before the Kahan step, and left-associated: `(Count*delta)*delta`.
            let term = bucket.count * delta * delta
            (variance, cVariance) = Kahan.inc(term, variance, cVariance)
        }
        variance += cVariance
        variance /= h.count
        if let varianceToResult {
            variance = varianceToResult(variance)
        }
        return variance
    }
    return (out, Annotations())
}

/// Go: `funcHistogramStdDev` — the square root of the variance.
func funcHistogramStdDev(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    histogramVariance(v, enh) { $0.squareRoot() }
}

/// Go: `funcHistogramStdVar`.
func funcHistogramStdVar(_ v: [Vector], _: Matrix, _: [any Expr], _ enh: EvalNodeHelper) -> (
    Vector, Annotations
) {
    histogramVariance(v, enh, nil)
}

// MARK: - histogram_fraction, histogram_quantile, histogram_quantiles

/// Go: `validateQuantile` — a warning, not an error, for a quantile outside [0, 1].
///
/// NaN counts as invalid. The function still runs and still produces output; the
/// annotation is advisory.
func validateQuantile(_ q: Double, _ arg: any Expr) -> (any AnnotationError)? {
    if q.isNaN || q < 0 || q > 1 {
        return newInvalidQuantileWarning(q, arg.positionRange)
    }
    return nil
}

/// Go: `funcHistogramFraction`.
///
/// The guard is `len(vectorVals) < 3 || len(vectorVals[0]) == 0 || len(vectorVals[1]) == 0`
/// — so a missing *bound* yields nothing at all, while an empty **input vector** is
/// fine and simply produces nothing per series.
func funcHistogramFraction(
    _ v: [Vector], _: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if v.count < 3 || v[0].isEmpty || v[1].isEmpty {
        return (enh.out, Annotations())
    }
    let lower = v[0][0].f
    let upper = v[1][0].f
    let inVec = v[2]

    var annos = enh.resetHistograms(inVec, args[2])

    for sample in enh.nativeHistogramSamples {
        // Nil `H` marks a sample that conflicted with a classic histogram.
        guard let h = sample.h else { continue }
        var metric = sample.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        // Go assigns the dropped labels back into `sample.Metric` and *then* reads
        // the name out of it, so when removal is eager the annotation is nameless.
        // Reading the original would name every metric. functions.go:2048.
        let (hf, hfAnnos) = histogramFraction(
            lower: lower, upper: upper, h,
            metricName: getMetricName(metric), pos: args[0].positionRange)
        annos.merge(hfAnnos)
        enh.out.append(Sample(f: hf, metric: metric, dropName: true))
    }

    for signature in enh.signatureOrder {
        guard let mb = enh.signatureToMetricWithBuckets[signature], !mb.buckets.isEmpty else {
            continue
        }
        if !enh.enableDelayedNameRemoval {
            mb.metric = mb.metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(
            Sample(
                f: bucketFraction(lower: lower, upper: upper, &mb.buckets),
                metric: mb.metric, dropName: true))
    }

    return (enh.out, annos)
}

/// Go: `funcHistogramQuantile`.
///
/// Note which argument each position range comes from, because they are not the
/// obvious ones: `validateQuantile` and `HistogramQuantile` report against
/// **`args[0]`** (the quantile), while `resetHistograms` and the
/// forced-monotonicity info report against **`args[1]`** (the vector).
///
/// And the metric name in that info is populated **only when name removal is
/// delayed** — the opposite way round from every other annotation here, because
/// when removal is eager the name has already gone by the time it is read.
func funcHistogramQuantile(
    _ v: [Vector], _: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    if v.count < 2 || v[0].isEmpty {
        return (enh.out, Annotations())
    }
    let q = v[0][0].f
    let inVec = v[1]
    var annos = Annotations()

    if let err = validateQuantile(q, args[0]) {
        annos.add(err)
    }
    annos.merge(enh.resetHistograms(inVec, args[1]))

    for sample in enh.nativeHistogramSamples {
        guard let h = sample.h else { continue }
        var metric = sample.metric
        if !enh.enableDelayedNameRemoval {
            metric = metric.dropReserved(isMetadataLabel)
        }
        // The name comes from the ALREADY-DROPPED metric — see the note in
        // ``funcHistogramFraction(_:_:_:_:)``.
        let (hq, hqAnnos) = histogramQuantile(
            q, h, metricName: getMetricName(metric), pos: args[0].positionRange)
        annos.merge(hqAnnos)
        enh.out.append(Sample(f: hq, metric: metric, dropName: true))
    }

    for signature in enh.signatureOrder {
        guard let mb = enh.signatureToMetricWithBuckets[signature], !mb.buckets.isEmpty else {
            continue
        }
        let (quantile, fix) = bucketQuantile(q, &mb.buckets)
        if fix.forcedMonotonic {
            var metricName = ""
            if enh.enableDelayedNameRemoval {
                metricName = getMetricName(mb.metric)
            }
            annos.add(
                newHistogramQuantileForcedMonotonicityInfo(
                    metricName, args[1].positionRange, enh.ts,
                    fix.minBucket, fix.maxBucket, fix.maxDiff))
        }
        if !enh.enableDelayedNameRemoval {
            mb.metric = mb.metric.dropReserved(isMetadataLabel)
        }
        enh.out.append(Sample(f: quantile, metric: mb.metric, dropName: true))
    }

    return (enh.out, annos)
}

/// Go: `funcHistogramQuantiles` — one output series per (input series, quantile),
/// labelled with the quantile.
///
/// The argument positions are stranger still than ``funcHistogramQuantile``'s:
/// `resetHistograms` and `HistogramQuantile` both report against **`args[0]`** (the
/// vector), and the forced-monotonicity info against **`args[1]`** — which is the
/// *string literal* naming the label. Reproduced rather than tidied, because the
/// position appears in the annotation text.
///
/// The output loops are quantile-major: every quantile walks every series, so the
/// order is q0's series then q1's, not each series' quantiles together.
func funcHistogramQuantiles(
    _ v: [Vector], _: Matrix, _ args: [any Expr], _ enh: EvalNodeHelper
) -> (Vector, Annotations) {
    let inVec = v[0]
    guard let literal = args[1] as? StringLiteral else {
        preconditionFailure("histogram_quantiles' second argument is a string literal")
    }
    let quantileLabel = String(decoding: literal.val, as: UTF8.self)
    var annos = Annotations()
    var qs: [Double] = []

    for i in 2..<v.count {
        let q = v[i][0].f
        if let err = validateQuantile(q, args[i]) {
            annos.add(err)
        }
        if enh.quantileStrs[q] == nil {
            enh.quantileStrs[q] = Labels.formatOpenMetricsFloat(q)
        }
        qs.append(q)
    }

    annos.merge(enh.resetHistograms(inVec, args[0]))

    for q in qs {
        for sample in enh.nativeHistogramSamples {
            guard let h = sample.h else { continue }
            var metric = sample.metric
            if !enh.enableDelayedNameRemoval {
                metric = metric.dropReserved(isMetadataLabel)
            }
            let (hq, hqAnnos) = histogramQuantile(
                q, h, metricName: getMetricName(metric), pos: args[0].positionRange)
            annos.merge(hqAnnos)
            enh.out.append(
                Sample(
                    f: hq,
                    metric: enh.getOrCreateLblsWithQuantile(metric, quantileLabel, q),
                    dropName: true))
        }

        for signature in enh.signatureOrder {
            guard let mb = enh.signatureToMetricWithBuckets[signature], !mb.buckets.isEmpty else {
                continue
            }
            let (hq, fix) = bucketQuantile(q, &mb.buckets)
            if fix.forcedMonotonic {
                var metricName = ""
                if enh.enableDelayedNameRemoval {
                    metricName = getMetricName(mb.metric)
                }
                annos.add(
                    newHistogramQuantileForcedMonotonicityInfo(
                        metricName, args[1].positionRange, enh.ts,
                        fix.minBucket, fix.maxBucket, fix.maxDiff))
            }
            if !enh.enableDelayedNameRemoval {
                mb.metric = mb.metric.dropReserved(isMetadataLabel)
            }
            enh.out.append(
                Sample(
                    f: hq,
                    metric: enh.getOrCreateLblsWithQuantile(mb.metric, quantileLabel, q),
                    dropName: true))
        }
    }

    return (enh.out, annos)
}
