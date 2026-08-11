package main

import (
	"encoding/hex"
	"fmt"
	"math/rand"
	"regexp/syntax"
	"unicode"

	// The SAME regexp package Prometheus uses — `github.com/grafana/regexp`, not the stdlib's. They
	// agree on `QuoteMeta`, but pinning against the one the caller actually imports is the point.
	"github.com/grafana/regexp"
)

// ----------------------------------------------------------------- simplefold

type runeIn struct {
	// Hex so the fixture reads as code points rather than decimal noise.
	R string `json:"r"`
}

// genSimpleFold pins the fold orbits the parser depends on. Go bakes (?i) folding
// into character classes at PARSE time, so an orbit mismatch silently changes the
// resulting AST rather than failing loudly.
func genSimpleFold(e *emitter) {
	r := rand.New(rand.NewSource(5150))
	seen := map[rune]bool{}
	add := func(c rune) {
		if c < 0 || c > 0x10FFFF || seen[c] {
			return
		}
		seen[c] = true
		e.emit(fmt.Sprintf("sf/%04X", c), runeIn{R: fmt.Sprintf("%04X", c)},
			fmt.Sprintf("%04X", unicode.SimpleFold(c)))
	}
	// Structural: ASCII, the fold bounds, and the notorious multi-member orbits.
	for c := rune(0); c <= 0x17F; c++ {
		add(c)
	}
	for _, c := range []rune{
		0x0041, 0x1E943, // minFold / maxFold
		0x017F, 0x0053, 0x0073, // ſ / S / s  -- a three-member orbit
		0x212A, 0x004B, 0x006B, // Kelvin / K / k
		0x0130, 0x0131, 0x0345, 0x0399, 0x03B9, 0x1FBE, // dotted I, iota variants
		0x03A3, 0x03C2, 0x03C3, // sigma: three members
		0x1E60, 0x1E61, 0x1E9B,
		0x10FFFF, 0x110000 - 1,
	} {
		add(c)
	}
	// Every rune that actually has an orbit, sampled, plus random probes.
	n := 0
	for c := rune(0); c <= 0x10FFFF; c++ {
		if unicode.SimpleFold(c) != c {
			if n%17 == 0 {
				add(c)
			}
			n++
		}
	}
	for i := 0; i < 1500; i++ {
		add(rune(r.Intn(0x110000)))
	}
}

// -------------------------------------------------------------- unicodetable

type nameIn struct {
	Name string `json:"name"`
}

type unicodeTableOut struct {
	// Whether \p{Name} resolves at all.
	Resolves bool `json:"resolves"`
	// The parsed class of `\p{Name}` as rendered by String(), which is the real
	// contract: it captures the ranges, the sign and the fold merge in one value.
	Class string `json:"class"`
	Err   string `json:"err"`
}

// genUnicodeTable pins \p{...} name resolution.
//
// The important negative case: Go's unicodeTable consults unicode.Categories and
// unicode.Scripts but NEVER unicode.Properties, so \p{White_Space} is an error
// even though the property exists. A merged lookup would wrongly accept it.
func genUnicodeTable(e *emitter) {
	names := []string{
		// Categories, one- and two-letter.
		"L", "Lu", "Ll", "Lt", "Lm", "Lo", "N", "Nd", "P", "S", "Z", "C", "Cc", "Cn", "LC",
		// Scripts.
		"Greek", "Latin", "Han", "Cyrillic", "Arabic", "Hebrew", "Hiragana", "Katakana",
		// Special cases Go handles before the maps.
		"Any", "Assigned", "ASCII", "Ascii", "ascii",
		// Aliases, exercised with underscores/hyphens/spaces since canonicalName strips them.
		"Letter", "Uppercase_Letter", "uppercase letter", "Uppercase-Letter",
		"Decimal_Number", "Other_Letter",
		// Properties: these must NOT resolve.
		"White_Space", "White Space", "Hyphen", "Dash", "Quotation_Mark", "Noncharacter_Code_Point",
		// Nonsense.
		"", "Nope", "Greekk", "l", "lu", "GREEK", "greek", "^Greek",
	}
	i := 0
	for _, name := range names {
		for _, form := range []string{`\p{%s}`, `\P{%s}`, `(?i)\p{%s}`} {
			pat := fmt.Sprintf(form, name)
			out := unicodeTableOut{}
			re, err := syntax.Parse(pat, syntax.Perl|syntax.DotNL)
			if err != nil {
				out.Err = err.Error()
			} else {
				out.Resolves = true
				out.Class = re.String()
			}
			e.emit(fmt.Sprintf("ut/%d", i), nameIn{Name: pat}, out)
			i++
		}
	}
	// Single-letter form without braces, and the \p{^Name} negation.
	for _, pat := range []string{
		`\pL`, `\pN`, `\PL`, `\pZ`, `\pQ`, `\p`, `\p{`, `\p{}`,
		`\p{^L}`, `\P{^L}`, `\p{^Greek}`, `[\pL]`, `[^\pL]`, `[\pL\pN]`, `(?i)[\pL]`,
	} {
		out := unicodeTableOut{}
		re, err := syntax.Parse(pat, syntax.Perl|syntax.DotNL)
		if err != nil {
			out.Err = err.Error()
		} else {
			out.Resolves = true
			out.Class = re.String()
		}
		e.emit(fmt.Sprintf("ut/%d", i), nameIn{Name: pat}, out)
		i++
	}
}

// QuoteMeta, which `promql/info.go` uses to build its info-series selector from label values.
//
// The escape set is `\.+*?()|[]{}^$` and the test is per BYTE: `special` checks `b < utf8.RuneSelf`
// first, so a metacharacter byte inside a multi-byte sequence is never escaped. The corpus therefore
// includes multi-byte input whose continuation bytes collide with metacharacter values.
func genQuoteMeta(e *emitter) {
	n := 0
	emit := func(s string) {
		e.emit(fmt.Sprintf("quotemeta/%d", n), map[string]string{"s": s},
			map[string]string{"out": regexp.QuoteMeta(s)})
		n++
	}
	for _, s := range []string{
		"", "a", "abc", "a.b", ".", "\\", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$",
		`\.+*?()|[]{}^$`, "a\\b", "...", "a|b|c", "^abc$", "[a-z]+", "{1,2}", "(x)",
		// Not special, so untouched: these are the near-misses.
		"-", "_", ":", "/", "#", "!", "<", ">", "=", ",", ";", "%", "&", "@", "~", "`", "'", "\"",
		// A real instance label, which is the actual caller.
		"localhost:9090", "1.2.3.4:9100", "host-1.example.com:80",
		// Multi-byte, including sequences whose continuation bytes are >= 0x80 and so never escaped.
		"é", "日本語", "café.au", "→|←", " .", "𝄞", "á.b",
		// Control bytes and NUL, which are not in the special set.
		"\x00", "a\x00b", "\t", "\n", "\r",
		// Long, so the "no metacharacter found, return the original" fast path and the slow path both
		// run on inputs of the same shape.
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa.",
		".aaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	} {
		emit(s)
	}
}

// FindStringSubmatchIndex + ExpandString, which is what `label_replace` is built on.
//
// Compiled the way `evalLabelReplace` compiles: `"^(?s:" + re + ")$"`. So every pattern here is fully
// anchored and `(?s)` is on, which means `.` matches a newline — a pattern that behaves differently
// unanchored is not what the caller sees.
//
// What has to be reached:
//   - the INDICES, in BYTES, including `-1` pairs for groups that did not participate;
//   - leftmost-FIRST semantics: with `(a|ab)` against `ab` the answer is the first alternative, and an
//     implementation that tracks captures without cutting lower-priority threads gets the other one;
//   - nested and repeated groups, where a repeated group keeps only its LAST iteration;
//   - the `$1` / `${1}` / `$name` template language, whose rules are upstream's own: `$1x` is the name
//     `1x`, a `$` before a non-name expands to nothing, `$$` is a literal `$`, a leading zero
//     disqualifies a number, and an unknown group expands to nothing;
//   - non-ASCII subjects, where byte offsets and rune offsets diverge.
func genRegexSubmatch(e *emitter) {
	n := 0
	emit := func(pattern, subject, template string) {
		out := map[string]any{}
		re, err := regexp.Compile("^(?s:" + pattern + ")$")
		if err != nil {
			out["err"] = err.Error()
		} else {
			idx := re.FindStringSubmatchIndex(subject)
			if idx == nil {
				out["matched"] = false
			} else {
				out["matched"] = true
				out["index"] = idx
				out["expandedHex"] = hex.EncodeToString(
					re.ExpandString([]byte{}, template, subject, idx))
			}
			out["numSubexp"] = re.NumSubexp()
			out["names"] = re.SubexpNames()
		}
		// **The subject and template travel as HEX, not as JSON strings.** `encoding/json` replaces
		// an invalid UTF-8 byte with U+FFFD when marshalling a Go string, so a corpus that carries
		// them as strings tests Go on the raw bytes and the port on the repaired ones — two cases
		// disagreed by exactly that before this was hex. The same trap ADR-9 is about, on the wire
		// rather than in an API.
		e.emit(fmt.Sprintf("submatch/%d", n),
			map[string]string{
				"pattern":  pattern,
				"subject":  hex.EncodeToString([]byte(subject)),
				"template": hex.EncodeToString([]byte(template)),
			}, out)
		n++
	}

	// The shapes `label_replace` is actually used with in the .test files and in practice.
	emit("(.*)", "foo", "$1")
	emit("(.*)", "", "$1")
	emit(".*", "foo", "$1")
	emit("(.*)-(.*)", "a-b", "$2-$1")
	emit("(?P<first>[a-z]+)_(?P<second>[a-z]+)", "ab_cd", "${second}.${first}")
	emit("([^:]+):(\\d+)", "host:9090", "$1")
	emit("([^:]+):(\\d+)", "host:9090", "$2")

	// LEFTMOST-FIRST. `(a|ab)` inside an anchored pattern with a trailing `b?`: the first alternative
	// wins even though the second would consume more.
	emit("(a|ab)b?", "ab", "[$1]")
	emit("(ab|a)b?", "ab", "[$1]")
	emit("(a*)(a*)", "aaa", "[$1][$2]")
	emit("(a*?)(a*)", "aaa", "[$1][$2]")
	emit("(a+)(a*)", "aaa", "[$1][$2]")

	// A group that does not participate: `-1` in the index array, and nothing in the expansion.
	emit("(a)|(b)", "a", "[$1][$2]")
	emit("(a)|(b)", "b", "[$1][$2]")
	emit("(a)?b", "b", "[$1]")
	emit("(a)?b", "ab", "[$1]")

	// A REPEATED group keeps its last iteration only.
	emit("(?:(a)|(b))+", "abab", "[$1][$2]")
	emit("(a|b)+", "abab", "[$1]")
	emit("((a)(b))+", "abab", "[$1][$2][$3]")

	// Nesting.
	emit("((a)(b))", "ab", "[$1][$2][$3]")
	emit("(a(b(c)))", "abc", "[$1][$2][$3]")

	// Zero-width and anchors inside the pattern.
	emit("()", "", "[$1]")
	emit("(^)a", "a", "[$1]")
	emit("a($)", "a", "[$1]")
	emit("(\\b)a", "a", "[$1]")

	// `(?s)` is on, so `.` spans a newline. This is the one place the wrapper is observable.
	emit("(.*)", "a\nb", "[$1]")
	emit("a(.)b", "a\nb", "[$1]")

	// The TEMPLATE language.
	for _, tpl := range []string{
		"$1", "${1}", "$1x", "${1}x", "$0", "$00", "$01", "$2", "$99", "$", "$$", "$$1", "a$1b",
		"$-", "$_", "${}", "${1", "${1x}", "$1$2", "$name", "${name}", "no dollars", "",
		"$1 $1", "${0}", "x$", "$}", "${a-b}",
	} {
		emit("(a)(b)", "ab", tpl)
	}

	// NON-ASCII, where byte offsets and rune offsets differ.
	emit("(.*)", "héllo", "[$1]")
	emit("(h)(é)(l+o)", "héllo", "[$1][$2][$3]")
	emit("(.)(.)", "日本", "[$1][$2]")
	emit("(.*)", "日本語", "[$1]")
	emit("(é)(.*)", "éa", "[$1][$2]")
	// A Unicode group NAME, which `extract` allows because it tests `unicode.IsLetter`.
	emit("(?P<café>a)", "a", "${café}")
	// A subject that is not valid UTF-8 cannot be written as a Go string literal here, but a lone
	// 0x80 byte can: Go decodes it as RuneError with width 1.
	emit("(.*)", "\x80", "[$1]")
	emit("(.)", "\x80", "[$1]")

	// An invalid pattern, which `evalLabelReplace` turns into a panic.
	emit("(", "a", "$1")
	emit("a{2,1}", "a", "$1")
	emit("[z-a]", "a", "$1")
}
