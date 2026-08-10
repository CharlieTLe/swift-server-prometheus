//===----------------------------------------------------------------------===//
// Ported from promql/parser/ast.go @ v3.13.2 — Statement, EvalStmt, TestStmt.
//
// Held back from AST.swift during Phase 4 because both need types that did not
// exist yet: `time.Time` (now `GoCompat.GoTime`) and, for `TestStmt`,
// `context.Context` (now `GoCompat.GoContext`).
//
// Neither is produced by the parser. `Engine.NewInstantQuery`/`NewRangeQuery`
// build the `EvalStmt`, and `NewTestQuery` the `TestStmt`.
//===----------------------------------------------------------------------===//

public import PromPosRange
public import GoCompat

/// Go: `Statement`.
///
/// Go's `PromQLStmt()` marker method exists only to stop unrelated types
/// satisfying the interface structurally. Swift conformance is explicit, so the
/// marker has no work to do and is omitted.
public protocol Statement: Node {}

/// Go: `EvalStmt` — an expression plus the range to evaluate it over.
public final class EvalStmt: Statement {
    /// The expression to evaluate.
    public var expr: any Expr

    /// The evaluation boundaries. `start == end` means an instant query.
    public var start: GoTime
    public var end: GoTime
    /// Time between two evaluated instants across `start...end`.
    public var interval: GoDuration
    /// Lookback delta for this evaluation.
    public var lookbackDelta: GoDuration

    public init(
        expr: any Expr,
        start: GoTime,
        end: GoTime,
        interval: GoDuration = GoDuration(nanoseconds: 0),
        lookbackDelta: GoDuration = GoDuration(nanoseconds: 0)
    ) {
        self.expr = expr
        self.start = start
        self.end = end
        self.interval = interval
        self.lookbackDelta = lookbackDelta
    }

    /// Go: `printer.go:52` — `"EVAL " + node.Expr.String()`. The prefix is real and was
    /// missing here until `promql/exec.jsonl` compared a statement's rendering after
    /// `Exec`: nothing else in the corpus printed an `EvalStmt`, because nothing else
    /// built one.
    public var description: String { "EVAL " + expr.description }

    /// Go: `prettier.go:106` — `Pretty` ignores the level and returns the same string as
    /// `String()`, expression included. It does NOT pretty-print the expression.
    public func pretty(_ level: Int) -> String { "EVAL " + expr.description }

    /// ast.go:515 — delegates to the expression.
    public var positionRange: PositionRange { expr.positionRange }

    public var nodeTypeName: String { "EvalStmt" }
}

/// Go: `TestStmt` — an arbitrary function run in place of an evaluation, used to
/// test the engine.
///
/// Go declares it as `func(context.Context) error`, a named function type with
/// methods. Swift cannot attach protocol conformance to a function type, so this
/// is a final class wrapping the closure. The observable surface is unchanged.
public final class TestStmt: Statement {
    public let body: (GoContext) throws -> Void

    public init(_ body: @escaping (GoContext) throws -> Void) {
        self.body = body
    }

    public func run(_ ctx: GoContext) throws { try body(ctx) }

    /// ast.go:241 — the literal string "test statement".
    public var description: String { "test statement" }

    /// ast.go:243 — `Pretty` ignores the level and returns `String()`.
    public func pretty(_: Int) -> String { description }

    /// ast.go:245 — position undefined, spelled -1/-1.
    public var positionRange: PositionRange { PositionRange(start: -1, end: -1) }

    public var nodeTypeName: String { "TestStmt" }
}
