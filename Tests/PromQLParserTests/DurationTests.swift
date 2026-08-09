//===----------------------------------------------------------------------===//
// Differential tests for model.Duration and for strconv.ParseInt/ParseUint.
//
// Both are byte-exact surfaces the parser depends on: `model.Duration.String()`
// renders every offset and range the printer emits, its parse errors reach the
// user through ParseErr, and `parser.number()` relies on ParseInt's base-0 rules
// to read `0755` as 493.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromModel
import Testing

@Suite("model.Duration matches Go")
struct ModelDurationTests {

    struct In: Decodable, Sendable {
        let op: String
        let `in`: String
    }

    struct Out: Decodable, Equatable, Sendable {
        let err: String?
        let nanos: String?
        let str: String?
    }

    @Test("ParseDuration and Duration.String()")
    func durations() throws {
        try Fixtures.check("promql/modelduration.jsonl", FixtureCase<In, Out>.self) { input in
            if input.op == "format" {
                let nanos = Int64(input.in)!
                return Out(
                    err: nil, nanos: nil,
                    str: PromDuration(nanoseconds: nanos).description)
            }
            do {
                let d = try PromDuration.parse(Hex.decode(input.in))
                return Out(err: nil, nanos: String(d.nanoseconds), str: d.description)
            } catch {
                return Out(err: String(describing: error), nanos: nil, str: nil)
            }
        }
    }
}

@Suite("strconv integer parsing matches Go")
struct ParseIntTests {

    struct In: Decodable, Sendable {
        let `in`: String
        let fn: String
        let base: Int
        let bitSize: Int
    }

    struct Out: Decodable, Equatable, Sendable {
        let val: String
        let err: String
    }

    @Test("ParseInt and ParseUint, values and NumError text")
    func integers() throws {
        try Fixtures.check("gocompat/intparse.jsonl", FixtureCase<In, Out>.self) { input in
            let bytes = Hex.decode(input.in)
            if input.fn == "ParseInt" {
                let (v, err) = GoStrconv.parseInt(bytes, base: input.base, bitSize: input.bitSize)
                return Out(val: String(v), err: err.map { $0.description } ?? "")
            }
            let (v, err) = GoStrconv.parseUint(bytes, base: input.base, bitSize: input.bitSize)
            return Out(val: String(v), err: err.map { $0.description } ?? "")
        }
    }
}
