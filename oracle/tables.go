package main

// Generated Swift tables. Reproducible via Scripts/regen-tables.sh.
//
// These exist because the data lives in Go's unicode package and hand
// transcription would be both huge and unverifiable. Emitting them from Go
// ground truth means the tables are correct by construction and can be
// regenerated when the pin moves.

import (
	"bufio"
	"fmt"
	"sort"
	"strconv"
	"unicode"
	"unicode/utf8"
)

var tables = map[string]func(*bufio.Writer){
	"GoIsPrint":     genIsPrintTable,
	"SimpleFold":    genSimpleFoldTable,
	"UnicodeGroups": genUnicodeGroupsTable,
}

func header(w *bufio.Writer, script, doc string) {
	fmt.Fprintf(w, `//===----------------------------------------------------------------------===//
// GENERATED FILE — DO NOT EDIT.
//
// Regenerate with: Scripts/regen-tables.sh
// Emitted from Go %s ground truth by oracle/tables.go.
//
%s//===----------------------------------------------------------------------===//

`, goToolchainVersion(), doc)
	_ = script
}

func goToolchainVersion() string {
	return "unicode/strconv"
}

// ---------------------------------------------------------------- IsPrint

func genIsPrintTable(w *bufio.Writer) {
	type rng struct{ lo, hi rune }
	var ranges []rng
	var cur *rng
	for r := rune(0); r <= 0x10FFFF; r++ {
		if !utf8.ValidRune(r) {
			continue
		}
		if strconv.IsPrint(r) {
			if cur != nil && cur.hi == r-1 {
				cur.hi = r
			} else {
				ranges = append(ranges, rng{r, r})
				cur = &ranges[len(ranges)-1]
			}
		}
	}
	header(w, "GoIsPrint", `// Mirrors Go's strconv.IsPrint (same definition as unicode.IsPrint), as
// compressed inclusive rune ranges.
`)
	fmt.Fprintf(w, "extension GoStrconv {\n")
	fmt.Fprintf(w, "    /// Sorted, non-overlapping inclusive ranges where strconv.IsPrint is true. %d ranges.\n", len(ranges))
	fmt.Fprintf(w, "    static let printableRanges: [(lo: UInt32, hi: UInt32)] = [\n")
	for i, r := range ranges {
		if i%4 == 0 {
			fmt.Fprintf(w, "        ")
		}
		fmt.Fprintf(w, "(0x%04X, 0x%04X), ", r.lo, r.hi)
		if i%4 == 3 {
			fmt.Fprintln(w)
		}
	}
	if len(ranges)%4 != 0 {
		fmt.Fprintln(w)
	}
	fmt.Fprintf(w, "    ]\n}\n")
}

// -------------------------------------------------------------- SimpleFold

func genSimpleFoldTable(w *bufio.Writer) {
	// Go's regexp/syntax bakes case folding into character classes at PARSE time
	// using unicode.SimpleFold, so the port needs the same orbits to produce the
	// same AST. SimpleFold(r) returns the next rune in r's fold orbit, wrapping
	// around to the orbit's smallest member.
	type pair struct{ from, to rune }
	var pairs []pair
	for r := rune(0); r <= 0x10FFFF; r++ {
		f := unicode.SimpleFold(r)
		if f != r {
			pairs = append(pairs, pair{r, f})
		}
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].from < pairs[j].from })

	header(w, "SimpleFold", `// Mirrors Go's unicode.SimpleFold. Only runes with a non-identity orbit are
// listed; everything else folds to itself.
`)
	fmt.Fprintf(w, "extension UnicodeTables {\n")
	fmt.Fprintf(w, "    /// (rune, next-in-fold-orbit) sorted by rune. %d entries.\n", len(pairs))
	fmt.Fprintf(w, "    static let simpleFoldPairs: [(from: UInt32, to: UInt32)] = [\n")
	for i, p := range pairs {
		if i%4 == 0 {
			fmt.Fprintf(w, "        ")
		}
		fmt.Fprintf(w, "(0x%04X, 0x%04X), ", p.from, p.to)
		if i%4 == 3 {
			fmt.Fprintln(w)
		}
	}
	if len(pairs)%4 != 0 {
		fmt.Fprintln(w)
	}
	fmt.Fprintf(w, "    ]\n}\n")
}

// ----------------------------------------------------------- UnicodeGroups

func genUnicodeGroupsTable(w *bufio.Writer) {
	// syntax.Perl enables UnicodeGroups, so \p{Greek}, \pL and friends must
	// resolve to exactly Go's ranges.
	emit := func(label string, m map[string]*unicode.RangeTable) []string {
		names := make([]string, 0, len(m))
		for k := range m {
			names = append(names, k)
		}
		sort.Strings(names)
		fmt.Fprintf(w, "\n    // MARK: - %s\n", label)
		for _, name := range names {
			t := m[name]
			fmt.Fprintf(w, "    static let %s_%s: [(lo: UInt32, hi: UInt32, stride: UInt32)] = [\n",
				label, sanitize(name))
			n := 0
			for _, r := range t.R16 {
				if n%3 == 0 {
					fmt.Fprintf(w, "        ")
				}
				fmt.Fprintf(w, "(0x%04X, 0x%04X, %d), ", r.Lo, r.Hi, r.Stride)
				n++
				if n%3 == 0 {
					fmt.Fprintln(w)
				}
			}
			for _, r := range t.R32 {
				if n%3 == 0 {
					fmt.Fprintf(w, "        ")
				}
				fmt.Fprintf(w, "(0x%06X, 0x%06X, %d), ", r.Lo, r.Hi, r.Stride)
				n++
				if n%3 == 0 {
					fmt.Fprintln(w)
				}
			}
			if n%3 != 0 {
				fmt.Fprintln(w)
			}
			fmt.Fprintf(w, "    ]\n")
		}
		return names
	}

	header(w, "UnicodeGroups", `// Mirrors Go's unicode.Categories, unicode.Scripts and unicode.Properties,
// which back \p{...} when syntax.UnicodeGroups is set (as syntax.Perl sets it).
//
// Ranges carry Go's stride: a stride of 1 is a contiguous range, and a larger
// stride means every Nth rune in [lo, hi].
`)
	fmt.Fprintf(w, "enum UnicodeTables {\n")
	cats := emit("category", unicode.Categories)
	scripts := emit("script", unicode.Scripts)
	props := emit("property", unicode.Properties)

	// Name -> table lookup, so the parser can resolve \p{Name}.
	fmt.Fprintf(w, "\n    // MARK: - Lookup\n")
	fmt.Fprintf(w, "    /// Go: unicode.Categories (%d) + unicode.Scripts (%d) + unicode.Properties (%d).\n",
		len(cats), len(scripts), len(props))
	fmt.Fprintf(w, "    static let groups: [String: [(lo: UInt32, hi: UInt32, stride: UInt32)]] = [\n")
	for _, n := range cats {
		fmt.Fprintf(w, "        %q: category_%s,\n", n, sanitize(n))
	}
	for _, n := range scripts {
		fmt.Fprintf(w, "        %q: script_%s,\n", n, sanitize(n))
	}
	for _, n := range props {
		fmt.Fprintf(w, "        %q: property_%s,\n", n, sanitize(n))
	}
	fmt.Fprintf(w, "    ]\n")
	fmt.Fprintf(w, "}\n")
}

func sanitize(s string) string {
	out := []rune{}
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			out = append(out, c)
		} else {
			out = append(out, '_')
		}
	}
	return string(out)
}
