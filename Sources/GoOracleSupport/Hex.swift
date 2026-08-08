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
