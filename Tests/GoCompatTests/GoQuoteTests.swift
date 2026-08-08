//===----------------------------------------------------------------------===//
// Differential tests: Go's strconv.Quote and encoding/binary varints.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import GoCompat

struct BytesIn: Decodable, Sendable {
    let bytes: String
    var raw: [UInt8] { Hex.decode(bytes) }
}

struct VarintIn: Decodable, Sendable {
    let u: String
    let signed: Bool
}

@Suite("GoStrconv.quote matches Go")
struct GoQuoteTests {

    @Test("every committed fixture case, including invalid UTF-8")
    func fixtures() throws {
        try Fixtures.check("gocompat/quote.jsonl", FixtureCase<BytesIn, String>.self) {
            // Byte-level entry point: Go strings may hold invalid UTF-8, which a
            // Swift String cannot represent. See ADR-9.
            GoStrconv.quote(bytes: $0.raw)
        }
    }

    @Test("invalid UTF-8 becomes \\xNN per offending byte")
    func invalidUTF8() {
        #expect(GoStrconv.quote(bytes: [0x80]) == #""\x80""#)
        #expect(GoStrconv.quote(bytes: [0xC0, 0x80]) == #""\xc0\x80""#)
        // Overlong and surrogate encodings are invalid, byte by byte.
        #expect(GoStrconv.quote(bytes: [0xED, 0xA0, 0x80]) == #""\xed\xa0\x80""#)
    }

    @Test("IsPrint table agrees with Go on ASCII boundaries")
    func isPrintASCII() {
        #expect(!GoStrconv.isPrint(0x1F))
        #expect(GoStrconv.isPrint(0x20))  // space is printable
        #expect(GoStrconv.isPrint(0x7E))
        #expect(!GoStrconv.isPrint(0x7F))  // DEL is not
    }
}

@Suite("GoVarint matches encoding/binary")
struct GoVarintTests {

    @Test("encoding every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("gocompat/varint.jsonl", FixtureCase<VarintIn, String>.self) { input in
            var out = [UInt8]()
            if input.signed {
                GoVarint.putVarint(&out, Int64(input.u)!)
            } else {
                GoVarint.putUvarint(&out, UInt64(input.u)!)
            }
            return Hex.encode(out)
        }
    }

    @Test("decoding round-trips the fixtures")
    func roundTrip() throws {
        let cases = try Fixtures.load(
            "gocompat/varint.jsonl", FixtureCase<VarintIn, String>.self)
        for c in cases {
            let encoded = Hex.decode(c.out)
            if c.in.signed {
                let (v, n) = GoVarint.varint(encoded)
                #expect(v == Int64(c.in.u)!, "\(c.id)")
                #expect(n == encoded.count, "\(c.id)")
            } else {
                let (v, n) = GoVarint.uvarint(encoded)
                #expect(v == UInt64(c.in.u)!, "\(c.id)")
                #expect(n == encoded.count, "\(c.id)")
            }
        }
    }

    @Test("Go's negative-return overflow signalling")
    func overflow() {
        // Ten 0x80 bytes then a continuation: more than MaxVarintLen64.
        let tooLong = [UInt8](repeating: 0x80, count: 11)
        let (_, n) = GoVarint.uvarint(tooLong)
        #expect(n == -11)

        // Truncated: Go returns 0 to mean "buffer too small".
        let (_, m) = GoVarint.uvarint([0x80])
        #expect(m == 0)
    }
}
