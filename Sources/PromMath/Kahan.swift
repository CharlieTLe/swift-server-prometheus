//===----------------------------------------------------------------------===//
// Ported from util/kahansum/kahansum.go @ v3.13.2
//
// Kahan–Neumaier compensated summation. This is a *bit-exactness* requirement,
// not an accuracy nicety: PromQL's `sum`, `avg`, `sum_over_time` and the
// histogram `KahanAdd` family accumulate through here, and the conformance suite
// pins their results.
//
// Go must defeat float fusing explicitly (`inc = float64(inc)` etc., see
// prometheus/prometheus#16895) because the Go spec permits FMA contraction.
// Swift evaluates each floating-point operation to IEEE 754 precision and does
// not contract, so the casts have no Swift analogue — but do not "simplify" the
// expression shapes below, because the association order is what makes the
// compensation term correct.
//===----------------------------------------------------------------------===//

public enum Kahan: Sendable {

    /// Go: `kahansum.isInf`. Avoids `isInfinite` for the same inlining reason.
    @inline(__always)
    private static func isInf(_ f: Double) -> Bool {
        f > Double.greatestFiniteMagnitude || f < -Double.greatestFiniteMagnitude
    }

    /// Go: `kahansum.Inc`. Returns the new running sum and compensation term.
    @inline(__always)
    public static func inc(_ inc: Double, _ sum: Double, _ c: Double) -> (sum: Double, c: Double) {
        var c = c
        let t = sum + inc
        if isInf(t) {
            c = 0
        } else if abs(sum) >= abs(inc) {
            // Neumaier improvement: swap if the next term is larger than the sum.
            c += (sum - t) + inc
        } else {
            c += (inc - t) + sum
        }
        return (t, c)
    }

    /// Go: `kahansum.Dec`.
    @inline(__always)
    public static func dec(_ dec: Double, _ sum: Double, _ c: Double) -> (sum: Double, c: Double) {
        inc(-dec, sum, c)
    }
}
