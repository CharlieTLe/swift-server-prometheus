//===----------------------------------------------------------------------===//
// Ported from tsdb/wlog/wlog.go @ v3.13.2 — `page`, `Segment` and `WL`'s write side.
//
// Read `WALFormat.swift`'s header first: it has the five layout facts and the list of what is deliberately
// absent. This file is the mechanism.
//===----------------------------------------------------------------------===//

public import PromFS

/// Go: `wlog.page` — the 32 KB staging buffer a segment is written through.
///
/// `alloc` is how far the page has been filled and `flushed` how far it has reached the file, so the two
/// together are what make a partial flush resumable. `reset()` zeroes the **whole** buffer rather than just
/// truncating, and that is not hygiene: `flushPage` with `shouldClear` sets `alloc = pageSize` and writes
/// `buf[flushed:alloc]`, so the tail of the buffer is written out as the page's zero padding.
struct WALPage {
    var alloc = 0
    var flushed = 0
    var buf = [UInt8](repeating: 0, count: pageSize)

    var remaining: Int { pageSize - alloc }

    /// Go: `full()` — fewer than a header's worth of bytes left, because a header cannot be split.
    var isFull: Bool { pageSize - alloc < recordHeaderSize }

    mutating func reset() {
        for i in 0..<buf.count { buf[i] = 0 }
        alloc = 0
        flushed = 0
    }
}

/// Go: `wlog.Segment` — a segment file plus the directory and index it was named from.
///
/// Go embeds a `SegmentFile` interface satisfied by `*os.File`, so one type serves both directions. Here the
/// handle is one of ADR-15's two, and which one is set says which direction this segment is open for.
public final class WALSegment {
    public let dir: String
    public let index: Int
    let writeHandle: (any FSWriteHandle)?
    let readHandle: (any FSReadHandle)?
    /// The bytes, for a read segment. ADR-15 declines `mmap`, so a read handle is already fully resident and
    /// `SegmentBufReader` reads out of this rather than through the handle.
    var readBytes: [UInt8]
    /// Read position within ``readBytes``, which `SegmentBufReader` advances.
    var readOffset = 0

    init(dir: String, index: Int, write: any FSWriteHandle) {
        self.dir = dir
        self.index = index
        self.writeHandle = write
        self.readHandle = nil
        self.readBytes = []
    }

    init(dir: String, index: Int, read: any FSReadHandle, bytes: [UInt8]) {
        self.dir = dir
        self.index = index
        self.writeHandle = nil
        self.readHandle = read
        self.readBytes = bytes
    }

    /// Go: `Stat().Size()` — for a write segment, the bytes written so far.
    var size: Int { writeHandle?.position ?? readBytes.count }

    public func close() throws {
        try writeHandle?.close()
        try readHandle?.close()
    }
}

/// Go: `wlog.CreateSegment` — `O_WRONLY|O_CREATE|O_APPEND`.
///
/// `PromFS.createFile` is `O_TRUNC` rather than `O_APPEND`, which differs only for a segment index that
/// already exists on disk. `NewSize` and `nextSegment` are the only callers and both target an index past
/// the last one, so no caller can tell — except `Repair`, which is deferred for exactly the missing verb.
public func createWALSegment(_ fs: any PromFS, _ dir: String, _ k: Int) throws -> WALSegment {
    let h = try fs.createFile(segmentName(dir, k))
    return WALSegment(dir: dir, index: k, write: h)
}

/// Go: `wlog.OpenReadSegment`.
///
/// The index comes from `strconv.Atoi(filepath.Base(fn))`, so a file whose name is not a bare integer is
/// `not a valid filename` — and note that means `00000007` parses to **7**, the leading zeros being
/// `Atoi`'s business rather than the caller's.
public func openReadWALSegment(_ fs: any PromFS, _ fn: String) throws -> WALSegment {
    let base = fn.split(separator: "/").last.map(String.init) ?? fn
    guard let k = Int(base), String(base.drop(while: { $0 == "0" || $0 == "+" || $0 == "-" })).allSatisfy(\.isNumber)
    else {
        throw WALError.notAValidFilename
    }
    let dir = fn.contains("/") ? String(fn[fn.startIndex..<fn.lastIndex(of: "/")!]) : "."
    let h = try fs.openForReading(fn)
    let bytes = try h.read(offset: 0, length: h.size)
    return WALSegment(dir: dir, index: k, read: h, bytes: bytes)
}

// MARK: - WL

/// Go: `wlog.WL` — a write log over a directory of segment files.
///
/// Upstream's doc comment is a contract worth keeping in view: *"It must be read from start to end once
/// before logging new data. If an error occurs during read, the repair procedure must be called before it's
/// safe to do further writes."* The port cannot repair yet, so the second half is a note rather than an
/// invariant it can enforce.
///
/// Not a `Sendable` type and not internally locked: Go guards `Log`/`nextSegment`/`Close` with a mutex
/// because the Head appends from many goroutines. The port's Head does not exist yet and its concurrency
/// story is that slice's to decide, so the mutex is deliberately absent rather than guessed at — a lock
/// here would be a claim about a design that has not been made.
public final class WL {

    private let fs: any PromFS
    private let directory: String
    private let segmentSize: Int
    private let compress: WALCompression

    private var page = WALPage()
    private var segment: WALSegment?
    /// Go: `donePages`. Set from the segment file's SIZE in `setSegment`, not tracked independently.
    private var donePages = 0
    private var closed = false

    public var dir: String { directory }
    public var compressionType: WALCompression { compress }

    /// Go: `New` — `NewSize` with `DefaultSegmentSize`.
    public convenience init(
        fs: any PromFS, dir: String, compress: WALCompression = .none
    ) throws {
        try self.init(fs: fs, dir: dir, segmentSize: defaultSegmentSize, compress: compress)
    }

    /// Go: `NewSize`.
    ///
    /// The segment index is `last + 1` over whatever is already in the directory — **never the last segment
    /// itself**, which is why the port needs no append-open verb here. An empty directory gives 0, because
    /// `Segments` returns `(-1, -1)` for one.
    public init(
        fs: any PromFS, dir: String, segmentSize: Int, compress: WALCompression = .none
    ) throws {
        guard segmentSize % pageSize == 0 else { throw WALError.invalidSegmentSize }
        self.fs = fs
        self.directory = dir
        self.segmentSize = segmentSize
        self.compress = compress

        try fs.createDirectory(dir)

        let (_, last) = try walSegments(fs, dir)
        let writeSegmentIndex = last == -1 ? 0 : last + 1
        let seg = try createWALSegment(fs, dir, writeSegmentIndex)
        try setSegment(seg)
    }

    private func setSegment(_ seg: WALSegment) throws {
        segment = seg
        donePages = seg.size / pageSize
    }

    /// Go: `pagesPerSegment`.
    private var pagesPerSegment: Int { segmentSize / pageSize }

    /// Go: `flushPage`.
    ///
    /// `shouldClear` sets `alloc = pageSize` **before** the write, so the padding goes to the file as real
    /// zero bytes. A port that wrote only `buf[flushed:alloc]` and then reset would leave a short page in
    /// the file, and `setSegment`'s `size / pageSize` would then miscount `donePages` on reopen.
    private func flushPage(forceClear: Bool) throws {
        let shouldClear = forceClear || page.isFull
        if shouldClear {
            page.alloc = pageSize
        }
        guard let seg = segment, let h = seg.writeHandle else { return }
        // Go tolerates a short write by advancing `flushed` and returning the error. `FSWriteHandle.append`
        // is all-or-throws, so there is no partial case to carry — but `flushed` is still advanced by the
        // full amount, because the resumption logic reads it.
        let slice = Array(page.buf[page.flushed..<page.alloc])
        try h.append(slice)
        page.flushed += slice.count

        if shouldClear {
            page.reset()
            donePages += 1
        }
    }

    /// Go: `Log(recs ...[]byte)`.
    ///
    /// The batch is what decides flushing: `final` is true only for the last record, and only a final record
    /// flushes a partially-filled page. `Log(a, b)` and `Log(a)` then `Log(b)` are therefore different
    /// writes of the same records — see `WALFormat.swift`'s point 4.
    public func log(_ recs: [UInt8]...) throws {
        try log(records: recs)
    }

    public func log(records recs: [[UInt8]]) throws {
        for (i, r) in recs.enumerated() {
            try logOne(r, final: i == recs.count - 1)
        }
    }

    /// Go: `WL.log`.
    private func logOne(_ rec: [UInt8], final: Bool) throws {
        // A failed flush leaves the page full, so this is a retry point rather than an edge case.
        if page.isFull {
            try flushPage(forceClear: true)
        }

        // Compression happens BEFORE the fits-in-this-segment arithmetic, because the encoded length is
        // what has to fit.
        var finalCompression = compress
        var enc = rec
        if compress != .none {
            // `compression.Encode` returns `src` unchanged for an empty record whatever the type, so the
            // `savedBytes <= 0` fallback below would fire anyway; the port rejects the type outright
            // because it cannot encode a non-empty one. See `WALFormat.swift` on what is absent.
            if !rec.isEmpty {
                throw WALError.unsupportedCompressionType(compress.rawValue)
            }
            // Go: an encoding that saved nothing is discarded and the record is written uncompressed, with
            // the flag cleared. An empty record always lands here.
            finalCompression = .none
            enc = rec
        }

        // Free space in the active page, then in every page the segment has left. Each future page is
        // discounted by one header because each will need one. This can go negative.
        var left = page.remaining - recordHeaderSize
        left += (pageSize - recordHeaderSize) * (pagesPerSegment - donePages - 1)

        if enc.count > left {
            _ = try nextSegment(async: true)
        }

        // `i == 0 || !enc.isEmpty` — the first pass is unconditional, which is what lets a ZERO-LENGTH
        // record exist at all.
        var i = 0
        var offset = 0
        while i == 0 || offset < enc.count {
            let l = min(enc.count - offset, (pageSize - page.alloc) - recordHeaderSize)
            let part = enc[offset..<(offset + l)]

            var typ: UInt8
            if i == 0 && l == enc.count - offset {
                typ = WALRecordType.full.rawValue
            } else if l == enc.count - offset {
                typ = WALRecordType.last.rawValue
            } else if i == 0 {
                typ = WALRecordType.first.rawValue
            } else {
                typ = WALRecordType.middle.rawValue
            }

            if finalCompression != .none {
                switch finalCompression {
                case .snappy: typ |= snappyMask
                case .zstd: typ |= zstdMask
                case .none: break
                }
            }

            let base = page.alloc
            page.buf[base] = typ
            let crc = walCRC(part)
            let len = UInt16(part.count)
            page.buf[base + 1] = UInt8(truncatingIfNeeded: len >> 8)
            page.buf[base + 2] = UInt8(truncatingIfNeeded: len)
            page.buf[base + 3] = UInt8(truncatingIfNeeded: crc >> 24)
            page.buf[base + 4] = UInt8(truncatingIfNeeded: crc >> 16)
            page.buf[base + 5] = UInt8(truncatingIfNeeded: crc >> 8)
            page.buf[base + 6] = UInt8(truncatingIfNeeded: crc)
            for (k, b) in part.enumerated() {
                page.buf[base + recordHeaderSize + k] = b
            }
            page.alloc += part.count + recordHeaderSize

            if page.isFull {
                try flushPage(forceClear: true)
            }
            offset += l
            i += 1
        }

        if final && page.alloc > 0 {
            try flushPage(forceClear: false)
        }
    }

    /// Go: `NextSegment` / `NextSegmentSync`.
    ///
    /// Identical here: `async` only decided whether the previous segment's fsync-and-close went through the
    /// actor goroutine, and `PromFS.sync` is a no-op by ADR-15. Both names are kept so call sites read the
    /// same as upstream's.
    @discardableResult
    public func nextSegment() throws -> Int { try nextSegment(async: true) }

    @discardableResult
    public func nextSegmentSync() throws -> Int { try nextSegment(async: false) }

    @discardableResult
    private func nextSegment(async: Bool) throws -> Int {
        if closed { throw WALError.wlogClosed }

        // Only a page holding data is flushed — an empty page would otherwise write a whole page of zeros
        // into the segment being abandoned.
        if page.alloc > 0 {
            try flushPage(forceClear: true)
        }
        guard let current = segment else { throw WALError.wlogClosed }
        let next = try createWALSegment(fs, directory, current.index + 1)
        let prev = current
        try setSegment(next)

        try prev.writeHandle?.sync()
        try prev.close()
        return next.index
    }

    /// Go: `LastSegmentAndOffset`.
    ///
    /// The offset is `donePages * pageSize + page.alloc` — the completed pages **plus** how far the
    /// in-memory page has been filled. So it names where the next record will go, which can be past what
    /// has reached the file, and it is 0 for a page that was just cleared rather than the page size.
    public func lastSegmentAndOffset() throws -> (segment: Int, offset: Int) {
        let (_, last) = try walSegments(fs, directory)
        return (last, donePages * pageSize + page.alloc)
    }

    /// Go: `Truncate(i)` — remove every segment with an index **below** `i`.
    ///
    /// The loop `break`s on the first index at or above `i` rather than filtering, which is only correct
    /// because `listSegments` sorts and rejects a non-sequential set.
    public func truncate(_ i: Int) throws {
        let refs = try listWALSegments(fs, directory)
        for r in refs {
            if r.index >= i { break }
            try fs.remove("\(directory)/\(r.name)")
        }
    }

    /// Go: `Sync` — "meant to be used only on tests due to different behaviour on Operating Systems".
    public func sync() throws {
        try segment?.writeHandle?.sync()
    }

    /// Go: `Close` — flush the last page and close the segment. Idempotence is NOT offered: a second call
    /// is `wlog already closed`.
    ///
    /// **The flush is conditional on `page.alloc > 0`**, and upstream's comment says why: *"We must not
    /// flush an empty page as it would falsely signal the segment is done if we start writing to it again
    /// after opening."* `setSegment` derives `donePages` from the file's size, so an unconditional flush
    /// would write 32 KB of zeros into a segment nothing was logged to and make it look like a completed
    /// page. The first version of this port flushed unconditionally and the empty-WAL case caught it.
    ///
    /// The fsync and close errors are **logged rather than returned** upstream, and only the fsync's reaches
    /// the named return value — `if err = w.fsync(...)` assigns it, while `w.segment.Close()`'s goes to a
    /// shadowed `err`. Both are no-ops or infallible under ADR-15's `PromFS`, so the shape is kept without
    /// anything depending on it.
    public func close() throws {
        if closed { throw WALError.wlogAlreadyClosed }
        guard let seg = segment else {
            closed = true
            return
        }
        if page.alloc > 0 {
            try flushPage(forceClear: true)
        }
        let syncError: (any Error)?
        do {
            try seg.writeHandle?.sync()
            syncError = nil
        } catch {
            syncError = error
        }
        try? seg.close()
        closed = true
        if let e = syncError { throw e }
    }

    /// Go: `Size` — `fileutil.DirSize`, the sum of every file under the directory.
    public func size() throws -> Int64 {
        var total: Int64 = 0
        for name in try fs.list(directory) {
            let path = "\(directory)/\(name)"
            guard let h = try? fs.openForReading(path) else { continue }
            total += Int64(h.size)
            try h.close()
        }
        return total
    }
}

// MARK: - The directory

/// Go: `wlog.segmentRef`.
public struct WALSegmentRef: Sendable, Equatable {
    public var name: String
    public var index: Int
}

/// Go: `wlog.listSegments`.
///
/// A file whose name is not an integer is **skipped**, not an error — that is how a `checkpoint.NNNNNN`
/// directory can live alongside the segments. A *gap* in the indices IS an error, and the sequentiality
/// check is what licenses `Truncate`'s `break`.
public func listWALSegments(_ fs: any PromFS, _ dir: String) throws -> [WALSegmentRef] {
    var refs: [WALSegmentRef] = []
    for fn in try fs.list(dir) {
        // `strconv.Atoi` accepts a leading sign and rejects anything else non-numeric; a bare `Int(fn)`
        // matches closely enough for names a WAL produces, and the check below rejects the rest.
        guard let k = Int(fn), fn.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "+" || $0 == "-") })
        else { continue }
        refs.append(WALSegmentRef(name: fn, index: k))
    }
    refs.sort { $0.index < $1.index }
    for i in 0..<max(0, refs.count - 1) {
        if refs[i].index + 1 != refs[i + 1].index {
            throw WALError.segmentsNotSequential
        }
    }
    return refs
}

/// Go: `wlog.Segments` — `(-1, -1)` for an empty directory, which is what `NewSize` tests for.
public func walSegments(_ fs: any PromFS, _ dir: String) throws -> (first: Int, last: Int) {
    let refs = try listWALSegments(fs, dir)
    if refs.isEmpty { return (-1, -1) }
    return (refs[0].index, refs[refs.count - 1].index)
}
