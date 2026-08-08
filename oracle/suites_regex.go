package main

import (
	"fmt"
	"math/rand"
	"regexp/syntax"
	"unicode"
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
