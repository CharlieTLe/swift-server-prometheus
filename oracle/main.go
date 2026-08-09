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
	"gocompat/time-rfc3339":     genGoTimeRFC3339,
	"gocompat/time-unixmilli":   genGoTimeUnixMilli,
	"storage/buffer":            genStorageBuffer,
	"storage/memoized":          genStorageMemoized,
	"storage/listseries":        genStorageListSeries,
	// The Phase 5 in-memory Queryable's contract, pinned against a real tsdb.DB
	// through util/teststorage. See oracle/suites_storage_memselect.go.
	"storage/mem-select": genStorageMemSelect,
	"storage/mem-labels": genStorageMemLabels,
	"promql/value":              genPromQLValue,
	"promql/value-sort":         genPromQLValueSort,
	"promql/storageseries":      genPromQLStorageSeries,
	"gocompat/exp2":             genGoExp2,
	"promql/bucketquantile":     genPromQLBucketQuantile,
	"promql/bucketfraction":     genPromQLBucketFraction,
	"promql/histogramquantile":  genPromQLHistogramQuantile,
	"promql/histogramfraction":  genPromQLHistogramFraction,
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
	"gocompat/sin":   genGoSin,
	"gocompat/cos":   genGoCos,
	"gocompat/tan":   genGoTan,
	"gocompat/asin":  genGoAsin,
	"gocompat/acos":  genGoAcos,
	"gocompat/atan":  genGoAtan,
	"gocompat/log10": genGoLog10,
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
