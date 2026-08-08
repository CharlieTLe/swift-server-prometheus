//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/regexp.go and parse.go (Flags)
//
// ADR-6: Prometheus's label matchers are RE2 semantics — linear time, no
// backreferences. Substituting NSRegularExpression would swap in backtracking
// ICU, which diverges on pathological patterns and is a denial-of-service
// surface on a user-facing query API.
//===----------------------------------------------------------------------===//

/// Go: `syntax.Op`.
///
/// Raw values match Go's `1 + iota` ordering, which is load-bearing: the printer
/// compares `sub.Op > OpCapture` to decide whether a repeat operand needs
/// parenthesising.
public enum RegexOp: UInt8, Sendable, Comparable, CustomStringConvertible {
    case noMatch = 1  // matches no strings
    case emptyMatch  // matches the empty string
    case literal  // matches the Rune sequence
    case charClass  // matches Rune interpreted as range pairs
    case anyCharNotNL  // any character except newline
    case anyChar  // any character
    case beginLine  // empty string at beginning of line
    case endLine  // empty string at end of line
    case beginText  // empty string at beginning of text
    case endText  // empty string at end of text
    case wordBoundary  // \b
    case noWordBoundary  // \B
    case capture  // capturing subexpression
    case star  // Sub[0] zero or more times
    case plus  // Sub[0] one or more times
    case quest  // Sub[0] zero or one times
    case `repeat`  // Sub[0] between Min and Max times (Max == -1 is unbounded)
    case concat  // concatenation of Subs
    case alternate  // alternation of Subs

    public static func < (a: RegexOp, b: RegexOp) -> Bool { a.rawValue < b.rawValue }

    /// Go: the stringer-generated `Op.String()`, used in error text.
    public var description: String {
        switch self {
        case .noMatch: return "NoMatch"
        case .emptyMatch: return "EmptyMatch"
        case .literal: return "Literal"
        case .charClass: return "CharClass"
        case .anyCharNotNL: return "AnyCharNotNL"
        case .anyChar: return "AnyChar"
        case .beginLine: return "BeginLine"
        case .endLine: return "EndLine"
        case .beginText: return "BeginText"
        case .endText: return "EndText"
        case .wordBoundary: return "WordBoundary"
        case .noWordBoundary: return "NoWordBoundary"
        case .capture: return "Capture"
        case .star: return "Star"
        case .plus: return "Plus"
        case .quest: return "Quest"
        case .repeat: return "Repeat"
        case .concat: return "Concat"
        case .alternate: return "Alternate"
        }
    }
}

/// Go: `syntax.Flags`.
public struct RegexFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Case-insensitive match.
    public static let foldCase = RegexFlags(rawValue: 1 << 0)
    /// Treat the pattern as a literal string.
    public static let literal = RegexFlags(rawValue: 1 << 1)
    /// Allow character classes like `[^a-z]` to match newline.
    public static let classNL = RegexFlags(rawValue: 1 << 2)
    /// Allow `.` to match newline.
    public static let dotNL = RegexFlags(rawValue: 1 << 3)
    /// Treat `^` and `$` as matching only at the beginning and end of text.
    public static let oneLine = RegexFlags(rawValue: 1 << 4)
    /// Make repetition operators default to non-greedy.
    public static let nonGreedy = RegexFlags(rawValue: 1 << 5)
    /// Allow Perl extensions.
    public static let perlX = RegexFlags(rawValue: 1 << 6)
    /// Allow `\p{Han}` / `\P{Han}`.
    public static let unicodeGroups = RegexFlags(rawValue: 1 << 7)
    /// The `OpEndText` came from `$`, not `\z`. Affects printing and `Equal`.
    public static let wasDollar = RegexFlags(rawValue: 1 << 8)
    /// The regexp contains no counted repetition.
    public static let simple = RegexFlags(rawValue: 1 << 9)

    public static let matchNL: RegexFlags = [.classNL, .dotNL]
    /// As close to Perl as possible — and what Prometheus uses, together with
    /// `.dotNL` (`syntax.Parse(v, syntax.Perl|syntax.DotNL)`).
    public static let perl: RegexFlags = [.classNL, .oneLine, .perlX, .unicodeGroups]
    public static let posix: RegexFlags = []
}

/// Go: `syntax.Regexp` — a node in the parsed syntax tree.
///
/// A **class**, not a struct: Go's parser builds and rewrites nodes in place, and
/// Prometheus's `findSetMatches`/`clearCapture`/`clearBeginEndText` mutate the
/// tree they are handed. Reference semantics keep those ports faithful instead of
/// fighting copy-on-write.
public final class Regexp: @unchecked Sendable {
    public var op: RegexOp
    public var flags: RegexFlags
    /// Subexpressions, if any.
    public var sub: [Regexp]
    /// Matched runes: the literal sequence for `.literal`, or range *pairs*
    /// (lo, hi, lo, hi, …) for `.charClass`.
    public var rune: [UInt32]
    /// Min/Max for `.repeat`; Max == -1 means unbounded.
    public var min: Int
    public var max: Int
    /// Capture index and optional name for `.capture`.
    public var cap: Int
    public var name: String

    public init(
        op: RegexOp,
        flags: RegexFlags = [],
        sub: [Regexp] = [],
        rune: [UInt32] = [],
        min: Int = 0,
        max: Int = 0,
        cap: Int = 0,
        name: String = ""
    ) {
        self.op = op
        self.flags = flags
        self.sub = sub
        self.rune = rune
        self.min = min
        self.max = max
        self.cap = cap
        self.name = name
    }

    /// Go: `(*Regexp).Equal` — identical structure, not pointer identity.
    public func isEqual(to other: Regexp?) -> Bool {
        guard let other else { return false }
        if op != other.op { return false }
        switch op {
        case .endText:
            // The parse flags remember whether this was `$` or `\z`.
            return flags.intersection(.wasDollar) == other.flags.intersection(.wasDollar)
        case .literal, .charClass:
            return flags.intersection(.foldCase) == other.flags.intersection(.foldCase)
                && rune == other.rune
        case .alternate, .concat:
            guard sub.count == other.sub.count else { return false }
            for (a, b) in zip(sub, other.sub) where !a.isEqual(to: b) { return false }
            return true
        case .star, .plus, .quest:
            return flags.intersection(.nonGreedy) == other.flags.intersection(.nonGreedy)
                && sub[0].isEqual(to: other.sub[0])
        case .repeat:
            return flags.intersection(.nonGreedy) == other.flags.intersection(.nonGreedy)
                && min == other.min && max == other.max
                && sub[0].isEqual(to: other.sub[0])
        case .capture:
            return cap == other.cap && name == other.name && sub[0].isEqual(to: other.sub[0])
        default:
            return true
        }
    }

    /// Go: `(*Regexp).MaxCap`.
    public func maxCap() -> Int {
        var m = op == .capture ? cap : 0
        for s in sub {
            m = Swift.max(m, s.maxCap())
        }
        return m
    }

    /// Go: `(*Regexp).CapNames`.
    public func capNames() -> [String] {
        var names = [String](repeating: "", count: maxCap() + 1)
        collectCapNames(&names)
        return names
    }

    private func collectCapNames(_ names: inout [String]) {
        if op == .capture, cap < names.count { names[cap] = name }
        for s in sub { s.collectCapNames(&names) }
    }

    /// A deep copy. Needed because several ported algorithms mutate in place.
    public func copy() -> Regexp {
        Regexp(
            op: op, flags: flags, sub: sub.map { $0.copy() }, rune: rune,
            min: min, max: max, cap: cap, name: name)
    }
}
