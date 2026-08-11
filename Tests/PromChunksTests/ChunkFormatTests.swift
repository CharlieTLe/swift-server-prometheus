//===----------------------------------------------------------------------===//
// The chunk file format's pure half: the two reference layouts, the per-chunk framing, the checksum, and
// `WriteChunks`' segment-batching arithmetic.
//
// The file and segment I/O is not ported — it needs a filesystem abstraction, which is an ADR rather than
// a transcription — so this pins everything about the format that does not touch a disk. The batching is
// observed the way a caller sees it: which segment each chunk's reference decodes to.
//
// Four fixture files rather than one: `Fixtures.check` decodes every line of a file with a single
// `In`/`Out` pair, so mixing shapes would need an id filter in shared test infrastructure. Four files is
// the cheaper seam.
//
// One wire note: sample values travel as HEX BIT PATTERNS. `encoding/json` cannot represent NaN and
// panics outright, which is the louder cousin of the submatch corpus's silent U+FFFD substitution.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import Testing

struct HeadRefIn: Codable, Sendable {
    var seriesRef: UInt64
    var chunkID: UInt64
}

struct HeadRefOut: Decodable, Equatable, Sendable {
    var ref: UInt64
    var seriesRef: UInt64
    var chunkID: UInt64
    /// Go PANICS above the field widths; the port throws. Non-empty means the bound was exceeded.
    var panic: String
}

struct BlockRefIn: Codable, Sendable {
    var fileIndex: UInt64
    var fileOffset: UInt64
}

struct BlockRefOut: Decodable, Equatable, Sendable {
    var ref: UInt64
    var segIndex: Int
    var chunkStart: Int
}

struct FramingIn: Codable, Sendable {
    var values: [String]
    var badSum: String
}

struct FramingOut: Decodable, Equatable, Sendable {
    var dataHex: String
    var framedHex: String
    var hashInputHex: String
    var crc: UInt32
    var checkErr: String
}

struct BatchIn: Codable, Sendable {
    var sizes: [Int]
    var segmentSize: Int64
}

struct BatchOut: Decodable, Equatable, Sendable {
    var segmentOf: [Int]
    var offsetOf: [Int]
    var err: String
    /// Every segment file the writer left behind, name-sorted, with its full contents. This is what makes
    /// the WRITER pinnable rather than only its arithmetic.
    var segmentNames: [String]
    var segmentHex: [String]
}

private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
private func unhx(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Suite("chunks: the file format's references, framing and batching")
struct ChunkFormatTests {

    @Test("HeadChunkRef packs 40 bits of series ref and 24 of chunk ID")
    func headRefs() throws {
        try Fixtures.check("chunks/headref.jsonl", FixtureCase<HeadRefIn, HeadRefOut>.self) {
            input in
            do {
                let ref = try HeadChunkRef(
                    seriesRef: HeadSeriesRef(rawValue: input.seriesRef),
                    chunkID: HeadChunkID(rawValue: input.chunkID))
                let (sr, cid) = ref.unpack()
                return HeadRefOut(
                    ref: ref.rawValue, seriesRef: sr.rawValue, chunkID: cid.rawValue, panic: "")
            } catch {
                // Go's `panic("series ID exceeds 5 bytes")` reaches the fixture as the recovered
                // message; the port's thrown error renders the same string.
                return HeadRefOut(ref: 0, seriesRef: 0, chunkID: 0, panic: String(describing: error))
            }
        }
    }

    @Test("BlockChunkRef packs 32 bits each, with no bounds check")
    func blockRefs() throws {
        try Fixtures.check("chunks/blockref.jsonl", FixtureCase<BlockRefIn, BlockRefOut>.self) {
            input in
            let ref = BlockChunkRef(fileIndex: input.fileIndex, fileOffset: input.fileOffset)
            let (si, cs) = ref.unpack()
            return BlockRefOut(ref: ref.rawValue, segIndex: si, chunkStart: cs)
        }
    }

    @Test("a chunk's framing and checksum are byte-exact")
    func framing() throws {
        try Fixtures.check("chunks/framing.jsonl", FixtureCase<FramingIn, FramingOut>.self) {
            input in
            let c = XORChunk()
            let app = try c.appender()
            for (i, v) in input.values.enumerated() {
                app.append(Int64(i) * 15000, fbits(v))
            }
            let data = c.bytes
            let hashInput = ChunkFraming.hashInput(.xor, data)
            let framed = ChunkFraming.framed(.xor, data)
            // The CRC is the last four bytes of the framing, big-endian.
            let crc =
                UInt32(framed[framed.count - 4]) << 24 | UInt32(framed[framed.count - 3]) << 16
                | UInt32(framed[framed.count - 2]) << 8 | UInt32(framed[framed.count - 1])

            var checkErr = ""
            let against = input.badSum.isEmpty
                ? Array(framed.suffix(4))
                : unhx(input.badSum)
            do {
                try checkCRC32(hashInput, against)
            } catch {
                checkErr = String(describing: error)
            }
            return FramingOut(
                dataHex: hx(data), framedHex: hx(framed), hashInputHex: hx(hashInput), crc: crc,
                checkErr: checkErr)
        }
    }

    /// **The port now HAS a writer** (`ChunkWriter` on `PromFS`), so this compares the real thing: Go
    /// writes real segment files to a temporary directory, the port writes to `InMemoryFS`, and the byte
    /// strings are compared. When §6e wrote this it could only check the batching arithmetic; ADR-15's seam
    /// is what turned it into a byte-for-byte comparison of the writer itself.
    @Test("segment batching matches, including the worst-case length sizing")
    func batching() throws {
        try Fixtures.check("chunks/batch.jsonl", FixtureCase<BatchIn, BatchOut>.self) {
            input in
            // Rebuild the chunks the oracle built: append until the encoding reaches the target size.
            var dataSizes: [Int] = []
            var datas: [[UInt8]] = []
            for target in input.sizes {
                let c = XORChunk()
                let app = try c.appender()
                var i = 0
                while c.bytes.count < target && i <= 100_000 {
                    app.append(Int64(i) * 15000, Double(i) * 1.7)
                    i += 1
                }
                dataSizes.append(c.bytes.count)
                datas.append(c.bytes)
            }

            let fs = InMemoryFS()
            let w = try ChunkWriter(fs: fs, dir: "d", segmentSize: input.segmentSize)
            let refs = try w.write(datas.map { (encoding: Encoding.xor, bytes: $0) })
            try w.close()

            var segmentOf: [Int] = []
            var offsetOf: [Int] = []
            for r in refs {
                let (si, cs) = BlockChunkRef(rawValue: r.rawValue).unpack()
                segmentOf.append(si)
                offsetOf.append(cs)
            }

            // Every file left behind, name-sorted — including any `.tmp` that should not have survived.
            var names = try fs.list("d")
            names.sort()
            var hexes: [String] = []
            for nm in names {
                let h = try fs.openForReading("d/" + nm)
                hexes.append(hx(try h.read(offset: 0, length: h.size)))
                try h.close()
            }
            return BatchOut(
                segmentOf: segmentOf, offsetOf: offsetOf, err: "", segmentNames: names,
                segmentHex: hexes)
        }
    }
}
