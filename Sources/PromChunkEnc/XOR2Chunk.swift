//===----------------------------------------------------------------------===//
// Ported from tsdb/chunkenc/xor2.go @ v3.13.2 — XOR with a JOINT timestamp+value control prefix and an
// optional start timestamp (ST) per chunk or per sample.
//
// **This is what the exit gate's last 23 skips wait on**: `@st` lines in the `.test` files need an
// encoding that can carry a start timestamp, and `EncXOR2` is it. Scoped in HANDOFF §6b before any of it
// was written, which is the only reason a 991-line file with fused bit writes was tractable.
//
// ## The grammar, from upstream's own comment
//
// Control prefix for samples >= 2 — one code covering BOTH the timestamp and the value, which is what
// makes this a different encoding rather than an extended XOR:
//
//     0     -> dod=0 AND value unchanged              (1 bit, and nothing else)
//     10    -> dod=0, value changed                   (2 bits, then a value field)
//     110   -> dod!=0, 13-bit signed                  (prefix+dod packed into 2 BYTES)
//     1110  -> dod!=0, 20-bit signed                  (prefix+dod packed into 3 BYTES)
//     11110 -> dod!=0, 64-bit escape                  (5+64 bits, then a value field)
//     11111 -> dod=0, STALE NaN                       (5 bits, and NO value field at all)
//
// The dod bins are widened *so that prefix+dod lands on a byte boundary* — which is why 13 bits after a
// 3-bit prefix, not 14. Those bounds are ordinary two's complement (`-(1<<12) ... (1<<12)-1`), NOT
// XOR's asymmetric `bitRange` (quirk 117). Two encodings in one package with different conventions.
//
// Two value encodings, and which applies depends on the prefix:
//
//     after dod!=0:  0 unchanged | 10 reuse window | 110 new window | 111 stale NaN
//     after dod=0:   0 reuse window | 1 new window        (the value is known to have changed)
//
// So **stale NaN is representable in two places** — as a whole-sample prefix and as a value code — and
// which one is used depends on whether the timestamp also moved.
//
// ## `baselineV` is not `val`
//
// A stale NaN never becomes the XOR baseline: every writer guards with `if !isStaleNaN(v)`, and the
// iterator carries `baselineV` separately from `val`. So `Appender()` lifts `it.baselineV`, and a port
// with one value field encodes correctly until the first stale sample and diverges on every one after.
//
// ## The ST header byte, and why sample 127 is special
//
// One byte between the sample count and the data:
//
//     bit 7 (0x80): firstSTKnown    — an ST for sample 0 is in the stream
//     bits 6-0:     firstSTChangeOn — the sample INDEX at which ST deltas begin
//
// Seven bits, so `maxFirstSTChangeOn` is `0x7F`. `writeHeaderFirstSTChangeOn` **silently returns** above
// that rather than erroring — upstream calls it corruption that should never happen — and `Append`
// prevents it by forcing the slow path at `numTotal == maxFirstSTChangeOn` *regardless of the data*, so
// the header is written while the index still fits. Sample 127 is a distinct branch, not an edge case.
//
// ## Three encoding paths in the `default` arm, each returning early
//
// A no-ST fast path, an active-ST fast path, and the full slow path. The middle one FUSES the value
// field's trailing bit with the ST delta into one `writeBitsFast` — so the same varbit prefix is written
// as **6** bits there and **5** bits where it is not fused. Every fast path repeats its own
// `numTotal` bump and header rewrite before returning; the duplication is upstream's and is kept,
// because collapsing it means reproducing every line of three copies exactly.
//
// ## The decoder reaches into the reader's buffer
//
// `decodeValue`, `decodeValueKnownNonZero`, `decodeNewLeadingTrailing` and `readDod` all manipulate
// `br.valid` and `br.buffer` directly, taking a fast path when enough bits are buffered and falling back
// to `readBits` when not. Both branches must produce the same answer; the port keeps both for the same
// reason §6a kept `readBitFast`-then-`readBit` — the fallback is where a buffer boundary is handled.
//===----------------------------------------------------------------------===//

public import PromHistogram

internal import GoCompat
internal import PromModel

/// Go: `chunkSTHeaderSize`, `maxFirstSTChangeOn`.
let chunkSTHeaderSize = 1
let maxFirstSTChangeOn: UInt16 = 0x7F

/// Go: `XOR2Chunk`.
public final class XOR2Chunk {
    var b: Bstream

    /// Go: `NewXOR2Chunk` — two count bytes plus one ST header byte.
    public init() {
        self.b = Bstream(
            stream: [UInt8](repeating: 0, count: chunkHeaderSize + chunkSTHeaderSize), count: 0)
    }

    public func reset(_ stream: [UInt8]) {
        b.reset(stream)
    }

    public var encoding: Encoding { .xor2 }
    public var bytes: [UInt8] { b.bytes }
    public var numSamples: Int { Int(GoBigEndian.uint16(bytes, 0)) }

    /// See `XORChunk.compact` — a no-op for the same reason.
    public func compact() {}

    /// Go: `XOR2Chunk.Appender`.
    ///
    /// Recovers MORE state than XOR's: the ST bookkeeping and the write bit-position as well as the
    /// leading/trailing window, and `baselineV` rather than `val`.
    public func appender() throws -> XOR2Appender {
        if b.stream.count == chunkHeaderSize + chunkSTHeaderSize {
            return XOR2Appender(chunk: self, t: Int64.min, leading: 0xff)
        }
        var it = iterator()
        while it.next() != .none {}
        if let err = it.err {
            throw err
        }
        // The write position comes from the READER's unread-bit count. See
        // `Bstream.restoreBitPosition`.
        b.restoreBitPosition(it.br.valid)

        return XOR2Appender(
            chunk: self, st: it.st, t: it.t, v: it.baselineV, tDelta: it.tDelta, stDiff: it.stDiff,
            leading: it.leading, trailing: it.trailing, numTotal: GoBigEndian.uint16(bytes, 0),
            firstSTKnown: it.firstSTKnown, firstSTChangeOn: UInt16(it.firstSTChangeOn))
    }

    public func iterator() -> XOR2Iterator {
        var it = XOR2Iterator()
        it.reset(bytes)
        return it
    }
}

/// Go: `writeHeaderFirstSTKnown`.
func writeHeaderFirstSTKnown(_ b: inout Bstream) {
    b.setByte(at: chunkHeaderSize, 0x80)
}

/// Go: `writeHeaderFirstSTChangeOn`.
///
/// **Silently returns** above `maxFirstSTChangeOn` rather than erroring: upstream's comment says "this
/// should never happen, would cause corruption (ST already skipped but shouldn't)". `Append` is what
/// keeps it from happening, by forcing the slow path at index `0x7F`. A port that throws here diverges
/// on a chunk upstream would write badly rather than reject.
func writeHeaderFirstSTChangeOn(_ b: inout Bstream, _ firstSTChangeOn: UInt16) {
    if firstSTChangeOn > maxFirstSTChangeOn {
        return
    }
    b.orByte(at: chunkHeaderSize, UInt8(truncatingIfNeeded: firstSTChangeOn))
}

/// Go: `readSTHeader`. The two exact-match fast paths are upstream's.
func readSTHeader(_ b: [UInt8], _ i: Int) -> (firstSTKnown: Bool, firstSTChangeOn: UInt8) {
    if b[i] == 0x00 { return (false, 0) }
    if b[i] == 0x80 { return (true, 0) }
    return (b[i] & 0x80 != 0, b[i] & 0x7F)
}

/// Go: `xor2Appender`.
public final class XOR2Appender {
    private let chunk: XOR2Chunk

    var st: Int64
    var t: Int64
    var v: Double
    var tDelta: UInt64
    /// Go: `stDiff` — `prevT - st` for the previous sample.
    var stDiff: Int64
    var leading: UInt8
    var trailing: UInt8
    var numTotal: UInt16
    var firstSTChangeOn: UInt16
    var firstSTKnown: Bool

    init(
        chunk: XOR2Chunk, st: Int64 = 0, t: Int64, v: Double = 0, tDelta: UInt64 = 0,
        stDiff: Int64 = 0, leading: UInt8 = 0, trailing: UInt8 = 0, numTotal: UInt16 = 0,
        firstSTKnown: Bool = false, firstSTChangeOn: UInt16 = 0
    ) {
        self.chunk = chunk
        self.st = st
        self.t = t
        self.v = v
        self.tDelta = tDelta
        self.stDiff = stDiff
        self.leading = leading
        self.trailing = trailing
        self.numTotal = numTotal
        self.firstSTKnown = firstSTKnown
        self.firstSTChangeOn = firstSTChangeOn
    }

    /// Go: `xor2Appender.Append`.
    public func append(_ st: Int64, _ t: Int64, _ v: Double) {
        var tDelta: UInt64 = 0
        var stDiff: Int64 = 0

        switch numTotal {
        case 0:
            var buf: [UInt8] = []
            GoVarint.putVarint(&buf, t)
            for byt in buf { chunk.b.writeByte(byt) }
            chunk.b.writeBitsFast(v.bitPattern, 64)

            if st != 0 {
                var stBuf: [UInt8] = []
                GoVarint.putVarint(&stBuf, t - st)
                for byt in stBuf { chunk.b.writeByte(byt) }
                firstSTKnown = true
                writeHeaderFirstSTKnown(&chunk.b)
            }

        case 1:
            tDelta = UInt64(bitPattern: t &- self.t)
            var buf: [UInt8] = []
            GoVarint.putUvarint(&buf, tDelta)
            for byt in buf { chunk.b.writeByte(byt) }

            writeVDelta(v)

            if st != self.st {
                stDiff = self.t &- st
                firstSTChangeOn = 1
                writeHeaderFirstSTChangeOn(&chunk.b, 1)
                putVarbitIntFast(&chunk.b, stDiff)
            }

        case UInt16.max:
            preconditionFailure("chunk capacity exceeded")

        default:
            tDelta = UInt64(bitPattern: t &- self.t)
            let dod = Int64(bitPattern: tDelta &- self.tDelta)

            // Fast path 1: nothing new to say about ST. The `numTotal != maxFirstSTChangeOn` clause is
            // NOT an optimisation guard — it forces the slow path at index 0x7F so the header can still
            // record a change that arrives later. See the file header.
            if firstSTChangeOn == 0 && st == self.st && numTotal != maxFirstSTChangeOn {
                let vbits = v.bitPattern
                if dod == 0 && vbits == self.v.bitPattern {
                    chunk.b.writeBit(false)
                } else if dod >= -(1 << 12) && dod <= (1 << 12) - 1 && vbits == self.v.bitPattern {
                    chunk.b.writeByte(
                        0b110_00000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 8) & 0x1F)
                    chunk.b.writeByte(UInt8(truncatingIfNeeded: UInt64(bitPattern: dod)))
                    chunk.b.writeBit(false)
                } else {
                    encodeJoint(dod, v)
                    if !PromValue.isStaleNaN(v) { self.v = v }
                }
                self.t = t
                self.tDelta = tDelta
                numTotal += 1
                chunk.b.putBigEndianUInt16(at: 0, numTotal)
                return
            }

            // Fast path 2: ST deltas are active, so every sample carries one. The value field's
            // trailing bit is FUSED with the ST delta — note the widths are one greater than the
            // unfused ones below.
            if firstSTChangeOn > 0 {
                let newStDiff = self.t &- st
                let deltaStDiff = newStDiff &- self.stDiff
                let vbits = v.bitPattern
                if dod == 0 && vbits == self.v.bitPattern {
                    writeFusedZeroBitAndST(deltaStDiff, leadingZeroBits: 1)
                } else if dod >= -(1 << 12) && dod <= (1 << 12) - 1 && vbits == self.v.bitPattern {
                    chunk.b.writeByte(
                        0b110_00000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 8) & 0x1F)
                    chunk.b.writeByte(UInt8(truncatingIfNeeded: UInt64(bitPattern: dod)))
                    writeFusedZeroBitAndST(deltaStDiff, leadingZeroBits: 1)
                } else {
                    encodeJoint(dod, v)
                    if !PromValue.isStaleNaN(v) { self.v = v }
                    // Not fused: the joint encoding already wrote its own value field.
                    writeFusedZeroBitAndST(deltaStDiff, leadingZeroBits: 0)
                }
                self.stDiff = newStDiff
                self.st = st
                self.t = t
                self.tDelta = tDelta
                numTotal += 1
                chunk.b.putBigEndianUInt16(at: 0, numTotal)
                return
            }

            // Full slow path: ST may be initialised here.
            encodeJoint(dod, v)

            if st != self.st || numTotal == maxFirstSTChangeOn {
                stDiff = self.t &- st
                firstSTChangeOn = numTotal
                writeHeaderFirstSTChangeOn(&chunk.b, numTotal)
                putVarbitIntFast(&chunk.b, stDiff)
            }
        }

        self.st = st
        self.t = t
        if !PromValue.isStaleNaN(v) { self.v = v }
        self.tDelta = tDelta
        self.stDiff = stDiff
        numTotal += 1
        chunk.b.putBigEndianUInt16(at: 0, numTotal)
    }

    /// The ST-delta write, with `leadingZeroBits` extra zero bits fused in front of it.
    ///
    /// Upstream spells this out three times with the widths hard-coded, because it is fusing a T/V
    /// control bit into the same `writeBitsFast` call. `leadingZeroBits: 1` reproduces the fused form
    /// (widths 6/10/14) and `0` the unfused one (5/9/13); the `deltaStDiff == 0` case writes that many
    /// plus one bare zero bits, which is what upstream's two `writeBit(zero)` calls do.
    ///
    /// Only the first three varbit buckets are inlined upstream — anything larger falls back to
    /// `putVarbitIntFast` after a separate zero bit, so the fusing stops there and so does this.
    private func writeFusedZeroBitAndST(_ deltaStDiff: Int64, leadingZeroBits: Int) {
        let extra = UInt64(leadingZeroBits)
        if deltaStDiff == 0 {
            for _ in 0..<(leadingZeroBits + 1) { chunk.b.writeBit(false) }
        } else if deltaStDiff >= -3 && deltaStDiff <= 4 {
            chunk.b.writeBitsFast(
                (0b10 << 3) | (UInt64(bitPattern: deltaStDiff) & 0x7), 5 + Int(extra))
        } else if deltaStDiff >= -31 && deltaStDiff <= 32 {
            chunk.b.writeBitsFast(
                (0b110 << 6) | (UInt64(bitPattern: deltaStDiff) & 0x3F), 9 + Int(extra))
        } else if deltaStDiff >= -255 && deltaStDiff <= 256 {
            chunk.b.writeBitsFast(
                (0b1110 << 9) | (UInt64(bitPattern: deltaStDiff) & 0x1FF), 13 + Int(extra))
        } else {
            for _ in 0..<leadingZeroBits { chunk.b.writeBit(false) }
            putVarbitIntFast(&chunk.b, deltaStDiff)
        }
    }

    /// Go: `encodeJoint`.
    private func encodeJoint(_ dod: Int64, _ v: Double) {
        if dod == 0 {
            if PromValue.isStaleNaN(v) {
                chunk.b.writeBitsFast(0b11111, 5)
                return
            }
            let vbits = v.bitPattern ^ self.v.bitPattern
            if vbits == 0 {
                chunk.b.writeBit(false)
                return
            }
            chunk.b.writeBitsFast(0b10, 2)
            writeVDeltaKnownNonZero(vbits)
            return
        }

        // Ordinary two's complement bounds here, NOT `bitRange` — see the file header.
        if dod >= -(1 << 12) && dod <= (1 << 12) - 1 {
            chunk.b.writeByte(
                0b110_00000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 8) & 0x1F)
            chunk.b.writeByte(UInt8(truncatingIfNeeded: UInt64(bitPattern: dod)))
        } else if dod >= -(1 << 19) && dod <= (1 << 19) - 1 {
            chunk.b.writeByte(
                0b1110_0000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 16) & 0x0F)
            chunk.b.writeByte(UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 8))
            chunk.b.writeByte(UInt8(truncatingIfNeeded: UInt64(bitPattern: dod)))
        } else {
            chunk.b.writeBitsFast(0b11110, 5)
            chunk.b.writeBitsFast(UInt64(bitPattern: dod), 64)
        }
        if v.bitPattern == self.v.bitPattern {
            chunk.b.writeBit(false)
        } else {
            writeVDelta(v)
        }
    }

    /// Go: `writeVDelta` — the dod!=0 value field, whose codes are `0` / `10` / `110` / `111`.
    private func writeVDelta(_ v: Double) {
        if PromValue.isStaleNaN(v) {
            chunk.b.writeBitsFast(0b111, 3)
            return
        }
        let delta = v.bitPattern ^ self.v.bitPattern
        if delta == 0 {
            chunk.b.writeBit(false)
            return
        }
        var newLeading = UInt8(delta.leadingZeroBitCount)
        let newTrailing = UInt8(delta.trailingZeroBitCount)
        if newLeading >= 32 { newLeading = 31 }

        if leading != 0xff && newLeading >= leading && newTrailing >= trailing {
            chunk.b.writeBitsFast(0b10, 2)
            chunk.b.writeBitsFast(delta >> trailing, 64 - Int(leading) - Int(trailing))
            return
        }
        leading = newLeading
        trailing = newTrailing
        chunk.b.writeBitsFast(0b110, 3)
        chunk.b.writeBitsFast(UInt64(newLeading), 5)
        let sigbits = 64 - newLeading - newTrailing
        chunk.b.writeBitsFast(UInt64(sigbits), 6)
        chunk.b.writeBitsFast(delta >> newTrailing, Int(sigbits))
    }

    /// Go: `writeVDeltaKnownNonZero` — the dod=0 value field, one control bit rather than up to three,
    /// because "the value changed" is already established by the joint prefix. Stale NaN never reaches
    /// here: with dod=0 it is the `11111` whole-sample prefix.
    private func writeVDeltaKnownNonZero(_ delta: UInt64) {
        var newLeading = UInt8(delta.leadingZeroBitCount)
        let newTrailing = UInt8(delta.trailingZeroBitCount)
        if newLeading >= 32 { newLeading = 31 }

        if leading != 0xff && newLeading >= leading && newTrailing >= trailing {
            chunk.b.writeBit(false)
            chunk.b.writeBitsFast(delta >> trailing, 64 - Int(leading) - Int(trailing))
            return
        }
        leading = newLeading
        trailing = newTrailing
        chunk.b.writeBit(true)
        chunk.b.writeBitsFast(UInt64(newLeading), 5)
        let sigbits = 64 - newLeading - newTrailing
        chunk.b.writeBitsFast(UInt64(sigbits), 6)
        chunk.b.writeBitsFast(delta >> newTrailing, Int(sigbits))
    }
}

/// Go: `xor2Iterator`.
public struct XOR2Iterator {
    var br = BstreamReader([])
    var numTotal: UInt16 = 0
    public private(set) var numRead: UInt16 = 0

    var firstSTKnown = false
    var firstSTChangeOn: UInt8 = 0

    var leading: UInt8 = 0
    var trailing: UInt8 = 0

    public private(set) var st: Int64 = 0
    public private(set) var t: Int64 = 0
    public private(set) var val: Double = 0

    var tDelta: UInt64 = 0
    /// Go: `stDiff` — the ACCUMULATED `prevT - st`, not a per-sample delta.
    var stDiff: Int64 = 0
    public private(set) var err: (any Error)? = nil
    /// Go: `baselineV` — the last NON-STALE value, which is what the XOR is against. See the file header.
    var baselineV: Double = 0

    init() {}

    /// Go: `At`, `AtT`, `AtST`.
    public var at: (Int64, Double) { (t, val) }
    public var atST: Int64 { st }

    /// Go: `xor2Iterator.Reset`.
    public mutating func reset(_ b: [UInt8]) {
        br = BstreamReader(Array(b[(chunkHeaderSize + chunkSTHeaderSize)...]))
        numTotal = GoBigEndian.uint16(b, 0)
        (firstSTKnown, firstSTChangeOn) = readSTHeader(b, chunkHeaderSize)
        numRead = 0
        st = 0
        t = 0
        val = 0
        leading = 0
        trailing = 0
        tDelta = 0
        stDiff = 0
        baselineV = 0
        err = nil
    }

    /// Go: `Seek`.
    public mutating func seek(_ target: Int64) -> ValueType {
        if err != nil { return .none }
        while target > t || numRead == 0 {
            if next() == .none { return .none }
        }
        return .float
    }

    /// Go: `xor2Iterator.Next`.
    public mutating func next() -> ValueType {
        if err != nil || numRead == numTotal { return .none }

        if numRead == 0 {
            do {
                let t0 = try br.readVarint()
                let v = try br.readBits(64)
                t = t0
                val = Double(bitPattern: v)
                if !PromValue.isStaleNaN(val) { baselineV = val }
                if firstSTKnown {
                    // Sample 0's ST is a plain varint of `t - st`.
                    st = t0 &- (try br.readVarint())
                }
            } catch {
                err = error
                return .none
            }
            numRead += 1
            return .float
        }

        if numRead == 1 {
            let prevT = t
            do {
                tDelta = try br.readUvarint()
                t = t &+ Int64(bitPattern: tDelta)
                try decodeValue()
                if firstSTChangeOn == 1 {
                    let sdod = try readVarbitInt(&br)
                    stDiff = sdod
                    st = prevT &- sdod
                }
            } catch {
                err = error
                return .none
            }
            numRead += 1
            return .float
        }

        // Sample N >= 2.
        let prevT = t
        let savedNumRead = numRead

        var ctrl: UInt8
        if let fast = br.readXOR2ControlFast() {
            ctrl = fast
        } else {
            do {
                ctrl = try br.readXOR2Control()
            } catch {
                err = error
                return .none
            }
        }

        do {
            switch ctrl {
            case 0:
                t = t &+ Int64(bitPattern: tDelta)
                val = baselineV
            case 1:
                t = t &+ Int64(bitPattern: tDelta)
                try decodeValueKnownNonZero()
            case 2:
                try readDod(13)
                try decodeValue()
            case 3:
                try readDod(20)
                try decodeValue()
            case 4:
                try readDod(64)
                try decodeValue()
            default:
                t = t &+ Int64(bitPattern: tDelta)
                val = Double(bitPattern: PromValue.staleNaNBits)
            }

            // The ST delta rides AFTER the joint encoding, and it was written against the PREVIOUS
            // sample's `t`. The first one is absolute; later ones accumulate.
            if firstSTChangeOn > 0 && savedNumRead >= UInt16(firstSTChangeOn) {
                let sdod = try readVarbitInt(&br)
                if savedNumRead == UInt16(firstSTChangeOn) {
                    stDiff = sdod
                } else {
                    stDiff = stDiff &+ sdod
                }
                st = prevT &- stDiff
            }
        } catch {
            err = error
            return .none
        }

        numRead += 1
        return .float
    }

    /// Go: `readDod` — a signed dod of `w` bits, updating `tDelta` and `t`.
    ///
    /// The `w < 64` guard on the sign extension matters: at 64 bits the value is already the full
    /// two's-complement pattern and `1 << 64` would be meaningless.
    private mutating func readDod(_ w: UInt8) throws {
        var b: UInt64
        if br.valid >= w {
            br.valid -= w
            b = (br.buffer >> UInt64(br.valid)) & ((UInt64(1) << UInt64(w)) &- 1)
        } else {
            b = try br.readBits(w)
        }
        if w < 64 && b >= (1 << (UInt64(w) - 1)) {
            b &-= 1 << UInt64(w)
        }
        tDelta = UInt64(bitPattern: Int64(bitPattern: tDelta) &+ Int64(bitPattern: b))
        t = t &+ Int64(bitPattern: tDelta)
    }

    /// Reads `n` bits, from the buffer when it holds them and through `readBits` when not. The decoder
    /// does this inline in five places upstream; factoring it is safe because both arms are the same
    /// arithmetic.
    private mutating func takeBits(_ n: UInt8) throws -> UInt64 {
        if br.valid >= n {
            br.valid -= n
            return (br.buffer >> UInt64(br.valid)) & ((UInt64(1) << UInt64(n)) &- 1)
        }
        return try br.readBits(n)
    }

    /// One bit, from the buffer when it has one.
    private mutating func takeBit() throws -> Bool {
        if br.valid > 0 {
            br.valid -= 1
            return (br.buffer & (UInt64(1) << UInt64(br.valid))) != 0
        }
        return try br.readBit()
    }

    /// Applies a value field that reuses the current leading/trailing window.
    private mutating func applyReusedWindow() throws {
        let sz = UInt8(64 - Int(leading) - Int(trailing))
        let valueBits = try takeBits(sz)
        var vbits = baselineV.bitPattern
        vbits ^= valueBits << UInt64(trailing)
        val = Double(bitPattern: vbits)
        baselineV = val
    }

    /// Go: `decodeValue` — the dod!=0 value field: `0` / `10` / `110` / `111`.
    private mutating func decodeValue() throws {
        // Fast path: the whole prefix is buffered, so it is one shift and a compare.
        if br.valid >= 3 {
            let ctrl = (br.buffer >> (UInt64(br.valid) - 3)) & 0x7
            if ctrl & 0x4 == 0 {
                br.valid -= 1
                val = baselineV
                return
            }
            if ctrl & 0x6 == 0x4 {
                br.valid -= 2
                try applyReusedWindow()
                return
            }
            br.valid -= 3
            if ctrl == 0x6 {
                try decodeNewLeadingTrailing()
                return
            }
            val = Double(bitPattern: PromValue.staleNaNBits)
            return
        }

        // Slow path, one bit at a time across a buffer refill.
        if try !takeBit() {
            val = baselineV
            return
        }
        if try !takeBit() {
            try applyReusedWindow()
            return
        }
        if try !takeBit() {
            try decodeNewLeadingTrailing()
            return
        }
        val = Double(bitPattern: PromValue.staleNaNBits)
    }

    /// Go: `decodeValueKnownNonZero` — the dod=0 value field: `0` reuse, `1` new window.
    private mutating func decodeValueKnownNonZero() throws {
        let sz = UInt8(64 - Int(leading) - Int(trailing))
        // Fast path: the control bit AND the value in one buffer operation.
        if br.valid >= 1 + sz {
            let ctrlBit = (br.buffer >> (UInt64(br.valid) - 1)) & 1
            if ctrlBit == 0 {
                br.valid -= 1 + sz
                let valueBits = (br.buffer >> UInt64(br.valid)) & ((UInt64(1) << UInt64(sz)) &- 1)
                var vbits = baselineV.bitPattern
                vbits ^= valueBits << UInt64(trailing)
                val = Double(bitPattern: vbits)
                baselineV = val
                return
            }
            br.valid -= 1
            try decodeNewLeadingTrailing()
            return
        }

        if try !takeBit() {
            try applyReusedWindow()
            return
        }
        try decodeNewLeadingTrailing()
    }

    /// Go: `decodeNewLeadingTrailing` — a 5-bit leading count, a 6-bit sigbits, then the value.
    private mutating func decodeNewLeadingTrailing() throws {
        var newLeading: UInt64
        var sigbits: UInt64
        // Fast path: leading and sigbits are adjacent, so 11 bits in one read.
        if br.valid >= 11 {
            let v = (br.buffer >> (UInt64(br.valid) - 11)) & 0x7FF
            br.valid -= 11
            newLeading = v >> 6
            sigbits = v & 0x3F
        } else {
            newLeading = try br.readBits(5)
            sigbits = try br.readBits(6)
        }

        leading = UInt8(truncatingIfNeeded: newLeading)
        if sigbits == 0 { sigbits = 64 }
        trailing = 64 - leading - UInt8(truncatingIfNeeded: sigbits)

        let valueBits = try takeBits(UInt8(truncatingIfNeeded: sigbits))
        var vbits = baselineV.bitPattern
        vbits ^= valueBits << UInt64(trailing)
        val = Double(bitPattern: vbits)
        baselineV = val
    }
}
