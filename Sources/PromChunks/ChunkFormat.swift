//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/chunks.go @ v3.13.2 — the chunk file format's REFERENCES, METADATA and
// per-chunk FRAMING.
//
// **The file and segment I/O is deliberately not here.** `Writer`, `cut`, `cutSegmentFile` and
// `NewDirReader` are built on `os.File`, a directory handle, `fileutil.BufWriter` and mmap; porting them
// needs a filesystem abstraction, and choosing one is an ADR rather than a transcription. What *is* here
// is everything about the format that is pure: how a chunk reference packs, how a chunk is framed inside
// a segment, how its checksum is computed and checked, and the batching arithmetic that decides where
// segments are cut. All of it is byte-exact and testable without touching a disk.
//
// ## Two reference layouts, and neither is a plain offset
//
//     HeadChunkRef:  series ref in the top 40 bits | chunk ID in the low 24
//     BlockChunkRef: segment index in the top 32   | byte offset in the low 32
//
// `NewHeadChunkRef` **panics** above those widths — 5 bytes of series ref and 3 of chunk ID — so the
// bounds are a contract rather than a truncation. The port throws instead of trapping, because a
// `preconditionFailure` cannot be recovered and this is reachable from data.
//
// `HeadChunkRef.Unpack` recovers the chunk ID as `(p << 40) >> 40`, not `p & 0xFFFFFF`. Same answer,
// and kept in Go's spelling because the shift pair is what documents the 24-bit field.
//
// ## A chunk's framing is four fields, and the CRC covers only two of them
//
//     <uvarint data length> <1-byte encoding> <data> <4-byte CRC32-C>
//
// `writeHash` feeds the CRC the **encoding byte and the data** — not the length prefix, and not the
// reference. So a corrupted length is not detected by the checksum; it is detected, if at all, by the
// read failing to make sense. That is upstream's choice and it is worth knowing before trusting a CRC
// to mean "this chunk is intact".
//
// The checksum is CRC32-**Castagnoli**, which `PromHash` already pins as `hash/crc32c`.
//
// ## `checkCRC32` reassembles the stored sum by hand
//
// `uint32(sum[0])<<24 + ... + uint32(sum[3])` — big-endian, and upstream's comment calls it "the inverse
// of digest.Sum() in go/src/hash/crc32". It is `binary.BigEndian.Uint32` spelled out, and the error
// message formats both values with `%x`.
//
// ## The batching arithmetic assumes the WORST-CASE length prefix
//
// `WriteChunks` sizes each chunk as `MaxChunkLengthFieldSize + 1 + len(data) + 4`, using the maximum
// varint width rather than the actual one. So a segment is cut slightly early — deliberately, since the
// decision has to be made before the prefix is written. A port that used the real width would produce
// different segment boundaries for the same input.
//
// The `firstBatch` clause is the subtle part: for the first batch only, and only when the current
// segment already holds more than a header, the test is against `w.n` (bytes already written) rather
// than against `SegmentHeaderSize`. That is what lets a partially-filled segment be topped up instead of
// abandoned.
//===----------------------------------------------------------------------===//

public import PromChunkEnc

internal import GoCompat
internal import PromHash

/// Go: `MagicChunks` — the four bytes at the head of a segment file.
public let magicChunks: UInt32 = 0x85BD_40DD
public let magicChunksSize = 4
let chunksFormatV1: UInt8 = 1
public let chunksFormatVersionSize = 1
let segmentHeaderPaddingSize = 3
/// Go: `SegmentHeaderSize` — magic, version, and three padding bytes.
public let segmentHeaderSize = magicChunksSize + chunksFormatVersionSize + segmentHeaderPaddingSize

/// Go: `MaxChunkLengthFieldSize` — `binary.MaxVarintLen32`, so **5**, not the actual varint width. See
/// the file header on why the batching uses the maximum.
public let maxChunkLengthFieldSize = 5
/// Go: `ChunkEncodingSize`.
public let chunkEncodingSize = 1
/// Go: `crc32.Size`.
public let crc32Size = 4

/// Go: `HeadSeriesRef`.
public struct HeadSeriesRef: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Go: `HeadChunkID`.
public struct HeadChunkID: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Go: the two `panic`s in `NewHeadChunkRef`.
///
/// Thrown rather than trapped: the widths are a contract on data, and Swift cannot recover a
/// `preconditionFailure`. The messages are Go's verbatim.
public enum ChunkRefError: Error, CustomStringConvertible, Equatable, Sendable {
    case seriesIDExceedsFiveBytes
    case chunkIDExceedsThreeBytes

    public var description: String {
        switch self {
        case .seriesIDExceedsFiveBytes: return "series ID exceeds 5 bytes"
        case .chunkIDExceedsThreeBytes: return "chunk ID exceeds 3 bytes"
        }
    }
}

/// Go: `HeadChunkRef` — a series ref and a chunk ID packed into eight bytes.
public struct HeadChunkRef: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Go: `NewHeadChunkRef`. 40 bits of series ref, 24 of chunk ID.
    public init(seriesRef: HeadSeriesRef, chunkID: HeadChunkID) throws {
        if seriesRef.rawValue > (1 << 40) - 1 {
            throw ChunkRefError.seriesIDExceedsFiveBytes
        }
        if chunkID.rawValue > (1 << 24) - 1 {
            throw ChunkRefError.chunkIDExceedsThreeBytes
        }
        // Go: `uint64(hsr<<24) | uint64(chunkID)`. Note the shift happens on the TYPED value, so it
        // wraps within 64 bits exactly as the port's `&<<` does.
        self.rawValue = (seriesRef.rawValue &<< 24) | chunkID.rawValue
    }

    /// Go: `Unpack` — `(p << 40) >> 40` for the chunk ID, which documents the field width.
    public func unpack() -> (HeadSeriesRef, HeadChunkID) {
        (
            HeadSeriesRef(rawValue: rawValue >> 24),
            HeadChunkID(rawValue: (rawValue &<< 40) >> 40)
        )
    }
}

/// Go: `BlockChunkRef` — a segment index and a byte offset.
public struct BlockChunkRef: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Go: `NewBlockChunkRef`. **No bounds check**, unlike `NewHeadChunkRef` — a file index above 2^32
    /// silently overlaps the offset field.
    public init(fileIndex: UInt64, fileOffset: UInt64) {
        self.rawValue = (fileIndex &<< 32) | fileOffset
    }

    /// Go: `Unpack` — returns `int`s, so the port keeps `Int` rather than widening to `UInt64`.
    public func unpack() -> (segmentIndex: Int, chunkStart: Int) {
        (Int(rawValue >> 32), Int((rawValue &<< 32) >> 32))
    }
}

/// Go: `Meta.writeHash` and the four fields `writeChunks` emits.
///
/// `ChunkRef` and `Meta` already exist in `Chunks.swift` (Phase 5 needed them for the `ChunkReader`
/// protocol), so this extends rather than redeclares — and the framing takes the encoding and bytes
/// directly, because a `Meta` whose `chunk` is nil has nothing to frame.
public enum ChunkFraming {
    /// Go: `writeHash` — the encoding byte then the raw data, and **nothing else**. The length prefix and
    /// the reference are outside the checksum; see the file header.
    public static func hashInput(_ encoding: Encoding, _ chunkBytes: [UInt8]) -> [UInt8] {
        [encoding.rawValue] + chunkBytes
    }

    /// Go: the four fields `writeChunks` emits per chunk.
    ///
    /// `<uvarint len(data)> <encoding> <data> <CRC32-C over encoding+data>`
    public static func framed(_ encoding: Encoding, _ chunkBytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        GoVarint.putUvarint(&out, UInt64(chunkBytes.count))
        out.append(encoding.rawValue)
        out.append(contentsOf: chunkBytes)
        let sum = crc32Castagnoli(hashInput(encoding, chunkBytes))
        // Go: `w.crc32.Sum(w.buf[:0])`, which is big-endian.
        out.append(UInt8(truncatingIfNeeded: sum >> 24))
        out.append(UInt8(truncatingIfNeeded: sum >> 16))
        out.append(UInt8(truncatingIfNeeded: sum >> 8))
        out.append(UInt8(truncatingIfNeeded: sum))
        return out
    }
}

/// Go: `newCRC32` plus `crc32.Checksum` — CRC32-Castagnoli, which `PromHash` already pins.
func crc32Castagnoli(_ data: [UInt8]) -> UInt32 {
    CRC32C.checksum(data)
}

/// Go: `errInvalidSize`.
public struct InvalidSizeError: Error, CustomStringConvertible, Equatable, Sendable {
    public init() {}
    public var description: String { "invalid size" }
}

/// Go: `checkCRC32`'s error.
public struct ChecksumMismatch: Error, CustomStringConvertible, Equatable, Sendable {
    public let expected: UInt32
    public let actual: UInt32
    public init(expected: UInt32, actual: UInt32) {
        self.expected = expected
        self.actual = actual
    }
    /// Go: `checksum mismatch expected:%x, actual:%x` — note "expected" is the STORED value and
    /// "actual" the computed one, and `%x` is lower-case hex with no padding.
    public var description: String {
        "checksum mismatch expected:\(String(expected, radix: 16)), "
            + "actual:\(String(actual, radix: 16))"
    }
}

/// Go: `checkCRC32`.
///
/// The stored sum is reassembled by hand from four bytes — big-endian, which upstream's comment calls
/// "the inverse of digest.Sum()".
public func checkCRC32(_ data: [UInt8], _ sum: [UInt8]) throws {
    let got = crc32Castagnoli(data)
    let want =
        UInt32(sum[0]) << 24 &+ UInt32(sum[1]) << 16 &+ UInt32(sum[2]) << 8 &+ UInt32(sum[3])
    if got != want {
        throw ChecksumMismatch(expected: want, actual: got)
    }
}

/// Go: `WriteChunks`' batching — which chunks go in which segment, given a segment size and how full
/// the current segment already is.
///
/// Pure arithmetic, and byte-exact-relevant because it decides segment boundaries. Two things a
/// straight reading misses, both in the file header: each chunk is sized with the **maximum** varint
/// width rather than its real one, and the `firstBatch` clause tests against bytes-already-written so a
/// partially filled segment gets topped up.
///
/// Returns the batches as index ranges into `sizes`, where `sizes[i]` is `chunkBytes.count` for chunk
/// `i`. Go returns slices of `Meta`; index ranges say the same thing without copying.
public func chunkWriteBatches(
    dataSizes sizes: [Int], segmentSize: Int64, bytesAlreadyWritten n: Int64
) -> [Range<Int>] {
    if sizes.isEmpty { return [0..<0] }

    var batchSize: Int64 = 0
    var batchStart = 0
    var batches: [Range<Int>] = [0..<0]
    var batchID = 0
    var firstBatch = true

    for (i, dataLen) in sizes.enumerated() {
        // The maximum length-field width, not the actual one: the decision precedes the write.
        var chkSize = Int64(maxChunkLengthFieldSize)
        chkSize += Int64(chunkEncodingSize)
        chkSize += Int64(dataLen)
        chkSize += Int64(crc32Size)
        batchSize += chkSize

        var cutNewBatch = (i != 0) && (batchSize + Int64(segmentHeaderSize) > segmentSize)

        if firstBatch && n > Int64(segmentHeaderSize) {
            cutNewBatch = batchSize + n > segmentSize
            if cutNewBatch {
                firstBatch = false
            }
        }

        if cutNewBatch {
            batchStart = i
            batches.append(0..<0)
            batchID += 1
            batchSize = chkSize
        }
        batches[batchID] = batchStart..<(i + 1)
    }
    return batches
}
