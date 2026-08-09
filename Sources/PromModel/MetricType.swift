//===----------------------------------------------------------------------===//
// Ported from prometheus/common/model/metadata.go @ v0.69.0
//===----------------------------------------------------------------------===//

/// Go: `model.MetricType` — the value of the `__type__` metadata label.
///
/// Only the raw strings matter to the port so far: annotations compare and
/// interpolate them (`PossibleNonCounterLabelInfo`), and Phase 8 will parse them
/// out of exposition text.
public enum MetricType: String, Sendable, Hashable, CaseIterable {
    case counter = "counter"
    case gauge = "gauge"
    case histogram = "histogram"
    case gaugeHistogram = "gaugehistogram"
    case summary = "summary"
    case info = "info"
    case stateset = "stateset"
    case unknown = "unknown"
}
