package main

// Differential coverage for schema/labels.go — the three special metadata labels
// and the `Metadata` value that reads and writes them.
//
// `promql` reaches exactly two things here: `IsMetadataLabel`, which
// `functions.go` and `engine.go` hand to `Labels.DropReserved` in eight places,
// and `Metadata.SetToLabels` at engine.go:3351. The rest is pinned now because
// the file is 100 lines and Phase 8's parsers will read all of it.
//
// Two suites because the in/out shapes differ and one fixture file holds one
// shape.
//
// The `Metadata` suite exercises **both** constructions deliberately. A literal
// `Metadata{}` has `Type == ""`; `NewMetadataFromLabels` on a label set with no
// `__type__` produces `Type == "unknown"` instead. Every reader in the file treats
// the two the same, so the pair is what shows that the equivalence is real rather
// than assumed — and it is why `SetToLabels`'s `if Type == MetricTypeUnknown`
// branch can be collapsed in the port.
//
// The builders are emitted **unsorted**. `AddToLabels` appends name, then type,
// then unit, and sorting before rendering would throw that order away — which is
// the one thing a caller building a series from scratch depends on.

import (
	"fmt"

	"github.com/prometheus/common/model"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/schema"
)

// ------------------------------------------------------- schema/metadatalabel

func genSchemaMetadataLabel(e *emitter) {
	names := []string{
		// The three that are metadata labels.
		model.MetricNameLabel, model.MetricTypeLabel, model.MetricUnitLabel,
		// Reserved-looking but not metadata: DropReserved stops scanning at the
		// first name above '_', so these matter to its loop rather than to this
		// predicate — included so a port that conflates the two fails here.
		"__address__", "__scrape_interval__", "__tmp", "__name", "__type", "__unit",
		"_name_", "__NAME__", "__Name__",
		// Ordinary names, and the empty one.
		"", "le", "job", "instance", "quantile", "a", "z", "Z",
		// Boundary bytes around '_' (0x5F): '^' 0x5E, '`' 0x60, and the digits and
		// letters either side.
		"^", "`", "]", "{", "0", "9", "A", "a",
	}
	for i, n := range names {
		e.emit(fmt.Sprintf("islabel/%d", i), n, schema.IsMetadataLabel(n))
	}
}

// ------------------------------------------------------------ schema/metadata

type schemaMetadataIn struct {
	// "literal" builds Metadata{Name, Type, Unit}; "fromLabels" builds it with
	// NewMetadataFromLabels(From).
	Mode string `json:"mode"`
	Name string `json:"name"`
	Type string `json:"type"`
	Unit string `json:"unit"`
	// Label pairs for "fromLabels", flattened name/value.
	From []string `json:"from"`
	// The base for SetToLabels' builder, flattened name/value.
	Base []string `json:"base"`
	// The names IsEmptyFor is probed with.
	Probe []string `json:"probe"`
}

type schemaMetadataOut struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Unit string `json:"unit"`
	// IsTypeEmpty.
	TypeEmpty bool `json:"typeEmpty"`
	// IsEmptyFor, one entry per Probe name.
	EmptyFor []bool `json:"emptyFor"`
	// AddToLabels into a fresh ScratchBuilder, rendered WITHOUT sorting.
	Add string `json:"add"`
	// SetToLabels onto a Builder seeded with Base.
	Set string `json:"set"`
}

func schemaProbeNames() []string {
	return []string{
		model.MetricNameLabel, model.MetricTypeLabel, model.MetricUnitLabel,
		"", "job", "__address__",
	}
}

func runSchemaMetadata(in schemaMetadataIn) schemaMetadataOut {
	var m schema.Metadata
	switch in.Mode {
	case "literal":
		m = schema.Metadata{Name: in.Name, Type: model.MetricType(in.Type), Unit: in.Unit}
	case "fromLabels":
		m = schema.NewMetadataFromLabels(labels.FromStrings(in.From...))
	default:
		panic("unknown mode " + in.Mode)
	}

	emptyFor := make([]bool, 0, len(in.Probe))
	for _, p := range in.Probe {
		emptyFor = append(emptyFor, m.IsEmptyFor(p))
	}

	sb := labels.NewScratchBuilder(0)
	m.AddToLabels(&sb)

	b := labels.NewBuilder(labels.FromStrings(in.Base...))
	m.SetToLabels(b)

	return schemaMetadataOut{
		Name:      m.Name,
		Type:      string(m.Type),
		Unit:      m.Unit,
		TypeEmpty: m.IsTypeEmpty(),
		EmptyFor:  emptyFor,
		Add:       sb.Labels().String(),
		Set:       b.Labels().String(),
	}
}

func genSchemaMetadata(e *emitter) {
	// The values Type is exercised with. "" and "unknown" are the pair the whole
	// suite exists to compare; "counter" is the ordinary case; "nonsense" is a
	// value no enum would hold, and it is reachable — NewMetadataFromLabels copies
	// whatever __type__ says.
	types := []string{"", "unknown", "counter", "gauge", "nonsense", "UNKNOWN"}
	names := []string{"", "http_requests_total", "a"}
	units := []string{"", "seconds", "s"}

	// The bases SetToLabels is applied to: empty, one already carrying all three
	// metadata labels (so the removing behaviour of an empty field is visible),
	// and one carrying only ordinary labels.
	bases := [][]string{
		{},
		{"__name__", "old", "__type__", "summary", "__unit__", "bytes", "job", "j"},
		{"job", "j", "instance", "i"},
	}

	i := 0
	for _, n := range names {
		for _, t := range types {
			for _, u := range units {
				for bi, base := range bases {
					in := schemaMetadataIn{
						Mode: "literal", Name: n, Type: t, Unit: u,
						Base: base, Probe: schemaProbeNames(),
					}
					e.emit(fmt.Sprintf("lit/%d/%d", i, bi), in, runSchemaMetadata(in))
				}
				i++
			}
		}
	}

	// fromLabels, including the sets that have no __type__ at all (which is what
	// produces Type == "unknown" rather than "") and one where __type__ is present
	// but empty — a label with an empty value, which labels.FromStrings drops, so
	// it is the same as absent. Included because "present but empty" is the case a
	// reader of the Go source would expect to behave differently.
	froms := [][]string{
		{},
		{"__name__", "foo"},
		{"__type__", "counter"},
		{"__type__", ""},
		{"__unit__", "seconds"},
		{"__name__", "foo", "__type__", "gauge", "__unit__", "ratio", "job", "j"},
		{"__name__", "", "__type__", "nonsense", "__unit__", ""},
		{"job", "j"},
	}
	for fi, from := range froms {
		for bi, base := range bases {
			in := schemaMetadataIn{
				Mode: "fromLabels", From: from,
				Base: base, Probe: schemaProbeNames(),
			}
			e.emit(fmt.Sprintf("lbls/%d/%d", fi, bi), in, runSchemaMetadata(in))
		}
	}
}
