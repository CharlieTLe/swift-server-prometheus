package main

import (
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
	"regexp/syntax"
	"strconv"
	"strings"
)

type parseOutRegex struct {
	// Go's syntax.Parse(...).String(), or "" when parsing failed.
	Tree string `json:"tree"`
	// The exact error text, which is user-visible through PromQL.
	Err string `json:"err"`
}

// patternCorpus assembles regex patterns from every source available:
//   - Go's own regexp testdata (basic.dat, repetition.dat, nullsubexpr.dat and
//     re2-search.txt), mined for the pattern column;
//   - Prometheus's real-world matcher shapes;
//   - hand-picked syntax corners and malformed input;
//   - random mutations, which is where the accept/reject boundary gets tested.
func patternCorpus() []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if seen[s] {
			return
		}
		seen[s] = true
		out = append(out, s)
	}

	// --- Go's regexp testdata (committed copies) ---------------------------
	//
	// Read from Fixtures/, NOT from $GOROOT: mining the live toolchain would make
	// the corpus depend on the Go version, so CI's Go would build a different
	// corpus and verify-fixtures.sh would report a meaningless diff.
	base := os.Getenv("REGEX_TESTDATA")
	if base == "" {
		base = "../Fixtures/regex/gotestdata"
	}
	for _, name := range []string{"basic.dat", "repetition.dat", "nullsubexpr.dat"} {
		data, err := os.ReadFile(base + "/" + name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: %s unreadable (%v); skipping\n", name, err)
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			if line == "" || strings.HasPrefix(line, "NOTE") || strings.HasPrefix(line, "#") {
				continue
			}
			f := strings.Fields(line)
			// Format: flags<TAB>pattern<TAB>text<TAB>expected...
			if len(f) >= 2 {
				add(f[1])
			}
		}
	}
	// re2-search.txt lists quoted regexps one per line after a "regexps" marker.
	if data, err := os.ReadFile(base + "/re2-search.txt"); err == nil {
		inRegexps := false
		for _, line := range strings.Split(string(data), "\n") {
			switch {
			case line == "regexps":
				inRegexps = true
				continue
			case line == "strings":
				inRegexps = false
				continue
			}
			if inRegexps && strings.HasPrefix(line, `"`) {
				if s, err := strconv.Unquote(line); err == nil {
					add(s)
				}
			}
		}
	}

	// --- Prometheus's real matcher shapes ----------------------------------
	for _, s := range []string{
		"", ".*", ".+", ".?", "foo", "foo.*", ".*foo", ".*foo.*", ".+foo.+",
		".*foo.*|.*bar.*", "foo|bar", "(foo|bar)", ".*(foo|bar).*", ".*[abc].*",
		"-.*-.*-.*-.*", ".*-.*-.*-.*-.*", "(?i)foo", "(?i:foo)", "(?i:(foo|bar))",
		".*(?i:abc).*", ".*((?i)abc).*", ".*(?msU:abc).*", "(?i).*(?-i:abc)def",
		"(?i:(xyz-016a-ixb-dp.*|xyz-016a-ixb-op.*))", "(?s).*", "(?i:(AAA|BBB|ccc))",
		// Unicode folding, which Prometheus's own tests exercise.
		"(?i:(ſſſſ|SSSS))", "(?i)ſ", "(?i)K", "(?i)Σ", "😀", "❤️", "(?i)é",
		"up", "node_cpu_seconds_total", "10.253.57.87:9100",
	} {
		add(s)
	}

	// --- Syntax corners ----------------------------------------------------
	for _, s := range []string{
		// Classes.
		"[a-z]", "[^a-z]", "[]a]", "[-a]", "[a-]", "[a^]", "[[:alnum:]]", "[[:^alnum:]]",
		"[[:foo:]]", "[\\d]", "[\\D]", "[\\s\\w]", "[a-b-c]", "[z-a]", "[\\x41-\\x5a]",
		"[^\\n]", "[\\n]", "[[]", "[]", "[^]", "[a", "[\\", "[a-\\d]",
		// Repetition.
		"a*", "a+", "a?", "a{2}", "a{2,}", "a{2,5}", "a{,5}", "a{}", "a{2,1}",
		"a{1001}", "a{0}", "a**", "a++", "a*?", "a+?", "a??", "a{2}?", "*a", "+a", "?a",
		"(a){2}{3}", "a{2}{3}",
		// Groups and flags.
		"(a)", "(?:a)", "(?P<n>a)", "(?<n>a)", "(?P<>a)", "(?P<1n>a)", "(?P<n a>a)",
		"(?i)a", "(?-i)a", "(?i-s:a)", "(?)", "(?", "(", ")", "(a", "a)", "()",
		"(?P<n>", "(?'n'a)", "(?#comment)", "(?=a)", "(?!a)", "(?<=a)", "(?<!a)",
		// Escapes.
		"\\a", "\\f", "\\n", "\\r", "\\t", "\\v", "\\0", "\\01", "\\012", "\\0123",
		"\\1", "\\x41", "\\x{41}", "\\x{110000}", "\\x{}", "\\x{zz}", "\\xzz",
		"\\Q.+*?\\E", "\\Qab", "\\A", "\\z", "\\b", "\\B", "\\C", "\\_", "\\q", "\\",
		"\\p{Greek}", "\\pL", "\\PL", "\\p{^L}", "\\p{Nope}", "\\p{White_Space}",
		"(?i)\\p{Greek}", "(?i)\\pL", "[\\p{L}\\p{N}]",
		// Anchors and dots.
		"^a$", "^", "$", "^$", "$^", ".", "(?s).", "(?m)^a$", "a$", "\\A a \\z",
		// Alternation factoring, which reshapes the tree.
		"ABC|ABD|AEF|BCX|BCY", "abc|abd", "a|b", "a|b|c", "ab|ac", "a|", "|a", "|",
		"foo|foobar", "x(a|b)|x(c|d)", "(a|b)(c|d)",
		// Nesting.
		strings.Repeat("(", 50) + "a" + strings.Repeat(")", 50),
		strings.Repeat("(", 1200) + "a" + strings.Repeat(")", 1200),
		"a{2}{2}{2}{2}{2}{2}{2}{2}{2}{2}",
		// Invalid UTF-8 in the pattern itself.
		"\xff", "a\x80b", "[\xff]",
	} {
		add(s)
	}

	// --- Random mutations ---------------------------------------------------
	r := rand.New(rand.NewSource(20260808))
	bases := []string{
		"a.*b", "(?i)foo|bar", "[a-z]+", "a{2,5}", "\\p{L}*", "(a|b)?c", "^ab$",
		"[[:alpha:]]{3}", "(?s).*x", "\\Qlit\\E",
	}
	alphabet := []byte(`ab.*+?()[]{}|^$\\-,:0129ipPsSwWdDQEzAbBxu{}<>'!=`)
	for i := 0; i < 4000; i++ {
		s := []byte(bases[r.Intn(len(bases))])
		for m := 0; m < 1+r.Intn(3); m++ {
			switch r.Intn(3) {
			case 0:
				if len(s) > 0 {
					s[r.Intn(len(s))] = alphabet[r.Intn(len(alphabet))]
				}
			case 1:
				p := r.Intn(len(s) + 1)
				s = append(s[:p], append([]byte{alphabet[r.Intn(len(alphabet))]}, s[p:]...)...)
			default:
				if len(s) > 0 {
					p := r.Intn(len(s))
					s = append(s[:p], s[p+1:]...)
				}
			}
		}
		add(string(s))
	}
	return out
}

// genRegexParse pins both halves of the contract: the tree Go builds (via
// String(), which round-trips) and the exact error text when it refuses.
func genRegexParse(e *emitter) {
	for i, pat := range patternCorpus() {
		out := parseOutRegex{}
		// Prometheus's flags: model/labels/regexp.go:69 @ v3.13.2.
		re, err := syntax.Parse(pat, syntax.Perl|syntax.DotNL)
		if err != nil {
			out.Err = err.Error()
		} else {
			out.Tree = re.String()
		}
		e.emit(fmt.Sprintf("p/%d", i), strIn{S: hex.EncodeToString([]byte(pat))}, out)
	}
}
