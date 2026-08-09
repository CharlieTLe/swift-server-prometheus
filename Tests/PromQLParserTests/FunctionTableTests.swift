//===----------------------------------------------------------------------===//
// Differential tests for promql/parser/functions.go and value.go.
//
// The function table is generated (Generated/PromQLFunctions.swift), so these
// fixtures are the independent check that the committed table matches Go. A stale
// regeneration or a hand edit fails here rather than surfacing later as a parser
// that accepts the wrong arity.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromQLParser

@Suite("PromQL function table matches Go")
struct FunctionTableTests {

    @Test("the set of function names is exactly Go's")
    func names() throws {
        // One case holding the whole sorted list, so a function the port is missing
        // — or invents — fails rather than simply going unchecked.
        try Fixtures.check("promql/functionnames.jsonl", FixtureCase<String, [String]>.self) {
            _ in
            PromQLFunctions.all.keys.sorted()
        }
    }

    @Test("every function's signature matches Go")
    func signatures() throws {
        struct Out: Decodable, Equatable, Sendable {
            let name: String
            let argTypes: [String]
            let variadic: Int
            let returnType: String
            let experimental: Bool
        }
        let cases = try Fixtures.load(
            "promql/functions.jsonl", FixtureCase<String, Out>.self)
        #expect(cases.count == PromQLFunctions.all.count)
        var mismatches = [String]()
        for c in cases {
            guard let f = PromQLFunctions.lookup(c.in) else {
                mismatches.append("[\(c.id)] missing from the port")
                continue
            }
            let got = Out(
                name: f.name,
                argTypes: f.argTypes.map(\.rawValue),
                variadic: f.variadic,
                returnType: f.returnType.rawValue,
                experimental: f.experimental)
            if got != c.out {
                mismatches.append("[\(c.id)]\n    got  \(got)\n    want \(c.out)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    @Test("ValueType and DocumentedType render the way Go's do")
    func valueTypes() throws {
        struct Out: Decodable, Equatable, Sendable {
            let raw: String
            let documented: String
        }
        try Fixtures.check("promql/valuetype.jsonl", FixtureCase<String, Out>.self) { input in
            let t = ValueType(input)
            return Out(raw: t.rawValue, documented: t.documented)
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("PromQL function table invariants")
struct FunctionTableInvariantTests {

    @Test("variadic encodes three different arities")
    func variadicEncoding() {
        // 0 is fixed arity, negative means unlimited trailing arguments, and a
        // positive value means that many optional ones. The parser's arity checks
        // depend on all three, so pin one example of each from the real table.
        #expect(PromQLFunctions.lookup("abs")?.variadic == 0)
        #expect(PromQLFunctions.lookup("round")?.variadic == 1)
        #expect(PromQLFunctions.lookup("label_join")?.variadic ?? 0 < 0)
    }

    @Test("experimental functions are flagged")
    func experimentalFlagged() {
        // These are gated behind EnableExperimentalFunctions, so the flag has to
        // survive generation or the parser would accept them unconditionally.
        let experimental = PromQLFunctions.all.values.filter(\.experimental).map(\.name).sorted()
        #expect(!experimental.isEmpty)
        // Every experimental function also appears in the table under its own name.
        for name in experimental {
            #expect(PromQLFunctions.lookup(name)?.name == name)
        }
    }

    @Test("every table key matches the entry's own name")
    func keysMatchNames() {
        // Go keys the map by name and stores the name again in the value; the parser
        // reads the value's Name when rendering a Call, so a mismatch would print
        // the wrong function.
        for (key, f) in PromQLFunctions.all {
            #expect(key == f.name)
        }
    }

    @Test("argument types are drawn from the declared value types")
    func argTypesAreKnown() {
        let known: Set<ValueType> = [.none, .vector, .scalar, .matrix, .string]
        for f in PromQLFunctions.all.values {
            for t in f.argTypes {
                #expect(known.contains(t), "\(f.name) takes \(t)")
            }
            #expect(known.contains(f.returnType), "\(f.name) returns \(f.returnType)")
        }
    }
}
