//===----------------------------------------------------------------------===//
// Ported from promql/parser/parse.go @ v3.13.2 — the modifier setters, the
// histogram-description builders, and `checkAST`.
//
// `checkAST` runs only after a clean parse (see `parseExpr`), and unlike the
// syntax errors it accumulates: one query can report several. The order it
// reports in is observable, because only the first error is rendered by
// `ParseErrors.Error()` — so the traversal order is part of the contract.
//===----------------------------------------------------------------------===//

public import PromPosRange
internal import GoCompat
public import PromHistogram
internal import PromLabels
internal import PromModel

extension Parser {

    // MARK: - Offsets

    /// Go: `addOffset`.
    func addOffset(_ e: any Expr, _ offset: GoDuration) {
        guard let target = offsetTarget(e) else { return }

        // parseDuration already guarantees a zero offset modifier is impossible, so
        // a non-zero existing offset means it was written twice.
        if target.originalOffset().nanoseconds != 0 || target.originalOffsetExpr() != nil {
            addParseErr(e.positionRange, .offsetSetMultipleTimes)
        } else {
            target.setOriginalOffset(offset)
        }
        target.setEndPos(lastClosing)
    }

    /// Go: `addOffsetExpr`.
    func addOffsetExpr(_ e: any Expr, _ expr: DurationExpr) {
        guard let target = offsetTarget(e) else { return }

        if target.originalOffset().nanoseconds != 0 || target.originalOffsetExpr() != nil {
            addParseErr(e.positionRange, .offsetSetMultipleTimes)
        } else {
            target.setOriginalOffsetExpr(expr)
        }
        target.setEndPos(lastClosing)
    }

    /// The three node types an `offset` can attach to, resolved to the vector
    /// selector that actually stores it. Go writes this out twice with pointers;
    /// here it is one lookup returning a small accessor.
    private func offsetTarget(_ e: any Expr) -> OffsetTarget? {
        switch e {
        case let vs as VectorSelector:
            return OffsetTarget(selector: vs, endPosNode: .vectorSelector(vs))
        case let ms as MatrixSelector:
            guard let vs = ms.vectorSelector as? VectorSelector else {
                addParseErr(e.positionRange, .rangesOnlyForVectorSelectors)
                return nil
            }
            return OffsetTarget(selector: vs, endPosNode: .matrixSelector(ms))
        case let sq as SubqueryExpr:
            return OffsetTarget(selector: nil, subquery: sq, endPosNode: .subquery(sq))
        default:
            addParseErr(e.positionRange, .offsetTargetInvalid)
            return nil
        }
    }

    // MARK: - The @ modifier

    /// Go: `setTimestamp`.
    func setTimestamp(_ e: any Expr, _ ts: Double) {
        if ts.isInfinite || ts.isNaN || ts >= Double(Int64.max) || ts <= Double(Int64.min) {
            addParseErr(e.positionRange, .timestampOutOfBounds(ts))
        }
        guard let target = atModifierTarget(e) else { return }
        // Go: timestamp.FromFloatSeconds — `int64(math.Round(ts*1000))`, rounding
        // rather than truncating. Note Go does NOT return after reporting the
        // out-of-bounds error above, so this conversion still runs on a NaN or an
        // infinity; the Go spec leaves that case implementation-defined, and Swift
        // traps outright. The stored value is unobservable either way — an AST is
        // only ever inspected after an error-free parse — so it is clamped.
        target.setTimestamp(clampToInt64((ts * 1000).rounded()))
        target.setEndPos(lastClosing)
    }

    /// Go: `setAtModifierPreprocessor`.
    func setAtModifierPreprocessor(_ e: any Expr, _ op: Item) {
        guard let target = atModifierTarget(e) else { return }
        target.setStartOrEnd(op.typ)
        target.setEndPos(lastClosing)
    }

    /// Go: `getAtModifierVars`, including the duplicate check.
    private func atModifierTarget(_ e: any Expr) -> AtModifierTarget? {
        var target: AtModifierTarget
        switch e {
        case let vs as VectorSelector:
            target = AtModifierTarget(selector: vs, endPosNode: .vectorSelector(vs))
        case let ms as MatrixSelector:
            guard let vs = ms.vectorSelector as? VectorSelector else {
                addParseErr(e.positionRange, .rangesOnlyForVectorSelectors)
                return nil
            }
            target = AtModifierTarget(selector: vs, endPosNode: .matrixSelector(ms))
        case let sq as SubqueryExpr:
            target = AtModifierTarget(selector: nil, subquery: sq, endPosNode: .subquery(sq))
        default:
            addParseErr(e.positionRange, .atTargetInvalid)
            return nil
        }

        if target.timestamp() != nil || target.startOrEnd() == .start
            || target.startOrEnd() == .end
        {
            addParseErr(e.positionRange, .atSetMultipleTimes)
            return nil
        }
        return target
    }

    // MARK: - anchored / smoothed

    /// Go: `setAnchored`.
    func setAnchored(_ e: any Expr) {
        if !options.enableExtendedRangeSelectors {
            addParseErr(e.positionRange, .anchoredNotEnabled)
            return
        }
        switch e {
        case let vs as VectorSelector:
            vs.anchored = true
            if vs.smoothed { addParseErr(e.positionRange, .anchoredAndSmoothedTogether) }
        case let ms as MatrixSelector:
            guard let vs = ms.vectorSelector as? VectorSelector else { return }
            vs.anchored = true
            if vs.smoothed { addParseErr(e.positionRange, .anchoredAndSmoothedTogether) }
        case is SubqueryExpr:
            addParseErr(e.positionRange, .anchoredNotSupportedForSubqueries)
        default:
            addParseErr(e.positionRange, .anchoredNotImplemented)
        }
    }

    /// Go: `setSmoothed`.
    func setSmoothed(_ e: any Expr) {
        if !options.enableExtendedRangeSelectors {
            addParseErr(e.positionRange, .smoothedNotEnabled)
            return
        }
        switch e {
        case let vs as VectorSelector:
            vs.smoothed = true
            if vs.anchored { addParseErr(e.positionRange, .anchoredAndSmoothedTogether) }
        case let ms as MatrixSelector:
            guard let vs = ms.vectorSelector as? VectorSelector else { return }
            vs.smoothed = true
            if vs.anchored { addParseErr(e.positionRange, .anchoredAndSmoothedTogether) }
        case is SubqueryExpr:
            addParseErr(e.positionRange, .smoothedNotSupportedForSubqueries)
        default:
            addParseErr(e.positionRange, .smoothedNotImplemented)
        }
    }

    // MARK: - Strings

    /// Go: `unquoteString`, which is `strutil.Unquote` — Go's `strconv.Unquote`
    /// with the single-quote special case removed, so `'a'` behaves like `"a"`.
    func unquoteString(_ s: String) -> String {
        String(decoding: unquoteStringBytes(Array(s.utf8)), as: UTF8.self)
    }

    /// The byte form. A string literal's value can be invalid UTF-8, so the
    /// primitive works in bytes and only the label paths decode (ADR-9).
    func unquoteStringBytes(_ s: [UInt8]) -> [UInt8] {
        do {
            return try PromStrutil.unquoteBytes(s)
        } catch {
            addParseErr(
                lastItem.positionRange,
                .errorUnquotingString(
                    value: String(decoding: s, as: UTF8.self),
                    reason: String(describing: error)))
            return []
        }
    }

    // MARK: - Histograms

    /// Go: `buildHistogramFromMap`.
    ///
    /// Go's map is `map[string]any` and every read is a type assertion with an
    /// "error parsing ..." branch behind it. Those branches are unreachable: the
    /// grammar fixes the value's type per key, and `mergeMaps` keeps the first
    /// value on a duplicate, so the type cannot change. The typed enum here makes
    /// that explicit rather than leaving dead error paths around.
    func buildHistogramFromMap(_ desc: [String: HistogramDescValue]) -> FloatHistogram {
        var output = FloatHistogram()
        lastHistogramCounterResetHintSet = false

        if case .int(let schema)? = desc["schema"] { output.schema = Int32(truncatingIfNeeded: schema) }
        if case .float(let sum)? = desc["sum"] { output.sum = sum }
        if case .float(let count)? = desc["count"] { output.count = count }
        if case .float(let zc)? = desc["z_bucket"] { output.zeroCount = zc }
        if case .float(let zt)? = desc["z_bucket_w"] { output.zeroThreshold = zt }
        if case .floats(let cv)? = desc["custom_values"] { output.customValues = cv }

        if case .hint(let hint)? = desc["counter_reset_hint"] {
            lastHistogramCounterResetHintSet = true
            switch hint {
            case .unknownCounterReset: output.counterResetHint = .unknownCounterReset
            case .counterReset: output.counterResetHint = .counterReset
            case .notCounterReset: output.counterResetHint = .notCounterReset
            case .gaugeType: output.counterResetHint = .gaugeType
            default: break  // Unreachable: the grammar allows only these four.
            }
        }

        let (positive, positiveSpans) = buildBucketsAndSpans(desc, "buckets", "offset")
        output.positiveBuckets = positive
        output.positiveSpans = positiveSpans

        let (negative, negativeSpans) = buildBucketsAndSpans(desc, "n_buckets", "n_offset")
        output.negativeBuckets = negative
        output.negativeSpans = negativeSpans

        return output
    }

    /// Go: `buildHistogramBucketsAndSpans` — the DSL gives one contiguous span, so
    /// the offset and the bucket count are all a span needs.
    private func buildBucketsAndSpans(
        _ desc: [String: HistogramDescValue], _ bucketsKey: String, _ offsetKey: String
    ) -> ([Double], [Span]) {
        var buckets = [Double]()
        if case .floats(let bs)? = desc[bucketsKey] { buckets = bs }

        var offset: Int32 = 0
        if case .int(let o)? = desc[offsetKey] { offset = Int32(truncatingIfNeeded: o) }

        guard !buckets.isEmpty else { return (buckets, []) }
        return (buckets, [Span(offset: offset, length: UInt32(buckets.count))])
    }

    /// Go: `newHistogramSequenceValue`.
    func newHistogramSequenceValue(_ h: FloatHistogram) -> SequenceValue {
        SequenceValue(histogram: h, counterResetHintSet: lastHistogramCounterResetHintSet)
    }

    /// Go: `histogramsIncreaseSeries` / `histogramsDecreaseSeries`, which share
    /// `histogramsSeries`.
    ///
    /// The hint flag is captured from the *increment* histogram, because it was
    /// built second and so is what `lastHistogramCounterResetHintSet` now holds.
    func histogramsSeries(
        base: FloatHistogram, inc: FloatHistogram, times: UInt64, add: Bool
    ) -> [SequenceValue] {
        let hintSet = lastHistogramCounterResetHintSet
        var out = [SequenceValue]()
        // An extra value for time 0, which the test harness ignores.
        out.append(SequenceValue(histogram: base, counterResetHintSet: hintSet))
        var current = base
        var i: UInt64 = 1
        while i <= times {
            if current.schema > inc.schema {
                addSemanticError(
                    .combiningHistograms(from: inc.schema, to: current.schema))
                return []
            }
            do {
                // Go: `combine(cur.Copy(), inc)` — the copy is mutated in place and
                // becomes the next value, so the previous one stays untouched in the
                // result list.
                var next = current.copy()
                if add {
                    _ = try next.add(inc)
                } else {
                    _ = try next.sub(inc)
                }
                current = next
            } catch {
                addSemanticError(.histogramArithmetic(String(describing: error)))
                return out
            }
            out.append(SequenceValue(histogram: current, counterResetHintSet: hintSet))
            i += 1
        }
        return out
    }

    /// Go: `addSemanticError` — reports against the last item the lexer produced.
    func addSemanticError(_ message: ParseErrorMessage) {
        addParseErr(lastItem.positionRange, message)
    }

    // MARK: - checkAST

    /// Go: `expectType`.
    func expectType(_ node: (any Expr)?, _ want: ValueType, _ context: String) {
        guard let node else { return }
        let t = checkAST(node)
        if t != want {
            addParseErr(
                node.positionRange, .expectedType(want: want, context: context, got: t))
        }
    }

    /// Go: `checkAST`. Returns the node's type and reports every problem it finds
    /// on the way down.
    @discardableResult
    func checkAST(_ node: any Expr) -> ValueType {
        let typ = node.type

        switch node {
        case let n as AggregateExpr:
            if !n.op.isAggregator {
                addParseErr(n.positionRange, .aggregationOperatorExpected(op: n.op))
            }
            expectType(n.expr, .vector, "aggregation expression")
            if n.op == .topk || n.op == .bottomk || n.op == .quantile || n.op == .limitk
                || n.op == .limitRatio
            {
                expectType(n.param, .scalar, "aggregation parameter")
            }
            if n.op == .countValues {
                expectType(n.param, .string, "aggregation parameter")
            }

        case let n as BinaryExpr:
            checkBinaryExpr(n)

        case let n as Call:
            checkCall(n)

        case let n as ParenExpr:
            checkAST(n.expr)

        case let n as UnaryExpr:
            if n.op != .add && n.op != .sub {
                addParseErr(n.positionRange, .onlyPlusMinusUnary)
            }
            let t = checkAST(n.expr)
            if t != .scalar && t != .vector {
                addParseErr(n.positionRange, .unaryTypeNotAllowed(got: t))
            }

        case let n as SubqueryExpr:
            let ty = checkAST(n.expr)
            if ty != .vector {
                addParseErr(n.positionRange, .subqueryOnlyOnVector(got: ty))
            }

        case let n as MatrixSelector:
            checkAST(n.vectorSelector)

        case let n as VectorSelector:
            checkVectorSelector(n)

        case is NumberLiteral, is StringLiteral, is DurationExpr:
            // Terminals. DurationExpr is not in Go's switch, so it falls to the
            // `default` there and reports "unknown node type" — but it can never
            // reach checkAST, because a duration expression only ever hangs off a
            // MatrixSelector's RangeExpr, which checkAST does not descend into.
            break

        default:
            addParseErr(node.positionRange, .expressionMustHaveValidType(got: typ))
        }
        return typ
    }

    private func checkBinaryExpr(_ n: BinaryExpr) {
        let lt = checkAST(n.lhs)
        let rt = checkAST(n.rhs)

        // Go: the operator's own range, with whitespace trimmed off both ends.
        // Computed lazily because most queries never need it.
        func opRange() -> PositionRange {
            var start = n.lhs.positionRange.end
            while start >= 0, Int(start) < input.count, isSpaceByte(input[Int(start)]) {
                start += 1
            }
            var end = n.rhs.positionRange.start - 1
            while end >= 0, Int(end) < input.count, isSpaceByte(input[Int(end)]) {
                end -= 1
            }
            return PositionRange(start: start, end: end)
        }

        if n.returnBool && !n.op.isComparisonOperator {
            addParseErr(opRange(), .boolModifierOnNonComparison)
        }

        if n.op.isComparisonOperator && !n.returnBool && n.rhs.type == .scalar
            && n.lhs.type == .scalar
        {
            addParseErr(opRange(), .scalarComparisonNeedsBool)
        }

        if n.op.isSetOperator && n.vectorMatching?.card == .oneToOne {
            n.vectorMatching?.card = .manyToMany
        }

        if let vm = n.vectorMatching {
            for l1 in vm.matchingLabels {
                for l2 in vm.include where l1 == l2 && vm.on {
                    addParseErr(opRange(), .labelInOnAndGroup(label: l1))
                }
            }
        }

        if !n.op.isOperator {
            addParseErr(n.positionRange, .unsupportedBinaryOperator(op: n.op))
        }
        if lt != .scalar && lt != .vector {
            addParseErr(n.lhs.positionRange, .binaryExpressionTypes)
        }
        if rt != .scalar && rt != .vector {
            addParseErr(n.rhs.positionRange, .binaryExpressionTypes)
        }

        if (lt != .vector || rt != .vector), n.vectorMatching != nil {
            if !(n.vectorMatching?.matchingLabels.isEmpty ?? true) {
                addParseErr(n.positionRange, .vectorMatchingOnlyBetweenVectors)
            }
            if n.vectorMatching?.fillValues.lhs != nil
                || n.vectorMatching?.fillValues.rhs != nil
            {
                addParseErr(n.positionRange, .fillOnlyBetweenVectors)
            }
            n.vectorMatching = nil
        } else if n.op.isSetOperator {
            // Both operands are vectors here.
            if n.vectorMatching?.card == .oneToMany || n.vectorMatching?.card == .manyToOne {
                addParseErr(n.positionRange, .noGroupingForOperation(op: n.op))
            }
            if n.vectorMatching?.card != .manyToMany {
                addParseErr(n.positionRange, .setOperationsMustBeManyToMany)
            }
            if n.vectorMatching?.fillValues.lhs != nil
                || n.vectorMatching?.fillValues.rhs != nil
            {
                addParseErr(n.positionRange, .fillNotAllowedForSetOperators)
            }
        }

        if (lt == .scalar || rt == .scalar) && n.op.isSetOperator {
            addParseErr(n.positionRange, .setOperatorInScalarExpression(op: n.op))
        }
    }

    private func checkCall(_ n: Call) {
        guard let function = n.function else {
            // Go would dereference nil and panic; the "unknown function" error has
            // already been reported, and nothing else about the call is checkable.
            return
        }
        let nargs = function.argTypes.count
        if function.variadic == 0 {
            if nargs != n.args.count {
                addParseErr(
                    n.positionRange,
                    .expectedArgCount(expected: nargs, name: function.name, got: n.args.count))
            }
        } else {
            let na = nargs - 1
            if na > n.args.count {
                addParseErr(
                    n.positionRange,
                    .expectedAtLeastArgCount(
                        expected: na, name: function.name, got: n.args.count))
            } else {
                let nargsmax = na + function.variadic
                if function.variadic > 0 && nargsmax < n.args.count {
                    addParseErr(
                        n.positionRange,
                        .expectedAtMostArgCount(
                            expected: nargsmax, name: function.name, got: n.args.count))
                }
            }
        }

        // `info()`'s second argument is a bare label-selector set, not a selector.
        if function.name == "info" && n.args.count > 1 {
            if n.args[1].type != .vector {
                addParseErr(
                    n.positionRange,
                    .expectedTypeInCall(
                        want: .vector, name: function.name, got: n.args[1].type))
            }
            if let vs = n.args[1] as? VectorSelector {
                if !vs.name.isEmpty {
                    addParseErr(
                        n.args[1].positionRange, .expectedLabelSelectorsGotVectorSelector)
                } else {
                    // Exempt it from the non-empty-matcher rule.
                    vs.bypassEmptyMatcherCheck = true
                }
            } else {
                addParseErr(n.args[1].positionRange, .expectedLabelSelectors)
            }
        }

        for (index, arg) in n.args.enumerated() {
            var i = index
            if i >= function.argTypes.count {
                if function.variadic == 0 {
                    // Not variadic: the surplus arguments are already reported and
                    // their types are not checked.
                    break
                }
                i = function.argTypes.count - 1
            }
            let t = checkAST(arg)
            if t != function.argTypes[i] {
                addParseErr(
                    arg.positionRange,
                    .expectedTypeInCall(want: function.argTypes[i], name: function.name, got: t))
            }
        }
    }

    private func checkVectorSelector(_ n: VectorSelector) {
        if !n.name.isEmpty {
            // The last matcher is the one the bare name produced; any earlier
            // `__name__` matcher means the name was given twice.
            for m in n.labelMatchers.dropLast() {
                if let m, m.name == LabelName.metricName {
                    addParseErr(
                        n.positionRange,
                        .metricNameSetTwice(name: n.name, other: m.value))
                }
            }
            // An explicit metric name is itself a non-empty matcher, so the check
            // below does not apply.
            return
        }
        guard !n.bypassEmptyMatcherCheck else { return }

        // At least one matcher has to reject the empty string, or the selector
        // would match every series in the database — usually a typo.
        var notEmpty = false
        for lm in n.labelMatchers {
            if let lm, !lm.matches("") {
                notEmpty = true
                break
            }
        }
        if !notEmpty {
            addParseErr(n.positionRange, .vectorSelectorNeedsNonEmptyMatcher)
        }
    }
}

/// Go: `isSpace`.
func isSpaceByte(_ b: UInt8) -> Bool {
    b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n")
        || b == UInt8(ascii: "\r")
}

/// A `Double` to `Int64` conversion that cannot trap, for the one site where Go
/// performs a conversion its own spec calls implementation-defined. Not a claim
/// about what Go produces — the value is unreachable through any observable
/// surface.
func clampToInt64(_ v: Double) -> Int64 {
    if v.isNaN { return 0 }
    if v >= Double(Int64.max) { return Int64.max }
    if v <= Double(Int64.min) { return Int64.min }
    return Int64(v)
}

// MARK: - Modifier targets

/// Which node's `EndPos` an offset or `@` modifier updates. Go takes a pointer to
/// the field; this names the three cases instead.
enum EndPosNode {
    case vectorSelector(VectorSelector)
    case matrixSelector(MatrixSelector)
    case subquery(SubqueryExpr)

    func set(_ pos: Pos) {
        switch self {
        case .vectorSelector(let vs): vs.posRange.end = pos
        case .matrixSelector(let ms): ms.endPos = pos
        case .subquery(let sq): sq.endPos = pos
        }
    }
}

/// The fields `addOffset` writes: a vector selector's, or a subquery's own.
struct OffsetTarget {
    var selector: VectorSelector?
    var subquery: SubqueryExpr?
    var endPosNode: EndPosNode

    init(selector: VectorSelector?, subquery: SubqueryExpr? = nil, endPosNode: EndPosNode) {
        self.selector = selector
        self.subquery = subquery
        self.endPosNode = endPosNode
    }

    func originalOffset() -> GoDuration {
        selector?.originalOffset ?? subquery?.originalOffset ?? GoDuration(nanoseconds: 0)
    }
    func originalOffsetExpr() -> DurationExpr? {
        selector?.originalOffsetExpr ?? subquery?.originalOffsetExpr
    }
    func setOriginalOffset(_ d: GoDuration) {
        selector?.originalOffset = d
        subquery?.originalOffset = d
    }
    func setOriginalOffsetExpr(_ e: DurationExpr) {
        selector?.originalOffsetExpr = e
        subquery?.originalOffsetExpr = e
    }
    func setEndPos(_ pos: Pos) { endPosNode.set(pos) }
}

/// The fields the `@` modifier writes.
struct AtModifierTarget {
    var selector: VectorSelector?
    var subquery: SubqueryExpr?
    var endPosNode: EndPosNode

    init(selector: VectorSelector?, subquery: SubqueryExpr? = nil, endPosNode: EndPosNode) {
        self.selector = selector
        self.subquery = subquery
        self.endPosNode = endPosNode
    }

    func timestamp() -> Int64? { selector?.timestamp ?? subquery?.timestamp }
    func startOrEnd() -> ItemType {
        selector?.startOrEnd ?? subquery?.startOrEnd ?? ItemType(0)
    }
    func setTimestamp(_ ts: Int64) {
        selector?.timestamp = ts
        subquery?.timestamp = ts
    }
    func setStartOrEnd(_ t: ItemType) {
        selector?.startOrEnd = t
        subquery?.startOrEnd = t
    }
    func setEndPos(_ pos: Pos) { endPosNode.set(pos) }
}
