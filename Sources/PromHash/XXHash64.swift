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

    /// Rotate left. Factored out deliberately: writing the four rotations of the
    /// accumulator merge inline as one chained expression exceeds the Swift 6.1
    /// type-checker's budget ("unable to type-check this expression in reasonable
    /// time"), even though 6.4 accepts it.
    @inline(__always)
    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always)
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        let a: UInt64 = acc &+ (input &* prime2)
        return rotl(a, 31) &* prime1
    }

    @inline(__always)
    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v: UInt64 = round(0, val)
        let a: UInt64 = acc ^ v
        return a &* prime1 &+ prime4
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
            // Split across statements so the type checker stays within budget on
            // Swift 6.1; see `rotl`.
            var acc: UInt64 = rotl(v1, 1)
            acc = acc &+ rotl(v2, 7)
            acc = acc &+ rotl(v3, 12)
            acc = acc &+ rotl(v4, 18)
            h = acc
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = prime5
        }

        h = h &+ UInt64(n)

        while n - i >= 8 {
            let k1: UInt64 = round(0, u64(i))
            h ^= k1
            h = rotl(h, 27) &* prime1 &+ prime4
            i += 8
        }
        if n - i >= 4 {
            h ^= UInt64(u32(i)) &* prime1
            h = rotl(h, 23) &* prime2 &+ prime3
            i += 4
        }
        while i < n {
            h ^= UInt64(b[i]) &* prime5
            h = rotl(h, 11) &* prime1
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
