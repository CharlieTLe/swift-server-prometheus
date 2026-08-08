//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/encoding/binary/varint.go
//
// LEB128 varints, with Go's exact overflow-signalling behaviour: a negative
// return means "malformed, and this many bytes were consumed". TSDB's index and
// WAL formats depend on both the encoding and the error signalling
// (tsdb/encoding/encoding.go, which additionally uses github.com/dennwc/varint
// for decoding — same semantics, faster implementation).
//===----------------------------------------------------------------------===//

public enum GoVarint: Sendable {

    /// Go: `binary.MaxVarintLen64`.
    public static let maxVarintLen64 = 10

    // MARK: - Encoding

    /// Go: `binary.PutUvarint`. Appends and returns the number of bytes written.
    @discardableResult
    public static func putUvarint(_ out: inout [UInt8], _ x: UInt64) -> Int {
        var x = x
        var n = 0
        while x >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: x) | 0x80)
            x >>= 7
            n += 1
        }
        out.append(UInt8(truncatingIfNeeded: x))
        return n + 1
    }

    /// Go: `binary.PutVarint`. Zig-zag encoded, then as a uvarint.
    @discardableResult
    public static func putVarint(_ out: inout [UInt8], _ x: Int64) -> Int {
        // Go: ux := uint64(x) << 1; if x < 0 { ux = ^ux }
        var ux = UInt64(bitPattern: x) << 1
        if x < 0 { ux = ~ux }
        return putUvarint(&out, ux)
    }

    // MARK: - Decoding

    /// Go: `binary.Uvarint`.
    ///
    /// Returns `(value, n)` where `n > 0` is the number of bytes consumed,
    /// `n == 0` means the buffer was too small, and `n < 0` means the value
    /// overflows a `UInt64` (`-n` bytes were read).
    public static func uvarint(_ buf: [UInt8], _ start: Int = 0) -> (UInt64, Int) {
        var x: UInt64 = 0
        var s: UInt64 = 0
        var i = 0
        while start + i < buf.count {
            if i == maxVarintLen64 {
                return (0, -(i + 1))  // overflow
            }
            let b = buf[start + i]
            if b < 0x80 {
                if i == maxVarintLen64 - 1 && b > 1 {
                    return (0, -(i + 1))  // overflow
                }
                return (x | (UInt64(b) << s), i + 1)
            }
            x |= UInt64(b & 0x7F) << s
            s += 7
            i += 1
        }
        return (0, 0)
    }

    /// Go: `binary.Varint`.
    public static func varint(_ buf: [UInt8], _ start: Int = 0) -> (Int64, Int) {
        let (ux, n) = uvarint(buf, start)
        var x = Int64(bitPattern: ux >> 1)
        if ux & 1 != 0 { x = ~x }
        return (x, n)
    }
}

//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/encoding/binary/binary.go
//===----------------------------------------------------------------------===//

/// Go: `binary.BigEndian`. TSDB's on-disk formats are big-endian throughout.
public enum GoBigEndian: Sendable {

    @inlinable
    public static func uint16(_ b: [UInt8], _ i: Int = 0) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    @inlinable
    public static func uint32(_ b: [UInt8], _ i: Int = 0) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    @inlinable
    public static func uint64(_ b: [UInt8], _ i: Int = 0) -> UInt64 {
        UInt64(b[i]) << 56 | UInt64(b[i + 1]) << 48 | UInt64(b[i + 2]) << 40
            | UInt64(b[i + 3]) << 32 | UInt64(b[i + 4]) << 24 | UInt64(b[i + 5]) << 16
            | UInt64(b[i + 6]) << 8 | UInt64(b[i + 7])
    }

    @inlinable
    public static func append(_ out: inout [UInt8], _ x: UInt16) {
        out.append(UInt8(truncatingIfNeeded: x >> 8))
        out.append(UInt8(truncatingIfNeeded: x))
    }

    @inlinable
    public static func append(_ out: inout [UInt8], _ x: UInt32) {
        out.append(UInt8(truncatingIfNeeded: x >> 24))
        out.append(UInt8(truncatingIfNeeded: x >> 16))
        out.append(UInt8(truncatingIfNeeded: x >> 8))
        out.append(UInt8(truncatingIfNeeded: x))
    }

    @inlinable
    public static func append(_ out: inout [UInt8], _ x: UInt64) {
        out.append(UInt8(truncatingIfNeeded: x >> 56))
        out.append(UInt8(truncatingIfNeeded: x >> 48))
        out.append(UInt8(truncatingIfNeeded: x >> 40))
        out.append(UInt8(truncatingIfNeeded: x >> 32))
        out.append(UInt8(truncatingIfNeeded: x >> 24))
        out.append(UInt8(truncatingIfNeeded: x >> 16))
        out.append(UInt8(truncatingIfNeeded: x >> 8))
        out.append(UInt8(truncatingIfNeeded: x))
    }
}

/// Go: `binary.LittleEndian`. Used by the stringlabels length prefix (3-byte LE)
/// and by tombstone/ULID bits.
public enum GoLittleEndian: Sendable {

    @inlinable
    public static func uint32(_ b: [UInt8], _ i: Int = 0) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    @inlinable
    public static func uint64(_ b: [UInt8], _ i: Int = 0) -> UInt64 {
        UInt64(b[i]) | UInt64(b[i + 1]) << 8 | UInt64(b[i + 2]) << 16 | UInt64(b[i + 3]) << 24
            | UInt64(b[i + 4]) << 32 | UInt64(b[i + 5]) << 40 | UInt64(b[i + 6]) << 48
            | UInt64(b[i + 7]) << 56
    }
}
