//===----------------------------------------------------------------------===//
// Differential tests: strconv.ParseFloat, strconv.Unquote, Duration.String.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

struct StrIn: Decodable, Sendable {
    let s: String
    var text: String { String(decoding: Hex.decode(s), as: UTF8.self) }
}

struct ParseOut: Decodable, Equatable, Sendable {
    let err: String
    let bits: String
}

struct UnquoteOut: Decodable, Equatable, Sendable {
    let ok: Bool
    let bytes: String
}

struct DurationIn: Decodable, Sendable {
    let nanos: String
}

@Suite("GoFloat.parse matches strconv.ParseFloat")
struct GoFloatParseTests {

    @Test("every committed fixture case, accepted and rejected")
    func fixtures() throws {
        try Fixtures.check("gocompat/floatparse.jsonl", FixtureCase<StrIn, ParseOut>.self) { input in
            let (v, err) = GoFloat.parseAllowingRange(input.text)
            let kind: String
            switch err {
            case .none: kind = ""
            case .syntax: kind = "syntax"
            case .range: kind = "range"
            }
            return ParseOut(err: kind, bits: String(format: "%016lx", v.bitPattern))
        }
    }

    @Test("Go's syntax quirks")
    func quirks() {
        // Signed NaN is rejected: Go's `special()` falls through the sign case
        // into the infinity branch only, never into the NaN branch.
        #expect(GoFloat.parseAllowingRange("nan").error == nil)
        #expect(GoFloat.parseAllowingRange("+nan").error == .syntax)
        #expect(GoFloat.parseAllowingRange("-nan").error == .syntax)
        // Signed infinity is fine, in either spelling, any case.
        #expect(GoFloat.parseAllowingRange("-Infinity").value == -.infinity)
        #expect(GoFloat.parseAllowingRange("+INF").value == .infinity)
        // "infi" is neither "inf" nor "infinity".
        #expect(GoFloat.parseAllowingRange("infi").error == .syntax)

        // Hex requires the p exponent.
        #expect(GoFloat.parseAllowingRange("0x1p-2").value == 0.25)
        #expect(GoFloat.parseAllowingRange("0x1").error == .syntax)

        // Underscores must separate digits.
        #expect(GoFloat.parseAllowingRange("1_000.5").value == 1000.5)
        for bad in ["1__0", "_1", "1_", "1._5", "1e_5"] {
            #expect(GoFloat.parseAllowingRange(bad).error == .syntax, "\(bad)")
        }
    }

    @Test("overflow is a range error but underflow is not")
    func rangeAsymmetry() {
        let over = GoFloat.parseAllowingRange("1e400")
        #expect(over.value == .infinity)
        #expect(over.error == .range)

        let under = GoFloat.parseAllowingRange("1e-400")
        #expect(under.value == 0)
        #expect(under.error == nil)  // Go returns no error here
    }

    @Test("NaN carries Go's exact payload, not Swift's")
    func nanPayload() {
        // Go's nan() is 0x7FF8000000000001; Swift's Double.nan is ...0000.
        #expect(GoFloat.parseAllowingRange("nan").value.bitPattern == 0x7FF8_0000_0000_0001)
        #expect(Double.nan.bitPattern == 0x7FF8_0000_0000_0000)
    }
}

@Suite("GoStrconv.unquote matches strconv.Unquote")
struct GoUnquoteTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("gocompat/unquote.jsonl", FixtureCase<StrIn, UnquoteOut>.self) { input in
            do {
                let out = try GoStrconv.unquoteBytes(input.text)
                return UnquoteOut(ok: true, bytes: Hex.encode(out))
            } catch {
                return UnquoteOut(ok: false, bytes: "")
            }
        }
    }

    @Test("quote and unquote round-trip over arbitrary bytes")
    func roundTrip() throws {
        // Includes invalid UTF-8, which survives as bytes through \xNN escapes.
        let cases: [[UInt8]] = [
            [], [0x61], [0x80], [0xFF, 0xFE], [0x61, 0x80, 0x62],
            Array("héllo 日本語".utf8), [0x00, 0x7F, 0x1B],
        ]
        for bytes in cases {
            let quoted = GoStrconv.quote(bytes: bytes)
            let back = try GoStrconv.unquoteBytes(quoted)
            #expect(back == bytes, "\(bytes)")
        }
    }

    @Test("raw strings drop carriage returns")
    func rawStrings() throws {
        #expect(try GoStrconv.unquote("`raw`") == "raw")
        #expect(try GoStrconv.unquote("`a\r\nb`") == "a\nb")
    }
}

@Suite("GoDuration.description matches time.Duration.String")
struct GoDurationTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("gocompat/duration.jsonl", FixtureCase<DurationIn, String>.self) {
            GoDuration(nanoseconds: Int64($0.nanos)!).description
        }
    }

    @Test("sub-second values switch to smaller units")
    func subSecond() {
        #expect(GoDuration(nanoseconds: 0).description == "0s")
        #expect(GoDuration(nanoseconds: 1).description == "1ns")
        #expect(GoDuration(nanoseconds: 1_500).description == "1.5µs")
        #expect(GoDuration(nanoseconds: 1_500_000).description == "1.5ms")
        #expect(GoDuration(nanoseconds: 500_000_000).description == "500ms")
    }

    @Test("hours are the largest unit and zero units are omitted")
    func largerUnits() {
        #expect(GoDuration(nanoseconds: 90_000_000_000).description == "1m30s")
        #expect(GoDuration(nanoseconds: 3_661_000_000_000).description == "1h1m1s")
        // A day renders as hours: Go stops at hours because days vary in length.
        #expect(GoDuration(nanoseconds: 86_400_000_000_000).description == "24h0m0s")
        #expect(GoDuration(nanoseconds: -1_500_000_000).description == "-1.5s")
    }

    @Test("Int64.min does not overflow on negation")
    func extremes() {
        // Negating Int64.min traps in Swift, so the magnitude is taken unsigned.
        let s = GoDuration(nanoseconds: .min).description
        #expect(s.hasPrefix("-"))
        #expect(!s.isEmpty)
    }
}
