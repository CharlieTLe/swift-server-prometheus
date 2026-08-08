//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/prog.go and simplify.go
//===----------------------------------------------------------------------===//

/// Go: `syntax.InstOp`.
public enum InstOp: UInt8, Sendable {
    case alt = 0
    case altMatch
    case capture
    case emptyWidth
    case match
    case fail
    case nop
    case rune
    case rune1
    case runeAny
    case runeAnyNotNL
}

/// Go: `syntax.EmptyOp` — a kind or mixture of zero-width assertions.
public struct EmptyOp: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let beginLine = EmptyOp(rawValue: 1 << 0)
    public static let endLine = EmptyOp(rawValue: 1 << 1)
    public static let beginText = EmptyOp(rawValue: 1 << 2)
    public static let endText = EmptyOp(rawValue: 1 << 3)
    public static let wordBoundary = EmptyOp(rawValue: 1 << 4)
    public static let noWordBoundary = EmptyOp(rawValue: 1 << 5)
}

/// Go: `syntax.IsWordChar`. Deliberately ASCII-only, as `\b`/`\B` are defined.
@inlinable
public func isWordChar(_ r: Int32) -> Bool {
    (r >= 97 && r <= 122) || (r >= 65 && r <= 90) || (r >= 48 && r <= 57) || r == 95
}

/// Go: `syntax.EmptyOpContext`. `-1` means "past the edge of the text".
public func emptyOpContext(_ r1: Int32, _ r2: Int32) -> EmptyOp {
    var op: EmptyOp = .noWordBoundary
    var boundary: UInt8 = 0
    if isWordChar(r1) {
        boundary = 1
    } else if r1 == 0x0A {
        op.insert(.beginLine)
    } else if r1 < 0 {
        op.formUnion([.beginText, .beginLine])
    }
    if isWordChar(r2) {
        boundary ^= 1
    } else if r2 == 0x0A {
        op.insert(.endLine)
    } else if r2 < 0 {
        op.formUnion([.endText, .endLine])
    }
    if boundary != 0 {  // isWordChar(r1) != isWordChar(r2)
        op.formSymmetricDifference([.wordBoundary, .noWordBoundary])
    }
    return op
}

/// Go: `syntax.Inst`.
public struct Inst: Sendable {
    public var op: InstOp = .fail
    public var out: UInt32 = 0
    public var arg: UInt32 = 0
    public var rune: [UInt32] = []

    /// Go: `Inst.MatchRune`.
    ///
    /// A single-element `rune` slice means a literal, not a one-element class;
    /// that is why folding is applied only in that case.
    func matchRune(_ r: UInt32) -> Bool {
        switch rune.count {
        case 0:
            return false
        case 1:
            let r0 = rune[0]
            if r == r0 { return true }
            if RegexFlags(rawValue: UInt16(truncatingIfNeeded: arg)).contains(.foldCase) {
                var r1 = UnicodeTables.simpleFold(r0)
                while r1 != r0 {
                    if r == r1 { return true }
                    r1 = UnicodeTables.simpleFold(r1)
                }
            }
            return false
        case 2:
            return r >= rune[0] && r <= rune[1]
        case 4, 6, 8:
            // Linear scan for a few pairs; handles ASCII classes well.
            var j = 0
            while j < rune.count {
                if r < rune[j] { return false }
                if r <= rune[j + 1] { return true }
                j += 2
            }
            return false
        default:
            var lo = 0
            var hi = rune.count / 2
            while lo < hi {
                let m = (lo + hi) / 2
                if rune[2 * m] <= r {
                    if r <= rune[2 * m + 1] { return true }
                    lo = m + 1
                } else {
                    hi = m
                }
            }
            return false
        }
    }

    /// Go: `Inst.MatchEmptyWidth`.
    func matchEmptyWidth(_ before: Int32, _ after: Int32) -> Bool {
        switch EmptyOp(rawValue: UInt8(truncatingIfNeeded: arg)) {
        case .beginLine: return before == 0x0A || before == -1
        case .endLine: return after == 0x0A || after == -1
        case .beginText: return before == -1
        case .endText: return after == -1
        case .wordBoundary: return isWordChar(before) != isWordChar(after)
        case .noWordBoundary: return isWordChar(before) == isWordChar(after)
        default: return false
        }
    }
}

/// Go: `syntax.Prog`.
public struct RegexProgram: Sendable {
    public var inst: [Inst] = []
    public var start: Int = 0
    public var numCap: Int = 2
}

// MARK: - Simplify

extension Regexp {

    /// Go: `(*Regexp).Simplify` — removes counted repetition and folds
    /// idempotent operators, e.g. `(?:a+)+` becomes `a+`.
    ///
    /// The result executes identically but its `String()` may differ, because
    /// capturing parens can be duplicated or dropped: `(x){1,2}` simplifies to
    /// `(x)(x)?` where both capture as $1.
    public func simplify() -> Regexp {
        switch op {
        case .capture, .concat, .alternate:
            var changed = false
            var newSubs = [Regexp]()
            newSubs.reserveCapacity(sub.count)
            for s in sub {
                let ns = s.simplify()
                if ns !== s { changed = true }
                newSubs.append(ns)
            }
            if !changed { return self }
            let nre = Regexp(
                op: op, flags: flags, sub: newSubs, rune: [], min: min, max: max,
                cap: cap, name: name)
            return nre

        case .star, .plus, .quest:
            return Self.simplify1(op, flags, sub[0].simplify(), self)

        case .repeat:
            // x{0} matches the empty string without even considering x.
            if min == 0 && max == 0 { return Regexp(op: .emptyMatch) }

            let s = sub[0].simplify()

            // x{n,}: at least n matches.
            if max == -1 {
                if min == 0 { return Self.simplify1(.star, flags, s, nil) }  // x*
                if min == 1 { return Self.simplify1(.plus, flags, s, nil) }  // x+
                // x{4,} becomes xxxx+.
                var subs = [Regexp]()
                for _ in 0..<(min - 1) { subs.append(s) }
                subs.append(Self.simplify1(.plus, flags, s, nil))
                return Regexp(op: .concat, sub: subs)
            }

            // x{1} is just x.
            if min == 1 && max == 1 { return s }

            // x{n,m}: n copies then m-n optional copies, nested so the machine
            // does less work — x{2,5} becomes xx(x(x(x)?)?)?
            var prefix: Regexp? = nil
            if min > 0 {
                prefix = Regexp(op: .concat, sub: Array(repeating: s, count: min))
            }
            if max > min {
                var suffix = Self.simplify1(.quest, flags, s, nil)
                var i = min + 1
                while i < max {
                    let nre2 = Regexp(op: .concat, sub: [s, suffix])
                    suffix = Self.simplify1(.quest, flags, nre2, nil)
                    i += 1
                }
                guard let p = prefix else { return suffix }
                p.sub.append(suffix)
            }
            if let p = prefix { return p }

            // Degenerate (min > max, or min < max < 0): impossible match.
            return Regexp(op: .noMatch)

        default:
            return self
        }
    }

    /// Go: `simplify1`.
    private static func simplify1(
        _ op: RegexOp, _ flags: RegexFlags, _ sub: Regexp, _ re: Regexp?
    ) -> Regexp {
        // Repeating the empty string any number of times is still the empty string.
        if sub.op == .emptyMatch { return sub }
        // The operators are idempotent when the greediness matches.
        if op == sub.op, flags.intersection(.nonGreedy) == sub.flags.intersection(.nonGreedy) {
            return sub
        }
        if let re, re.op == op,
            re.flags.intersection(.nonGreedy) == flags.intersection(.nonGreedy),
            sub === re.sub[0]
        {
            return re
        }
        return Regexp(op: op, flags: flags, sub: [sub])
    }
}
