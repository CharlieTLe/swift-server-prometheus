//===----------------------------------------------------------------------===//
// Ported from github.com/prometheus/common@v0.69.0 model/metric.go, model/labels.go
//
// prometheus/common/model is an implicit hard dependency of the whole port; we
// port only the subset actually used. `Labels.String()` consults
// `LegacyValidation.IsValidLabelName` to decide whether to quote a label name,
// so this is on the byte-exactness path.
//===----------------------------------------------------------------------===//

/// Go: `model.ValidationScheme`.
public enum ValidationScheme: String, Sendable, CaseIterable {
    /// Go: `model.LegacyValidation`.
    case legacy = "legacy"
    /// Go: `model.UTF8Validation`.
    case utf8 = "utf8"

    /// Go: `ValidationScheme.IsValidLabelName`.
    ///
    /// Note: unlike metric names, label names do **not** admit `:`.
    public func isValidLabelName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        switch self {
        case .utf8:
            return true  // a Swift String is always valid UTF-8; cf. ADR-9
        case .legacy:
            for (i, b) in name.utf8.enumerated() {
                let ok =
                    (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                    || b == UInt8(ascii: "_")
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") && i > 0)
                if !ok { return false }
            }
            return true
        }
    }

    /// Go: `ValidationScheme.IsValidMetricName`. Uses `isValidLegacyRune`, which
    /// additionally permits `:`.
    public func isValidMetricName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        switch self {
        case .utf8:
            return true
        case .legacy:
            for (i, b) in name.utf8.enumerated() {
                if !Self.isValidLegacyRune(b, i) { return false }
            }
            return true
        }
    }

    /// Go: `model.isValidLegacyRune`.
    @inlinable
    public static func isValidLegacyRune(_ b: UInt8, _ i: Int) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || b == UInt8(ascii: "_")
            || b == UInt8(ascii: ":")
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") && i > 0)
    }
}

/// Well-known label names. Go: `model` constants plus `model/labels`.
public enum LabelName: Sendable {
    /// Go: `model.MetricNameLabel`.
    public static let metricName = "__name__"
    /// Go: `labels.AlertName`.
    public static let alertName = "alertname"
    /// Go: `labels.BucketLabel`.
    public static let bucket = "le"
    /// Go: `schema.MetadataTypeLabel`.
    public static let type = "__type__"
    /// Go: `schema.MetadataUnitLabel`.
    public static let unit = "__unit__"
}
