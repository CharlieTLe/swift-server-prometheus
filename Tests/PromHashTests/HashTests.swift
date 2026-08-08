//===----------------------------------------------------------------------===//
// Differential tests: xxhash64 and CRC-32C against Go.
//
// labels.Hash() is xxhash64 over the packed label encoding; CRC-32C guards every
// TSDB on-disk structure. Both must be exact.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHash

struct HashBytesIn: Decodable, Sendable {
    let bytes: String
    var raw: [UInt8] { Hex.decode(bytes) }
}

@Suite("XXHash64 matches cespare/xxhash")
struct XXHash64Tests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("hash/xxhash64.jsonl", FixtureCase<HashBytesIn, String>.self) {
            String(format: "%016lx", XXHash64.sum64($0.raw))
        }
    }

    @Test("length sweep crosses the 32-byte block and 8/4/1-byte tails")
    func lengthSweep() throws {
        // The fixture already sweeps 0...200; assert the boundaries explicitly so
        // a regression names the branch it broke.
        let cases = try Fixtures.load("hash/xxhash64.jsonl", FixtureCase<HashBytesIn, String>.self)
        let boundaries = cases.filter {
            ["xlen/0", "xlen/1", "xlen/4", "xlen/8", "xlen/31", "xlen/32", "xlen/33"].contains($0.id)
        }
        #expect(boundaries.count == 7)
        for c in boundaries {
            #expect(String(format: "%016lx", XXHash64.sum64(c.in.raw)) == c.out, "\(c.id)")
        }
    }

    @Test("String and byte overloads agree")
    func stringOverload() {
        for s in ["", "a", "up", "hello world", "日本語"] {
            #expect(XXHash64.sum64(s) == XXHash64.sum64(Array(s.utf8)))
        }
    }
}

@Suite("CRC32C matches hash/crc32 Castagnoli")
struct CRC32CTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("hash/crc32c.jsonl", FixtureCase<HashBytesIn, String>.self) {
            String(format: "%08x", CRC32C.checksum($0.raw))
        }
    }

    @Test("incremental update equals one-shot")
    func incremental() {
        // Encbuf.PutHash streams, so chunked updates must agree with a single call.
        let data = (0..<300).map { UInt8($0 % 251) }
        for split in [0, 1, 7, 8, 9, 100, 299, 300] {
            var h = CRC32C()
            h.update(Array(data[0..<split]))
            h.update(Array(data[split...]))
            #expect(h.final() == CRC32C.checksum(data), "split at \(split)")
        }
    }
}
