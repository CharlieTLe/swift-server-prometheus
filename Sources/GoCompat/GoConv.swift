//===----------------------------------------------------------------------===//
// Go's numeric *conversions*, as distinct from its `math` package.
//
// The Go spec calls an out-of-range float-to-integer conversion
// implementation-defined, so there is nothing to read: the behaviour has to be
// probed on the target architecture and pinned. Everything here is verified
// against Go on arm64 rather than inferred from the spec.
//===----------------------------------------------------------------------===//

/// Go's numeric conversions, where they differ from Swift's.
public enum GoConv: Sendable {

    /// Go: `int64(v)` for a `float64` — a bare `FCVTZS` on arm64, which **saturates**
    /// and maps NaN to zero.
    ///
    /// Swift's `Int64(_:)` traps on all three of those inputs instead, so every
    /// ported `int64(someFloat)` has to come through here.
    ///
    /// Probed, not assumed:
    ///
    /// | `v` | Go |
    /// |---|---|
    /// | `NaN` | `0` |
    /// | `+Inf`, `1e300`, anything ≥ 2**63 | `Int64.max` |
    /// | `-Inf`, `-1e300`, anything ≤ -2**63 | `Int64.min` |
    ///
    /// **Two live call sites, and both are reachable from an ordinary query rather
    /// than from a pathological one:**
    ///
    ///   * `promql/functions.go:2487`, `dateWrapper` — `int64(el.F)` on arbitrary
    ///     sample data with no guard at all. So `year(vector(NaN))` is legal PromQL
    ///     and would be a Swift crash; in Go it is 1970.
    ///   * `promql/parser`'s `durationOf` — `foo[9223372036.8547764]` parses,
    ///     because the range check at parse.go:1208 has an inclusive bound, and
    ///     reaches `time.Duration(math.Round(val * 1e9))`.
    ///
    /// The comparisons are against `Double(Int64.max)` and `Double(Int64.min)`,
    /// which are 2**63 and -2**63 exactly — `Int64.max` is not representable as a
    /// `Double`, so `>=` is the correct boundary and `>` would let 2**63 through to
    /// a trapping conversion.
    @inlinable
    public static func int64(_ v: Double) -> Int64 {
        if v.isNaN { return 0 }
        if v >= Double(Int64.max) { return Int64.max }
        if v <= Double(Int64.min) { return Int64.min }
        return Int64(v)
    }
}
