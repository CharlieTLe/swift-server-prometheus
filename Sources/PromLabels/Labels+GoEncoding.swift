//===----------------------------------------------------------------------===//
// Ported from model/labels/labels_stringlabels.go @ v3.13.2
//
// The packed "stringlabels" encoding and the hashes derived from it. See ADR-1
// for why a slice-backed Labels reproduces stringlabels' hash: it is the default
// Go build, so oracle fixtures come from a stock binary.
//
// ⚠️ Hash() is NOT canonical across Go's label implementations. stringlabels
// hashes the packed bytes below; slicelabels hashes 0xFF-framed name/value
// pairs. They differ. HashForLabels/HashWithoutLabels *are* 0xFF-framed in both.
//===----------------------------------------------------------------------===//

private import GoCompat
private import PromHash
internal import PromModel

extension Labels {

    /// Separator between name/value pairs in `Bytes` and the `HashFor`/`HashWithout`
    /// framings. Go: `labels.sep`.
    @usableFromInline static let sep: UInt8 = 0xFF

    // MARK: - Packed encoding

    /// The stringlabels packed representation.
    ///
    /// Per label, in sorted-name order: `size(name), name, size(value), value`.
    /// A size below 255 is one byte; otherwise `0xFF` followed by three bytes
    /// little-endian. Maximum length 2^24 (16 MB).
    /// Go: `marshalLabelsToSizedBuffer` / `encodeSize`.
    public func goEncodedBytes() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(goEncodedSize())
        for l in self {
            Self.appendSize(&out, l.name.utf8.count)
            out.append(contentsOf: l.name.utf8)
            Self.appendSize(&out, l.value.utf8.count)
            out.append(contentsOf: l.value.utf8)
        }
        return out
    }

    /// Go: `labelsSize`.
    public func goEncodedSize() -> Int {
        var n = 0
        for l in self {
            let ln = l.name.utf8.count
            let lv = l.value.utf8.count
            n += ln + Self.sizeWhenEncoded(ln) + lv + Self.sizeWhenEncoded(lv)
        }
        return n
    }

    /// Go: `encodeSize`.
    @inlinable
    static func appendSize(_ out: inout [UInt8], _ v: Int) {
        if v < 255 {
            out.append(UInt8(v))
        } else {
            out.append(255)
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
        }
    }

    /// Go: `sizeWhenEncoded`.
    @inlinable
    static func sizeWhenEncoded(_ v: Int) -> Int { v < 255 ? 1 : 4 }

    /// Decode a packed representation. Go: `decodeString` in a loop.
    public static func fromGoEncodedBytes(_ data: [UInt8]) -> Labels? {
        var out = [Label]()
        var i = 0
        func decodeSize() -> Int? {
            guard i < data.count else { return nil }
            let b = data[i]
            i += 1
            if b == 255 {
                guard i + 3 <= data.count else { return nil }
                let v = Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16)
                i += 3
                return v
            }
            return Int(b)
        }
        func decodeString() -> String? {
            guard let n = decodeSize(), i + n <= data.count else { return nil }
            let s = String(decoding: data[i..<(i + n)], as: UTF8.self)
            i += n
            return s
        }
        while i < data.count {
            guard let name = decodeString(), let value = decodeString() else { return nil }
            out.append(Label(name, value))
        }
        return Labels(sortedUnchecked: out)
    }

    // MARK: - Hashing

    /// Go: `Labels.Hash()` under the default (stringlabels) build —
    /// `xxhash.Sum64(ls.data)` over the packed encoding above.
    ///
    /// Not observable in PromQL output except through `limit_ratio`
    /// (`HashRatioSampler.SampleOffset`), whose conformance test tolerates
    /// hashing luck. See docs/PORTING.md exception 2.
    public func goHash() -> UInt64 {
        XXHash64.sum64(goEncodedBytes())
    }

    /// Go: `Labels.HashForLabels(b, names...)`. `names` must be sorted ascending.
    ///
    /// Framing is `name 0xFF value 0xFF`, which *is* identical across all three
    /// Go label implementations.
    public func goHash(forNames names: [String]) -> UInt64 {
        var b = [UInt8]()
        var j = 0
        for l in self {
            while j < names.count && names[j].utf8Lexicographic < l.name.utf8Lexicographic {
                j += 1
            }
            if j == names.count { break }
            if l.name == names[j] {
                b.append(contentsOf: l.name.utf8)
                b.append(Self.sep)
                b.append(contentsOf: l.value.utf8)
                b.append(Self.sep)
            }
        }
        return XXHash64.sum64(b)
    }

    /// Go: `Labels.HashWithoutLabels(b, names...)`. `names` must be sorted ascending.
    ///
    /// Note Go also unconditionally drops `__name__` here, independently of `names`.
    public func goHash(withoutNames names: [String]) -> UInt64 {
        var b = [UInt8]()
        var j = 0
        for l in self {
            while j < names.count && names[j].utf8Lexicographic < l.name.utf8Lexicographic {
                j += 1
            }
            if l.name == LabelName.metricName || (j < names.count && l.name == names[j]) {
                continue
            }
            b.append(contentsOf: l.name.utf8)
            b.append(Self.sep)
            b.append(contentsOf: l.value.utf8)
            b.append(Self.sep)
        }
        return XXHash64.sum64(b)
    }
}
