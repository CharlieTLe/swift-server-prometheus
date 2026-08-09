//===----------------------------------------------------------------------===//
// Ported from generated_parser.y @ v3.13.2 — the duration-expression grammar,
// which is `duration_expr`, `positive_duration_expr`, `offset_duration_expr` and
// `paren_duration_expr`.
//
// This is the one part of the grammar where goyacc's conflict resolution decides
// the language, so it is worth stating what was verified against Go rather than
// inferred:
//
//   - `offset_duration_expr` **stops at the literal**. It and `duration_expr`
//     both derive `number_duration_literal`, a reduce/reduce conflict that yacc
//     settles by taking the rule declared earlier — and `offset_duration_expr` is
//     declared first. So `foo offset 1m+1m` is `(foo offset 1m) + 1m`, and
//     `foo offset -2^2` is `(foo offset -2)^2`. Only the parenthesised,
//     `step()`/`range()` and `max_of`/`min_of` forms carry arithmetic after
//     `offset`.
//   - Inside `[...]` there is no such competition, so the full arithmetic grammar
//     applies: `foo[1m+1m*2]` and `foo[2^3^2s]` both parse.
//   - `Wrapped` is only ever set on a `DurationExpr`. `(1m)` in duration position
//     is a bare `NumberLiteral`, so it reprints as `1m` with the parentheses gone.
//===----------------------------------------------------------------------===//

private import GoCompat

extension Parser {

    /// Go: `positive_duration_expr: duration_expr`, plus the check that a constant
    /// duration is greater than zero.
    func positiveDurationExpr() throws -> any Expr {
        let e = try durationExpr()
        if let nl = e as? NumberLiteral {
            if nl.val <= 0 {
                addParseErr(nl.positionRange, .durationMustBeGreaterThanZero)
                return NumberLiteral(val: 0)  // Go returns a fresh zero on error.
            }
            return nl
        }
        return e
    }

    /// Go: `duration_expr` — the same precedence climb as `expr`, over the
    /// arithmetic operators only.
    func durationExpr(_ minPrecedence: Int = 1) throws -> any Expr {
        var lhs = try durationUnaryExpr()

        while let precedence = Self.binaryPrecedence[cur.typ], precedence >= minPrecedence,
            isDurationOperator(cur.typ)
        {
            let opItem = take()
            let nextMinimum = opItem.typ == .pow ? precedence : precedence + 1
            let rhs = try durationExpr(nextMinimum)

            experimentalDurationExpr(lhs)

            // Division and modulo by a literal zero are rejected here rather than
            // at evaluation time, and the node is replaced by a zero.
            if opItem.typ == .div, let nl = rhs as? NumberLiteral, nl.val == 0 {
                addParseErr(opItem.positionRange, .divisionByZero)
                return NumberLiteral(val: 0)
            }
            if opItem.typ == .mod, let nl = rhs as? NumberLiteral, nl.val == 0 {
                addParseErr(opItem.positionRange, .moduloByZero)
                return NumberLiteral(val: 0)
            }
            lhs = DurationExpr(op: opItem.typ, lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    /// Go: `duration_expr: unary_op duration_expr %prec MUL`, and the primaries.
    func durationUnaryExpr() throws -> any Expr {
        if cur.typ == .add || cur.typ == .sub {
            let opItem = take()
            let operand = try durationExpr(Self.mulPrecedence + 1)
            return applyUnaryOpToDurationExpr(opItem, operand, wrapped: false)
        }
        return try durationPrimary()
    }

    /// The non-recursive alternatives of `duration_expr`.
    func durationPrimary() throws -> any Expr {
        switch cur.typ {
        case .number, .duration:
            // `duration_expr: number_duration_literal`, with the range guard.
            let nl = numberDurationLiteral()
            if durationLiteralOutOfRange(nl.val) {
                addParseErr(nl.posRange, .durationOutOfRange)
                return NumberLiteral(val: 0)
            }
            return nl

        case .step, .range:
            // `STEP LEFT_PAREN RIGHT_PAREN` / `RANGE LEFT_PAREN RIGHT_PAREN`
            let opItem = take()
            guard accept(.leftParen) != nil, let rparen = accept(.rightParen) else {
                throw syntaxError()
            }
            let de = DurationExpr(
                op: opItem.typ,
                startPos: opItem.positionRange.start,
                endPos: rparen.positionRange.end)
            experimentalDurationExpr(de)
            return de

        case .maxOf, .minOf:
            // `max_of_min_of LEFT_PAREN duration_expr COMMA duration_expr RIGHT_PAREN`
            let opItem = take()
            guard accept(.leftParen) != nil else { throw syntaxError() }
            let lhs = try durationExpr()
            guard accept(.comma) != nil else { throw syntaxError() }
            let rhs = try durationExpr()
            guard let rparen = accept(.rightParen) else { throw syntaxError() }
            let de = DurationExpr(
                op: opItem.typ,
                lhs: lhs,
                rhs: rhs,
                startPos: opItem.positionRange.start,
                endPos: rparen.positionRange.end)
            experimentalDurationExpr(de)
            return de

        case .leftParen:
            // `paren_duration_expr: LEFT_PAREN duration_expr RIGHT_PAREN`
            take()
            let inner = try durationExpr()
            guard accept(.rightParen) != nil else { throw syntaxError() }
            experimentalDurationExpr(inner)
            if let de = inner as? DurationExpr {
                de.wrapped = true
                return de
            }
            // A parenthesised literal keeps no trace of the parentheses.
            return inner

        default:
            throw syntaxError()
        }
    }

    /// Go: `offset_duration_expr`.
    ///
    /// Deliberately not a call into `durationExpr`: after `offset`, a bare literal
    /// terminates the duration, so the arithmetic loop must not run. See the file
    /// header.
    func offsetDurationExpr() throws -> any Expr {
        if cur.typ == .add || cur.typ == .sub {
            let opItem = take()

            switch cur.typ {
            case .number, .duration:
                // `unary_op number_duration_literal` — just the literal.
                let nl = numberDurationLiteral()
                if opItem.typ == .sub { nl.val *= -1 }
                if durationLiteralOutOfRange(nl.val) {
                    addParseErr(opItem.positionRange, .durationOutOfRange)
                    return NumberLiteral(val: 0)
                }
                nl.posRange.start = opItem.pos
                return nl

            case .step, .range:
                // `unary_op STEP LEFT_PAREN RIGHT_PAREN`
                let inner = take()
                guard accept(.leftParen) != nil, let rparen = accept(.rightParen) else {
                    throw syntaxError()
                }
                let de = DurationExpr(
                    op: opItem.typ,
                    rhs: DurationExpr(
                        op: inner.typ,
                        startPos: inner.positionRange.start,
                        endPos: rparen.positionRange.end),
                    startPos: opItem.pos)
                experimentalDurationExpr(de)
                return de

            case .maxOf, .minOf:
                // `unary_op max_of_min_of LEFT_PAREN duration_expr COMMA duration_expr RIGHT_PAREN`
                let inner = take()
                guard accept(.leftParen) != nil else { throw syntaxError() }
                let lhs = try durationExpr()
                guard accept(.comma) != nil else { throw syntaxError() }
                let rhs = try durationExpr()
                guard let rparen = accept(.rightParen) else { throw syntaxError() }
                let de = DurationExpr(
                    op: opItem.typ,
                    rhs: DurationExpr(
                        op: inner.typ,
                        lhs: lhs,
                        rhs: rhs,
                        startPos: inner.positionRange.start,
                        endPos: rparen.positionRange.end),
                    startPos: opItem.pos)
                experimentalDurationExpr(de)
                return de

            case .leftParen:
                // `unary_op LEFT_PAREN duration_expr RIGHT_PAREN %prec MUL`
                take()
                let inner = try durationExpr()
                guard accept(.rightParen) != nil else { throw syntaxError() }
                return applyUnaryOpToDurationExpr(opItem, inner, wrapped: true)

            default:
                throw syntaxError("offset", "number, duration, step(), or range()")
            }
        }

        switch cur.typ {
        case .number, .duration:
            // `offset_duration_expr: number_duration_literal` — wins the
            // reduce/reduce against `duration_expr`, so no arithmetic follows.
            let nl = numberDurationLiteral()
            if durationLiteralOutOfRange(nl.val) {
                addParseErr(nl.posRange, .durationOutOfRange)
                return NumberLiteral(val: 0)
            }
            return nl
        default:
            // The remaining forms are step()/range(), max_of/min_of and a
            // parenthesised expression. `durationPrimary`, not `durationExpr`: the
            // arithmetic loop must not run, or `foo offset step()*0` would fold the
            // `*0` into the offset instead of leaving it as a binary expression.
            return try durationPrimary()
        }
    }

    /// Go: `applyUnaryOpToDurationExpr`.
    func applyUnaryOpToDurationExpr(
        _ op: Item, _ expr: any Expr, wrapped: Bool
    ) -> any Expr {
        if let de = expr as? DurationExpr {
            if wrapped { de.wrapped = true }
            if op.typ == .sub {
                return DurationExpr(op: .sub, rhs: de, startPos: op.pos)
            }
            return de
        }
        if let nl = expr as? NumberLiteral {
            if op.typ == .sub { nl.val *= -1 }
            if durationLiteralOutOfRange(nl.val) {
                addParseErr(op.positionRange, .durationOutOfRange)
                return NumberLiteral(val: 0)
            }
            nl.posRange.start = op.pos
            return nl
        }
        addParseErr(op.positionRange, .expectedNumberLiteralOrDurationExpr)
        return NumberLiteral(val: 0)
    }

    /// Go: `experimentalDurationExpr` — the gate. Note it reports against the node
    /// that was already built, so the error position is the expression's, not the
    /// operator's.
    func experimentalDurationExpr(_ e: any Expr) {
        if !options.experimentalDurationExpr {
            addParseErr(e.positionRange, .durationExprNotEnabled)
        }
    }

    /// Whether the operator is one `duration_expr` accepts. The comparison and set
    /// operators share the precedence table but have no duration production.
    func isDurationOperator(_ t: ItemType) -> Bool {
        switch t {
        case .add, .sub, .mul, .div, .mod, .pow: return true
        default: return false
        }
    }
}

/// Go: `durationLiteralOutOfRange` — whether the value, read as seconds, would
/// overflow a `time.Duration`'s int64 nanoseconds.
func durationLiteralOutOfRange(_ val: Double) -> Bool {
    val > maxDurationSeconds || val < -maxDurationSeconds
}

/// Go writes this as `1<<63/1e9`, an untyped constant expression. In Swift
/// `1 << 63` overflows `Int` at compile time, so the numerator is spelled as the
/// Double it denotes — 2^63 is exactly representable, and the division is
/// correctly rounded, so the result matches Go's constant evaluation.
private let maxDurationSeconds = 9_223_372_036_854_775_808.0 / 1e9
