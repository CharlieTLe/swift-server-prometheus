//===----------------------------------------------------------------------===//
// Ported from tsdb/encoding/encoding.go @ v3.13.2
//
// Encbuf/Decbuf are the primitives every TSDB binary format is built on: the
// block index, tombstones and WAL records all encode through here. Byte-exact.
//===----------------------------------------------------------------------===//

private import GoCompat
private import PromHash

/// Go: `encoding.Encbuf`.
public struct Encbuf: Sendable {

    /// Go: `Encbuf.B`.
    public private(set) var bytes: [UInt8] = []

    public init() {}
    public init(reservingCapacity n: Int) { bytes.reserveCapacity(n) }

    /// Go: `Reset` / `Get` / `Len`.
    public mutating func reset() { bytes.removeAll(keepingCapacity: true) }
    public var count: Int { bytes.count }

    // MARK: - Raw

    public mutating func putString(_ s: String) { bytes.append(contentsOf: s.utf8) }
    public mutating func putByte(_ c: UInt8) { bytes.append(c) }
    public mutating func putBytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func putBytes(_ b: ArraySlice<UInt8>) { bytes.append(contentsOf: b) }

    // MARK: - Big endian

    public mutating func putBE32(_ x: UInt32) { GoBigEndian.append(&bytes, x) }
    public mutating func putBE64(_ x: UInt64) { GoBigEndian.append(&bytes, x) }
    public mutating func putBE32int(_ x: Int) { putBE32(UInt32(truncatingIfNeeded: x)) }
    public mutating func putBE64int64(_ x: Int64) { putBE64(UInt64(bitPattern: x)) }
    public mutating func putBEFloat64(_ x: Double) { putBE64(x.bitPattern) }

    // MARK: - Varints

    public mutating func putUvarint64(_ x: UInt64) { GoVarint.putUvarint(&bytes, x) }
    public mutating func putVarint64(_ x: Int64) { GoVarint.putVarint(&bytes, x) }
    public mutating func putUvarint(_ x: Int) { putUvarint64(UInt64(x)) }
    public mutating func putUvarint32(_ x: UInt32) { putUvarint64(UInt64(x)) }

    /// Go: `PutUvarintStr` — varint byte length, then contents.
    public mutating func putUvarintStr(_ s: String) {
        let utf8 = Array(s.utf8)
        putUvarint(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    /// Go: `PutUvarintBytes`.
    public mutating func putUvarintBytes(_ b: [UInt8]) {
        putUvarint(b.count)
        bytes.append(contentsOf: b)
    }

    // MARK: - Checksum

    /// Go: `PutHash(h)` — appends a CRC-32C over the buffer's current contents.
    public mutating func putHash() {
        let sum = CRC32C.checksum(bytes)
        GoBigEndian.append(&bytes, sum)
    }

    /// The CRC-32C over the current contents, without appending it.
    public func crc32() -> UInt32 { CRC32C.checksum(bytes) }
}

/// Go: `encoding.Decbuf`.
///
/// Preserves Go's **sticky error** design: reads past the end return zero and
/// latch `error`, and callers check once at the end. Making each read `throws`
/// would restructure every ported reader, so we keep Go's shape.
public struct Decbuf {

    /// Remaining bytes. Go: `Decbuf.B`.
    public private(set) var b: ByteSlice
    /// Go: `Decbuf.E`.
    public private(set) var error: EncodingError?

    public init(_ b: ByteSlice) { self.b = b }
    public init(error: EncodingError) {
        self.b = ByteSlice(base: UnsafeRawPointer(bitPattern: 1)!, count: 0)
        self.error = error
    }

    /// Go: `Err()` / `Len()`.
    public var err: EncodingError? { error }
    public var count: Int { b.count }

    // MARK: - Framed constructors

    /// Go: `NewDecbufAt` — a big-endian uint32 length at `off`, then contents,
    /// then a CRC-32C. Pass `verifyChecksum: false` for Go's `nil` table.
    public static func at(_ bs: ByteSlice, _ off: Int, verifyChecksum: Bool = true) -> Decbuf {
        guard bs.count >= off + 4 else { return Decbuf(error: .invalidSize) }
        let l = Int(bs.loadBE32(at: off))
        guard bs.count >= off + 4 + l + 4 else { return Decbuf(error: .invalidSize) }

        let framed = bs.range(off + 4, off + 4 + l + 4)
        let dec = Decbuf(framed.range(0, framed.count - 4))
        if verifyChecksum {
            let expected = framed.loadBE32(at: framed.count - 4)
            if dec.crc32() != expected { return Decbuf(error: .invalidChecksum) }
        }
        return dec
    }

    /// Go: `NewDecbufUvarintAt`.
    public static func uvarintAt(_ bs: ByteSlice, _ off: Int) -> Decbuf {
        let maxVarintLen32 = 5
        guard bs.count >= off + maxVarintLen32 else { return Decbuf(error: .invalidSize) }
        let head = Array(bs.range(off, off + maxVarintLen32).rawBuffer)
        let (l, n) = GoVarint.uvarint(head)
        guard n > 0, n <= maxVarintLen32 else { return Decbuf(error: .invalidUvarint(n)) }
        guard bs.count >= off + n + Int(l) + 4 else { return Decbuf(error: .invalidSize) }

        let framed = bs.range(off + n, off + n + Int(l) + 4)
        let dec = Decbuf(framed.range(0, framed.count - 4))
        let expected = framed.loadBE32(at: framed.count - 4)
        if dec.crc32() != expected { return Decbuf(error: .invalidChecksum) }
        return dec
    }

    /// Go: `NewDecbufRaw`.
    public static func raw(_ bs: ByteSlice, length: Int) -> Decbuf {
        guard bs.count >= length else { return Decbuf(error: .invalidSize) }
        return Decbuf(bs.range(0, length))
    }

    // MARK: - Reads

    /// Go: `Crc32` — a checksum over the *remaining* bytes.
    public func crc32() -> UInt32 {
        var h = CRC32C()
        h.update(Array(b.rawBuffer))
        return h.final()
    }

    public mutating func skip(_ l: Int) {
        guard b.count >= l else { error = .invalidSize; return }
        b = b.range(l, b.count)
    }

    public mutating func byte() -> UInt8 {
        if error != nil { return 0 }
        guard b.count >= 1 else { error = .invalidSize; return 0 }
        let x = b[0]
        b = b.range(1, b.count)
        return x
    }

    public mutating func be32() -> UInt32 {
        if error != nil { return 0 }
        guard b.count >= 4 else { error = .invalidSize; return 0 }
        let x = b.loadBE32(at: 0)
        b = b.range(4, b.count)
        return x
    }

    public mutating func be64() -> UInt64 {
        if error != nil { return 0 }
        guard b.count >= 8 else { error = .invalidSize; return 0 }
        let x = b.loadBE64(at: 0)
        b = b.range(8, b.count)
        return x
    }

    public mutating func be32int() -> Int { Int(be32()) }
    public mutating func be64int64() -> Int64 { Int64(bitPattern: be64()) }
    public mutating func be64Float64() -> Double { Double(bitPattern: be64()) }

    public mutating func uvarint64() -> UInt64 {
        if error != nil { return 0 }
        let (x, n) = GoVarint.uvarint(Array(b.rawBuffer))
        guard n >= 1 else { error = .invalidSize; return 0 }
        b = b.range(n, b.count)
        return x
    }

    public mutating func uvarint() -> Int { Int(uvarint64()) }
    public mutating func uvarint32() -> UInt32 { UInt32(truncatingIfNeeded: uvarint64()) }

    public mutating func varint64() -> Int64 {
        if error != nil { return 0 }
        // Go decodes as unsigned first, then un-zig-zags.
        let (ux, n) = GoVarint.uvarint(Array(b.rawBuffer))
        guard n >= 1 else { error = .invalidSize; return 0 }
        var x = Int64(bitPattern: ux >> 1)
        if ux & 1 != 0 { x = ~x }
        b = b.range(n, b.count)
        return x
    }

    /// Go: `UvarintBytes`. Returns a view into the underlying buffer.
    public mutating func uvarintBytes() -> ByteSlice {
        let l = uvarint64()
        if error != nil { return ByteSlice(base: b.base, count: 0) }
        guard b.count >= Int(l) else {
            error = .invalidSize
            return ByteSlice(base: b.base, count: 0)
        }
        let s = b.range(0, Int(l))
        b = b.range(Int(l), b.count)
        return s
    }

    /// Go: `UvarintStr`.
    public mutating func uvarintStr() -> String {
        let s = uvarintBytes()
        return String(decoding: s.rawBuffer, as: UTF8.self)
    }

    /// Go: `ConsumePadding`.
    public mutating func consumePadding() {
        if error != nil { return }
        while b.count > 1 && b[0] == 0 {
            b = b.range(1, b.count)
        }
        if b.count < 1 { error = .invalidSize }
    }
}
