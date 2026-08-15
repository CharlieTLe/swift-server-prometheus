//===----------------------------------------------------------------------===//
// Ported from model/labels/labels_stringlabels.go (Labels helpers),
// sharding_stringlabels.go (StableHash) and float.go @ v3.13.2
//===----------------------------------------------------------------------===//

private import GoCompat
private import PromHash
public import PromModel

extension Labels {

    // MARK: - Derived label sets

    /// Go: `Labels.DropMetricName()`. Deprecated upstream in favour of
    /// `dropReserved`, kept because ported code still calls it.
    public func dropMetricName() -> Labels {
        dropReserved { $0 == LabelName.metricName }
    }

    /// Go: `Labels.DropReserved(shouldDropFn)`.
    ///
    /// Faithfully preserves Go's early exit: it stops scanning once a label name
    /// begins with a byte greater than `_` (0x5F). Since names are sorted, all
    /// reserved (underscore-prefixed) labels sort before ordinary lowercase
    /// names, so this is safe — but it also means a "reserved" name that sorts
    /// after would *not* be dropped, and we reproduce that.
    public func dropReserved(_ shouldDrop: (String) -> Bool) -> Labels {
        var out: [Label]? = nil
        for (i, l) in self.enumerated() {
            if let first = l.name.utf8.first, first > UInt8(ascii: "_") {
                // Past the reserved range; everything remaining is kept.
                if out != nil { out!.append(contentsOf: self[i...]) }
                break
            }
            if shouldDrop(l.name) {
                if out == nil { out = Array(self[..<i]) }
                continue
            }
            out?.append(l)
        }
        guard let out else { return self }
        return Labels(sortedUnchecked: out)
    }

    /// Go: `Labels.WithoutEmpty()` — drops labels whose value is "".
    public func withoutEmpty() -> Labels {
        guard contains(where: { $0.value.isEmpty }) else { return self }
        return Labels(sortedUnchecked: filter { !$0.value.isEmpty })
    }

    /// Go: `Labels.HasDuplicateLabelNames` — the first repeated name, or nil.
    ///
    /// Compares ADJACENT names only, which is sound because a `Labels` is sorted by name; a duplicate can
    /// therefore only sit next to its twin. `headAppender.getOrCreate` is the caller, and it rejects the whole
    /// append with `label name "%s" is not unique`.
    public func hasDuplicateLabelNames() -> String? {
        var prevName = ""
        for l in self {
            if l.name == prevName {
                return l.name
            }
            prevName = l.name
        }
        return nil
    }

    /// Go: `Labels.MatchLabels(on, names...)`.
    ///
    /// With `on: true` keeps only `names`; with `on: false` drops `names` **and**
    /// `__name__`.
    public func matchLabels(on: Bool, _ names: [String]) -> Labels {
        var b = LabelsBuilder(self)
        if on {
            b.keep(names)
        } else {
            b.del(LabelName.metricName)
            b.del(names)
        }
        return b.labels()
    }

    /// Go: `Labels.Validate(f)` — stops at the first error.
    public func validate(_ body: (Label) throws -> Void) rethrows {
        for l in self { try body(l) }
    }

    /// Go: `Labels.IsValid(scheme)`.
    public func isValid(_ scheme: ValidationScheme) -> Bool {
        for l in self {
            if l.name == LabelName.metricName && !scheme.isValidMetricName(l.value) {
                return false
            }
            if !scheme.isValidLabelName(l.name) { return false }
            // Go additionally requires the value to be valid UTF-8; a Swift
            // String always is. See ADR-9.
        }
        return true
    }

    // MARK: - Stable hashing

    /// Go: `labels.StableHash(ls)`.
    ///
    /// Unlike `Hash()`, this **is** canonical: it uses `name 0xFF value 0xFF`
    /// framing in every Go label implementation, precisely so it can be relied
    /// on across versions and builds. Use it wherever hash stability is part of
    /// the contract.
    public func stableHash() -> UInt64 {
        var b = [UInt8]()
        b.reserveCapacity(1024)
        for l in self {
            b.append(contentsOf: l.name.utf8)
            b.append(Self.sep)
            b.append(contentsOf: l.value.utf8)
            b.append(Self.sep)
        }
        return XXHash64.sum64(b)
    }
}

// MARK: - OpenMetrics float formatting

extension Labels {

    /// Go: `labels.FormatOpenMetricsFloat(f)`.
    ///
    /// Go's `'g'` formatting, but appends ".0" when the result contains neither
    /// "." nor "e", so the value still reads as a float in OpenMetrics output.
    public static func formatOpenMetricsFloat(_ f: Double) -> String {
        // Go hardcodes these common cases.
        if f == 1 { return "1.0" }
        if f == 0 { return "0.0" }
        if f == -1 { return "-1.0" }
        if f.isNaN { return "NaN" }
        if f.isInfinite { return f > 0 ? "+Inf" : "-Inf" }

        let s = GoFloat.format(f, .g, precision: -1)
        if s.contains(".") || s.contains("e") { return s }
        return s + ".0"
    }
}
