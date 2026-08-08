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
	"RegexGroups":   genRegexGroupsTable,
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

	// Separate lookups per Go's `unicodeTable`, which consults Categories then
	// Scripts and NEVER Properties — a merged map would resolve \p{White_Space},
	// which Go rejects.
	fmt.Fprintf(w, "\n    // MARK: - Lookup\n")
	emitLookup := func(swiftName, prefix string, names []string) {
		fmt.Fprintf(w, "    static let %s: [String: [(lo: UInt32, hi: UInt32, stride: UInt32)]] = [\n", swiftName)
		for _, n := range names {
			fmt.Fprintf(w, "        %q: %s_%s,\n", n, prefix, sanitize(n))
		}
		fmt.Fprintf(w, "    ]\n")
	}
	emitLookup("categories", "category", cats)
	emitLookup("scripts", "script", scripts)
	// Emitted for completeness; \p{...} resolution deliberately does not use it.
	emitLookup("properties", "property", props)
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

// ------------------------------------------------------------- RegexGroups

// genRegexGroupsTable emits the remaining data regexp/syntax needs:
//   - FoldCategory / FoldScript: the extra fold-equivalent code points for
//     \p{...} under (?i). Without these, case-insensitive Unicode classes are
//     silently too small.
//   - CategoryAliases, canonicalised, for inexact \p{...} name matching.
//   - perlGroup / posixGroup: \d \s \w and [:alnum:] etc.
func genRegexGroupsTable(w *bufio.Writer) {
	header(w, "RegexGroups", `// Mirrors unicode.FoldCategory, unicode.FoldScript, unicode.CategoryAliases and
// the perl/posix class tables in regexp/syntax/perl_groups.go.
`)
	fmt.Fprintf(w, "extension UnicodeTables {\n")

	emitTables := func(label string, m map[string]*unicode.RangeTable) []string {
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

	foldCats := emitTables("foldCategory", unicode.FoldCategory)
	foldScripts := emitTables("foldScript", unicode.FoldScript)

	fmt.Fprintf(w, "\n    // MARK: - Fold lookup\n")
	fmt.Fprintf(w, "    static let foldGroups: [String: [(lo: UInt32, hi: UInt32, stride: UInt32)]] = [\n")
	for _, n := range foldCats {
		fmt.Fprintf(w, "        %q: foldCategory_%s,\n", n, sanitize(n))
	}
	for _, n := range foldScripts {
		fmt.Fprintf(w, "        %q: foldScript_%s,\n", n, sanitize(n))
	}
	fmt.Fprintf(w, "    ]\n")

	// CategoryAliases, canonicalised exactly as regexp/syntax does.
	fmt.Fprintf(w, "\n    // MARK: - Category aliases (canonicalised)\n")
	fmt.Fprintf(w, "    static let categoryAliases: [String: String] = [\n")
	akeys := make([]string, 0, len(unicode.CategoryAliases))
	for k := range unicode.CategoryAliases {
		akeys = append(akeys, k)
	}
	sort.Strings(akeys)
	for _, k := range akeys {
		fmt.Fprintf(w, "        %q: %q,\n", canonicalNameGo(k), unicode.CategoryAliases[k])
	}
	fmt.Fprintf(w, "    ]\n")

	fmt.Fprintf(w, "}\n")
}

// canonicalNameGo mirrors regexp/syntax.canonicalName.
func canonicalNameGo(name string) string {
	var b []byte
	first := true
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c == '_' || c == '-' || c == ' ':
			c = ' '
		case first:
			if 'a' <= c && c <= 'z' {
				c -= 'a' - 'A'
			}
			first = false
		default:
			if 'A' <= c && c <= 'Z' {
				c += 'a' - 'A'
			}
		}
		if b == nil {
			if c == name[i] && c != ' ' {
				continue
			}
			b = make([]byte, i, len(name))
			copy(b, name[:i])
		}
		if c == ' ' {
			continue
		}
		b = append(b, c)
	}
	if b == nil {
		return name
	}
	return string(b)
}
