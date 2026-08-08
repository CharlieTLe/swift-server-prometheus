//===----------------------------------------------------------------------===//
// Differential tests: Encbuf byte output and Decbuf framing against Go's
// tsdb/encoding package. These primitives underpin every TSDB on-disk format.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromEncoding

struct EncOp: Decodable, Sendable {
    let op: String
    let arg: String
}

struct EncbufIn: Decodable, Sendable {
    let ops: [EncOp]
}

@Suite("Encbuf matches Go tsdb/encoding")
struct EncbufTests {

    /// Replays an oracle op-script through Encbuf.
    private func run(_ input: EncbufIn) -> String {
        var buf = Encbuf()
        for op in input.ops {
            switch op.op {
            case "byte": buf.putByte(UInt8(op.arg)!)
            case "be32": buf.putBE32(UInt32(op.arg)!)
            case "be64": buf.putBE64(UInt64(op.arg)!)
            case "be32int": buf.putBE32int(Int(op.arg)!)
            case "be64int64": buf.putBE64int64(Int64(op.arg)!)
            case "befloat64":
                buf.putBEFloat64(Double(bitPattern: UInt64(op.arg, radix: 16)!))
            case "uvarint": buf.putUvarint(Int(op.arg)!)
            case "uvarint64": buf.putUvarint64(UInt64(op.arg)!)
            case "varint64": buf.putVarint64(Int64(op.arg)!)
            case "uvarintstr":
                // The oracle may emit invalid UTF-8 here; go through bytes so the
                // length prefix counts the same bytes Go counted. See ADR-9.
                let raw = Hex.decode(op.arg)
                buf.putUvarint(raw.count)
                buf.putBytes(raw)
            case "string": buf.putBytes(Hex.decode(op.arg))
            case "hash": buf.putHash()
            default: fatalError("unknown op \(op.op)")
            }
        }
        return Hex.encode(buf.bytes)
    }

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("encoding/encbuf.jsonl", FixtureCase<EncbufIn, String>.self) {
            run($0)
        }
    }
}

@Suite("Decbuf framing and sticky errors")
struct DecbufTests {

    @Test("Decbuf.at round-trips a length+CRC frame written by Encbuf")
    func atRoundTrip() {
        var payload = Encbuf()
        payload.putUvarintStr("hello")
        payload.putBE64(0xDEAD_BEEF_CAFE_F00D)

        // Frame: BE32 length, contents, CRC32C. Matches Go's NewDecbufAt layout.
        var framed = Encbuf()
        framed.putBE32int(payload.bytes.count)
        framed.putBytes(payload.bytes)
        var inner = Encbuf()
        inner.putBytes(payload.bytes)
        inner.putHash()
        framed.putBytes(Array(inner.bytes.suffix(4)))

        let owner = ArrayByteSliceOwner(framed.bytes)
        var dec = Decbuf.at(owner.bytes, 0)
        #expect(dec.err == nil)
        #expect(dec.uvarintStr() == "hello")
        #expect(dec.be64() == 0xDEAD_BEEF_CAFE_F00D)
        #expect(dec.err == nil)
    }

    @Test("a corrupted frame is reported as invalidChecksum")
    func checksumMismatch() {
        var payload = Encbuf()
        payload.putUvarintStr("hello")

        var framed = Encbuf()
        framed.putBE32int(payload.bytes.count)
        framed.putBytes(payload.bytes)
        framed.putBE32(0)  // deliberately wrong CRC

        let owner = ArrayByteSliceOwner(framed.bytes)
        let dec = Decbuf.at(owner.bytes, 0)
        #expect(dec.err == .invalidChecksum)
    }

    @Test("errors are sticky and reads return zero after one")
    func stickyError() {
        // Go's Decbuf accumulates a single error and callers check once at the
        // end; reads after a failure must be inert rather than trapping.
        let owner = ArrayByteSliceOwner([0x01, 0x02])
        var dec = Decbuf(owner.bytes)
        #expect(dec.be64() == 0)  // only 2 bytes available
        #expect(dec.err == .invalidSize)
        #expect(dec.be32() == 0)
        #expect(dec.byte() == 0)
        #expect(dec.err == .invalidSize)
    }

    @Test("truncated frames are invalidSize, not a crash")
    func truncated() {
        let owner = ArrayByteSliceOwner([0x00, 0x00])
        #expect(Decbuf.at(owner.bytes, 0).err == .invalidSize)

        // Length header claims more than is present.
        let owner2 = ArrayByteSliceOwner([0x00, 0x00, 0x00, 0xFF, 0x01])
        #expect(Decbuf.at(owner2.bytes, 0).err == .invalidSize)
    }

    @Test("ByteSlice.range is a view, not a copy")
    func byteSliceRange() {
        let owner = ArrayByteSliceOwner([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let sub = owner.bytes.range(3, 7)
        #expect(sub.count == 4)
        #expect(sub[0] == 3)
        #expect(sub[3] == 6)
        #expect(owner.bytes.loadBE32(at: 0) == 0x0001_0203)
    }
}
