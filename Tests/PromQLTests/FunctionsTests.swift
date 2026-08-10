//===----------------------------------------------------------------------===//
// Differential tests for promql/functions.go's element-wise arithmetic slice,
// driven through `functionCalls` exactly as the oracle drives Go's
// `promql.FunctionCalls`.
//
// The table is deliberately partial until Phase 5 closes, so the fixture replay
// skips the functions this slice does not implement — and the skipped set is
// asserted by name, so a body that quietly goes missing fails rather than being
// counted as "not ported yet".
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromLabels
import PromQLParser
import Testing

@testable import PromQL

@Suite("promql/functions: the element-wise arithmetic slice")
struct FunctionsElementwiseTests {

    @Test("every implemented function matches Go on every committed case")
    func elementwiseMatchesGo() throws {
        try Fixtures.check(
            "promql/functions-elementwise.jsonl",
            FixtureCase<FnIn, FnOut>.self
        ) { input in
            runFnCase(input)
        }
    }

    @Test("the eight date functions match Go on every committed case")
    func dateMatchesGo() throws {
        try Fixtures.check(
            "promql/functions-date.jsonl",
            FixtureCase<FnIn, FnOut>.self
        ) { input in
            runFnCase(input)
        }
    }

    @Test("the histogram family matches Go on every committed case")
    func histogramMatchesGo() throws {
        try Fixtures.check(
            "promql/functions-histogram.jsonl",
            FixtureCase<FnIn, FnOut>.self
        ) { input in
            runFnCase(input)
        }
    }

    @Test("the FunctionCalls table is a subset of Go's, and the gap is the deferred set")
    func tableIsAKnownSubset() throws {
        // `promql/functionnames` already pins `parser.Functions`; this pins
        // `promql.FunctionCalls`, which is a different list — the parser knows about
        // functions the evaluator has no entry for. Asserting the *difference* by
        // name is what makes a partial table safe: a body that goes missing shows up
        // here instead of looking like one that has not landed yet.
        let goNames = try Fixtures.load(
            "promql/functioncallnames.jsonl",
            FixtureCase<String, [String]>.self
        )[0].out

        let ours = Set(functionCalls.keys)
        let theirs = Set(goNames)

        #expect(ours.isSubset(of: theirs), "invented: \(ours.subtracting(theirs).sorted())")
        #expect(goNames.count == functionCallsCountAtPin)

        // The deferred set, by name and with its owning slice. Each of these parses
        // and type-checks today and simply has no implementation yet.
        let deferred: Set<String> = [
            // Range-vector functions: need interpolate/correctForCounterResets.
            "avg_over_time", "changes", "count_over_time", "delta", "deriv",
            "double_exponential_smoothing", "first_over_time", "idelta", "increase",
            "irate", "last_over_time", "mad_over_time", "max_over_time",
            "min_over_time", "predict_linear", "present_over_time",
            "quantile_over_time", "rate", "resets", "stddev_over_time",
            "stdvar_over_time", "sum_over_time",
            "ts_of_first_over_time", "ts_of_last_over_time",
            "ts_of_max_over_time", "ts_of_min_over_time",
            // Sorts: need Go's pdqsort, because the two sorts are observably
            // different and neither comparator is a strict weak ordering.
            "sort", "sort_by_label", "sort_by_label_desc", "sort_desc",
            // The rest of the evaluator's own surface.
            "absent", "absent_over_time", "info", "label_join", "label_replace",
            "start", "end", "step", "range",
        ]
        #expect(theirs.subtracting(ours) == deferred,
                "unexpected gap: \(theirs.subtracting(ours).symmetricDifference(deferred).sorted())")
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("promql/functions invariants")
struct FunctionsElementwiseInvariantTests {

    private func vec(_ samples: [Sample]) -> [Vector] { [Vector(samples)] }
    private func scalar(_ f: Double) -> Vector { Vector([Sample(f: f)]) }

    @Test("delayed name removal decides whether the body strips labels at all")
    func delayedNameRemoval() {
        // The axis the whole corpus is doubled over, and the one setting that is
        // *not* the Prometheus server's default is what the exit gate runs with
        // (promqltest sets it true at test.go:111). Both are live, so both are here.
        let metric = Labels(strings: [
            "__name__", "foo", "__type__", "counter", "__unit__", "seconds", "job", "j",
        ])
        let input = vec([Sample(t: 1000, f: -2.5, metric: metric)])

        let eager = EvalNodeHelper(enableDelayedNameRemoval: false)
        let (a, _) = funcAbs(input, Matrix(), [], eager)
        #expect(a[0].metric.description == #"{job="j"}"#, "all three metadata labels go")

        let delayed = EvalNodeHelper(enableDelayedNameRemoval: true)
        let (b, _) = funcAbs(input, Matrix(), [], delayed)
        #expect(b[0].metric.description == metric.description, "none of them go")

        // DropName is set either way: it is the *intent*, and it is what the last
        // step of the query reads when removal is delayed.
        #expect(a[0].dropName)
        #expect(b[0].dropName)
    }

    @Test("histogram samples are skipped, except by timestamp")
    func histogramSkip() {
        // Every body in this slice tests `el.H == nil` and drops the sample —
        // `sqrt(some_histogram)` yields nothing for that series, with no annotation.
        // `funcTimestamp` reads only `el.T`, so it emits a float sample instead, and
        // that asymmetry is easy to normalise away by copying simpleFloatFunc.
        let h = Sample(t: 1000, metric: Labels(strings: ["__name__", "h"]))
        var withHist = h
        withHist.h = genTestHistogram(3).toFloat()
        let f = Sample(t: 2000, f: 4, metric: Labels(strings: ["__name__", "f"]))
        let input = vec([withHist, f])

        let (a, aAnnos) = funcSqrt(input, Matrix(), [], EvalNodeHelper())
        #expect(a.count == 1, "the histogram sample produced nothing")
        #expect(a[0].f == 2)
        #expect(aAnnos.isEmpty, "and it is not a warning")

        let (b, _) = funcTimestamp(input, Matrix(), [], EvalNodeHelper())
        #expect(b.count == 2, "timestamp does not skip")
        #expect(b[0].f == 1, "1000ms -> 1s")
        #expect(b[0].h == nil, "and the histogram does not survive into the result")
    }

    @Test("clamp with an inverted range returns nothing, without an annotation")
    func clampInvertedRange() {
        let input = Vector([Sample(f: 0.5, metric: Labels(strings: ["__name__", "x"]))])
        let enh = EvalNodeHelper()
        let (out, annos) = clamp(input, 1, 0, enh)
        #expect(out.isEmpty)
        #expect(annos.isEmpty, "an inverted range is not an error")

        // `max < min` uses `<`, so an equal range is legal and clamps to the point.
        let enh2 = EvalNodeHelper()
        let (out2, _) = clamp(input, 1, 1, enh2)
        #expect(out2.count == 1)
        #expect(out2[0].f == 1)
    }

    @Test("clamp goes through Go's Max and Min, so NaN does not behave like Swift's")
    func clampNaNOrdering() {
        // `math.Max(min, math.Min(max, f))` with Go's arm64 assembly semantics:
        // FMAXD/FMIND propagate NaN where libm's fmax/fmin suppress it, and the
        // ±Inf check runs before the NaN check. PORTING.md quirk 28.
        let nan = Sample(f: Double(bitPattern: 0x7FF8_0000_DEAD_BEEF))
        let enh = EvalNodeHelper()
        let (out, _) = clamp(Vector([nan]), 0, 1, enh)
        #expect(out.count == 1)
        #expect(out[0].f.isNaN, "a NaN sample clamps to NaN, not to a bound")

        // Swift's own spelling suppresses it, which is the divergence this guards.
        #expect(!Swift.max(0, Swift.min(1, Double.nan)).isNaN)
    }

    @Test("round's toNearest comes from the ARGUMENT COUNT, not from the values")
    func roundArgumentCount() {
        // `len(args) >= 2` is what decides whether `toNearest` is read, so the same
        // `vectorVals` with one and two args give different answers. A port that
        // looked at `vectorVals.count` instead would be right in the engine and
        // wrong here — and the engine is not the only caller.
        let input = vec([Sample(f: 2.34, metric: .empty)])
        let both = [input[0], scalar(0.1)]

        let one = EvalNodeHelper()
        let (a, _) = funcRound(both, Matrix(), [NumberLiteral(val: 0)], one)
        #expect(a[0].f == 2, "toNearest defaulted to 1")

        let two = EvalNodeHelper()
        let (b, _) = funcRound(
            both, Matrix(), [NumberLiteral(val: 0), NumberLiteral(val: 0)], two)
        #expect(b[0].f != 2, "toNearest was read")
    }

    @Test("round breaks ties upward, including for negatives")
    func roundTies() {
        func round1(_ f: Double) -> Double {
            let enh = EvalNodeHelper()
            let (out, _) = funcRound(vec([Sample(f: f, metric: .empty)]), Matrix(), [], enh)
            return out[0].f
        }
        // `Floor(f + 0.5)`, so a tie goes up — which for -2.5 means -2, not -3, and
        // is the opposite of `.rounded(.toNearestOrEven)` and of `.rounded()`.
        #expect(round1(2.5) == 3)
        #expect(round1(-2.5) == -2)
        #expect(round1(0.5) == 1)
        #expect(round1(-0.5).isZero, "and it lands on a zero")
        #expect(Double(-2.5).rounded() == -3, "Swift's default disagrees")
    }

    @Test("scalar returns Go's NaN for none and for many, but the sample's for one")
    func scalarNaNProvenance() {
        // Not a detail: `promqltest` renders results as text, and the three paths
        // produce different payloads. None and many go through `math.NaN()`
        // (0x7FF8000000000001); a single NaN sample is returned *as the value*, so
        // its own payload survives.
        let odd = Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)
        let m = Labels(strings: ["__name__", "x"])

        let none = EvalNodeHelper()
        let (a, _) = funcScalar([Vector()], Matrix(), [], none)
        #expect(a[0].f.bitPattern == 0x7FF8_0000_0000_0001, "Go's NaN()")

        let many = EvalNodeHelper()
        let (b, _) = funcScalar(
            vec([Sample(f: 1, metric: m), Sample(f: 2, metric: m)]), Matrix(), [], many)
        #expect(b[0].f.bitPattern == 0x7FF8_0000_0000_0001)

        let one = EvalNodeHelper()
        let (c, _) = funcScalar(vec([Sample(f: odd, metric: m)]), Matrix(), [], one)
        #expect(c[0].f.bitPattern == 0x7FF8_0000_DEAD_BEEF, "the sample's own payload")
    }

    @Test("scalar ignores histogram samples when counting")
    func scalarIgnoresHistograms() {
        // One float among any number of histograms is still one float.
        var h = Sample(t: 1000, metric: Labels(strings: ["__name__", "h"]))
        h.h = genTestHistogram(3).toFloat()
        let f = Sample(t: 2000, f: 42, metric: Labels(strings: ["__name__", "f"]))

        let enh = EvalNodeHelper()
        let (out, _) = funcScalar(vec([h, f, h]), Matrix(), [], enh)
        #expect(out[0].f == 42)

        // And a vector of only histograms is "none", so Go's NaN.
        let enh2 = EvalNodeHelper()
        let (out2, _) = funcScalar(vec([h, h]), Matrix(), [], enh2)
        #expect(out2[0].f.bitPattern == 0x7FF8_0000_0000_0001)
    }

    @Test("vector alone leaves DropName false")
    func vectorKeepsDropNameFalse() {
        // Every other function here sets DropName; `vector(s)` does not, because
        // there is no name to drop — its metric is the empty label set.
        let enh = EvalNodeHelper()
        let (out, _) = funcVector([scalar(42)], Matrix(), [], enh)
        #expect(out[0].f == 42)
        #expect(out[0].metric.isEmpty)
        #expect(!out[0].dropName)
    }

    @Test("sgn's default arm returns the argument, so ±0 and NaN survive")
    func sgnPreservesZeroAndNaN() {
        // `default: return v` rather than `return 0`. That makes sgn(-0) negative
        // zero and sgn(NaN) a NaN carrying the argument's payload — both of which a
        // `v == 0 ? 0 : ...` spelling would lose.
        func sgn1(_ f: Double) -> Double {
            let enh = EvalNodeHelper()
            let (out, _) = funcSgn(vec([Sample(f: f, metric: .empty)]), Matrix(), [], enh)
            return out[0].f
        }
        #expect(sgn1(-0.0).bitPattern == 0x8000_0000_0000_0000)
        #expect(sgn1(0.0).bitPattern == 0)
        #expect(sgn1(Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)).bitPattern == 0x7FF8_0000_DEAD_BEEF)
        #expect(sgn1(-5) == -1)
        #expect(sgn1(5) == 1)
        #expect(sgn1(.infinity) == 1)
        #expect(sgn1(-.infinity) == -1)
    }

    @Test("pi and time ignore enh.out; everything else appends to it")
    func outIsAppendedToExceptByPiAndTime() {
        // Unreachable from a real query — engine.go:1523 resets `Out` to empty before
        // every call — but it is exported behaviour and it is the only thing that
        // distinguishes the two shapes. Pinned so a port that "tidies" the fresh
        // vectors into appends fails.
        let seed = Vector([Sample(t: 111, f: -99, metric: .empty)])

        let a = EvalNodeHelper(ts: 7000, out: seed)
        let (pi, _) = funcPi([], Matrix(), [], a)
        #expect(pi.count == 1, "fresh vector")
        #expect(pi[0].f == Double.pi)

        let b = EvalNodeHelper(ts: 7000, out: seed)
        let (t, _) = funcTime([], Matrix(), [], b)
        #expect(t.count == 1, "fresh vector")
        #expect(t[0].f == 7)

        let c = EvalNodeHelper(ts: 7000, out: seed)
        let (abs, _) = funcAbs(vec([Sample(f: -1, metric: .empty)]), Matrix(), [], c)
        #expect(abs.count == 2, "appended to the seed")
        #expect(abs[0].f == -99)
        #expect(abs[1].f == 1)
    }

    @Test("time and timestamp divide by 1000, so sub-second values are fractional")
    func timeIsSeconds() {
        let enh = EvalNodeHelper(ts: 1500)
        let (out, _) = funcTime([], Matrix(), [], enh)
        #expect(out[0].f == 1.5)

        let enh2 = EvalNodeHelper()
        let (out2, _) = funcTimestamp(
            vec([Sample(t: -1500, f: 0, metric: .empty)]), Matrix(), [], enh2)
        #expect(out2[0].f == -1.5)
    }

    @Test("the date functions' no-argument form is a different shape entirely")
    func dateNoArgumentForm() {
        // `len(vectorVals) == 0` reads enh.Ts, emits ONE unlabelled sample, and
        // leaves DropName **false** — where the argument form emits one per sample,
        // keeps the metric and sets DropName. Easy to write as one loop with an
        // `isEmpty` guard and get the flag wrong.
        let noArgs = EvalNodeHelper(ts: 1_709_164_800_000)
        let (a, _) = funcYear([], Matrix(), [], noArgs)
        #expect(a.count == 1)
        #expect(a[0].f == 2024)
        #expect(a[0].metric.isEmpty)
        #expect(!a[0].dropName, "the no-argument form does NOT set DropName")

        let withArgs = EvalNodeHelper()
        let m = Labels(strings: ["__name__", "x", "job", "j"])
        let (b, _) = funcYear(
            [Vector([Sample(f: 1_709_164_800, metric: m)])], Matrix(), [], withArgs)
        #expect(b[0].f == 2024)
        #expect(b[0].dropName, "the argument form does")

        // And the timestamp is divided by 1000 FIRST, so this form cannot reach the
        // Int64 seconds the argument form can.
        let extreme = EvalNodeHelper(ts: .max)
        let (c, _) = funcYear([], Matrix(), [], extreme)
        #expect(c[0].f == 292_278_994, "Ts/1000, so no wrap")
    }

    @Test("year(vector(NaN)) is 1970 and BOTH infinities are 292277026596")
    func dateSaturation() {
        // `int64(el.F)` is unguarded on arbitrary sample data, so all of these are
        // legal PromQL. Swift's `Int64(_:)` would trap on every one.
        func year(_ f: Double) -> Double {
            let enh = EvalNodeHelper()
            let (out, _) = funcYear(
                [Vector([Sample(f: f, metric: .empty)])], Matrix(), [], enh)
            return out[0].f
        }
        #expect(year(.nan) == 1970, "NaN saturates to 0 seconds")
        #expect(year(.infinity) == 292_277_026_596)
        #expect(year(-.infinity) == 292_277_026_596,
                "Int64.min lands in the band where Go's absolute count wraps")
        #expect(year(-1e300) == 292_277_026_596)
        // A finite sample inside the wrap band, so this is not an infinities-only
        // quirk. The boundary is -9223372028741760000, and one ULP of a Double this
        // large is 2048 — so ordinary sample data can land either side of it.
        //
        // Note the wrapped year is *not* a single value: it varies with the input,
        // because the wrap is `uint64(sec + unixToAbsolute)` and the further below
        // the boundary `sec` is, the further into year 292277026xxx it lands. Only
        // `Int64.min` itself gives 292277026596, which is why the infinities agree
        // with each other and this case does not agree with them.
        #expect(year(-9.2233720287e18) == -292_277_022_399, "above the boundary")
        #expect(year(-9.2233720288e18) == 292_277_026_852, "below it: the sign flips")
        #expect(year(-9.223372029e18) == 292_277_026_845)
    }

    @Test("day_of_week has Sunday as 0, and day_of_year is 1-based")
    func dateConventions() {
        // Both are off-by-one traps: Go's Weekday starts at Sunday, and YearDay is
        // 1-based where the internal `yday` it comes from is 0-based.
        func on(_ fn: FunctionCall, _ sec: Double) -> Double {
            let enh = EvalNodeHelper()
            let (out, _) = fn([Vector([Sample(f: sec, metric: .empty)])], Matrix(), [], enh)
            return out[0].f
        }
        #expect(on(funcDayOfWeek, 0) == 4, "1970-01-01 was a Thursday")
        #expect(on(funcDayOfYear, 0) == 1, "and it was day 1")
        #expect(on(funcDayOfMonth, 0) == 1)
        #expect(on(funcMonth, 0) == 1)
        #expect(on(funcDaysInMonth, 0) == 31)
        // 2024-02-29, a leap day: weekday Thursday, yearDay 60, month length 29.
        #expect(on(funcDayOfWeek, 1_709_164_800) == 4)
        #expect(on(funcDayOfYear, 1_709_164_800) == 60)
        #expect(on(funcDaysInMonth, 1_709_164_800) == 29)
    }

    @Test("simpleHistogramFunc drops ONLY __name__, unlike simpleFloatFunc")
    func histogramLabelDropAsymmetry() {
        // Upstream's own asymmetry, and the fixture is what found it: functions.go
        // passes `schema.IsMetadataLabel` for the float wrappers and an inline
        // `func(n string) bool { return n == labels.MetricName }` for the histogram
        // ones (functions.go:1946). So `abs(x)` loses the type and unit and
        // `histogram_count(x)` keeps them.
        let m = Labels(strings: [
            "__name__", "h", "__type__", "histogram", "__unit__", "s", "job", "j",
        ])
        var hs = Sample(t: 1000, metric: m)
        hs.h = genTestHistogram(3).toFloat()

        let a = EvalNodeHelper()
        let (hist, _) = funcHistogramCount([Vector([hs])], Matrix(), [], a)
        #expect(hist[0].metric.description == #"{__type__="histogram", __unit__="s", job="j"}"#)

        let b = EvalNodeHelper()
        let (float, _) = funcAbs(
            [Vector([Sample(t: 1000, f: 1, metric: m)])], Matrix(), [], b)
        #expect(float[0].metric.description == #"{job="j"}"#, "all three go here")
    }

    @Test("a native/classic conflict drops BOTH series and warns once")
    func mixedHistogramConflict() {
        // `resetHistograms`' second pass keys on the native sample's full label set
        // and compares it against the classic signature that had `le` stripped. On a
        // match it removes the classic entry AND nils the native sample's `h`, which
        // is the marker every later loop skips on. So one warning, no output.
        let name = "hb"
        var native = Sample(t: 1000, metric: Labels(strings: ["__name__", name]))
        native.h = genTestHistogram(2).toFloat()
        let classic = [
            Sample(t: 1000, f: 1, metric: Labels(strings: ["__name__", name, "le", "1"])),
            Sample(t: 1000, f: 2, metric: Labels(strings: ["__name__", name, "le", "+Inf"])),
        ]

        let enh = EvalNodeHelper()
        let annos = enh.resetHistograms(Vector([native] + classic), NumberLiteral(val: 0))
        #expect(enh.signatureToMetricWithBuckets.isEmpty, "the classic entry went")
        #expect(enh.nativeHistogramSamples.count == 1)
        #expect(enh.nativeHistogramSamples[0].h == nil, "and the native was marked")
        let (warnings, _) = annos.asStrings(query: "", maxWarnings: 0, maxInfos: 0)
        #expect(warnings.count == 1)

        // A native histogram under a DIFFERENT name does not conflict.
        var other = native
        other.metric = Labels(strings: ["__name__", "other"])
        let enh2 = EvalNodeHelper()
        let annos2 = enh2.resetHistograms(Vector([other] + classic), NumberLiteral(val: 0))
        #expect(enh2.signatureToMetricWithBuckets.count == 1)
        #expect(enh2.nativeHistogramSamples[0].h != nil)
        #expect(annos2.isEmpty)
    }

    @Test("both the signature and the stored metric strip only le, at this stage")
    func classicSignatureVersusStoredMetric() {
        // `excludedLabels` is `[BucketLabel]` alone — quantile.go:51 — so the metric
        // stored alongside the buckets keeps `__name__`, `__type__` and `__unit__`
        // here. Those are dropped later, by the *function*, and only when removal is
        // eager. Worth pinning because "excludedLabels" reads like it would include
        // the name, and the grouping and the output would then differ.
        let enh = EvalNodeHelper()
        let samples = [
            Sample(
                t: 1000, f: 1,
                metric: Labels(strings: [
                    "__name__", "hb", "__type__", "histogram", "__unit__", "s",
                    "job", "j", "le", "1",
                ])),
            Sample(
                t: 1000, f: 2,
                metric: Labels(strings: [
                    "__name__", "hb", "__type__", "histogram", "__unit__", "s",
                    "job", "j", "le", "+Inf",
                ])),
        ]
        _ = enh.resetHistograms(Vector(samples), NumberLiteral(val: 0))
        // One group: the two samples differ only in `le`, which the signature drops.
        #expect(enh.signatureToMetricWithBuckets.count == 1)
        let mb = enh.signatureToMetricWithBuckets[enh.signatureOrder[0]]!
        #expect(mb.buckets.count == 2)
        // The stored metric has lost `le` and nothing else.
        #expect(
            mb.metric.description
                == #"{__name__="hb", __type__="histogram", __unit__="s", job="j"}"#)
    }

    @Test("native-histogram results come before classic ones")
    func nativeBeforeClassic() {
        // The one ordering that IS deterministic in Go: the natives are a slice and
        // come first, the classics come out of a map and come second. The fixture
        // sorts, so this is where the order is pinned. PORTING.md exception 13.
        var native = Sample(t: 1000, metric: Labels(strings: ["__name__", "zzz_native"]))
        native.h = genTestHistogram(3).toFloat()
        let classic = [
            Sample(t: 1000, f: 1, metric: Labels(strings: ["__name__", "aaa_bucket", "le", "1"])),
            Sample(t: 1000, f: 2, metric: Labels(strings: ["__name__", "aaa_bucket", "le", "+Inf"])),
        ]
        // Delayed removal, so the names survive into the output and the order is
        // readable. With eager removal both metrics would render `{}`.
        let enh = EvalNodeHelper(enableDelayedNameRemoval: true)
        let (out, _) = funcHistogramQuantile(
            [Vector([Sample(f: 0.5)]), Vector([native] + classic)], Matrix(),
            [NumberLiteral(val: 0.5), NumberLiteral(val: 0)], enh)
        #expect(out.count == 2)
        #expect(out[0].metric.description.contains("zzz_native"), "native first")
        #expect(out[1].metric.description.contains("aaa_bucket"), "despite sorting later")
    }

    @Test("an invalid quantile warns but still produces output")
    func invalidQuantileStillComputes() {
        // `validateQuantile` returns an annotation, not an error, and the function
        // runs on regardless. NaN counts as invalid.
        var native = Sample(t: 1000, metric: Labels(strings: ["__name__", "h"]))
        native.h = genTestHistogram(3).toFloat()
        for q in [-0.1, 1.1, Double.nan] {
            let enh = EvalNodeHelper()
            let (out, annos) = funcHistogramQuantile(
                [Vector([Sample(f: q)]), Vector([native])], Matrix(),
                [NumberLiteral(val: q), NumberLiteral(val: 0)], enh)
            #expect(out.count == 1, "q = \(q) still produced a sample")
            #expect(!annos.isEmpty, "and a warning")
        }
        // In range: no warning.
        let enh = EvalNodeHelper()
        let (_, annos) = funcHistogramQuantile(
            [Vector([Sample(f: 0.5)]), Vector([native])], Matrix(),
            [NumberLiteral(val: 0.5), NumberLiteral(val: 0)], enh)
        #expect(annos.isEmpty)
    }

    @Test("histogram_fraction's guard is on the bounds, not the input vector")
    func fractionGuard() {
        // `len(vectorVals) < 3 || len(vectorVals[0]) == 0 || len(vectorVals[1]) == 0`
        // — an empty *bound* yields nothing, an empty input vector is simply an empty
        // result. Easy to write as a guard on the vector and be wrong only for the
        // degenerate call.
        var native = Sample(t: 1000, metric: Labels(strings: ["__name__", "h"]))
        native.h = genTestHistogram(3).toFloat()
        let args: [any Expr] = [
            NumberLiteral(val: 0), NumberLiteral(val: 1), NumberLiteral(val: 0),
        ]

        let a = EvalNodeHelper()
        let (missingBound, _) = funcHistogramFraction(
            [Vector(), Vector([Sample(f: 1)]), Vector([native])], Matrix(), args, a)
        #expect(missingBound.isEmpty)

        let b = EvalNodeHelper()
        let (emptyInput, _) = funcHistogramFraction(
            [Vector([Sample(f: 0)]), Vector([Sample(f: 1)]), Vector()], Matrix(), args, b)
        #expect(emptyInput.isEmpty, "same result, different reason")

        let c = EvalNodeHelper()
        let (ok, _) = funcHistogramFraction(
            [Vector([Sample(f: 0)]), Vector([Sample(f: 1)]), Vector([native])],
            Matrix(), args, c)
        #expect(ok.count == 1)
    }

    @Test("rad and deg keep Go's left association")
    func radDegAssociation() {
        // `v * math.Pi / 180`, not `v * (math.Pi / 180)`. Folding the divisor would
        // let the compiler round it once and change every result.
        let enh = EvalNodeHelper()
        let (out, _) = funcRad(vec([Sample(f: 180, metric: .empty)]), Matrix(), [], enh)
        #expect(out[0].f == 180 * Double.pi / 180)

        // The two spellings genuinely differ for some inputs, which is why the
        // association is not a style choice.
        let v = 3.0
        #expect((v * Double.pi / 180) != (v * (Double.pi / 180)))
    }
}
