//===----------------------------------------------------------------------===//
// Ported from tsdb/index/index.go @ v3.13.2 — the index file's HEADER, TABLE OF CONTENTS and SYMBOL
// TABLE, all of which read from a `ByteSlice` and so need no filesystem.
//
// **The writer is not here, and neither is the rest of the reader yet.** `index.Writer` is
// `FileWriter`-based (ADR-15's subject) and the reader's series records, postings offset table and label
// indices are the next slices. What this file establishes is the seam: the oracle writes a REAL index
// file with Go's writer, emits its bytes, and the port parses them. So the port is pinned against
// upstream's own serialiser without owning one — the same trick §6e used for the chunk-segment batching,
// generalised.
//
// ## The TOC is at the END, and its CRC covers only itself
//
// Six big-endian `uint64` offsets followed by a four-byte CRC32-C, in the last 52 bytes of the file. So
// reading an index starts at the tail and works backwards, and a truncated file fails on the TOC rather
// than on the header.
//
// ## `NewDecbufAt`'s framing is length-prefixed AND checksummed, and it is used everywhere
//
//     <4-byte big-endian length> <length bytes of content> <4-byte CRC32-C over the content>
//
// The length does **not** include itself or the CRC. Note the checksum covers the content only, which is
// the same choice `chunks.writeHash` makes (quirk 126) — a corrupted length is caught by the bounds test,
// not the CRC.
//
// ## The symbol table is a COUNT then that many uvarint-prefixed strings, indexed sparsely
//
// `NewSymbols` walks the whole table once at open, recording a byte offset every **32** symbols
// (`symbolFactor`). A `Lookup(o)` in format v2 then jumps to `offsets[o/32]` and walks `o % 32` symbols
// forward. So the index is deliberately sparse: 1/32 of the offsets in memory, at most 31 skips per
// lookup.
//
// **Format v1 and v2 mean different things by the same `uint32`.** In v1 the argument to `Lookup` is a
// BYTE OFFSET into the file and `d.Skip(int(o))` uses it directly; in v2 it is an ORDINAL and the sparse
// table resolves it. `ReverseLookup` mirrors that — v1 returns `bs.Len() - lastLen`, a byte position,
// where v2 returns `res`, a count. A port that treats the value as one kind throughout reads v1 files as
// garbage.
//
// ## `ReverseLookup`'s binary search is over the SPARSE offsets, then it walks
//
// `sort.Search` finds the first sparse offset whose symbol sorts **after** the target, steps back one,
// and walks forward from there. The `if i > 0 { i-- }` is what makes it a lower bound; without it a
// symbol landing exactly on a sparse boundary is missed. And the walk's termination is `res <= s.seen`,
// inclusive, so the last symbol is reachable.
//===----------------------------------------------------------------------===//

public import PromEncoding

internal import GoCompat
internal import PromHash

/// Go: `MagicIndex` — the four bytes at the head of an index file.
public let magicIndex: UInt32 = 0xBAAA_D700
/// Go: `HeaderLen` — magic plus a one-byte version.
public let indexHeaderLen = 5
/// Go: `FormatV1`, `FormatV2`.
public let indexFormatV1 = 1
public let indexFormatV2 = 2
/// Go: `indexTOCLen` — six `uint64`s plus a CRC.
public let indexTOCLen = 6 * 8 + 4
/// Go: `symbolFactor` — one recorded offset per 32 symbols.
let symbolFactor = 32

/// Go: the index reader's error values.
public enum IndexError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `encoding.ErrInvalidSize`.
    case invalidSize
    /// Go: `fmt.Errorf("read TOC: %w", encoding.ErrInvalidChecksum)`.
    case tocInvalidChecksum
    /// Go: `fmt.Errorf("unknown symbol offset %d", o)`.
    case unknownSymbolOffset(UInt32)
    /// Go: `fmt.Errorf("unknown symbol %q - no symbols", sym)` — note `%q`, so the symbol is quoted.
    case unknownSymbolNoSymbols(String)
    /// Go: `fmt.Errorf("unknown symbol %q", sym)`.
    case unknownSymbol(String)

    public var description: String {
        switch self {
        case .invalidSize: return "invalid size"
        case .tocInvalidChecksum: return "read TOC: invalid checksum"
        case .unknownSymbolOffset(let o): return "unknown symbol offset \(o)"
        case .unknownSymbolNoSymbols(let s): return "unknown symbol \(goQuote(s)) - no symbols"
        case .unknownSymbol(let s): return "unknown symbol \(goQuote(s))"
        }
    }
}

/// Go's `%q` on a string. `GoStrconv.quote` is the pinned implementation.
private func goQuote(_ s: String) -> String { GoStrconv.quote(s) }

/// Go: `index.TOC` — six offsets into the file, stored in its last 52 bytes.
public struct IndexTOC: Sendable, Equatable {
    public var symbols: UInt64
    public var series: UInt64
    public var labelIndices: UInt64
    public var labelIndicesTable: UInt64
    public var postings: UInt64
    public var postingsTable: UInt64

    /// A memberwise initialiser, for the WRITER — which fills the offsets in as each stage begins rather
    /// than parsing them.
    public init(
        symbols: UInt64 = 0, series: UInt64 = 0, labelIndices: UInt64 = 0,
        labelIndicesTable: UInt64 = 0, postings: UInt64 = 0, postingsTable: UInt64 = 0
    ) {
        self.symbols = symbols
        self.series = series
        self.labelIndices = labelIndices
        self.labelIndicesTable = labelIndicesTable
        self.postings = postings
        self.postingsTable = postingsTable
    }

    /// Go: `NewTOCFromByteSlice`.
    ///
    /// Reads from the END of the file. The CRC covers the six offsets and nothing else — not the file, not
    /// the header — so it verifies the TOC's own integrity only.
    public init(byteSlice bs: ByteSlice) throws {
        if bs.count < indexTOCLen {
            throw IndexError.invalidSize
        }
        let b = bs.range(bs.count - indexTOCLen, bs.count)
        let expCRC = b.loadBE32(at: b.count - 4)
        var d = Decbuf(b.range(0, b.count - 4))
        if d.crc32() != expCRC {
            throw IndexError.tocInvalidChecksum
        }
        symbols = d.be64()
        series = d.be64()
        labelIndices = d.be64()
        labelIndicesTable = d.be64()
        postings = d.be64()
        postingsTable = d.be64()
        if let e = d.err {
            throw e
        }
    }
}

/// Go: `index.Symbols` — the symbol table, with a sparse offset index.
public struct IndexSymbols: Sendable {
    private let bs: ByteSlice
    private let version: Int
    private let off: Int
    /// Byte offsets, one every `symbolFactor` symbols.
    private var offsets: [Int] = []
    /// Go: `seen` — how many symbols the table holds.
    public private(set) var seen = 0

    /// Go: `NewSymbols` — walks the WHOLE table once, recording every 32nd offset.
    ///
    /// `basePos + origLen - d.Len()` is how Go recovers an absolute byte position from a decoder that only
    /// knows how much it has left: `origLen - d.Len()` is bytes consumed, and `basePos` is `off + 4`,
    /// past the length prefix.
    public init(byteSlice bs: ByteSlice, version: Int, off: Int) throws {
        self.bs = bs
        self.version = version
        self.off = off

        var d = Decbuf.at(bs, off, verifyChecksum: true)
        if let e = d.err { throw e }
        let origLen = d.count
        let cnt = d.be32int()
        let basePos = off + 4
        offsets.reserveCapacity(1 + cnt / symbolFactor)
        while d.err == nil && seen < cnt {
            if seen % symbolFactor == 0 {
                offsets.append(basePos + origLen - d.count)
            }
            _ = d.uvarintBytes()  // The symbol itself, skipped.
            seen += 1
        }
        if let e = d.err {
            throw e
        }
    }

    /// Go: `Symbols.Lookup`.
    ///
    /// **`o` means different things in v1 and v2** — a byte offset in v1, an ordinal in v2. See the file
    /// header.
    public func lookup(_ o: UInt32) throws -> String {
        var d = Decbuf(bs.range(0, bs.count))
        if version == indexFormatV1 {
            d.skip(Int(o))
        } else {
            if Int(o) >= seen {
                throw IndexError.unknownSymbolOffset(o)
            }
            d.skip(offsets[Int(o) / symbolFactor])
            // Walk the remainder of the sparse block.
            var i = o - (o / UInt32(symbolFactor) * UInt32(symbolFactor))
            while i > 0 {
                _ = d.uvarintBytes()
                i -= 1
            }
        }
        let sym = d.uvarintStr()
        if let e = d.err {
            throw e
        }
        return sym
    }

    /// Go: `Symbols.ReverseLookup`.
    ///
    /// Binary search over the SPARSE offsets, then a linear walk. The `if i > 0 { i-- }` turns the
    /// search's upper bound into a lower one; without it a symbol on a sparse boundary is missed.
    public func reverseLookup(_ sym: String) throws -> UInt32 {
        if offsets.isEmpty {
            throw IndexError.unknownSymbolNoSymbols(sym)
        }
        // Go: `sort.Search` for the first sparse block whose first symbol sorts AFTER `sym`. Errors
        // inside the predicate are lost upstream too — the table was already walked at open.
        var lo = 0
        var hi = offsets.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            var d = Decbuf(bs.range(0, bs.count))
            d.skip(offsets[mid])
            let first = d.uvarintStr()
            if goStringGreater(first, sym) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        var i = lo
        var d = Decbuf(bs.range(0, bs.count))
        if i > 0 { i -= 1 }
        d.skip(offsets[i])
        var res = i * symbolFactor
        var lastLen = 0
        var lastSymbol = ""
        // `res <= seen` is INCLUSIVE, so the final symbol is reachable.
        while d.err == nil && res <= seen {
            lastLen = d.count
            lastSymbol = d.uvarintStr()
            if !goStringLess(lastSymbol, sym) {
                break
            }
            res += 1
        }
        if let e = d.err {
            throw e
        }
        if lastSymbol != sym {
            throw IndexError.unknownSymbol(sym)
        }
        if version == indexFormatV1 {
            // v1 answers with a BYTE POSITION.
            return UInt32(bs.count - lastLen)
        }
        return UInt32(res)
    }

    /// Go: `Symbols.Size` — the memory the sparse index occupies, eight bytes per entry.
    public var size: Int { offsets.count * 8 }

    /// Go: `Symbols.Iter` — every symbol in table order.
    public func all() throws -> [String] {
        var d = Decbuf.at(bs, off, verifyChecksum: true)
        if let e = d.err { throw e }
        let cnt = d.be32int()
        var out: [String] = []
        out.reserveCapacity(cnt)
        for _ in 0..<cnt {
            out.append(d.uvarintStr())
            if let e = d.err { throw e }
        }
        return out
    }
}

/// ADR-10: Go compares strings by BYTE, Swift by Unicode collation. The symbol table is sorted by Go's
/// ordering, so its binary search must use Go's comparison or it searches a differently-sorted array.
func goStringLess(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}

func goStringGreater(_ a: String, _ b: String) -> Bool {
    goStringLess(b, a)
}

// MARK: - Series records and postings

/// Go: `seriesByteAlign` — in format v2 a series ID is the byte position **divided by 16**.
let seriesByteAlign = 16

/// Go: `Decoder.Series`' errors, each wrapping the decoder's own.
public enum SeriesDecodeError: Error, CustomStringConvertible, Equatable, Sendable {
    case readSeriesLabelOffsets(String)
    case lookupLabelName(String)
    case lookupLabelValue(String)
    case readMetaForChunk(Int, String)
    /// Go: `fmt.Errorf("read series: %w", err)` — `Reader.Series` wraps whatever `Decoder.Series` returns.
    case readSeries(String)
    /// Go: `fmt.Errorf("get buffer for series: %w", err)` — **`LabelNamesFor`'s wrapper, which is NOT
    /// prefixed with "read series:"**. Reusing `readSeries` here double-wraps, and two corpus cases said
    /// so: the same underlying `invalid checksum` reaches the caller with a different prefix depending on
    /// which reader method asked.
    case getBufferForSeries(String)
    /// Go: `unexpected postings length, should be %d bytes for %d postings, got %d bytes`.
    case unexpectedPostingsLength(expectedBytes: Int, postings: Int, gotBytes: Int)

    public var description: String {
        switch self {
        case .readSeriesLabelOffsets(let e): return "read series label offsets: \(e)"
        case .lookupLabelName(let e): return "lookup label name: \(e)"
        case .lookupLabelValue(let e): return "lookup label value: \(e)"
        case .readMetaForChunk(let i, let e): return "read meta for chunk \(i): \(e)"
        case .readSeries(let e): return "read series: \(e)"
        case .getBufferForSeries(let e): return "get buffer for series: \(e)"
        case .unexpectedPostingsLength(let exp, let n, let got):
            return
                "unexpected postings length, should be \(exp) bytes for \(n) postings, got \(got) bytes"
        }
    }
}

/// One decoded series: its labels, and the metadata of its chunks.
public struct DecodedSeries: Sendable, Equatable {
    public var labels: [(name: String, value: String)]
    public var chunks: [DecodedChunkMeta]

    public static func == (a: DecodedSeries, b: DecodedSeries) -> Bool {
        a.chunks == b.chunks && a.labels.count == b.labels.count
            && zip(a.labels, b.labels).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

/// Go: the `chunks.Meta` fields a series record carries. Only the reference and the time range are
/// stored; the data lives in a chunk segment.
public struct DecodedChunkMeta: Sendable, Equatable {
    public var ref: UInt64
    public var minTime: Int64
    public var maxTime: Int64
}

/// Go: `Decoder.Series` — the series record's payload.
///
/// ## The chunk metas are DOUBLE-DELTA encoded, and the first one is framed differently
///
/// The first chunk stores `mint` as a signed varint, `maxt` as an unsigned delta from it, and the
/// reference as an unsigned varint. Every chunk after that stores `mint` as an unsigned delta from the
/// PREVIOUS chunk's `maxt`, `maxt` as an unsigned delta from its own `mint`, and the reference as a
/// **signed** delta — references can move backwards between chunks because a later chunk may live in an
/// earlier segment.
///
/// So `t0` tracks the previous `maxt` and `ref0` accumulates. Reading the first chunk with the general
/// framing, or the general ones with the first's, decodes plausible-looking nonsense rather than failing.
///
/// ## The label pairs are symbol-table OFFSETS, not strings
///
/// Each pair is two uvarints resolved through `lookupSymbol`. In format v2 those are ordinals; in v1 they
/// are byte offsets (quirk 130), so the same record decodes differently depending on the file's version.
public func decodeSeries(
    _ b: ByteSlice, lookupSymbol: (UInt32) throws -> String, decodeChunks: Bool = true
) throws -> DecodedSeries {
    var d = Decbuf(b)
    var out = DecodedSeries(labels: [], chunks: [])

    let k = d.uvarint()
    for _ in 0..<k {
        let lno = UInt32(truncatingIfNeeded: d.uvarint())
        let lvo = UInt32(truncatingIfNeeded: d.uvarint())
        if let e = d.err {
            throw SeriesDecodeError.readSeriesLabelOffsets(String(describing: e))
        }
        let ln: String
        do {
            ln = try lookupSymbol(lno)
        } catch {
            throw SeriesDecodeError.lookupLabelName(String(describing: error))
        }
        let lv: String
        do {
            lv = try lookupSymbol(lvo)
        } catch {
            throw SeriesDecodeError.lookupLabelValue(String(describing: error))
        }
        out.labels.append((ln, lv))
    }

    // Go: `if chks == nil` — the caller can ask for labels only, and then the chunk metas are not even
    // parsed.
    if !decodeChunks {
        if let e = d.err { throw e }
        return out
    }

    let kChunks = d.uvarint()
    if kChunks == 0 {
        if let e = d.err { throw e }
        return out
    }

    // The FIRST chunk: signed mint, unsigned maxt delta, unsigned ref.
    var t0 = d.varint64()
    var maxt = Int64(bitPattern: d.uvarint64()) &+ t0
    var ref0 = Int64(bitPattern: d.uvarint64())
    out.chunks.append(DecodedChunkMeta(ref: UInt64(bitPattern: ref0), minTime: t0, maxTime: maxt))
    t0 = maxt

    for i in 1..<kChunks {
        let mint = Int64(bitPattern: d.uvarint64()) &+ t0
        maxt = Int64(bitPattern: d.uvarint64()) &+ mint
        // SIGNED: a later chunk can live in an earlier segment.
        ref0 &+= d.varint64()
        t0 = maxt
        if let e = d.err {
            throw SeriesDecodeError.readMetaForChunk(i, String(describing: e))
        }
        out.chunks.append(
            DecodedChunkMeta(ref: UInt64(bitPattern: ref0), minTime: mint, maxTime: maxt))
    }
    if let e = d.err { throw e }
    return out
}

/// Go: `Reader.Series` — resolve a series ID to its record and decode it.
///
/// **In format v2 the ID is the byte position divided by 16.** Series records are padded to
/// `seriesByteAlign`, so the ID multiplies back up; in v1 it is the position itself.
public func readSeries(
    _ bs: ByteSlice, id: UInt64, version: Int, lookupSymbol: (UInt32) throws -> String,
    decodeChunks: Bool = true
) throws -> DecodedSeries {
    let offset = version == indexFormatV1 ? id : id * UInt64(seriesByteAlign)
    let d = Decbuf.uvarintAt(bs, Int(offset))
    if let e = d.err { throw e }
    do {
        return try decodeSeries(d.b, lookupSymbol: lookupSymbol, decodeChunks: decodeChunks)
    } catch {
        throw SeriesDecodeError.readSeries(String(describing: error))
    }
}

/// Go: `DecodePostingsRaw` — a big-endian count then that many big-endian `uint32`s.
///
/// The length check is exact: `4*n` bytes for `n` postings, and a mismatch is an error rather than a
/// truncated read.
public func decodePostingsRaw(_ d: Decbuf) throws -> (count: Int, postings: any Postings) {
    var d = d
    let n = d.be32int()
    let l = d.b
    if let e = d.err { throw e }
    if l.count != 4 * n {
        throw SeriesDecodeError.unexpectedPostingsLength(
            expectedBytes: 4 * n, postings: n, gotBytes: l.count)
    }
    return (n, BigEndianPostings(Array(l.rawBuffer)))
}

// MARK: - The postings offset table

/// Go: `postingOffset` — one entry of the in-memory sparse index over the postings offset table.
public struct PostingOffset: Sendable, Equatable {
    public var value: String
    /// A byte offset **relative to the start of the table's contents**, not to the file.
    public var off: Int
}

/// Go: the postings-offset-table errors.
public enum PostingsTableError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `unexpected number of keys for postings offset table %d`.
    case unexpectedKeyCount(Int)
    /// Go: `fmt.Errorf("get postings offset entry: %w", err)`.
    case getPostingsOffsetEntry(String)

    public var description: String {
        switch self {
        case .unexpectedKeyCount(let k):
            return "unexpected number of keys for postings offset table \(k)"
        case .getPostingsOffsetEntry(let e): return "get postings offset entry: \(e)"
        }
    }
}

/// Go: `ReadPostingsOffsetTable` — every entry, in order.
///
/// An entry is `<uvarint key count, always 2> <uvarint-prefixed name> <uvarint-prefixed value>
/// <uvarint postings offset>`, and the table opens with a big-endian count. The callback also receives
/// the entry's byte position **relative to the table's contents**, which is what the sparse index stores.
///
/// The loop's guard is `d.Err() == nil && d.Len() > 0 && cnt > 0` — all three, so a truncated table stops
/// quietly rather than erroring, and a count larger than the data does too.
public func readPostingsOffsetTable(
    _ bs: ByteSlice, off: UInt64,
    _ f: (_ name: String, _ value: String, _ postingsOffset: UInt64, _ labelOffset: Int) throws ->
        Void
) throws {
    var d = Decbuf.at(bs, Int(off), verifyChecksum: true)
    if let e = d.err { throw e }
    let startLen = d.count
    var cnt = d.be32()

    while d.err == nil && d.count > 0 && cnt > 0 {
        let offsetPos = startLen - d.count
        let keyCount = d.uvarint()
        if keyCount != 2 {
            throw PostingsTableError.unexpectedKeyCount(keyCount)
        }
        let name = d.uvarintStr()
        let value = d.uvarintStr()
        let o = d.uvarint64()
        if d.err != nil { break }
        try f(name, value, o, offsetPos)
        cnt -= 1
    }
    if let e = d.err { throw e }
}

/// Go: the sparse postings index `newReader` builds — every label NAME, but only every 32nd label
/// VALUE, plus the first and last of each name.
///
/// **The "plus the last" part is the subtle half.** A name's final value is appended when the NEXT name
/// begins, using `lastName`/`lastValue`/`lastOff` carried forward — and again after the loop for the
/// final name. Without it a lookup for a name's largest value has no entry at or before it and the
/// binary search in `postings(name:values:)` walks from the wrong place.
///
/// `lastName` is cleared whenever a value IS recorded, so a value that lands exactly on the sparse
/// boundary is not also appended as a "last".
public func buildPostingsOffsetIndex(_ bs: ByteSlice, postingsTable off: UInt64) throws
    -> [String: [PostingOffset]]
{
    var postings: [String: [PostingOffset]] = [:]
    var order: [String] = []
    var lastName: String? = nil
    var lastValue = ""
    var lastOff = 0
    var valueCount = 0

    try readPostingsOffsetTable(bs, off: off) { name, value, _, entryOff in
        if postings[name] == nil {
            // A new label name begins.
            postings[name] = []
            order.append(name)
            if let ln = lastName {
                // Always include the previous name's LAST value.
                postings[ln]!.append(PostingOffset(value: lastValue, off: lastOff))
            }
            valueCount = 0
        }
        if valueCount % symbolFactor == 0 {
            postings[name]!.append(PostingOffset(value: value, off: entryOff))
            lastName = nil
        } else {
            lastName = name
            lastValue = value
            lastOff = entryOff
        }
        valueCount += 1
    }
    if let ln = lastName {
        postings[ln]!.append(PostingOffset(value: lastValue, off: lastOff))
    }
    return postings
}

/// Go: `Reader.traversePostingOffsets` — walk the table from a byte offset, calling back per entry until
/// the callback says stop.
///
/// **Two things here are load-bearing.**
///
/// The decoder is built with a **nil** checksum table — upstream's comment: "Don't Crc32 the entire
/// postings offset table, this is very slow so hope any issues were caught at startup." So this read is
/// deliberately unverified, unlike every other `NewDecbufAt` in the file.
///
/// And the `skip` optimisation assumes **the label name does not change**: it measures the bytes the
/// first entry's key-count-plus-name occupies and then skips exactly that many for every later entry.
/// That is only valid within one name's run, which is why the callback's `false` return — driven by the
/// caller comparing against the *next* sparse entry's value — is what keeps it correct rather than an
/// optimisation detail.
public func traversePostingOffsets(
    _ bs: ByteSlice, postingsTable tableOff: UInt64, from off: Int,
    _ cb: (_ value: String, _ postingsOffset: UInt64) throws -> Bool
) throws {
    // Note: no checksum verification, deliberately.
    var d = Decbuf.at(bs, Int(tableOff), verifyChecksum: false)
    d.skip(off)
    var skip = 0
    while d.err == nil {
        if skip == 0 {
            // Measure the key count plus label name once; they are the same width for every entry of
            // this name.
            skip = d.count
            _ = d.uvarint()  // Key count.
            _ = d.uvarintBytes()  // Label name.
            skip -= d.count
        } else {
            d.skip(skip)
        }
        let v = d.uvarintStr()  // Label value.
        let postingsOff = d.uvarint64()
        if d.err != nil { break }
        if !(try cb(v, postingsOff)) {
            break
        }
    }
    if let e = d.err {
        throw PostingsTableError.getPostingsOffsetEntry(String(describing: e))
    }
}

/// Go: `Reader.Postings` for format v2 — the postings lists for a set of values of one label.
///
/// The value list is **sorted first**, because the algorithm steps forward through an on-disk table and
/// cannot go back. Then for each value it binary-searches the sparse index, steps back one entry when the
/// hit is not exact (`if i > 0 && e[i].value != value { i-- }`), and traverses from there — consuming as
/// many of the requested values as that run covers before moving to a later sparse entry.
///
/// The leading `for valueIndex < len(values) && values[valueIndex] < e[0].value` loop discards requested
/// values below the table's first entry; without it the first binary search would land at 0 and the
/// step-back would be skipped, traversing from the right place by luck rather than by construction.
public func indexPostings(
    _ bs: ByteSlice, postingsTable tableOff: UInt64,
    sparse: [String: [PostingOffset]], name: String, values: [String]
) throws -> [any Postings] {
    guard let e = sparse[name], !values.isEmpty else {
        return []
    }
    // Go: `slices.Sort(values)` — Go's byte ordering (ADR-10), matching the table's own sort.
    let values = values.sorted { goStringLess($0, $1) }
    var res: [any Postings] = []
    var valueIndex = 0
    while valueIndex < values.count && goStringLess(values[valueIndex], e[0].value) {
        valueIndex += 1
    }
    while valueIndex < values.count {
        var value = values[valueIndex]

        // The first sparse entry whose value is >= the wanted one.
        var i = 0
        var lo = 0
        var hi = e.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if goStringLess(e[mid].value, value) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        i = lo
        if i == e.count {
            // Past the end.
            break
        }
        if i > 0 && e[i].value != value {
            // The hit is not exact, so the run containing it starts at the previous entry.
            i -= 1
        }

        let entryIndex = i
        try traversePostingOffsets(bs, postingsTable: tableOff, from: e[entryIndex].off) {
            val, postingsOff in
            while !goStringLess(val, value) {
                if val == value {
                    var d2 = Decbuf.at(bs, Int(postingsOff), verifyChecksum: true)
                    if let err = d2.err { throw err }
                    let (_, p) = try decodePostingsRaw(d2)
                    res.append(p)
                }
                valueIndex += 1
                if valueIndex == values.count { break }
                value = values[valueIndex]
            }
            if entryIndex + 1 == e.count || !goStringLess(value, e[entryIndex + 1].value)
                || valueIndex == values.count
            {
                // Move to a later sparse entry, if there is one.
                return false
            }
            return true
        }
    }
    return res
}

// MARK: - Label values and names

/// Go: `Reader.LabelValues` for format v2 — every value of one label, in table order.
///
/// **The traversal's stop condition is `val != lastVal`, and `lastVal` comes from the SPARSE index's final
/// entry.** That works only because the sparse index always includes each name's last value (quirk 136):
/// without it there would be no reliable sentinel and the walk would run into the next label name, whose
/// entries the `skip` optimisation would then mis-parse (quirk 135). The three pieces are one mechanism.
///
/// `hints.limit` truncates, and it is checked BEFORE appending, so a limit of `n` yields at most `n`
/// values. Go returns `nil, nil` for an unknown name — not an empty slice — which the port models as an
/// empty array since nothing distinguishes them downstream.
public func indexLabelValues(
    _ bs: ByteSlice, postingsTable tableOff: UInt64, sparse: [String: [PostingOffset]],
    name: String, limit: Int = 0
) throws -> [String] {
    guard let e = sparse[name], !e.isEmpty else {
        return []
    }
    var values: [String] = []
    var capacity = e.count * symbolFactor
    if limit > 0 && capacity > limit {
        capacity = limit
    }
    values.reserveCapacity(capacity)
    let lastVal = e[e.count - 1].value
    try traversePostingOffsets(bs, postingsTable: tableOff, from: e[0].off) { val, _ in
        if limit > 0 && values.count >= limit {
            return false
        }
        values.append(val)
        // Stop when the name's final value has been seen.
        return val != lastVal
    }
    return values
}

/// Go: `Reader.LabelNames` — every label name, sorted, **excluding the all-postings key**.
///
/// That exclusion is the thing to notice: the table contains an entry for `("", "")`
/// (`allPostingsKey`), which is how "every series" is stored, and it is not a real label. Go skips it by
/// name; a port that returns the map's keys verbatim reports an empty-string label name.
///
/// The sort is Go's byte ordering (ADR-10), matching `slices.Sort`.
public func indexLabelNames(_ sparse: [String: [PostingOffset]]) -> [String] {
    let allKey = allPostingsKey().name
    return sparse.keys.filter { $0 != allKey }.sorted { goStringLess($0, $1) }
}

/// Go: `Decoder.LabelNamesOffsetsFor` — the label-NAME symbol offsets of one series record, skipping the
/// values.
///
/// Returned in stored order, which upstream's comment says "should be sorted lexicographically" — a
/// statement about the writer, not a guarantee the reader enforces.
public func labelNamesOffsetsFor(_ b: ByteSlice) throws -> [UInt32] {
    var d = Decbuf(b)
    let k = d.uvarint()
    var offsets: [UInt32] = []
    offsets.reserveCapacity(k)
    for _ in 0..<k {
        offsets.append(UInt32(truncatingIfNeeded: d.uvarint()))
        _ = d.uvarint()  // The label value's offset, skipped.
    }
    if let e = d.err { throw e }
    return offsets
}

/// Go: `Reader.LabelNamesFor` — the union of label names across a set of series, sorted.
///
/// Collects symbol OFFSETS into a set first and resolves them once at the end, so a name shared by a
/// thousand series costs one symbol lookup rather than a thousand. The sort is Go's byte ordering.
public func indexLabelNamesFor(
    _ bs: ByteSlice, version: Int, seriesIDs: [UInt64], lookupSymbol: (UInt32) throws -> String
) throws -> [String] {
    var offsetsSet = Set<UInt32>()
    for id in seriesIDs {
        let offset = version == indexFormatV1 ? id : id * UInt64(seriesByteAlign)
        let d = Decbuf.uvarintAt(bs, Int(offset))
        if let e = d.err {
            throw SeriesDecodeError.getBufferForSeries(String(describing: e))
        }
        for off in try labelNamesOffsetsFor(d.b) {
            offsetsSet.insert(off)
        }
    }
    var names: [String] = []
    names.reserveCapacity(offsetsSet.count)
    for off in offsetsSet {
        names.append(try lookupSymbol(off))
    }
    return names.sorted { goStringLess($0, $1) }
}
