//===----------------------------------------------------------------------===//
// Ported from github.com/cespare/xxhash/v2 @ v2.3.0 (XXH64, seed 0)
//
// `labels.Hash()` is xxhash64 over the stringlabels packed encoding, and
// `HashForLabels`/`HashWithoutLabels` are xxhash64 over 0xFF-framed name/value
// pairs. See docs/DECISIONS.md ADR-1.
//===----------------------------------------------------------------------===//

public enum XXHash64: Sendable {

    private static let prime1: UInt64 = 11_400_714_785_074_694_791
    private static let prime2: UInt64 = 14_029_467_366_897_019_727
    private static let prime3: UInt64 = 1_609_587_929_392_839_161
    private static let prime4: UInt64 = 9_650_029_242_287_828_579
    private static let prime5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always)
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ (input &* prime2)
        acc = (acc << 31) | (acc >> 33)
        return acc &* prime1
    }

    @inline(__always)
    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let val = round(0, val)
        var acc = acc ^ val
        acc = acc &* prime1 &+ prime4
        return acc
    }

    /// Go: `xxhash.Sum64`.
    public static func sum64(_ b: [UInt8]) -> UInt64 {
        b.withUnsafeBufferPointer { sum64(UnsafeRawBufferPointer($0)) }
    }

    /// Go: `xxhash.Sum64String`.
    public static func sum64(_ s: String) -> UInt64 {
        var s = s
        return s.withUTF8 { sum64(UnsafeRawBufferPointer($0)) }
    }

    public static func sum64(_ b: UnsafeRawBufferPointer) -> UInt64 {
        let n = b.count
        var h: UInt64

        @inline(__always)
        func u64(_ i: Int) -> UInt64 { b.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian }
        @inline(__always)
        func u32(_ i: Int) -> UInt32 { b.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }

        var i = 0
        if n >= 32 {
            var v1 = prime1 &+ prime2
            var v2 = prime2
            var v3: UInt64 = 0
            var v4 = 0 &- prime1
            while n - i >= 32 {
                v1 = round(v1, u64(i))
                v2 = round(v2, u64(i + 8))
                v3 = round(v3, u64(i + 16))
                v4 = round(v4, u64(i + 24))
                i += 32
            }
            h = ((v1 << 1) | (v1 >> 63))
                &+ ((v2 << 7) | (v2 >> 57))
                &+ ((v3 << 12) | (v3 >> 52))
                &+ ((v4 << 18) | (v4 >> 46))
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = prime5
        }

        h = h &+ UInt64(n)

        while n - i >= 8 {
            let k1 = round(0, u64(i))
            h ^= k1
            h = ((h << 27) | (h >> 37)) &* prime1 &+ prime4
            i += 8
        }
        if n - i >= 4 {
            h ^= UInt64(u32(i)) &* prime1
            h = ((h << 23) | (h >> 41)) &* prime2 &+ prime3
            i += 4
        }
        while i < n {
            h ^= UInt64(b[i]) &* prime5
            h = ((h << 11) | (h >> 53)) &* prime1
            i += 1
        }

        // Avalanche.
        h ^= h >> 33
        h = h &* prime2
        h ^= h >> 29
        h = h &* prime3
        h ^= h >> 32
        return h
    }
}
