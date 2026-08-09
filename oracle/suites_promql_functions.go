package main

// Differential coverage for promql/parser/functions.go and value.go.
//
// Sources/PromQLParser/Generated/PromQLFunctions.swift is emitted from
// parser.Functions by oracle/tables.go, so it is correct by construction when
// freshly generated. This suite is the independent check: it compares the
// committed Swift table against Go, so a stale regeneration — or a hand edit —
// fails the build instead of passing silently.

import (
	"fmt"
	"sort"

	"github.com/prometheus/prometheus/promql/parser"
)

func genPromQLFunctionNames(e *emitter) {
	// The full name list as a single case, so a function missing from the port — or
	// one it invents — fails rather than merely going unchecked. Kept in its own
	// suite because its output shape differs from the per-function one, and a
	// fixture file holds one shape.
	names := make([]string, 0, len(parser.Functions))
	for name := range parser.Functions {
		names = append(names, name)
	}
	sort.Strings(names)
	e.emit("names", "", names)
}

func genPromQLFunctions(e *emitter) {
	type out struct {
		Name         string   `json:"name"`
		ArgTypes     []string `json:"argTypes"`
		Variadic     int      `json:"variadic"`
		ReturnType   string   `json:"returnType"`
		Experimental bool     `json:"experimental"`
	}

	names := make([]string, 0, len(parser.Functions))
	for name := range parser.Functions {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		f := parser.Functions[name]
		argTypes := make([]string, 0, len(f.ArgTypes))
		for _, t := range f.ArgTypes {
			argTypes = append(argTypes, string(t))
		}
		e.emit(fmt.Sprintf("fn/%s", name), name, out{
			Name:         f.Name,
			ArgTypes:     argTypes,
			Variadic:     f.Variadic,
			ReturnType:   string(f.ReturnType),
			Experimental: f.Experimental,
		})
	}
}

func genPromQLValueType(e *emitter) {
	// Every declared type, plus values that fall through DocumentedType's default.
	types := []parser.ValueType{
		parser.ValueTypeNone, parser.ValueTypeVector, parser.ValueTypeScalar,
		parser.ValueTypeMatrix, parser.ValueTypeString,
		parser.ValueType(""), parser.ValueType("unknown"), parser.ValueType("Vector"),
	}
	for i, t := range types {
		type out struct {
			Raw        string `json:"raw"`
			Documented string `json:"documented"`
		}
		e.emit(fmt.Sprintf("vt/%d", i), string(t),
			out{Raw: string(t), Documented: parser.DocumentedType(t)})
	}
}
