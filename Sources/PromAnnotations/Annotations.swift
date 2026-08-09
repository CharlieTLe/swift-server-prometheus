//===----------------------------------------------------------------------===//
// Ported from util/annotations/annotations.go @ v3.13.2
//===----------------------------------------------------------------------===//

public import PromPosRange

/// Go: `Annotations`, a `map[string]error` keyed on the annotation's message.
///
/// **Deliberate divergence — iteration order.** Go's is a map, so `AsStrings`
/// returns warnings and infos in randomised order, and when `maxWarnings` or
/// `maxInfos` truncates, *which* annotations survive is random too. There is
/// therefore no order to be byte-exact against. This port keeps first-insertion
/// order so output is reproducible; a Swift `Dictionary` would have been no
/// better than Go, since Swift seeds its hasher per process. See
/// docs/PORTING.md's documented exceptions.
///
/// Deduplication *is* contractual and is reproduced exactly: the key is the
/// annotation's message with no query set, so two annotations differing only in
/// position collapse into one — and the **last** one wins, because `Add` calls
/// `incoming.Merge(stored)` and `annoErr.Merge` returns its receiver.
public struct Annotations {

    /// Keys in first-insertion order.
    private var order: [String] = []
    private var entries: [String: any AnnotationError] = [:]

    /// Go: the zero value of `Annotations`, a nil map, which is usable as-is.
    public init() {}

    /// Go: `New()`.
    public static func new() -> Annotations { Annotations() }

    public var isEmpty: Bool { order.isEmpty }
    public var count: Int { order.count }

    /// Go: `Add`. Mutates in place and returns the receiver for chaining.
    @discardableResult
    public mutating func add(_ err: any AnnotationError) -> Annotations {
        var err = err
        let key = err.description
        if let previous = entries[key] {
            err = err.merge(previous)
        } else {
            order.append(key)
        }
        // annotations.go:52 stores under the *merged* error's key. For both
        // annoErr (Merge returns the receiver) and the monotonicity error (Merge
        // returns `other`, whose message is unchanged) that is the same key, so
        // `order` cannot go stale.
        entries[err.description] = err
        return self
    }

    /// Go: `Merge`. Adds `other`'s contents to the receiver, in place.
    @discardableResult
    public mutating func merge(_ other: Annotations) -> Annotations {
        for key in other.order {
            guard var value = other.entries[key] else { continue }
            if let previous = entries[key] {
                value = value.merge(previous)
            } else {
                order.append(key)
            }
            entries[key] = value
        }
        return self
    }

    /// Go: `AsErrors`.
    public func asErrors() -> [any Error] {
        order.compactMap { entries[$0] }
    }

    /// Go: `AsStrings`. Renders every annotation against `query` so positions
    /// appear, split into warnings and infos.
    ///
    /// `maxWarnings`/`maxInfos` of 0 mean no limit. When the limit bites, Go
    /// appends a count line — reproduced verbatim, including the singular/plural
    /// wording Go does not vary.
    public func asStrings(query: String, maxWarnings: Int, maxInfos: Int) -> (
        warnings: [String], infos: [String]
    ) {
        var warnings: [String] = []
        var infos: [String] = []
        var warnSkipped = 0
        var infoSkipped = 0

        for key in order {
            guard let err = entries[key] else { continue }
            // annotations.go:100 — SetQuery mutates the stored annotation, so the
            // map keys are now stale. Go does not rekey either.
            err.setQuery(query)
            switch err.kind {
            case .info:
                if maxInfos == 0 || infos.count < maxInfos {
                    infos.append(err.description)
                } else {
                    infoSkipped += 1
                }
            case .warning:
                if maxWarnings == 0 || warnings.count < maxWarnings {
                    warnings.append(err.description)
                } else {
                    warnSkipped += 1
                }
            }
        }

        if warnSkipped > 0 {
            warnings.append("\(warnSkipped) more warning annotations omitted")
        }
        if infoSkipped > 0 {
            infos.append("\(infoSkipped) more info annotations omitted")
        }
        return (warnings, infos)
    }

    /// Go: `CountWarningsAndInfo`.
    public func countWarningsAndInfo() -> (countWarnings: Int, countInfo: Int) {
        var countWarnings = 0
        var countInfo = 0
        for key in order {
            switch entries[key]?.kind {
            case .warning: countWarnings += 1
            case .info: countInfo += 1
            case nil: break
            }
        }
        return (countWarnings, countInfo)
    }
}

extension Annotations {
    /// Convenience for the common `var annos annotations.Annotations;
    /// annos.Add(...)` shape at a call site that has only a position.
    @discardableResult
    public mutating func add(
        _ make: (PositionRange) -> any AnnotationError, _ pos: PositionRange
    ) -> Annotations {
        add(make(pos))
    }
}
