//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/xor.go @ v3.13.2 — Gorilla-style XOR encoding for float samples.
// Originally Damian Gryski's go-tsz; the upstream file carries his BSD licence notice and so does
// this port's origin note.
//
// **This is the slice that makes `Bstream.swift` verifiable.** `bstream` is unexported upstream, so the
// oracle could not reach it and `Bstream.swift` landed unpinned on a branch (HANDOFF §5d).
// `NewXORChunk`, `Appender`, `Bytes()` and `Iterator` *are* exported, and an appended sample sequence
// has exactly one correct byte string — so the two files are one unit of verification even though they
// are two units of code. Every bit `Bstream` writes is checked here, byte for byte.
//
// ## The two header bytes are a big-endian sample COUNT, rewritten on every append
//
// A chunk's first two bytes are `uint16` sample count, and `Append` bumps them in place after writing
// the sample. So the count is not derived from the stream — it is stored, and everything downstream
// (`NumSamples`, the iterator's `numTotal`) reads those two bytes rather than parsing.
//
// ## Getting an Appender for a non-empty chunk REPLAYS the whole chunk
//
// The encoder is stateful — it needs the last timestamp, the last value, the last delta, and the
// current leading/trailing zero counts — and none of that is stored. So `Appender()` iterates to the
// end and lifts the state off the iterator. That is why the appender and the iterator have to agree
// bit for bit: the appender is *defined* by the decoder's final state.
//
// ## The delta-of-delta buckets, and `bitRange`'s asymmetry
//
// A timestamp's delta-of-delta is written in one of five buckets, chosen by `bitRange(dod, n)`:
//
//     dod == 0        -> a single `0` bit
//     fits in 14 bits -> `0b10` then 14 bits, written as TWO BYTES rather than as bit writes
//     fits in 17 bits -> `0b110` then 17 bits
//     fits in 20 bits -> `0b1110` then 20 bits
//     otherwise       -> `0b1111` then the full 64 bits
//
// `bitRange` is **not symmetric**: `-((1<<(n-1))-1) <= x && x <= 1<<(n-1)`. The upper bound is
// `1<<(n-1)`, the lower is `-((1<<(n-1))-1)` — so for 14 bits the range is `-8191...8192`, one wider at
// the top than a two's-complement reading would give. Reproduced exactly; a symmetric version picks a
// different bucket at the boundary and writes a different byte string.
//
// The 14-bit case uses `writeByte` twice where the others use `writeBits`. That is observably the same
// bit sequence — but it is upstream's shape and the comment there explains the packing, so it stays.
//
// ## Leading zeros are clamped to 31, and 0 significant bits means 64
//
// `newLeading >= 32` becomes 31, because the leading count is written in 5 bits. And `sigbits` is
// written in 6 bits, so 64 does not fit — it is written as 0 and read back as 64, which is safe only
// because a delta of 0 is handled by the earlier `writeBit(zero)` branch and so 0 significant bits can
// never legitimately occur.
//
// ## `readBitFast` then `readBit` is not redundant
//
// Every read in the decoder tries the fast path, and on error falls back to the slow one. The fast
// path fails when the internal buffer does not hold enough bits; the slow path refills it. A port that
// kept only one of the two either loses the fast path's speed or its correctness at a buffer boundary.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat

/// Go: `chunkHeaderSize`, `chunkAllocationSize`, `chunkCompactCapacityThreshold`.
let chunkHeaderSize = 2
let chunkAllocationSize = 128
let chunkCompactCapacityThreshold = 32

/// Go: `XORChunk` — XOR-encoded float samples.
///
/// A `final class` rather than a struct: upstream passes `*XORChunk` and the appender holds `*bstream`
/// pointing into it, so an append through the appender must be visible through the chunk. Value
/// semantics would silently give the appender its own copy and every `Bytes()` would read the empty
/// header.
public final class XORChunk {
    var b: Bstream

    /// Go: `NewXORChunk` — two header bytes, and capacity for 128.
    public init() {
        self.b = Bstream(stream: [UInt8](repeating: 0, count: chunkHeaderSize), count: 0)
    }

    /// Go: `XORChunk.Reset`.
    public func reset(_ stream: [UInt8]) {
        b.reset(stream)
    }

    /// Go: `Encoding`.
    public var encoding: Encoding { .xor }

    /// Go: `Bytes`.
    public var bytes: [UInt8] { b.bytes }

    /// Go: `NumSamples` — the two header bytes, big-endian.
    public var numSamples: Int {
        Int(GoBigEndian.uint16(bytes, 0))
    }

    /// Go: `Compact` — shrink the backing array when it is over-allocated.
    ///
    /// Swift `Array` has no `cap` the way a Go slice does, and `reserveCapacity` is advisory, so this
    /// is a no-op the port keeps for the call-site symmetry PORTING.md §4 asks for. Nothing observes
    /// capacity: `Bytes()` returns the used prefix in both languages.
    public func compact() {}

    /// Go: `XORChunk.Appender`.
    ///
    /// For a non-empty chunk this REPLAYS the whole chunk to recover the encoder state — see the file
    /// header. `leading = 0xff` on an empty chunk is a sentinel meaning "no previous value", which
    /// `xorWrite` tests for.
    public func appender() throws -> XORAppender {
        if b.stream.count == chunkHeaderSize {
            // Avoid allocating an iterator when the chunk is empty.
            return XORAppender(chunk: self, t: Int64.min, leading: 0xff)
        }
        var it = iterator()
        while it.next() != .none {}
        if let err = it.err {
            throw err
        }
        return XORAppender(
            chunk: self, t: it.t, v: it.val, tDelta: it.tDelta, leading: it.leading,
            trailing: it.trailing)
    }

    /// Go: `XORChunk.iterator`.
    public func iterator() -> XORIterator {
        XORIterator(
            br: BstreamReader(Array(bytes[chunkHeaderSize...])),
            numTotal: GoBigEndian.uint16(bytes, 0))
    }
}

/// Go: `xorAppender`.
public final class XORAppender {
    /// Go holds `b *bstream`, a pointer into the chunk. The port holds the chunk and writes through
    /// it, which is the same aliasing with a name on it.
    private let chunk: XORChunk

    var t: Int64
    var v: Double
    var tDelta: UInt64
    var leading: UInt8
    var trailing: UInt8

    init(
        chunk: XORChunk, t: Int64, v: Double = 0, tDelta: UInt64 = 0, leading: UInt8 = 0,
        trailing: UInt8 = 0
    ) {
        self.chunk = chunk
        self.t = t
        self.v = v
        self.tDelta = tDelta
        self.leading = leading
        self.trailing = trailing
    }

    /// Go: `xorAppender.Append`. The first `int64` argument is the start timestamp, which XOR ignores.
    public func append(_ t: Int64, _ v: Double) {
        var tDelta: UInt64 = 0
        let num = GoBigEndian.uint16(chunk.b.stream, 0)
        switch num {
        case 0:
            // The first sample: a varint timestamp and the raw 64-bit value.
            // Go writes into a fixed 10-byte buffer and slices to the returned length;
            // `GoVarint.putVarint` **APPENDS** instead (its doc says so), so the buffer starts EMPTY
            // and all of it is written. Pre-sizing it to 10 and taking the first `n` bytes writes
            // zeros — and it is nearly invisible, because the varint of `0` is `0x00`, so the first
            // sample of every chunk still came out right and only the second was wrong.
            var buf: [UInt8] = []
            GoVarint.putVarint(&buf, t)
            for byt in buf {
                chunk.b.writeByte(byt)
            }
            chunk.b.writeBits(v.bitPattern, 64)
        case 1:
            // The second: an unsigned varint delta, then the XOR'd value.
            tDelta = UInt64(bitPattern: t &- self.t)
            var buf: [UInt8] = []
            GoVarint.putUvarint(&buf, tDelta)
            for byt in buf {
                chunk.b.writeByte(byt)
            }
            writeVDelta(v)
        case UInt16.max:
            preconditionFailure("chunk capacity exceeded")
        default:
            tDelta = UInt64(bitPattern: t &- self.t)
            let dod = Int64(bitPattern: tDelta &- self.tDelta)

            // Gorilla's resolution is seconds and Prometheus' is milliseconds, hence the larger
            // buckets. Upstream's TODO notes this jumps to large sizes for small deviations.
            if dod == 0 {
                chunk.b.writeBit(false)
            } else if bitRange(dod, 14) {
                // TWO BYTES, not bit writes: the size code and the top 6 bits of the dod share a byte.
                chunk.b.writeByte(0b10 << 6 | (UInt8(truncatingIfNeeded: dod >> 8) & (1 << 6 - 1)))
                chunk.b.writeByte(UInt8(truncatingIfNeeded: dod))
            } else if bitRange(dod, 17) {
                chunk.b.writeBits(0b110, 3)
                chunk.b.writeBits(UInt64(bitPattern: dod), 17)
            } else if bitRange(dod, 20) {
                chunk.b.writeBits(0b1110, 4)
                chunk.b.writeBits(UInt64(bitPattern: dod), 20)
            } else {
                chunk.b.writeBits(0b1111, 4)
                chunk.b.writeBits(UInt64(bitPattern: dod), 64)
            }
            writeVDelta(v)
        }

        self.t = t
        self.v = v
        chunk.b.putBigEndianUInt16(at: 0, num + 1)
        self.tDelta = tDelta
    }

    private func writeVDelta(_ v: Double) {
        xorWrite(&chunk.b, v, self.v, &leading, &trailing)
    }
}

/// Go: `bitRange` — whether `x` fits in `nbits`, **asymmetrically**. See the file header.
func bitRange(_ x: Int64, _ nbits: UInt8) -> Bool {
    -((1 << (Int64(nbits) - 1)) - 1) <= x && x <= 1 << (Int64(nbits) - 1)
}

/// Go: `xorIterator`.
public struct XORIterator {
    var br: BstreamReader
    let numTotal: UInt16
    public private(set) var numRead: UInt16 = 0

    public private(set) var t: Int64 = Int64.min
    public private(set) var val: Double = 0

    var leading: UInt8 = 0
    var trailing: UInt8 = 0
    var tDelta: UInt64 = 0
    public private(set) var err: (any Error)? = nil

    init(br: BstreamReader, numTotal: UInt16) {
        self.br = br
        self.numTotal = numTotal
    }

    /// Go: `xorIterator.Seek`. Note `it.numRead == 0` in the loop condition: a seek to a timestamp at
    /// or before the first sample still has to advance once, because `t` starts at `MinInt64`.
    public mutating func seek(_ target: Int64) -> ValueType {
        if err != nil { return .none }
        while target > t || numRead == 0 {
            if next() == .none { return .none }
        }
        return .float
    }

    /// Go: `At`.
    public var at: (Int64, Double) { (t, val) }

    /// Go: `xorIterator.Next`.
    public mutating func next() -> ValueType {
        if err != nil || numRead == numTotal {
            return .none
        }

        if numRead == 0 {
            do {
                let t = try readVarintFromBstream(&br)
                let v = try br.readBits(64)
                self.t = t
                self.val = Double(bitPattern: v)
            } catch {
                err = error
                return .none
            }
            numRead += 1
            return .float
        }
        if numRead == 1 {
            do {
                tDelta = try readUvarintFromBstream(&br)
            } catch {
                err = error
                return .none
            }
            t = t &+ Int64(bitPattern: tDelta)
            return readValue()
        }

        // The delta-of-delta's size code is a unary prefix of at most four bits.
        var d: UInt8 = 0
        for _ in 0..<4 {
            d <<= 1
            var bit: Bool
            do {
                bit = try br.readBitFast()
            } catch {
                do {
                    bit = try br.readBit()
                } catch {
                    err = error
                    return .none
                }
            }
            if !bit { break }
            d |= 1
        }
        var sz: UInt8 = 0
        var dod: Int64 = 0
        switch d {
        case 0b0:
            break  // dod == 0
        case 0b10:
            sz = 14
        case 0b110:
            sz = 17
        case 0b1110:
            sz = 20
        case 0b1111:
            // Not the fast path: upstream's comment says it is very unlikely to succeed for 64 bits.
            do {
                dod = Int64(bitPattern: try br.readBits(64))
            } catch {
                err = error
                return .none
            }
        default:
            break
        }

        if sz != 0 {
            var bits: UInt64
            do {
                bits = try br.readBitsFast(sz)
            } catch {
                do {
                    bits = try br.readBits(sz)
                } catch {
                    err = error
                    return .none
                }
            }
            // A negative dod comes back as a large unsigned value. Note the test is `>`, not `>=`:
            // the value `1 << (sz-1)` itself stays positive, which is `bitRange`'s asymmetric upper
            // bound read back out.
            if bits > (1 << (UInt64(sz) - 1)) {
                bits &-= 1 << UInt64(sz)
            }
            dod = Int64(bitPattern: bits)
        }

        tDelta = UInt64(bitPattern: Int64(bitPattern: tDelta) &+ dod)
        t = t &+ Int64(bitPattern: tDelta)
        return readValue()
    }

    private mutating func readValue() -> ValueType {
        do {
            try xorRead(&br, &val, &leading, &trailing)
        } catch {
            err = error
            return .none
        }
        numRead += 1
        return .float
    }
}

/// Go: `binary.ReadUvarint` over an `io.ByteReader`, which `bstreamReader` implements.
///
/// `GoVarint.uvarint` works on a buffer and returns a consumed length; the decoder needs the
/// byte-at-a-time form, because the varint sits in the middle of a bit stream and only the reader knows
/// where it ends. Errors match Go's: EOF from the reader propagates, and an overlong encoding is
/// `errOverflow`.
func readUvarintFromBstream(_ br: inout BstreamReader) throws -> UInt64 {
    var x: UInt64 = 0
    var s: UInt = 0
    var i = 0
    while true {
        let b = try br.readByte()
        if b < 0x80 {
            // Go: `if i == binary.MaxVarintLen64-1 && b > 1 { return 0, errOverflow }`.
            if i == GoVarint.maxVarintLen64 - 1 && b > 1 {
                throw VarintOverflow()
            }
            return x | UInt64(b) << s
        }
        x |= UInt64(b & 0x7F) << s
        s += 7
        i += 1
        if i == GoVarint.maxVarintLen64 {
            throw VarintOverflow()
        }
    }
}

/// Go: `binary.ReadVarint` — zig-zag over `ReadUvarint`.
func readVarintFromBstream(_ br: inout BstreamReader) throws -> Int64 {
    let ux = try readUvarintFromBstream(&br)
    var x = Int64(bitPattern: ux >> 1)
    if ux & 1 != 0 {
        x = ~x
    }
    return x
}

/// Go: `binary.errOverflow` — "binary: varint overflows a 64-bit integer".
public struct VarintOverflow: Error, CustomStringConvertible, Equatable, Sendable {
    public init() {}
    public var description: String { "binary: varint overflows a 64-bit integer" }
}

/// Go: `xorWrite` — one value against the previous one.
func xorWrite(
    _ b: inout Bstream, _ newValue: Double, _ currentValue: Double, _ leading: inout UInt8,
    _ trailing: inout UInt8
) {
    let delta = newValue.bitPattern ^ currentValue.bitPattern

    if delta == 0 {
        b.writeBit(false)
        return
    }
    b.writeBit(true)

    var newLeading = UInt8(delta.leadingZeroBitCount)
    let newTrailing = UInt8(delta.trailingZeroBitCount)

    // Clamped because the count is written in 5 bits.
    if newLeading >= 32 {
        newLeading = 31
    }

    if leading != 0xff && newLeading >= leading && newTrailing >= trailing {
        // The existing window still covers the delta, so reuse it.
        b.writeBit(false)
        b.writeBits(delta >> trailing, 64 - Int(leading) - Int(trailing))
        return
    }

    leading = newLeading
    trailing = newTrailing

    b.writeBit(true)
    b.writeBits(UInt64(newLeading), 5)

    // 64 significant bits does not fit in 6 bits, so it is written as 0 and read back as 64. Safe
    // only because a zero delta took the branch above.
    let sigbits = 64 - newLeading - newTrailing
    b.writeBits(UInt64(sigbits), 6)
    b.writeBits(delta >> newTrailing, Int(sigbits))
}

/// Go: `xorRead`.
func xorRead(
    _ br: inout BstreamReader, _ value: inout Double, _ leading: inout UInt8,
    _ trailing: inout UInt8
) throws {
    func readOneBit() throws -> Bool {
        do {
            return try br.readBitFast()
        } catch {
            return try br.readBit()
        }
    }
    func readSomeBits(_ n: UInt8) throws -> UInt64 {
        do {
            return try br.readBitsFast(n)
        } catch {
            return try br.readBits(n)
        }
    }

    if try !readOneBit() {
        // Same value as before.
        return
    }
    let controlBit = try readOneBit()

    var newLeading: UInt8
    var newTrailing: UInt8
    var mbits: UInt8

    if !controlBit {
        // Reuse the current leading/trailing window.
        newLeading = leading
        newTrailing = trailing
        mbits = 64 - newLeading - newTrailing
    } else {
        newLeading = UInt8(truncatingIfNeeded: try readSomeBits(5))
        mbits = UInt8(truncatingIfNeeded: try readSomeBits(6))
        // 0 significant bits means the writer overflowed 6 bits and meant 64.
        if mbits == 0 {
            mbits = 64
        }
        newTrailing = 64 - newLeading - mbits
        leading = newLeading
        trailing = newTrailing
    }
    let bits = try readSomeBits(mbits)
    var vbits = value.bitPattern
    vbits ^= bits << newTrailing
    value = Double(bitPattern: vbits)
}
