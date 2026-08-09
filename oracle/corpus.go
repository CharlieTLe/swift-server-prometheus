package main

// Corpus extraction for the PromQL parser suites.
//
// The inputs come from two places, and BOTH are committed into Fixtures/ before
// generation so the corpus never depends on the local toolchain (see
// docs/PORTING.md on corpus reproducibility):
//
//   - Fixtures/promql/parse-corpus.txt — every `input:` string literal in the
//     pinned promql/parser/parse_test.go, extracted by `promoracle parse-corpus`
//     during the copy phase of Scripts/regen-fixtures.sh. That file is upstream's
//     own case list: 400-odd expressions chosen to cover the grammar, including
//     the ones that only exist to pin an error message.
//   - Fixtures/promql/testdata/*.test — the promqltest conformance suite, copied
//     verbatim. Queries are pulled off the `eval` lines and series descriptions
//     off the indented lines, using upstream's own regexps so the split matches
//     how promqltest itself reads these files.
//
// Extraction is deliberately a superset: an indented line that is not really a
// series description is still a fine differential case, because both sides are
// handed the same bytes and must agree on the error.

import (
	"bufio"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// ------------------------------------------------------------- parse_test.go

// extractParseTestInputs returns every `input: "..."` string literal in the
// given Go source file, in source order, deduplicated.
//
// Only untyped string literals are taken. A non-literal input (a concatenation
// or a call) is reported on stderr rather than silently dropped, so a future
// upstream bump that introduces one cannot quietly shrink the corpus.
func extractParseTestInputs(path string) ([]string, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		return nil, err
	}

	var out []string
	seen := map[string]bool{}
	skipped := 0

	ast.Inspect(file, func(n ast.Node) bool {
		kv, ok := n.(*ast.KeyValueExpr)
		if !ok {
			return true
		}
		key, ok := kv.Key.(*ast.Ident)
		if !ok || key.Name != "input" {
			return true
		}
		lit, ok := kv.Value.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			skipped++
			return true
		}
		s, err := strconv.Unquote(lit.Value)
		if err != nil {
			skipped++
			return true
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
		return true
	})

	if skipped > 0 {
		fmt.Fprintf(os.Stderr, "parse-corpus: %d non-literal `input:` values skipped\n", skipped)
	}
	return out, nil
}

// writeParseCorpus emits one hex-encoded input per line.
//
// Hex, because a test input can hold a newline, a quote or invalid UTF-8, and the
// corpus has to stay one-case-per-line to be diffable (ADR-9).
func writeParseCorpus(w *bufio.Writer, inputs []string) {
	for _, s := range inputs {
		fmt.Fprintf(w, "%x\n", s)
	}
}

// readParseCorpus reads the committed corpus file back.
func readParseCorpus(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		b, err := hexDecodeString(line)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		out = append(out, string(b))
	}
	return out, nil
}

// ------------------------------------------------------------ promqltest data

// Upstream's own patterns, copied from promql/promqltest/test.go @ v3.13.2, so
// the query/series split matches how promqltest reads the same files.
var (
	patEvalInstantCorpus = regexp.MustCompile(`^eval(?:_(fail|warn|ordered|info))?\s+instant\s+(?:at\s+(.+?))?\s+(.+)$`)
	patEvalRangeCorpus   = regexp.MustCompile(`^eval(?:_(fail|warn|info))?\s+range\s+from\s+(.+)\s+to\s+(.+)\s+step\s+(.+?)\s+(.+)$`)
)

// testdataQueries returns the PromQL expressions and the series-description
// lines found in the committed conformance suite.
func testdataQueries(dir string) (exprs, series []string, err error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.test"))
	if err != nil {
		return nil, nil, err
	}
	sort.Strings(files) // Glob sorts already; explicit because the corpus depends on it.

	seenExpr := map[string]bool{}
	seenSeries := map[string]bool{}

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, nil, err
		}
		for _, raw := range strings.Split(string(data), "\n") {
			// An indented line is a series description: a `load` body, or the
			// expected result of an `eval`. Both go through ParseSeriesDesc
			// upstream (promqltest/test.go:514).
			if strings.HasPrefix(raw, "\t") || strings.HasPrefix(raw, "    ") {
				s := strings.TrimSpace(raw)
				if s == "" || strings.HasPrefix(s, "#") {
					continue
				}
				if !seenSeries[s] {
					seenSeries[s] = true
					series = append(series, s)
				}
				continue
			}
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			var expr string
			switch {
			case patEvalInstantCorpus.MatchString(line):
				expr = patEvalInstantCorpus.FindStringSubmatch(line)[3]
			case patEvalRangeCorpus.MatchString(line):
				expr = patEvalRangeCorpus.FindStringSubmatch(line)[5]
			default:
				continue
			}
			if !seenExpr[expr] {
				seenExpr[expr] = true
				exprs = append(exprs, expr)
			}
		}
	}
	return exprs, series, nil
}

// hexDecodeString is encoding/hex.DecodeString, named to avoid shadowing the
// import used elsewhere in the oracle.
func hexDecodeString(s string) ([]byte, error) {
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("odd-length hex string")
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi, err := hexNibble(s[2*i])
		if err != nil {
			return nil, err
		}
		lo, err := hexNibble(s[2*i+1])
		if err != nil {
			return nil, err
		}
		out[i] = hi<<4 | lo
	}
	return out, nil
}

func hexNibble(c byte) (byte, error) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', nil
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, nil
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, nil
	}
	return 0, fmt.Errorf("invalid hex byte %q", c)
}
