//===----------------------------------------------------------------------===//
// Ported from schema/labels.go @ v3.13.2
//
// Its own target for the same reason upstream gives it its own package: `schema`
// sits *below* `model/labels` in the import graph and above nothing, and both
// `promql` and (from Phase 8) `model/textparse` read it. Folding it into
// `PromLabels` would invert that edge; folding it into `PromModel` would mix
// `prometheus/schema` with `prometheus/common/model`, which every other target
// here keeps one-to-one with a Go package.
//
// `promql` reaches exactly two things in this file: ``isMetadataLabel(_:)``,
// which `functions.go` and `engine.go` pass to `Labels.DropReserved` in eight
// places, and ``Metadata/setToLabels(_:)`` at engine.go:3351.
//
// **`IgnoreOverriddenMetadataLabelScratchBuilder` is deliberately not here.** Its
// only callers are the three `model/textparse` parsers, which is Phase 8; it is
// noted in docs/HANDOFF.md's deferred list rather than half-ported.
//===----------------------------------------------------------------------===//

public import PromLabels

internal import PromModel

/// Go: `schema.IsMetadataLabel` — whether `name` is one of the three special
/// schema metadata labels.
///
/// The three are `__name__`, `__type__` and `__unit__`. Note this is a *superset*
/// of what `Labels.dropMetricName` drops, which is why the engine passes this
/// function rather than reusing that helper: a PromQL function's result keeps the
/// type and unit of nothing, so all three go.
public func isMetadataLabel(_ name: String) -> Bool {
    name == LabelName.metricName || name == LabelName.type || name == LabelName.unit
}

/// Go: `schema.Metadata` — the metric schema elements that identify a series'
/// shape: its name, type and unit.
///
/// With the type-and-unit feature (PROM-39) these live in labels rather than in a
/// side table, which is why this type exists at all.
///
/// **`type` is a `String`, not ``PromModel/MetricType``.** Go declares it as
/// `model.MetricType`, a named `string` type, and ``newMetadataFromLabels(_:)``
/// copies *whatever* the `__type__` label holds — so a scraped
/// `__type__="nonsense"` flows through with `isTypeEmpty` false and gets written
/// back out by ``addToLabels(_:)``. A Swift enum would narrow that surface and
/// silently drop the value, the same forcing PORTING.md exception 8 records for
/// `HistogramOperation`. Callers that want the enum can initialise
/// `MetricType(rawValue:)` themselves.
public struct Metadata: Sendable, Hashable {

    /// Go: `Metadata.Name` — the final `__name__` for the series, which is not
    /// always the scrape format's metric *family* name: an OpenMetrics family
    /// `acme_request_seconds` yields a Prometheus name `acme_request_seconds_sum`.
    ///
    /// Empty means a nameless metric, which is what a PromQL function returns.
    public var name: String

    /// Go: `Metadata.Type`. Empty is equivalent to `unknown` — see
    /// ``isTypeEmpty``.
    public var type: String

    /// Go: `Metadata.Unit`. Empty means unitless.
    public var unit: String

    public init(name: String = "", type: String = "", unit: String = "") {
        self.name = name
        self.type = type
        self.unit = unit
    }

    /// Go: `schema.NewMetadataFromLabels`.
    ///
    /// Note the asymmetry with ``Metadata/init(name:type:unit:)``: a missing
    /// `__type__` label becomes the **string `"unknown"`** here, not the empty
    /// string. So `Metadata()` and `Metadata(labels: Labels.empty)` are different
    /// values that behave identically — every reader below treats `""` and
    /// `"unknown"` the same.
    public init(labels ls: Labels) {
        var typ = MetricType.unknown.rawValue
        let got = ls[LabelName.type]
        if !got.isEmpty {
            typ = got
        }
        self.name = ls[LabelName.metricName]
        self.type = typ
        self.unit = ls[LabelName.unit]
    }

    /// Go: `Metadata.IsTypeEmpty` — true when the type is unset. Both the empty
    /// string and the literal `"unknown"` count.
    public var isTypeEmpty: Bool {
        type.isEmpty || type == MetricType.unknown.rawValue
    }

    /// Go: `Metadata.IsEmptyFor(labelName)` — whether the field that `labelName`
    /// names is unset.
    ///
    /// **Returns `true` for any label that is not one of the three**, which reads
    /// backwards until you see the caller: `IgnoreOverriddenMetadataLabelScratchBuilder`
    /// (Phase 8) uses it as "this `Add` is not overridden, let it through".
    public func isEmpty(for labelName: String) -> Bool {
        switch labelName {
        case LabelName.metricName: return name.isEmpty
        case LabelName.type: return isTypeEmpty
        case LabelName.unit: return unit.isEmpty
        default: return true
        }
    }

    /// Go: `Metadata.AddToLabels` — appends the non-empty fields to a
    /// `ScratchBuilder`.
    ///
    /// Empty fields are **skipped**, which is the difference from
    /// ``setToLabels(_:)``.
    public func addToLabels(_ b: inout ScratchBuilder) {
        if !name.isEmpty {
            b.add(LabelName.metricName, name)
        }
        if !isTypeEmpty {
            b.add(LabelName.type, type)
        }
        if !unit.isEmpty {
            b.add(LabelName.unit, unit)
        }
    }

    /// Go: `Metadata.SetToLabels` — sets all three on a `LabelsBuilder`, so an
    /// empty field **removes** an existing label rather than leaving it.
    ///
    /// Go writes the type as an `if m.Type == MetricTypeUnknown { Set("") } else
    /// { Set(string(m.Type)) }`, with a comment explaining that unknown is
    /// semantically empty. The branch is behaviourally redundant — the `else` arm
    /// on an empty `Type` sets `""` too — so both arms collapse to one statement
    /// here. Verified by fixture over both spellings rather than assumed.
    public func setToLabels(_ b: inout LabelsBuilder) {
        b.set(LabelName.metricName, name)
        b.set(LabelName.type, isTypeUnknownForSet ? "" : type)
        b.set(LabelName.unit, unit)
    }

    /// The exact predicate Go's `SetToLabels` branches on: `Type ==
    /// MetricTypeUnknown`, which is *narrower* than ``isTypeEmpty`` — it does not
    /// include the empty string. Kept separate so the collapse above stays
    /// verifiable against the source.
    private var isTypeUnknownForSet: Bool {
        type == MetricType.unknown.rawValue
    }
}
