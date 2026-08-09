//===----------------------------------------------------------------------===//
// Ported from promql/parser/ast.go @ v3.13.2
//
// The nodes are **final classes behind a protocol**, not an indirect enum. See
// ADR-11: the engine mutates nodes in place at query-preparation time —
// `VectorSelector.Timestamp`, `Offset`, `UnexpandedSeriesSet` and `Series` are
// all filled in after parsing, and `preprocessExpr` rewrites the tree — so
// reference semantics keep Phase 5 a field assignment instead of a tree rebuild.
// The cost is that dispatch is `as?` chains rather than an exhaustive switch.
//
// Two sets of fields are deliberately absent:
//
//   - `VectorSelector.UnexpandedSeriesSet` and `.Series` are `storage.SeriesSet`
//     and `[]storage.Series`. Phase 5 brings the storage protocols; inventing a
//     placeholder now would be a guess to unpick later.
//   - `EvalStmt` and `TestStmt` are statements the parser never produces. They
//     carry `time.Time` and an evaluation context, and belong with the engine.
//===----------------------------------------------------------------------===//

public import PromLabels
public import GoCompat

// MARK: - Protocols

/// Go: `Node` — any node in the AST.
///
/// `description` is Go's `String()`: a rendering that parses back to the same
/// node. `AnyObject` is load-bearing, not incidental — see the header.
public protocol Node: AnyObject, CustomStringConvertible {
    /// Go: `Pretty(level int)`.
    func pretty(_ level: Int) -> String

    /// Go: `PositionRange()`.
    var positionRange: PositionRange { get }

    /// What Go's `%T` renders for this node, minus the package qualifier.
    /// `Tree()` prints it, so it is observable output rather than a debug aid.
    var nodeTypeName: String { get }
}

/// Go: `Expr`.
public protocol Expr: Node {
    /// Go: `Type()` — the value type this expression evaluates to. A shallow
    /// check; the deep one happened at parse time.
    var type: ValueType { get }
}

/// Go: `Expressions` is `[]Expr` with methods, which a Swift array cannot have
/// while also being a class-bound `Node`. The three methods it carries are free
/// functions instead, and `Call.args` is a plain `[any Expr]`.
///
/// Nothing is lost: `ChildrenIter` yields a `Call`'s arguments individually
/// rather than the list, so no `Expressions` node ever reaches `Tree()`, and
/// `checkAST`'s `case Expressions` is unreachable from every parser entry point.
public enum Expressions {
    /// Go: `Expressions.String()`.
    public static func string(_ es: [any Expr]) -> String {
        switch es.count {
        case 0: return ""
        case 1: return es[0].description
        default:
            var b = es[0].description
            for e in es.dropFirst() {
                b += ", "
                b += e.description
            }
            return b
        }
    }

    /// Go: `Expressions.PositionRange()`. An empty list has no position, which
    /// Go spells as -1/-1 rather than 0/0.
    public static func positionRange(_ es: [any Expr]) -> PositionRange {
        if es.isEmpty { return PositionRange(start: -1, end: -1) }
        return mergeRanges(es[0], es[es.count - 1])
    }

    /// Go: `Expressions.Pretty(level int)`. No indent prefix: each element
    /// indents itself.
    public static func pretty(_ es: [any Expr], _ level: Int) -> String {
        if es.isEmpty { return "" }
        return es.map { $0.pretty(level) }.joined(separator: ",\n")
    }
}

// MARK: - Nodes

/// Go: `AggregateExpr` — an aggregation over a vector.
public final class AggregateExpr: Expr {
    /// The aggregation operation.
    public var op: ItemType
    /// The vector expression being aggregated.
    public var expr: (any Expr)?
    /// The parameter some aggregators take: `topk`'s k, `count_values`'s label.
    public var param: (any Expr)?
    /// The labels to group by.
    public var grouping: [String]
    /// Whether `grouping` is a drop list rather than a keep list.
    public var without: Bool
    public var posRange: PositionRange

    public init(
        op: ItemType = ItemType(0),
        expr: (any Expr)? = nil,
        param: (any Expr)? = nil,
        grouping: [String] = [],
        without: Bool = false,
        posRange: PositionRange = PositionRange(start: 0, end: 0)
    ) {
        self.op = op
        self.expr = expr
        self.param = param
        self.grouping = grouping
        self.without = without
        self.posRange = posRange
    }

    public var type: ValueType { .vector }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "AggregateExpr" }
}

/// Go: `BinaryExpr` — a binary operation between two expressions.
public final class BinaryExpr: Expr {
    public var op: ItemType
    public var lhs: any Expr
    public var rhs: any Expr

    /// How elements of the two sides are matched, when both are vectors. Nil
    /// when they are not — `checkAST` clears it in that case.
    public var vectorMatching: VectorMatching?

    /// For a comparison operator, return 0/1 instead of filtering.
    public var returnBool: Bool

    public init(
        op: ItemType = ItemType(0),
        lhs: any Expr,
        rhs: any Expr,
        vectorMatching: VectorMatching? = nil,
        returnBool: Bool = false
    ) {
        self.op = op
        self.lhs = lhs
        self.rhs = rhs
        self.vectorMatching = vectorMatching
        self.returnBool = returnBool
    }

    /// Go: scalar only when both sides are scalar.
    public var type: ValueType {
        if lhs.type == .scalar && rhs.type == .scalar { return .scalar }
        return .vector
    }
    public var positionRange: PositionRange { mergeRanges(lhs, rhs) }
    public var nodeTypeName: String { "BinaryExpr" }
}

/// Go: `DurationExpr` — arithmetic over durations, inside `[...]`, after
/// `offset`, or as a `step()`/`range()`/`max_of()`/`min_of()` call in a duration
/// position. Gated behind `ExperimentalDurationExpr`.
public final class DurationExpr: Expr {
    public var op: ItemType
    /// Nil for a unary expression and for `step()`/`range()`.
    public var lhs: (any Expr)?
    public var rhs: (any Expr)?
    /// Set when the duration was written inside parentheses.
    public var wrapped: Bool

    /// For unary operations, `step()` and `range()`: where the operator starts.
    public var startPos: Pos
    /// For `step()` and `range()`: where the operator ends.
    public var endPos: Pos

    public init(
        op: ItemType = ItemType(0),
        lhs: (any Expr)? = nil,
        rhs: (any Expr)? = nil,
        wrapped: Bool = false,
        startPos: Pos = 0,
        endPos: Pos = 0
    ) {
        self.op = op
        self.lhs = lhs
        self.rhs = rhs
        self.wrapped = wrapped
        self.startPos = startPos
        self.endPos = endPos
    }

    public var type: ValueType { .scalar }

    /// Go: four cases, in this order — both sides absent (`step()`), only the
    /// left, only the right (unary), and both.
    public var positionRange: PositionRange {
        if rhs == nil && lhs == nil {
            return PositionRange(start: startPos, end: endPos)
        }
        if rhs == nil {
            return PositionRange(start: startPos, end: lhs!.positionRange.end)
        }
        if lhs == nil {
            return PositionRange(start: startPos, end: rhs!.positionRange.end)
        }
        return mergeRanges(lhs!, rhs!)
    }
    public var nodeTypeName: String { "DurationExpr" }
}

/// Go: `Call` — a function call.
public final class Call: Expr {
    /// The function called. Nil when the name did not resolve, which is an error
    /// the parser has already reported — but the node still exists.
    public var function: Function?
    public var args: [any Expr]
    public var posRange: PositionRange

    public init(
        function: Function?,
        args: [any Expr],
        posRange: PositionRange
    ) {
        self.function = function
        self.args = args
        self.posRange = posRange
    }

    public var type: ValueType { function?.returnType ?? .none }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "Call" }
}

/// Go: `MatrixSelector` — a range selection, `foo[5m]`.
public final class MatrixSelector: Expr {
    /// Safe to treat as a `VectorSelector` if the parser reported no error.
    public var vectorSelector: any Expr
    public var range: GoDuration
    public var rangeExpr: DurationExpr?
    public var endPos: Pos

    public init(
        vectorSelector: any Expr,
        range: GoDuration = GoDuration(nanoseconds: 0),
        rangeExpr: DurationExpr? = nil,
        endPos: Pos = 0
    ) {
        self.vectorSelector = vectorSelector
        self.range = range
        self.rangeExpr = rangeExpr
        self.endPos = endPos
    }

    public var type: ValueType { .matrix }
    public var positionRange: PositionRange {
        PositionRange(start: vectorSelector.positionRange.start, end: endPos)
    }
    public var nodeTypeName: String { "MatrixSelector" }
}

/// Go: `SubqueryExpr` — `foo[5m:1m]`.
public final class SubqueryExpr: Expr {
    public var expr: any Expr
    public var range: GoDuration
    public var rangeExpr: DurationExpr?
    /// The offset as written in the query.
    public var originalOffset: GoDuration
    /// The offset expression as written in the query.
    public var originalOffsetExpr: DurationExpr?
    /// The offset used at evaluation time, derived from the original offset, the
    /// `@` timestamp, the evaluation time and any enclosing subquery offsets.
    public var offset: GoDuration
    public var timestamp: Int64?
    /// Set when `@` was used with `start()` or `end()`.
    public var startOrEnd: ItemType
    public var step: GoDuration
    public var stepExpr: DurationExpr?
    public var endPos: Pos

    public init(
        expr: any Expr,
        range: GoDuration = GoDuration(nanoseconds: 0),
        rangeExpr: DurationExpr? = nil,
        originalOffset: GoDuration = GoDuration(nanoseconds: 0),
        originalOffsetExpr: DurationExpr? = nil,
        offset: GoDuration = GoDuration(nanoseconds: 0),
        timestamp: Int64? = nil,
        startOrEnd: ItemType = ItemType(0),
        step: GoDuration = GoDuration(nanoseconds: 0),
        stepExpr: DurationExpr? = nil,
        endPos: Pos = 0
    ) {
        self.expr = expr
        self.range = range
        self.rangeExpr = rangeExpr
        self.originalOffset = originalOffset
        self.originalOffsetExpr = originalOffsetExpr
        self.offset = offset
        self.timestamp = timestamp
        self.startOrEnd = startOrEnd
        self.step = step
        self.stepExpr = stepExpr
        self.endPos = endPos
    }

    public var type: ValueType { .matrix }
    public var positionRange: PositionRange {
        PositionRange(start: expr.positionRange.start, end: endPos)
    }
    public var nodeTypeName: String { "SubqueryExpr" }
}

/// Go: `NumberLiteral`.
public final class NumberLiteral: Expr {
    public var val: Double
    /// Set when the literal was written as a duration, which changes only how it
    /// prints — `1m` rather than `60`.
    public var duration: Bool
    public var posRange: PositionRange

    public init(
        val: Double,
        duration: Bool = false,
        posRange: PositionRange = PositionRange(start: 0, end: 0)
    ) {
        self.val = val
        self.duration = duration
        self.posRange = posRange
    }

    public var type: ValueType { .scalar }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "NumberLiteral" }
}

/// Go: `ParenExpr` — parentheses, kept in the tree so precedence cannot be
/// undone by reprinting.
public final class ParenExpr: Expr {
    public var expr: any Expr
    public var posRange: PositionRange

    public init(expr: any Expr, posRange: PositionRange) {
        self.expr = expr
        self.posRange = posRange
    }

    public var type: ValueType { expr.type }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "ParenExpr" }
}

/// Go: `StringLiteral`.
///
/// The value is bytes, not a `String`: `"\xff"` is a legal PromQL string literal
/// and its value is not valid UTF-8, which a Swift String cannot hold. Go's
/// `strconv.Quote` re-escapes the raw byte, so decoding through U+FFFD here would
/// change the printed query (ADR-9).
public final class StringLiteral: Expr {
    public var val: [UInt8]
    public var posRange: PositionRange

    public init(val: [UInt8], posRange: PositionRange) {
        self.val = val
        self.posRange = posRange
    }

    public init(val: String, posRange: PositionRange) {
        self.val = Array(val.utf8)
        self.posRange = posRange
    }

    /// The value decoded as UTF-8, with U+FFFD for anything invalid. This is what
    /// Go's `json.Marshal` produces for the same string, so it is the right form
    /// for the AST serialisation — but not for printing.
    public var valString: String { String(decoding: val, as: UTF8.self) }

    public var type: ValueType { .string }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "StringLiteral" }
}

/// Go: `UnaryExpr`.
public final class UnaryExpr: Expr {
    public var op: ItemType
    public var expr: any Expr
    public var startPos: Pos

    public init(op: ItemType, expr: any Expr, startPos: Pos = 0) {
        self.op = op
        self.expr = expr
        self.startPos = startPos
    }

    public var type: ValueType { expr.type }
    public var positionRange: PositionRange {
        PositionRange(start: startPos, end: expr.positionRange.end)
    }
    public var nodeTypeName: String { "UnaryExpr" }
}

/// Go: `StepInvariantExpr` — a query whose result does not depend on the
/// evaluation time. Only the engine's optimiser produces it; the parser never
/// does. Present because Phase 5 needs it and because it is part of `ast.go`.
public final class StepInvariantExpr: Expr {
    public var expr: any Expr

    public init(expr: any Expr) { self.expr = expr }

    public var type: ValueType { expr.type }
    public var positionRange: PositionRange { expr.positionRange }
    public var nodeTypeName: String { "StepInvariantExpr" }
    public var description: String { expr.description }
    public func pretty(_ level: Int) -> String { expr.pretty(level) }
}

/// Go: `VectorSelector` — an instant vector selection.
public final class VectorSelector: Expr {
    public var name: String
    /// The offset as written in the query, before any expression is folded in.
    public var originalOffset: GoDuration
    /// The offset expression as written in the query.
    public var originalOffsetExpr: DurationExpr?
    /// The offset used at evaluation time.
    public var offset: GoDuration
    public var timestamp: Int64?
    /// Set when decoding native-histogram buckets is not needed to evaluate.
    public var skipHistogramBuckets: Bool
    /// Set when `@` was used with `start()` or `end()`.
    public var startOrEnd: ItemType
    public var labelMatchers: [Matcher?]

    /// True when this selector need not have a matcher that rejects the empty
    /// string — which is the case for `info()`'s second argument.
    public var bypassEmptyMatcherCheck: Bool

    public var anchored: Bool
    public var smoothed: Bool

    public var posRange: PositionRange

    public init(
        name: String = "",
        originalOffset: GoDuration = GoDuration(nanoseconds: 0),
        originalOffsetExpr: DurationExpr? = nil,
        offset: GoDuration = GoDuration(nanoseconds: 0),
        timestamp: Int64? = nil,
        skipHistogramBuckets: Bool = false,
        startOrEnd: ItemType = ItemType(0),
        labelMatchers: [Matcher?] = [],
        bypassEmptyMatcherCheck: Bool = false,
        anchored: Bool = false,
        smoothed: Bool = false,
        posRange: PositionRange = PositionRange(start: 0, end: 0)
    ) {
        self.name = name
        self.originalOffset = originalOffset
        self.originalOffsetExpr = originalOffsetExpr
        self.offset = offset
        self.timestamp = timestamp
        self.skipHistogramBuckets = skipHistogramBuckets
        self.startOrEnd = startOrEnd
        self.labelMatchers = labelMatchers
        self.bypassEmptyMatcherCheck = bypassEmptyMatcherCheck
        self.anchored = anchored
        self.smoothed = smoothed
        self.posRange = posRange
    }

    public var type: ValueType { .vector }
    public var positionRange: PositionRange { posRange }
    public var nodeTypeName: String { "VectorSelector" }
}

// MARK: - Vector matching

/// Go: `VectorMatchCardinality`.
public enum VectorMatchCardinality: Int, Sendable, CustomStringConvertible {
    case oneToOne = 0
    case manyToOne
    case oneToMany
    case manyToMany

    public var description: String {
        switch self {
        case .oneToOne: return "one-to-one"
        case .manyToOne: return "many-to-one"
        case .oneToMany: return "one-to-many"
        case .manyToMany: return "many-to-many"
        }
    }
}

/// Go: `VectorMatching` — how elements of two vectors are paired.
///
/// A struct, not a class: `checkAST` both mutates `Card` through the owning
/// `BinaryExpr` and sets the whole thing to nil, and optional chaining onto a
/// `var` property of a class does both.
public struct VectorMatching: Sendable, Equatable {
    public var card: VectorMatchCardinality
    /// The labels that define equality between a pair of elements.
    public var matchingLabels: [String]
    /// Whether `matchingLabels` is an include list (`on`) rather than an exclude
    /// list (`ignoring`).
    public var on: Bool
    /// Extra labels carried over from the lower-cardinality side.
    public var include: [String]
    /// Values to substitute when one side has no match.
    public var fillValues: VectorMatchFillValues

    public init(
        card: VectorMatchCardinality = .oneToOne,
        matchingLabels: [String] = [],
        on: Bool = false,
        include: [String] = [],
        fillValues: VectorMatchFillValues = VectorMatchFillValues()
    ) {
        self.card = card
        self.matchingLabels = matchingLabels
        self.on = on
        self.include = include
        self.fillValues = fillValues
    }
}

/// Go: `VectorMatchFillValues`. A nil side means no fill: a match group with no
/// match produces no output at all, which is different from filling with 0.
public struct VectorMatchFillValues: Sendable, Equatable {
    public var rhs: Double?
    public var lhs: Double?

    public init(lhs: Double? = nil, rhs: Double? = nil) {
        self.lhs = lhs
        self.rhs = rhs
    }
}

// MARK: - Position helpers

/// Go: `mergeRanges` — the span from the first node's start to the last node's
/// end. The arguments must be in the order they appear in the input.
public func mergeRanges(_ first: any Node, _ last: any Node) -> PositionRange {
    PositionRange(start: first.positionRange.start, end: last.positionRange.end)
}

/// Go: `(*Item).PositionRange()` — an `Item` is a `Node` in Go purely so
/// `mergeRanges` can take one. Here it is a method instead, because `Item` is a
/// struct and `Node` is class-bound.
extension Item {
    public var positionRange: PositionRange {
        PositionRange(start: pos, end: pos + Pos(val.count))
    }
}

/// `mergeRanges` over positions rather than nodes, for the call sites that merge
/// two `Item`s.
func mergeRanges(_ first: PositionRange, _ last: PositionRange) -> PositionRange {
    PositionRange(start: first.start, end: last.end)
}

// MARK: - Traversal

/// Go: `ChildrenIter` / `Children` — every child of a node, in order.
///
/// The order is observable: `Tree()` prints it. Note the asymmetry Go has and
/// this keeps — `AggregateExpr` nil-checks its children and `BinaryExpr` does
/// not, because a binary expression always has both.
public func children(of node: any Node) -> [any Node] {
    switch node {
    case let n as AggregateExpr:
        var out = [any Node]()
        if let e = n.expr { out.append(e) }
        if let p = n.param { out.append(p) }
        return out
    case let n as BinaryExpr:
        return [n.lhs, n.rhs]
    case let n as Call:
        return n.args
    case let n as SubqueryExpr:
        return [n.expr]
    case let n as ParenExpr:
        return [n.expr]
    case let n as UnaryExpr:
        return [n.expr]
    case let n as MatrixSelector:
        return [n.vectorSelector]
    case let n as StepInvariantExpr:
        return [n.expr]
    case is NumberLiteral, is StringLiteral, is VectorSelector, is DurationExpr:
        // Go handles NumberLiteral, StringLiteral and VectorSelector explicitly.
        // A DurationExpr never reaches ChildrenIter upstream — it hangs off a
        // MatrixSelector's RangeExpr rather than being a child — so treating it
        // as childless here matches, and avoids panicking on a shape Go's
        // traversal simply never sees.
        return []
    default:
        preconditionFailure("promql.ChildrenIter: unhandled node type \(node.nodeTypeName)")
    }
}

/// Go: `Visitor`.
public protocol Visitor {
    /// Returning nil stops the descent into this node's children.
    func visit(node: (any Node)?, path: [any Node]) throws -> (any Visitor)?
}

/// Go: `Walk` — depth-first, passing each node the path that led to it. After a
/// node's children have been walked, the visitor is called once with nil.
public func walk(_ v: any Visitor, _ node: any Node, _ path: [any Node]) throws {
    guard let v = try v.visit(node: node, path: path) else { return }
    var pathToHere: [any Node]? = nil
    for child in children(of: node) {
        if pathToHere == nil { pathToHere = path + [node] }
        try walk(v, child, pathToHere!)
    }
    _ = try v.visit(node: nil, path: [])
}

/// Go: `Inspect` — `Walk` with a closure. The closure throwing stops the
/// descent below that node.
public func inspect(_ node: any Node, _ f: (any Node, [any Node]) throws -> Void) {
    // Go swallows the error (`Walk(f, node, pathBuf[:0]) //nolint:errcheck`);
    // a throwing inspector is how a caller stops early, not how it reports.
    try? walkInspecting(node, [], f)
}

private func walkInspecting(
    _ node: any Node, _ path: [any Node], _ f: (any Node, [any Node]) throws -> Void
) throws {
    try f(node, path)
    let pathToHere = path + [node]
    for child in children(of: node) {
        try walkInspecting(child, pathToHere, f)
    }
}

/// Go: `ExtractSelectors` — the label matchers of every vector selector in the
/// expression, in traversal order.
public func extractSelectors(_ expr: any Expr) -> [[Matcher?]] {
    var selectors = [[Matcher?]]()
    inspect(expr) { node, _ in
        if let vs = node as? VectorSelector {
            selectors.append(vs.labelMatchers)
        }
    }
    return selectors
}
