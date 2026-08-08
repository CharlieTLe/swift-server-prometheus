//===----------------------------------------------------------------------===//
// Ported from model/labels/labels_common.go (Builder methods) and
// labels_slicelabels.go (Builder struct/Reset/Labels, ScratchBuilder) @ v3.13.2
//===----------------------------------------------------------------------===//

/// Go: `labels.Builder`. Accumulates deletions and additions over a base set.
///
/// Go's Builder is a pointer type used as `b.Del(x); b.Set(y, z); b.Labels()`.
/// Here it is a struct with mutating methods, which is the same usage pattern.
public struct LabelsBuilder: Sendable {

    private var base: Labels
    private var del: [String]
    private var add: [Label]

    public init(_ base: Labels = .empty) {
        self.base = base
        self.del = []
        self.add = []
        reset(base)
    }

    /// Go: `Builder.Reset(base)`.
    ///
    /// Note base labels with an **empty value** are recorded as deletions: Go
    /// treats an empty label value as equivalent to the label being absent.
    public mutating func reset(_ base: Labels) {
        self.base = base
        del.removeAll(keepingCapacity: true)
        add.removeAll(keepingCapacity: true)
        for l in base where l.value.isEmpty {
            del.append(l.name)
        }
    }

    /// Go: `Builder.Del(ns...)`.
    public mutating func del(_ names: String...) { del(names) }

    public mutating func del(_ names: [String]) {
        for n in names {
            // Go iterates `range b.add` while splicing it, which works only
            // because Set() keeps names unique, so at most one entry matches.
            if let i = add.firstIndex(where: { $0.name == n }) {
                add.remove(at: i)
            }
            del.append(n)
        }
    }

    /// Go: `Builder.Keep(ns...)` — deletes everything in the base except `names`.
    public mutating func keep(_ names: String...) { keep(names) }

    public mutating func keep(_ names: [String]) {
        for l in base where !names.contains(l.name) {
            del.append(l.name)
        }
    }

    /// Go: `Builder.Set(n, v)`. An empty value deletes the label.
    public mutating func set(_ name: String, _ value: String) {
        if value.isEmpty {
            del(name)
            return
        }
        if let i = add.firstIndex(where: { $0.name == name }) {
            add[i].value = value
            return
        }
        add.append(Label(name, value))
    }

    /// Go: `Builder.Get(n)`.
    public func get(_ name: String) -> String {
        // Del() removes from .add but Set() does not remove from .del, so .add
        // must be consulted first.
        if let l = add.first(where: { $0.name == name }) { return l.value }
        if del.contains(name) { return "" }
        return base[name]
    }

    /// Go: `Builder.Range(f)`.
    public func forEach(_ body: (Label) -> Void) {
        // Go snapshots add/del so the callback may mutate the builder.
        let origAdd = add
        let origDel = del
        for l in base where !origDel.contains(l.name) && !origAdd.contains(where: { $0.name == l.name }) {
            body(l)
        }
        for a in origAdd { body(a) }
    }

    /// Go: `Builder.Labels()`. Returns the base unchanged if nothing was modified.
    public func labels() -> Labels {
        if del.isEmpty && add.isEmpty { return base }

        var res = [Label]()
        res.reserveCapacity(max(base.count + add.count - del.count, 1))
        for l in base where !del.contains(l.name) && !add.contains(where: { $0.name == l.name }) {
            res.append(l)
        }
        if !add.isEmpty {
            // The base is already ordered, so sorting is only needed when adding.
            res.append(contentsOf: add)
            res.sort { $0.name.utf8Lexicographic < $1.name.utf8Lexicographic }
        }
        return Labels(sortedUnchecked: res)
    }
}

/// Go: `labels.ScratchBuilder`. Builds a Labels from scratch without a base.
public struct ScratchBuilder: Sendable {

    private var add: [Label]

    public init(capacity: Int = 0) {
        add = []
        add.reserveCapacity(capacity)
    }

    /// Go: `ScratchBuilder.Reset()`.
    public mutating func reset() { add.removeAll(keepingCapacity: true) }

    /// Go: `ScratchBuilder.Add(name, value)`.
    ///
    /// Adding the same name twice produces a duplicate label, which is invalid —
    /// Go does not check for it either.
    public mutating func add(_ name: String, _ value: String) {
        add.append(Label(name, value))
    }

    /// Go: `ScratchBuilder.Sort()` — by name only.
    public mutating func sort() {
        add.sort { $0.name.utf8Lexicographic < $1.name.utf8Lexicographic }
    }

    /// Go: `ScratchBuilder.Assign(ls)`.
    public mutating func assign(_ ls: Labels) { add = Array(ls) }

    /// Go: `ScratchBuilder.Labels()`. Not sorted unless `sort()` was called.
    public func labels() -> Labels { Labels(sortedUnchecked: add) }

    /// Go: `ScratchBuilder.Overwrite(&ls)`.
    public func overwrite(_ ls: inout Labels) { ls = Labels(sortedUnchecked: add) }

    public var count: Int { add.count }
}
