//===----------------------------------------------------------------------===//
// Ported from promql/parser/parse.go @ v3.13.2 — ParseErr, ParseErrors, and every
// message the parser can produce.
//
// The messages live in one enum rather than being formatted at the call sites,
// per CLAUDE.md: they are contract strings, compared byte-for-byte against Go by
// the promql/parse fixture. Keeping them together also makes them diffable
// against the `addParseErrf` calls in parse.go and the actions in
// generated_parser.y on the next upstream bump.
//
// Verb notes, because Go's formatting is not obvious:
//   - `%q` on an `ItemType` goes through `fmt`'s Stringer handling, so it is
//     `strconv.Quote(op.String())` — `"+"`, not `'+'`.
//   - `%f` is six decimal places, always.
//   - `%v` on a float64 is 'g' with precision -1.
//   - `%s` on a strconv error renders the whole NumError, function name included.
//===----------------------------------------------------------------------===//

public import PromPosRange

private import GoCompat
private import PromModel

/// Go: `ParseErr` — one error, with the position and the query it came from.
public struct ParseErr: Error, CustomStringConvertible, Sendable {
    public var positionRange: PositionRange
    /// The message. Go holds an `error`; here it is the rendered text, which is
    /// all any caller reads.
    public var message: String
    /// The query, kept so `description` can turn a byte offset into `line:col`.
    public var query: [UInt8]
    /// Go: `LineOffset` — only set by the unit-test harness.
    public var lineOffset: Int

    public init(
        positionRange: PositionRange,
        message: String,
        query: [UInt8],
        lineOffset: Int = 0
    ) {
        self.positionRange = positionRange
        self.message = message
        self.query = query
        self.lineOffset = lineOffset
    }

    /// Go: `(*ParseErr).Error()`.
    public var description: String {
        "\(positionRange.startPosInput(query: query, lineOffset: lineOffset)): parse error: \(message)"
    }
}

/// Go: `ParseErrors` — the parser reports every error it finds, not just the
/// first.
///
/// `description` deliberately shows only the first, as Go does: a wrapped
/// multi-error reads badly. Callers wanting the rest read `errors`.
public struct ParseErrors: Error, CustomStringConvertible, Sendable {
    public var errors: [ParseErr]

    public init(_ errors: [ParseErr]) { self.errors = errors }

    public var description: String {
        if let first = errors.first { return first.description }
        // Go: "Should never happen" — and panicking while printing an error is a
        // bad trade, so it explains itself instead.
        return "error contains no error message"
    }
}

/// Go: `ErrUnexpected` — returned when the parser recovered from a runtime panic.
///
/// Nothing in this port produces it: Swift has no `recover`, and a
/// precondition failure is a trap rather than something to catch. It exists so
/// the type is complete and so the fixture's `unexpected` flag has a counterpart.
public struct ErrUnexpected: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "unexpected error" }
}

// MARK: - Messages

/// Every message the PromQL parser can produce, with Go's formatting.
enum ParseErrorMessage: CustomStringConvertible {

    // ---- Syntax: the `error` productions in generated_parser.y ----

    /// Go: `unexpected(context, expected)` — `unexpected <item>[ in <ctx>][,
    /// expected <exp>]`. The item is `Item.desc()`, not its raw text.
    case unexpected(item: String, context: String, expected: String)
    /// A lexer error, passed through verbatim.
    case lexer(String)
    /// Go: the `START_EXPRESSION EOF` production.
    case noExpressionFound

    // ---- Aggregations ----

    case noArgumentsForAggregate
    /// Go: `%s() is experimental and must be enabled with --enable-feature=promql-experimental-functions`
    case experimentalAggregator(op: ItemType)
    case wrongAggregateArgCount(expected: Int, got: Int)
    case aggregationOperatorExpected(op: ItemType)

    // ---- Function calls ----

    case unknownFunction(name: String)
    case functionNotEnabled(name: String)
    case trailingCommaInArgs
    case expectedArgCount(expected: Int, name: String, got: Int)
    case expectedAtLeastArgCount(expected: Int, name: String, got: Int)
    case expectedAtMostArgCount(expected: Int, name: String, got: Int)
    case expectedLabelSelectorsGotVectorSelector
    case expectedLabelSelectors
    /// Go: `expected type %s in call to function %q, got %s`
    case expectedTypeInCall(want: ValueType, name: String, got: ValueType)

    // ---- Types ----

    /// Go: `expected type %s in %s, got %s`
    case expectedType(want: ValueType, context: String, got: ValueType)
    case expressionMustHaveValidType(got: ValueType)
    case evaluationStatementMustHaveValidType(got: ValueType)

    // ---- Binary expressions ----

    case boolModifierOnNonComparison
    case scalarComparisonNeedsBool
    case labelInOnAndGroup(label: String)
    case unsupportedBinaryOperator(op: ItemType)
    case binaryExpressionTypes
    case vectorMatchingOnlyBetweenVectors
    case fillOnlyBetweenVectors
    case noGroupingForOperation(op: ItemType)
    case setOperationsMustBeManyToMany
    case fillNotAllowedForSetOperators
    case setOperatorInScalarExpression(op: ItemType)
    case binopFillModifiersNotEnabled

    // ---- Unary, subquery, selectors ----

    case onlyPlusMinusUnary
    case unaryTypeNotAllowed(got: ValueType)
    case subqueryOnlyOnVector(got: ValueType)
    case metricNameSetTwice(name: String, other: String)
    case vectorSelectorNeedsNonEmptyMatcher
    case invalidLabelNameForGrouping(name: String)

    // ---- Ranges, offsets, @ and the extended modifiers ----

    case rangesOnlyForVectorSelectors
    case noOffsetBeforeRange
    case noAtBeforeRange
    case offsetTargetInvalid
    case offsetSetMultipleTimes
    case atTargetInvalid
    case atSetMultipleTimes
    case timestampOutOfBounds(Double)
    case anchoredNotEnabled
    case smoothedNotEnabled
    case anchoredAndSmoothedTogether
    case anchoredNotSupportedForSubqueries
    case smoothedNotSupportedForSubqueries
    case anchoredNotImplemented
    case smoothedNotImplemented

    // ---- Durations and numbers ----

    case durationExprNotEnabled
    case durationOutOfRange
    case durationMustBeGreaterThanZero
    case expectedNumberLiteralOrDurationExpr
    case divisionByZero
    case moduloByZero
    /// Go: `error parsing number: %s`, where `%s` is strconv's own NumError.
    case errorParsingNumber(String)
    /// A `model.ParseDuration` failure, passed through.
    case duration(String)
    /// Go: `error unquoting string %q: %s`
    case errorUnquotingString(value: String, reason: String)
    /// A `labels.NewMatcher` failure, passed through.
    case matcher(String)

    // ---- Series descriptions ----

    case invalidRepetition(String)
    case combiningHistograms(from: Int32, to: Int32)
    /// A `FloatHistogram.Add`/`Sub` failure, passed through.
    case histogramArithmetic(String)
    case duplicateHistogramKey(String)

    var description: String {
        switch self {

        case .unexpected(let item, let context, let expected):
            var m = "unexpected " + item
            if !context.isEmpty { m += " in " + context }
            if !expected.isEmpty { m += ", expected " + expected }
            return m
        case .lexer(let m):
            return m
        case .noExpressionFound:
            return "no expression found in input"

        case .noArgumentsForAggregate:
            return "no arguments for aggregate expression provided"
        case .experimentalAggregator(let op):
            return
                "\(op)() is experimental and must be enabled with --enable-feature=promql-experimental-functions"
        case .wrongAggregateArgCount(let expected, let got):
            return
                "wrong number of arguments for aggregate expression provided, expected \(expected), got \(got)"
        case .aggregationOperatorExpected(let op):
            return "aggregation operator expected in aggregation expression but got \(quoted(op))"

        case .unknownFunction(let name):
            return "unknown function with name \(GoStrconv.quote(name))"
        case .functionNotEnabled(let name):
            return "function \(GoStrconv.quote(name)) is not enabled"
        case .trailingCommaInArgs:
            return "trailing commas not allowed in function call args"
        case .expectedArgCount(let expected, let name, let got):
            return
                "expected \(expected) argument(s) in call to \(GoStrconv.quote(name)), got \(got)"
        case .expectedAtLeastArgCount(let expected, let name, let got):
            return
                "expected at least \(expected) argument(s) in call to \(GoStrconv.quote(name)), got \(got)"
        case .expectedAtMostArgCount(let expected, let name, let got):
            return
                "expected at most \(expected) argument(s) in call to \(GoStrconv.quote(name)), got \(got)"
        case .expectedLabelSelectorsGotVectorSelector:
            return "expected label selectors only, got vector selector instead"
        case .expectedLabelSelectors:
            return "expected label selectors only"
        case .expectedTypeInCall(let want, let name, let got):
            return
                "expected type \(want.documented) in call to function \(GoStrconv.quote(name)), got \(got.documented)"

        case .expectedType(let want, let context, let got):
            return "expected type \(want.documented) in \(context), got \(got.documented)"
        case .expressionMustHaveValidType(let got):
            return "expression must have a valid expression type but got \(got.documented)"
        case .evaluationStatementMustHaveValidType(let got):
            return
                "evaluation statement must have a valid expression type but got \(got.documented)"

        case .boolModifierOnNonComparison:
            return "bool modifier can only be used on comparison operators"
        case .scalarComparisonNeedsBool:
            return "comparisons between scalars must use BOOL modifier"
        case .labelInOnAndGroup(let label):
            return
                "label \(GoStrconv.quote(label)) must not occur in ON and GROUP clause at once"
        case .unsupportedBinaryOperator(let op):
            return "binary expression does not support operator \(quoted(op))"
        case .binaryExpressionTypes:
            return "binary expression must contain only scalar and instant vector types"
        case .vectorMatchingOnlyBetweenVectors:
            return "vector matching only allowed between instant vectors"
        case .fillOnlyBetweenVectors:
            return "filling in missing series only allowed between instant vectors"
        case .noGroupingForOperation(let op):
            return "no grouping allowed for \(quoted(op)) operation"
        case .setOperationsMustBeManyToMany:
            return "set operations must always be many-to-many"
        case .fillNotAllowedForSetOperators:
            return "filling in missing series not allowed for set operators"
        case .setOperatorInScalarExpression(let op):
            return "set operator \(quoted(op)) not allowed in binary scalar expression"
        case .binopFillModifiersNotEnabled:
            return "binop fill modifiers are experimental and not enabled"

        case .onlyPlusMinusUnary:
            return "only + and - operators allowed for unary expressions"
        case .unaryTypeNotAllowed(let got):
            return
                "unary expression only allowed on expressions of type scalar or instant vector, got \(GoStrconv.quote(got.documented))"
        case .subqueryOnlyOnVector(let got):
            // Note `%s` on the raw ValueType here, not DocumentedType: this one
            // says "matrix", not "range vector".
            return "subquery is only allowed on instant vector, got \(got) instead"
        case .metricNameSetTwice(let name, let other):
            return
                "metric name must not be set twice: \(GoStrconv.quote(name)) or \(GoStrconv.quote(other))"
        case .vectorSelectorNeedsNonEmptyMatcher:
            return "vector selector must contain at least one non-empty matcher"
        case .invalidLabelNameForGrouping(let name):
            return "invalid label name for grouping: \(GoStrconv.quote(name))"

        case .rangesOnlyForVectorSelectors:
            return "ranges only allowed for vector selectors"
        case .noOffsetBeforeRange:
            return "no offset modifiers allowed before range"
        case .noAtBeforeRange:
            return "no @ modifiers allowed before range"
        case .offsetTargetInvalid:
            return
                "offset modifier must be preceded by an instant vector selector or range vector selector or a subquery"
        case .offsetSetMultipleTimes:
            return "offset may not be set multiple times"
        case .atTargetInvalid:
            return
                "@ modifier must be preceded by an instant vector selector or range vector selector or a subquery"
        case .atSetMultipleTimes:
            return "@ <timestamp> may not be set multiple times"
        case .timestampOutOfBounds(let ts):
            // Go: `%f` — six decimal places.
            return
                "timestamp out of bounds for @ modifier: \(GoFloat.format(ts, .f, precision: 6))"
        case .anchoredNotEnabled:
            return "anchored modifier is experimental and not enabled"
        case .smoothedNotEnabled:
            return "smoothed modifier is experimental and not enabled"
        case .anchoredAndSmoothedTogether:
            return "anchored and smoothed modifiers cannot be used together"
        case .anchoredNotSupportedForSubqueries:
            return "anchored modifier is not supported for subqueries"
        case .smoothedNotSupportedForSubqueries:
            return "smoothed modifier is not supported for subqueries"
        case .anchoredNotImplemented:
            return "anchored modifier not implemented"
        case .smoothedNotImplemented:
            return "smoothed modifier not implemented"

        case .durationExprNotEnabled:
            return "experimental duration expression is not enabled"
        case .durationOutOfRange:
            return "duration out of range"
        case .durationMustBeGreaterThanZero:
            return "duration must be greater than 0"
        case .expectedNumberLiteralOrDurationExpr:
            return "expected number literal or duration expression"
        case .divisionByZero:
            return "division by zero"
        case .moduloByZero:
            return "modulo by zero"
        case .errorParsingNumber(let reason):
            return "error parsing number: \(reason)"
        case .duration(let reason):
            return reason
        case .errorUnquotingString(let value, let reason):
            return "error unquoting string \(GoStrconv.quote(value)): \(reason)"
        case .matcher(let reason):
            return reason

        case .invalidRepetition(let reason):
            return "invalid repetition in series values: \(reason)"
        case .combiningHistograms(let from, let to):
            return "error combining histograms: cannot merge from schema \(from) to \(to)"
        case .histogramArithmetic(let reason):
            return reason
        case .duplicateHistogramKey(let key):
            // Note the quotes are literal in Go's format string, not `%q`, so a
            // key containing a quote would not be escaped. Unreachable: keys come
            // from a fixed table.
            return "duplicate key \"\(key)\" in histogram"
        }
    }

    /// Go's `%q` on an `ItemType`: `fmt` routes `%q` through the Stringer, so the
    /// operator's rendering is what gets quoted.
    private func quoted(_ op: ItemType) -> String {
        GoStrconv.quote(op.description)
    }
}
