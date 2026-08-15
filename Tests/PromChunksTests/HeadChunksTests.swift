//===----------------------------------------------------------------------===//
// `tsdb/chunks`' `ChunkDiskMapper`, pinned against Go in both directions.
//
// Each case is a program of writes, and then it **closes and reopens** the directory before iterating —
// which is how the Head uses it, and the only supported time to call `iterateAllChunks`. See
// `oracle/suites_headchunks.go` for why, and for why the chunk handed to the writer is a stub with explicit
// bytes rather than a real XOR chunk.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import PromFS
import Testing

@testable import PromChunks

// The shared codec lives in `GoOracleSupport.RLEHex` so the WAL and head chunk suites cannot drift apart.
private func rleHex(_ b: [UInt8]) -> String { RLEHex.encode(b) }
private func unrleHex(_ s: String) -> [UInt8] { RLEHex.decode(s) }

// MARK: - Wire types

struct HCOp: Codable, Sendable {
    var op: String
    var seriesRef: UInt64?
    var mint: Int64?
    var maxt: Int64?
    var encoding: UInt8?
    var data: String?
    var isOOO: Bool?
    var fileNo: UInt32?
}

struct HCSeedFile: Codable, Sendable {
    var name: String
    var bytes: String
}

struct HCIn: Codable, Sendable {
    var writeBufferSize: Int
    var ops: [HCOp]?
    var preSeed: [HCSeedFile]?
    /// Reading on the LIVE mapper is the only way to reach the `chunkBuffer`: a reopened mapper's buffer is
    /// empty, so a corpus that only reads after reopening cannot see the buffer or the flush decisions.
    var readBeforeClose: Bool?
    /// Deliberately invalid refs, so `chunk(ref:)`'s bounds checks and CRC verification are reachable.
    var extraReadRefs: [UInt64]?
}

struct HCFileOut: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var bytes: String
}

struct HCIterOut: Codable, Equatable, Sendable {
    var seriesRef: UInt64
    var chunkRef: UInt64
    var mint: Int64
    var maxt: Int64
    var numSamples: UInt16
    var encoding: UInt8
    var isOOO: Bool
}

struct HCReadOut: Codable, Equatable, Sendable {
    var ref: UInt64
    var encoding: UInt8
    var bytes: String
    var err: String
}

struct HCOut: Codable, Equatable, Sendable {
    var refs: [UInt64]
    var writeErrs: [String]
    var opErr: String
    var files: [HCFileOut]
    var size: Int64
    var liveReads: [HCReadOut]
    var reopenErr: String
    var iter: [HCIterOut]
    var iterErr: String
    var reads: [HCReadOut]
}

@Suite("chunks: the ChunkDiskMapper, written then reopened")
struct HeadChunksTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("chunks/headchunks.jsonl", FixtureCase<HCIn, HCOut>.self) { input in
            let fs = InMemoryFS()
            let chunkDir = "chunks_head"
            var out = HCOut(
                refs: [], writeErrs: [], opErr: "", files: [], size: 0, liveReads: [],
                reopenErr: "", iter: [], iterErr: "", reads: [])

            try fs.createDirectory(chunkDir)
            for sf in input.preSeed ?? [] {
                let sh = try fs.createFile("\(chunkDir)/\(sf.name)")
                try sh.append(unrleHex(sf.bytes))
                try sh.close()
            }

            let cdm: ChunkDiskMapper
            do {
                cdm = try ChunkDiskMapper(
                    fs: fs, dir: chunkDir, writeBufferSize: input.writeBufferSize)
            } catch {
                out.opErr = String(describing: error)
                return out
            }

            for op in input.ops ?? [] {
                switch op.op {
                case "writeChunk":
                    var cbErr = ""
                    let ref = cdm.writeChunk(
                        seriesRef: HeadSeriesRef(rawValue: op.seriesRef ?? 0),
                        mint: op.mint ?? 0, maxt: op.maxt ?? 0,
                        encoding: Encoding(rawValue: op.encoding ?? 0),
                        bytes: unrleHex(op.data ?? ""),
                        isOOO: op.isOOO ?? false,
                        callback: { e in if let e { cbErr = String(describing: e) } })
                    out.refs.append(ref.rawValue)
                    out.writeErrs.append(cbErr)
                case "cutNewFile":
                    cdm.cutNewFile()
                case "truncate":
                    do { try cdm.truncate(fileNo: op.fileNo ?? 0) } catch {
                        if out.opErr.isEmpty { out.opErr = String(describing: error) }
                    }
                default:
                    Issue.record("unknown head chunk op \(op.op)")
                }
            }

            if input.readBeforeClose == true {
                for r in out.refs + (input.extraReadRefs ?? []) {
                    out.liveReads.append(Self.read(cdm, r, dir: chunkDir))
                }
            }

            out.size = (try? cdm.size()) ?? 0
            do { try cdm.close() } catch {
                if out.opErr.isEmpty { out.opErr = String(describing: error) }
            }

            out.files = Self.readDir(fs, chunkDir)

            // The reopen: this is where `openMappedFiles`, `repairLastChunkFile` and the header checks run.
            let cdm2: ChunkDiskMapper
            do {
                cdm2 = try ChunkDiskMapper(
                    fs: fs, dir: chunkDir, writeBufferSize: input.writeBufferSize)
            } catch {
                out.reopenErr = String(describing: error)
                return out
            }
            do {
                try cdm2.iterateAllChunks { sref, cref, mint, maxt, numSamples, enc, isOOO in
                    out.iter.append(
                        HCIterOut(
                            seriesRef: sref.rawValue, chunkRef: cref.rawValue, mint: mint,
                            maxt: maxt, numSamples: numSamples, encoding: enc.rawValue,
                            isOOO: isOOO))
                }
            } catch {
                out.iterErr = String(describing: error)
            }

            for r in out.refs + (input.extraReadRefs ?? []) {
                out.reads.append(Self.read(cdm2, r, dir: chunkDir))
            }
            try cdm2.close()
            return out
        }
    }

    /// One `chunk(ref:)` read, shared by the live and the reopened mapper.
    ///
    /// Go returns a chunk from the pool, so an encoding the pool does not know is an ERROR there and merely a
    /// byte here — the port validates it at the call site to keep the two answers the same. That is the pool's
    /// only observable behaviour (PORTING.md's `sync.Pool` exception covers the rest).
    static func read(_ cdm: ChunkDiskMapper, _ r: UInt64, dir: String) -> HCReadOut {
        var ro = HCReadOut(ref: r, encoding: 0, bytes: "", err: "")
        do {
            let (enc, bytes) = try cdm.chunk(ref: ChunkDiskMapperRef(rawValue: r))
            guard poolKnows(enc) else {
                throw HeadChunkCorruptionError(
                    dir: dir, fileIndex: ChunkDiskMapperRef(rawValue: r).unpack().seq,
                    underlying: UnknownEncodingError(encoding: enc))
            }
            ro.encoding = enc.rawValue
            ro.bytes = rleHex(bytes)
        } catch {
            ro.err = String(describing: error)
        }
        return ro
    }

    /// Go: `chunkenc.Pool.Get` accepts exactly these and errors on anything else with
    /// `invalid chunk encoding "<enc>"`.
    static func poolKnows(_ e: Encoding) -> Bool {
        e == .xor || e == .xor2 || e == .histogram || e == .floatHistogram
    }

    static func readDir(_ fs: InMemoryFS, _ dir: String) -> [HCFileOut] {
        var out: [HCFileOut] = []
        for name in ((try? fs.list(dir)) ?? []).sorted() {
            guard let h = try? fs.openForReading("\(dir)/\(name)"),
                let b = try? h.read(offset: 0, length: h.size)
            else { continue }
            try? h.close()
            out.append(HCFileOut(name: name, size: b.count, bytes: rleHex(b)))
        }
        return out
    }

    /// `bytesToWriteForChunk` has to predict the on-disk size EXACTLY or `cutAndExpectRef` fires. Asserted
    /// directly as well as through the corpus, because the corpus only sees it via the refs and a
    /// compensating error in both would cancel out.
    @Test("bytesToWriteForChunk agrees with the header the writer emits")
    func bytesToWriteArithmetic() {
        // 8 (series ref) + 8 + 8 (mint/maxt) + 1 (encoding) + 4 (CRC) = 29 fixed, then the uvarint and the
        // data. I first wrote these expectations with a 28-byte base and five of the six failed — the fixed
        // part is 29, and the CRC is easy to leave out of a count that "looks like" a header.
        let base = 8 + 8 + 8 + 1 + 4
        #expect(ChunkPos.bytesToWriteForChunk(0) == UInt64(base + 1 + 0))
        #expect(ChunkPos.bytesToWriteForChunk(1) == UInt64(base + 1 + 1))
        #expect(ChunkPos.bytesToWriteForChunk(127) == UInt64(base + 1 + 127))
        // 128 is where the uvarint needs a second byte.
        #expect(ChunkPos.bytesToWriteForChunk(128) == UInt64(base + 2 + 128))
        #expect(ChunkPos.bytesToWriteForChunk(16383) == UInt64(base + 2 + 16383))
        #expect(ChunkPos.bytesToWriteForChunk(16384) == UInt64(base + 3 + 16384))
    }

    /// `toNewFile` restarts the offset at the HEADER size, and `shouldCutNewFile` recognises the first file by
    /// `offset == 0` — a value no real file position ever takes.
    @Test("chunkPos numbers files from 1 and offsets from the header")
    func chunkPosFirstFile() {
        var p = ChunkPos()
        #expect(p.shouldCutNewFile(30))
        let (ref, cut) = p.getNextChunkRef(chunkLength: 4)
        #expect(cut)
        let (seq, offset) = ref.unpack()
        // Never file 0: `toNewFile` pre-increments.
        #expect(seq == 1)
        #expect(offset == segmentHeaderSize)

        // The next chunk goes in the same file, right after the first.
        let (ref2, cut2) = p.getNextChunkRef(chunkLength: 4)
        #expect(!cut2)
        #expect(ref2.unpack().seq == 1)
        #expect(ref2.unpack().offset == segmentHeaderSize + Int(ChunkPos.bytesToWriteForChunk(4)))
    }

    /// The OOO mask is the TOP bit, so it survives round-tripping through the encoding byte and does not
    /// collide with any real encoding.
    @Test("the out-of-order mask round-trips and does not collide")
    func oooMask() {
        for e in [Encoding.xor, .xor2, .histogram, .floatHistogram] {
            let masked = applyOutOfOrderMask(e)
            #expect(isOutOfOrderChunk(masked))
            #expect(!isOutOfOrderChunk(e))
            #expect(removeMasks(masked) == e)
            #expect(removeMasks(e) == e)
        }
    }

    /// `segmentFile` is `fmt.Sprintf("%0.6d", i)`, and a NEGATIVE index is reachable: `chunk(ref:)`'s "more
    /// than current open file" arm passes -1 and its message renders the name. `.6` is a **precision** — a
    /// minimum digit count — so the sign sits outside it and -1 is `-000001`, seven characters. I wrote this
    /// expectation as `-00001` and the corpus disagreed first.
    @Test("the corruption message renders a negative file index as Go formats it")
    func negativeFileIndexName() {
        #expect(headSegmentFile("d", 1) == "d/000001")
        #expect(headSegmentFile("d", 123456) == "d/123456")
        #expect(headSegmentFile("d", 1234567) == "d/1234567")
        #expect(headSegmentFile("d", -1) == "d/-000001")
        #expect(headSegmentFile("", 1) == "000001")
    }

    /// `ChunkDiskMapperRef` packs the file index above the offset, and the two comparisons are over the
    /// unpacked halves.
    @Test("the ref packs seq above offset")
    func refPacking() {
        let r = ChunkDiskMapperRef(seq: 3, offset: 8)
        #expect(r.unpack() == (3, 8))
        #expect(r.rawValue == (3 << 32) | 8)
        let bigger = ChunkDiskMapperRef(seq: 3, offset: 9)
        #expect(bigger.greaterThan(r))
        #expect(bigger.greaterThanOrEqualTo(r))
        #expect(!r.greaterThan(r))
        #expect(r.greaterThanOrEqualTo(r))
        // A later file always wins, whatever the offsets.
        #expect(ChunkDiskMapperRef(seq: 4, offset: 0).greaterThan(ChunkDiskMapperRef(seq: 3, offset: 999)))
    }

    /// **Exception 22.** A zero-length head chunk file is refused by both, at the same call, for the same
    /// reason — but upstream's message is mmap's (`mmap, size 0: invalid argument`, i.e. `strerror(EINVAL)`)
    /// because `OpenMmapFile` runs before any header is validated, and ADR-15 declines mmap. The corpus
    /// deliberately omits the case rather than commit an OS error string two CI platforms must agree on, so the
    /// port's own answer is asserted here.
    ///
    /// It is reachable: `repairLastChunkFile` returns early on `lastFile <= 0`, so an empty `000000` is never
    /// repaired away. A writer never creates index 0, so it takes a planted or externally corrupted directory.
    @Test("a zero-length chunk file is refused, with the port's own message")
    func zeroLengthFileIsRefused() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("chunks_head")
        let h = try fs.createFile("chunks_head/000000")
        try h.close()

        do {
            _ = try ChunkDiskMapper(fs: fs, dir: "chunks_head")
            Issue.record("expected a zero-length chunk file to be refused")
        } catch let e as HeadChunksError {
            #expect(
                e.description == "chunks_head/000000: invalid head chunk file header: invalid size")
        }
    }

    /// `curFileSize` is `curFileOffset` — the bytes handed to the writer, which after a cut is the HEADER
    /// SIZE and not zero. The corpus cannot see it: it only iterates after reopening, where the current
    /// sequence is 0 and every file is bounded by its own length instead. So it is asserted here.
    @Test("curFileSize starts at the header size after a cut, not at zero")
    func curFileSizeAfterCut() throws {
        let fs = InMemoryFS()
        let cdm = try ChunkDiskMapper(fs: fs, dir: "chunks_head")
        // Nothing written yet, so no file has been cut and nothing has been counted.
        #expect(cdm.curFileSize == 0)

        cdm.writeChunk(
            seriesRef: HeadSeriesRef(rawValue: 1), mint: 1, maxt: 2, encoding: .xor,
            bytes: [0, 3, 9, 9, 9])
        // The header, then the chunk: 8 + bytesToWriteForChunk(5).
        #expect(cdm.curFileSize == UInt64(segmentHeaderSize) + ChunkPos.bytesToWriteForChunk(5))
        try cdm.close()
    }

    @Test("a rejected write buffer size creates no directory")
    func rejectedBufferLeavesNoDirectory() throws {
        let fs = InMemoryFS()
        #expect(throws: (any Error).self) {
            _ = try ChunkDiskMapper(fs: fs, dir: "chunks_head", writeBufferSize: 1024)
        }
        #expect((try? fs.list("chunks_head")) == nil || ((try? fs.list("chunks_head")) ?? []).isEmpty)
    }
}

/// Go: `chunkenc.Pool.Get`'s error for an encoding it does not know.
struct UnknownEncodingError: Error, CustomStringConvertible {
    var encoding: Encoding
    var description: String { "invalid chunk encoding \"\(encoding)\"" }
}
