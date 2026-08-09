//===----------------------------------------------------------------------===//
// Differential tests for util/annotations/annotations.go.
//
// The messages are asserted verbatim by promqltest, so they are the reason this
// suite exists. Two fixtures, because they fail for different reasons: one
// annotation at a time (message composition, %q escaping, %g and %.2g
// formatting, RFC 3339 rendering) and then the collection (dedup, merge, limits).
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromPosRange
import Testing

@testable import PromAnnotations

/// Mirrors `annoIn` in oracle/suites_promql_annotations.go.
struct AnnoIn: Decodable, Sendable {
    let ctor: String
    let query: String
    let start: Int
    let end: Int

    let metricName: String
    let label: String
    let typeLabel: String
    let operator_: String
    let lhsType: String
    let rhsType: String
    let aggregation: String
    let operation: String

    // Hex bit patterns; see the oracle's note. JSON cannot carry NaN.
    let f1: String
    let f2: String
    let f3: String
    let ts: Int64

    enum CodingKeys: String, CodingKey {
        case ctor, query, start, end
        case metricName, label, typeLabel
        case operator_ = "operator"
        case lhsType, rhsType, aggregation, operation
        case f1, f2, f3, ts
    }

    var pos: PositionRange { PositionRange(start: Pos(start), end: Pos(end)) }

    var float1: Double { AnnoIn.decode(f1) }
    var float2: Double { AnnoIn.decode(f2) }
    var float3: Double { AnnoIn.decode(f3) }

    private static func decode(_ hex: String) -> Double {
        guard let bits = UInt64(hex, radix: 16) else { return 0 }
        return Double(bitPattern: bits)
    }

    /// The counterpart of the oracle's `buildAnno`. Returns nil for an unknown
    /// name so a drifted corpus fails loudly.
    func build() -> (any AnnotationError)? {
        let op = HistogramOperation(rawValue: operation)
        switch ctor {
        case "InvalidQuantile":
            return newInvalidQuantileWarning(float1, pos)
        case "InvalidRatio":
            return newInvalidRatioWarning(float1, float2, pos)
        case "BadBucketLabel":
            return newBadBucketLabelWarning(metricName, label, pos)
        case "MixedFloatsHistograms":
            return newMixedFloatsHistogramsWarning(metricName, pos)
        case "MixedFloatsHistogramsAgg":
            return newMixedFloatsHistogramsAggWarning(pos)
        case "MixedClassicNativeHistograms":
            return newMixedClassicNativeHistogramsWarning(metricName, pos)
        case "NativeHistogramNotCounter":
            return newNativeHistogramNotCounterWarning(metricName, pos)
        case "NativeHistogramNotGauge":
            return newNativeHistogramNotGaugeWarning(metricName, pos)
        case "MixedExponentialCustomHistograms":
            return newMixedExponentialCustomHistogramsWarning(metricName, pos)
        case "PossibleNonCounter":
            return newPossibleNonCounterInfo(metricName, pos)
        case "PossibleNonCounterLabel":
            return newPossibleNonCounterLabelInfo(metricName, typeLabel, pos)
        case "IncompatibleTypesInBinOp":
            return newIncompatibleTypesInBinOpInfo(lhsType, operator_, rhsType, pos)
        case "HistogramIgnoredInAggregation":
            return newHistogramIgnoredInAggregationInfo(aggregation, pos)
        case "HistogramIgnoredInMixedRange":
            return newHistogramIgnoredInMixedRangeInfo(metricName, pos)
        case "IncompatibleBucketLayoutInBinOp":
            return newIncompatibleBucketLayoutInBinOpWarning(operator_, pos)
        case "SortInRangeQuery":
            return newSortInRangeQueryWarning(pos)
        case "NativeHistogramQuantileNaNResult":
            return newNativeHistogramQuantileNaNResultInfo(metricName, pos)
        case "NativeHistogramQuantileNaNSkew":
            return newNativeHistogramQuantileNaNSkewInfo(metricName, pos)
        case "NativeHistogramFractionNaNs":
            return newNativeHistogramFractionNaNsInfo(metricName, pos)
        case "HistogramCounterResetCollision":
            // Go's HistogramOperation is an open string type; a raw value outside
            // the set renders "unknown operation". A Swift enum cannot represent
            // that, so those corpus rows are skipped rather than faked. See
            // `unknownOperationIsUnrepresentable` below.
            guard let op else { return nil }
            return newHistogramCounterResetCollisionWarning(pos, op)
        case "MismatchedCustomBucketsHistograms":
            guard let op else { return nil }
            return newMismatchedCustomBucketsHistogramsInfo(pos, op)
        case "HistogramQuantileForcedMonotonicity":
            return newHistogramQuantileForcedMonotonicityInfo(
                metricName, pos, ts, float1, float2, float3)
        default:
            return nil
        }
    }

    /// True when the case exercises Go's open-string-type default, which this port
    /// deliberately cannot reach.
    var isUnrepresentableOperation: Bool {
        switch ctor {
        case "HistogramCounterResetCollision", "MismatchedCustomBucketsHistograms":
            return HistogramOperation(rawValue: operation) == nil
        default:
            return false
        }
    }
}

@Suite("Annotation messages match Go")
struct AnnotationMessageTests {

    struct Out: Decodable, Equatable, Sendable {
        let message: String
        let rendered: String
        let kind: String
    }

    @Test("every constructor's message and rendering is byte-identical")
    func messages() throws {
        let cases = try Fixtures.load("promql/annotations.jsonl", FixtureCase<AnnoIn, Out>.self)
        #expect(!cases.isEmpty)

        var failures = 0
        var skipped = 0
        var detail = ""
        for c in cases {
            if c.in.isUnrepresentableOperation {
                skipped += 1
                continue
            }
            guard let anno = c.in.build() else {
                failures += 1
                if failures <= 20 {
                    detail += "  [\(c.id)] no constructor for \(c.in.ctor)\n"
                }
                continue
            }
            // description before setQuery is the dedup key; after, the rendered
            // form. Build twice so the first reading stays meaningful.
            let message = anno.description
            let second = c.in.build()!
            second.setQuery(c.in.query)
            let got = Out(
                message: message, rendered: second.description, kind: anno.kind.kindName)
            if got != c.out {
                failures += 1
                if failures <= 20 {
                    detail += "  [\(c.id)]\n    got  \(got)\n    want \(c.out)\n"
                }
            }
        }
        if failures > 20 {
            detail += "  ... and \(failures - 20) more\n"
        }
        #expect(failures == 0, "\(failures) of \(cases.count) mismatched\n\(detail)")
        // Every skip is Go's "unknown operation" default; the count is fixed by the
        // corpus, so a change here means the corpus moved.
        #expect(skipped == 4, "expected 4 unrepresentable-operation cases, got \(skipped)")
    }
}

extension AnnotationKind {
    /// The oracle emits "info"/"warning", which is what `errors.Is` reports.
    var kindName: String {
        switch self {
        case .info: return "info"
        case .warning: return "warning"
        }
    }
}

@Suite("Annotations collection matches Go")
struct AnnotationsSetTests {

    struct SetIn: Decodable, Sendable {
        let adds: [AnnoIn]?
        let merge: [AnnoIn]?
        let query: String
        let maxWarnings: Int
        let maxInfos: Int
    }

    struct SetOut: Decodable, Equatable, Sendable {
        let truncated: Bool
        let warnings: [String]?
        let infos: [String]?
        let warningsLen: Int
        let infosLen: Int
        let omittedWarningLine: String
        let omittedInfoLine: String
        let countWarnings: Int
        let countInfos: Int
        let size: Int
        let numErrors: Int
    }

    @Test("dedup, merge, limits and counts match Go")
    func set() throws {
        try Fixtures.check("promql/annotations-set.jsonl", FixtureCase<SetIn, SetOut>.self) {
            input in
            var annos = Annotations()
            for a in input.adds ?? [] {
                annos.add(a.build()!)
            }
            if let merges = input.merge, !merges.isEmpty {
                var other = Annotations()
                for a in merges {
                    other.add(a.build()!)
                }
                annos.merge(other)
            }

            let counts = annos.countWarningsAndInfo()
            let size = annos.count
            let numErrors = annos.asErrors().count

            let rendered = annos.asStrings(
                query: input.query, maxWarnings: input.maxWarnings, maxInfos: input.maxInfos)
            let warningsLen = rendered.warnings.count
            let infosLen = rendered.infos.count

            // Split before sorting: the omitted-count line starts with a digit, so
            // sorting moves it off the end.
            let (rawWarnings, omittedW) = Self.splitOmitted(rendered.warnings, noun: "warning")
            let (rawInfos, omittedI) = Self.splitOmitted(rendered.infos, noun: "info")
            let truncated = !omittedW.isEmpty || !omittedI.isEmpty

            let warnings = rawWarnings.sorted()
            let infos = rawInfos.sorted()

            return SetOut(
                truncated: truncated,
                // Go leaves these out when truncated: its map iteration makes the
                // surviving subset random, so there is nothing to compare.
                warnings: truncated ? nil : warnings,
                infos: truncated ? nil : infos,
                warningsLen: warningsLen,
                infosLen: infosLen,
                omittedWarningLine: omittedW,
                omittedInfoLine: omittedI,
                countWarnings: counts.countWarnings,
                countInfos: counts.countInfo,
                size: size,
                numErrors: numErrors)
        }
    }

    private static func splitOmitted(
        _ lines: [String], noun: String
    ) -> (rest: [String], omitted: String) {
        guard let last = lines.last else { return (lines, "") }
        let suffix = " more \(noun) annotations omitted"
        if last.count > suffix.count, last.hasSuffix(suffix) {
            return (Array(lines.dropLast()), last)
        }
        return (lines, "")
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("Annotation invariants")
struct AnnotationInvariantTests {

    @Test("the sentinel text is the message prefix")
    func sentinelIsPrefix() {
        // Go builds every annotation as fmt.Errorf("%w: ...", PromQLWarning), so the
        // sentinel's own text leads the message. The port depends on that to carry
        // the kind as an enum instead of an unwrap chain.
        #expect(AnnotationBase.invalidRatioWarning.text.hasPrefix("PromQL warning: "))
        #expect(AnnotationBase.possibleNonCounterInfo.text.hasPrefix("PromQL info: "))
    }

    @Test("an empty query suppresses the position suffix")
    func noQueryNoPosition() {
        let anno = newSortInRangeQueryWarning(PositionRange(start: 4, end: 9))
        let bare = anno.description
        #expect(!bare.contains("("))
        anno.setQuery("sum(foo)")
        #expect(anno.description == "\(bare) (1:5)")
    }

    @Test("dedup keys on the query-less message, so position is not part of it")
    func dedupIgnoresPosition() {
        // Two identical warnings at different positions collapse to one, and the
        // **last** one wins: Add merges the incoming error into the stored one, and
        // annoErr.Merge returns the receiver — which is the new annotation, not the
        // previously stored one (annotations.go:49). So the surviving position is
        // the most recent. The fixture caught this; the obvious guess is wrong.
        var annos = Annotations()
        annos.add(newMixedFloatsHistogramsWarning("a", PositionRange(start: 0, end: 3)))
        annos.add(newMixedFloatsHistogramsWarning("a", PositionRange(start: 8, end: 11)))
        #expect(annos.count == 1)
        let (warnings, infos) = annos.asStrings(
            query: "foo bar baz qux", maxWarnings: 0, maxInfos: 0)
        #expect(infos.isEmpty)
        #expect(warnings.count == 1)
        #expect(warnings[0].hasSuffix("(1:9)"), "\(warnings[0])")
    }

    @Test("the monotonicity annotation accumulates rather than deduplicating")
    func monotonicityAccumulates() {
        // annotations.go:350 — merging widens the timestamp and bucket ranges and
        // grows the sample count, so three occurrences report "over 3 samples"
        // spanning the outermost timestamps.
        var annos = Annotations()
        for (ts, minB, maxB, diff) in [
            (5_000 as Int64, 1.0, 2.0, 0.5),
            (1_000, 0.5, 4.0, 0.25),
            (9_000, 2.0, 3.0, 0.75),
        ] {
            annos.add(
                newHistogramQuantileForcedMonotonicityInfo(
                    "foo", PositionRange(start: 0, end: 3), ts, minB, maxB, diff))
        }
        #expect(annos.count == 1)
        let (_, infos) = annos.asStrings(query: "foo", maxWarnings: 0, maxInfos: 0)
        #expect(infos.count == 1)
        let text = infos[0]
        #expect(text.contains("from buckets 0.5 to 4"))
        #expect(text.contains("max diff of 0.75"))
        #expect(text.contains("over 3 samples"))
        #expect(text.contains("from 1970-01-01T00:00:01Z to 1970-01-01T00:00:09Z"))
    }

    @Test("HistogramOperation cannot express Go's unknown-operation default")
    func unknownOperationIsUnrepresentable() {
        // Documented divergence, and the reason the message fixture skips four
        // cases: Go's HistogramOperation is a named string type, so an unexpected
        // value renders "unknown operation". A Swift enum's raw-value init simply
        // fails, which is a compile-time-safe narrowing rather than a wrong string.
        #expect(HistogramOperation(rawValue: "bogus") == nil)
        #expect(HistogramOperation(rawValue: "") == nil)
        #expect(HistogramOperation(rawValue: "addition")?.goString == "addition")
    }
}
