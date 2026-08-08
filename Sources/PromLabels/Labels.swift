//===----------------------------------------------------------------------===//
// Ported from model/labels/labels_common.go and labels_slicelabels.go @ v3.13.2
//
// ADR-1: storage is a sorted [Label] (slicelabels-shaped), while the hash and
// packed encoding reproduce stringlabels (the default Go build). See
// Labels+GoEncoding.swift.
//===----------------------------------------------------------------------===//

internal import PromModel
private import GoCompat

/// Go: `labels.Label`.
public struct Label: Sendable, Hashable {
    public var name: String
    public var value: String

    @inlinable
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

extension Label: Comparable {
    /// Ordering is by name, then value — the order `labels.Compare` induces.
    @inlinable
    public static func < (a: Label, b: Label) -> Bool {
        if a.name != b.name { return a.name.utf8Lexicographic < b.name.utf8Lexicographic }
        return a.value.utf8Lexicographic < b.value.utf8Lexicographic
    }
}

/// Go: `labels.Labels`. Sorted by name; names are unique.
public struct Labels: Sendable, Hashable {

    /// Sorted by name, names unique. Go maintains the same invariant.
    @usableFromInline
    internal var storage: [Label]

    // MARK: - Construction

    /// Go: `labels.EmptyLabels()`.
    public static let empty = Labels()

    public init() { storage = [] }

    /// Go: `labels.New(ls...)` — sorts by name.
    ///
    /// Go's `New` documents that "the caller has to guarantee that all label
    /// names are unique"; we do not silently dedupe either.
    public init(_ labels: [Label]) {
        storage = labels.sorted {
            $0.name.utf8Lexicographic < $1.name.utf8Lexicographic
        }
    }

    /// Hot path: the caller guarantees sorted-by-name, unique names.
    @inlinable
    public init(sortedUnchecked storage: [Label]) {
        self.storage = storage
    }

    /// Go: `labels.FromStrings(ss...)`. Traps on an odd count, as Go panics.
    public init(strings ss: String...) {
        self.init(strings: ss)
    }

    public init(strings ss: [String]) {
        precondition(ss.count % 2 == 0, "invalid number of strings")
        var labels = [Label]()
        labels.reserveCapacity(ss.count / 2)
        for i in stride(from: 0, to: ss.count, by: 2) {
            labels.append(Label(ss[i], ss[i + 1]))
        }
        self.init(labels)
    }

    /// Go: `labels.FromMap(m)`.
    public init(map m: [String: String]) {
        self.init(m.map { Label($0.key, $0.value) })
    }

    // MARK: - Access

    /// Go: `Labels.Get(name)`. Returns `""` when absent, matching Go — ported
    /// code is full of `lset.Get(x) == ""` and reshaping it to Optional at every
    /// call site would invite divergence. Use `value(for:)` for Swift ergonomics.
    @inlinable
    public subscript(name: String) -> String {
        for l in storage where l.name == name { return l.value }
        return ""
    }

    @inlinable
    public func value(for name: String) -> String? {
        for l in storage where l.name == name { return l.value }
        return nil
    }

    /// Go: `Labels.Has(name)`.
    @inlinable
    public func has(_ name: String) -> Bool {
        storage.contains { $0.name == name }
    }

    /// Go: `Labels.IsEmpty()`.
    @inlinable
    public var isEmpty: Bool { storage.isEmpty }

    /// Go: `Labels.Len()`.
    @inlinable
    public var count: Int { storage.count }

    /// Go: `Labels.Map()`.
    public func map() -> [String: String] {
        var m = [String: String](minimumCapacity: storage.count)
        for l in storage { m[l.name] = l.value }
        return m
    }

    // MARK: - Ordering

    /// Go: `labels.Compare(a, b)`.
    ///
    /// Only the *sign* is contractual. Go's three label implementations return
    /// different magnitudes for the prefix case — stringlabels returns a byte
    /// length delta, slicelabels a label count delta — and all callers are sort
    /// comparators. See docs/PORTING.md.
    public static func compare(_ a: Labels, _ b: Labels) -> Int {
        // `Swift.min`: Labels is a Collection, so bare `min` resolves to the
        // instance method.
        let l = Swift.min(a.storage.count, b.storage.count)
        for i in 0..<l {
            let x = a.storage[i]
            let y = b.storage[i]
            if x.name != y.name {
                return x.name.utf8Lexicographic < y.name.utf8Lexicographic ? -1 : 1
            }
            if x.value != y.value {
                return x.value.utf8Lexicographic < y.value.utf8Lexicographic ? -1 : 1
            }
        }
        // All labels so far in common: the set with fewer labels comes first.
        return a.storage.count - b.storage.count
    }
}

extension Labels: Comparable {
    @inlinable
    public static func < (a: Labels, b: Labels) -> Bool { compare(a, b) < 0 }
}

extension Labels: RandomAccessCollection {
    public typealias Element = Label
    public typealias Index = Int

    @inlinable public var startIndex: Int { storage.startIndex }
    @inlinable public var endIndex: Int { storage.endIndex }
    @inlinable public subscript(position: Int) -> Label { storage[position] }
}

// MARK: - String rendering

extension Labels: CustomStringConvertible {

    /// Go: `Labels.String()` (`stringImpl(addSpace: true)`).
    public var description: String { stringImpl(addSpace: true) }

    /// Go: `Labels.StringNoSpace()`.
    public var descriptionNoSpace: String { stringImpl(addSpace: false) }

    private func stringImpl(addSpace: Bool) -> String {
        var out = "{"
        var i = 0
        for l in storage {
            if i > 0 {
                out += addSpace ? ", " : ","
            }
            // Go quotes names that fail *legacy* validation, regardless of the
            // configured scheme (labels_common.go stringImpl).
            if ValidationScheme.legacy.isValidLabelName(l.name) {
                out += l.name
            } else {
                out += GoStrconv.quote(l.name)
            }
            out += "="
            out += GoStrconv.quote(l.value)
            i += 1
        }
        out += "}"
        return out
    }
}

// MARK: - Byte-ordered string comparison

extension String {
    /// Go compares strings by UTF-8 byte value. Swift's `<` on `String` uses
    /// Unicode canonical ordering, which differs (e.g. for combining sequences),
    /// so every ported comparison must go through this.
    @inlinable
    var utf8Lexicographic: UTF8ByteOrder { UTF8ByteOrder(self) }
}

/// A `Comparable` wrapper giving Go's byte-wise string ordering.
@usableFromInline
struct UTF8ByteOrder: Comparable {
    @usableFromInline let value: String
    @inlinable init(_ value: String) { self.value = value }

    @inlinable
    static func < (a: UTF8ByteOrder, b: UTF8ByteOrder) -> Bool {
        var x = a.value
        var y = b.value
        return x.withUTF8 { xb in
            y.withUTF8 { yb in
                let n = min(xb.count, yb.count)
                for i in 0..<n where xb[i] != yb[i] {
                    return xb[i] < yb[i]
                }
                return xb.count < yb.count
            }
        }
    }

    @usableFromInline
    static func == (a: UTF8ByteOrder, b: UTF8ByteOrder) -> Bool { a.value == b.value }
}
