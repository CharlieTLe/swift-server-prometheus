//===----------------------------------------------------------------------===//
// Ported from tsdb/wlog/wlog.go and tsdb/wlog/reader.go @ v3.13.2 — the segment FORMAT.
//
// §7a ported the records; this is the envelope they travel in. A WAL directory is a sequence of segment
// files named `%08d`, each a sequence of 32 KB **pages**, each page a sequence of
// `[1 byte type|flags][BE16 length][BE32 CRC-32C][payload]` fragments. One logical record may span pages
// but **never segments**, which is the property that makes truncating a whole segment safe.
//
// ## Five things the layout does that a reading of the struct would not predict
//
//  1. **A record that would not fit in the rest of the current SEGMENT starts a new segment**, and the
//     space calculation counts the free bytes of every remaining page, not the file's remaining bytes:
//
//         left  = page.remaining() - recordHeaderSize
//         left += (pageSize - recordHeaderSize) * (pagesPerSegment() - donePages - 1)
//
//     so each future page is discounted by one header. `left` can go **negative** — `page.remaining()` is
//     as low as 0 — and the comparison still behaves, because `len(enc) > left` is then trivially true.
//  2. **A page is "full" when fewer than 7 bytes remain, not when 0 do**, because a header cannot be split.
//     The leftover 1-6 bytes are zero-padded, and the reader has to accept a page terminator that is
//     followed by fewer than `pageSize-1` zeros.
//  3. **The loop runs at least once**, `for i := 0; i == 0 || len(enc) > 0; i++`. That is what makes a
//     **zero-length record** representable: it becomes a `recFull` fragment with length 0 and the CRC of
//     the empty string. Written as a plain `while !enc.isEmpty` it would produce nothing at all, and the
//     record would silently vanish.
//  4. **Flushing is per-BATCH, not per-record.** `Log(recs...)` passes `final: i == len(recs)-1`, and only
//     the final record flushes a partially-filled page. So `Log(a, b)` and `Log(a); Log(b)` produce
//     different *files* — the first leaves one flush, the second two — even though both produce the same
//     record stream. The visible difference is when bytes reach the file, which the corpus pins by reading
//     the segment after `Close`.
//  5. **`flushPage` writes `buf[flushed:alloc]`, and `shouldClear` sets `alloc = pageSize` first.** So
//     clearing a page writes the zero padding out as real bytes; the file is always a whole number of
//     pages once a page has been cleared, and `donePages` is derived from the file's size rather than
//     tracked independently.
//
// ## The type byte carries the compression flag, and the mask arithmetic is load-bearing
//
//     [3 bits unused][1 bit zstd][1 bit snappy][3 bits record type]
//
// `recTypeMask` is spelled `snappyMask - 1`, i.e. 7 — the record type occupies exactly the bits below the
// first flag. A reader takes the type with `header & recTypeMask` and the compression by testing snappy
// **first**, so a byte with both flags set reads as snappy.
//
// ## What is deliberately not here
//
//   * **Compression.** `WALCompression.none` is implemented; snappy and zstd are recognised on read (the
//     flag bits, and a record that carries one) and rejected. `db.go:85` defaults `WALCompression` to
//     `None`, so nothing in the port needs them yet, and the snappy block format deserves its own slice
//     and its own corpus rather than being smuggled in here.
//   * **`OpenWriteSegment` and `Repair`.** Both need to open an existing segment for *appending*, which
//     ADR-15's `PromFS` has no verb for — it has `createFile` (which truncates) and `openForReading`.
//     Adding `openForAppending` is the first thing the repair slice does. Note `NewSize` does **not** need
//     it: it always creates a segment at `last + 1` rather than resuming the last one.
//   * **The actor goroutine.** `nextSegment(async: true)` queues an fsync-and-close onto `actorc` so a
//     write is not blocked by the previous segment's fsync. `PromFS.sync` is a no-op by ADR-15, so the
//     only remaining effect is the `close`, which is done inline. `NextSegment` and `NextSegmentSync`
//     therefore behave identically here, and both keep their names so the call sites read the same.
//   * **Metrics.** PORTING.md's standing exception; `wlMetrics` has no behaviour.
//   * **`LiveReader`, `Watcher` and `Checkpoint`.** The first two belong to remote write (Phase 10) and
//     the third needs the Head. `validateRecord` lives in `live_reader.go` upstream and is ported here,
//     because `Reader` calls it and it is the whole of the fragment-sequence grammar.
//===----------------------------------------------------------------------===//

internal import PromHash

/// Go: `wlog.DefaultSegmentSize` — 128 MB.
public let defaultSegmentSize = 128 * 1024 * 1024
/// Go: `wlog.pageSize` — 32 KB.
public let pageSize = 32 * 1024
/// Go: `wlog.recordHeaderSize` — one type byte, a BE16 length, a BE32 CRC.
public let recordHeaderSize = 7
/// Go: `wlog.WblDirName`.
public let wblDirName = "wbl"

/// Go: `wlog.snappyMask` / `zstdMask` / `recTypeMask`.
///
/// `recTypeMask` is `snappyMask - 1` upstream, which is the statement that the type occupies exactly the
/// bits below the first flag. Kept as that expression rather than as `7`.
let snappyMask: UInt8 = 1 << 3
let zstdMask: UInt8 = 1 << 4
let recTypeMask: UInt8 = snappyMask - 1

/// Go: `wlog.recType`.
///
/// A `RawRepresentable` struct rather than an enum for the same reason `RecordType` is: `recTypeFromHeader`
/// masks an arbitrary byte down to three bits, so values 5, 6 and 7 are reachable and must render as
/// `<invalid>` rather than trap.
public struct WALRecordType: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Go: `recPageTerm` — the rest of the page is zero padding.
    public static let pageTerm = WALRecordType(rawValue: 0)
    public static let full = WALRecordType(rawValue: 1)
    public static let first = WALRecordType(rawValue: 2)
    public static let middle = WALRecordType(rawValue: 3)
    public static let last = WALRecordType(rawValue: 4)

    /// Go: `recType.String()`. Note `recPageTerm` renders as **"zero"**, not "pageterm".
    public var description: String {
        switch self {
        case .pageTerm: return "zero"
        case .full: return "full"
        case .first: return "first"
        case .middle: return "middle"
        case .last: return "last"
        default: return "<invalid>"
        }
    }
}

/// Go: `wlog.recTypeFromHeader`.
public func walRecordType(fromHeader header: UInt8) -> WALRecordType {
    WALRecordType(rawValue: header & recTypeMask)
}

/// Go: `compression.Type`, as much of it as the WAL needs.
///
/// `compression.Type` is a **type alias for `string`**, not a distinct type, so any string is a valid value
/// and `Encode`/`Decode` treat `""` *and* `"none"` as no compression — `if len(src) == 0 || t == "" || t ==
/// None`. The doc comment on `None` says so: "None is the default when Type is empty". Modelled as an enum
/// with `"none"` as the raw value and ``init(configValue:)`` for the empty-string alias, because an alias
/// with two spellings is exactly the kind of thing a port silently normalises to one.
public enum WALCompression: String, Sendable, Hashable, CaseIterable {
    case none = "none"
    case snappy = "snappy"
    case zstd = "zstd"

    /// Go: what a `compression.Type` from a config file means. `""` is `None`; anything unrecognised is
    /// nil, which is `Encode`'s `unsupported compression type` path rather than a silent fallback.
    public init?(configValue: String) {
        if configValue.isEmpty {
            self = .none
            return
        }
        guard let t = WALCompression(rawValue: configValue) else { return nil }
        self = t
    }
}

/// Go: `wlog.CorruptionErr`.
///
/// The two spellings of the message are a real distinction: a negative segment means the reader could not
/// say *which* file the corruption is in, so the offset is a total over the stream rather than a position
/// in a file. `Reader.Err()` picks between them by asking whether its source is a `SegmentBufReader`.
public struct WALCorruptionError: Error, CustomStringConvertible {
    public var dir: String
    public var segment: Int
    public var offset: Int64
    public var underlying: any Error

    public init(dir: String = "", segment: Int, offset: Int64, underlying: any Error) {
        self.dir = dir
        self.segment = segment
        self.offset = offset
        self.underlying = underlying
    }

    public var description: String {
        if segment < 0 {
            return "corruption after \(offset) bytes: \(underlying)"
        }
        return "corruption in segment \(segmentName(dir, segment)) at \(offset): \(underlying)"
    }
}

/// Go: `wlog.SegmentName` — `filepath.Join(dir, fmt.Sprintf("%08d", i))`.
///
/// Zero-padded to **eight** digits, which is what makes a plain lexicographic directory listing agree with
/// numeric order for every index a real WAL reaches. `listSegments` sorts numerically anyway; the padding is
/// what makes the two agree.
public func segmentName(_ dir: String, _ i: Int) -> String {
    let s = String(i)
    let padded = i >= 0 && s.count < 8 ? String(repeating: "0", count: 8 - s.count) + s : s
    return dir.isEmpty ? padded : "\(dir)/\(padded)"
}

/// Go: the errors `wlog` produces itself, plus the two `io` sentinels the reader's control flow depends on.
public enum WALError: Error, CustomStringConvertible, Equatable {
    /// Go: `io.EOF`. A CLEAN end of stream, and the only error `Reader.Next` swallows.
    case eof
    /// Go: `io.ErrUnexpectedEOF` — a partial read. **Not** `io.EOF`, so `Reader.Next` reports it. That
    /// distinction is what turns a half-written header at the end of a segment into a corruption rather
    /// than a clean stop.
    case unexpectedEOF

    case invalidSegmentSize
    case wlogClosed
    case wlogAlreadyClosed
    case notAValidFilename
    case segmentsNotSequential

    /// Go: `errors.New("last record is torn")`.
    case lastRecordIsTorn
    case unexpectedNonZeroByteInPaddedPage
    case invalidRecordSize(UInt16)
    case invalidSize(expected: Int, got: Int)
    case unexpectedChecksum(got: UInt32, expected: UInt32)

    /// Go: `validateRecord`'s four messages.
    case unexpectedFullRecord
    case unexpectedFirstRecord
    case unexpectedMiddleRecord
    case unexpectedLastRecord
    /// Go: `fmt.Errorf("unexpected record type %d", typ)` — `typ` is a `recType`, which has no `String`
    /// method in that formatting position because `%d` forces the numeric verb. So this is a NUMBER even
    /// though `recType.String()` exists, and it is reachable: `recTypeFromHeader` masks to three bits, so
    /// 5, 6 and 7 all arrive here.
    case unexpectedRecordType(UInt8)

    case unsupportedCompressionType(String)
    /// Go: `fmt.Errorf("%s: %w", context, err)` — the reader's five wrapping sites, which name the read
    /// that failed. The text is `"read first header byte: EOF"` and so on.
    indirect case wrapped(String, any Error)

    public var description: String {
        switch self {
        case .eof: return "EOF"
        case .unexpectedEOF: return "unexpected EOF"
        case .invalidSegmentSize: return "invalid segment size"
        case .wlogClosed: return "wlog is closed"
        case .wlogAlreadyClosed: return "wlog already closed"
        case .notAValidFilename: return "not a valid filename"
        case .segmentsNotSequential: return "segments are not sequential"
        case .lastRecordIsTorn: return "last record is torn"
        case .unexpectedNonZeroByteInPaddedPage: return "unexpected non-zero byte in padded page"
        case .invalidRecordSize(let n): return "invalid record size \(n)"
        case .invalidSize(let e, let g): return "invalid size: expected \(e), got \(g)"
        case .unexpectedChecksum(let g, let e):
            return "unexpected checksum \(String(g, radix: 16)), expected \(String(e, radix: 16))"
        case .unexpectedFullRecord: return "unexpected full record"
        case .unexpectedFirstRecord: return "unexpected first record, dropping buffer"
        case .unexpectedMiddleRecord: return "unexpected middle record, dropping buffer"
        case .unexpectedLastRecord: return "unexpected last record, dropping buffer"
        case .unexpectedRecordType(let t): return "unexpected record type \(t)"
        case .unsupportedCompressionType(let t): return "unsupported compression type: \(t)"
        case .wrapped(let ctx, let err): return "\(ctx): \(err)"
        }
    }

    public static func == (a: WALError, b: WALError) -> Bool {
        a.description == b.description
    }

    /// Go: `errors.Is(err, io.EOF)`, which follows `%w` wrapping. `Reader.Next` needs it, and the
    /// distinction from `unexpectedEOF` is the point — see that case's comment.
    public var isEOF: Bool {
        switch self {
        case .eof: return true
        case .wrapped(_, let inner): return (inner as? WALError)?.isEOF ?? false
        default: return false
        }
    }
}

/// Go: `wlog.validateRecord` (it lives in `live_reader.go`, and `Reader` calls it).
///
/// The grammar in one function: a `full` or `first` fragment may only appear at position 0, and a `middle`
/// or `last` only after one. `i` counts **content** fragments only — the reader does not increment it for a
/// page terminator, which is what lets a record span a page boundary.
func validateRecord(_ typ: WALRecordType, _ i: Int) throws {
    switch typ {
    case .full:
        if i != 0 { throw WALError.unexpectedFullRecord }
    case .first:
        if i != 0 { throw WALError.unexpectedFirstRecord }
    case .middle:
        if i == 0 { throw WALError.unexpectedMiddleRecord }
    case .last:
        if i == 0 { throw WALError.unexpectedLastRecord }
    default:
        throw WALError.unexpectedRecordType(typ.rawValue)
    }
}

/// Go: `crc32.Checksum(part, castagnoliTable)`.
func walCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    CRC32C.checksum(Array(bytes))
}
