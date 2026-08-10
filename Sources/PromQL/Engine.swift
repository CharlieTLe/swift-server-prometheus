//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — everything from a query string up to (but not
// including) its execution: `EngineOpts`, `Engine`, `NewEngine`, `QueryOpts`,
// `PrometheusQueryOpts`, `newQuery`, `validateOpts`, and the `NewInstantQuery` /
// `NewRangeQuery` entry points.
//
// So this is the front door. Handed a query it parses, validates, type-checks (range
// queries only) and preprocesses, producing the `EvalStmt` the evaluator will later walk.
// Nothing here touches storage, which is what lets it be pinned before the evaluator
// exists — every error a query can produce *before* evaluation is decided here.
//
// ## Three divergences, all deliberate, none behavioural
//
//   * **No metrics.** `NewEngine` builds nine `prometheus.Collector`s and registers them.
//     That is client_golang, an instrumentation surface with no PromQL semantics, and it
//     is deferred to Phase 8 with the rest of the HTTP layer. `Engine` therefore keeps the
//     configuration fields and drops `metrics`.
//   * **No `ActiveQueryTracker`.** `queueActive` blocks until a concurrency slot is free
//     and can fail with the tracker's own error. It is a separate file
//     (`util/pool`-adjacent) and a separate slice; `activeQueryTracker` is accepted and
//     ignored, so `NewInstantQuery` never queues. A query that would have been rejected
//     for concurrency is instead accepted — recorded in PORTING.md rather than hidden.
//   * **No `slog.Logger`, no `stats`.** Timers and per-step sample stats are observability;
//     `enablePerStepStats` is still stored because `newQuery` reads it.
//
// ## Two lookback defaults, with two different comparisons
//
// `NewEngine` replaces a lookback delta of exactly **zero** with `defaultLookbackDelta`
// (five minutes) before any query exists — testing `== 0`. `newQuery` then replaces a
// per-query delta that is `<= 0` with the engine's. The asymmetry is real and observable:
// a **negative engine** lookback survives, a negative **per-query** one is discarded. The
// fixture found this; reading `newQuery` alone suggests a zero engine lookback can reach a
// query, and it cannot.
//
// ## `newQuery`'s lookback defaulting is `<= 0`, not `== 0`
//
// A query's own lookback delta wins only if it is **positive**. A zero *or negative* one
// falls back to the engine's — so `NewPrometheusQueryOpts(false, -1)` is not a way to ask
// for a negative lookback, it is a way to ask for the default. Reproduced with the
// comparison Go uses rather than a nil check.
//
// A nil `opts` becomes `NewPrometheusQueryOpts(false, 0)`, which then takes that same
// branch — so nil and "zero opts" are the same thing by construction, not by coincidence.
//
// ## `validateOpts` walks the AST even when it cannot fail
//
// The early return is `enableAtModifier && enableNegativeOffset` — both. With one of them
// off the walk runs, and it reports **whichever violation it meets first in traversal
// order**: a query using both a negative offset and an `@` gets the `@` error if the `@`
// node comes first. So the message depends on the shape of the expression, not on which
// feature is disabled, and swapping the two `if`s inside the visitor changes the answer.
//
// The flags are also *sticky*: `atModifierUsed` stays true once set, and the check runs
// after every node — so a later node can trigger the error for an earlier node's
// violation. Only observable through the error's identity, which is why the corpus mixes
// them.
//
// Note it inspects `MatrixSelector` *and* the `VectorSelector` inside it, so a matrix
// selector's `@` is seen twice — and the `MatrixSelector` arm is therefore **redundant**:
// `Inspect` walks into the inner selector, which catches the same `@` and the same negative
// offset. Deleting the arm changes nothing, which the negative control for it confirms by
// being unable to fail. Preserved because it is upstream's.
//
// ## The range-query type check is not the parser's
//
// `NewRangeQuery` rejects an expression whose type is neither scalar nor instant vector,
// with a message built from `parser.DocumentedType` — "range vector" and "instant vector"
// rather than the internal names. An instant query accepts all four types, so
// `max_over_time(foo[5m])[1h:1m]` is a legal instant query and an illegal range query.
//
// ## 18 negative controls, 17 break — and two needed a query that fails twice
//
// The single survivor is the redundant `MatrixSelector` arm above, which cannot be
// witnessed by anything.
//
// Two others survived at first and were corpus gaps, both needing a query that fails in
// **two** places at once:
//
//   * validating before preprocessing versus after. Both orders give the same answer
//     unless a query fails both — `rate(foo[1m-1m] @ 100)` with the `@` modifier disabled
//     folds its range to zero (which preprocessing rejects) *and* uses a disabled feature.
//     Go answers "@ modifier is disabled", so validation comes first.
//   * passing the query's interval to `PreprocessExpr` versus zero. The step only reaches
//     the AST through `step()` in duration position, so `max_over_time(foo[step()])` is the
//     only shape that separates them — and as an *instant* query it is an error, because
//     an instant query's step is zero and a zero duration is invalid.
//===----------------------------------------------------------------------===//

public import GoCompat
public import PromQLParser
public import PromStorage

/// Go: `QueryOpts` — the per-query knobs.
public protocol QueryOpts: Sendable {
    var enablePerStepStats: Bool { get }
    var lookbackDelta: GoDuration { get }
}

/// Go: `PrometheusQueryOpts`.
public struct PrometheusQueryOpts: QueryOpts {
    public let enablePerStepStats: Bool
    public let lookbackDelta: GoDuration

    /// Go: `NewPrometheusQueryOpts`.
    public init(enablePerStepStats: Bool, lookbackDelta: GoDuration) {
        self.enablePerStepStats = enablePerStepStats
        self.lookbackDelta = lookbackDelta
    }
}

/// Go: `EngineOpts` — the engine's configuration.
///
/// `Logger`, `Reg` and `ActiveQueryTracker` are absent; see the file header.
public struct EngineOpts: Sendable {
    public var maxSamples: Int
    public var timeout: GoDuration
    public var lookbackDelta: GoDuration
    /// Go: `NoStepSubqueryIntervalFn` — the default subquery step, in milliseconds.
    public var noStepSubqueryIntervalFn: (@Sendable (Int64) -> Int64)?
    public var enableAtModifier: Bool
    public var enableNegativeOffset: Bool
    public var enablePerStepStats: Bool
    public var enableDelayedNameRemoval: Bool
    public var enableTypeAndUnitLabels: Bool
    public var useStartTimestamps: Bool
    /// Go: `Parser` — the engine holds the parser instance rather than making one per
    /// query, so its options are engine-wide.
    public var parserOptions: Options

    public init(
        maxSamples: Int = 0,
        timeout: GoDuration = GoDuration(nanoseconds: 0),
        lookbackDelta: GoDuration = GoDuration(nanoseconds: 0),
        noStepSubqueryIntervalFn: (@Sendable (Int64) -> Int64)? = nil,
        enableAtModifier: Bool = false,
        enableNegativeOffset: Bool = false,
        enablePerStepStats: Bool = false,
        enableDelayedNameRemoval: Bool = false,
        enableTypeAndUnitLabels: Bool = false,
        useStartTimestamps: Bool = false,
        parserOptions: Options = Options()
    ) {
        self.maxSamples = maxSamples
        self.timeout = timeout
        self.lookbackDelta = lookbackDelta
        self.noStepSubqueryIntervalFn = noStepSubqueryIntervalFn
        self.enableAtModifier = enableAtModifier
        self.enableNegativeOffset = enableNegativeOffset
        self.enablePerStepStats = enablePerStepStats
        self.enableDelayedNameRemoval = enableDelayedNameRemoval
        self.enableTypeAndUnitLabels = enableTypeAndUnitLabels
        self.useStartTimestamps = useStartTimestamps
        self.parserOptions = parserOptions
    }
}

/// Go: the two validation sentinels, plus `NewRangeQuery`'s type error.
///
/// `description` reproduces Go's message byte for byte; the two sentinels are compared by
/// identity upstream (`errors.Is`), so they are cases rather than strings.
public enum QueryValidationError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Go: `ErrValidationAtModifierDisabled`.
    case atModifierDisabled
    /// Go: `ErrValidationNegativeOffsetDisabled`.
    case negativeOffsetDisabled
    /// Go: `NewRangeQuery`'s `invalid expression type %q for range query…`. The type is
    /// quoted with `%q` and named with `DocumentedType`.
    case invalidRangeQueryType(ValueType)

    public var description: String {
        switch self {
        case .atModifierDisabled:
            return "@ modifier is disabled"
        case .negativeOffsetDisabled:
            return "negative offset is disabled"
        case .invalidRangeQueryType(let t):
            return
                "invalid expression type \(GoStrconv.quote(t.documented)) for range query, must be Scalar or instant Vector"
        }
    }
}

/// Go: `query` — a parsed statement bound to the engine and storage that will run it.
///
/// `Exec` is not here: execution is the evaluator's slice. What this type carries is what
/// `NewInstantQuery`/`NewRangeQuery` produce, which is the observable this slice pins.
public final class Query {
    /// Go: `q` — the original query string.
    public let queryString: String
    /// Go: `stmt`.
    public let statement: any Statement
    /// Go: `queryable`.
    public let queryable: any Queryable
    /// Go: `ng`.
    public let engine: Engine

    init(
        queryString: String, statement: any Statement, queryable: any Queryable, engine: Engine
    ) {
        self.queryString = queryString
        self.statement = statement
        self.queryable = queryable
        self.engine = engine
    }

    /// Go: `String()` — the original text, not the AST's rendering.
    public var description: String { queryString }
}

/// Go: `Engine` — the lifetime of queries from beginning to end.
public final class Engine {
    let maxSamplesPerQuery: Int
    let timeout: GoDuration
    let lookbackDelta: GoDuration
    let noStepSubqueryIntervalFn: (@Sendable (Int64) -> Int64)?
    let enableAtModifier: Bool
    let enableNegativeOffset: Bool
    let enablePerStepStats: Bool
    let enableDelayedNameRemoval: Bool
    let enableTypeAndUnitLabels: Bool
    let useStartTimestamps: Bool
    let parser: Parser

    /// Go: `defaultLookbackDelta` (engine.go:64) — five minutes.
    public static let defaultLookbackDelta = GoDuration(nanoseconds: 5 * 60 * 1_000_000_000)

    /// Go: `NewEngine`. The metric registration and the logger default are dropped; every
    /// field that changes query behaviour is copied across unchanged — including the two
    /// defaults `NewEngine` fills in for itself.
    public init(_ opts: EngineOpts) {
        maxSamplesPerQuery = opts.maxSamples
        timeout = opts.timeout
        // engine.go:454 — a ZERO lookback delta becomes five minutes here, before any
        // query is built. So `newQuery`'s own `<= 0` fallback can never actually yield
        // zero, and an engine configured with no lookback still has one. Note this test is
        // `== 0` where `newQuery`'s is `<= 0`: a NEGATIVE engine lookback survives.
        lookbackDelta =
            opts.lookbackDelta.nanoseconds == 0 ? Engine.defaultLookbackDelta : opts.lookbackDelta
        noStepSubqueryIntervalFn = opts.noStepSubqueryIntervalFn
        enableAtModifier = opts.enableAtModifier
        enableNegativeOffset = opts.enableNegativeOffset
        enablePerStepStats = opts.enablePerStepStats
        enableDelayedNameRemoval = opts.enableDelayedNameRemoval
        enableTypeAndUnitLabels = opts.enableTypeAndUnitLabels
        useStartTimestamps = opts.useStartTimestamps
        parser = Parser(options: opts.parserOptions)
    }

    /// Go: `newQuery` — the `EvalStmt` shell and the `query` around it, before the
    /// expression exists.
    ///
    /// Go returns a `*parser.Expr` pointing into the statement so the caller can fill it in
    /// after preprocessing; `EvalStmt` is a class here, so the caller assigns `stmt.expr`.
    func newQuery(
        _ q: any Queryable, _ qs: String, _ optsIn: (any QueryOpts)?,
        _ start: GoTime, _ end: GoTime, _ interval: GoDuration
    ) -> (EvalStmt, Query) {
        let opts: any QueryOpts =
            optsIn ?? PrometheusQueryOpts(
                enablePerStepStats: false, lookbackDelta: GoDuration(nanoseconds: 0))

        // `<= 0`, not `== 0`: a negative per-query lookback asks for the engine's default
        // rather than for a negative window.
        var lookbackDelta = opts.lookbackDelta
        if lookbackDelta.nanoseconds <= 0 {
            lookbackDelta = self.lookbackDelta
        }

        // Go leaves `Expr` nil here and the caller fills it in; a placeholder stands in
        // until then, and every caller assigns before returning.
        let es = EvalStmt(
            expr: NumberLiteral(val: 0),
            start: start, end: end, interval: interval, lookbackDelta: lookbackDelta)
        let qry = Query(queryString: qs, statement: es, queryable: q, engine: self)
        return (es, qry)
    }

    /// Go: `NewInstantQuery` — start and end are both `ts`, and the interval is zero.
    ///
    /// The order matters and is upstream's: the shell is built first, so a *parse* failure
    /// still allocated one; then parse, then validate, then preprocess. A parse error
    /// therefore beats a validation error for a query that is both malformed and uses a
    /// disabled feature.
    public func newInstantQuery(
        _ q: any Queryable, _ opts: (any QueryOpts)?, _ qs: String, _ ts: GoTime
    ) throws -> Query {
        let (es, qry) = newQuery(q, qs, opts, ts, ts, GoDuration(nanoseconds: 0))
        let expr = try parser.parseExpr(qs)
        try validateOpts(expr)
        es.expr = try preprocessExpr(expr, start: ts, end: ts, step: GoDuration(nanoseconds: 0))
        return qry
    }

    /// Go: `NewRangeQuery`. Same as the instant form plus the type check, which is the one
    /// thing a range query rejects that an instant query accepts.
    public func newRangeQuery(
        _ q: any Queryable, _ opts: (any QueryOpts)?, _ qs: String,
        _ start: GoTime, _ end: GoTime, _ interval: GoDuration
    ) throws -> Query {
        let (es, qry) = newQuery(q, qs, opts, start, end, interval)
        let expr = try parser.parseExpr(qs)
        try validateOpts(expr)
        if expr.type != .vector && expr.type != .scalar {
            throw QueryValidationError.invalidRangeQueryType(expr.type)
        }
        es.expr = try preprocessExpr(expr, start: start, end: end, step: interval)
        return qry
    }

    /// Go: `validateOpts` — reject `@` and negative offsets when the engine has them off.
    ///
    /// Returns early only when **both** are enabled. The two `if`s at the end of the
    /// visitor run after every node and in that order, so for an expression using both
    /// features the reported error is decided by traversal order, not by precedence.
    func validateOpts(_ expr: any Expr) throws {
        if enableAtModifier && enableNegativeOffset {
            return
        }

        var atModifierUsed = false
        var negativeOffsetUsed = false
        var validationErr: QueryValidationError? = nil

        // Go's visitor returns the error to stop the walk; `inspect` here takes a
        // non-throwing closure, so the flag doubles as the stop condition.
        inspect(expr) { node, _ in
            if validationErr != nil {
                return
            }
            if let n = node as? VectorSelector {
                if n.timestamp != nil || n.startOrEnd == .start || n.startOrEnd == .end {
                    atModifierUsed = true
                }
                if n.originalOffset.nanoseconds < 0 {
                    negativeOffsetUsed = true
                }
            } else if let n = node as? MatrixSelector {
                // The inner VectorSelector is visited in its own right too, so a matrix
                // selector's `@` is seen twice. Upstream's, and harmless.
                if let vs = n.vectorSelector as? VectorSelector {
                    if vs.timestamp != nil || vs.startOrEnd == .start || vs.startOrEnd == .end {
                        atModifierUsed = true
                    }
                    if vs.originalOffset.nanoseconds < 0 {
                        negativeOffsetUsed = true
                    }
                }
            } else if let n = node as? SubqueryExpr {
                if n.timestamp != nil || n.startOrEnd == .start || n.startOrEnd == .end {
                    atModifierUsed = true
                }
                if n.originalOffset.nanoseconds < 0 {
                    negativeOffsetUsed = true
                }
            }

            if atModifierUsed && !enableAtModifier {
                validationErr = .atModifierDisabled
                return
            }
            if negativeOffsetUsed && !enableNegativeOffset {
                validationErr = .negativeOffsetDisabled
                return
            }
        }

        if let validationErr {
            throw validationErr
        }
    }
}
