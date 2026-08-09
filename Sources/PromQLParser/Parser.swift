//===----------------------------------------------------------------------===//
// Ported from promql/parser/parse.go and generated_parser.y @ v3.13.2
//
// goyacc is replaced by recursive descent with precedence climbing (ADR-12). The
// grammar's own structure is preserved: one function per nonterminal, named
// after it, so `generated_parser.y` can be read side by side with this file.
//
// Three things about an LALR parser have to be reproduced deliberately, because
// they are observable and a naive recursive-descent parser gets them wrong:
//
//  1. **Where errors are reported.** goyacc has 24 explicit `error` productions,
//     each with its own (context, expected) pair, and one catch-all
//     `start: error` that reports `unexpected <item>`. Every syntax error must
//     land on the same one, describing the same *lookahead* token. Anything the
//     grammar has no specific production for falls back to the catch-all.
//  2. **One syntax error, then stop.** After the catch-all fires, yacc discards
//     input to the end, so exactly one syntax error is reported. Semantic errors
//     (checkAST, and the actions) accumulate — a query can report several.
//  3. **`lastClosing` and the overread.** It is updated when a closing token is
//     *lexed*, not when it is consumed, so it can already point past the token an
//     action cares about. `aggregate_op function_call_body` is the case where the
//     grammar forces a lookahead past `)`, which is why Go passes `overread` there
//     and walks back with `findPrevRightParen`. See upstream issue 16053.
//
// Note what is *not* here: `expr: duration_expr`. That alternative exists in the
// grammar, but every string it could match is claimed by an earlier one — a bare
// `step()` reduces through `function_call` (it is a function in the table, gated
// behind EnableExperimentalFunctions), `1m + 1m` through `binary_expr` over two
// `number_duration_literal`s, and `(1m)` through `paren_expr`. Duration
// expressions are therefore only reachable in duration position: inside `[...]`,
// after `offset`, and as `max_of`/`min_of` arguments. Verified against Go rather
// than reasoned about — see the promql/parse fixture.
//===----------------------------------------------------------------------===//

public import PromPosRange
public import PromLabels
public import PromHistogram
internal import GoCompat
internal import PromModel

// MARK: - Options and entry points

/// Go: `parser.Options` — the four feature gates. Each one changes which queries
/// parse at all, so they are part of the parser's contract, not tuning.
public struct Options: Sendable, Hashable {
    /// Experimental functions and the `limitk`/`limit_ratio` aggregators.
    public var enableExperimentalFunctions: Bool
    /// Arithmetic in duration position: `foo[1m+30s]`, `step()`, `max_of()`.
    public var experimentalDurationExpr: Bool
    /// The `anchored` and `smoothed` range-selector modifiers.
    public var enableExtendedRangeSelectors: Bool
    /// `fill`, `fill_left` and `fill_right` on binary operators.
    public var enableBinopFillModifiers: Bool

    public init(
        enableExperimentalFunctions: Bool = false,
        experimentalDurationExpr: Bool = false,
        enableExtendedRangeSelectors: Bool = false,
        enableBinopFillModifiers: Bool = false
    ) {
        self.enableExperimentalFunctions = enableExperimentalFunctions
        self.experimentalDurationExpr = experimentalDurationExpr
        self.enableExtendedRangeSelectors = enableExtendedRangeSelectors
        self.enableBinopFillModifiers = enableBinopFillModifiers
    }
}

/// Go: `SequenceValue` — one value in a series description, which may be a float,
/// a histogram, or omitted (`_`).
public struct SequenceValue: Sendable, CustomStringConvertible {
    public var value: Double
    public var omitted: Bool
    public var histogram: FloatHistogram?
    /// True when `counter_reset_hint:` was written explicitly, which lets a test
    /// distinguish "no hint given" from "the hint is unknown".
    public var counterResetHintSet: Bool

    public init(
        value: Double = 0,
        omitted: Bool = false,
        histogram: FloatHistogram? = nil,
        counterResetHintSet: Bool = false
    ) {
        self.value = value
        self.omitted = omitted
        self.histogram = histogram
        self.counterResetHintSet = counterResetHintSet
    }

    /// Go: `SequenceValue.String()`. Note the float form is `%f`, six decimals.
    public var description: String {
        if omitted { return "_" }
        if let histogram { return histogram.description }
        return GoFloat.format(value, .f, precision: 6)
    }
}

/// Go: `parser.Parser` / `NewParser(opts)` — the package's entry point.
///
/// A value type holding only the options: Go pools a mutable parser for
/// allocation reasons, and each parse here builds its own state instead. The
/// mutable half is ``ParseState``.
///
/// Named `Parser`, not `PromQLParser`, deliberately. A type sharing its module's
/// name shadows that module, which makes `PromQLParser.ValueType` unresolvable
/// from any module that also imports `PromChunkEnc` — and both define a
/// `ValueType`. Go disambiguates those as `parser.ValueType` and
/// `chunkenc.ValueType`; this port can only do the same if the module name stays
/// available.
public struct Parser: Sendable {
    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Go: `ParseExpr`.
    public func parseExpr(_ input: String) throws -> any Expr {
        try parseExpr(Array(input.utf8))
    }

    public func parseExpr(_ input: [UInt8]) throws -> any Expr {
        let p = ParseState(input: input, options: options, seriesDesc: false)
        let expr = p.parseExpressionEntry()
        // Only typecheck when the syntax was clean: checkAST on a partial tree
        // reports errors that are consequences of the syntax error, not of the
        // query.
        if p.parseErrors.isEmpty, let expr {
            _ = p.checkAST(expr)
        }
        if !p.parseErrors.isEmpty { throw ParseErrors(p.parseErrors) }
        guard let expr else {
            // Unreachable: an empty result always comes with an error.
            throw ParseErrors([
                ParseErr(
                    positionRange: PositionRange(start: 0, end: 0),
                    message: ParseErrorMessage.noExpressionFound.description,
                    query: input)
            ])
        }
        return expr
    }

    /// Go: `ParseMetric` — the `START_METRIC` entry point, a label set with an
    /// optional leading metric name.
    public func parseMetric(_ input: String) throws -> Labels {
        let p = ParseState(input: Array(input.utf8), options: options, seriesDesc: false)
        let lbls = p.parseMetricEntry()
        if !p.parseErrors.isEmpty { throw ParseErrors(p.parseErrors) }
        return lbls ?? Labels()
    }

    /// Go: `ParseMetricSelector` — the `START_METRIC_SELECTOR` entry point.
    ///
    /// The matchers are optional because a failed one is nil in Go, and callers
    /// see the list only when there was no error.
    public func parseMetricSelector(_ input: String) throws -> [Matcher?] {
        let p = ParseState(input: Array(input.utf8), options: options, seriesDesc: false)
        let vs = p.parseMetricSelectorEntry()
        if !p.parseErrors.isEmpty { throw ParseErrors(p.parseErrors) }
        return vs?.labelMatchers ?? []
    }

    /// Go: `ParseMetricSelectors`.
    public func parseMetricSelectors(_ matchers: [String]) throws -> [[Matcher?]] {
        var out = [[Matcher?]]()
        for s in matchers {
            out.append(try parseMetricSelector(s))
        }
        return out
    }

    /// Go: `ParseSeriesDesc` — the `START_SERIES_DESCRIPTION` entry point. This is
    /// the only one that sets the lexer's `seriesDesc` flag, and so the only one
    /// that can reach the histogram-description states.
    public func parseSeriesDesc(
        _ input: String
    ) throws -> (labels: Labels, values: [SequenceValue]) {
        let p = ParseState(input: Array(input.utf8), options: options, seriesDesc: true)
        let result = p.parseSeriesDescriptionEntry()
        if !p.parseErrors.isEmpty { throw ParseErrors(p.parseErrors) }
        return (result?.labels ?? Labels(), result?.values ?? [])
    }
}

// MARK: - The parser

/// Thrown to unwind after a syntax error has been recorded. It carries nothing:
/// the error is already in `parseErrors`, and this only exists to stop parsing,
/// the way yacc's discard-to-end-of-input does.
struct Abort: Error {}

/// Go: `parser`.
final class ParseState {
    var lex: Lexer
    let options: Options
    let input: [UInt8]

    var parseErrors: [ParseErr] = []

    /// Go: `lastClosing` — the end position of the most recent token that could
    /// end an expression.
    ///
    /// Go updates this in `Lex`, when the token is produced. Here it is updated
    /// when the token is **consumed**, which is a deliberate difference: goyacc
    /// resolves its conflicts at table-generation time, so almost every state ends
    /// up with a single default action and reduces *without* reading a lookahead —
    /// meaning Go's value is in practice the last consumed closing token, not the
    /// last lexed one. Pinned by the error positions in `(sum(foo, 1))`,
    /// `({a=""} offset 5m)` and `count(limitk by (group) (-1, x))`, each of which
    /// has a closing token immediately after the one the node ends on.
    ///
    /// The one state where the grammar genuinely forces a lookahead is
    /// `aggregate_op function_call_body`, and `findPrevRightParen` still covers it.
    var lastClosing: Pos = 0

    /// Go: `lastHistogramCounterResetHintSet`.
    var lastHistogramCounterResetHintSet = false

    /// The lookahead token. Every `unexpected()` describes this one.
    var cur: Item
    /// The most recently consumed token. The semantic errors in the grammar
    /// actions report against `yyParser.lval.item`, which for a default reduce —
    /// the common case — is the last token shifted rather than the lookahead.
    var lastItem: Item
    /// Once the lexer reports an error, it becomes sticky: Go's `Lex` returns
    /// yacc's end-of-input from then on, while `lval.item` keeps the ERROR item so
    /// `unexpected()` can suppress a duplicate report.
    private var sticky: Item?

    /// The enclosing `error` productions, innermost last. See `syntaxError()`.
    var errorContexts: [(context: String, expected: String)] = []

    /// The depth of `errorContexts` when the syntax error was raised, so the
    /// construct that owns the `error` production can run its action as it unwinds.
    var syntaxErrorDepth: Int?

    /// Nesting depth inside `series_item`, so `uintValue` can tell a repetition
    /// count apart from an item boundary. See `uintValue`.
    var seriesItemDepth = 0

    /// yacc's `Errflag`. Set to 3 when an `error` production reports, decremented
    /// on every token shifted after that. While it is non-zero the parser is still
    /// recovering, and a further error discards a token instead of reporting — which
    /// is why `{a=b}` reports "expected string" once rather than following it with
    /// "expected \",\" or \"}\"".
    var errFlag = 0

    init(input: [UInt8], options: Options, seriesDesc: Bool) {
        self.input = input
        self.options = options
        self.lex = Lexer(input, seriesDesc: seriesDesc)
        self.cur = Item(typ: .eof, pos: 0, val: [])
        self.lastItem = self.cur
        advance()
    }

    // MARK: Token stream — Go's Lex()

    /// Go: `Lex` — the next non-comment item, updating `lastClosing`.
    func advance() {
        lastItem = cur
        if let sticky {
            cur = sticky
            return
        }
        while true {
            let item = lex.nextItem()
            if item.typ == .comment { continue }

            switch item.typ {
            case .error:
                // Go reports at {lex.start, len(input)} — the whole tail, not the
                // item — and then tells yacc this is the end of input.
                addParseErr(
                    PositionRange(start: lex.start, end: Pos(input.count)),
                    .lexer(item.valString))
                sticky = item
                cur = item
                return
            default:
                break
            }
            cur = item
            if item.typ == .eof { sticky = item }
            return
        }
    }

    /// True once the token stream is exhausted, whether cleanly or through a
    /// lexer error.
    var atEnd: Bool { cur.typ == .eof || cur.typ == .error }

    /// Consumes the current token and returns it.
    @discardableResult
    func take() -> Item {
        let item = cur
        if errFlag > 0 { errFlag -= 1 }
        switch item.typ {
        case .rightBrace, .rightParen, .rightBracket, .duration, .number:
            lastClosing = item.pos + Pos(item.val.count)
        default:
            break
        }
        advance()
        return item
    }

    func accept(_ typ: ItemType) -> Item? {
        guard cur.typ == typ else { return nil }
        return take()
    }

    // MARK: Error reporting

    func addParseErr(_ range: PositionRange, _ message: ParseErrorMessage) {
        parseErrors.append(
            ParseErr(positionRange: range, message: message.description, query: input))
    }

    /// Go: `unexpected(context, expected)`.
    func unexpected(_ context: String, _ expected: String) {
        // Go: do not report lexer errors twice.
        if cur.typ == .error { return }
        addParseErr(
            cur.positionRange,
            .unexpected(item: cur.desc, context: context, expected: expected))
    }

    /// The catch-all `start: error` production: whatever the grammar has no
    /// specific message for.
    ///
    /// Not literally the catch-all, though. On a syntax error goyacc pops the
    /// stack until it finds a state that can shift `error`, so the message comes
    /// from the **innermost enclosing** `error` production, not from `start`.
    /// `errorContexts` is that stack: constructs which have an `error` production
    /// covering a whole region push their (context, expected) pair for its
    /// duration, and a failure with no production of its own reports against the
    /// innermost one. Only when the stack is empty is it really `start: error`.
    func syntaxError() -> Abort {
        if let ctx = errorContexts.last {
            unexpected(ctx.context, ctx.expected)
        } else {
            unexpected("", "")
        }
        syntaxErrorDepth = errorContexts.count
        drainInput()
        return Abort()
    }

    /// Reports a specific `error` production and unwinds.
    ///
    /// `syntaxErrorDepth` is cleared, not set: naming a production means *that*
    /// one is what yacc popped to, so no enclosing construct's action runs. Without
    /// this, `sum without(,)(some_metric)` would report the grouping error and then
    /// also "no arguments for aggregate expression provided" from `aggregate_op
    /// error`, which Go does not.
    func syntaxError(_ context: String, _ expected: String) -> Abort {
        unexpected(context, expected)
        syntaxErrorDepth = nil
        drainInput()
        return Abort()
    }

    /// yacc's `case 3: clobber input char` — after shifting `error` it keeps
    /// discarding tokens until it can proceed, which for the outermost production
    /// means to the end of the input. That matters because the lexer may not have
    /// reached its own error yet: `{} {{}}` reports the syntax error at `{` and
    /// *then* the lexer's "unexpected left brace", which only appears because the
    /// discard kept reading.
    func drainInput() {
        var guardCount = 0
        while !atEnd && guardCount < 1_000_000 {
            advance()
            guardCount += 1
        }
    }

    /// An `error` production whose rule still reduces to something usable, so the
    /// parse continues instead of unwinding. Reporting is skipped while `errFlag` is
    /// non-zero, matching yacc's "no shift yet; clobber input char" branch.
    func recoverableError(_ context: String, _ expected: String) {
        if errFlag == 0 { unexpected(context, expected) }
        errFlag = 3
    }

    /// Runs `body` with an enclosing `error` production in scope.
    func withErrorContext<T>(
        _ context: String, _ expected: String, _ body: () throws -> T
    ) throws -> T {
        errorContexts.append((context, expected))
        defer { errorContexts.removeLast() }
        return try body()
    }

    // MARK: - Entry points

    /// Go: `start: START_EXPRESSION EOF | START_EXPRESSION expr`, then `start EOF`.
    func parseExpressionEntry() -> (any Expr)? {
        if cur.typ == .eof {
            // Go: the `START_EXPRESSION EOF` production, reported with an empty
            // PositionRange rather than the input's end.
            addParseErr(PositionRange(start: 0, end: 0), .noExpressionFound)
            return nil
        }
        if cur.typ == .error {
            // The lexer already reported. Go's `Lex` returns yacc's end-of-input
            // (0) rather than the EOF *token* here, so `START_EXPRESSION EOF`
            // cannot match and no second error is added.
            return nil
        }
        do {
            let expr = try expression()
            // `start EOF`: anything left over is the catch-all error.
            if !atEnd { throw syntaxError() }
            return expr
        } catch {
            return nil
        }
    }

    /// Go: `start: START_METRIC metric`.
    func parseMetricEntry() -> Labels? {
        do {
            let lbls = try metric()
            if !atEnd { throw syntaxError() }
            return lbls
        } catch {
            return nil
        }
    }

    /// Go: `start: START_METRIC_SELECTOR vector_selector`.
    func parseMetricSelectorEntry() -> VectorSelector? {
        do {
            let vs = try vectorSelector()
            if !atEnd { throw syntaxError() }
            return vs
        } catch {
            return nil
        }
    }

    /// Go: `start: START_SERIES_DESCRIPTION series_description`.
    func parseSeriesDescriptionEntry() -> (labels: Labels, values: [SequenceValue])? {
        do {
            let lbls = try metric()
            let values = try seriesValues()
            if !atEnd { throw syntaxError() }
            return (lbls, values)
        } catch {
            return nil
        }
    }

    // MARK: - Expressions

    /// The precedence table from `generated_parser.y`, lowest first. Higher binds
    /// tighter. `OFFSET` and `LEFT_BRACKET` sit above `POW` in the grammar and are
    /// handled as postfix operators instead of appearing here.
    static let binaryPrecedence: [ItemType: Int] = [
        .lor: 1,
        .land: 2, .lunless: 2,
        .eqlc: 3, .gte: 3, .gtr: 3, .lss: 3, .lte: 3, .neq: 3,
        .trimUpper: 3, .trimLower: 3,
        .add: 4, .sub: 4,
        .mul: 5, .div: 5, .mod: 5, .atan2: 5,
        .pow: 6,
    ]
    /// The precedence `unary_expr` borrows via `%prec MUL`.
    static let mulPrecedence = 5

    /// Go: `expr`, via precedence climbing over `binary_expr`.
    func expression(_ minPrecedence: Int = 1) throws -> any Expr {
        var lhs = try unaryExpr()

        while let precedence = Self.binaryPrecedence[cur.typ], precedence >= minPrecedence {
            let opItem = take()
            let modifiers = try binModifiers()
            // POW is the only `%right` operator: its right operand may contain
            // another POW at the same precedence.
            let nextMinimum = opItem.typ == .pow ? precedence : precedence + 1
            let rhs = try expression(nextMinimum)
            lhs = newBinaryExpression(lhs: lhs, op: opItem, modifiers: modifiers, rhs: rhs)
        }
        return lhs
    }

    /// Go: `unary_expr: unary_op expr %prec MUL`.
    ///
    /// Because the rule takes MUL's precedence, only POW binds tighter than the
    /// sign — which is why `-1^2` is `-(1^2)` while `-1*2` is `(-1)*2`.
    func unaryExpr() throws -> any Expr {
        guard cur.typ == .add || cur.typ == .sub else {
            return try postfixModifiers(try primaryExpr())
        }
        let opItem = take()
        let operand = try expression(Self.mulPrecedence + 1)

        // A signed number literal folds into the literal rather than becoming a
        // UnaryExpr, so `-1` is one node and prints as `-1`.
        if let nl = operand as? NumberLiteral {
            if opItem.typ == .sub { nl.val *= -1 }
            nl.posRange.start = opItem.pos
            return nl
        }
        return UnaryExpr(op: opItem.typ, expr: operand, startPos: opItem.pos)
    }

    /// The postfix modifiers, all of which are `expr <token> ...` productions
    /// sitting above every binary operator: ranges and subqueries
    /// (`%right LEFT_BRACKET`), `offset` (`%nonassoc OFFSET`), `@`, `anchored` and
    /// `smoothed`.
    ///
    /// A loop, not a single application: `foo offset 5m offset 5m` parses and is
    /// then rejected semantically ("offset may not be set multiple times"), and
    /// `foo[5m] anchored smoothed` reaches the "cannot be used together" check.
    func postfixModifiers(_ expression: any Expr) throws -> any Expr {
        var e = expression
        loop: while true {
            switch cur.typ {
            case .leftBracket:
                e = try bracketSuffix(e)
            case .offset:
                e = try offsetSuffix(e)
            case .at:
                e = try atSuffix(e)
            case .anchored:
                // The action does not assign `$$`, so yacc's default applies and
                // the node is unchanged.
                take()
                setAnchored(e)
            case .smoothed:
                take()
                setSmoothed(e)
            default:
                break loop
            }
        }
        return e
    }

    /// Go: `matrix_selector` and `subquery_expr` — both start `expr [`.
    ///
    /// The error context changes as the parse advances, because the grammar has a
    /// separate `error` production for each stage.
    func bracketSuffix(_ e: any Expr) throws -> any Expr {
        let lbracket = take()

        guard canStartDurationExpr(cur.typ) else {
            throw syntaxError(
                "subquery or range selector", "number, duration, step(), or range()")
        }
        let range = try withErrorContext(
            "subquery or range selector", "number, duration, step(), or range()"
        ) { try positiveDurationExpr() }

        if cur.typ == .colon {
            take()
            // `expr [ range : ]` — a subquery with the default step.
            if let rbracket = accept(.rightBracket) {
                return SubqueryExpr(
                    expr: e,
                    range: durationOf(range),
                    rangeExpr: range as? DurationExpr,
                    endPos: rbracket.pos + 1)
            }
            guard canStartDurationExpr(cur.typ) else {
                throw syntaxError(
                    "subquery selector", "number, duration, step(), range(), or \"]\"")
            }
            let step = try withErrorContext(
                "subquery selector", "number, duration, step(), range(), or \"]\""
            ) { try positiveDurationExpr() }
            guard let rbracket = accept(.rightBracket) else {
                throw syntaxError("subquery selector", "\"]\"")
            }
            return SubqueryExpr(
                expr: e,
                range: durationOf(range),
                rangeExpr: range as? DurationExpr,
                step: durationOf(step),
                stepExpr: step as? DurationExpr,
                endPos: rbracket.pos + 1)
        }

        guard let rbracket = accept(.rightBracket) else {
            throw syntaxError("subquery or range", "\":\" or \"]\"")
        }

        // A range selector is only valid over a vector selector, and only before
        // any offset or @ modifier — those have to come after the range.
        var message: ParseErrorMessage? = nil
        if let vs = e as? VectorSelector {
            if vs.originalOffset.nanoseconds != 0 {
                message = .noOffsetBeforeRange
            } else if vs.timestamp != nil {
                message = .noAtBeforeRange
            }
        } else {
            message = .rangesOnlyForVectorSelectors
        }
        if let message {
            addParseErr(
                mergeRanges(lbracket.positionRange, rbracket.positionRange), message)
        }

        return MatrixSelector(
            vectorSelector: e,
            range: durationOf(range),
            rangeExpr: range as? DurationExpr,
            endPos: lastClosing)
    }

    /// Go: `offset_expr: expr OFFSET offset_duration_expr | expr OFFSET error`.
    func offsetSuffix(_ e: any Expr) throws -> any Expr {
        take()
        return try withErrorContext("offset", "number, duration, step(), or range()") {
            guard canStartOffsetDurationExpr(cur.typ) else {
                throw syntaxError("offset", "number, duration, step(), or range()")
            }
            let d = try offsetDurationExpr()
            if let nl = d as? NumberLiteral {
                addOffset(e, durationOf(nl))
            } else if let de = d as? DurationExpr {
                addOffsetExpr(e, de)
            }
            return e
        }
    }

    /// Go: `step_invariant_expr: expr AT signed_or_unsigned_number
    ///                         | expr AT at_modifier_preprocessors LEFT_PAREN RIGHT_PAREN
    ///                         | expr AT error`.
    func atSuffix(_ e: any Expr) throws -> any Expr {
        take()
        return try withErrorContext("@", "timestamp") {
            if cur.typ == .start || cur.typ == .end {
                let opItem = take()
                // No `error` production covers a missing `()`, so recovery pops back
                // to `expr AT error` — which is this context.
                guard accept(.leftParen) != nil, accept(.rightParen) != nil else {
                    throw syntaxError()
                }
                setAtModifierPreprocessor(e, opItem)
                return e
            }
            guard canStartSignedOrUnsignedNumber(cur.typ) else {
                throw syntaxError("@", "timestamp")
            }
            let ts = try signedOrUnsignedNumber()
            setTimestamp(e, ts)
            return e
        }
    }

    /// The `expr` alternatives that are not left- or right-extensions of another
    /// expression.
    func primaryExpr() throws -> any Expr {
        switch cur.typ {
        case .leftParen:
            // `paren_expr: LEFT_PAREN expr RIGHT_PAREN`
            let lparen = take()
            let inner = try expression()
            guard let rparen = accept(.rightParen) else { throw syntaxError() }
            return ParenExpr(
                expr: inner,
                posRange: mergeRanges(lparen.positionRange, rparen.positionRange))

        case .string:
            // `string_literal: STRING`. A STRING can also begin a vector selector
            // (`{"foo"}` is handled under leftBrace), but bare it is a literal.
            let item = take()
            return StringLiteral(
                val: unquoteStringBytes(item.val), posRange: item.positionRange)

        case .number, .duration:
            return numberDurationLiteral()

        case .leftBrace:
            // `vector_selector: label_matchers`
            let vs = try labelMatchers()
            assembleVectorSelector(vs)
            return vs

        default:
            break
        }

        // `aggregate_expr: aggregate_op ...`
        //
        // Every aggregator name is also a `metric_identifier`, and yacc only
        // reduces one to `aggregate_op` when the lookahead is in that
        // nonterminal's follow set — `(`, `by` or `without`. So a bare `sum` is a
        // vector selector, and `foo * sum` parses.
        if cur.typ.isAggregator {
            let after = peekType()
            if after == .leftParen || after == .by || after == .without {
                return try aggregateExpr()
            }
        }

        // A function call is an identifier-like token followed by `(`. Without the
        // paren the same token is a metric identifier, which is how `start`,
        // `step` and `offset` remain usable as metric names.
        if canStartFunctionCall(cur.typ) && peekType() == .leftParen {
            return try functionCall()
        }

        if isMetricIdentifier(cur.typ) {
            return try vectorSelector()
        }

        throw syntaxError()
    }

    /// The type of the token after `cur`, without consuming anything.
    ///
    /// Two decisions need it, and both are ones an LALR parser makes from its own
    /// lookahead: function call versus metric identifier, and aggregation versus
    /// metric identifier.
    func peekType() -> ItemType {
        // The lexer is a value type, so a copy can be run ahead without
        // disturbing the real one.
        var ahead = lex
        while true {
            let item = ahead.nextItem()
            if item.typ == .comment { continue }
            return item.typ
        }
    }

    // MARK: - Aggregations

    /// Go: `aggregate_expr`.
    ///
    /// `aggregate_op error` covers everything after the operator, so any syntax
    /// error inside the body or the modifier reports as "in aggregation" unless a
    /// nested construct has an `error` production of its own.
    func aggregateExpr() throws -> any Expr {
        let opItem = take()

        let depth = errorContexts.count + 1
        do {
            return try withErrorContext("aggregation", "") {
                try aggregateBody(op: opItem)
            }
        } catch let abort as Abort {
            aggregateErrorAction(op: opItem, depth: depth)
            throw abort
        }
    }

    private func aggregateBody(op opItem: Item) throws -> any Expr {
        if cur.typ == .by || cur.typ == .without {
            let modifier = try aggregateModifier()
            let args = try functionCallBody()
            return newAggregateExpr(
                op: opItem, modifier: modifier, arguments: args, overread: false)
        }

        // `aggregate_op error`. The fall-through form, so the depth is recorded and
        // `aggregateErrorAction` runs the rest of the production as this unwinds.
        guard cur.typ == .leftParen else {
            throw syntaxError()
        }

        let args = try functionCallBody()
        if cur.typ == .by || cur.typ == .without {
            let modifier = try aggregateModifier()
            return newAggregateExpr(
                op: opItem, modifier: modifier, arguments: args, overread: false)
        }
        // No modifier: the grammar had to look past `)` to know that, so the end
        // position has to be recovered.
        return newAggregateExpr(
            op: opItem, modifier: AggregateExpr(), arguments: args, overread: true)
    }

    /// The `aggregate_op error` production's action, run when a syntax error deeper
    /// in the aggregation unwound to it. Besides the message — which `unexpected()`
    /// has already emitted, or suppressed if the lexer got there first — it builds
    /// an empty aggregate, and that is what reports "no arguments for aggregate
    /// expression provided". `sum(` produces both errors for exactly this reason.
    func aggregateErrorAction(op: Item, depth: Int) {
        guard syntaxErrorDepth == depth else { return }
        syntaxErrorDepth = nil
        _ = newAggregateExpr(
            op: op, modifier: AggregateExpr(), arguments: [], overread: false)
    }

    /// Go: `aggregate_modifier: BY grouping_labels | WITHOUT grouping_labels`.
    func aggregateModifier() throws -> AggregateExpr {
        let keyword = take()
        let labels = try groupingLabels()
        return AggregateExpr(grouping: labels, without: keyword.typ == .without)
    }

    /// Go: `newAggregateExpr`.
    @discardableResult
    func newAggregateExpr(
        op: Item, modifier: AggregateExpr, arguments: [any Expr], overread: Bool
    ) -> AggregateExpr {
        let ret = modifier
        ret.posRange = PositionRange(start: op.pos, end: lastClosing)
        if overread {
            ret.posRange.end = lex.findPrevRightParen(fallbackPos: lastClosing)
        }
        ret.op = op.typ

        if arguments.isEmpty {
            addParseErr(ret.positionRange, .noArgumentsForAggregate)
            return ret
        }

        var desiredArgs = 1
        if ret.op.isAggregatorWithParam {
            if !options.enableExperimentalFunctions && ret.op.isExperimentalAggregator {
                addParseErr(ret.positionRange, .experimentalAggregator(op: ret.op))
                return ret
            }
            desiredArgs = 2
            ret.param = arguments[0]
        }

        if arguments.count != desiredArgs {
            addParseErr(
                ret.positionRange,
                .wrongAggregateArgCount(expected: desiredArgs, got: arguments.count))
            return ret
        }

        ret.expr = arguments[desiredArgs - 1]
        return ret
    }

    // MARK: - Binary operator modifiers

    /// Go: `bin_modifier -> fill_modifiers -> group_modifiers -> on_or_ignoring
    /// -> bool_modifier`. Flattened into one function, in the order the tokens can
    /// appear. The result is a `BinaryExpr` carrying only the modifiers, which
    /// `newBinaryExpression` then fills in — the same node reuse Go does.
    func binModifiers() throws -> BinaryExpr {
        let placeholder = NumberLiteral(val: 0)
        let ret = BinaryExpr(
            lhs: placeholder, rhs: placeholder,
            vectorMatching: VectorMatching(card: .oneToOne))

        // `bool_modifier`
        if accept(.bool) != nil {
            ret.returnBool = true
        }

        // `on_or_ignoring`
        if cur.typ == .ignoring || cur.typ == .on {
            let keyword = take()
            let labels = try groupingLabels()
            ret.vectorMatching?.matchingLabels = labels
            ret.vectorMatching?.on = keyword.typ == .on

            // `group_modifiers` — only reachable after on/ignoring.
            if cur.typ == .groupLeft || cur.typ == .groupRight {
                let side = take()
                ret.vectorMatching?.card = side.typ == .groupLeft ? .manyToOne : .oneToMany
                ret.vectorMatching?.include = try maybeGroupingLabels()
            }
        }

        // `fill_modifiers`. `fill` sets both sides; `fill_left`/`fill_right` may
        // appear in either order, and both may appear.
        if cur.typ == .fill {
            take()
            let v = try fillValue()
            ret.vectorMatching?.fillValues.lhs = v
            ret.vectorMatching?.fillValues.rhs = v
        } else if cur.typ == .fillLeft {
            take()
            ret.vectorMatching?.fillValues.lhs = try fillValue()
            if cur.typ == .fillRight {
                take()
                ret.vectorMatching?.fillValues.rhs = try fillValue()
            }
        } else if cur.typ == .fillRight {
            take()
            ret.vectorMatching?.fillValues.rhs = try fillValue()
            if cur.typ == .fillLeft {
                take()
                ret.vectorMatching?.fillValues.lhs = try fillValue()
            }
        }

        return ret
    }

    /// Go: `fill_value: LEFT_PAREN number_duration_literal RIGHT_PAREN
    ///               | LEFT_PAREN unary_op number_duration_literal RIGHT_PAREN`.
    func fillValue() throws -> Double {
        guard accept(.leftParen) != nil else { throw syntaxError() }
        var negate = false
        if cur.typ == .add || cur.typ == .sub {
            negate = cur.typ == .sub
            take()
        }
        guard cur.typ == .number || cur.typ == .duration else { throw syntaxError() }
        let nl = numberDurationLiteral()
        guard accept(.rightParen) != nil else { throw syntaxError() }
        return negate ? -nl.val : nl.val
    }

    /// Go: `newBinaryExpression`.
    func newBinaryExpression(
        lhs: any Expr, op: Item, modifiers: BinaryExpr, rhs: any Expr
    ) -> BinaryExpr {
        let ret = modifiers
        ret.lhs = lhs
        ret.rhs = rhs
        ret.op = op.typ

        if !options.enableBinopFillModifiers,
            ret.vectorMatching?.fillValues.lhs != nil
                || ret.vectorMatching?.fillValues.rhs != nil
        {
            addParseErr(ret.positionRange, .binopFillModifiersNotEnabled)
        }
        return ret
    }

    // MARK: - Grouping labels

    /// Go: `grouping_labels: LEFT_PAREN grouping_label_list [COMMA] RIGHT_PAREN
    ///                    | LEFT_PAREN RIGHT_PAREN | error`.
    func groupingLabels() throws -> [String] {
        guard accept(.leftParen) != nil else {
            throw syntaxError("grouping opts", "\"(\"")
        }
        if accept(.rightParen) != nil { return [] }

        var labels = [String]()
        while true {
            labels.append(try groupingLabel())
            if accept(.comma) != nil {
                // A trailing comma before `)` is allowed.
                if accept(.rightParen) != nil { return labels }
                continue
            }
            if accept(.rightParen) != nil { return labels }
            // `grouping_label_list error`
            throw syntaxError("grouping opts", "\",\" or \")\"")
        }
    }

    /// Go: `grouping_label: maybe_label | STRING | error`.
    func groupingLabel() throws -> String {
        if cur.typ == .string {
            let item = take()
            let unquoted = unquoteString(item.valString)
            if !ValidationScheme.utf8.isValidLabelName(unquoted) {
                addParseErr(
                    item.positionRange, .invalidLabelNameForGrouping(name: unquoted))
            }
            return unquoted
        }
        guard isMaybeLabel(cur.typ) else {
            throw syntaxError("grouping opts", "label")
        }
        let item = take()
        let name = item.valString
        if !ValidationScheme.utf8.isValidLabelName(name) {
            addParseErr(item.positionRange, .invalidLabelNameForGrouping(name: name))
        }
        return name
    }

    /// Go: `maybe_grouping_labels: /* empty */ | grouping_labels`.
    func maybeGroupingLabels() throws -> [String] {
        guard cur.typ == .leftParen else { return [] }
        return try groupingLabels()
    }

    // MARK: - Function calls

    /// Go: `function_call`, in all five of its forms — the callee may be an
    /// IDENTIFIER, `start`/`end`, `step`, `range`, or `max_of`/`min_of`. They
    /// differ only in which token type the lexer produced for the name.
    func functionCall() throws -> any Expr {
        let nameItem = take()
        let name = nameItem.valString

        let function = PromQLFunctions.lookup(name)
        if function == nil {
            addParseErr(nameItem.positionRange, .unknownFunction(name: name))
        }
        if let function, function.experimental, !options.enableExperimentalFunctions {
            addParseErr(nameItem.positionRange, .functionNotEnabled(name: name))
        }

        let args = try functionCallBody()
        return Call(
            function: function,
            args: args,
            posRange: PositionRange(start: nameItem.positionRange.start, end: lastClosing))
    }

    /// Go: `function_call_body: LEFT_PAREN function_call_args RIGHT_PAREN
    ///                       | LEFT_PAREN RIGHT_PAREN`.
    func functionCallBody() throws -> [any Expr] {
        guard accept(.leftParen) != nil else { throw syntaxError() }
        if accept(.rightParen) != nil { return [] }

        var args = [any Expr]()
        while true {
            args.append(try expression())
            if let comma = accept(.comma) {
                // `function_call_args COMMA` — a trailing comma is parsed and then
                // rejected, so the message is about the comma rather than about
                // whatever follows. `atEnd` counts: when the lexer has errored, the
                // comma is the last thing the grammar can reduce, which is how
                // `label_replace(a, \`b\`, \`c\xff\`, ...)` reports the invalid rune
                // and then the trailing comma.
                if accept(.rightParen) != nil || atEnd {
                    addParseErr(comma.positionRange, .trailingCommaInArgs)
                    return args
                }
                continue
            }
            if accept(.rightParen) != nil { return args }
            throw syntaxError()
        }
    }

    // MARK: - Vector selectors

    /// Go: `vector_selector: metric_identifier label_matchers
    ///                    | metric_identifier | label_matchers`.
    func vectorSelector() throws -> VectorSelector {
        if cur.typ == .leftBrace {
            let vs = try labelMatchers()
            assembleVectorSelector(vs)
            return vs
        }
        guard isMetricIdentifier(cur.typ) else { throw syntaxError() }
        let nameItem = take()

        if cur.typ == .leftBrace {
            let vs = try labelMatchers()
            vs.posRange = mergeRanges(nameItem.positionRange, vs.positionRange)
            vs.name = nameItem.valString
            assembleVectorSelector(vs)
            return vs
        }

        let vs = VectorSelector(
            name: nameItem.valString,
            labelMatchers: [],
            posRange: nameItem.positionRange)
        assembleVectorSelector(vs)
        return vs
    }

    /// Go: `assembleVectorSelector` — a name written outside the braces becomes a
    /// `__name__` matcher. A name written inside them already is one.
    func assembleVectorSelector(_ vs: VectorSelector) {
        guard !vs.name.isEmpty else { return }
        // Go panics if this fails, and MatchEqual cannot fail.
        guard let m = try? Matcher(.equal, LabelName.metricName, vs.name) else { return }
        vs.labelMatchers.append(m)
    }

    /// Go: `label_matchers`.
    func labelMatchers() throws -> VectorSelector {
        guard let lbrace = accept(.leftBrace) else { throw syntaxError() }
        if let rbrace = accept(.rightBrace) {
            return VectorSelector(
                labelMatchers: [],
                posRange: mergeRanges(lbrace.positionRange, rbrace.positionRange))
        }

        var matchers = [Matcher?]()
        while true {
            matchers.append(try labelMatcher())
            if accept(.comma) != nil {
                if let rbrace = accept(.rightBrace) {
                    return VectorSelector(
                        labelMatchers: matchers,
                        posRange: mergeRanges(lbrace.positionRange, rbrace.positionRange))
                }
                continue
            }
            if let rbrace = accept(.rightBrace) {
                return VectorSelector(
                    labelMatchers: matchers,
                    posRange: mergeRanges(lbrace.positionRange, rbrace.positionRange))
            }
            if atEnd { throw syntaxError("label matching", "\",\" or \"}\"") }

            // `label_match_list error`. The rule reduces to the list it already
            // has, so yacc carries on: it discards tokens until one can be shifted,
            // which here means up to the next separator or closing brace.
            recoverableError("label matching", "\",\" or \"}\"")
            while !atEnd, cur.typ != .comma, cur.typ != .rightBrace {
                advance()
            }
        }
    }

    /// Go: `label_matcher`, including its four `error` productions.
    func labelMatcher() throws -> Matcher? {
        if cur.typ == .string {
            // `string_identifier` — a quoted name, which may stand alone as the
            // metric name or take a match operator.
            let item = take()
            let name = unquoteString(item.valString)
            let nameItem = Item(typ: .metricIdentifier, pos: item.positionRange.start, val: name)
            if isMatchOp(cur.typ) {
                let op = take()
                guard let value = accept(.string) else {
                    // `string_identifier match_op error` — `$$ = nil`, and the list
                    // continues.
                    recoverableError("label matching", "string")
                    return nil
                }
                return newLabelMatcher(label: nameItem, operator: op, value: value)
            }
            return newMetricNameMatcher(nameItem)
        }

        guard cur.typ == .identifier else {
            // `label_matcher: error`
            recoverableError("label matching", "identifier or \"}\"")
            return nil
        }
        let nameItem = take()
        guard isMatchOp(cur.typ) else {
            // `IDENTIFIER error`
            recoverableError("label matching", "label matching operator")
            return nil
        }
        let op = take()
        guard let value = accept(.string) else {
            // `IDENTIFIER match_op error`
            recoverableError("label matching", "string")
            return nil
        }
        return newLabelMatcher(label: nameItem, operator: op, value: value)
    }

    /// Go: `newLabelMatcher`.
    func newLabelMatcher(label: Item, operator op: Item, value: Item) -> Matcher? {
        let val = unquoteString(value.valString)
        let matchType: MatchType
        switch op.typ {
        case .eql: matchType = .equal
        case .neq: matchType = .notEqual
        case .eqlRegex: matchType = .regexp
        case .neqRegex: matchType = .notRegexp
        default:
            // Go panics: the grammar has already restricted this to match_op.
            preconditionFailure("invalid operator")
        }
        do {
            return try Matcher(matchType, label.valString, val)
        } catch {
            addParseErr(
                mergeRanges(label.positionRange, value.positionRange),
                .matcher(String(describing: error)))
            return nil
        }
    }

    /// Go: `newMetricNameMatcher`.
    func newMetricNameMatcher(_ value: Item) -> Matcher? {
        do {
            return try Matcher(.equal, LabelName.metricName, value.valString)
        } catch {
            addParseErr(value.positionRange, .matcher(String(describing: error)))
            return nil
        }
    }

    // MARK: - Metric descriptions (START_METRIC and series descriptions)

    /// Go: `metric: metric_identifier label_set | label_set`.
    func metric() throws -> Labels {
        if isMetricIdentifier(cur.typ) {
            let nameItem = take()
            let set = try labelSet()
            var builder = LabelsBuilder(set)
            builder.set(LabelName.metricName, nameItem.valString)
            return builder.labels()
        }
        return try labelSet()
    }

    /// Go: `label_set: LEFT_BRACE label_set_list [COMMA] RIGHT_BRACE
    ///              | LEFT_BRACE RIGHT_BRACE | /* empty */`.
    func labelSet() throws -> Labels {
        guard cur.typ == .leftBrace else { return Labels() }
        take()
        if accept(.rightBrace) != nil { return Labels() }

        var items = [Label]()
        while true {
            items.append(try labelSetItem())
            if accept(.comma) != nil {
                if accept(.rightBrace) != nil { return Labels(items) }
                continue
            }
            if accept(.rightBrace) != nil { return Labels(items) }
            // `label_set_list error`
            throw syntaxError("label set", "\",\" or \"}\"")
        }
    }

    /// Go: `label_set_item`, with its four `error` productions.
    func labelSetItem() throws -> Label {
        if cur.typ == .string {
            let item = take()
            let name = unquoteString(item.valString)
            if accept(.eql) != nil {
                guard let value = accept(.string) else {
                    throw syntaxError("label set", "string")
                }
                return Label(name, unquoteString(value.valString))
            }
            // A bare quoted string is the metric name.
            return Label(LabelName.metricName, name)
        }

        guard cur.typ == .identifier else {
            throw syntaxError("label set", "identifier or \"}\"")
        }
        let nameItem = take()
        guard accept(.eql) != nil else {
            throw syntaxError("label set", "\"=\"")
        }
        guard let value = accept(.string) else {
            throw syntaxError("label set", "string")
        }
        return Label(nameItem.valString, unquoteString(value.valString))
    }

    // MARK: - Series descriptions

    /// Go: `series_values: /* empty */ | series_values SPACE series_item
    ///                  | series_values SPACE | error`.
    func seriesValues() throws -> [SequenceValue] {
        var values = [SequenceValue]()
        // `series_values: error` is an alternative of `series_values` itself, so it
        // is only reachable in the state immediately after `metric` — once a SPACE
        // has been shifted the stack no longer admits it, and recovery pops all the
        // way out to `start: error`. That is why the second error in
        // `expect fail msg: ...` has no context.
        var atStart = true
        while true {
            if atEnd { return values }
            guard accept(.space) != nil else {
                throw atStart ? syntaxError("series values", "") : syntaxError()
            }
            atStart = false
            if atEnd { return values }  // `series_values SPACE`
            values.append(contentsOf: try seriesItem())
        }
    }

    /// Go: `series_item`.
    func seriesItem() throws -> [SequenceValue] {
        seriesItemDepth += 1
        defer { seriesItemDepth -= 1 }
        return try seriesItemBody()
    }

    private func seriesItemBody() throws -> [SequenceValue] {
        if accept(.blank) != nil {
            // `BLANK` or `BLANK TIMES uint`
            guard accept(.times) != nil else { return [SequenceValue(omitted: true)] }
            let times = try uintValue()
            return (0..<times).map { _ in SequenceValue(omitted: true) }
        }

        if cur.typ == .openHist {
            let base = try histogramSeriesValue()
            if accept(.times) != nil {
                let times = try uintValue()
                let sv = newHistogramSequenceValue(base)
                // The extra leading value is for time 0, which tests ignore.
                return (0...times).map { _ in sv }
            }
            if cur.typ == .add || cur.typ == .sub {
                let opItem = take()
                let inc = try histogramSeriesValue()
                guard accept(.times) != nil else { throw syntaxError() }
                let times = try uintValue()
                return histogramsSeries(base: base, inc: inc, times: times, add: opItem.typ == .add)
            }
            return [newHistogramSequenceValue(base)]
        }

        var value = try seriesValue()
        if accept(.times) != nil {
            let times = try uintValue()
            return (0...times).map { _ in SequenceValue(value: value) }
        }
        if cur.typ == .add || cur.typ == .sub {
            // `series_value signed_number TIMES uint` — an arithmetic ramp.
            let delta = try signedNumber()
            guard accept(.times) != nil else { throw syntaxError() }
            let times = try uintValue()
            var out = [SequenceValue]()
            for _ in 0...times {
                out.append(SequenceValue(value: value))
                value += delta
            }
            return out
        }
        return [SequenceValue(value: value)]
    }

    /// Go: `series_value: IDENTIFIER | number | signed_number`.
    func seriesValue() throws -> Double {
        if cur.typ == .identifier {
            // Reported *before* consuming: Go's action runs on a default reduce, so
            // `lval.item` is still the identifier rather than the token after it.
            if cur.valString != "stale" {
                unexpected("series values", "number or \"stale\"")
            }
            take()
            return PromValue.staleNaN
        }
        if cur.typ == .add || cur.typ == .sub {
            return try signedNumber()
        }
        guard cur.typ == .number || cur.typ == .duration else {
            // No `error` production covers a series item, so this is the catch-all.
            throw syntaxError()
        }
        return try numberValue()
    }

    /// Go: `histogram_series_value: OPEN_HIST histogram_desc_map [SPACE] CLOSE_HIST`
    /// and the two empty forms.
    func histogramSeriesValue() throws -> FloatHistogram {
        guard accept(.openHist) != nil else { throw syntaxError() }
        _ = accept(.space)
        if accept(.closeHist) != nil {
            return buildHistogramFromMap([:])
        }
        let desc = try histogramDescMap()
        _ = accept(.space)
        guard accept(.closeHist) != nil else {
            throw syntaxError(
                "histogram description", "histogram description key, e.g. buckets:[5 10 7]")
        }
        return buildHistogramFromMap(desc)
    }

    /// Go: `histogram_desc_map: histogram_desc_map SPACE histogram_desc_item
    ///                       | histogram_desc_item | histogram_desc_map error`.
    ///
    /// Go builds a one-entry map per item and merges left-to-right, so on a
    /// duplicate key the **first** occurrence wins and the second is reported.
    func histogramDescMap() throws -> [String: HistogramDescValue] {
        var map = [String: HistogramDescValue]()
        while true {
            let (key, value) = try histogramDescItem()
            if map[key] != nil {
                // Go reports this with an empty PositionRange.
                addParseErr(PositionRange(start: 0, end: 0), .duplicateHistogramKey(key))
            } else {
                map[key] = value
            }
            // A SPACE may separate another item, or precede CLOSE_HIST.
            guard cur.typ == .space else { return map }
            var ahead = lex
            let next = ahead.nextItem()
            if next.typ == .closeHist { return map }
            take()
            guard isHistogramDescKey(cur.typ) else {
                throw syntaxError(
                    "histogram description", "histogram description key, e.g. buckets:[5 10 7]")
            }
        }
    }

    /// One key/value of a histogram description. The value's type is fixed by the
    /// grammar for each key, which is why `buildHistogramFromMap`'s
    /// "error parsing ..." branches are unreachable.
    func histogramDescItem() throws -> (String, HistogramDescValue) {
        guard isHistogramDescKey(cur.typ) else {
            throw syntaxError(
                "histogram description", "histogram description key, e.g. buckets:[5 10 7]")
        }
        let keyItem = take()
        guard accept(.colon) != nil else { throw syntaxError() }

        switch keyItem.typ {
        case .schemaDesc:
            return ("schema", .int(try intValue()))
        case .sumDesc:
            return ("sum", .float(try signedOrUnsignedNumber()))
        case .countDesc:
            return ("count", .float(try signedOrUnsignedNumber()))
        case .zeroBucketDesc:
            return ("z_bucket", .float(try signedOrUnsignedNumber()))
        case .zeroBucketWidthDesc:
            return ("z_bucket_w", .float(try numberValue()))
        case .customValuesDesc:
            return ("custom_values", .floats(try bucketSet()))
        case .bucketsDesc:
            return ("buckets", .floats(try bucketSet()))
        case .offsetDesc:
            return ("offset", .int(try intValue()))
        case .negativeBucketsDesc:
            return ("n_buckets", .floats(try bucketSet()))
        case .negativeOffsetDesc:
            return ("n_offset", .int(try intValue()))
        case .counterResetHintDesc:
            guard isCounterResetHint(cur.typ) else { throw syntaxError() }
            return ("counter_reset_hint", .hint(take().typ))
        default:
            throw syntaxError()
        }
    }

    /// Go: `bucket_set: LEFT_BRACKET bucket_set_list [SPACE] RIGHT_BRACKET`.
    func bucketSet() throws -> [Double] {
        guard accept(.leftBracket) != nil else { throw syntaxError() }
        var out = [Double]()
        out.append(try signedOrUnsignedNumber())
        while true {
            if accept(.rightBracket) != nil { return out }
            guard accept(.space) != nil else { throw syntaxError() }
            if accept(.rightBracket) != nil { return out }
            out.append(try signedOrUnsignedNumber())
        }
    }

    // MARK: - Numbers and durations

    /// Go: `number_duration_literal: NUMBER | DURATION`.
    func numberDurationLiteral() -> NumberLiteral {
        let item = take()
        if item.typ == .duration {
            var seconds = 0.0
            do {
                seconds = try PromDuration.parse(item.valString).seconds
            } catch {
                addParseErr(item.positionRange, .duration(String(describing: error)))
            }
            return NumberLiteral(
                val: seconds, duration: true, posRange: item.positionRange)
        }
        return NumberLiteral(val: number(item.valString), posRange: item.positionRange)
    }

    /// Go: `number: NUMBER | DURATION` — the bare float, without a node.
    func numberValue() throws -> Double {
        guard cur.typ == .number || cur.typ == .duration else { throw syntaxError() }
        let item = take()
        if item.typ == .duration {
            do {
                return try PromDuration.parse(item.valString).seconds
            } catch {
                addParseErr(item.positionRange, .duration(String(describing: error)))
                return 0
            }
        }
        return number(item.valString)
    }

    /// Go: `signed_number: ADD number | SUB number`.
    func signedNumber() throws -> Double {
        guard cur.typ == .add || cur.typ == .sub else { throw syntaxError() }
        let negate = cur.typ == .sub
        take()
        let v = try numberValue()
        return negate ? -v : v
    }

    /// Go: `signed_or_unsigned_number: number | signed_number`.
    func signedOrUnsignedNumber() throws -> Double {
        if cur.typ == .add || cur.typ == .sub { return try signedNumber() }
        return try numberValue()
    }

    /// Go: `uint: NUMBER`, via `strconv.ParseUint(val, 10, 64)`.
    ///
    /// A repetition count that is not a number reports "in series values", while
    /// the same failure at an item boundary does not — `metric 1x` gets the context
    /// and `expect fail msg:` does not. Pinned by the promql/seriesdesc fixture:
    /// the difference is how far yacc's recovery has to pop before it finds a state
    /// that still admits `series_values: error`, and after TIMES it is inside a
    /// partially built `series_item` where it does.
    func uintValue() throws -> UInt64 {
        guard let item = accept(.number) else {
            throw seriesItemDepth > 0 ? syntaxError("series values", "") : syntaxError()
        }
        let (v, err) = GoStrconv.parseUint(item.valString, base: 10, bitSize: 64)
        if let err {
            addParseErr(item.positionRange, .invalidRepetition(err.description))
        }
        return v
    }

    /// Go: `int: SUB uint | uint`.
    func intValue() throws -> Int64 {
        if cur.typ == .sub {
            take()
            return -Int64(bitPattern: try uintValue())
        }
        return Int64(bitPattern: try uintValue())
    }

    /// Go: `parser.number(val)` — `ParseInt(val, 0, 64)` first, so `0x1f` is 31 and
    /// `0755` is 493, then `ParseFloat` as a fallback.
    func number(_ val: String) -> Double {
        let (n, intErr) = GoStrconv.parseInt(val, base: 0, bitSize: 64)
        if intErr == nil { return Double(n) }
        let (f, floatErr) = GoFloat.parseAllowingRange(val)
        if let floatErr {
            addParseErr(
                lastItem.positionRange,
                .errorParsingNumber(
                    GoNumError(fn: "ParseFloat", num: val, err: floatErr).description))
        }
        return f
    }

    /// Go: `time.Duration(math.Round(numLit.Val * float64(time.Second)))`.
    func durationOf(_ nl: NumberLiteral) -> GoDuration {
        GoDuration(nanoseconds: Int64((nl.val * 1e9).rounded()))
    }

    /// The same conversion for whichever of the two duration node kinds appeared;
    /// a `DurationExpr` has no constant value, so it contributes zero and travels
    /// in the node's `RangeExpr`/`StepExpr` field instead.
    func durationOf(_ e: any Expr) -> GoDuration {
        guard let nl = e as? NumberLiteral else { return GoDuration(nanoseconds: 0) }
        return durationOf(nl)
    }
}

/// The value side of a histogram description entry. Typed, because the grammar
/// fixes the type per key.
enum HistogramDescValue: Equatable {
    case int(Int64)
    case float(Double)
    case floats([Double])
    case hint(ItemType)
}

// MARK: - Token classification

/// Go: `metric_identifier` — the token list on line 837 of generated_parser.y.
/// Most of these are keywords, listed so they keep working as metric names.
func isMetricIdentifier(_ t: ItemType) -> Bool {
    switch t {
    case .avg, .bottomk, .by, .count, .countValues, .fill, .fillLeft, .fillRight,
        .group, .identifier, .land, .lor, .lunless, .max, .metricIdentifier, .min,
        .offset, .quantile, .stddev, .stdvar, .sum, .topk, .without, .start, .end,
        .limitk, .limitRatio, .step, .range, .anchored, .smoothed, .maxOf, .minOf:
        return true
    default:
        return false
    }
}

/// Go: `maybe_label` — the keywords that can also be a label name inside grouping
/// options. A superset of `metric_identifier`: it adds `bool`, `group_left`,
/// `group_right`, `ignoring`, `on` and `atan2`, and drops nothing.
func isMaybeLabel(_ t: ItemType) -> Bool {
    switch t {
    case .bool, .groupLeft, .groupRight, .ignoring, .on, .atan2:
        return true
    default:
        return isMetricIdentifier(t)
    }
}

/// Go: `match_op`.
func isMatchOp(_ t: ItemType) -> Bool {
    switch t {
    case .eql, .neq, .eqlRegex, .neqRegex: return true
    default: return false
    }
}

/// The five callee forms of `function_call`.
func canStartFunctionCall(_ t: ItemType) -> Bool {
    switch t {
    case .identifier, .start, .end, .step, .range, .maxOf, .minOf: return true
    default: return false
    }
}

/// Whether the token can begin a `duration_expr`.
func canStartDurationExpr(_ t: ItemType) -> Bool {
    switch t {
    case .number, .duration, .add, .sub, .leftParen, .step, .range, .maxOf, .minOf:
        return true
    default:
        return false
    }
}

/// `offset_duration_expr` accepts everything `duration_expr` does — the extra
/// alternatives it adds all start with the same tokens.
func canStartOffsetDurationExpr(_ t: ItemType) -> Bool { canStartDurationExpr(t) }

/// Whether the token can begin `signed_or_unsigned_number`.
func canStartSignedOrUnsignedNumber(_ t: ItemType) -> Bool {
    switch t {
    case .number, .duration, .add, .sub: return true
    default: return false
    }
}

func isHistogramDescKey(_ t: ItemType) -> Bool {
    t > .histogramDescStart && t < .histogramDescEnd
}

func isCounterResetHint(_ t: ItemType) -> Bool {
    switch t {
    case .unknownCounterReset, .counterReset, .notCounterReset, .gaugeType: return true
    default: return false
    }
}
