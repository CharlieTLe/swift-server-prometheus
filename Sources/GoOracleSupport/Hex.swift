//===----------------------------------------------------------------------===//
// Hex helpers for fixture payloads. Binary travels through JSON as hex so a
// fixture line stays a single readable line and JSON never reinterprets bytes.
//===----------------------------------------------------------------------===//

public enum Hex: Sendable {

    private static let digits = Array("0123456789abcdef".utf8)

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func encode(_ bytes: ArraySlice<UInt8>) -> String { encode(Array(bytes)) }

    public static func decode(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        precondition(u.count % 2 == 0, "odd-length hex string")
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        for i in stride(from: 0, to: u.count, by: 2) {
            out.append(nibble(u[i]) << 4 | nibble(u[i + 1]))
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: preconditionFailure("bad hex digit \(c)")
        }
    }
}

/// The oracle's `rleHex`/`unrleHex` — hex pairs with runs of zeros collapsed to `z<n>.`.
///
/// **Reversible, not a digest.** A padding run of the wrong length is still a diff. It exists because the
/// formats that use it are mostly padding: a WAL page is 32 KB and a head chunk file is pre-allocated to
/// 128 KB, so plain hex would make those fixtures tens of megabytes and hide the interesting bytes.
///
/// The trailing `.` on a run is load-bearing: hex pairs are themselves digits, so `z16372` followed by the
/// byte `0x11` would read back as a run of 1,637,211 without it. That ambiguity panicked the first run of the
/// WAL generator.
public enum RLEHex: Sendable {

    public static func encode(_ b: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < b.count {
            if b[i] == 0 {
                var j = i
                while j < b.count && b[j] == 0 { j += 1 }
                out += "z"
                out += String(j - i)
                out += "."
                i = j
                continue
            }
            let hex = String(b[i], radix: 16)
            out += hex.count == 1 ? "0" + hex : hex
            i += 1
        }
        return out
    }

    public static func decode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "z" {
                var j = i + 1
                while j < chars.count && chars[j] != "." { j += 1 }
                let n = Int(String(chars[(i + 1)..<j]))!
                out.append(contentsOf: [UInt8](repeating: 0, count: n))
                i = j + 1
                continue
            }
            out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
            i += 2
        }
        return out
    }
}
