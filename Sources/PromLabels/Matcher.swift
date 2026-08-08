//===----------------------------------------------------------------------===//
// Ported from model/labels/matcher.go @ v3.13.2
//
// Regex matching sits behind the `RegexMatching` protocol. Phase 1 ships a
// literal-only matcher that THROWS on anything it cannot handle exactly; Phase 2
// replaces it with a real RE2 (`PromRegex`). See docs/DECISIONS.md ADR-6.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `labels.MatchType`.
public enum MatchType: Int, Sendable, CaseIterable, CustomStringConvertible {
    case equal = 0
    case notEqual
    case regexp
    case notRegexp

    /// Go: `MatchType.String()`.
    public var description: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "!="
        case .regexp: return "=~"
        case .notRegexp: return "!~"
        }
    }
}

/// The seam Phase 2's RE2 engine plugs into.
///
/// ⚠️ `setMatches` is not merely an optimisation: TSDB uses it to turn a regex
/// matcher into direct index lookups. It must be correct before Phase 6.
public protocol RegexMatching: Sendable {
    /// Go: `FastRegexMatcher.GetRegexString()`.
    var regexString: String { get }
    /// Go: `FastRegexMatcher.MatchString(s)`. Fully anchored.
    func matchString(_ s: String) -> Bool
    /// Go: `FastRegexMatcher.SetMatches()`. Empty when it cannot be reduced to a
    /// finite set of equality matches.
    var setMatches: [String] { get }
    /// Go: `FastRegexMatcher.prefix`.
    var prefix: String { get }
    /// Go: `FastRegexMatcher.IsOptimized()`.
    var isOptimized: Bool { get }
}

/// Builds the matcher used for `=~` / `!~`.
///
/// Injected rather than held in a mutable global: global mutable state is not
/// concurrency-safe under Swift 6, and a compile-time default expresses the
/// Phase-1 → Phase-2 swap more honestly. When `PromRegex` lands, change
/// `defaultRegexFactory` in one place.
public typealias RegexFactory = @Sendable (String) throws -> any RegexMatching

public let defaultRegexFactory: RegexFactory = { try LiteralOnlyRegexMatcher(pattern: $0) }

/// Go: `labels.Matcher`.
public struct Matcher: Sendable, CustomStringConvertible {

    public let type: MatchType
    public let name: String
    public let value: String
    private let re: (any RegexMatching)?

    /// Go: `labels.NewMatcher(t, n, v)`.
    public init(
        _ type: MatchType, _ name: String, _ value: String,
        regexFactory: RegexFactory = defaultRegexFactory
    ) throws {
        self.type = type
        self.name = name
        self.value = value
        if type == .regexp || type == .notRegexp {
            self.re = try regexFactory(value)
        } else {
            self.re = nil
        }
    }

    /// Go: `Matcher.Matches(s)`.
    public func matches(_ s: String) -> Bool {
        switch type {
        case .equal: return s == value
        case .notEqual: return s != value
        case .regexp: return re?.matchString(s) ?? false
        case .notRegexp: return !(re?.matchString(s) ?? false)
        }
    }

    /// Go: `Matcher.String()`.
    public var description: String {
        var out = ""
        out += shouldQuoteName ? GoStrconv.quote(name) : name
        out += type.description
        out += GoStrconv.quote(value)
        return out
    }

    /// Go: `Matcher.shouldQuoteName()`.
    ///
    /// Ported separately from `ValidationScheme.isValidLabelName` even though the
    /// two agree, because Go keeps them separate and they could drift. Note Go
    /// iterates runes with a *byte* index, so any non-ASCII rune fails the
    /// character classes and forces quoting; an empty name is also quoted.
    var shouldQuoteName: Bool {
        if name.isEmpty { return true }
        for (i, c) in name.utf8.enumerated() {
            let ok =
                c == UInt8(ascii: "_")
                || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
                || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || (i > 0 && c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
            if !ok { return true }
        }
        return false
    }

    /// Go: `Matcher.Inverse()`.
    public func inverse() throws -> Matcher {
        switch type {
        case .equal: return try Matcher(.notEqual, name, value)
        case .notEqual: return try Matcher(.equal, name, value)
        case .regexp: return try Matcher(.notRegexp, name, value)
        case .notRegexp: return try Matcher(.regexp, name, value)
        }
    }

    /// Go: `Matcher.GetRegexString()`.
    public var regexString: String { re?.regexString ?? "" }
    /// Go: `Matcher.SetMatches()`.
    public var setMatches: [String] { re?.setMatches ?? [] }
    /// Go: `Matcher.Prefix()`.
    public var prefix: String { re?.prefix ?? "" }
    /// Go: `Matcher.IsRegexOptimized()`.
    public var isRegexOptimized: Bool { re?.isOptimized ?? false }
}

/// A deliberately limited Phase-1 stand-in for `FastRegexMatcher`.
///
/// It handles only patterns whose semantics are unambiguous without a regex
/// engine: a plain literal, or an alternation of plain literals (`a|b|c`) —
/// which covers what `SetMatches` exists to optimise. Anything else throws.
///
/// Throwing is deliberate. The alternative — reaching for
/// `NSRegularExpression` — would silently substitute backtracking ICU semantics
/// for RE2's, which diverges on pathological patterns *and* is a denial-of-service
/// surface, since these patterns arrive verbatim from user queries. A loud
/// failure until Phase 2 lands is far better than quietly wrong matching.
/// See ADR-6.
public struct LiteralOnlyRegexMatcher: RegexMatching {

    public let regexString: String
    private let literals: [String]

    public struct Unsupported: Error, CustomStringConvertible {
        public let pattern: String
        public var description: String {
            """
            regex not supported until Phase 2 (PromRegex): \(pattern)
            Phase 1 handles only literals and literal alternations; see ADR-6.
            """
        }
    }

    /// True for the empty pattern, which Go treats specially — see `setMatches`.
    private let isEmptyPattern: Bool

    public init(pattern: String) throws {
        regexString = pattern
        isEmptyPattern = pattern.isEmpty
        // Go anchors matchers fully, so `a|b` means exactly "a" or "b".
        let parts = pattern.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let metacharacters = Set(".*+?()[]{}^$\\")
        for p in parts where p.contains(where: { metacharacters.contains($0) }) {
            throw Unsupported(pattern: pattern)
        }
        literals = parts
    }

    public func matchString(_ s: String) -> Bool { literals.contains(s) }

    /// Go's `optimizeAlternatingLiterals` returns a matcher but **nil** setMatches
    /// for the empty pattern, even though the set would be `[""]` — so an empty
    /// regex falls back to matching rather than to an index lookup. Reproduced here.
    ///
    /// Sorted but **not** deduplicated: Go's slice-backed matcher returns
    /// duplicates for "a|a". The order itself is not contractual — above roughly
    /// 16 alternates Go switches to a map-backed matcher and iterates a randomized
    /// Go map — so both sides sort. See docs/PORTING.md.
    public var setMatches: [String] {
        if isEmptyPattern { return [] }
        return literals.sorted()
    }

    /// The longest common prefix of the alternatives.
    public var prefix: String {
        guard var common = literals.first else { return "" }
        for l in literals.dropFirst() {
            common = String(zip(common, l).prefix { $0.0 == $0.1 }.map(\.0))
        }
        return common
    }

    public var isOptimized: Bool { true }
}
