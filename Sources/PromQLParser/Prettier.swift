//===----------------------------------------------------------------------===//
// Ported from promql/parser/prettier.go @ v3.13.2
//
// The rule, from upstream's own notes: a node is split across lines only when
// its normalised (String()) form exceeds 100 characters. Every node receives the
// depth its parent gives it and indents by two spaces per level — but only if
// the parent actually broke the line, which is what a level of 0 encodes.
//
// A trap worth naming: `needsSplit` measures `len(n.String())`, which is a
// **byte** count in Go. Swift's `String.count` counts grapheme clusters, so a
// query with any multi-byte character would split at a different width. Every
// length here is taken over `.utf8`.
//===----------------------------------------------------------------------===//

/// Go: `maxCharactersPerLine`.
let maxCharactersPerLine = 100

/// Go: `Prettify`.
public func prettify(_ n: any Node) -> String {
    n.pretty(0)
}

/// Go: `needsSplit` — normalise the node and see whether it is too long. The
/// normalisation is what removes trailing whitespace before measuring.
private func needsSplit(_ n: (any Node)?) -> Bool {
    guard let n else { return false }
    return n.description.utf8.count > maxCharactersPerLine
}

/// Go: `indent`.
private func indent(_ n: Int) -> String {
    String(repeating: "  ", count: max(0, n))
}

/// Go: `getCommonPrefixIndent` — the leaf case: indent, then the node itself.
private func commonPrefixIndent(_ level: Int, _ current: any Node) -> String {
    indent(level) + current.description
}

extension AggregateExpr {
    public func pretty(_ level: Int) -> String {
        var s = indent(level)
        if !needsSplit(self) {
            s += description
            return s
        }
        s += shortString
        s += "(\n"
        if op.isAggregatorWithParam, let param {
            s += "\(param.pretty(level + 1)),\n"
        }
        s += "\(expr?.pretty(level + 1) ?? "")\n\(indent(level)))"
        return s
    }
}

extension BinaryExpr {
    public func pretty(_ level: Int) -> String {
        let s = indent(level)
        if !needsSplit(self) {
            return s + description
        }
        let returnBoolStr = returnBool ? " bool" : ""
        return
            "\(lhs.pretty(level + 1))\n\(indent(level))\(op)\(returnBoolStr)\(matchingStr)\n\(rhs.pretty(level + 1))"
    }
}

extension DurationExpr {
    /// A duration expression never splits, whatever its level.
    public func pretty(_: Int) -> String {
        var s: String
        if lhs == nil {
            s = "\(op)\(rhs?.pretty(0) ?? "")"
        } else {
            s = "\(lhs?.pretty(0) ?? "") \(op) \(rhs?.pretty(0) ?? "")"
        }
        if wrapped { s = "(\(s))" }
        return s
    }
}

extension Call {
    public func pretty(_ level: Int) -> String {
        var s = indent(level)
        if !needsSplit(self) {
            s += description
            return s
        }
        s +=
            "\(function?.name ?? "")(\n\(Expressions.pretty(args, level + 1))\n\(indent(level)))"
        return s
    }
}

extension ParenExpr {
    public func pretty(_ level: Int) -> String {
        let s = indent(level)
        if !needsSplit(self) {
            return s + description
        }
        return "\(s)(\n\(expr.pretty(level + 1))\n\(indent(level)))"
    }
}

extension MatrixSelector {
    public func pretty(_ level: Int) -> String { commonPrefixIndent(level, self) }
}

extension SubqueryExpr {
    /// Note this one does **not** indent when it fits: it returns `String()`
    /// bare, unlike every other node, which prefixes `indent(level)`.
    public func pretty(_ level: Int) -> String {
        if !needsSplit(self) { return description }
        return "\(expr.pretty(level))\(subqueryTimeSuffix)"
    }
}

extension VectorSelector {
    public func pretty(_ level: Int) -> String { commonPrefixIndent(level, self) }
}

extension NumberLiteral {
    public func pretty(_ level: Int) -> String { commonPrefixIndent(level, self) }
}

extension StringLiteral {
    public func pretty(_ level: Int) -> String { commonPrefixIndent(level, self) }
}

extension UnaryExpr {
    public func pretty(_ level: Int) -> String {
        // The child's own indent is stripped, because the prefix goes before the
        // operator instead.
        let child = expr.pretty(level).trimmingGoSpace()
        return "\(indent(level))\(op)\(child)"
    }
}

extension String {
    /// Go: `strings.TrimSpace` — trims Unicode whitespace from both ends.
    ///
    /// The set is Go's `unicode.IsSpace`: the ASCII controls '\t'-'\r' and ' ',
    /// U+0085, U+00A0, and the Unicode `White_Space` property. Only ASCII space
    /// can actually appear here (the prettifier's own indent), but the set is
    /// spelled out so a future caller does not inherit a narrower rule by
    /// accident.
    func trimmingGoSpace() -> String {
        let isGoSpace: (Character) -> Bool = { c in
            guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
                return false
            }
            switch s.value {
            case 0x09...0x0D, 0x20, 0x85, 0xA0:
                return true
            default:
                return s.properties.isWhitespace
            }
        }
        var view = Substring(self)
        while let f = view.first, isGoSpace(f) { view = view.dropFirst() }
        while let l = view.last, isGoSpace(l) { view = view.dropLast() }
        return String(view)
    }
}
