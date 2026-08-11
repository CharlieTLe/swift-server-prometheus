//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/bstream.go @ v3.13.2 — the bit stream every chunk encoding is
// built on. Originally Damian Gryski's go-tsz; the upstream file carries his BSD licence
// notice and so does this port's origin note.
//
// This is the first code of Phase 6 (HANDOFF §5d). It comes before `xor.go` because every
// encoding writes through `Bstream` and reads through `BstreamReader`, and because it is
// pinnable on its own: a sequence of write operations has one correct byte string, and a byte
// string plus a sequence of read widths has one correct list of values.
//
// The XOR2 control-prefix readers in the same upstream file are **not** here — they are XOR2's
// grammar rather than the stream's, and they land with XOR2.
//
// ## NOT YET PINNED, and why — do not treat this file as verified
//
// `bstream`, `bstreamReader` and `newBReader` are **unexported** in package `chunkenc`, so the
// oracle — a separate Go module — cannot call them. The same wall as `promql.evaluator`. What IS
// exported is `chunkenc.NewXORChunk` and `Chunk.Bytes()`, so this file becomes differentially
// testable the moment `xor.go` lands on top of it: an appended sample sequence produces one
// correct byte string, and those bytes are the bit stream this file wrote.
//
// So the two slices are one unit of verification even though they are two units of code. This is
// transcribed against the pinned source and reviewed line by line; it is not yet corpus-checked,
// and nothing in the port calls it yet. See HANDOFF §5d.
//
// ## `count` counts what is FREE, not what is used
//
// `Bstream.count` is how many right-most bits of the last byte are still available. It starts
// at 0, which means "no partial byte" and so forces `writeBit` to append. Reading it as
// "bits used" inverts every shift in the file.
//
// ## The reader keeps a copy of the last byte, on purpose
//
// `newBReader` copies `stream[len-1]` into `last`, and `loadNextBuffer` uses that copy rather
// than the slice whenever the read reaches the final byte. Upstream's comment says why: a chunk
// can be appended to *while it is being read*, and the last byte is the one an appender
// mutates. So this is a concurrency accommodation baked into the decoder's arithmetic, and it
// is preserved — a port that read `stream.last` directly would agree on every committed case
// and diverge under concurrent append.
//
// `loadNextBuffer` has two paths: a fast one that reads a full big-endian `UInt64` when more
// than 8 bytes remain (so it never touches the last byte), and a slow one that assembles
// `(nbits / 8) + 1` bytes — note that is a byte count derived from a *bit* count, and it can
// exceed what remains, which is why it is clamped.
//
// ## `writeBits` and `writeBitsFast` must agree
//
// Upstream keeps both, with a TODO to drop the slow one once XOR2 stabilises. They are
// different algorithms — one calls `writeByte` per byte, the other fills the partial byte
// inline and appends whole bytes directly — so the corpus runs every case through both and
// compares them against each other as well as against Go.
//===----------------------------------------------------------------------===//

/// Go: `bstream` — a stream of bits, written left to right.
public struct Bstream: Sendable {
    /// Go: `stream`.
    public private(set) var stream: [UInt8]
    /// Go: `count` — how many right-most bits of the **last** byte are free.
    public private(set) var count: UInt8

    public init(stream: [UInt8] = [], count: UInt8 = 0) {
        self.stream = stream
        self.count = count
    }

    /// Go: `Reset` — note it zeroes `count`, so the last byte of `stream` is treated as full
    /// even when it is not.
    /// Go: `binary.BigEndian.PutUint16(b.bytes(), v)` — an in-place rewrite of two bytes.
    ///
    /// Go gets this for free: `bytes()` returns the slice itself, so a caller can write through it, and
    /// `xorAppender.Append` rewrites the chunk's two-byte sample count on every append. `stream` is
    /// `private(set)` here, so the operation is named rather than left to the caller — which is the
    /// better shape anyway, since "write into the stream at an offset" is the only mutation any encoder
    /// needs that is not a bit append.
    public mutating func putBigEndianUInt16(at i: Int, _ v: UInt16) {
        stream[i] = UInt8(truncatingIfNeeded: v >> 8)
        stream[i + 1] = UInt8(truncatingIfNeeded: v)
    }

    public mutating func reset(_ stream: [UInt8]) {
        self.stream = stream
        count = 0
    }

    /// Go: `bytes`.
    public var bytes: [UInt8] { stream }

    /// Go: `writeBit`.
    public mutating func writeBit(_ bit: Bool) {
        if count == 0 {
            stream.append(0)
            count = 8
        }
        let i = stream.count - 1
        if bit {
            stream[i] |= 1 << (count - 1)
        }
        count -= 1
    }

    /// Go: `writeByte` — completes the partial byte with the byte's leftmost bits and appends
    /// the remainder, so `count` is unchanged.
    public mutating func writeByte(_ byt: UInt8) {
        if count == 0 {
            stream.append(byt)
            return
        }
        let i = stream.count - 1
        stream[i] |= byt >> (8 - count)
        stream.append(byt << count)
    }

    /// Go: `writeBits` — the `nbits` right-most bits of `u`, in left-to-right order.
    ///
    /// `u <<= 64 - nbits` first, so the bits to write are at the top; then whole bytes through
    /// `writeByte` and the remainder bit by bit. `nbits == 0` writes nothing, and `nbits == 64`
    /// shifts by zero — both are reachable and both are why the shift is written this way.
    public mutating func writeBits(_ uIn: UInt64, _ nbitsIn: Int) {
        var u = uIn
        var nbits = nbitsIn
        u <<= UInt64(64 - nbits)
        while nbits >= 8 {
            let byt = UInt8(truncatingIfNeeded: u >> 56)
            writeByte(byt)
            u <<= 8
            nbits -= 8
        }
        while nbits > 0 {
            writeBit((u >> 63) == 1)
            u <<= 1
            nbits -= 1
        }
    }

    /// Go: `writeBitsFast` — the same result by a different route: fill the partial byte inline,
    /// then append whole bytes directly.
    ///
    /// The early return when `nbits < free` is the one place the two implementations could
    /// disagree, because it leaves `count` at `free - nbits` without appending anything.
    public mutating func writeBitsFast(_ uIn: UInt64, _ nbitsIn: Int) {
        var u = uIn
        var nbits = nbitsIn
        u <<= UInt64(64 - nbits)

        if count > 0 {
            let free = Int(count)
            let last = stream.count - 1
            stream[last] |= UInt8(truncatingIfNeeded: u >> UInt64(64 - free))
            if nbits < free {
                count = UInt8(free - nbits)
                return
            }
            u <<= UInt64(free)
            nbits -= free
            count = 0
        }

        while nbits >= 8 {
            stream.append(UInt8(truncatingIfNeeded: u >> 56))
            u <<= 8
            nbits -= 8
        }

        if nbits > 0 {
            stream.append(UInt8(truncatingIfNeeded: u >> 56))
            count = UInt8(8 - nbits)
        }
    }
}

/// Go: `io.EOF`, as the bit reader raises it.
public struct BstreamEOF: Error, CustomStringConvertible, Equatable, Sendable {
    public init() {}
    public var description: String { "EOF" }
}

/// Go: `bstreamReader` — reads bits back out of a `Bstream`'s bytes.
public struct BstreamReader: Sendable {
    let stream: [UInt8]
    var streamOffset: Int = 0
    var buffer: UInt64 = 0
    /// Go: `valid` — how many right-most bits of `buffer` are still readable.
    var valid: UInt8 = 0
    /// Go: `last` — a COPY of the stream's final byte, taken at construction. See the file
    /// header: an appender may be mutating that byte while this reader runs.
    let last: UInt8

    /// Go: `newBReader`.
    public init(_ b: [UInt8]) {
        stream = b
        last = b.last ?? 0
    }

    /// Go: `readBit`.
    public mutating func readBit() throws -> Bool {
        if valid == 0 {
            if !loadNextBuffer(1) {
                throw BstreamEOF()
            }
        }
        return try readBitFast()
    }

    /// Go: `readBitFast` — throws when the buffer is empty, and the caller is expected to retry
    /// through `readBit`. Kept separate because Go relies on it being inlinable.
    public mutating func readBitFast() throws -> Bool {
        if valid == 0 {
            throw BstreamEOF()
        }
        valid -= 1
        let bitmask = UInt64(1) << valid
        return (buffer & bitmask) != 0
    }

    /// Go: `readBits` — the `nbits` right-most bits, zero elsewhere.
    ///
    /// The interesting branch is the third: when the request straddles the buffer boundary it
    /// takes what is left, refills, and takes the rest — and it refills with the *remaining*
    /// count, not the original, which is what makes the two halves line up.
    public mutating func readBits(_ nbitsIn: UInt8) throws -> UInt64 {
        var nbits = nbitsIn
        if valid == 0 {
            if !loadNextBuffer(nbits) {
                throw BstreamEOF()
            }
        }
        if nbits <= valid {
            return try readBitsFast(nbits)
        }

        // `&- 1`, not `- 1`: see `readBitsFast` below. Wrapping here too, for consistency and because
        // `valid == 64` is reachable at this line in principle even though the branch condition makes
        // it unreachable in practice.
        var bitmask = (UInt64(1) << valid) &- 1
        nbits -= valid
        var v = (buffer & bitmask) << nbits
        valid = 0

        if !loadNextBuffer(nbits) {
            throw BstreamEOF()
        }

        bitmask = (UInt64(1) << nbits) &- 1
        v |= ((buffer >> (valid - nbits)) & bitmask)
        valid -= nbits
        return v
    }

    /// Go: `readBitsFast`.
    ///
    /// **`&- 1`, not `- 1`.** Go's `(uint64(1) << nbits) - 1` with `nbits == 64` is `0 - 1`, which
    /// wraps to all-ones and is the mask that was wanted; Swift's `-` **traps** on that underflow. And
    /// `nbits == 64` is not exotic: `loadNextBuffer`'s fast path sets `valid = 64`, and the XOR
    /// decoder's very first read is `readBits(64)` for the raw sample value.
    ///
    /// This was the first bug the XOR corpus found, and it could not have been found earlier — the
    /// file had no caller and no fixture, which is exactly what its own header warned about. The crash
    /// was in the DECODER while the encoder wrote all 200 samples happily, because the encoder's
    /// `writeBits` never needs a 64-bit mask.
    public mutating func readBitsFast(_ nbits: UInt8) throws -> UInt64 {
        if nbits > valid {
            throw BstreamEOF()
        }
        let bitmask = (UInt64(1) << nbits) &- 1
        valid -= nbits
        return (buffer >> valid) & bitmask
    }

    /// Go: `ReadByte` — eight bits, and so subject to the same straddling path.
    public mutating func readByte() throws -> UInt8 {
        UInt8(truncatingIfNeeded: try readBits(8))
    }

    /// Go: `loadNextBuffer`.
    ///
    /// Two paths, and the split is not just an optimisation: the fast path requires *more* than
    /// 8 bytes remaining (`+8 <` rather than `+8 <=`) precisely so it can never read the final
    /// byte, which an appender may be writing. The slow path derives a byte count from a bit
    /// count — `(nbits / 8) + 1` — clamps it to what remains, and substitutes the saved copy for
    /// the last byte when the read reaches it.
    mutating func loadNextBuffer(_ nbits: UInt8) -> Bool {
        if streamOffset >= stream.count {
            return false
        }

        if streamOffset + 8 < stream.count {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(stream[streamOffset + i])
            }
            buffer = v
            streamOffset += 8
            valid = 64
            return true
        }

        var nbytes = Int((nbits / 8) + 1)
        if streamOffset + nbytes > stream.count {
            nbytes = stream.count - streamOffset
        }

        var newBuffer: UInt64 = 0
        var skip = 0
        if streamOffset + nbytes == stream.count {
            newBuffer |= UInt64(last)
            skip = 1
        }

        for i in 0..<(nbytes - skip) {
            newBuffer |= UInt64(stream[streamOffset + i]) << UInt64(8 * (nbytes - i - 1))
        }

        buffer = newBuffer
        streamOffset += nbytes
        valid = UInt8(nbytes * 8)
        return true
    }
}

// MARK: - XOR2's grammar
//
// The file header said these were left out because they are XOR2's grammar rather than the stream's.
// XOR2 has arrived, so here they are — and the header's judgement holds: nothing else reads a
// variable-length joint control prefix, and putting them here rather than in `XOR2Chunk.swift` is only
// because they need `buffer`/`valid` directly, the way upstream's do.

extension Bstream {
    /// `xor2Appender.Appender()` restores the write position from the READER's unread-bit count:
    /// `c.b.count = it.br.valid`.
    ///
    /// Two quantities with the same units and different meanings — `count` is free bits in the last
    /// byte, `valid` is unread bits in the reader's buffer — and XOR2 relies on their coinciding at
    /// end-of-stream. XOR's appender needs no such line because its writes are always bit-aligned from
    /// a known state; XOR2's fused writes are not. Named rather than exposing `count`'s setter, for the
    /// reason `putBigEndianUInt16(at:)` is named.
    public mutating func restoreBitPosition(_ valid: UInt8) {
        count = valid
    }

    /// Go writes into the header through the slice `bytes()` returns: `b[0] = 0x80`.
    mutating func setByte(at i: Int, _ v: UInt8) {
        stream[i] = v
    }

    /// Go: `b[0] |= uint8(...)`.
    mutating func orByte(at i: Int, _ v: UInt8) {
        stream[i] |= v
    }
}

extension BstreamReader {
    /// Go: `readXOR2ControlFast` — the four-bit lookahead, returning `nil` where Go returns `ok=false`.
    ///
    /// Deliberately gives up on `1111`: distinguishing cases 4 and 5 needs a fifth bit, and this
    /// function only promises to be fast. The caller falls back to `readXOR2Control`.
    mutating func readXOR2ControlFast() -> UInt8? {
        if valid < 4 {
            return nil
        }
        let top4 = UInt8((buffer >> (UInt64(valid) - 4)) & 0xF)
        if top4 < 8 {  // `0xxx`: dod=0, value unchanged.
            valid -= 1
            return 0
        }
        if top4 < 12 {  // `10xx`: dod=0, value changed.
            valid -= 2
            return 1
        }
        if top4 < 14 {  // `110x`: 13-bit dod.
            valid -= 3
            return 2
        }
        if top4 == 14 {  // `1110`: 20-bit dod.
            valid -= 4
            return 3
        }
        return nil
    }

    /// Go: `readXOR2Control` — the joint control prefix, mapped to 0...5.
    ///
    /// ```
    /// 0 -> `0`      dod=0, value unchanged      (1 bit)
    /// 1 -> `10`     dod=0, value changed        (2 bits)
    /// 2 -> `110`    13-bit signed dod           (3 bits)
    /// 3 -> `1110`   20-bit signed dod           (4 bits)
    /// 4 -> `11110`  64-bit dod escape           (5 bits)
    /// 5 -> `11111`  dod=0, stale NaN            (5 bits)
    /// ```
    ///
    /// Three paths, and the middle one is the subtle one: with four bits buffered but not five, the
    /// prefix is `1111` and the deciding fifth bit straddles the buffer. Go consumes the four known
    /// bits and then calls `readBit`, which refills — so the straddle is handled by *splitting the
    /// read*, not by refusing it.
    mutating func readXOR2Control() throws -> UInt8 {
        if valid >= 4 {
            let top4 = UInt8((buffer >> (UInt64(valid) - 4)) & 0xF)
            if top4 < 8 {
                valid -= 1
                return 0
            }
            if top4 < 12 {
                valid -= 2
                return 1
            }
            if top4 < 14 {
                valid -= 3
                return 2
            }
            if top4 == 14 {
                valid -= 4
                return 3
            }
            // `1111`: the fifth bit decides between 4 and 5.
            if valid >= 5 {
                let bit4 = UInt8((buffer >> (UInt64(valid) - 5)) & 1)
                valid -= 5
                return 4 + bit4
            }
            valid -= 4
            return try readBit() ? 5 : 4
        }

        // Fewer than four bits buffered: one at a time, each refilling as needed.
        if try !readBit() { return 0 }
        if try !readBit() { return 1 }
        if try !readBit() { return 2 }
        if try !readBit() { return 3 }
        return try readBit() ? 5 : 4
    }

    /// Go: `bstreamReader.readUvarint` — a method rather than `binary.ReadUvarint`, whose
    /// `io.ByteReader` dispatch made the receiver escape to the heap. Same encoding, so the port shares
    /// `readUvarintFromBstream`.
    mutating func readUvarint() throws -> UInt64 {
        try readUvarintFromBstream(&self)
    }

    /// Go: `bstreamReader.readVarint`.
    mutating func readVarint() throws -> Int64 {
        try readVarintFromBstream(&self)
    }
}
