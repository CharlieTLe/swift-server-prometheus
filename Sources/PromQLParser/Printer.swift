//===----------------------------------------------------------------------===//
// Ported from promql/parser/printer.go @ v3.13.2
//
// Every string here is a contract. `String()` has to parse back to the same
// node — the exit gate is parse(print(parse(x))) == parse(x) — and it is what
// `promtool`, the web API and every error message show the user.
//
// Two rules that are easy to get wrong and are pinned by the promql/parse
// fixture:
//
//   - Floats go through GoFloat.format, never Swift's own formatting (ADR-4).
//     `%v` on a float64 is 'g' with precision -1; a timestamp is 'f' with
//     precision 3; a plain NumberLiteral is 'f' with precision -1.
//   - Durations go through PromDuration, which is model.Duration, not
//     time.Duration: `5m`, never `5m0s`.
//===----------------------------------------------------------------------===//

private import GoCompat
private import PromLabels
private import PromModel

// MARK: - Tree

/// Go: `Tree` — the tree structure of a node, one line per node.
public func tree(_ node: any Node) -> String {
    treeImpl(node, "")
}

private func treeImpl(_ node: (any Node)?, _ level: String) -> String {
    guard let node else {
        // Go: `%T` of a nil interface renders as "<nil>".
        return "\(level) |---- <nil>\n"
    }
    var t = "\(level) |---- \(node.nodeTypeName) :: \(node.description)\n"
    let level = level + " · · ·"
    for child in children(of: node) {
        t += treeImpl(child, level)
    }
    return t
}

// MARK: - Shared helpers

/// Go: `writeLabels` — comma-separated label names, quoting the ones the legacy
/// scheme would reject. The scheme is `LegacyValidation` even under UTF-8 label
/// support: printing quotes anything that is not a bare identifier.
private func writeLabels(_ ss: [String]) -> String {
    var out = ""
    for (i, s) in ss.enumerated() {
        if i > 0 { out += ", " }
        if !ValidationScheme.legacy.isValidLabelName(s) {
            out += GoStrconv.quote(s)
        } else {
            out += s
        }
    }
    return out
}

/// Go: `fmt.Sprintf("%v", f)` for a float64 — 'g' with precision -1.
private func fmtV(_ f: Double) -> String {
    GoFloat.format(f, .g, precision: -1)
}

/// Go: `model.Duration(d).String()`. `d` is a `time.Duration`, and the cast is
/// what switches it to PromQL's formatting.
private func modelDurationString(_ d: GoDuration) -> String {
    PromDuration(nanoseconds: d.nanoseconds).description
}

/// The ` @ <timestamp>` / ` @ start()` / ` @ end()` suffix, shared by the three
/// node types that can carry an `@` modifier.
private func atSuffix(timestamp: Int64?, startOrEnd: ItemType) -> String {
    if let ts = timestamp {
        // Go: `%.3f` over the timestamp in seconds.
        return " @ " + GoFloat.format(Double(ts) / 1000.0, .f, precision: 3)
    }
    if startOrEnd == .start { return " @ start()" }
    if startOrEnd == .end { return " @ end()" }
    return ""
}

/// The ` offset <duration>` suffix. Note the sign is written explicitly and the
/// magnitude formatted from the negated value, so a negative offset prints as
/// `offset -5m` rather than as a negative duration.
private func offsetSuffix(_ offset: GoDuration, _ offsetExpr: DurationExpr?) -> String {
    if let e = offsetExpr { return " offset \(e)" }
    if offset.nanoseconds > 0 { return " offset " + modelDurationString(offset) }
    if offset.nanoseconds < 0 {
        return " offset -" + modelDurationString(GoDuration(nanoseconds: -offset.nanoseconds))
    }
    return ""
}

// MARK: - AggregateExpr

extension AggregateExpr {
    public var description: String {
        var b = aggOpStr
        b += "("
        if op.isAggregatorWithParam {
            b += param?.description ?? ""
            b += ", "
        }
        b += expr?.description ?? ""
        b += ")"
        return b
    }

    /// Go: `ShortString()` — the operator and its grouping clause, without the
    /// aggregated expression. The prettifier uses it as a line header.
    public var shortString: String { aggOpStr }

    /// Go: `writeAggOpStr`. Note the trailing space after the grouping clause,
    /// which is why `sum by (a) (foo)` has one and `sum(foo)` does not.
    private var aggOpStr: String {
        var b = op.description
        if without {
            b += " without ("
            b += writeLabels(grouping)
            b += ") "
        } else if !grouping.isEmpty {
            b += " by ("
            b += writeLabels(grouping)
            b += ") "
        }
        return b
    }
}

// MARK: - BinaryExpr

extension BinaryExpr {
    public var description: String {
        lhs.description + " " + op.description + returnBoolStr + matchingStr + " "
            + rhs.description
    }

    public var shortString: String { op.description + returnBoolStr + matchingStr }

    private var returnBoolStr: String { returnBool ? " bool" : "" }

    /// Go: `getMatchingStr`.
    ///
    /// The three clauses are independent: an `on`/`ignoring` clause is emitted
    /// whenever there are matching labels **or** a cardinality modifier, which is
    /// why `foo group_left bar` prints an empty ` ignoring ()`.
    var matchingStr: String {
        guard let vm = vectorMatching else { return "" }
        var matching = ""

        if !vm.matchingLabels.isEmpty || vm.on || vm.card == .manyToOne
            || vm.card == .oneToMany
        {
            let tag = vm.on ? "on" : "ignoring"
            matching = " " + tag + " (" + writeLabels(vm.matchingLabels) + ")"
        }

        if vm.card == .manyToOne || vm.card == .oneToMany {
            let side = vm.card == .manyToOne ? "left" : "right"
            matching += " group_" + side + " (" + writeLabels(vm.include) + ")"
        }

        if vm.fillValues.lhs != nil || vm.fillValues.rhs != nil {
            if let l = vm.fillValues.lhs, let r = vm.fillValues.rhs, l == r {
                matching += " fill (\(fmtV(l)))"
            } else {
                if let l = vm.fillValues.lhs { matching += " fill_left (\(fmtV(l)))" }
                if let r = vm.fillValues.rhs { matching += " fill_right (\(fmtV(r)))" }
            }
        }
        return matching
    }
}

// MARK: - DurationExpr

extension DurationExpr {
    public var description: String {
        var b = ""
        writeTo(&b)
        return b
    }

    public var shortString: String { op.description }

    /// Go: `writeTo`. The `step()`/`range()`/`min_of`/`max_of` forms are checked
    /// before the nil-LHS test, because those have no operands either.
    func writeTo(_ b: inout String) {
        if wrapped { b += "(" }

        if op == .step {
            b += "step()"
        } else if op == .range {
            b += "range()"
        } else if op == .minOf {
            b += "min_of("
            b += lhs?.description ?? ""
            b += ", "
            b += rhs?.description ?? ""
            b += ")"
        } else if op == .maxOf {
            b += "max_of("
            b += lhs?.description ?? ""
            b += ", "
            b += rhs?.description ?? ""
            b += ")"
        } else if lhs == nil {
            // A unary duration expression. A leading `+` is dropped: it carries no
            // information and reparsing without it gives the same node.
            switch op {
            case .sub:
                b += op.description
                b += rhs?.description ?? ""
            case .add:
                b += rhs?.description ?? ""
            default:
                // Go panics here. The parser cannot build such a node.
                preconditionFailure("unexpected unary duration expression: \(op)")
            }
        } else {
            b += lhs?.description ?? ""
            b += " "
            b += op.description
            b += " "
            b += rhs?.description ?? ""
        }

        if wrapped { b += ")" }
    }
}

// MARK: - Call

extension Call {
    public var description: String {
        (function?.name ?? "") + "(" + Expressions.string(args) + ")"
    }

    public var shortString: String { function?.name ?? "" }
}

// MARK: - MatrixSelector

extension MatrixSelector {
    /// Go: `atOffset` — the `@` and `offset` suffixes, taken from the *inner*
    /// vector selector, because that is where the parser records them.
    private var atOffset: (at: String, offset: String) {
        guard let vs = vectorSelector as? VectorSelector else { return ("", "") }
        return (
            atSuffix(timestamp: vs.timestamp, startOrEnd: vs.startOrEnd),
            offsetSuffix(vs.originalOffset, vs.originalOffsetExpr)
        )
    }

    public var description: String {
        let (at, offset) = atOffset
        // Go copies the VectorSelector by value and clears the modifiers so they
        // are not printed twice. With reference semantics that would mutate the
        // real node, so the inner selector is rendered with the modifiers
        // suppressed instead.
        var inner = ""
        var anchored = false
        var smoothed = false
        if let vs = vectorSelector as? VectorSelector {
            inner = vs.stringSuppressingModifiers()
            anchored = vs.anchored
            smoothed = vs.smoothed
        } else {
            inner = vectorSelector.description
        }

        var extendedAttribute = ""
        if anchored {
            extendedAttribute = " anchored"
        } else if smoothed {
            extendedAttribute = " smoothed"
        }

        var rangeStr = modelDurationString(range)
        if let re = rangeExpr { rangeStr = re.description }

        return "\(inner)[\(rangeStr)]\(extendedAttribute)\(at)\(offset)"
    }

    public var shortString: String {
        let (at, offset) = atOffset
        var rangeStr = modelDurationString(range)
        if let re = rangeExpr { rangeStr = re.description }
        return "[\(rangeStr)]\(at)\(offset)"
    }
}

// MARK: - SubqueryExpr

extension SubqueryExpr {
    public var description: String { expr.description + subqueryTimeSuffix }

    public var shortString: String { subqueryTimeSuffix }

    /// Go: `getSubqueryTimeSuffix` — `[<range>:<step>] @ <ts> offset <offset>`.
    ///
    /// Note the step is taken from `Step` first and only then from `StepExpr`,
    /// the opposite order from the range. That is upstream's ordering, and it
    /// matters for `foo[5m:]`, where both are zero-valued and the step is empty.
    var subqueryTimeSuffix: String {
        var stepStr = ""
        if step.nanoseconds != 0 {
            stepStr = modelDurationString(step)
        } else if let se = stepExpr {
            stepStr = se.description
        }
        let offset = offsetSuffix(originalOffset, originalOffsetExpr)
        let at = atSuffix(timestamp: timestamp, startOrEnd: startOrEnd)
        var rangeStr = modelDurationString(range)
        if let re = rangeExpr { rangeStr = re.description }
        return "[\(rangeStr):\(stepStr)]\(at)\(offset)"
    }
}

// MARK: - Literals and the remaining nodes

extension NumberLiteral {
    public var description: String {
        if duration {
            // The value is held in seconds, so it goes back to nanoseconds for
            // formatting. Go's float-to-int64 conversion truncates toward zero;
            // so does Swift's Int64(_:) on a Double.
            if val < 0 {
                return "-" + modelDurationString(GoDuration(nanoseconds: Int64(-val * 1e9)))
            }
            return modelDurationString(GoDuration(nanoseconds: Int64(val * 1e9)))
        }
        return GoFloat.format(val, .f, precision: -1)
    }
}

extension ParenExpr {
    public var description: String { "(" + expr.description + ")" }
}

extension StringLiteral {
    public var description: String { GoStrconv.quote(bytes: val) }
}

extension UnaryExpr {
    public var description: String { op.description + expr.description }
    public var shortString: String { op.description }
}

extension VectorSelector {
    public var description: String { stringSuppressingModifiers(suppress: false) }

    /// Go builds this from a by-value copy of the node with the modifiers
    /// zeroed, which `MatrixSelector.String()` relies on. `suppress` is that
    /// copy, expressed without mutating anything.
    func stringSuppressingModifiers(suppress: Bool = true) -> String {
        var labelStrings = [String]()
        for matcher in labelMatchers {
            // A nil matcher only exists after a parse error, and nothing is
            // printed after one — Go dereferences here unconditionally.
            guard let matcher else { continue }
            // The __name__ matcher is folded into the bare name, but only when it
            // is exactly the equality matcher the name produced. An explicit
            // empty-name matcher is kept.
            if matcher.name == LabelName.metricName && matcher.type == .equal
                && matcher.value == name && !matcher.value.isEmpty
            {
                continue
            }
            labelStrings.append(matcher.description)
        }

        var b = name
        if !labelStrings.isEmpty {
            b += "{"
            // Sorted, so printing is independent of matcher order. Byte-wise, not
            // by Unicode collation — ADR-10.
            b += labelStrings
                .sorted { $0.utf8Lexicographic < $1.utf8Lexicographic }
                .joined(separator: ",")
            b += "}"
        }
        if suppress { return b }

        b += atSuffix(timestamp: timestamp, startOrEnd: startOrEnd)
        if anchored {
            b += " anchored"
        } else if smoothed {
            b += " smoothed"
        }
        b += offsetSuffix(originalOffset, originalOffsetExpr)
        return b
    }
}
