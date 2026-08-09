//===----------------------------------------------------------------------===//
// Ported from model/histogram/convert.go @ v3.13.2
//
// Turns a native histogram with custom buckets (NHCB) back into classic
// histogram series — `_bucket` with an `le` label per bound, plus `_count` and
// `_sum`. Needed for Remote Write v1 and for migrating off native histograms.
//
// This is the file that gives PromHistogram a dependency on PromLabels, mirroring
// upstream: model/histogram imports model/labels for exactly this.
//===----------------------------------------------------------------------===//

public import PromLabels

private import PromModel

/// Go: the errors `ConvertNHCBToClassic` returns directly.
public enum NHCBConversionError: Error, Equatable, CustomStringConvertible {
    case missingMetricName
    case unsupportedSchema
    case invalidHistogram(String)

    public var description: String {
        switch self {
        case .missingMetricName:
            return "metric name label '__name__' is missing"
        case .unsupportedSchema:
            return "unsupported histogram schema, not a NHCB"
        case .invalidHistogram(let message):
            return message
        }
    }
}

/// Go: the `nhcb any` parameter, which is a `*Histogram` or a `*FloatHistogram`.
///
/// Go's `default:` branch returns `unsupported histogram type: %T` for anything
/// else; an enum makes that case unrepresentable, so it has no Swift counterpart.
public enum NativeHistogramWithCustomBuckets: Sendable {
    case integer(Histogram)
    case float(FloatHistogram)
}

/// Go: `ConvertNHCBToClassic` — emits the classic series equivalent to `nhcb`.
///
/// The caller must ensure `nhcb` really is a valid NHCB. Labels are restored to
/// `builder`'s original contents before returning, because upstream's queue
/// manager relies on the caller's label set not being disturbed.
public func convertNHCBToClassic(
    _ nhcb: NativeHistogramWithCustomBuckets,
    lset: Labels,
    builder: inout LabelsBuilder,
    emitSeries: (Labels, Double) throws -> Void
) throws {
    let baseName = lset[LabelName.metricName]
    if baseName.isEmpty {
        throw NHCBConversionError.missingMetricName
    }

    // The original labels are preserved and restored, so that no modification is
    // made to the label set the caller handed in.
    let oldLabels = builder.labels()
    defer { builder.reset(oldLabels) }

    var customValues: [Double]
    var positiveBuckets: [Double]
    let count: Double
    let sum: Double
    var idx = 0  // Tracks buckets in the classic histogram.
    var currIdx = 0  // Tracks buckets in the native histogram.

    switch nhcb {
    case .integer(let h):
        guard isCustomBucketsSchema(h.schema) else {
            throw NHCBConversionError.unsupportedSchema
        }
        // The caller is expected to have validated; Go checks anyway, and calls
        // Validate twice to build the message.
        do {
            try h.validate()
        } catch {
            throw NHCBConversionError.invalidHistogram("\(error)")
        }

        customValues = h.customValues ?? []
        positiveBuckets = [Double](repeating: 0, count: customValues.count + 1)

        // Integer histograms store deltas, so accumulate to absolute counts first.
        var acc: Int64 = 0
        for span in h.positiveSpans {
            for _ in 0..<Int(span.offset) {
                positiveBuckets[idx] = Double(acc)
                idx += 1
            }
            for _ in 0..<Int(span.length) {
                acc += h.positiveBuckets[currIdx]
                positiveBuckets[idx] = Double(acc)
                idx += 1
                currIdx += 1
            }
        }
        count = Double(h.count)
        sum = h.sum

    case .float(let h):
        guard isCustomBucketsSchema(h.schema) else {
            throw NHCBConversionError.unsupportedSchema
        }
        do {
            try h.validate()
        } catch {
            throw NHCBConversionError.invalidHistogram("\(error)")
        }
        customValues = h.customValues ?? []
        positiveBuckets = [Double](repeating: 0, count: customValues.count + 1)

        for span in h.positiveSpans {
            // Float histograms are already absolute, so leave the sparse buckets
            // empty and jump to the next filled index.
            idx += Int(span.offset)
            for _ in 0..<Int(span.length) {
                positiveBuckets[idx] = h.positiveBuckets[currIdx]
                idx += 1
                currIdx += 1
            }
        }
        count = h.count
        sum = h.sum
    }

    // Classic buckets are cumulative.
    var currCount: Double = 0
    for (i, val) in customValues.enumerated() {
        currCount += positiveBuckets[i]
        builder.reset(lset)
        builder.set(LabelName.metricName, baseName + "_bucket")
        builder.set(LabelName.bucket, Labels.formatOpenMetricsFloat(val))
        try emitSeries(builder.labels(), currCount)
    }

    currCount += positiveBuckets[positiveBuckets.count - 1]

    builder.reset(lset)
    builder.set(LabelName.metricName, baseName + "_bucket")
    builder.set(LabelName.bucket, Labels.formatOpenMetricsFloat(.infinity))
    try emitSeries(builder.labels(), currCount)

    builder.reset(lset)
    builder.set(LabelName.metricName, baseName + "_count")
    try emitSeries(builder.labels(), count)

    builder.reset(lset)
    builder.set(LabelName.metricName, baseName + "_sum")
    try emitSeries(builder.labels(), sum)
}
