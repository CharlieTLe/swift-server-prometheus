package main

// Differential coverage for util/annotations/annotations.go.
//
// The messages are a hard contract: promqltest asserts them verbatim, including
// the trailing `(line:col)`. Two things are pinned separately, because they fail
// for different reasons:
//
//   - promql/annotations      one annotation at a time: the query-less message
//                             (the dedup key) and the rendered message (with
//                             position), for every constructor.
//   - promql/annotations-set  the collection: dedup, merge, AsStrings limits and
//                             CountWarningsAndInfo.
//
// Ordering is deliberately not pinned. `Annotations` is a Go map, so AsStrings
// returns a randomised order and truncation drops a random subset; both sides
// sort before comparing. See docs/PORTING.md.

import (
	"errors"
	"fmt"
	"math"
	"sort"

	"github.com/prometheus/prometheus/promql/parser/posrange"
	"github.com/prometheus/prometheus/util/annotations"
)

func nan() float64         { return math.NaN() }
func inf(sign int) float64 { return math.Inf(sign) }

// unfbits is fbits' inverse.
func unfbits(s string) float64 {
	if s == "" {
		return 0
	}
	var bits uint64
	if _, err := fmt.Sscanf(s, "%016x", &bits); err != nil {
		panic(err)
	}
	return math.Float64frombits(bits)
}

// annoIn mirrors the Swift decoder: `ctor` selects the constructor and the rest
// are its arguments. A flat struct rather than a union because a fixture line
// holds one shape.
type annoIn struct {
	Ctor  string `json:"ctor"`
	Query string `json:"query"`
	Start int    `json:"start"`
	End   int    `json:"end"`

	MetricName  string `json:"metricName"`
	Label       string `json:"label"`
	TypeLabel   string `json:"typeLabel"`
	Operator    string `json:"operator"`
	LhsType     string `json:"lhsType"`
	RhsType     string `json:"rhsType"`
	Aggregation string `json:"aggregation"`
	Operation   string `json:"operation"`

	// Hex bit patterns, not JSON numbers: encoding/json cannot represent NaN or
	// the infinities, and a decimal round trip would not be bit-exact anyway.
	// Repo convention, matching fbits() elsewhere in the oracle.
	F1 string `json:"f1"`
	F2 string `json:"f2"`
	F3 string `json:"f3"`
	Ts int64  `json:"ts"`
}

type annoOut struct {
	// Error() before SetQuery — the string Annotations keys on.
	Message string `json:"message"`
	// Error() after SetQuery(query).
	Rendered string `json:"rendered"`
	// "info" or "warning", via errors.Is against the two sentinels.
	Kind string `json:"kind"`
}

func annoKind(err error) string {
	switch {
	case errors.Is(err, annotations.PromQLInfo):
		return "info"
	case errors.Is(err, annotations.PromQLWarning):
		return "warning"
	}
	return "neither"
}

// buildAnno constructs the annotation named by in.Ctor. Returns nil for an
// unknown name so a typo fails loudly rather than emitting a bogus case.
func buildAnno(in annoIn) error {
	pos := posrange.PositionRange{Start: posrange.Pos(in.Start), End: posrange.Pos(in.End)}
	op := annotations.HistogramOperation(in.Operation)
	f1, f2, f3 := unfbits(in.F1), unfbits(in.F2), unfbits(in.F3)

	switch in.Ctor {
	case "InvalidQuantile":
		return annotations.NewInvalidQuantileWarning(f1, pos)
	case "InvalidRatio":
		return annotations.NewInvalidRatioWarning(f1, f2, pos)
	case "BadBucketLabel":
		return annotations.NewBadBucketLabelWarning(in.MetricName, in.Label, pos)
	case "MixedFloatsHistograms":
		return annotations.NewMixedFloatsHistogramsWarning(in.MetricName, pos)
	case "MixedFloatsHistogramsAgg":
		return annotations.NewMixedFloatsHistogramsAggWarning(pos)
	case "MixedClassicNativeHistograms":
		return annotations.NewMixedClassicNativeHistogramsWarning(in.MetricName, pos)
	case "NativeHistogramNotCounter":
		return annotations.NewNativeHistogramNotCounterWarning(in.MetricName, pos)
	case "NativeHistogramNotGauge":
		return annotations.NewNativeHistogramNotGaugeWarning(in.MetricName, pos)
	case "MixedExponentialCustomHistograms":
		return annotations.NewMixedExponentialCustomHistogramsWarning(in.MetricName, pos)
	case "PossibleNonCounter":
		return annotations.NewPossibleNonCounterInfo(in.MetricName, pos)
	case "PossibleNonCounterLabel":
		return annotations.NewPossibleNonCounterLabelInfo(in.MetricName, in.TypeLabel, pos)
	case "IncompatibleTypesInBinOp":
		return annotations.NewIncompatibleTypesInBinOpInfo(in.LhsType, in.Operator, in.RhsType, pos)
	case "HistogramIgnoredInAggregation":
		return annotations.NewHistogramIgnoredInAggregationInfo(in.Aggregation, pos)
	case "HistogramIgnoredInMixedRange":
		return annotations.NewHistogramIgnoredInMixedRangeInfo(in.MetricName, pos)
	case "IncompatibleBucketLayoutInBinOp":
		return annotations.NewIncompatibleBucketLayoutInBinOpWarning(in.Operator, pos)
	case "SortInRangeQuery":
		return annotations.NewSortInRangeQueryWarning(pos)
	case "NativeHistogramQuantileNaNResult":
		return annotations.NewNativeHistogramQuantileNaNResultInfo(in.MetricName, pos)
	case "NativeHistogramQuantileNaNSkew":
		return annotations.NewNativeHistogramQuantileNaNSkewInfo(in.MetricName, pos)
	case "NativeHistogramFractionNaNs":
		return annotations.NewNativeHistogramFractionNaNsInfo(in.MetricName, pos)
	case "HistogramCounterResetCollision":
		return annotations.NewHistogramCounterResetCollisionWarning(pos, op)
	case "MismatchedCustomBucketsHistograms":
		return annotations.NewMismatchedCustomBucketsHistogramsInfo(pos, op)
	case "HistogramQuantileForcedMonotonicity":
		return annotations.NewHistogramQuantileForcedMonotonicityInfo(
			in.MetricName, pos, in.Ts, f1, f2, f3)
	}
	return nil
}

// Deterministic argument pools. Chosen for the edges that actually bite:
// %q escaping (quotes, backslash, newline, non-ASCII), %g formatting (NaN,
// infinities, exponent boundaries), and empty-vs-set metric names, which switch
// maybeAddMetricName on and off.
//
// Deliberately all valid UTF-8, per ADR-9: these travel through JSON as plain
// strings, and Go's encoding/json silently rewrites invalid UTF-8 to U+FFFD — so
// an invalid-byte case would corrupt its own *input* and fail for a reason that
// has nothing to do with the port. Byte-level %q behaviour is covered by the
// gocompat/quote suite, which takes hex and never builds a String.
var (
	annoMetricNames = []string{
		"", "http_requests_total", `weird"name`, "with\\backslash", "new\nline",
		"héllo", "tab\there", "a", "_", "very_long_metric_name_that_keeps_going_and_going",
	}
	annoLabels    = []string{"le", "", "0.5", `"quoted"`, "+Inf", "not a number"}
	annoFloats    = []float64{0, 1, -1, 0.5, -0.5, 1.5, 2, 1e-5, 1e21, 1234.5, 0.000012345}
	annoQueries   = []string{"", "foo", "sum(rate(foo[5m]))", "foo\nbar", "  histogram_quantile(1.5, x)"}
	annoPositions = [][2]int{{0, 3}, {4, 9}, {-1, -1}, {0, 0}, {12, 30}, {3, 4}}
	annoOps       = []string{"addition", "subtraction", "aggregation", "", "bogus"}
	annoTypes     = []string{"vector", "scalar", "matrix", "string"}
	annoOperators = []string{"+", "-", "*", "/", "==", "and", "unless", "atan2"}
	annoAggs      = []string{"sum", "avg", "topk", "quantile", "count_values"}
	annoTsValues  = []int64{0, 1, 999, 1000, -1, -1000, -1001, 1136239445000, 253402300800000}
)

func genPromQLAnnotations(e *emitter) {
	// Constructors taking only a metric name and a position. Every one of these
	// funnels through either maybeAddMetricName or a bare %q, and both branch on
	// the empty string.
	metricOnly := []string{
		"MixedFloatsHistograms", "MixedClassicNativeHistograms", "NativeHistogramNotCounter",
		"NativeHistogramNotGauge", "MixedExponentialCustomHistograms", "PossibleNonCounter",
		"HistogramIgnoredInMixedRange", "NativeHistogramQuantileNaNResult",
		"NativeHistogramQuantileNaNSkew", "NativeHistogramFractionNaNs",
	}
	for _, ctor := range metricOnly {
		for mi, name := range annoMetricNames {
			for pi, pos := range annoPositions {
				for qi, q := range annoQueries {
					in := annoIn{
						Ctor: ctor, MetricName: name, Query: q,
						Start: pos[0], End: pos[1],
					}
					emitAnno(e, fmt.Sprintf("%s/%d/%d/%d", ctor, mi, pi, qi), in)
				}
			}
		}
	}

	// No arguments beyond the position.
	for _, ctor := range []string{"MixedFloatsHistogramsAgg", "SortInRangeQuery"} {
		for pi, pos := range annoPositions {
			for qi, q := range annoQueries {
				in := annoIn{Ctor: ctor, Query: q, Start: pos[0], End: pos[1]}
				emitAnno(e, fmt.Sprintf("%s/%d/%d", ctor, pi, qi), in)
			}
		}
	}

	// One float: %g at the edges.
	for fi, f := range append(annoFloats, nan(), inf(1), inf(-1)) {
		for pi, pos := range annoPositions {
			for qi, q := range annoQueries {
				in := annoIn{
					Ctor: "InvalidQuantile", F1: fbits(f), Query: q, Start: pos[0], End: pos[1],
				}
				emitAnno(e, fmt.Sprintf("InvalidQuantile/%d/%d/%d", fi, pi, qi), in)
			}
		}
	}

	// Two floats.
	allFloats := append(annoFloats, nan(), inf(1), inf(-1))
	for i, f1 := range allFloats {
		for j, f2 := range allFloats {
			in := annoIn{Ctor: "InvalidRatio", F1: fbits(f1), F2: fbits(f2), Query: "foo", Start: 0, End: 3}
			emitAnno(e, fmt.Sprintf("InvalidRatio/%d/%d", i, j), in)
		}
	}

	// Metric name plus a label: two %q in one message.
	for mi, name := range annoMetricNames {
		for li, label := range annoLabels {
			in := annoIn{
				Ctor: "BadBucketLabel", MetricName: name, Label: label,
				Query: "foo", Start: 0, End: 3,
			}
			emitAnno(e, fmt.Sprintf("BadBucketLabel/%d/%d", mi, li), in)
		}
	}

	// Metric name plus a __type__ value.
	for mi, name := range annoMetricNames {
		for ti, typeLabel := range append(annoTypes, "", "counter", "gauge") {
			in := annoIn{
				Ctor: "PossibleNonCounterLabel", MetricName: name, TypeLabel: typeLabel,
				Query: "foo", Start: 0, End: 3,
			}
			emitAnno(e, fmt.Sprintf("PossibleNonCounterLabel/%d/%d", mi, ti), in)
		}
	}

	// Binary-operator types.
	for li, lhs := range annoTypes {
		for oi, op := range annoOperators {
			for ri, rhs := range annoTypes {
				in := annoIn{
					Ctor: "IncompatibleTypesInBinOp", LhsType: lhs, Operator: op, RhsType: rhs,
					Query: "a + b", Start: 0, End: 5,
				}
				emitAnno(e, fmt.Sprintf("IncompatibleTypesInBinOp/%d/%d/%d", li, oi, ri), in)
			}
		}
	}
	for oi, op := range annoOperators {
		in := annoIn{
			Ctor: "IncompatibleBucketLayoutInBinOp", Operator: op, Query: "a + b",
			Start: 0, End: 5,
		}
		emitAnno(e, fmt.Sprintf("IncompatibleBucketLayoutInBinOp/%d", oi), in)
	}

	// Aggregation name.
	for ai, agg := range annoAggs {
		for pi, pos := range annoPositions {
			in := annoIn{
				Ctor: "HistogramIgnoredInAggregation", Aggregation: agg, Query: "sum(x)",
				Start: pos[0], End: pos[1],
			}
			emitAnno(e, fmt.Sprintf("HistogramIgnoredInAggregation/%d/%d", ai, pi), in)
		}
	}

	// HistogramOperation, including the values that hit its "unknown operation"
	// default — the one place a Swift enum cannot follow Go's open string type.
	for _, ctor := range []string{"HistogramCounterResetCollision", "MismatchedCustomBucketsHistograms"} {
		for oi, op := range annoOps {
			in := annoIn{Ctor: ctor, Operation: op, Query: "a + b", Start: 0, End: 5}
			emitAnno(e, fmt.Sprintf("%s/%d", ctor, oi), in)
		}
	}

	// The monotonicity annotation: RFC3339 rendering of ts/1000 (Go's division
	// truncates toward zero), %g bucket bounds and a %.2g max diff.
	for ti, ts := range annoTsValues {
		for fi, f := range allFloats {
			in := annoIn{
				Ctor: "HistogramQuantileForcedMonotonicity", MetricName: "foo",
				Ts: ts, F1: fbits(f), F2: fbits(f * 2), F3: fbits(f / 3),
				Query: "histogram_quantile(0.9, foo)", Start: 0, End: 27,
			}
			emitAnno(e, fmt.Sprintf("Monotonicity/%d/%d", ti, fi), in)
		}
	}
	for mi, name := range annoMetricNames {
		in := annoIn{
			Ctor: "HistogramQuantileForcedMonotonicity", MetricName: name,
			Ts: 1136239445000, F1: fbits(0.5), F2: fbits(2.5), F3: fbits(0.125),
			Query: "histogram_quantile(0.9, foo)", Start: 0, End: 27,
		}
		emitAnno(e, fmt.Sprintf("Monotonicity/name/%d", mi), in)
	}
}

func emitAnno(e *emitter, id string, in annoIn) {
	err := buildAnno(in)
	if err == nil {
		panic("unknown annotation constructor " + in.Ctor)
	}
	out := annoOut{Message: err.Error(), Kind: annoKind(err)}

	// SetQuery mutates, so the rendered form has to come from a fresh instance to
	// keep Message above meaningful.
	err2 := buildAnno(in)
	var anErr interface{ SetQuery(string) }
	if errors.As(err2, &anErr) {
		anErr.SetQuery(in.Query)
	}
	out.Rendered = err2.Error()

	e.emit(id, in, out)
}

// ------------------------------------------------------------ the collection

type annoSetIn struct {
	// Each element is built by buildAnno and added in order.
	Adds []annoIn `json:"adds"`
	// A second Annotations merged into the first, after the adds.
	Merge []annoIn `json:"merge"`

	Query       string `json:"query"`
	MaxWarnings int    `json:"maxWarnings"`
	MaxInfos    int    `json:"maxInfos"`
}

type annoSetOut struct {
	// True when AsStrings hit maxWarnings/maxInfos. Go then drops a **random**
	// subset, because it is iterating a map, so the surviving strings are not a
	// fixture-able value and Warnings/Infos are left empty. The counts and the
	// omitted-count line below are deterministic and are what gets pinned.
	Truncated bool `json:"truncated"`

	// Sorted, and only populated when Truncated is false: Go's map iteration
	// order is random even without truncation. See the file header.
	Warnings []string `json:"warnings"`
	Infos    []string `json:"infos"`

	// len of each slice AsStrings returned, omitted-count line included.
	WarningsLen int `json:"warningsLen"`
	InfosLen    int `json:"infosLen"`
	// The trailing "N more ... annotations omitted" line, or "" when absent.
	OmittedWarningLine string `json:"omittedWarningLine"`
	OmittedInfoLine    string `json:"omittedInfoLine"`

	// Before AsStrings, so counted off the query-less messages.
	CountWarnings int `json:"countWarnings"`
	CountInfos    int `json:"countInfos"`
	// len(a) after the adds and the merge.
	Size int `json:"size"`
	// AsErrors' length; a separate field because it is a separate method.
	NumErrors int `json:"numErrors"`
}

// splitOmitted separates AsStrings' trailing "N more ... omitted" line from the
// annotations themselves. It must run **before** sorting: the line starts with a
// digit, so sorting moves it to the front and "is it last?" stops being true.
//
// Matching on the suffix rather than recomputing the count keeps the assertion
// honest — it fails if Go ever changes the wording.
func splitOmitted(lines []string, noun string) (rest []string, omitted string) {
	if len(lines) == 0 {
		return lines, ""
	}
	last := lines[len(lines)-1]
	suffix := fmt.Sprintf(" more %s annotations omitted", noun)
	if len(last) > len(suffix) && last[len(last)-len(suffix):] == suffix {
		return lines[:len(lines)-1], last
	}
	return lines, ""
}

func genPromQLAnnotationsSet(e *emitter) {
	// Building blocks, named so the cases below read as scenarios.
	warn := func(name string, start int) annoIn {
		return annoIn{Ctor: "MixedFloatsHistograms", MetricName: name, Start: start, End: start + 3}
	}
	info := func(name string, start int) annoIn {
		return annoIn{Ctor: "PossibleNonCounter", MetricName: name, Start: start, End: start + 3}
	}
	mono := func(ts int64, minB, maxB, diff float64, start int) annoIn {
		return annoIn{
			Ctor: "HistogramQuantileForcedMonotonicity", MetricName: "foo",
			Ts: ts, F1: fbits(minB), F2: fbits(maxB), F3: fbits(diff), Start: start, End: start + 3,
		}
	}

	cases := []struct {
		id string
		in annoSetIn
	}{
		{"empty", annoSetIn{Query: "foo"}},
		{"single-warning", annoSetIn{Adds: []annoIn{warn("a", 0)}, Query: "foo"}},
		{"single-info", annoSetIn{Adds: []annoIn{info("a", 0)}, Query: "foo"}},
		{"mixed", annoSetIn{Adds: []annoIn{warn("a", 0), info("b", 4)}, Query: "foo bar"}},

		// Same message, different positions: the dedup key is the query-less
		// message, so these collapse to one and the *first* position survives.
		{"dedup-same-name", annoSetIn{
			Adds:  []annoIn{warn("a", 0), warn("a", 4), warn("a", 8)},
			Query: "foo bar baz qux",
		}},
		{"distinct-names", annoSetIn{
			Adds:  []annoIn{warn("a", 0), warn("b", 0), warn("c", 0)},
			Query: "foo",
		}},

		// Truncation. Which annotations survive is random in Go, so these cases
		// exist to pin the counts and the omitted-count line, not the selection.
		{"limit-warnings", annoSetIn{
			Adds:        []annoIn{warn("a", 0), warn("b", 0), warn("c", 0), warn("d", 0)},
			Query:       "foo",
			MaxWarnings: 2,
		}},
		{"limit-infos", annoSetIn{
			Adds:     []annoIn{info("a", 0), info("b", 0), info("c", 0)},
			Query:    "foo",
			MaxInfos: 1,
		}},
		{"limit-both", annoSetIn{
			Adds: []annoIn{
				warn("a", 0), warn("b", 0), warn("c", 0),
				info("d", 0), info("e", 0), info("f", 0),
			},
			Query:       "foo",
			MaxWarnings: 1,
			MaxInfos:    2,
		}},
		{"limit-not-reached", annoSetIn{
			Adds:        []annoIn{warn("a", 0)},
			Query:       "foo",
			MaxWarnings: 5,
			MaxInfos:    5,
		}},

		// Merge between two sets.
		{"merge-disjoint", annoSetIn{
			Adds:  []annoIn{warn("a", 0)},
			Merge: []annoIn{info("b", 0)},
			Query: "foo",
		}},
		{"merge-overlapping", annoSetIn{
			Adds:  []annoIn{warn("a", 0)},
			Merge: []annoIn{warn("a", 4), warn("b", 0)},
			Query: "foo bar",
		}},
		{"merge-into-empty", annoSetIn{
			Merge: []annoIn{warn("a", 0)},
			Query: "foo",
		}},

		// The monotonicity annotation accumulates instead of deduplicating: the
		// timestamp and bucket ranges widen and the sample count grows.
		{"mono-single", annoSetIn{Adds: []annoIn{mono(1000, 1, 2, 0.5, 0)}, Query: "foo"}},
		{"mono-widening", annoSetIn{
			Adds: []annoIn{
				mono(5000, 1, 2, 0.5, 0),
				mono(1000, 0.5, 4, 0.25, 0),
				mono(9000, 2, 3, 0.75, 0),
			},
			Query: "foo",
		}},
		{"mono-same-values", annoSetIn{
			Adds:  []annoIn{mono(1000, 1, 2, 0.5, 0), mono(1000, 1, 2, 0.5, 0)},
			Query: "foo",
		}},
		{"mono-merge", annoSetIn{
			Adds:  []annoIn{mono(5000, 1, 2, 0.5, 0)},
			Merge: []annoIn{mono(1000, 0.5, 8, 0.75, 0)},
			Query: "foo",
		}},
		// Different metric names give different messages, so they do not merge.
		{"mono-different-names", annoSetIn{
			Adds: []annoIn{
				mono(1000, 1, 2, 0.5, 0),
				{
					Ctor: "HistogramQuantileForcedMonotonicity", MetricName: "bar",
					Ts: 2000, F1: fbits(1), F2: fbits(2), F3: fbits(0.5), Start: 0, End: 3,
				},
			},
			Query: "foo",
		}},

		// An empty query means no position is appended anywhere.
		{"no-query", annoSetIn{
			Adds:  []annoIn{warn("a", 0), info("b", 0), mono(1000, 1, 2, 0.5, 0)},
			Query: "",
		}},
	}

	for _, c := range cases {
		var annos annotations.Annotations
		for _, in := range c.in.Adds {
			annos.Add(buildAnno(in))
		}
		if len(c.in.Merge) > 0 {
			var other annotations.Annotations
			for _, in := range c.in.Merge {
				other.Add(buildAnno(in))
			}
			annos.Merge(other)
		}

		countW, countI := annos.CountWarningsAndInfo()
		size := len(annos)
		numErrors := len(annos.AsErrors())

		rawWarnings, rawInfos := annos.AsStrings(c.in.Query, c.in.MaxWarnings, c.in.MaxInfos)
		warningsLen, infosLen := len(rawWarnings), len(rawInfos)

		warnings, omittedW := splitOmitted(rawWarnings, "warning")
		infos, omittedI := splitOmitted(rawInfos, "info")
		truncated := omittedW != "" || omittedI != ""

		sort.Strings(warnings)
		sort.Strings(infos)

		out := annoSetOut{
			Truncated:          truncated,
			WarningsLen:        warningsLen,
			InfosLen:           infosLen,
			OmittedWarningLine: omittedW,
			OmittedInfoLine:    omittedI,
			CountWarnings:      countW,
			CountInfos:         countI,
			Size:               size,
			NumErrors:          numErrors,
		}
		if !truncated {
			out.Warnings = warnings
			out.Infos = infos
		}
		e.emit("set/"+c.id, c.in, out)
	}
}
