//===----------------------------------------------------------------------===//
// Ported from promql/durations.go @ v3.13.2
//
// `durationVisitor` folds duration *expressions* — `foo offset (1h / 2)`,
// `foo[1h + 30m]`, `foo[2h * 0.5]`, `step()`, `range()`, `max_of(...)` — into the
// concrete `time.Duration` fields the evaluator reads. The parser leaves both
// forms in the tree: `OriginalOffsetExpr`/`RangeExpr`/`StepExpr` hold the
// expression, and `OriginalOffset`/`Range`/`Step` are zero until this runs.
//
// It is reached only through ``preprocessExpr(_:start:end:step:)``, which is
// where `PreprocessExpr` calls `parser.Walk` on it (engine.go:4491).
//===----------------------------------------------------------------------===//

internal import GoCompat
// `public`, not `internal`: `DurationExprError` is public and its payload is a
// `PositionRange`. `InternalImportsByDefault` rejects that otherwise, and the
// error only fires once a public method mentions the type — HANDOFF §4.
public import PromPosRange
public import PromQLParser

/// Go: the `fmt.Errorf` values in `calculateDuration` and `evaluateDurationExpr`.
///
/// Every message carries a `start:end` byte-offset prefix taken from the
/// offending expression, and reproduces Go's text byte-for-byte. Note the prefix
/// is **byte offsets**, not `line:col` — `ParseErr` renders positions the other
/// way, and these errors are not `ParseErr`s.
public enum DurationExprError: Error, Hashable, Sendable, CustomStringConvertible {
    /// durations.go:97. Guarded before the bounds check below, because NaN
    /// compares false against everything and would otherwise reach the
    /// `time.Duration` conversion.
    case notFinite(PositionRange)
    /// durations.go:100 — a non-positive duration where negatives are not allowed,
    /// which is every position except an `offset`.
    case notPositive(PositionRange)
    /// durations.go:107.
    case outOfRange(PositionRange)
    /// durations.go:159.
    case divisionByZero(PositionRange)
    /// durations.go:164.
    case moduloByZero(PositionRange)
    /// durations.go:170. Unreachable from a parsed tree: the parser only ever puts
    /// ADD, SUB, MUL, DIV, MOD, POW, STEP, RANGE, MIN_OF or MAX_OF in a
    /// `DurationExpr`, and all ten are handled. Ported because it is the contract
    /// for a hand-built tree. The payload is Go's `%q` of `ItemType.String()`.
    case unexpectedOperator(String)
    /// durations.go:173. Also unreachable from a parsed tree — a duration
    /// expression's operands are always a `NumberLiteral` or another
    /// `DurationExpr`. The payload is Go's `%T`, package qualifier included.
    case unexpectedType(String)

    public var description: String {
        switch self {
        case .notFinite(let r):
            return "\(r.start):\(r.end): duration is NaN or infinite"
        case .notPositive(let r):
            return "\(r.start):\(r.end): duration must be greater than 0"
        case .outOfRange(let r):
            return "\(r.start):\(r.end): duration is out of range"
        case .divisionByZero(let r):
            return "\(r.start):\(r.end): division by zero"
        case .moduloByZero(let r):
            return "\(r.start):\(r.end): modulo by zero"
        case .unexpectedOperator(let op):
            return "unexpected duration expression operator \(GoStrconv.quote(op))"
        case .unexpectedType(let t):
            return "unexpected duration expression type \(t)"
        }
    }
}

/// Go: `durationVisitor`.
///
/// A class because `Visitor.visit` returns `self` and Go's is a pointer receiver;
/// nothing here mutates the visitor, only the nodes it walks.
final class DurationVisitor: Visitor {
    let step: GoDuration
    let queryRange: GoDuration

    init(step: GoDuration = GoDuration(nanoseconds: 0),
         queryRange: GoDuration = GoDuration(nanoseconds: 0))
    {
        self.step = step
        self.queryRange = queryRange
    }

    /// Go: `durationVisitor.Visit`.
    ///
    /// `Walk` does **not** descend into `OriginalOffsetExpr`, `RangeExpr` or
    /// `StepExpr` — they are not children (see `children(of:)`) — so each is
    /// recursed into here instead. That is upstream's own note at durations.go:35.
    func visit(node: (any Node)?, path: [any Node]) throws -> (any Visitor)? {
        switch node {
        case let n as VectorSelector:
            if let e = n.originalOffsetExpr {
                n.originalOffset = try calculateDuration(e, allowedNegative: true)
            }
        case let n as MatrixSelector:
            if let e = n.rangeExpr {
                n.range = try calculateDuration(e, allowedNegative: false)
            }
        case let n as SubqueryExpr:
            // The order matters only for which error is reported first when more
            // than one sub-expression is invalid: offset, then step, then range.
            if let e = n.originalOffsetExpr {
                n.originalOffset = try calculateDuration(e, allowedNegative: true)
            }
            if let e = n.stepExpr {
                n.step = try calculateDuration(e, allowedNegative: false)
            }
            if let e = n.rangeExpr {
                n.range = try calculateDuration(e, allowedNegative: false)
            }
        default:
            break
        }
        return self
    }

    /// Go: `durationVisitor.calculateDuration`.
    func calculateDuration(
        _ expr: any Expr, allowedNegative: Bool
    ) throws -> GoDuration {
        let duration = try evaluateDurationExpr(expr)
        let range = expr.positionRange

        // durations.go:94 — NaN and the infinities go first. NaN compares false
        // against everything, so without this guard a NaN would slip past the
        // bounds check and produce an implementation-defined Int64 in the
        // conversion at the tail.
        if duration.isNaN || duration.isInfinite {
            throw DurationExprError.notFinite(range)
        }
        if duration <= 0 && !allowedNegative {
            throw DurationExprError.notPositive(range)
        }
        // The bound is Go's `1<<63/1e9`, an arbitrary-precision constant
        // expression that rounds to this `Double` — spelled as the value it
        // denotes because a chain of untyped literals is what blows the Swift 6.1
        // type checker's budget (HANDOFF §4). Probed against Go: the constant is
        // 0x42012e0be826d695, i.e. slightly *above* the exact 2^63/1e9, so the
        // bound is inclusive of 9223372036.854776 rather than of 2^63/1e9.
        let maxSeconds = 9_223_372_036.854_776_382_446_289_062_5
        if duration > maxSeconds || duration < -maxSeconds {
            throw DurationExprError.outOfRange(range)
        }
        // Go: `time.Duration(duration*1000) * time.Millisecond` — truncate to
        // whole milliseconds toward zero, then scale to nanoseconds. `&*` because
        // Go's multiplication wraps; the bound above keeps the product in range
        // for every input that reaches here.
        let millis = Int64(duration * 1000)
        return GoDuration(nanoseconds: millis &* GoDuration.millisecond.nanoseconds)
    }

    /// Go: `durationVisitor.evaluateDurationExpr`.
    func evaluateDurationExpr(_ expr: any Expr) throws -> Double {
        if let n = expr as? NumberLiteral {
            return n.val
        }
        guard let n = expr as? DurationExpr else {
            throw DurationExprError.unexpectedType(goTypeName(expr))
        }

        // Go evaluates both sides *before* the operator switch, so `step()` and
        // `range()` — which ignore both — still pay for and can still fail on
        // whatever hangs off them. No parsed tree puts operands on those, so this
        // is order preserved rather than behaviour observed.
        var lhs = 0.0
        var rhs = 0.0
        if let l = n.lhs {
            lhs = try evaluateDurationExpr(l)
        }
        if let r = n.rhs {
            rhs = try evaluateDurationExpr(r)
        }

        switch n.op {
        case .step:
            return step.seconds
        case .range:
            return queryRange.seconds
        case .minOf:
            return GoMath.min(lhs, rhs)
        case .maxOf:
            return GoMath.max(lhs, rhs)
        case .add:
            // A nil LHS is the unary form: `offset +1h`.
            if n.lhs == nil { return rhs }
            return lhs + rhs
        case .sub:
            if n.lhs == nil { return -rhs }
            return lhs - rhs
        case .mul:
            return lhs * rhs
        case .div:
            if rhs == 0 {
                throw DurationExprError.divisionByZero(expr.positionRange)
            }
            return lhs / rhs
        case .mod:
            if rhs == 0 {
                throw DurationExprError.moduloByZero(expr.positionRange)
            }
            return GoMath.mod(lhs, rhs)
        case .pow:
            return GoMath.pow(lhs, rhs)
        default:
            throw DurationExprError.unexpectedOperator(n.op.description)
        }
    }
}

/// Go's `%T` for a `parser.Expr`, which is what
/// ``DurationExprError/unexpectedType(_:)`` reports. Every AST node is a pointer
/// to a struct in the `parser` package, so the rendering is mechanical.
private func goTypeName(_ node: any Node) -> String {
    "*parser.\(node.nodeTypeName)"
}
