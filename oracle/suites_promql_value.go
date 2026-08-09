package main

// Differential coverage for promql/value.go.
//
// Every String() here is a compatibility surface: promqltest renders results
// through them and compares the text, so a reworded one fails the exit gate
// rather than a unit test. They also all go through
// strconv.FormatFloat(v, 'f', -1, 64) — 'f', not 'g' — which is a different ADR-4
// surface from most of this repo.
//
// Three suites, because a fixture file holds one in/out shape:
//
//   promql/value          the whole value tree: StringValue, Scalar, Series,
//                         FPoint, HPoint, Sample, Vector, Matrix, and the sample
//                         counters and duplicate-labelset checks
//   promql/value-sort     Matrix ordering, which is labels.Compare and therefore
//                         ADR-10 territory
//   promql/storageseries  the promql.Series -> storage.Series bridge, driven by
//                         the same op-script shape as storage/buffer
//
// Two things are NOT in the corpus because they are unexported and so unreachable
// from a separate module: `countSamplesAfter` and `HPoint.size`. `size` is observed
// indirectly, through a one-element Matrix's TotalSamples, which routes through
// `totalHPointSize`. `countSamplesAfter` has no such route, so it is pinned by a
// Swift invariant test built on the size formula this suite does pin — faking an
// oracle for it would only test the fake.
//
// MarshalJSON is deliberately absent: it needs Go's encoding/json float encoder,
// its HTML escaping and its sorted map keys, which are three separate byte-exact
// surfaces belonging to the HTTP API in Phase 9.

import (
	"fmt"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
)

// ---------------------------------------------------------------- wire types

// seriesJSON describes one promql.Series. Floats and histograms are separate
// streams, as they are in the struct.
type seriesJSON struct {
	// Label name/value pairs, flat. Hex-free: the corpus is valid UTF-8 (ADR-9).
	Metric []string `json:"metric"`
	// Timestamp / hex-bit-pattern pairs.
	Floats []pointJSON `json:"floats"`
	// Timestamp / catalogue-index pairs.
	Histograms []hpointJSON `json:"histograms"`
	DropName   bool         `json:"dropName"`
}

type pointJSON struct {
	T string `json:"t"`
	F string `json:"f"`
}

type hpointJSON struct {
	T string `json:"t"`
	// Index into the float-histogram catalogue in suites_storage_iterators.go.
	Hist int `json:"hist"`
}

type sampleJSONValue struct {
	Metric   []string `json:"metric"`
	T        string   `json:"t"`
	F        string   `json:"f"`
	Hist     int      `json:"hist"`
	DropName bool     `json:"dropName"`
}

type valueIn struct {
	// Exactly one of these is populated; `kind` says which.
	Kind   string            `json:"kind"`
	Str    *stringValueJSON  `json:"str"`
	Scalar *pointJSON        `json:"scalar"`
	Point  *pointJSON        `json:"point"`
	HPoint *hpointJSON       `json:"hpoint"`
	Sample *sampleJSONValue  `json:"sample"`
	Series *seriesJSON       `json:"series"`
	Vector []sampleJSONValue `json:"vector"`
	Matrix []seriesJSON      `json:"matrix"`
}

type stringValueJSON struct {
	T string `json:"t"`
	V string `json:"v"`
}

type valueOut struct {
	// The rendered String(), which is the contract.
	String string `json:"string"`
	// parser.ValueType, "" for the types that are not Values.
	Type string `json:"type"`
	// Set for Vector and Matrix.
	TotalSamples *int  `json:"totalSamples"`
	SameLabelset *bool `json:"sameLabelset"`
	// Set for HPoint.
	Size *int `json:"size"`
}

func labelsFrom(ss []string) labels.Labels {
	if len(ss) == 0 {
		return labels.EmptyLabels()
	}
	return labels.FromStrings(ss...)
}

func buildFPoints(in []pointJSON) []promql.FPoint {
	if len(in) == 0 {
		return nil
	}
	out := make([]promql.FPoint, 0, len(in))
	for _, p := range in {
		out = append(out, promql.FPoint{T: parseI64(p.T), F: unfbits(p.F)})
	}
	return out
}

func buildHPoints(in []hpointJSON) []promql.HPoint {
	if len(in) == 0 {
		return nil
	}
	out := make([]promql.HPoint, 0, len(in))
	for _, p := range in {
		fh := floatHistogram(p.Hist)
		if fh == nil {
			panic(fmt.Sprintf("catalogue index %d is not a float histogram", p.Hist))
		}
		out = append(out, promql.HPoint{T: parseI64(p.T), H: fh})
	}
	return out
}

func buildSeries(in seriesJSON) promql.Series {
	return promql.Series{
		Metric:     labelsFrom(in.Metric),
		Floats:     buildFPoints(in.Floats),
		Histograms: buildHPoints(in.Histograms),
		DropName:   in.DropName,
	}
}

func buildSample(in sampleJSONValue) promql.Sample {
	s := promql.Sample{
		T: parseI64(in.T), F: unfbits(in.F),
		Metric: labelsFrom(in.Metric), DropName: in.DropName,
	}
	if in.Hist != 0 {
		fh := floatHistogram(in.Hist)
		if fh == nil {
			panic(fmt.Sprintf("catalogue index %d is not a float histogram", in.Hist))
		}
		s.H = fh
	}
	return s
}

func intPtr(v int) *int { return &v }

// ------------------------------------------------------------- promql/value

func genPromQLValue(e *emitter) {
	for _, c := range valueCases() {
		e.emit(c.id, c.in, runValueCase(c.in))
	}
}

func runValueCase(in valueIn) valueOut {
	var out valueOut
	switch in.Kind {
	case "string":
		v := promql.String{T: parseI64(in.Str.T), V: in.Str.V}
		out.String = v.String()
		out.Type = string(v.Type())
	case "scalar":
		v := promql.Scalar{T: parseI64(in.Scalar.T), V: unfbits(in.Scalar.F)}
		out.String = v.String()
		out.Type = string(v.Type())
	case "fpoint":
		p := promql.FPoint{T: parseI64(in.Point.T), F: unfbits(in.Point.F)}
		out.String = p.String()
	case "hpoint":
		p := buildHPoints([]hpointJSON{*in.HPoint})[0]
		out.String = p.String()
		// size() is unexported, so it is observed through a one-element
		// Matrix's TotalSamples, which routes through totalHPointSize.
		m := promql.Matrix{promql.Series{Histograms: []promql.HPoint{p}}}
		out.Size = intPtr(m.TotalSamples())
	case "sample":
		s := buildSample(*in.Sample)
		out.String = s.String()
	case "series":
		s := buildSeries(*in.Series)
		out.String = s.String()
	case "vector":
		vec := make(promql.Vector, 0, len(in.Vector))
		for _, s := range in.Vector {
			vec = append(vec, buildSample(s))
		}
		out.String = vec.String()
		out.Type = string(vec.Type())
		out.TotalSamples = intPtr(vec.TotalSamples())
		ok := vec.ContainsSameLabelset()
		out.SameLabelset = &ok
	case "matrix":
		m := make(promql.Matrix, 0, len(in.Matrix))
		for _, s := range in.Matrix {
			m = append(m, buildSeries(s))
		}
		out.String = m.String()
		out.Type = string(m.Type())
		out.TotalSamples = intPtr(m.TotalSamples())
		ok := m.ContainsSameLabelset()
		out.SameLabelset = &ok
	default:
		panic("unknown value kind " + in.Kind)
	}
	return out
}

// -------------------------------------------------------- promql/value-sort

type sortIn struct {
	Matrix []seriesJSON `json:"matrix"`
}

type sortOut struct {
	// The metric of each series after sorting, in order.
	Order []string `json:"order"`
}

func genPromQLValueSort(e *emitter) {
	for _, c := range valueSortCases() {
		m := make(promql.Matrix, 0, len(c.in.Matrix))
		for _, s := range c.in.Matrix {
			m = append(m, buildSeries(s))
		}
		sortMatrix(m)
		order := make([]string, 0, len(m))
		for _, s := range m {
			order = append(order, s.Metric.String())
		}
		e.emit(c.id, c.in, sortOut{Order: order})
	}
}

// sortMatrix is sort.Sort(m) — Matrix implements sort.Interface.
func sortMatrix(m promql.Matrix) {
	// Insertion sort against Less, so the result is deterministic regardless of
	// sort.Sort's internal pivot choices. The port's comparator must agree with
	// Less, which is what this pins; sort.Sort's own instability across duplicate
	// label sets is not a contract (see the port's note on Matrix.sort).
	for i := 1; i < len(m); i++ {
		for j := i; j > 0 && m.Less(j, j-1); j-- {
			m.Swap(j, j-1)
		}
	}
}

// ----------------------------------------------------- promql/storageseries

func genPromQLStorageSeries(e *emitter) {
	for _, c := range storageSeriesCases() {
		e.emit(c.id, c.in, runStorageSeriesOps(c.in))
	}
}

type storageSeriesIn struct {
	Series seriesJSON `json:"series"`
	Ops    []iterOp   `json:"ops"`
}

func runStorageSeriesOps(in storageSeriesIn) iterOut {
	ss := promql.NewStorageSeries(buildSeries(in.Series))
	it := ss.Iterator(nil)

	out := iterOut{Steps: []iterStep{}}
	for _, op := range in.Ops {
		step := iterStep{Op: op.Op, Ret: -1}
		switch op.Op {
		case "next":
			step.Ret = int(it.Next())
		case "seek":
			step.Ret = int(it.Seek(parseI64(op.Arg)))
		case "at":
			t, f := it.At()
			step.T, step.F = i64(t), fbits(f)
		case "atT":
			step.T = i64(it.AtT())
		case "atST":
			step.ST = i64(it.AtST())
		case "atFloatHistogram":
			t, fh := it.AtFloatHistogram(nil)
			step.T = i64(t)
			step.Hist = histString(nil, fh)
		case "err":
			if err := it.Err(); err != nil {
				step.Err = err.Error()
			}
		default:
			panic("unknown storageseries op " + op.Op)
		}
		out.Steps = append(out.Steps, step)
	}
	return out
}
