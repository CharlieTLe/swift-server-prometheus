//===----------------------------------------------------------------------===//
// Ported from model/value/value.go @ v3.13.2
//===----------------------------------------------------------------------===//

/// Go: `model/value`. Prometheus's two special NaN payloads.
///
/// These are bit patterns, not just "some NaN": `StaleNaN` is a staleness marker
/// that must never compare equal to an ordinary NaN, and it travels through
/// chunk encodings and the wire format as an exact payload.
public enum PromValue: Sendable {

    /// Go: `value.NormalNaN`. A quiet NaN; also what `math.NaN()` returns.
    public static let normalNaNBits: UInt64 = 0x7ff8_0000_0000_0001

    /// Go: `value.StaleNaN`. A signalling NaN (MSB of the mantissa is 0), chosen
    /// with many leading zeros to leave room for richer markers later. It is 2
    /// rather than 1 so a human can tell it from `NormalNaN` when debugging.
    public static let staleNaNBits: UInt64 = 0x7ff0_0000_0000_0002

    public static let normalNaN = Double(bitPattern: normalNaNBits)
    public static let staleNaN = Double(bitPattern: staleNaNBits)

    /// Go: `value.IsStaleNaN`. An exact bit-pattern comparison, deliberately.
    @inlinable
    public static func isStaleNaN(_ v: Double) -> Bool {
        v.bitPattern == staleNaNBits
    }
}
