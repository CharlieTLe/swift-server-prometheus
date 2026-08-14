//===----------------------------------------------------------------------===//
// `tsdb/wlog`'s segment format, pinned against Go in both directions.
//
// The corpus is a *program*: a segment size, a list of write operations, and a read range. The committed
// output is the resulting directory's bytes plus what `wlog.Reader` reads back out of them, so the writer
// and the reader are checked against each other as well as against Go.
//
// The bytes travel RLE-encoded (`z<n>.` for a run of zeros) because a page is 32 KB and most of one is
// padding. It is reversible, not a digest — a padding run of the wrong length is still a diff. See
// `oracle/suites_wal.go`.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromFS
import PromWAL
import Testing

// MARK: - The RLE codec, which must agree with the oracle's

/// The oracle's `rleHex`. The trailing `.` on a run is load-bearing: hex pairs are themselves digits, so
/// `z16372` followed by the byte `0x11` would read back as a run of 1,637,211 without it.
func rleHex(_ b: [UInt8]) -> String {
    var out = ""
    var i = 0
    while i < b.count {
        if b[i] == 0 {
            var j = i
            while j < b.count && b[j] == 0 { j += 1 }
            out += "z"
            out += String(j - i)
            out += "."
            i = j
            continue
        }
        let hex = String(b[i], radix: 16)
        out += hex.count == 1 ? "0" + hex : hex
        i += 1
    }
    return out
}

/// The oracle's `unrleHex`.
func unrleHex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        if chars[i] == "z" {
            var j = i + 1
            while j < chars.count && chars[j] != "." { j += 1 }
            let n = Int(String(chars[(i + 1)..<j]))!
            out.append(contentsOf: [UInt8](repeating: 0, count: n))
            i = j + 1
            continue
        }
        out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
        i += 2
    }
    return out
}

// MARK: - Wire types

struct WALOp: Codable, Sendable {
    var op: String
    var records: [String]?
    var index: Int?
}

/// A file planted before `WL` is constructed. Three controls need it and nothing else: every other case
/// starts from an empty directory, so `NewSize` never resumes an existing WAL and `listSegments` never sees a
/// set that is unsorted or gappy.
struct WALSeedFile: Codable, Sendable {
    var name: String
    var bytes: String
}

struct WALIn: Codable, Sendable {
    var segmentPages: Int
    var ops: [WALOp]?
    var readFirst: Int
    var readLast: Int
    var preSeed: [WALSeedFile]?
}

struct WALSegmentOut: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var bytes: String
}

struct WALOut: Codable, Equatable, Sendable {
    var segments: [WALSegmentOut]
    var segFirst: Int
    var segLast: Int
    var size: Int64
    var lastSegment: Int
    var lastOffset: Int
    var opErr: String
    var read: [String]
    var readErr: String
    var readSegment: Int
    var readOffset: Int64
    var readerHasNoSegments: Bool
}

// MARK: - The read-back half

/// The oracle's `walReadBack`, and the ORDER matters: Go assigns `SegFirst`/`SegLast` even when `Segments`
/// errors (they are 0/0 then), and it returns **early** when the range reader cannot be built, leaving
/// `readerHasNoSegments` false and both accessors at 0. Shared by the write-program cases and the raw-bytes
/// ones, exactly as it is upstream.
func walReadBack(
    _ fs: InMemoryFS, _ dir: String, readFirst: Int, readLast: Int, _ out: inout WALOut
) {
    for name in ((try? fs.list(dir)) ?? []).sorted() {
        guard let h = try? fs.openForReading("\(dir)/\(name)"),
            let bytes = try? h.read(offset: 0, length: h.size)
        else { continue }
        try? h.close()
        out.segments.append(WALSegmentOut(name: name, size: bytes.count, bytes: rleHex(bytes)))
    }

    do {
        let (first, last) = try walSegments(fs, dir)
        out.segFirst = first
        out.segLast = last
    } catch {
        out.opErr = String(describing: error)
        out.segFirst = 0
        out.segLast = 0
    }

    let sr: SegmentBufReader
    do {
        sr = try newWALSegmentsRangeReader(
            fs, [WALSegmentRange(dir: dir, first: readFirst, last: readLast)])
    } catch {
        out.readErr = String(describing: error).replacingOccurrences(of: dir, with: "<dir>")
        return
    }

    let r = WALReader(sr)
    while r.next() {
        out.read.append(rleHex(r.record))
    }
    if let e = r.err {
        // The oracle scrubs its temp directory out of the message; the port's directory is literally
        // `wal`, so the two agree only if this one is scrubbed the same way.
        out.readErr = String(describing: e).replacingOccurrences(of: dir, with: "<dir>")
    }
    let refs = (try? listWALSegments(fs, dir)) ?? []
    out.readerHasNoSegments = !refs.contains { rf in
        if readFirst >= 0 && rf.index < readFirst { return false }
        if readLast >= 0 && rf.index > readLast { return false }
        return true
    }
    if !out.readerHasNoSegments {
        out.readSegment = r.segment
        out.readOffset = r.offset
    }
    try? sr.close()
}

@Suite("wal: the segment format, and the reader over the writer's own bytes")
struct WALSegmentTests {

    @Test("every committed case matches Go, page for page")
    func matchesGo() throws {
        try Fixtures.check("wal/segments.jsonl", FixtureCase<WALIn, WALOut>.self) { input in
            let fs = InMemoryFS()
            let dir = "wal"
            var out = WALOut(
                segments: [], segFirst: 0, segLast: 0, size: 0, lastSegment: 0, lastOffset: 0,
                opErr: "", read: [], readErr: "", readSegment: 0, readOffset: 0,
                readerHasNoSegments: false)

            // Planted before construction, because `NewSize` reads the directory to pick its index.
            if let seed = input.preSeed, !seed.isEmpty {
                try fs.createDirectory(dir)
                for sf in seed {
                    let sh = try fs.createFile("\(dir)/\(sf.name)")
                    try sh.append(unrleHex(sf.bytes))
                    try sh.close()
                }
            }

            // Construction can legitimately FAIL: a gap in the planted indices makes `walSegments` throw out
            // of `init`. Go returns that error from `NewSize` rather than panicking, so it is a case.
            let w: WL
            do {
                w = try WL(
                    fs: fs, dir: dir, segmentSize: input.segmentPages * pageSize, compress: .none)
            } catch {
                out.opErr = String(describing: error)
                walReadBack(fs, dir, readFirst: input.readFirst, readLast: input.readLast, &out)
                return out
            }

            for op in input.ops ?? [] {
                do {
                    switch op.op {
                    case "log":
                        try w.log(records: (op.records ?? []).map(unrleHex))
                    case "nextSegment":
                        _ = try w.nextSegment()
                    case "nextSegmentSync":
                        _ = try w.nextSegmentSync()
                    case "truncate":
                        try w.truncate(op.index ?? 0)
                    case "sync":
                        try w.sync()
                    default:
                        Issue.record("unknown wal op \(op.op)")
                    }
                } catch {
                    out.opErr = String(describing: error)
                    break
                }
            }

            // Before close: the offset is the in-memory page's `alloc`, which closing consumes.
            if out.opErr.isEmpty {
                let (seg, off) = try w.lastSegmentAndOffset()
                out.lastSegment = seg
                out.lastOffset = off
            }
            out.size = try w.size()
            do { try w.close() } catch {
                if out.opErr.isEmpty { out.opErr = String(describing: error) }
            }

            walReadBack(fs, dir, readFirst: input.readFirst, readLast: input.readLast, &out)
            return out
        }
    }

    /// `Reader.Segment()` **panics** upstream when the reader has no segments —
    /// `b.segs[b.cur].Index()` with `segs` nil, which `NewSegmentBufReader` produces on purpose so that
    /// `Read` can answer `io.EOF`. The corpus found it by reaching it (a range whose `First` is past the
    /// last segment, and a `Truncate` that removed everything), and it cannot be pinned differentially
    /// because querying it takes the fixture generator down.
    ///
    /// So the port's answers for that state are asserted here instead. `-1` for the segment is the value
    /// upstream's own `else` branch gives when the source is not a `segmentBufReader` at all, which makes it
    /// the only defensible choice: it means "this reader cannot say".
    @Test("a reader with no segments answers rather than trapping")
    func emptyReaderDoesNotTrap() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("empty")
        let sr = try newWALSegmentsReader(fs, "empty")
        let r = WALReader(sr)
        #expect(r.next() == false)
        #expect(r.err == nil)
        #expect(r.segment == -1)
        #expect(r.offset == 0)
        try sr.close()
    }

    /// The two `WALError` cases the corpus cannot reach, because both are rejections of a caller rather
    /// than of data.
    @Test("the caller-error vocabulary")
    func callerErrors() throws {
        let fs = InMemoryFS()
        // Go: `errors.New("invalid segment size")` for anything not a multiple of the page size.
        #expect(throws: WALError.invalidSegmentSize) {
            _ = try WL(fs: fs, dir: "a", segmentSize: pageSize + 1)
        }
        #expect(throws: WALError.invalidSegmentSize) {
            _ = try WL(fs: fs, dir: "a", segmentSize: 1)
        }
        // Zero IS a multiple, and upstream accepts it — `pagesPerSegment()` is then 0, so `left` is
        // negative for every record and each one rotates. Accepted rather than "fixed".
        let w = try WL(fs: fs, dir: "b", segmentSize: 0)
        try w.close()
        #expect(throws: WALError.wlogAlreadyClosed) { try w.close() }

        let w2 = try WL(fs: fs, dir: "c", segmentSize: pageSize)
        try w2.close()
        #expect(throws: WALError.wlogClosed) { _ = try w2.nextSegment() }
    }

    /// `WALCompression` is a Go **type alias for `string`**, so `""` and `"none"` are both "no compression"
    /// and anything else is unsupported. Asserted here because the corpus runs `None` only — the snappy and
    /// zstd block formats are their own slice.
    @Test("the compression type's two spellings of none")
    func compressionSpellings() throws {
        // Spelled `WALCompression.none` rather than `.none`: the initialiser is failable, so `== .none`
        // resolves to `Optional.none` and asserts the OPPOSITE of what it reads as. It failed first try.
        #expect(WALCompression(configValue: "") == WALCompression.none)
        #expect(WALCompression(configValue: "none") == WALCompression.none)
        #expect(WALCompression(configValue: "snappy") == WALCompression.snappy)
        #expect(WALCompression(configValue: "zstd") == WALCompression.zstd)
        #expect(WALCompression(configValue: "gzip") == nil)

        // A non-empty record under an unsupported type is rejected rather than written uncompressed, which
        // would produce a WAL Prometheus reads correctly and this port then could not.
        let fs = InMemoryFS()
        let w = try WL(fs: fs, dir: "d", segmentSize: pageSize, compress: .snappy)
        #expect(throws: WALError.unsupportedCompressionType("snappy")) { try w.log([1, 2, 3]) }
        // An EMPTY record is fine, because `compression.Encode` returns `src` untouched for one and the
        // flag is then cleared by the `savedBytes <= 0` fallback.
        try w.log([])
        try w.close()
    }

    /// The record-type table, including the three values `recTypeFromHeader` can produce that are not
    /// record types at all — it masks to three bits, so 5, 6 and 7 arrive and must render as `<invalid>`.
    @Test("the record-type names, and the flag masks")
    func recordTypeTable() {
        #expect(WALRecordType.pageTerm.description == "zero")
        #expect(WALRecordType.full.description == "full")
        #expect(WALRecordType.first.description == "first")
        #expect(WALRecordType.middle.description == "middle")
        #expect(WALRecordType.last.description == "last")
        for raw in UInt8(5)...UInt8(7) {
            #expect(WALRecordType(rawValue: raw).description == "<invalid>")
        }
        // The flag bits live above the type, and a header carrying both reads as snappy because the reader
        // tests snappy first.
        #expect(walRecordType(fromHeader: 0b0000_1001) == .full)
        #expect(walRecordType(fromHeader: 0b0001_0010) == .first)
        #expect(walRecordType(fromHeader: 0b0001_1100) == .last)
    }

    /// `SegmentName` is `%08d`, and the padding is what makes a lexicographic listing agree with numeric
    /// order for every index a real WAL reaches.
    @Test("segment names are zero-padded to eight digits")
    func segmentNames() {
        #expect(segmentName("wal", 0) == "wal/00000000")
        #expect(segmentName("wal", 7) == "wal/00000007")
        #expect(segmentName("wal", 12_345_678) == "wal/12345678")
        // Past eight digits the padding stops rather than truncating.
        #expect(segmentName("wal", 123_456_789) == "wal/123456789")
    }
}
