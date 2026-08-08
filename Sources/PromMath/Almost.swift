//===----------------------------------------------------------------------===//
// Ported from util/almost/almost.go @ v3.13.2
//
// Mirrors Go's dependency direction: util/almost imports model/value.
//===----------------------------------------------------------------------===//

public import PromModel

/// Go: `util/almost`.
public enum Almost: Sendable {

    /// The smallest positive normal `Double`. Go: `almost.minNormal`.
    public static let minNormal = Double(bitPattern: 0x0010_0000_0000_0000)

    /// Go: `almost.Equal`.
    ///
    /// True when `a` and `b` differ by less than their sum times `epsilon`, or
    /// when both are `StaleNaN`, or when both are any other NaN. Used by the
    /// PromQL conformance runner to compare expected against actual samples.
    public static func equal(_ a: Double, _ b: Double, _ epsilon: Double) -> Bool {
        // StaleNaN is a staleness marker; it must not compare equal to other NaNs.
        if PromValue.isStaleNaN(a) || PromValue.isStaleNaN(b) {
            return PromValue.isStaleNaN(a) && PromValue.isStaleNaN(b)
        }

        // NaN has no equality, but for testing we still want to know whether both
        // values are NaN.
        if a.isNaN && b.isNaN {
            return true
        }

        // Cf. http://floating-point-gui.de/errors/comparison/
        if a == b {
            return true
        }

        let absSum = abs(a) + abs(b)
        let diff = abs(a - b)

        if a == 0 || b == 0 || absSum < minNormal {
            return diff < epsilon * minNormal
        }
        return diff / min(absSum, Double.greatestFiniteMagnitude) < epsilon
    }
}
