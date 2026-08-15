//===----------------------------------------------------------------------===//
// Ported from tsdb/chunks/head_chunks.go @ v3.13.2 — the `ChunkDiskMapper`.
//
// The Head's chunks do not live in a block. When a `memSeries` fills a chunk it is handed to this, which
// appends it to a numbered file under `chunks_head/` and returns a `ChunkDiskMapperRef` naming where it
// went. The Head then holds only that 8-byte reference. So this is the *other* chunk format — a sibling of
// `chunks.go`'s, sharing the 8-byte segment header and the CRC discipline, and differing in the per-chunk
// metadata: a head chunk carries its series reference and its mint/maxt, a block chunk carries neither.
//
// ## The per-chunk layout, and the one field the WRITER never writes
//
//     [BE64 series ref][BE64 mint][BE64 maxt][1 byte encoding|OOO mask][uvarint data len][data][BE32 CRC]
//
// `IterateAllChunks` reads a `numSamples` as a BE16 *at the start of the chunk data* — it is not a field of
// this format at all, it is the first two bytes of an XOR chunk's own body. So the head chunk format
// borrows a fact about `chunkenc`'s payload, and a port that treated `numSamples` as its own field would
// write a fourth header value that upstream never writes. Quirk 181.
//
// ## `chunkPos` decides the reference BEFORE the write, and that is what makes the queue possible
//
// `getNextChunkRef` computes the ref and the cut-a-new-file decision from a running `(seq, offset)` pair,
// advancing `offset` by exactly what the write will consume. The write then *asserts* it landed there
// (`cutAndExpectRef`). Upstream needs this because the write can be queued behind other writes; the port has
// no queue and still keeps the split, because the assertion is a real consistency check and its error
// message is part of the contract.
//
// `bytesToWriteForChunk` is the arithmetic that has to agree with the writer byte for byte:
// `8 + 8 + 8 + 1 + UvarintSize(len) + len + 4`.
//
// ## What is deliberately absent
//
//   * **The write QUEUE.** `DefaultWriteQueueSize` is **0**, which disables it — `NewChunkDiskMapper` only
//     builds a `chunkWriteQueue` when asked for one, and `db.go` never asks. So the port implements the
//     direct path and `isQueueEmpty` is always true. Porting the queue means porting a goroutine and a
//     condition variable for a feature upstream ships off.
//   * **mmap.** ADR-15 declines it: a "mapped" file here is its bytes, read whole. Two consequences worth
//     knowing before reading the writer. The 128 MiB `MaxHeadChunkFileSize` mapping goes away, which is why
//     `curFileSize` and not the file's length is what `IterateAllChunks` bounds the CURRENT file by. But the
//     128 KiB `HeadChunkFilePreallocationSize` does NOT: it is never truncated away, so it is part of the
//     format and the port reproduces it (quirk 182). And a zero-length file is an mmap error upstream and a
//     header error here — exception 22.
//   * **`HardLinkChunkFiles`.** Needs `os.Link`, and `PromFS` has no hardlink verb (ADR-15). Its only caller
//     is `db.go`'s snapshot path. Deferred with `openForAppending` and the rest of the ADR-15 gaps.
//   * **`chunkenc.Pool`.** PORTING.md's standing `sync.Pool` exception. `chunk(ref:)` returns the encoding
//     and the bytes, exactly as `ChunkReader.chunk(ref:)` does, and the caller builds the chunk type.
//   * **Metrics**, and the `prometheus.Registerer` argument that carries them.
//===----------------------------------------------------------------------===//

internal import GoCompat
public import PromChunkEnc
public import PromFS
internal import PromHash

// MARK: - Format constants

/// Go: `MagicHeadChunks` — 4 bytes at the start of a head chunk file. **Not** `MagicChunks`.
public let magicHeadChunks: UInt32 = 0x0130_BC91
let headChunksFormatV1: UInt8 = 1

/// Go: `MintMaxtSize`.
public let mintMaxtSize = 8
/// Go: `SeriesRefSize`.
public let seriesRefSize = 8
/// Go: `HeadChunkFileHeaderSize` — the same 8-byte header `chunks.go` writes.
public let headChunkFileHeaderSize = segmentHeaderSize
/// Go: `MaxHeadChunkFileSize` — 128 MiB.
public let maxHeadChunkFileSize = 128 * 1024 * 1024
/// Go: `MaxHeadChunkMetaSize` — the most a chunk's metadata can take. "Max" because the uvarint can be
/// shorter, which is why `IterateAllChunks` checks it as a *lower bound* on the bytes remaining.
public let maxHeadChunkMetaSize =
    seriesRefSize + 2 * mintMaxtSize + chunkEncodingSize + maxChunkLengthFieldSize + crc32Size
/// Go: `MinWriteBufferSize` / `MaxWriteBufferSize` / `DefaultWriteBufferSize`.
public let minWriteBufferSize = 64 * 1024
public let maxWriteBufferSize = 8 * 1024 * 1024
public let defaultWriteBufferSize = 4 * 1024 * 1024
/// Go: `DefaultWriteQueueSize` — **0**, which disables the queue. See the file header.
public let defaultWriteQueueSize = 0
/// Go: `HeadChunkFilePreallocationSize` (`head_chunks_other.go:21`) — `MinWriteBufferSize * 2`. Unused here
/// because ADR-15 declines pre-allocation; kept so the constant is not rediscovered.
public let headChunkFilePreallocationSize = minWriteBufferSize * 2

/// Go: `OutOfOrderMask` — the top bit of the encoding byte, used by the Head for its own bookkeeping and
/// never written into a block.
public let outOfOrderMask: UInt8 = 0b1000_0000

/// Go: `ChunkDiskMapper.ApplyOutOfOrderMask` / `IsOutOfOrderChunk` / `RemoveMasks`. Methods upstream, but
/// they take no receiver state, so they are free functions here.
public func applyOutOfOrderMask(_ e: Encoding) -> Encoding {
    Encoding(rawValue: e.rawValue | outOfOrderMask)
}

public func isOutOfOrderChunk(_ e: Encoding) -> Bool {
    (e.rawValue & outOfOrderMask) != 0
}

public func removeMasks(_ e: Encoding) -> Encoding {
    Encoding(rawValue: e.rawValue & ~outOfOrderMask)
}

// MARK: - Errors

/// Go: `chunks.CorruptionErr`.
///
/// The message is `corruption in head chunk file <segmentFile(dir, idx)>: <err>`, and note it renders the
/// **file name**, so a `fileIndex` of -1 produces `.../-000001` rather than anything special-cased — `%0.6d`
/// is a precision, so the sign sits outside the six digits (quirk 183). It is reachable: `chunk(ref:)` uses
/// -1 for "index beyond the current open file".
public struct HeadChunkCorruptionError: Error, CustomStringConvertible {
    public var dir: String
    public var fileIndex: Int
    public var underlying: any Error

    public init(dir: String, fileIndex: Int, underlying: any Error) {
        self.dir = dir
        self.fileIndex = fileIndex
        self.underlying = underlying
    }

    public var description: String {
        "corruption in head chunk file \(headSegmentFile(dir, fileIndex)): \(underlying)"
    }
}

/// Go: `segmentFile` — `fmt.Sprintf("%0.6d", index)`.
///
/// `.6` is a **precision**, not a width, so it is a minimum number of DIGITS and the sign is separate: -1
/// renders as `-000001`, seven characters. Reproduced rather than guarded because a negative index is
/// reachable — `chunk(ref:)`'s "more than current open file" arm passes -1 and its message is pinned. Padding
/// the sign into the six caught it: the port answered `-00001` and the fixture said no.
func headSegmentFile(_ dir: String, _ index: Int) -> String {
    let negative = index < 0
    var s = String(negative ? -index : index)
    while s.count < 6 { s = "0" + s }
    if negative { s = "-" + s }
    return dir.isEmpty ? s : "\(dir)/\(s)"
}

/// Go: the errors `head_chunks.go` produces itself.
public enum HeadChunksError: Error, CustomStringConvertible, Equatable {
    /// Go: `ErrChunkDiskMapperClosed`.
    case closed
    case writeBufferSizeOutOfRange(min: Int, max: Int, actual: Int)
    case writeBufferSizeNotMultipleOf1024(Int)
    case unsequentialFiles(firstName: String, firstIndex: Int, secondName: String, secondIndex: Int)
    case invalidHeadChunkFileHeader(file: String)
    case invalidMagicNumber(file: String, magic: UInt32)
    case invalidChunkFormatVersion(file: String, version: Int)
    case unexpectedCutPosition(expSeq: Int, expOffset: Int, seq: Int, offset: Int)
    case indexMoreThanCurrentOpenFile(Int)
    case indexDoesNotExistOnDisk(Int)
    case notEnoughBytesForSizeField(required: Int, available: Int)
    case notEnoughBytesForChunk(required: Int, available: Int)
    case readingChunkLengthFailed(Int)
    case chunkLengthExceedsSupportedSize(UInt64)
    case chunkDataEndOverflows(start: Int, len: Int, n: Int)
    case unreadDataButNotEnoughForHeader(required: Int, available: Int, file: Int)
    case notEnoughBytesForChunkHeader(required: Int, available: Int, file: Int)
    case notEnoughBytesForLastChunkData(required: Int, available: Int, file: Int)
    case cannotHandleError(String)

    public var description: String {
        switch self {
        case .closed: return "ChunkDiskMapper closed"
        case .writeBufferSizeOutOfRange(let lo, let hi, let a):
            return "ChunkDiskMapper write buffer size should be between \(lo) and \(hi) (actual: \(a))"
        case .writeBufferSizeNotMultipleOf1024(let a):
            return "ChunkDiskMapper write buffer size should be a multiple of 1024 (actual: \(a))"
        case .unsequentialFiles(let n1, let i1, let n2, let i2):
            return "found unsequential head chunk files \(n1) (index: \(i1)) and \(n2) (index: \(i2))"
        case .invalidHeadChunkFileHeader(let f):
            return "\(f): invalid head chunk file header: \(InvalidSizeError())"
        case .invalidMagicNumber(let f, let m):
            return "\(f): invalid magic number \(String(m, radix: 16))"
        case .invalidChunkFormatVersion(let f, let v):
            return "\(f): invalid chunk format version \(v)"
        case .unexpectedCutPosition(let es, let eo, let s, let o):
            return "expected newly cut file to have sequence:offset \(es):\(eo), got \(s):\(o)"
        case .indexMoreThanCurrentOpenFile(let i):
            return "head chunk file index \(i) more than current open file"
        case .indexDoesNotExistOnDisk(let i):
            return "head chunk file index \(i) does not exist on disk"
        case .notEnoughBytesForSizeField(let r, let a):
            return "head chunk file doesn't include enough bytes to read the chunk size data field"
                + " - required:\(r), available:\(a)"
        case .notEnoughBytesForChunk(let r, let a):
            return "head chunk file doesn't include enough bytes to read the chunk"
                + " - required:\(r), available:\(a)"
        case .readingChunkLengthFailed(let n): return "reading chunk length failed with \(n)"
        case .chunkLengthExceedsSupportedSize(let l): return "chunk length \(l) exceeds supported size"
        case .chunkDataEndOverflows(let s, let l, let n):
            return "chunk data end overflows supported size (start=\(s), len=\(l), n=\(n))"
        case .unreadDataButNotEnoughForHeader(let r, let a, let f):
            return "head chunk file has some unread data, but doesn't include enough bytes to read the"
                + " chunk header - required:\(r), available:\(a), file:\(f)"
        case .notEnoughBytesForChunkHeader(let r, let a, let f):
            return "head chunk file doesn't include enough bytes to read the chunk header"
                + " - required:\(r), available:\(a), file:\(f)"
        case .notEnoughBytesForLastChunkData(let r, let a, let f):
            return "head chunk file doesn't include enough bytes to read the last chunk data"
                + " - required:\(r), available:\(a), file:\(f)"
        case .cannotHandleError(let e): return "cannot handle error: \(e)"
        }
    }
}

// MARK: - ChunkDiskMapperRef's arithmetic

extension ChunkDiskMapperRef {
    /// Go: `newChunkDiskMapperRef` — the file index in the upper 4 bytes, the byte offset in the lower 4.
    public init(seq: UInt64, offset: UInt64) {
        self.init(rawValue: (seq << 32) | offset)
    }

    /// Go: `Unpack`.
    public func unpack() -> (seq: Int, offset: Int) {
        (Int(rawValue >> 32), Int((rawValue << 32) >> 32))
    }

    /// Go: `GreaterThanOrEqualTo`. Compares the two halves separately rather than the packed value — which
    /// gives the same answer for every ref a writer produces, and is kept because upstream's spelling is
    /// what a reader checks against.
    public func greaterThanOrEqualTo(_ r: ChunkDiskMapperRef) -> Bool {
        let (s1, o1) = unpack()
        let (s2, o2) = r.unpack()
        return s1 > s2 || (s1 == s2 && o1 >= o2)
    }

    /// Go: `GreaterThan`.
    public func greaterThan(_ r: ChunkDiskMapperRef) -> Bool {
        let (s1, o1) = unpack()
        let (s2, o2) = r.unpack()
        return s1 > s2 || (s1 == s2 && o1 > o2)
    }
}

// MARK: - chunkPos

/// Go: `chunkPos` — where the next chunk will go, tracked ahead of the write.
///
/// Not thread-safe upstream either; the comment says so and a mutex guards it. The port has no queue, so
/// there is nothing to serialise against.
struct ChunkPos {
    var seq: UInt64 = 0
    var offset: UInt64 = 0
    var cutFile = false

    /// Go: `getNextChunkRef`. **Order-dependent**: it must be called in the order chunks are written, because
    /// it advances `offset` by what each write consumes.
    mutating func getNextChunkRef(chunkLength: Int) -> (ref: ChunkDiskMapperRef, cutFile: Bool) {
        let chkLen = UInt64(chunkLength)
        let bytesToWrite = Self.bytesToWriteForChunk(chkLen)

        var cut = false
        if shouldCutNewFile(bytesToWrite) {
            toNewFile()
            cutFile = false
            cut = true
        }

        let chkOffset = offset
        offset += bytesToWrite
        return (ChunkDiskMapperRef(seq: seq, offset: chkOffset), cut)
    }

    /// Go: `toNewFile` — the offset restarts at the header size, not at 0.
    mutating func toNewFile() {
        seq += 1
        offset = UInt64(segmentHeaderSize)
    }

    /// Go: `cutFileOnNextChunk`.
    mutating func cutFileOnNextChunk() { cutFile = true }

    /// Go: `setSeq`.
    mutating func setSeq(_ s: UInt64) { seq = s }

    /// Go: `shouldCutNewFile`. `offset == 0` is how the FIRST file is recognised — a real file's offset is
    /// never below the header size.
    func shouldCutNewFile(_ bytesToWrite: UInt64) -> Bool {
        if cutFile { return true }
        return offset == 0 || offset + bytesToWrite > UInt64(maxHeadChunkFileSize)
    }

    /// Go: `bytesToWriteForChunk`. Must agree with `writeChunk` byte for byte.
    static func bytesToWriteForChunk(_ chkLen: UInt64) -> UInt64 {
        var bytes = UInt64(seriesRefSize) + 2 * UInt64(mintMaxtSize) + UInt64(chunkEncodingSize)
        bytes += UInt64(GoVarint.uvarintSize(chkLen))
        bytes += chkLen
        bytes += UInt64(crc32Size)
        return bytes
    }
}

// MARK: - The buffered writer

// Go uses a `bufio.Writer` over the file plus an mmap of the same file, and `os.File` writes at the
// descriptor's own offset — so the header, the chunks and the pre-allocated zero tail coexist naturally.
// `PromFS` has neither a positional write nor an appending open (ADR-15), and `createFile` TRUNCATES, so the
// port keeps the current file's content in memory and rewrites it whenever it changes.
//
// That is not a shortcut, it is what makes two observable things come out right, and the corpus caught both:
//
//   * the segment HEADER survives. `cutSegmentFile` writes it, and a second `createFile` for the append
//     handle would erase it — the port's first version produced files that began with the first chunk;
//   * `Size()` reads the PRE-ALLOCATED length from the moment the file is cut, not after the first flush.
//     Go pre-allocates in `cutSegmentFile`; padding at close instead reports 32,802 where Go reports 131,072.
//
// `pending` is the `bufio.Writer` buffer, and it is modelled rather than dropped because its `Available()` is
// read by `writeChunk` to decide whether to flush — and a flush clears the `chunkBuffer`, which decides
// whether `chunk(ref:)` is served from memory or from the file.

// MARK: - chunkBuffer

/// Go: `chunkBuffer` — chunks served from memory until they are flushed.
///
/// Upstream shards it across `inBufferShards = 128` maps, each with its own mutex, and the comment says 128
/// is "a randomly chosen number". The shard index is `ref % 128`, so it partitions the same key space and
/// changes nothing observable — it exists to spread lock contention, which a port without the write queue
/// does not have. One dictionary here, and the control that removes the sharding could not fail.
struct HeadChunkBuffer {
    private var entries: [ChunkDiskMapperRef: (encoding: Encoding, bytes: [UInt8])] = [:]

    mutating func put(_ ref: ChunkDiskMapperRef, _ encoding: Encoding, _ bytes: [UInt8]) {
        entries[ref] = (encoding, bytes)
    }

    func get(_ ref: ChunkDiskMapperRef) -> (encoding: Encoding, bytes: [UInt8])? {
        entries[ref]
    }

    mutating func clear() { entries.removeAll(keepingCapacity: true) }
}

// MARK: - ChunkDiskMapper

/// Go: `chunks.ChunkDiskMapper`.
///
/// Not `Sendable` and not internally locked, for the same reason `WL` is not: upstream's three mutexes exist
/// because the Head appends from many goroutines and the write queue drains on another, and the port has
/// neither yet. The Head's concurrency story belongs to that slice.
public final class ChunkDiskMapper {

    private var fs: any PromFS { fsStorage }
    private let fsStorage: any PromFS
    private let directory: String
    private let writeBufferSize: Int

    /// Whether a file is currently open for writing. Go's `curFile != nil`.
    private var hasCurFile = false
    private var curFileSequence = 0
    /// The current file's LOGICAL content — header plus every chunk written, flushed or not. On disk it is
    /// this padded out to `headChunkFilePreallocationSize`. See the note above `MARK: - The buffered writer`.
    private var curFileBytes: [UInt8] = []
    /// Go: the `bufio.Writer`'s buffer. Part of the content, not yet spliced into `curFileBytes`.
    private var pending: [UInt8] = []
    /// Go: `curFileOffset` — bytes handed to the writer, advanced whether or not they have been flushed. It
    /// is the bound `IterateAllChunks` uses for the current file, which is why it is not the file's length.
    private var curFileOffset: UInt64 = 0
    private var curFileMaxt: Int64 = 0

    private var evtlPos = ChunkPos()

    private var crc = CRC32C()

    /// Go: `mmappedChunkFiles` — the bytes of each file, plus its max timestamp. ADR-15 declines mmap, so
    /// "mapped" means "read whole".
    private var mappedChunkFiles: [Int: MappedHeadChunkFile] = [:]

    private var chunkBuffer = HeadChunkBuffer()
    /// Go: `fileMaxtSet` — whether `IterateAllChunks` has run and filled in every file's `maxt`.
    public private(set) var fileMaxtSet = false
    private var closed = false

    public var dir: String { directory }

    struct MappedHeadChunkFile {
        var bytes: [UInt8]
        var maxt: Int64 = 0
    }

    /// Go: `NewChunkDiskMapper`. The buffer-size validation happens **before** the directory is created, so
    /// a bad size leaves no directory behind.
    ///
    /// `writeQueueSize` is accepted and must be 0: see the file header on the queue.
    public init(
        fs: any PromFS, dir: String, writeBufferSize: Int = defaultWriteBufferSize,
        writeQueueSize: Int = defaultWriteQueueSize
    ) throws {
        guard writeBufferSize >= minWriteBufferSize, writeBufferSize <= maxWriteBufferSize else {
            throw HeadChunksError.writeBufferSizeOutOfRange(
                min: minWriteBufferSize, max: maxWriteBufferSize, actual: writeBufferSize)
        }
        guard writeBufferSize % 1024 == 0 else {
            throw HeadChunksError.writeBufferSizeNotMultipleOf1024(writeBufferSize)
        }
        precondition(
            writeQueueSize == 0,
            "the write queue is not ported: DefaultWriteQueueSize is 0 and db.go never asks for one")

        self.fsStorage = fs
        self.directory = dir
        self.writeBufferSize = writeBufferSize

        try fs.createDirectory(dir)
        try openMappedFiles()
    }

    // MARK: Opening

    /// Go: `openMMapFiles`. The order is load-bearing: repair the last file, load them all, check for a
    /// **gap**, then check each header. A gap is reported before any header is looked at.
    private func openMappedFiles() throws {
        mappedChunkFiles = [:]

        var files = try Self.listChunkFiles(fs, directory)
        files = try repairLastChunkFile(files)

        var indices: [Int] = []
        for (seq, fn) in files {
            let h = try fs.openForReading(fn)
            let bytes = try h.read(offset: 0, length: h.size)
            try h.close()
            mappedChunkFiles[seq] = MappedHeadChunkFile(bytes: bytes)
            indices.append(seq)
        }

        indices.sort()
        if indices.isEmpty { return }
        var lastSeq = indices[0]
        for seq in indices.dropFirst() {
            if seq != lastSeq + 1 {
                throw HeadChunksError.unsequentialFiles(
                    firstName: files[lastSeq] ?? "", firstIndex: lastSeq,
                    secondName: files[seq] ?? "", secondIndex: seq)
            }
            lastSeq = seq
        }

        // Go iterates the MAP here, so which file a multi-file error names is not deterministic upstream.
        // The port iterates in index order, which is one of the orders Go can produce; exception 21.
        for i in indices {
            let b = mappedChunkFiles[i]!.bytes
            if b.count < headChunkFileHeaderSize {
                throw HeadChunksError.invalidHeadChunkFileHeader(file: files[i] ?? "")
            }
            var m: UInt32 = 0
            for k in 0..<magicChunksSize { m = (m << 8) | UInt32(b[k]) }
            if m != magicHeadChunks {
                throw HeadChunksError.invalidMagicNumber(file: files[i] ?? "", magic: m)
            }
            let v = Int(b[magicChunksSize])
            if v != Int(chunksFormatV1) {
                throw HeadChunksError.invalidChunkFormatVersion(file: files[i] ?? "", version: v)
            }
        }

        evtlPos.setSeq(UInt64(lastSeq))
    }

    /// Go: `listChunkFiles` — names that do not parse as a `uint64` are **skipped**, not an error.
    static func listChunkFiles(_ fs: any PromFS, _ dir: String) throws -> [Int: String] {
        var res: [Int: String] = [:]
        for name in try fs.list(dir) {
            guard let seq = UInt64(name) else { continue }
            res[Int(seq)] = "\(dir)/\(name)"
        }
        return res
    }

    /// Go: `repairLastChunkFile` — deletes the last file if it is empty, because these files are not fsynced
    /// on creation and an abrupt shutdown can leave a zero-length one.
    ///
    /// Two details that are easy to lose. `lastFile <= 0` returns early, so **file 0 is never repaired** —
    /// index 0 is not a file a writer creates (`toNewFile` pre-increments), so a 0 here is already odd. And
    /// a *wrong* magic number is deliberately NOT an error here: the comment says that has to travel up so
    /// the Head can run its own repair. Only "too short" or "magic is zero" delete.
    private func repairLastChunkFile(_ files: [Int: String]) throws -> [Int: String] {
        var files = files
        var lastFile = -1
        for seq in files.keys where seq > lastFile { lastFile = seq }
        if lastFile <= 0 { return files }

        let h = try fs.openForReading(files[lastFile]!)
        let n = min(magicChunksSize, h.size)
        let buf = try h.read(offset: 0, length: n)
        try h.close()

        var magic: UInt32 = 0
        if buf.count >= magicChunksSize {
            for k in 0..<magicChunksSize { magic = (magic << 8) | UInt32(buf[k]) }
        }
        if buf.count < magicChunksSize || magic == 0 {
            try fs.remove(files[lastFile]!)
            files.removeValue(forKey: lastFile)
        }
        return files
    }

    // MARK: Writing

    /// Go: `WriteChunk`. Takes the encoding and bytes rather than a `chunkenc.Chunk`, matching
    /// `ChunkReader.chunk(ref:)` — the pool is not modelled, so a chunk here *is* its encoding and bytes.
    ///
    /// The callback is upstream's queue completion hook. With no queue it fires inline, before returning,
    /// which is exactly what the direct path does upstream.
    @discardableResult
    public func writeChunk(
        seriesRef: HeadSeriesRef, mint: Int64, maxt: Int64, encoding: Encoding, bytes: [UInt8],
        isOOO: Bool = false, callback: ((any Error)?) -> Void = { _ in }
    ) -> ChunkDiskMapperRef {
        let (ref, cutFile) = evtlPos.getNextChunkRef(chunkLength: bytes.count)
        do {
            try writeChunkAt(
                seriesRef: seriesRef, mint: mint, maxt: maxt, encoding: encoding, bytes: bytes,
                ref: ref, isOOO: isOOO, cutFile: cutFile)
            callback(nil)
        } catch {
            callback(error)
        }
        return ref
    }

    /// Go: `writeChunk` (the lower-case one).
    private func writeChunkAt(
        seriesRef: HeadSeriesRef, mint: Int64, maxt: Int64, encoding: Encoding, bytes: [UInt8],
        ref: ChunkDiskMapperRef, isOOO: Bool, cutFile: Bool
    ) throws {
        if closed { throw HeadChunksError.closed }

        if cutFile {
            try cutAndExpectRef(ref)
        }

        // The condition is subtle and both halves matter. A chunk at least as big as the buffer is NOT
        // flushed-before, because it will be flushed *after* anyway (the second check below); flushing here
        // as well would write the same partial page twice as far as `curFileOffset` is concerned.
        if bytes.count + maxHeadChunkMetaSize < writeBufferSize,
            writerAvailable < maxHeadChunkMetaSize + bytes.count
        {
            try flushBuffer()
        }

        crc.reset()
        var header: [UInt8] = []
        header.reserveCapacity(maxHeadChunkMetaSize)
        appendBE64(&header, UInt64(bitPattern: Int64(seriesRef.rawValue)))
        appendBE64(&header, UInt64(bitPattern: mint))
        appendBE64(&header, UInt64(bitPattern: maxt))
        header.append(isOOO ? applyOutOfOrderMask(encoding).rawValue : encoding.rawValue)
        _ = GoVarint.putUvarint(&header, UInt64(bytes.count))

        try writeAndAppendToCRC32(header)
        try writeAndAppendToCRC32(bytes)
        try writeCRC32()

        if maxt > curFileMaxt { curFileMaxt = maxt }

        chunkBuffer.put(ref, encoding, bytes)

        if bytes.count + maxHeadChunkMetaSize >= writeBufferSize {
            // Bigger than the buffer itself, so flush rather than keep a partial chunk in it.
            try flushBuffer()
        }
    }

    private func appendBE64(_ out: inout [UInt8], _ v: UInt64) {
        out.append(UInt8(truncatingIfNeeded: v >> 56))
        out.append(UInt8(truncatingIfNeeded: v >> 48))
        out.append(UInt8(truncatingIfNeeded: v >> 40))
        out.append(UInt8(truncatingIfNeeded: v >> 32))
        out.append(UInt8(truncatingIfNeeded: v >> 24))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    /// Go: `CutNewFile`.
    public func cutNewFile() {
        evtlPos.cutFileOnNextChunk()
    }

    /// Go: `IsQueueEmpty` — always true, because the queue is not ported.
    public var isQueueEmpty: Bool { true }

    /// Go: `cutAndExpectRef` — cut, then assert the new position is the one `chunkPos` predicted.
    private func cutAndExpectRef(_ chkRef: ChunkDiskMapperRef) throws {
        let (seq, offset) = try cut()
        let (expSeq, expOffset) = chkRef.unpack()
        if seq != expSeq || offset != expOffset {
            throw HeadChunksError.unexpectedCutPosition(
                expSeq: expSeq, expOffset: expOffset, seq: seq, offset: offset)
        }
    }

    /// Go: `cut`. Finalise the tail, create the next numbered file with its header, and adopt it.
    ///
    /// The previous file's `maxt` is written into the mapped-files table here, which is the only place it is
    /// set for a file the process itself wrote — `IterateAllChunks` sets it for the ones it read.
    private func cut() throws -> (seq: Int, offset: Int) {
        let previousSequence = hasCurFile ? curFileSequence : nil
        try finalizeCurFile()

        // Go: `nextSequenceFile` — the MAXIMUM parsable name plus one, so a gap is not filled.
        var i: UInt64 = 0
        for name in try fs.list(directory) {
            guard let j = UInt64(name) else { continue }
            if j > i { i = j }
        }
        let seq = Int(i + 1)

        if let prev = previousSequence, mappedChunkFiles[prev] != nil {
            mappedChunkFiles[prev]!.maxt = curFileMaxt
        }

        var header = [UInt8](repeating: 0, count: segmentHeaderSize)
        header[0] = UInt8(truncatingIfNeeded: magicHeadChunks >> 24)
        header[1] = UInt8(truncatingIfNeeded: magicHeadChunks >> 16)
        header[2] = UInt8(truncatingIfNeeded: magicHeadChunks >> 8)
        header[3] = UInt8(truncatingIfNeeded: magicHeadChunks)
        header[4] = headChunksFormatV1
        // Bytes 5-7 stay zero: three bytes of padding that `SegmentHeaderSize` counts.

        curFileSequence = seq
        hasCurFile = true
        curFileBytes = header
        pending = []
        curFileOffset = UInt64(segmentHeaderSize)
        curFileMaxt = 0

        // Persist immediately, PRE-ALLOCATED. `Size()` reports the pre-allocated length from this moment
        // upstream, and the corpus reads it before `Close`.
        try persistCurrentFile()
        try fs.syncDirectory(directory)

        return (seq, segmentHeaderSize)
    }

    /// Writes the current file: its logical content, padded out to `HeadChunkFilePreallocationSize`.
    ///
    /// **The pre-allocated tail is never truncated away, and that is the format rather than an artefact.**
    /// `cutSegmentFile` pre-allocates and `finalizeCurFile` does flush-sync-close with no truncate, so every
    /// head chunk file is at least 128 KiB with a zero tail — which is exactly what `IterateAllChunks`' "all
    /// zeros marks the end of the content" branch and its `seriesRef == 0 && mint == 0 && maxt == 0` break
    /// exist to handle. A port that skipped it would make both branches unreachable *and* its files a
    /// different length. Contrast `Writer.finalizeTail` in `ChunkWriter.swift`, which does truncate, because
    /// there the pre-allocation is unobservable and ADR-15 declines it.
    private func persistCurrentFile() throws {
        guard hasCurFile else { return }
        var content = curFileBytes
        content.append(contentsOf: pending)
        if content.count < headChunkFilePreallocationSize {
            content.append(
                contentsOf: [UInt8](repeating: 0, count: headChunkFilePreallocationSize - content.count))
        }
        // `createFile` truncates, which is what makes rewriting the whole file correct here.
        let h = try fs.createFile(headSegmentFile(directory, curFileSequence))
        try h.append(content)
        try h.flush()
        try h.close()
        // The mapped view is this file's bytes; upstream gets that from mmap for free.
        let maxt = mappedChunkFiles[curFileSequence]?.maxt ?? 0
        mappedChunkFiles[curFileSequence] = MappedHeadChunkFile(bytes: content, maxt: maxt)
    }

    /// Go: `finalizeCurFile` — flush, sync, close. No truncate; see `persistCurrentFile`.
    private func finalizeCurFile() throws {
        guard hasCurFile else { return }
        try flushBuffer()
        try persistCurrentFile()
        hasCurFile = false
    }

    /// Go: `write` — advances `curFileOffset` by the full amount regardless of buffering, and buffers through
    /// `bufio.Writer`'s rules: a slice that does not fit flushes first, and one at least as big as the buffer
    /// goes straight through.
    private func write(_ b: [UInt8]) throws {
        if b.count > writeBufferSize - pending.count {
            try flushPending()
            if b.count >= writeBufferSize {
                curFileBytes.append(contentsOf: b)
                curFileOffset += UInt64(b.count)
                return
            }
        }
        pending.append(contentsOf: b)
        curFileOffset += UInt64(b.count)
    }

    /// Go: `bufio.Writer.Available()`, which `writeChunk` reads to decide whether to flush first.
    private var writerAvailable: Int { writeBufferSize - pending.count }

    private func flushPending() throws {
        if pending.isEmpty { return }
        curFileBytes.append(contentsOf: pending)
        pending = []
    }

    private func writeAndAppendToCRC32(_ b: [UInt8]) throws {
        try write(b)
        crc.update(b)
    }

    /// Go: `writeCRC32` — `crc32.Sum` appends BIG-endian, which `checkCRC32` then reassembles by hand.
    private func writeCRC32() throws {
        let s = crc.final()
        var out: [UInt8] = []
        out.append(UInt8(truncatingIfNeeded: s >> 24))
        out.append(UInt8(truncatingIfNeeded: s >> 16))
        out.append(UInt8(truncatingIfNeeded: s >> 8))
        out.append(UInt8(truncatingIfNeeded: s))
        try write(out)
    }

    /// Go: `flushBuffer` — flushes the writer AND clears the chunk buffer, so a flushed chunk is served from
    /// the file from then on rather than from memory.
    private func flushBuffer() throws {
        try flushPending()
        try persistCurrentFile()
        chunkBuffer.clear()
    }

    // MARK: Reading

    /// Go: `Chunk`. Returns the encoding and bytes; see the file header on the pool.
    public func chunk(ref: ChunkDiskMapperRef) throws -> (encoding: Encoding, bytes: [UInt8]) {
        if closed { throw HeadChunksError.closed }

        var (sgmIndex, chkStart) = ref.unpack()
        // The ref points at the series ref; the encoding is past it and the two timestamps.
        chkStart += seriesRefSize + 2 * mintMaxtSize

        // A chunk in the current file may still be in the buffer.
        if sgmIndex == curFileSequence, let c = chunkBuffer.get(ref) {
            return c
        }

        guard let mapped = mappedChunkFiles[sgmIndex] else {
            if sgmIndex > curFileSequence {
                throw HeadChunkCorruptionError(
                    dir: directory, fileIndex: -1,
                    underlying: HeadChunksError.indexMoreThanCurrentOpenFile(sgmIndex))
            }
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.indexDoesNotExistOnDisk(sgmIndex))
        }
        let b = mapped.bytes

        if chkStart + maxChunkLengthFieldSize > b.count {
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.notEnoughBytesForSizeField(
                    required: chkStart + maxChunkLengthFieldSize, available: b.count))
        }

        let sourceEnc = Encoding(rawValue: b[chkStart])
        let chkEnc = removeMasks(sourceEnc)

        let chkDataLenStart = chkStart + chunkEncodingSize
        let (chkDataLen, n) = GoVarint.uvarint(b, chkDataLenStart)
        if n <= 0 {
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.readingChunkLengthFailed(n))
        }
        if chkDataLen > UInt64(Int.max) {
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.chunkLengthExceedsSupportedSize(chkDataLen))
        }
        let chkDataLenInt = Int(chkDataLen)
        if chkDataLenStart > Int.max - n - chkDataLenInt {
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.chunkDataEndOverflows(
                    start: chkDataLenStart, len: chkDataLenInt, n: n))
        }

        let chkDataEnd = chkDataLenStart + n + chkDataLenInt
        if chkDataEnd > b.count {
            throw HeadChunkCorruptionError(
                dir: directory, fileIndex: sgmIndex,
                underlying: HeadChunksError.notEnoughBytesForChunk(
                    required: chkDataEnd, available: b.count))
        }

        // The CRC covers from the SERIES REF, not from the encoding — which is why `chkStart` is walked
        // back by the header it was advanced past.
        let sum = Array(b[chkDataEnd..<(chkDataEnd + crc32Size)])
        let covered = Array(b[(chkStart - (seriesRefSize + 2 * mintMaxtSize))..<chkDataEnd])
        do {
            try checkCRC32(covered, sum)
        } catch {
            throw HeadChunkCorruptionError(dir: directory, fileIndex: sgmIndex, underlying: error)
        }

        let data = Array(b[(chkDataEnd - chkDataLenInt)..<chkDataEnd])
        return (chkEnc, data)
    }

    /// Go: `IterateAllChunks`. Must be called once after construction to set every file's `maxt`.
    ///
    /// Three things a reading of the loop does not give away, all pinned by the corpus:
    ///
    ///  * `numSamples` is read as a BE16 **from the chunk data**, not from a field of this format — quirk 181;
    ///  * `seriesRef == 0 && mint == 0 && maxt == 0` is the end-of-content marker, because pre-allocation
    ///    leaves zeros and a real series reference starts at 1;
    ///  * a short tail that is **all zeros** ends the file cleanly, and one that is not is a corruption.
    public func iterateAllChunks(
        _ f: (HeadSeriesRef, ChunkDiskMapperRef, Int64, Int64, UInt16, Encoding, Bool) throws -> Void
    ) throws {
        defer { fileMaxtSet = true }

        for segID in mappedChunkFiles.keys.sorted() {
            var b = mappedChunkFiles[segID]!.bytes
            var fileEnd = b.count
            if segID == curFileSequence { fileEnd = Int(curFileSize) }

            var idx = headChunkFileHeaderSize
            while idx < fileEnd {
                if fileEnd - idx < maxHeadChunkMetaSize {
                    // All zeros means the content ended; anything else is a corruption.
                    var allZeros = true
                    for k in idx..<fileEnd where b[k] != 0 {
                        allZeros = false
                        break
                    }
                    if allZeros { break }
                    throw HeadChunkCorruptionError(
                        dir: directory, fileIndex: segID,
                        underlying: HeadChunksError.unreadDataButNotEnoughForHeader(
                            required: idx + maxHeadChunkMetaSize, available: fileEnd, file: segID))
                }
                let chunkRef = ChunkDiskMapperRef(seq: UInt64(segID), offset: UInt64(idx))
                let startIdx = idx

                let seriesRef = HeadSeriesRef(rawValue: readBE64(b, idx))
                idx += seriesRefSize
                let mint = Int64(bitPattern: readBE64(b, idx))
                idx += mintMaxtSize
                let maxt = Int64(bitPattern: readBE64(b, idx))
                idx += mintMaxtSize

                if seriesRef.rawValue == 0 && mint == 0 && maxt == 0 { break }

                var chkEnc = Encoding(rawValue: b[idx])
                idx += chunkEncodingSize
                let (dataLen, n) = GoVarint.uvarint(b, idx)
                idx += n

                // From the chunk's own body — see quirk 181.
                let numSamples = UInt16(b[idx]) << 8 | UInt16(b[idx + 1])
                idx += Int(dataLen)

                if idx + crc32Size > fileEnd {
                    throw HeadChunkCorruptionError(
                        dir: directory, fileIndex: segID,
                        underlying: HeadChunksError.notEnoughBytesForChunkHeader(
                            required: idx + crc32Size, available: fileEnd, file: segID))
                }
                let sum = Array(b[idx..<(idx + crc32Size)])
                do {
                    try checkCRC32(Array(b[startIdx..<idx]), sum)
                } catch {
                    throw HeadChunkCorruptionError(
                        dir: directory, fileIndex: segID, underlying: error)
                }
                idx += crc32Size

                if maxt > mappedChunkFiles[segID]!.maxt {
                    mappedChunkFiles[segID]!.maxt = maxt
                }
                let isOOO = isOutOfOrderChunk(chkEnc)
                chkEnc = removeMasks(chkEnc)
                do {
                    try f(seriesRef, chunkRef, mint, maxt, numSamples, chkEnc, isOOO)
                } catch let e as HeadChunkCorruptionError {
                    // Go REWRITES the callback's corruption error to name this file, rather than passing it
                    // through — so a Head that reports a corruption gets the mapper's file index, not
                    // whatever the callback guessed.
                    throw HeadChunkCorruptionError(
                        dir: directory, fileIndex: segID, underlying: e.underlying)
                }
                _ = b  // `b` is a value here; upstream re-reads the slice each iteration.
            }

            if idx > fileEnd {
                throw HeadChunkCorruptionError(
                    dir: directory, fileIndex: segID,
                    underlying: HeadChunksError.notEnoughBytesForLastChunkData(
                        required: idx, available: fileEnd, file: segID))
            }
        }
    }

    private func readBE64(_ b: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(b[at + k]) }
        return v
    }

    // MARK: Truncation and teardown

    /// Go: `Truncate` — delete every file numbered below `fileNo`.
    ///
    /// The loop `break`s at the current file OR at `fileNo`, whichever comes first, which is why a
    /// truncation cannot remove the file being written. And a new file is cut first **only if the current
    /// one has chunks in it**, so repeated truncation of an idle mapper does not litter the directory.
    public func truncate(fileNo: UInt32) throws {
        let indices = mappedChunkFiles.keys.sorted()
        var removed: [Int] = []
        for seq in indices {
            if seq == curFileSequence || UInt32(seq) >= fileNo { break }
            removed.append(seq)
        }

        if curFileSize > UInt64(headChunkFileHeaderSize) {
            cutNewFile()
        }

        var firstError: (any Error)?
        var pendingDeletes: [Int] = []
        do {
            try deleteFiles(removed)
        } catch let e as PendingDeletesError {
            firstError = e.underlying
            pendingDeletes = e.pending
        }

        if indices.count == removed.count {
            if firstError == nil {
                evtlPos.setSeq(0)
            } else if let last = pendingDeletes.last {
                evtlPos.setSeq(UInt64(last))
            }
        }
        if let e = firstError { throw e }
    }

    /// Carries `deleteFiles`' second return value — the files that were NOT removed from disk — which
    /// `Truncate` and `DeleteCorrupted` both read to decide what to reset the sequence to.
    struct PendingDeletesError: Error {
        var pending: [Int]
        var underlying: any Error
    }

    /// Go: `deleteFiles` — drop them from the maps first, then unlink, in index order.
    private func deleteFiles(_ removedFiles: [Int]) throws {
        let sorted = removedFiles.sorted()
        for seq in sorted {
            mappedChunkFiles.removeValue(forKey: seq)
        }
        for (i, seq) in sorted.enumerated() {
            do {
                try fs.remove(headSegmentFile(directory, seq))
            } catch {
                throw PendingDeletesError(pending: Array(sorted[i...]), underlying: error)
            }
        }
    }

    /// Go: `DeleteCorrupted` — remove the corrupt file and every file after it.
    public func deleteCorrupted(_ originalErr: any Error) throws {
        guard let cerr = originalErr as? HeadChunkCorruptionError else {
            throw HeadChunksError.cannotHandleError(String(describing: originalErr))
        }
        var segs: [Int] = []
        var lastSeq = 0
        for seg in mappedChunkFiles.keys {
            if seg >= cerr.fileIndex {
                segs.append(seg)
            } else if seg > lastSeq {
                lastSeq = seg
            }
        }
        var firstError: (any Error)?
        var pendingDeletes: [Int] = []
        do {
            try deleteFiles(segs)
        } catch let e as PendingDeletesError {
            firstError = e.underlying
            pendingDeletes = e.pending
        }
        if firstError == nil {
            evtlPos.setSeq(UInt64(lastSeq))
        } else if let last = pendingDeletes.last {
            evtlPos.setSeq(UInt64(last))
        }
        if let e = firstError { throw e }
    }

    /// Go: `Size` — `fileutil.DirSize`.
    public func size() throws -> Int64 {
        var total: Int64 = 0
        for name in try fs.list(directory) {
            guard let h = try? fs.openForReading("\(directory)/\(name)") else { continue }
            total += Int64(h.size)
            try h.close()
        }
        return total
    }

    /// Go: `curFileSize`.
    public var curFileSize: UInt64 { curFileOffset }

    /// Go: `Close`. Idempotent — unlike `WL.Close`, a second call returns nil.
    public func close() throws {
        if closed { return }
        closed = true
        try finalizeCurFile()
        mappedChunkFiles = [:]
    }
}
