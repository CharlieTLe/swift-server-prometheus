// promoracle emits golden fixtures describing Go's exact behaviour, so the Swift
// port can be differentially tested without a Go toolchain at test time.
//
// Usage:
//
//	promoracle gen <suite>    # deterministic corpus -> JSONL on stdout
//	promoracle suites         # list suite names
//
// Every suite generates its own corpus from a fixed seed, so regeneration is
// reproducible and `Scripts/verify-fixtures.sh` can diff it against the
// committed copy to detect upstream drift.
//
// Build with the DEFAULT build tags: labels.Hash() is implementation-dependent
// and we deliberately match stringlabels, the default. See docs/DECISIONS.md ADR-1.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

// Case is one fixture line. `In` and `Out` are suite-specific.
type Case struct {
	ID  string `json:"id"`
	In  any    `json:"in"`
	Out any    `json:"out"`
}

type emitter struct {
	w   *bufio.Writer
	enc *json.Encoder
	n   int
}

func (e *emitter) emit(id string, in, out any) {
	if err := e.enc.Encode(Case{ID: id, In: in, Out: out}); err != nil {
		panic(err)
	}
	e.n++
}

var suites = map[string]func(*emitter){
	"gocompat/floatformat":         genFloatFormat,
	"gocompat/quote":               genQuote,
	"gocompat/varint":              genVarint,
	"hash/xxhash64":                genXXHash64,
	"hash/crc32c":                  genCRC32C,
	"math/kahan":                   genKahan,
	"labels/labels":                genLabels,
	"labels/compare":               genLabelsCompare,
	"labels/hashnames":             genLabelsHashNames,
	"encoding/encbuf":              genEncbuf,
	"gocompat/floatparse":          genFloatParse,
	"gocompat/unquote":             genUnquote,
	"gocompat/duration":            genDuration,
	"labels/builder":               genLabelsBuilder,
	"labels/matcher":               genMatcher,
	"labels/stablehash":            genStableHash,
	"labels/omfloat":               genOpenMetricsFloat,
	"regex/simplefold":             genSimpleFold,
	"regex/unicodetable":           genUnicodeTable,
	"regex/parse":                  genRegexParse,
	"regex/match":                  genRegexMatch,
	"regex/setmatches":             genRegexSetMatches,
	"regex/quotemeta":              genQuoteMeta,
	"regex/submatch":               genRegexSubmatch,
	"histogram/bounds":             genHistogramBounds,
	"histogram/integer":            genHistogramInteger,
	"histogram/integer-compact":    genHistogramCompact,
	"histogram/integer-reduce":     genHistogramReduce,
	"histogram/integer-validate":   genHistogramValidate,
	"histogram/integer-equals":     genHistogramEquals,
	"histogram/float":              genFloatHistogram,
	"histogram/float-copytoschema": genFloatHistogramCopyToSchema,
	"histogram/float-equals":       genFloatHistogramEquals,
	"histogram/float-scale":        genFloatHistogramScale,
	"histogram/float-add":          genFloatHistogramAdd,
	"histogram/float-kahanadd":     genFloatHistogramKahanAdd,
	"histogram/float-reduce":       genFloatHistogramReduce,
	"histogram/float-detectreset":  genFloatHistogramDetectReset,
	"histogram/float-trim":         genFloatHistogramTrim,
	"histogram/nhcb-classic":       genNHCBToClassic,
	"gocompat/log2":                genGoLog2,
	"promql/lex":                   genPromQLLex,
	"promql/posrange":              genPromQLPosRange,
	"promql/functions":             genPromQLFunctions,
	"promql/functionnames":         genPromQLFunctionNames,
	"promql/valuetype":             genPromQLValueType,
	"promql/parse":                 genPromQLParse,
	"promql/seriesdesc":            genPromQLSeriesDesc,
	"promql/metric":                genPromQLMetric,
	"promql/metricselector":        genPromQLMetricSelector,
	"promql/modelduration":         genPromQLModelDuration,
	"gocompat/intparse":            genGoParseInt,
	// Phase 5.
	"promql/annotations":        genPromQLAnnotations,
	"promql/annotations-set":    genPromQLAnnotationsSet,
	"promql/timestamp":          genPromQLTimestamp,
	"promql/timestamp-floatsec": genPromQLTimestampFloatSeconds,
	"storage/errors":            genStorageErrors,
	"storage/duplicate":         genStorageDuplicateErrors,
	"chunkenc/encoding":         genChunkEncEncoding,
	"chunkenc/valuetype":        genChunkEncValueType,
	"chunkenc/compatible":       genChunkEncCompatible,
	"chunkenc/xor":              genChunkEncXOR,
	"chunkenc/xor2":             genChunkEncXOR2,
	"index/postings":            genIndexPostings,
	"chunks/headref":            genChunksHeadRef,
	"chunks/blockref":           genChunksBlockRef,
	"chunks/framing":            genChunksFraming,
	"chunks/batch":              genChunksBatch,
	"index/reader":              genIndexReader,
	"index/pfm":                 genPostingsForMatchers,
	"index/findintersecting":    genFindIntersecting,
	"block/labels":              genBlockLabelQueries,
	"block/meta":                genBlockMeta,
	"gocompat/time-rfc3339":     genGoTimeRFC3339,
	"gocompat/time-unixmilli":   genGoTimeUnixMilli,
	"storage/buffer":            genStorageBuffer,
	"storage/memoized":          genStorageMemoized,
	"storage/listseries":        genStorageListSeries,
	// The Phase 5 in-memory Queryable's contract, pinned against a real tsdb.DB
	// through util/teststorage. See oracle/suites_storage_memselect.go.
	"storage/mem-select":       genStorageMemSelect,
	"storage/mem-labels":       genStorageMemLabels,
	"promql/value":             genPromQLValue,
	"promql/value-sort":        genPromQLValueSort,
	"promql/storageseries":     genPromQLStorageSeries,
	"gocompat/exp2":            genGoExp2,
	"promql/bucketquantile":    genPromQLBucketQuantile,
	"promql/bucketfraction":    genPromQLBucketFraction,
	"promql/histogramquantile": genPromQLHistogramQuantile,
	"promql/histogramfraction": genPromQLHistogramFraction,
	// Phase 5: the math routines the evaluator reaches that neither Swift's
	// standard library nor libm reproduce. See oracle/suites_gomath.go.
	"gocompat/log":              genGoLog,
	"gocompat/exp":              genGoExp,
	"gocompat/pow":              genGoPow,
	"gocompat/mod":              genGoMod,
	"gocompat/minmax":           genGoMinMax,
	"gocompat/ldexp":            genGoLdexp,
	"gocompat/duration-seconds": genGoDurationSeconds,
	"promql/preprocess":         genPromQLPreprocess,
	"promql/histogram-stats":    genPromQLHistogramStats,
	// Phase 5: the transcendentals `promql/functions.go` reaches through
	// `simpleFloatFunc`. Every one of them diverges from libm on 15-67% of
	// inputs. See oracle/suites_gomath_trig.go.
	"gocompat/sin":  genGoSin,
	"gocompat/cos":  genGoCos,
	"gocompat/tan":  genGoTan,
	"gocompat/asin": genGoAsin,
	"gocompat/acos": genGoAcos,
	"gocompat/atan": genGoAtan,
	// `atan2` is PromQL's only binary math operator, and scalarBinop refuses it until
	// GoMath.atan2 exists. See the tail of oracle/suites_gomath_trig.go.
	"gocompat/atan2": genGoAtan2,
	"gocompat/log10": genGoLog10,
	// Phase 5: the hyperbolics `promql/functions.go` reaches through
	// `simpleFloatFunc`, plus `math.Log1p`, which three of them are built on and
	// which has no PromQL wrapper of its own. Every one diverges from libm on
	// 5-70% of inputs. See oracle/suites_gomath_hyperbolic.go.
	"gocompat/sinh":  genGoSinh,
	"gocompat/cosh":  genGoCosh,
	"gocompat/tanh":  genGoTanh,
	"gocompat/asinh": genGoAsinh,
	"gocompat/acosh": genGoAcosh,
	"gocompat/atanh": genGoAtanh,
	"gocompat/log1p": genGoLog1p,
	// Phase 5: prometheus/schema, which `functions.go` and `engine.go` reach for
	// `IsMetadataLabel` and `Metadata.SetToLabels`.
	// See oracle/suites_schema.go.
	"schema/metadatalabel": genSchemaMetadataLabel,
	"schema/metadata":      genSchemaMetadata,
	// Phase 5: `promql.FunctionCalls`' element-wise arithmetic bodies, called
	// directly — no running engine needed, because FunctionCall and every type in
	// its signature are exported. See
	// oracle/suites_promql_functions_elementwise.go.
	"promql/functioncallnames":     genPromQLFunctionCallNames,
	"promql/functions-elementwise": genPromQLFunctionsElementwise,
	// Phase 5: the calendar half of `time.Time`, which the eight date functions
	// read, and the date functions themselves. See
	// oracle/suites_gotime_calendar.go.
	"gocompat/time-calendar": genGoTimeCalendar,
	"promql/functions-date":  genPromQLFunctionsDate,
	// Phase 5: the histogram family. See
	// oracle/suites_promql_functions_histogram.go.
	"promql/functions-histogram": genPromQLFunctionsHistogram,
	// Phase 5: the float-only range aggregations. See
	// oracle/suites_promql_functions_overtime.go.
	"promql/functions-overtime": genPromQLFunctionsOverTime,
	// Phase 5: the four sorts, and the two pieces of machinery they need to be
	// byte-exact about — Go's pdqsort and natsort.Compare. Neither PromQL comparator
	// is a strict weak ordering, so the ALGORITHM is the contract. Note
	// `gocompat/sort` is pinned to a Go TOOLCHAIN rather than to prometheus v3.13.2;
	// see oracle/suites_gosort.go.
	"gocompat/sort":         genGoPdqsort,
	"gocompat/natsort":      genGoNatsort,
	"promql/functions-sort": genPromQLFunctionsSort,
	// Phase 5: the first of engine.go — the query planner's time arithmetic
	// (`FindMinMaxTime`) and `limit_ratio`'s sampler. Both exported and both
	// storage-free, which is what makes them portable before the evaluator exists.
	// See oracle/suites_promql_engine_range.go.
	"promql/minmaxtime":   genPromQLMinMaxTime,
	"promql/ratiosampler": genPromQLRatioSampler,
	// Phase 5: engine.go's front door — NewInstantQuery/NewRangeQuery up to but not
	// including Exec. See oracle/suites_promql_engine_newquery.go.
	"promql/newquery": genPromQLEngineNewQuery,
	// Phase 5: engine.go's error vocabulary, and `sort.Sort(Matrix)` — which is exported
	// through Matrix's sort.Interface methods. See
	// oracle/suites_promql_engine_errors.go.
	"promql/queryerrors": genPromQLQueryErrors,
	"promql/matrixsort":  genPromQLMatrixSort,
	// Phase 5: the EXECUTION path, as far as it is ported — instant queries over
	// expressions that never touch the storage. See
	// oracle/suites_promql_engine_exec.go.
	"promql/exec": genPromQLExec,
	// Phase 5: the RANGE evaluation — execEvalStmt's second half, rangeEval's
	// multi-step assembly, addToSeries and StepInvariantExpr's step duplication. A
	// separate suite because a range query's input shape is start/end/step, and one
	// fixture file holds one in/out shape. See
	// oracle/suites_promql_engine_rangequery.go.
	"promql/exec-range": genPromQLExecRange,
	// Phase 5: util/convertnhcb, classic histogram samples -> one NHCB. Exported
	// and pure, so it is driven directly. Worth ~195 exit-gate assertions. See
	// oracle/suites_convertnhcb.go.
	"histogram/convertnhcb": genConvertNHCB,
	"chunkenc/chunkmeta":    genChunkMeta,
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "tables":
		if len(os.Args) != 3 {
			usage()
		}
		fn, ok := tables[os.Args[2]]
		if !ok {
			fmt.Fprintf(os.Stderr, "unknown table %q\n", os.Args[2])
			os.Exit(2)
		}
		w := bufio.NewWriterSize(os.Stdout, 1<<20)
		fn(w)
		if err := w.Flush(); err != nil {
			panic(err)
		}
	case "table-names":
		names := make([]string, 0, len(tables))
		for k := range tables {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Println(n)
		}
	case "suites":
		names := make([]string, 0, len(suites))
		for k := range suites {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Println(n)
		}
	case "gen":
		if len(os.Args) != 3 {
			usage()
		}
		fn, ok := suites[os.Args[2]]
		if !ok {
			fmt.Fprintf(os.Stderr, "unknown suite %q; try `promoracle suites`\n", os.Args[2])
			os.Exit(2)
		}
		w := bufio.NewWriterSize(os.Stdout, 1<<20)
		e := &emitter{w: w, enc: json.NewEncoder(w)}
		fn(e)
		if err := w.Flush(); err != nil {
			panic(err)
		}
		fmt.Fprintf(os.Stderr, "%s: %d cases\n", os.Args[2], e.n)
	case "parse-corpus":
		// Extracts upstream's own parser case list into a committed corpus file.
		// Run from the copy phase of Scripts/regen-fixtures.sh, before `gen`.
		if len(os.Args) != 3 {
			usage()
		}
		inputs, err := extractParseTestInputs(os.Args[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse-corpus: %v\n", err)
			os.Exit(1)
		}
		w := bufio.NewWriterSize(os.Stdout, 1<<20)
		writeParseCorpus(w, inputs)
		if err := w.Flush(); err != nil {
			panic(err)
		}
		fmt.Fprintf(os.Stderr, "parse-corpus: %d inputs\n", len(inputs))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr,
		"usage: promoracle gen <suite> | suites | tables <name> | table-names | parse-corpus <parse_test.go>")
	os.Exit(2)
}
