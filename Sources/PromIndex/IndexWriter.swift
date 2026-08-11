//===----------------------------------------------------------------------===//
// Ported from tsdb/index/index.go @ v3.13.2 — `Writer`'s meta, symbol and series stages, on `PromFS`.
//
// ## The postings sections re-READ the series records this writer already wrote
//
// `writePostingsToTmpFiles` does not keep the series in memory. It flushes, mmaps the file it is writing,
// and walks the series section back — consuming padding, taking `startPos/16` as each series' ordinal, and
// collecting them per (label name, label value). So the series section is the source of truth for the
// postings, and the ordinals are positions rather than the `ref` the caller passed to `AddSeries`.
//
// The port reads the file back through `PromFS` instead of mmapping (ADR-15), which is the same bytes.
//
// ## Two temporary files, and the offsets in one are relative to the other
//
// `fP` holds the postings lists, each 4-byte aligned and framed `<BE32 len><payload><BE32 CRC>`. `fPO`
// holds the offset-table entries, whose offsets are **relative to `fP`**. `writePostings` then copies `fP`
// into the index after 4-byte padding and records `postingsStart`, and `writePostingsOffsetTable` copies
// `fPO` while **adding `postingsStart` to every offset**. Get that adjustment wrong and every postings
// list is unreachable while the file still passes every checksum.
//
// The port holds both in memory rather than on disk. That is byte-equivalent — what matters is `fP`'s
// layout, because the offsets are positions within it — and it avoids two more `PromFS` handles for data
// that never outlives the call.
//
// ## The all-postings list is written FIRST, under `("", "")`
//
// Before any real label, `writePosting("", "", offsets)` records every series in file order. That is the
// entry `LabelNames` has to skip (quirk 139), and writing it first is why it has the lowest offset.
//
// ## The stages are a strict ladder and skipping one is an error
//
// `idxStageNone < idxStageSymbols < idxStageSeries < idxStageDone`, and `ensureStage` recurses to fill a
// gap while REJECTING a move backwards (`invalid stage %q, currently at %q`). So `AddSymbol` after
// `AddSeries` fails, and the section offsets in the TOC are recorded as each stage begins — which is why
// the ladder exists rather than being a convenience.
//
// ## Section lengths are back-patched, and the placeholders are ASCII
//
// `startSymbols` writes the literal bytes `"alenblen"` — eight bytes of placeholder for a 4-byte length
// and a 4-byte symbol count — and `finishSymbols` overwrites them once both are known. `finishSymbols`
// then writes `"hash"` as a placeholder and patches that too. Those strings are visible in a truncated
// index file, which is a useful thing to recognise when debugging one.
//
// The length written is `pos - toc.Symbols - 4`: it excludes its own four bytes but INCLUDES the symbol
// count and the trailing hash, which is what `NewDecbufAt`'s framing expects.
//
// ## A series record's length prefix is a UVARINT, unlike the symbol table's BE32
//
// `AddSeries` writes `PutUvarint(buf2.Len())` then the payload and its hash, so a series is framed by
// `NewDecbufUvarintAt` while the symbol table is framed by `NewDecbufAt`. Two framings in one file, and
// which one applies depends on the section.
//
// ## Records are padded to 16 bytes BEFORE the length prefix
//
// `addPadding(seriesByteAlign)` runs first, then the assertion `pos % 16 != 0`, and only then the record.
// That is what makes a series ID the position divided by 16 (quirk 133). The padding belongs to the
// previous record's tail, not to this record's head.
//
// ## The validation order in `AddSeries` is observable
//
// Label ordering, then the series-ref bound, then per-chunk checks in index order, then padding. So a
// series that is both out of order AND has bad chunks reports the ordering error — and the chunk checks
// report the FIRST offending chunk, which the port preserves by keeping the loop rather than validating
// in bulk.
//===----------------------------------------------------------------------===//

public import PromEncoding
public import PromFS

internal import GoCompat
internal import PromHash

/// Go: `indexWriterStage`.
enum IndexWriterStage: Int, Comparable, CustomStringConvertible {
    case none = 0
    case symbols
    case series
    case done

    static func < (a: IndexWriterStage, b: IndexWriterStage) -> Bool { a.rawValue < b.rawValue }

    /// Go: `indexWriterStage.String()`, which the stage error interpolates with `%q`.
    var description: String {
        switch self {
        case .none: return "none"
        case .symbols: return "symbols"
        case .series: return "series"
        case .done: return "done"
        }
    }
}

/// Go: `index.Writer`'s errors.
public enum IndexWriteError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidStage(want: String, current: String)
    case symbolOutOfOrder(String)
    case outOfOrderSeries(labels: String, last: String)
    case seriesRefTooLarge(UInt64)
    case unsortedChunkReference(UInt64, previous: UInt64)
    case chunkMinTNotHigher(minT: Int64, previousMaxT: Int64)
    case chunkMaxTLessThanMinT(maxT: Int64, minT: Int64)
    case symbolEntryMissing(String)
    case seriesNotAligned(UInt64)
    case symbolTableTooLarge(UInt64)

    public var description: String {
        switch self {
        case .invalidStage(let want, let current):
            return "invalid stage \(goQuoteString(want)), currently at \(goQuoteString(current))"
        case .symbolOutOfOrder(let s): return "symbol \(goQuoteString(s)) out-of-order"
        case .outOfOrderSeries(let l, let last):
            return
                "out-of-order series added with label set \(goQuoteString(l)), last label set \(goQuoteString(last))"
        case .seriesRefTooLarge(let r): return "series with reference greater than \(r) already added"
        case .unsortedChunkReference(let r, let p):
            return "unsorted chunk reference: \(r), previous: \(p)"
        case .chunkMinTNotHigher(let m, let p):
            return "chunk minT \(m) is not higher than previous chunk maxT \(p)"
        case .chunkMaxTLessThanMinT(let mx, let mn):
            return "chunk maxT \(mx) is less than minT \(mn)"
        case .symbolEntryMissing(let s): return "symbol entry for \(goQuoteString(s)) does not exist"
        case .seriesNotAligned(let pos): return "series write not 16-byte aligned at \(pos)"
        case .symbolTableTooLarge(let n):
            return "symbol table size exceeds 4294967295 bytes: \(n)"
        }
    }
}

private func goQuoteString(_ s: String) -> String { GoStrconv.quote(s) }

/// Go: `index.Writer`, meta/symbols/series stages only.
public final class IndexWriter {
    private let fs: any PromFS
    private let path: String
    private var f: any FSWriteHandle
    private var stage: IndexWriterStage = .none

    /// Go: `toc` — filled in as each stage begins.
    public private(set) var toc = IndexTOC(
        symbols: 0, series: 0, labelIndices: 0, labelIndicesTable: 0, postings: 0, postingsTable: 0)

    private var numSymbols = 0
    private var lastSymbol = ""
    /// Go: `symbolCache` — symbol -> its ORDINAL, which is what a series record stores in format v2.
    ///
    /// **Keyed by BYTES, not by `String`.** Swift compares strings by Unicode canonical equivalence, so
    /// `"e\u{301}"` and `"é"` are the same dictionary key in Swift and two different symbols in Go. Keyed
    /// by `String`, one of them silently takes the other's ordinal and every series referencing it points
    /// at the wrong symbol — the file stays structurally valid and decodes to the wrong labels. ADR-10 is
    /// usually cited for *ordering*; this is the same hazard in *hashing and equality*, and the corpus
    /// caught it as a four-byte divergence 83 bytes into the series section.
    private var symbolCache: [[UInt8]: UInt32] = [:]
    /// Go: `labelNames` — how many series use each label name, which drives the batching. The port keeps
    /// the count for the same reason and keys it by BYTES (ADR-10a).
    private var labelNameUses: [[UInt8]: Int] = [:]
    /// Go: the `fP` and `fPO` temporary files, held in memory here. See the file header.
    private var postingsBuf: [UInt8] = []
    private var postingsOffsetBuf: [UInt8] = []
    private var postingsOffsetCount = 0
    private var postingsStart: UInt64 = 0
    private var lastSeries: [(name: String, value: String)] = []
    private var lastSeriesRef: UInt64 = 0
    private var lastChunkRef: UInt64 = 0

    private var pos: UInt64 { UInt64(f.position) }

    public init(fs: any PromFS, path: String) throws {
        self.fs = fs
        self.path = path
        // Go: `os.MkdirAll(filepath.Dir(fn))` then creates the file.
        let dir = path.split(separator: "/").dropLast().joined(separator: "/")
        if !dir.isEmpty {
            try fs.createDirectory(dir)
        }
        self.f = try fs.createFile(path)
        try writeMeta()
    }

    /// Go: `writeMeta` — the magic and the format version, and nothing else.
    private func writeMeta() throws {
        var buf: [UInt8] = []
        buf.append(UInt8(truncatingIfNeeded: magicIndex >> 24))
        buf.append(UInt8(truncatingIfNeeded: magicIndex >> 16))
        buf.append(UInt8(truncatingIfNeeded: magicIndex >> 8))
        buf.append(UInt8(truncatingIfNeeded: magicIndex))
        buf.append(UInt8(indexFormatV2))
        try f.append(buf)
    }

    /// Go: `ensureStage` — the ladder. Recurses to fill a gap, rejects a move backwards.
    private func ensureStage(_ s: IndexWriterStage) throws {
        if stage == s { return }
        if stage.rawValue < s.rawValue - 1 {
            try ensureStage(IndexWriterStage(rawValue: s.rawValue - 1)!)
        }
        if stage > s {
            throw IndexWriteError.invalidStage(
                want: s.description, current: stage.description)
        }
        switch s {
        case .symbols:
            toc.symbols = pos
            try startSymbols()
        case .series:
            try finishSymbols()
            toc.series = pos
        case .done:
            toc.labelIndices = pos
            // The postings depend on the series section being complete, which is why this is the `done`
            // stage's work rather than `Close`'s.
            try writePostingsToBuffers()
            toc.postings = pos
            try writePostings()
            toc.labelIndicesTable = pos
            toc.postingsTable = pos
            try writePostingsOffsetTable()
            try writeTOC()
        case .none:
            break
        }
        stage = s
    }

    /// Go: `startSymbols` — eight bytes of ASCII placeholder, `"alenblen"`.
    private func startSymbols() throws {
        try f.append(Array("alenblen".utf8))
    }

    /// Go: `AddSymbol`. Symbols must arrive in strictly increasing Go byte order.
    public func addSymbol(_ sym: String) throws {
        try ensureStage(.symbols)
        if numSymbols != 0 && !goStringLess(lastSymbol, sym) {
            throw IndexWriteError.symbolOutOfOrder(sym)
        }
        lastSymbol = sym
        let bytes = Array(sym.utf8)
        symbolCache[bytes] = UInt32(numSymbols)
        ordinalToSymbol[UInt32(numSymbols)] = bytes
        numSymbols += 1
        var buf: [UInt8] = []
        GoVarint.putUvarint(&buf, UInt64(bytes.count))
        buf.append(contentsOf: bytes)
        try f.append(buf)
    }

    /// Go: `finishSymbols` — patch the length and count, then append and patch the hash.
    ///
    /// The length is `pos - toc.Symbols - 4`: it excludes its own four bytes but includes the count and the
    /// trailing hash, which is what `NewDecbufAt` expects.
    private func finishSymbols() throws {
        let symbolTableSize = pos - toc.symbols - 4
        if symbolTableSize > UInt64(UInt32.max) {
            throw IndexWriteError.symbolTableTooLarge(symbolTableSize)
        }
        var buf: [UInt8] = []
        appendBE32(&buf, UInt32(truncatingIfNeeded: symbolTableSize))
        appendBE32(&buf, UInt32(numSymbols))
        try f.write(buf, at: Int(toc.symbols))

        let hashPos = pos
        // Go writes the literal "hash" as a placeholder, then patches it once the contents are readable.
        try f.append(Array("hash".utf8))
        try f.flush()

        // Go mmaps the file to hash the section it just wrote; ADR-15 declines mmap, so the port reads it.
        // The hashed range is `[toc.Symbols+4, hashPos)` — from AFTER the length, through the count and
        // every symbol, stopping before the hash itself.
        let r = try fs.openForReading(path)
        let hashed = try r.read(
            offset: Int(toc.symbols) + 4, length: Int(hashPos) - (Int(toc.symbols) + 4))
        try r.close()
        var hbuf: [UInt8] = []
        appendBE32(&hbuf, CRC32C.checksum(hashed))
        try f.write(hbuf, at: Int(hashPos))
    }

    /// Go: `AddSeries`.
    ///
    /// The validation order is observable — see the file header — and the padding happens BEFORE the
    /// length prefix, which is what makes a series ID the position divided by 16.
    public func addSeries(
        ref: UInt64, labels: [(name: String, value: String)],
        chunks: [(minTime: Int64, maxTime: Int64, ref: UInt64)] = []
    ) throws {
        try ensureStage(.series)

        if !labelsGreater(labels, lastSeries) {
            throw IndexWriteError.outOfOrderSeries(
                labels: labelsString(labels), last: labelsString(lastSeries))
        }
        if ref < lastSeriesRef && !lastSeries.isEmpty {
            throw IndexWriteError.seriesRefTooLarge(ref)
        }

        var runningChunkRef = lastChunkRef
        var lastMaxT: Int64 = 0
        for (ix, c) in chunks.enumerated() {
            if c.ref < runningChunkRef {
                throw IndexWriteError.unsortedChunkReference(c.ref, previous: runningChunkRef)
            }
            runningChunkRef = c.ref
            if ix > 0 && c.minTime <= lastMaxT {
                throw IndexWriteError.chunkMinTNotHigher(minT: c.minTime, previousMaxT: lastMaxT)
            }
            if c.maxTime < c.minTime {
                throw IndexWriteError.chunkMaxTLessThanMinT(maxT: c.maxTime, minT: c.minTime)
            }
            lastMaxT = c.maxTime
        }

        // Padding first, so the record starts on a 16-byte boundary.
        try f.addPadding(to: seriesByteAlign)
        if pos % UInt64(seriesByteAlign) != 0 {
            throw IndexWriteError.seriesNotAligned(pos)
        }

        var payload: [UInt8] = []
        GoVarint.putUvarint(&payload, UInt64(labels.count))
        for l in labels {
            guard let nameIndex = symbolCache[Array(l.name.utf8)] else {
                throw IndexWriteError.symbolEntryMissing(l.name)
            }
            labelNameUses[Array(l.name.utf8), default: 0] += 1
            GoVarint.putUvarint(&payload, UInt64(nameIndex))
            guard let valueIndex = symbolCache[Array(l.value.utf8)] else {
                throw IndexWriteError.symbolEntryMissing(l.value)
            }
            GoVarint.putUvarint(&payload, UInt64(valueIndex))
        }

        GoVarint.putUvarint(&payload, UInt64(chunks.count))
        if let first = chunks.first {
            GoVarint.putVarint(&payload, first.minTime)
            GoVarint.putUvarint(&payload, UInt64(first.maxTime - first.minTime))
            GoVarint.putUvarint(&payload, first.ref)
            var t0 = first.maxTime
            var ref0 = Int64(bitPattern: first.ref)
            for c in chunks.dropFirst() {
                GoVarint.putUvarint(&payload, UInt64(c.minTime - t0))
                GoVarint.putUvarint(&payload, UInt64(c.maxTime - c.minTime))
                t0 = c.maxTime
                GoVarint.putVarint(&payload, Int64(bitPattern: c.ref) - ref0)
                ref0 = Int64(bitPattern: c.ref)
            }
        }

        // The length prefix is a UVARINT here, unlike the symbol table's BE32.
        var lenBuf: [UInt8] = []
        GoVarint.putUvarint(&lenBuf, UInt64(payload.count))
        var withHash = payload
        appendBE32(&withHash, CRC32C.checksum(payload))

        try f.append(lenBuf)
        try f.append(withHash)

        lastSeries = labels
        lastSeriesRef = ref
        lastChunkRef = runningChunkRef
    }

    /// Go: `writePosting` — one postings list into `fP`, and its offset-table entry into `fPO`.
    ///
    /// The list is 4-byte aligned "for more efficient postings list scans", and the offset recorded is
    /// `fP`'s position BEFORE the padding is... no: after it, because `AddPadding` runs first and `fP.pos`
    /// is read afterwards. An off-by-the-padding here is invisible until a reader lands mid-list.
    private func writePosting(_ name: String, _ value: String, _ offsets: [UInt32]) throws {
        // Align to 4 bytes.
        let rem = postingsBuf.count % 4
        if rem != 0 {
            postingsBuf.append(contentsOf: [UInt8](repeating: 0, count: 4 - rem))
        }

        // The offset-table entry, whose offset is relative to `fP`.
        var entry: [UInt8] = []
        GoVarint.putUvarint(&entry, 2)  // Key count, always 2.
        appendUvarintStr(&entry, name)
        appendUvarintStr(&entry, value)
        GoVarint.putUvarint(&entry, UInt64(postingsBuf.count))
        postingsOffsetBuf.append(contentsOf: entry)
        postingsOffsetCount += 1

        // Go: `EncodePostingsRaw` — a BE32 count then that many BE32 offsets.
        var payload: [UInt8] = []
        appendBE32(&payload, UInt32(offsets.count))
        for off in offsets {
            appendBE32(&payload, off)
        }
        var framed: [UInt8] = []
        appendBE32(&framed, UInt32(payload.count))
        framed.append(contentsOf: payload)
        appendBE32(&framed, CRC32C.checksum(payload))
        postingsBuf.append(contentsOf: framed)
    }

    /// Go: `writePostingsToTmpFiles` — re-read the series section and collect the postings.
    ///
    /// The batching by `maxPostings` is omitted: it bounds memory by processing label names in groups, and
    /// the result is identical either way because each name's postings are written independently. The port
    /// notes it rather than reproducing it, since the *output* is what the corpus pins.
    private func writePostingsToBuffers() throws {
        try f.flush()
        let r = try fs.openForReading(path)
        let all = try r.read(offset: 0, length: r.size)
        try r.close()

        // Walk the series section: every record is 16-byte aligned, prefixed with a uvarint length, and
        // followed by a 4-byte CRC.
        var seriesOrdinals: [UInt32] = []
        var perName: [[UInt8]: [[UInt8]: [UInt32]]] = [:]
        var p = Int(toc.series)
        let end = Int(toc.labelIndices)
        while p < end {
            // Go: `ConsumePadding` — zero bytes until the next record.
            while p < end && all[p] == 0 { p += 1 }
            if p >= end { break }
            let startPos = p
            if startPos % seriesByteAlign != 0 {
                throw IndexWriteError.seriesNotAligned(UInt64(startPos))
            }
            let ordinal = UInt32(startPos / seriesByteAlign)
            seriesOrdinals.append(ordinal)

            let (recLen, lenWidth) = GoVarint.uvarint(all, p)
            p += lenWidth
            let payloadStart = p

            // The labels, so each (name, value) learns this series.
            var q = p
            let (numLabels, nlW) = GoVarint.uvarint(all, q)
            q += nlW
            for _ in 0..<Int(numLabels) {
                let (lno, w1) = GoVarint.uvarint(all, q)
                q += w1
                let (lvo, w2) = GoVarint.uvarint(all, q)
                q += w2
                guard let name = ordinalToSymbol[UInt32(truncatingIfNeeded: lno)],
                    let value = ordinalToSymbol[UInt32(truncatingIfNeeded: lvo)]
                else {
                    continue
                }
                perName[name, default: [:]][value, default: []].append(ordinal)
            }

            p = payloadStart + Int(recLen) + 4  // Skip the payload and its CRC.
        }

        // The ALL-postings list first, under `("", "")`.
        try writePosting("", "", seriesOrdinals)

        // Then each label name in Go byte order, and within it each value in SYMBOL-ORDINAL order —
        // upstream's comment: "Symbol numbers are in order, so the strings will also be in order."
        let names = perName.keys.sorted { $0.lexicographicallyPrecedes($1) }
        for name in names {
            guard let values = perName[name] else { continue }
            let sortedValues = values.keys.sorted { a, b in
                (symbolCache[a] ?? 0) < (symbolCache[b] ?? 0)
            }
            for v in sortedValues {
                try writePosting(
                    String(decoding: name, as: UTF8.self), String(decoding: v, as: UTF8.self),
                    values[v] ?? [])
            }
        }
    }

    /// Go: `writePostings` — 4-byte padding, then copy `fP` in, recording where it landed.
    private func writePostings() throws {
        try f.addPadding(to: 4)
        postingsStart = pos
        try f.append(postingsBuf)
    }

    /// Go: `writePostingsOffsetTable` — copy `fPO` in, **adding `postingsStart` to every offset**.
    private func writePostingsOffsetTable() throws {
        let startPos = pos
        // Go writes the literal "alen" as a placeholder for the length.
        try f.append(Array("alen".utf8))

        var hashed: [UInt8] = []
        var out: [UInt8] = []
        appendBE32(&out, UInt32(postingsOffsetCount))
        hashed.append(contentsOf: out)

        var p = 0
        var remaining = postingsOffsetCount
        while remaining > 0 && p < postingsOffsetBuf.count {
            var entry: [UInt8] = []
            let (keyCount, w0) = GoVarint.uvarint(postingsOffsetBuf, p)
            p += w0
            GoVarint.putUvarint(&entry, keyCount)
            for _ in 0..<2 {
                let (l, w) = GoVarint.uvarint(postingsOffsetBuf, p)
                p += w
                GoVarint.putUvarint(&entry, l)
                entry.append(contentsOf: postingsOffsetBuf[p..<(p + Int(l))])
                p += Int(l)
            }
            let (off, w3) = GoVarint.uvarint(postingsOffsetBuf, p)
            p += w3
            // THE ADJUSTMENT. Offsets in `fPO` are relative to `fP`.
            GoVarint.putUvarint(&entry, off + postingsStart)
            out.append(contentsOf: entry)
            hashed.append(contentsOf: entry)
            remaining -= 1
        }
        // ALL of `out`, count included. Go writes `"alen"` (the length placeholder) and THEN the BE32
        // count — two separate four-byte fields — and dropping the count made every file exactly four
        // bytes short, with the divergence appearing at the offset table rather than where the mistake was.
        try f.append(out)

        // Go: `writeLengthAndHash` — patch the length, then append the CRC over count-plus-entries.
        let l = pos - startPos - 4
        var lenBuf: [UInt8] = []
        appendBE32(&lenBuf, UInt32(truncatingIfNeeded: l))
        try f.write(lenBuf, at: Int(startPos))
        var crcBuf: [UInt8] = []
        appendBE32(&crcBuf, CRC32C.checksum(hashed))
        try f.append(crcBuf)
    }

    /// The inverse of `symbolCache`, for resolving a series record's ordinals while re-reading it.
    private var ordinalToSymbol: [UInt32: [UInt8]] = [:]

    /// Go: `writeTOC` — six big-endian offsets and a hash over them.
    private func writeTOC() throws {
        var buf: [UInt8] = []
        appendBE64(&buf, toc.symbols)
        appendBE64(&buf, toc.series)
        appendBE64(&buf, toc.labelIndices)
        appendBE64(&buf, toc.labelIndicesTable)
        appendBE64(&buf, toc.postings)
        appendBE64(&buf, toc.postingsTable)
        appendBE32(&buf, CRC32C.checksum(buf))
        try f.append(buf)
    }

    /// Go: `Close` — advances to `idxStageDone`, which is what writes the TOC.
    public func close() throws {
        try ensureStage(.done)
        try f.flush()
        try f.sync()
        try f.close()
    }
}

private func appendUvarintStr(_ out: inout [UInt8], _ s: String) {
    let bytes = Array(s.utf8)
    GoVarint.putUvarint(&out, UInt64(bytes.count))
    out.append(contentsOf: bytes)
}

private func appendBE32(_ out: inout [UInt8], _ v: UInt32) {
    out.append(UInt8(truncatingIfNeeded: v >> 24))
    out.append(UInt8(truncatingIfNeeded: v >> 16))
    out.append(UInt8(truncatingIfNeeded: v >> 8))
    out.append(UInt8(truncatingIfNeeded: v))
}

private func appendBE64(_ out: inout [UInt8], _ v: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
        out.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
    }
}

/// Go: `labels.Compare(a, b) > 0`, which is name-then-value byte comparison, shortest-first on a prefix.
func labelsGreater(_ a: [(name: String, value: String)], _ b: [(name: String, value: String)]) -> Bool
{
    for i in 0..<min(a.count, b.count) {
        if a[i].name != b[i].name {
            return goStringLess(b[i].name, a[i].name)
        }
        if a[i].value != b[i].value {
            return goStringLess(b[i].value, a[i].value)
        }
    }
    return a.count > b.count
}

/// Go's `%q` on a `labels.Labels`, which renders as `{n="v", ...}` and is then quoted.
func labelsString(_ ls: [(name: String, value: String)]) -> String {
    "{" + ls.map { "\($0.name)=\"\($0.value)\"" }.joined(separator: ", ") + "}"
}
