//===----------------------------------------------------------------------===//
// Ported from storage/errors.go @ v3.13.2
//===----------------------------------------------------------------------===//

internal import GoCompat

/// Go: `errDuplicateSampleForTimestamp`.
///
/// Separate from ``StorageError`` because it carries data and formats it into the
/// message. Go makes every instance compare equal to the sentinel
/// `ErrDuplicateSampleForTimestamp` via a custom `Is`, which is why
/// ``isDuplicateSampleForTimestamp(_:)`` exists rather than a bare `==`.
public struct DuplicateSampleForTimestampError: Error, Hashable, Sendable,
    CustomStringConvertible
{
    public var timestamp: Int64
    public var existing: Double
    public var existingIsHistogram: Bool
    public var newValue: Double

    /// Go: the zero value, which is the exported `ErrDuplicateSampleForTimestamp`
    /// sentinel. Its message is the bare "duplicate sample for timestamp",
    /// because `timestamp` is 0.
    public static let sentinel = DuplicateSampleForTimestampError(
        timestamp: 0, existing: 0, existingIsHistogram: false, newValue: 0)

    public init(
        timestamp: Int64, existing: Double, existingIsHistogram: Bool, newValue: Double
    ) {
        self.timestamp = timestamp
        self.existing = existing
        self.existingIsHistogram = existingIsHistogram
        self.newValue = newValue
    }

    /// Go: `NewDuplicateFloatErr`.
    public static func duplicateFloat(
        t: Int64, existing: Double, newValue: Double
    ) -> DuplicateSampleForTimestampError {
        DuplicateSampleForTimestampError(
            timestamp: t, existing: existing, existingIsHistogram: false, newValue: newValue)
    }

    /// Go: `NewDuplicateHistogramToFloatErr` — a float sample arriving at the
    /// timestamp of an existing histogram. Note `existing` stays 0 and is not
    /// printed.
    public static func duplicateHistogramToFloat(
        t: Int64, newValue: Double
    ) -> DuplicateSampleForTimestampError {
        DuplicateSampleForTimestampError(
            timestamp: t, existing: 0, existingIsHistogram: true, newValue: newValue)
    }

    /// errors.go:31. A timestamp of 0 short-circuits to the bare message, so the
    /// sentinel and a genuine sample at the Unix epoch render identically —
    /// Go's behaviour, replicated.
    public var description: String {
        if timestamp == 0 {
            return "duplicate sample for timestamp"
        }
        if existingIsHistogram {
            var out = "duplicate sample for timestamp \(timestamp)"
            out += "; overrides not allowed: existing is a histogram"
            out += ", new value \(GoFloat.formatG(newValue))"
            return out
        }
        var out = "duplicate sample for timestamp \(timestamp)"
        out += "; overrides not allowed: existing \(GoFloat.formatG(existing))"
        out += ", new value \(GoFloat.formatG(newValue))"
        return out
    }
}

/// Go: `errors.Is(err, ErrDuplicateSampleForTimestamp)`.
///
/// errors.go:52 — the custom `Is` returns true for *any*
/// `errDuplicateSampleForTimestamp` when the target is the sentinel, and
/// otherwise falls back to whole-struct equality. Callers across the tree test
/// against the sentinel, so this is the form they need.
public func isDuplicateSampleForTimestamp(_ err: any Error) -> Bool {
    err is DuplicateSampleForTimestampError
}
