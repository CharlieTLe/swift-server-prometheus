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

    /// Go: `ValidationScheme.IsValidLabelName` over raw **bytes**.
    ///
    /// Note: unlike metric names, label names do **not** admit `:`.
    ///
    /// **This overload is the one that is faithful, and the `String` one is lossy.** Go's
    /// `UTF8Validation` calls `utf8.ValidString(name)`, and a Go `string` is arbitrary bytes — so
    /// `count_values("a\xc5z", …)` is an *error* upstream. Decoding those bytes into a Swift
    /// `String` first substitutes U+FFFD, after which the name is valid UTF-8 by construction and
    /// the check can no longer fail. That is ADR-9's open question, and the exit gate is what
    /// finally reached it: one assertion in `aggregators.test` asserts the failure.
    ///
    /// So any caller holding bytes — `StringLiteral.val` is `[UInt8]` for exactly this reason —
    /// must use this overload rather than decoding first.
    public func isValidLabelName(_ name: [UInt8]) -> Bool {
        if name.isEmpty { return false }
        switch self {
        case .utf8:
            return Self.isValidUTF8(name)
        case .legacy:
            return isValidLegacyLabelName(name)
        }
    }

    /// Go: `utf8.Valid` — the four-range DFA, spelled out.
    ///
    /// Rejects overlong encodings, surrogates (`U+D800`-`U+DFFF`) and anything above `U+10FFFF`,
    /// which is what makes it a *validity* check rather than a length check.
    static func isValidUTF8(_ b: [UInt8]) -> Bool {
        var i = 0
        while i < b.count {
            let c = b[i]
            if c < 0x80 {
                i += 1
                continue
            }
            let need: Int
            var lower: UInt8 = 0x80
            var upper: UInt8 = 0xBF
            switch c {
            case 0xC2...0xDF: need = 1
            // An E0 lead must be followed by A0-BF, or the encoding is overlong.
            case 0xE0: need = 2; lower = 0xA0
            case 0xE1...0xEC: need = 2
            // ED excludes the surrogate range by capping the continuation at 9F.
            case 0xED: need = 2; upper = 0x9F
            case 0xEE...0xEF: need = 2
            case 0xF0: need = 3; lower = 0x90
            case 0xF1...0xF3: need = 3
            // F4 caps at U+10FFFF.
            case 0xF4: need = 3; upper = 0x8F
            // C0, C1 and F5-FF are never legal leads.
            default: return false
            }
            if i + need >= b.count { return false }
            if b[i + 1] < lower || b[i + 1] > upper { return false }
            for k in 2...max(need, 2) where k <= need {
                if b[i + k] < 0x80 || b[i + k] > 0xBF { return false }
            }
            i += need + 1
        }
        return true
    }

    private func isValidLegacyLabelName(_ name: [UInt8]) -> Bool {
        for (i, b) in name.enumerated() {
            let ok =
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || b == UInt8(ascii: "_")
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") && i > 0)
            if !ok { return false }
        }
        return true
    }

    public func isValidLabelName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        switch self {
        case .utf8:
            // A Swift `String` is always valid UTF-8, so this arm cannot fail — which is precisely
            // the lossiness ADR-9 warns about. Callers holding bytes must use the `[UInt8]`
            // overload above.
            return true
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
