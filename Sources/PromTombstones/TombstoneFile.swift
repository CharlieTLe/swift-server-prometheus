//===----------------------------------------------------------------------===//
// Ported from tsdb/tombstones/tombstones.go @ v3.13.2 — the FILE CODEC.
//
// The half PORTING.md exception 16 left out. `DeletionIntervals.swift` has the interval arithmetic and
// `MemTombstones.swift` the in-memory reader; this is the on-disk `tombstones` file a block carries, which is
// what `compact.go:739` writes for every block it produces and what `block.go:370` reads back on `OpenBlock`.
//
// ## The layout, and what the checksum does NOT cover
//
//     [BE32 magic 0x0130BA30][version byte 0x01][ ref, mint, maxt … ][BE32 CRC-32C]
//                            └──────────────────── Encode() ───────┘
//                                                 └── the CRC's input ──┘
//
// Three separate framings, and the boundaries between them are where the interesting behaviour lives:
//
//   * the **magic** is written by `WriteFile` and read by `ReadTombstones`; `Encode`/`Decode` never see it;
//   * the **version byte** is written by `Encode` and checked by `Decode` — and it is **excluded from the
//     checksum** at both ends (`tombstones.go:113` and `:210` both slice `[tombstoneFormatVersionSize:]`,
//     with the same "we do this for compatibility" comment on the write side). So a file whose version byte
//     has been corrupted still passes its CRC and is rejected by the format check instead. PORTING.md quirk 211.
//   * the **CRC** is the last four bytes and is taken off the buffer *before* the magic is read, which is why
//     a file shorter than nine bytes reports the errors it does. See below.
//
// ## The body is a flat triple stream, not a per-series record
//
// `Encode` writes `[uvarint ref][varint mint][varint maxt]` **once per interval**, so a series with three
// intervals occupies three triples and its ref is repeated. There is no count, no index and no terminator:
// `Decode` reads until the buffer is empty, which is why a body that ends mid-triple is `invalid size` and
// why one truncated byte at the end is indistinguishable from a short final entry. Same asymmetry the WAL's
// Tombstones record has (`Stone.swift`), and for the same reason — `AddInterval` merges on the way back in,
// so the round trip is the identity on the *interval set* rather than on the entry list.
//
// ## An 8-byte file PANICS upstream (quirk 210)
//
// `ReadTombstones` guards `len(b) < 5` and then does `hash.Write(d.Get()[tombstoneFormatVersionSize:])` with
// no guard at all. After `d.Be32()` has taken the magic, `d.Get()` is `len(b) - 8` bytes — so a file of
// exactly eight bytes leaves it EMPTY and `[1:]` is out of range, because Go's slice rule needs
// `low <= high` and `high` defaults to `len`, which is 0. Upstream panics with
// `runtime error: slice bounds out of range [1:0]` and takes the process with it; `Block.OpenBlock` has no
// recover. It is reachable — a torn write or a truncated copy is all it takes — so the port RAISES it with
// Go's own text rather than trapping (HANDOFF §5's `extendFloats` lesson: reachability decides which
// treatment a panic gets). `Fixtures/tombstones/corrupt.jsonl` pins it from both directions.
//
// ## What the short-file arms actually answer
//
//   len(b) == 0…4   `tombstones header: invalid size`   — the explicit guard
//   len(b) == 5…7   `invalid magic number 0`            — `Be32` under-runs, latches the error and returns 0,
//                                                         and 0 is not the magic, so the magic arm answers first
//   len(b) == 8     the panic above
//   len(b) == 9     the smallest valid file: magic, `0x01`, no entries, CRC-32C of nothing (which is 0)
//
// The 5…7 arm is why the `if d.Err() != nil` check further down is **dead code**, and so is `Decode`'s: by
// the time either runs, every read that could have failed has already been answered by a more specific arm.
// Both are ported anyway (quirk 213) because deleting them would make the next reader wonder.
//
// ## No rename, so the temporary file is COPIED
//
// Upstream writes `tombstones.tmp` and `fileutil.Replace`s it onto `tombstones`. `PromFS` has no rename
// (ADR-15), so the port copies and then lets the deferred remove delete the temporary — the same divergence
// `checkpoint.go` has, recorded once in PORTING.md exception 25 and named there for both sites.
//===----------------------------------------------------------------------===//

public import PromFS

// `PromEncoding` is PUBLIC rather than internal because `TombstoneFileError.decode` carries an
// `EncodingError` — the sticky `Decbuf` error, surfaced verbatim as `d.Err()` is.
public import PromEncoding

internal import GoCompat
internal import PromHash
internal import PromStorage

/// Go: `TombstonesFilename`.
public let tombstonesFilename = "tombstones"

/// Go: `MagicTombstone` — "4 bytes at the head of a tombstone file".
public let magicTombstone: UInt32 = 0x0130_BA30

/// Go: `tombstoneFormatV1`.
public let tombstoneFormatV1: UInt8 = 1
/// Go: `tombstoneFormatVersionSize`.
public let tombstoneFormatVersionSize = 1
/// Go: `tombstonesHeaderSize` — magic plus the version byte, and the ONLY length the reader checks.
public let tombstonesHeaderSize = 5
/// Go: `tombstonesCRCSize`.
public let tombstonesCRCSize = 4

/// Not upstream's constant — Go spells `path + ".tmp"` inline at `tombstones.go:78`.
public let tombstonesTempFileSuffix = ".tmp"

/// The tombstone file's rejection paths, each reproducing Go's message byte for byte.
///
/// `%x` in Go is lowercase hex with no padding and no `0x`, so `String(_:radix:)` is the exact match and
/// `String(format:)` would not be (it pads to the argument width for `%08x` and differs on zero). ADR-4's
/// rule about float formatting has the same shape here.
public enum TombstoneFileError: Error, CustomStringConvertible, Equatable {
    /// Go: `fmt.Errorf("tombstones header: %w", encoding.ErrInvalidSize)`.
    case header(EncodingError)
    /// Go: `fmt.Errorf("invalid magic number %x", mg)`.
    case invalidMagicNumber(UInt32)
    /// Go: `errors.New("checksum did not match")`.
    case checksumDidNotMatch
    /// Go: `fmt.Errorf("invalid tombstone format %x", flag)`.
    case invalidTombstoneFormat(UInt8)
    /// A `Decbuf` error surfaced verbatim, as `d.Err()` is.
    case decode(EncodingError)
    /// Go: `fmt.Errorf("encoding tombstones: %w", err)`.
    case encodingTombstones(String)
    /// Go: `fmt.Errorf("writing tombstones: %w", err)`.
    case writingTombstones(String)
    /// **Not an error upstream — a PANIC.** See the file header, quirk 210.
    case sliceBoundsOutOfRange(low: Int, high: Int)

    public var description: String {
        switch self {
        case .header(let e): return "tombstones header: \(e)"
        case .invalidMagicNumber(let mg): return "invalid magic number \(String(mg, radix: 16))"
        case .checksumDidNotMatch: return "checksum did not match"
        case .invalidTombstoneFormat(let f):
            return "invalid tombstone format \(String(f, radix: 16))"
        case .decode(let e): return "\(e)"
        case .encodingTombstones(let e): return "encoding tombstones: \(e)"
        case .writingTombstones(let e): return "writing tombstones: \(e)"
        case .sliceBoundsOutOfRange(let lo, let hi):
            return "runtime error: slice bounds out of range [\(lo):\(hi)]"
        }
    }
}

// MARK: - Encode

/// Go: `Encode` — "encodes the tombstones from the reader. It does not attach any magic number or checksum."
///
/// **Returns the partial buffer alongside the error**, exactly as Go's `return buf.Get(), err` does. A
/// `throws` signature would be the idiomatic Swift and would discard bytes that upstream hands back; the one
/// upstream caller that can fail (`head_wal.go:1342`, the chunk snapshot) discards them too, so the
/// difference is unobservable *today* — which is precisely the kind of "no caller can reach this" reasoning
/// HANDOFF §3 says becomes a time bomb. `Appender.appendCTZeroSample` has the same shape for the same reason.
public func encodeTombstones(_ tr: any TombstoneReader) -> (bytes: [UInt8], error: (any Error)?) {
    var buf = Encbuf()
    buf.putByte(tombstoneFormatV1)
    var thrown: (any Error)?
    do {
        try tr.iter { ref, ivs in
            for iv in ivs {
                buf.putUvarint64(ref.rawValue)
                buf.putVarint64(iv.mint)
                buf.putVarint64(iv.maxt)
            }
        }
    } catch {
        thrown = error
    }
    return (buf.bytes, thrown)
}

/// Go: `Decode` — "decodes the tombstones from the bytes which was encoded using the Encode method."
///
/// Returns `MemTombstones` where Go's static type is the `Reader` interface. Its dynamic type is always
/// `*MemTombstones` (there is one `return` and it builds one), so this is strictly more information; the
/// existential would only cost call sites a downcast.
public func decodeTombstones(_ b: [UInt8]) throws -> MemTombstones {
    let owner = ArrayByteSliceOwner(b)
    return try withExtendedLifetime(owner) {
        var d = Decbuf(owner.bytes)
        // tombstones.go:160 — the format check comes BEFORE the error check, so an EMPTY buffer answers
        // `invalid tombstone format 0` rather than `invalid size`: `Byte()` latches the error and returns 0.
        let flag = d.byte()
        if flag != tombstoneFormatV1 {
            throw TombstoneFileError.invalidTombstoneFormat(flag)
        }
        // tombstones.go:164 — dead, and see the file header. The only read above is the one whose failure
        // the line before already turned into a format error.
        if let e = d.err {
            throw TombstoneFileError.decode(e)
        }

        let stonesMap = MemTombstones()
        while d.count > 0 {
            let k = SeriesRef(rawValue: d.uvarint64())
            let mint = d.varint64()
            let maxt = d.varint64()
            // Checked inside the loop, so a body ending mid-triple is `invalid size` and the entries before
            // it are discarded with the whole reader. A latched `Decbuf` does not consume, so `d.count` is
            // still positive here and the loop would otherwise spin.
            if let e = d.err {
                throw TombstoneFileError.decode(e)
            }
            stonesMap.addInterval(k, DeletionInterval(mint: mint, maxt: maxt))
        }
        return stonesMap
    }
}

// MARK: - The file

/// Go: `WriteFile` — writes `dir/tombstones` and returns the number of bytes written.
///
/// The `*slog.Logger` parameter is dropped, as everywhere in the port: upstream uses it only to report a
/// failed `Close` or `RemoveAll` of the temporary file, neither of which changes the result.
@discardableResult
public func writeTombstoneFile(
    _ fs: any PromFS, _ dir: String, _ tr: any TombstoneReader
) throws -> Int64 {
    let path = "\(dir)/\(tombstonesFilename)"
    let tmp = path + tombstonesTempFileSuffix
    var hash = CRC32C()
    var size = 0

    let f = try fs.createFile(tmp)
    var closed = false
    defer {
        // Go's deferred closure, in the same order: close the handle if it is still open, then remove the
        // temporary file whatever happened. After a successful copy the removal is the *cleanup* upstream
        // gets for free from the rename.
        if !closed { try? f.close() }
        try? fs.remove(tmp)
    }

    // tombstones.go:97 — the buffer is sized for three varints and then used for four bytes. Reproduced
    // because the reservation is the only thing the size expresses; nothing reads it back.
    var buf = Encbuf(reservingCapacity: 3 * 10)
    buf.putBE32(magicTombstone)
    try f.append(buf.bytes)
    size += buf.count

    let (bytes, encodeError) = encodeTombstones(tr)
    if let encodeError {
        throw TombstoneFileError.encodingTombstones("\(encodeError)")
    }

    // "Ignore first byte which is the format type. We do this for compatibility." `bytes` is never empty —
    // `Encode` writes the version byte before it can fail — so the slice upstream does not guard is safe
    // here for a reason, unlike the one in `readTombstones`.
    hash.update(bytes[tombstoneFormatVersionSize...])

    do {
        try f.append(bytes)
    } catch {
        throw TombstoneFileError.writingTombstones("\(error)")
    }
    size += bytes.count

    var sum: [UInt8] = []
    GoBigEndian.append(&sum, hash.final())
    try f.append(sum)
    size += sum.count

    // Upstream: `f.Sync()` then `f.Close()`. `flush` has no upstream counterpart — a raw `*os.File` is
    // unbuffered — but `RealFS` buffers, so it is the equivalent of the write actually having happened.
    try f.flush()
    try f.sync()
    try f.close()
    closed = true

    // Go: `fileutil.Replace(tmp, path)`. PORTING.md exception 25 — no rename in `PromFS`, so copy.
    try copyTombstoneFile(fs, from: tmp, to: path)
    return Int64(size)
}

private func copyTombstoneFile(_ fs: any PromFS, from: String, to: String) throws {
    let r = try fs.openForReading(from)
    let contents = try r.read(offset: 0, length: r.size)
    try r.close()
    let w = try fs.createFile(to)
    try w.append(contents)
    try w.flush()
    try w.sync()
    try w.close()
}

/// Go: `ReadTombstones` — the reader, and the file's size in bytes.
///
/// A MISSING file is not an error: upstream's `os.IsNotExist` arm answers an empty `MemTombstones` and a
/// size of zero, which is what makes a block with no deletions indistinguishable from one whose tombstone
/// file was never written. `compact.go` writes an empty file anyway; `OpenBlock` does not require it.
public func readTombstones(_ fs: any PromFS, _ dir: String) throws -> (MemTombstones, Int64) {
    let path = "\(dir)/\(tombstonesFilename)"
    let b: [UInt8]
    do {
        let h = try fs.openForReading(path)
        defer { try? h.close() }
        b = try h.read(offset: 0, length: h.size)
    } catch let e as FSError {
        if case .notFound = e {
            return (MemTombstones(), 0)
        }
        throw e
    }

    if b.count < tombstonesHeaderSize {
        throw TombstoneFileError.header(.invalidSize)
    }

    let owner = ArrayByteSliceOwner(b)
    return try withExtendedLifetime(owner) {
        // tombstones.go:202 — the CRC is taken off the END before anything is read off the FRONT, so every
        // arm below is looking at a buffer four bytes shorter than the file.
        var d = Decbuf(owner.bytes.range(0, b.count - tombstonesCRCSize))
        let mg = d.be32()
        if mg != magicTombstone {
            // For a 5-to-7-byte file `Be32` under-runs and returns 0, so this arm — not the size check —
            // is what answers. See the file header.
            throw TombstoneFileError.invalidMagicNumber(mg)
        }

        // tombstones.go:210 — `d.Get()[tombstoneFormatVersionSize:]`, unguarded, PANICS when the remainder
        // is empty. Quirk 210.
        if d.count < tombstoneFormatVersionSize {
            throw TombstoneFileError.sliceBoundsOutOfRange(low: tombstoneFormatVersionSize, high: d.count)
        }
        var hash = CRC32C()
        hash.update(Array(d.b.range(tombstoneFormatVersionSize, d.count).rawBuffer))

        let stored = owner.bytes.loadBE32(at: b.count - tombstonesCRCSize)
        if stored != hash.final() {
            throw TombstoneFileError.checksumDidNotMatch
        }

        // tombstones.go:217 — dead for the same reason `Decode`'s is; see the file header.
        if let e = d.err {
            throw TombstoneFileError.decode(e)
        }

        let stonesMap = try decodeTombstones(Array(d.b.rawBuffer))
        return (stonesMap, Int64(b.count))
    }
}
