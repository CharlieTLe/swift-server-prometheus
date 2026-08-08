//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/hash/crc32 (Castagnoli polynomial)
//
// CRC-32C guards every TSDB on-disk structure: index sections, chunk entries,
// WAL record frames, tombstones. `tsdb/encoding/encoding.go` threads a
// `*crc32.Table` through `NewDecbufAt`/`PutHash`.
//
// ADR: table-driven slicing-by-8 rather than a C shim. ARMv8 has `crc32c`
// instructions but they are not reachable from Swift without inline asm, and the
// table approach is portable and fast enough. Revisit in Phase 10 if profiling
// says otherwise.
//===----------------------------------------------------------------------===//

public struct CRC32C: Sendable {

    /// Go: `crc32.Castagnoli`, the reversed polynomial.
    public static let polynomial: UInt32 = 0x82F6_3B78

    /// Eight tables for slicing-by-8. `tables[0]` is the classic byte-at-a-time table.
    private static let tables: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1
            }
            t[0][i] = crc
        }
        for i in 0..<256 {
            var crc = t[0][i]
            for k in 1..<8 {
                crc = t[0][Int(crc & 0xFF)] ^ (crc >> 8)
                t[k][i] = crc
            }
        }
        return t
    }()

    /// Running value, stored pre-inversion exactly as Go's `crc32.Update` does.
    private var crc: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// Go: `crc32.Checksum(data, castagnoliTable)`.
    public static func checksum(_ data: [UInt8]) -> UInt32 {
        var h = CRC32C()
        h.update(data)
        return h.final()
    }

    public static func checksum(_ data: ArraySlice<UInt8>) -> UInt32 {
        var h = CRC32C()
        h.update(data)
        return h.final()
    }

    /// Go: `hash.Hash.Reset`.
    public mutating func reset() { crc = 0xFFFF_FFFF }

    public mutating func update(_ data: [UInt8]) { update(data[...]) }

    /// Go: `crc32.Update`.
    public mutating func update(_ data: ArraySlice<UInt8>) {
        var c = crc
        let t = CRC32C.tables
        var i = data.startIndex
        let end = data.endIndex

        // Slicing-by-8: consume eight bytes per iteration. The first four are
        // folded into the running CRC as a little-endian word (the polynomial is
        // reflected), the next four index the higher tables directly.
        //
        // Accumulated stepwise rather than as one eight-term XOR chain, which
        // exceeds the Swift 6.1 type checker's budget.
        while end - i >= 8 {
            var w: UInt32 = 0
            for k in (0..<4).reversed() { w = (w << 8) | UInt32(data[i + k]) }
            w ^= c

            var acc = t[7][Int(w & 0xFF)]
            acc ^= t[6][Int((w >> 8) & 0xFF)]
            acc ^= t[5][Int((w >> 16) & 0xFF)]
            acc ^= t[4][Int((w >> 24) & 0xFF)]
            acc ^= t[3][Int(data[i + 4])]
            acc ^= t[2][Int(data[i + 5])]
            acc ^= t[1][Int(data[i + 6])]
            acc ^= t[0][Int(data[i + 7])]
            c = acc
            i += 8
        }

        // Tail, byte at a time.
        while i < end {
            c = t[0][Int((c ^ UInt32(data[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
        crc = c
    }

    /// The checksum value. Go: `hash.Hash32.Sum32`.
    public func final() -> UInt32 { ~crc }
}
