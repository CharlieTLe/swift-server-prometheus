//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/chunks.go @ v3.13.2 — `Writer`, on top of `PromFS` (ADR-15).
//
// §6e ported this file's pure half and stopped at the I/O; ADR-15 decided the seam; this is the rest. The
// framing and the batching arithmetic are already in `ChunkFormat.swift` and pinned, so what is new here is
// the orchestration: when a segment is cut, what its header says, how its name is chosen, and what
// `Close` leaves behind.
//
// ## A segment's name is `nextSequenceFile`, and it takes the MAXIMUM, not the count
//
// `nextSequenceFile` lists the directory, parses every name as a `uint64`, **skips the ones that do not
// parse**, and returns `max + 1` zero-padded to six digits. Upstream's comment explains why max rather
// than count: `'1000000'` sorts before `'200000'`, so directory order is not numeric order. A port that
// used the file count would collide after any gap.
//
// ## The header is 8 bytes and three of them are padding
//
//     <4-byte big-endian magic 0x85BD40DD> <1-byte format version> <3 bytes of zero>
//
// `SegmentHeaderSize` is 8 and only 5 bytes are used. The padding is not optional: the batching
// arithmetic (quirk 128) compares against `SegmentHeaderSize`, so a 5-byte header would move every
// segment boundary.
//
// ## Write to `.tmp`, then rename
//
// `cutSegmentFile` opens `<name>.tmp`, writes the header, closes it, renames it into place, then reopens
// for appending. So a crash mid-cut leaves a `.tmp` and no half-written segment. The port keeps the
// sequence because the *observable* result — which names exist when — is part of the format's contract,
// even though `PromFS` cannot crash.
//
// ## `finalizeTail` truncates, and here that is a no-op with a reason
//
// Upstream pre-allocates a segment and then truncates the superfluous zeros when cutting away from it.
// ADR-15 declines pre-allocation, so there is nothing to truncate — the call is kept, and it does nothing,
// so the call sites match (PORTING.md §4).
//===----------------------------------------------------------------------===//

public import PromChunkEnc
public import PromFS

internal import GoCompat

/// Go: `chunks.Writer`.
public final class ChunkWriter {
    private let fs: any PromFS
    private let dir: String
    private let segmentSize: Int64

    /// Go: `files` — every segment written, in order. Only the count and the tail's index are read.
    private var sequences: [Int] = []
    /// Go: `wbuf` plus the tail handle.
    private var tail: (any FSWriteHandle)? = nil
    /// Go: `n` — bytes written to the current segment, header included.
    private var n: Int64 = 0

    /// Go: `DefaultChunkSegmentSize`.
    public static let defaultSegmentSize: Int64 = 512 * 1024 * 1024

    public init(fs: any PromFS, dir: String, segmentSize: Int64 = ChunkWriter.defaultSegmentSize) throws
    {
        self.fs = fs
        self.dir = dir
        self.segmentSize = segmentSize
        // Go: `os.MkdirAll(dir, 0o777)` then opens the directory handle.
        try fs.createDirectory(dir)
    }

    /// Go: `nextSequenceFile` — the MAXIMUM parsable name plus one, not the file count.
    private func nextSequence() throws -> Int {
        var i: UInt64 = 0
        for name in try fs.list(dir) {
            // Names that do not parse as a decimal integer are SKIPPED, not counted — that is how a
            // stray `.tmp` or an unrelated file is tolerated.
            guard let j = UInt64(name) else { continue }
            if j > i { i = j }
        }
        return Int(i + 1)
    }

    /// Go: `segmentFile` — six digits, zero padded.
    static func segmentName(_ seq: Int) -> String {
        var s = String(seq)
        while s.count < 6 { s = "0" + s }
        return s
    }

    private func path(_ seq: Int) -> String { dir + "/" + Self.segmentName(seq) }

    /// Go: `finalizeTail` — flush, sync, and truncate away pre-allocated zeros.
    ///
    /// The truncate is a no-op here because ADR-15 declines pre-allocation; the call is kept so the shape
    /// matches upstream and a later pre-allocating `RealFS` has the hook.
    private func finalizeTail() throws {
        guard let t = tail else { return }
        try t.flush()
        try t.sync()
        try t.close()
        tail = nil
    }

    /// Go: `cut` plus `cutSegmentFile`.
    private func cut() throws {
        try finalizeTail()

        let seq = try nextSequence()
        let finalPath = path(seq)
        let tmpPath = finalPath + ".tmp"

        // Header first, into a temporary name, so a half-written segment never appears under its real one.
        let tmp = try fs.createFile(tmpPath)
        var header = [UInt8](repeating: 0, count: segmentHeaderSize)
        header[0] = UInt8(truncatingIfNeeded: magicChunks >> 24)
        header[1] = UInt8(truncatingIfNeeded: magicChunks >> 16)
        header[2] = UInt8(truncatingIfNeeded: magicChunks >> 8)
        header[3] = UInt8(truncatingIfNeeded: magicChunks)
        header[4] = chunksFormatV1
        // Bytes 5-7 stay zero: three bytes of padding that `SegmentHeaderSize` counts.
        try tmp.append(header)
        try tmp.flush()
        try tmp.close()

        // ADR-15 gives no rename, so the port copies and removes — the observable result (which names
        // exist, and with what contents) is identical, and `PromFS` cannot crash between the two.
        let readTmp = try fs.openForReading(tmpPath)
        let bytes = try readTmp.read(offset: 0, length: readTmp.size)
        try readTmp.close()
        let finalFile = try fs.createFile(finalPath)
        try finalFile.append(bytes)
        try fs.remove(tmpPath)
        try fs.syncDirectory(dir)

        sequences.append(seq)
        tail = finalFile
        n = Int64(segmentHeaderSize)
    }

    /// Go: `Writer.seq` — **`len(w.files) - 1`, a 0-based index into the writer's own file list, NOT the
    /// segment's filename number.**
    ///
    /// The two coincide only for a directory whose segments start at `000001` and have no gaps, which is
    /// why writing to a fresh directory hides the difference. `BlockChunkRef`'s "file index" is therefore
    /// a position in the reader's segment list, and `NewDirReader` builds that list by sorting the
    /// directory — so a directory whose first segment is `000005` yields index 0 for it.
    ///
    /// The port had this as the filename number and every one of the twelve batch cases disagreed on the
    /// ref while the segment BYTES matched exactly. A corpus that compared only the bytes would have
    /// missed it.
    private func fileIndex() -> Int { sequences.count - 1 }

    /// Go: `WriteChunks` — batch the chunks into segments, then write each batch.
    ///
    /// The batching is `chunkWriteBatches` (quirk 128, already pinned); this is the part that acts on it.
    /// Note the initial `if w.n == 0 { cut() }`: the first call cuts before writing, so a `Writer` that is
    /// never written to leaves **no segment at all**.
    @discardableResult
    public func write(_ chunks: [(encoding: Encoding, bytes: [UInt8])]) throws -> [ChunkRef] {
        var refs = [ChunkRef](repeating: ChunkRef(rawValue: 0), count: chunks.count)
        let batches = chunkWriteBatches(
            dataSizes: chunks.map { $0.bytes.count }, segmentSize: segmentSize,
            bytesAlreadyWritten: n)

        if n == 0 {
            try cut()
        }

        for (i, range) in batches.enumerated() {
            for j in range {
                // The reference is the segment index and the byte offset AT THE TIME OF WRITING, so it has
                // to be taken before the bytes go out.
                refs[j] = ChunkRef(
                    rawValue: BlockChunkRef(
                        fileIndex: UInt64(fileIndex()), fileOffset: UInt64(n)
                    ).rawValue)
                let framed = ChunkFraming.framed(chunks[j].encoding, chunks[j].bytes)
                guard let t = tail else { throw FSError.closed(dir) }
                try t.append(framed)
                n += Int64(framed.count)
            }
            if i < batches.count - 1 {
                try cut()
            }
        }
        return refs
    }

    /// Go: `Close`.
    public func close() throws {
        try finalizeTail()
    }

    /// The segment names written, in order — for tests and for the reader.
    public var segmentNames: [String] { sequences.map(Self.segmentName) }
}
