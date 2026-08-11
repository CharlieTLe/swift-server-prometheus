//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/chunks.go @ v3.13.2 — `Reader`, on `PromFS` (ADR-15).
//
// The last reader piece: resolve a `BlockChunkRef` to a chunk's encoding and bytes. §6e ported the framing
// and §6h the writer; this reads back what that writes.
//
// ## The segment list's ORDER is the reference's index space
//
// `NewDirReader` lists the directory, sorts it, and opens each file — so a ref's "file index" is a position
// in *that sorted list* (quirk 142), not the segment's filename number. A directory whose segments start at
// `000005` gives index 0 to it. So the reader must sort exactly as `fileutil.ReadDir` does, which is plain
// lexicographic order over the names — and because the names are zero-padded to six digits, lexicographic
// and numeric agree until segment 1,000,000.
//
// ## Two bounds checks with DIFFERENT messages, both before any parsing
//
// First `chkStart + MaxChunkLengthFieldSize > sgmBytes.Len()` — "enough bytes to read the chunk size data
// field" — using the MAXIMUM varint width, because the real width is not known until the varint is read.
// Then, after decoding the length, `chkEnd > sgmBytes.Len()` — "enough bytes to read the chunk". Upstream's
// comment on the first: "With the minimum chunk length this should never cause us reading over the end of
// the slice."
//
// ## The CRC covers the encoding byte and the data, not the length prefix
//
// `checkCRC32(sgmBytes.Range(chkEncStart, chkDataEnd), sum)` — starting at the encoding byte, ending before
// the checksum. Quirk 126 again, from the reading side: a corrupted length prefix is caught by the bounds
// check or not at all.
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromFS

internal import GoCompat

/// Go: `chunks.Reader`'s errors.
public enum ChunkReadError: Error, CustomStringConvertible, Equatable, Sendable {
    case segmentIndexOutOfRange(Int)
    case notEnoughBytesForSizeField(required: Int, available: Int)
    case readingChunkLengthFailed(Int)
    case notEnoughBytesForChunk(required: Int, available: Int)

    public var description: String {
        switch self {
        case .segmentIndexOutOfRange(let i): return "segment index \(i) out of range"
        case .notEnoughBytesForSizeField(let r, let a):
            return
                "segment doesn't include enough bytes to read the chunk size data field - required:\(r), available:\(a)"
        case .readingChunkLengthFailed(let n): return "reading chunk length failed with \(n)"
        case .notEnoughBytesForChunk(let r, let a):
            return
                "segment doesn't include enough bytes to read the chunk - required:\(r), available:\(a)"
        }
    }
}

/// Go: `chunks.Reader` — resolves a `BlockChunkRef` to a chunk.
public final class ChunkReader {
    /// The segments, in the sorted order that defines the reference index space. See the file header.
    private let segments: [[UInt8]]
    public let segmentNames: [String]

    /// Go: `NewDirReader` — every segment in the directory, name-sorted.
    ///
    /// Files whose names are not segments are still opened by upstream (it filters nothing), so the port
    /// does the same: a stray file becomes a segment whose magic will not match, which is upstream's
    /// behaviour rather than a silent skip.
    public init(fs: any PromFS, dir: String) throws {
        let names = try fs.list(dir).sorted()
        var loaded: [[UInt8]] = []
        for name in names {
            let h = try fs.openForReading(dir + "/" + name)
            loaded.append(try h.read(offset: 0, length: h.size))
            try h.close()
        }
        self.segmentNames = names
        self.segments = loaded
    }

    /// Go: `ChunkOrIterable` — the encoding and raw bytes at a reference.
    ///
    /// Returns the bytes rather than a decoded chunk: upstream goes through a `chunkenc.Pool`, which exists
    /// to recycle allocations and is not modelled (PORTING.md's `sync.Pool` exception). The caller builds
    /// whichever chunk type the encoding names.
    public func chunk(ref: ChunkRef) throws -> (encoding: Encoding, bytes: [UInt8]) {
        let (sgmIndex, chkStart) = BlockChunkRef(rawValue: ref.rawValue).unpack()
        guard sgmIndex >= 0, sgmIndex < segments.count else {
            throw ChunkReadError.segmentIndexOutOfRange(sgmIndex)
        }
        let sgm = segments[sgmIndex]

        // The MAXIMUM varint width, because the real one is unknown until it is read.
        if chkStart + maxChunkLengthFieldSize > sgm.count {
            throw ChunkReadError.notEnoughBytesForSizeField(
                required: chkStart + maxChunkLengthFieldSize, available: sgm.count)
        }
        let (chkDataLen, n) = GoVarint.uvarint(sgm, chkStart)
        if n <= 0 {
            throw ChunkReadError.readingChunkLengthFailed(n)
        }

        let chkEncStart = chkStart + n
        let chkEnd = chkEncStart + chunkEncodingSize + Int(chkDataLen) + crc32Size
        let chkDataStart = chkEncStart + chunkEncodingSize
        let chkDataEnd = chkEnd - crc32Size

        if chkEnd > sgm.count {
            throw ChunkReadError.notEnoughBytesForChunk(required: chkEnd, available: sgm.count)
        }

        // The CRC covers the encoding byte through the data — not the length prefix. Quirk 126.
        let sum = Array(sgm[chkDataEnd..<chkEnd])
        try checkCRC32(Array(sgm[chkEncStart..<chkDataEnd]), sum)

        let enc = Encoding(rawValue: sgm[chkEncStart])
        return (enc, Array(sgm[chkDataStart..<chkDataEnd]))
    }
}
