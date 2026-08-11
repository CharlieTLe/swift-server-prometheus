//===----------------------------------------------------------------------===//
// `chunks.Reader` — resolving a `BlockChunkRef` back to a chunk.
//
// The corpus for this is `chunks/batch.jsonl`, which already contains Go's real segment files and the ref
// Go's writer assigned to every chunk. So the reader is checked against **Go's files and Go's refs**, not
// against the port's own writer — a writer bug and a reader bug cannot cancel out.
//
// The write-then-read path is checked too, because it is what a block actually does, but only after the
// against-Go direction passes.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import Testing

@Suite("chunks: reading a chunk back from a segment")
struct ChunkReaderTests {

    /// Loads Go's segment files into an in-memory filesystem and resolves the refs Go's writer produced.
    @Test("Go's refs resolve to Go's chunk bytes")
    func resolvesGoRefs() throws {
        var checked = 0
        for c in try Fixtures.load("chunks/batch.jsonl", FixtureCase<BatchIn, BatchOut>.self) {
            guard c.out.err.isEmpty, !c.out.segmentNames.isEmpty else { continue }

            let fs = InMemoryFS()
            try fs.createDirectory("d")
            for (name, hex) in zip(c.out.segmentNames, c.out.segmentHex) {
                let w = try fs.createFile("d/" + name)
                try w.append(unhexR(hex))
                try w.close()
            }
            let reader = try ChunkReader(fs: fs, dir: "d")
            #expect(reader.segmentNames == c.out.segmentNames.sorted())

            // Rebuild the same chunks the oracle wrote, so the bytes read back can be compared to them.
            var expected: [[UInt8]] = []
            for target in c.in.sizes {
                let ch = XORChunk()
                let app = try ch.appender()
                var i = 0
                while ch.bytes.count < target && i <= 100_000 {
                    app.append(Int64(i) * 15000, Double(i) * 1.7)
                    i += 1
                }
                expected.append(ch.bytes)
            }

            for (j, (seg, off)) in zip(c.out.segmentOf, c.out.offsetOf).enumerated() {
                let ref = ChunkRef(
                    rawValue: BlockChunkRef(fileIndex: UInt64(seg), fileOffset: UInt64(off)).rawValue)
                let (enc, bytes) = try reader.chunk(ref: ref)
                #expect(enc == Encoding.xor, "\(c.id) chunk \(j): wrong encoding")
                #expect(bytes == expected[j], "\(c.id) chunk \(j): wrong bytes")
                checked += 1
            }
        }
        #expect(checked > 0, "no comparable cases — the corpus shape changed")
    }

    /// What a block does: write, then read back through the port's own reader.
    @Test("the port's writer and reader agree")
    func writeThenRead() throws {
        let fs = InMemoryFS()
        var datas: [[UInt8]] = []
        for n in [1, 5, 40, 200] {
            let ch = XORChunk()
            let app = try ch.appender()
            for i in 0..<n {
                app.append(Int64(i) * 15000, Double(i) * 2.5)
            }
            datas.append(ch.bytes)
        }
        // 128 bytes, which genuinely forces cuts: the four chunks above total a few hundred bytes and a
        // 512-byte segment held them all, so the first version of this test asserted a multi-segment
        // layout it had not created.
        let w = try ChunkWriter(fs: fs, dir: "blk/chunks", segmentSize: 128)
        let refs = try w.write(datas.map { (encoding: Encoding.xor, bytes: $0) })
        try w.close()

        let reader = try ChunkReader(fs: fs, dir: "blk/chunks")
        #expect(reader.segmentNames.count > 1, "the segment size should have forced a cut")
        for (i, ref) in refs.enumerated() {
            let (enc, bytes) = try reader.chunk(ref: ref)
            #expect(enc == Encoding.xor)
            #expect(bytes == datas[i], "chunk \(i) did not survive the round trip")
        }
    }

    /// The bounds checks and the checksum, each with its own message.
    @Test("a bad reference reports the right error")
    func errors() throws {
        let fs = InMemoryFS()
        let ch = XORChunk()
        let app = try ch.appender()
        app.append(0, 1)
        let w = try ChunkWriter(fs: fs, dir: "d", segmentSize: 4096)
        let refs = try w.write([(encoding: Encoding.xor, bytes: ch.bytes)])
        try w.close()
        let reader = try ChunkReader(fs: fs, dir: "d")

        // A segment that does not exist.
        let badSegment = ChunkRef(
            rawValue: BlockChunkRef(fileIndex: 99, fileOffset: 8).rawValue)
        #expect(throws: ChunkReadError.segmentIndexOutOfRange(99)) {
            _ = try reader.chunk(ref: badSegment)
        }

        // An offset so near the end that even the length field cannot be read. The message quotes the
        // MAXIMUM varint width, not the real one.
        let size = try fs.openForReading("d/000001").size
        let nearEnd = ChunkRef(
            rawValue: BlockChunkRef(fileIndex: 0, fileOffset: UInt64(size - 2)).rawValue)
        #expect(
            throws: ChunkReadError.notEnoughBytesForSizeField(
                required: size - 2 + 5, available: size)
        ) {
            _ = try reader.chunk(ref: nearEnd)
        }

        // A corrupted chunk: flip a byte in the data and the CRC must reject it.
        let h = try fs.openForReading("d/000001")
        var bytes = try h.read(offset: 0, length: h.size)
        try h.close()
        let (_, off) = BlockChunkRef(rawValue: refs[0].rawValue).unpack()
        bytes[off + 3] ^= 0xFF
        let fs2 = InMemoryFS()
        try fs2.createDirectory("d")
        let w2 = try fs2.createFile("d/000001")
        try w2.append(bytes)
        try w2.close()
        let reader2 = try ChunkReader(fs: fs2, dir: "d")
        #expect(throws: (any Error).self) { _ = try reader2.chunk(ref: refs[0]) }
    }
}

private func unhexR(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
