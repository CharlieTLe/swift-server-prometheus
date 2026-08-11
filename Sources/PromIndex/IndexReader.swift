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
